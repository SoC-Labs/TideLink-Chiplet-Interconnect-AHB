"""Cocotb testbench for tidelink_sram_manager — mirrors the SV testbench tests.

Uses cocotbext-axi AxiStreamSource/Sink for AXI-Stream interfaces.
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink, AxiStreamFrame

# ── Constants ────────────────────────────────────────────────────────────────
RAM_ADDR_W = 14
WORD_LEN_W = 8
CLK_PERIOD_NS = 10


# ── Helper functions ─────────────────────────────────────────────────────────

def build_ctrl_frame(read_write, addr, length):
    """Build an AxiStreamFrame for a control command.

    Control word: {read_write[1], addr[13:0], length[7:0]} = 23 bits.
    Wrapper pads to 24 bits (3 bytes LE) for byte-aligned cocotbext-axi.
    """
    cmd = ((read_write & 0x1) << 22) | ((addr & 0x3FFF) << 8) | (length & 0xFF)
    return AxiStreamFrame(cmd.to_bytes(3, "little"))


def build_din_frame(num_words, start_val):
    """Build an AxiStreamFrame for a data-in burst (32-bit words, LE byte order)."""
    data = bytearray()
    for i in range(num_words):
        val = (start_val + i) & 0xFFFFFFFF
        data.extend(val.to_bytes(4, "little"))
    return AxiStreamFrame(data)


def unpack_dout_words(frame):
    """Extract 32-bit words (LE) from a received AxiStreamFrame."""
    words = []
    for i in range(0, len(frame.tdata), 4):
        words.append(int.from_bytes(frame.tdata[i : i + 4], "little"))
    return words


def random_pause_generator(max_pause):
    """Yield True/False each cycle: one active cycle then 0–max_pause paused cycles."""
    while True:
        yield False
        for _ in range(random.randint(0, max_pause)):
            yield True


async def setup(dut):
    """Start clock, create AXI-Stream Source/Sink objects, and return them."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())

    ctrl_source = AxiStreamSource(
        AxiStreamBus.from_prefix(dut, "ctrl"), dut.clk, dut.rst_n, reset_active_level=False
    )
    din_source = AxiStreamSource(
        AxiStreamBus.from_prefix(dut, "din"), dut.clk, dut.rst_n, reset_active_level=False
    )
    dout_sink = AxiStreamSink(
        AxiStreamBus.from_prefix(dut, "dout"), dut.clk, dut.rst_n, reset_active_level=False
    )
    return ctrl_source, din_source, dout_sink


async def do_reset(dut):
    """Assert active-low reset for 5 cycles, then deassert and wait 2 cycles."""
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def send_ctrl(ctrl_source, read_write, addr, length):
    """Send a control command and wait for the handshake to complete."""
    frame = build_ctrl_frame(read_write, addr, length)
    await ctrl_source.send(frame)
    await ctrl_source.wait()


async def write_burst(ctrl_source, din_source, addr, num_words, start_val):
    """Issue a WRITE command then send din data. Waits until fully transmitted."""
    await send_ctrl(ctrl_source, 1, addr, num_words)
    frame = build_din_frame(num_words, start_val)
    await din_source.send(frame)
    await din_source.wait()


async def read_burst(ctrl_source, dout_sink, addr, num_words):
    """Issue a READ command and return list of received 32-bit words."""
    await send_ctrl(ctrl_source, 0, addr, num_words)
    rx_frame = await dout_sink.recv()
    return unpack_dout_words(rx_frame)


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset_defaults(dut):
    """Test 1: Reset defaults."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    dout_sink.pause = True  # Keep tready low to match SV TB reset state
    await do_reset(dut)
    await RisingEdge(dut.clk)

    assert dut.ctrl_tready.value == 1, "ctrl_tready should be 1 in IDLE"
    assert dut.u_dut.sramcs.value == 0, "sramcs should be 0 after reset"
    assert dut.u_dut.sramwen.value == 0, "sramwen should be 0 after reset"
    assert dut.dout_tvalid.value == 0, "dout_tvalid should be 0 after reset"


@cocotb.test()
async def test_02_write_cmd_fsm(dut):
    """Test 2: WRITE command — FSM transitions to PROCESSING_DATA_IN."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await send_ctrl(ctrl_source, 1, 0x0000, 4)
    await RisingEdge(dut.clk)

    assert dut.ctrl_tready.value == 0, "ctrl_tready should be low in PROCESSING_DATA_IN"
    assert dut.u_dut.din_tready.value == 1, "din_tready should be high in PROCESSING_DATA_IN"


@cocotb.test()
async def test_03_single_word_write_readback(dut):
    """Test 3: Single word write and readback."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await write_burst(ctrl_source, din_source, 0x0000, 1, 0xCAFEBABE)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1, "ctrl_tready not back in IDLE"

    rx = await read_burst(ctrl_source, dout_sink, 0x0000, 1)
    assert len(rx) == 1, f"Expected 1 word, got {len(rx)}"
    assert rx[0] == 0xCAFEBABE, f"Readback mismatch: expected 0xCAFEBABE, got 0x{rx[0]:08X}"


@cocotb.test()
async def test_04_multi_word_burst(dut):
    """Test 4: 4-word write burst and readback."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await write_burst(ctrl_source, din_source, 0x0000, 4, 0xAA000000)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1, "ctrl_tready not back in IDLE"

    rx = await read_burst(ctrl_source, dout_sink, 0x0000, 4)
    assert len(rx) == 4, f"Expected 4 words, got {len(rx)}"
    for i in range(4):
        expected = (0xAA000000 + i) & 0xFFFFFFFF
        assert rx[i] == expected, \
            f"Readback data[{i}]: expected 0x{expected:08X}, got 0x{rx[i]:08X}"


@cocotb.test()
async def test_05_read_cmd_fsm(dut):
    """Test 5: READ command — FSM goes to PROCESSING_DATA_OUT."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    dout_sink.pause = True  # Hold tready low so FSM stays in PROCESSING_DATA_OUT
    await do_reset(dut)

    await send_ctrl(ctrl_source, 0, 0x0000, 1)
    await RisingEdge(dut.clk)

    assert int(dut.u_dut.control_state.value) == 2, \
        f"Expected state PROCESSING_DATA_OUT (2), got {int(dut.u_dut.control_state.value)}"
    assert dut.ctrl_tready.value == 0, "ctrl_tready should be low in PROCESSING_DATA_OUT"


@cocotb.test()
async def test_06_loopback_different_address(dut):
    """Test 6: Write-then-read loopback at addr=0x0040."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await write_burst(ctrl_source, din_source, 0x0040, 4, 0xCC000000)
    await ClockCycles(dut.clk, 2)

    rx = await read_burst(ctrl_source, dout_sink, 0x0040, 4)
    assert len(rx) == 4, f"Expected 4 words, got {len(rx)}"
    for i in range(4):
        expected = (0xCC000000 + i) & 0xFFFFFFFF
        assert rx[i] == expected, \
            f"Loopback data[{i}]: expected 0x{expected:08X}, got 0x{rx[i]:08X}"


@cocotb.test()
async def test_07_back_to_back_single_writes(dut):
    """Test 7: Back-to-back single-word writes then readback."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await write_burst(ctrl_source, din_source, 0x0000, 1, 0x11111111)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1, "FSM not back to IDLE"

    await write_burst(ctrl_source, din_source, 0x0004, 1, 0x22222222)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1, "FSM not back to IDLE"

    rx = await read_burst(ctrl_source, dout_sink, 0x0000, 1)
    assert rx[0] == 0x11111111, \
        f"1st write readback: expected 0x11111111, got 0x{rx[0]:08X}"

    await ClockCycles(dut.clk, 2)

    rx = await read_burst(ctrl_source, dout_sink, 0x0004, 1)
    assert rx[0] == 0x22222222, \
        f"2nd write readback: expected 0x22222222, got 0x{rx[0]:08X}"


@cocotb.test()
async def test_08_dout_tlast(dut):
    """Test 8: Verify dout_tlast on final read beat (length=3).

    The sink only completes a frame on tlast, so receiving a 3-word frame
    confirms tlast was asserted on the 3rd beat.
    """
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await write_burst(ctrl_source, din_source, 0x0000, 3, 0xFF000000)
    await ClockCycles(dut.clk, 2)

    rx = await read_burst(ctrl_source, dout_sink, 0x0000, 3)
    assert len(rx) == 3, f"dout_tlast should delimit exactly 3 words, got {len(rx)}"


@cocotb.test()
async def test_09_gapped_write(dut):
    """Test 9: 4-word write with gapped din, then readback."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    # Enable random gaps on din source
    din_source.set_pause_generator(random_pause_generator(5))

    await write_burst(ctrl_source, din_source, 0x0080, 4, 0xDA000000)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1, "ctrl_tready not back in IDLE"

    din_source.clear_pause_generator()

    rx = await read_burst(ctrl_source, dout_sink, 0x0080, 4)
    assert len(rx) == 4
    for i in range(4):
        expected = (0xDA000000 + i) & 0xFFFFFFFF
        assert rx[i] == expected, \
            f"Gapped write readback[{i}]: expected 0x{expected:08X}, got 0x{rx[i]:08X}"


@cocotb.test()
async def test_10_stalled_read(dut):
    """Test 10: 4-word read with stalled dout_tready."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    await write_burst(ctrl_source, din_source, 0x00C0, 4, 0xAC000000)
    await ClockCycles(dut.clk, 2)

    # Enable random stalls on dout sink
    dout_sink.set_pause_generator(random_pause_generator(5))

    rx = await read_burst(ctrl_source, dout_sink, 0x00C0, 4)

    dout_sink.clear_pause_generator()

    assert len(rx) == 4, f"Expected 4 words (stalled), got {len(rx)}"
    for i in range(4):
        expected = (0xAC000000 + i) & 0xFFFFFFFF
        assert rx[i] == expected, \
            f"Stalled read data[{i}]: expected 0x{expected:08X}, got 0x{rx[i]:08X}"


@cocotb.test()
async def test_11_gapped_write_stalled_read(dut):
    """Test 11: 8-word gapped write + stalled read."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    din_source.set_pause_generator(random_pause_generator(4))
    await write_burst(ctrl_source, din_source, 0x0100, 8, 0xBB000000)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1
    din_source.clear_pause_generator()

    dout_sink.set_pause_generator(random_pause_generator(4))
    rx = await read_burst(ctrl_source, dout_sink, 0x0100, 8)
    dout_sink.clear_pause_generator()

    assert len(rx) == 8
    for i in range(8):
        expected = (0xBB000000 + i) & 0xFFFFFFFF
        assert rx[i] == expected, \
            f"Gapped/stalled data[{i}]: expected 0x{expected:08X}, got 0x{rx[i]:08X}"


@cocotb.test()
async def test_12_single_word_gapped_stalled(dut):
    """Test 12: Single-word gapped write + stalled read (edge case)."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    din_source.set_pause_generator(random_pause_generator(3))
    await write_burst(ctrl_source, din_source, 0x0140, 1, 0xDEADBEEF)
    await ClockCycles(dut.clk, 2)
    din_source.clear_pause_generator()

    dout_sink.set_pause_generator(random_pause_generator(3))
    rx = await read_burst(ctrl_source, dout_sink, 0x0140, 1)
    dout_sink.clear_pause_generator()

    assert len(rx) == 1
    assert rx[0] == 0xDEADBEEF, \
        f"Single-word gapped/stalled readback: expected 0xDEADBEEF, got 0x{rx[0]:08X}"


@cocotb.test()
async def test_13_stress(dut):
    """Test 13: Stress — 8-word write (max gap=10) + read (max stall=10)."""
    ctrl_source, din_source, dout_sink = await setup(dut)
    await do_reset(dut)

    din_source.set_pause_generator(random_pause_generator(10))
    await write_burst(ctrl_source, din_source, 0x0180, 8, 0xEE000000)
    await ClockCycles(dut.clk, 2)
    assert dut.ctrl_tready.value == 1
    din_source.clear_pause_generator()

    dout_sink.set_pause_generator(random_pause_generator(10))
    rx = await read_burst(ctrl_source, dout_sink, 0x0180, 8)
    dout_sink.clear_pause_generator()

    assert len(rx) == 8
    for i in range(8):
        expected = (0xEE000000 + i) & 0xFFFFFFFF
        assert rx[i] == expected, \
            f"Stress data[{i}]: expected 0x{expected:08X}, got 0x{rx[i]:08X}"
