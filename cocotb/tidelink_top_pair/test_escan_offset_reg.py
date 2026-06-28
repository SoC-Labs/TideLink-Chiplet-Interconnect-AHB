# =============================================================================
# test_escan_offset_reg.py — runtime MMIO ESCAN_OFFSET register (Region D slot 3,
# SoC 0x4403_21AC). Mirrors test_eyescan_arm_default_off.py (the 0x215C chicken-
# bit) for the new FIX-CENTER-LITE runtime eye-centre nudge register.
#
#   (A) DEFAULT-OFF: with NO write to 0x4403_21AC, the reg reads 0 on both dies
#       (presence marker 0xEA confirms the new slot is live, offset[2:0]=0), and
#       a full doorbell bring-up + crossing still works -> integration inert at
#       POR (reset value 0 -> calibrator uses its synth ESCAN_CENTER_OFFSET
#       default -> bit-identical to FIX-R).
#
#   (B) RW + read-back: a write of an offset value on both dies latches
#       swi_escan_offset_r (read-back [2:0]=value, marker 0xEA), proving the
#       Region-D slot-3 write/read path reaches the controller and is NOT
#       shadowed by any eye_regs/gpio_phy slave.
#
#   (C) FIELD ISOLATION: only [2:0] is captured; the upper write bits are
#       dropped (the reg is 3 bits) and the marker is always 0xEA.
#
# ADDRESS NOTE: the integration brief named SoC 0x4403_2160, but that address is
# apb_region 4'b1011 (Region 11), already owned by the tidelink_gpio_phy APB
# slave. Region 10 (0x2140-0x215F) is full (slots 1-7 used; slot 0 = EPOCH).
# The next free CONTROLLER-DECODED RW slot is Region D (rxcap, 0x21A0-0x21BF)
# slot 3 = 0x4403_21AC (slots 0-2 are the rxcap observability words). Region D
# folds onto the same ctrl_reg write/read path as the chicken-bit and is outside
# both the eye_shim (Region 10) and gpio_phy (Region 11) windows, so no top-level
# shim exclusion is needed.
#
# Joint work commissioned on behalf of SoC Labs, Arm Academic Access license.
# Contributors: David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, APB_TIDELINK_BASE, APB_DOORBELL, APB_DOORBELL_RESP_ACC,
    run_bringup_full,
)

# Region D slot 3 ESCAN_OFFSET (SoC 0x4403_21AC => APB offset 0x1AC).
APB_ESCAN_OFFSET = APB_TIDELINK_BASE + 0x1AC
ESCAN_OFFSET_MARKER = 0xEA


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_escan_offset_default_off(dut):
    """DEFAULT-OFF: unwritten 0x21AC reads offset=0 (marker 0xEA) on both dies,
    and a full doorbell bring-up + crossing works -> integration inert at POR."""
    tb = PairTB(dut)

    # Run the full proven bring-up WITHOUT touching 0x21AC.
    await run_bringup_full(tb)

    m_off = await tb.m_apb.read(APB_ESCAN_OFFSET)
    s_off = await tb.s_apb.read(APB_ESCAN_OFFSET)
    tb.log.info(f"[escan-off] default 0x21AC: M=0x{m_off:08x} S=0x{s_off:08x}")

    # Direct reg peek (load-bearing): the controller reg is 0 at POR.
    m_reg = _i(dut.u_master.u_chiplet_controller.swi_escan_offset_r)
    s_reg = _i(dut.u_slave.u_chiplet_controller.swi_escan_offset_r)
    assert m_reg == 0 and s_reg == 0, (
        f"swi_escan_offset_r not 0 at POR (default-off broken): M={m_reg} S={s_reg}")

    # APB read-back: marker 0xEA in [31:24], offset[2:0]=0.
    for side, v in (("M", m_off), ("S", s_off)):
        assert ((v >> 24) & 0xFF) == ESCAN_OFFSET_MARKER, (
            f"{side} 0x21AC missing 0xEA presence marker: 0x{v:08x} "
            f"(slot not routed to controller / shadowed?)")
        assert (v & 0x7) == 0, f"{side} 0x21AC offset != 0 at POR: 0x{v:08x}"

    # And the link is up + a doorbell crosses (byte-identical link-up).
    cleared = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(tb.dut.hclk, 20)
    await tb.m_apb.write(APB_DOORBELL, 1)
    await ClockCycles(tb.dut.hclk, 2000)
    s_db = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    tb.log.info(f"[escan-off] default-off doorbell crossed: clr={cleared} after={s_db}")
    assert s_db != 0, (
        "default-off: doorbell did NOT cross with offset=0 "
        "(integration regressed the proven path)")

    tb.log.info("[escan-off] PASS: 0x21AC default offset=0 (marker 0xEA), link-up "
                "+ doorbell crossing intact -> offset integration inert at POR.")


@cocotb.test()
async def test_escan_offset_rw_readback(dut):
    """RW: write 0x21AC=value pre-link on both dies -> reg + read-back show
    offset=value (marker 0xEA). Proves the slot-3 write/read path reaches the
    controller (Region D ctrl_reg path; not eye_regs/gpio_phy shadowed)."""
    tb = PairTB(dut)
    await tb.reset()

    WR_VAL = 5
    await tb.m_apb.write(APB_ESCAN_OFFSET, WR_VAL)
    await tb.s_apb.write(APB_ESCAN_OFFSET, WR_VAL)
    await ClockCycles(tb.dut.hclk, 20)

    m_reg = _i(dut.u_master.u_chiplet_controller.swi_escan_offset_r)
    s_reg = _i(dut.u_slave.u_chiplet_controller.swi_escan_offset_r)
    assert m_reg == WR_VAL and s_reg == WR_VAL, (
        f"swi_escan_offset_r did not latch the write: M={m_reg} S={s_reg} "
        f"(expected {WR_VAL}; Region-D slot-3 write decode failed)")

    m_off = await tb.m_apb.read(APB_ESCAN_OFFSET)
    s_off = await tb.s_apb.read(APB_ESCAN_OFFSET)
    tb.log.info(f"[escan-off] written 0x21AC: M=0x{m_off:08x} S=0x{s_off:08x}")
    for side, v in (("M", m_off), ("S", s_off)):
        assert ((v >> 24) & 0xFF) == ESCAN_OFFSET_MARKER, (
            f"{side} 0x21AC missing 0xEA marker after write: 0x{v:08x}")
        assert (v & 0x7) == WR_VAL, (
            f"{side} 0x21AC offset wrong after write: 0x{v:08x} "
            f"(read-back shadowed / wrong field?)")

    tb.log.info("[escan-off] PASS: 0x21AC offset RW + read-back live in V1.")


@cocotb.test()
async def test_escan_offset_field_isolation(dut):
    """FIELD ISOLATION: a write with set upper bits captures ONLY [2:0]; the
    marker stays 0xEA. Confirms the reg is 3 bits and nothing else is clobbered."""
    tb = PairTB(dut)
    await tb.reset()

    # Write 0xFFFF_FFF7 -> only [2:0]=7 should land.
    await tb.m_apb.write(APB_ESCAN_OFFSET, 0xFFFFFFF7)
    await ClockCycles(tb.dut.hclk, 20)

    m_reg = _i(dut.u_master.u_chiplet_controller.swi_escan_offset_r)
    assert m_reg == 0x7, f"upper bits leaked into reg: 0x{m_reg:x} (expected 0x7)"

    m_off = await tb.m_apb.read(APB_ESCAN_OFFSET)
    assert ((m_off >> 24) & 0xFF) == ESCAN_OFFSET_MARKER, (
        f"marker corrupted: 0x{m_off:08x}")
    # Bits [23:3] must be 0 (only marker + 3-bit field).
    assert (m_off & 0x00FFFFF8) == 0, (
        f"reserved bits non-zero in read-back: 0x{m_off:08x}")
    assert (m_off & 0x7) == 0x7, f"offset field wrong: 0x{m_off:08x}"

    tb.log.info("[escan-off] PASS: 0x21AC captures only [2:0], marker 0xEA intact.")
