#!/usr/bin/env bash
#=============================================================================
# td_bilateral_regression.sh  —  V1 TideLink silicon BILATERAL regression gate
#   for the bridge1 PYNQ-Z2 pair (z2_02 die_a/master <-> z2_01 die_b/slave).
#   RTL baseline: v1-silicon-bilateral-2026-06-23 (commit 142a7ca).
#
# RUN ON mapstone-dev (needs fpgahub + routes to the board PS-mgmt network,
# logged in as the user whose key/sshpass reaches the boards — david).
#
# This is the single PASS/FAIL gate the regression-flow CI deploy_test stage
# (and the `make regression` manual fallback) invoke. It composes the
# per-direction primitive `td_v1_b2a_proof.sh`:
#
#   1. (optional, $PROOF=program)  PROGRAM both dies once via
#      td_v1_b2a_proof.sh --program (fpgahub pair up, overlay-load each
#      bitstream, stage the matching .bin for fast re-POR rolls, and CAPTURE
#      a releasable lease token). The bitstreams default to the staged
#      ~/td_v1_deploy/{tidelink.bit,tidelink-flip.bit} (BIT_A / BIT_B).
#
#   2. B->A GATE (must PASS).  The proven-good direction. We re-run the B->A
#      proof up to $BTOA_TRIES times (each is its own marginal-eye roll
#      campaign of $ROLLS re-PORs); the first PASS satisfies the gate. If
#      every try fails, the link itself has REGRESSED -> hard FAIL.
#
#   3. A->B LOTTERY SAMPLE.  On the current baseline die_b flip build, A->B
#      is a ~13% marginal-RX lottery (LUT-driven pad_clk_rx). We run the A->B
#      proof $ATOB_RUNS times and require at least $ATOB_MIN passes:
#        * ATOB_MIN=1 (default) on the CURRENT baseline — proves A->B is not
#          fully dead (catches a *total* A->B regression) without demanding
#          the unfixed eye behave deterministically.
#        * Raise ATOB_MIN to ~12 (of 15) AFTER the die_b flip-XDC BUFG /
#          word-window fix lands, when A->B should be reliable, so a
#          *reliability* regression reddens the gate. See docs/CI_REGRESSION.md.
#
# Verdict:  BILATERAL OK   iff (B->A gate PASS) AND (A->B passes >= ATOB_MIN).
#           BILATERAL REGRESSED otherwise.
#
# Exit 0 ONLY on BILATERAL OK. The fresh-random payload in td_v1_b2a_proof.sh
# means a PASS can never be a stale-FIFO artefact.
#
# Lease safety: this gate ALWAYS releases the fpgahub pair lease on exit
# (success, failure, or signal) via td_v1_b2a_proof.sh --release in an EXIT
# trap — so a CI job that dies mid-run cannot leak the shared boards.
#
# Usage:
#   ./td_bilateral_regression.sh                 # boards already programmed
#   PROOF=program ./td_bilateral_regression.sh   # program both dies first
#   ATOB_MIN=12 ./td_bilateral_regression.sh     # post-fix reliability gate
#
# Env overrides (defaults in brackets):
#   PROOF        [link]   "program" => program both dies first; else assume
#                         the pair is already programmed + lease held.
#   ATOB_RUNS    [15]     number of A->B lottery samples.
#   ATOB_MIN     [1]      min A->B passes required (=1 baseline, ~12 post-fix).
#   ROLLS        [15]     per-direction re-POR rolls handed to the proof
#                         (--rolls): the marginal-eye lottery budget.
#   BTOA_TRIES   [2]      how many times to retry the B->A gate before FAIL.
#   RELEASE      [1]      1 => release the pair lease on exit; 0 => leave held
#                         (e.g. for an interactive follow-up). CI keeps =1.
#   JUNIT_OUT    [unset]  if set, write a JUnit XML summary to this path.
#   (passed through to td_v1_b2a_proof.sh: PAIR, A_IP, B_IP, A_NAME, B_NAME,
#    BIT_A, BIT_B, TIDELINK_BOARD_PASS, FPGAHUB, TX_BASE, RX_BASE, DWELL)
#=============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_SH="$SCRIPT_DIR/td_v1_b2a_proof.sh"

# ---- config (env-overridable) ----------------------------------------------
PROOF="${PROOF:-link}"          # "program" | "link"
ATOB_RUNS="${ATOB_RUNS:-15}"
ATOB_MIN="${ATOB_MIN:-1}"
ROLLS="${ROLLS:-15}"
BTOA_TRIES="${BTOA_TRIES:-2}"
RELEASE="${RELEASE:-1}"
PAIR="${PAIR:-bridge1}"
FPGAHUB="${FPGAHUB:-/opt/fpgahub/bin/fpgahub}"
JUNIT_OUT="${JUNIT_OUT:-}"

ts(){ date '+%H:%M:%S'; }
log(){ printf '[bilateral %s] %s\n' "$(ts)" "$*"; }
hr(){  printf '==================================================================\n'; }

[ -x "$PROOF_SH" ] || { echo "FATAL: $PROOF_SH not found/executable" >&2; exit 2; }

# ---- optional JUnit summary -------------------------------------------------
# Emits a 2-testcase suite (b_to_a gate + a_to_b lottery) so the CI deploy_test
# stage can surface a green/red testcase in the GitLab MR widget. No-op unless
# JUNIT_OUT is set. $1=overall PASS|FAIL, $2=atob_pass, $3=atob_runs.
write_junit(){
  [ -n "$JUNIT_OUT" ] || return 0
  local verdict="$1" ap="${2:-0}" ar="${3:-0}" fails=0 btoa_fail="" atob_fail=""
  if [ "$verdict" != "PASS" ]; then
    # Distinguish which sub-gate failed for the report.
    if [ "${btoa_pass:-0}" != 1 ]; then
      btoa_fail="<failure type=\"link_regressed\" message=\"B-&gt;A gate failed after ${BTOA_TRIES} tries\"/>"
      fails=$((fails + 1))
    fi
    if [ "$ap" -lt "$ATOB_MIN" ]; then
      atob_fail="<failure type=\"atob_regressed\" message=\"A-&gt;B ${ap}/${ar} &lt; ATOB_MIN=${ATOB_MIN}\"/>"
      fails=$((fails + 1))
    fi
  fi
  mkdir -p "$(dirname "$JUNIT_OUT")"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites name="td_bilateral_regression (pair=%s, baseline ATOB_MIN=%s)">\n' "$PAIR" "$ATOB_MIN"
    printf '  <testsuite name="tidelink.v1_silicon_bilateral" tests="2" failures="%s">\n' "$fails"
    printf '    <testcase classname="tidelink.bilateral" name="b_to_a_data_delivery_gate">%s</testcase>\n' "$btoa_fail"
    printf '    <testcase classname="tidelink.bilateral" name="a_to_b_lottery_min%s_of%s">%s' "$ATOB_MIN" "$ar" "$atob_fail"
    printf '<system-out>A-&gt;B passes: %s/%s</system-out></testcase>\n' "$ap" "$ar"
    printf '  </testsuite>\n'
    printf '</testsuites>\n'
  } > "$JUNIT_OUT"
  log "wrote JUnit summary -> $JUNIT_OUT"
}

# ---- always release the lease on exit --------------------------------------
# td_v1_b2a_proof.sh --program writes a lease token to
# ${TMPDIR:-/tmp}/td_v1_lease_${PAIR}.token; --release frees it. We mirror
# the same PAIR so the token path matches, and trap it so any exit path
# (incl. SIGTERM from a CI runner preempt) frees the shared boards.
release_lease(){
  [ "$RELEASE" = 1 ] || { log "RELEASE=0 — leaving $PAIR lease held"; return 0; }
  log "releasing $PAIR lease (PROOF=$PROOF)"
  PAIR="$PAIR" FPGAHUB="$FPGAHUB" "$PROOF_SH" --release >/dev/null 2>&1 || true
}
trap release_lease EXIT INT TERM

hr
log "V1 BILATERAL regression gate — pair=$PAIR"
log "  PROOF=$PROOF  B->A tries=$BTOA_TRIES  A->B runs=$ATOB_RUNS (need >=$ATOB_MIN)  rolls=$ROLLS"
hr

# ---- step 1: program (optional) + B->A gate --------------------------------
# The FIRST B->A try carries the --program (so we program exactly once); any
# retry re-rolls against the already-programmed/leased pair.
btoa_pass=0
btoa_rc=1
for try in $(seq 1 "$BTOA_TRIES"); do
  args=(--dir BtoA --rolls "$ROLLS")
  if [ "$PROOF" = "program" ] && [ "$try" = 1 ]; then
    args=(--program "${args[@]}")
    log "B->A try $try/$BTOA_TRIES (with --program: load both dies + capture lease)"
  else
    log "B->A try $try/$BTOA_TRIES"
  fi
  # Never let the proof self-release between steps — this gate owns the lease
  # lifecycle (we release once, at the very end, via the trap above).
  if RELEASE=0 "$PROOF_SH" "${args[@]}"; then
    btoa_pass=1; btoa_rc=0
    log "B->A GATE PASS on try $try"
    break
  else
    btoa_rc=$?
    log "B->A try $try FAILED (rc=$btoa_rc)"
  fi
done

if [ "$btoa_pass" != 1 ]; then
  hr
  log "RESULT: BILATERAL REGRESSED — B->A gate FAILED after $BTOA_TRIES tries"
  log "  B->A is the proven-good path; its failure means the LINK regressed"
  log "  (eye/credit/ribbon/build), not just the A->B marginal-RX lottery."
  hr
  write_junit "FAIL" 0 0
  exit 1
fi

# ---- step 2: A->B lottery sample -------------------------------------------
# A->B on the baseline die_b flip build is a ~13% marginal-RX lottery. Sample
# it ATOB_RUNS times; PASS the sub-gate iff >= ATOB_MIN land. Each run is its
# own roll campaign, so we DON'T --program here (pair already up + leased).
atob_pass=0
for run in $(seq 1 "$ATOB_RUNS"); do
  if RELEASE=0 "$PROOF_SH" --dir AtoB --rolls "$ROLLS"; then
    atob_pass=$((atob_pass + 1))
    log "A->B sample $run/$ATOB_RUNS: PASS   (cumulative $atob_pass/$run)"
  else
    log "A->B sample $run/$ATOB_RUNS: fail   (cumulative $atob_pass/$run)"
  fi
done
atob_rate=$(awk "BEGIN{ if($ATOB_RUNS>0) printf \"%.0f\", 100*$atob_pass/$ATOB_RUNS; else print 0 }")
log "A->B lottery: $atob_pass/$ATOB_RUNS PASS (~${atob_rate}%), need >= $ATOB_MIN"

# ---- verdict ----------------------------------------------------------------
hr
if [ "$atob_pass" -ge "$ATOB_MIN" ]; then
  log "RESULT: BILATERAL OK"
  log "  B->A gate: PASS"
  log "  A->B:      $atob_pass/$ATOB_RUNS (>= $ATOB_MIN required)"
  hr
  write_junit "PASS" "$atob_pass" "$ATOB_RUNS"
  exit 0
else
  log "RESULT: BILATERAL REGRESSED"
  log "  B->A gate: PASS"
  log "  A->B:      $atob_pass/$ATOB_RUNS  (< $ATOB_MIN required) — A->B REGRESSED"
  if [ "$ATOB_MIN" -le 1 ]; then
    log "  At ATOB_MIN=1 this means A->B is TOTALLY dead — investigate die_b RX,"
    log "  the flip build, and the ribbon before raising ATOB_MIN."
  fi
  hr
  write_junit "FAIL" "$atob_pass" "$ATOB_RUNS"
  exit 1
fi
