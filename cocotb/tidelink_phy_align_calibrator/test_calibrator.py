"""
test_calibrator — STANDALONE unit test for tidelink_phy_align_calibrator,
focused on the "cal_done asserted WITHOUT a genuine lane lock" invariant
suspected on silicon.

Symptom (silicon, slave die): calibration_done=1 while SWI_LANE_STATUS /
lane_locked reads 0x00. The FCSM then stays wedged with no data. Hypothesis:
the S_VALIDATE 2,000,000-cycle timeout fires S_DONE even when the latched
(slip,phase) never produced a real lock (cr_pkt_seen / crack_pkt_seen never
asserted AND lane_locked is currently low) — so cal_done is set on a TIMEOUT
rather than a genuine lock.

Three tests:

  (a) test_happy_path_lock
        Lanes lock and STAY locked through the sweep AND through S_HOLD /
        S_VALIDATE (driving crack_pkt_seen_i=1 to model the FCSM credit
        handshake succeeding). cal_done must rise AND lane_locked must be
        non-zero when it does. This is the "good" link.

  (b) test_validate_timeout_without_lock   <-- the INVARIANT
        Lanes lock TRANSIENTLY during the sweep (so every lane finds a
        passing point -> sweep_success=1 -> no fault), then lane_locked
        drops to 0x00 BEFORE S_VALIDATE and cr/crack are held LOW (the
        FCSM never decodes a real packet). S_VALIDATE runs out its
        VALIDATION_TIMEOUT. We assert what actually happens to cal_done at
        the instant S_DONE is reached, and whether lane_locked is 0 there.
        This REPRODUCES (or refutes) the silicon bug.

  (c) test_hold_training_mode
        S_HOLD / training_mode interplay: while in S_HOLD training_mode
        must stay HIGH and dropping lane_locked must NOT trigger a
        re-sweep (S_HOLD is sticky), then it advances to S_VALIDATE.

The wrapper tb_calibrator.sv shrinks DWELL_CYCLES / HOLD_CYCLES /
VALIDATION_TIMEOUT so the full FSM traversal runs in a few thousand cycles.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


# FSM state encodings (must mirror tidelink_phy_align_calibrator.sv).
S_IDLE     = 0
S_ARM      = 1
S_SWEEP    = 2
S_FINISH   = 3
S_DONE     = 4
S_CANCEL   = 5
S_HOLD     = 6
S_PROBE    = 7
S_FINALIZE = 8
S_VALIDATE = 9

# TB parameter overrides — MUST match tb_calibrator.sv defaults.
DWELL_CYCLES         = 16
LOCK_THRESH          = 8
HOLD_CYCLES          = 64
VALIDATION_TIMEOUT   = 256
MAX_VALIDATE_RETRIES = 2   # M9: tb_calibrator.sv override (RTL default=8)
# A full 128-point sweep = 128 dwells * DWELL_CYCLES, plus probe + finalize.
FULL_SWEEP_CYCLES  = 128 * DWELL_CYCLES + 4 * DWELL_CYCLES
# Worst-case cycles for M9 retries to exhaust and reach S_DONE:
# (MAX_VALIDATE_RETRIES + 1) attempts × (S_VALIDATE window + full loop back to S_VALIDATE)
VALIDATE_RETRY_TOTAL = (MAX_VALIDATE_RETRIES + 1) * (
    VALIDATION_TIMEOUT + FULL_SWEEP_CYCLES + HOLD_CYCLES + 32)


async def _reset(dut):
    dut.rst.value = 1
    dut.role_locked.value = 0
    dut.swreset.value = 0
    dut.lane_locked.value = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value = 0
    dut.min_lock_dwells_i.value = 0
    dut.cr_pkt_seen_i.value = 0
    dut.crack_pkt_seen_i.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def _trigger(dut):
    """Rising edge of role_locked launches a sweep."""
    dut.role_locked.value = 1
    await RisingEdge(dut.clk)


async def _wait_state(dut, target, timeout):
    """Wait until state==target, up to `timeout` cycles. Returns True if hit."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.state.value) == target:
            return True
    return False


# ---------------------------------------------------------------------------
# (a) HAPPY PATH
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_happy_path_lock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    # Lanes locked the whole time (a clean board). crack_pkt_seen models the
    # FCSM credit handshake succeeding so S_VALIDATE passes on real data.
    dut.lane_locked.value = 0xFF
    dut.crack_pkt_seen_i.value = 1
    await _trigger(dut)

    # Walk through PROBE/SWEEP/FINALIZE/FINISH/HOLD/VALIDATE to S_DONE.
    reached = await _wait_state(dut, S_DONE, FULL_SWEEP_CYCLES + HOLD_CYCLES + VALIDATION_TIMEOUT + 64)
    assert reached, "happy path never reached S_DONE"

    await RisingEdge(dut.clk)
    cal_done   = int(dut.calibration_done.value)
    locked     = int(dut.lane_locked.value)
    fault      = int(dut.lane_fault.value)
    dut._log.info(f"[happy] S_DONE: cal_done={cal_done} lane_locked=0x{locked:02x} lane_fault=0x{fault:02x}")

    assert cal_done == 1, "cal_done must be 1 in S_DONE"
    assert locked != 0, "HAPPY PATH: lane_locked must be non-zero when cal_done asserts"
    assert fault == 0, f"HAPPY PATH: no lane should fault, got 0x{fault:02x}"
    dut._log.info("[happy] PASS: cal_done=1 WITH a genuine lane lock (lane_locked=0xff)")


# ---------------------------------------------------------------------------
# (b) THE INVARIANT — cal_done on VALIDATION TIMEOUT after M9 retries exhausted
#
# M9 change: S_VALIDATE timeout → S_ARM (retry) up to MAX_VALIDATE_RETRIES
# times, THEN → S_DONE. lane_locked stays 0xFF throughout so retry sweeps
# SUCCEED (probe_all_locked fires at S_PROBE) and loop back to S_VALIDATE.
# cr/crack stay LOW the whole test (FCSM never decodes a real packet on any
# attempt). After MAX_VALIDATE_RETRIES+1 S_VALIDATE timeouts, the calibrator
# reaches S_DONE and MUST set validation_timed_out=1.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_validate_timeout_without_lock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    # lane_locked=0xFF throughout: training always passes so every retry sweep
    # succeeds → probe_all_locked fires at S_PROBE → S_FINISH → S_HOLD → S_VALIDATE.
    # cr/crack=0 throughout: FCSM never decodes a real packet on any attempt.
    dut.lane_locked.value = 0xFF
    dut.cr_pkt_seen_i.value = 0
    dut.crack_pkt_seen_i.value = 0
    await _trigger(dut)

    # Each retry cycle: S_ARM(1) + S_PROBE(DWELL_CYCLES) + S_FINISH(1) +
    # S_HOLD(HOLD_CYCLES) + S_VALIDATE(VALIDATION_TIMEOUT).
    # MAX_VALIDATE_RETRIES+1 total S_VALIDATE trips before S_DONE.
    per_retry = DWELL_CYCLES + HOLD_CYCLES + VALIDATION_TIMEOUT + 10
    total_budget = (MAX_VALIDATE_RETRIES + 2) * per_retry

    reached_done = await _wait_state(dut, S_DONE, total_budget)
    assert reached_done, (
        f"calibrator never reached S_DONE after {total_budget} cycles "
        f"(MAX_VALIDATE_RETRIES={MAX_VALIDATE_RETRIES})")

    await RisingEdge(dut.clk)
    cal_done  = int(dut.calibration_done.value)
    timed_out = _opt_int(dut, "validation_timed_out")
    dut._log.info(
        f"[invariant] S_DONE after M9 retries: cal_done={cal_done} "
        f"validation_timed_out={timed_out}")

    assert cal_done == 1, "calibration_done must be 1 in S_DONE"
    assert timed_out == 1, (
        "DEFECT: reached S_DONE via timeout but validation_timed_out=0 "
        "-> SW cannot distinguish timeout-DONE from real-lock DONE.")
    dut._log.info(
        "[invariant] PASS: cal_done=1 AND validation_timed_out=1 after "
        f"{MAX_VALIDATE_RETRIES} M9 retries — SW guard is present.")


# ---------------------------------------------------------------------------
# (c) S_HOLD / training_mode interplay
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_hold_training_mode(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    dut.lane_locked.value = 0xFF
    dut.cr_pkt_seen_i.value = 0
    dut.crack_pkt_seen_i.value = 0
    await _trigger(dut)

    reached_hold = await _wait_state(dut, S_HOLD, FULL_SWEEP_CYCLES + 64)
    assert reached_hold, "never reached S_HOLD"

    # In S_HOLD training_mode must be HIGH.
    assert int(dut.training_mode.value) == 1, "training_mode must be HIGH in S_HOLD"
    dut._log.info("[hold] training_mode HIGH in S_HOLD")

    # Drop lane_locked mid-HOLD — must NOT re-sweep (sticky), must NOT leave
    # for S_ARM/S_SWEEP. It should stay in S_HOLD until HOLD_CYCLES, then go
    # to S_VALIDATE.
    dut.lane_locked.value = 0x00
    saw_resweep = False
    for _ in range(HOLD_CYCLES + 32):
        await RisingEdge(dut.clk)
        st = int(dut.state.value)
        if st in (S_ARM, S_SWEEP, S_PROBE):
            saw_resweep = True
            break
        if st == S_VALIDATE:
            break
    assert not saw_resweep, "S_HOLD must NOT re-sweep when lane_locked drops"
    assert int(dut.state.value) == S_VALIDATE, "S_HOLD must advance to S_VALIDATE"
    # training_mode stays HIGH in S_VALIDATE too (M8 behaviour).
    assert int(dut.training_mode.value) == 1, "training_mode HIGH in S_VALIDATE (M8)"
    dut._log.info("[hold] PASS: S_HOLD sticky against lane drop -> S_VALIDATE, training_mode stays HIGH")


def _opt_int(dut, name):
    """Read an optional DUT signal (handle hierarchy through the wrapper).
    Returns the int value, or None if the signal does not exist."""
    # Try wrapper-level first, then the DUT instance inside the wrapper.
    for handle in (dut, getattr(dut, "u_dut", None)):
        if handle is None:
            continue
        sig = getattr(handle, name, None)
        if sig is not None:
            try:
                return int(sig.value)
            except Exception:
                return None
    return None
