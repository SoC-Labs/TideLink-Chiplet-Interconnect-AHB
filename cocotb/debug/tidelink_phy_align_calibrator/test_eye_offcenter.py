"""test_eye_offcenter — unit test for the S_PROBE (0,0)-bias fix vs the
§9.9 eye-CENTRE design intent.

CONTEXT
=======

`feat/calibrator-bug-fix` HEAD `b5f92e8` added a new `S_PROBE = 4'd7`
state between `S_ARM` and `S_SWEEP`. S_PROBE dwells DWELL_CYCLES at
(sweep_slip=0, sweep_phase=0) and latches any lane that crosses the
LOCK_THRESH bar at that (0,0) point with `lane_done[i]=1` and
slip[i]/phase[i] := 0. Lanes that DON'T pass the probe fall through to
S_SWEEP for the normal best-of-sweep search.

The independent reviewer (Agent K) flagged this as an AMBER risk: on
silicon at PVT extremes or under ribbon-cable skew, the eye centre may
NOT be at (0,0). The fix is supposed to fall through for such lanes —
but does the *S_SWEEP* path that catches them still find the
eye-CENTRE? The §9.9 motivation was to defeat eye-edge oscillation; the
score-capture comparator is currently `>` (strictly greater), which
makes S_SWEEP latch the EARLIEST sweep-order locking point per lane,
not the centre.

This test fabricates a `lane_locked` trace where the eye is positioned
at a known non-(0,0) (slip,phase) point, with lane_locked=0 everywhere
else. We then read out the per-lane latched (slip,phase) after S_DONE
and check (1) whether it's inside the eye region and (2) whether it's
the eye centre.

THREE VARIANTS:
  V1 — single eye at (slip=3, phase=8), 3x3 cells. S_PROBE@(0,0) must
       FAIL (lane_locked=0 there); S_SWEEP must find the eye. Expected
       centre = (3,8). EARLY-EYE-EDGE (strict-`>` comparator) prediction
       = (2,7) — first cell in sweep order, NOT centre.

  V2 — TWO eyes: a small 1-cell eye at (slip=6, phase=2), and a wide
       3x3 eye at (slip=3, phase=8). Sweep order (phase-outer slip-
       inner) means the small eye is encountered FIRST. With strict-`>`,
       calibrator latches the small eye and never re-considers the wide
       eye. §9.9 design intent says: prefer the WIDER eye.

  V3 — Two eyes: a 3-cell L-shaped eye covering {(0,0), (0,1), (1,0)},
       AND a 3x3 eye at (slip=4, phase=8). S_PROBE@(0,0) PASSES on
       the first eye, latches lane to (0,0). The wider eye at (4,8) is
       NEVER selected. §9.9 says: pick the WIDER eye.

INVOCATION
==========

    cd /home/dam1n19/SoCLabs/td-bisect/td-sim-eyecenter && source set_env.sh
    cd cocotb/tidelink_phy_align_calibrator
    rm -rf sim_build
    make MODULE=test_eye_offcenter

The default tb_top variant (single DUT, EARLY_EXIT_ON_ALL_LOCKED=0,
silicon best-of-sweep policy) is what we want.

A joint work commissioned on behalf of SoC Labs, under Arm Academic
Access license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# tb_top.sv parameter overrides (must match the values in the testbench
# wrapper — see tb_top.sv lines 43-51).
DWELL_CYCLES = 8
LOCK_THRESH  = 2
# A full 128-point sweep = 16 phase × 8 slip × DWELL_CYCLES = 1024 cycles.
# Add the S_PROBE dwell (8 cycles) + S_ARM (1) + S_FINISH (1) + a bit of
# tear-down slack.
ONE_SWEEP_CYCLES = 16 * 8 * DWELL_CYCLES + DWELL_CYCLES + 8

# FSM state encodings — must mirror src/rtl/tidelink_phy_align_calibrator.sv.
S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5
S_HOLD   = 6
S_PROBE  = 7


# ---------------------------------------------------------------------------
# Test harness helpers
# ---------------------------------------------------------------------------

async def _start(dut):
    """Start clock, drive a clean reset, settle inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())  # 100 MHz
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


def _lane_field(packed, lane, bits):
    """Extract a per-lane field from a packed bus (3-bit slip, 4-bit phase)."""
    mask = (1 << bits) - 1
    return (packed >> (bits * lane)) & mask


def _in_eye(slip, phase, eye_cells):
    """True iff (slip, phase) is in the eye cell set."""
    return (slip, phase) in eye_cells


def _eye_cells_rect(centre_slip, centre_phase, half_w):
    """Square eye centred at (centre_slip, centre_phase), half-width
    `half_w` (so a half_w=1 eye is 3x3 = 9 cells).

    Cells are clamped to the legal sweep space slip∈[0..7], phase∈[0..15]."""
    cells = set()
    for ds in range(-half_w, half_w + 1):
        for dp in range(-half_w, half_w + 1):
            s = centre_slip + ds
            p = centre_phase + dp
            if 0 <= s <= 7 and 0 <= p <= 15:
                cells.add((s, p))
    return cells


async def _drive_until_done(dut, eye_cells, timeout_cycles=None):
    """Drive lane_locked from the live (sweep_slip, sweep_phase) iterator
    inside `eye_cells`. Read the DUT's iterator on EVERY clock so the
    lane_locked trace tracks both the S_PROBE dwell at (0,0) AND the
    S_SWEEP walk through the 128 points.

    Returns when the FSM reaches S_HOLD or S_DONE, or after
    timeout_cycles.

    The driver paints lane_locked=0xFF (all 8 lanes locked) at any
    iterator point in the eye, and 0x00 elsewhere. By making every lane
    see the same eye we keep the per-lane analysis trivial — what
    matters is whether the FSM picks the eye centre vs an edge.
    """
    if timeout_cycles is None:
        timeout_cycles = ONE_SWEEP_CYCLES + 64
    final_state = None
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        sw_slip  = int(dut.u_dut.sweep_slip.value)
        sw_phase = int(dut.u_dut.sweep_phase.value)
        if _in_eye(sw_slip, sw_phase, eye_cells):
            dut.lane_locked.value = 0xFF
        else:
            dut.lane_locked.value = 0x00
        st = int(dut.state.value)
        if st in (S_HOLD, S_DONE):
            final_state = st
            break
    return final_state


def _read_latched(dut):
    """Read per-lane (slip,phase) from packed bit_slip / phase_offset."""
    bs = int(dut.bit_slip.value)
    po = int(dut.phase_offset.value)
    out = []
    for ln in range(8):
        out.append((_lane_field(bs, ln, 3), _lane_field(po, ln, 4)))
    return out


# ---------------------------------------------------------------------------
# V1 — single eye at (3,8), 3x3 cells
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_eye_offcenter_single_3x8(dut):
    """V1: eye at (slip=3, phase=8), half-width 1 (9 cells).
    lane_locked=1 ONLY when (sweep_slip,sweep_phase) is in that 9-cell
    square; lane_locked=0 everywhere else.

    Expected behaviour with the bias-fix RTL:
      * S_PROBE@(0,0) — lane_locked=0 there → probe FAILS, fall through.
      * S_SWEEP walks 128 points. First eye cell in sweep order
        (phase-outer, slip-inner) is (slip=2, phase=7).
      * best_score saturates immediately at the first eye cell.
      * Strict-`>` comparator → best_* never updates after the first
        saturation → calibrator latches (2, 7).

    Assertions:
      * Latched (slip,phase) MUST be inside the eye (slip∈[2..4],
        phase∈[7..9]). Otherwise the calibrator silently picked an
        out-of-eye point → real bug.
      * INFO: log whether it picked the centre (3,8) or just an edge.
    """
    await _start(dut)

    eye_centre = (3, 8)
    eye_cells  = _eye_cells_rect(*eye_centre, half_w=1)
    dut._log.info(
        f"V1: eye centre=({eye_centre[0]},{eye_centre[1]}), "
        f"{len(eye_cells)} cells: {sorted(eye_cells)}"
    )

    # Sanity: (0,0) must NOT be in the eye (would defeat the test).
    assert (0, 0) not in eye_cells, "V1: stimulus bug — (0,0) is in the eye"

    # Trigger calibration.
    dut.role_locked.value = 1
    final_state = await _drive_until_done(dut, eye_cells)
    assert final_state is not None, (
        "V1: FSM never reached S_HOLD/S_DONE — sweep didn't complete"
    )

    latched = _read_latched(dut)
    dut._log.info(f"V1 latched per-lane (slip,phase): {latched}")

    # Per-lane checks. We made all 8 lanes see the same eye, so all
    # latched values should agree.
    fails_outside_eye = []
    fails_not_centre  = []
    for ln, (s, p) in enumerate(latched):
        if (s, p) not in eye_cells:
            fails_outside_eye.append((ln, s, p))
        if (s, p) != eye_centre:
            fails_not_centre.append((ln, s, p))

    if fails_outside_eye:
        dut._log.error(
            f"V1 FAIL: lanes picked OUTSIDE the eye: {fails_outside_eye}"
        )
    if fails_not_centre:
        dut._log.warning(
            f"V1 WARN: lanes did not pick the eye CENTRE (3,8): "
            f"{fails_not_centre}"
        )

    # HARD assertion: must be inside the eye.
    assert not fails_outside_eye, (
        f"V1: calibrator latched (slip,phase) values OUTSIDE the eye for "
        f"lanes {fails_outside_eye}. Eye = {sorted(eye_cells)}. This is a "
        f"real bug — the calibrator picked a point where lane_locked was "
        f"never asserted."
    )

    # SOFT-pass: log whether we picked the centre vs an edge. Either is
    # accepted by this assertion (the §9.9 intent says centre, but the
    # bias-fix RTL with strict-`>` will pick the first sweep-order eye
    # cell = (2,7)).
    if not fails_not_centre:
        dut._log.info("V1 PASS: calibrator picked the eye CENTRE (3,8)")
    else:
        dut._log.info(
            "V1 PASS (degraded): calibrator picked an eye-edge point. "
            "This is the AMBER risk Agent K flagged — §9.9 eye-CENTRE "
            "intent is not preserved by the current strict-`>` comparator."
        )


# ---------------------------------------------------------------------------
# V2 — two eyes: small earlier-in-sweep vs wider later-in-sweep
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_eye_offcenter_widest_wins(dut):
    """V2: two eyes:
      * Eye-A — 1-cell  small eye at (slip=6, phase=2).
      * Eye-B — 3x3 cells wide eye at (slip=3, phase=8).

    Sweep order is phase-outer, slip-inner. Phase=2 is hit BEFORE
    phase=7, so Eye-A is encountered first in the sweep.

    Per §9.9 the calibrator MUST pick the wider eye (Eye-B). With
    strict-`>` best_* comparator, the first eye cell at (6,2) saturates
    best_score and Eye-B never displaces it.

    Expected per Agent K:
      * Bias-fix RTL: FAIL — picks Eye-A (6,2), the smaller earlier eye.
      * §9.9 intent: PASS — picks Eye-B centre (3,8) (the wider eye).
    """
    await _start(dut)

    eye_a_centre = (6, 2)
    eye_a_cells  = {eye_a_centre}              # 1-cell pinpoint eye
    eye_b_centre = (3, 8)
    eye_b_cells  = _eye_cells_rect(*eye_b_centre, half_w=1)
    eye_cells    = eye_a_cells | eye_b_cells

    dut._log.info(
        f"V2: eye-A={sorted(eye_a_cells)} (1 cell), "
        f"eye-B={sorted(eye_b_cells)} ({len(eye_b_cells)} cells)"
    )
    # Sanity: eyes disjoint and (0,0) not in either.
    assert eye_a_cells.isdisjoint(eye_b_cells)
    assert (0, 0) not in eye_cells

    dut.role_locked.value = 1
    final_state = await _drive_until_done(dut, eye_cells)
    assert final_state is not None, (
        "V2: FSM never reached S_HOLD/S_DONE"
    )

    latched = _read_latched(dut)
    dut._log.info(f"V2 latched per-lane (slip,phase): {latched}")

    # Categorise per-lane: did we pick eye-A, eye-B, or out-of-eye?
    picked_a    = []
    picked_b    = []
    out_of_eye  = []
    for ln, sp in enumerate(latched):
        if sp in eye_a_cells:
            picked_a.append(ln)
        elif sp in eye_b_cells:
            picked_b.append(ln)
        else:
            out_of_eye.append((ln, sp))

    dut._log.info(
        f"V2: picked eye-A={picked_a}, picked eye-B={picked_b}, "
        f"out-of-eye={out_of_eye}"
    )

    # HARD assertion #1: every lane must be inside SOME eye (the lanes
    # were locked across both eyes, so the calibrator should never pick
    # an unlocked point).
    assert not out_of_eye, (
        f"V2: lanes {out_of_eye} latched outside both eyes — real bug."
    )

    # §9.9 INTENT assertion: every lane should pick the wider eye-B.
    # This is the assertion that will FAIL on the current bias-fix RTL,
    # exposing the §9.9 abandonment Agent K flagged.
    if picked_a and not picked_b:
        dut._log.error(
            "V2: all lanes picked the SMALLER eye-A — §9.9 wider-eye "
            "intent ABANDONED. This is the Agent K AMBER finding."
        )
    elif picked_b and not picked_a:
        dut._log.info(
            "V2: all lanes picked the WIDER eye-B — §9.9 intent preserved."
        )
    else:
        dut._log.warning(
            f"V2: mixed picks — lanes A={picked_a}, B={picked_b}"
        )

    assert picked_b and not picked_a, (
        f"V2: §9.9 wider-eye design intent VIOLATED. Calibrator picked "
        f"smaller eye-A on lanes {picked_a} instead of wider eye-B "
        f"(picked-B on lanes {picked_b}). Eye-A is encountered earlier in "
        f"sweep order (phase=2 vs phase=8) and the strict-`>` best-of-"
        f"sweep comparator never displaces it. Agent K AMBER risk "
        f"confirmed."
    )


# ---------------------------------------------------------------------------
# V3 — eye-A contains (0,0); eye-B is wider but elsewhere
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_eye_offcenter_zero_vs_wide(dut):
    """V3: two eyes:
      * Eye-A — L-shape covering {(0,0), (0,1), (1,0)}  (3 cells incl. (0,0))
      * Eye-B — 3x3 cells wide  at (slip=4, phase=8)    (9 cells)

    S_PROBE@(0,0) sees lane_locked=1 for the ENTIRE DWELL → score
    saturates → probe passes → lane_done=1 → latched at (0,0). S_SWEEP
    cannot displace.

    Per §9.9 the WIDER eye should win (eye-B). With the bias-fix RTL,
    S_PROBE wins absolutely.

    Expected per Agent K:
      * Bias-fix RTL: FAIL — every lane latches at (0,0).
      * §9.9 intent: PASS — every lane latches at eye-B centre (4,8).
    """
    await _start(dut)

    eye_a_cells  = {(0, 0), (0, 1), (1, 0)}
    eye_b_centre = (4, 8)
    eye_b_cells  = _eye_cells_rect(*eye_b_centre, half_w=1)
    eye_cells    = eye_a_cells | eye_b_cells

    dut._log.info(
        f"V3: eye-A={sorted(eye_a_cells)} (3 cells incl. (0,0)), "
        f"eye-B={sorted(eye_b_cells)} ({len(eye_b_cells)} cells)"
    )
    assert eye_a_cells.isdisjoint(eye_b_cells)
    assert (0, 0) in eye_a_cells

    dut.role_locked.value = 1
    final_state = await _drive_until_done(dut, eye_cells)
    assert final_state is not None, "V3: FSM never reached S_HOLD/S_DONE"

    latched = _read_latched(dut)
    dut._log.info(f"V3 latched per-lane (slip,phase): {latched}")

    picked_a    = []
    picked_b    = []
    out_of_eye  = []
    for ln, sp in enumerate(latched):
        if sp in eye_a_cells:
            picked_a.append((ln, sp))
        elif sp in eye_b_cells:
            picked_b.append((ln, sp))
        else:
            out_of_eye.append((ln, sp))

    dut._log.info(
        f"V3: picked eye-A={picked_a}, picked eye-B={picked_b}, "
        f"out-of-eye={out_of_eye}"
    )

    assert not out_of_eye, (
        f"V3: lanes {out_of_eye} latched outside both eyes — real bug."
    )

    # If every lane is in eye-A AT (0,0) specifically, this confirms the
    # S_PROBE bias-to-(0,0) behaviour: the (0,0) probe-pass overrode
    # the wider-eye search.
    at_zero = [t for t in picked_a if t[1] == (0, 0)]
    if at_zero and not picked_b:
        dut._log.error(
            f"V3: S_PROBE bias to (0,0) confirmed — all lanes latched at "
            f"(0,0) despite a wider eye at (4,8) being available. This "
            f"DIRECTLY abandons §9.9 eye-CENTRE intent (Agent K finding)."
        )

    # §9.9 INTENT assertion. Will FAIL on the current bias-fix RTL.
    assert picked_b and not picked_a, (
        f"V3: §9.9 wider-eye design intent VIOLATED. S_PROBE@(0,0) "
        f"latched lanes {picked_a} at (0,0) instead of the WIDER eye-B "
        f"(picked-B on lanes {picked_b}). This confirms Agent K's "
        f"finding that the bias fix abandons the §9.9 eye-CENTRE intent: "
        f"any lane that crosses LOCK_THRESH at (0,0) is forever locked "
        f"there, even when a wider eye exists in S_SWEEP space."
    )
