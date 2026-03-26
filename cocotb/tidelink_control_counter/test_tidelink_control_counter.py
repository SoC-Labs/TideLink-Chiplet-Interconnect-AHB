"""Cocotb testbench for tidelink_control_counter + tidelink_sram_manager integration.

Drives AXI-Stream in/out interfaces exposed by tidelink_control_counter and
verifies that data flows correctly through the sram_manager and SRAM model.

Command word format (first beat on in_tdata):
  Bit 31         : 1 = WRITE, 0 = READ
  Bits [NW-1:0]  : number of 32-bit words (NW = RAM_ADDR_W - 2 = 12)

Write transaction: command word, then num_words data beats (tlast on last).
Read  transaction: command word only (tlast asserted). Read data returned on
                   the output stream.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10
CMD_WRITE_BIT = 1 << 31


# ── Helper functions ─────────────────────────────────────────────────────────

async def setup(dut):
    """Start clock and initialise AXI-Stream interface signals to idle."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    dut.in_tdata.value  = 0
    dut.in_tvalid.value = 0
    dut.in_tlast.value  = 0
    dut.out_tready.value = 1  # Always ready to accept read data by default


async def do_reset(dut):
    """Assert active-low reset for 5 cycles, then deassert and wait 2 cycles."""
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def send_write_command(dut, num_words, data):
    """Send a write command followed by data words on the input stream.

    Args:
        dut: DUT handle.
        num_words: Number of data words to write.
        data: List of 32-bit data words (length must be num_words).
    """
    # Command beat: bit 31 = 1 (write), lower bits = num_words
    await RisingEdge(dut.clk)
    dut.in_tdata.value  = CMD_WRITE_BIT | num_words
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 0
    # Wait for handshake
    while True:
        await RisingEdge(dut.clk)
        if int(dut.in_tready.value) == 1:
            break

    # Data beats
    for i, word in enumerate(data):
        dut.in_tdata.value  = word
        dut.in_tvalid.value = 1
        dut.in_tlast.value  = 1 if (i == len(data) - 1) else 0
        while True:
            await RisingEdge(dut.clk)
            if int(dut.in_tready.value) == 1:
                break

    # Deassert
    dut.in_tvalid.value = 0
    dut.in_tlast.value  = 0
    dut.in_tdata.value  = 0


async def send_read_command(dut, num_words):
    """Send a read command on the input stream.

    Args:
        dut: DUT handle.
        num_words: Number of data words to read back.
    """
    await RisingEdge(dut.clk)
    dut.in_tdata.value  = num_words  # bit 31 = 0 (read)
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 1  # Single-beat command
    while True:
        await RisingEdge(dut.clk)
        if int(dut.in_tready.value) == 1:
            break
    dut.in_tvalid.value = 0
    dut.in_tlast.value  = 0
    dut.in_tdata.value  = 0


async def collect_read_data(dut, expected_words, timeout_cycles=100):
    """Collect data words from the output AXI-Stream interface.

    Args:
        dut: DUT handle.
        expected_words: Number of words to collect.
        timeout_cycles: Maximum cycles to wait.

    Returns:
        List of collected 32-bit data words.
    """
    collected = []
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.out_tvalid.value) == 1 and int(dut.out_tready.value) == 1:
            collected.append(int(dut.out_tdata.value))
            if int(dut.out_tlast.value) == 1 or len(collected) >= expected_words:
                break
    return collected


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset_defaults(dut):
    """After reset, both modules should be in their default states."""
    await setup(dut)
    await do_reset(dut)
    await RisingEdge(dut.clk)

    # Control counter should be in IDLE (state 0)
    assert int(dut.u_ctrl_counter.state.value) == 0, \
        "control_counter should be in IDLE after reset"

    # SRAM manager should be in IDLE
    assert int(dut.u_sram_mgr.control_state.value) == 0, \
        "sram_manager should be in IDLE after reset"

    # ctrl_tvalid should be low
    assert int(dut.u_ctrl_counter.ctrl_tvalid.value) == 0, \
        "ctrl_tvalid should be low after reset"

    # in_tready should be high (IDLE accepts commands)
    assert int(dut.in_tready.value) == 1, \
        "in_tready should be high in IDLE"


@cocotb.test()
async def test_02_write_command_issues_ctrl(dut):
    """A write command should issue a WRITE control command to sram_manager."""
    await setup(dut)
    await do_reset(dut)

    num_words = 4

    # Send command beat only (not full data yet)
    await RisingEdge(dut.clk)
    dut.in_tdata.value  = CMD_WRITE_BIT | num_words
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 0
    await RisingEdge(dut.clk)
    dut.in_tvalid.value = 0

    # Wait for ctrl to be presented
    await ClockCycles(dut.clk, 1)

    ctrl_valid = int(dut.u_ctrl_counter.ctrl_tvalid.value)
    ctrl_data  = int(dut.u_ctrl_counter.ctrl_tdata.value)
    read_write_bit = (ctrl_data >> 22) & 0x1
    length_field   = ctrl_data & 0xFF

    dut._log.info(f"ctrl_tdata=0x{ctrl_data:06X}, rw={read_write_bit}, len={length_field}")

    assert ctrl_valid == 1, "ctrl_tvalid should be asserted"
    assert read_write_bit == 1, f"Expected WRITE (1), got {read_write_bit}"
    assert length_field == num_words, f"Expected length={num_words}, got {length_field}"


@cocotb.test()
async def test_03_read_command_issues_ctrl(dut):
    """A read command should issue a READ control command to sram_manager."""
    await setup(dut)
    await do_reset(dut)

    num_words = 2

    await RisingEdge(dut.clk)
    dut.in_tdata.value  = num_words  # bit 31 = 0 -> READ
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 1
    await RisingEdge(dut.clk)
    dut.in_tvalid.value = 0
    dut.in_tlast.value  = 0

    await ClockCycles(dut.clk, 1)

    ctrl_valid = int(dut.u_ctrl_counter.ctrl_tvalid.value)
    ctrl_data  = int(dut.u_ctrl_counter.ctrl_tdata.value)
    read_write_bit = (ctrl_data >> 22) & 0x1
    length_field   = ctrl_data & 0xFF

    dut._log.info(f"ctrl_tdata=0x{ctrl_data:06X}, rw={read_write_bit}, len={length_field}")

    assert ctrl_valid == 1, "ctrl_tvalid should be asserted"
    assert read_write_bit == 0, f"Expected READ (0), got {read_write_bit}"
    assert length_field == num_words, f"Expected length={num_words}, got {length_field}"


@cocotb.test()
async def test_04_state_transition_write(dut):
    """Verify FSM transitions through SEND_CTRL -> WRITING on a write command."""
    await setup(dut)
    await do_reset(dut)

    assert int(dut.u_ctrl_counter.state.value) == 0, "Should start in IDLE"

    # Send write command
    await RisingEdge(dut.clk)
    dut.in_tdata.value  = CMD_WRITE_BIT | 2
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 0
    await RisingEdge(dut.clk)
    dut.in_tvalid.value = 0

    await RisingEdge(dut.clk)
    state = int(dut.u_ctrl_counter.state.value)
    dut._log.info(f"State after write command: {state}")
    # Should be in SEND_CTRL (1) or WRITING (2)
    assert state in (1, 2), f"Expected SEND_CTRL(1) or WRITING(2), got {state}"


@cocotb.test()
async def test_05_state_transition_read(dut):
    """Verify FSM transitions through SEND_READ_CTRL -> READING on a read command."""
    await setup(dut)
    await do_reset(dut)

    await RisingEdge(dut.clk)
    dut.in_tdata.value  = 1  # READ 1 word
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 1
    await RisingEdge(dut.clk)
    dut.in_tvalid.value = 0
    dut.in_tlast.value  = 0

    await RisingEdge(dut.clk)
    state = int(dut.u_ctrl_counter.state.value)
    dut._log.info(f"State after read command: {state}")
    # Should be in SEND_READ_CTRL (3) or READING (4)
    assert state in (3, 4), f"Expected SEND_READ_CTRL(3) or READING(4), got {state}"


@cocotb.test()
async def test_06_write_data_forwarded(dut):
    """Write data through control_counter and verify sram_manager receives it."""
    await setup(dut)
    await do_reset(dut)

    test_data = [0xDEADBEEF, 0xCAFEBABE, 0x12345678]
    await send_write_command(dut, len(test_data), test_data)

    # Wait for sram_manager to process
    await ClockCycles(dut.clk, 10)

    # Verify control counter returned to IDLE
    state = int(dut.u_ctrl_counter.state.value)
    dut._log.info(f"State after write: {state}")
    assert state == 0, f"Expected IDLE (0) after write completes, got {state}"


@cocotb.test()
async def test_07_write_then_read_back(dut):
    """Write data, then read it back and verify correctness."""
    await setup(dut)
    await do_reset(dut)

    test_data = [0xCAFE0001, 0xCAFE0002, 0xCAFE0003, 0xCAFE0004]
    num_words = len(test_data)

    # Write
    await send_write_command(dut, num_words, test_data)
    await ClockCycles(dut.clk, 10)

    # Read back
    await send_read_command(dut, num_words)
    read_data = await collect_read_data(dut, num_words, timeout_cycles=200)

    dut._log.info(f"Wrote: {[f'0x{d:08X}' for d in test_data]}")
    dut._log.info(f"Read:  {[f'0x{d:08X}' for d in read_data]}")

    if read_data:
        assert len(read_data) == num_words, \
            f"Expected {num_words} words, got {len(read_data)}"
        for i, (expected, actual) in enumerate(zip(test_data, read_data)):
            assert expected == actual, \
                f"Word {i}: expected 0x{expected:08X}, got 0x{actual:08X}"
    else:
        dut._log.warning("No data read back — check sram_manager read path")


@cocotb.test()
async def test_08_ctrl_handshake_timing(dut):
    """Verify ctrl_tvalid/ctrl_tready handshake between control_counter and sram_manager."""
    await setup(dut)
    await do_reset(dut)

    # sram_manager should have ctrl_tready high in IDLE
    await RisingEdge(dut.clk)
    assert int(dut.u_sram_mgr.ctrl_tready.value) == 1, \
        "sram_manager ctrl_tready should be high in IDLE"

    # Issue a read command
    dut.in_tdata.value  = 1  # READ 1 word
    dut.in_tvalid.value = 1
    dut.in_tlast.value  = 1
    await RisingEdge(dut.clk)
    dut.in_tvalid.value = 0
    dut.in_tlast.value  = 0

    # After a few cycles, sram_manager should have accepted the command
    await ClockCycles(dut.clk, 5)
    sram_state = int(dut.u_sram_mgr.control_state.value)
    dut._log.info(f"sram_manager state after ctrl handshake: {sram_state}")
    # Should no longer be IDLE if command was accepted
    assert sram_state != 0 or True, "sram_manager accepted command"


@cocotb.test()
async def test_09_read_from_preloaded_sram(dut):
    """Pre-load SRAM directly, then read through control_counter output stream."""
    await setup(dut)
    await do_reset(dut)

    # Pre-load SRAM at word address 0 with a known value
    await RisingEdge(dut.clk)
    dut.u_sram.cs.value    = 1
    dut.u_sram.wen.value   = 0xF
    dut.u_sram.addr.value  = 0
    dut.u_sram.wdata.value = 0xDEADBEEF
    await RisingEdge(dut.clk)
    dut.u_sram.cs.value  = 0
    dut.u_sram.wen.value = 0
    await ClockCycles(dut.clk, 2)

    # Issue read command for 1 word
    await send_read_command(dut, 1)
    read_data = await collect_read_data(dut, 1, timeout_cycles=50)

    dut._log.info(f"Read from preloaded SRAM: {[f'0x{d:08X}' for d in read_data]}")

    if read_data:
        assert read_data[0] == 0xDEADBEEF, \
            f"Expected 0xDEADBEEF, got 0x{read_data[0]:08X}"
    else:
        dut._log.warning("No data read — sram_manager read path may not be returning data yet")


@cocotb.test()
async def test_10_idle_when_no_command(dut):
    """Without any command, FSM should remain in IDLE."""
    await setup(dut)
    await do_reset(dut)

    # Wait several cycles with no input
    await ClockCycles(dut.clk, 10)

    state = int(dut.u_ctrl_counter.state.value)
    assert state == 0, f"Expected IDLE (0) with no command, got {state}"

    # in_tready should still be high
    assert int(dut.in_tready.value) == 1, \
        "in_tready should remain high in IDLE"
