"""
test_fixe_training_release — I1 / FIX-E training-hold self-deadlock regression.

SILICON-PROVEN (2026-07-30, KR260 eth-chiplet pair, recovery FCSM)
=================================================================
The winscan calibrator's S_HOLD(6) -> S_VALIDATE(9) transition is gated at
    src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv:1499
        else if (hold_ctr >= HOLD_MAX && !swi_training_mode_r) nxt_state = S_VALIDATE;
i.e. on the hold-timer AND on SWI_TRAINING_MODE being RELEASED — NOT on cr_seen,
NOT on full lane lock.  The bring-up recipe held SWI_TRAINING_MODE=1 while
polling cal_done; but cal_done needs S_HOLD->S_VALIDATE->S_DONE, which needs
training released.  => self-deadlock: the die parks in S_HOLD forever
(state=6, fcsm=1, cal_done=0, cr_seen=0).

The FIX (FIX-E) is to release SWI_TRAINING_MODE=0 once in S_HOLD: the :1499 gate
then fires (hold_ctr already expired) -> S_VALIDATE; cr_seen goes 0->1 the instant
the link enters data mode (and VAL_TIMEOUT_TO_DONE=1 is the terminal backstop)
-> S_DONE -> cal_done=1 -> fcsm=4.

Why the pre-existing cocotb/tidelink_fcsm_silicon_ratio was BLIND
----------------------------------------------------------------
It reaches state=4 but NEVER models the training-hold, so it could not observe
this deadlock — which is what led a prior investigation to wrongly conclude the
failure was "below RTL / a timing wall".  This test models the hold AND release.

Discriminator (see phase (a)/(b) below, and FIXE_INVERT)
--------------------------------------------------------
  (a) DEADLOCK: with SWI_TRAINING_MODE held HIGH, advance PAST HOLD_MAX and
      assert the FSM STAYS in S_HOLD with cal_done=0.  This FAILS if the RTL ever
      lets S_HOLD->S_VALIDATE proceed while training is held (pins the :1499 gate).
  (b) RELEASE: drop SWI_TRAINING_MODE=0 and assert S_HOLD->S_VALIDATE->S_DONE with
      cal_done asserted within a bounded window.  This FAILS if releasing does not
      reach cal_done.
  Non-vacuity: FIXE_INVERT=1 SKIPS the release in (b), so the deadlock persists and
  phase (b) MUST fail/time-out — proving the test is not vacuous.

Invocation:
    source ./set_env.sh
    rm -rf cocotb/tidelink_i1_fixe_training_release/sim_build*
    make -C cocotb/tidelink_i1_fixe_training_release
    # discriminator (must FAIL):
    FIXE_INVERT=1 make -C cocotb/tidelink_i1_fixe_training_release

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# FSM state encodings — mirror tidelink_phy_align_calibrator_v2.sv (lines 616-696).
S_IDLE = 0
S_ARM = 1
S_SWEEP = 2
S_FINISH = 3
S_DONE = 4
S_CANCEL = 5
S_HOLD = 6
S_PROBE = 7
S_FINALIZE = 8
S_VALIDATE = 9

# Must match the tb_fixe.sv parameter overrides.
HOLD_CYCLES = 64
HOLD_MAX = HOLD_CYCLES - 1
VALIDATION_TIMEOUT = 128

# Non-vacuity discriminator: when set, the RELEASE (phase b) is SKIPPED, so the
# deadlock persists and phase (b) must FAIL.  Default off = the fixed recipe.
INVERT = os.environ.get("FIXE_INVERT", "0") == "1"


def _st(dut):
    return int(dut.state.value)


async def _reset(dut, training_hold):
    """Start clock, apply reset, settle inputs.  training_hold sets the initial
    SWI_TRAINING_MODE level (the FIX-E gate input)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value = 0
    dut.swreset.value = 0
    dut.lane_locked.value = 0xFF          # all lanes score a lock in S_PROBE
    dut.swi_training_hold_i.value = training_hold
    dut.cr_pkt_seen_i.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def _drive_to_hold(dut):
    """Rising role_locked -> trigger -> S_ARM -> S_PROBE -> S_FINISH -> S_HOLD.
    Returns (reached, state_trace).  Budget covers the full-sweep path too."""
    dut.role_locked.value = 1
    trace = []
    for _ in range(2000):
        await RisingEdge(dut.clk)
        s = _st(dut)
        trace.append(s)
        if s == S_HOLD:
            return True, trace
        # With training HELD the FSM must not sneak to S_DONE before S_HOLD.
    return False, trace


@cocotb.test()
async def test_fixe_training_hold_deadlock_then_release(dut):
    """The discriminating regression: DEADLOCK with training held, RECOVERY on
    release.  Fails if the :1499 gate ever advances S_HOLD while training is
    held, or if releasing training does not reach cal_done."""
    # -- Bring the FSM to S_HOLD with SWI_TRAINING_MODE held HIGH. -------------
    await _reset(dut, training_hold=1)
    reached, trace = await _drive_to_hold(dut)
    assert reached, (
        f"FSM never reached S_HOLD (state tail: {trace[-24:]}). Cannot exercise "
        f"the FIX-E gate."
    )
    assert _st(dut) == S_HOLD
    assert int(dut.cal_in_hold_o.value) == 1, "cal_in_hold_o not asserted in S_HOLD"
    assert int(dut.calibration_done.value) == 0, "cal_done set on S_HOLD entry"
    assert int(dut.training_mode.value) == 1, "training_mode low in S_HOLD"

    # -- Phase (a): DEADLOCK ---------------------------------------------------
    # Advance well past HOLD_MAX.  With training held, the :1499 gate
    # (hold_ctr >= HOLD_MAX && !swi_training_mode_r) can NEVER fire.
    saw_saturated = False
    for _ in range(HOLD_CYCLES * 4):
        await RisingEdge(dut.clk)
        hc = int(dut.u_dut.hold_ctr.value)
        if hc >= HOLD_MAX:
            saw_saturated = True
        s = _st(dut)
        assert s == S_HOLD, (
            f"FSM left S_HOLD to state {s} while SWI_TRAINING_MODE held HIGH "
            f"(hold_ctr={hc}, HOLD_MAX={HOLD_MAX}). The :1499 "
            f"'&& !swi_training_mode_r' gate did NOT hold — I1 gate regression: "
            f"S_HOLD->S_VALIDATE must be blocked while training is held."
        )
        assert int(dut.calibration_done.value) == 0, (
            "calibration_done asserted while training held — cal_done must stay 0 "
            "throughout the deadlock (fcsm would falsely leave state 1)."
        )
    assert saw_saturated, (
        f"hold_ctr never reached HOLD_MAX={HOLD_MAX} in the deadlock window — the "
        f"test is not actually past the hold-timer, so it would not exercise the "
        f"post-hold gate.  Increase the window."
    )
    assert int(dut.u_dut.swi_training_mode_r.value) == 1, (
        "swi_training_mode_r not registered HIGH — the gate input is not what the "
        "deadlock assertion assumes."
    )
    dut._log.info(
        f"OK phase(a) DEADLOCK: parked in S_HOLD with hold_ctr saturated "
        f">= HOLD_MAX({HOLD_MAX}) and cal_done=0 while SWI_TRAINING_MODE held — "
        f"reproduces the I1 self-deadlock the silicon-blind fcsm_silicon_ratio missed."
    )

    # -- Phase (b): RELEASE ----------------------------------------------------
    if INVERT:
        dut._log.warning(
            "FIXE_INVERT=1: NOT releasing SWI_TRAINING_MODE (buggy recipe) — "
            "phase (b) is EXPECTED to FAIL (deadlock persists)."
        )
    else:
        # FIX-E bilateral coordinated release.  cr_seen goes 0->1 the instant the
        # link enters data mode (silicon behaviour).
        dut.swi_training_hold_i.value = 0
        dut.cr_pkt_seen_i.value = 1

    reached_done = False
    seen_validate = False
    trace_b = []
    for _ in range(VALIDATION_TIMEOUT + 200):
        await RisingEdge(dut.clk)
        s = _st(dut)
        trace_b.append(s)
        if s == S_VALIDATE:
            seen_validate = True
        if s == S_DONE:
            reached_done = True
            break

    assert reached_done, (
        f"FSM did not reach S_DONE after the training-release step "
        f"(seen_validate={seen_validate}, state tail: {trace_b[-24:]}). "
        + (
            "FIXE_INVERT=1 set: this FAILURE is the discriminator — with training "
            "never released the die stays deadlocked in S_HOLD."
            if INVERT else
            "FIX-E broken: releasing SWI_TRAINING_MODE did NOT free "
            "S_HOLD->S_VALIDATE->S_DONE."
        )
    )
    assert seen_validate, "reached S_DONE without passing through S_VALIDATE(9)"
    for _ in range(4):
        if int(dut.calibration_done.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.calibration_done.value) == 1, (
        "reached S_DONE but calibration_done did not assert — fcsm would never "
        "reach state 4."
    )
    assert int(dut.training_mode.value) == 0, (
        "training_mode still HIGH in S_DONE — TX must drop the training pattern."
    )
    dut._log.info(
        "OK phase(b) RELEASE: dropping SWI_TRAINING_MODE drove "
        "S_HOLD->S_VALIDATE->S_DONE with calibration_done=1 — FIX-E proven, the "
        "deadlock is recoverable exactly as on silicon."
    )


@cocotb.test()
async def test_fixe_no_hold_flows_to_done(dut):
    """Positive control (INVERT-independent): with SWI_TRAINING_MODE NEVER held,
    the FSM flows S_HOLD->S_VALIDATE->S_DONE autonomously.  Proves the deadlock in
    the main test is caused SPECIFICALLY by the training hold (not a tb that can
    never reach S_DONE), so phase (a) is not vacuously true."""
    await _reset(dut, training_hold=0)
    dut.cr_pkt_seen_i.value = 1           # data-mode oracle available immediately
    reached, trace = await _drive_to_hold(dut)
    assert reached, f"FSM never reached S_HOLD (state tail: {trace[-24:]})"

    reached_done = False
    for _ in range(HOLD_CYCLES + VALIDATION_TIMEOUT + 300):
        await RisingEdge(dut.clk)
        if _st(dut) == S_DONE:
            reached_done = True
            break
    assert reached_done, (
        "with training NEVER held, the FSM still failed to reach S_DONE — the tb "
        "cannot reach cal_done at all, so the main test's deadlock assertion would "
        "be vacuous."
    )
    assert int(dut.calibration_done.value) == 1
    dut._log.info(
        "OK control: training-not-held -> autonomous S_HOLD->S_VALIDATE->S_DONE, "
        "cal_done=1.  Confirms the main-test deadlock is caused by the training hold."
    )
