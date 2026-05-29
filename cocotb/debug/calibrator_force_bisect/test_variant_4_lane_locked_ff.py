"""Variant 4 — Force calibrator INPUT `lane_locked = 8'hFF` on both sides
from t=0.

Hypothesis: the lane checker feeds a noisy / asymmetric lane_locked vector
back to the calibrator, which influences which sweep iterations end in
DONE vs CANCEL. If we pin lane_locked=FF (= "all lanes locked, all the
time"), the calibrator should converge to a benign state immediately and
M→S should work — unless the bug is downstream of the calibrator's
decisions (i.e. in its output drive of Wlink), in which case M→S still
fails.
"""
import cocotb
from cocotb.handle import Force
from pair_force_lib import run_variant


async def force_lane_locked_ff(tb):
    tb.calibrator("m").lane_locked.value = Force(0xFF)
    tb.calibrator("s").lane_locked.value = Force(0xFF)
    tb.log.info("  [force] cal lane_locked := 8'hFF on M and S")


@cocotb.test()
async def test_v4_lane_locked_ff(dut):
    result = await run_variant(dut, "v4_lane_locked_ff",
                               pre_reset_force=force_lane_locked_ff,
                               post_cal_done_force=None)
    dut._log.info(f"[RESULT] {result}")
