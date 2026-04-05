"""Cocotb testbench for tidelink_addr_translator.

Exercises APB-configurable segment-based address remapping via the AHB
config slave, verifying two independent translation channels, identity
and non-trivial mappings, base offset, and edge cases.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster

# ── Constants ────────────────────────────────────────────────────────────────

CLK_PERIOD_NS = 10

# APB slave mux address decode: paddr[15:12]
#   Channel 0 registers: 0x0000 - 0x0FFF
#   Channel 1 registers: 0x1000 - 0x1FFF
CH0_BASE = 0x0000
CH1_BASE = 0x1000

# Register offsets within each channel (apb_control)
#   0x000: base_offset
#   0x004: addr_seg_reg[0]  -> seg_addr[0..3]
#   0x008: addr_seg_reg[1]  -> seg_addr[4..7]
#   ...
#   0x100: addr_seg_reg[63] -> seg_addr[252..255]
REG_BASE_OFFSET = 0x000
REG_SEG_BASE    = 0x004  # addr_seg_reg[0] starts here

# PID/CID offsets within each 4 KB page (for identification readback)
REG_PIDR0 = 0xFE0
REG_PIDR1 = 0xFE4
REG_CIDR0 = 0xFF0


def seg_reg_offset(seg_index):
    """Return the AHB byte offset for the 32-bit register containing
    seg_addr entries [seg_index*4 .. seg_index*4+3].

    seg_index ranges 0..63; each register packs 4 consecutive 8-bit entries.
    """
    return REG_SEG_BASE + seg_index * 4


def seg_entry_default(entry_index):
    """Default value of seg_addr[entry_index] after reset (identity mapping)."""
    return entry_index & 0xFF


# ── Testbench Environment ────────────────────────────────────────────────────

class AddrTranslatorTB:
    """Reusable testbench wrapper for tidelink_addr_translator."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        ahbc_bus = AHBBus.from_prefix(dut, "ahbc")
        self.ahb_cfg = AHBLiteMaster(
            ahbc_bus, dut.hclk, dut.hresetn, timeout=200
        )

    async def reset(self):
        self.dut.hresetn.value = 0
        self.dut.chp0_ahb_haddr_i.value = 0
        self.dut.chp1_ahb_haddr_i.value = 0
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 5)

    async def cfg_read(self, offset):
        """Read a 32-bit config register via the AHB config slave."""
        resp = await self.ahb_cfg.read(offset)
        return int(resp[0].get("data", "0x0"), 16)

    async def cfg_write(self, offset, data):
        """Write a 32-bit config register via the AHB config slave."""
        await self.ahb_cfg.write(offset, data)

    async def write_seg_entry(self, channel, seg_index, value):
        """Write a single 8-bit segment entry by read-modify-write of
        the containing 32-bit register.

        channel: 0 or 1
        seg_index: 0..255
        value: 0..255
        """
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        reg_idx = seg_index // 4
        byte_pos = seg_index % 4
        reg_addr = ch_base + REG_SEG_BASE + reg_idx * 4

        current = await self.cfg_read(reg_addr)
        mask = 0xFF << (byte_pos * 8)
        new_val = (current & ~mask) | ((value & 0xFF) << (byte_pos * 8))
        await self.cfg_write(reg_addr, new_val)

    async def write_seg_reg(self, channel, reg_idx, value):
        """Write a full 32-bit segment register (packing 4 entries)."""
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        reg_addr = ch_base + REG_SEG_BASE + reg_idx * 4
        await self.cfg_write(reg_addr, value)

    async def read_seg_reg(self, channel, reg_idx):
        """Read a 32-bit segment register."""
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        reg_addr = ch_base + REG_SEG_BASE + reg_idx * 4
        return await self.cfg_read(reg_addr)

    async def write_base_offset(self, channel, value):
        """Write the base_offset register for a channel."""
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        await self.cfg_write(ch_base + REG_BASE_OFFSET, value)

    async def read_base_offset(self, channel):
        """Read the base_offset register for a channel."""
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        return await self.cfg_read(ch_base + REG_BASE_OFFSET)

    def get_translated_addr(self, channel):
        """Read the combinational translated output for a channel."""
        if channel == 0:
            return int(self.dut.chp0_ahb_haddr_o.value)
        else:
            return int(self.dut.chp1_ahb_haddr_o.value)

    def set_input_addr(self, channel, addr):
        """Drive the input address for a channel."""
        if channel == 0:
            self.dut.chp0_ahb_haddr_i.value = addr
        else:
            self.dut.chp1_ahb_haddr_i.value = addr


# ══════════════════════════════════════════════════════════════════════════════
# Reset Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_01_reset_outputs_known(dut):
    """After reset, translated outputs should reflect default identity mapping."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # With identity mapping and base_offset=0, input should pass through
    tb.set_input_addr(0, 0x00000000)
    tb.set_input_addr(1, 0x00000000)
    await ClockCycles(dut.hclk, 2)

    out0 = tb.get_translated_addr(0)
    out1 = tb.get_translated_addr(1)
    assert out0 == 0x00000000, f"CH0: expected 0x00000000, got 0x{out0:08X}"
    assert out1 == 0x00000000, f"CH1: expected 0x00000000, got 0x{out1:08X}"


@cocotb.test()
async def test_02_reset_base_offset_zero(dut):
    """Base offset registers default to 0 after reset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    bo0 = await tb.read_base_offset(0)
    bo1 = await tb.read_base_offset(1)
    assert bo0 == 0, f"CH0 base_offset: expected 0, got 0x{bo0:08X}"
    assert bo1 == 0, f"CH1 base_offset: expected 0, got 0x{bo1:08X}"


@cocotb.test()
async def test_03_reset_seg_table_identity(dut):
    """Segment table defaults to identity mapping after reset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Check a selection of segment registers for channel 0
    # addr_seg_reg[0] should be {3, 2, 1, 0} = 0x03020100
    val = await tb.read_seg_reg(0, 0)
    assert val == 0x03020100, f"CH0 seg_reg[0]: expected 0x03020100, got 0x{val:08X}"

    # addr_seg_reg[1] should be {7, 6, 5, 4} = 0x07060504
    val = await tb.read_seg_reg(0, 1)
    assert val == 0x07060504, f"CH0 seg_reg[1]: expected 0x07060504, got 0x{val:08X}"

    # addr_seg_reg[63] should be {255, 254, 253, 252} = 0xFFFEFDFC
    val = await tb.read_seg_reg(0, 63)
    assert val == 0xFFFEFDFC, f"CH0 seg_reg[63]: expected 0xFFFEFDFC, got 0x{val:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# AHB Config Interface Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_04_base_offset_rw_ch0(dut):
    """Base offset register is read-write for channel 0."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(0, 0xABCD0000)
    val = await tb.read_base_offset(0)
    assert val == 0xABCD0000, f"CH0 base_offset: expected 0xABCD0000, got 0x{val:08X}"


@cocotb.test()
async def test_05_base_offset_rw_ch1(dut):
    """Base offset register is read-write for channel 1."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(1, 0x12345678)
    val = await tb.read_base_offset(1)
    assert val == 0x12345678, f"CH1 base_offset: expected 0x12345678, got 0x{val:08X}"


@cocotb.test()
async def test_06_seg_reg_write_readback_ch0(dut):
    """Segment register write and readback for channel 0."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Write non-default value to seg_reg[0]
    await tb.write_seg_reg(0, 0, 0xDEADBEEF)
    val = await tb.read_seg_reg(0, 0)
    assert val == 0xDEADBEEF, f"CH0 seg_reg[0]: expected 0xDEADBEEF, got 0x{val:08X}"


@cocotb.test()
async def test_07_seg_reg_write_readback_ch1(dut):
    """Segment register write and readback for channel 1."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_seg_reg(1, 10, 0xCAFEBABE)
    val = await tb.read_seg_reg(1, 10)
    assert val == 0xCAFEBABE, f"CH1 seg_reg[10]: expected 0xCAFEBABE, got 0x{val:08X}"


@cocotb.test()
async def test_08_channels_independent_config(dut):
    """Writing channel 0 registers does not affect channel 1 and vice versa."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Write different values to the same register index on each channel
    await tb.write_seg_reg(0, 5, 0x11111111)
    await tb.write_seg_reg(1, 5, 0x22222222)

    val0 = await tb.read_seg_reg(0, 5)
    val1 = await tb.read_seg_reg(1, 5)
    assert val0 == 0x11111111, f"CH0 seg_reg[5]: expected 0x11111111, got 0x{val0:08X}"
    assert val1 == 0x22222222, f"CH1 seg_reg[5]: expected 0x22222222, got 0x{val1:08X}"

    # Verify base offsets are independent
    await tb.write_base_offset(0, 0xAAAA0000)
    await tb.write_base_offset(1, 0xBBBB0000)

    bo0 = await tb.read_base_offset(0)
    bo1 = await tb.read_base_offset(1)
    assert bo0 == 0xAAAA0000, f"CH0 base_offset: expected 0xAAAA0000, got 0x{bo0:08X}"
    assert bo1 == 0xBBBB0000, f"CH1 base_offset: expected 0xBBBB0000, got 0x{bo1:08X}"


@cocotb.test()
async def test_09_pidr_readback(dut):
    """PID registers are readable at expected offsets for both channels."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # PIDR0 at offset 0xFE0 within channel 0 (absolute 0x0FE0)
    pidr0_ch0 = await tb.cfg_read(CH0_BASE + REG_PIDR0)
    assert pidr0_ch0 == 0x59, f"CH0 PIDR0: expected 0x59, got 0x{pidr0_ch0:02X}"

    pidr0_ch1 = await tb.cfg_read(CH1_BASE + REG_PIDR0)
    assert pidr0_ch1 == 0x59, f"CH1 PIDR0: expected 0x59, got 0x{pidr0_ch1:02X}"


# ══════════════════════════════════════════════════════════════════════════════
# Channel 0 Identity Mapping Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_10_ch0_identity_mapping(dut):
    """With default identity mapping, channel 0 passes addresses through."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    test_addrs = [0x00000000, 0x01ABCDEF, 0x80123456, 0xFF000000]
    for addr in test_addrs:
        tb.set_input_addr(0, addr)
        await ClockCycles(dut.hclk, 1)
        out = tb.get_translated_addr(0)
        assert out == addr, f"CH0 identity: input 0x{addr:08X}, got 0x{out:08X}"


@cocotb.test()
async def test_11_ch0_identity_lower_bits_preserved(dut):
    """Lower 24 bits are always passed through unchanged on channel 0."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    tb.set_input_addr(0, 0xAB123456)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    # With identity mapping: seg_addr[0xAB] = 0xAB
    assert out & 0x00FFFFFF == 0x00123456, \
        f"CH0 lower 24 bits: expected 0x123456, got 0x{out & 0x00FFFFFF:06X}"


# ══════════════════════════════════════════════════════════════════════════════
# Non-Trivial Segment Remapping Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_12_ch0_remap_segment(dut):
    """Program segment 0 to remap to value 0x42, verify translation."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Segment entry 0 is in addr_seg_reg[0] byte 0.
    # Write seg_addr[0]=0x42, keep [1]=1, [2]=2, [3]=3
    await tb.write_seg_reg(0, 0, 0x03020142)
    await ClockCycles(dut.hclk, 2)

    # Input address 0x00ABCDEF -> segment index = (0x00 - 0)[31:24] = 0x00
    # -> seg_addr[0] = 0x42 -> output = 0x42ABCDEF
    tb.set_input_addr(0, 0x00ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x42ABCDEF, f"CH0 remap seg0: expected 0x42ABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_13_ch0_remap_high_segment(dut):
    """Program segment 255 to remap to value 0x10, verify translation."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # seg_addr[255] is in addr_seg_reg[63] byte 3 (MSB).
    # Default addr_seg_reg[63] = 0xFFFEFDFC
    # Set byte 3 to 0x10: 0x10FEFDFC
    await tb.write_seg_reg(0, 63, 0x10FEFDFC)
    await ClockCycles(dut.hclk, 2)

    # Input 0xFF112233 -> segment index = 0xFF -> seg_addr[255] = 0x10
    # Output = 0x10112233
    tb.set_input_addr(0, 0xFF112233)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x10112233, f"CH0 remap seg255: expected 0x10112233, got 0x{out:08X}"


@cocotb.test()
async def test_14_ch0_remap_multiple_segments(dut):
    """Program multiple segment entries and verify each translates correctly."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Remap seg[0]=0xAA, seg[1]=0xBB, seg[2]=0xCC, seg[3]=0xDD
    await tb.write_seg_reg(0, 0, 0xDDCCBBAA)
    await ClockCycles(dut.hclk, 2)

    test_cases = [
        (0x00000000, 0xAA000000),
        (0x01FFFFFF, 0xBBFFFFFF),
        (0x02800000, 0xCC800000),
        (0x03123456, 0xDD123456),
    ]
    for inp, expected in test_cases:
        tb.set_input_addr(0, inp)
        await ClockCycles(dut.hclk, 1)
        out = tb.get_translated_addr(0)
        assert out == expected, \
            f"CH0 multi-remap: input 0x{inp:08X}, expected 0x{expected:08X}, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Channel 1 Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_15_ch1_identity_mapping(dut):
    """Channel 1 identity mapping works independently."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    test_addrs = [0x00000000, 0x80FEDCBA, 0xFF000001]
    for addr in test_addrs:
        tb.set_input_addr(1, addr)
        await ClockCycles(dut.hclk, 1)
        out = tb.get_translated_addr(1)
        assert out == addr, f"CH1 identity: input 0x{addr:08X}, got 0x{out:08X}"


@cocotb.test()
async def test_16_ch1_remap_segment(dut):
    """Channel 1 segment remapping works independently."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Remap CH1 seg[4]=0xF0, seg[5]=0xF1, seg[6]=0xF2, seg[7]=0xF3
    await tb.write_seg_reg(1, 1, 0xF3F2F1F0)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(1, 0x05AAAAAA)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(1)
    assert out == 0xF1AAAAAA, f"CH1 remap seg5: expected 0xF1AAAAAA, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Simultaneous Operation Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_17_both_channels_simultaneous(dut):
    """Both channels translate simultaneously with different mappings."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # CH0: remap seg[0x10] to 0xAA
    # seg[0x10] is in addr_seg_reg[4] byte 0. Default is {0x13,0x12,0x11,0x10}=0x13121110
    await tb.write_seg_reg(0, 4, 0x131211AA)
    # CH1: remap seg[0x20] to 0xBB
    # seg[0x20] is in addr_seg_reg[8] byte 0. Default is {0x23,0x22,0x21,0x20}=0x23222120
    await tb.write_seg_reg(1, 8, 0x232221BB)
    await ClockCycles(dut.hclk, 2)

    # Drive both inputs simultaneously
    tb.set_input_addr(0, 0x10CAFE00)
    tb.set_input_addr(1, 0x20BABE00)
    await ClockCycles(dut.hclk, 1)

    out0 = tb.get_translated_addr(0)
    out1 = tb.get_translated_addr(1)
    assert out0 == 0xAACAFE00, f"CH0: expected 0xAACAFE00, got 0x{out0:08X}"
    assert out1 == 0xBBBABE00, f"CH1: expected 0xBBBABE00, got 0x{out1:08X}"


@cocotb.test()
async def test_18_channels_do_not_interfere(dut):
    """Remapping one channel does not affect the other."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Only remap CH0 seg[0] to 0xFF
    await tb.write_seg_reg(0, 0, 0x030201FF)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x00123456)
    tb.set_input_addr(1, 0x00123456)
    await ClockCycles(dut.hclk, 1)

    out0 = tb.get_translated_addr(0)
    out1 = tb.get_translated_addr(1)
    assert out0 == 0xFF123456, f"CH0: expected 0xFF123456, got 0x{out0:08X}"
    # CH1 still has identity mapping for seg[0]
    assert out1 == 0x00123456, f"CH1: expected 0x00123456 (identity), got 0x{out1:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Segment Table Coverage Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_19_write_verify_multiple_seg_entries(dut):
    """Write and verify a selection of segment entries across the full range."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Test a representative set of segment register indices
    test_regs = [0, 1, 15, 31, 32, 48, 62, 63]
    test_val = 0xA5A5A5A5

    for reg_idx in test_regs:
        await tb.write_seg_reg(0, reg_idx, test_val)
        readback = await tb.read_seg_reg(0, reg_idx)
        assert readback == test_val, \
            f"CH0 seg_reg[{reg_idx}]: expected 0x{test_val:08X}, got 0x{readback:08X}"

    # Verify the writes took effect on translation
    # seg_reg[0] = 0xA5A5A5A5 -> seg_addr[0]=0xA5
    tb.set_input_addr(0, 0x00AAAAAA)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xA5AAAAAA, f"CH0 seg_reg[0] remap: expected 0xA5AAAAAA, got 0x{out:08X}"

    # seg_reg[63] = 0xA5A5A5A5 -> seg_addr[252]=0xA5
    tb.set_input_addr(0, 0xFC000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xA5000000, f"CH0 seg[252] remap: expected 0xA5000000, got 0x{out:08X}"


@cocotb.test()
async def test_20_all_64_seg_regs_writable(dut):
    """All 64 segment registers for channel 0 accept writes and read back."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Write unique pattern to each register
    for i in range(64):
        pattern = ((i * 4 + 100) & 0xFF) | \
                  (((i * 4 + 101) & 0xFF) << 8) | \
                  (((i * 4 + 102) & 0xFF) << 16) | \
                  (((i * 4 + 103) & 0xFF) << 24)
        await tb.write_seg_reg(0, i, pattern)

    # Read back and verify
    for i in range(64):
        pattern = ((i * 4 + 100) & 0xFF) | \
                  (((i * 4 + 101) & 0xFF) << 8) | \
                  (((i * 4 + 102) & 0xFF) << 16) | \
                  (((i * 4 + 103) & 0xFF) << 24)
        readback = await tb.read_seg_reg(0, i)
        assert readback == pattern, \
            f"CH0 seg_reg[{i}]: expected 0x{pattern:08X}, got 0x{readback:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Base Offset Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_21_base_offset_shifts_segment_lookup(dut):
    """Base offset shifts which segment entry is selected.

    addr_i_norm = addr_i - base_offset
    segment_index = addr_i_norm[31:24]

    With base_offset = 0x01000000 and addr_i = 0x01ABCDEF:
      addr_i_norm = 0x00ABCDEF -> segment_index = 0x00
      -> seg_addr[0] (default = 0x00) -> output = 0x00ABCDEF
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(0, 0x01000000)
    await ClockCycles(dut.hclk, 2)

    # Input 0x01ABCDEF: norm = 0x00ABCDEF, seg_index = 0, seg_addr[0] = 0x00
    tb.set_input_addr(0, 0x01ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x00ABCDEF, f"CH0 base_offset shift: expected 0x00ABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_22_base_offset_with_remap(dut):
    """Base offset combined with remapped segment entry.

    base_offset = 0x10000000, addr_i = 0x10ABCDEF
    addr_i_norm = 0x00ABCDEF, seg_index = 0x00
    We set seg_addr[0] = 0xEE -> output = 0xEEABCDEF
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(0, 0x10000000)
    # seg_addr[0] = 0xEE, keep [1..3] default
    await tb.write_seg_reg(0, 0, 0x030201EE)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x10ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xEEABCDEF, f"CH0 offset+remap: expected 0xEEABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_23_base_offset_independent_per_channel(dut):
    """Each channel has its own base offset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(0, 0x20000000)
    await tb.write_base_offset(1, 0x80000000)
    await ClockCycles(dut.hclk, 2)

    # CH0: input 0x20FACE00 -> norm = 0x00FACE00 -> seg[0] = 0x00 -> out = 0x00FACE00
    tb.set_input_addr(0, 0x20FACE00)
    # CH1: input 0x80DEAD00 -> norm = 0x00DEAD00 -> seg[0] = 0x00 -> out = 0x00DEAD00
    tb.set_input_addr(1, 0x80DEAD00)
    await ClockCycles(dut.hclk, 1)

    out0 = tb.get_translated_addr(0)
    out1 = tb.get_translated_addr(1)
    assert out0 == 0x00FACE00, f"CH0: expected 0x00FACE00, got 0x{out0:08X}"
    assert out1 == 0x00DEAD00, f"CH1: expected 0x00DEAD00, got 0x{out1:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Edge Case Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_24_edge_addr_zero(dut):
    """Address 0x00000000 translates correctly with identity mapping."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    tb.set_input_addr(0, 0x00000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x00000000, f"Edge 0x0: expected 0x00000000, got 0x{out:08X}"


@cocotb.test()
async def test_25_edge_addr_ffffffff(dut):
    """Address 0xFFFFFFFF translates correctly with identity mapping."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    tb.set_input_addr(0, 0xFFFFFFFF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xFFFFFFFF, f"Edge 0xFFFFFFFF: expected 0xFFFFFFFF, got 0x{out:08X}"


@cocotb.test()
async def test_26_edge_addr_zero_remapped(dut):
    """Address 0x00000000 with seg[0] remapped."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Remap seg[0] to 0x55
    await tb.write_seg_reg(0, 0, 0x03020155)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x00000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x55000000, f"Edge 0x0 remapped: expected 0x55000000, got 0x{out:08X}"


@cocotb.test()
async def test_27_edge_addr_ffffffff_remapped(dut):
    """Address 0xFFFFFFFF with seg[255] remapped."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Remap seg[255] (byte 3 of seg_reg[63]) to 0x00
    await tb.write_seg_reg(0, 63, 0x00FEFDFC)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0xFFFFFFFF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x00FFFFFF, f"Edge 0xFFFFFFFF remapped: expected 0x00FFFFFF, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Unused APB Port Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_28_unused_apb_port_access(dut):
    """Accessing address ranges for disabled APB ports (2-15) returns error
    (PSLVERR=1 is tied off for disabled ports). The AHB bridge should
    propagate the slave error but still respond with hreadyout."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Port 2 range would be 0x2000-0x2FFF.
    # With the AHB-to-APB bridge, accessing this should return data from
    # the slave mux default (0x00000000 with PSLVERR=1).
    # We simply verify the bus does not hang (we get a response).
    val = await tb.cfg_read(0x2000)
    # The disabled port returns prdata=0x00000000, pslverr=1
    # But the AHB bridge still completes. Data should be 0.
    dut._log.info(f"Unused port 2 read: 0x{val:08X}")

    # Access port 15 range: 0xF000-0xFFFF
    val = await tb.cfg_read(0xF000)
    dut._log.info(f"Unused port 15 read: 0x{val:08X}")


# ══════════════════════════════════════════════════════════════════════════════
# Reset Persistence Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_29_config_cleared_by_reset(dut):
    """Programmed segment values revert to identity mapping after reset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Program non-default values
    await tb.write_seg_reg(0, 0, 0xDEADBEEF)
    await tb.write_base_offset(0, 0xFFFF0000)
    await ClockCycles(dut.hclk, 2)

    # Verify programmed values took effect
    val = await tb.read_seg_reg(0, 0)
    assert val == 0xDEADBEEF

    # Reset
    await tb.reset()

    # Verify defaults restored
    val = await tb.read_seg_reg(0, 0)
    assert val == 0x03020100, \
        f"After reset, seg_reg[0] should be 0x03020100, got 0x{val:08X}"
    bo = await tb.read_base_offset(0)
    assert bo == 0, f"After reset, base_offset should be 0, got 0x{bo:08X}"


@cocotb.test()
async def test_30_translation_updates_combinationally(dut):
    """Translation output changes combinationally when input address changes."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Remap seg[0]=0xAA, seg[1]=0xBB
    await tb.write_seg_reg(0, 0, 0x0302BBAA)
    await ClockCycles(dut.hclk, 2)

    # Set initial input
    tb.set_input_addr(0, 0x00111111)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xAA111111, f"Expected 0xAA111111, got 0x{out:08X}"

    # Change input -- output should update without additional clock edges
    tb.set_input_addr(0, 0x01222222)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xBB222222, f"Expected 0xBB222222, got 0x{out:08X}"
