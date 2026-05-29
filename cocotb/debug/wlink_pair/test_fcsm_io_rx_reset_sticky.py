"""Regression: FCSM cr_pkt_seen_rx / crack_pkt_seen_rx are sticky against
io_rx_reset re-pulses (submodule commit 0e126b0).

Why this test exists
--------------------
On the FPGA platform `proc_sys_reset` re-pulses `io_rx_reset` repeatedly
until the clock wizard locks. The pre-0e126b0 RTL reset
`cr_pkt_seen_rx` / `crack_pkt_seen_rx` from `io_rx_reset` (and also
synchronously cleared them on `_fe_tx_credit_max_in_T =
~en_ff2_rx_demet_io_out`). Each io_rx_reset re-pulse therefore wiped an
already-latched cr_pkt_seen, so the master never registered the slave's
crack packet, the FC state machine wedged at state 1 (SEND_CREDITS1) and
`CURRENT_CREDITS` stayed at its 4096 default.

`0e126b0` changed both latches to reset only from the full-POR `reset`
and removed the `_fe_tx_credit_max_in_T` synchronous clear, so they are
sticky-once-set across io_rx_reset re-pulses.

The plain pair testbench never re-pulses io_rx_reset, so
`cocotb/phy_align/test_autocal_integrated.py` passes with or without
0e126b0. This test closes that coverage gap by *driving* the re-pulse
behaviour the FPGA exhibits, directly on the FCSM `io_rx_reset` port,
mid-simulation, after the latch has set.

DUT hierarchy (verified against TideLinkToWlink.v / Wlink.v):
  dut.u_<side>.u_wlink.tl2wl.wlink_tidelinktl
    .reset          <- Wlink apb_reset      (full-POR domain)
    .io_rx_reset    <- rx_link_clk_reset_wrs (the net proc_sys_reset
                                              re-pulses on FPGA)
    .io_rx_clk      <- phy_link_rx_rx_link_clk
    .cr_pkt_seen_rx / .crack_pkt_seen_rx / .state  (internal regs)

Invocation (from cocotb/wlink_pair/):
    rm -rf sim_build ../phy_align/sim_build
    make MODULE=test_fcsm_io_rx_reset_sticky SKID_BITS=3

Negative control (documented in the report): locally restore the
pre-0e126b0 always-blocks in
deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v,
`rm -rf cocotb/*/sim_build`, rerun — the test must FAIL (the re-pulse
wipes the latch and the FCSM falls back to state 1). Restore the file
and it passes again.
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge, ClockCycles

from test_link_bringup import setup, lock_master, lock_slave


# ---------------------------------------------------------------------------
# Calibrator force-enable. With SKID_BITS=3 the PHY is misaligned at boot;
# the in-RTL auto-cal FSM (gated by autocal_force_enable_q) must be turned
# on for any cr_pkt to ever reach the FCSM — exactly as
# test_autocal_integrated.py does. Without it cr_pkt_seen_rx never sets and
# there is nothing to test the stickiness of.
# ---------------------------------------------------------------------------
def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _force_autocal_enable(dut, side, on):
    _chiplet(dut, side).autocal_force_enable_q.value = 1 if on else 0


def _fcsm(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl.wlink_tidelinktl


async def _bring_up_until_cr_latched(dut, timeout_chunks=4000):
    """Boot + role-lock with the calibrator on, then poll until BOTH the
    master FCSM's cr_pkt_seen_rx AND crack_pkt_seen_rx have latched and
    the FCSM has left SEND_CREDITS1 (state >= 2). The credit handshake is
    a two-step latch (cr_pkt first, then peer crack); cr_pkt_seen_rx sets
    a few hundred ns before crack_pkt_seen_rx, so polling must wait for
    the *full* handshake before the stickiness phase can be meaningful."""
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")
    max_state_m = 0
    cr_latched = False
    crack_latched = False
    for _ in range(timeout_chunks):
        await ClockCycles(dut.master_clk, 25)
        max_state_m = max(max_state_m, int(m.state.value))
        if int(m.cr_pkt_seen_rx.value):
            cr_latched = True
        if int(m.crack_pkt_seen_rx.value):
            crack_latched = True
        if cr_latched and crack_latched and max_state_m >= 2:
            break
    return m, s, max_state_m, cr_latched


async def _pulse_io_rx_reset(dut, fcsm, n_pulses, high_cycles=4, low_cycles=8):
    """Force the FCSM io_rx_reset port HIGH for `high_cycles` rx-clk
    cycles, then LOW for `low_cycles`, `n_pulses` times — mimicking
    proc_sys_reset re-pulsing until clk_wiz locks. The FCSM's own
    io_rx_clk is used so the forced level is sampled coherently.
    full-POR `reset` is left untouched (deasserted) the whole time."""
    rx_clk = fcsm.io_rx_clk
    for i in range(n_pulses):
        fcsm.io_rx_reset.value = Force(1)
        for _ in range(high_cycles):
            await RisingEdge(rx_clk)
        fcsm.io_rx_reset.value = Force(0)
        for _ in range(low_cycles):
            await RisingEdge(rx_clk)
        dut._log.info(
            f"  io_rx_reset re-pulse #{i+1}/{n_pulses}: "
            f"cr_seen={int(fcsm.cr_pkt_seen_rx.value)} "
            f"crack_seen={int(fcsm.crack_pkt_seen_rx.value)} "
            f"state={int(fcsm.state.value)} "
            f"full_por_reset={int(fcsm.reset.value)}"
        )
    fcsm.io_rx_reset.value = Release()


@cocotb.test()
async def test_fcsm_io_rx_reset_sticky(dut):
    """cr_pkt_seen_rx / crack_pkt_seen_rx survive io_rx_reset re-pulses
    (0e126b0); a genuine full-POR reset still clears them."""
    m, s, max_state_m, cr_latched = await _bring_up_until_cr_latched(dut)

    crack_latched = int(m.crack_pkt_seen_rx.value) == 1
    dut._log.info(
        f"[setup] master FCSM max_state={max_state_m} "
        f"cr_pkt_seen_rx={int(m.cr_pkt_seen_rx.value)} "
        f"crack_pkt_seen_rx={int(m.crack_pkt_seen_rx.value)} "
        f"state={int(m.state.value)}"
    )
    # Preconditions: the credit handshake must actually have happened,
    # otherwise the stickiness assertion below would pass vacuously.
    assert cr_latched, (
        "PRECONDITION: master cr_pkt_seen_rx never latched during bring-up "
        "— credit path did not converge (autocal/PHY issue), cannot test "
        "io_rx_reset stickiness"
    )
    assert max_state_m >= 2, (
        f"PRECONDITION: master FCSM never advanced past SEND_CREDITS1 "
        f"(max_state={max_state_m}) — nothing to keep sticky"
    )
    assert crack_latched, (
        "PRECONDITION: master crack_pkt_seen_rx never latched — peer "
        "crack handshake did not complete; cannot test its stickiness"
    )
    assert int(m.reset.value) == 0, (
        "full-POR reset is asserted at the start of the re-pulse phase — "
        "test setup invalid"
    )

    # -------------------------------------------------------------------
    # Phase 1: re-pulse io_rx_reset several times (proc_sys_reset on FPGA)
    # while full-POR reset stays deasserted. The latches must NOT clear
    # and the FCSM must still be at >= state 2 (it left SEND_CREDITS1).
    # -------------------------------------------------------------------
    N_PULSES = 6
    await _pulse_io_rx_reset(dut, m, N_PULSES)

    # Let the FCSM run a little after the last re-pulse to prove it does
    # not regress to state 1 once io_rx_reset is released.
    for _ in range(40):
        await ClockCycles(dut.master_clk, 25)

    cr_after = int(m.cr_pkt_seen_rx.value)
    crack_after = int(m.crack_pkt_seen_rx.value)
    state_after = int(m.state.value)
    dut._log.info(
        f"[after {N_PULSES} io_rx_reset re-pulses] "
        f"cr_pkt_seen_rx={cr_after} crack_pkt_seen_rx={crack_after} "
        f"state={state_after}"
    )

    assert cr_after == 1, (
        f"cr_pkt_seen_rx was CLEARED by an io_rx_reset re-pulse "
        f"(now {cr_after}) while full-POR reset stayed deasserted — "
        f"the 0e126b0 sticky-latch fix is missing or reverted "
        f"(pre-0e126b0 RTL resets this from io_rx_reset)"
    )
    assert crack_after == 1, (
        f"crack_pkt_seen_rx was CLEARED by an io_rx_reset re-pulse "
        f"(now {crack_after}) — 0e126b0 sticky-latch fix missing/reverted"
    )
    assert state_after >= 2, (
        f"FCSM fell back to state {state_after} (< 2 = SEND_CREDITS1) "
        f"after io_rx_reset re-pulses — the credit-seen latch was wiped "
        f"so the FCSM no longer advances 1->2 (the exact FPGA wedge "
        f"0e126b0 fixes)"
    )
    dut._log.info(
        "OK: cr/crack_pkt_seen_rx survived io_rx_reset re-pulses and the "
        "FCSM stayed past SEND_CREDITS1 (1->2 advance held)"
    )

    # -------------------------------------------------------------------
    # Phase 2: a *genuine* full-POR reset on the FCSM must still clear
    # the latches (0e126b0 keeps full-POR as the legitimate clear path —
    # this proves the test is exercising real reset logic, not a tied-1).
    # -------------------------------------------------------------------
    rx_clk = m.io_rx_clk
    m.reset.value = Force(1)
    for _ in range(6):
        await RisingEdge(rx_clk)
    cr_in_por = int(m.cr_pkt_seen_rx.value)
    crack_in_por = int(m.crack_pkt_seen_rx.value)
    dut._log.info(
        f"[during full-POR reset] cr_pkt_seen_rx={cr_in_por} "
        f"crack_pkt_seen_rx={crack_in_por}"
    )
    m.reset.value = Release()

    assert cr_in_por == 0, (
        f"full-POR reset did NOT clear cr_pkt_seen_rx (still {cr_in_por}) "
        f"— the latch is stuck-at-1 / not wired to full-POR `reset`; the "
        f"Phase-1 result would then be vacuous"
    )
    assert crack_in_por == 0, (
        f"full-POR reset did NOT clear crack_pkt_seen_rx "
        f"(still {crack_in_por}) — latch not wired to full-POR `reset`"
    )
    dut._log.info(
        "OK: genuine full-POR reset cleared both latches — stickiness is "
        "specifically against io_rx_reset, not a stuck-at bit"
    )
