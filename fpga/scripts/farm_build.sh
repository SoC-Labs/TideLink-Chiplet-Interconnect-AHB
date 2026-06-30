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
### Env:     REMOTE_ROOT  (default .cache/tidelink-farm, under remote $HOME)
###          FPGA_NUM_JOBS         override Vivado -jobs (default: local=4,
###                                remote=8)
###          FPGA_INSERT_DEBUG_CORE passed through to build_design.tcl
###          SSH_OPTS              extra ssh options (default BatchMode batch)
### Standalone preflight for the remote case: fpga/scripts/setup_farm_ssh.sh
###-----------------------------------------------------------------------------
set -u

TARGET="${1:?usage: farm_build.sh <TARGET> <HOST>}"
HOST="${2:?usage: farm_build.sh <TARGET> <HOST>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
FPGA_DIR="$TIDELINK_HOME/fpga"

REMOTE_ROOT="${REMOTE_ROOT:-.cache/tidelink-farm}"
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
    [ -n "$TIDELINK_PHY_V2" ] && \
        printf 'export TIDELINK_PHY_V2=%q; ' "$TIDELINK_PHY_V2"
    [ -n "$FPGA_INSERT_DEBUG_CORE" ] && \
        printf 'export FPGA_INSERT_DEBUG_CORE=%q; ' "$FPGA_INSERT_DEBUG_CORE"
    [ -n "$FPGA_USE_IDELAY" ] && \
        printf 'export FPGA_USE_IDELAY=%q; ' "$FPGA_USE_IDELAY"
    # PHC IP sibling repo (used by package_phc_ip). Optional — older trees
    # without PHC integration leave this unset and skip the PHC IP package.
    [ -n "$PHC_REPO_DIR" ] && \
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
    [ -n "$TIDELINK_PHY_V2" ] && export TIDELINK_PHY_V2
    [ -n "$FPGA_INSERT_DEBUG_CORE" ] && export FPGA_INSERT_DEBUG_CORE
    [ -n "$FPGA_USE_IDELAY" ] && export FPGA_USE_IDELAY
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
