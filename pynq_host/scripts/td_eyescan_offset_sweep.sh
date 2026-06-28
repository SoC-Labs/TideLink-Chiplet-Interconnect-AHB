#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TideLink eyescan eye-CENTRE OFFSET sweep (FIX-CENTER-LITE) on bridge1 silicon
# ---------------------------------------------------------------------------
# The armed eyescan pins each lane at first-sync = the eye LEADING EDGE (~0
# margin) -> A->B data drops (silicon probe: one word byte-exact, one dropped).
# FIX-CENTER-LITE nudges the pinned phase off the edge toward centre by a
# runtime offset held in MMIO reg 0x4403_21AC [2:0] (0xEA marker in [31:24]).
# offset 0 == FIX-R (the proven link-up anchor / fast first-sync edge pin).
#
# This sweeps offset 0..7: for each, re-POR -> set offset -> arm -> role_lock
# -> cal/dwell -> measure A->B and B->A delivery. Finds the offset that makes
# A->B cross reliably WITHOUT killing B->A or link-up. The eye is ~2-3 phases
# wide so the winner is expected to be 1 or 2; offsets that overshoot the eye
# show link-DOWN or 0 delivery (the FIX-CENTER full-run-centre failure mode).
#
# Env: SENDS (per-dir per-offset, def 6), DWELL (cal settle s, def 14),
#      OFFSETS (def "0 1 2 3 4 5 6 7").
# ---------------------------------------------------------------------------
PW=xilinx; A=192.168.4.101; B=192.168.2.101; FW=/sys/class/fpga_manager/fpga0/firmware
TX=0x84000000; RX=0x84010000
UNLOCK=0x44041000; ARM=0x4403215C; OFFREG=0x440321AC; RL=0x44032080; LINK=0x44032108
SENDS="${SENDS:-6}"; DWELL="${DWELL:-14}"; OFFSETS="${OFFSETS:-0 1 2 3 4 5 6 7}"
FH=$(command -v fpgahub || echo /opt/fpgahub/bin/fpgahub)

bsh(){ sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 xilinx@"$1" "echo $PW|sudo -S sh -c \"$2\" 2>/dev/null"; }
rd(){ bsh "$1" "/usr/bin/devmem2 $2 w" | grep -oE "0x[0-9A-Fa-f]+" | tail -1; }
wr(){ bsh "$1" "/usr/bin/devmem2 $2 w $3 >/dev/null"; }
lkv(){ local v; v=$(($(rd "$1" $LINK))); [ $(((v>>16)&1)) = 1 ] && [ $(((v>>17)&7)) = 4 ] && [ $(((v>>23)&1)) = 1 ] && [ $(((v>>24)&1)) = 1 ]; }
# proven host-computed-hex send: 4 TX writes + per-offset FIFO reads
send(){ local s=$1 r=$2 u0 u1 o addr w
  u0=$(printf 0xC0DE%04X $((RANDOM&0xFFFF))); u1=$(printf 0xFEED%04X $((RANDOM&0xFFFF)))
  wr "$s" $TX 0x00240000; wr "$s" $TX 0x00000000; wr "$s" $TX "$u0"; wr "$s" $TX "$u1"; sleep 2
  for o in 0 4 8 12 16 20 24 28; do addr=$(printf 0x%X $((RX+o))); w=$(rd "$r" "$addr")
    { [ "$w" = "$u0" ] || [ "$w" = "$u1" ]; } && return 0; done; return 1; }
count(){ local s=$1 r=$2 i h=0; for i in $(seq 1 "$SENDS"); do send "$s" "$r" && h=$((h+1)); done; echo $h; }

$FH pair up bridge1 --ttl 1500 >/dev/null 2>&1 || true
echo "=================================================================="
echo " EYESCAN OFFSET SWEEP  $(date)  SENDS=$SENDS/dir  DWELL=${DWELL}s  offsets: $OFFSETS"
echo "=================================================================="
echo "[$(date +%H:%M:%S)] program both (FIX-CENTER-LITE + MMIO offset build)"
bsh "$A" "echo tidelink.bin > $FW"; bsh "$B" "echo tidelink.bin > $FW"; sleep 2

best=-1; bestoff=-1
for off in $OFFSETS; do
  # re-POR (reload .bin -> PL reset) so each offset gets a FRESH cal
  bsh "$A" "echo tidelink.bin > $FW"; bsh "$B" "echo tidelink.bin > $FW"; sleep 2
  wr "$A" $UNLOCK 0x1; wr "$B" $UNLOCK 0x1
  # set the eye-centre offset BEFORE cal (latched at pin time), then arm + role_lock
  wr "$A" $OFFREG "$off"; wr "$B" $OFFREG "$off"
  oa=$(rd "$A" $OFFREG); ob=$(rd "$B" $OFFREG)
  wr "$A" $ARM 0x1; wr "$B" $ARM 0x1
  wr "$A" $RL 0x2; wr "$B" $RL 0x3
  sleep "$DWELL"
  if lkv "$A" && lkv "$B"; then
    ab=$(count "$A" "$B"); ba=$(count "$B" "$A")
    echo "[$(date +%H:%M:%S)]   offset $off (regA=$oa regB=$ob): link UP    A->B $ab/$SENDS   B->A $ba/$SENDS"
    [ "$ab" -gt "$best" ] && { best=$ab; bestoff=$off; }
  else
    la=0; lb=0; lkv "$A" && la=1; lkv "$B" && lb=1
    echo "[$(date +%H:%M:%S)]   offset $off (regA=$oa regB=$ob): link DOWN (lkA=$la lkB=$lb) — skip"
  fi
done
echo "=================================================================="
if [ "$best" -ge 1 ]; then
  echo " RESULT: BEST A->B = offset $bestoff  ($best/$SENDS)"
else
  echo " RESULT: no offset delivered A->B (all 0 or link-down) — inspect"
fi
echo "=================================================================="
$FH pair down bridge1 >/dev/null 2>&1 || true
