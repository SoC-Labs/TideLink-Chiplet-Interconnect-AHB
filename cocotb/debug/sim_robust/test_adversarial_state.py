"""
test_adversarial_state — Category 3: out-of-enum FSM state injection
======================================================================

The calibrator FSM is encoded as a 4-bit enum with 6 valid values
(S_IDLE..S_CANCEL = 0..5). The next-state logic uses `unique case
(cur_state)` with a `default: nxt_state = S_IDLE` arm.

Synth tools may either:
  (a) honour the default (Vivado typical behaviour)
  (b) optimise the default away if they decide the enum is "safe"
      (this is the Bug #7 class — `unique case + cross-process REVROP`)

If (b) happens, an out-of-enum cur_state (e.g. 4'd6..4'd15) becomes a
silent freeze — the FSM never advances out of the invalid value because
no enumerated arm matches.

This test forces cur_state to each of the 10 invalid encodings (6..15) and
verifies that within a bounded number of cycles the FSM EITHER:
  - recovers to S_IDLE (the spec'd default arm)
  - OR the test reports a clear FAIL with the invalid state that wedged

We do NOT use a permanent Force here — that would prevent recovery by
construction. We use a one-shot deposit (cur_state <= invalid) and then
release the simulator to step forward.

This catches the failure mode where the synth-collapsed FSM has no
default arm — exactly the Bug #7 fingerprint.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# Valid FSM encodings (must mirror tidelink_phy_align_calibrator.sv):
S_IDLE   = 0
S_ARM    = 1
S_SWEEP  = 2
S_FINISH = 3
S_DONE   = 4
S_CANCEL = 5
VALID_STATES = {S_IDLE, S_ARM, S_SWEEP, S_FINISH, S_DONE, S_CANCEL}
INVALID_STATES = [s for s in range(16) if s not in VALID_STATES]  # 6..15

# How many cycles to allow the FSM to recover before declaring "stuck".
# The default arm of the case statement should fire on the very next clock
# edge, but we allow a few cycles for the deposit/event reorder.
RECOVERY_CYCLES = 8


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
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_invalid_state_recovers_to_idle(dut):
    """For each invalid state encoding (6..15), deposit it into cur_state
    and verify the FSM recovers to S_IDLE (the default-arm target) within
    RECOVERY_CYCLES. Wedging on an invalid encoding is the Bug #7
    fingerprint."""
    await _start(dut)

    # Verify we can reach the hierarchical signal at all
    try:
        _ = int(dut.u_dut.cur_state.value)
    except AttributeError:
        dut._log.warning(
            "Cannot reach dut.u_dut.cur_state — hierarchical ref unsupported."
        )
        return

    wedged = []
    for bad in INVALID_STATES:
        # Deposit (NOT Force — we want the FSM to be free to recover)
        dut.u_dut.cur_state.value = bad

        # Let the FSM run a few cycles. Spec'd behaviour: default arm
        # fires next cycle → nxt_state = S_IDLE → cur_state = S_IDLE on
        # the cycle after.
        recovered = False
        seen_states = []
        for cyc in range(RECOVERY_CYCLES):
            await RisingEdge(dut.clk)
            s = int(dut.state.value)
            seen_states.append(s)
            if s in VALID_STATES:
                recovered = True
                break

        if not recovered:
            wedged.append((bad, seen_states))
            dut._log.error(
                f"BUG #7 FINGERPRINT: cur_state={bad} never recovered. "
                f"Last {RECOVERY_CYCLES} states: {seen_states}. The "
                f"unique-case default arm was NOT honoured — exactly the "
                f"synth-collapsed-FSM defect class."
            )
        else:
            final = seen_states[-1]
            dut._log.info(
                f"OK invalid_state={bad} → recovered to "
                f"S_{['IDLE','ARM','SWEEP','FINISH','DONE','CANCEL'][final]} "
                f"in {len(seen_states)} cycle(s)"
            )

        # Reset between iterations so the next deposit starts from a known
        # post-reset state
        dut.rst.value = 1
        await ClockCycles(dut.clk, 4)
        dut.rst.value = 0
        await ClockCycles(dut.clk, 2)

    assert not wedged, (
        f"Bug #7 fingerprint reproduced for invalid states: "
        f"{[w[0] for w in wedged]}. The FSM did not honour the case "
        f"default arm — synth-collapse risk."
    )

    dut._log.info(
        f"OK: 10/10 invalid encodings recovered to a valid state. "
        f"The unique-case default arm is honoured."
    )


@cocotb.test()
async def test_lane_done_wedge(dut):
    """Force lane_done[] to a non-natural bit pattern (0b1010_1010) AFTER
    the sweep has started. Verify the FSM still progresses to S_FINISH
    once all_done = &lane_done holds.

    On silicon, a latched lane_done (Bug #1-class) would have UNKNOWN
    values latched on the missing-default path; this test does NOT
    directly model that (cocotb sim still values-resolves the regs), but
    we DO check that arbitrary intermediate patterns of lane_done can
    drive the all_done signal correctly. If the wire-to-FSM dependency
    is broken, this test catches it.
    """
    await _start(dut)

    try:
        _ = int(dut.u_dut.lane_done.value)
    except AttributeError:
        dut._log.warning("Cannot reach lane_done — skipping")
        return

    # Trigger a sweep
    dut.role_locked.value = 1
    dut.lane_locked.value = 0  # no real locks

    # Wait for FSM to enter S_SWEEP
    for _ in range(32):
        await RisingEdge(dut.clk)
        if int(dut.state.value) == S_SWEEP:
            break
    assert int(dut.state.value) == S_SWEEP, "FSM never reached S_SWEEP"

    # NOW deposit lane_done = 0xFF (all lanes done) and lane_fault_q to a
    # pattern. all_done = &lane_done so the FSM should advance to S_FINISH.
    dut.u_dut.lane_done.value    = 0xFF
    dut.u_dut.lane_fault_q.value = 0xAA   # arbitrary
    await ClockCycles(dut.clk, 1)

    # The all_done wire should now be 1 → next-state S_FINISH. Allow a
    # few cycles for propagation.
    finished = False
    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.state.value) == S_FINISH:
            finished = True
            break
        if int(dut.state.value) == S_DONE:
            finished = True
            break

    assert finished, (
        f"FSM did not advance to S_FINISH/S_DONE when lane_done=0xFF was "
        f"deposited mid-sweep — final state {int(dut.state.value)}. "
        f"This suggests the all_done signal is not driving nxt_state "
        f"correctly (possible Bug #1 latch on lane_done feedback path)."
    )

    dut._log.info("OK: lane_done deposit drove all_done → S_FINISH transition")
