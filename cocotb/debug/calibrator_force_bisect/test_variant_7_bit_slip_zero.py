"""Variant 7 — Force the calibrator's `bit_slip[23:0]` output to 0 from t=0.

Companion to variant 3 (phase_offset := 0). With both phase_offset and
bit_slip held at 0, the OR-mux into Wlink's `swi_*_in` is dominated by
the SW-side `swi_*_r` registers (all zero at POR). If this variant makes
M→S work and variant 3 does not, the calibrator's `bit_slip` per-lane
post-DONE latch is the smoking gun.
"""
import cocotb
from cocotb.handle import Force
from pair_force_lib import run_variant


async def force_bit_slip_zero(tb):
    tb.calibrator("m").bit_slip.value = Force(0)
    tb.calibrator("s").bit_slip.value = Force(0)
    tb.log.info("  [force] cal bit_slip := 24'h0 on M and S")


@cocotb.test()
async def test_v7_bit_slip_zero(dut):
    result = await run_variant(dut, "v7_bit_slip_zero",
                               pre_reset_force=force_bit_slip_zero,
                               post_cal_done_force=None)
    dut._log.info(f"[RESULT] {result}")
