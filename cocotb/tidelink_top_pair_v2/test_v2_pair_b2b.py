"""V2 BACK-TO-BACK packet-delivery gate.

This is the gate the spaced test_v2_pair_data suite HID: it sends a multi-word
FIFO-data burst with NO inter-word idle gap, so the Wlink LL framer packs the
FC words into back-to-back long packets with no inter-packet idle slot. On the
unfixed V2 RTL the receiver's framer slips at the second packet boundary and
never re-aligns (V2 removed the idle-gated SYNC the V1 path used), so the words
never enqueue in the dst RX FIFO. With the packet-boundary re-alignment fix the
whole burst must land byte-correct.

Run (back-to-back fix gate):
  make EPOCH_PROFILE=zero MODULE=test_v2_pair_b2b
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, send_and_check_b2b,
)

# An 8-word burst — long enough to span several back-to-back LL long packets
# so a single boundary slip corrupts the tail even if the head survives.
BURST_M2S = [0xDA7A0000, 0xCAFEBABE, 0x11112222, 0x33334444,
             0x55556666, 0x77778888, 0x9999AAAA, 0xBBBBCCCC]
BURST_S2M = [0xDEADBEEF, 0x5A17F00D, 0xA0A0B0B0, 0xC0C0D0D0,
             0xE0E0F0F0, 0x01020304, 0x05060708, 0x090A0B0C]


@cocotb.test()
async def test_04_b2b_master_to_slave(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await send_and_check_b2b(tb, "m", "s", BURST_M2S, ctx="m2s-b2b")


@cocotb.test()
async def test_05_b2b_slave_to_master(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    await send_and_check_b2b(tb, "s", "m", BURST_S2M, ctx="s2m-b2b")
