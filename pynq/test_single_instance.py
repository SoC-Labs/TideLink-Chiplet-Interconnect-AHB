"""PYNQ hardware test for a single TideLink instance.

The Zynq PS acts as both the software controller and the "pair" —
it writes packets into the FIFO, reads them back, and inspects the
returner's AHB master writes via a PS-readable BRAM.

Usage (on Pynq-Z2):
    exec(open("test_single_instance.py").read())

Address map targets the Wave B1 single-instance bitstream
(fpga/targets/pynq-z2-single/tidelink_design.tcl).
"""

try:
    from overlay import TidelinkOverlay as _Overlay
    _ol = _Overlay(paired=False)
    _mmio_cls = _ol.ahb_sub.__class__  # pynq.MMIO
except ImportError:
    from bare_overlay import TidelinkBareOverlay as _Overlay, BareMMIO as _mmio_cls
    _ol = _Overlay(paired=False, skip_load=True)

from tidelink.pynq_driver import PynqTidelinkDriver
from tidelink.packet import FifoPacket
from tidelink import regs

# ── Address map — Wave B1 single-instance (fpga/targets/pynq-z2-single) ──────
# Source: tidelink_design.tcl assign_bd_address block
FIFO_BASE          = 0x4401_0000   # ahb_fifo — RX FIFO window (64 KB)
CFG_BASE           = 0x4403_0000   # apb      — unified config registers (32 KB)
RETURNER_BRAM_BASE = 0x4400_0000   # ahb_tx   — TX aperture used as returner capture
RETURNER_BRAM_SIZE = 0x1000

# Returner target addresses (pair_base defaults to 0)
PAIR_RELEASED_CREDITS_ADDR   = 0x020
PAIR_DOORBELL_RESPONSE_ADDR = 0x024

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
tl = PynqTidelinkDriver(FIFO_BASE, CFG_BASE)
returner_bram = _ol.ahb_tx  # re-use already-open MMIO from overlay

print("=" * 60)
print("TideLink Single Instance Hardware Test")
print("=" * 60)

# ── Test 1: Credit count after reset ──────────────────────────────────────────
print("\n[Test 1] Credit count after reset")
credits = tl.read_credit_count()
check("credit count == MAX_CREDITS", credits == regs.MAX_CREDITS,
      f"got {credits}, expected {regs.MAX_CREDITS}")

# ── Test 2: Release threshold default ────────────────────────────────────────
print("\n[Test 2] Release threshold default")
threshold = tl.cfg_read(regs.REG_REL_THRESHOLD)
check("threshold == 20", threshold == 20, f"got {threshold}")

# ── Test 3: Release threshold R/W ────────────────────────────────────────────
print("\n[Test 3] Release threshold R/W")
tl.cfg_write(regs.REG_REL_THRESHOLD, 50)
readback = tl.cfg_read(regs.REG_REL_THRESHOLD)
check("threshold readback == 50", readback == 50, f"got {readback}")
tl.cfg_write(regs.REG_REL_THRESHOLD, 0)  # Set to immediate for remaining tests

# ── Test 4: Pair base address default ────────────────────────────────────────
print("\n[Test 4] Pair base address default")
pair_base = tl.cfg_read(regs.REG_PAIR_BASE)
check("pair base == 0", pair_base == 0, f"got 0x{pair_base:08X}")

# ── Test 5: FIFO write and credit decrement ───────────────────────────────────
print("\n[Test 5] FIFO write and credit decrement")
pkt_data = [0xAAAA_0001, 0xAAAA_0002, 0xAAAA_0003]
pkt = FifoPacket(data=pkt_data)
tl.write_packet(pkt_data)
credits_after_write = tl.read_credit_count()
expected = regs.MAX_CREDITS - pkt.total_words
check(f"credits == {expected}", credits_after_write == expected,
      f"got {credits_after_write}")

# ── Test 6: FIFO read and returner delta ─────────────────────────────────────
print("\n[Test 6] FIFO read and returner delta")
# Clear the returner BRAM target
returner_bram.write(PAIR_RELEASED_CREDITS_ADDR, 0)

read_data = tl.read_packet()
tl.wait_returner_idle()

check("read data matches written", read_data == pkt_data,
      f"got {[hex(w) for w in read_data]}")

returner_delta = returner_bram.read(PAIR_RELEASED_CREDITS_ADDR)
check(f"returner delta == {pkt.total_words}", returner_delta == pkt.total_words,
      f"got {returner_delta}")

# ── Test 7: Credits restored after read ───────────────────────────────────────
print("\n[Test 7] Credits restored after read")
credits_after_read = tl.read_credit_count()
check("credits == MAX_CREDITS", credits_after_read == regs.MAX_CREDITS,
      f"got {credits_after_read}")

# ── Test 8: Doorbell triggers returner ───────────────────────────────────────
print("\n[Test 8] Doorbell triggers returner")
returner_bram.write(PAIR_DOORBELL_RESPONSE_ADDR, 0)
tl.cfg_write(regs.REG_DOORBELL, 1)
tl.wait_returner_idle()
doorbell_resp = returner_bram.read(PAIR_DOORBELL_RESPONSE_ADDR)
check(f"doorbell wrote credit count {regs.MAX_CREDITS}",
      doorbell_resp == regs.MAX_CREDITS,
      f"got {doorbell_resp}")

# ── Test 9: Accumulator W-add / R-clear ──────────────────────────────────────
print("\n[Test 9] Accumulator W-add / R-clear")
tl.cfg_write(regs.REG_RELEASED_ACC, 10)
tl.cfg_write(regs.REG_RELEASED_ACC, 25)
acc_val = tl.cfg_read(regs.REG_RELEASED_ACC)
check("accumulator == 35", acc_val == 35, f"got {acc_val}")
acc_val2 = tl.cfg_read(regs.REG_RELEASED_ACC)
check("accumulator cleared to 0", acc_val2 == 0, f"got {acc_val2}")

# ── Summary ──────────────────────────────────────────────────────────────────
print("\n" + "=" * 60)
print(f"Results: {passed} passed, {failed} failed")
print("=" * 60)
