"""F14 · Scenario 2 — MID-BURST DIE RESET (single-die link-layer reset).

Models the KR260 fcsm=2 class of PARTIAL-reset states: one die's link layer is
reset while the peer keeps running, so their FCSM state / a2l pointers /
exp_pkt_num desync.

Two injections:
  test_01  LL swreset (APB 0x0208 bit[3], Wlink.v:2457-2463) on the SLAVE mid-
           burst. This re-zeros ONLY the slave's Wlink LL. It is LOCAL — it does
           NOT propagate to the master (agent-mapped: the two CAN desync). Does
           the standard SW re-bring-up recover, or is a full POR of both needed?
  test_02  Full single-die POR (m_por_gate/s_por_gate low then high, tb_top:165)
           — the pad outputs squash to 0 while that die is in reset.

EXPECTED (from RTL):
  * The reset die's FCSM returns to state 0->...->4; its exp_pkt_num/credits
    re-zero (WlinkGenericFCSM_6.v:1229,1323). The peer's counters do NOT, so the
    first post-reset packets may be dropped as unexpected pkt_num until the
    CR/CRACK re-handshake re-seeds both. The L7 bring-up-forgive + F-1 NACK
    watchdog (state 7 -> 4) are designed to make this self-heal after a
    re-handshake; whether the standard `to_data_mode` re-bring-up suffices is
    the open question this scenario answers.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, send_and_check
from errinj_common import (
    link_healthy, classify_recovery, ll_swreset_one_die, reset_one_die,
    credit_snapshot,
)


async def _bringup_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: not healthy pre-injection ({detail})"
    tb.log.info(f"  [pre-inject] HEALTHY ({detail}) "
                f"cred_m={credit_snapshot(tb,'m')} cred_s={credit_snapshot(tb,'s')}")
    return tb


@cocotb.test()
async def test_01_slave_ll_swreset_midburst(dut):
    tb = await _bringup_healthy(dut)

    # A packet is in flight, then the slave's LL is swreset.
    await tb.ahb_tx_write_packet("s", __import__("pair_v2_common").make_packet(
        [0x5A00BEEF, 0x5A00F00D]))
    await ll_swreset_one_die(tb, "s")
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    tb.log.info(f"  [post-swreset] fcsm m={fm} s={fs} "
                f"cred_m={credit_snapshot(tb,'m')} cred_s={credit_snapshot(tb,'s')}")

    verdict, detail = await classify_recovery(tb, "s", "m")
    tb.log.info(f"VERDICT[S2_slave_LL_swreset]: {verdict} | "
                f"fcsm post-reset m={fm} s={fs} | post health: {detail}")


@cocotb.test()
async def test_02_slave_full_por_midburst(dut):
    tb = await _bringup_healthy(dut)

    await tb.ahb_tx_write_packet("s", __import__("pair_v2_common").make_packet(
        [0x5A11BEEF, 0x5A11F00D]))
    await reset_one_die(tb, "s", cycles=60)   # full single-die POR gate
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    tb.log.info(f"  [post-POR-1die] fcsm m={fm} s={fs}")

    verdict, detail = await classify_recovery(tb, "s", "m")
    tb.log.info(f"VERDICT[S2_slave_full_POR_1die]: {verdict} | "
                f"fcsm post-reset m={fm} s={fs} | post health: {detail}")
