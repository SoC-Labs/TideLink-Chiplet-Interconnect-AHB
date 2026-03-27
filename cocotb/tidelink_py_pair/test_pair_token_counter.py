"""Pair token counter tests."""

import cocotb
from cocotb.triggers import ClockCycles

from py_pair_helpers import (
    setup_with_pair, apb_write, apb_read, fifo_write_packet,
    OFF_RELEASED_TOKENS, OFF_DOORBELL_RESPONSE,
    OFF_PAIR_TOKEN_COUNTER, OFF_PAIR_TOKEN_CONSUME, OFF_PAIR_TOKEN_ENABLE,
)


@cocotb.test()
async def test_ptc_01_defaults_after_reset(dut):
    """Pair token counter is 0 and enabled after reset."""
    pair = await setup_with_pair(dut)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    enable  = await apb_read(dut, OFF_PAIR_TOKEN_ENABLE)

    dut._log.info(f"After reset: counter={counter}, enable={enable}")
    assert counter == 0, f"Counter should be 0 after reset, got {counter}"
    assert enable == 1, f"Enable should be 1 after reset, got {enable}"


@cocotb.test()
async def test_ptc_02_increments_on_released_tokens(dut):
    """Counter increments when released tokens are written to 0x020."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)  # Clear accumulator from reset
    await ClockCycles(dut.hclk, 2)

    # Simulate pair releasing 10 tokens (write to 0x020)
    await apb_write(dut, OFF_RELEASED_TOKENS, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After 10 released tokens: counter={counter}")
    assert counter == 10, f"Expected 10, got {counter}"

    # Release 5 more
    await apb_write(dut, OFF_RELEASED_TOKENS, 5)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After 5 more: counter={counter}")
    assert counter == 15, f"Expected 15, got {counter}"


@cocotb.test()
async def test_ptc_03_decrements_on_consume(dut):
    """Counter decrements when CPU writes to consume register (0x02C)."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Add 20 tokens
    await apb_write(dut, OFF_RELEASED_TOKENS, 20)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    assert counter == 20, f"Expected 20, got {counter}"

    # Consume 7 tokens
    await apb_write(dut, OFF_PAIR_TOKEN_CONSUME, 7)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After consuming 7: counter={counter}")
    assert counter == 13, f"Expected 13, got {counter}"

    # Consume 3 more
    await apb_write(dut, OFF_PAIR_TOKEN_CONSUME, 3)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After consuming 3 more: counter={counter}")
    assert counter == 10, f"Expected 10, got {counter}"


@cocotb.test()
async def test_ptc_04_read_has_no_side_effects(dut):
    """Reading the counter does NOT clear it (unlike accumulators)."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Add tokens
    await apb_write(dut, OFF_RELEASED_TOKENS, 42)
    await ClockCycles(dut.hclk, 2)

    # Read multiple times -- should return same value each time
    for i in range(3):
        counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
        dut._log.info(f"Read {i+1}: counter={counter}")
        assert counter == 42, f"Read {i+1}: expected 42, got {counter}"


@cocotb.test()
async def test_ptc_05_disable_freezes_counter(dut):
    """When disabled, counter ignores both increments and decrements."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Add 30 tokens while enabled
    await apb_write(dut, OFF_RELEASED_TOKENS, 30)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    assert counter == 30, f"Expected 30, got {counter}"

    # Disable the counter
    await apb_write(dut, OFF_PAIR_TOKEN_ENABLE, 0)
    await ClockCycles(dut.hclk, 2)

    enable = await apb_read(dut, OFF_PAIR_TOKEN_ENABLE)
    assert enable == 0, f"Enable should be 0, got {enable}"

    # Try to add tokens -- should be ignored
    await apb_write(dut, OFF_RELEASED_TOKENS, 100)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After disabled increment: counter={counter}")
    assert counter == 30, f"Counter should still be 30, got {counter}"

    # Try to consume tokens -- should be ignored
    await apb_write(dut, OFF_PAIR_TOKEN_CONSUME, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After disabled decrement: counter={counter}")
    assert counter == 30, f"Counter should still be 30, got {counter}"


@cocotb.test()
async def test_ptc_06_re_enable_resumes_counting(dut):
    """Re-enabling the counter allows increments/decrements again."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Add 50, disable, re-enable, add 25, consume 10
    await apb_write(dut, OFF_RELEASED_TOKENS, 50)
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_PAIR_TOKEN_ENABLE, 0)  # Disable
    await apb_write(dut, OFF_RELEASED_TOKENS, 999)  # Ignored
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_PAIR_TOKEN_ENABLE, 1)  # Re-enable
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_RELEASED_TOKENS, 25)
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_PAIR_TOKEN_CONSUME, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After disable/re-enable cycle: counter={counter}")
    assert counter == 65, f"Expected 50+25-10=65, got {counter}"


@cocotb.test()
async def test_ptc_07_accumulator_independent_of_counter(dut):
    """The released tokens accumulator (0x020) and pair token counter (0x028)
    are independent: reading the accumulator clears it but doesn't affect
    the counter."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Write tokens -- both accumulator and counter should increment
    await apb_write(dut, OFF_RELEASED_TOKENS, 100)
    await ClockCycles(dut.hclk, 2)

    acc     = await apb_read(dut, OFF_RELEASED_TOKENS)  # Read-to-clear
    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)

    dut._log.info(f"Accumulator (read-to-clear): {acc}")
    dut._log.info(f"Counter (persistent): {counter}")

    assert acc == 100, f"Accumulator should be 100, got {acc}"
    assert counter == 100, f"Counter should be 100, got {counter}"

    # After the read, accumulator should be cleared but counter should persist
    acc_after = await apb_read(dut, OFF_RELEASED_TOKENS)
    counter_after = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)

    dut._log.info(f"Accumulator after clear: {acc_after}")
    dut._log.info(f"Counter after acc clear: {counter_after}")

    assert acc_after == 0, f"Accumulator should be cleared, got {acc_after}"
    assert counter_after == 100, f"Counter should still be 100, got {counter_after}"


@cocotb.test()
async def test_ptc_08_end_to_end_with_fifo_writes(dut):
    """Write packets into the FIFO, read them back (releasing tokens),
    verify the pair token counter tracks the released tokens that
    arrive from the pair's returner."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)
    await ClockCycles(dut.hclk, 2)

    # Write 2 packets
    await fifo_write_packet(dut, [0xAA, 0xBB, 0xCC])      # 4 tokens
    await fifo_write_packet(dut, [0x11, 0x22])              # 3 tokens
    await ClockCycles(dut.hclk, 20)

    # The write completions send deltas to the pair's accumulator (0x020)
    dut._log.info(f"Pair accumulated from writes: {pair.released_tokens_acc}")

    # Now simulate the pair releasing those tokens back to us
    await apb_write(dut, OFF_RELEASED_TOKENS, 4)
    await apb_write(dut, OFF_RELEASED_TOKENS, 3)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"Pair token counter after receiving 4+3: {counter}")
    assert counter == 7, f"Expected 7, got {counter}"

    # CPU consumes 5 tokens from pair
    await apb_write(dut, OFF_PAIR_TOKEN_CONSUME, 5)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_TOKEN_COUNTER)
    dut._log.info(f"After consuming 5: counter={counter}")
    assert counter == 2, f"Expected 2, got {counter}"
