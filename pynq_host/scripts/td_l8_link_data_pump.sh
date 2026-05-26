#!/bin/bash
# =============================================================================
# td_l8_link_data_pump.sh — Force master FCSM to LINK_DATA via TX aperture
# =============================================================================
#
# WHY THIS EXISTS — the post-L7 wedge (2026-05-26 / tdif-13)
#
#   After L6 (producer CR-emit hold) and L7 (NACK forgive) landed, the
#   tdif-13 build observed both FCSMs reach state=4 (LINK_IDLE) symmetric,
#   cr_pkt_seen=1 / crack_pkt_seen=1 symmetric, PHY clean.  But end-to-end
#   data still does NOT cross:
#
#     * doorbells M->S x8           -> S_DOORBELL_RESP_ACC unchanged (0)
#     * AHB peer-write 0xDEADBEEF   -> S reads 0x00000000
#     * PAIR_CREDIT_CTR             -> 0 (no credit pumped through
#                                     user-traffic path)
#     * M_TIDELINK_FC_active=0      -> master a2l_replay_link_empty=0
#                                     i.e. MASTER HAS WORDS QUEUED but
#                                     the FCSM is NOT consuming them.
#     * S_TIDELINK_FC_active=1      -> slave a2l_replay_link_empty=1
#                                     i.e. slave has NO queued traffic.
#     * Both FCSM state=4 LINK_IDLE -> the very state at which a2l_valid
#                                     SHOULD trigger 4->5 (LINK_DATA).
#
# THE ROOT CAUSE — chicken-and-egg from sim test docstring
#
#   `cocotb/wlink_pair/test_link_idle_advance_with_payload.py` (commit
#   664853c) documents the exact failure pattern:
#
#     "on HW the FCSM is stuck at LINK_IDLE because the AHB side never
#      advances the master past it (the SW driver expects the link to
#      come up first). This test removes the chicken-and-egg by forcing
#      the app interface and asks 'can the FCSM forward a packet at all?'"
#
#   The sim proves that FORCING a2l_valid (test_post_recal_link_data_advance
#   commit 664853c, 3/3 PASS post-recal) makes the FCSM advance LINK_IDLE
#   -> LINK_DATA cleanly.  But on HW the deploy_pair / bringup_pair_converge
#   flow NEVER writes ahb_tx (0x4400_0000) and NEVER rings the doorbell
#   first (see bringup_pair_converge.sh:56 — explicit safety comment).
#
#   The only auto-generated a2l_valid traffic is the reset_deassert_pulse
#   firing the returner's Channel 2 (PAIR_DOORBELL_ADDR) ONCE per hresetn
#   rise.  In post-L7 HW that single returner write is queued in master's
#   a2l replay FIFO but the FCSM never consumes it -- the L7 forgive gate
#   clears send_nack_req but does NOT clear send_ack_req, AND the master
#   is constantly servicing slave's reset_deassert_pulse data packet by
#   ACKing (state 4 -> 6) before it ever gets to forward its OWN queued
#   doorbell (state 4 -> 5).
#
#   This script breaks the deadlock from SW: it writes a single 32-bit
#   word to the TX aperture (0x4400_0000) on master, which:
#
#     1. Triggers ahb_tx_hsel + htrans=NONSEQ + hwrite=1 on the FC
#        adapter's TX aperture slave port.
#     2. Latches tx_data_phase_r=1 in the adapter (tidelink_fc_adapter.sv
#        line 180-193).
#     3. Constructs tx_fc_word = {PKT_FIFO_DATA, addr, data} (line 196).
#     4. Pushes through arbiter -> skid -> replay FIFO.
#     5. The replay FIFO sees a new write while link_valid is already
#        non-empty.  The FCSM at LINK_IDLE sees a2l_valid persistently
#        HIGH (the queue depth is now 2+ words).
#     6. Eventually send_ack_req clears (after master finishes ACKing
#        slave's reset packet) and 4 -> 5 fires.
#
# WHY THIS UNWEDGES THE BUG
#
#   The post-L7 wedge is a STATISTICAL race: master keeps getting send_ack_req
#   re-asserted by l2a_fifo_raddr_txclk_update before it can drain its own
#   queued a2l word.  By keeping a2l_valid HIGH for many cycles (queue depth
#   >> 1), we guarantee that SOME cycle in state==4 has send_ack_req=0 AND
#   a2l_valid=1 simultaneously, forcing state -> 5.
#
#   Once state 5 is reached ONCE, the L7 reached_link_data sticky latches
#   permanently, send_nack_req mask drops, and steady-state behaviour
#   is identical to upstream (no further deadlock paths).
#
# WHEN TO RUN
#
#   AFTER bringup_pair_converge.sh exits 0 (16/16 lanes locked, cal_done
#   on both sides).  Before running this, the link is DEFINITELY
#   structurally healthy (lane lock proves PHY).  The only failure mode
#   pre-pump is the L7 wedge described above, which this script breaks.
#
# SAFETY
#
#   * Writes 0x00000001 (a single low-priority 32-bit word) to 0x44000000
#     on MASTER only.  This is the TX aperture's offset 0 -- the slave
#     receives FIFO_DATA{addr=0, data=1} and writes 1 to its local RX
#     FIFO[0].  No SW reads slave's FIFO[0] for validation, so the
#     consumed FIFO slot is harmless.
#   * If FCSM was actually wedged on something OTHER than a2l_valid
#     starvation (e.g. fe_rx_is_full, swi_enable=0), this write WILL
#     stall (hreadyout drops, the SW write blocks).  /dev/mem writes do
#     not have a timeout, so a true wedge would hang the script.  Pump
#     is wrapped in a Python-level timeout to bound the impact.
#
# USAGE
#
#   td_l8_link_data_pump.sh [MASTER_IP]
#
#   MASTER_IP defaults to $MASTER_IP env or 192.168.4.101.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# A joint work commissioned on behalf of SoC Labs.
# Contributors: David Mapstone (d.a.mapstone@soton.ac.uk)
# =============================================================================

set -u

MASTER_IP="${1:-${MASTER_IP:-192.168.4.101}}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

echo "================================================================"
echo " td_l8_link_data_pump — break post-L7 LINK_IDLE wedge"
echo "  MASTER_IP=$MASTER_IP"
echo "  Strategy: write 4 words to ahb_tx (0x44000000..0x4400000C)"
echo "            to keep a2l_valid HIGH for many cycles."
echo "================================================================"

# Pre-flight: read master FCSM state to confirm we're in the L7 wedge
# (state=4 with M_TIDELINK_FC_active=0).  If we observe state already at
# 5 (LINK_DATA) or higher, the pump is a no-op (safe).
sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$MASTER_IP" \
    "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os, sys
P = 4096
fd = os.open(\"/dev/mem\", os.O_RDWR | os.O_SYNC)

def mm(addr, sz=4096):
    base = addr & ~(P - 1)
    off  = addr - base
    pgs  = ((sz + off + P - 1) // P) * P
    return mmap.mmap(fd, pgs, mmap.MAP_SHARED,
                     mmap.PROT_READ | mmap.PROT_WRITE, offset=base), off

# 1. Read pre-pump status.  Region 8 slot1 = SWI_LANE_STATUS.
r, ro = mm(0x44032000, 0x400)
status = struct.unpack_from(\"<I\", r, ro + 0x108)[0]
fcsm   = (status >> 17) & 0xF
locked = bin(status & 0xFF).count(\"1\")
print(\"  pre-pump:  FCSM=%d  locked=%d/8  status=0x%08x\" % (fcsm, locked, status))
sys.stdout.flush()

# 2. Read FC channel link_empty (the M_TIDELINK_FC_active observable).
#    Wlink region 0x1700 offset 0x08 = a2l_fc_replay_link_empty.
w, wo = mm(0x44030000, 0x8000)
fc_obs = struct.unpack_from(\"<I\", w, wo + 0x1708)[0]
empty  = fc_obs & 1
print(\"  pre-pump:  a2l_link_empty=%d (1=empty=normal, 0=words queued=wedge)\" % empty)
sys.stdout.flush()

# 3. Pump: 4 single-word writes to TX aperture offsets 0/4/8/0xC.
#    Each write is one AHB transaction.  Burst of 4 ensures we get a
#    queue depth of 4+ in the a2l replay FIFO, which exceeds the
#    1-cycle window in which send_ack_req might steal priority.
tx, txo = mm(0x44000000, 0x10)
for offs, val in [(0x0, 0xC0FFEE01),
                  (0x4, 0xC0FFEE02),
                  (0x8, 0xC0FFEE03),
                  (0xC, 0xC0FFEE04)]:
    struct.pack_into(\"<I\", tx, txo + offs, val)
print(\"  pumped:    4 words to ahb_tx 0x44000000..0x4400000C\")
sys.stdout.flush()

# 4. Brief settle (link layer + ACK round trip).
import time
time.sleep(0.05)

# 5. Read post-pump status.
status = struct.unpack_from(\"<I\", r, ro + 0x108)[0]
fcsm   = (status >> 17) & 0xF
print(\"  post-pump: FCSM=%d  status=0x%08x\" % (fcsm, status))

# 6. Re-read FC channel link_empty.  If pump worked, FCSM should have
#    advanced through LINK_DATA and drained the queue; empty should be 1.
fc_obs = struct.unpack_from(\"<I\", w, wo + 0x1708)[0]
empty  = fc_obs & 1
print(\"  post-pump: a2l_link_empty=%d\" % empty)

# 7. Read PAIR_CREDIT_CTR (0x44032000 + Region1 0x028) to see if any
#    credit traffic crossed.
pcc = struct.unpack_from(\"<I\", r, ro + 0x028)[0]
print(\"  post-pump: PAIR_CREDIT_CTR=0x%08x (was 0 pre-pump per report)\" % pcc)

# Exit code: 0 if FCSM reached LINK_DATA (5) or higher (steady state),
# 1 if still wedged at 4 (LINK_IDLE) -- meaning the L8 hypothesis is wrong.
sys.exit(0 if fcsm >= 5 or empty == 1 else 1)
'"
RC=$?

echo "----------------------------------------------------------------"
if [ "$RC" -eq 0 ]; then
    echo "PASS: pump unwedged the link (FCSM advanced or queue drained)."
    echo "       Run hwtest/02_tidelink_top_regs.sh next to validate"
    echo "       doorbell + AHB peer-write end-to-end."
else
    echo "FAIL: pump did NOT unwedge.  Hypothesis L8 was wrong --"
    echo "       FCSM still at LINK_IDLE with words queued.  Likely root"
    echo "       cause is RTL (not SW): inspect send_ack_req or"
    echo "       fe_rx_is_full state via the obs taps."
fi

exit $RC
