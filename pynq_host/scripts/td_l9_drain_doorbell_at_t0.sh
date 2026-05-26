#!/bin/bash
# =============================================================================
# td_l9_drain_doorbell_at_t0.sh — discriminator probe between H-1/H-2 deadlock
# classes and a transient "settling" condition.
#
# After a converged bringup_pair_converge run, this script:
#   1. Snapshots master FCSM_6 [0x08] (link_empty) — should be 1 (clean idle)
#   2. Rings ONE doorbell on master via the safe APB doorbell address
#      (0x44032024 = DOORBELL_RESP_ACC write — fires returner via
#      doorbell_irq, queues a SIDEBAND packet onto the TideLink FC TX FIFO)
#   3. Polls [0x08] every 100ms for 10s
#   4. Reports: did the FIFO drain (link_empty → 1)?
#      - PASS: drained within 100ms = link is working
#      - FAIL: never drained within 10s = FCSM is wedged at state != 5
#
# This is the SIMPLEST positive test the L9 doc proposes — a single 4-byte
# APB write that exercises the smallest possible app-TX path.
#
# SAFETY: this script touches the doorbell accumulator, which DOES queue
# TX traffic on master TideLink FC. If FCSM_6 is healthy, the doorbell
# crosses and slave's DOORBELL_RESP_ACC increments. If FCSM_6 is wedged,
# the doorbell sits in master's a2l FIFO indefinitely — exactly the L9
# symptom. NEITHER outcome wedges the board (unlike AHB_TX 0x44000000,
# which can hang the AXI-Lite-to-AHB-Lite bridge and take down SSH).
#
# The doorbell address 0x44032024 is a TideLink APB reg, NOT AHB_TX,
# so the wedge hazard doc warnings don't apply.
#
# Usage:
#   td_l9_drain_doorbell_at_t0.sh [MASTER_IP] [SLAVE_IP]
#
# DO NOT RUN against bridge1 from this branch — staged for the NEXT
# operator session. The L9 doc explicitly says "DO NOT execute".
# =============================================================================
set -u
MASTER_IP="${1:-${MASTER_IP:-192.168.4.101}}"
SLAVE_IP="${2:-${SLAVE_IP:-192.168.6.101}}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Disabled-by-default guard. The L9 doc requires explicit operator opt-in
# before this script touches the TX path. Override with TD_L9_FORCE=1.
if [ "${TD_L9_FORCE:-0}" != "1" ]; then
    cat <<EOF
==============================================================
 td_l9_drain_doorbell_at_t0.sh — GUARD ACTIVE (no-op)
==============================================================

This script is staged on the L9 branch but disabled by default.
It rings a master doorbell and polls the TX FIFO for drain. To
actually invoke against bridge1 (only after H-3 has been probed
via td_l9_probe_fcsm_credit_asym.sh AND the operator decides this
is the next step):

  TD_L9_FORCE=1 $0 [MASTER_IP] [SLAVE_IP]

Per docs/TIDELINK_L9_TIDELINK_FC_ASYM_2026_05_26.md §10, the
recommended sequence is:
  1) td_l9_probe_fcsm_credit_asym.sh  (read-only)
  2) Check master vs slave [0x10]/[0x14] diff for H-3
  3) IF H-3 falsified, write the sim test FIRST
  4) Only then consider invoking this drain test

DO NOT REMOVE THE GUARD without an L9 follow-up doc entry.
EOF
    exit 0
fi

read_link_empty() {
    local IP=$1
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os
P=4096; fd=os.open(\"/dev/mem\", os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd, pages, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=b), o
r, o = mm(0x44030000 + 0x1700, 64)
print(struct.unpack_from(\"<I\", r, o+0x08)[0])
'" 2>/dev/null
}

ring_doorbell() {
    local IP=$1
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os
P=4096; fd=os.open(\"/dev/mem\", os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd, pages, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=b), o
# TideLink APB base 0x44032000, Region 1 doorbell accumulator at +0x024
r, o = mm(0x44032000, 0x40)
struct.pack_into(\"<I\", r, o+0x024, 1)   # add 1 to doorbell_response_acc -> doorbell_irq fires -> returner emits SIDEBAND packet on TideLink FC
'" 2>/dev/null
}

echo "=============================================================="
echo " L9 doorbell drain test  $(date)"
echo "  Master IP: $MASTER_IP"
echo "  Slave  IP: $SLAVE_IP"
echo "=============================================================="

echo "  pre-ring: master link_empty = $(read_link_empty $MASTER_IP)"
ring_doorbell "$MASTER_IP"
echo "  doorbell rung."

for t in $(seq 0 99); do
    LE=$(read_link_empty "$MASTER_IP")
    if [ "$LE" = "1" ]; then
        T_MS=$((t * 100))
        echo "  t=${T_MS}ms: master link_empty=1 -> FIFO drained.  PASS (FCSM is forwarding)."
        exit 0
    fi
    sleep 0.1
done

echo "  t=10000ms: master link_empty still 0 -> FCSM never drained the doorbell."
echo "  FAIL: confirms L9 symptom — FCSM_6 wedged below LINK_DATA on master."
exit 1
