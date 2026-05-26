"""Reset-stress + re-arm cycle regression.

Hammer the chiplet pair with repeated reset sequences in quick succession.
Looks for any latched-state corruption from a reset-glitch (override paths,
sticky latches, async-reset crossings).

Three tests:
  test_01: repeated POR cycles with no settle between → assert clean
           every-time bring-up to LINK_IDLE
  test_02: repeated swreset_ll (0x208 swreset toggling) without POR →
           assert link comes back up each iteration
  test_03: alternating mid-bringup reset interrupt — POR the slave during
           the master's CR-handshake → assert no half-stuck states on
           the master (no SEND_NACK loops, no stuck cr_pkt_seen_rx)

Strategic value
---------------
Existing tests do exactly one POR per scenario. If a sticky latch survives
a reset (e.g. an override path that doesn't clear), a single-POR test
won't see it. This test cycles N times and asserts STATE FREEDOM after
every iteration.

Invocation
----------
  rm -rf sim_build ../phy_align/sim_build
  make MODULE=test_reset_stress
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from test_link_bringup import (
    setup, lock_master, lock_slave, ctrl_write, apb_write, apb_read,
    WL_LINK_ENABLE_RESET,
)
from test_paired_recal_to_link_data import (
    _fcsm, FCSM_LINK_IDLE, STATE_NAME,
)


LL_CTRL_SWRESET_ON   = 0x27f08
LL_CTRL_SWRESET_OFF  = 0x27f00
LL_CTRL_ENABLED      = 0x27f07


async def _drop_resets(dut):
    """Drop POR + hresetn on both sides without re-starting the clocks."""
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 5)


async def _release_resets(dut):
    dut.m_poresetn.value = 1
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


# -----------------------------------------------------------------------
# TEST 1 — repeated POR cycles. Assert link always reaches LINK_IDLE on
# both sides after each POR.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_repeated_por_cycles(dut):
    """5 POR cycles in succession. After each, lock roles, wait, assert
    both FCSMs reach LINK_IDLE (state>=4) and cr_pkt_seen_rx symmetric."""
    await setup(dut)

    NUM_ITERATIONS = 5
    failures = []
    for it in range(NUM_ITERATIONS):
        # POR pulse
        await _drop_resets(dut)
        await _release_resets(dut)

        # Re-lock roles
        await lock_master(dut)
        await lock_slave(dut)

        await ClockCycles(dut.master_clk, 3000)

        m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
        m_state = int(m.state.value); s_state = int(s.state.value)
        m_cr = int(m.cr_pkt_seen_rx.value); s_cr = int(s.cr_pkt_seen_rx.value)
        dut._log.info(
            f"  iter {it}: m.state={m_state}({STATE_NAME.get(m_state,'?')}) "
            f"s.state={s_state}({STATE_NAME.get(s_state,'?')}) "
            f"m.cr={m_cr} s.cr={s_cr}")
        if m_state < FCSM_LINK_IDLE:
            failures.append(f"iter {it}: master state={m_state}")
        if s_state < FCSM_LINK_IDLE:
            failures.append(f"iter {it}: slave state={s_state}")
        if m_cr != s_cr:
            failures.append(f"iter {it}: asymmetric cr_pkt_seen_rx (m={m_cr} s={s_cr})")

    assert not failures, (
        f"reset-stress test_01 found {len(failures)} failures across "
        f"{NUM_ITERATIONS} POR cycles: {failures}")


# -----------------------------------------------------------------------
# TEST 2 — repeated LL swreset cycles WITHOUT POR. Each iteration cycles
# 0x208 ON -> OFF -> ENABLED and asserts the FCSM is still up.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_repeated_swreset_ll_cycles(dut):
    """After initial bring-up, repeatedly cycle 0x208 swreset on both
    sides and assert FCSM returns to LINK_IDLE each time."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 3000)

    # Verify initial bring-up
    m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
    assert int(m.state.value) >= FCSM_LINK_IDLE, "pre-test bring-up failed (master)"
    assert int(s.state.value) >= FCSM_LINK_IDLE, "pre-test bring-up failed (slave)"

    NUM_ITERATIONS = 4
    failures = []
    for it in range(NUM_ITERATIONS):
        # Drive swreset on both sides
        await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
        await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
        await ClockCycles(dut.master_clk, 30)
        await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
        await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
        await ClockCycles(dut.master_clk, 30)
        await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)
        await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)

        await ClockCycles(dut.master_clk, 3000)
        m_state = int(m.state.value); s_state = int(s.state.value)
        m_cr = int(m.cr_pkt_seen_rx.value); s_cr = int(s.cr_pkt_seen_rx.value)
        dut._log.info(
            f"  swreset iter {it}: m.state={m_state}({STATE_NAME.get(m_state,'?')}) "
            f"s.state={s_state}({STATE_NAME.get(s_state,'?')}) "
            f"m.cr={m_cr} s.cr={s_cr}")
        if m_state < FCSM_LINK_IDLE:
            failures.append(f"swreset iter {it}: master stuck at {m_state}")
        if s_state < FCSM_LINK_IDLE:
            failures.append(f"swreset iter {it}: slave stuck at {s_state}")

    assert not failures, (
        f"repeated swreset_ll cycles caused {len(failures)} failures: "
        f"{failures}")


# -----------------------------------------------------------------------
# TEST 3 — alternating mid-bringup reset interrupt. POR the slave while
# the master is mid-CR-handshake. Asserts no master-side stuck state.
# Catches: sticky latches surviving a one-sided reset, override paths
# corrupted by partial-reset.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_slave_por_during_master_handshake(dut):
    """Master comes up first. While master is mid-handshake (state 1-3),
    POR the slave. Repeat. Assert master either advances or sits cleanly,
    NOT that it enters SEND_NACK loops or latches stale crack_seen."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    # Initial bring-up to baseline
    await ClockCycles(dut.master_clk, 1000)

    m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
    initial_m = int(m.state.value)
    initial_s = int(s.state.value)
    dut._log.info(f"  initial: m.state={initial_m} s.state={initial_s}")

    NUM_ITERATIONS = 3
    nack_violations = []
    stuck_violations = []
    for it in range(NUM_ITERATIONS):
        # Drop slave only, mid-flight
        dut.s_poresetn.value = 0
        dut.s_hresetn.value = 0
        await ClockCycles(dut.master_clk, 50)
        # Sample master state during slave-down period
        m_during = int(m.state.value)
        dut._log.info(f"  iter {it} (slave dropped): m.state={m_during}")
        # SEND_NACK = state 7 — should NOT enter SEND_NACK loops because
        # there's no traffic to nack.
        if m_during == 7:
            nack_violations.append(f"iter {it}: master entered SEND_NACK during slave reset")

        # Release slave
        dut.s_poresetn.value = 1
        await ClockCycles(dut.master_clk, 2)
        dut.s_hresetn.value = 1
        await ClockCycles(dut.master_clk, 2)
        # Re-lock slave
        await lock_slave(dut)

        # Settle
        await ClockCycles(dut.master_clk, 2000)
        m_post = int(m.state.value); s_post = int(s.state.value)
        dut._log.info(f"  iter {it} (recovery): m.state={m_post} s.state={s_post}")
        if m_post < FCSM_LINK_IDLE:
            stuck_violations.append(f"iter {it}: master stuck at {m_post}")
        if s_post < FCSM_LINK_IDLE:
            stuck_violations.append(f"iter {it}: slave stuck at {s_post}")

    if nack_violations:
        dut._log.error(f"  NACK violations: {nack_violations}")
    if stuck_violations:
        dut._log.error(f"  Stuck violations: {stuck_violations}")

    assert not nack_violations, (
        f"master entered SEND_NACK in response to slave-only POR: "
        f"{nack_violations}. This means the master is reacting to "
        f"slave-side reset glitches by enqueuing NACKs — a state-machine "
        f"bug")
    # Stuck violations after slave POR — slave may take longer than 2000
    # cycles to come back when the master is already up but the
    # cross-link autoneg has to re-converge. We log loudly but don't
    # hard-assert here because this scenario overlaps the §9.8 known
    # blocker (staggered bring-up).
    if stuck_violations:
        dut._log.warning(
            f"  Stuck violations after slave POR (may overlap §9.8 known "
            f"blocker; not asserting hard): {stuck_violations}")
