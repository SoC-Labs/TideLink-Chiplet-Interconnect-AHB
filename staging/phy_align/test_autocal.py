"""Cocotb tests for the autonomous PHY-align calibration FSM.

Scope: validate the §9.6 / §2.2 in-RTL calibration sweep without involving
the full Wlink stack. The TB exposes the FSM in isolation; this Python
harness models the per-lane "checker" — for each test scenario we pick a
target slip pattern, watch the FSM's `bit_slip` output, and drive
`lane_locked[i]` high after a few cycles of settling only when the FSM is
currently driving the matching slip for that lane.

Scenarios:
    1. test_uniform_slip          — every lane targets slip=3
    2. test_asymmetric            — target=[3,5,0,2,7,1,4,6]
    3. test_stuck_lane            — lane 4 never locks; expect lane_fault[4]=1
    4. test_apb_override          — mid-sweep override bypasses the FSM
    5. test_swreset_retrigger     — swreset cancels and restarts cleanly
    6. test_recovers_after_done   — second role_locked rising re-runs the
                                    sweep with a new target pattern
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

DWELL_CYCLES = 32
LOCK_LATENCY = 4   # how many cycles after slip matches before we assert
                    # lane_locked[i]. Models the lane-checker's match counter
                    # ramping up; must be < DWELL_CYCLES.

# State enum from the RTL.
S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5


def _get_lane_slip(bit_slip_int, lane):
    return (bit_slip_int >> (3 * lane)) & 0x7


def _build_lane_locked(bit_slip_int, target, match_age):
    """Build the lane_locked[7:0] vector based on which lanes have a matching
    slip *and* have been matching for at least LOCK_LATENCY cycles.

    target[i] = the slip value at which lane i should be allowed to lock,
                or None if that lane should never lock (stuck-fault scenario).
    match_age[i] = number of consecutive cycles bit_slip[i] has equalled
                target[i]. We drive lane_locked[i]=1 once match_age[i] reaches
                LOCK_LATENCY.
    """
    out = 0
    for i in range(8):
        if target[i] is None:
            continue
        if _get_lane_slip(bit_slip_int, i) == target[i] and match_age[i] >= LOCK_LATENCY:
            out |= (1 << i)
    return out


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())


async def _reset(dut):
    dut.rst.value = 1
    dut.role_locked.value = 0
    dut.swreset.value = 0
    dut.lane_locked.value = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def _run_calibration(dut, target, timeout_cycles=2000, abort_signal=None, debug=False):
    """Drive role_locked high and run the sweep, modelling per-lane lock
    behaviour against `target`. target[i] is the slip the lane will lock at,
    or None for "never locks" (fault).

    Returns the final bit_slip integer.

    If abort_signal is a coroutine, run it concurrently — useful for swreset /
    override mid-sweep tests.
    """
    # Clear lane_locked BEFORE triggering, then pulse role_locked. This
    # ensures any stale lane_locked from a previous sweep can't leak into
    # the FSM's first S_SWEEP cycle.
    dut.lane_locked.value = 0
    dut.role_locked.value = 1
    # Allow the value-set to propagate before we enter the per-cycle loop.
    # Without this, on some simulators the next RisingEdge sees the OLD
    # role_locked value and trigger_now never fires.
    await ClockCycles(dut.clk, 1)

    match_age = [0] * 8

    abort_task = None
    if abort_signal is not None:
        abort_task = cocotb.start_soon(abort_signal)

    iter_num = 0
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        iter_num += 1
        bs = int(dut.bit_slip.value)
        try:
            cur_state = int(dut.state.value)
        except Exception:
            cur_state = 0
        # While the FSM hasn't reached S_SWEEP yet, force lane_locked=0 and
        # don't accrue match_age. The FSM is allowed to take a couple of
        # cycles between role_locked_rise and S_SWEEP (S_DONE → S_ARM →
        # S_SWEEP); the model only becomes "live" once the FSM is sweeping.
        if cur_state != S_SWEEP:
            dut.lane_locked.value = 0
            for i in range(8):
                match_age[i] = 0
        else:
            # Track per-lane match age.
            for i in range(8):
                tgt = target[i]
                if tgt is None:
                    match_age[i] = 0
                elif _get_lane_slip(bs, i) == tgt:
                    match_age[i] += 1
                else:
                    match_age[i] = 0
            # Drive lane_locked based on current state.
            new_ll = _build_lane_locked(bs, target, match_age)
            dut.lane_locked.value = new_ll

        try:
            done = int(dut.calibration_done.value)
        except Exception:
            done = 0
        if debug and iter_num < 6:
            dut._log.info(f"    iter {iter_num}: state={cur_state} bs=0x{bs:06x} done={done} ll=0x{int(dut.lane_locked.value):02x}")
        if done == 1:
            break
    else:
        raise AssertionError(
            f"calibration_done never asserted within {timeout_cycles} cycles. "
            f"state={int(dut.state.value)} bit_slip=0x{int(dut.bit_slip.value):06x}"
        )

    if abort_task is not None and not abort_task.done():
        abort_task.kill()

    return int(dut.bit_slip.value)


def _slip_vec(target_list):
    """Pack [s0..s7] into a 24-bit integer matching RTL layout."""
    v = 0
    for i, s in enumerate(target_list):
        v |= (s & 0x7) << (3 * i)
    return v


def _unpack(bs_int):
    return [_get_lane_slip(bs_int, i) for i in range(8)]


# -----------------------------------------------------------------------------
# Test 1: uniform slip = 3
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_uniform_slip(dut):
    await _start_clock(dut)
    await _reset(dut)

    target = [3] * 8
    final_bs = await _run_calibration(dut, target)

    got = _unpack(final_bs)
    dut._log.info(f"  uniform: target={target} got={got}")
    assert got == target, f"slip mismatch: expected {target} got {got}"
    assert int(dut.lane_fault.value) == 0, f"unexpected fault: 0x{int(dut.lane_fault.value):02x}"
    assert int(dut.calibration_done.value) == 1
    assert int(dut.training_mode.value) == 0, "training_mode must drop on done"


# -----------------------------------------------------------------------------
# Test 2: asymmetric per-lane slips
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_asymmetric(dut):
    await _start_clock(dut)
    await _reset(dut)

    target = [3, 5, 0, 2, 7, 1, 4, 6]
    final_bs = await _run_calibration(dut, target)

    got = _unpack(final_bs)
    dut._log.info(f"  asymmetric: target={target} got={got}")
    assert got == target, f"slip mismatch: expected {target} got {got}"
    assert int(dut.lane_fault.value) == 0


# -----------------------------------------------------------------------------
# Test 3: one stuck lane → lane_fault asserted, others done
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_stuck_lane(dut):
    await _start_clock(dut)
    await _reset(dut)

    # Lane 4 never locks; everyone else has a target slip.
    target = [3, 5, 0, 2, None, 1, 4, 6]
    final_bs = await _run_calibration(dut, target, timeout_cycles=3000)

    fault = int(dut.lane_fault.value)
    got = _unpack(final_bs)
    dut._log.info(f"  stuck_lane: target={target} got={got} fault=0x{fault:02x}")

    assert fault == 0x10, f"expected lane_fault[4] only; got 0x{fault:02x}"
    # Non-stuck lanes should still match their targets.
    for i in range(8):
        if target[i] is not None:
            assert got[i] == target[i], (
                f"lane {i}: expected slip {target[i]} got {got[i]}"
            )
    assert int(dut.calibration_done.value) == 1


# -----------------------------------------------------------------------------
# Test 4: APB override mid-sweep — FSM bypassed, slip = override value
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_apb_override(dut):
    await _start_clock(dut)
    await _reset(dut)

    override_target = [7, 6, 5, 4, 3, 2, 1, 0]
    override_vec = _slip_vec(override_target)

    # Pre-arm override before triggering — FSM should never assert
    # training_mode in this mode.
    dut.apb_bit_slip_override.value = override_vec
    dut.apb_override_enable.value = 1
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 20)

    bs = int(dut.bit_slip.value)
    got = _unpack(bs)
    dut._log.info(f"  override: vec=0x{override_vec:06x} got={got}")
    assert got == override_target, f"override mismatch: got {got}"
    assert int(dut.training_mode.value) == 0, "override must not assert training_mode"
    assert int(dut.calibration_done.value) == 1, "override forces calibration_done=1"

    # Now disable override mid-test — the FSM should run its sweep from the
    # appropriate trigger point. Since role_locked has been high the whole
    # time, we need a re-trigger; simulate it with a swreset pulse.
    dut.apb_override_enable.value = 0
    dut.swreset.value = 1
    await ClockCycles(dut.clk, 3)
    dut.swreset.value = 0
    # Run a real sweep with a different target.
    target = [0] * 8
    final_bs = await _run_calibration_no_retrigger(dut, target)
    got = _unpack(final_bs)
    dut._log.info(f"  override-then-fsm: target={target} got={got}")
    assert got == target


async def _run_calibration_no_retrigger(dut, target, timeout_cycles=2000):
    """Like _run_calibration but does NOT re-pulse role_locked; it stays
    high. Used for the override→FSM transition where the FSM re-triggers
    via swreset_fall."""
    dut.lane_locked.value = 0
    match_age = [0] * 8
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        bs = int(dut.bit_slip.value)
        try:
            cur_state = int(dut.state.value)
        except Exception:
            cur_state = 0
        if cur_state != S_SWEEP:
            dut.lane_locked.value = 0
            for i in range(8):
                match_age[i] = 0
        else:
            for i in range(8):
                tgt = target[i]
                if tgt is None:
                    match_age[i] = 0
                elif _get_lane_slip(bs, i) == tgt:
                    match_age[i] += 1
                else:
                    match_age[i] = 0
            dut.lane_locked.value = _build_lane_locked(bs, target, match_age)
        try:
            done = int(dut.calibration_done.value)
        except Exception:
            done = 0
        if done == 1:
            return int(dut.bit_slip.value)
    raise AssertionError("calibration_done never asserted")


# -----------------------------------------------------------------------------
# Test 5: swreset re-trigger
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_swreset_retrigger(dut):
    await _start_clock(dut)
    await _reset(dut)

    target1 = [1, 2, 3, 4, 5, 6, 7, 0]
    # Run a first sweep to completion.
    final_bs1 = await _run_calibration(dut, target1)
    assert _unpack(final_bs1) == target1

    # Pulse swreset → FSM should cancel and re-arm; deasserting swreset
    # triggers a fresh sweep at a different target.
    dut.swreset.value = 1
    await ClockCycles(dut.clk, 5)
    dut.swreset.value = 0
    # The state should transition cancel → arm; calibration_done should drop.
    await ClockCycles(dut.clk, 3)
    assert int(dut.calibration_done.value) == 0, (
        f"calibration_done failed to drop on swreset re-trigger; state={int(dut.state.value)}"
    )

    target2 = [4, 4, 4, 4, 4, 4, 4, 4]
    final_bs2 = await _run_calibration_no_retrigger(dut, target2)
    got2 = _unpack(final_bs2)
    dut._log.info(f"  swreset-retrigger: target={target2} got={got2}")
    assert got2 == target2
    assert int(dut.lane_fault.value) == 0


# -----------------------------------------------------------------------------
# Test 6: second role_locked rising re-runs (link drop → re-up)
# -----------------------------------------------------------------------------
@cocotb.test()
async def test_role_relock(dut):
    await _start_clock(dut)
    await _reset(dut)

    target1 = [3] * 8
    final_bs1 = await _run_calibration(dut, target1)
    assert _unpack(final_bs1) == target1

    # Drop role_locked, then raise it — simulates the link going down and
    # coming back up.
    dut.role_locked.value = 0
    dut.lane_locked.value = 0
    await ClockCycles(dut.clk, 5)

    target2 = [5, 5, 0, 0, 7, 7, 2, 2]
    final_bs2 = await _run_calibration(dut, target2)
    got2 = _unpack(final_bs2)
    dut._log.info(f"  re-lock: target={target2} got={got2}")
    assert got2 == target2
    assert int(dut.lane_fault.value) == 0
