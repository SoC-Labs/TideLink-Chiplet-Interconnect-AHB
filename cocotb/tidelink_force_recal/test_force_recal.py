"""
test_force_recal — P1 FORCED-RECAL W1P (2026-07-19, lane B1).

WHAT THIS PROVES
================

The defect (docs/LINK_RECOVERY_MECHANISM.md §4): the calibrator latches
`calibrated_once_q` on its FIRST S_DONE and from then on gates off BOTH
re-trigger edges, so `SWI_RECAL` is a no-op after first lock and there was NO
firmware-reachable PHY retrain at all — in the FPGA image AND the ASIC path.
That doc measured it on the pair TB (FSM sampled 60x on both dies, never left
S_DONE). This bench reproduces it at the UNIT level and then proves the fix.

The fix is ADDITIVE, so the same build carries both arms — the baseline is not
a different build, it is a different STIMULUS:

  test_1  baseline / control : swreset (== SWI_RECAL) pulse after first lock
                               must be a NO-OP. Reproduces the defect AND
                               proves the Bug-A guard is untouched.
  test_2  baseline / control : role_locked re-pulse after first lock must be a
                               NO-OP (the other gated edge).
  test_3  THE FIX            : force_recal_i pulse must re-arm — FSM LEAVES
                               S_DONE, re-runs a real sweep, re-converges, and
                               calibration_done re-asserts.
  test_4  guard preserved    : after a forced recal, an SWI_RECAL pulse is
                               STILL a no-op. This is the load-bearing test —
                               it proves calibrated_once_q was BYPASSED for one
                               arming, not CLEARED, so the Bug-A protection is
                               identical before, during and after.
  test_5  default-off        : with force_recal_i held 0 for the whole run the
                               FSM never re-arms — the new port cannot fire on
                               its own.
  test_6  qualified          : force_recal_i with role_locked=0 must NOT arm
                               (same qualification the swreset path carries).

Bug-A (what calibrated_once_q protects, and must keep protecting): in autonomous
I2C bring-up the winner's autoneg ST_TRAIN_EXIT pulses SWI_RECAL 0->1->0 while
the calibrator is ALREADY in S_DONE. That falling edge re-asserted training_mode
and squelched the master's CR/CRACK framing mid-FCSM-credit-init, wedging the
master at FCSM state 2 with ZERO TX credit. test_1 and test_4 are that
regression.

Runs against BOTH calibrators (they carry the same sticky and the same fix):
    make                 # V2 override — flists/tidelink_fpga_v2.flist +
                         #   tidelink_top_full_asic_v2.flist (FPGA + TAPEOUT)
    make RTL=v1          # V1 src/rtl — flists/tidelink_fpga.flist +
                         #   tidelink_top_full_asic.flist

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# FSM state encodings (mirror tidelink_phy_align_calibrator.sv).
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

# TB parameter overrides (must match tb_force_recal_v*.sv).
DWELL_CYCLES = 8
HOLD_CYCLES  = 64

# A full 128-point sweep = 16 phase x 8 slip x DWELL_CYCLES, plus the
# ARM/PROBE/FINALIZE/FINISH/HOLD/VALIDATE overhead. Generous ceiling.
CONVERGE_TIMEOUT = 16 * 8 * DWELL_CYCLES + HOLD_CYCLES + 2048

# The doc sampled the FSM 60x looking for S_DONE -> S_ARM. Match that, with
# margin: a re-arm would show within a couple of cycles of the trigger.
NOOP_SAMPLES = 120


def _state(dut):
    return int(dut.state.value)


async def _start(dut):
    """Start clock, drive a clean reset, settle all inputs to safe defaults."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.force_recal_i.value         = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.min_lock_dwells_i.value     = 0
    # Validation oracle high: S_VALIDATE confirms on real data promptly so the
    # FSM reaches a genuine (not timed-out) S_DONE.
    dut.cr_pkt_seen_i.value         = 1
    dut.crack_pkt_seen_i.value      = 1
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


async def _converge_to_done(dut, what="first lock"):
    """Drive a cold bring-up to a genuine S_DONE and assert we got there."""
    dut.lane_locked.value  = 0xFF          # every lane locks in every dwell
    dut.role_locked.value  = 1             # rising edge = the cold-boot trigger
    for _ in range(CONVERGE_TIMEOUT):
        await RisingEdge(dut.clk)
        if _state(dut) == S_DONE:
            break
    assert _state(dut) == S_DONE, (
        f"calibrator never reached S_DONE ({what}); final state={_state(dut)}. "
        f"The bench cannot test a re-trigger without a converged starting point."
    )
    # Let calibrated_once_q latch and the FSM settle.
    await ClockCycles(dut.clk, 8)
    assert int(dut.calibration_done.value) == 1, (
        "calibration_done should be high in S_DONE"
    )


async def _pulse(dut, sig, high_cycles=16):
    """Drive a 0->1->0 pulse on a named DUT input, wide enough to clear the
    3-FF synchroniser inside the calibrator."""
    getattr(dut, sig).value = 1
    await ClockCycles(dut.clk, high_cycles)
    getattr(dut, sig).value = 0
    await ClockCycles(dut.clk, 4)


async def _record(dut, cycles, trace, flags):
    """Background recorder: sample the FSM state EVERY cycle.

    Polling after the fact is not good enough here. With all lanes locked at
    (0,0) the calibrator takes the RTL's probe fast-path
    (probe_all_locked -> S_FINISH, ~DWELL_CYCLES=8 cycles in S_PROBE), so the
    re-calibration window is only a handful of cycles wide and a checker that
    starts sampling ~20 cycles after the trigger misses it entirely and
    wrongly concludes "never re-calibrated".
    """
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        trace.append(_state(dut))
        if int(dut.training_mode.value) == 1:
            flags["training_mode_seen"] = True


async def _assert_stays_in_done(dut, why):
    """Sample the FSM NOOP_SAMPLES times; it must never leave S_DONE."""
    seen = []
    for _ in range(NOOP_SAMPLES):
        await RisingEdge(dut.clk)
        st = _state(dut)
        seen.append(st)
        if st != S_DONE:
            raise AssertionError(
                f"{why}: FSM LEFT S_DONE (saw state={st} after "
                f"{len(seen)} samples). states={seen[:24]}"
            )
    assert int(dut.calibration_done.value) == 1, (
        f"{why}: calibration_done dropped while parked in S_DONE"
    )


async def _force_recal_and_assert_rearms(dut, why):
    """Pulse force_recal_i with a cycle-accurate recorder running, then assert
    the calibrator GENUINELY re-ran: left S_DONE, entered the calibration path,
    re-asserted training_mode, and re-converged to S_DONE."""
    trace = []
    flags = {"training_mode_seen": False}
    rec = cocotb.start_soon(_record(dut, CONVERGE_TIMEOUT, trace, flags))

    await _pulse(dut, "force_recal_i")

    # Wait for re-convergence (or the recorder to run out).
    for _ in range(CONVERGE_TIMEOUT - 64):
        await RisingEdge(dut.clk)
        if len(trace) > 32 and _state(dut) == S_DONE and S_ARM in trace:
            break
    rec.kill()

    assert any(st != S_DONE for st in trace), (
        f"{why}: FSM NEVER left S_DONE — the forced recal did not re-arm the "
        f"calibrator. This is exactly the defect the fix is supposed to close. "
        f"trace={trace[:32]}"
    )
    assert S_ARM in trace, (
        f"{why}: FSM left S_DONE but never passed through S_ARM. trace={trace[:32]}"
    )
    # A genuine re-calibration, not a flicker: the FSM must actually enter the
    # alignment-search path. Either arm is legitimate — S_PROBE fast-paths to
    # S_FINISH when all lanes pass at (0,0), otherwise the full S_SWEEP runs.
    assert (S_PROBE in trace) or (S_SWEEP in trace), (
        f"{why}: FSM re-armed but never entered S_PROBE/S_SWEEP — it did not "
        f"actually re-calibrate. trace={trace[:32]}"
    )
    assert flags["training_mode_seen"], (
        f"{why}: training_mode was never re-asserted during the forced recal — "
        f"the PHY was never actually put back into training."
    )
    assert _state(dut) == S_DONE, (
        f"{why}: FSM re-armed but never RE-CONVERGED to S_DONE "
        f"(final state={_state(dut)}) — a recal that cannot finish is worse "
        f"than no recal. trace={trace[:48]}"
    )
    await ClockCycles(dut.clk, 4)
    assert int(dut.calibration_done.value) == 1, (
        f"{why}: calibration_done did not re-assert after the forced recal"
    )
    assert int(dut.lane_fault.value) == 0, (
        f"{why}: lanes faulted on the forced re-sweep "
        f"(lane_fault=0x{int(dut.lane_fault.value):02x})"
    )
    return trace


# =============================================================================
# BASELINE / CONTROL — the defect, and the Bug-A guard that causes it
# =============================================================================

@cocotb.test()
async def test_1_baseline_swi_recal_is_noop_after_lock(dut):
    """BASELINE (defect reproduction + Bug-A regression).

    After first lock, a swreset (== SWI_RECAL) 0->1->0 pulse with role_locked
    still high must NOT re-arm the calibrator. This is the measured defect
    (LINK_RECOVERY_MECHANISM.md §4) and simultaneously the Bug-A guard: the
    autoneg winner's ST_TRAIN_EXIT pulse arrives on exactly this port and must
    keep being rejected on a converged eye.
    """
    await _start(dut)
    await _converge_to_done(dut)

    await _pulse(dut, "swreset")
    await _assert_stays_in_done(
        dut, "SWI_RECAL (swreset) pulse after first lock"
    )


@cocotb.test()
async def test_2_baseline_role_lock_repulse_is_noop_after_lock(dut):
    """BASELINE: the OTHER gated edge. A role_locked 1->0->1 re-pulse after
    first lock must also be rejected (calibrated_once_q gates both)."""
    await _start(dut)
    await _converge_to_done(dut)

    dut.role_locked.value = 0
    await ClockCycles(dut.clk, 16)
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 4)

    await _assert_stays_in_done(dut, "role_locked re-pulse after first lock")


# =============================================================================
# THE FIX
# =============================================================================

@cocotb.test()
async def test_3_force_recal_rearms_after_lock(dut):
    """THE FIX: a force_recal_i pulse on an already-converged calibrator must
    genuinely re-run the calibration — leave S_DONE, re-assert training_mode,
    sweep, and re-converge with calibration_done re-asserted.

    Contrast with test_1: identical starting state, identical link, only the
    trigger port differs.
    """
    await _start(dut)
    await _converge_to_done(dut)

    trace = await _force_recal_and_assert_rearms(
        dut, "SWI_FORCE_RECAL pulse after first lock"
    )
    dut._log.info("forced-recal FSM trace (first 32): %s", trace[:32])


@cocotb.test()
async def test_4_sticky_still_guards_after_forced_recal(dut):
    """LOAD-BEARING: the forced recal must BYPASS calibrated_once_q for one
    arming, NOT clear it.

    After a forced recal has completed, an SWI_RECAL pulse must STILL be a
    no-op. If the fix had cleared the sticky, the Bug-A hole would be re-opened
    for every subsequent autoneg training-exit pulse — the regression that
    wedged the master FCSM at state 2 with zero TX credit.
    """
    await _start(dut)
    await _converge_to_done(dut)

    # One forced recal, all the way back to a converged S_DONE.
    await _force_recal_and_assert_rearms(
        dut, "forced recal (setup for the guard check)"
    )

    # The implicit door must still be shut.
    await _pulse(dut, "swreset")
    await _assert_stays_in_done(
        dut,
        "SWI_RECAL pulse AFTER a forced recal (calibrated_once_q must still "
        "be set — the fix must bypass it for one arming, never clear it)",
    )

    # ...and so must the other one.
    dut.role_locked.value = 0
    await ClockCycles(dut.clk, 16)
    dut.role_locked.value = 1
    await ClockCycles(dut.clk, 4)
    await _assert_stays_in_done(
        dut, "role_locked re-pulse AFTER a forced recal"
    )


@cocotb.test()
async def test_5_default_off_never_rearms(dut):
    """DEFAULT-OFF: with force_recal_i held 0 for the entire run, the FSM must
    park in S_DONE and stay there. The new port cannot self-trigger, so a build
    whose firmware never writes SWI_FORCE_RECAL behaves exactly as today."""
    await _start(dut)
    await _converge_to_done(dut)

    assert int(dut.force_recal_i.value) == 0
    await _assert_stays_in_done(dut, "force_recal_i held 0 (default-off)")


@cocotb.test()
async def test_6_force_recal_requires_role_locked(dut):
    """QUALIFICATION: force_recal_i is qualified by role_locked, exactly as the
    swreset path is — never launch a sweep on a link whose role is not locked.
    """
    await _start(dut)
    await _converge_to_done(dut)

    dut.role_locked.value = 0
    await ClockCycles(dut.clk, 16)

    await _pulse(dut, "force_recal_i")
    await _assert_stays_in_done(
        dut, "force_recal_i pulsed while role_locked=0 (must be ignored)"
    )
