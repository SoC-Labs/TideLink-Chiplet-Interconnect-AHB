# =============================================================================
# STREAM-START WEDGE repro + fix gate (SoC Labs 2026-07-06, agent 2b).
#
# SILICON SYMPTOM: a B->A (die_b TX -> die_a RX) transfer loses/corrupts its
# leading words at STREAM START (26/28), while A->B is clean. In this pair sim
# the marginal direction is S->M (EPOCH_PROFILE=silicon puts the whole-word
# epoch skew on the master's RX = the s2m path).
#
# ROOT CAUSE (WlinkGenericFCSM_6.v, RX FC node): at stream start on the skewed
# RX, data beats arrive whose ll_rx_pktnum is BEHIND exp_pkt_num -- a cold-start
# deskew re-delivery, a stale replay echo, or a PERIODIC PHANTOM pktnum==0 beat
# recurring on the ~SOCL_REACK_THRESHOLD (256-cycle) re-ACK cadence. The FC
# treated every such backward mismatch as exp_pkt_not_seen -> send_nack_req ->
# die_b NACK -> die_a a2l replay REVERTS and re-walks -> the replayed lower
# pktnums all mismatch the advanced exp -> a NACK->revert->re-walk REPLAY STORM
# that ratchets to credit-max and WEDGES exp (POR-only clear).
#
# This gate drives a stream-start burst on the skewed s2m path and asserts the
# STORM-FREE property directly: the TX must not enter a link_revert storm and
# the RX exp_pkt_num must not freeze. It is RED on pristine HEAD (hundreds of
# reverts, exp frozen) and GREEN with the L9c backward-mismatch re-ACK guard.
#
# Run (repro/fix gate, the skewed direction):
#   make EPOCH_PROFILE=silicon MODULE=test_v2_stream_start_28w \
#        TESTCASE=test_s2m_stream_start_no_storm
# Clean control (must always pass, no storm on a zero-skew link):
#   make EPOCH_PROFILE=zero    MODULE=test_v2_stream_start_28w \
#        TESTCASE=test_s2m_stream_start_no_storm
# =============================================================================
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full

N_WORDS = 28
# Storm bound: a healthy link needs a handful of reverts at most (transient
# NACK recovery). The pristine wedge asserts link_revert hundreds of times
# (observed 371-377 for a 16-word s2m burst under EPOCH_PROFILE=silicon).
REVERT_BUDGET = 40


def _fcsm(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return -1


async def _burst_and_watch_storm(tb, src, dst, label):
    """Drive an N_WORDS back-to-back burst src->dst while counting TX
    link_revert pulses and tracking whether RX exp_pkt_num freezes."""
    dut = tb.dut
    tx = _fcsm(tb, src)
    rx = _fcsm(tb, dst)
    tx_revert = getattr(tx, "a2l_fc_replay_link_revert", None)
    rx_exp = getattr(rx, "exp_pkt_num", None)

    payloads = [0xA5A50000 + (i << 8) + i for i in range(N_WORDS)]

    revert_pulses = 0
    exp_seen = set()

    async def watcher():
        nonlocal revert_pulses
        for _ in range(9000):
            await RisingEdge(dut.hclk)
            if tx_revert is not None and _i(tx_revert) == 1:
                revert_pulses += 1
            if rx_exp is not None:
                exp_seen.add(_i(rx_exp))

    w = cocotb.start_soon(watcher())
    await tb.ahb_tx_write_packet_b2b(src, payloads)
    await ClockCycles(dut.hclk, 8000)
    await w

    exp_max = max(exp_seen) if exp_seen else -1
    tb.log.info(f"  [{label}] TX link_revert pulses={revert_pulses} "
                f"(budget {REVERT_BUDGET}); RX exp_pkt_num reached {exp_max} "
                f"of {N_WORDS} words; distinct exp values seen={len(exp_seen)}")
    return revert_pulses, exp_max, len(exp_seen)


@cocotb.test()
async def test_s2m_stream_start_no_storm(dut):
    """B->A (skewed) stream-start must not trigger a NACK/revert storm."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    reverts, exp_max, n_exp = await _burst_and_watch_storm(tb, "s", "m", "s2m")
    assert reverts <= REVERT_BUDGET, (
        f"B->A STREAM-START WEDGE reproduced: {reverts} TX link_revert pulses "
        f"(> {REVERT_BUDGET}) -- NACK->revert replay storm at stream start.")
    # exp must keep advancing (not freeze at a low wedge value): a healthy
    # 28-word burst walks exp well past the credit ring, not stuck near 0.
    assert n_exp >= 8, (
        f"B->A RX exp_pkt_num appears frozen (only {n_exp} distinct values, "
        f"max {exp_max}) -- credit-ring wedge at stream start.")


@cocotb.test()
async def test_m2s_stream_start_no_storm(dut):
    """A->B (clean) control: no storm either direction on a healthy link."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    reverts, exp_max, n_exp = await _burst_and_watch_storm(tb, "m", "s", "m2s")
    assert reverts <= REVERT_BUDGET, f"A->B storm: {reverts} reverts"
