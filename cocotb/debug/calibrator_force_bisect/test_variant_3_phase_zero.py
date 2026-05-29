"""Variant 3 — Force the calibrator's per-lane phase to 0 from t=0.

Hypothesis: the per-lane `phase[*]` registers (sampled into output
`phase_offset[31:0]` = 8×4-bit) differ between M and S after S_DONE because
each side independently picked its best phase. A non-zero per-lane phase on
ONE side can rotate the Wlink deserialiser bit-select by N positions, which
would misalign TX framing for the OPPOSITE direction (since the calibrator
runs on RX, but its output drives TX framing through `swi_phase_offset_in`).

If forcing `cal_phase_offset_w = 0` on both sides makes M→S work, the phase
asymmetry is the smoking gun. The integration path passes the phase from
the calibrator's RX-side optimisation into the Wlink TX-side framing logic.
"""
import cocotb
from cocotb.handle import Force
from pair_force_lib import run_variant


async def force_phase_zero(tb):
    # The calibrator drives `phase_offset[31:0]` as an output — force the
    # entire 32-bit bus to zero on both sides.
    tb.calibrator("m").phase_offset.value = Force(0)
    tb.calibrator("s").phase_offset.value = Force(0)
    tb.log.info("  [force] cal phase_offset := 32'h0 on M and S")


@cocotb.test()
async def test_v3_phase_zero(dut):
    result = await run_variant(dut, "v3_phase_zero",
                               pre_reset_force=force_phase_zero,
                               post_cal_done_force=None)
    dut._log.info(f"[RESULT] {result}")
