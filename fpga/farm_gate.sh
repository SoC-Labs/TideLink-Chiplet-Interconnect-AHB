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
###   * dropped-XDC          — a constraint silently not applied (xdc_lint).
###   * comb-loop / latch     — an anti-pattern the idealised sim never exercised
###                            (sv_anti_pattern_lint + the SILICON-config sim).
###   * anchor / eye margin   — deskew / marginal-eye behaviour only visible at
###                            the silicon epoch fingerprint (EPOCH_PROFILE=silicon
###                            + EYE_FAULT + reduced-lane + the bridge BFM).
###
### This gate runs those checks and MUST pass before any farm build launches. It
### is the single highest-value piece of the verif-infra hardening: it moves the
### campaign's dominant failure classes to build time.
###
### TIERS
###   Tier-0 STATIC (seconds, no EDA license) — always runs:
###       * xdc_lint            fpga/targets/*.xdc anti-pattern lint.
###       * sv_anti_pattern      first-party RTL latch/incomplete-case lint,
###                             RATCHETED against fpga/farm_gate_sv_baseline.txt
###                             (green today, fails on any NEW finding).
###   Tier-1 SIM (minutes, needs VCS + cocotb) — runs unless FARM_GATE_FAST=1:
###       * the V2 pair sim at the SILICON epoch fingerprint + reduced-lane +
###         marginal-eye (EYE_FAULT) + the XHB bridge BFM. These are the configs
###         that expose the silicon-only classes the idealised default never did.
###
### EXIT: 0 = GREEN (safe to launch farm build). Non-zero = RED (refuse to build).
###
### ENV
###   FARM_GATE_FAST=1            Tier-0 only (dev pre-flight; NOT a build gate).
###   FARM_GATE_ALLOW_NO_SIM=1    Downgrade "VCS/cocotb absent" from FAIL to WARN
###                              (e.g. a lint-only CI runner). Off by default so a
###                              build host silently missing the sim can't slip.
###   FARM_GATE_SIM_STAGES="a b"  Override the sim-stage list (names below).
###   FARM_GATE_STAMP=<path>      Write a SHA-stamped pass token here on success
###                              (build_farm.sh consumes it as proof-of-gate).
###-----------------------------------------------------------------------------
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="${TIDELINK_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$TIDELINK_HOME"

LINT_DIR="cocotb/lint"
PAIR_DIR="cocotb/tidelink_top_pair_v2"
SV_BASELINE="fpga/farm_gate_sv_baseline.txt"
XDC_BASELINE="fpga/farm_gate_xdc_baseline.txt"
LOG_DIR="imp/fpga/run/farm_gate"
mkdir -p "$LOG_DIR"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)}"

RED=0            # accumulates failures; non-zero -> gate RED
declare -a FAILED_CHECKS=()

hr()   { printf '%s\n' "=============================================================="; }
say()  { printf '[farm_gate] %s\n' "$*"; }
fail() { RED=1; FAILED_CHECKS+=("$1"); printf '[farm_gate] FAIL: %s\n' "$1" >&2; }
pass() { printf '[farm_gate] ok:   %s\n' "$1"; }

hr; say "TideLink pre-build gate — $(date 2>/dev/null || echo '')"
say "TIDELINK_HOME=$TIDELINK_HOME"
say "mode=$([ "${FARM_GATE_FAST:-0}" = 1 ] && echo FAST-lint-only || echo full-lint+sim)"
hr

# ---------------------------------------------------------------------------
# Generic RATCHET: run a lint, reduce findings to stable "path:line: CODE" keys,
# and fail ONLY on keys not already in the accepted baseline. This keeps the
# gate green on today's known/accepted debt yet red on any NEW finding.
#
#   Finding lines : <path>:<line>: <CODE> <message...>
#   Baseline lines: <path>:<line>: <CODE>            (message dropped)
# ---------------------------------------------------------------------------
extract_keys() {
    # $1 = file of raw lint/baseline text -> stdout: sorted-uniq "path:line: CODE"
    sed -nE 's#^([^:[:space:]]+:[0-9]+):[[:space:]]+([A-Z_]+).*$#\1: \2#p' "$1" \
        | sort -u
}

# ratchet_lint <label> <raw-output-log> <baseline-file>
ratchet_lint() {
    local label="$1" rawlog="$2" baseline="$3"
    local cur="$LOG_DIR/${label}_cur.$STAMP.txt"
    local base="$LOG_DIR/${label}_base.$STAMP.txt"
    extract_keys "$rawlog" >"$cur"
    if [ -f "$baseline" ]; then
        extract_keys "$baseline" >"$base"
    else
        : >"$base"
        say "WARNING: baseline $baseline absent — treating all $label findings as NEW"
    fi
    local newf gone
    newf="$(comm -23 "$cur" "$base")"
    gone="$(comm -13 "$cur" "$base")"   # in baseline, no longer found -> retire
    if [ -n "$newf" ]; then
        fail "$label — NEW finding(s) not in $baseline:"
        printf '%s\n' "$newf" | sed 's/^/[farm_gate]     + /' >&2
        say "(full $label output: $rawlog)"
    else
        pass "$label (no new findings vs baseline; $(grep -c . "$base" 2>/dev/null || echo 0) accepted)"
    fi
    if [ -n "$gone" ]; then
        say "note: $label baseline entry(ies) no longer found — retire from $baseline:"
        printf '%s\n' "$gone" | sed 's/^/[farm_gate]     - /'
    fi
}

# ---------------------------------------------------------------------------
# Tier-0.a  xdc_lint (dropped-XDC / anti-pattern constraint gate), RATCHETED
# ---------------------------------------------------------------------------
say "Tier-0.a  xdc_lint fpga/targets/ (ratcheted) ..."
XDC_LOG="$LOG_DIR/xdc_lint.$STAMP.log"
# '|| true': the tool exits 1 when findings exist; the ratchet decides pass/fail.
python3 "$LINT_DIR/xdc_lint.py" fpga/targets/ >"$XDC_LOG" 2>&1 || true
ratchet_lint "xdc_lint" "$XDC_LOG" "$XDC_BASELINE"

# ---------------------------------------------------------------------------
# Tier-0.b  sv_anti_pattern lint, RATCHETED against the accepted baseline
# ---------------------------------------------------------------------------
say "Tier-0.b  sv_anti_pattern lint (ratcheted) ..."
SV_LOG="$LOG_DIR/sv_anti_pattern.$STAMP.log"
python3 "$LINT_DIR/sv_anti_pattern_lint.py" src/rtl >"$SV_LOG" 2>&1 || true
ratchet_lint "sv_anti_pattern" "$SV_LOG" "$SV_BASELINE"

# ---------------------------------------------------------------------------
# Tier-1  SILICON-config V2 pair sim  (skipped in FAST mode)
# ---------------------------------------------------------------------------
# Stage catalogue: name -> "make var=val ... MODULE=..." .
#
# FUNCTIONAL stages verify the build is HEALTHY (bring-up + both directions +
# reduced-lane + the XHB bridge BFM) and must be green on ANY sound V2 branch —
# these are the always-on default.
#
# STRESS stages drive the SILICON epoch-skew fingerprint (v37: 3..7 words on the
# master's RX) + the marginal-eye injector. Their green-ness is PHY-pin
# dependent: the autonomous deskew (deps/tidelink-phy @ bbd094c, Loop-12..14
# anchor-verify) is expected to PASS them, whereas the older pin (9f4953c, the
# feat/dieb-clock-fix-wip base) is MARGINAL — test_v2_pair_data.test_03 (S->M)
# reproduces the v37 byte-fragmentation signature. So the stress tier is OPT-IN
# (FARM_GATE_STRESS=1); run it on the autonomous/unified lineage where it should
# be green, and treat a RED there as a real deskew regression.
declare -A SIM_STAGE=(
  [data_zero]="EPOCH_PROFILE=zero MODULE=test_v2_pair_data"
  [reduced_lane]="EPOCH_PROFILE=zero MODULE=test_v2_reduced_lane"
  [bridge_bfm]="EPOCH_PROFILE=zero MODULE=test_v2_xhb_window_bridge"
  [silicon_data]="EPOCH_PROFILE=silicon MODULE=test_v2_pair_data"
  [marginal_eye]="EPOCH_PROFILE=silicon EYE_FAULT=1 MODULE=test_v2_marginal_eye"
)
FUNCTIONAL_STAGES="data_zero reduced_lane bridge_bfm"
STRESS_STAGES="silicon_data marginal_eye"
if [ -n "${FARM_GATE_SIM_STAGES:-}" ]; then
    STAGES="$FARM_GATE_SIM_STAGES"                 # explicit override wins
elif [ "${FARM_GATE_STRESS:-0}" = 1 ]; then
    STAGES="$FUNCTIONAL_STAGES $STRESS_STAGES"     # full silicon-skew gate
else
    STAGES="$FUNCTIONAL_STAGES"                    # default: functional only
fi

run_sim_stage() {
    local name="$1" args="$2"
    local slog="$LOG_DIR/sim_${name}.$STAMP.log"
    local rxml="$PAIR_DIR/results.xml"
    say "Tier-1  sim[$name]: make -C $PAIR_DIR $args"
    rm -f "$rxml"
    local mk_rc=0
    make -C "$PAIR_DIR" $args >"$slog" 2>&1 || mk_rc=$?
    # Modern cocotb makes the sim exit non-zero on a TEST failure, so a non-zero
    # mk_rc alone can't tell a compile error from a test failure. Always consult
    # results.xml: present + testcases + no <failure>/<error> is the truth. Only
    # a missing/empty results.xml means the sim never ran (real compile error).
    if [ ! -f "$rxml" ]; then
        fail "sim[$name] — no results.xml (sim did not compile/run; make rc=$mk_rc) — see $slog"
        tail -n 25 "$slog" >&2 || true
        return
    fi
    local n_tc n_fail
    n_tc="$(grep -c '<testcase' "$rxml" 2>/dev/null || echo 0)"
    n_fail="$(grep -cE '<failure|<error' "$rxml" 2>/dev/null || echo 0)"
    if [ "$n_tc" -eq 0 ]; then
        fail "sim[$name] — results.xml has 0 testcases (harness/compile issue; make rc=$mk_rc) — see $slog"
    elif [ "$n_fail" -ne 0 ]; then
        fail "sim[$name] — $n_fail/$n_tc testcase(s) FAILED — see $slog"
        grep -E 'FAIL|corrupt|undelivered|AssertionError' "$slog" | head -4 >&2 || true
    elif [ "$mk_rc" -ne 0 ]; then
        # results say all passed but make still failed -> infra noise (e.g. a
        # non-test post-step). Surface it but don't hide a real pass.
        fail "sim[$name] — all $n_tc testcase(s) passed but make rc=$mk_rc (non-test error) — see $slog"
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
        for s in $STAGES; do
            if [ -n "${SIM_STAGE[$s]:-}" ]; then
                run_sim_stage "$s" "${SIM_STAGE[$s]}"
            else
                fail "unknown sim stage '$s' (valid: ${!SIM_STAGE[*]})"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
hr
if [ "$RED" -ne 0 ]; then
    say "GATE RED — ${#FAILED_CHECKS[@]} check(s) failed:"
    for c in "${FAILED_CHECKS[@]}"; do printf '[farm_gate]   x %s\n' "$c" >&2; done
    say "Refusing to launch a farm build. Fix the above and re-run 'make farm_gate'."
    hr
    exit 1
fi

# Success token — SHA-stamped so build_farm.sh can prove the gate ran on THIS
# tree state (a dirty/newer tree invalidates it).
GIT_SHA="$(git -C "$TIDELINK_HOME" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
[ -n "$(git -C "$TIDELINK_HOME" status --porcelain 2>/dev/null)" ] && GIT_DIRTY="-dirty"
if [ -n "${FARM_GATE_STAMP:-}" ]; then
    printf 'farm_gate PASS %s%s %s\n' "$GIT_SHA" "$GIT_DIRTY" "$STAMP" >"$FARM_GATE_STAMP"
    say "wrote pass token: $FARM_GATE_STAMP"
fi
say "GATE GREEN — all checks passed on ${GIT_SHA}${GIT_DIRTY}. Safe to launch farm build."
hr
exit 0
