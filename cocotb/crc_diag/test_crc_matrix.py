"""STEP 5 — the clean 2x2 matrix, on the established send/check pattern.

BENCH HISTORY (kept deliberately, it is the main lesson of this investigation):
earlier revisions of this bench pre-drained the RX FIFO with more reads than the
packet contained. Reading an EMPTY RX FIFO pops a PHANTOM zero-length packet
that walks read_ptr by 2 words
(project_rxfifo_empty_read_phantom_pop_2026_07_14), which desyncs the read
pointer and wedges the FIFO from the second packet onward. That wedge looked
exactly like per-packet link corruption and produced TWO false mechanisms
before it was caught by an A/B that turned the beacon OFF and saw the failures
persist. All results from those revisions are VOID.

This revision uses `send_and_check` from pair_v2_common -- the same helper the
shipping V2 pair tests use -- which does no draining at all, and it does a
FRESH BRING-UP per cell so no cell can contaminate another.

The 2x2 under test (CRC re-ENABLED on both dies in every cell):

                     beacon OFF     beacon FORCE_ALWAYS
    8 lanes (1 beat)    cell A            cell B
    4 lanes (2 beats)   cell C            cell D      <- the V2 silicon config

Silicon runs cell D: the V2 lane mask is 0xE4 (4 lanes) and the documented
bring-up recipe writes R8 = 0x1C, which sets bit[2] sync_insert_en AND bit[3]
sync_force_always.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import send_and_check
from crc_common import bringup, enable_crc, CrcMonitor, APB_FC_CRC_ERRORS
from test_crc_beacon_ab import set_beacon, force_lane_mask, ACTIVE_MASK_4LANE

N = 3   # packets per cell, no draining between them


async def _cell(dut, name, lanes8, beacon):
    tb = await bringup(dut)
    if not lanes8:
        force_lane_mask(tb, ACTIVE_MASK_4LANE)
        await ClockCycles(dut.hclk, 2000)
    for s in ("m", "s"):
        await enable_crc(tb, s)
    await set_beacon(tb, beacon)

    mon = CrcMonitor(tb, "m")
    mon.start()
    oks = []
    for i in range(N):
        ok, got = await send_and_check(
            tb, "s", "m", [0x7E570000 | i, 0xA5000000 | i],
            f"{name}#{i}", expect_pass=False)
        oks.append(ok)
    mon.stop()
    crc_apb = await tb.apb("m").read(APB_FC_CRC_ERRORS)

    tb.log.info(f"VERDICT[cell_{name}]: lanes={'8' if lanes8 else '4'} "
                f"beacon={'FORCE_ALWAYS' if beacon else 'OFF'} "
                f"delivered={sum(oks)}/{N} "
                f"crc_corrupt_cycles={mon.seen.get('crc_corrupt', 0)} "
                f"crc_errors_apb=0x{crc_apb:x} | {mon.report(name)}")
    return sum(oks), mon.seen.get("crc_corrupt", 0)


@cocotb.test()
async def test_40_cellA_8lane_beacon_off(dut):
    ok, fired = await _cell(dut, "A_8lane_beaconOFF", True, False)
    assert ok == N, "cell A: 8-lane beacon-off must deliver every packet"
    assert fired == 0, "cell A: CRC fired on known-good 8-lane traffic"


@cocotb.test()
async def test_41_cellB_8lane_beacon_on(dut):
    await _cell(dut, "B_8lane_beaconFORCE", True, True)


@cocotb.test()
async def test_42_cellC_4lane_beacon_off(dut):
    await _cell(dut, "C_4lane_beaconOFF", False, False)


@cocotb.test()
async def test_43_cellD_4lane_beacon_on(dut):
    """The V2 silicon configuration."""
    await _cell(dut, "D_4lane_beaconFORCE", False, True)
