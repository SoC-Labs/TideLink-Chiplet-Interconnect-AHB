#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### TideLink FPGA — MANDATORY pre-farm-build gate (farm_gate)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### WHY THIS EXISTS
###
### The 2026 bring-up campaign's most expensive failures were NOT physics — they
### were build/fidelity bugs that a fast pre-build check would have turned red in
### seconds instead of days on silicon:
###
###   * silent-V1 / stale IP  — a V2 build silently packaged the V1 PHY IP, or
###                             edited RTL never re-packaged, so the bitstream did
###                             not contain the RTL it claimed to (roots 8705a99,
###                             project_farm_package_ip_stale). Caught by the
###                             IP-match tier (content hash + V2 marker).
###   * dropped-XDC           — a constraint silently not applied (xdc_lint).
###   * comb-loop / latch     — an anti-pattern the idealised sim never exercised
###                             (sv_anti_pattern_lint + the SILICON-config sim).
###   * anchor / eye margin   — deskew / marginal-eye behaviour only visible at
###                             the silicon epoch fingerprint + silicon clock ratio
###                             (EPOCH_PROFILE=silicon + TIDELINK_SIM_REF_PERIOD_NS
###                             + EYE_FAULT + reduced-lane + the bridge BFM).
###
### This gate runs those checks and MUST pass before any farm build launches. It
### is the single highest-value piece of the verif-infra hardening: it moves the
### campaign's dominant failure classes to build time. Every artefact it produces
### is stamped with the git SHA + dirty flag + V1/V2 marker so a build can always
### be traced to the tree it came from.
###
### FAST-FAIL ORDER (cheap first, so a misconfig dies in <1 s, not after a sim):
###   Tier-0.0 PROVENANCE  (ms)      git SHA + -dirty + V1/V2 marker + flist +
###                                  submodule pins -> JSON manifest. Never blocks;
###                                  it is the record you consult when a build is
###                                  suspect. (skip: FARM_GATE_SKIP_PROV=1)
###   Tier-0.a IP-MATCH    (ms)      silent-V1 env guard + V2-source presence +
###                                  packaged-IP content-hash vs current RTL +
###                                  V2 marker in the packaged IP. Hard-fail on a
###                                  STALE / silent-V1 package.  Reuses the SAME
###                                  procs build_design.tcl uses (build_provenance
###                                  .tcl), so gate and build agree exactly.
###                                  (skip: FARM_GATE_SKIP_IPMATCH=1)
###   Tier-0.b xdc_lint    (ms)      dropped-XDC / anti-pattern constraint gate,
###                                  RATCHETED vs fpga/farm_gate_xdc_baseline.txt.
###                                  (skip: FARM_GATE_SKIP_XDC=1)
###   Tier-0.c sv_anti_pattern (ms)  first-party latch / incomplete-case lint,
###                                  RATCHETED vs fpga/farm_gate_sv_baseline.txt.
###                                  (skip: FARM_GATE_SKIP_SV=1)
###   Tier-1   SIM         (minutes) the V2 pair sim, in two named tiers:
###       FUNCTIONAL (always, blocking): zero-epoch bring-up + reduced-lane +
###           XHB bridge BFM. Must be green on ANY sound V2 branch.
###       SILICON (first-class, runs by default): the SAME stack at the SILICON
###           epoch fingerprint AND the silicon clock ratio (40 ns ref-period) +
###           the v37 negative-control detector. This is the silicon-faithful
###           check the idealised default never ran. Its blocking policy tracks
###           FARM_GATE_STRESS (see below). (skip: FARM_GATE_SKIP_SILICON=1)
###
### SILICON tier blocking policy — WHY it is not always hard-blocking
###   The silicon profile's green-ness is PHY-pin dependent. The autonomous-deskew
###   pin (deps/tidelink-phy @ bbd094c, Loop-12..14 anchor-verify) is expected to
###   PASS it; the older pin (9f4953c, the feat/dieb-clock-fix-wip base) is
###   MARGINAL — at the 40 ns silicon ratio the FCSM stalls short of LINK_IDLE and
###   data does not cross (measured 2026-07-07). So:
###     * default (FARM_GATE_STRESS unset): the SILICON tier RUNS and its result
###       is reported first-class, but a FAIL is ADVISORY (loud WARN, non-blocking)
###       — the base branch stays green while you still SEE the silicon result.
###     * FARM_GATE_STRESS=1 (run this on the autonomous/unified lineage where the
###       silicon profile MUST be green): a SILICON-tier FAIL is BLOCKING, and the
###       harsher STRESS-only stages (marginal-eye eye_fault, silicon bridge BFM)
###       are added. A RED there is a real deskew/eye regression.
###
### EXIT: 0 = GREEN (safe to launch farm build). Non-zero = RED (refuse to build).
###
### ENV KNOBS  (every check is independently skippable for emergencies; all ON by
###             default so a build host can never silently drop a check)
###   FARM_GATE_FAST=1            Tier-0 only (dev pre-flight; NOT a build gate).
###   FARM_GATE_SKIP_PROV=1       skip the provenance stamp.
###   FARM_GATE_SKIP_IPMATCH=1    skip the IP-match / silent-V1 tier.
###   FARM_GATE_SKIP_XDC=1        skip xdc_lint.
###   FARM_GATE_SKIP_SV=1         skip sv_anti_pattern lint.
###   FARM_GATE_SKIP_SILICON=1    skip the silicon-faithful sim tier (functional
###                              sim still runs).
###   FARM_GATE_STRESS=1          promote the SILICON tier to BLOCKING + add the
###                              harsher STRESS stages (autonomous-lineage gate).
###   FARM_GATE_ALLOW_V1=1        accept an intentional V1 build (else an unset
###                              TIDELINK_PHY_V2 is failed as a silent-V1 risk).
###   FARM_GATE_ALLOW_NO_SIM=1    downgrade "VCS/cocotb absent" from FAIL to WARN.
###   FARM_GATE_SILICON_REF_NS=N  silicon-tier ref-clock period (default 40 = the
###                              silicon ratio; e.g. 8 to match the idealised sim).
###   FARM_GATE_SIM_STAGES="a b"  override the sim-stage list (names below); every
###                              listed stage is treated as BLOCKING.
###   FARM_GATE_STAMP=<path>      write a SHA-stamped pass token here on success
###                              (build_farm.sh consumes it as proof-of-gate).
###-----------------------------------------------------------------------------
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="${TIDELINK_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$TIDELINK_HOME"
# build_provenance.tcl's tl_repo_root prefers this; pin it so the gate and the
# build resolve the repo root identically regardless of cwd.
export SOCLABS_TIDELINK_DIR="$TIDELINK_HOME"

LINT_DIR="cocotb/lint"
PAIR_DIR="cocotb/tidelink_top_pair_v2"
SV_BASELINE="fpga/farm_gate_sv_baseline.txt"
XDC_BASELINE="fpga/farm_gate_xdc_baseline.txt"
GATE_TCL="$SCRIPT_DIR/scripts/farm_gate_tcl.tcl"
IP_REPO="imp/fpga/tidelink_ip"
LOG_DIR="imp/fpga/run/farm_gate"
mkdir -p "$LOG_DIR"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)}"

# Canonical V2-only marker source: present in the V2 flist / packaged IP, absent
# from V1. Used both for the on-disk V2-source presence check and the
# packaged-IP silent-V1 grep.
V2_MARKER_SRC="deps/tidelink-phy/rtl/tidelink_lane_deskew.sv"
V2_MARKER_BASE="$(basename "$V2_MARKER_SRC")"

# Silicon-tier ref-clock period (ns). 40 = the on-silicon clock ratio (see
# pair_v2_common.py TIDELINK_SIM_REF_PERIOD_NS); default sim uses 8.
SILICON_REF_NS="${FARM_GATE_SILICON_REF_NS:-40}"

RED=0            # accumulates BLOCKING failures; non-zero -> gate RED
declare -a FAILED_CHECKS=()
declare -a ADVISORIES=()   # non-blocking warnings (surfaced, do not fail)

hr()   { printf '%s\n' "=============================================================="; }
say()  { printf '[farm_gate] %s\n' "$*"; }
fail() { RED=1; FAILED_CHECKS+=("$1"); printf '[farm_gate] FAIL: %s\n' "$1" >&2; }
warn() { ADVISORIES+=("$1"); printf '[farm_gate] WARN(advisory): %s\n' "$1" >&2; }
pass() { printf '[farm_gate] ok:   %s\n' "$1"; }
skip() { printf '[farm_gate] SKIP: %s\n' "$1"; }

# emit a message with the right severity: $1=block|advise, $2=message
sev_report() { if [ "$1" = block ]; then fail "$2"; else warn "$2"; fi; }

hr; say "TideLink pre-build gate — $(date 2>/dev/null || echo '')"
say "TIDELINK_HOME=$TIDELINK_HOME"
say "mode=$([ "${FARM_GATE_FAST:-0}" = 1 ] && echo FAST-lint-only || echo full-lint+sim)  stress=$([ "${FARM_GATE_STRESS:-0}" = 1 ] && echo ON || echo off)"
hr

# ---------------------------------------------------------------------------
# Generic RATCHET: run a lint, reduce findings to stable "path:line: CODE" keys,
# and fail ONLY on keys not already in the accepted baseline. This keeps the
# gate green on today's known/accepted debt yet red on any NEW finding — and
# red on a lint that CRASHED rather than reporting nothing.
#
# extract_keys / lint_evaluable / ratchet_lint live in fpga/lint_ratchet.sh so
# ci/checker_controls/control_farm_gate_ratchet.sh can grade them directly.
# ---------------------------------------------------------------------------
# shellcheck source=fpga/lint_ratchet.sh
. "$SCRIPT_DIR/lint_ratchet.sh"

# ===========================================================================
# Tier-0.0  PROVENANCE stamp  (cheapest; never blocks — it is the record)
# ===========================================================================
PROV_JSON="$LOG_DIR/farm_gate_provenance.$STAMP.json"
if [ "${FARM_GATE_SKIP_PROV:-0}" = 1 ]; then
    skip "Tier-0.0 provenance (FARM_GATE_SKIP_PROV=1)"
else
    say "Tier-0.0  provenance stamp (git SHA + -dirty + V1/V2 marker) ..."
    if command -v tclsh >/dev/null 2>&1 && [ -f "$GATE_TCL" ]; then
        if tclsh "$GATE_TCL" manifest "$PROV_JSON" "pre-build-gate" 2>&1 \
                | sed 's/^/[farm_gate]   /'; then
            say "provenance -> $PROV_JSON"
        else
            # A provenance write failing is a WARN, not a build blocker.
            warn "provenance stamp did not complete (see above) — non-blocking"
        fi
    else
        warn "provenance skipped — tclsh and/or $GATE_TCL absent (non-blocking)"
    fi
fi

# ===========================================================================
# Tier-0.a  IP-MATCH & silent-V1 guard  (cheap; hard-fails a stale/V1 package)
# ===========================================================================
if [ "${FARM_GATE_SKIP_IPMATCH:-0}" = 1 ]; then
    skip "Tier-0.a IP-match / silent-V1 (FARM_GATE_SKIP_IPMATCH=1)"
else
    say "Tier-0.a  IP-match & silent-V1 guard ..."
    # Resolve the V1/V2 marker + flist the packaging step WILL consume (mirrors
    # fpga/filelist.tcl exactly, via build_provenance.tcl).
    marker="V?"; flist="?"
    if command -v tclsh >/dev/null 2>&1 && [ -f "$GATE_TCL" ]; then
        _ml="$(tclsh "$GATE_TCL" marker 2>/dev/null || true)"
        [ -n "$_ml" ] && { marker="${_ml%% *}"; flist="${_ml##* }"; }
    fi
    say "  resolved: marker=$marker flist=$flist (TIDELINK_PHY_V2=${TIDELINK_PHY_V2:-<unset>})"

    # (1) silent-V1 ENV guard — the 8705a99 root cause. If TIDELINK_PHY_V2 is
    #     unset the upcoming package_ip silently picks the V1 flist; a "V2" build
    #     then ships the V1 IP byte-identically. Fail unless V1 is intentional.
    if [ -z "${TIDELINK_PHY_V2:-}" ]; then
        if [ "${FARM_GATE_ALLOW_V1:-0}" = 1 ]; then
            warn "TIDELINK_PHY_V2 unset — proceeding as an INTENTIONAL V1 build (FARM_GATE_ALLOW_V1=1)"
        else
            fail "silent-V1 risk: TIDELINK_PHY_V2 is unset/empty — package_ip would pick the V1 flist ($flist), shipping V1 IP under a 'V2' build. Export TIDELINK_PHY_V2=1 (or FARM_GATE_ALLOW_V1=1 for a real V1 build)."
        fi
    elif [ "${TIDELINK_PHY_V2:-}" = 1 ]; then
        # (2) V2-source PRESENCE on disk — catches an uninitialised submodule
        #     BEFORE an hours-long farm build dies at compile ("cannot open
        #     tidelink_lane_deskew.sv"). The V2-only anchor source must exist.
        if [ -f "$V2_MARKER_SRC" ]; then
            pass "V2 marker source present on disk ($V2_MARKER_SRC)"
        else
            fail "V2 requested but $V2_MARKER_SRC is missing — deps/tidelink-phy submodule not checked out. Run: git submodule update --init deps/tidelink-phy"
        fi
    fi

    # (3) Packaged-IP content match + V2 marker. Only meaningful if an IP repo
    #     already exists in this tree (build_farm re-packages fresh, so an ABSENT
    #     repo is fine here — reported, not failed).
    if [ -d "$IP_REPO/src" ]; then
        say "  packaged IP present ($IP_REPO/src) — content-hash vs current RTL ..."
        IPV_LOG="$LOG_DIR/ip_verify.$STAMP.log"
        ipv_rc=0
        tclsh "$GATE_TCL" verify_ip "$IP_REPO" >"$IPV_LOG" 2>&1 || ipv_rc=$?
        sed 's/^/[farm_gate]   /' "$IPV_LOG"
        if [ "$ipv_rc" -ne 0 ]; then
            fail "packaged IP is STALE / mismatched vs current RTL (see $IPV_LOG) — run 'make package_ip'"
        else
            pass "packaged IP content matches current RTL"
        fi
        # silent-V1 in an ALREADY-packaged IP: V2 requested but the V2 marker
        # file is absent from the packaged src -> the IP was packaged V1.
        if [ "${TIDELINK_PHY_V2:-}" = 1 ]; then
            if [ -e "$IP_REPO/src/$V2_MARKER_BASE" ] \
               || grep -rql "TIDELINK_PHY_V2" "$IP_REPO/src" 2>/dev/null; then
                pass "packaged IP carries the V2 marker ($V2_MARKER_BASE / TIDELINK_PHY_V2)"
            else
                fail "silent-V1: V2 requested but the packaged IP under $IP_REPO/src carries neither $V2_MARKER_BASE nor a TIDELINK_PHY_V2 marker — it was packaged V1. Re-run 'make package_ip' with TIDELINK_PHY_V2=1."
            fi
        fi
    else
        say "  no packaged IP in this tree ($IP_REPO/src absent) — build_farm will package fresh; env guard above ensures it is $marker."
    fi
fi

# ===========================================================================
# Tier-0.b  xdc_lint (dropped-XDC / anti-pattern constraint gate), RATCHETED
# ===========================================================================
if [ "${FARM_GATE_SKIP_XDC:-0}" = 1 ]; then
    skip "Tier-0.b xdc_lint (FARM_GATE_SKIP_XDC=1)"
else
    say "Tier-0.b  xdc_lint fpga/targets/ (ratcheted) ..."
    XDC_LOG="$LOG_DIR/xdc_lint.$STAMP.log"
    # Exit 1 means "findings exist" and the ratchet, not the exit code, decides
    # pass/fail — but 2 / 127 / a crash mean the lint did not run, and that is
    # NOT the same as finding nothing. Keep the status; ratchet_lint grades it.
    python3 "$LINT_DIR/xdc_lint.py" fpga/targets/ >"$XDC_LOG" 2>&1
    XDC_RC=$?
    ratchet_lint "xdc_lint" "$XDC_LOG" "$XDC_BASELINE" "$XDC_RC"
fi

# ===========================================================================
# Tier-0.c  sv_anti_pattern lint, RATCHETED against the accepted baseline
# ===========================================================================
if [ "${FARM_GATE_SKIP_SV:-0}" = 1 ]; then
    skip "Tier-0.c sv_anti_pattern (FARM_GATE_SKIP_SV=1)"
else
    say "Tier-0.c  sv_anti_pattern lint (ratcheted) ..."
    SV_LOG="$LOG_DIR/sv_anti_pattern.$STAMP.log"
    python3 "$LINT_DIR/sv_anti_pattern_lint.py" src/rtl >"$SV_LOG" 2>&1
    SV_RC=$?
    ratchet_lint "sv_anti_pattern" "$SV_LOG" "$SV_BASELINE" "$SV_RC"
fi

# ===========================================================================
# Tier-1  V2 PAIR SIM  (FUNCTIONAL always; SILICON first-class; skipped in FAST)
# ===========================================================================
# Stage catalogue: name -> a space-separated list of VAR=val tokens, applied to
# the sim as ENVIRONMENT (so both the compile-time make vars, EPOCH_PROFILE etc.
# via '?=', AND the runtime cocotb env, TIDELINK_SIM_REF_PERIOD_NS / TESTCASE,
# propagate uniformly).
#
# FUNCTIONAL — build HEALTH: zero-epoch bring-up + both directions + reduced-lane
# + XHB bridge BFM. Green on any sound V2 branch. Always on, always blocking.
#
# SILICON — silicon-faithful: the SAME stack at the v37 epoch fingerprint AND the
# 40 ns silicon clock ratio + the negative-control v37 detector. First-class:
# runs by default; blocking only under FARM_GATE_STRESS (see header).
#
# STRESS — the harshest silicon stages (marginal-eye eye_fault + silicon bridge
# BFM). Added only under FARM_GATE_STRESS=1.
declare -A SIM_STAGE=(
  [data_zero]="EPOCH_PROFILE=zero MODULE=test_v2_pair_data"
  [reduced_lane]="EPOCH_PROFILE=zero MODULE=test_v2_reduced_lane"
  [bridge_bfm]="EPOCH_PROFILE=zero MODULE=test_v2_xhb_window_bridge"
  [silicon_data]="EPOCH_PROFILE=silicon TIDELINK_SIM_REF_PERIOD_NS=$SILICON_REF_NS MODULE=test_v2_pair_data"
  [silicon_negctl]="EPOCH_PROFILE=silicon EPOCH_ANCHOR_DIS=1 TIDELINK_SIM_REF_PERIOD_NS=$SILICON_REF_NS MODULE=test_v2_pair_epoch_negctl"
  [silicon_bridge]="EPOCH_PROFILE=silicon TIDELINK_SIM_REF_PERIOD_NS=$SILICON_REF_NS MODULE=test_v2_xhb_window_bridge"
  [marginal_eye]="EPOCH_PROFILE=silicon EYE_FAULT=1 TIDELINK_SIM_REF_PERIOD_NS=$SILICON_REF_NS MODULE=test_v2_marginal_eye"
)
FUNCTIONAL_STAGES="data_zero reduced_lane bridge_bfm"
SILICON_STAGES="silicon_data silicon_negctl"
STRESS_STAGES="silicon_bridge marginal_eye"

# run_sim_stage <name> <var=val ...> <severity:block|advise>
run_sim_stage() {
    local name="$1" args="$2" sev="$3"
    local slog="$LOG_DIR/sim_${name}.$STAMP.log"
    local rxml="$PAIR_DIR/results.xml"
    say "Tier-1  sim[$name] ($sev): env $args make -C $PAIR_DIR"
    rm -f "$rxml"
    local mk_rc=0
    # shellcheck disable=SC2086
    env $args make -C "$PAIR_DIR" >"$slog" 2>&1 || mk_rc=$?
    # Modern cocotb makes the sim exit non-zero on a TEST failure, so a non-zero
    # mk_rc alone can't tell a compile error from a test failure. Always consult
    # results.xml: present + testcases + no <failure>/<error> is the truth. Only
    # a missing/empty results.xml means the sim never ran (real compile error).
    if [ ! -f "$rxml" ]; then
        sev_report "$sev" "sim[$name] — no results.xml (sim did not compile/run; make rc=$mk_rc) — see $slog"
        tail -n 25 "$slog" >&2 || true
        return
    fi
    local n_tc n_fail
    # NOTE: `grep -c` prints "0" AND exits 1 on a zero-count match, so the old
    # `|| echo 0` appended a SECOND "0", yielding the two-line string "0\n0".
    # `[ "0\n0" -eq/-ne 0 ]` then errors ("integer expression expected") and the
    # test is treated as false — so a 0-testcase harness failure would FALSE-PASS
    # and a genuine all-pass run emitted spurious stderr. grep -c already prints
    # the count; capture it and default an empty capture to 0 (same fix as
    # merge_guard.sh). No `|| echo 0`.
    n_tc="$(grep -c '<testcase' "$rxml" 2>/dev/null)"; n_tc=${n_tc:-0}
    n_fail="$(grep -cE '<failure|<error' "$rxml" 2>/dev/null)"; n_fail=${n_fail:-0}
    if [ "$n_tc" -eq 0 ]; then
        sev_report "$sev" "sim[$name] — results.xml has 0 testcases (harness/compile issue; make rc=$mk_rc) — see $slog"
    elif [ "$n_fail" -ne 0 ]; then
        sev_report "$sev" "sim[$name] — $n_fail/$n_tc testcase(s) FAILED — see $slog"
        grep -E 'FAIL|corrupt|undelivered|AssertionError' "$slog" | head -4 >&2 || true
    elif [ "$mk_rc" -ne 0 ]; then
        # results say all passed but make still failed -> infra noise (e.g. a
        # non-test post-step). Surface it but don't hide a real pass.
        sev_report "$sev" "sim[$name] — all $n_tc testcase(s) passed but make rc=$mk_rc (non-test error) — see $slog"
    else
        pass "sim[$name] — $n_tc/$n_tc testcase(s) passed"
    fi
}

if [ "${FARM_GATE_FAST:-0}" = 1 ]; then
    say "Tier-1 SIM: SKIPPED (FARM_GATE_FAST=1 — lint-only pre-flight, NOT a build gate)"
else
    have_sim=1
    command -v vcs          >/dev/null 2>&1 || have_sim=0
    command -v cocotb-config >/dev/null 2>&1 || have_sim=0
    if [ "$have_sim" -eq 0 ]; then
        if [ "${FARM_GATE_ALLOW_NO_SIM:-0}" = 1 ]; then
            say "WARNING: VCS/cocotb absent — Tier-1 SIM SKIPPED (FARM_GATE_ALLOW_NO_SIM=1)."
            say "         The silicon-config sim did NOT run; static tier only."
        else
            fail "Tier-1 SIM cannot run — vcs and/or cocotb-config not on PATH."
            say  "  A farm build host MUST be able to run the silicon-config sim."
            say  "  Set FARM_GATE_ALLOW_NO_SIM=1 only for a deliberately lint-only runner."
        fi
    else
        # Build the ordered (stage,severity) plan.
        declare -a PLAN_STAGE=() PLAN_SEV=()
        if [ -n "${FARM_GATE_SIM_STAGES:-}" ]; then
            # explicit override — every listed stage blocks
            for s in $FARM_GATE_SIM_STAGES; do PLAN_STAGE+=("$s"); PLAN_SEV+=("block"); done
        else
            for s in $FUNCTIONAL_STAGES; do PLAN_STAGE+=("$s"); PLAN_SEV+=("block"); done
            if [ "${FARM_GATE_SKIP_SILICON:-0}" = 1 ]; then
                skip "SILICON sim tier (FARM_GATE_SKIP_SILICON=1) — functional tier only"
            elif [ "${FARM_GATE_STRESS:-0}" = 1 ]; then
                say "SILICON tier = BLOCKING (+ STRESS stages) — FARM_GATE_STRESS=1"
                for s in $SILICON_STAGES $STRESS_STAGES; do PLAN_STAGE+=("$s"); PLAN_SEV+=("block"); done
            else
                say "SILICON tier = ADVISORY (first-class, non-blocking on this lineage; set FARM_GATE_STRESS=1 to gate it)"
                for s in $SILICON_STAGES; do PLAN_STAGE+=("$s"); PLAN_SEV+=("advise"); done
            fi
        fi
        for i in "${!PLAN_STAGE[@]}"; do
            s="${PLAN_STAGE[$i]}"; sev="${PLAN_SEV[$i]}"
            if [ -n "${SIM_STAGE[$s]:-}" ]; then
                run_sim_stage "$s" "${SIM_STAGE[$s]}" "$sev"
            else
                fail "unknown sim stage '$s' (valid: ${!SIM_STAGE[*]})"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
GIT_SHA="$(git -C "$TIDELINK_HOME" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
[ -n "$(git -C "$TIDELINK_HOME" status --porcelain 2>/dev/null)" ] && GIT_DIRTY="-dirty"

hr
# Surface advisories regardless of verdict (first-class visibility).
if [ "${#ADVISORIES[@]}" -ne 0 ]; then
    say "ADVISORY — ${#ADVISORIES[@]} non-blocking finding(s) (silicon-faithful tier; gate FARM_GATE_STRESS=1 to make them blocking):"
    for a in "${ADVISORIES[@]}"; do printf '[farm_gate]   ~ %s\n' "$a" >&2; done
fi

if [ "$RED" -ne 0 ]; then
    say "GATE RED — ${#FAILED_CHECKS[@]} check(s) failed on ${GIT_SHA}${GIT_DIRTY}:"
    for c in "${FAILED_CHECKS[@]}"; do printf '[farm_gate]   x %s\n' "$c" >&2; done
    say "Refusing to launch a farm build. Fix the above and re-run 'make farm_gate'."
    # Even on RED, leave a provenance record of WHAT tree this RED was on.
    say "provenance: $PROV_JSON  (commit ${GIT_SHA}${GIT_DIRTY})"
    hr
    exit 1
fi

# Success token — SHA-stamped so build_farm.sh can prove the gate ran on THIS
# tree state (a dirty/newer tree invalidates it).
if [ -n "${FARM_GATE_STAMP:-}" ]; then
    printf 'farm_gate PASS %s%s %s marker=%s advisories=%d\n' \
        "$GIT_SHA" "$GIT_DIRTY" "$STAMP" "${marker:-?}" "${#ADVISORIES[@]}" >"$FARM_GATE_STAMP"
    say "wrote pass token: $FARM_GATE_STAMP"
fi
say "GATE GREEN — all blocking checks passed on ${GIT_SHA}${GIT_DIRTY}. Safe to launch farm build."
say "provenance: $PROV_JSON"
hr
exit 0
