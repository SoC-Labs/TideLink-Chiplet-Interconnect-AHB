#!/usr/bin/env bash
#=============================================================================
# td_reliable_bilateral.sh — confirm + regression-gate the RELIABLE bilateral
# V1 state (tag v1-silicon-reliable-a2b-2026-06-25):
#   B->A reliable  AND  A->B reliable with die_b RX word_pin SET (default 4).
#
# Programs both dies (die_b = the word_pin-fix build, md5 8ab846ba), sets
# word_pin on die_b, then runs B->A and A->B INTERLEAVED to prove both
# directions deliver simultaneously. word_pin is OFF at POR (= proven legacy
# free-run), so it must be re-set after every program. RUN ON mapstone-dev.
#
# Pre-fix history: A->B was a ~13% free-run lottery; the word_pin enable reg
# 0x4403214C SIGBUSed (eye_regs RO slot) until the V1-arm perlane_wp_sel fix.
#
# Usage:  ./td_reliable_bilateral.sh        (WORD_PIN=4 N=8 by default)
#=============================================================================
set -u
PROOF="${PROOF:-/tmp/td_v1_b2a_proof.sh}"
B_IP="${B_IP:-192.168.2.101}"; PW="${TIDELINK_BOARD_PASS:-xilinx}"
WP=0x44032148; WP_EN=0x4403214C
WORD_PIN="${WORD_PIN:-4}"; N="${N:-8}"; ROLLS="${ROLLS:-15}"
SSHC="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
bwr(){ sshpass -p "$PW" ssh $SSHC xilinx@"$B_IP" "echo '$PW' | sudo -S /usr/bin/devmem2 $1 w $2 >/dev/null 2>&1"; }
dir(){ "$PROOF" --dir "$1" --rolls "$ROLLS" 2>&1 | grep -qE '^RESULT: PASS'; }
trap '"$PROOF" --release >/dev/null 2>&1 || true' EXIT

echo "=================================================================="
echo " RELIABLE bilateral V1 confirmation   $(date)"
echo "   die_b word_pin=$WORD_PIN   N=$N interleaved each direction"
echo "=================================================================="
log "program both + confirm B->A ..."
"$PROOF" --program --dir BtoA --rolls "$ROLLS" 2>&1 | grep -qE '^RESULT: PASS' || { echo " RESULT: B->A FAILED on program (REGRESSED)"; exit 2; }
log "set die_b word_pin=$WORD_PIN (0x214C enable + 0x2148 value) ..."
bwr "$WP_EN" 0xFF; bwr "$WP" "$(printf '0x%08X' $(( WORD_PIN * 0x11111111 )))"

b=0; a=0
for r in $(seq 1 "$N"); do
  dir BtoA && b=$((b+1))
  dir AtoB && a=$((a+1))
  log "  round $r: B->A $b/$r   A->B $a/$r"
done

echo "=================================================================="
echo " B->A: $b/$N    A->B(word_pin=$WORD_PIN): $a/$N"
rc=1
if   [ "$b" -lt $((N-1)) ]; then echo " RESULT: REGRESSED — B->A only $b/$N"
elif [ "$a" -ge $((N-1)) ]; then echo " RESULT: RELIABLE BILATERAL — B->A $b/$N + A->B $a/$N (word_pin=$WORD_PIN)"; rc=0
else echo " RESULT: A->B not reliable — $a/$N at word_pin=$WORD_PIN"; fi
echo "=================================================================="
exit $rc
