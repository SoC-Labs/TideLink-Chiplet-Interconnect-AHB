"""test_eye_force_phase_override — proposal §9 test #4.

Writes SWI_FORCE_PHASE_VAL and asserts the override flows through to
the calibrator's per-lane 4-bit phase output (`phase_offset[31:0]`,
lane N at `[4N+3:4N]`).

Override conditions (proposal §5 SWI_FORCE_PHASE_EN):
  [0] override-en        — top-level "phase/slip override active"
  [1] skip-calibrator    — keep FSM in S_IDLE (covered in test #5)
  [2] freeze-on-cal-done — leave the override flowing after DONE

For this test we exercise mode [0]=1 and assert the per-lane phase
field arrives unchanged at the calibrator's `phase_offset` output.

The companion register SWI_FORCE_SLIP_VAL covers per-lane 3-bit slip;
we verify the same propagation path via `bit_slip[23:0]`.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.triggers import ClockCycles

from eye_common import (
    SWI_FORCE_PHASE_EN, SWI_FORCE_PHASE_VAL, SWI_FORCE_SLIP_VAL,
    FORCE_EN_OVERRIDE,
    apb_idle, apb_write,
    start_clock_and_reset,
)


def _pack_per_lane_4b(values):
    """Pack a list of eight 4-bit ints into a 32-bit word; lane N at
    bits [4N+3 : 4N]."""
    assert len(values) == 8
    out = 0
    for lane, v in enumerate(values):
        out |= (v & 0xF) << (4 * lane)
    return out


def _pack_per_lane_3b(values):
    """Pack a list of eight 3-bit ints into a 24-bit word; lane N at
    bits [3N+2 : 3N]."""
    assert len(values) == 8
    out = 0
    for lane, v in enumerate(values):
        out |= (v & 0x7) << (3 * lane)
    return out


def _unpack_per_lane_4b(word):
    return [(word >> (4 * lane)) & 0xF for lane in range(8)]


def _unpack_per_lane_3b(word):
    return [(word >> (3 * lane)) & 0x7 for lane in range(8)]


@cocotb.test()
async def test_force_phase_per_lane_propagates(dut):
    """Programme an arbitrary per-lane phase pattern, enable the
    override, and read phase_offset back out of the DUT."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0
    await apb_idle(dut)
    await start_clock_and_reset(dut)

    target_phases = [0x3, 0x9, 0xC, 0x5, 0x7, 0xE, 0x1, 0xA]
    packed = _pack_per_lane_4b(target_phases)

    await apb_write(dut, SWI_FORCE_PHASE_VAL, packed)
    await apb_write(dut, SWI_FORCE_PHASE_EN, FORCE_EN_OVERRIDE)
    await ClockCycles(dut.clk, 8)

    observed = int(dut.phase_offset.value)
    observed_per_lane = _unpack_per_lane_4b(observed)

    assert observed_per_lane == target_phases, (
        f"phase_offset per-lane mismatch:\n"
        f"  programmed = {[hex(v) for v in target_phases]}\n"
        f"  observed   = {[hex(v) for v in observed_per_lane]}\n"
        f"SWI_FORCE_PHASE_VAL is not flowing into the calibrator's "
        f"phase_offset output. Spec §5 SWI_FORCE_PHASE_VAL bit layout: "
        f"lane N at [4N+3:4N]."
    )

    dut._log.info("OK: per-lane SWI_FORCE_PHASE_VAL flows to phase_offset.")


@cocotb.test()
async def test_force_slip_per_lane_propagates(dut):
    """Same as above but for SWI_FORCE_SLIP_VAL (24 bits, per-lane 3 bit
    slip). Verified via the calibrator's bit_slip[23:0] output."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0
    await apb_idle(dut)
    await start_clock_and_reset(dut)

    target_slips = [0x5, 0x2, 0x7, 0x0, 0x4, 0x3, 0x6, 0x1]
    packed = _pack_per_lane_3b(target_slips)

    await apb_write(dut, SWI_FORCE_SLIP_VAL, packed)
    await apb_write(dut, SWI_FORCE_PHASE_EN, FORCE_EN_OVERRIDE)
    await ClockCycles(dut.clk, 8)

    observed = int(dut.bit_slip.value)
    observed_per_lane = _unpack_per_lane_3b(observed)

    assert observed_per_lane == target_slips, (
        f"bit_slip per-lane mismatch:\n"
        f"  programmed = {[hex(v) for v in target_slips]}\n"
        f"  observed   = {[hex(v) for v in observed_per_lane]}\n"
        f"SWI_FORCE_SLIP_VAL is not flowing into bit_slip."
    )

    dut._log.info("OK: per-lane SWI_FORCE_SLIP_VAL flows to bit_slip.")


@cocotb.test()
async def test_force_phase_disabled_does_not_override(dut):
    """Negative control: with SWI_FORCE_PHASE_EN[0]=0, writes to
    SWI_FORCE_PHASE_VAL must NOT affect phase_offset."""
    dut.role_locked.value = 0
    dut.swreset.value     = 0
    dut.lane_locked.value = 0
    await apb_idle(dut)
    await start_clock_and_reset(dut)

    # Capture the natural (override-off) phase_offset value first.
    baseline = int(dut.phase_offset.value)

    target_phases = [0xF] * 8
    packed = _pack_per_lane_4b(target_phases)
    # Programme the override register, but DO NOT enable.
    await apb_write(dut, SWI_FORCE_PHASE_VAL, packed)
    await ClockCycles(dut.clk, 8)

    observed = int(dut.phase_offset.value)
    assert observed == baseline, (
        f"With FORCE_PHASE_EN[0]=0, SWI_FORCE_PHASE_VAL leaked into "
        f"phase_offset (baseline=0x{baseline:08x}, observed=0x{observed:08x}). "
        f"The override-enable gate is missing."
    )

    dut._log.info(
        "OK: SWI_FORCE_PHASE_EN[0]=0 correctly disables the override path."
    )
