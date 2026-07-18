"""F14 · Scenario 6 — BACK-TO-BACK RESET STORM (N rapid swreset pulses).

Sweeps N rapid Wlink LL swreset pulses (APB 0x0208 bit[3]) on the SLAVE with no
recovery dwell between them, then attempts recovery and checks the FCSM lands in
a recoverable state. The concern: a burst of resets that overlaps the CR/CRACK
re-handshake could leave an FSM latched off LINK_IDLE (e.g. stuck in SEND_NACK
state 7) with pointers desynced.

EXPECTED (from RTL):
  * Each swreset re-zeros the slave LL (Wlink.v:2457-2463). The F-1 NACK
    watchdog (SOCL_L7_WDOG_THRESHOLD=0x4000, WlinkGenericFCSM_6.v:113-168) pulls
    a stuck state-7 back to state 4, and the L6/L7 bring-up gates re-seed the
    handshake. After the storm + one SW re-bring-up, the link should recover for
    every N.
  * FINDING if any N leaves the link unrecoverable by SW re-bring-up, or the
    FCSM stuck off {4,5} after recovery.
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB, run_bringup_full, APB_WL_LINK_ENABLE_RESET,
    LL_BOOTSTRAP_SWRESET_ON, LL_BOOTSTRAP_SWRESET_OFF, LL_BOOTSTRAP_ENABLE,
)
from errinj_common import link_healthy, classify_recovery


async def _bringup_healthy(dut):
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "PRECONDITION: no CR/CRACK"
    await ClockCycles(dut.hclk, 500)
    ok, detail = await link_healthy(tb)
    assert ok, f"PRECONDITION: not healthy ({detail})"
    return tb


async def _storm(tb, side, n, gap=8):
    """n rapid swreset ON/OFF pulses with only `gap` hclk between them."""
    apb = tb.apb(side)
    for _ in range(n):
        await apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_ON)
        await ClockCycles(tb.dut.hclk, gap)
        await apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_SWRESET_OFF)
        await ClockCycles(tb.dut.hclk, gap)
    # Leave the LL enabled at the end.
    await apb.write(APB_WL_LINK_ENABLE_RESET, LL_BOOTSTRAP_ENABLE)
    await ClockCycles(tb.dut.hclk, 200)


async def _run_n(dut, n):
    tb = await _bringup_healthy(dut)
    await _storm(tb, "s", n)
    fm, fs = tb.fcsm_state("m"), tb.fcsm_state("s")
    tb.log.info(f"  [storm N={n}] post-storm fcsm m={fm} s={fs}")
    verdict, detail = await classify_recovery(tb, "s", "m")
    fm2, fs2 = tb.fcsm_state("m"), tb.fcsm_state("s")
    recoverable = fm2 in (4, 5) and fs2 in (4, 5)
    tb.log.info(f"VERDICT[S6_reset_storm_N{n}]: {verdict} | "
                f"fcsm after-recovery m={fm2} s={fs2} recoverable_state={recoverable} "
                f"| post health: {detail}")


@cocotb.test()
async def test_01_storm_n1(dut):
    await _run_n(dut, 1)


@cocotb.test()
async def test_02_storm_n2(dut):
    await _run_n(dut, 2)


@cocotb.test()
async def test_03_storm_n3(dut):
    await _run_n(dut, 3)


@cocotb.test()
async def test_04_storm_n5(dut):
    await _run_n(dut, 5)
