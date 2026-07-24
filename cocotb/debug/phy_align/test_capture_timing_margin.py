"""DRAFT / PROPOSED — capture-timing-MARGIN guard for the GPIO-PHY pair.

   *** This is a PROTOTYPE produced by the SIM_GUARD_FEASIBILITY analysis. ***
   *** It is NOT wired into CI and NOT committed. See docs/SIM_GUARD_     ***
   *** FEASIBILITY.md for the honest scope discussion before relying on it.***

WHAT THIS DOES (and does NOT) GUARD
-----------------------------------
The 2026-05 XDC/clock saga had TWO root defects (docs/reference/LANE_LOCK_ROOT_CAUSE.md):

  Bug A  USE_CLKBUF/USE_IDELAY stripped (51b5169) -> recovered capture clock
         on a LUT-driven net -> HOLD violation -> cal_done=0 -> 0/16 lock.
  Bug B  XDC procedural Tcl silently dropped (Designutils 20-1307) ->
         IODELAY_GROUP / capture-skew bounds / TX-eye constraints vanished.

NEITHER of those is an RTL-functional defect. Both are PHYSICAL / CONSTRAINT
defects (placement of a LUT on a clock net; a constraint not reaching the
router). A pure event-driven RTL simulator (cocotb) has NO concept of:
  * routed clock-network topology (BUFG vs LUT vs general routing),
  * picosecond clk->data skew at an IOB,
  * setup/hold timing, jitter, or an XDC file at all.
So this test CANNOT see Bug A or Bug B directly. Do not pretend otherwise.

WHAT IS GENUINELY CATCHABLE IN SIM, and what this prototype actually asserts:

  (1) The FUNCTIONAL CONTRACT the calibrator must satisfy: with per-lane
      capture-window misalignment present, the autocal sweep must still
      converge to 16/16 (all 8 lanes, both directions). The existing
      pad_skid model injects per-lane INTEGER-bit-period skew between the
      forwarded clock and data — that is the only timing axis RTL sim can
      represent. We assert convergence under a deliberately HOSTILE asymmetric
      per-lane skid pattern (the realistic PCB-routing case). A regression
      that breaks the calibrator's ability to tolerate per-lane misalignment
      (e.g. collapses per-lane slip back to a global value) is then caught
      in seconds instead of on a 22-minute FPGA build.

  (2) A NEGATIVE CONTROL proving the harness has teeth: a lane forced
      stuck-at-0 (STUCK_LANES_MASK) must NOT lock, and the calibrator must
      REPORT it as un-locked (not silently claim cal_done with a dead lane).
      This is the closest sim analogue to "a lane outside the capture window":
      if a future change made cal_done assert with a dead lane, that is the
      same false-PASS shape as the 0/16-but-reported-good silicon bug.

HONEST LIMITATION (also stated in test_phase_sweep.py): in zero-jitter RTL
sim with the period-8 training byte, ANY integer pad misalignment is
correctable by bit-slip alone. There is no sub-bit eye, no hold window, no
"this lane is 0.5 UI off" — those live only in the timing-analysed netlist.
So this test guards the calibrator's FUNCTIONAL robustness and observability,
NOT capture-timing margin in picoseconds. The picosecond/placement layer is
guarded at BUILD time (fpga msg gate commit 57c2810 + fpga/scripts/
verify_xdc.tcl) and at LINT time (lint/verilator), NOT here.

Invocation (from cocotb/phy_align/), once promoted out of DRAFT:
    make MODULE=test_capture_timing_margin SKID_BITS=3
The pair simv does NOT auto-rebuild on submodule RTL edits:
    rm -rf sim_build ../wlink_pair/sim_build && make clean   # before runs
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave, snapshot


# --------------------------------------------------------------------------
# Helpers (mirror test_pair_align.py so this prototype is self-contained and
# does not perturb the existing tests).
# --------------------------------------------------------------------------
def _gpio_path(dut, side):
    inst = dut.u_master if side == "m" else dut.u_slave
    return inst.u_wlink.phy.gpio


def _read_lane_locked(dut, side):
    sig = dut.master_lane_locked if side == "m" else dut.slave_lane_locked
    return int(sig.value)


def _stuck_mask(env_name):
    raw = os.environ.get(env_name, "") or "0"
    try:
        return int(raw, 0)
    except ValueError:
        return 0


@cocotb.test()
async def test_calibrator_converges_under_asymmetric_skew(dut):
    """POSITIVE: with an asymmetric per-lane capture misalignment present
    (pad_skid integer-bit skew, the only timing axis RTL sim can model),
    role-lock + autocal must still drive BOTH directions to 16/16.

    This guards the FUNCTIONAL contract the FPGA bug ultimately violated:
    the calibrator must align every lane independently. It does NOT — and
    cannot — observe the LUT-on-clock hold violation that caused the
    silicon 0/16; see module docstring + SIM_GUARD_FEASIBILITY.md.
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Give the autocal sweep generous time to walk slip x phase on every lane,
    # both directions. The pair model cross-wires each TX through pad_skid to
    # the peer RX, so a single convergence window covers both directions.
    await ClockCycles(dut.master_clk, 20000)

    m = _read_lane_locked(dut, "m")
    s = _read_lane_locked(dut, "s")
    await snapshot(dut, "m", "asym-skew")
    await snapshot(dut, "s", "asym-skew")
    dut._log.info(f"  master_lane_locked=0x{m:02x}  slave_lane_locked=0x{s:02x}")

    assert s == 0xFF, (
        f"master->slave path did not reach 16/16 under asymmetric per-lane "
        f"skew: slave_lane_locked=0x{s:02x}. The calibrator's per-lane "
        f"alignment robustness regressed (the FUNCTIONAL shape of the FPGA "
        f"0/16 bug). NOTE: a real LUT-on-clock hold violation is NOT visible "
        f"here — that is a build-time/lint guard. See SIM_GUARD_FEASIBILITY.md."
    )
    assert m == 0xFF, (
        f"slave->master path did not reach 16/16 under asymmetric per-lane "
        f"skew: master_lane_locked=0x{m:02x}. See assertion above."
    )
    dut._log.info("OK: 16/16 both directions under asymmetric per-lane skew.")


@cocotb.test()
async def test_dead_lane_is_reported_not_silently_passed(dut):
    """NEGATIVE CONTROL: a lane forced stuck-at-0 must NOT lock, and that
    must be VISIBLE in lane_locked. This is the sim analogue of "a lane is
    outside the capture window": the failure shape we must never let report
    a false good (the silicon bug looked PASSED while locking 0/16).

    Drive STUCK_LANES_MASK via the wlink_pair Makefile knob, e.g.:
        make MODULE=test_capture_timing_margin STUCK_LANES_MASK=0x10
    With no mask set this test SKIPS (it needs a stuck lane to be meaningful).
    """
    mask = _stuck_mask("STUCK_LANES_MASK")
    if mask == 0:
        dut._log.warning(
            "STUCK_LANES_MASK=0 -> no dead lane to model; skipping the "
            "negative control. Re-run with STUCK_LANES_MASK=0x10 (lane 4)."
        )
        return

    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 20000)

    s = _read_lane_locked(dut, "s")
    await snapshot(dut, "s", "dead-lane")
    dut._log.info(f"  STUCK_LANES_MASK=0x{mask:02x}  slave_lane_locked=0x{s:02x}")

    stuck_lanes = [b for b in range(8) if (mask >> b) & 1]
    for lane in stuck_lanes:
        assert not ((s >> lane) & 1), (
            f"lane {lane} is forced stuck-at-0 by STUCK_LANES_MASK but "
            f"reports LOCKED (slave_lane_locked=0x{s:02x}). The lane checker "
            f"is asserting lock on a dead lane -> a future cal_done could "
            f"falsely report good with a non-locking lane (the silicon "
            f"false-PASS shape). This is the regression this control guards."
        )
    dut._log.info(
        f"OK: stuck lane(s) {stuck_lanes} correctly reported un-locked "
        f"(slave_lane_locked=0x{s:02x}) — the harness has teeth."
    )
