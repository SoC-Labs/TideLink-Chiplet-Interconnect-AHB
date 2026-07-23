#!/bin/bash
# HW phase + SWI_RECAL sweep on the v3 bitstream (fix#1+fix#2).
#
# swi_phase_offset must be loaded BEFORE role_lock (SHORTCOMINGS-14b: the
# RX deserialiser counter syncs at role_lock and can't be re-synced after),
# so every phase point is a fresh deploy_pair.sh with PHASE_OVERRIDE
# (full 32-bit Wlink PHY-ctrl value = phase<<17). After deploy we run the
# SWI_RECAL coordinated re-trigger (Region 8 slot0: bit0=train, bit1=recal)
# with the training pattern held on BOTH boards, then read SWI_LANE_STATUS
# and report popcount(locked) per side. Goal: characterise phase→#lanes
# and find any global (mp,sp) that beats the 5/8 bit-slip-only result.
set -u

# --- ZynqMP (KR260) SAFETY GUARD (inline) ------------------------------------
# This tool mmaps RAW Pynq-Z2 control literals (0x4403_xxxx / 0x4404_xxxx /
# 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP (KR260) those addresses
# are UNDECODED with NO bus timeout => a hard PS hang (power-cycle to recover).
# Pynq-Z2 ONLY. Refuse the moment we start if TIDELINK_SOC names anything else.
# Safe on a KR260: tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.
_tl_guard_soc=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$_tl_guard_soc" in
  ""|z2|pynq-z2|pynq_z2|zynq7|zynq) : ;;
  *)
    printf '\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 literals (0x4403_xxxx)\n' "${0##*/}" "$TIDELINK_SOC" >&2
    printf '  UNDECODED on a ZynqMP (KR260) => hard PS hang. This tool is Pynq-Z2 ONLY.\n' >&2
    printf '  On a KR260 use tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.\n' >&2
    exit 3 ;;
esac

MASTER_IP=192.168.4.101
SLAVE_IP=192.168.6.101
PASS=xilinx
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SC=/tmp/tidelink_scripts

# slot0 write helper: VAL into Region 8 0x44032100 (+ debug_unlock GPIO)
set_slot0() {
    local IP=$1 VAL=$2
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
g,go=mm(0x44041000); struct.pack_into(\"<I\",g,go,1)
r,ro=mm(0x44032000,0x400); struct.pack_into(\"<I\",r,ro+0x100,$VAL)'" 2>/dev/null
}

# returns "locked_hex fault_hex popcount"
read_lock() {
    local IP=$1
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,o=mm(0x44032000,0x400); st=struct.unpack_from(\"<I\",r,o+0x108)[0]
lk=st&0xff; ft=(st>>8)&0xff; print(\"0x%02x 0x%02x %d\"%(lk,ft,bin(lk).count(\"1\")))'" 2>/dev/null
}

recal_cycle() {   # {train=1,recal=1} hold, {train=1,recal=0}, settle
    set_slot0 $MASTER_IP 0x3 & set_slot0 $SLAVE_IP 0x3 & wait
    sleep 0.25
    set_slot0 $MASTER_IP 0x1 & set_slot0 $SLAVE_IP 0x1 & wait
    sleep 3
}

# Sweep set: master phase fixed values × slave phase values.
# 14b says slave RX ends ~3 ahead of master, so centre slave sweep wide;
# also try a couple master phases.
MP_LIST="${MP_LIST:-0 2}"
SP_LIST="${SP_LIST:-0 1 2 3 4 5 6 8 10 12}"

echo "phase sweep start $(date)"
printf '%-4s %-4s | %-22s | %-22s | %s\n' MP SP "MASTER lk/ft/#" "SLAVE lk/ft/#" "total"
BEST=-1; BESTCFG=""
for mp in $MP_LIST; do
  for sp in $SP_LIST; do
    MPV=$(( mp << 17 )); SPV=$(( sp << 17 ))
    PHASE_OVERRIDE=$MPV $SC/deploy_pair.sh $MASTER_IP z2_02 die_a /tmp/tidelink_deploy >/dev/null 2>&1 &
    PHASE_OVERRIDE=$SPV $SC/deploy_pair.sh $SLAVE_IP  z2_03 die_b /tmp/tidelink_deploy >/dev/null 2>&1 &
    wait
    sleep 1
    recal_cycle
    MR=$(read_lock $MASTER_IP); SR=$(read_lock $SLAVE_IP)
    mn=$(echo "$MR" | awk '{print $3}'); sn=$(echo "$SR" | awk '{print $3}')
    tot=$(( ${mn:-0} + ${sn:-0} ))
    printf '%-4s %-4s | %-22s | %-22s | %s\n' "$mp" "$sp" "$MR" "$SR" "$tot"
    if [ "$tot" -gt "$BEST" ]; then BEST=$tot; BESTCFG="mp=$mp sp=$sp ($MR | $SR)"; fi
  done
done
echo "phase sweep done $(date)"
echo "BEST total=$BEST  @ $BESTCFG"
