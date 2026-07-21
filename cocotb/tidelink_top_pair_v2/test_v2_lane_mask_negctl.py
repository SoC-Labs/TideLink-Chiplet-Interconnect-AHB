"""NEGATIVE CONTROL for test_v2_lane_mask_sweep — proves the sweep can go RED.

The sweep passes at 0xFF, 0xE4 AND 0xE5. Before that green can be believed, the
instrument must be shown to be capable of failing. This module injects two
KNOWN-BAD conditions and asserts the byte-exact oracle DETECTS them:

  test_01_asym_mask   — the TX packs for K=popcount(tx_mask) but the RX gathers
                        for K'=popcount(rx_mask). With tx=0xE5 (K=5) vs rx=0xE4
                        (K'=4) the byte geometry disagrees, so the payload MUST
                        be corrupt. If this "passes", the lane-mask Force never
                        reached the datapath and the whole sweep is worthless.

  test_02_lane_drop   — the RX mask drops a lane the TX is actively packing onto
                        (tx=0xE5, rx=0xE1: lane 2 dropped). The gather loses a
                        byte column. MUST be corrupt.

A green run of THIS module means: the masks reach the DUT, the masks change the
byte geometry, and the oracle notices. Only then does a green sweep mean
anything.
"""
import cocotb
from cocotb.handle import Force
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, make_packet

PAYLOAD = [0xCAFE0001, 0xCAFE0002]


def _wlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink


def force_split_mask(tb, tx_mask, rx_mask):
    """Force a DELIBERATELY INCONSISTENT mask pair on both dies."""
    for side in ("m", "s"):
        wl = _wlink(tb, side)
        wl.swi_tx_lane_mask.value = Force(tx_mask)
        wl.out_prepend_swi_rx_lane_mask.value = Force(rx_mask)


async def _run_split(tb, tx_mask, rx_mask, ctx):
    await tb.reset()
    force_split_mask(tb, tx_mask, rx_mask)
    await ClockCycles(tb.dut.hclk, 50)
    force_split_mask(tb, tx_mask, rx_mask)
    tb.log.info(f"  [{ctx}] tx_mask=0x{tx_mask:02X} (K={bin(tx_mask).count('1')}) "
                f"rx_mask=0x{rx_mask:02X} (K'={bin(rx_mask).count('1')})")
    await run_bringup_full(tb)
    await tb.wait_cr_crack()
    await ClockCycles(tb.dut.hclk, 500)

    words = make_packet(PAYLOAD)
    await tb.ahb_tx_write_packet("m", words)
    await ClockCycles(tb.dut.hclk, 3000)
    got = [await tb.ahb_fifo_read_word("s", i * 4) for i in range(4)]
    ok = all(got[i] == words[i] for i in range(4))
    tb.log.info(f"  [{ctx}] sent=[{', '.join(f'0x{w:08x}' for w in words)}] "
                f"rx=[{', '.join(f'0x{w:08x}' for w in got)}] -> "
                f"{'BYTE-EXACT (BAD! should be corrupt)' if ok else 'CORRUPT (expected)'}")
    return ok, got, words


@cocotb.test()
async def test_01_asym_mask_must_corrupt(dut):
    """tx K=5 vs rx K'=4 — mismatched byte geometry MUST corrupt the payload."""
    tb = PairV2TB(dut)
    ok, got, words = await _run_split(tb, 0xE5, 0xE4, ctx="negctl-asym")
    assert not ok, (
        "INSTRUMENT FAULT: a TX packing for K=5 was received byte-exact by an "
        "RX gathering for K'=4. That is geometrically impossible — the lane "
        "mask is NOT reaching the datapath, so every green in "
        "test_v2_lane_mask_sweep is meaningless.")


@cocotb.test()
async def test_02_rx_drops_active_lane_must_corrupt(dut):
    """RX mask drops lane 2, which the TX is packing onto. MUST corrupt."""
    tb = PairV2TB(dut)
    ok, got, words = await _run_split(tb, 0xE5, 0xE1, ctx="negctl-drop2")
    assert not ok, (
        "INSTRUMENT FAULT: the RX gathered a byte-exact packet while masking "
        "off lane 2 that the TX was actively driving. The mask is not gating "
        "the RX datapath.")
