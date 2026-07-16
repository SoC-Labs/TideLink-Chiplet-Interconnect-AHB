"""test_calibrator_centering — FORCE-FULL-SWEEP CENTERING MODE coverage.

THE COMPLETION FIX (2026-06-17). Verifies that when CENTERING MODE is active
(min_lock_dwells_i != 0) the calibrator:

  1. transitions S_ARM -> S_SWEEP DIRECTLY (NEVER enters S_PROBE), and
  2. S_FINALIZE selects the CENTRE of the widest contiguous matched phase run
     (NOT the eye EDGE / NOT (slip=0,phase=0)) on an OFF-CENTRE-eye stimulus.

It also pins the no-regression control: with min_lock_dwells_i == 0 the FSM
still takes the legacy S_ARM -> S_PROBE fast-path.

These run against the DEPLOYED deps/ calibrator only (DEPS=1, tb_top_deps),
which exposes min_lock_dwells_i + the eye-width reads as drivable/observable
ports. The eye is SHAPED by driving lane_locked HIGH only while the live driven
(slip,phase) iterator (read back from bit_slip/phase_offset lane 0) is inside an
off-centre window, so the run-length tracker sees a real off-centre eye.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# FSM state encodings — mirror tidelink_phy_align_calibrator.sv §state-encoding.
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

# TB parameter overrides (must match tb_top_deps.sv defaults).
DWELL_CYCLES = 8

# Off-centre eye: slip=0, contiguous phase run [6..10] (width 5). Run centre =
# 6 + (5-1)//2 = 8. (slip=0, phase=0) — the probe/edge point — is OUTSIDE this
# window, so a centred selection MUST differ from the broken (0,0) edge latch.
EYE_SLIP        = 0
EYE_PHASE_LO    = 6
EYE_PHASE_HI    = 10
EYE_CENTRE      = EYE_PHASE_LO + (EYE_PHASE_HI - EYE_PHASE_LO) // 2  # = 8
MIN_LOCK_DWELLS = 3   # effective centering width gate (< run width 5)


def _state(dut):
    return int(dut.state.value)


def _lane0_slip(dut):
    # bit_slip is 8x3b, lane 0 at [2:0].
    return int(dut.bit_slip.value) & 0x7


def _lane0_phase(dut):
    # phase_offset is 8x4b, lane 0 at [3:0].
    return int(dut.phase_offset.value) & 0xF


async def _start(dut, min_lock_dwells):
    """Boot the deps calibrator TB with a clean reset + centering knob."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.min_lock_dwells_i.value     = min_lock_dwells
    dut.eye_lane_sel.value          = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


def _in_eye(slip, phase):
    return slip == EYE_SLIP and EYE_PHASE_LO <= phase <= EYE_PHASE_HI


@cocotb.test()
async def test_centering_goes_arm_to_sweep_not_probe(dut):
    """min_lock_dwells_i != 0 => S_ARM -> S_SWEEP directly, NEVER S_PROBE."""
    await _start(dut, MIN_LOCK_DWELLS)
    dut.role_locked.value = 1

    saw_arm = False
    saw_sweep = False
    for _ in range(64):
        await RisingEdge(dut.clk)
        s = _state(dut)
        assert s != S_PROBE, (
            "FSM entered S_PROBE in centering mode; expected S_ARM -> S_SWEEP "
            "directly (probe bypass)."
        )
        if s == S_ARM:
            saw_arm = True
        if s == S_SWEEP:
            saw_sweep = True
            break
    assert saw_arm, "S_ARM never observed."
    assert saw_sweep, "S_SWEEP never reached (centering bypass failed)."
    dut._log.info("PASS: centering mode S_ARM -> S_SWEEP, no S_PROBE detour.")


@cocotb.test()
async def test_centering_selects_run_centre_offcentre_eye(dut):
    """Off-centre eye [6..10] @ slip0 → S_FINALIZE latches the run CENTRE
    (phase 8), NOT the edge / (0,0). Eye is shaped by gating lane_locked on the
    live driven (slip,phase) iterator."""
    await _start(dut, MIN_LOCK_DWELLS)
    dut.role_locked.value = 1

    reached_finalize = False
    latched_phase = None
    latched_slip = None
    # Walk the sweep; gate lane_locked on the live iterator each cycle, and
    # capture the latched lane-0 (slip,phase) at S_FINALIZE entry.
    for _ in range(16 * 8 * DWELL_CYCLES + 256):
        await RisingEdge(dut.clk)
        s = _state(dut)
        # Shape the eye: all 8 lanes lock iff the driven iterator is in-window.
        slip = _lane0_slip(dut)
        phase = _lane0_phase(dut)
        dut.lane_locked.value = 0xFF if _in_eye(slip, phase) else 0x00
        assert s != S_PROBE, "S_PROBE entered in centering mode."
        if s == S_FINALIZE and not reached_finalize:
            reached_finalize = True
            # One cycle after S_FINALIZE the per-lane latch is committed; the
            # output mux then drives slip[]/phase[] for the now-done lanes.
            await RisingEdge(dut.clk)
            latched_slip = _lane0_slip(dut)
            latched_phase = _lane0_phase(dut)
            break

    assert reached_finalize, "S_FINALIZE never reached (sweep did not run)."
    # Read the eye-width visibility for lane 0 as corroboration.
    dut.eye_lane_sel.value = 0
    await RisingEdge(dut.clk)
    best = int(dut.eye_score_best.value)
    best_phase = int(dut.eye_score_best_phase.value)
    best_slip = int(dut.eye_score_best_slip.value)

    dut._log.info(
        f"latched lane0 (slip={latched_slip}, phase={latched_phase}); "
        f"eye-vis best_run={best} start_phase={best_phase} slip={best_slip}"
    )
    assert latched_slip == EYE_SLIP, (
        f"latched slip={latched_slip}, expected {EYE_SLIP}."
    )
    assert latched_phase != 0, (
        "latched phase=0 — eye-centre arm did NOT fire (regressed to the "
        "(0,0) edge, the silicon bug)."
    )
    # Allow +/-1 for dwell-boundary run-start sampling jitter.
    assert abs(latched_phase - EYE_CENTRE) <= 1, (
        f"latched phase={latched_phase}, expected ~{EYE_CENTRE} (centre of "
        f"the [{EYE_PHASE_LO}..{EYE_PHASE_HI}] run)."
    )
    assert best >= MIN_LOCK_DWELLS, (
        f"eye-vis best_run={best} < MIN_LOCK_DWELLS={MIN_LOCK_DWELLS}."
    )
    dut._log.info(
        f"PASS: centering latched phase={latched_phase} ~ centre {EYE_CENTRE} "
        f"(NOT the (0,0) edge)."
    )


@cocotb.test()
async def test_no_centering_takes_probe_fastpath(dut):
    """Control: min_lock_dwells_i == 0 => legacy S_ARM -> S_PROBE fast-path
    (no-regression guarantee)."""
    await _start(dut, 0)
    dut.lane_locked.value = 0xFF   # all lanes lock at (0,0) immediately
    dut.role_locked.value = 1

    saw_probe = False
    for _ in range(64):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if s == S_PROBE:
            saw_probe = True
            break
        if s == S_SWEEP:
            raise AssertionError(
                "S_SWEEP entered with min_lock_dwells_i==0; legacy build must "
                "take the S_ARM -> S_PROBE fast-path."
            )
    assert saw_probe, "S_PROBE never reached with centering off (regression)."
    dut._log.info("PASS: min_lock_dwells_i==0 keeps the S_PROBE fast-path.")
