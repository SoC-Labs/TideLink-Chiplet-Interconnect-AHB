#!/usr/bin/env bash
#=============================================================================
# td_bilateral_regression.sh — one-command bilateral V1 data regression gate.
#
# Wraps td_v1_b2a_proof.sh to reproduce + check the CURRENT silicon state:
#   * B->A delivery is RELIABLE
#   * A->B delivery is a ~13% WINDOW LOTTERY (die_b RX free-runs its word boundary)
# Programs both dies, runs B->A (expect reliable PASS), samples A->B N times,
# and prints a clear BILATERAL OK / REGRESSED verdict with an exit code.
# Self-cleans the fpgahub lease on ANY exit (EXIT trap).
#
# RUN ON mapstone-dev. Needs td_v1_b2a_proof.sh staged (default /tmp).
#
# BASELINE = tag v1-silicon-bilateral-2026-06-23 (branch fix/die-b-pad-clk-rx-bufg;
#            new die_b .bit md5=314bc0e6; die_a = the v1-silicon-baseline image):
#   B->A reliable (>=1 PASS in BTOA_TRIES);  A->B ~13% (~2/15 PASS).
# Regression triggers:
#   * B->A 0 PASS  -> B->A broke (was reliable; e.g. a die_b TX / die_a RX regression)
#   * A->B 0 PASS  -> A->B data wall returned (die_b RX clock/eye regressed)
# After the word-window fix lands, A->B should approach ~100% -> set
#   ATOB_MIN=12 ATOB_RUNS=15 to gate on RELIABILITY, not just deliverability.
#
# Why N=15 for A->B: at a ~13% rate you need ~15+ samples to reliably see >=1 PASS;
# a single --dir AtoB run is NOT a valid A->B regression signal.
#
# Usage:   ./td_bilateral_regression.sh [--no-program]
# Env:     PROOF(=/tmp/td_v1_b2a_proof.sh) ATOB_RUNS(15) ROLLS(15)
#          ATOB_MIN(1) BTOA_TRIES(2)
#=============================================================================
set -u
PROOF="${PROOF:-/tmp/td_v1_b2a_proof.sh}"
ATOB_RUNS="${ATOB_RUNS:-15}"; ROLLS="${ROLLS:-15}"
ATOB_MIN="${ATOB_MIN:-1}";    BTOA_TRIES="${BTOA_TRIES:-2}"
DO_PROGRAM=1; [ "${1:-}" = "--no-program" ] && DO_PROGRAM=0

log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
[ -x "$PROOF" ] || { echo "FATAL: $PROOF not found/executable — stage td_v1_b2a_proof.sh first"; exit 2; }
trap '"$PROOF" --release >/dev/null 2>&1 || true' EXIT   # always free the lease

echo "=================================================================="
echo " TideLink V1 BILATERAL regression gate   $(date)"
echo "   baseline: B->A reliable; A->B ~13% window lottery (tag v1-silicon-bilateral-2026-06-23)"
echo "   A->B sample=$ATOB_RUNS  rolls<=$ROLLS  gate: B->A>=1, A->B>=$ATOB_MIN"
echo "=================================================================="

# ---- B->A gate (the first --program run programs both dies + leases) ----
log "B->A gate (expect reliable PASS) ..."
btoa=0
for t in $(seq 1 "$BTOA_TRIES"); do
  if [ "$t" = 1 ] && [ "$DO_PROGRAM" = 1 ]; then
    o=$("$PROOF" --program --dir BtoA --rolls "$ROLLS" 2>&1)   # program + lease + B->A
  else
    o=$("$PROOF" --dir BtoA --rolls "$ROLLS" 2>&1)
  fi
  if echo "$o" | grep -qE '^RESULT: PASS'; then btoa=$((btoa+1)); log "  B->A try $t: PASS"; break; else log "  B->A try $t: fail"; fi
done

# ---- A->B sample (window lottery; expect ~13%) ----
log "A->B sample ($ATOB_RUNS attempts) ..."
atob=0
for r in $(seq 1 "$ATOB_RUNS"); do
  o=$("$PROOF" --dir AtoB --rolls "$ROLLS" 2>&1)
  if echo "$o" | grep -qE '^RESULT: PASS'; then
    atob=$((atob+1)); w=$(echo "$o" | grep -oE 'byte-exact: 0x[0-9A-Fa-f]+' | head -1)
    log "  A->B run $r: PASS ($w)"
  fi
done

# ---- verdict (lease freed by the EXIT trap) ----
pct=$(awk "BEGIN{printf \"%.0f\",($atob/$ATOB_RUNS)*100}")
echo "=================================================================="
echo " B->A: $btoa/$BTOA_TRIES PASS    A->B: $atob/$ATOB_RUNS PASS (~${pct}%)"
rc=0
if   [ "$btoa" -lt 1 ];           then echo " RESULT: REGRESSED — B->A broken (was reliable)"; rc=1
elif [ "$atob" -lt "$ATOB_MIN" ]; then echo " RESULT: REGRESSED — A->B $atob/$ATOB_RUNS below gate $ATOB_MIN (data wall returned?)"; rc=1
else echo " RESULT: BILATERAL OK — B->A reliable + A->B delivers (${pct}% vs ~13% baseline)"; fi
echo "=================================================================="
exit $rc
