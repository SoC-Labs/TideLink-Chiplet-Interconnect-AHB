"""Verification-gap tests for paired TideLink system.

Covers four functional areas not exercised by the main test suite:
  1. IRQ-driven receive flow (packet_committed_irq)
  2. IRQ-driven credit release flow (released_credits_irq)
  3. Credit threshold sweep across boundary values
  4. Accumulator read/write race characterisation
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, First, Timer

from cocotbext.ahb import AHBBus, AHBLiteMaster

from tidelink.regs import (
    MAX_CREDITS,
    REG_CREDIT_COUNT, REG_DOORBELL, REG_REL_THRESHOLD,
    REG_RELEASED_ACC, REG_DOORBELL_RESP_ACC, REG_STATUS,
    REG_PAIR_CREDIT_COUNTER, REG_PAIR_CREDIT_ENABLE,
    STATUS_OVERRUN, STATUS_UNDERRUN,
)

# Re-use the driver and TB classes from the main test module
from test_tidelink_system import (
    TideLinkDriver, TideLinkSystemTB,
    CLK_PERIOD_NS,
)


# =============================================================================
# Helper: wait for an IRQ signal to assert with a timeout
# =============================================================================

async def wait_irq(dut, irq_signal, timeout_cycles=500):
    """Wait for *irq_signal* to go high.  Returns True on success,
    False on timeout."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.hclk)
        try:
            if int(irq_signal.value):
                return True
        except ValueError:
            pass
    return False


# =============================================================================
# Test 1 -- IRQ-driven receive flow
# =============================================================================

@cocotb.test()
async def test_irq_packet_committed(dut):
    """Send a 4-word packet A->B, wait for packet_committed_irq on B,
    then read the packet and verify the IRQ clears."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    data = [0xFACE_0001, 0xFACE_0002, 0xFACE_0003, 0xFACE_0004]

    # Confirm IRQ is deasserted before we start
    assert int(tb.b.packet_committed_irq.value) == 0, \
        "b_packet_committed_irq should be low before any traffic"

    # Send a 4-word packet from A to B
    await tb.a.tx_write_packet(data)

    # Wait for the IRQ rather than polling registers
    irq_ok = await wait_irq(dut, tb.b.packet_committed_irq, timeout_cycles=500)
    assert irq_ok, "b_packet_committed_irq did not assert within timeout"
    tb.log.info("b_packet_committed_irq asserted after packet arrival")

    # Read the packet from B's FIFO
    readback = await tb.b.fifo_read_packet()

    # Verify data integrity
    assert readback == data, \
        f"Data mismatch: expected {data}, got {readback}"
    tb.log.info(f"Packet data verified: {len(readback)} words correct")

    # Reading address 0 (the length word) should have cleared the committed
    # flag.  Allow a few cycles for the flag to propagate.
    await ClockCycles(dut.hclk, 10)

    irq_after = int(tb.b.packet_committed_irq.value)
    assert irq_after == 0, \
        "b_packet_committed_irq should deassert after FIFO read (addr 0)"
    tb.log.info("b_packet_committed_irq correctly deasserted after read")


# =============================================================================
# Test 2 -- IRQ-driven credit release flow
# =============================================================================

@cocotb.test()
async def test_irq_released_credits(dut):
    """Send a packet A->B, read on B (triggers credit release), then verify
    released_credits_irq fires on A and clears after reading RELEASED_ACC."""
    tb = TideLinkSystemTB(dut)
    await tb.reset()

    # Use immediate release threshold so credits come back quickly
    await tb.b.cfg_write(REG_REL_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 5)

    # Clear any stale accumulator value on A
    _ = await tb.a.cfg_read(REG_RELEASED_ACC)
    await ClockCycles(dut.hclk, 5)

    # Confirm A's released_credits_irq is low
    assert int(tb.a.released_credits_irq.value) == 0, \
        "a_released_credits_irq should be low before traffic"

    # A sends a 3-word packet to B (4 credits: 1 length + 3 data)
    data = [0xC0DE_0001, 0xC0DE_0002, 0xC0DE_0003]
    await tb.a.tx_write_packet(data)
    await tb.b.wait_fc_settle(30)

    # B reads the packet -- this triggers the returner to release credits
    readback = await tb.b.fifo_read_packet()
    assert readback == data, "Data mismatch on B side"

    # Wait for released_credits_irq on A
    irq_ok = await wait_irq(dut, tb.a.released_credits_irq, timeout_cycles=500)
    assert irq_ok, "a_released_credits_irq did not assert within timeout"
    tb.log.info("a_released_credits_irq asserted after credit return")

    # Read RELEASED_ACC on A -- this should return the accumulated value
    # and clear the IRQ
    released = await tb.a.cfg_read(REG_RELEASED_ACC)
    expected_credits = len(data) + 1  # 4 credits (length word + 3 data)
    tb.log.info(f"RELEASED_ACC on A = {released} (expected {expected_credits})")
    assert released == expected_credits, \
        f"Expected {expected_credits} released credits, got {released}"

    # Allow the IRQ to deassert after the read-clear
    await ClockCycles(dut.hclk, 10)
    irq_after = int(tb.a.released_credits_irq.value)
    assert irq_after == 0, \
        "a_released_credits_irq should deassert after reading RELEASED_ACC"
    tb.log.info("a_released_credits_irq correctly deasserted after ACC read")


# =============================================================================
# Test 3 -- Credit threshold sweep
# =============================================================================

@cocotb.test()
async def test_credit_threshold_sweep(dut):
    """Sweep four threshold values and verify credits return correctly
    for each: 0 (immediate), 1 (per-word), 20 (default), MAX_CREDITS/2."""
    tb = TideLinkSystemTB(dut)

    thresholds = [0, 1, 20, MAX_CREDITS // 2]

    for threshold in thresholds:
        tb.log.info(f"--- Threshold sweep: {threshold} ---")

        # Full reset between iterations to start from a clean state
        await tb.reset()

        # Configure both sides with the same threshold
        await tb.a.cfg_write(REG_REL_THRESHOLD, threshold)
        await tb.b.cfg_write(REG_REL_THRESHOLD, threshold)
        await ClockCycles(dut.hclk, 5)

        # Clear stale accumulators
        _ = await tb.a.cfg_read(REG_RELEASED_ACC)
        _ = await tb.b.cfg_read(REG_RELEASED_ACC)
        await ClockCycles(dut.hclk, 5)

        # A sends a 3-word packet to B
        data = [0xAAAA_0000 | threshold,
                0xBBBB_0000 | threshold,
                0xCCCC_0000 | threshold]
        credits_before = await tb.b.cfg_read(REG_CREDIT_COUNT)
        tb.log.info(f"  B credits before send: {credits_before}")

        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(30)

        credits_after_send = await tb.b.cfg_read(REG_CREDIT_COUNT)
        expected_after_send = credits_before - (len(data) + 1)
        tb.log.info(f"  B credits after send: {credits_after_send} "
                    f"(expected {expected_after_send})")
        assert credits_after_send == expected_after_send, \
            f"Threshold {threshold}: credit count after send mismatch"

        # B reads the packet
        readback = await tb.b.fifo_read_packet()
        assert readback == data, \
            f"Threshold {threshold}: data mismatch"

        # Wait long enough for credits to propagate back through FC
        # For large thresholds the credits may not release immediately,
        # so we check the final B credit count which should reflect
        # the local view.
        await ClockCycles(dut.hclk, 200)

        credits_final = await tb.b.cfg_read(REG_CREDIT_COUNT)
        tb.log.info(f"  B credits after read + settle: {credits_final}")

        # After a complete packet read, the read_complete signal flushes
        # the release accumulator via the returner regardless of threshold.
        # So credits should always be fully restored after read + settle,
        # even when the freed count is below the threshold value.
        # The threshold only affects mid-stream partial releases (e.g.
        # streaming reads that haven't completed the packet yet).
        assert credits_final == MAX_CREDITS, \
            f"Threshold {threshold}: expected full credit restoration " \
            f"after packet read, got {credits_final}"

        # Verify no error flags on either side
        status_a = await tb.a.cfg_read(REG_STATUS)
        status_b = await tb.b.cfg_read(REG_STATUS)
        assert (status_a & (1 << STATUS_OVERRUN)) == 0, \
            f"Threshold {threshold}: A overrun flag set"
        assert (status_a & (1 << STATUS_UNDERRUN)) == 0, \
            f"Threshold {threshold}: A underrun flag set"
        assert (status_b & (1 << STATUS_OVERRUN)) == 0, \
            f"Threshold {threshold}: B overrun flag set"
        assert (status_b & (1 << STATUS_UNDERRUN)) == 0, \
            f"Threshold {threshold}: B underrun flag set"
        tb.log.info(f"  Threshold {threshold}: PASS (no errors)")


# =============================================================================
# Test 4 -- Accumulator read/write race characterisation
# =============================================================================

@cocotb.test()
async def test_accumulator_race(dut):
    """Characterisation test: probe the race window between the returner
    writing to RELEASED_ACC and a CPU read of the same register.

    This test does NOT assert pass/fail -- it logs observed behaviour
    to help characterise the hardware arbitration.
    """
    tb = TideLinkSystemTB(dut)

    NUM_TRIALS = 5
    results = []

    for trial in range(NUM_TRIALS):
        tb.log.info(f"=== Accumulator race trial {trial} ===")

        # Fresh reset each trial
        await tb.reset()

        # Immediate release so credits come back quickly
        await tb.b.cfg_write(REG_REL_THRESHOLD, 0)
        await ClockCycles(dut.hclk, 5)

        # Clear stale accumulator
        _ = await tb.a.cfg_read(REG_RELEASED_ACC)
        await ClockCycles(dut.hclk, 5)

        # A sends a packet to B
        data = [0x4ACE_0000 | trial for _ in range(3)]
        await tb.a.tx_write_packet(data)
        await tb.b.wait_fc_settle(30)

        # B reads the packet -- triggers returner credit release
        _ = await tb.b.fifo_read_packet()

        # Now race: start the CPU read on A's RELEASED_ACC immediately,
        # while the returner's sideband credit is still in flight.
        # Vary the timing offset each trial to probe different windows.
        wait_cycles = trial * 5  # 0, 5, 10, 15, 20 cycles
        await ClockCycles(dut.hclk, wait_cycles)

        acc_value = await tb.a.cfg_read(REG_RELEASED_ACC)

        # Expected value if the write has landed: len(data)+1 = 4
        expected = len(data) + 1

        if acc_value == 0:
            outcome = "OLD (zero -- write not yet landed)"
        elif acc_value == expected:
            outcome = "NEW (full value -- write completed)"
        else:
            outcome = f"PARTIAL ({acc_value} -- unexpected intermediate)"

        tb.log.info(f"  Trial {trial} (wait={wait_cycles} cyc): "
                    f"RELEASED_ACC = {acc_value} -> {outcome}")
        results.append((trial, wait_cycles, acc_value, outcome))

    # Summarise all trials
    tb.log.info("=== Accumulator race characterisation summary ===")
    for trial, wait, val, outcome in results:
        tb.log.info(f"  Trial {trial}: wait={wait:3d} cyc, "
                    f"acc={val:5d}, {outcome}")
    tb.log.info("=== End characterisation (no pass/fail assertion) ===")
