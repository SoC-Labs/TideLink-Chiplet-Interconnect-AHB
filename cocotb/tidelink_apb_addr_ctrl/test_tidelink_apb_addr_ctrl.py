"""Cocotb testbench for tidelink_apb_addr_ctrl.

Standalone unit-test coverage for the APB-decoded segment-table register
file used by the TideLink address translator. Exercises:

  * Reset defaults (base_offset = 0, seg_addr = identity-map)
  * APB3 protocol smoke (pready always high, pslverr always low)
  * Base-offset RW including byte-strobe gating
  * Per-segment-register RW and identity-map reset semantics
  * Read-back through seg_addr unpacked output
  * CoreSight PIDR/CIDR ROM read values
  * Out-of-range register reads return the documented 0xCAFECAFE default
  * Writes to out-of-range / RO offsets are silently dropped (no pslverr)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# Parameters mirror tb_top defaults
ADDR_W      = 12
DATA_W      = 32
SEG_IDX_W   = 8
NUM_SEGS    = 256
SEG_PER_REG = DATA_W // SEG_IDX_W            # 4
NUM_SEG_REGS = NUM_SEGS // SEG_PER_REG       # 64

# Word-addressed register offsets in bytes
OFF_BASE_OFFSET = 0x000
OFF_SEG_BASE    = 0x004                      # first segment register
OFF_SEG_LAST    = OFF_SEG_BASE + (NUM_SEG_REGS - 1) * 4

# CoreSight ID register byte offsets (word-addr 0x3F4..0x3FF -> byte 0xFD0..0xFFC)
def _id_byte_off(word_addr: int) -> int:
    return word_addr * 4

OFF_PIDR4 = _id_byte_off(0x3F4)
OFF_PIDR5 = _id_byte_off(0x3F5)
OFF_PIDR6 = _id_byte_off(0x3F6)
OFF_PIDR7 = _id_byte_off(0x3F7)
OFF_PIDR0 = _id_byte_off(0x3F8)
OFF_PIDR1 = _id_byte_off(0x3F9)
OFF_PIDR2 = _id_byte_off(0x3FA)
OFF_PIDR3 = _id_byte_off(0x3FB)
OFF_CIDR0 = _id_byte_off(0x3FC)
OFF_CIDR1 = _id_byte_off(0x3FD)
OFF_CIDR2 = _id_byte_off(0x3FE)
OFF_CIDR3 = _id_byte_off(0x3FF)

EXPECTED_PIDR = {
    OFF_PIDR0: 0x59,
    OFF_PIDR1: 0x16,
    OFF_PIDR2: 0x15,
    OFF_PIDR3: 0x00,
    OFF_PIDR4: 0x00,
    OFF_PIDR5: 0x00,
    OFF_PIDR6: 0x00,
    OFF_PIDR7: 0x00,
    OFF_CIDR0: 0x50,
    OFF_CIDR1: 0x51,
    OFF_CIDR2: 0x4C,
    OFF_CIDR3: 0x54,
}

UNMAPPED_DEFAULT = 0xCAFECAFE


# ── BFM / helpers ───────────────────────────────────────────────────────────

async def setup(dut):
    cocotb.start_soon(Clock(dut.PCLK, CLK_PERIOD_NS, units="ns").start())
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = 0
    dut.pwdata.value  = 0
    dut.pprot.value   = 0
    dut.pstrb.value   = 0xF
    dut.PRESETn.value = 0


async def do_reset(dut):
    dut.PRESETn.value = 0
    await ClockCycles(dut.PCLK, 5)
    dut.PRESETn.value = 1
    await ClockCycles(dut.PCLK, 2)


async def apb_write(dut, addr, data, strb=0xF):
    """APB3 write: setup phase + access phase, no wait-state."""
    await RisingEdge(dut.PCLK)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 1
    dut.paddr.value   = addr & ((1 << ADDR_W) - 1)
    dut.pwdata.value  = data & ((1 << DATA_W) - 1)
    dut.pstrb.value   = strb & 0xF
    await RisingEdge(dut.PCLK)
    dut.penable.value = 1
    # Sample pready/pslverr in access phase
    await RisingEdge(dut.PCLK)
    pready  = int(dut.pready.value)
    pslverr = int(dut.pslverr.value)
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.pstrb.value   = 0xF
    return pready, pslverr


async def apb_read(dut, addr):
    """APB3 read: setup phase + access phase. Returns (rdata, pready, pslverr)."""
    await RisingEdge(dut.PCLK)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = addr & ((1 << ADDR_W) - 1)
    await RisingEdge(dut.PCLK)
    dut.penable.value = 1
    await RisingEdge(dut.PCLK)
    rdata   = int(dut.prdata.value)
    pready  = int(dut.pready.value)
    pslverr = int(dut.pslverr.value)
    dut.psel.value    = 0
    dut.penable.value = 0
    return rdata, pready, pslverr


def seg_addr_value(dut, seg_idx: int) -> int:
    """Extract the SEG_IDX_W-bit slice for segment `seg_idx` from the
    packed flat output vector."""
    flat = int(dut.seg_addr_flat.value)
    mask = (1 << SEG_IDX_W) - 1
    return (flat >> (seg_idx * SEG_IDX_W)) & mask


def identity_reg_value(reg_idx: int) -> int:
    """Reconstruct the identity-map reset value for segment register reg_idx."""
    val = 0
    for s in range(SEG_PER_REG):
        seg_val = (reg_idx * SEG_PER_REG + s) & ((1 << SEG_IDX_W) - 1)
        val |= seg_val << (s * SEG_IDX_W)
    return val


# ══════════════════════════════════════════════════════════════════════════════
# Reset / default-value tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_01_reset_base_offset_default(dut):
    """base_offset register reads 0 after reset, and the output port matches."""
    await setup(dut)
    await do_reset(dut)

    rdata, pready, pslverr = await apb_read(dut, OFF_BASE_OFFSET)
    assert rdata == 0, f"Expected base_offset=0 after reset, got 0x{rdata:08X}"
    assert pready == 1 and pslverr == 0
    assert int(dut.base_offset.value) == 0


@cocotb.test()
async def test_02_reset_seg_regs_identity(dut):
    """Every segment register resets to its identity-map default."""
    await setup(dut)
    await do_reset(dut)

    for k in range(NUM_SEG_REGS):
        addr = OFF_SEG_BASE + k * 4
        rdata, pready, pslverr = await apb_read(dut, addr)
        expected = identity_reg_value(k)
        assert rdata == expected, (
            f"Seg reg {k} (offset 0x{addr:03X}): expected 0x{expected:08X}, "
            f"got 0x{rdata:08X}"
        )
        assert pready == 1 and pslverr == 0


@cocotb.test()
async def test_03_reset_seg_addr_output_identity(dut):
    """seg_addr unpacked output reflects identity map after reset."""
    await setup(dut)
    await do_reset(dut)

    # Let outputs settle
    await ClockCycles(dut.PCLK, 1)

    mismatches = []
    for i in range(NUM_SEGS):
        val = seg_addr_value(dut, i)
        if val != (i & ((1 << SEG_IDX_W) - 1)):
            mismatches.append((i, val))
    assert not mismatches, f"seg_addr identity mismatches: {mismatches[:8]}..."


# ══════════════════════════════════════════════════════════════════════════════
# APB protocol smoke tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_04_apb_pready_always_high(dut):
    """pready is wired high — every transaction completes with no wait state."""
    await setup(dut)
    await do_reset(dut)

    # 1 write and 1 read across a mix of offsets
    for addr in (OFF_BASE_OFFSET, OFF_SEG_BASE, OFF_SEG_LAST, OFF_PIDR0, 0x800):
        pready_w, pslverr_w = await apb_write(dut, addr, 0xA5A5_A5A5)
        assert pready_w == 1, f"pready low on write to 0x{addr:03X}"
        assert pslverr_w == 0, f"pslverr high on write to 0x{addr:03X}"

        _, pready_r, pslverr_r = await apb_read(dut, addr)
        assert pready_r == 1, f"pready low on read from 0x{addr:03X}"
        assert pslverr_r == 0, f"pslverr high on read from 0x{addr:03X}"


@cocotb.test()
async def test_05_apb_pslverr_unmapped(dut):
    """Out-of-range reads return 0xCAFECAFE without asserting pslverr.

    The module deliberately ties pslverr low; the documented default for an
    unmapped offset is the sentinel value 0xCAFECAFE.
    """
    await setup(dut)
    await do_reset(dut)

    # 0x800 is well past the seg-reg window and below the ID-ROM window
    unmapped_offsets = [0x108, 0x400, 0x800, 0xC00, 0xF00]
    for addr in unmapped_offsets:
        rdata, pready, pslverr = await apb_read(dut, addr)
        assert pslverr == 0, f"pslverr asserted on unmapped 0x{addr:03X}"
        assert pready == 1
        assert rdata == UNMAPPED_DEFAULT, (
            f"Unmapped 0x{addr:03X}: expected 0x{UNMAPPED_DEFAULT:08X}, "
            f"got 0x{rdata:08X}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Base-offset register RW
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_06_base_offset_rw(dut):
    """base_offset is fully read-write; output port tracks the register."""
    await setup(dut)
    await do_reset(dut)

    patterns = [0xDEAD_BEEF, 0x0000_0001, 0xFFFF_FFFF, 0x1234_5678]
    for pat in patterns:
        await apb_write(dut, OFF_BASE_OFFSET, pat)
        await ClockCycles(dut.PCLK, 1)
        rdata, _, _ = await apb_read(dut, OFF_BASE_OFFSET)
        assert rdata == pat, f"base_offset RW: wrote 0x{pat:08X}, read 0x{rdata:08X}"
        assert int(dut.base_offset.value) == pat


@cocotb.test()
async def test_07_base_offset_byte_strobes(dut):
    """pstrb gates per-byte writes to base_offset."""
    await setup(dut)
    await do_reset(dut)

    # Initialise to known value
    await apb_write(dut, OFF_BASE_OFFSET, 0x1122_3344)
    await ClockCycles(dut.PCLK, 1)

    # Strobe only byte 0 with 0xFF: should clobber LSB only
    await apb_write(dut, OFF_BASE_OFFSET, 0xFFFF_FFFF, strb=0b0001)
    await ClockCycles(dut.PCLK, 1)
    rdata, _, _ = await apb_read(dut, OFF_BASE_OFFSET)
    assert rdata == 0x1122_33FF, f"Byte 0 only: expected 0x112233FF, got 0x{rdata:08X}"

    # Strobe bytes 1 and 3
    await apb_write(dut, OFF_BASE_OFFSET, 0xAABB_CCDD, strb=0b1010)
    await ClockCycles(dut.PCLK, 1)
    rdata, _, _ = await apb_read(dut, OFF_BASE_OFFSET)
    # bytes: [3]=AA new, [2]=22 keep, [1]=CC new, [0]=FF keep
    assert rdata == 0xAA22_CCFF, f"Strb=0b1010: expected 0xAA22CCFF, got 0x{rdata:08X}"


@cocotb.test()
async def test_08_base_offset_reset_clears(dut):
    """Asserting PRESETn returns base_offset to 0."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_BASE_OFFSET, 0xCAFE_BABE)
    await ClockCycles(dut.PCLK, 1)
    rdata, _, _ = await apb_read(dut, OFF_BASE_OFFSET)
    assert rdata == 0xCAFE_BABE

    await do_reset(dut)
    rdata, _, _ = await apb_read(dut, OFF_BASE_OFFSET)
    assert rdata == 0, f"base_offset did not clear after reset: 0x{rdata:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Segment-register RW
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_09_seg_reg_first_rw(dut):
    """First seg register (offset 0x004) is fully RW."""
    await setup(dut)
    await do_reset(dut)

    pat = 0xA1B2_C3D4
    await apb_write(dut, OFF_SEG_BASE, pat)
    await ClockCycles(dut.PCLK, 1)
    rdata, _, _ = await apb_read(dut, OFF_SEG_BASE)
    assert rdata == pat, f"Seg reg 0 RW: wrote 0x{pat:08X}, read 0x{rdata:08X}"

    # Verify the per-segment output array unpacks each byte correctly
    for s in range(SEG_PER_REG):
        expected = (pat >> (s * SEG_IDX_W)) & ((1 << SEG_IDX_W) - 1)
        got = seg_addr_value(dut, s)
        assert got == expected, (
            f"seg_addr[{s}]: expected 0x{expected:02X}, got 0x{got:02X}"
        )


@cocotb.test()
async def test_10_seg_reg_last_rw(dut):
    """Last seg register at the end of the window is RW and reachable."""
    await setup(dut)
    await do_reset(dut)

    pat = 0xFACE_F00D
    await apb_write(dut, OFF_SEG_LAST, pat)
    await ClockCycles(dut.PCLK, 1)
    rdata, _, _ = await apb_read(dut, OFF_SEG_LAST)
    assert rdata == pat, (
        f"Seg reg {NUM_SEG_REGS - 1} RW: wrote 0x{pat:08X}, read 0x{rdata:08X}"
    )

    # Last register feeds the top 4 segments
    base_seg = (NUM_SEG_REGS - 1) * SEG_PER_REG
    for s in range(SEG_PER_REG):
        expected = (pat >> (s * SEG_IDX_W)) & ((1 << SEG_IDX_W) - 1)
        got = seg_addr_value(dut, base_seg + s)
        assert got == expected, (
            f"seg_addr[{base_seg + s}]: expected 0x{expected:02X}, got 0x{got:02X}"
        )


@cocotb.test()
async def test_11_seg_reg_walk_all(dut):
    """Program every seg register with a unique pattern, read every one back."""
    await setup(dut)
    await do_reset(dut)

    # Write phase: unique pattern per register
    patterns = [((k * 0x01010101) ^ 0xA5A5_A5A5) & 0xFFFF_FFFF
                for k in range(NUM_SEG_REGS)]
    for k, pat in enumerate(patterns):
        await apb_write(dut, OFF_SEG_BASE + k * 4, pat)
    await ClockCycles(dut.PCLK, 1)

    # Read-back phase
    for k, pat in enumerate(patterns):
        rdata, _, _ = await apb_read(dut, OFF_SEG_BASE + k * 4)
        assert rdata == pat, (
            f"Seg reg {k}: wrote 0x{pat:08X}, read 0x{rdata:08X}"
        )


@cocotb.test()
async def test_12_seg_reg_byte_strobes(dut):
    """pstrb gates per-byte (per-segment) writes within a seg register."""
    await setup(dut)
    await do_reset(dut)

    # Write a known full pattern
    await apb_write(dut, OFF_SEG_BASE, 0x1020_3040)
    await ClockCycles(dut.PCLK, 1)

    # Update only byte 2 (segment index 2 within the register)
    await apb_write(dut, OFF_SEG_BASE, 0x00AA_0000, strb=0b0100)
    await ClockCycles(dut.PCLK, 1)
    rdata, _, _ = await apb_read(dut, OFF_SEG_BASE)
    assert rdata == 0x10AA_3040, (
        f"Byte-strobe on seg reg: expected 0x10AA3040, got 0x{rdata:08X}"
    )


@cocotb.test()
async def test_13_seg_regs_reset_to_identity(dut):
    """After writing all seg regs, reset returns them to identity map."""
    await setup(dut)
    await do_reset(dut)

    # Clobber every seg reg
    for k in range(NUM_SEG_REGS):
        await apb_write(dut, OFF_SEG_BASE + k * 4, 0xFFFF_FFFF)
    await ClockCycles(dut.PCLK, 1)

    await do_reset(dut)

    # Spot-check a handful of registers
    for k in (0, 1, NUM_SEG_REGS // 2, NUM_SEG_REGS - 1):
        rdata, _, _ = await apb_read(dut, OFF_SEG_BASE + k * 4)
        expected = identity_reg_value(k)
        assert rdata == expected, (
            f"Seg reg {k} post-reset: expected 0x{expected:08X}, got 0x{rdata:08X}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# CoreSight ID ROM (RO)
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_14_coresight_id_rom_values(dut):
    """PIDR/CIDR ROM bytes match the documented constants."""
    await setup(dut)
    await do_reset(dut)

    for addr, expected in EXPECTED_PIDR.items():
        rdata, pready, pslverr = await apb_read(dut, addr)
        assert pready == 1 and pslverr == 0
        assert rdata == expected, (
            f"ID ROM 0x{addr:03X}: expected 0x{expected:02X}, "
            f"got 0x{rdata:08X}"
        )


@cocotb.test()
async def test_15_coresight_id_rom_writes_ignored(dut):
    """Writes to ID-ROM offsets are dropped silently (no pslverr, value unchanged)."""
    await setup(dut)
    await do_reset(dut)

    for addr, expected in EXPECTED_PIDR.items():
        _, pslverr_w = await apb_write(dut, addr, 0xFFFF_FFFF)
        assert pslverr_w == 0, f"pslverr asserted writing ID ROM 0x{addr:03X}"
        rdata, _, _ = await apb_read(dut, addr)
        assert rdata == expected, (
            f"ID ROM 0x{addr:03X} mutated by write: expected 0x{expected:02X}, "
            f"got 0x{rdata:08X}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Out-of-range / unmapped writes
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_16_unmapped_write_no_side_effect(dut):
    """Writes to unmapped offsets don't corrupt the mapped registers."""
    await setup(dut)
    await do_reset(dut)

    # Snapshot known state
    await apb_write(dut, OFF_BASE_OFFSET, 0x1111_2222)
    await apb_write(dut, OFF_SEG_BASE,     0x3333_4444)
    await ClockCycles(dut.PCLK, 1)

    # Hit a pile of unmapped offsets
    for addr in (0x108, 0x200, 0x400, 0x800, 0xC00, 0xF00):
        await apb_write(dut, addr, 0xDEAD_BEEF)
    await ClockCycles(dut.PCLK, 1)

    rdata, _, _ = await apb_read(dut, OFF_BASE_OFFSET)
    assert rdata == 0x1111_2222, f"base_offset corrupted: 0x{rdata:08X}"
    rdata, _, _ = await apb_read(dut, OFF_SEG_BASE)
    assert rdata == 0x3333_4444, f"seg reg 0 corrupted: 0x{rdata:08X}"
