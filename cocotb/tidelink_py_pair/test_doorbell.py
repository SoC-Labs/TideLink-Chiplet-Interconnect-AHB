"""Tests for doorbell/reset handshake flows."""

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from py_pair_helpers import (
    setup, setup_with_pair, do_reset, apb_write, apb_read,
    ahb_master_monitor, PairRegisterBank,
    OFF_DOORBELL, OFF_DOORBELL_RESPONSE,
    PAIR_BASE, MAX_TOKENS,
)


@cocotb.test()
async def test_01_reset_doorbell_flow(dut):
    """Test the reset -> doorbell -> token response flow.

    1. DUT comes out of reset
    2. Channel 2 fires: writes to pair's doorbell
    3. Pair responds with its token count to DUT's doorbell response accumulator
    4. DUT's doorbell_irq asserts
    5. CPU reads accumulator -> gets pair's token count, IRQ clears
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS,
    )

    cocotb.start_soon(ahb_master_monitor(dut, pair))

    await do_reset(dut)
    await ClockCycles(dut.hclk, 10)

    assert pair.doorbell_pending, \
        "Pair should have received a doorbell ring after DUT reset"

    await ClockCycles(dut.hclk, 5)

    irq = int(dut.doorbell_irq.value)
    dut._log.info(f"doorbell_irq = {irq}")
    assert irq == 1, "doorbell_irq should be asserted after pair responds"

    acc_value = await apb_read(dut, OFF_DOORBELL_RESPONSE)
    dut._log.info(f"Doorbell response accumulator = {acc_value} "
                  f"(expected {MAX_TOKENS})")
    assert acc_value == MAX_TOKENS, \
        f"Expected {MAX_TOKENS}, got {acc_value}"

    await ClockCycles(dut.hclk, 1)
    irq = int(dut.doorbell_irq.value)
    assert irq == 0, "doorbell_irq should clear after CPU read"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_02_software_doorbell(dut):
    """Test the software-triggered doorbell flow.

    1. DUT is out of reset and stable
    2. CPU writes to DUT's doorbell register
    3. Channel 1 fires: writes DUT's total free tokens to pair's doorbell response accumulator
    4. Pair model accumulates the value
    """
    pair = await setup_with_pair(dut)

    pair.released_tokens_acc = 0
    pair.log_lines.clear()

    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    dut._log.info(f"Pair received: {pair.released_tokens_acc} tokens")
    assert pair.released_tokens_acc == MAX_TOKENS, \
        f"Pair should have received {MAX_TOKENS} tokens, got {pair.released_tokens_acc}"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_03_independent_resets(dut):
    """Test that each side can reset independently.

    1. Both sides come out of reset together
    2. DUT's reset doorbell rings pair, pair responds
    3. DUT resets again (simulating a soft reset)
    4. DUT's reset doorbell rings pair again, pair responds again
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS,
    )
    cocotb.start_soon(ahb_master_monitor(dut, pair))

    # First reset (both sides together)
    dut._log.info("=== First reset ===")
    pair.reset()
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    irq = int(dut.doorbell_irq.value)
    assert irq == 1, "doorbell_irq should be asserted after first reset handshake"

    acc = await apb_read(dut, OFF_DOORBELL_RESPONSE)
    dut._log.info(f"After first reset: doorbell response accumulator = {acc}")
    assert acc == MAX_TOKENS, f"Expected {MAX_TOKENS}, got {acc}"

    await ClockCycles(dut.hclk, 2)
    assert int(dut.doorbell_irq.value) == 0, "doorbell_irq should clear after read"

    # Second reset (DUT only, pair stays running)
    dut._log.info("=== Second reset (DUT only) ===")
    pair.token_count = MAX_TOKENS - 100
    pair.doorbell_pending = False

    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    assert pair.doorbell_pending, "Pair should see doorbell from DUT's second reset"

    irq = int(dut.doorbell_irq.value)
    assert irq == 1, "doorbell_irq should be asserted after second reset handshake"

    acc = await apb_read(dut, OFF_DOORBELL_RESPONSE)
    dut._log.info(f"After second reset: doorbell response accumulator = {acc} "
                  f"(pair has {pair.token_count} free)")
    assert acc == MAX_TOKENS - 100, \
        f"Expected {MAX_TOKENS - 100} (pair's current free tokens), got {acc}"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_04_pair_resets_while_dut_running(dut):
    """Simulate the pair resetting while the DUT is running.

    When the pair resets, it rings the DUT's doorbell. The DUT should
    respond with its total free tokens to the pair's accumulator.
    """
    pair = await setup_with_pair(dut)

    pair.released_tokens_acc = 0
    pair.log_lines.clear()
    await apb_read(dut, OFF_DOORBELL_RESPONSE)  # Clear DUT's doorbell response accumulator

    dut._log.info("=== Pair resets -- ringing DUT's doorbell ===")
    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    dut._log.info(f"Pair received: {pair.released_tokens_acc} tokens from DUT")
    assert pair.released_tokens_acc == MAX_TOKENS, \
        f"Expected DUT to send {MAX_TOKENS} tokens, got {pair.released_tokens_acc}"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_05_simultaneous_reset(dut):
    """Both sides reset at the same time.

    1. DUT resets and pair resets simultaneously
    2. DUT's reset channel rings pair's doorbell
    3. Pair responds with its full token count
    4. Pair would ring DUT's doorbell (simulated via APB write)
    5. Verify both sides receive each other's token counts
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS,
    )
    cocotb.start_soon(ahb_master_monitor(dut, pair))

    dut._log.info("=== Simultaneous reset ===")
    pair.reset()
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    acc_from_pair = await apb_read(dut, OFF_DOORBELL_RESPONSE)
    dut._log.info(f"DUT received from pair: {acc_from_pair}")
    assert acc_from_pair == MAX_TOKENS, \
        f"DUT should receive {MAX_TOKENS} from pair, got {acc_from_pair}"

    pair.released_tokens_acc = 0
    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    dut._log.info(f"Pair received from DUT: {pair.released_tokens_acc}")
    assert pair.released_tokens_acc == MAX_TOKENS, \
        f"Pair should receive {MAX_TOKENS} from DUT, got {pair.released_tokens_acc}"

    dut._log.info("Both sides received each other's token counts")

    for line in pair.log_lines:
        dut._log.info(line)
