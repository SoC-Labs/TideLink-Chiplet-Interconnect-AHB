#!/bin/bash
# =============================================================================
# eye_margin.sh — per-lane EYE MARGIN via the calibrator's own sweep result.
#
# THE CORRECT eye instrument (supersedes the tap-sweep in lane_health_preflight,
# which read 0x1AC — that register HARD-STALLS the PS thread, board-proven
# 2026-07-10). This reads the calibrator's per-lane eye-width register, which the
# calibrator populates during its OWN sweep at bring-up. No host tap sweep, no
# winscan-owned register, no 0x1AC/0x1B0/0x1B4.
#
# Registers (all SAFE — Region 10 / control, none winscan-owned):
#   0x4403_2154 [2:0]  EYE_LANE_SEL (RW)  — select the lane to report
#   0x4403_2150        EYE_WIDTH (RO):
#       [ 5: 0] best_run  = matched-window WIDTH in IDELAY/phase taps (0..16)
#       [ 9: 6] best_run_start_phase
#       [12:10] best_run_slip
#       [13]    lane_passed (best_run >= LOCK_THRESH)
#       [31:24] 0xE7 presence marker (V1/old images read 0 here)
#
# THE MEASUREMENT this settles: the autonomy blocker is a SYNC-coverage lottery on
# MARGINAL lanes (no lane is dead). This splits the two marginal sub-cases:
#   best_run WIDE (>= LOCK_THRESH, lane_passed=1) yet the lane still FAILOPENs its
#       sticky sync_seen -> the eye is fine; the failure is the confirm/accumulation
#       FSM -> a LOGIC lever (widen window / relax confirm) is right.
#   best_run NARROW/low -> genuinely marginal physical eye -> an SI lever
#       (per-lane IDELAY tap, div-2) is right; a logic lever won't fix it.
#
# USAGE: TD_DEPLOY_DIR=/tmp/td_iter5 ./eye_margin.sh   (acquires+releases its lease)
#        NO_LEASE=1 ... to reuse a held lease. TD_SKIP_DEPLOY=1 to skip the reflash.
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"

R_EYE=0x44032150
R_EYE_SEL=0x44032154
LANES="2 5 6 7"
LOCK_THRESH=${LOCK_THRESH:-8}    # best_run >= this => healthy (matches lane_passed gate)

boards_up || { echo "ABORT: a board unreachable"; exit 3; }
if [ "${NO_LEASE:-0}" != 1 ]; then
  lease_acquire 900 || { echo "ABORT: no lease"; exit 3; }
  trap 'lease_release' EXIT
fi

if [ "${TD_SKIP_DEPLOY:-0}" != 1 ]; then
  echo "== deploy + bring-up (rcp locks the calibrator) =="
  deploy_pair; sleep 2
fi
rcp
echo "  waiting for the calibrator eye to populate (marker 0xE7)..."
for i in $(seq 1 40); do
  mk=$(( ( $(a rd $R_EYE) >> 24 ) & 0xff ))
  [ "$mk" -eq $(( 0xE7 )) ] && break
  sleep 0.5
done

read_eye(){ # $1=die $2=lane -> "best_run lane_passed marker"
  local d="$1" L="$2" v
  "$d" wr $R_EYE_SEL "$L" >/dev/null; sleep 0.02
  v=$(( $("$d" rd $R_EYE) ))
  echo "$(( v & 0x3f )) $(( (v>>13)&1 )) $(( (v>>24)&0xff ))"
}
classify(){ # best_run lane_passed -> DEAD|MARGINAL|HEALTHY
  local br=$1 lp=$2
  if [ "$br" -eq 0 ]; then echo DEAD
  elif [ "$lp" -eq 1 ] || [ "$br" -ge "$LOCK_THRESH" ]; then echo HEALTHY
  else echo MARGINAL; fi
}

echo
echo "== per-lane EYE MARGIN (best_run 0..16; LOCK_THRESH=$LOCK_THRESH) =="
worst=99; any_marginal=0
for d in a b; do
  printf "  die_%s:\n" "$d"
  for L in $LANES; do
    read br lp mk < <(read_eye "$d" "$L")
    if [ "$mk" -ne $(( 0xE7 )) ]; then
      printf "    lane %s: EYE MARKER 0x%02x != 0xE7 -> stale IP or no cal; result void\n" "$L" "$mk"
      continue
    fi
    v=$(classify "$br" "$lp")
    printf "    lane %s: best_run=%-2d/16  lane_passed=%d  -> %s\n" "$L" "$br" "$lp" "$v"
    [ "$br" -lt "$worst" ] && worst=$br
    [ "$v" = MARGINAL ] && any_marginal=1
  done
done

echo
echo "== VERDICT =="
if [ "$worst" -eq 99 ]; then
  echo "  no valid eye data (calibrator never converged / stale IP)."
elif [ "$worst" -eq 0 ]; then
  echo "  a lane has ZERO eye -> genuinely DEAD lane. Physical only (IDELAY/div-2/reduced-lane)."
elif [ "$any_marginal" -eq 1 ]; then
  echo "  narrowest eye best_run=$worst (< LOCK_THRESH=$LOCK_THRESH) -> MARGINAL physical eye."
  echo "  => the SYNC-coverage lottery is eye-limited: an SI lever (per-lane IDELAY, div-2)"
  echo "     is the primary lever; a logic window-widen helps only at the margin."
else
  echo "  every lane best_run >= LOCK_THRESH (worst=$worst) -> eyes are HEALTHY."
  echo "  => the FAILOPEN is NOT eye-limited; it is the confirm/accumulation FSM."
  echo "     => the LOGIC lever (widen accumulation window / relax SYNC_CONFIRM) is correct."
fi
