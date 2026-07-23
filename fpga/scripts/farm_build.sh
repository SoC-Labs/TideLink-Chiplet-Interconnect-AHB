#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### TideLink FPGA concurrent farm — single (TARGET, HOST) build worker
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Builds ONE Vivado TARGET on ONE host, then leaves the artefacts at the
### canonical local path  imp/fpga/output/<TARGET>/  so `make deploy` /
### deploy_pair work unchanged.
###
###   HOST = local                      build here (orchestrator already ran
###                                      package_ip once; we pass
###                                      SKIP_PACKAGE_IP=1 so the parallel
###                                      runs don't race the shared IP repo).
###   HOST = <farm hostname>            ssh+rsync: push the tree to
###                                      ~/<REMOTE_ROOT>/<TARGET>/ on HOST,
###                                      run package_ip+build_design THERE,
###                                      rsync only output/<TARGET>/ back.
###                                      No shared FS / NFS export needed —
###                                      this is independent-job farming, NOT
###                                      Vivado `launch_runs -host`.
###
### Usage:   farm_build.sh <TARGET> <HOST>
### Env:     REMOTE_ROOT  subdir under remote $HOME for this checkout's farm
###                       trees. DEFAULT is AUTO-DERIVED PER-CHECKOUT:
###                       .cache/tidelink-farm-<worktree-basename>-<sha1[:8] of
###                       worktree abspath>, so two different local checkouts
###                       NEVER share a remote tree (the concurrent-collision
###                       incident). Set explicitly to override / deliberately
###                       share a tree.
###          FARM_LOCK_WAIT seconds to wait for the per-target remote-tree lock
###                       before failing (default 14400; 0 = fail fast). Two
###                       jobs sharing HOST+REMOTE_ROOT+TARGET serialize on it.
###          FARM_LOCK_DIR local dir holding the lockfiles
###                       (default $HOME/.cache/tidelink-farm-locks)
###          FPGA_NUM_JOBS         override Vivado -jobs (default: local=4,
###                                remote=8)
###          FPGA_INSERT_DEBUG_CORE passed through to build_design.tcl
###          SSH_OPTS              extra ssh options (default BatchMode batch)
### Standalone preflight for the remote case: fpga/scripts/setup_farm_ssh.sh
###-----------------------------------------------------------------------------
set -u

# SILENT-V1 GUARD (2026-07-05): the pair targets MUST be packaged as V2. With
# TIDELINK_PHY_V2 unset, the old `[ -n "$VAR" ]` forwards aborted under set -u
# and remote package_ip silently selected the V1 flist (4 occurrences: fcsm
# a=2/b=1 cal=0 no-link fingerprint). Fail LOUDLY here instead.
if [ -z "${TIDELINK_PHY_V2:-}" ]; then
    echo "ERROR: TIDELINK_PHY_V2 is unset - pair targets would package a SILENT-V1 IP." >&2
    echo "       export TIDELINK_PHY_V2=1 (V2) explicitly before farm builds." >&2
    exit 1
fi

TARGET="${1:?usage: farm_build.sh <TARGET> <HOST>}"
HOST="${2:?usage: farm_build.sh <TARGET> <HOST>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
FPGA_DIR="$TIDELINK_HOME/fpga"

# REMOTE_ROOT: the subdir under the remote $HOME that holds this checkout's
# farm trees (RTREE=$RHOME/$REMOTE_ROOT/$TARGET). AUTO-DERIVED PER-CHECKOUT by
# default so two different local worktrees NEVER share a remote RTREE. THE
# incident this guards (2026-07): two checkouts building the same TARGET into
# one shared .cache/tidelink-farm/<TARGET> — the second's rsync --delete +
# `create_project -force` deleted the first's running impl -> phantom "timing
# wall" no-bit failures, mis-diagnosed for days. The default embeds the
# worktree basename (human-readable) + an 8-char sha1 of its ABSPATH
# (collision-proof across identically-named checkouts). An explicit REMOTE_ROOT
# still overrides (e.g. to deliberately share a tree between jobs).
if [ -z "${REMOTE_ROOT:-}" ]; then
    _ck_base="$(basename "$TIDELINK_HOME")"
    _ck_hash="$(printf '%s' "$TIDELINK_HOME" | sha1sum | cut -c1-8)"
    REMOTE_ROOT=".cache/tidelink-farm-${_ck_base}-${_ck_hash}"
fi
VIVADO_BIN="${VIVADO_BIN:-/apps/Xilinx/Vivado/2024.1/bin/vivado}"
# Vivado's own launch_runs default ssh opts — same here for the build login.
read -r -a SSH_OPTS_ARR <<< "${SSH_OPTS:--q -o ConnectTimeout=30 -o ConnectionAttempts=3 -o BatchMode=yes}"
SSH=(ssh -T "${SSH_OPTS_ARR[@]}")

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
say() { printf '[farm %s@%s %s] %s\n' "$TARGET" "$HOST" "$(ts)" "$*"; }
die() { printf '[farm %s@%s %s] ERROR: %s\n' "$TARGET" "$HOST" "$(ts)" "$*" >&2; exit 1; }

# Shared EDA-env preamble. Pin CMSDK to the standalone BP210 install (the
# Corstone-101 BP210 is missing cmsdk_fpga_sram.v — see the cmsdk_fpga_sram
# workaround); set_env.sh then derives XHB500_IP_DIR and skips XHB500
# regeneration because deps/xhb500/generated/ is rsynced along (it is
# gitignored but a real on-disk artefact, deliberately NOT excluded).
ARM_IP_LIBRARY_PATH="${ARM_IP_LIBRARY_PATH:-/research/AAA/ip_library}"
CMSDK_DIR="${CMSDK_DIR:-$ARM_IP_LIBRARY_PATH/BP210/BP210-BU-00000-r1p1-00rel0}"
CMSDK_FPGA_SRAM_V="${CMSDK_FPGA_SRAM_V:-$CMSDK_DIR/logical/models/memories/cmsdk_fpga_sram.v}"
FPGA_INSERT_DEBUG_CORE="${FPGA_INSERT_DEBUG_CORE:-}"
FPGA_USE_IDELAY="${FPGA_USE_IDELAY:-}"
# Forwarded so the msg gate bypass reaches the REMOTE build_design session.
# NOTE (2026-07-05 forensics): the gate's get_msg_config count only sees the
# PARENT Vivado session's messages — impl-run CWs (e.g. Timing 38-282) are in
# the launch_runs child process and are ALWAYS invisible to the gate (every
# log shows "count after impl_1 : 0" even with 10 CWs in the child). This
# knob therefore only matters for parent-session CWs (BD create/validate).
FPGA_ALLOW_CRITICAL_WARNINGS="${FPGA_ALLOW_CRITICAL_WARNINGS:-}"

# rsync: ship the whole repo tree EXCEPT host-specific build outputs and
# bulky sim/coverage debris. Keep deps/ (submodule working tree + the
# generated XHB500 IP) and the constraints/RTL. --delete mirrors source
# deletions; excluded paths are PROTECTED from --delete (no
# --delete-excluded) so the remote imp/ a prior build produced survives
# and Vivado can build incrementally on re-sync.
RSYNC_EXCLUDES=(
    --exclude '.git/'           --exclude 'imp/'
    # uvm/ + cocotb/ are simulation-only — the Vivado package_ip/build_design
    # flow never reads them; dropping them roughly halves the sync.
    --exclude 'uvm/'            --exclude 'cocotb/'
    --exclude '.claude/'        --exclude '__pycache__/'
    --exclude '.pytest_cache/'  --exclude '*.pyc'
    --exclude '*.fsdb'          --exclude '*.vpd'
    --exclude '*.vcd'           --exclude '*.wlf'
    --exclude 'csrc/'           --exclude 'simv'
    --exclude 'simv.daidir/'    --exclude 'DVEfiles/'
    --exclude 'verdiLog/'       --exclude 'novas.*'
    --exclude '.Xil/'           --exclude '*.jou'
    --exclude '*.log'           --exclude '*.bak'
)

is_local() {
    case "$HOST" in
        local|localhost) return 0 ;;
    esac
    [ "$HOST" = "$(hostname -s 2>/dev/null)" ] && return 0
    [ "$HOST" = "$(hostname -f 2>/dev/null)" ] && return 0
    return 1
}

build_env_prefix() {
    # Emitted verbatim into both the local make call and the remote bash.
    printf 'export ARM_IP_LIBRARY_PATH=%q CMSDK_DIR=%q CMSDK_FPGA_SRAM_V=%q; ' \
        "$ARM_IP_LIBRARY_PATH" "$CMSDK_DIR" "$CMSDK_FPGA_SRAM_V"
    # TIDELINK_PHY_V2 (2026-06-30): MUST be forwarded to package_ip. This is the
    # single knob fpga/filelist.tcl reads to select the V2 flist (the v2shims
    # that materialise the controller WITH `define TIDELINK_PHY_V2). If it is
    # NOT in the package_ip environment, filelist.tcl silently falls back to the
    # V1 flist and packages a V1 IP — the controller compiles with the define
    # UNDEFINED, so the entire `ifdef TIDELINK_PHY_V2 autonomous-winscan FSM is
    # preprocessed out (0 cells) while fch_arm degenerates to the `else (the FC
    # handoff still fires). Root cause of the 8705a99 byte-identical "FSM
    # optimised out" build: build_design got the define at the per-target synth
    # run, but package_ip (run earlier, here / in build_farm.sh) did NOT, so the
    # packaged IP was already V1 and the FSM never existed to be synthesised.
    [ -n "${TIDELINK_PHY_V2:-}" ] && \
        printf 'export TIDELINK_PHY_V2=%q; ' "$TIDELINK_PHY_V2"
    # TD_AUTO_LANE_MASK_E4 (2026-07-17): SAME TRAP as TIDELINK_PHY_V2 above, and
    # it bit on the first 8-lane farm build. This knob selects Wlink's tx/rx
    # lane-mask POR in fpga/filelist.tcl (unset/1 -> 8'hE4 = 4 lanes; 0 -> 8'hFF
    # = 8 lanes), and Wlink derives bytesPerCycle = popcount(lane_mask)*2 — so
    # it IS the link's bandwidth. The remote job re-sources filelist.tcl with
    # its own environment: without this forward the var is UNSET there, the
    # default (1) applies, and the remote half of the pair silently builds
    # 4-lane while the local half builds 8-lane — a MIXED pair.
    # MEASURED on the first attempt: local package_ip logged "8'hFF (8 lanes)"
    # while pynq-z2-pair-flip-all@srv04936 logged "8'hE4 (4 lanes)
    # TD_AUTO_LANE_MASK_E4=<unset> (default 1)", and the resulting die_b .bin
    # came out byte-IDENTICAL (md5 e384eec6…) to the certified 4-lane build.
    # NB `-n` is correct for the value "0": it tests for a non-empty string.
    [ -n "${TD_AUTO_LANE_MASK_E4:-}" ] && \
        printf 'export TD_AUTO_LANE_MASK_E4=%q; ' "$TD_AUTO_LANE_MASK_E4"
    [ -n "${FPGA_INSERT_DEBUG_CORE:-}" ] && \
        printf 'export FPGA_INSERT_DEBUG_CORE=%q; ' "$FPGA_INSERT_DEBUG_CORE"
    [ -n "${FPGA_USE_IDELAY:-}" ] && \
        printf 'export FPGA_USE_IDELAY=%q; ' "$FPGA_USE_IDELAY"
    [ -n "${FPGA_ALLOW_CRITICAL_WARNINGS:-}" ] && \
        printf 'export FPGA_ALLOW_CRITICAL_WARNINGS=%q; ' "$FPGA_ALLOW_CRITICAL_WARNINGS"
    # PHC IP sibling repo (used by package_phc_ip). Optional — older trees
    # without PHC integration leave this unset and skip the PHC IP package.
    [ -n "${PHC_REPO_DIR:-}" ] && \
        printf 'export PHC_REPO_DIR=%q; ' "$PHC_REPO_DIR"
}

###----------------------------------------------------------------- LOCAL ----
if is_local; then
    JOBS="${FPGA_NUM_JOBS:-8}"   # SoC Labs 2026-06-21: 4->8 (overlap OOC sub-IP synth; QoR-neutral)
    say "local build start (jobs=$JOBS, SKIP_PACKAGE_IP=1)"
    # set_env.sh sets XHB500_IP_DIR (Makefile env-guard needs it); it honours
    # our pre-exported CMSDK_DIR. Source under set +e — its XHB500 codepath
    # returns non-zero shapes we don't want to abort on (it [skip]s here).
    export ARM_IP_LIBRARY_PATH CMSDK_DIR CMSDK_FPGA_SRAM_V
    # shellcheck disable=SC1091
    source "$TIDELINK_HOME/set_env.sh" >/dev/null 2>&1 || true
    # TIDELINK_PHY_V2 reaches the per-target build_design synth run (the top-run
    # -verilog_define injection in build_design.tcl). See build_env_prefix().
    [ -n "${TIDELINK_PHY_V2:-}" ] && export TIDELINK_PHY_V2
    [ -n "${FPGA_INSERT_DEBUG_CORE:-}" ] && export FPGA_INSERT_DEBUG_CORE
    [ -n "${FPGA_USE_IDELAY:-}" ] && export FPGA_USE_IDELAY
    [ -n "${FPGA_ALLOW_CRITICAL_WARNINGS:-}" ] && export FPGA_ALLOW_CRITICAL_WARNINGS
    if make -C "$FPGA_DIR" build_design \
            TARGET="$TARGET" SKIP_PACKAGE_IP=1 FPGA_NUM_JOBS="$JOBS"; then
        say "local build OK -> $TIDELINK_HOME/imp/fpga/output/$TARGET/tidelink.bit"
        exit 0
    fi
    die "local build_design failed for $TARGET"
fi

###---------------------------------------------------------------- REMOTE ----
JOBS="${FPGA_NUM_JOBS:-8}"
say "remote farm build (jobs=$JOBS)"

# Preflight — fail fast with the actionable fix, never hang a parallel run.
"${SSH[@]}" "$HOST" true 2>/dev/null \
    || die "ssh $HOST failed under BatchMode — run fpga/scripts/setup_farm_ssh.sh FARM_HOST=$HOST"
RHOME="$("${SSH[@]}" "$HOST" 'printf %s "$HOME"' 2>/dev/null)"
[ -n "$RHOME" ] || die "could not resolve \$HOME on $HOST"
"${SSH[@]}" "$HOST" "test -x '$VIVADO_BIN'" 2>/dev/null \
    || die "$VIVADO_BIN absent/not executable on $HOST"
"${SSH[@]}" "$HOST" "test -d '$CMSDK_DIR' && command -v rsync >/dev/null && command -v make >/dev/null" 2>/dev/null \
    || die "$HOST missing one of: $CMSDK_DIR / rsync / make"

RTREE="$RHOME/$REMOTE_ROOT/$TARGET"

# ---- HARD LOCK on the remote tree (create_project -force race guard) --------
# THE incident this whole file is hardened against: two farm jobs (from two
# checkouts that share HOST+REMOTE_ROOT) targeting the same RTREE. Job A is
# mid-impl; job B rsync --delete's over RTREE and runs package_ip/build_design
# whose `create_project -force` DELETES A's running project -> A produces no
# bit (mis-read as a "timing wall" for days).
#
# Mechanism: a LOCAL advisory flock keyed on the exact remote destination
# (HOST + REMOTE_ROOT + TARGET). All farm orchestration runs on this one lab
# box (every worktree shares $HOME), so a local lock is authoritative for who
# may touch a given remote RTREE. The FD is opened here and HELD until this
# farm_build.sh process EXITS, so the ENTIRE remote critical section — the
# rsync --delete AND the remote create_project/build AND the artefact pull —
# is serialized as one indivisible unit (a remote-only flock could not cover
# the locally-launched rsync --delete, the other half of the clobber). Only
# jobs that would actually collide (same HOST+REMOTE_ROOT+TARGET) contend;
# per-checkout REMOTE_ROOT means distinct checkouts never reach for the lock.
command -v flock >/dev/null 2>&1 \
    || die "flock not found — cannot safely serialize the remote tree (install util-linux)"
LOCK_DIR="${FARM_LOCK_DIR:-$HOME/.cache/tidelink-farm-locks}"
mkdir -p "$LOCK_DIR" || die "cannot create lock dir $LOCK_DIR"
LOCK_KEY="$(printf '%s' "${HOST}__${REMOTE_ROOT}__${TARGET}" | tr -c 'A-Za-z0-9._-' '_')"
LOCKFILE="$LOCK_DIR/${LOCK_KEY}.lock"
LOCK_WAIT="${FARM_LOCK_WAIT:-14400}"   # 0 = fail fast; else seconds to serialize
exec {LOCK_FD}>"$LOCKFILE" || die "cannot open lockfile $LOCKFILE"
if [ "$LOCK_WAIT" -eq 0 ]; then
    flock -n "$LOCK_FD" \
        || die "another build holds $TARGET on $HOST:$REMOTE_ROOT (FARM_LOCK_WAIT=0) — refusing to clobber its impl; use a distinct REMOTE_ROOT to build in parallel"
elif ! flock -n "$LOCK_FD"; then
    say "another build holds $TARGET on $HOST:$REMOTE_ROOT — serializing, waiting up to ${LOCK_WAIT}s (lock: $LOCKFILE)"
    flock -w "$LOCK_WAIT" "$LOCK_FD" \
        || die "timed out after ${LOCK_WAIT}s waiting for the $TARGET lock on $HOST:$REMOTE_ROOT — another build still holds it; use a distinct REMOTE_ROOT to build in parallel"
fi
say "acquired remote-tree lock $LOCKFILE"

say "rsync tree -> $HOST:$RTREE/"
"${SSH[@]}" "$HOST" "mkdir -p '$RTREE'" 2>/dev/null \
    || die "cannot mkdir $RTREE on $HOST"
if ! rsync -a --delete "${RSYNC_EXCLUDES[@]}" \
        -e "ssh ${SSH_OPTS_ARR[*]}" \
        "$TIDELINK_HOME/" "$HOST:$RTREE/"; then
    die "rsync of tree to $HOST failed"
fi

say "remote package_ip + build_design $TARGET (jobs=$JOBS)"
# Feed the build script over stdin to `bash -s` — ssh execs bash directly,
# the script arrives verbatim (no remote re-quoting of a nested bash -c).
# %q-quoted values are parsed by that remote bash, which is correct.
REMOTE_CMD="set -e; cd $(printf %q "$RTREE"); $(build_env_prefix)"
REMOTE_CMD+="source set_env.sh >/dev/null 2>&1 || true; "
REMOTE_CMD+="make -C fpga package_ip; "
# Package the PHC IP on the remote too, if its sibling repo is present.
# Mirrors the local 'package_phc_ip (once)' step in build_farm.sh; without
# this the BD on -all / pair targets hits [BD 5-390] for the PHC VLNV. The
# remote is expected to have ~/SoCLabs/ptp-hardware-clock-ahb (or PHC_REPO_DIR
# pre-exported via build_env_prefix above); if not, skip and proceed.
REMOTE_CMD+="if [ -d \"\${PHC_REPO_DIR:-\$HOME/SoCLabs/ptp-hardware-clock-ahb}\" ]; then make -C fpga package_phc_ip; else echo '[farm_build] PHC_REPO_DIR not present on remote - skipping package_phc_ip'; fi; "
REMOTE_CMD+="make -C fpga build_design TARGET=$(printf %q "$TARGET") SKIP_PACKAGE_IP=1 FPGA_NUM_JOBS=$(printf %q "$JOBS")"
build_rc=0
printf '%s\n' "$REMOTE_CMD" | "${SSH[@]}" "$HOST" bash -s || build_rc=$?

# Always try to pull the run log back for diagnosis; pull artefacts only on
# success (a failed run leaves none / stale ones — don't poison the local
# output dir that deploy reads).
mkdir -p "$TIDELINK_HOME/imp/fpga/run/$TARGET"
rsync -a -e "ssh ${SSH_OPTS_ARR[*]}" \
    "$HOST:$RTREE/imp/fpga/run/$TARGET/" \
    "$TIDELINK_HOME/imp/fpga/run/$TARGET/" 2>/dev/null || true

if [ "$build_rc" -ne 0 ]; then
    die "remote build_design failed on $HOST (rc=$build_rc) — see imp/fpga/run/$TARGET/build_design.log"
fi

say "rsync artefacts <- $HOST"
mkdir -p "$TIDELINK_HOME/imp/fpga/output/$TARGET"
if ! rsync -a -e "ssh ${SSH_OPTS_ARR[*]}" \
        "$HOST:$RTREE/imp/fpga/output/$TARGET/" \
        "$TIDELINK_HOME/imp/fpga/output/$TARGET/"; then
    die "rsync of artefacts from $HOST failed"
fi
[ -f "$TIDELINK_HOME/imp/fpga/output/$TARGET/tidelink.bit" ] \
    || die "no tidelink.bit in pulled-back output/$TARGET (build claimed OK?)"

say "remote build OK -> $TIDELINK_HOME/imp/fpga/output/$TARGET/tidelink.bit"
exit 0
