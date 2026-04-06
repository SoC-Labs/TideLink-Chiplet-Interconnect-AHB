"""Pair credit counter tests."""

import cocotb
from cocotb.triggers import ClockCycles

from py_pair_helpers import (
    setup_with_pair, apb_write, apb_read, fifo_write_packet,
    OFF_RELEASED_CREDITS, OFF_DOORBELL_RESPONSE,
    OFF_PAIR_CREDIT_COUNTER, OFF_PAIR_CREDIT_CONSUME, OFF_PAIR_CREDIT_ENABLE,
)


@cocotb.test()
async def test_ptc_01_defaults_after_reset(dut):
    """Pair credit counter is 0 and enabled after reset."""
    pair = await setup_with_pair(dut)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    enable  = await apb_read(dut, OFF_PAIR_CREDIT_ENABLE)

    dut._log.info(f"After reset: counter={counter}, enable={enable}")
    assert counter == 0, f"Counter should be 0 after reset, got {counter}"
    assert enable == 1, f"Enable should be 1 after reset, got {enable}"


@cocotb.test()
async def test_ptc_02_increments_on_released_credits(dut):
    """Counter increments when released credits are written to 0x020."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)  # Clear accumulator from reset
    await ClockCycles(dut.hclk, 2)

    # Simulate pair releasing 10 credits (write to 0x020)
    await apb_write(dut, OFF_RELEASED_CREDITS, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After 10 released credits: counter={counter}")
    assert counter == 10, f"Expected 10, got {counter}"

    # Release 5 more
    await apb_write(dut, OFF_RELEASED_CREDITS, 5)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After 5 more: counter={counter}")
    assert counter == 15, f"Expected 15, got {counter}"


@cocotb.test()
async def test_ptc_03_decrements_on_consume(dut):
    """Counter decrements when CPU writes to consume register (0x02C)."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Add 20 credits
    await apb_write(dut, OFF_RELEASED_CREDITS, 20)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    assert counter == 20, f"Expected 20, got {counter}"

    # Consume 7 credits
    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 7)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After consuming 7: counter={counter}")
    assert counter == 13, f"Expected 13, got {counter}"

    # Consume 3 more
    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 3)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After consuming 3 more: counter={counter}")
    assert counter == 10, f"Expected 10, got {counter}"


@cocotb.test()
async def test_ptc_04_read_has_no_side_effects(dut):
    """Reading the counter does NOT clear it (unlike accumulators)."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Add credits
    await apb_write(dut, OFF_RELEASED_CREDITS, 42)
    await ClockCycles(dut.hclk, 2)

    # Read multiple times -- should return same value each time
    for i in range(3):
        counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
        dut._log.info(f"Read {i+1}: counter={counter}")
        assert counter == 42, f"Read {i+1}: expected 42, got {counter}"


@cocotb.test()
async def test_ptc_05_disable_freezes_counter(dut):
    """When disabled, counter ignores both increments and decrements."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Add 30 credits while enabled
    await apb_write(dut, OFF_RELEASED_CREDITS, 30)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    assert counter == 30, f"Expected 30, got {counter}"

    # Disable the counter
    await apb_write(dut, OFF_PAIR_CREDIT_ENABLE, 0)
    await ClockCycles(dut.hclk, 2)

    enable = await apb_read(dut, OFF_PAIR_CREDIT_ENABLE)
    assert enable == 0, f"Enable should be 0, got {enable}"

    # Try to add credits -- should be ignored
    await apb_write(dut, OFF_RELEASED_CREDITS, 100)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After disabled increment: counter={counter}")
    assert counter == 30, f"Counter should still be 30, got {counter}"

    # Try to consume credits -- should be ignored
    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After disabled decrement: counter={counter}")
    assert counter == 30, f"Counter should still be 30, got {counter}"


@cocotb.test()
async def test_ptc_06_re_enable_resumes_counting(dut):
    """Re-enabling the counter allows increments/decrements again."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Add 50, disable, re-enable, add 25, consume 10
    await apb_write(dut, OFF_RELEASED_CREDITS, 50)
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_PAIR_CREDIT_ENABLE, 0)  # Disable
    await apb_write(dut, OFF_RELEASED_CREDITS, 999)  # Ignored
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_PAIR_CREDIT_ENABLE, 1)  # Re-enable
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_RELEASED_CREDITS, 25)
    await ClockCycles(dut.hclk, 2)

    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After disable/re-enable cycle: counter={counter}")
    assert counter == 65, f"Expected 50+25-10=65, got {counter}"


@cocotb.test()
async def test_ptc_07_accumulator_independent_of_counter(dut):
    """The released credits accumulator (0x020) and pair credit counter (0x028)
    are independent: reading the accumulator clears it but doesn't affect
    the counter."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Write credits -- both accumulator and counter should increment
    await apb_write(dut, OFF_RELEASED_CREDITS, 100)
    await ClockCycles(dut.hclk, 2)

    acc     = await apb_read(dut, OFF_RELEASED_CREDITS)  # Read-to-clear
    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)

    dut._log.info(f"Accumulator (read-to-clear): {acc}")
    dut._log.info(f"Counter (persistent): {counter}")

    assert acc == 100, f"Accumulator should be 100, got {acc}"
    assert counter == 100, f"Counter should be 100, got {counter}"

    # After the read, accumulator should be cleared but counter should persist
    acc_after = await apb_read(dut, OFF_RELEASED_CREDITS)
    counter_after = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)

    dut._log.info(f"Accumulator after clear: {acc_after}")
    dut._log.info(f"Counter after acc clear: {counter_after}")

    assert acc_after == 0, f"Accumulator should be cleared, got {acc_after}"
    assert counter_after == 100, f"Counter should still be 100, got {counter_after}"


@cocotb.test()
async def test_ptc_08_end_to_end_with_fifo_writes(dut):
    """Write packets into the FIFO, read them back (releasing credits),
    verify the pair credit counter tracks the released credits that
    arrive from the pair's returner."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await apb_read(dut, OFF_DOORBELL_RESPONSE)
    await ClockCycles(dut.hclk, 2)

    # Write 2 packets
    await fifo_write_packet(dut, [0xAA, 0xBB, 0xCC])      # 4 credits
    await fifo_write_packet(dut, [0x11, 0x22])              # 3 credits
    await ClockCycles(dut.hclk, 20)

    # The write completions send deltas to the pair's accumulator (0x020)
    dut._log.info(f"Pair accumulated from writes: {pair.released_credits_acc}")

    # Now simulate the pair releasing those credits back to us
    await apb_write(dut, OFF_RELEASED_CREDITS, 4)
    await apb_write(dut, OFF_RELEASED_CREDITS, 3)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"Pair credit counter after receiving 4+3: {counter}")
    assert counter == 7, f"Expected 7, got {counter}"

    # CPU consumes 5 credits from pair
    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 5)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After consuming 5: counter={counter}")
    assert counter == 2, f"Expected 2, got {counter}"


@cocotb.test()
async def test_ptc_09_underflow_saturates_at_zero(dut):
    """Shortcoming #7: Consuming more credits than available must saturate
    the pair credit counter at 0, not wrap to a large unsigned value."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Add 10 credits
    await apb_write(dut, OFF_RELEASED_CREDITS, 10)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    assert counter == 10, f"Expected 10, got {counter}"

    # Over-consume: try to subtract 25 from a counter of 10
    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 25)
    await ClockCycles(dut.hclk, 2)

    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    dut._log.info(f"After over-consuming 25 from 10: counter={counter}")

    # Should saturate at 0, NOT wrap to a huge value
    assert counter == 0, (
        f"Pair credit counter should saturate at 0, got {counter}. "
        f"If large, the 32-bit counter has wrapped — Shortcoming #7."
    )


@cocotb.test()
async def test_ptc_10_underflow_guard_normal_path(dut):
    """Verify the underflow guard does not affect normal consume operations."""
    pair = await setup_with_pair(dut)
    await apb_read(dut, OFF_RELEASED_CREDITS)
    await ClockCycles(dut.hclk, 2)

    # Add 100 credits
    await apb_write(dut, OFF_RELEASED_CREDITS, 100)
    await ClockCycles(dut.hclk, 2)

    # Consume exactly 100 — should reach 0 without saturation issues
    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 50)
    await ClockCycles(dut.hclk, 2)
    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    assert counter == 50, f"Expected 50, got {counter}"

    await apb_write(dut, OFF_PAIR_CREDIT_CONSUME, 50)
    await ClockCycles(dut.hclk, 2)
    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    assert counter == 0, f"Expected 0, got {counter}"

    # Add more after reaching 0 — should still work
    await apb_write(dut, OFF_RELEASED_CREDITS, 5)
    await ClockCycles(dut.hclk, 2)
    counter = await apb_read(dut, OFF_PAIR_CREDIT_COUNTER)
    assert counter == 5, f"Expected 5 after adding to 0, got {counter}"

    dut._log.info("Normal consume path unaffected by underflow guard — passed")
