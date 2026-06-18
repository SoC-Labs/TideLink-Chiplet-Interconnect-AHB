"""
test_calibrator_t3 — pin T3 continuous re-sweep + T3.2 S_HOLD in
tidelink_phy_align_calibrator (commits 1e5f4e0 + 50f7869).

Background
==========

The per-deploy bring-up lottery (T1 HW-confirmed) was caused by ms-scale
skew between master and slave role_lock writes: each side's ~82 µs
training sweep almost never overlapped the peer's, so every lane faulted
and the link wedged with calibration_done=1, lane_fault=0xFF.

T3   (commit 1e5f4e0): a sweep that ends with sweep_success=0
                       (~|lane_fault_q == 0 means at least one lane
                       faulted) must NOT release to S_DONE while
                       role_locked=1 — it must auto re-arm
                       (S_FINISH→S_ARM) and run a fresh sweep with
                       training_mode HIGH. Two skew-triggered nodes then
                       re-sweep continuously until their windows
                       coincide; ms-scale non-overlap (fatal) becomes a
                       ≤few-hundred-µs convergence delay (benign).

T3.2 (commit 50f7869): a sweep that ends with sweep_success=1 (all lanes
                       locked) must NOT go S_FINISH→S_DONE either — it
                       must go S_FINISH→S_HOLD and keep training_mode
                       HIGH for HOLD_CYCLES so the (role_lock-skew-
                       delayed) peer can also converge against our
                       continuous pattern. Then S_HOLD→S_DONE. S_HOLD
                       deliberately does NOT react to lane_locked
                       (the latched alignment is physically correct;
                       the peer switching to real data will drop our
                       lane_checker, which must NOT trigger a re-sweep).

The TB instantiates the calibrator standalone (no PHY) with small
DWELL_CYCLES / HOLD_CYCLES so the 128-point sweep + the HOLD window
complete in ~1k+1k cycles instead of millions. The cocotb test scripts
lane_locked directly:
  * test_t3_resweep_on_fault    : keep lane_locked=0x00 throughout one
                                  sweep → sweep_success=0 → FSM must
                                  S_FINISH→S_ARM (not →S_DONE).
                                  calibration_done must STAY 0.
                                  training_mode must STAY 1.
  * test_t32_shold_on_success   : keep lane_locked=0xFF throughout one
                                  sweep → sweep_success=1 → FSM must
                                  S_FINISH→S_HOLD (state=6), keep
                                  training_mode=1 for HOLD_CYCLES, then
                                  S_HOLD→S_DONE (state=4) with
                                  calibration_done rising.
  * test_t32_shold_ignores_lane_drop : in S_HOLD, drop lane_locked to
                                  0x00 (the peer transitions out of
                                  training). The FSM must stay in
                                  S_HOLD until HOLD_CYCLES — NO
                                  re-sweep. S_HOLD is sticky against
                                  lane_locked.
  * test_t3_resweep_advances_counter : repeated re-sweeps must
                                  increment resweep_ctr; trigger_now
                                  must clear it.

Invocation:
    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/tidelink_phy_align_calibrator/sim_build
    make -C cocotb/tidelink_phy_align_calibrator

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# FSM state encodings (must mirror tidelink_phy_align_calibrator.sv).
S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5
S_HOLD   = 6

# TB parameter overrides (must match tb_top.sv).
DWELL_CYCLES = 8
LOCK_THRESH  = 2
HOLD_CYCLES  = 2 * 128 * DWELL_CYCLES   # 2048

# A full 128-point sweep (best-of-sweep mode walks the whole space)
# = 16 phase × 8 slip × DWELL_CYCLES = 1024 cycles + 1 cycle of S_ARM
# + 1 cycle of S_FINISH ≈ 1026 cycles.
ONE_SWEEP_CYCLES = 16 * 8 * DWELL_CYCLES + 4


async def _start(dut):
    """Start clock, drive a clean reset, settle inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    # deps wrapper (tb_top_deps) exposes the centering knob + eye-sel as ports.
    # Drive them to their safe defaults so centering_mode stays 0 (probe path).
    if hasattr(dut, "min_lock_dwells_i"):
        dut.min_lock_dwells_i.value = 0
    if hasattr(dut, "eye_lane_sel"):
        dut.eye_lane_sel.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def _trigger_role_lock(dut):
    """Rising edge of role_locked → trigger_now → S_IDLE/S_DONE → S_ARM."""
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 2)


def _state(dut):
    return int(dut.state.value)


@cocotb.test()
async def test_t3_resweep_on_fault(dut):
    """T3 (commit 1e5f4e0): sweep_success=0 + role_locked=1 must auto
    re-sweep. The FSM goes S_FINISH→S_ARM (not →S_DONE).
    calibration_done must STAY 0 throughout. training_mode must STAY 1
    across the FINISH→ARM transition.
    """
    await _start(dut)

    # Trigger calibration.
    await _trigger_role_lock(dut)

    # Wait for the FSM to enter S_SWEEP.
    saw_sweep = False
    for _ in range(64):
        await RisingEdge(dut.clk)
        if _state(dut) == S_SWEEP:
            saw_sweep = True
            break
    assert saw_sweep, (
        f"FSM never reached S_SWEEP after role_locked rose (final "
        f"state={_state(dut)}). Trigger path or S_ARM→S_SWEEP edge is broken."
    )

    # Sanity: in S_SWEEP training_mode must be 1.
    assert int(dut.training_mode.value) == 1, (
        "training_mode = 0 in S_SWEEP — the calibrator is not driving "
        "its training pattern. The peer cannot align."
    )

    # Keep lane_locked = 0x00 throughout the sweep → sweep_success=0.
    dut.lane_locked.value = 0x00

    # Wait long enough for the sweep to finish + a few cycles past
    # S_FINISH so the auto re-arm is observable.
    found_finish = False
    found_rearm  = False
    last_states  = []
    for i in range(ONE_SWEEP_CYCLES + 32):
        await RisingEdge(dut.clk)
        s = _state(dut)
        last_states.append(s)
        if s == S_FINISH:
            found_finish = True
            # Right after S_FINISH the FSM must re-arm to S_ARM
            # (or be already in S_ARM by next cycle).
        # The S_FINISH→S_ARM transition fires on the next clock edge.
        if found_finish and s == S_ARM:
            found_rearm = True
            break

    assert found_finish, (
        f"FSM never reached S_FINISH after lane_locked=0x00 sweep "
        f"(states seen tail: {last_states[-16:]})."
    )
    assert found_rearm, (
        f"FSM reached S_FINISH but did NOT auto-rearm to S_ARM "
        f"(states seen tail: {last_states[-16:]}). T3 is broken — "
        f"a faulted sweep released to S_DONE while role_locked=1."
    )

    # While we're at it, confirm calibration_done stayed 0 throughout.
    cal_done = int(dut.calibration_done.value)
    assert cal_done == 0, (
        f"calibration_done = {cal_done} after a faulted sweep — must "
        f"stay 0 until sweep_success. T3 release gating is broken."
    )

    # And training_mode is back to 1 in the new sweep.
    # Allow a couple of cycles for S_ARM→S_SWEEP.
    for _ in range(4):
        if int(dut.training_mode.value) == 1:
            break
        await RisingEdge(dut.clk)
    assert int(dut.training_mode.value) == 1, (
        "training_mode dropped 0 across the S_FINISH→S_ARM re-arm. "
        "T3 contract requires training_mode HIGH across re-sweeps."
    )

    dut._log.info(
        "OK: T3 continuous re-sweep — faulted sweep auto-rearms to "
        "S_ARM with training_mode held HIGH; calibration_done stays 0."
    )


@cocotb.test()
async def test_t32_shold_on_success(dut):
    """T3.2 (commit 50f7869): sweep_success=1 must NOT release to S_DONE
    — must enter S_HOLD and hold training_mode HIGH for HOLD_CYCLES.
    Then S_HOLD→S_DONE with calibration_done rising.
    """
    await _start(dut)

    # Force all lanes to "locked" throughout the sweep — every dwell
    # window scores LANE_SCORE_MAX (saturates at 6'h3F), so best_score
    # easily exceeds LOCK_THRESH=2 and sweep_success=1 (~|lane_fault_q).
    dut.lane_locked.value = 0xFF

    await _trigger_role_lock(dut)

    # Wait for S_HOLD (state=6). This must happen out of S_FINISH on the
    # cycle after sweep_exhausted; not via S_DONE.
    saw_hold = False
    saw_done = False
    states_trace = []
    for _ in range(ONE_SWEEP_CYCLES + 32):
        await RisingEdge(dut.clk)
        s = _state(dut)
        states_trace.append(s)
        if s == S_DONE:
            saw_done = True
            break
        if s == S_HOLD:
            saw_hold = True
            break

    assert saw_hold and not saw_done, (
        f"Expected FSM to enter S_HOLD (6) before S_DONE (4) on "
        f"sweep_success. states tail: {states_trace[-16:]}. T3.2 "
        f"S_HOLD entry is broken — sweep_success short-circuited "
        f"to S_DONE, peer-aware hold is not engaged."
    )

    # In S_HOLD, training_mode MUST stay HIGH (T3.2's whole point —
    # keep the TX pattern up so the peer converges) and
    # calibration_done MUST stay 0 (lltx/FCSM still gated until
    # genuine mutual lock).
    tm = int(dut.training_mode.value)
    cd = int(dut.calibration_done.value)
    assert tm == 1, (
        f"In S_HOLD training_mode = {tm}, expected 1. T3.2 contract "
        f"requires training_mode HIGH throughout S_HOLD so the peer "
        f"sees a continuous training pattern."
    )
    assert cd == 0, (
        f"In S_HOLD calibration_done = {cd}, expected 0. lltx/FCSM "
        f"must stay gated until S_DONE."
    )

    # Wait HOLD_CYCLES (the hold_ctr saturates at HOLD_MAX = HOLD_CYCLES-1),
    # then S_HOLD→S_DONE.
    saw_done = False
    for i in range(HOLD_CYCLES + 64):
        await RisingEdge(dut.clk)
        if _state(dut) == S_DONE:
            saw_done = True
            break

    assert saw_done, (
        f"FSM did not exit S_HOLD to S_DONE after {HOLD_CYCLES + 64} "
        f"cycles. T3.2 hold_ctr saturation/release is broken."
    )

    # In S_DONE, calibration_done MUST rise; training_mode MUST drop
    # (the link is no longer training).
    cd = int(dut.calibration_done.value)
    tm = int(dut.training_mode.value)
    assert cd == 1, (
        f"In S_DONE calibration_done = {cd}, expected 1 — the link "
        f"is supposed to release to lltx/FCSM here."
    )
    assert tm == 0, (
        f"In S_DONE training_mode = {tm}, expected 0 — the TX must "
        f"stop emitting the training pattern once we release."
    )

    dut._log.info(
        "OK: T3.2 S_HOLD path — sweep_success enters S_HOLD with "
        "training_mode held HIGH and calibration_done held LOW for "
        f"~{HOLD_CYCLES} cycles, then releases to S_DONE."
    )


@cocotb.test()
async def test_t32_shold_ignores_lane_drop(dut):
    """T3.2 explicit contract: in S_HOLD, do NOT react to lane_locked
    transitions. The latched (slip,phase) is physically correct; the
    peer's transition out of training will (correctly) drop our
    lane_checker — this MUST NOT trigger a re-sweep. The FSM must hold
    in S_HOLD until the HOLD_CYCLES timer expires.
    """
    await _start(dut)

    dut.lane_locked.value = 0xFF
    await _trigger_role_lock(dut)

    # Wait until we are in S_HOLD.
    in_hold = False
    for _ in range(ONE_SWEEP_CYCLES + 32):
        await RisingEdge(dut.clk)
        if _state(dut) == S_HOLD:
            in_hold = True
            break
    assert in_hold, "FSM did not enter S_HOLD — see test_t32_shold_on_success."

    # Now drop lane_locked → simulate the peer switching to real data.
    dut.lane_locked.value = 0x00

    # FSM must stay in S_HOLD (state=6); must NOT transition to S_ARM
    # (re-sweep) or S_SWEEP within the HOLD window.
    cycles_in_hold = 0
    for _ in range(HOLD_CYCLES // 2):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if s != S_HOLD:
            assert s == S_DONE, (
                f"FSM left S_HOLD to state {s} on lane_locked drop. "
                f"S_HOLD must be insensitive to lane_locked — that is "
                f"the explicit T3.2 contract: the peer's transition out "
                f"of training drops our lane_checker, which MUST NOT "
                f"trigger a re-sweep."
            )
            # Reaching S_DONE before half the HOLD window expired would
            # be a bug too — premature release.
            assert False, (
                f"FSM released to S_DONE too early (after "
                f"{cycles_in_hold} HOLD cycles, expected at least "
                f"{HOLD_CYCLES // 2})."
            )
        cycles_in_hold += 1

    dut._log.info(
        f"OK: T3.2 S_HOLD insensitivity — held in S_HOLD for "
        f"{cycles_in_hold} cycles after lane_locked drop, no re-sweep, "
        f"no premature release."
    )


@cocotb.test()
async def test_t3_resweep_advances_counter(dut):
    """T3 resweep_ctr semantics: each S_FINISH→S_ARM auto-rearm
    increments the counter; trigger_now (a fresh role_locked rising /
    swreset-fall edge) clears it. Probes the counter via the
    hierarchical handle u_dut.resweep_ctr.
    """
    await _start(dut)

    # Initial counter must be 0.
    assert int(dut.u_dut.resweep_ctr.value) == 0, (
        "resweep_ctr non-zero out of reset."
    )

    # Trigger calibration with no lanes locked → repeated re-sweeps.
    dut.lane_locked.value = 0x00
    await _trigger_role_lock(dut)

    # Wait for 3 successful re-arms.
    last_state = _state(dut)
    rearms = 0
    for _ in range((ONE_SWEEP_CYCLES + 32) * 4):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if last_state == S_FINISH and s == S_ARM:
            rearms += 1
            if rearms == 3:
                break
        last_state = s

    assert rearms >= 3, (
        f"Saw only {rearms} S_FINISH→S_ARM transitions, expected at "
        f"least 3 — T3 auto re-arm is not happening repeatedly."
    )

    ctr = int(dut.u_dut.resweep_ctr.value)
    dut._log.info(f"After {rearms} re-arms, resweep_ctr = {ctr}")
    assert ctr >= rearms, (
        f"resweep_ctr = {ctr}, expected ≥ {rearms} after that many "
        f"auto re-arms. The counter is not being incremented on "
        f"S_FINISH→S_ARM."
    )

    # Re-trigger via role_locked rising edge: clear role_locked then
    # re-assert. trigger_now must clear resweep_ctr to 0.
    dut.role_locked.value = 0
    await ClockCycles(dut.clk, 8)
    dut.role_locked.value = 1
    # trigger_now is the rising edge of the 2-flop-SYNCHRONISED role_locked
    # (role_locked_s2 & ~role_locked_s3), so it does not pulse until ~3 clocks
    # after the async re-assert. Wait long enough (deps CDC chain) for the
    # synchronised rising edge to fire and clear resweep_ctr on that edge.
    await ClockCycles(dut.clk, 6)
    ctr_after_trigger = int(dut.u_dut.resweep_ctr.value)
    assert ctr_after_trigger == 0, (
        f"After re-trigger (role_locked rising), resweep_ctr = "
        f"{ctr_after_trigger}, expected 0 — trigger_now is not "
        f"clearing the counter."
    )

    dut._log.info(
        "OK: T3 resweep_ctr increments on each S_FINISH→S_ARM "
        "auto-rearm and clears on trigger_now."
    )
