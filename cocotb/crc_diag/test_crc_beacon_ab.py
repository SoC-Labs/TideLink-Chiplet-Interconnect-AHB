"""STEP 2 — the SYNC-beacon hypothesis, and the lane-width (beat-count) axis.

Two candidate explanations for "V2 long DATA packets fail the header CRC":

  H1 (SYNC beacon, d593058): WlinkRxLinkLayer's `sync_resync` used to fire
      unconditionally, synchronously resetting state/word_count/byte_count. A
      beacon landing MID-BODY of a LONG packet therefore aborted the half-parsed
      packet; the remaining body bytes were then mis-parsed as a fresh header.
      SHORT packets are structurally immune (no body). d593058 gates it:
          WlinkRxLinkLayer.v:393  sync_resync_boundary = sync_resync & (state != 2'h1)
      Under SWI_SYNC_FORCE_ALWAYS the beacon fires every 32 words regardless of
      bus idle, so this would mangle long packets repeatedly -> crc_errors
      saturating, which is exactly the reported silicon signature.

  H2 (multi-beat reassembly): a 13-byte long packet needs ceil(13/bytesPerCycle)
      beats. At 8 lanes bytesPerCycle=16 -> ONE beat. At the V2 4-lane mask
      (0xE4) bytesPerCycle=8 -> TWO beats. If the multi-beat path mis-assembles
      the CRC bytes, the CRC would fail only in 4-lane V2 configs.

These tests separate them: H1 is exercised by toggling the beacon at a FIXED
lane width; H2 by changing the lane width with the beacon FIXED.

Every case checks BYTE-EXACT DELIVERY in the same run, so a CRC assertion is
never ambiguous between "the CRC is wrong" and "the link is wrong".
"""
import cocotb
from cocotb.handle import Force
from cocotb.triggers import ClockCycles

from pair_v2_common import make_packet, APB_R8_SLOT0
from crc_common import (
    bringup, drain_rx, enable_crc, CrcMonitor, rd, APB_FC_CRC_ERRORS,
)

R8_SYNC_INSERT_EN    = 1 << 2
R8_SYNC_FORCE_ALWAYS = 1 << 3

ACTIVE_MASK_4LANE = 0xE4      # lanes 2,5,6,7 -- the V2 silicon mask


def ctrl(tb, side):
    return tb.top(side).u_chiplet_controller


async def set_beacon(tb, on):
    """Enable/disable the SYNC beacon in force_always mode on BOTH dies."""
    val = (R8_SYNC_INSERT_EN | R8_SYNC_FORCE_ALWAYS) if on else 0
    for side in ("m", "s"):
        try:
            await tb.apb(side).write(APB_R8_SLOT0, val)
        except Exception:                                    # noqa: BLE001
            pass
    await ClockCycles(tb.dut.hclk, 200)
    st = {}
    for side in ("m", "s"):
        c = ctrl(tb, side)
        st[side] = (rd(c, "swi_sync_insert_en_r"), rd(c, "swi_sync_force_always_r"))
    tb.log.info(f"set_beacon({on}): (insert_en, force_always) = {st}")
    return st


def force_lane_mask(tb, mask):
    """Continuous Force of the lane mask on both dies (same mechanism as
    cocotb/tidelink_top_pair_v2/test_v2_reduced_lane.py)."""
    for side in ("m", "s"):
        wl = tb.top(side).u_chiplet_controller.u_wlink
        wl.swi_tx_lane_mask.value = Force(mask)
        wl.out_prepend_swi_rx_lane_mask.value = Force(mask)


async def _one_case(tb, ctx, payloads, rx="m", tx="s"):
    """Send each payload tx->rx with the CRC live on rx; report delivery + CRC."""
    results = []
    mon = CrcMonitor(tb, rx)
    for payload in payloads:
        await drain_rx(tb, rx)
        mon.start()
        words = make_packet(payload)
        await tb.ahb_tx_write_packet(tx, words)
        await ClockCycles(tb.dut.hclk, 4000)
        mon.stop()
        got = [await tb.ahb_fifo_read_word(rx, i * 4) for i in range(4)]
        ok = all(got[i] == words[i] for i in range(4))
        fired = mon.seen.get("crc_corrupt", 0)
        tb.log.info(f"VERDICT[{ctx}]: delivered={ok} crc_corrupt_cycles={fired} "
                    + mon.report(ctx))
        results.append((ok, fired, mon.crc_errors_max))
    crc_apb = await tb.apb(rx).read(APB_FC_CRC_ERRORS)
    tb.log.info(f"VERDICT[{ctx}_crc_errors_apb]: 0x{crc_apb:x}")
    return results


PAYLOADS = [[0x7E570000 | i, 0xA5000000 | i] for i in range(1, 5)]


@cocotb.test()
async def test_10_beacon_off_crc_on(dut):
    """H1 control: beacon OFF, CRC ON, default 8-lane. Expect clean."""
    tb = await bringup(dut)
    for s in ("m", "s"):
        await enable_crc(tb, s)
    await set_beacon(tb, False)
    res = await _one_case(tb, "beacon_off", PAYLOADS)
    assert all(ok for ok, _, _ in res), "beacon OFF: delivery broke"
    fired = sum(f for _, f, _ in res)
    tb.log.info(f"VERDICT[H1_control]: beacon OFF -> total crc_corrupt cycles={fired}")


@cocotb.test()
async def test_11_beacon_force_always_crc_on(dut):
    """H1 under test: beacon FORCED ALWAYS (fires every 32 words regardless of
    idle), CRC ON. With d593058's sync_resync_boundary guard present this should
    stay clean; without it, long packets get aborted mid-body."""
    tb = await bringup(dut)
    for s in ("m", "s"):
        await enable_crc(tb, s)
    st = await set_beacon(tb, True)
    if all(v == (0, 0) for v in st.values()):
        tb.log.warning("VERDICT[H1_beacon_NOT_ARMED]: could not arm the beacon "
                       "over APB -- this case proves NOTHING about H1.")
    res = await _one_case(tb, "beacon_force_always", PAYLOADS)
    fired = sum(f for _, f, _ in res)
    delivered = all(ok for ok, _, _ in res)
    tb.log.info(f"VERDICT[H1_result]: beacon FORCE_ALWAYS -> delivered_all="
                f"{delivered} total crc_corrupt cycles={fired}")


@cocotb.test()
async def test_12_four_lane_crc_on(dut):
    """H2 under test: V2 4-lane mask 0xE4 -> bytesPerCycle=8 -> a 13-byte long
    packet spans TWO beats. CRC ON, beacon OFF, so the ONLY variable vs
    test_10 is the beat count."""
    tb = await bringup(dut)
    force_lane_mask(tb, ACTIVE_MASK_4LANE)
    await ClockCycles(dut.hclk, 2000)
    for s in ("m", "s"):
        await enable_crc(tb, s)
    await set_beacon(tb, False)
    res = await _one_case(tb, "four_lane", PAYLOADS)
    fired = sum(f for _, f, _ in res)
    delivered = all(ok for ok, _, _ in res)
    tb.log.info(f"VERDICT[H2_result]: 4-lane (2-beat) -> delivered_all={delivered} "
                f"total crc_corrupt cycles={fired}")


@cocotb.test()
async def test_13_four_lane_beacon_force_always(dut):
    """Both axes together -- the closest match to the V2 silicon configuration
    that reported the failure."""
    tb = await bringup(dut)
    force_lane_mask(tb, ACTIVE_MASK_4LANE)
    await ClockCycles(dut.hclk, 2000)
    for s in ("m", "s"):
        await enable_crc(tb, s)
    await set_beacon(tb, True)
    res = await _one_case(tb, "four_lane_beacon", PAYLOADS)
    fired = sum(f for _, f, _ in res)
    delivered = all(ok for ok, _, _ in res)
    tb.log.info(f"VERDICT[H1H2_result]: 4-lane + FORCE_ALWAYS -> delivered_all="
                f"{delivered} total crc_corrupt cycles={fired}")
