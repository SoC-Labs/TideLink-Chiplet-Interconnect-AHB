"""Variant 5 — Force calibrator into S_IDLE permanently on BOTH sides.

The cleanest way to keep the calibrator's FSM in S_IDLE without touching
the state register itself is to drive its `role_locked` INPUT (= local wire
`calibrator_role_locked` in axi_chiplet_controller) to 0 from t=0. With
role_locked=0 there is no rising edge to trigger the sweep, so the FSM
stays at S_IDLE forever and every output stays at its `S_IDLE` default
(training_mode=0, bit_slip=0, phase_offset=0, calibration_done=0).

This is the equivalent of AUTOCAL_ENABLE=0. If M→S works under this force
but variants 1, 3, 4 all fail, the bug is from a calibrator output not
covered by those variants (probably `bit_slip`) or some side-effect inside
the calibrator's clk_en gating that those variants don't suppress.

If variant 5 fails too, the bug is independent of the calibrator (and the
hypothesis behind this whole bisect is wrong).
"""
import cocotb
from cocotb.handle import Force
from pair_force_lib import run_variant


async def force_state_idle(tb):
    # Drive the calibrator's `role_locked` input low. This is the parameter-
    # equivalent of AUTOCAL_ENABLE=0 — `calibrator_role_locked` in
    # axi_chiplet_controller is the gated wire that feeds the calibrator.
    tb.calibrator("m").role_locked.value = Force(0)
    tb.calibrator("s").role_locked.value = Force(0)
    tb.log.info("  [force] cal role_locked := 0 on M and S → FSM held in S_IDLE")


@cocotb.test()
async def test_v5_force_state_idle(dut):
    result = await run_variant(dut, "v5_force_state_idle",
                               pre_reset_force=force_state_idle,
                               post_cal_done_force=None,
                               # In this variant cal_done will NEVER assert.
                               # Cap the wait at 5k cycles to short-circuit
                               # instead of the 500k baseline; the doorbell
                               # probe still runs.
                               cal_done_max_cycles=5000,
                               m_to_s_required=True)
    dut._log.info(f"[RESULT] {result}")
