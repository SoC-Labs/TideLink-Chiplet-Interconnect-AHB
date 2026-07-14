"""DELIVERABLE A — the 0044bef serialiser-drain-guard defect class, in sim.

0044bef restored V1's guard on the idle-gated SYNC beacon:
    tx_sync_en_w = insert_en & (force_always | (tx_idle & (postcount==0)))
                                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
The claim: WlinkTxLinkLayer asserts io_link_tx_tx_idle BEFORE the GPIO serialiser
has finished shifting the tail of the last packet, so an idle-gated beacon fired
in that window OVERWRITES the packet tail (silicon: R8=0x14 => filt 25/28, rot-1).

This test is the A/B the commit said "sim CANNOT prove":
  * enable the PERMANENT autonomous data-mode state: idle-gated beacons on the
    sender (insert_en=1, robust=1, force_always=0 — R8=0x14-equivalent);
  * send many distinct packets, SWEEPING the packet->idle alignment against the
    free-running SYNC period counter so a beacon boundary lands in the tail-
    flush window across many phases;
  * byte-check every delivered packet.

Acceptance:
  - guard IN  (0044bef): PASS  (byte-exact both directions).
  - guard OUT (reverted): FAIL  (corrupted / short packets).

A tail-overlap monitor counts beacons that fire within the drain window
(io_link_tx_tx_idle rose <=DRAIN cycles ago) so a PASS is never vacuous: the
run reports how many beacons actually hit the window under test.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_beacon_drain_corruption
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_R8_SLOT0, APB_TIDELINK_BASE,
)

R8_SLOT0_SYNC_EN       = 0x4    # bit[2] insert_en
R8_SLOT0_ROBUST_DETECT = 0x10   # bit[4] robust

# Wlink swi_delay_cycles (HW 0x4403_0230 -> unified APB 0x0230). POR 0 in the
# local override (PSTATE FSM disabled). A nonzero value re-enables the TX
# P-state machine so tx_en pulses after idle => the GPIO postcount actually
# DRAINS (postcount 7->0), i.e. the genuine transient the guard predicate keys
# on. Optional lever; the test sweeps with it both 0 and small.
APB_WL_SWI_DELAY_CYCLES = 0x0230


def gpio(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.phy.gpio


async def tail_overlap_monitor(tb, side, stats, drain=8):
    """Count beacons (tx_sync_inserting_w) that fire while the TX just went idle
    after carrying payload — the drain window under test. `since_active`
    counts link cycles since io_link_tx_tx_idle last rose from 0 (payload->idle
    edge). A beacon with since_active <= drain overwrites the flushing tail."""
    g = gpio(tb, side)
    prev_idle = 1
    since_active = 10 ** 9
    while True:
        await RisingEdge(g.io_link_tx_tx_link_clk)
        try:
            idle = int(g.io_link_tx_tx_idle.value)
            post = int(g.postcount.value)
            beacon = int(g.tx_sync_inserting_w.value)
        except ValueError:
            continue
        if idle == 0:
            since_active = 0            # payload on the bus this cycle
        else:
            since_active += 1
            if prev_idle == 0:
                stats["payload_idle_edges"] += 1
        prev_idle = idle
        if beacon:
            stats["beacons"] += 1
            if since_active <= drain:
                stats["beacon_tail_overlap"] += 1
            if post != 0:
                stats["beacon_postcount_nz"] += 1
        stats["post_min"] = min(stats["post_min"], post)


async def drain_rx(tb, dst, nwords):
    return [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(nwords)]


@cocotb.test()
async def test_beacon_drain_corruption(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"

    # PERMANENT autonomous data-mode state on the MASTER (the m->s beacon TX).
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_ROBUST_DETECT)
    rb = await tb.m_apb.read(APB_R8_SLOT0)
    assert (rb >> 2) & 1 == 1, f"insert_en not set (R8=0x{rb:x})"
    tb.log.info(f"master R8_SLOT0=0x{rb:08x} insert_en=1 robust={(rb>>4)&1} "
                f"force_always={(rb>>3)&1} (R8=0x14-equivalent, idle-gated)")

    # Optional: re-enable the TX P-state FSM so tx_en pulses after idle and the
    # GPIO postcount actually DRAINS 7->0 (postcount==0 in true LP idle). With
    # this >0, the guard permits data-safe beacons in genuine idle AND still
    # blocks the drain-window ones — the faithful A/B. POR override pins it 0.
    # Default 8: PSTATE ON. This is REQUIRED for a FAITHFUL A/B — with the POR
    # value 0 the FSM never runs, tx_en is pinned high, postcount is pinned at 7
    # (never 0), so the guard suppresses EVERY idle beacon and the guard-IN
    # "pass" is vacuous (0 beacons). With PSTATE on, postcount drains to 0 in
    # true LP idle so the guard PERMITS data-safe beacons there (postcount==0)
    # and blocks ONLY the drain-window ones (postcount!=0) — the fix's intent.
    # It is a plain SW APB write to an existing runtime register, not a hook.
    swi_delay = int(os.environ.get("TB_SWI_DELAY", "8"))
    if swi_delay:
        await tb.m_apb.write(APB_WL_SWI_DELAY_CYCLES, swi_delay)
        rd = await tb.m_apb.read(APB_WL_SWI_DELAY_CYCLES)
        tb.log.info(f"master swi_delay_cycles set -> 0x{rd & 0xFFFF:x} "
                    f"(PSTATE FSM re-enabled; postcount will drain)")

    stats = dict(beacons=0, beacon_tail_overlap=0, beacon_postcount_nz=0,
                 payload_idle_edges=0, post_min=255)
    cocotb.start_soon(tail_overlap_monitor(tb, "m", stats))

    # Sweep the packet->idle alignment against the mod-32 SYNC counter: step the
    # inter-packet spacing by 1 hclk each iter so the payload tail walks through
    # all 32 counter phases; a beacon boundary must eventually land in the flush
    # window on SOME packet if the window is reachable.
    NPKT = 40
    mism = []            # (idx, expected, got)
    delivered = 0
    for k in range(NPKT):
        payload = [0xDA7A0000 | (k << 4), 0xCAFE0000 | k]
        words = make_packet(payload)              # [hdr, 0, p0, p1]
        await tb.ahb_tx_write_packet("m", words, gap=2)
        # alignment sweep: 3..3+31 hclk of settle before the next packet
        await ClockCycles(dut.hclk, 300 + k)
        got = await drain_rx(tb, "s", 4)
        ok = (got[0] == words[0] and got[2] == payload[0] and got[3] == payload[1])
        if ok:
            delivered += 1
        else:
            mism.append((k, [f"0x{w:08x}" for w in words],
                         [f"0x{w:08x}" for w in got]))

    tb.log.info(f"MONITOR: beacons={stats['beacons']} "
                f"tail_overlap={stats['beacon_tail_overlap']} "
                f"postcount_nz_at_beacon={stats['beacon_postcount_nz']} "
                f"payload->idle edges={stats['payload_idle_edges']} "
                f"post_min={stats['post_min']}")
    tb.log.info(f"DELIVERY: {delivered}/{NPKT} packets byte-exact; "
                f"{len(mism)} mismatches")
    for idx, exp, got in mism[:12]:
        tb.log.info(f"  MISMATCH pkt {idx}: sent={exp} got={got}")

    # --- non-vacuity: beacons MUST have fired, or this is a NON-RESULT --------
    # (With PSTATE off, the guard suppresses every beacon and a 40/40 "pass"
    #  would prove nothing. The default swi_delay=8 makes postcount reach 0 so
    #  beacons fire in genuine idle even WITH the guard.)
    assert stats["beacons"] > 0, (
        "NO beacons fired at all — idle-gated beacon never triggered. This is "
        "a NON-RESULT (drain window not exercised). Set TB_SWI_DELAY>0 so "
        "postcount drains and beacons can fire in true idle.")

    # --- the A/B discriminator -----------------------------------------------
    # guard IN (0044bef): every beacon fires with postcount==0 (safe idle);
    #                     ZERO fire in the drain window; data byte-exact.
    # guard OUT (revert): beacons ALSO fire with postcount!=0 (drain window)
    #                     and overwrite packet tails -> corruption.
    assert stats["beacon_postcount_nz"] == 0, (
        f"{stats['beacon_postcount_nz']} beacon(s) fired while postcount!=0 "
        f"(the serialiser-drain window) — the 0044bef guard is NOT in effect "
        f"(this is the reverted-RTL signature; expect data corruption below)")
    assert not mism, (
        f"{len(mism)}/{NPKT} packets corrupted under idle-gated beacons "
        f"(drain-window beacons={stats['beacon_postcount_nz']}, "
        f"tail_overlap={stats['beacon_tail_overlap']}) — the serialiser-drain "
        f"defect class reproduced")
    tb.log.info(
        f"VERDICT: PASS — {stats['beacons']} idle-gated beacons fired (all with "
        f"postcount==0, {stats['beacon_tail_overlap']} in the drain window), "
        f"{delivered}/{NPKT} packets byte-exact: the 0044bef drain guard makes "
        f"idle-gated beacons data-safe.")
