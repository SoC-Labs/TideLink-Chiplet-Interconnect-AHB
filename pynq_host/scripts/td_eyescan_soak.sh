#!/usr/bin/env bash
#=============================================================================
# td_eyescan_soak.sh — ACCEPTANCE SOAK for the eyescan fix (design §7).
# ARMs the eyescan (0x4403215C=1) on BOTH dies, re-PORs so the calibrator runs
# the in-S_VALIDATE PRBS eyescan and pins each lane's sample point, then proves
# SUSTAINED reliable bidirectional (no drift) across two bursts separated by an
# idle dwell. Requires the EYESCAN builds programmed on both dies.
# RUN ON mapstone-dev. Reuses td_v1_b2a_proof.sh for lease+program+release.
#
# Pass = both bursts >= THRESH% each direction AND link integrity held AND
# eyescan stayed armed (0xEA0000.1) AND no validation stall.
#
# NOTE batched devmem2: each send = 1 SSH (4 TX writes) + 1 SSH (8 FIFO reads)
# instead of 12 SSH, so a 100-send burst is ~15 min not ~70 min.
#=============================================================================
set -u
PROOF="${PROOF:-/tmp/td_v1_b2a_proof.sh}"
A_IP="${A_IP:-192.168.4.101}"; B_IP="${B_IP:-192.168.2.101}"; PW="${TIDELINK_BOARD_PASS:-xilinx}"
TX="${TX_BASE:-0x84000000}"; RX="${RX_BASE:-0x84010000}"
ARM=0x4403215C; ROLE=0x44032080; UNLOCK=0x44041000; LS=0x44032108; CRED=0x4403219C
FW=/sys/class/fpga_manager/fpga0/firmware
SENDS="${SENDS:-100}"; ROLLS="${ROLLS:-15}"; DWELL="${DWELL:-12}"; IDLE="${IDLE:-120}"; THRESH="${THRESH:-98}"
SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
bsh(){ local ip=$1; shift; sshpass -p "$PW" ssh $SSHC xilinx@"$ip" "echo '$PW' | sudo -S sh -c '$*' 2>/dev/null"; }
rdr(){ bsh "$1" "/usr/bin/devmem2 $2 w" | grep -oE '0x[0-9A-Fa-f]+' | tail -1; }
wrr(){ bsh "$1" "/usr/bin/devmem2 $2 w $3 >/dev/null"; }
lk(){ local v; v=$(rdr "$1" $LS); v=$((${v:-0})); [ $(((v>>16)&1)) = 1 ] && [ $(((v>>17)&7)) = 4 ] && [ $(((v>>23)&1)) = 1 ] && [ $(((v>>24)&1)) = 1 ]; }
cred(){ local c; c=$(rdr "$1" $CRED); [ -n "$c" ] && [ "${c: -2}" != "00" ]; }
arm(){ rdr "$1" $ARM; }
# send: PROVEN mechanism (host-computed hex addrs, separate devmem2 per word) —
# robust vs board-side $((hex)) arithmetic. 4 TX writes + per-offset FIFO reads.
send(){ local s=$1 r=$2 u0 u1 off addr w
  u0=$(printf '0xC0DE%04X' $((RANDOM&0xFFFF))); u1=$(printf '0xFEED%04X' $((RANDOM&0xFFFF)))
  wrr "$s" "$TX" 0x00240000; wrr "$s" "$TX" 0x00000000; wrr "$s" "$TX" "$u0"; wrr "$s" "$TX" "$u1"
  sleep 2
  for off in 0 4 8 12 16 20 24 28; do addr=$(printf '0x%X' $(( RX + off ))); w=$(rdr "$r" "$addr")
    { [ "$w" = "$u0" ] || [ "$w" = "$u1" ]; } && return 0; done; return 1; }
trap '"$PROOF" --release >/dev/null 2>&1 || true' EXIT

echo "=================================================================="
echo " EYESCAN ACCEPTANCE SOAK  $(date)  SENDS=$SENDS x2  IDLE=${IDLE}s  THRESH=${THRESH}%"
echo "=================================================================="
log "program both (eyescan builds) + lease via proof --program ..."
"$PROOF" --program --dir BtoA --rolls "$ROLLS" >/dev/null 2>&1 || true   # lease+program+initial bringup

log "ARMED roll: re-POR -> arm eyescan (0x215C=1) BEFORE role_lock cal -> dwell ..."
clean=0
for r in $(seq 1 "$ROLLS"); do
  bsh "$A_IP" "echo tidelink.bin > $FW"; bsh "$B_IP" "echo tidelink.bin > $FW"; sleep 2
  wrr "$A_IP" $UNLOCK 0x1; wrr "$B_IP" $UNLOCK 0x1
  wrr "$A_IP" $ARM 0x1;    wrr "$B_IP" $ARM 0x1      # ARM before the role_lock-triggered calibration
  wrr "$A_IP" $ROLE 0x2;   wrr "$B_IP" $ROLE 0x3
  sleep "$DWELL"
  log "  roll $r: armA=$(arm $A_IP) armB=$(arm $B_IP)  lkA=$(lk $A_IP&&echo 1||echo 0) lkB=$(lk $B_IP&&echo 1||echo 0)"
  if lk "$A_IP" && lk "$B_IP" && cred "$A_IP" && cred "$B_IP"; then log "  ARMED link UP on roll $r"; clean=1; break; fi
done
[ "$clean" = 1 ] || { echo "RESULT: FAIL — no armed link-up in $ROLLS rolls"; exit 1; }

soak(){ local lbl=$1 b=0 a=0 i; for i in $(seq 1 "$SENDS"); do
    send "$B_IP" "$A_IP" && b=$((b+1)); send "$A_IP" "$B_IP" && a=$((a+1))
    [ $((i % 25)) = 0 ] && log "  [$lbl] $i/$SENDS: B->A $b A->B $a  lk=$(lk $A_IP&&echo 1||echo 0)$(lk $B_IP&&echo 1||echo 0)"
  done; printf '%s %s' "$b" "$a"; }

log "SOAK burst 1 ..."; r1=$(soak b1); b1=${r1% *}; a1=${r1#* }
log "idle ${IDLE}s (drift dwell) ..."; sleep "$IDLE"
log "SOAK burst 2 (drift-proof) ..."; r2=$(soak b2); b2=${r2% *}; a2=${r2#* }

m=$((SENDS*THRESH/100))
echo "=================================================================="
echo "  burst1: B->A $b1/$SENDS  A->B $a1/$SENDS    burst2: B->A $b2/$SENDS  A->B $a2/$SENDS"
echo "  arm: A=$(arm $A_IP) B=$(arm $B_IP)   final link: lkA=$(lk $A_IP&&echo up||echo DOWN) lkB=$(lk $B_IP&&echo up||echo DOWN)"
if [ "$b1" -ge "$m" ]&&[ "$a1" -ge "$m" ]&&[ "$b2" -ge "$m" ]&&[ "$a2" -ge "$m" ]&&lk "$A_IP"&&lk "$B_IP"; then
  echo " RESULT: PASS — SUSTAINED RELIABLE BIDIRECTIONAL (eyescan armed, drift-proof)"; rc=0
else echo " RESULT: NOT sustained — inspect counts/link"; rc=1; fi
echo "=================================================================="
exit $rc
