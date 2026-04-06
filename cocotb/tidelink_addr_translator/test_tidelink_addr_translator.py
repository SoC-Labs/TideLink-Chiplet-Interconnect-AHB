"""Cocotb testbench for tidelink_addr_translator (CAM-based).

Exercises APB-configurable CAM rule-based address remapping via the APB
config slave, verifying rule programming, priority, global enable,
base offset, identity passthrough, and edge cases.

Register map per channel (tl_addr_trans_regs):
  0x000: BASE_OFFSET  (RW, reset=0)
  0x004: CTRL         ([0] global_enable, RW, reset=0)
  0x010: RULE_0       {[23:16] replace, [15:8] match, [0] enable}
  0x014: RULE_1
  ...
  0x02C: RULE_7
  0xFD0-0xFFC: PID/CID (RO)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles


# ── Minimal APB Master Driver ───────────────────────────────────────────────

class APBMaster:
    """Minimal APB master driver for register access."""

    def __init__(self, dut, clk, prefix="apbc"):
        self._clk     = clk
        self._psel    = getattr(dut, f"{prefix}_psel")
        self._penable = getattr(dut, f"{prefix}_penable")
        self._pwrite  = getattr(dut, f"{prefix}_pwrite")
        self._paddr   = getattr(dut, f"{prefix}_paddr")
        self._pwdata  = getattr(dut, f"{prefix}_pwdata")
        self._pstrb   = getattr(dut, f"{prefix}_pstrb")
        self._prdata  = getattr(dut, f"{prefix}_prdata")
        self._pready  = getattr(dut, f"{prefix}_pready")

    def idle(self):
        self._psel.value    = 0
        self._penable.value = 0
        self._pwrite.value  = 0
        self._paddr.value   = 0
        self._pwdata.value  = 0
        self._pstrb.value   = 0

    async def write(self, addr, data):
        self._psel.value    = 1
        self._penable.value = 0
        self._pwrite.value  = 1
        self._paddr.value   = addr
        self._pwdata.value  = data
        self._pstrb.value   = 0xF
        await RisingEdge(self._clk)
        self._penable.value = 1
        await RisingEdge(self._clk)
        while not int(self._pready.value):
            await RisingEdge(self._clk)
        self.idle()

    async def read(self, addr):
        self._psel.value    = 1
        self._penable.value = 0
        self._pwrite.value  = 0
        self._paddr.value   = addr
        self._pwdata.value  = 0
        await RisingEdge(self._clk)
        self._penable.value = 1
        await FallingEdge(self._clk)
        while not int(self._pready.value):
            await RisingEdge(self._clk)
            await FallingEdge(self._clk)
        data = int(self._prdata.value)
        await RisingEdge(self._clk)
        self.idle()
        return data

# ── Constants ────────────────────────────────────────────────────────────────

CLK_PERIOD_NS = 10
NUM_RULES = 8

# APB slave mux address decode: paddr[15:12]
#   Channel 0 registers: 0x0000 - 0x0FFF
#   Channel 1 registers: 0x1000 - 0x1FFF
CH0_BASE = 0x0000
CH1_BASE = 0x1000

# Register offsets within each channel (tl_addr_trans_regs)
REG_BASE_OFFSET = 0x000
REG_CTRL        = 0x004
REG_RULE_BASE   = 0x010  # RULE_0 at 0x010, RULE_1 at 0x014, etc.

# PID/CID offsets
REG_PIDR0 = 0xFE0
REG_PIDR1 = 0xFE4
REG_CIDR0 = 0xFF0


def rule_offset(rule_idx):
    """Return the byte offset for RULE_N within a channel."""
    return REG_RULE_BASE + rule_idx * 4


def pack_rule(enable, match_byte, replace_byte):
    """Pack a rule register value from its fields."""
    return ((replace_byte & 0xFF) << 16) | ((match_byte & 0xFF) << 8) | (enable & 1)


# ── Testbench Environment ────────────────────────────────────────────────────

class AddrTranslatorTB:
    """Reusable testbench wrapper for tidelink_addr_translator (CAM-based)."""

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

        cocotb.start_soon(
            Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start()
        )

        self.apb_cfg = APBMaster(dut, dut.hclk, prefix="apbc")

    async def reset(self):
        self.dut.hresetn.value = 0
        self.dut.chp0_ahb_haddr_i.value = 0
        self.dut.chp1_ahb_haddr_i.value = 0
        self.apb_cfg.idle()
        await ClockCycles(self.dut.hclk, 5)
        self.dut.hresetn.value = 1
        await ClockCycles(self.dut.hclk, 5)

    async def cfg_read(self, offset):
        """Read a 32-bit config register via the APB config slave."""
        return await self.apb_cfg.read(offset)

    async def cfg_write(self, offset, data):
        """Write a 32-bit config register via the APB config slave."""
        await self.apb_cfg.write(offset, data)

    async def write_base_offset(self, channel, value):
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        await self.cfg_write(ch_base + REG_BASE_OFFSET, value)

    async def read_base_offset(self, channel):
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        return await self.cfg_read(ch_base + REG_BASE_OFFSET)

    async def write_ctrl(self, channel, enable):
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        await self.cfg_write(ch_base + REG_CTRL, enable & 1)

    async def read_ctrl(self, channel):
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        return await self.cfg_read(ch_base + REG_CTRL)

    async def write_rule(self, channel, rule_idx, enable, match_byte, replace_byte):
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        val = pack_rule(enable, match_byte, replace_byte)
        await self.cfg_write(ch_base + rule_offset(rule_idx), val)

    async def read_rule(self, channel, rule_idx):
        ch_base = CH0_BASE if channel == 0 else CH1_BASE
        return await self.cfg_read(ch_base + rule_offset(rule_idx))

    def get_translated_addr(self, channel):
        if channel == 0:
            return int(self.dut.chp0_ahb_haddr_o.value)
        else:
            return int(self.dut.chp1_ahb_haddr_o.value)

    def set_input_addr(self, channel, addr):
        if channel == 0:
            self.dut.chp0_ahb_haddr_i.value = addr
        else:
            self.dut.chp1_ahb_haddr_i.value = addr


# ══════════════════════════════════════════════════════════════════════════════
# Reset Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_01_reset_defaults(dut):
    """After reset, all registers are at default values (0)."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    bo = await tb.read_base_offset(0)
    assert bo == 0, f"CH0 base_offset: expected 0, got 0x{bo:08X}"

    ctrl = await tb.read_ctrl(0)
    assert ctrl == 0, f"CH0 ctrl: expected 0, got 0x{ctrl:08X}"

    for i in range(NUM_RULES):
        rule = await tb.read_rule(0, i)
        assert rule == 0, f"CH0 rule[{i}]: expected 0, got 0x{rule:08X}"


@cocotb.test()
async def test_02_reset_identity_passthrough(dut):
    """After reset (global_enable=0), all addresses pass through unchanged."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    test_addrs = [0x00000000, 0x01ABCDEF, 0x80123456, 0xFF000000, 0xFFFFFFFF]
    for addr in test_addrs:
        tb.set_input_addr(0, addr)
        await ClockCycles(dut.hclk, 1)
        out = tb.get_translated_addr(0)
        assert out == addr, f"Identity: input 0x{addr:08X}, got 0x{out:08X}"


@cocotb.test()
async def test_03_reset_ch1_passthrough(dut):
    """Channel 1 also passes through after reset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    tb.set_input_addr(1, 0xABCDEF12)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(1)
    assert out == 0xABCDEF12, f"CH1 identity: expected 0xABCDEF12, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Register Read/Write Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_04_base_offset_rw(dut):
    """Base offset register is read-write."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(0, 0xABCD0000)
    val = await tb.read_base_offset(0)
    assert val == 0xABCD0000, f"base_offset: expected 0xABCD0000, got 0x{val:08X}"


@cocotb.test()
async def test_05_ctrl_rw(dut):
    """CTRL register enable bit is read-write."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    val = await tb.read_ctrl(0)
    assert val == 1, f"ctrl: expected 1, got 0x{val:08X}"

    await tb.write_ctrl(0, 0)
    val = await tb.read_ctrl(0)
    assert val == 0, f"ctrl: expected 0, got 0x{val:08X}"


@cocotb.test()
async def test_06_rule_rw(dut):
    """Rule registers are read-write with correct field packing."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Write RULE_0: enable=1, match=0x60, replace=0xA0
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xA0)
    val = await tb.read_rule(0, 0)
    expected = pack_rule(1, 0x60, 0xA0)
    assert val == expected, f"rule[0]: expected 0x{expected:08X}, got 0x{val:08X}"


@cocotb.test()
async def test_07_all_rules_writable(dut):
    """All 8 rule registers accept writes and read back correctly."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    for i in range(NUM_RULES):
        await tb.write_rule(0, i, enable=1, match_byte=i*16, replace_byte=0xF0+i)

    for i in range(NUM_RULES):
        val = await tb.read_rule(0, i)
        expected = pack_rule(1, i*16, 0xF0+i)
        assert val == expected, f"rule[{i}]: expected 0x{expected:08X}, got 0x{val:08X}"


@cocotb.test()
async def test_08_pidr_readback(dut):
    """PID registers are readable with correct values."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    pidr0 = await tb.cfg_read(CH0_BASE + REG_PIDR0)
    assert pidr0 == 0x59, f"PIDR0: expected 0x59, got 0x{pidr0:02X}"

    cidr0 = await tb.cfg_read(CH0_BASE + REG_CIDR0)
    assert cidr0 == 0x50, f"CIDR0: expected 0x50, got 0x{cidr0:02X}"


# ══════════════════════════════════════════════════════════════════════════════
# Single Rule Translation Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_09_single_rule_match(dut):
    """A single enabled rule remaps the matching upper byte."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Enable translation, program rule: match 0x60 -> replace 0xA0
    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xA0)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x60ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xA0ABCDEF, f"Expected 0xA0ABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_10_single_rule_no_match(dut):
    """An address that doesn't match any rule passes through unchanged."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xA0)
    await ClockCycles(dut.hclk, 2)

    # Input 0x50... doesn't match rule (match=0x60)
    tb.set_input_addr(0, 0x50ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    # No match -> identity passthrough of normalised upper byte
    assert out == 0x50ABCDEF, f"Expected 0x50ABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_11_lower_bits_passthrough(dut):
    """Lower 24 bits always pass through from addr_i regardless of rules."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0xAB, replace_byte=0xCD)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0xAB123456)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert (out & 0x00FFFFFF) == 0x00123456, \
        f"Lower 24 bits: expected 0x123456, got 0x{out & 0x00FFFFFF:06X}"
    assert (out >> 24) == 0xCD, f"Upper byte: expected 0xCD, got 0x{out >> 24:02X}"


# ══════════════════════════════════════════════════════════════════════════════
# Multi-Rule and Priority Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_12_multiple_rules(dut):
    """Multiple rules each remap their respective matching addresses."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x00, replace_byte=0xAA)
    await tb.write_rule(0, 1, enable=1, match_byte=0x01, replace_byte=0xBB)
    await tb.write_rule(0, 2, enable=1, match_byte=0xFF, replace_byte=0x10)
    await ClockCycles(dut.hclk, 2)

    cases = [
        (0x00123456, 0xAA123456),
        (0x01FFFFFF, 0xBBFFFFFF),
        (0xFF000000, 0x10000000),
        (0x50000000, 0x50000000),  # no match -> passthrough
    ]
    for inp, expected in cases:
        tb.set_input_addr(0, inp)
        await ClockCycles(dut.hclk, 1)
        out = tb.get_translated_addr(0)
        assert out == expected, \
            f"Input 0x{inp:08X}: expected 0x{expected:08X}, got 0x{out:08X}"


@cocotb.test()
async def test_13_rule_priority(dut):
    """Lowest-index rule wins when multiple rules match the same byte."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    # Both rules match 0x42, but rule 0 should win
    await tb.write_rule(0, 0, enable=1, match_byte=0x42, replace_byte=0xAA)
    await tb.write_rule(0, 1, enable=1, match_byte=0x42, replace_byte=0xBB)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x42000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert (out >> 24) == 0xAA, \
        f"Priority: expected upper byte 0xAA (rule 0 wins), got 0x{out >> 24:02X}"


@cocotb.test()
async def test_14_disabled_rule_ignored(dut):
    """A rule with enable=0 is not evaluated even if match_byte matches."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    # Rule 0: disabled, matches 0x60
    await tb.write_rule(0, 0, enable=0, match_byte=0x60, replace_byte=0xAA)
    # Rule 1: enabled, matches 0x60
    await tb.write_rule(0, 1, enable=1, match_byte=0x60, replace_byte=0xBB)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x60000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert (out >> 24) == 0xBB, \
        f"Disabled rule skip: expected 0xBB (rule 1), got 0x{out >> 24:02X}"


# ══════════════════════════════════════════════════════════════════════════════
# Global Enable Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_15_global_enable_off_passthrough(dut):
    """With global_enable=0, all addresses pass through even with active rules."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Program a rule but keep global_enable=0
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x60ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x60ABCDEF, f"Global disable: expected 0x60ABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_16_global_enable_toggle(dut):
    """Toggling global_enable activates/deactivates translation."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)
    tb.set_input_addr(0, 0x60000000)

    # Enable -> rule active
    await tb.write_ctrl(0, 1)
    await ClockCycles(dut.hclk, 2)
    out = tb.get_translated_addr(0)
    assert (out >> 24) == 0xAA, f"Enabled: expected 0xAA, got 0x{out >> 24:02X}"

    # Disable -> passthrough
    await tb.write_ctrl(0, 0)
    await ClockCycles(dut.hclk, 2)
    out = tb.get_translated_addr(0)
    assert (out >> 24) == 0x60, f"Disabled: expected 0x60, got 0x{out >> 24:02X}"


# ══════════════════════════════════════════════════════════════════════════════
# Base Offset Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_17_base_offset_shifts_match(dut):
    """Base offset shifts which upper byte the rules see.

    base_offset=0x10000000, addr_i=0x70ABCDEF
    addr_norm = 0x60ABCDEF -> upper byte = 0x60
    Rule matching 0x60 should fire.
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0x10000000)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x70ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xAAABCDEF, f"Base offset+rule: expected 0xAAABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_18_base_offset_wrap(dut):
    """Base offset wrapping via unsigned subtraction.

    base_offset=0xFF000000, addr_i=0x01000000
    addr_norm = 0x01000000 - 0xFF000000 = 0x02000000 (unsigned wrap)
    upper byte of norm = 0x02
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0xFF000000)
    await tb.write_rule(0, 0, enable=1, match_byte=0x02, replace_byte=0xDD)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x01000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xDD000000, f"Offset wrap: expected 0xDD000000, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Channel Independence Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_19_channels_independent(dut):
    """Channel 0 and channel 1 rules are independent."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # CH0: enable, rule 0x60->0xAA
    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)

    # CH1: enable, rule 0x60->0xBB (different replace)
    await tb.write_ctrl(1, 1)
    await tb.write_rule(1, 0, enable=1, match_byte=0x60, replace_byte=0xBB)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x60000000)
    tb.set_input_addr(1, 0x60000000)
    await ClockCycles(dut.hclk, 1)

    out0 = tb.get_translated_addr(0)
    out1 = tb.get_translated_addr(1)
    assert (out0 >> 24) == 0xAA, f"CH0: expected 0xAA, got 0x{out0 >> 24:02X}"
    assert (out1 >> 24) == 0xBB, f"CH1: expected 0xBB, got 0x{out1 >> 24:02X}"


@cocotb.test()
async def test_20_ch1_unaffected_by_ch0(dut):
    """Remapping CH0 does not affect CH1."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x00, replace_byte=0xFF)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x00123456)
    tb.set_input_addr(1, 0x00123456)
    await ClockCycles(dut.hclk, 1)

    out0 = tb.get_translated_addr(0)
    out1 = tb.get_translated_addr(1)
    assert out0 == 0xFF123456, f"CH0: expected 0xFF123456, got 0x{out0:08X}"
    # CH1 has global_enable=0 -> passthrough
    assert out1 == 0x00123456, f"CH1: expected 0x00123456, got 0x{out1:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Edge Case Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_21_edge_addr_zero(dut):
    """Address 0x00000000 passes through with global_enable=0."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    tb.set_input_addr(0, 0x00000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x00000000, f"Edge 0x0: got 0x{out:08X}"


@cocotb.test()
async def test_22_edge_addr_ffffffff(dut):
    """Address 0xFFFFFFFF passes through with global_enable=0."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    tb.set_input_addr(0, 0xFFFFFFFF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xFFFFFFFF, f"Edge 0xFFFFFFFF: got 0x{out:08X}"


@cocotb.test()
async def test_23_all_rules_active(dut):
    """All 8 rules can be active simultaneously and each matches correctly."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    for i in range(NUM_RULES):
        await tb.write_rule(0, i, enable=1, match_byte=i*0x20, replace_byte=0xA0+i)
    await ClockCycles(dut.hclk, 2)

    for i in range(NUM_RULES):
        tb.set_input_addr(0, (i * 0x20) << 24 | 0x00CAFE00)
        await ClockCycles(dut.hclk, 1)
        out = tb.get_translated_addr(0)
        expected_upper = 0xA0 + i
        assert (out >> 24) == expected_upper, \
            f"Rule {i}: expected upper 0x{expected_upper:02X}, got 0x{out >> 24:02X}"
        assert (out & 0x00FFFFFF) == 0x00CAFE00, \
            f"Rule {i}: lower bits corrupted: 0x{out & 0x00FFFFFF:06X}"


# ══════════════════════════════════════════════════════════════════════════════
# Rapid Reconfiguration Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_24_rapid_reconfig(dut):
    """Reprogram a rule between translations, verify both results correct."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x60000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert (out >> 24) == 0xAA, f"Before reconfig: expected 0xAA, got 0x{out >> 24:02X}"

    # Reprogram same rule with different replace
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xBB)
    await ClockCycles(dut.hclk, 2)

    out = tb.get_translated_addr(0)
    assert (out >> 24) == 0xBB, f"After reconfig: expected 0xBB, got 0x{out >> 24:02X}"


@cocotb.test()
async def test_25_combinational_update(dut):
    """Translation output changes combinationally when input changes."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_rule(0, 0, enable=1, match_byte=0x00, replace_byte=0xAA)
    await tb.write_rule(0, 1, enable=1, match_byte=0x01, replace_byte=0xBB)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x00111111)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xAA111111, f"First: expected 0xAA111111, got 0x{out:08X}"

    tb.set_input_addr(0, 0x01222222)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0xBB222222, f"Second: expected 0xBB222222, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Reset Persistence Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_26_config_cleared_by_reset(dut):
    """Programmed rules and ctrl revert to defaults after reset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0xFFFF0000)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)
    await ClockCycles(dut.hclk, 2)

    # Verify programmed
    ctrl = await tb.read_ctrl(0)
    assert ctrl == 1

    # Reset
    await tb.reset()

    # Verify defaults restored
    ctrl = await tb.read_ctrl(0)
    assert ctrl == 0, f"After reset, ctrl should be 0, got {ctrl}"
    bo = await tb.read_base_offset(0)
    assert bo == 0, f"After reset, base_offset should be 0, got 0x{bo:08X}"
    rule = await tb.read_rule(0, 0)
    assert rule == 0, f"After reset, rule[0] should be 0, got 0x{rule:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Unused APB Port Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_27_unused_apb_port_access(dut):
    """Accessing disabled APB ports (2-15) does not hang the bus."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    val = await tb.cfg_read(0x2000)
    dut._log.info(f"Unused port 2 read: 0x{val:08X}")

    val = await tb.cfg_read(0xF000)
    dut._log.info(f"Unused port 15 read: 0x{val:08X}")


# ══════════════════════════════════════════════════════════════════════════════
# Default Read Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_28_unmapped_register_read(dut):
    """Reading unmapped offsets within a channel returns 0xCAFECAFE."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    # Offset 0x040 is beyond the rule registers but before PID/CID
    val = await tb.cfg_read(CH0_BASE + 0x040)
    assert val == 0xCAFECAFE, f"Unmapped read: expected 0xCAFECAFE, got 0x{val:08X}"


@cocotb.test()
async def test_29_base_offset_independent_per_channel(dut):
    """Each channel has its own base offset."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_base_offset(0, 0x20000000)
    await tb.write_base_offset(1, 0x80000000)

    bo0 = await tb.read_base_offset(0)
    bo1 = await tb.read_base_offset(1)
    assert bo0 == 0x20000000, f"CH0: expected 0x20000000, got 0x{bo0:08X}"
    assert bo1 == 0x80000000, f"CH1: expected 0x80000000, got 0x{bo1:08X}"


@cocotb.test()
async def test_30_no_match_identity_with_base_offset(dut):
    """When no rule matches, the normalised upper byte passes through.

    base_offset=0x10000000, addr_i=0x60ABCDEF
    addr_norm = 0x50ABCDEF -> upper byte = 0x50
    No rule for 0x50 -> output upper byte = 0x50
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0x10000000)
    await tb.write_rule(0, 0, enable=1, match_byte=0x60, replace_byte=0xAA)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0x60ABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    # addr_norm upper = 0x50, no match -> passthrough 0x50
    assert out == 0x50ABCDEF, f"No match passthrough: expected 0x50ABCDEF, got 0x{out:08X}"


# ══════════════════════════════════════════════════════════════════════════════
# Opt 2: Parallel Priority Encoder Verification
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_31_priority_lowest_index_wins(dut):
    """When multiple rules match, the lowest-index rule wins (Opt 2 verification).

    Configure rules 0, 3, 7 all matching 0xAA, with different replace values.
    Lowest index (0) must win.
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)  # global enable
    await tb.write_base_offset(0, 0)

    # Rules 0, 3, 7 all match 0xAA but replace with different values
    await tb.write_rule(0, 0, enable=1, match_byte=0xAA, replace_byte=0x11)
    await tb.write_rule(0, 3, enable=1, match_byte=0xAA, replace_byte=0x33)
    await tb.write_rule(0, 7, enable=1, match_byte=0xAA, replace_byte=0x77)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0xAA123456)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x11123456, f"Lowest-index rule 0 should win: expected 0x11123456, got 0x{out:08X}"


@cocotb.test()
async def test_32_priority_skips_disabled_lower_index(dut):
    """If a lower-index rule is disabled, the next matching rule wins.

    Rule 0: disabled, matches 0xBB
    Rule 1: enabled, matches 0xBB, replace 0x22
    Rule 5: enabled, matches 0xBB, replace 0x55
    Rule 1 should win.
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0)

    await tb.write_rule(0, 0, enable=0, match_byte=0xBB, replace_byte=0x00)
    await tb.write_rule(0, 1, enable=1, match_byte=0xBB, replace_byte=0x22)
    await tb.write_rule(0, 5, enable=1, match_byte=0xBB, replace_byte=0x55)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0xBB000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x22000000, f"Rule 1 should win (rule 0 disabled): expected 0x22000000, got 0x{out:08X}"


@cocotb.test()
async def test_33_priority_last_rule_only(dut):
    """Only the highest-index rule matches — verifies it is still selected.

    Rule 7: enabled, matches 0xCC, replace 0x77
    All others: disabled or different match.
    """
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0)

    # Only rule 7 matches
    for i in range(7):
        await tb.write_rule(0, i, enable=1, match_byte=0xDD, replace_byte=0x00)
    await tb.write_rule(0, 7, enable=1, match_byte=0xCC, replace_byte=0x77)
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0xCCABCDEF)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x77ABCDEF, f"Rule 7 only match: expected 0x77ABCDEF, got 0x{out:08X}"


@cocotb.test()
async def test_34_all_rules_match_same_addr(dut):
    """All 8 rules match the same address — rule 0 must win."""
    tb = AddrTranslatorTB(dut)
    await tb.reset()

    await tb.write_ctrl(0, 1)
    await tb.write_base_offset(0, 0)

    for i in range(NUM_RULES):
        await tb.write_rule(0, i, enable=1, match_byte=0xEE, replace_byte=(0x10 + i))
    await ClockCycles(dut.hclk, 2)

    tb.set_input_addr(0, 0xEE000000)
    await ClockCycles(dut.hclk, 1)
    out = tb.get_translated_addr(0)
    assert out == 0x10000000, f"All rules match: rule 0 (replace=0x10) should win, got 0x{out:08X}"
