#!/bin/bash
# =============================================================================
# rate_lane_census.sh — per-lane health on BOTH dies at the CURRENT link rate
#
# One rung of the rate ladder. For the bitstream currently on the boards:
#   (1) which of the 8 lanes are ALIVE at this rate, on die_a RX and die_b RX?
#   (2) are lanes 0/1/3/4 — masked out by LANE_MASK_RESET=8'hE4 on the claim
#       that they are "dead silicon" — actually dead, or merely masked?
#
# TWO INSTRUMENT TRAPS THIS SCRIPT EXISTS TO AVOID. Both were VERIFIED in RTL in
# this tree, and either one alone silently fakes the answer:
#
#  [T1] V2 MASKS SYNC *BEFORE* THE PADS. The TX chain is
#         tx_link_data_sync_w -> u_tx_segmenter -> u_tx_mask(io_link_tx_tx_lane_mask)
#       (WavD2DGpio_v2.v, u_tx_mask). SYNC is inserted BEFORE the lane mask, so a
#       masked-out lane transmits 0x0000 EVEN DURING SYNC. Probing lane health
#       with the golden mask 0xE4E4 in place therefore reports lanes 0/1/3/4 dark
#       REGARDLESS OF THEIR HEALTH — you measure your own mask, not the silicon.
#       => we set the LANE mask 0x44030214 = 0x0000FFFF while probing, and read it
#          back at measure time to prove it applied.
#
#  [T2] STICKY sync_seen (0x4403215C) IS STRUCTURALLY BLIND TO LANE 0. Lane 0's
#       SYNC slice 0x1F00 has popcount 5, and SYNC_REANCHOR_TOL=5, so the all-zero
#       IDLE word is a within-tolerance "match" on lane 0 -> continuous match ->
#       `periodic` never asserts -> lane 0 can NEVER commit sticky sync_seen
#       (documented at tidelink_lane_deskew_v2.sv:8-22). Using sync_seen as the
#       health signal reports lane 0 dead when it is bit-exact.
#       => LIVEMATCH (0x44032144, per-lane currently-matching) is the PRIMARY
#          signal. sync_seen is recorded as SECONDARY/context only.
#
# SAFETY:
#   * NEVER touches 0x440321AC / 0x440321B0 / 0x440321B4 — those SIGBUS-wedge the
#     PS. This is a pure observation census; it needs no IDELAY winscan/dist path.
#   * All reads throttled >= TD_THROTTLE (0.25s default).
#   * Restores the golden lane mask 0xE4E4 + SYNC mask 0xE4 on exit, so the pair
#     is left in the golden config for the next user.
#
# Usage:  ./rate_lane_census.sh --rate-label "6.25MHz"
#         Assumes the lease is held and the pair is deployed + rcp'd + bilateral.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/td_v2_hwlib.sh"

RATE_LABEL="${RATE_LABEL:-unknown-rate}"
while [ $# -gt 0 ]; do case "$1" in
  --rate-label) RATE_LABEL="$2"; shift;;
  *) echo "unknown arg: $1"; exit 2;;
esac; shift; done

R_LIVEMATCH=0x44032144        # [7:0] per-lane currently-matching  <-- PRIMARY (T2)
MASK32_ALL=0x0000ffff         # lane mask: ALL 8 lanes TX+RX (probe only, see T1)
MASK32_GOLD=0x0000e4e4        # golden lane mask (restore)
SYNCTOL_ALL=0x000005ff        # tol=5 ([12:8]), SYNC-detect mask 0xFF ([7:0])
SYNCTOL_GOLD=0x000005e4       # tol=5, SYNC-detect mask 0xE4 (restore)
ACTIVE_LANES="2 5 6 7"        # LANE_MASK_RESET=0xE4
MASKED_LANES="0 1 3 4"        # the "dead silicon" claim under test

rd_die(){ case "$1" in a) a rd "$2";; b) b rd "$2";; esac; sleep "$TD_THROTTLE"; }
wr_die(){ case "$1" in a) a wr "$2" "$3" >/dev/null;; b) b wr "$2" "$3" >/dev/null;; esac; }

restore(){
  echo "[census] restoring golden lane mask 0xE4E4 + SYNC mask 0xE4"
  wr_die a "$R_LANEMASK" "$MASK32_GOLD"; wr_die b "$R_LANEMASK" "$MASK32_GOLD"
  wr_die a "$R_SYNCTOL"  "$SYNCTOL_GOLD"; wr_die b "$R_SYNCTOL" "$SYNCTOL_GOLD"
  wr_die a "$R_R8" 0x1D;                  wr_die b "$R_R8" 0x1D
}
trap restore EXIT

bits(){ local v=$1 L out=""; for L in 0 1 2 3 4 5 6 7; do out="$out $L:$(( (v>>L)&1 ))"; done; echo "$out"; }

echo "============================================================"
echo " RATE-LADDER LANE CENSUS   rate=$RATE_LABEL   $(date -u +%H:%M:%SZ)"
echo "============================================================"
printf "[link] fcsm_a=%s fcsm_b=%s reanchored=%s\n" "$(fcsm a)" "$(fcsm b)" "$(reanchored)"

# --- 1. open BOTH the lane mask (T1) and the SYNC-detect mask ---------------
echo "[census] opening LANE mask 0x214 -> 0x0000FFFF (T1: else masked lanes TX 0x0000)"
wr_die a "$R_LANEMASK" "$MASK32_ALL"; wr_die b "$R_LANEMASK" "$MASK32_ALL"
echo "[census] opening SYNC-detect mask 0x2128 -> 0xFF (tol=5)"
wr_die a "$R_SYNCTOL" "$SYNCTOL_ALL"; wr_die b "$R_SYNCTOL" "$SYNCTOL_ALL"

# --- 2. flood SYNC on both dies so every lane has a beacon to see -----------
echo "[census] flooding SYNC (R8=0x1C) on BOTH dies"
wr_die a "$R_R8" 0x1C; wr_die b "$R_R8" 0x1C
sleep 1.0
for d in a b; do wr_die $d "$R_R8" 0x3C; wr_die $d "$R_R8" 0x1C; done   # obs_clr pulse
sleep 1.5

# --- 3. PROVE the probe config actually applied at measure time -------------
echo "[census] read-back at measure time (proves the probe config landed):"
bad=0
for d in a b; do
  lm=$(( $(rd_die $d $R_LANEMASK) )); st=$(( $(rd_die $d $R_SYNCTOL) )); r8=$(( $(rd_die $d $R_R8) ))
  printf "  [cfg] die_%s lanemask=0x%08x sync_mask=0x%02x tol=%d R8=0x%02x\n" \
         "$d" "$lm" $(( st & 0xff )) $(( (st>>8)&0x1f )) "$r8"
  [ "$lm" -ne $((MASK32_ALL)) ] && { echo "  ABORT: die_$d lane mask did NOT take (T1) — census would be meaningless"; bad=1; }
  [ $(( st & 0xff )) -ne 255 ] && { echo "  ABORT: die_$d SYNC mask did NOT take"; bad=1; }
  [ $(( r8 & 0x0c )) -ne 12 ]  && { echo "  ABORT: die_$d R8=0x$(printf %02x $r8) — SYNC flood not active"; bad=1; }
done
[ "$bad" = 0 ] || { echo "CENSUS_ABORT rate=$RATE_LABEL"; exit 1; }

# --- 4. read the per-lane census on BOTH dies -------------------------------
declare -A LIVE SEEN
for d in a b; do
  LIVE[$d]=$(( $(rd_die $d $R_LIVEMATCH) & 0xff ))   # PRIMARY (T2)
  SEEN[$d]=$(( $(rd_die $d $R_SYNCSEEN)  & 0xff ))   # SECONDARY (lane-0 blind)
done

echo
echo "---------------- RESULT: rate=$RATE_LABEL ----------------"
for d in a b; do
  printf "die_%s RX  livematch=0x%02x  (sync_seen=0x%02x, lane-0 blind - context only)\n" \
         "$d" "${LIVE[$d]}" "${SEEN[$d]}"
  printf "          per-lane ALIVE:%s\n" "$(bits ${LIVE[$d]})"
done

# --- 5. verdicts (all keyed off LIVEMATCH) ----------------------------------
echo
for d in a b; do
  miss=""; for L in $ACTIVE_LANES; do [ $(( (${LIVE[$d]}>>L)&1 )) -eq 0 ] && miss="$miss $L"; done
  if [ -z "$miss" ]; then echo "[verdict] die_$d: all ACTIVE lanes {${ACTIVE_LANES// /,}} alive at $RATE_LABEL"
  else echo "[verdict] die_$d: ACTIVE lane(s)$miss NOT alive at $RATE_LABEL  <-- rate margin exceeded"; fi
done
for d in a b; do
  alive=""; for L in $MASKED_LANES; do [ $(( (${LIVE[$d]}>>L)&1 )) -eq 1 ] && alive="$alive $L"; done
  if [ -n "$alive" ]; then echo "[dead-lane] die_$d: masked lane(s)$alive ARE ALIVE at $RATE_LABEL => NOT dead silicon"
  else echo "[dead-lane] die_$d: no masked lane {${MASKED_LANES// /,}} alive at $RATE_LABEL (consistent with dead conductor)"; fi
done
echo "CENSUS_DONE rate=$RATE_LABEL live_a=0x$(printf %02x ${LIVE[a]}) live_b=0x$(printf %02x ${LIVE[b]})"
