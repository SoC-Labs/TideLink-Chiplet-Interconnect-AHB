"""Cocotb testbench for tidelink_ahb_to_reg — AHB slave to register interface.

Uses cocotbext-ahb AHBLiteMaster to drive AHB transactions and verifies
correct register read/write behaviour including byte/halfword/word access.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteMaster

# -- Constants ----------------------------------------------------------------
ADDR_W = 12
CLK_PERIOD_NS = 10


# -- Helpers ------------------------------------------------------------------

async def setup(dut):
    """Start clock and create AHB Lite master driver."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())

    ahb_master = AHBLiteMaster(
        AHBBus.from_entity(dut),
        dut.clk,
        dut.rst_n,
        timeout=200,
    )
    return ahb_master


async def do_reset(dut):
    """Assert active-low reset for 5 cycles, then deassert."""
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


# -- Tests --------------------------------------------------------------------

@cocotb.test()
async def test_01_reset_defaults(dut):
    """Test 1: After reset, register interface outputs are deasserted."""
    ahb_master = await setup(dut)
    await do_reset(dut)
    await RisingEdge(dut.clk)

    assert dut.hready.value == 1, "hready should be high (zero wait-state slave)"
    assert dut.hresp.value == 0, "hresp should be OKAY"
    assert dut.reg_write_en.value == 0, "reg_write_en should be 0 after reset"
    assert dut.reg_read_en.value == 0, "reg_read_en should be 0 after reset"
    assert dut.reg_byte_strobe.value == 0, "reg_byte_strobe should be 0 after reset"


@cocotb.test()
async def test_02_single_word_write_read(dut):
    """Test 2: Write a single word and read it back."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x000
    write_val = 0xDEADBEEF

    await ahb_master.write(addr, write_val)
    resp = await ahb_master.read(addr)
    read_val = int(resp[0]["data"], 16)

    assert read_val == write_val, \
        f"Read mismatch at 0x{addr:03X}: expected 0x{write_val:08X}, got 0x{read_val:08X}"


@cocotb.test()
async def test_03_multiple_addresses(dut):
    """Test 3: Write to multiple addresses and read all back."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    test_data = {
        0x000: 0x11111111,
        0x004: 0x22222222,
        0x008: 0x33333333,
        0x00C: 0x44444444,
    }

    # Write all
    for addr, val in test_data.items():
        await ahb_master.write(addr, val)

    # Read all back
    for addr, expected in test_data.items():
        resp = await ahb_master.read(addr)
        got = int(resp[0]["data"], 16)
        assert got == expected, \
            f"Mismatch at 0x{addr:03X}: expected 0x{expected:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_04_overwrite(dut):
    """Test 4: Overwrite a register and verify only the latest value persists."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x010

    await ahb_master.write(addr, 0xAAAAAAAA)
    await ahb_master.write(addr, 0x55555555)

    resp = await ahb_master.read(addr)
    got = int(resp[0]["data"], 16)
    assert got == 0x55555555, \
        f"Overwrite failed: expected 0x55555555, got 0x{got:08X}"


@cocotb.test()
async def test_05_no_clobber_neighbour(dut):
    """Test 5: Writing to one register must not corrupt adjacent registers."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    await ahb_master.write(0x020, 0xAAAA0000)
    await ahb_master.write(0x024, 0xBBBB0000)

    # Overwrite second register
    await ahb_master.write(0x024, 0xCCCC0000)

    # First register should be untouched
    resp = await ahb_master.read(0x020)
    got = int(resp[0]["data"], 16)
    assert got == 0xAAAA0000, \
        f"Neighbour clobbered: expected 0xAAAA0000, got 0x{got:08X}"

    # Second should have new value
    resp = await ahb_master.read(0x024)
    got = int(resp[0]["data"], 16)
    assert got == 0xCCCC0000, \
        f"Overwrite failed: expected 0xCCCC0000, got 0x{got:08X}"


@cocotb.test()
async def test_06_byte_write(dut):
    """Test 6: Byte-sized writes to individual lanes within a word."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x030

    # Clear the register first
    await ahb_master.write(addr, 0x00000000)

    # Write individual bytes using size=1 (BYTE)
    # Byte 0 at addr+0
    await ahb_master.write(addr + 0, 0x000000AA, size=1)
    # Byte 1 at addr+1
    await ahb_master.write(addr + 1, 0x0000BB00, size=1)
    # Byte 2 at addr+2
    await ahb_master.write(addr + 2, 0x00CC0000, size=1)
    # Byte 3 at addr+3
    await ahb_master.write(addr + 3, 0xDD000000, size=1)

    # Read back the full word
    resp = await ahb_master.read(addr)
    got = int(resp[0]["data"], 16)
    assert got == 0xDDCCBBAA, \
        f"Byte write composite: expected 0xDDCCBBAA, got 0x{got:08X}"


@cocotb.test()
async def test_07_halfword_write(dut):
    """Test 7: Halfword-sized writes to lower and upper halves."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x040

    # Clear register
    await ahb_master.write(addr, 0x00000000)

    # Write lower halfword (addr[1]=0, size=2)
    await ahb_master.write(addr, 0x0000BEEF, size=2)
    # Write upper halfword (addr[1]=1, size=2)
    await ahb_master.write(addr + 2, 0xDEAD0000, size=2)

    resp = await ahb_master.read(addr)
    got = int(resp[0]["data"], 16)
    assert got == 0xDEADBEEF, \
        f"Halfword write composite: expected 0xDEADBEEF, got 0x{got:08X}"


@cocotb.test()
async def test_08_read_does_not_modify(dut):
    """Test 8: Reading a register does not modify its value."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x050
    val = 0xFACECAFE

    await ahb_master.write(addr, val)

    # Read multiple times
    for _ in range(5):
        resp = await ahb_master.read(addr)
        got = int(resp[0]["data"], 16)
        assert got == val, \
            f"Read modified register: expected 0x{val:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_09_batch_write_read(dut):
    """Test 9: Batch write and batch read using address lists."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    num_regs = 16
    addrs = [i * 4 + 0x100 for i in range(num_regs)]
    values = [0x10000000 + i for i in range(num_regs)]

    # Batch write
    await ahb_master.write(addrs, values)

    # Batch read
    responses = await ahb_master.read(addrs)

    for i in range(num_regs):
        got = int(responses[i]["data"], 16)
        assert got == values[i], \
            f"Batch reg[{i}] at 0x{addrs[i]:03X}: expected 0x{values[i]:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_10_pipelined_write_read(dut):
    """Test 10: Pipelined AHB transactions (pip=True)."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addrs = [0x200, 0x204, 0x208, 0x20C]
    values = [0xCAFE0001, 0xCAFE0002, 0xCAFE0003, 0xCAFE0004]

    # Pipelined write
    await ahb_master.write(addrs, values, pip=True)

    # Pipelined read
    responses = await ahb_master.read(addrs, pip=True)

    for i in range(4):
        got = int(responses[i]["data"], 16)
        assert got == values[i], \
            f"Pipelined reg[{i}] at 0x{addrs[i]:03X}: expected 0x{values[i]:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_11_back_to_back_write_then_read(dut):
    """Test 11: Write then immediately read the same address (no idle cycles)."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    for i in range(8):
        addr = 0x300 + i * 4
        val = 0xAB000000 + i
        await ahb_master.write(addr, val)
        resp = await ahb_master.read(addr)
        got = int(resp[0]["data"], 16)
        assert got == val, \
            f"Back-to-back @0x{addr:03X}: expected 0x{val:08X}, got 0x{got:08X}"


@cocotb.test()
async def test_12_full_address_range(dut):
    """Test 12: Write to first and last registers in the address space."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    # First register
    await ahb_master.write(0x000, 0x00000001)
    # Last word-aligned register in 4KB space
    await ahb_master.write(0xFFC, 0xFFFFFFFF)

    resp_first = await ahb_master.read(0x000)
    resp_last = await ahb_master.read(0xFFC)

    got_first = int(resp_first[0]["data"], 16)
    got_last = int(resp_last[0]["data"], 16)

    assert got_first == 0x00000001, \
        f"First reg: expected 0x00000001, got 0x{got_first:08X}"
    assert got_last == 0xFFFFFFFF, \
        f"Last reg: expected 0xFFFFFFFF, got 0x{got_last:08X}"


@cocotb.test()
async def test_13_byte_lane_isolation(dut):
    """Test 13: Verify byte writes only modify their target lane."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x060

    # Fill with known pattern
    await ahb_master.write(addr, 0x12345678)

    # Overwrite only byte 1 (at addr+1)
    await ahb_master.write(addr + 1, 0x0000FF00, size=1)

    resp = await ahb_master.read(addr)
    got = int(resp[0]["data"], 16)
    assert got == 0x1234FF78, \
        f"Byte lane isolation: expected 0x1234FF78, got 0x{got:08X}"


@cocotb.test()
async def test_14_halfword_lane_isolation(dut):
    """Test 14: Verify halfword writes only modify their target lanes."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    addr = 0x070

    # Fill with known pattern
    await ahb_master.write(addr, 0xAABBCCDD)

    # Overwrite upper halfword only (at addr+2)
    await ahb_master.write(addr + 2, 0x11220000, size=2)

    resp = await ahb_master.read(addr)
    got = int(resp[0]["data"], 16)
    assert got == 0x1122CCDD, \
        f"Halfword lane isolation: expected 0x1122CCDD, got 0x{got:08X}"


@cocotb.test()
async def test_15_hready_always_high(dut):
    """Test 15: Verify hready remains high throughout transactions."""
    ahb_master = await setup(dut)
    await do_reset(dut)

    # Perform several transactions and check hready stays high
    for i in range(4):
        await ahb_master.write(0x080 + i * 4, i)
        await RisingEdge(dut.clk)
        assert dut.hready.value == 1, \
            f"hready dropped during transaction {i}"

    for i in range(4):
        await ahb_master.read(0x080 + i * 4)
        await RisingEdge(dut.clk)
        assert dut.hready.value == 1, \
            f"hready dropped during read {i}"
