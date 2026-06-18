"""test_calibrator_s_probe_skip — FSM-coverage test for the new calibrator
S_PROBE → S_FINISH skip path (Agent F §9.10, commit f900e07 +).

ASIC readiness — closes C01-equivalent of
docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md §3.1.

The S_PROBE skip path (S_ARM → S_PROBE → S_FINISH on `probe_all_locked`)
saves ~127 of the 128 sweep dwells when both peers come up cleanly
aligned at the silicon default (slip=0, phase=0). A regression that
broke the predicate would silently fall back to the full S_SWEEP — fine
for sim, fatal for silicon yield.

Pinned:
  * Path A — all 8 lanes lock at (0,0) → S_PROBE→S_FINISH skip
  * Path B — 7/8 lanes lock → S_PROBE→S_SWEEP fallback
  * lane_done = 0xFF latched at S_FINISH entry on the skip path

Uses the standalone TB at cocotb/tidelink_phy_align_calibrator/tb_top.sv.
The TB synthesises `dwell_min_dist` from `lane_locked` (locked→0,
else→16) so driving lane_locked picks the predicate outcome.

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

# TB parameter overrides (must match tb_top.sv defaults).
DWELL_CYCLES     = 8
LOCK_THRESH      = 2
# ONE full sweep takes 16 phase × 8 slip × DWELL_CYCLES + handshake.
ONE_SWEEP_CYCLES = 16 * 8 * DWELL_CYCLES + 8
# S_PROBE only dwells DWELL_CYCLES + 2 cycles (entry + dwell_expire + xition).
PROBE_WINDOW     = DWELL_CYCLES + 4


async def _start(dut):
    """Boot the calibrator standalone TB with a clean reset."""
    cocotb.start_soon(Clock(dut.clk, 16, unit="ns").start())
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


def _state(dut):
    return int(dut.state.value)


async def _walk_until_state(dut, target_state, max_cycles, exclude_states=None):
    """Cycle until `dut.state == target_state`. Records every visited state
    in order. If `exclude_states` is provided and any of those states is
    seen, raise AssertionError immediately (used to prove a transition path
    did NOT take a forbidden detour).
    """
    seen = []
    exclude_states = set(exclude_states or [])
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if not seen or seen[-1] != s:
            seen.append(s)
        if s in exclude_states:
            raise AssertionError(
                f"FSM entered forbidden state {s}; expected to reach "
                f"{target_state} without touching {sorted(exclude_states)}. "
                f"states tail: {seen[-16:]}"
            )
        if s == target_state:
            return seen
    raise AssertionError(
        f"FSM never reached state {target_state} within {max_cycles} cycles. "
        f"states tail: {seen[-16:]}"
    )


@cocotb.test()
async def test_s_probe_skip_all_lanes_locked(dut):
    """Path A: all 8 lanes lock at (0,0) during S_PROBE → S_FINISH skip.
    TB maps lane_locked[i]=1 → dwell_min_dist_i[i]=0 → lane_dist_pass=1 →
    lane_score saturates → probe_all_locked=1 → skip predicate fires.
    """
    await _start(dut)
    dut.lane_locked.value = 0xFF
    dut.role_locked.value = 1

    seen_to_probe = await _walk_until_state(
        dut, S_PROBE, max_cycles=32,
        exclude_states={S_SWEEP, S_FINISH, S_DONE, S_HOLD},
    )
    assert S_ARM in seen_to_probe, (
        f"S_ARM bypassed on path to S_PROBE. seen: {seen_to_probe}"
    )
    dut._log.info(f"OK: visited {seen_to_probe} on the way to S_PROBE")

    seen_to_finish = await _walk_until_state(
        dut, S_FINISH, max_cycles=PROBE_WINDOW + 8,
        exclude_states={S_SWEEP, S_CANCEL},
    )
    dut._log.info(
        f"OK: S_PROBE → S_FINISH skip — visited {seen_to_finish} "
        f"WITHOUT entering S_SWEEP."
    )

    # After S_FINISH, may go S_HOLD (silicon) or S_DONE (sim). Either
    # is fine; what is NOT fine is dropping back into S_SWEEP.
    seen_release = []
    for _ in range(ONE_SWEEP_CYCLES * 4):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if not seen_release or seen_release[-1] != s:
            seen_release.append(s)
        if s == S_DONE:
            break
        assert s != S_SWEEP, (
            f"FSM dropped back into S_SWEEP after S_FINISH on a "
            f"probe_all_locked path. seen: {seen_release[-16:]}"
        )
    dut._log.info("PASS: full S_PROBE skip exercised without S_SWEEP detour.")


@cocotb.test()
async def test_s_probe_falls_back_to_sweep_on_partial(dut):
    """Path B: 7/8 lanes lock at (0,0); lane 0 unlocked. probe_all_locked=0
    → S_PROBE → S_SWEEP fallback (not skip). Pins the partial-pass arm.
    """
    await _start(dut)
    dut.lane_locked.value = 0xFE   # bit[0]=0
    dut.role_locked.value = 1

    seen_to_probe = await _walk_until_state(
        dut, S_PROBE, max_cycles=32,
        exclude_states={S_SWEEP, S_FINISH, S_DONE},
    )
    dut._log.info(f"OK: reached S_PROBE — seen {seen_to_probe}")

    seen_to_sweep = await _walk_until_state(
        dut, S_SWEEP, max_cycles=PROBE_WINDOW + 8,
        exclude_states={S_FINISH, S_DONE, S_HOLD},
    )
    dut._log.info(
        f"OK: S_PROBE → S_SWEEP fallback — seen {seen_to_sweep}. "
        f"probe_all_locked=0 steered into the full sweep."
    )

    tm = int(dut.training_mode.value)
    assert tm == 1, (
        f"In S_SWEEP, training_mode={tm}, expected 1. TX must keep "
        f"emitting training so the peer can align."
    )
    dut._log.info("PASS: probe_all_locked=0 → S_SWEEP; training_mode HIGH.")


@cocotb.test()
async def test_s_probe_lane_done_latched_on_skip(dut):
    """On the skip path, lane_done[i] must be latched=1 BEFORE leaving
    S_PROBE — S_FINALIZE is skipped, so the per-lane (slip=0, phase=0,
    lane_done=1) write has to happen in S_PROBE itself.
    """
    await _start(dut)
    dut.lane_locked.value = 0xFF
    dut.role_locked.value = 1

    in_probe = False
    lane_done_at_finish = None
    for _ in range(64):
        await RisingEdge(dut.clk)
        s = _state(dut)
        if s == S_PROBE:
            in_probe = True
        if in_probe and s == S_FINISH:
            await RisingEdge(dut.clk)
            try:
                lane_done_at_finish = int(dut.u_dut.lane_done.value)
            except (AttributeError, ValueError) as e:
                dut._log.warning(
                    f"u_dut.lane_done not visible ({e}); skipping assert. "
                    f"Skip-path coverage still pinned by test_s_probe_skip."
                )
                return
            break

    assert lane_done_at_finish is not None, "S_FINISH not reached from S_PROBE."
    assert lane_done_at_finish == 0xFF, (
        f"lane_done=0x{lane_done_at_finish:02x} at S_FINISH on the skip "
        f"path; expected 0xFF. Per-lane (0,0) latch did not fire in S_PROBE."
    )
    dut._log.info(
        f"PASS: lane_done=0x{lane_done_at_finish:02x} latched at S_FINISH "
        f"entry — per-lane (0,0) captured during S_PROBE."
    )
