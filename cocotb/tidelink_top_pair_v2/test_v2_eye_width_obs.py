"""test_v2_eye_width_obs — Task 2 + Task 3 APB-decode gate (V2 top).

Proves on the real V2 tidelink_top APB surface that:

  * TASK 2 — the eye-width obs at SoC 0x4403_2150 now DECODES (returns the
    0xE7 presence marker in bits[31:24]) instead of 0x00000000. The bug was
    that the top-level prdata mux let eye_shim (tied to 0 in V2) win 0x2150;
    the fix excludes 0x2150 from eye_shim so the chiplet-controller's
    region10_rdata (ctrl_reg_r10 path) serves it.

  * TASK 3 — the eye-width LANE SELECT at SoC 0x4403_2154 is now APB-writable
    (was hardwired 3'h0 → only lane 0 readable). Write each lane index, read
    back the 0xE8 marker + the stored 3-bit value.

These are pure register-decode checks; they do not require a full link bring-up
(the decode is independent of calibrator state). A short reset + role-lock is
enough for the APB path to be live.

Run:
  make EPOCH_PROFILE=zero MODULE=test_v2_eye_width_obs

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, APB_TIDELINK_BASE

# SoC register offsets within the tidelink APB block (base 0x2000).
APB_EYE_WIDTH_SEL = APB_TIDELINK_BASE + 0x150   # 0x2150 EYE_WIDTH_SEL (RO)
APB_EYE_LANE_SEL  = APB_TIDELINK_BASE + 0x154   # 0x2154 EYE_LANE_SEL  (RW)


@cocotb.test()
async def test_eye_width_obs_decodes_marker(dut):
    """0x2150 returns the 0xE7 presence marker (Task 2 decode fix)."""
    tb = PairV2TB(dut)
    await tb.reset()
    await tb.do_role_lock()
    await ClockCycles(dut.hclk, 200)

    val = await tb.m_apb.read(APB_EYE_WIDTH_SEL)
    marker = (val >> 24) & 0xFF
    dut._log.info(f"0x2150 EYE_WIDTH_SEL read = 0x{val:08x} (marker=0x{marker:02x})")
    assert marker == 0xE7, (
        f"0x2150 marker = 0x{marker:02x}, expected 0xE7. The eye-width obs is "
        f"NOT decoded (eye_shim still wins 0x2150 in the top prdata mux)."
    )
    dut._log.info("PASS: 0x2150 decodes with the 0xE7 marker (Task 2 fixed).")


@cocotb.test()
async def test_eye_lane_sel_is_writable(dut):
    """0x2154 EYE_LANE_SEL is APB-writable, all 8 lanes; readback carries the
    0xE8 marker + the stored 3-bit lane (Task 3)."""
    tb = PairV2TB(dut)
    await tb.reset()
    await tb.do_role_lock()
    await ClockCycles(dut.hclk, 200)

    # Default (reset) must read lane 0.
    rb0 = await tb.m_apb.read(APB_EYE_LANE_SEL)
    assert (rb0 >> 24) & 0xFF == 0xE8, (
        f"0x2154 marker = 0x{(rb0 >> 24) & 0xFF:02x}, expected 0xE8 — "
        f"EYE_LANE_SEL not decoded."
    )
    assert rb0 & 0x7 == 0, f"reset EYE_LANE_SEL = {rb0 & 0x7}, expected lane 0."

    for lane in range(8):
        await tb.m_apb.write(APB_EYE_LANE_SEL, lane)
        await ClockCycles(dut.hclk, 4)
        rb = await tb.m_apb.read(APB_EYE_LANE_SEL)
        got = rb & 0x7
        marker = (rb >> 24) & 0xFF
        dut._log.info(f"  EYE_LANE_SEL <= {lane}: readback 0x{rb:08x} "
                      f"(lane={got}, marker=0x{marker:02x})")
        assert marker == 0xE8, f"lane {lane}: marker 0x{marker:02x} != 0xE8."
        assert got == lane, (
            f"EYE_LANE_SEL wrote {lane} but read {got} — register not writable."
        )
    dut._log.info("PASS: EYE_LANE_SEL RW across all 8 lanes (Task 3).")


@cocotb.test()
async def test_eye_width_follows_lane_sel(dut):
    """Selecting different lanes via 0x2154 routes the corresponding lane's
    eye-width fields out of 0x2150. We can't guarantee distinct widths per lane
    without a shaped eye, so this only asserts the read stays decoded (0xE7
    marker) for every lane select — the routing path is exercised."""
    tb = PairV2TB(dut)
    await tb.reset()
    await tb.do_role_lock()
    await ClockCycles(dut.hclk, 200)

    for lane in range(8):
        await tb.m_apb.write(APB_EYE_LANE_SEL, lane)
        await ClockCycles(dut.hclk, 8)
        val = await tb.m_apb.read(APB_EYE_WIDTH_SEL)
        marker = (val >> 24) & 0xFF
        width = val & 0x3F
        dut._log.info(f"  lane {lane}: 0x2150 = 0x{val:08x} "
                      f"(width={width}, marker=0x{marker:02x})")
        assert marker == 0xE7, (
            f"lane {lane}: 0x2150 marker 0x{marker:02x} != 0xE7 (decode lost "
            f"under lane-select routing)."
        )
    dut._log.info("PASS: 0x2150 stays decoded across all lane selects.")
