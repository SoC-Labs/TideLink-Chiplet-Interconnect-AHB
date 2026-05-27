"""§9.11 eye-centre selection — unit test (upgraded from §9.9 widest-eye).

Drives a single tb_top that instantiates TWO copies of
`tidelink_phy_align_calibrator`:

  * u_dut_best  — EARLY_EXIT_ON_ALL_LOCKED = 1'b0  (silicon default,
                  §9.11 eye-centre via MIN_LOCK_DWELLS contiguity)
  * u_dut_first — EARLY_EXIT_ON_ALL_LOCKED = 1'b1  (legacy §9.7
                  first-match-wins behaviour)

Both DUTs see THE SAME externally-driven `lane_locked[7:0]` trajectory.
The cocotb driver computes that trajectory from the BEST DUT's current
sweep iterator (sweep_slip, sweep_phase, dwell_ctr) so we can paint
deterministic per-(slip,phase) lock-duration patterns:

  * Lanes 1..7  — lane_locked held HIGH every cycle. Under §9.11 both
    DUTs see every (slip,phase) point pass; the best-DUT's per-lane run
    spans the full phase axis at slip=0 (length 16, the first slip in
    sweep order), so it latches the CENTRE (slip=0, phase=7). The
    first-match DUT still picks (0,0) — its first lock-rising dwell.
    This is the §9.11-vs-§9.7 difference for a "wide-everywhere" lane.

  * Lane 0      — the "eye-edge-marginal vs centred-real-eye" lane.
    HIGH for ONLY 18 consecutive cycles at (slip=0, phase=0) (just over
    LOCK_THRESH=16) — a SINGLE eye-edge point. Also HIGH for the FULL
    DWELL_CYCLES (32) at FOUR contiguous phase points (slip=3, phase=4..7)
    — a 4-wide real eye centred at phase=5/6 boundary.

    Under §9.11 with MIN_LOCK_DWELLS=4:
      best-of-sweep   picks (slip=3, phase=5)  — centre of 4-wide run
                      (start=4, len=4, centre=4+(4-1)/2 = 5).
                      The marginal (0,0) point produces run_len=1 only —
                      below MIN_LOCK_DWELLS=4, so the run never promotes.
    Under §9.7:
      first-match     picks (slip=0, phase=0)  — first eye edge it sees.

That difference is the §9.11 eye-CENTRE intent: a marginal lane that
JUST barely clears LOCK_THRESH at the first edge no longer locks the
calibrator to that edge — instead, the centre of the widest 4-contiguous
run wins, giving maximum margin on either side.

Invocation (from cocotb/phy_align_calibrator/):
    rm -rf sim_build && make TB_VARIANT=compare
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# Must match the tb_top.sv parameters.
DWELL_CYCLES = 32
LOCK_THRESH  = 16

# Marginal lane stimulus: lane 0 locked for 18 cycles at (0,0), then drops.
# This produces lane_score=18 > LOCK_THRESH=16 at the single point (0,0) —
# a 1-wide phase run. With MIN_LOCK_DWELLS=4 this NEVER promotes to best_run,
# so §9.11 ignores it. (Under §9.9 it would have saturated the score
# comparator and locked the calibrator to (0,0).)
MARGINAL_RUN_LEN = 18
MARGINAL_SLIP    = 0
MARGINAL_PHASE   = 0

# Widest-eye stimulus: lane 0 locked for the full dwell at 4 contiguous
# phase points at slip=3 (phase=4,5,6,7). §9.11 promotes a 4-wide run
# (>= MIN_LOCK_DWELLS=4) and latches the run centre = 4 + (4-1)/2 = 5.
WIDE_SLIP        = 3
WIDE_PHASE_START = 4
WIDE_PHASE_END   = 7        # inclusive
WIDE_PHASE       = 5        # centre = start + (len-1)/2 = 4 + (4-1)/2 = 5


def _lane_locked_for(sweep_slip, sweep_phase, dwell_ctr):
    """Compute lane_locked[7:0] for the BEST DUT's current iterator value.

    Lanes 1..7 always HIGH — under §9.11 these latch at the eye CENTRE
    (phase=7, slip=0 — the centre of the full-passing strip at the first
    swept slip).
    Lane 0 is the eye-edge-marginal vs centred-real-eye lane:
      - MARGINAL point (0,0): HIGH for the first 18 cycles of the dwell
        only. lane_score reaches 18 > LOCK_THRESH=16 → that single point
        passes. But it's a 1-wide phase run, below MIN_LOCK_DWELLS=4.
        §9.11 does NOT promote.
      - WIDE run (slip=3, phase=4..7): HIGH for the full DWELL_CYCLES at
        each of the 4 contiguous phases. §9.11 promotes a 4-wide run.
        Run centre = 4 + (4-1)/2 = 5, so latched (slip=3, phase=5).
    """
    vec = 0xFE  # bits 7..1 always HIGH
    lane0 = 0
    if sweep_slip == MARGINAL_SLIP and sweep_phase == MARGINAL_PHASE:
        # Eye-edge marginal: HIGH for the first MARGINAL_RUN_LEN cycles of
        # the dwell, then drop. Single phase point only.
        if dwell_ctr < MARGINAL_RUN_LEN:
            lane0 = 1
    elif sweep_slip == WIDE_SLIP and (
            WIDE_PHASE_START <= sweep_phase <= WIDE_PHASE_END):
        # 4-wide contiguous phase eye at slip=3.
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
    # Full sweep = 128 iterator points × DWELL_CYCLES = 128*32 = 4096 cycles,
    # PLUS S_PROBE adds one extra dwell (32 cy) at the front, PLUS S_FINALIZE
    # is one extra cycle. Add settle margin — the best-of-sweep DUT then
    # transitions S_SWEEP → S_FINALIZE → S_FINISH → S_HOLD (no fault on lane
    # 0 since WIDE pair always meets LOCK_THRESH=16).
    #
    # State codes (must match the calibrator typedef):
    #   S_IDLE=0, S_ARM=1, S_SWEEP=2, S_FINISH=3, S_DONE=4,
    #   S_CANCEL=5, S_HOLD=6, S_PROBE=7, S_FINALIZE=8
    # "Done with the sweep" means cur_state ∈ {S_FINISH, S_DONE, S_HOLD}.
    # The naive `state >= 3` check matches S_PROBE (7) and S_FINALIZE (8) —
    # both of which the FSM passes through DURING the sweep — so it would
    # exit instantly without the sweep having run. Use an explicit allow-list.
    SWEEP_COMPLETE_STATES = {3, 4, 6}    # S_FINISH, S_DONE, S_HOLD
    settle_budget = 128 * DWELL_CYCLES + 400  # +S_PROBE+S_FINALIZE+slack
    best_state = 0
    for _ in range(settle_budget):
        await RisingEdge(dut.clk)
        best_state = int(dut.best_state.value)
        if best_state in SWEEP_COMPLETE_STATES:
            break
    assert best_state in SWEEP_COMPLETE_STATES, (
        f"best-of-sweep DUT did not exit S_SWEEP within {settle_budget} cycles "
        f"(state={best_state}, expected one of {SWEEP_COMPLETE_STATES})"
    )

    # First-match DUT exits the sweep much earlier — by this point it has
    # been in S_HOLD for a while.  Verify it's done sweeping too.
    first_state = int(dut.first_state.value)
    assert first_state in SWEEP_COMPLETE_STATES, (
        f"first-match DUT also expected to be past sweep "
        f"(state={first_state}, expected one of {SWEEP_COMPLETE_STATES})"
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

    # Sanity: lanes 1..7 — both DUTs see them always-locked.
    #   first-match: latches first point = (0,0)
    #   best-of-sweep §9.11: latches centre of the full-passing strip at
    #       slip=0 (first slip in the slip-outer iteration), centre of
    #       phase [0..15] = phase 7. So (slip=0, phase=7).
    for ln in range(1, 8):
        bs_ln = (_lane_field(best_bs, ln, 3),   _lane_field(best_po, ln, 4))
        fs_ln = (_lane_field(first_bs, ln, 3),  _lane_field(first_po, ln, 4))
        assert bs_ln == (0, 7), (
            f"best  lane {ln} latched ({bs_ln}), expected (0,7) — centre of "
            f"always-passing strip at slip=0 (§9.11 eye-centre policy)"
        )
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
        if int(dut.best_state.value) in SWEEP_COMPLETE_STATES:
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
