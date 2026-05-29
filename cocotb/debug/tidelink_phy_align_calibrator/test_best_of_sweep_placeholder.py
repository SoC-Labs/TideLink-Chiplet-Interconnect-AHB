"""
test_best_of_sweep_placeholder — placeholder test for the §9.9 best-of-
sweep selection policy in tidelink_phy_align_calibrator.

CONTEXT
=======

The calibrator's `EARLY_EXIT_ON_ALL_LOCKED` parameter (default 1'b0 in
silicon) selects between two per-lane (slip,phase) selection policies
once the sweep walks the 128-point space:

  * 0 (best-of-sweep, silicon default — §9.9):
      Every lane walks ALL 128 (slip,phase) points. At each dwell-window
      expiry we update best_{score,slip,phase}[i] if lane_score[i]
      (consecutive-lane_locked-1 run-length within the dwell) exceeds the
      running best. At sweep exhaustion we LATCH slip[i]/phase[i] from
      best_slip/best_phase for lanes whose best_score ≥ LOCK_THRESH;
      lanes that never made the bar fault out.
      This is the "marginal eye" defence — best_score picks the
      (slip,phase) with the LONGEST stable lock, not the first
      barely-locking one.

  * 1 (early-exit / first-match — §9.7 compat):
      Each lane freezes on the first dwell where lane_locked rises.
      Matches §9.7 first-match-wins exactly. Used by the cocotb/UVM
      tests whose timing assumptions depend on early-exit.

PLACEHOLDER
===========

This test file exists so a future Agent A best-of-sweep refinement (e.g.
adding tie-break rules, score-weighting, or a different scoring window
function) lands with a dedicated home for its regression test. The
CURRENT RTL (commit 56a8aca, branch feat/td-combined) ALREADY implements
best-of-sweep — see tidelink_phy_align_calibrator.sv lines 282-345 +
562-630. The first test below pins the existing contract that any future
Agent A work must preserve. Additional tests should be added under
@cocotb.test() decorators here as Agent A's refinements land.

TODO (Agent A, future): once best-of-sweep is refined further, add
direct regression tests for the refinement here. Examples that would be
strong coverage:

  * "tie-break favours lower slip": with two equal-best dwells, the
    earlier-iterator (slip,phase) wins (current RTL: `>`, not `≥`).
  * "best_score saturation": with a lane locked for the WHOLE sweep, the
    score should saturate at LANE_SCORE_MAX=6'h3F without wrap-around.
  * "marginal eye over first-match": script a lane to lock briefly early
    (e.g. score=3) then deeply later (score=63); best-of-sweep must
    select the deeper point.

These cases are currently exercised INDIRECTLY by the pair-level
test_pair_align tests in cocotb/phy_align/ but have no dedicated unit
coverage. Adding them here would close that gap.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


S_DONE   = 4
S_HOLD   = 6

# Mirror tb_top.sv overrides.
DWELL_CYCLES = 8
ONE_SWEEP_CYCLES = 16 * 8 * DWELL_CYCLES + 4


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_best_of_sweep_default_walks_full_space(dut):
    """Pin the CURRENT best-of-sweep contract (commit 56a8aca):
    EARLY_EXIT_ON_ALL_LOCKED defaults to 1'b0 → the FSM does NOT short-
    circuit S_SWEEP when all 8 lanes are locked. It must walk the FULL
    128-point space and only finish on the dedicated sweep_exhausted
    strobe.

    We script lane_locked = 0xFF immediately at S_SWEEP entry (so every
    dwell satisfies the early-exit condition `all_done` in the compat
    mode). With best-of-sweep, the FSM must STILL stay in S_SWEEP for
    ~16 × 8 × DWELL_CYCLES cycles before reaching S_FINISH (and then
    S_HOLD).

    This is the property a future best-of-sweep refinement must preserve.
    """
    # Confirm the parameter default.
    eeoa = int(dut.u_dut.EARLY_EXIT_ON_ALL_LOCKED.value)
    assert eeoa == 0, (
        f"u_dut.EARLY_EXIT_ON_ALL_LOCKED = {eeoa}, expected 0 (silicon "
        f"default — best-of-sweep). The TB or the RTL changed the "
        f"default; cocotb/UVM tests that assumed early-exit timing "
        f"need to set tb_early_exit_force_q=1 explicitly."
    )

    await _start(dut)

    dut.lane_locked.value = 0xFF
    dut.role_locked.value = 1
    # Trigger calibration.
    await ClockCycles(dut.clk, 2)

    # Count S_SWEEP cycles before S_FINISH.
    sweep_cycles = 0
    reached_finish = False
    for _ in range(ONE_SWEEP_CYCLES + 64):
        await RisingEdge(dut.clk)
        s = int(dut.state.value)
        if s == 2:        # S_SWEEP
            sweep_cycles += 1
        elif s == 3:      # S_FINISH
            reached_finish = True
            break

    assert reached_finish, (
        f"FSM never reached S_FINISH (cycles in S_SWEEP: {sweep_cycles})."
    )

    # Best-of-sweep walks the full 128-point space. Allow a small
    # margin (≥ 90% of expected) to absorb cocotb scheduling skew.
    expected = 16 * 8 * DWELL_CYCLES
    assert sweep_cycles >= int(expected * 0.9), (
        f"S_SWEEP only ran {sweep_cycles} cycles, expected ≥ "
        f"{int(expected*0.9)} (best-of-sweep walks the full 128-point "
        f"space = {expected} cycles). Either EARLY_EXIT_ON_ALL_LOCKED "
        f"is being asserted, or the sweep_exhausted strobe fires "
        f"prematurely. A future Agent A best-of-sweep change that "
        f"shortens the sweep MUST update this test."
    )

    dut._log.info(
        f"OK: best-of-sweep walks {sweep_cycles} cycles (expected "
        f"{expected}) before S_FINISH — silicon default holds."
    )


# TODO(Agent A): add targeted tests for any best-of-sweep refinements
# here. The harness above (clock + reset + role_locked + lane_locked
# script via cocotb) is sufficient — extend `_start()` and add
# additional @cocotb.test() decorators.
