"""test_eye_skip_calibrator — proposal §9 test #5.

Asserts SWI_FORCE_PHASE_EN[1] (skip-calibrator) keeps the FSM in
S_IDLE even when role_lock rises — the v2 path that lets a host pin
the eye centre without re-running the sweep.

Sequence:
  1. Reset, idle inputs.
  2. Write SWI_FORCE_PHASE_EN with [1]=1 (skip-calibrator).
  3. Raise role_lock.
  4. Wait LONG enough for a natural sweep to complete (ONE_SWEEP_CYCLES
     × 2 cycles).
  5. Assert `dut.state` reports S_IDLE the whole time, and that
     `calibration_done` is held at 1 (the spec says skip mode tells the
     rest of the link "cal is done, ride with the override").

The complementary negative control runs without setting [1]=1 and shows
the FSM correctly leaves S_IDLE on role_lock — proves the FSM is not
just stuck.

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from eye_common import (
    SWI_FORCE_PHASE_EN,
    FORCE_EN_OVERRIDE, FORCE_EN_SKIP_CAL,
    S_IDLE, S_ARM, S_SWEEP, S_PROBE,
    apb_idle, apb_write,
    start_clock_and_reset,
    ONE_SWEEP_CYCLES,
)


@cocotb.test()
async def test_skip_calibrator_holds_fsm_in_idle(dut):
    """With SWI_FORCE_PHASE_EN[1]=1, raising role_lock must NOT trigger
    a sweep. The FSM stays in S_IDLE for the full observation window.
    """
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0
    await apb_idle(dut)
    await start_clock_and_reset(dut)

    # Engage skip-calibrator mode (and also the top-level override so the
    # apb_override_enable path takes effect — spec §5 says skip is
    # paired with override-en in practice).
    await apb_write(dut, SWI_FORCE_PHASE_EN, FORCE_EN_OVERRIDE | FORCE_EN_SKIP_CAL)
    await ClockCycles(dut.clk, 4)

    # Now raise role_lock. Without skip mode this would trigger S_ARM →
    # S_SWEEP within a few cycles.
    dut.role_locked.value = 1

    # Watch the FSM for ONE full natural sweep window. The state must
    # NEVER transition out of S_IDLE.
    bad_states = (S_ARM, S_SWEEP, S_PROBE)
    for cyc in range(ONE_SWEEP_CYCLES * 2):
        await RisingEdge(dut.clk)
        s = int(dut.state.value)
        assert s == S_IDLE, (
            f"Cycle {cyc} after role_lock: state={s} (expected "
            f"S_IDLE={S_IDLE}). skip-calibrator did not block the "
            f"S_IDLE→S_ARM trigger. spec §5 SWI_FORCE_PHASE_EN[1]."
        )
        # Cheap shortcut — if we sit on S_IDLE consistently the loop
        # converges. The full ONE_SWEEP_CYCLES*2 window is the conservative
        # upper bound.
        assert s not in bad_states, (
            f"FSM entered state {s} after role_lock — must stay in S_IDLE."
        )

    # With override-en + skip-cal, calibration_done is driven by the
    # APB override path; spec §5 explicitly says the override forces
    # calibration_done=1 so lltx/FCSM treats the link as cal-complete.
    cal_done = int(dut.calibration_done.value)
    assert cal_done == 1, (
        f"calibration_done = {cal_done} with override-en + skip-cal "
        f"(expected 1). Spec §5: override path forces cal_done=1."
    )

    dut._log.info(
        f"OK: SWI_FORCE_PHASE_EN[1] holds FSM in S_IDLE across "
        f"{ONE_SWEEP_CYCLES * 2} cycles after role_lock rose."
    )


@cocotb.test()
async def test_no_skip_negative_control_sweep_runs(dut):
    """Negative control: WITHOUT skip-calibrator, the FSM does leave
    S_IDLE on role_lock. Prevents false-pass if the FSM is just broken
    (and never moves regardless of skip)."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0
    await apb_idle(dut)
    await start_clock_and_reset(dut)

    # No FORCE_PHASE_EN write — natural path. role_lock rising should
    # trigger S_IDLE → S_ARM within a couple of cycles.
    dut.role_locked.value = 1

    saw_arm_or_sweep = False
    for _ in range(64):
        await RisingEdge(dut.clk)
        s = int(dut.state.value)
        if s in (S_ARM, S_SWEEP, S_PROBE):
            saw_arm_or_sweep = True
            break

    assert saw_arm_or_sweep, (
        "Negative control failed — without skip-calibrator, FSM did not "
        "leave S_IDLE after role_lock. Skip-cal test above is meaningless."
    )

    dut._log.info("OK: negative control — natural path triggers sweep on role_lock.")
