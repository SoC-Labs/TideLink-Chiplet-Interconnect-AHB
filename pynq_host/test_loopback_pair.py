"""PYNQ hardware test for two cross-connected TideLink instances.

Instance A's returner master writes to instance B's config registers,
and vice versa. No Python pair model is needed — the hardware does it.

Usage (on Pynq-Z2, two boards running the paired bitstream):
    # Board A:  FPGAHUB_LOCAL_ROLE=die_a python3 test_loopback_pair.py
    # Board B:  FPGAHUB_LOCAL_ROLE=die_b python3 test_loopback_pair.py

Address map targets the Wave B2 paired bitstream
(fpga/targets/pynq-z2-pair/tidelink_design.tcl).
"""

import os
import time

try:
    from overlay import TidelinkOverlay as _Overlay
    _ol = _Overlay(paired=True)
except ImportError:
    from bare_overlay import TidelinkBareOverlay as _Overlay
    _ol = _Overlay(paired=True, skip_load=True)

# Apply role strap from environment if running under fpgahub
_local_role = os.environ.get("FPGAHUB_LOCAL_ROLE")
if _local_role:
    _ol.set_role(_local_role)

from tidelink.pynq_driver import PynqTidelinkDriver
from tidelink.packet import FifoPacket
from tidelink import regs

# ── Address map — Wave B2 paired bitstream (fpga/targets/pynq-z2-pair) ───────
# Source: tidelink_design.tcl assign_bd_address block
# Each physical board exposes a single TideLink instance; A/B are the two boards.
# On a single-FPGA loopback rig both instances share the same address space —
# this layout is kept for documentation; the drivers below use the overlay MMIO.
TL_A_FIFO = 0x4401_0000   # ahb_fifo  — RX FIFO window (64 KB)
TL_A_CFG  = 0x4403_0000   # apb       — config registers (32 KB)
TL_B_FIFO = 0x4401_0000   # (same physical board in pair; remote via GPIO bridge)
TL_B_CFG  = 0x4403_0000   # (remote APB registers accessible via ahb_sub window)

passed = 0
failed = 0


def check(name, condition, msg=""):
    global passed, failed
    if condition:
        print(f"  PASS: {name}")
        passed += 1
    else:
        print(f"  FAIL: {name} — {msg}")
        failed += 1


# ── Setup ────────────────────────────────────────────────────────────────────
# Both drivers address the local instance; in a real paired test each board
# runs this script independently and the GPIO bridge carries the traffic.
tl_a = PynqTidelinkDriver(TL_A_FIFO, TL_A_CFG)
tl_b = PynqTidelinkDriver(TL_B_FIFO, TL_B_CFG)

print("=" * 60)
print("TideLink Loopback Pair Hardware Test")
print("=" * 60)

# ── Test 1: Both instances report MAX_CREDITS ─────────────────────────────────
print("\n[Test 1] Initial credit counts")
credits_a = tl_a.read_credit_count()
credits_b = tl_b.read_credit_count()
check("A credits == MAX_CREDITS", credits_a == regs.MAX_CREDITS,
      f"got {credits_a}")
check("B credits == MAX_CREDITS", credits_b == regs.MAX_CREDITS,
      f"got {credits_b}")

# ── Test 2: Reset doorbell handshake ─────────────────────────────────────────
# After reset, each instance's channel 2 fires a doorbell to the pair.
# The pair responds with its total credit count.
print("\n[Test 2] Reset doorbell handshake")
# Wait for any reset-triggered returner activity to complete
time.sleep(0.01)
tl_a.wait_returner_idle()
tl_b.wait_returner_idle()

# A should have received B's doorbell response at 0x024
doorbell_resp_a = tl_a.cfg_read(regs.REG_DOORBELL_RESP_ACC)
check("A received B's credit count", doorbell_resp_a == regs.MAX_CREDITS,
      f"got {doorbell_resp_a}")

# B should have received A's doorbell response at 0x024
doorbell_resp_b = tl_b.cfg_read(regs.REG_DOORBELL_RESP_ACC)
check("B received A's credit count", doorbell_resp_b == regs.MAX_CREDITS,
      f"got {doorbell_resp_b}")

# ── Test 3: Write packet to A, read back, verify B gets credit delta ──────────
print("\n[Test 3] Credit release flow A->B")
# Set threshold=0 for immediate release
tl_a.cfg_write(regs.REG_REL_THRESHOLD, 0)

# Clear B's released credits accumulator
_ = tl_b.cfg_read(regs.REG_RELEASED_ACC)

pkt_data = [0xDEAD, 0xBEEF, 0xCAFE]
pkt = FifoPacket(data=pkt_data)
tl_a.write_packet(pkt_data)

credits_a_after_write = tl_a.read_credit_count()
expected_credits = regs.MAX_CREDITS - pkt.total_words
check(f"A credits == {expected_credits}", credits_a_after_write == expected_credits,
      f"got {credits_a_after_write}")

read_data = tl_a.read_packet()
tl_a.wait_returner_idle()
time.sleep(0.001)  # Allow returner write to propagate

check("read data matches", read_data == pkt_data,
      f"got {[hex(w) for w in read_data]}")

# B's released credits accumulator should have the delta
released_at_b = tl_b.cfg_read(regs.REG_RELEASED_ACC)
check(f"B received delta == {pkt.total_words}", released_at_b == pkt.total_words,
      f"got {released_at_b}")

# A's credits should be restored
credits_a_after_read = tl_a.read_credit_count()
check("A credits restored", credits_a_after_read == regs.MAX_CREDITS,
      f"got {credits_a_after_read}")

# ── Test 4: Software doorbell A->B ───────────────────────────────────────────
print("\n[Test 4] Software doorbell A->B")
# Clear B's doorbell response accumulator
_ = tl_b.cfg_read(regs.REG_DOORBELL_RESP_ACC)

tl_a.cfg_write(regs.REG_DOORBELL, 1)
tl_a.wait_returner_idle()
time.sleep(0.001)

doorbell_resp_b = tl_b.cfg_read(regs.REG_DOORBELL_RESP_ACC)
check(f"B received A's total credits ({regs.MAX_CREDITS})",
      doorbell_resp_b == regs.MAX_CREDITS,
      f"got {doorbell_resp_b}")

# ── Test 5: Threshold batching ───────────────────────────────────────────────
print("\n[Test 5] Threshold batching")
tl_a.cfg_write(regs.REG_REL_THRESHOLD, 10)

# Clear B's accumulator
_ = tl_b.cfg_read(regs.REG_RELEASED_ACC)

# Write 4 small packets (2 data words each -> delta=3 per read)
packets = [[0xAA00 + i, 0xBB00 + i] for i in range(4)]
for data in packets:
    tl_a.write_packet(data)

# Read 3 packets: acc = 9 < 10
for i in range(3):
    tl_a.read_packet()
    tl_a.wait_returner_idle()
    time.sleep(0.001)

released_before = tl_b.cfg_read(regs.REG_RELEASED_ACC)
check("B accumulator == 0 (below threshold)", released_before == 0,
      f"got {released_before}")

# 4th read: acc = 12 >= 10 -> release
tl_a.read_packet()
tl_a.wait_returner_idle()
time.sleep(0.001)

released_after = tl_b.cfg_read(regs.REG_RELEASED_ACC)
check("B received batched delta == 12", released_after == 12,
      f"got {released_after}")

# ── Test 6: Pair credit counter ───────────────────────────────────────────────
print("\n[Test 6] Pair credit counter")
tl_a.cfg_write(regs.REG_REL_THRESHOLD, 0)

# Reset B's pair credit counter by reading released acc (clears it)
_ = tl_a.cfg_read(regs.REG_PAIR_CREDIT_COUNTER)
# Write and read a packet on B -> B's returner sends delta to A
pkt_data_b = [0x1111, 0x2222]
tl_b.cfg_write(regs.REG_REL_THRESHOLD, 0)
tl_b.write_packet(pkt_data_b)
tl_b.read_packet()
tl_b.wait_returner_idle()
time.sleep(0.001)

# A's pair credit counter should have incremented
pair_ctr = tl_a.cfg_read(regs.REG_PAIR_CREDIT_COUNTER)
expected_ctr = len(pkt_data_b) + 1  # 3
check(f"A pair credit counter == {expected_ctr}", pair_ctr == expected_ctr,
      f"got {pair_ctr}")

# ── Summary ──────────────────────────────────────────────────────────────────
print("\n" + "=" * 60)
print(f"Results: {passed} passed, {failed} failed")
print("=" * 60)
