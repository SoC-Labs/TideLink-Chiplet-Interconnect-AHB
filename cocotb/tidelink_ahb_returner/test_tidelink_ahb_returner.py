"""Cocotb testbench for tidelink_ahb_returner.

Uses cocotbext-ahb AHBLiteSlaveRAM to respond to AHB master transactions
and verifies that the DUT performs a single-beat write on interrupt.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.ahb import AHBBus, AHBLiteSlaveRAM

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10
MEM_SIZE      = 0x10000  # 64 KiB slave memory


# ── Helper Functions ─────────────────────────────────────────────────────────

async def setup(dut):
    """Start clock and create AHB slave RAM."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    ahb_slave = AHBLiteSlaveRAM(
        AHBBus.from_entity(dut),
        dut.hclk,
        dut.hresetn,
        mem_size=MEM_SIZE,
    )
    return ahb_slave


async def do_reset(dut):
    """Assert active-low reset for 5 cycles, then deassert."""
    dut.hresetn.value = 0
    dut.interrupt.value = 0
    dut.write_addr.value = 0
    dut.write_data.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def wait_not_busy(dut, timeout_cycles=50):
    """Wait until the DUT de-asserts busy."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.hclk)
        if dut.busy.value == 0:
            return
    raise TimeoutError("DUT still busy after timeout")


def read_slave_word(slave, byte_addr):
    """Read a 32-bit word from the slave RAM at the given byte address."""
    raw = slave.memory.read(byte_addr, 4)
    return int.from_bytes(raw, byteorder="little")


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset_defaults(dut):
    """After reset, bus should be idle and busy should be low."""
    await setup(dut)
    await do_reset(dut)

    assert dut.busy.value == 0, "busy should be 0 after reset"
    assert dut.u_dut.htrans.value == 0, "htrans should be IDLE after reset"


@cocotb.test()
async def test_02_single_write_on_interrupt(dut):
    """Pulsing interrupt should produce a single-beat AHB write."""
    slave = await setup(dut)
    await do_reset(dut)

    test_addr = 0x0000_1000
    test_data = 0xDEAD_BEEF

    dut.write_addr.value = test_addr
    dut.write_data.value = test_data

    # Pulse interrupt for one cycle
    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    # Wait for the transfer to complete
    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    # Verify the slave RAM captured the write
    actual = read_slave_word(slave, test_addr)
    assert actual == test_data, \
        f"Expected 0x{test_data:08X} at 0x{test_addr:08X}, got 0x{actual:08X}"


@cocotb.test()
async def test_03_busy_during_transfer(dut):
    """Busy should be asserted during the AHB transfer."""
    await setup(dut)
    await do_reset(dut)

    dut.write_addr.value = 0x0000_2000
    dut.write_data.value = 0x1234_5678

    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    # On the next rising edge, DUT should be busy (address phase)
    await RisingEdge(dut.hclk)
    assert dut.busy.value == 1, "busy should be high during transfer"

    await wait_not_busy(dut)
    assert dut.busy.value == 0, "busy should be low after transfer completes"


@cocotb.test()
async def test_04_no_transfer_without_interrupt(dut):
    """Without an interrupt, no AHB transfer should occur."""
    slave = await setup(dut)
    await do_reset(dut)

    test_addr = 0x0000_3000
    dut.write_addr.value = test_addr
    dut.write_data.value = 0xAAAA_BBBB

    # Wait several cycles without asserting interrupt
    await ClockCycles(dut.hclk, 10)

    assert dut.busy.value == 0, "busy should remain low without interrupt"
    # Slave memory should still be zero at the target address
    actual = read_slave_word(slave, test_addr)
    assert actual == 0, f"No write expected, but got 0x{actual:08X}"


@cocotb.test()
async def test_05_interrupt_ignored_while_busy(dut):
    """A second interrupt during an active transfer should be ignored."""
    slave = await setup(dut)
    await do_reset(dut)

    dut.write_addr.value = 0x0000_4000
    dut.write_data.value = 0x1111_2222

    # First interrupt
    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    # While busy, change data and pulse interrupt again
    await RisingEdge(dut.hclk)
    dut.write_addr.value = 0x0000_5000
    dut.write_data.value = 0x3333_4444
    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    # Should have written the first set of parameters
    actual = read_slave_word(slave, 0x0000_4000)
    assert actual == 0x1111_2222, \
        f"Expected first interrupt data, got 0x{actual:08X}"

    # Second address should not have been written
    actual2 = read_slave_word(slave, 0x0000_5000)
    assert actual2 == 0, \
        f"Second interrupt should be ignored, but got 0x{actual2:08X}"


@cocotb.test()
async def test_06_back_to_back_transfers(dut):
    """Two consecutive interrupt pulses should produce two separate writes."""
    slave = await setup(dut)
    await do_reset(dut)

    # First transfer
    dut.write_addr.value = 0x0000_A000
    dut.write_data.value = 0xAAAA_0001

    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual1 = read_slave_word(slave, 0x0000_A000)
    assert actual1 == 0xAAAA_0001, f"First write mismatch: 0x{actual1:08X}"

    # Second transfer with different parameters
    dut.write_addr.value = 0x0000_B000
    dut.write_data.value = 0xBBBB_0002

    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual2 = read_slave_word(slave, 0x0000_B000)
    assert actual2 == 0xBBBB_0002, f"Second write mismatch: 0x{actual2:08X}"


@cocotb.test()
async def test_07_htrans_sequence(dut):
    """Verify htrans goes IDLE -> NONSEQ -> IDLE during transfer."""
    await setup(dut)
    await do_reset(dut)

    dut.write_addr.value = 0x0000_6000
    dut.write_data.value = 0xCAFE_BABE

    # Before interrupt, htrans should be IDLE
    assert dut.u_dut.htrans.value == 0, "htrans should be IDLE before interrupt"

    dut.interrupt.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt.value = 0

    # Address phase: htrans should be NONSEQ (0b10 = 2)
    await RisingEdge(dut.hclk)
    assert dut.u_dut.htrans.value == 2, \
        f"htrans should be NONSEQ (2), got {dut.u_dut.htrans.value.integer}"

    # Data phase: htrans should return to IDLE
    await RisingEdge(dut.hclk)
    assert dut.u_dut.htrans.value == 0, \
        f"htrans should be IDLE (0) in data phase, got {dut.u_dut.htrans.value.integer}"
