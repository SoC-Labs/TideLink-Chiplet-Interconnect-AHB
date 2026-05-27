"""Variant 1 — Force `cal_training_mode_w = 0` on both M and S from t=0.

Hypothesis: the calibrator's `training_mode` output, asserted during S_ARM /
S_SWEEP / S_HOLD, is leaking through the OR-mux into Wlink's
`swi_training_mode_in` and corrupting the TX framing.  If clamping it to 0
makes M→S work, the residual training_mode is the smoking gun.

NOTE: with this force the calibrator can never put the link into training
mode at all → equivalent of AUTOCAL=0 path. Other calibrator outputs
(phase/bit_slip/lane_locked feedback) still progress.
"""
import cocotb
from cocotb.handle import Force
from pair_force_lib import run_variant


async def force_training_mode_zero(tb):
    # The calibrator's output is `training_mode` (a logic output).
    # Forcing this output to 0 will make `cal_training_mode_w = 0`, which
    # OR's with `swi_training_mode_r` (POR default 0) into
    # `swi_training_mode_w = 0` → Wlink stays in data mode.
    tb.calibrator("m").training_mode.value = Force(0)
    tb.calibrator("s").training_mode.value = Force(0)
    tb.log.info("  [force] cal training_mode := 0 on M and S")


@cocotb.test()
async def test_v1_training_mode_zero_t0(dut):
    result = await run_variant(dut, "v1_training_mode_zero_t0",
                               pre_reset_force=force_training_mode_zero,
                               post_cal_done_force=None)
    dut._log.info(f"[RESULT] {result}")
