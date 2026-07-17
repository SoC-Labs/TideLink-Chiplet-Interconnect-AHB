#!/bin/bash
# SW-coordinated PHY-align calibration for the INTEGRATED §9 build (Region 8).
#
# v1 of the integrated bitstream wedged at role_lock; the apb_debug_unlock_i
# gate fix (commit cab2d8f) cleared that — role_lock now latches via SW W1S
# and the calibrator fires (cal_done=1). But an SSH-staggered deploy makes the
# two calibrators sweep in NON-overlapping windows (fault=0xff both sides).
#
# Fix: hold SWI_TRAINING_MODE=1 on BOTH boards (Region 8 @ TideLink APB
# 0x44032000 +0x100). That OR-muxes into Wlink swi_training_mode_in, so both
# TX serialisers continuously emit the training pattern (clk_en fix keeps them
# clocked even with lltx idle). With the pattern present on BOTH links, pulse
# the Wlink swreset on each board: its falling edge (role_locked still high)
# re-triggers the calibrator, which clears lane_fault and re-sweeps — now
# against a live peer pattern. Then drop training and enable lltx for data.
#
# Region 8 layout (TideLink chiplet APB base 0x44032000), slot 0 @ +0x100:
#   bit[0] SWI_TRAINING_MODE   RW  — OR-muxed into Wlink swi_training_mode_in
#   bit[1] SWI_RECAL           RW  — level → calibrator .swreset (commit d1351f4)
#   +0x108 SWI_LANE_STATUS     RO [7:0]=locked [15:8]=fault [16]=cal_done
# Wlink APB base 0x44030000:
#   +0x208 LL ctrl: [0]swi_en [1]lltx_en [2]lltx_en_1 [3]swreset
#
# Sequence (the calibrator's own swreset re-trigger, NOT the Wlink LL swreset):
#   1. BOTH: write 0x44032100 = 0x3 {train=1,recal=1}. recal=1 asserts the
#      calibrator swreset -> cancels the stale faulted S_DONE (-> S_CANCEL);
#      train=1 forces the training pattern out (clk_en fix keeps the
#      serialiser clocked). Hold ~50 ms so BOTH links carry the pattern.
#   2. BOTH: write 0x44032100 = 0x1 {train=1,recal=0}. recal falling edge
#      (role_locked still high) re-triggers a fresh sweep that clears
#      lane_fault — now against a LIVE peer training pattern -> lanes lock.
#   3. Poll SWI_LANE_STATUS until locked=0xff (training still held).
#   4. BOTH: write 0x44032100 = 0x0, then Wlink LL swreset+lltx bootstrap
#      (0x...f08 -> f00 -> f07) to drain the queued cr_pkt -> data mode.
#
# debug_unlock GPIO (0x44041000=1) is set by deploy_pair.sh; re-assert here so
# the slave's external APB path to Wlink stays open for the LL ctrl writes.
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

# $1=IP  $2=slot0 value : write Region 8 slot 0 (0x44032100) = VAL.
#   0x3={train=1,recal=1}  0x1={train=1,recal=0}  0x0={off}
set_slot0() {
    local IP=$1 VAL=$2
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
        "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os
P=4096
fd=os.open(\"/dev/mem\", os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd, pages, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=b), o
g, go = mm(0x44041000)                       # debug_unlock GPIO (slave APB path)
struct.pack_into(\"<I\", g, go, 1)
r, ro = mm(0x44032000, 0x400)                # TideLink chiplet APB (Region 8)
struct.pack_into(\"<I\", r, ro+0x100, $VAL)  # slot 0 = {recal,train}
'" 2>/dev/null
}

# $1=IP : drop training+recal, then Wlink LL swreset+lltx bootstrap to drain
#         the queued cr_pkt and enter data mode.
to_data_mode() {
    local IP=$1
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
        "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os, time
P=4096
fd=os.open(\"/dev/mem\", os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd, pages, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=b), o
r, ro = mm(0x44032000, 0x400)
struct.pack_into(\"<I\", r, ro+0x100, 0)            # slot 0 = 0 (train+recal off)
w, wo = mm(0x44030000, 0x2000)
time.sleep(0.005)
struct.pack_into(\"<I\", w, wo+0x208, 0x00027f08)  # LL swreset on
time.sleep(0.005)
struct.pack_into(\"<I\", w, wo+0x208, 0x00027f00)  # LL swreset off
time.sleep(0.005)
struct.pack_into(\"<I\", w, wo+0x208, 0x00027f07)  # swi+lltx+lltx_1 enabled
'" 2>/dev/null
}

read_status() {
    local IP=$1
    sshpass -p $PASS ssh $SSHCOMMON xilinx@$IP \
        "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os
P=4096
fd=os.open(\"/dev/mem\", os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd, pages, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=b), o
r, o = mm(0x44032000, 0x400)
st = struct.unpack_from(\"<I\", r, o+0x108)[0]
cc = struct.unpack_from(\"<I\", r, o+0x0c)[0]
print(\"  SWI_LANE_STATUS = 0x{:08x}  locked=0x{:02x} fault=0x{:02x} cal_done={}   CURRENT_CREDITS={} {}\".format(
      st, st&0xff, (st>>8)&0xff, (st>>16)&1, cc, \"\" if cc==4096 else \"<== LINK UP\"))
'" 2>/dev/null
}

echo "=== Step 1: {train=1,recal=1} on BOTH (concurrent) — cancel stale S_DONE, pattern ON ==="
set_slot0 $MASTER_IP 0x3 &
set_slot0 $SLAVE_IP  0x3 &
wait
echo "    holding training pattern 0.2 s so BOTH links carry it..."
sleep 0.2

echo "=== Step 2: {train=1,recal=0} on BOTH (concurrent) — recal falling edge => RETRIGGER sweep ==="
set_slot0 $MASTER_IP 0x1 &
set_slot0 $SLAVE_IP  0x1 &
wait

echo "=== Step 2b: hold training, poll lane lock (up to ~8 s) ==="
for i in $(seq 1 8); do
    sleep 1
    echo "--- t=${i}s MASTER ---"; read_status $MASTER_IP
    echo "--- t=${i}s SLAVE  ---"; read_status $SLAVE_IP
done

echo ""
echo "=== Step 3: drop training, enable lltx -> data mode on BOTH (concurrent) ==="
to_data_mode $MASTER_IP &
to_data_mode $SLAVE_IP  &
wait
sleep 0.5

echo ""
echo "=== Step 4: final link state ==="
echo "--- MASTER ---"; read_status $MASTER_IP
/tmp/tidelink_scripts/wlink_probe.sh $MASTER_IP z2_02 2>&1 | grep -E 'CURRENT|RELEASED|DOORBELL|PAIR_CRED|CTRL_LOCK|ROLE_CFG' | grep -vi 'agent pid'
echo "--- SLAVE ---"; read_status $SLAVE_IP
/tmp/tidelink_scripts/wlink_probe.sh $SLAVE_IP z2_03 2>&1 | grep -E 'CURRENT|RELEASED|DOORBELL|PAIR_CRED|CTRL_LOCK|ROLE_CFG' | grep -vi 'agent pid'
