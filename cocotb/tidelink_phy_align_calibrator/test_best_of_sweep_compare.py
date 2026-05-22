"""§9.9 best-of-sweep widest-eye selection — unit test.

Drives a single tb_top that instantiates TWO copies of
`tidelink_phy_align_calibrator`:

  * u_dut_best  — EARLY_EXIT_ON_ALL_LOCKED = 1'b0  (silicon default,
                  best-of-sweep widest-eye latch)
  * u_dut_first — EARLY_EXIT_ON_ALL_LOCKED = 1'b1  (legacy §9.7
                  first-match-wins behaviour)

Both DUTs see THE SAME externally-driven `lane_locked[7:0]` trajectory.
The cocotb driver computes that trajectory from the BEST DUT's current
sweep iterator (sweep_slip, sweep_phase, dwell_ctr) so we can paint
deterministic per-(slip,phase) lock-duration patterns:

  * Lanes 1..7  — lane_locked held HIGH every cycle.  Both DUTs lock
    them at the FIRST iterator point (slip=0, phase=0).  No difference
    in selection between policies for these lanes — the score at (0,0)
    saturates DWELL_CYCLES; later points tie and `lane_score > best_score`
    is strict, so best_slip/best_phase do not move.

  * Lane 0      — the "eye-edge marginal" lane.  HIGH for ONLY 18
    consecutive cycles at (slip=0, phase=0) (just over LOCK_THRESH=16),
    then drops.  HIGH for the FULL DWELL_CYCLES (32) at (slip=3, phase=5).
    LOW everywhere else.

  Expected outcome:
    first-match picks (slip=0, phase=0)  — first eye edge it sees
    best-of-sweep picks (slip=3, phase=5)  — widest eye (longest run)

That difference is the entire point of the §9.9 change: a marginal lane
that JUST barely clears LOCK_THRESH at the first eye edge no longer
locks the calibrator to that edge for the rest of the link lifetime.

Invocation (from cocotb/phy_align_calibrator/):
    rm -rf sim_build && make
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# Must match the tb_top.sv parameters.
DWELL_CYCLES = 32
LOCK_THRESH  = 16

# Marginal lane stimulus: lane 0 locked for 18 cycles at (0,0), then drops.
MARGINAL_RUN_LEN = 18
MARGINAL_SLIP    = 0
MARGINAL_PHASE   = 0

# Widest-eye stimulus: lane 0 locked for the full dwell at (3, 5).
WIDE_SLIP        = 3
WIDE_PHASE       = 5


def _lane_locked_for(sweep_slip, sweep_phase, dwell_ctr):
    """Compute lane_locked[7:0] for the BEST DUT's current iterator value.

    Lanes 1..7 always HIGH (uninteresting — both policies agree).
    Lane 0 is the eye-edge-marginal lane (see module docstring).
    """
    vec = 0xFE  # bits 7..1 always HIGH
    lane0 = 0
    if sweep_slip == MARGINAL_SLIP and sweep_phase == MARGINAL_PHASE:
        # Eye-edge marginal: HIGH for the first MARGINAL_RUN_LEN cycles of
        # the dwell, then drop.
        if dwell_ctr < MARGINAL_RUN_LEN:
            lane0 = 1
    elif sweep_slip == WIDE_SLIP and sweep_phase == WIDE_PHASE:
        lane0 = 1
    vec |= lane0 & 0x1
    return vec


def _lane_field(packed, lane, bits):
    """Extract the per-lane field from a packed bus (3-bit slip / 4-bit phase)."""
    mask = (1 << bits) - 1
    return (packed >> (bits * lane)) & mask


@cocotb.test()
async def test_best_of_sweep_picks_widest_eye(dut):
    """Best-of-sweep latches (WIDE_SLIP, WIDE_PHASE) for lane 0; the
    first-match DUT (driven by the IDENTICAL stimulus) latches the
    marginal-edge pair (MARGINAL_SLIP, MARGINAL_PHASE).  This is the
    §9.9 widest-eye latch property."""

    # --- Clock + reset --------------------------------------------------
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())  # 100 MHz
    dut.rst.value         = 1
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)

    # --- Stimulus driver ------------------------------------------------
    # Co-routine: each cycle read the BEST DUT's iterator + dwell counter
    # and compute lane_locked for both DUTs (they see the same input).
    async def _drive_lane_locked():
        while True:
            await RisingEdge(dut.clk)
            sweep_slip  = int(dut.u_dut_best.sweep_slip.value)
            sweep_phase = int(dut.u_dut_best.sweep_phase.value)
            dwell_ctr   = int(dut.u_dut_best.dwell_ctr.value)
            dut.lane_locked.value = _lane_locked_for(sweep_slip, sweep_phase, dwell_ctr)

    drv = cocotb.start_soon(_drive_lane_locked())

    # --- Trigger calibration -------------------------------------------
    # Both DUTs trigger on the rising edge of role_locked.
    await ClockCycles(dut.clk, 2)
    dut.role_locked.value = 1

    # --- Wait for the best-of-sweep DUT to finish its sweep ------------
    # Full sweep = 128 iterator points × DWELL_CYCLES = 128*32 = 4096 cycles.
    # Add settle margin (a few extra dwells) — the best-of-sweep DUT then
    # transitions S_SWEEP → S_FINISH → S_HOLD (no fault on lane 0 since
    # WIDE pair always meets LOCK_THRESH).  Wait until state>=3 (FINISH
    # or HOLD or DONE).
    settle_budget = 128 * DWELL_CYCLES + 200
    best_state = 0
    for _ in range(settle_budget):
        await RisingEdge(dut.clk)
        best_state = int(dut.best_state.value)
        if best_state >= 3:   # S_FINISH or beyond
            break
    assert best_state >= 3, (
        f"best-of-sweep DUT did not exit S_SWEEP within {settle_budget} cycles "
        f"(state={best_state})"
    )

    # First-match DUT exits the sweep much earlier — by this point it has
    # been in S_HOLD for a while.  Verify it's done sweeping too.
    first_state = int(dut.first_state.value)
    assert first_state >= 3, (
        f"first-match DUT also expected to be past sweep "
        f"(state={first_state})"
    )

    drv.cancel()

    # --- Read out the latched per-lane (slip, phase) -------------------
    best_bs   = int(dut.best_bit_slip.value)
    best_po   = int(dut.best_phase_offset.value)
    first_bs  = int(dut.first_bit_slip.value)
    first_po  = int(dut.first_phase_offset.value)
    best_fault  = int(dut.best_lane_fault.value)
    first_fault = int(dut.first_lane_fault.value)

    best_slip0   = _lane_field(best_bs,   0, 3)
    best_phase0  = _lane_field(best_po,   0, 4)
    first_slip0  = _lane_field(first_bs,  0, 3)
    first_phase0 = _lane_field(first_po,  0, 4)

    dut._log.info(
        f"  best  lane0  (slip,phase) = ({best_slip0},{best_phase0})  "
        f"fault=0x{best_fault:02x}  bit_slip=0x{best_bs:06x}  "
        f"phase_offset=0x{best_po:08x}"
    )
    dut._log.info(
        f"  first lane0  (slip,phase) = ({first_slip0},{first_phase0}) "
        f"fault=0x{first_fault:02x}  bit_slip=0x{first_bs:06x}  "
        f"phase_offset=0x{first_po:08x}"
    )

    # --- Core §9.9 assertion -------------------------------------------
    # First-match: picks the marginal eye edge.
    assert (first_slip0, first_phase0) == (MARGINAL_SLIP, MARGINAL_PHASE), (
        f"first-match DUT should latch lane 0 at "
        f"(slip={MARGINAL_SLIP}, phase={MARGINAL_PHASE}) — got "
        f"({first_slip0}, {first_phase0})"
    )
    # Best-of-sweep: picks the widest eye, NOT the marginal edge.
    assert (best_slip0, best_phase0) == (WIDE_SLIP, WIDE_PHASE), (
        f"best-of-sweep DUT should latch lane 0 at the widest-eye pair "
        f"(slip={WIDE_SLIP}, phase={WIDE_PHASE}) — got "
        f"({best_slip0}, {best_phase0}). §9.9 selection policy is not "
        f"working: it picked the first-eye-edge pair instead of the "
        f"longest in-dwell run."
    )
    # They picked DIFFERENT pairs (the whole point of the test).
    assert (best_slip0, best_phase0) != (first_slip0, first_phase0), (
        "best-of-sweep and first-match latched the SAME lane 0 (slip,phase). "
        "The test stimulus was supposed to make them disagree — fix the "
        "stimulus (MARGINAL vs WIDE).")
    # Neither should fault lane 0 (both stimuli meet LOCK_THRESH=16).
    assert (best_fault & 1) == 0, (
        f"best-of-sweep DUT spuriously faulted lane 0 (fault=0x{best_fault:02x})"
    )
    assert (first_fault & 1) == 0, (
        f"first-match DUT spuriously faulted lane 0 (fault=0x{first_fault:02x})"
    )

    # Sanity: lanes 1..7 should latch (0,0) for both DUTs (both score
    # saturates at the first iterator point; strict-gt comparator means
    # later equal-score points don't displace).
    for ln in range(1, 8):
        bs_ln = (_lane_field(best_bs, ln, 3),   _lane_field(best_po, ln, 4))
        fs_ln = (_lane_field(first_bs, ln, 3),  _lane_field(first_po, ln, 4))
        assert bs_ln == (0, 0), f"best  lane {ln} latched ({bs_ln}), expected (0,0)"
        assert fs_ln == (0, 0), f"first lane {ln} latched ({fs_ln}), expected (0,0)"


    # =====================================================================
    # SECOND SCENARIO (in-test rather than @cocotb.test — VCS+cocotb 2.x
    # shuts the simulator down between separate @cocotb.test functions
    # because the persistent clock coroutine confuses the regression
    # tear-down).  Keeps everything in one cocotb test.
    # =====================================================================
    # Sub-scenario: if a lane's best in-dwell run-length never reaches
    # LOCK_THRESH across the entire 128-point sweep, the best-of-sweep DUT
    # must mark that lane FAULTED (rather than latch a sub-threshold pair).

    # Re-apply reset so both DUTs forget everything from the first sweep.
    dut.role_locked.value = 0
    dut.lane_locked.value = 0
    dut.rst.value         = 1
    await ClockCycles(dut.clk, 10)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)

    BAD_RUN_LEN = 12      # below LOCK_THRESH=16
    BAD_SLIP    = 2
    BAD_PHASE   = 4

    async def _drive_sub_thresh():
        while True:
            await RisingEdge(dut.clk)
            sweep_slip  = int(dut.u_dut_best.sweep_slip.value)
            sweep_phase = int(dut.u_dut_best.sweep_phase.value)
            dwell_ctr   = int(dut.u_dut_best.dwell_ctr.value)
            vec = 0xFE   # other lanes always locked
            if (sweep_slip == BAD_SLIP and sweep_phase == BAD_PHASE
                    and dwell_ctr < BAD_RUN_LEN):
                vec |= 0x01
            dut.lane_locked.value = vec

    drv2 = cocotb.start_soon(_drive_sub_thresh())

    await ClockCycles(dut.clk, 2)
    dut.role_locked.value = 1

    for _ in range(settle_budget):
        await RisingEdge(dut.clk)
        if int(dut.best_state.value) >= 3:
            break

    drv2.cancel()

    best_fault2 = int(dut.best_lane_fault.value)
    dut._log.info(f"  [scenario 2] best lane_fault = 0x{best_fault2:02x} "
                  f"(expect lane 0 set)")
    assert (best_fault2 & 0x01) == 0x01, (
        f"best-of-sweep DUT must fault lane 0 when no (slip,phase) ever "
        f"yielded a run-length >= LOCK_THRESH ({LOCK_THRESH}). "
        f"Got fault=0x{best_fault2:02x}"
    )
    # Other lanes (always locked) should NOT fault.
    assert (best_fault2 & 0xFE) == 0x00, (
        f"best-of-sweep DUT faulted a stable lane: 0x{best_fault2:02x}"
    )
