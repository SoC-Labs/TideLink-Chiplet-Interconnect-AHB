#!/usr/bin/env bash
#=============================================================================
# td_wordpin_sweep.sh — commission die_b's RX word_pin (the word-window fix).
#
# Sweeps die_b word_pin 0..15, finds the window that makes A->B DELIVER, then
# confirms reliability with a long sample. REQUIRES the word_pin bitstream
# (branch fix/word-window) deployed on die_b — it wires the previously
# dead-ended word_pin APB regs into the RX. RUN ON mapstone-dev. Self-releases
# the fpgahub lease on any exit.
#
# Why a sweep: with word_pin SET, die_b's RX word boundary is DETERMINISTIC, so
# A->B delivers reliably at the ONE correct window and fails at the others
# (vs the ~13% free-run lottery without the fix). This finds + pins that window.
#
# Usage:   ./td_wordpin_sweep.sh
# Env:     PROOF(=/tmp/td_v1_b2a_proof.sh) SCAN_RUNS(2) CONFIRM_RUNS(15) ROLLS(15)
#          B_IP(192.168.2.101) TIDELINK_BOARD_PASS(xilinx)
#=============================================================================
set -u
PROOF="${PROOF:-/tmp/td_v1_b2a_proof.sh}"
B_IP="${B_IP:-192.168.2.101}"; PW="${TIDELINK_BOARD_PASS:-xilinx}"
WP=0x44032148; WP_EN=0x4403214C            # per-lane word_pin (8x4b) + enable (8b) APB regs
SCAN_RUNS="${SCAN_RUNS:-2}"; CONFIRM_RUNS="${CONFIRM_RUNS:-15}"; ROLLS="${ROLLS:-15}"
SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
# write a 32b APB reg on die_b (sudo -S handles z2_01's passworded sudo)
bwr(){ sshpass -p "$PW" ssh $SSHC xilinx@"$B_IP" "echo '$PW' | sudo -S /usr/bin/devmem2 $1 w $2 >/dev/null 2>&1"; }
setwin(){ bwr "$WP_EN" 0xFF; bwr "$WP" "$(printf '0x%08X' $(( $1 * 0x11111111 )))"; }  # all 8 lanes -> window $1
atob(){ "$PROOF" --dir AtoB --rolls "$ROLLS" 2>&1 | grep -qE '^RESULT: PASS'; }
trap '"$PROOF" --release >/dev/null 2>&1 || true' EXIT   # always free the lease

echo "=================================================================="
echo " die_b RX word_pin sweep + reliability confirm   $(date)"
echo "=================================================================="
log "program both dies + confirm B->A still works ..."
if "$PROOF" --program --dir BtoA --rolls "$ROLLS" 2>&1 | grep -qE '^RESULT: PASS'; then log "  B->A: PASS"; else log "  B->A FAILED — abort (regression?)"; exit 2; fi

log "scanning word_pin 0..15 ($SCAN_RUNS A->B runs each) ..."
best_w=-1; best=-1; scan=""
for w in $(seq 0 15); do
  setwin "$w"
  p=0; for r in $(seq 1 "$SCAN_RUNS"); do atob && p=$((p+1)); done
  printf '  word_pin=%2d : A->B %d/%d\n' "$w" "$p" "$SCAN_RUNS"; scan="$scan ${w}:${p}"
  [ "$p" -gt "$best" ] && { best=$p; best_w=$w; }
done
log "best scan window = $best_w ($best/$SCAN_RUNS)"

rc=1
echo "=================================================================="
if [ "$best" -gt 0 ]; then
  setwin "$best_w"
  log "confirming word_pin=$best_w over $CONFIRM_RUNS A->B runs ..."
  c=0; for r in $(seq 1 "$CONFIRM_RUNS"); do atob && c=$((c+1)); done
  pct=$(awk "BEGIN{printf \"%.0f\",($c/$CONFIRM_RUNS)*100}")
  if [ "$c" -ge 12 ]; then echo " RESULT: A->B RELIABLE at word_pin=$best_w — $c/$CONFIRM_RUNS (${pct}%)  [scan:$scan]"; rc=0
  else echo " RESULT: A->B best word_pin=$best_w — $c/$CONFIRM_RUNS (${pct}%, want >=12/15)  [scan:$scan]"; fi
else
  echo " RESULT: NO window delivered A->B in the scan — word_pin fix ineffective or die_b eye issue  [scan:$scan]"
fi
echo "=================================================================="
exit $rc
