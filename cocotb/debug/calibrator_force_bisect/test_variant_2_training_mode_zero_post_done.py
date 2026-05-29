"""Variant 2 — Allow the calibrator to sweep, but clamp `cal_training_mode_w`
to 0 once both sides reach S_DONE.

Hypothesis: distinguishes "residual training_mode after S_DONE" from "any
training_mode at all". If variant 1 passes M→S and variant 2 also passes
M→S, then the post-DONE residual is the smoking gun. If variant 1 passes
and variant 2 fails, the bug is from the during-sweep behaviour (not post).
"""
import cocotb
from cocotb.handle import Force
from pair_force_lib import run_variant


async def force_training_mode_zero_post_done(tb):
    tb.calibrator("m").training_mode.value = Force(0)
    tb.calibrator("s").training_mode.value = Force(0)
    tb.log.info("  [force] (post-DONE) cal training_mode := 0 on M and S")


@cocotb.test()
async def test_v2_training_mode_zero_post_done(dut):
    result = await run_variant(dut, "v2_training_mode_zero_post_done",
                               pre_reset_force=None,
                               post_cal_done_force=force_training_mode_zero_post_done)
    dut._log.info(f"[RESULT] {result}")
