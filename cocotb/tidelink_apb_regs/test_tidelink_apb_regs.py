"""Cocotb testbench for tidelink_apb_regs standalone.

Tests the APB register interface in isolation — no FIFO or returner,
just the register block with sideband inputs driven directly.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10
PAIR_BASE     = 0x4000_1000  # Must match tb_top parameter

# APB offsets — Region 0
OFF_PAIR_BASE     = 0x000
OFF_PKT_WORD_LEN  = 0x008
OFF_TOKEN_COUNT   = 0x00C
OFF_STATUS        = 0x010
OFF_DOORBELL      = 0x014

# APB offsets — Region 1
OFF_REL_TOKENS    = 0x020
OFF_DOORBELL_RSP  = 0x024
OFF_PAIR_COUNTER  = 0x028
OFF_PAIR_CONSUME  = 0x02C
OFF_PAIR_CTR_EN   = 0x030


# ── Helpers ──────────────────────────────────────────────────────────────────

async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = 0
    dut.pwdata.value  = 0
    dut.packet_word_length.value  = 0
    dut.current_token_count.value = 0
    dut.read_complete.value       = 0
    dut.returner_busy.value       = 0


async def do_reset(dut):
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def apb_write(dut, addr, data):
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 1
    dut.paddr.value   = addr & 0xFFF
    dut.pwdata.value  = data
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    dut.psel.value    = 0
    dut.penable.value = 0
    dut.pwrite.value  = 0


async def apb_read(dut, addr):
    await RisingEdge(dut.hclk)
    dut.psel.value    = 1
    dut.penable.value = 0
    dut.pwrite.value  = 0
    dut.paddr.value   = addr & 0xFFF
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    rdata = int(dut.prdata.value)
    dut.psel.value    = 0
    dut.penable.value = 0
    return rdata


# ══════════════════════════════════════════════════════════════════════════════
# Region 0 Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_r0_01_pair_base_default(dut):
    """Pair base address defaults to TIDELINK_PAIR_BASE parameter."""
    await setup(dut)
    await do_reset(dut)

    val = await apb_read(dut, OFF_PAIR_BASE)
    assert val == PAIR_BASE, f"Expected 0x{PAIR_BASE:08X}, got 0x{val:08X}"


@cocotb.test()
async def test_r0_02_pair_base_rw(dut):
    """Pair base address is read-write."""
    await setup(dut)
    await do_reset(dut)

    new_base = 0xDEAD_0000
    await apb_write(dut, OFF_PAIR_BASE, new_base)
    val = await apb_read(dut, OFF_PAIR_BASE)
    assert val == new_base, f"Expected 0x{new_base:08X}, got 0x{val:08X}"

    # Also check the output port
    assert int(dut.pair_base_addr.value) == new_base


@cocotb.test()
async def test_r0_03_pair_base_resets_to_param(dut):
    """Pair base reverts to parameter value after reset."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_PAIR_BASE, 0xBEEF_0000)
    await do_reset(dut)

    val = await apb_read(dut, OFF_PAIR_BASE)
    assert val == PAIR_BASE, f"Expected 0x{PAIR_BASE:08X} after reset, got 0x{val:08X}"


@cocotb.test()
async def test_r0_04_packet_word_length_ro(dut):
    """Packet word length reflects sideband input, is read-only."""
    await setup(dut)
    await do_reset(dut)

    dut.packet_word_length.value = 42
    await ClockCycles(dut.hclk, 1)

    val = await apb_read(dut, OFF_PKT_WORD_LEN)
    assert val == 42, f"Expected 42, got {val}"


@cocotb.test()
async def test_r0_05_token_count_ro(dut):
    """Token count reflects sideband input."""
    await setup(dut)
    await do_reset(dut)

    dut.current_token_count.value = 1000
    await ClockCycles(dut.hclk, 1)

    val = await apb_read(dut, OFF_TOKEN_COUNT)
    assert val == 1000, f"Expected 1000, got {val}"


@cocotb.test()
async def test_r0_06_status_returner_busy(dut):
    """Status register bit 0 reflects returner_busy."""
    await setup(dut)
    await do_reset(dut)

    dut.returner_busy.value = 0
    await ClockCycles(dut.hclk, 1)
    val = await apb_read(dut, OFF_STATUS)
    assert val & 1 == 0, f"Expected busy=0, got 0x{val:08X}"

    dut.returner_busy.value = 1
    await ClockCycles(dut.hclk, 1)
    val = await apb_read(dut, OFF_STATUS)
    assert val & 1 == 1, f"Expected busy=1, got 0x{val:08X}"


@cocotb.test()
async def test_r0_07_doorbell_trigger_pulse(dut):
    """Writing to doorbell register generates a one-cycle pulse."""
    await setup(dut)
    await do_reset(dut)

    assert int(dut.doorbell_trigger.value) == 0

    await apb_write(dut, OFF_DOORBELL, 1)
    # Pulse should have fired and self-cleared
    await ClockCycles(dut.hclk, 2)
    assert int(dut.doorbell_trigger.value) == 0, "Doorbell should self-clear"


@cocotb.test()
async def test_r0_08_reset_deassert_pulse(dut):
    """Reset deassertion generates a one-cycle pulse."""
    await setup(dut)
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1

    # Pulse should fire 2 cycles after reset deassertion
    await RisingEdge(dut.hclk)
    await RisingEdge(dut.hclk)
    pulse = int(dut.reset_deassert_pulse.value)
    assert pulse == 1, "reset_deassert_pulse should fire"

    await RisingEdge(dut.hclk)
    pulse = int(dut.reset_deassert_pulse.value)
    assert pulse == 0, "reset_deassert_pulse should be one cycle only"


# ══════════════════════════════════════════════════════════════════════════════
# Region 1 Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_r1_01_released_tokens_acc_add(dut):
    """Released tokens accumulator adds incoming values."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 10)
    await apb_write(dut, OFF_REL_TOKENS, 20)
    val = await apb_read(dut, OFF_REL_TOKENS)
    assert val == 30, f"Expected 30, got {val}"


@cocotb.test()
async def test_r1_02_released_tokens_read_clear(dut):
    """Reading released tokens accumulator clears it."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 100)
    await apb_read(dut, OFF_REL_TOKENS)  # Clears
    val = await apb_read(dut, OFF_REL_TOKENS)
    assert val == 0, f"Expected 0 after clear, got {val}"


@cocotb.test()
async def test_r1_03_released_tokens_irq(dut):
    """released_tokens_irq asserts on non-zero, clears on read."""
    await setup(dut)
    await do_reset(dut)

    assert int(dut.released_tokens_irq.value) == 0

    await apb_write(dut, OFF_REL_TOKENS, 5)
    await ClockCycles(dut.hclk, 1)
    assert int(dut.released_tokens_irq.value) == 1

    await apb_read(dut, OFF_REL_TOKENS)
    await ClockCycles(dut.hclk, 1)
    assert int(dut.released_tokens_irq.value) == 0


@cocotb.test()
async def test_r1_04_doorbell_response_acc(dut):
    """Doorbell response accumulator adds and read-clears."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_DOORBELL_RSP, 4096)
    val = await apb_read(dut, OFF_DOORBELL_RSP)
    assert val == 4096

    val = await apb_read(dut, OFF_DOORBELL_RSP)
    assert val == 0


@cocotb.test()
async def test_r1_05_doorbell_irq(dut):
    """doorbell_irq asserts on non-zero doorbell response, clears on read."""
    await setup(dut)
    await do_reset(dut)

    assert int(dut.doorbell_irq.value) == 0

    await apb_write(dut, OFF_DOORBELL_RSP, 100)
    await ClockCycles(dut.hclk, 1)
    assert int(dut.doorbell_irq.value) == 1

    await apb_read(dut, OFF_DOORBELL_RSP)
    await ClockCycles(dut.hclk, 1)
    assert int(dut.doorbell_irq.value) == 0


@cocotb.test()
async def test_r1_06_pair_counter_increment(dut):
    """Pair token counter increments on write to released tokens (0x020)."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 10)
    await apb_write(dut, OFF_REL_TOKENS, 5)
    val = await apb_read(dut, OFF_PAIR_COUNTER)
    assert val == 15, f"Expected 15, got {val}"


@cocotb.test()
async def test_r1_07_pair_counter_consume(dut):
    """Pair token counter decrements on write to consume (0x02C)."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 20)
    await apb_write(dut, OFF_PAIR_CONSUME, 7)
    val = await apb_read(dut, OFF_PAIR_COUNTER)
    assert val == 13, f"Expected 13, got {val}"


@cocotb.test()
async def test_r1_08_pair_counter_no_side_effect_read(dut):
    """Reading pair token counter does NOT clear it."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 42)
    for _ in range(3):
        val = await apb_read(dut, OFF_PAIR_COUNTER)
        assert val == 42


@cocotb.test()
async def test_r1_09_pair_counter_disable(dut):
    """Disabled counter ignores increments and decrements."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 30)
    await apb_write(dut, OFF_PAIR_CTR_EN, 0)  # Disable
    await apb_write(dut, OFF_REL_TOKENS, 100)  # Ignored
    await apb_write(dut, OFF_PAIR_CONSUME, 10)  # Ignored
    val = await apb_read(dut, OFF_PAIR_COUNTER)
    assert val == 30, f"Expected 30 (frozen), got {val}"


@cocotb.test()
async def test_r1_10_pair_counter_re_enable(dut):
    """Re-enabling counter resumes tracking."""
    await setup(dut)
    await do_reset(dut)

    await apb_write(dut, OFF_REL_TOKENS, 50)
    await apb_write(dut, OFF_PAIR_CTR_EN, 0)
    await apb_write(dut, OFF_REL_TOKENS, 999)  # Ignored
    await apb_write(dut, OFF_PAIR_CTR_EN, 1)
    await apb_write(dut, OFF_REL_TOKENS, 25)
    await apb_write(dut, OFF_PAIR_CONSUME, 10)
    val = await apb_read(dut, OFF_PAIR_COUNTER)
    assert val == 65, f"Expected 65, got {val}"


@cocotb.test()
async def test_r1_11_pair_counter_enable_readback(dut):
    """Enable register reads back correctly."""
    await setup(dut)
    await do_reset(dut)

    val = await apb_read(dut, OFF_PAIR_CTR_EN)
    assert val == 1, "Default enable should be 1"

    await apb_write(dut, OFF_PAIR_CTR_EN, 0)
    val = await apb_read(dut, OFF_PAIR_CTR_EN)
    assert val == 0

    await apb_write(dut, OFF_PAIR_CTR_EN, 1)
    val = await apb_read(dut, OFF_PAIR_CTR_EN)
    assert val == 1


@cocotb.test()
async def test_r1_12_token_delta_capture(dut):
    """Token delta is captured on read_complete pulse."""
    await setup(dut)
    await do_reset(dut)

    dut.packet_word_length.value = 5
    await ClockCycles(dut.hclk, 1)

    # Pulse read_complete
    dut.read_complete.value = 1
    await RisingEdge(dut.hclk)
    dut.read_complete.value = 0
    await RisingEdge(dut.hclk)

    delta = int(dut.token_delta_data.value)
    assert delta == 6, f"Expected delta 6 (5+1), got {delta}"


@cocotb.test()
async def test_r1_13_token_count_data_passthrough(dut):
    """token_count_data reflects current_token_count combinationally."""
    await setup(dut)
    await do_reset(dut)

    dut.current_token_count.value = 4096
    await ClockCycles(dut.hclk, 1)

    val = int(dut.token_count_data.value)
    assert val == 4096, f"Expected 4096, got {val}"


@cocotb.test()
async def test_misc_01_pready_always_high(dut):
    """pready is always 1 (zero wait-state slave)."""
    await setup(dut)
    await do_reset(dut)
    assert int(dut.pready.value) == 1


@cocotb.test()
async def test_misc_02_pslverr_always_low(dut):
    """pslverr is always 0 (no errors)."""
    await setup(dut)
    await do_reset(dut)
    assert int(dut.pslverr.value) == 0


@cocotb.test()
async def test_misc_03_unimplemented_reads_zero(dut):
    """Reading unimplemented addresses returns 0."""
    await setup(dut)
    await do_reset(dut)

    for offset in [0x004, 0x018, 0x01C, 0x034, 0x038]:
        val = await apb_read(dut, offset)
        assert val == 0, f"Offset 0x{offset:03X} should read 0, got 0x{val:08X}"
