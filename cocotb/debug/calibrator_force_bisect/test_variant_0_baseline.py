"""Variant 0 — BASELINE.

No hierarchical forces applied. AUTOCAL_ENABLE=1 (RTL default). Reproduces
the HW symptom (M→S broken under AUTOCAL=1) and serves as the reference
against which the force variants are compared.
"""
import cocotb
from pair_force_lib import run_variant


@cocotb.test()
async def test_v0_baseline(dut):
    result = await run_variant(dut, "v0_baseline",
                               pre_reset_force=None,
                               post_cal_done_force=None)
    dut._log.info(f"[RESULT] {result}")
    # No assertion — we want the run to complete and report PASS/FAIL of the
    # two doorbell crossings via the log.
