"""DIAGNOSTIC (Deliverable A scaffolding) — observe the serialiser-drain window.

Not a gate. Brings the pair up, enables IDLE-GATED SYNC beacons on the master
(R8 bit[2] insert_en=1, force_always=0 — the permanent autonomous state), sends
a burst, and samples the master gpio TX path every link-clock edge to answer the
mechanistic question 0044bef raised:

  * does (io_link_tx_tx_idle==1 && postcount!=0) — the "idle asserted but the
    serialiser is still draining" window — actually OCCUR in this pair TB?
  * does the free-running SYNC counter (u_tx_sync_insert.ctr_q) ever hit 0
    inside that window (so a beacon WOULD fire there without the guard)?
  * with the 0044bef guard IN, does tx_sync_inserting_w stay OUT of that window?

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_beacon_drain_diag
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, APB_R8_SLOT0

R8_SLOT0_SYNC_EN       = 0x4    # bit[2] insert_en
R8_SLOT0_ROBUST_DETECT = 0x10   # bit[4] robust


def gpio(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.phy.gpio


async def _monitor(tb, side, n_edges, stats):
    g = gpio(tb, side)
    ins = g.u_tx_sync_insert
    for _ in range(n_edges):
        await RisingEdge(g.io_link_tx_tx_link_clk)
        try:
            idle = int(g.io_link_tx_tx_idle.value)
            en   = int(g.io_link_tx_tx_en.value)
            post = int(g.postcount.value)
            ctr  = int(ins.ctr_q.value)
            insrt = int(g.tx_sync_inserting_w.value)
            syncen = int(g.tx_sync_en_w.value)
        except ValueError:
            continue
        stats["edges"] += 1
        drain = (idle == 1 and post != 0)
        if drain:
            stats["drain_cycles"] += 1
            if ctr == 0:
                stats["ctr0_in_drain"] += 1
            if insrt == 1:
                stats["beacon_in_drain"] += 1
        if en == 1:
            stats["tx_en_cycles"] += 1
        if insrt == 1:
            stats["beacon_total"] += 1
        if idle == 1:
            stats["idle_cycles"] += 1


@cocotb.test()
async def test_diag_drain_window(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no bilateral CR/CRACK"

    # Enable idle-gated beacons on the MASTER (the m->s TX beacon source).
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_SYNC_EN | R8_SLOT0_ROBUST_DETECT)
    rb = await tb.m_apb.read(APB_R8_SLOT0)
    tb.log.info(f"master R8_SLOT0 = 0x{rb:08x} (insert_en={(rb>>2)&1} "
                f"force_always={(rb>>3)&1} robust={(rb>>4)&1})")

    stats = dict(edges=0, drain_cycles=0, ctr0_in_drain=0, beacon_in_drain=0,
                 tx_en_cycles=0, beacon_total=0, idle_cycles=0)
    mon = cocotb.start_soon(_monitor(tb, "m", 6000, stats))

    # Drive several packets with varied spacing so the free-running ctr_q walks
    # different phase alignments against each packet's tx_en falling edge.
    from pair_v2_common import make_packet
    for k in range(12):
        words = make_packet([0xDA7A0000 | k, 0xCAFE0000 | k])
        await tb.ahb_tx_write_packet("m", words, gap=2 + (k % 7))
        await ClockCycles(dut.hclk, 200 + 37 * k)

    await mon

    tb.log.info(f"DIAG stats: {stats}")
    tb.log.info(f"  drain-window cycles (idle & postcount!=0) = {stats['drain_cycles']}")
    tb.log.info(f"  ctr_q==0 falling INSIDE drain window       = {stats['ctr0_in_drain']}")
    tb.log.info(f"  beacons INSIDE drain window (tx_sync_ins)  = {stats['beacon_in_drain']}")
    tb.log.info(f"  beacons total                              = {stats['beacon_total']}")
