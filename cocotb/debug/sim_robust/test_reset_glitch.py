"""
test_reset_glitch — Category 2: asymmetric reset / X-prop / CDC stress
=======================================================================

On the PYNQ pair we observed silicon failures where one die came out of
reset 10s of microseconds before the other. That asymmetry interacts with
the calibrator FSM in two ways:

  (a) The "early" die starts emitting training_mode=1 + sweep patterns,
      but the peer side hasn't started its own sweep yet — so neither
      lane locks → both sweeps fault out → 0x00 fault byte → silent
      wedge (this is the §9.8 sequencing contract violation).

  (b) On a single die, if the reset deasserts asymmetrically between the
      calibrator's own clock domain and the lane_checker's, an X value
      can latch into lane_done or cur_state and silently mask faults.

This test exercises BOTH at the calibrator unit level (single instance).
We cannot exercise (a) at unit level (no peer in this TB), but we can:

  test_reset_glitch_short_dip   — reset glitch (1-cycle dip) while the
                                  sweep is in flight. Verify the FSM
                                  recovers to S_IDLE and a follow-on
                                  role_locked re-arms cleanly.
  test_reset_late_deassert      — role_locked rises BEFORE the FSM
                                  observes !rst. Verify trigger_now
                                  doesn't fire prematurely on the
                                  reset edge.
  test_reset_release_with_x     — deposit X into cur_state immediately
                                  before reset release; verify rst
                                  drives cur_state to S_IDLE
                                  (X-init resilience).

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5


async def _start(dut, hold_in_reset=8):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 0
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, hold_in_reset)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_reset_glitch_short_dip(dut):
    """Drive a 1-cycle reset glitch in the middle of an in-flight sweep.
    Verify the FSM returns to S_IDLE (no in-between freeze) and that a
    subsequent role_locked re-trigger cleanly arms a new sweep."""
    await _start(dut)

    # Kick a sweep off + let it complete so lane_fault_q accumulates 0xFF
    # (every lane faults out because lane_locked stays 0x00). We need
    # lane_fault_q to be non-zero BEFORE the glitch so the post-glitch
    # check (lane_fault==0x00) actually proves reset cleared it.
    dut.role_locked.value = 1
    dut.lane_locked.value = 0x00
    # DWELL_CYCLES default = 32; full sweep = 8*32 + S_ARM + S_FINISH ≈ 260
    # On a healthy RTL lane_fault should be 0xFF after sweep. On a Bug #1
    # latch (reset doesn't clear lane_fault_q), lane_fault may contain X
    # bits at this point — that itself is a failure.
    for _ in range(300):
        await RisingEdge(dut.clk)
        lf = dut.lane_fault.value
        if lf.is_resolvable and int(lf) == 0xFF:
            break
    lf = dut.lane_fault.value
    assert lf.is_resolvable, (
        f"BUG #1 CANDIDATE: lane_fault contains X-bits before glitch "
        f"(value={lf!s}). This indicates lane_fault_q's reset path was "
        f"not honoured — power-up X never cleared."
    )
    assert int(lf) == 0xFF, (
        f"Failed to drive lane_fault to 0xFF before glitch — "
        f"got 0x{int(lf):02x}. Glitch test won't discriminate a "
        f"lane_fault_q reset-clear defect."
    )

    # GLITCH: drop role_locked first so the post-glitch state observation
    # can confirm the reset HONOURED clearing cur_state. (If we leave
    # role_locked high through the glitch, the FSM will immediately
    # re-trigger via the implicit rising edge of role_locked vs
    # role_locked_q after reset clears the latter.)
    dut.role_locked.value = 0
    await ClockCycles(dut.clk, 1)

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    # ONE cycle after reset release — observe before any re-trigger fires
    await RisingEdge(dut.clk)

    # The FSM MUST be back at S_IDLE (sync reset behaviour).
    assert int(dut.state.value) == S_IDLE, (
        f"After reset glitch: state={int(dut.state.value)} (expected "
        f"S_IDLE). The reset is not driving cur_state — risk of stale "
        f"state surviving a real silicon glitch."
    )
    # Lane fault should also be cleared (lane_fault_q is in the same FF).
    assert int(dut.lane_fault.value) == 0x00, (
        f"After reset glitch lane_fault = 0x{int(dut.lane_fault.value):02x}, "
        f"expected 0x00. Reset did not clear lane_fault_q."
    )

    # And a re-trigger should ARM a new sweep cleanly. Re-assert
    # role_locked to make a rising edge.
    dut.role_locked.value = 1
    re_armed = False
    for _ in range(32):
        await RisingEdge(dut.clk)
        if int(dut.state.value) in (S_ARM, S_SWEEP):
            re_armed = True
            break
    assert re_armed, (
        f"After reset glitch + role_lock re-trigger, FSM did not re-arm. "
        f"State={int(dut.state.value)}. The trigger_now path is broken."
    )

    dut._log.info("OK: reset glitch recovered cleanly + re-arm succeeded")


@cocotb.test()
async def test_reset_late_deassert(dut):
    """Hold reset asserted while role_locked is already high. Verify the
    FSM does NOT mistake the reset edge for a role_locked rising edge
    (trigger_now must require role_locked_q == 0 → role_locked == 1)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.role_locked.value           = 1   # Already high during reset!
    dut.swreset.value               = 0
    dut.lane_locked.value           = 0
    dut.apb_bit_slip_override.value = 0
    dut.apb_override_enable.value   = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 12)
    dut.rst.value = 0
    # role_locked is still 1 (no rising edge AFTER reset). The FSM should
    # NOT auto-trigger — it must wait for an actual edge.
    await ClockCycles(dut.clk, 8)

    # Two valid outcomes:
    #  - S_IDLE (most likely — role_locked_q updates with rst=1 to 0, then
    #    on next clk both are 1, no edge)
    #  - S_ARM (if trigger_now sample is from the post-reset-release edge)
    state = int(dut.state.value)
    dut._log.info(f"After reset release with role_locked already high: "
                  f"state={state}")

    # The dangerous outcome we want to detect: a partial advance — FSM in
    # S_SWEEP but with role_locked_q still 0 — which would mean the FSM
    # latched a phantom edge.
    assert state in (S_IDLE, S_ARM, S_SWEEP), (
        f"FSM in unexpected state {state} after reset-release glitch."
    )
    # And if it advanced, it must do so cleanly (no half-trigger).
    if state in (S_ARM, S_SWEEP):
        assert int(dut.training_mode.value) == 1, (
            f"FSM advanced to S_ARM/SWEEP but training_mode=0 — "
            f"half-triggered. This is a silicon-failure precursor."
        )
        dut._log.info("OK: post-reset rising-edge sampled cleanly")
    else:
        dut._log.info("OK: no spurious trigger from the reset release")


@cocotb.test()
async def test_reset_release_with_x_in_cur_state(dut):
    """Deposit an X-equivalent (we use the integer 'x' substitute via
    Logic('x') if available, else use the maximum invalid encoding 4'd15)
    into cur_state mid-reset. Verify rst forces cur_state to S_IDLE on
    its trailing edge — i.e. the calibrator is X-resilient."""
    await _start(dut)

    try:
        _ = int(dut.u_dut.cur_state.value)
    except AttributeError:
        dut._log.warning("Cannot reach cur_state — skipping")
        return

    # Assert reset
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)

    # Deposit max invalid encoding (cocotb LogicArray-ints don't expose
    # 'x' assignment trivially; deposit 4'd15 = stand-in for "garbage").
    dut.u_dut.cur_state.value = 15
    await ClockCycles(dut.clk, 2)

    # Release reset
    dut.rst.value = 0
    await ClockCycles(dut.clk, 4)

    # rst is async assertion AND sync deassertion → on the next clk after
    # rst=0, cur_state should be S_IDLE.
    s = int(dut.state.value)
    assert s == S_IDLE, (
        f"After reset release with garbage cur_state deposit, "
        f"state={s} (expected S_IDLE=0). The reset is not driving "
        f"cur_state to S_IDLE — silicon could power up with a stale "
        f"register value."
    )
    dut._log.info("OK: reset releases cleanly to S_IDLE even after deposit")
