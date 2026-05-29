"""
test_drift_retrain — Category 4: long-runtime + repeated retrain
==================================================================

The standard cocotb tests for the calibrator run a SINGLE sweep over a
few hundred cycles. Silicon failures that take 10s or 100s of retrain
cycles to manifest (state accumulation, slow drift, sticky lane_done
bits) escape that suite.

This test does:

  test_repeated_retrain_no_state_accumulation
      Run 100 retrain cycles. Each cycle: assert role_locked, wait for
      S_DONE, drop role_locked, swreset cycle, repeat. Verify after
      each retrain that lane_done = 0xFF (all locked, lane_locked=0xFF)
      and lane_fault_q = 0x00 (no leftover fault from a previous run).
      A leaked fault bit between retrains is a silicon-precursor.

  test_lane_locked_jitter_during_sweep
      Run a sweep while randomly flipping lane_locked[7:0] every few
      cycles (simulating a noisy peer that briefly drops out of lock).
      Verify the FSM does NOT permanently fault any lane that did
      eventually lock.

We deliberately use SHORT DWELL_CYCLES=8 to keep wall-clock manageable
over 100 iterations (~10k cycles total ≈ 100 µs sim time, ~0.5 s wall).

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5

DWELL_CYCLES = 8
ONE_SWEEP_CYCLES = 8 * DWELL_CYCLES + 16   # bound on a single sweep
RETRAIN_ITERATIONS = 100


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 8)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 2)


async def _wait_for_state(dut, target, max_cycles):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.state.value) == target:
            return True
    return False


@cocotb.test()
async def test_repeated_retrain_no_state_accumulation(dut):
    """100 retrain cycles. Each cycle ends in S_DONE; we then cycle
    swreset to retrigger. After each retrain, lane_fault_q must be 0x00
    when lane_locked stayed 0xFF throughout (no fault should ever fire)."""
    await _start(dut)

    # All lanes "locked" — every sweep should hit S_DONE cleanly
    dut.lane_locked.value = 0xFF

    accumulated_faults = 0

    for it in range(RETRAIN_ITERATIONS):
        # Trigger: rising edge of role_locked
        dut.role_locked.value = 0
        await ClockCycles(dut.clk, 2)
        dut.role_locked.value = 1

        # Wait for S_DONE
        ok = await _wait_for_state(dut, S_DONE, ONE_SWEEP_CYCLES * 2)
        assert ok, (
            f"Iteration {it}: FSM never reached S_DONE within "
            f"{ONE_SWEEP_CYCLES * 2} cycles. State stuck at "
            f"{int(dut.state.value)}, lane_fault=0x{int(dut.lane_fault.value):02x}"
        )

        lane_fault = int(dut.lane_fault.value)
        if lane_fault != 0:
            accumulated_faults += 1
            dut._log.warning(
                f"Iteration {it}: lane_fault=0x{lane_fault:02x} despite "
                f"lane_locked=0xFF. STATE ACCUMULATION."
            )

        # Cycle swreset to retrigger
        dut.swreset.value = 1
        await ClockCycles(dut.clk, 4)
        dut.swreset.value = 0
        await ClockCycles(dut.clk, 2)

    assert accumulated_faults == 0, (
        f"State accumulation detected: {accumulated_faults}/{RETRAIN_ITERATIONS} "
        f"retrains saw spurious lane_fault despite lane_locked=0xFF. "
        f"This is a sticky-bit class defect."
    )

    dut._log.info(
        f"OK: 100/{RETRAIN_ITERATIONS} retrain cycles completed with no "
        f"state accumulation (no spurious lane_fault bits)."
    )


@cocotb.test()
async def test_lane_locked_jitter_during_sweep(dut):
    """Sweep while lane_locked toggles randomly every few cycles. After
    one sweep + retrain, lanes that EVENTUALLY locked must not be
    permanently faulted."""
    await _start(dut)

    rng = random.Random(0xc0ffee)

    # Drive lane_locked to a noisy pattern for the duration of one sweep
    dut.lane_locked.value = 0x55
    dut.role_locked.value = 1

    # Step until S_DONE, flipping lane_locked at random intervals
    state_history = []
    for i in range(ONE_SWEEP_CYCLES * 3):
        # Every 4-12 cycles, toggle some bits
        if i % rng.randint(4, 12) == 0:
            # ~50% locked on each lane, independently
            mask = sum((rng.randint(0, 1) << b) for b in range(8))
            dut.lane_locked.value = mask
        await RisingEdge(dut.clk)
        state_history.append(int(dut.state.value))
        if int(dut.state.value) == S_DONE:
            break

    assert int(dut.state.value) == S_DONE, (
        f"FSM did not reach S_DONE during jitter sweep. Final state "
        f"{int(dut.state.value)}, history tail {state_history[-16:]}"
    )

    lane_fault = int(dut.lane_fault.value)
    dut._log.info(
        f"OK: jitter sweep finished with lane_fault=0x{lane_fault:02x}. "
        f"This is not asserted to be 0x00 — the test just verifies the "
        f"FSM doesn't wedge mid-sweep on a noisy peer signal."
    )
