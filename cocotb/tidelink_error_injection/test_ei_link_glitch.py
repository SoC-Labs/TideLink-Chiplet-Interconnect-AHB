"""F14 · Scenario 1 — MID-BURST LINK GLITCH (kill/corrupt N link-clk cycles).

Injection (my err_inject on the S->M pads, corrupting the MASTER's RX):
  * clk_kill : hold pad_clk_out low for a window  -> the master's recovered
    link clock stops advancing mid-burst (a clock dropout).
  * mode=FLIP all lanes for a window              -> every assembled 128-bit
    link word is corrupted (a data blackout / marginal-eye storm).

EXPECTED (from RTL):
  * The bring-up leaves the SYNC beacon OFF (swi_sync_insert_en_r POR=0,
    axi_chiplet_controller.sv:1888; do_to_data_mode writes R8 slot0=0). So the
    RX framer has NO re-align delimiter for a mid-stream slip — the wedge class
    at WlinkRxLinkLayer.v:315-321. Recovery therefore rests ENTIRELY on the FC
    layer: the 32-deep a2l replay FIFO (WlinkGenericFCSM_6.v:257-297), the
    periodic credit re-ACK (SOCL_REACK_THRESHOLD=0x0100, :53/:180-189) and the
    F-1 state-7 NACK watchdog (SOCL_L7_WDOG_THRESHOLD=0x4000, :113-168/:273-283
    -> falls back to state 4).
  * Prediction: a corrupt/glitch window that only garbles in-flight words
    should be caught by CRC -> NACK -> replay and RECOVER (fcsm returns to 4,
    later packets byte-exact). A window that slips WORD FRAMING (clk_kill
    dropping pad_clk edges) has no SYNC to re-anchor and may WEDGE.

Test PASSES as long as the scenario executes and a verdict is recorded; a WEDGE
is a FINDING, not a test failure. test_00 (passthrough) is the harness sanity
gate and DOES assert — it proves the err_inject splice is bit-identical when
idle.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, send_and_check
from errinj_common import (
    inject_data, clear_all, kill_clock, link_healthy, M_FLIP,
    burst_during_fault, classify_recovery,
)


async def _bringup_and_prove_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: link never reached CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: link not healthy pre-injection ({detail})"
    tb.log.info(f"  [pre-inject] link HEALTHY ({detail})")
    return tb


@cocotb.test()
async def test_00_passthrough_sanity(dut):
    """Injector idle == bit-identical harness: full bring-up + both dirs."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "passthrough: CR/CRACK failed"
    await ClockCycles(dut.hclk, 500)
    await send_and_check(tb, "m", "s", [0x11110000, 0x22220000], ctx="pt-m2s")
    await send_and_check(tb, "s", "m", [0x33330000, 0x44440000], ctx="pt-s2m")
    tb.log.info("VERDICT[S0_passthrough]: RECOVERS (baseline healthy, injector idle)")


@cocotb.test()
async def test_01_s2m_data_flip_glitch(dut):
    """FLIP all S->M lanes WHILE an s->m multi-packet burst is in flight, then
    release and classify recovery. Corrupts every assembled link word during
    the window."""
    tb = await _bringup_and_prove_healthy(dut)

    during = await burst_during_fault(
        tb, "s", "m",
        [[0xBEEF0001, 0xF00D0002], [0xBEEF0003, 0xF00D0004],
         [0xBEEF0005, 0xF00D0006]],
        fault_setup=lambda: inject_data(dut, "s2m", M_FLIP, 0xFF),
        fault_clear=lambda: clear_all(dut),
        ctx="flip")
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    tb.log.info(f"  [flip] during-burst delivered={during} fcsm m={fm} s={fs}")

    verdict, detail = await classify_recovery(tb, "s", "m")
    tb.log.info(f"VERDICT[S1_s2m_data_flip]: {verdict} | "
                f"during-burst byte-exact={during} | post health: {detail}")


@cocotb.test()
async def test_02_s2m_clock_kill_glitch(dut):
    """Kill the S->M pad clock (drop recovered-link-clock edges) WHILE an s->m
    burst is in flight. The framing-slip case: no SYNC beacon in data mode to
    re-anchor (WlinkRxLinkLayer.v:315-321)."""
    tb = await _bringup_and_prove_healthy(dut)

    during = await burst_during_fault(
        tb, "s", "m",
        [[0xC10C0001, 0xC10C0002], [0xC10C0003, 0xC10C0004]],
        fault_setup=lambda: kill_clock(dut, "s2m", on=True),
        fault_clear=lambda: kill_clock(dut, "s2m", on=False),
        ctx="clkkill")
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    tb.log.info(f"  [clkkill] during-burst delivered={during} fcsm m={fm} s={fs}")

    verdict, detail = await classify_recovery(tb, "s", "m")
    tb.log.info(f"VERDICT[S1_s2m_clock_kill]: {verdict} | "
                f"during-burst byte-exact={during} | post health: {detail}")
