#!/bin/bash
# Reduced-width LL/FCSM milestone on v5. Proven remote-python idiom copied
# verbatim from phase_recal_sweep.sh (single-quoted -c, \" escaping, $VAR
# shell-injected). Deploy @ MP/SP, recal retry, mask Wlink 0x214 to the
# lanes BOTH boards lock, LL bootstrap, check CURRENT_CREDITS.
set -u
MIP=192.168.4.101; SIP=192.168.6.101; PASS=xilinx
SC=/tmp/tidelink_scripts
MP=${MP:-0}; SP=${SP:-6}
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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
print(st&0xff)'" 2>/dev/null
}
apply_mask() {
    local IP=$1 MV=$2
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os,time
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,ro=mm(0x44032000,0x400)
struct.pack_into(\"<I\",r,ro+0x100,0)            # drop SWI_TRAINING_MODE+RECAL -> data
w,o=mm(0x44030000,0x2000)
struct.pack_into(\"<I\",w,o+0x214,$MV); time.sleep(0.005)
# 2026-05-25: changed from 0x27f08/00/07 -> 0x27f09/01/07 to keep
# swi_enable=1 throughout the swreset cycle. Per FC.scala:619-621,
# swi_enable=0 resets all 7 FCSMs to IDLE and clears cr_pkt_seen
# sticky bits, which on HW left the link unable to enter data mode.
# See docs/TIDELINK_PHASE0_OBS_20260524_2109.md S9 for full diagnosis.
struct.pack_into(\"<I\",w,o+0x208,0x00027f09); time.sleep(0.01)  # LL swreset, swi_enable kept high
struct.pack_into(\"<I\",w,o+0x208,0x00027f01); time.sleep(0.01)  # release swreset, swi_enable kept high
struct.pack_into(\"<I\",w,o+0x208,0x00027f07)                    # swi+lltx enable
print(\"lane_mask=0x%08x active=0x%08x\"%(struct.unpack_from(\"<I\",w,o+0x214)[0],struct.unpack_from(\"<I\",w,o+0x210)[0]))'" 2>/dev/null
}

echo "=== deploy v5 @ master_phase=$MP / slave_phase=$SP ==="
PHASE_OVERRIDE=$((MP<<17)) $SC/deploy_pair.sh $MIP z2_02 die_a /tmp/tidelink_deploy >/dev/null 2>&1 &
PHASE_OVERRIDE=$((SP<<17)) $SC/deploy_pair.sh $SIP z2_03 die_b /tmp/tidelink_deploy >/dev/null 2>&1 &
wait; sleep 1

COMMON=0
for cyc in 1 2 3 4 5; do
  set_slot0 $MIP 0x3 & set_slot0 $SIP 0x3 & wait; sleep 0.25
  set_slot0 $MIP 0x1 & set_slot0 $SIP 0x1 & wait; sleep 3
  ML=$(read_lock $MIP); SL=$(read_lock $SIP)
  COMMON=$(( ${ML:-0} & ${SL:-0} ))
  N=$(python3 -c "print(bin($COMMON).count('1'))")
  printf "  recal %d: master=0x%02x slave=0x%02x COMMON=0x%02x (%d)\n" "$cyc" "${ML:-0}" "${SL:-0}" "$COMMON" "$N"
  [ "$N" -ge 4 ] && break
done
[ "$COMMON" -eq 0 ] && { echo "COMMON=0 — abort"; exit 1; }
MASKVAL=$(( (COMMON<<8) | COMMON ))

echo "=== mask both to 0x$(printf %02x $COMMON) + LL bootstrap ==="
echo -n "  MASTER "; apply_mask $MIP $MASKVAL
echo -n "  SLAVE  "; apply_mask $SIP $MASKVAL
sleep 1

echo "=== link state ==="
echo "--- MASTER z2_02 ---"
$SC/wlink_probe.sh $MIP z2_02 2>&1 | grep -E 'CURRENT_CREDITS|CTRL_LOCK|RELEASED|DOORBELL|PAIR_CRED|ROLE_CFG|TideLnk FC' | grep -vi 'agent pid'
echo "--- SLAVE z2_03 ---"
$SC/wlink_probe.sh $SIP z2_03 2>&1 | grep -E 'CURRENT_CREDITS|CTRL_LOCK|RELEASED|DOORBELL|PAIR_CRED|ROLE_CFG|TideLnk FC' | grep -vi 'agent pid'
echo
echo "SUCCESS = CURRENT_CREDITS != 4096"
