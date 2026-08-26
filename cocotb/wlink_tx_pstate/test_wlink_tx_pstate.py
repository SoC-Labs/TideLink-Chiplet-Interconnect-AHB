"""WlinkTxPstateCtrl -- the Wlink TX power-state controller.

WHY (2026-08-26)
    FSM 0.00%: 1 of 3 states, 0 of 4 transitions, in ALL 42 coverage databases
    that contain the module.  It has never changed state in any simulation in
    this repository.

    It is armed in silicon.  swi_delay_cycles resets to 16'h6a4 (1700) and
    Wlink.v:1702 assigns `phy_link_tx_tx_en = txpstate_io_tx_en`, i.e. the
    inverse of this FSM's req_pstate.  So 1700 idle cycles after the last
    packet, this block:
      1. backpressures the upstream TX path  (auto_in_advance forced to 0),
      2. hijacks the outgoing packet stream and injects PREQ packets,
      3. DROPS THE PHY TX ENABLE, and holds it low until new traffic arrives.
    Every existing bench either keeps the link busy or finishes well before
    1700 quiet cycles, so none of that has ever run.

    The tests below shorten the timeout so the sequence fits in a unit bench,
    and then test_05 asserts the SHIPPING reset value separately -- without
    that, a shortened timeout would be the only thing linking these results to
    silicon, and the link would be "the number I chose".

FSM (LinkLayer.scala 169):
    0 IDLE      count down; auto_in_sop reloads count to swi_delay_cycles
    1 SEND_PREQ count up while auto_out_advance; leaves at swi_num_preq_send
    2 POST      req_pstate set => io_tx_en low; returns to IDLE on new traffic

RED PROOF is in the commit message; the mutations are to
deps/axi-chiplet-controller/logical/wlink/WlinkTxPstateCtrl.v, restored and
verified afterwards.

Copyright 2026, SoC Labs (www.soclabs.org)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

CLK_NS = 10

ST_IDLE, ST_SEND_PREQ, ST_POST = 0, 1, 2

# Shipping reset values, from deps/.../wlink/Wlink.v:2082/2089/2096.
SHIPPING_DELAY_CYCLES = 0x06A4      # 1700
SHIPPING_NUM_PREQ = 1
SHIPPING_CYCLES_POST_PREQ = 0xFF

DELAY = 8                            # short timeout for the bench
POST_CYCLES = 4                      # short swi_cycles_post_preq for the bench
PREQ_DATA_ID = 0xA7


def _i(sig):
    v = sig.value
    if v.is_resolvable:
        return int(v)
    raise AssertionError(f"{sig._name} unresolvable: {v!r}")


async def bringup(dut, delay=DELAY, num_preq=1, post=POST_CYCLES):
    cocotb.start_soon(Clock(dut.clock, CLK_NS, units="ns").start())
    dut.reset.value = 1
    dut.auto_in_sop.value = 0
    dut.auto_in_data_id.value = 0x11
    dut.auto_in_word_count.value = 0x2222
    dut.auto_in_data.value = 0
    dut.auto_in_crc.value = 0x3333
    dut.auto_out_advance.value = 1
    dut.io_swi_delay_cycles.value = delay
    dut.io_swi_num_preq_send.value = num_preq
    dut.io_swi_preq_data_id.value = PREQ_DATA_ID
    dut.io_swi_cycles_post_preq.value = post
    dut.io_tx_ready.value = 1
    await ClockCycles(dut.clock, 3)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


async def pulse_sop(dut):
    """One upstream packet start, which reloads the idle timer."""
    await RisingEdge(dut.clock)
    dut.auto_in_sop.value = 1
    await RisingEdge(dut.clock)
    dut.auto_in_sop.value = 0


PROBE = ("io_state_o", "io_tx_en", "auto_in_advance", "auto_out_advance",
         "auto_out_data_id", "auto_out_word_count", "auto_out_sop")


async def snapshot(dut):
    """Sample every probed output in the settled ReadOnly phase of one cycle,
    then leave ReadOnly so the caller can drive again.

    Returning a snapshot rather than leaving the caller in ReadOnly is not
    style: cocotb raises "awaiting ReadOnly in ReadOnly phase" if a helper
    returns from inside it, and "Attempting settings a value during the
    ReadOnly phase" if the caller then drives.  Both happened here first.
    """
    await ReadOnly()
    snap = {n: _i(getattr(dut, n)) for n in PROBE}
    await RisingEdge(dut.clock)
    return snap


async def wait_tx_en(dut, want, limit=64):
    """Wait for io_tx_en == want.  Returns (cycles_waited, snapshot).

    io_tx_en does NOT change in the cycle POST is entered: req_pstate is
    registered off `(state == 2'h2) & ((count == 0) | req_pstate)`, and count
    is loaded with swi_cycles_post_preq on entry, so the PHY TX enable drops
    swi_cycles_post_preq cycles LATER.  Asserting on the entry cycle reads
    io_tx_en still high and looks like the transition never happened.
    """
    for n in range(limit):
        await ReadOnly()
        snap = {k: _i(getattr(dut, k)) for k in PROBE}
        await RisingEdge(dut.clock)
        if snap["io_tx_en"] == want:
            return n, snap
    raise AssertionError(
        f"io_tx_en never reached {want} within {limit} cycles "
        f"(state {snap['io_state_o']})")


async def wait_state(dut, want, limit=400):
    """Wait for io_state_o == want.  Returns (cycles_waited, snapshot).

    The snapshot is taken IN the cycle the state matched, so a test can assert
    on outputs at the moment of the transition even though the helper has
    advanced past it by the time it returns.
    """
    for n in range(limit):
        await ReadOnly()
        snap = {k: _i(getattr(dut, k)) for k in PROBE}
        await RisingEdge(dut.clock)
        if snap["io_state_o"] == want:
            return n, snap
    raise AssertionError(
        f"FSM never reached state {want}; last seen {snap['io_state_o']} "
        f"after {limit} cycles")


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_01_idle_timeout_enters_preq_and_backpressures_upstream(dut):
    """After swi_delay_cycles of quiet, the FSM enters SEND_PREQ.

    Asserts the two things that actually reach the rest of the chip, not just
    the state number: the upstream TX path is backpressured (auto_in_advance
    forced low regardless of auto_out_advance) and the outgoing packet stream
    is replaced by the configured PREQ.  A state change with the datapath left
    alone would be harmless; this is not that.
    """
    await bringup(dut)
    await pulse_sop(dut)               # arm the timer at a known point

    took, snap = await wait_state(dut, ST_SEND_PREQ)
    dut._log.info(f"entered SEND_PREQ after {took} idle cycles (delay={DELAY})")

    assert snap["auto_in_advance"] == 0, (
        "upstream TX path must be backpressured while the PREQ is injected "
        "(auto_out_advance is high, so this can only come from pstate_ctrl)")
    assert snap["auto_out_data_id"] == PREQ_DATA_ID, (
        f"outgoing packet must carry the PREQ data_id {PREQ_DATA_ID:#04x}, "
        f"got {snap['auto_out_data_id']:#04x}")
    assert snap["auto_out_word_count"] == 0, \
        "an injected PREQ must have word_count 0"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_02_preq_sent_then_post_drops_phy_tx_enable(dut):
    """SEND_PREQ -> POST, and POST drops io_tx_en.

    io_tx_en is `phy_link_tx_tx_en` at Wlink.v:1702 -- this transition turns
    the PHY transmitter off.  That is the consequence worth having a test for.
    """
    await bringup(dut, num_preq=2)
    await pulse_sop(dut)
    _n, preq = await wait_state(dut, ST_SEND_PREQ)
    assert preq["io_tx_en"] == 1, "PHY TX must still be enabled while sending PREQ"

    _n, post = await wait_state(dut, ST_POST)
    n_off, off = await wait_tx_en(dut, 0, limit=POST_CYCLES + 8)
    assert off["io_state_o"] == ST_POST, \
        f"io_tx_en dropped in state {off['io_state_o']}, expected POST"
    assert n_off <= POST_CYCLES + 2, (
        f"io_tx_en took {n_off} cycles to drop after entering POST; "
        f"swi_cycles_post_preq is {POST_CYCLES}")


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_03_new_traffic_returns_to_idle_and_restores_tx_enable(dut):
    """POST -> IDLE on new upstream traffic, and the PHY TX enable comes back.

    A PASSING ESCAPE TEST IS NOT A SAFETY TEST.  The valuable half here is not
    that the FSM can enter the power-down state -- it is that it LEAVES it and
    that io_tx_en and auto_in_advance both return to their working values, so
    a link that went quiet can carry traffic again.
    """
    await bringup(dut, num_preq=1)
    await pulse_sop(dut)
    await wait_state(dut, ST_SEND_PREQ)
    await wait_state(dut, ST_POST)
    await wait_tx_en(dut, 0, limit=POST_CYCLES + 8)   # precondition: PHY TX is off

    # The PHY reports it has finished shutting down, then traffic arrives.
    dut.io_tx_ready.value = 0
    await pulse_sop(dut)
    await wait_state(dut, ST_IDLE)

    dut.io_tx_ready.value = 1
    await ClockCycles(dut.clock, 3)
    back = await snapshot(dut)
    assert back["io_tx_en"] == 1, \
        "io_tx_en must be restored once the FSM is back in IDLE"
    assert back["auto_in_advance"] == back["auto_out_advance"], \
        "upstream backpressure must be released once back in IDLE"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_04_traffic_within_the_window_prevents_pstate_entry(dut):
    """A busy link never enters the power-state sequence.

    The control for test_01.  Without it, a controller that entered SEND_PREQ
    unconditionally -- disabling the PHY under live traffic -- would pass every
    other test in this file.
    """
    await bringup(dut)

    for _ in range(6):
        await pulse_sop(dut)
        await ClockCycles(dut.clock, DELAY - 3)
        snap = await snapshot(dut)
        assert snap["io_state_o"] == ST_IDLE, (
            f"FSM left IDLE while traffic was still arriving inside the "
            f"{DELAY}-cycle window (state {snap['io_state_o']})")
        assert snap["io_tx_en"] == 1, "PHY TX dropped under live traffic"


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_05_shipping_reset_value_arms_the_timeout(dut):
    """swi_delay_cycles = 0 disables entry; the SHIPPING reset value does not.

    LinkLayer.scala gates entry on `count == 0 & |io_swi_delay_cycles`, so zero
    is the disable.  Wlink.v:2082 resets the register to 16'h6a4 = 1700, which
    is non-zero -- the idle timeout is ARMED OUT OF RESET in silicon, with no
    firmware write required.  This test pins both halves of that, so the short
    DELAY the other tests use cannot quietly become the thing being claimed.
    """
    assert SHIPPING_DELAY_CYCLES != 0, \
        "shipping reset value would disable the timeout -- update this test"

    # Zero: the disable.
    await bringup(dut, delay=0)
    await pulse_sop(dut)
    await ClockCycles(dut.clock, 300)
    off = await snapshot(dut)
    assert off["io_state_o"] == ST_IDLE, \
        "swi_delay_cycles=0 must disable power-state entry entirely"
    assert off["io_tx_en"] == 1, "PHY TX must stay enabled when disabled by config"

    # Non-zero, the shipping shape: entry happens on its own.
    dut.io_swi_delay_cycles.value = DELAY
    await pulse_sop(dut)
    took, _snap = await wait_state(dut, ST_SEND_PREQ)
    assert took <= DELAY + 4, (
        f"entry took {took} cycles for a {DELAY}-cycle timeout -- the timer is "
        f"not counting what the register says")
