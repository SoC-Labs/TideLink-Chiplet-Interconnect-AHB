"""PROBE (transient — root-cause confirmation): with SYNC insertion ENABLED,
is the full-128 sync_detected in WlinkRxLinkLayer.v:321 DEAD under mask 0xE4
while it is ALIVE under 0xFF?

This isolates the root cause WITHOUT needing a framer slip: drive the master
to insert SYNC beacons (force_always), and on the slave RX, sample the
full-128 `sync_detected` (the strip+rehunt driver) vs the PHY's mask-aware
detector count (0x2124). Under 0xE4 the masked lanes are zeroed on the wire so
the full-128 compare can never equal SYNC_WORD -> sync_detected dead; the PHY
mask-aware detector still fires. Under 0xFF both fire.

    make EPOCH_PROFILE=zero MODULE=test_v2_sync_mask_probe
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from pair_v2_common import PairV2TB, run_bringup_full, APB_R8_SLOT0, APB_TIDELINK_BASE
from test_v2_reduced_lane import bringup_reduced, ACTIVE_MASK
from test_v2_sync_insert_en import (
    R8_SLOT0_SYNC_EN, R8_SLOT0_SYNC_FORCE_ALWAYS,
    APB_SYNC_DETECT2, SYNC2_SEEN_CNT, SYNC2_SEEN_LANE,
    APB_SYNC_LANE_MASK,
)

FULL_MASK = 0xFF


async def _probe(tb, mask):
    if mask == FULL_MASK:
        await run_bringup_full(tb)
    else:
        await bringup_reduced(tb, mask)
    assert await tb.wait_cr_crack(), f"mask 0x{mask:02x}: no CR/CRACK"

    # Tell the slave's PHY mask-aware SYNC detector which lanes are in (0x2128).
    await tb.s_apb.write(APB_SYNC_LANE_MASK, mask)

    # Master beacons every word (force_always) so the slave RX sees SYNC often.
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_SYNC_FORCE_ALWAYS)

    llrx = tb.top("s").u_chiplet_controller.u_wlink.llrx
    full128_pulses = 0
    for _ in range(32 * 64):
        await RisingEdge(llrx.clock)
        try:
            if int(llrx.sync_detected.value) == 1:
                full128_pulses += 1
        except ValueError:
            pass

    d = await tb.s_apb.read(APB_SYNC_DETECT2)
    mask_cnt = SYNC2_SEEN_CNT(d)
    mask_lane = SYNC2_SEEN_LANE(d)
    tb.log.info(
        f"  [mask=0x{mask:02x}] full128 sync_detected pulses (WlinkRxLinkLayer:321) "
        f"= {full128_pulses} ;  PHY mask-aware detector @0x2124 cnt={mask_cnt} "
        f"lane=0x{mask_lane:02x}")
    return full128_pulses, mask_cnt, mask_lane


@cocotb.test()
async def test_full128_alive_under_0xFF(dut):
    tb = PairV2TB(dut)
    f, c, lane = await _probe(tb, FULL_MASK)
    assert f > 0, ("full-128 sync_detected NEVER pulsed under 0xFF — SYNC not "
                   "reaching the slave RX framer at all (harness assumption wrong)")
    assert c > 0, "PHY mask-aware detector count 0 under 0xFF"


# NOTE: with the MASK-AWARE FIX in WlinkRxLinkLayer.v, sync_detected is no longer
# the full-128 equality — under 0xE4 it now compares only the active-lane slices
# and SHOULD fire. The env var SYNC_DETECTED_EXPECT selects the assertion:
#   before fix: SYNC_DETECTED_EXPECT=dead  (sync_detected pulses == 0 under 0xE4)
#   after  fix: SYNC_DETECTED_EXPECT=alive (sync_detected pulses  > 0 under 0xE4)
import os
EXPECT = os.environ.get("SYNC_DETECTED_EXPECT", "alive")


@cocotb.test()
async def test_sync_detected_under_0xE4(dut):
    tb = PairV2TB(dut)
    f, c, lane = await _probe(tb, ACTIVE_MASK)
    tb.log.info(f"ROOT CAUSE / FIX: sync_detected pulses under 0xE4 = {f} "
                f"(expect '{EXPECT}'); PHY mask-aware cnt = {c} lane=0x{lane:02x}")
    if EXPECT == "dead":
        assert f == 0, (f"sync_detected pulsed {f}x under 0xE4 with the FULL-128 "
                        f"compare — root cause wrong (expected DEAD)")
    else:
        assert f > 0, (f"sync_detected did NOT pulse under 0xE4 after the mask-aware "
                       f"fix (got {f}) — the fix did not revive the active-lane match")
        assert f == c, (f"mask-aware sync_detected ({f}) != PHY mask-aware detector "
                        f"count ({c}) under 0xE4 — fixed framer compare disagrees "
                        f"with the proven PHY detector")
