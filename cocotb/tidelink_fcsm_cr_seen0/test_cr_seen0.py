"""FAITHFUL cr_seen=0 repro (I1 bring-up). See docs/I1_SIM_REPRO_PLAN.md.

The two existing envs are BLIND because (a) cr_seen (cr_pkt_seen_rx) is a sticky
latch that sets on ONE intact peer CR, so on a zero-BER shared-clock wire it
always latches 1; (b) they force_calibrator_sim_bypass() (forcing cal_done, which
severs the cal<-cr coupling); (c) they run a clean bring-up first; (d) they assert
on state==4, never on cr_seen.

This env: COLD bring-up, UN-BYPASSED calibrator (short HOLD, S_VALIDATE still
gated on real cr_pkt_seen), and an oracle on the silicon 4-tuple
(cr_seen/crack_seen/cal_done/fcsm). RED lever = the L6 state-1 CR-emit hold; GREEN
= deps FCSM.

NOT YET RUN: deps/ submodules are un-checked-out in this worktree, and rung 2+
(per-die clocks, F6) needs a split-clock tb_top variant (see Makefile TODO(F6)).
The bring-up + oracle + instrument-trust structure below is complete and ready.
"""
import os
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (PairV2TB, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
                            ST_CR_SEEN, ST_CRACK_SEEN, ST_CAL_DONE,
                            APB_R8_SWI_LANE_STATUS)

FCSM_SRC   = os.environ.get("FCSM_SRC", "local")
CAL_BYPASS = os.environ.get("TIDELINK_CAL_BYPASS", "0") == "1"
SILICON_LANE_STATUS = 0x00100000     # cr=0 crack=0 cal=0 fcsm=0, only bit20 set

# Sustained-RED window and GREEN convergence bound (hclk chunks of 200).
RED_HOLD_CHUNKS  = int(os.environ.get("RED_HOLD_CHUNKS", "150"))
GREEN_BOUND_CHUNKS = int(os.environ.get("GREEN_BOUND_CHUNKS", "300"))


# --- observability: read cr_seen from BOTH the APB surface AND the RTL latch ---
def _hier_cr(tb, side):
    try:
        return int(tb.fcsm(side).cr_pkt_seen_rx.value)
    except (AttributeError, ValueError):
        return -1


async def _read_status(tb, side):
    st = await tb.apb(side).read(APB_R8_SWI_LANE_STATUS)
    return st


async def _tuple(tb, side):
    """Return the silicon 4-tuple (cr, crack, cal, fcsm) from the APB surface."""
    st = await _read_status(tb, side)
    return (ST_CR_SEEN(st), ST_CRACK_SEEN(st), ST_CAL_DONE(st),
            tb.fcsm_state(side), st)


async def _cold_bringup(tb):
    """POR -> role_lock -> LL enable (data mode). The FIDELITY DELTA vs the blind
    envs: force_calibrator_sim_bypass is applied ONLY if CAL_BYPASS (rung 0); the
    real calibrator otherwise gates S_VALIDATE on cr_pkt_seen. We do NOT run a
    clean bring-up first, and we sample cr_seen from cold."""
    await tb.reset()
    if CAL_BYPASS:
        tb.force_calibrator_sim_bypass()          # rung 0 positive control ONLY
    # TODO(F4): when CAL_BYPASS=0, apply `defparam ...u_calibrator.HOLD_CYCLES` via
    #   a compiled defparam stub (TIDELINK_CAL_HOLD_CYCLES) so S_HOLD is brief but
    #   S_VALIDATE still waits on real cr_pkt_seen. Placeholder until the stub lands.
    await tb.do_role_lock()
    await tb.wait_role_locked()
    await tb.do_to_data_mode()                    # LL enable -> FCSM state 0->1 attempt


async def _instrument_trust(tb, dut, expect_cr):
    """Plan §5 checks common to every run. `expect_cr` = 'reaches1' | 'stays0'."""
    # #3: pkt_is_cr_pkt (the detect INPUT, not the sticky latch) must pulse in
    # GREEN and never in RED. Monitor the RX-side detect.
    saw_pulse = {"m": False, "s": False}
    for _ in range(GREEN_BOUND_CHUNKS):
        await ClockCycles(dut.hclk, 200)
        for side in ("m", "s"):
            try:
                if int(tb.fcsm(side).pkt_is_cr_pkt.value):
                    saw_pulse[side] = True
            except (AttributeError, ValueError):
                pass
        # #2 cross-check: APB cr bit and hier latch must agree.
        for side in ("m", "s"):
            st = await _read_status(tb, side)
            assert ST_CR_SEEN(st) == max(_hier_cr(tb, side), 0), (
                f"[{side}] APB cr_seen={ST_CR_SEEN(st)} disagrees with RTL "
                f"cr_pkt_seen_rx={_hier_cr(tb, side)} -- APB-mux/obs bug")
        if expect_cr == "reaches1" and all(
                ST_CR_SEEN(await _read_status(tb, s)) for s in ("m", "s")):
            break
    return saw_pulse


@cocotb.test()
async def test_rung0_green_baseline(dut):
    """Positive control: deps FCSM, calibrator bypassed, fast ratio. cr_seen MUST
    reach 1 and cal_done MUST reach 1. If THIS fails the observable path is broken
    and every later RED is meaningless (plan §5.1)."""
    dut._log.info(f"=== rung0 GREEN baseline === FCSM_SRC={FCSM_SRC} "
                  f"CAL_BYPASS={CAL_BYPASS} ref={REF_CLK_PERIOD_NS}ns")
    tb = PairV2TB(dut)
    await _cold_bringup(tb)
    saw = await _instrument_trust(tb, dut, expect_cr="reaches1")
    for side in ("m", "s"):
        cr, crack, cal, fcsm, st = await _tuple(tb, side)
        dut._log.info(f"  [{side}] cr={cr} crack={crack} cal={cal} fcsm={fcsm} "
                      f"status=0x{st:08x} cr_pulse={saw[side]}")
        assert cr == 1, f"[{side}] positive control FAILED: cr_seen never latched"
        assert cal == 1, f"[{side}] positive control FAILED: cal_done never set"
        assert saw[side], f"[{side}] pkt_is_cr_pkt never pulsed -- dead observable"


@cocotb.test()
async def test_cold_bringup_cr_seen(dut):
    """THE ORACLE. Cold, un-bypassed bring-up. Assert the split keyed on FCSM_SRC:
      deps  (GREEN): cr_seen -> 1 and cal_done -> 1 within GREEN_BOUND_CHUNKS.
      local (RED):   cr_seen == 0 AND crack==0 AND cal==0 AND fcsm==0, sustained,
                     and SWI_LANE_STATUS == 0x00100000 (the exact silicon word)."""
    dut._log.info(f"=== cold cr_seen oracle === FCSM_SRC={FCSM_SRC} "
                  f"CAL_BYPASS={CAL_BYPASS} ref={REF_CLK_PERIOD_NS}ns")
    tb = PairV2TB(dut)
    await _cold_bringup(tb)

    if FCSM_SRC == "deps":
        saw = await _instrument_trust(tb, dut, expect_cr="reaches1")
        for side in ("m", "s"):
            cr, crack, cal, fcsm, st = await _tuple(tb, side)
            dut._log.info(f"  GREEN [{side}] cr={cr} cal={cal} fcsm={fcsm} "
                          f"0x{st:08x} cr_pulse={saw[side]}")
            assert cr == 1 and cal == 1, (
                f"[{side}] GREEN(deps) FAILED to converge: cr={cr} cal={cal}")
            assert saw[side], f"[{side}] deps CR never crossed the wire"
        return

    # RED (local): the CR must NEVER cross. Sustained 4-tuple + exact status word.
    saw = await _instrument_trust(tb, dut, expect_cr="stays0")
    for _ in range(RED_HOLD_CHUNKS):
        await ClockCycles(dut.hclk, 200)
        for side in ("m", "s"):
            cr, crack, cal, fcsm, st = await _tuple(tb, side)
            assert (cr, crack, cal, fcsm) == (0, 0, 0, 0), (
                f"[{side}] NOT the silicon RED: cr={cr} crack={crack} cal={cal} "
                f"fcsm={fcsm} status=0x{st:08x} -- bring-up partially advanced")
    for side in ("m", "s"):
        _, _, _, _, st = await _tuple(tb, side)
        assert st == SILICON_LANE_STATUS, (
            f"[{side}] status=0x{st:08x} != silicon 0x{SILICON_LANE_STATUS:08x}")
        assert not saw[side], (
            f"[{side}] pkt_is_cr_pkt PULSED in RED -- a CR did cross; this is the "
            f"emit-gate livelock (blind), NOT the cr_seen=0 deadlock")
    dut._log.info("  RED reproduced: silicon 4-tuple sustained, no CR crossed")


@cocotb.test()
async def test_refuted_fix_stays_red(dut):
    """Plan §5.5: the refuted emit-gate fix (shipping default, HOLD_ALWAYS unset)
    MUST NOT green a faithful cr_seen=0 RED. Run with the fix compiled in; assert
    the RED still holds. If cr_seen reaches 1 here, the sim is still BLIND
    (reproducing the emit-gate livelock, not the deadlock) -- a fidelity failure."""
    assert FCSM_SRC == "local", "refuted-fix check is a local-FCSM RED control"
    dut._log.info("=== refuted-fix-stays-red === (emit-gate fix compiled in)")
    tb = PairV2TB(dut)
    await _cold_bringup(tb)
    saw = await _instrument_trust(tb, dut, expect_cr="stays0")
    for side in ("m", "s"):
        cr, crack, cal, fcsm, st = await _tuple(tb, side)
        assert cr == 0, (
            f"[{side}] FIDELITY FAILURE: the refuted emit-gate fix greened the "
            f"RED (cr_seen={cr}). The sim is reproducing the emit-gate livelock, "
            f"not the cr_seen=0 deadlock silicon shows.")
        assert not saw[side], f"[{side}] CR crossed under the refuted fix"
    dut._log.info("  refuted fix correctly STAYED RED (matches silicon)")
