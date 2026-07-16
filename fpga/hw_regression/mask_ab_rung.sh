#!/bin/bash
# =============================================================================
# mask_ab_rung.sh — 0xE4 vs 0x65 head-to-head at ONE link rate
#
# THE EXPERIMENT (priority: above climbing to the next rate):
#   0xE4 = lanes {2,5,6,7}  — today's golden mask
#   0x65 = lanes {0,2,5,6}  — same lane COUNT (4, so it dodges the measured
#                             odd-lane-count no-data defect, and bytesPerCycle
#                             is unchanged so framing/throughput are identical),
#                             but built from the healthiest lanes: it DROPS
#                             lane 7 and picks up lane 0 (measured bit-exact,
#                             matched at tol=0).
#   Question: does 0x65 carry byte-exact data BOTH directions, and does it
#   survive a HIGHER rate than 0xE4?
#
# Runs, for each mask: deploy -> rcp(mask) -> wait bilateral -> record
# livematch/anchor/fcsm -> enter_data_mode -> byte-exact txburst BOTH directions.
#
# HONESTY NOTE ON THE RATIONALE: the usual justification for dropping lane 7 is
# its "measured 7.05 ns capture-clock skew". This ladder's own static
# measurement does NOT reproduce that (routed pynq-z2-pair-all + -flip-all,
# 2026-07-14 DCPs): lane 7 arrives 8.225 ns (die_a) / 8.256 ns (die_b) and is
# among the FASTEST lanes; the late lanes are 1/3 on die_a and 0/4 on die_b, and
# the victim MOVES between builds. So 0x65 should be judged on what it DELIVERS
# here, not on the skew story. If 0x65 wins, the reason is more likely lane 0
# being bit-exact than lane 7 being skewed.
#
# Usage: TD_DEPLOY_DIR=<stage> ./mask_ab_rung.sh --rate-label "6.25MHz"
#        Assumes the lease is held.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

RATE_LABEL="${RATE_LABEL:-unknown-rate}"
while [ $# -gt 0 ]; do case "$1" in
  --rate-label) RATE_LABEL="$2"; shift;;
  *) echo "unknown arg: $1"; exit 2;;
esac; shift; done

run_mask(){ # $1=label $2=lanemask32 $3=synctol $4=lanes-desc
  local label="$1" lm="$2" st="$3" desc="$4"
  echo
  echo "############################################################"
  echo "# MASK $label ($desc)   rate=$RATE_LABEL   $(date -u +%H:%M:%SZ)"
  echo "############################################################"
  (
    export TD_LANEMASK32="$lm" TD_SYNCTOL="$st"
    # shellcheck disable=SC1091
    . "$HERE/td_v2_hwlib.sh"

    deploy_pair
    sleep 1
    rcp
    if wait_bilateral 4 14; then echo "[$label] bilateral fcsm=4 OK"
    else echo "[$label] RESULT: NO BILATERAL LINK at $RATE_LABEL (fcsm_a=$(fcsm a) fcsm_b=$(fcsm b))"; exit 3; fi

    # read back what actually landed — never trust the write
    for d in a b; do
      v=$( [ $d = a ] && a rd $R_LANEMASK || b rd $R_LANEMASK ); sleep "$TD_THROTTLE"
      printf "[%s] die_%s lanemask readback=0x%08x (wanted %s)\n" "$label" "$d" $((v)) "$lm"
    done
    printf "[%s] livematch_a=0x%02x livematch_b=0x%02x reanchored=%s fcsm_a=%s fcsm_b=%s\n" \
      "$label" $(( $(a rd 0x44032144)&0xff )) $(( $(b rd 0x44032144)&0xff )) \
      "$(reanchored)" "$(fcsm a)" "$(fcsm b)"

    enter_data_mode
    sleep 0.5
    echo "[$label] --- byte-exact data both directions ---"
    "$HERE/td_v2_channels.sh" --mode manual --channels data 2>&1 | sed "s/^/[$label] /"
    rc=${PIPESTATUS[0]}
    echo "[$label] channels rc=$rc"
    exit $rc
  )
  local rc=$?
  echo "[$label] MASK_RESULT rate=$RATE_LABEL mask=$label rc=$rc"
  return $rc
}

echo "==================== MASK A/B @ $RATE_LABEL ===================="
run_mask "0xE4" 0x0000e4e4 0x000005e4 "lanes 2,5,6,7 - golden"; RC_E4=$?
run_mask "0x65" 0x00006565 0x00000565 "lanes 0,2,5,6 - drops lane7, adds lane0"; RC_65=$?

echo
echo "==================== SUMMARY @ $RATE_LABEL ===================="
printf "  0xE4 {2,5,6,7} : rc=%s %s\n" "$RC_E4" "$([ $RC_E4 = 0 ] && echo 'byte-exact BOTH directions' || echo 'FAILED')"
printf "  0x65 {0,2,5,6} : rc=%s %s\n" "$RC_65" "$([ $RC_65 = 0 ] && echo 'byte-exact BOTH directions' || echo 'FAILED')"
echo "MASK_AB_DONE rate=$RATE_LABEL e4=$RC_E4 x65=$RC_65"
