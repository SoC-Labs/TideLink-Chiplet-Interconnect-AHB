"""DELIVERABLE A — the 0044bef serialiser-drain-guard defect class, in sim,
BIDIRECTIONAL, with concurrent FC traffic + idle-gated beacons on BOTH dies.

0044bef restored V1's guard on the idle-gated SYNC beacon:
    tx_sync_en_w = insert_en & (force_always | (tx_idle & (postcount==0)))
                                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
The claim: WlinkTxLinkLayer asserts io_link_tx_tx_idle BEFORE the GPIO serialiser
has finished shifting the tail of the last packet, so an idle-gated beacon fired
in that window OVERWRITES the packet tail (silicon: R8=0x14 => filt 25/28, rot-1).

This test is the A/B the commit said "sim CANNOT prove":
  * PERMANENT autonomous data-mode state on BOTH dies (insert_en=1, robust=1,
    force_always=0 — R8=0x14-equivalent), so master beacons ride the m->s TX
    and slave beacons ride the s->m TX;
  * send packets in BOTH directions with CONCURRENT overlap, SWEEPING the
    packet->idle alignment against the free-running SYNC period counter;
  * byte-check every delivered packet, PER DIRECTION.

Acceptance (guard reverted must FAIL, guard-in must PASS — proven both ways):
  - guard IN  (0044bef): PASS  (byte-exact both directions).
  - guard OUT (reverted): FAIL  (corrupted / short packets).

Silicon follow-up (coordinator 2026-07-14): the guard-in bitstream is only
PARTIALLY effective — A->B 6/9 but B->A 0/9 (slave->master hard-dead) under
R8=0x14 both dies. So this test ALSO reports per-direction delivery WITH the
guard in, and instruments the RX re-hunt (WlinkRxLinkLayer sync_resync /
sync_resync_boundary) on each receiver to look for a residual s->m mechanism
the TX guard does not cover.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_beacon_drain_corruption
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, make_packet, APB_R8_SLOT0,
)

R8_SLOT0_SYNC_EN       = 0x4    # bit[2] insert_en
R8_SLOT0_ROBUST_DETECT = 0x10   # bit[4] robust
APB_WL_SWI_DELAY_CYCLES = 0x0230  # Wlink swi_delay_cycles (HW 0x4403_0230)


def gpio(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.phy.gpio


def llrx(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.llrx


async def tx_tail_monitor(tb, side, stats, drain=8):
    """Per-die TX beacon/drain-window monitor (the sender's gpio)."""
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
            since_active = 0
        else:
            since_active += 1
        prev_idle = idle
        if beacon:
            stats["beacons"] += 1
            if since_active <= drain:
                stats["beacon_tail_overlap"] += 1
            if post != 0:
                stats["beacon_postcount_nz"] += 1
        stats["post_min"] = min(stats["post_min"], post)


async def rx_rehunt_monitor(tb, side, stats):
    """Per-die RX re-hunt monitor (the receiver's WlinkRxLinkLayer). Counts
    sync_resync firings and how often the raw sync_resync wants to fire while
    the framer is MID-LONG-PACKET (state==1) — the window the boundary guard
    suppresses. A residual mechanism would show as resync activity correlated
    with a dropped packet."""
    r = llrx(tb, side)
    while True:
        await RisingEdge(r.clock)
        try:
            st = int(r.state.value)
            rs = int(r.sync_resync.value)
            rsb = int(r.sync_resync_boundary.value)
            sd = int(r.sync_detected.value)
            rob = int(r.io_robust_sync_seen.value)
        except (ValueError, AttributeError):
            continue
        if rs:
            stats["sync_resync"] += 1
            if st == 1:
                stats["resync_midpacket_raw"] += 1   # blocked by boundary guard
        if rsb:
            stats["resync_boundary"] += 1
        if sd:
            stats["sync_detected"] += 1
        if rob:
            stats["robust_seen"] += 1


async def drain_rx(tb, dst, nwords):
    return [await tb.ahb_fifo_read_word(dst, i * 4) for i in range(nwords)]


async def _enable_die(tb, side, swi_delay):
    apb = tb.apb(side)
    await apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_ROBUST_DETECT)
    rb = await apb.read(APB_R8_SLOT0)
    assert (rb >> 2) & 1 == 1, f"{side}: insert_en not set (R8=0x{rb:x})"
    if swi_delay:
        await apb.write(APB_WL_SWI_DELAY_CYCLES, swi_delay)
    tb.log.info(f"[{side}] R8_SLOT0=0x{rb:08x} insert_en=1 robust={(rb>>4)&1} "
                f"force_always={(rb>>3)&1} swi_delay={swi_delay} (R8=0x14-equiv)")


@cocotb.test()
async def test_beacon_drain_corruption_bidir(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"

    # PERMANENT autonomous data-mode state on BOTH dies + PSTATE on (so postcount
    # actually drains to 0 in true idle — a plain SW APB write, not a hook).
    swi_delay = int(os.environ.get("TB_SWI_DELAY", "8"))
    await _enable_die(tb, "m", swi_delay)
    await _enable_die(tb, "s", swi_delay)

    tx_m = dict(beacons=0, beacon_tail_overlap=0, beacon_postcount_nz=0, post_min=255)
    tx_s = dict(beacons=0, beacon_tail_overlap=0, beacon_postcount_nz=0, post_min=255)
    rx_m = dict(sync_resync=0, resync_midpacket_raw=0, resync_boundary=0,
                sync_detected=0, robust_seen=0)
    rx_s = dict(sync_resync=0, resync_midpacket_raw=0, resync_boundary=0,
                sync_detected=0, robust_seen=0)
    cocotb.start_soon(tx_tail_monitor(tb, "m", tx_m))
    cocotb.start_soon(tx_tail_monitor(tb, "s", tx_s))
    cocotb.start_soon(rx_rehunt_monitor(tb, "m", rx_m))
    cocotb.start_soon(rx_rehunt_monitor(tb, "s", rx_s))

    NPKT = 24
    res = {"m2s": dict(ok=0, mism=[]), "s2m": dict(ok=0, mism=[])}

    for k in range(NPKT):
        # distinct payloads per direction so a cross-direction leak is visible.
        p_m2s = [0xDA7A0000 | (k << 4), 0xCAFE0000 | k]
        p_s2m = [0xB0BA0000 | (k << 4), 0x5A5A0000 | k]
        w_m2s = make_packet(p_m2s)
        w_s2m = make_packet(p_s2m)

        # CONCURRENT: launch both TX sends overlapping (both dies beaconing).
        t_m = cocotb.start_soon(tb.ahb_tx_write_packet("m", w_m2s, gap=2))
        t_s = cocotb.start_soon(tb.ahb_tx_write_packet("s", w_s2m, gap=2))
        await t_m
        await t_s
        await ClockCycles(dut.hclk, 300 + k)     # alignment sweep

        got_s = await drain_rx(tb, "s", 4)       # m->s lands in SLAVE RX FIFO
        got_m = await drain_rx(tb, "m", 4)       # s->m lands in MASTER RX FIFO

        ok_m2s = (got_s[0] == w_m2s[0] and got_s[2] == p_m2s[0] and got_s[3] == p_m2s[1])
        ok_s2m = (got_m[0] == w_s2m[0] and got_m[2] == p_s2m[0] and got_m[3] == p_s2m[1])
        if ok_m2s:
            res["m2s"]["ok"] += 1
        else:
            res["m2s"]["mism"].append((k, [f"0x{x:08x}" for x in w_m2s],
                                       [f"0x{x:08x}" for x in got_s]))
        if ok_s2m:
            res["s2m"]["ok"] += 1
        else:
            res["s2m"]["mism"].append((k, [f"0x{x:08x}" for x in w_s2m],
                                       [f"0x{x:08x}" for x in got_m]))

    tb.log.info(f"TX-M monitor: {tx_m}")
    tb.log.info(f"TX-S monitor: {tx_s}")
    tb.log.info(f"RX-M(recv s2m) re-hunt: {rx_m}")
    tb.log.info(f"RX-S(recv m2s) re-hunt: {rx_s}")
    tb.log.info(f"DELIVERY m2s: {res['m2s']['ok']}/{NPKT}  "
                f"s2m: {res['s2m']['ok']}/{NPKT}")
    for d in ("m2s", "s2m"):
        for idx, exp, got in res[d]["mism"][:8]:
            tb.log.info(f"  MISMATCH {d} pkt {idx}: sent={exp} got={got}")

    beacons = tx_m["beacons"] + tx_s["beacons"]
    drain_beacons = tx_m["beacon_postcount_nz"] + tx_s["beacon_postcount_nz"]

    # non-vacuity
    assert beacons > 0, (
        "NO beacons fired on either die — NON-RESULT (drain window not "
        "exercised). Set TB_SWI_DELAY>0.")

    # A/B discriminator: with the guard IN, ZERO beacons fire while postcount!=0.
    assert drain_beacons == 0, (
        f"{drain_beacons} beacon(s) fired while postcount!=0 (drain window) — "
        f"the 0044bef guard is NOT in effect (reverted-RTL signature)")

    # Per-direction delivery. Report BOTH before asserting so a direction-
    # asymmetric residual (silicon s->m death) is visible in the log even when
    # the assert trips.
    m2s_bad = res["m2s"]["mism"]
    s2m_bad = res["s2m"]["mism"]
    assert not m2s_bad and not s2m_bad, (
        f"corruption under idle-gated beacons: m2s {len(m2s_bad)}/{NPKT} bad, "
        f"s2m {len(s2m_bad)}/{NPKT} bad (drain-window beacons={drain_beacons}) "
        f"— serialiser-drain defect class reproduced")
    tb.log.info(
        f"VERDICT: PASS — {beacons} idle-gated beacons on both dies (0 in drain "
        f"window), m2s {res['m2s']['ok']}/{NPKT} + s2m {res['s2m']['ok']}/{NPKT} "
        f"byte-exact: the 0044bef drain guard is data-safe BOTH directions in "
        f"this TB.")
