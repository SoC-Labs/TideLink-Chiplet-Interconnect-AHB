"""
test_t3a_timeout — pin the WavD2DGpioRx T3a MAX_HUNT timeout fallback.

The T3a hunt FSM (USE_T3A=1) has a bounded MAX_HUNT cycle budget after
S_SETTLE before falling through to S_LOCKED with NO slip applied. From
WavD2DGpioRx.v:

    S_HUNT: begin
      if (match_any) begin
        slip_amt    <= match_rot;
        do_slip     <= 1'b1;
        align_state <= S_LOCKED;
      end else if (hunt_cnt == MAX_HUNT) begin
        // Time-out: leave count alone, fall through to LOCKED.
        slip_amt    <= 3'd0;
        do_slip     <= 1'b0;
        align_state <= S_LOCKED;
      end else begin
        hunt_cnt <= hunt_cnt + 10'd1;
      end
    end

The contract under test (silent-peer graceful degradation):
  * If the peer is silent (io_pad held at a constant non-training value),
    the FSM still reaches S_LOCKED after SETTLE_CYCLES + MAX_HUNT cycles
    (no hang).
  * `count` free-runs from where it was — `do_slip` stays 0 throughout.
  * io_link_data is whatever the deserialiser captures from the steady
    input (0x0000 for the steady-0 silent stream).

This is the staggered-bring-up case: the peer (slave) is in POR for
milliseconds while master comes up. If MAX_HUNT or the timeout branch
were broken, the master's RX would livelock in S_HUNT, or assert a
spurious slip on the silent input. Either is a regression that breaks
staggered bring-up — which is exactly the FPGA scenario the T3a fix
was designed to harden.

This test complements cocotb/wavd2d_gpiorx_t3a/ (which proves the slip-
on-match path works across 8 lanes × multiple skews) by proving the
peer-silent fallback works.

Why a single-lane TB (not the 8-lane array): cocotb 2.0 + VCS 2022.06
exposes `generate for (lane = 0; lane < 8; ...) begin : g_lane` as a
HierarchyArrayObject whose `g_lane[N].u_dut` child names confuse cocotb's
`_discover_all` (it raises ValueError on the bracketed sub-path). A
single-instance TB sidesteps that — `u_dut.g_t3a_realign.align_state`
is a flat hierarchical path.

Invocation:
    cd /home/dam1n19/td_idelay_wt && source set_env.sh
    rm -rf cocotb/wavd2d_gpiorx_t3a_timeout/sim_build
    make -C cocotb/wavd2d_gpiorx_t3a_timeout

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors
  David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# Same constants as the RTL.
SETTLE_CYCLES = 64
MAX_HUNT      = 1023
# Total cycles of silent-peer input before the FSM MUST have fallen through
# to S_LOCKED via the MAX_HUNT timeout. Comfortable margin past the worst
# case (SETTLE + MAX_HUNT).
TIMEOUT_BOUND = SETTLE_CYCLES + MAX_HUNT + 64

# Mirror of the RTL localparams (must match WavD2DGpioRx.v):
S_SETTLE = 0
S_HUNT   = 1
S_LOCKED = 2


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.io_pad_clk, 10, unit="ns").start())


@cocotb.test()
async def test_t3a_timeout_to_locked_on_silent_peer(dut):
    """Silent-peer fallback: io_pad steady 0 (not a rotation of any
    TRAINING_BYTE since popcount(0x00)=0 and popcount(0xA3)=4). FSM must
    reach S_LOCKED via MAX_HUNT, NOT hang in S_HUNT, NOT assert slip.
    """
    await _start_clock(dut)

    # POR + silent input; let the clock advance a bit before deasserting POR.
    dut.io_por_reset.value = 1
    dut.io_pad.value = 0
    await ClockCycles(dut.io_pad_clk, 8)

    # Confirm initial state. align_state should be S_SETTLE during POR
    # (sync reset in the FSM clears it to S_SETTLE).
    state = int(dut.u_dut["g_t3a_realign.align_state"].value)
    dut._log.info(
        f"align_state during POR = {state} (expect S_SETTLE={S_SETTLE})"
    )
    assert state == S_SETTLE, (
        f"align_state during io_por_reset=1 is {state}, expected "
        f"S_SETTLE ({S_SETTLE}). The async-reset arm of the FSM "
        f"is broken — the timeout test's preconditions don't hold."
    )

    # Deassert POR; drive silent stream long enough to exit via timeout.
    dut.io_por_reset.value = 0
    for _ in range(TIMEOUT_BOUND):
        await RisingEdge(dut.io_pad_clk)

    state = int(dut.u_dut["g_t3a_realign.align_state"].value)
    dut._log.info(
        f"align_state after SETTLE+MAX_HUNT+margin of silent peer = {state}"
    )
    assert state == S_LOCKED, (
        f"align_state = {state}, expected S_LOCKED ({S_LOCKED}) after "
        f"{TIMEOUT_BOUND} pad_clks of a silent peer. The MAX_HUNT timeout "
        f"fallback is broken — the FSM is hung in S_HUNT (1) or "
        f"S_SETTLE (0). Staggered bring-up would livelock if the peer is "
        f"in POR longer than MAX_HUNT pad_clk periods."
    )

    # Also check do_slip stayed low — the timeout arm explicitly sets
    # slip_amt=0, do_slip=0. If the FSM had erroneously asserted slip on
    # the silent input, do_slip would be 1 here (it's a registered signal
    # that holds for one cycle; we sample right after the transition).
    do_slip = int(dut.u_dut["g_t3a_realign.do_slip"].value)
    slip_amt = int(dut.u_dut["g_t3a_realign.slip_amt"].value)
    dut._log.info(f"do_slip after timeout = {do_slip}, slip_amt = {slip_amt}")
    assert do_slip == 0, (
        f"do_slip = {do_slip} after timeout, expected 0. The FSM asserted "
        f"a spurious slip pulse on a silent input. count is now offset by "
        f"slip_amt={slip_amt} — corruption."
    )
    assert slip_amt == 0, (
        f"slip_amt = {slip_amt} after timeout, expected 0. The timeout "
        f"arm leaked a non-zero slip into the next cycle."
    )

    # Sanity: deserialised io_link_data must be 0x0000 (steady-0 input
    # produces an all-zero word). If the timeout path corrupted count or
    # the deserialiser, this would be non-zero.
    word = int(dut.io_link_data.value)
    dut._log.info(
        f"io_link_data after timeout = 0x{word:04X} "
        f"(expect 0x0000 for steady-0 input)"
    )
    assert word == 0x0000, (
        f"io_link_data = 0x{word:04X}, expected 0x0000 for steady-0 "
        f"silent peer. The deserialiser saw something other than 0 — "
        f"either the timeout asserted a spurious slip or the capture "
        f"chain is broken."
    )

    dut._log.info(
        "OK: T3a MAX_HUNT timeout reached S_LOCKED on silent peer "
        "without spurious slip — staggered bring-up will not livelock."
    )
