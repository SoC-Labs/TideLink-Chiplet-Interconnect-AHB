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
    dut.interrupt_0.value = 0
    dut.write_addr_0.value = 0
    dut.write_data_0.value = 0
    dut.interrupt_1.value = 0
    dut.write_addr_1.value = 0
    dut.write_data_1.value = 0
    dut.interrupt_2.value = 0
    dut.write_addr_2.value = 0
    dut.write_data_2.value = 0
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

    dut.write_addr_0.value = test_addr
    dut.write_data_0.value = test_data

    # Pulse interrupt for one cycle
    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

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

    dut.write_addr_0.value = 0x0000_2000
    dut.write_data_0.value = 0x1234_5678

    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

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
    dut.write_addr_0.value = test_addr
    dut.write_data_0.value = 0xAAAA_BBBB

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

    dut.write_addr_0.value = 0x0000_4000
    dut.write_data_0.value = 0x1111_2222

    # First interrupt
    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

    # While busy, change data and pulse interrupt again
    await RisingEdge(dut.hclk)
    dut.write_addr_0.value = 0x0000_5000
    dut.write_data_0.value = 0x3333_4444
    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

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
    dut.write_addr_0.value = 0x0000_A000
    dut.write_data_0.value = 0xAAAA_0001

    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual1 = read_slave_word(slave, 0x0000_A000)
    assert actual1 == 0xAAAA_0001, f"First write mismatch: 0x{actual1:08X}"

    # Second transfer with different parameters
    dut.write_addr_0.value = 0x0000_B000
    dut.write_data_0.value = 0xBBBB_0002

    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual2 = read_slave_word(slave, 0x0000_B000)
    assert actual2 == 0xBBBB_0002, f"Second write mismatch: 0x{actual2:08X}"


@cocotb.test()
async def test_07_htrans_sequence(dut):
    """Verify htrans goes IDLE -> NONSEQ -> IDLE during transfer."""
    await setup(dut)
    await do_reset(dut)

    dut.write_addr_0.value = 0x0000_6000
    dut.write_data_0.value = 0xCAFE_BABE

    # Before interrupt, htrans should be IDLE
    assert dut.u_dut.htrans.value == 0, "htrans should be IDLE before interrupt"

    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

    # Address phase: htrans should be NONSEQ (0b10 = 2)
    await RisingEdge(dut.hclk)
    assert dut.u_dut.htrans.value == 2, \
        f"htrans should be NONSEQ (2), got {dut.u_dut.htrans.value.integer}"

    # Data phase: htrans should return to IDLE
    await RisingEdge(dut.hclk)
    assert dut.u_dut.htrans.value == 0, \
        f"htrans should be IDLE (0) in data phase, got {dut.u_dut.htrans.value.integer}"


# ── Priority and Coverage Tests ──────────────────────────────────────────────


@cocotb.test()
async def test_08_priority_channel_0_over_1(dut):
    """Channel 0 has highest priority — when both are pending, 0 is serviced first."""
    slave = await setup(dut)
    await do_reset(dut)

    addr_0, data_0 = 0x0000_1000, 0xAAAA_0000
    addr_1, data_1 = 0x0000_2000, 0xBBBB_1111

    dut.write_addr_0.value = addr_0
    dut.write_data_0.value = data_0
    dut.write_addr_1.value = addr_1
    dut.write_data_1.value = data_1

    # Pulse both interrupts simultaneously
    dut.interrupt_0.value = 1
    dut.interrupt_1.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0
    dut.interrupt_1.value = 0

    # Wait for first transfer (should be channel 0)
    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_0 = read_slave_word(slave, addr_0)
    assert actual_0 == data_0, \
        f"Channel 0 should be serviced first: expected 0x{data_0:08X}, got 0x{actual_0:08X}"

    # Wait for second transfer (should be channel 1)
    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_1 = read_slave_word(slave, addr_1)
    assert actual_1 == data_1, \
        f"Channel 1 should be serviced second: expected 0x{data_1:08X}, got 0x{actual_1:08X}"


@cocotb.test()
async def test_09_priority_channel_0_over_2(dut):
    """Channel 0 has highest priority over channel 2."""
    slave = await setup(dut)
    await do_reset(dut)

    addr_0, data_0 = 0x0000_3000, 0xCCCC_0000
    addr_2, data_2 = 0x0000_4000, 0xDDDD_2222

    dut.write_addr_0.value = addr_0
    dut.write_data_0.value = data_0
    dut.write_addr_2.value = addr_2
    dut.write_data_2.value = data_2

    dut.interrupt_0.value = 1
    dut.interrupt_2.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0
    dut.interrupt_2.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_0 = read_slave_word(slave, addr_0)
    assert actual_0 == data_0, \
        f"Channel 0 first: expected 0x{data_0:08X}, got 0x{actual_0:08X}"

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_2 = read_slave_word(slave, addr_2)
    assert actual_2 == data_2, \
        f"Channel 2 second: expected 0x{data_2:08X}, got 0x{actual_2:08X}"


@cocotb.test()
async def test_10_priority_channel_1_over_2(dut):
    """Channel 1 has higher priority than channel 2."""
    slave = await setup(dut)
    await do_reset(dut)

    addr_1, data_1 = 0x0000_5000, 0xEEEE_1111
    addr_2, data_2 = 0x0000_6000, 0xFFFF_2222

    dut.write_addr_1.value = addr_1
    dut.write_data_1.value = data_1
    dut.write_addr_2.value = addr_2
    dut.write_data_2.value = data_2

    dut.interrupt_1.value = 1
    dut.interrupt_2.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_1.value = 0
    dut.interrupt_2.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_1 = read_slave_word(slave, addr_1)
    assert actual_1 == data_1, \
        f"Channel 1 first: expected 0x{data_1:08X}, got 0x{actual_1:08X}"

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_2 = read_slave_word(slave, addr_2)
    assert actual_2 == data_2, \
        f"Channel 2 second: expected 0x{data_2:08X}, got 0x{actual_2:08X}"


@cocotb.test()
async def test_11_all_three_channels_pending(dut):
    """All three channels pending simultaneously — service order 0, 1, 2."""
    slave = await setup(dut)
    await do_reset(dut)

    addrs = [0x0000_7000, 0x0000_8000, 0x0000_9000]
    datas = [0x1111_0000, 0x2222_1111, 0x3333_2222]

    dut.write_addr_0.value = addrs[0]
    dut.write_data_0.value = datas[0]
    dut.write_addr_1.value = addrs[1]
    dut.write_data_1.value = datas[1]
    dut.write_addr_2.value = addrs[2]
    dut.write_data_2.value = datas[2]

    # Pulse all three simultaneously
    dut.interrupt_0.value = 1
    dut.interrupt_1.value = 1
    dut.interrupt_2.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0
    dut.interrupt_1.value = 0
    dut.interrupt_2.value = 0

    # Wait for all three transfers to complete
    for ch in range(3):
        await wait_not_busy(dut)
        await ClockCycles(dut.hclk, 2)

    # Verify all three wrote correctly
    for ch in range(3):
        actual = read_slave_word(slave, addrs[ch])
        assert actual == datas[ch], \
            f"Channel {ch}: expected 0x{datas[ch]:08X}, got 0x{actual:08X}"


@cocotb.test()
async def test_12_pending_survives_busy(dut):
    """Interrupt during busy state sets pending, serviced after current completes."""
    slave = await setup(dut)
    await do_reset(dut)

    addr_0, data_0 = 0x0000_A000, 0xAAAA_AAAA
    addr_1, data_1 = 0x0000_B000, 0xBBBB_BBBB

    dut.write_addr_0.value = addr_0
    dut.write_data_0.value = data_0
    dut.write_addr_1.value = addr_1
    dut.write_data_1.value = data_1

    # Start channel 0 transfer
    dut.interrupt_0.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_0.value = 0

    # While busy, pulse channel 1
    await RisingEdge(dut.hclk)
    assert dut.busy.value == 1, "DUT should be busy"
    dut.interrupt_1.value = 1
    await RisingEdge(dut.hclk)
    dut.interrupt_1.value = 0

    # Wait for channel 0 to complete
    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 1)

    actual_0 = read_slave_word(slave, addr_0)
    assert actual_0 == data_0, f"Channel 0: got 0x{actual_0:08X}"

    # Channel 1 should now be serviced from pending
    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual_1 = read_slave_word(slave, addr_1)
    assert actual_1 == data_1, \
        f"Channel 1 pending should survive busy: expected 0x{data_1:08X}, got 0x{actual_1:08X}"


@cocotb.test()
async def test_13_channel_data_isolation(dut):
    """Each channel uses its own addr/data — verify no cross-contamination."""
    slave = await setup(dut)
    await do_reset(dut)

    # Set up all three channels with distinct addresses and data
    channels = [
        (0x0000_C000, 0xC0C0_C0C0),
        (0x0000_D000, 0xD0D0_D0D0),
        (0x0000_E000, 0xE0E0_E0E0),
    ]

    for i, (addr, data) in enumerate(channels):
        getattr(dut, f"write_addr_{i}").value = addr
        getattr(dut, f"write_data_{i}").value = data

    # Fire each channel separately and verify isolation
    for i, (addr, data) in enumerate(channels):
        getattr(dut, f"interrupt_{i}").value = 1
        await RisingEdge(dut.hclk)
        getattr(dut, f"interrupt_{i}").value = 0

        await wait_not_busy(dut)
        await ClockCycles(dut.hclk, 2)

        actual = read_slave_word(slave, addr)
        assert actual == data, \
            f"Channel {i} data contaminated: expected 0x{data:08X}, got 0x{actual:08X}"

        # Verify other addresses weren't written (on first two iterations)
        for j in range(i + 1, 3):
            other_addr = channels[j][0]
            other_val = read_slave_word(slave, other_addr)
            assert other_val == 0, \
                f"Channel {j} addr 0x{other_addr:08X} should be 0, got 0x{other_val:08X}"


@cocotb.test()
async def test_14_held_interrupt_single_transfer(dut):
    """Interrupt held high should only produce one transfer (edge-triggered)."""
    slave = await setup(dut)
    await do_reset(dut)

    addr = 0x0000_F000
    dut.write_addr_0.value = addr
    dut.write_data_0.value = 0x1234_5678

    # Hold interrupt high for many cycles
    dut.interrupt_0.value = 1
    await ClockCycles(dut.hclk, 10)
    dut.interrupt_0.value = 0

    await wait_not_busy(dut)
    await ClockCycles(dut.hclk, 2)

    actual = read_slave_word(slave, addr)
    assert actual == 0x1234_5678, f"Expected single write, got 0x{actual:08X}"

    # Change data and wait — no new transfer should happen
    dut.write_data_0.value = 0xDEAD_BEEF
    await ClockCycles(dut.hclk, 10)

    assert dut.busy.value == 0, "No second transfer should occur from held interrupt"
    # Original data should remain (not overwritten)
    actual = read_slave_word(slave, addr)
    assert actual == 0x1234_5678, \
        f"Held interrupt should not cause second write: got 0x{actual:08X}"
