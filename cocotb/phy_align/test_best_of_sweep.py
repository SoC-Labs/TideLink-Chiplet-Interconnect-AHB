"""§9.9 best-of-sweep widest-eye selection — pointer to the unit test.

The actual best-of-sweep selection-policy test lives in the calibrator's
standalone unit testbench, NOT in this pair-level suite. The standalone
TB elaborates TWO copies of `tidelink_phy_align_calibrator` (one with
the silicon-default EARLY_EXIT_ON_ALL_LOCKED=0 / best-of-sweep, one with
EARLY_EXIT_ON_ALL_LOCKED=1 / §9.7 first-match-wins) and drives the same
lane_locked trajectory into both. That structural setup is impossible
to express in the pair TB (which has one calibrator per chiplet, both
forced to the same policy globally).

Run it via:

    rm -rf cocotb/tidelink_phy_align_calibrator/sim_build
    make -C cocotb/tidelink_phy_align_calibrator TB_VARIANT=compare

The test asserts that with an "eye-edge marginal" stimulus on lane 0:

  * The best-of-sweep DUT latches the widest-eye (slip,phase) pair.
  * The first-match-wins DUT latches the first-eye-edge (slip,phase) pair.
  * The two DUTs therefore pick DIFFERENT (slip,phase) — proving the
    §9.9 selection policy is actually different from §9.7 on a marginal
    input.

It also includes a sub-scenario asserting that a lane whose best
in-dwell run-length never reaches LOCK_THRESH gets faulted at sweep
exhaustion (rather than latching a sub-threshold pair).

This is the test mandated by the §9.9 RTL change: see commit message
"fix(§9 calibrator): best-of-sweep widest-eye latch ...".
"""

import cocotb
from cocotb.triggers import Timer


@cocotb.test(skip=True)
async def test_best_of_sweep_pointer(dut):
    """Skipped: the real test lives at
    cocotb/tidelink_phy_align_calibrator/test_best_of_sweep_compare.py.
    See module docstring for the run command."""
    await Timer(1, unit="ns")
