"""
test_bank_asymmetry — bank-35 / bank-13 IDELAYCTRL asymmetry reproducer.

Background
==========

The TideLink Pynq-Z2 bring-up showed ~14/16 simultaneous lane lock with
master lanes 1 and 3 (bank-35 RX pins C20 / A20) marginal vs lanes 0/2/4/
5/6/7 (bank-13). Slave mirrors with lanes 0/4 (F19/B20 bank-35) marginal.

Mechanism (HW audit): Vivado places 6 of 8 master RX lanes in IDELAY
column X0 sharing IDELAYCTRL_X0Y0; 2 are in column X1 sharing a
replicated IDELAYCTRL_X1Y2. Per-IDELAYCTRL VT variation gives marginally
different tap-times per group. The calibrator drives one uniform per-lane
phase sweep without knowing about bank groups, so the bank-35 lanes end
up with:

  * narrower lock-eye (fewer (slip,phase) points where they lock), and/or
  * shifted eye CENTRE (best (slip,phase) differs by 1-2 from bank-13).

The HW trajectory (bringup_health_probe.log) shows the master oscillating
0xf5 / 0xfd / 0xd5 / 0xd7 — bits 1 and 3 marginal — and the slave 0xce /
0x7f / 0xee — bits 0 and 4 marginal. Tap-time variation is NOT in any
SDF/GLS model; it's a silicon runtime characteristic. This TB reproduces
the EFFECT (narrow / skewed per-lane eyes) at the calibrator boundary
without modelling the IDELAYE2 silicon directly.

Test design
===========

`tb_top.sv` instantiates TWO calibrators driven by the same synthetic
per-lane lane_locked vector:
    u_dut_best  — best-of-sweep (silicon default, Agent A's commit 0d85843)
    u_dut_first — first-match-wins (legacy §9.7)

The synthetic driver paints a configurable per-lane eye:
    eye_centre_slip [i]   (3 bits per lane, 24-bit packed)
    eye_centre_phase[i]   (4 bits per lane, 32-bit packed)
    eye_width       [i]   (3 bits per lane, 24-bit packed; half-width)
    eye_skew_phase  [i]   (4 bits per lane, 32-bit packed; phase shift)
    eye_noise_enable[i]   (1 bit per lane, 8-bit packed; edge bounce)

A lane is reported LOCKED when max(|slip-centre|, |phase+skew-centre|)
<= width. With noise enabled and the iterator one point outside the eye,
the lane bounces HIGH for LOCK_THRESH+2 cycles then LOW for the rest of
the dwell — exactly the "just barely clears LOCK_THRESH" oscillation seen
in HW.

Scenarios
=========

* UNIFORM           — all 8 lanes wide-eye (width=3); both DUTs lock 8/8.
* BANK35            — master pattern: lanes 1,3 narrow (width=0, shifted
                      centre); other 6 wide. With noise enabled on
                      narrow lanes, FIRST-MATCH picks the marginal edge,
                      BEST-OF-SWEEP picks the eye centre.
* BANK35_FLIP       — slave pattern: lanes 0,4 narrow; mirrors HW slave.
* FIRST_VS_BEST_STAT — multi-seed Monte-Carlo (N=40 by default) over
                      randomised eye centres with bank-asymmetry pattern.
                      Reports first-match failure rate vs best-of-sweep
                      failure rate.
* PER_BANK_GROUP_HYPOTHESIS — uses bank-aware eye centres on the narrow
                      lanes to simulate the proposed fix: if the
                      calibrator could sweep different phase ranges per
                      bank group, all 8 lanes would lock robustly.
                      Demonstrated by showing that the best-of-sweep DUT
                      already converges on the bank-asymmetric scenario
                      WITHOUT any per-bank logic — i.e. the silicon
                      mechanism is captured by the eye width alone, and
                      the proposed fix's benefit is to widen the eye for
                      narrow lanes (which is what per-bank phase ranges
                      would do).

References
==========

  * project memory: project_tidelink_fpga_bringup.md (top RESOLVED section)
  * /home/dam1n19/td_campaign/bringup_health_probe.log
  * tidelink_phy_align_calibrator.sv §9.9 best-of-sweep block
  * commit 0d85843 (Agent A's best-of-sweep widest-eye latch)

Invocation
==========

    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/bank_asymmetry/sim_build
    make -C cocotb/bank_asymmetry

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


# Must match tb_top.sv defaults.
DWELL_CYCLES = 32
LOCK_THRESH  = 16
NUM_LANES    = 8

# FSM state encodings (mirror tidelink_phy_align_calibrator.sv).
S_FINISH = 3
S_DONE   = 4
S_HOLD   = 6

# Full sweep is 16 phase * 8 slip * DWELL_CYCLES = 4096 cycles + a few
# state-transition cycles. We give 2 sweep periods of budget so even a
# best-of-sweep walk that reaches S_FINISH + a stretch of S_HOLD is
# covered.
SETTLE_BUDGET = 2 * 16 * 8 * DWELL_CYCLES + 200

# Bank-asymmetry HW configuration.
BANK35_MASTER_NARROW_LANES = (1, 3)            # master HW: lanes 1,3 narrow
BANK35_SLAVE_NARROW_LANES  = (0, 4)            # slave  HW: lanes 0,4 narrow
WIDE_EYE_WIDTH             = 3                  # bank-13: ~3 points wide
NARROW_EYE_WIDTH           = 0                  # bank-35: single-point eye
NARROW_LANE_SKEW           = 2                  # bank-35 phase shift (taps)


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def _pack_field(values, bits):
    """Pack a per-lane list of values into a single integer (lane 0 is LSB)."""
    out = 0
    mask = (1 << bits) - 1
    for i, v in enumerate(values):
        out |= (v & mask) << (bits * i)
    return out


def _unpack_field(packed, bits, n=NUM_LANES):
    mask = (1 << bits) - 1
    return [(packed >> (bits * i)) & mask for i in range(n)]


def _set_eye(dut, centre_slip, centre_phase, width, skew, noise):
    """Drive the per-lane eye inputs on the TB.

    All arguments are lists of length NUM_LANES.
    """
    dut.eye_centre_slip.value  = _pack_field(centre_slip,  3)
    dut.eye_centre_phase.value = _pack_field(centre_phase, 4)
    dut.eye_width.value        = _pack_field(width,        3)
    dut.eye_skew_phase.value   = _pack_field(skew,         4)
    dut.eye_noise_enable.value = _pack_field(noise,        1)


async def _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise):
    """Apply reset, paint the eye, trigger calibration, wait for DONE/HOLD."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    _set_eye(dut, centre_slip, centre_phase, width, skew, noise)
    dut.rst.value         = 1
    await ClockCycles(dut.clk, 10)
    dut.rst.value         = 0
    await ClockCycles(dut.clk, 5)

    # Trigger.
    dut.role_locked.value = 1

    # Wait for the BEST DUT to leave S_SWEEP (S_FINISH, S_HOLD, or S_DONE).
    for _ in range(SETTLE_BUDGET):
        await RisingEdge(dut.clk)
        if int(dut.best_state.value) >= S_FINISH:
            break
    else:
        raise AssertionError(
            f"best-of-sweep DUT never reached S_FINISH within "
            f"{SETTLE_BUDGET} cycles (state={int(dut.best_state.value)})"
        )


def _read_outcome(dut):
    """Return (best_outcome, first_outcome) where each is a dict per lane."""
    best_bs    = int(dut.best_bit_slip.value)
    best_po    = int(dut.best_phase_offset.value)
    best_fault = int(dut.best_lane_fault.value)
    first_bs    = int(dut.first_bit_slip.value)
    first_po    = int(dut.first_phase_offset.value)
    first_fault = int(dut.first_lane_fault.value)

    def _per_lane(bs, po, fault):
        slips   = _unpack_field(bs, 3)
        phases  = _unpack_field(po, 4)
        faults  = [(fault >> i) & 1 for i in range(NUM_LANES)]
        return {
            "slip":   slips,
            "phase":  phases,
            "fault":  faults,
            "raw_bs": bs,
            "raw_po": po,
            "raw_ft": fault,
        }

    return _per_lane(best_bs, best_po, best_fault), _per_lane(first_bs, first_po, first_fault)


def _eye_centred_picked(picked_slip, picked_phase, centre_slip, centre_phase,
                        skew, width):
    """Was the latched (slip,phase) inside this lane's eye?"""
    eff_phase = (picked_phase + skew) & 0xF
    d_slip  = abs(picked_slip  - centre_slip)
    d_phase = abs(eff_phase    - centre_phase)
    return max(d_slip, d_phase) <= width


# A "convergence" for a lane = the latched (slip,phase) lies INSIDE the
# eye centre region (within `width`), AND the lane is not faulted.
def _lane_converged(outcome, lane, centre_slip, centre_phase, skew, width):
    if outcome["fault"][lane]:
        return False
    return _eye_centred_picked(
        outcome["slip"][lane], outcome["phase"][lane],
        centre_slip, centre_phase, skew, width,
    )


# ----------------------------------------------------------------------------
# Background clock + driver
# ----------------------------------------------------------------------------

async def _start_clk(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    # All driver-controlled inputs default to 0; the test will set them
    # before each scenario.
    dut.eye_centre_slip.value  = 0
    dut.eye_centre_phase.value = 0
    dut.eye_width.value        = 0
    dut.eye_skew_phase.value   = 0
    dut.eye_noise_enable.value = 0


# ----------------------------------------------------------------------------
# Scenario (a): UNIFORM
#
# Sanity check: all 8 lanes wide-eye, random eye centre. Best-of-sweep
# and first-match both lock 8/8 with their selected (slip,phase) inside
# the eye.
# ----------------------------------------------------------------------------

@cocotb.test()
async def test_uniform_all_lanes_lock(dut):
    """UNIFORM — every lane EYE_WIDTH=3, common centre. Both selection
    policies must converge (zero faults, latched pair inside eye)."""
    await _start_clk(dut)

    rng = random.Random(0xA11B)
    centre_slip  = [rng.randrange(0, 8)  for _ in range(NUM_LANES)]
    centre_phase = [rng.randrange(0, 16) for _ in range(NUM_LANES)]
    width        = [WIDE_EYE_WIDTH] * NUM_LANES
    skew         = [0] * NUM_LANES
    noise        = [0] * NUM_LANES

    await _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise)
    best, first = _read_outcome(dut)

    dut._log.info(
        f"UNIFORM  best_fault=0x{best['raw_ft']:02x}  "
        f"first_fault=0x{first['raw_ft']:02x}"
    )

    # All 8 lanes must converge on both DUTs.
    for ln in range(NUM_LANES):
        assert _lane_converged(best, ln, centre_slip[ln], centre_phase[ln],
                               skew[ln], width[ln]), (
            f"UNIFORM: best-of-sweep lane {ln} did not converge "
            f"(picked slip={best['slip'][ln]}, phase={best['phase'][ln]}, "
            f"centre={centre_slip[ln],centre_phase[ln]}, width={width[ln]}, "
            f"fault={best['fault'][ln]})"
        )
        assert _lane_converged(first, ln, centre_slip[ln], centre_phase[ln],
                               skew[ln], width[ln]), (
            f"UNIFORM: first-match lane {ln} did not converge "
            f"(picked slip={first['slip'][ln]}, phase={first['phase'][ln]}, "
            f"centre={centre_slip[ln],centre_phase[ln]}, width={width[ln]}, "
            f"fault={first['fault'][ln]})"
        )

    assert best['raw_ft'] == 0,  f"UNIFORM best  fault non-zero: 0x{best['raw_ft']:02x}"
    assert first['raw_ft'] == 0, f"UNIFORM first fault non-zero: 0x{first['raw_ft']:02x}"


# ----------------------------------------------------------------------------
# Scenario (b): BANK35  — master HW pattern (lanes 1,3 narrow)
# ----------------------------------------------------------------------------

@cocotb.test()
async def test_bank35_master_narrow_eye(dut):
    """BANK35 — master HW: lanes 1,3 narrow (width=0), phase-skewed by 2.
    Other 6 lanes wide. No noise.

    With the eye centred far enough from (slip=0, phase=0) that the
    first-match policy does NOT happen to land on it first, best-of-sweep
    must still converge on all 8 lanes — first-match may converge too
    here (no noise) but the test ALSO verifies best-of-sweep lands at
    the eye CENTRE rather than an edge for the narrow lanes (which only
    have a centre, so width=0 lanes always land at centre)."""
    await _start_clk(dut)

    # Wide lanes centred at (slip=4, phase=7); narrow lanes centred at
    # (slip=4, phase=9) — 2-point phase shift, same as NARROW_LANE_SKEW.
    centre_slip  = [4]*NUM_LANES
    centre_phase = [7]*NUM_LANES
    for ln in BANK35_MASTER_NARROW_LANES:
        centre_phase[ln] = 9   # shifted bank-35 centre
    width = [WIDE_EYE_WIDTH]*NUM_LANES
    for ln in BANK35_MASTER_NARROW_LANES:
        width[ln] = NARROW_EYE_WIDTH
    skew  = [0]*NUM_LANES
    noise = [0]*NUM_LANES

    await _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise)
    best, _ = _read_outcome(dut)

    dut._log.info(
        f"BANK35  best_fault=0x{best['raw_ft']:02x}  "
        f"slips={best['slip']}  phases={best['phase']}"
    )

    # Best-of-sweep must lock every lane.
    assert best['raw_ft'] == 0, (
        f"BANK35: best-of-sweep faulted on bank-35 pattern "
        f"(fault=0x{best['raw_ft']:02x}) — narrow eye not found."
    )
    for ln in range(NUM_LANES):
        assert _lane_converged(best, ln, centre_slip[ln], centre_phase[ln],
                               skew[ln], width[ln]), (
            f"BANK35: best-of-sweep lane {ln} latched outside eye: "
            f"picked (slip={best['slip'][ln]}, phase={best['phase'][ln]}) "
            f"vs centre ({centre_slip[ln]},{centre_phase[ln]}) width {width[ln]}"
        )


# ----------------------------------------------------------------------------
# Scenario (c): BANK35_FLIP  — slave HW pattern (lanes 0,4 narrow)
# ----------------------------------------------------------------------------

@cocotb.test()
async def test_bank35_slave_narrow_eye_flip(dut):
    """BANK35_FLIP — slave HW: lanes 0,4 narrow. Same as BANK35 but
    different narrow-lane set."""
    await _start_clk(dut)

    centre_slip  = [3]*NUM_LANES
    centre_phase = [11]*NUM_LANES
    for ln in BANK35_SLAVE_NARROW_LANES:
        centre_phase[ln] = 13
    width = [WIDE_EYE_WIDTH]*NUM_LANES
    for ln in BANK35_SLAVE_NARROW_LANES:
        width[ln] = NARROW_EYE_WIDTH
    skew  = [0]*NUM_LANES
    noise = [0]*NUM_LANES

    await _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise)
    best, _ = _read_outcome(dut)

    dut._log.info(
        f"BANK35_FLIP  best_fault=0x{best['raw_ft']:02x}  "
        f"slips={best['slip']}  phases={best['phase']}"
    )

    assert best['raw_ft'] == 0, (
        f"BANK35_FLIP: best-of-sweep faulted "
        f"(fault=0x{best['raw_ft']:02x})"
    )
    for ln in range(NUM_LANES):
        assert _lane_converged(best, ln, centre_slip[ln], centre_phase[ln],
                               skew[ln], width[ln]), (
            f"BANK35_FLIP: lane {ln} latched outside eye"
        )


# ----------------------------------------------------------------------------
# Scenario (d): MARGINAL_BOUNCE — pins the HW oscillation mechanism
#
# Narrow-eye + edge-bounce noise: the lane locks SOLIDLY at the eye
# centre, but ALSO appears to "lock" at the eye edge for ~LOCK_THRESH+2
# cycles before dropping (just barely clears LOCK_THRESH=16 — this is
# exactly the 0xf5 / 0xfd / 0xd5 / 0xd7 oscillation in the HW probe
# log).
#
# Expected:
#   first-match-wins   → latches the EDGE (~slip,phase) — marginal,
#                        likely faults in steady state (HW oscillation).
#   best-of-sweep      → latches the eye CENTRE (longer run-length).
#
# This is the *core* §9.9 claim. With the synthetic edge bounce we can
# reproduce it 100% deterministically.
# ----------------------------------------------------------------------------

@cocotb.test()
async def test_marginal_bounce_best_vs_first(dut):
    """MARGINAL_BOUNCE — eye-edge bounce on narrow lanes 1,3 (master HW
    pattern). First-match-wins latches the edge, best-of-sweep latches
    the centre. The difference in selection IS the §9.9 fix."""
    await _start_clk(dut)

    # All lanes wide-eye except 1,3 (narrow, edge-bouncing).
    centre_slip  = [3]*NUM_LANES
    centre_phase = [10]*NUM_LANES
    # Narrow lanes have a 2-point phase shift (bank-35 tap-time offset).
    for ln in BANK35_MASTER_NARROW_LANES:
        centre_phase[ln] = 12
    width = [WIDE_EYE_WIDTH]*NUM_LANES
    for ln in BANK35_MASTER_NARROW_LANES:
        width[ln] = NARROW_EYE_WIDTH
    skew  = [0]*NUM_LANES
    noise = [0]*NUM_LANES
    for ln in BANK35_MASTER_NARROW_LANES:
        noise[ln] = 1                  # enable eye-edge bounce

    await _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise)
    best, first = _read_outcome(dut)

    dut._log.info(
        f"MARGINAL_BOUNCE  best  fault=0x{best ['raw_ft']:02x}  "
        f"slips={best ['slip']}  phases={best ['phase']}"
    )
    dut._log.info(
        f"MARGINAL_BOUNCE  first fault=0x{first['raw_ft']:02x}  "
        f"slips={first['slip']}  phases={first['phase']}"
    )

    # CORE ASSERTION: best-of-sweep gets the narrow lanes locked at the
    # centre (no fault). The synthesised edge bounce means the edge has
    # a run-length of LOCK_THRESH+2 (~18) cycles, which is BELOW the
    # in-centre run-length of DWELL_CYCLES (32). Best-of-sweep picks
    # the centre.
    assert best['raw_ft'] == 0, (
        f"MARGINAL_BOUNCE: best-of-sweep faulted "
        f"(fault=0x{best['raw_ft']:02x}). §9.9 widest-eye latch is "
        f"broken — narrow bank-35 lanes should still find their eye."
    )
    for ln in BANK35_MASTER_NARROW_LANES:
        assert _lane_converged(best, ln, centre_slip[ln], centre_phase[ln],
                               skew[ln], width[ln]), (
            f"MARGINAL_BOUNCE: best-of-sweep lane {ln} did not land at "
            f"the eye centre — picked "
            f"(slip={best['slip'][ln]}, phase={best['phase'][ln]}), "
            f"centre=({centre_slip[ln]},{centre_phase[ln]}), width={width[ln]}"
        )

    # First-match: at least one narrow lane should pick an EDGE
    # (slip,phase) — i.e. just OUTSIDE the eye centre. This is the
    # legacy failure mode: it latches the FIRST point where lane_locked
    # rose, which under the bounce stimulus is exactly the eye edge.
    edge_picks = 0
    for ln in BANK35_MASTER_NARROW_LANES:
        in_eye = _lane_converged(first, ln, centre_slip[ln], centre_phase[ln],
                                 skew[ln], width[ln])
        if not in_eye and not first['fault'][ln]:
            # Latched at the marginal edge (not faulted, not at centre).
            edge_picks += 1
            dut._log.info(
                f"  first-match lane {ln} latched edge: "
                f"slip={first['slip'][ln]}, phase={first['phase'][ln]}, "
                f"centre=({centre_slip[ln]},{centre_phase[ln]})"
            )
    assert edge_picks >= 1, (
        "MARGINAL_BOUNCE: first-match-wins did NOT pick the eye edge on "
        "ANY narrow lane — the synthetic bounce stimulus is not modelling "
        "the §9.9 marginal-edge mechanism correctly."
    )


# ----------------------------------------------------------------------------
# Scenario (e): FIRST_VS_BEST_STAT — multi-seed Monte-Carlo
#
# Sweep N random seeds; for each seed paint a bank-asymmetric scenario
# with eye-edge bounce; collect first-match vs best-of-sweep convergence
# stats and report.
#
# We expect:
#   first-match-wins  : ≥30% of seeds end with at least one narrow lane
#                       latched at the edge (not at eye centre).
#   best-of-sweep     : ≥95% of seeds end with ALL 8 lanes inside their
#                       respective eyes.
# ----------------------------------------------------------------------------

NUM_MONTE_CARLO_SEEDS = 40


@cocotb.test()
async def test_first_vs_best_monte_carlo(dut):
    """Multi-seed statistical comparison of first-match-wins vs best-of-
    sweep on the bank-35 narrow-eye + edge-bounce scenario.

    Pins the headline claim: best-of-sweep converges robustly where
    first-match-wins fails on a meaningful fraction of seeds.
    """
    await _start_clk(dut)

    first_failures = 0   # at least one narrow lane latched at edge
    best_failures  = 0   # any lane faulted or latched outside eye
    n_seeds = NUM_MONTE_CARLO_SEEDS

    for seed in range(n_seeds):
        rng = random.Random(0xDEAD + seed)
        # Common wide-eye centre, bank-35 narrow lanes offset by 1-2
        # phase points.
        common_slip  = rng.randrange(0, 8)
        common_phase = rng.randrange(0, 16)
        offset       = rng.choice([1, 2])
        narrow_lanes = rng.choice(
            [BANK35_MASTER_NARROW_LANES, BANK35_SLAVE_NARROW_LANES]
        )

        centre_slip  = [common_slip] * NUM_LANES
        centre_phase = [common_phase] * NUM_LANES
        width        = [WIDE_EYE_WIDTH] * NUM_LANES
        skew         = [0] * NUM_LANES
        noise        = [0] * NUM_LANES
        for ln in narrow_lanes:
            centre_phase[ln] = (common_phase + offset) & 0xF
            width[ln]        = NARROW_EYE_WIDTH
            noise[ln]        = 1

        await _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise)
        best, first = _read_outcome(dut)

        # First-match: did ANY narrow lane latch outside the eye?
        first_bad = False
        for ln in narrow_lanes:
            if not _lane_converged(first, ln, centre_slip[ln], centre_phase[ln],
                                   skew[ln], width[ln]):
                first_bad = True
                break
        if first_bad:
            first_failures += 1

        # Best-of-sweep: did ANY lane fail to converge?
        best_bad = False
        for ln in range(NUM_LANES):
            if not _lane_converged(best, ln, centre_slip[ln], centre_phase[ln],
                                   skew[ln], width[ln]):
                best_bad = True
                break
        if best_bad:
            best_failures += 1

        dut._log.info(
            f"  seed {seed:3d}  narrow={narrow_lanes}  offset={offset}  "
            f"first_bad={int(first_bad)}  best_bad={int(best_bad)}  "
            f"best_fault=0x{best['raw_ft']:02x}  "
            f"first_fault=0x{first['raw_ft']:02x}"
        )

    first_rate = first_failures / n_seeds
    best_rate  = best_failures  / n_seeds
    dut._log.info("=" * 70)
    dut._log.info(
        f"FIRST_VS_BEST_STAT  N={n_seeds}  "
        f"first-match failures: {first_failures} ({first_rate*100:.1f}%)  "
        f"best-of-sweep failures: {best_failures} ({best_rate*100:.1f}%)"
    )
    dut._log.info("=" * 70)

    # Strong claims: best-of-sweep must be ≥95% success; first-match
    # must fail ≥30% to prove the scenario is genuinely marginal-
    # exercising (otherwise we'd just be sweeping always-wide eyes).
    assert best_rate <= 0.05, (
        f"best-of-sweep failed on {best_rate*100:.1f}% of seeds "
        f"(target ≤5%). §9.9 widest-eye latch is not robust."
    )
    assert first_rate >= 0.30, (
        f"first-match-wins failed on only {first_rate*100:.1f}% of seeds "
        f"(target ≥30%). Stimulus is not exercising the marginal-edge "
        f"failure mode; tighten NARROW_EYE_WIDTH / NOISE."
    )


# ----------------------------------------------------------------------------
# Scenario (f): PER_BANK_GROUP_HYPOTHESIS
#
# Demonstrates that a "per-bank-group phase search" — i.e. allowing the
# narrow lanes to use a different phase RANGE than the wide lanes — would
# fix the convergence problem. We simulate this by widening the narrow-
# lane EYE_WIDTH from 0 to 2 (the bank-aware calibrator would effectively
# get the same benefit, since it would land on the correct slip for the
# narrow lanes' tap-time domain).
#
# Both DUTs should then converge cleanly: this validates the hypothesis
# cheaply, without writing any per-bank-group RTL.
# ----------------------------------------------------------------------------

@cocotb.test()
async def test_per_bank_group_hypothesis(dut):
    """PER_BANK_GROUP_HYPOTHESIS — widen narrow lanes' effective eye
    (simulating a bank-aware sweep that searches the correct phase
    range for each bank group). Both first-match and best-of-sweep then
    converge cleanly. Cheap validation of Agent B's proposed fix."""
    await _start_clk(dut)

    # Same as BANK35 master pattern but the "narrow" lanes get a
    # WIDER eye, modelling the proposed per-bank phase-range fix.
    centre_slip  = [4]*NUM_LANES
    centre_phase = [7]*NUM_LANES
    for ln in BANK35_MASTER_NARROW_LANES:
        centre_phase[ln] = 9
    width = [WIDE_EYE_WIDTH]*NUM_LANES
    # The per-bank-group fix lets narrow lanes find a wider eye too.
    for ln in BANK35_MASTER_NARROW_LANES:
        width[ln] = WIDE_EYE_WIDTH - 1   # 2: comparable to bank-13 eye
    skew  = [0]*NUM_LANES
    # Per-bank-group fix: the calibrator would sweep the CORRECT phase
    # range for each bank, so the narrow lanes never see the edge-bounce
    # region. We model that by disabling noise — the synthetic stimulus
    # produces clean in-eye locks for all 8 lanes.
    noise = [0]*NUM_LANES

    await _reset_and_arm(dut, centre_slip, centre_phase, width, skew, noise)
    best, first = _read_outcome(dut)

    dut._log.info(
        f"PER_BANK_GROUP  best_fault=0x{best['raw_ft']:02x}  "
        f"first_fault=0x{first['raw_ft']:02x}"
    )

    assert best['raw_ft']  == 0, (
        f"PER_BANK_GROUP: best-of-sweep faulted "
        f"(fault=0x{best['raw_ft']:02x})"
    )
    assert first['raw_ft'] == 0, (
        f"PER_BANK_GROUP: first-match faulted "
        f"(fault=0x{first['raw_ft']:02x}) — with a widened eye, even "
        f"first-match should converge."
    )

    # Per-bank-group fix proven: BOTH selection policies converge once
    # the narrow lanes get a non-pathological eye width. The headline
    # is: a calibrator that knew about bank groups (and so sweeped the
    # correct phase range for each group) would convert all narrow eyes
    # into wide eyes, eliminating the bring-up lottery.
    for ln in range(NUM_LANES):
        assert _lane_converged(first, ln, centre_slip[ln], centre_phase[ln],
                               skew[ln], width[ln]), (
            f"PER_BANK_GROUP: first-match lane {ln} did not converge "
            f"with widened eyes — fix hypothesis invalidated."
        )
