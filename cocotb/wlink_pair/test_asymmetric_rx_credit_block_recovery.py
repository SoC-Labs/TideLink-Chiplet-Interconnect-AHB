"""Asymmetric-RX credit block + recovery — permanent sim reproducer of the
current TideLink hardware blocker (v7 RO-observability capture, 2026-05-18).

Field scenario: the master RX locks and the master FCSM advances to
state 2 with cr_pkt_seen_rx=1, waiting for the slave's crack; the slave
RX never locks, so the slave FCSM stays at SEND_CREDITS1 (state 1,
cr_pkt_seen_rx=0) and never emits a crack -> the master parks at state 2
and CURRENT_CREDITS never moves. The credit-path *logic* is correct
(proven by test_fcsm_io_rx_reset_sticky + test_credit_handshake_end_to_end);
the blocker is purely one side's RX not locking.

Two tests:

  test_asymmetric_rx_block_observable  (deterministic PASS)
    Only master_clk runs; the slave is frozen (slave_clk dead) so the
    master's pad_clk_rx is silent and it can never receive a crack.
    Asserts the master FCSM sits in a DEFINED waiting state (not X / not
    an undefined hang), never reaches LINK_DATA, crack_pkt_seen_rx stays
    0, and the Region-8 RO credit-path mirror reports that same blocked
    state — i.e. this exact field failure is faithfully readable over the
    APB with no ILA. The defined-state / not-LINK_DATA assertion doubles
    as the negative control for the recovery test (if the FCSM completed
    with the slave frozen, the credit path would not depend on the crack
    and any "recovery" would be vacuous).

  test_asymmetric_rx_recovery_via_swi_recal  (expect_fail — documented
    reproducer of the OPEN staggered-bring-up problem, §9.8 /
    test_pair_align_staggered_bringup)
    Brings the slave up late and applies the genuine designed re-arm —
    the SWI_RECAL coordinated retrain (Region-8 slot-0 {train,recal}) on
    BOTH sides — then asserts the credit handshake completes (both FCSMs
    LINK_DATA). In the zero-jitter pair TB a late joiner is exactly the
    staggered-bring-up case that does not converge without I²C-coordinated
    training; this is marked expect_fail so it is an *asserted* reproducer
    of the known open blocker rather than a flaky failure. If a future
    fix (I²C-coordinated training, timing-determinism remediation) makes
    recovery converge, this becomes an XPASS that flags "promote — the
    asymmetric-RX recovery now works".

CURRENT_CREDITS limitation: as in test_credit_handshake_end_to_end, the
RX-FIFO credit counter is not on this pair TB's chiplet APB and only
moves under AHB data traffic; the handshake-driven proof is the FCSM
reaching LINK_DATA. Documented, not asserted as evidence.

Invocation (from cocotb/wlink_pair/):
    rm -rf sim_build ../phy_align/sim_build
    make MODULE=test_asymmetric_rx_credit_block_recovery SKID_BITS=3
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from test_link_bringup import lock_master, lock_slave, ctrl_read, ctrl_write
from test_credit_handshake_end_to_end import (
    _fcsm, _force_autocal_enable,
    _fcsm_state, _crack_seen,
    R8_SWI_LANE_STATUS,
)

CLK_PS = 20000           # 50 MHz, matches the other wlink_pair tests
LINK_DATA = 4            # FCSM state >= 4 == LINK_DATA
R8_SWI_TRAINING_MODE = 0b1000   # Region-8 slot 0: bit0=train, bit1=recal


def _resolvable(handle):
    try:
        int(handle.value)
        return True
    except Exception:
        return False


async def _idle_and_reset(dut):
    for p in ("m", "s"):
        for s in ("apb_psel", "apb_penable", "apb_pwrite", "apb_paddr",
                  "apb_pwdata", "apb_pprot", "apb_pstrb",
                  "ctrl_reg_write", "ctrl_reg_addr", "ctrl_reg_wdata"):
            getattr(dut, f"{p}_{s}").value = 0
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0


async def _bring_master_up_slave_frozen(dut):
    """Master clocked + locked; slave_clk dead => master pad_clk_rx silent."""
    await _idle_and_reset(dut)
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)
    cocotb.start_soon(Clock(dut.master_clk, CLK_PS, unit="ps").start())
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await lock_master(dut)


@cocotb.test()
async def test_asymmetric_rx_block_observable(dut):
    m = _fcsm(dut, "m")
    await _bring_master_up_slave_frozen(dut)

    blk_max, unresolved = 0, False
    for _ in range(400):
        await ClockCycles(dut.master_clk, 25)
        if not _resolvable(m.state):
            unresolved = True
            break
        blk_max = max(blk_max, int(m.state.value))
    blk_state = int(m.state.value) if _resolvable(m.state) else -1
    blk_crack = int(m.crack_pkt_seen_rx.value) if _resolvable(
        m.crack_pkt_seen_rx) else -1
    dut._log.info(f"[block] master FCSM state={blk_state} max={blk_max} "
                  f"crack_seen={blk_crack} resolvable={not unresolved}")

    assert not unresolved, (
        "master FCSM went X/undefined with the slave frozen — the blocked "
        "path must be a DEFINED wait state, not an undefined hang")
    assert blk_max < LINK_DATA, (
        f"master FCSM reached LINK_DATA (max={blk_max}) with the slave "
        f"frozen — credit path completed without a crack (negative-control "
        f"violation: recovery proof would be vacuous)")
    assert blk_crack == 0, (
        f"crack_pkt_seen_rx={blk_crack} latched with no slave running — "
        f"the crack latch is not sourced from a received crack")

    ro = await ctrl_read(dut, "m", R8_SWI_LANE_STATUS)
    ro_state, ro_crack = _fcsm_state(ro), _crack_seen(ro)
    dut._log.info(f"[block] RO mirror CREDIT_PATH_STATUS=0x{ro:08x} "
                  f"fcsm_state={ro_state} crack_seen={ro_crack}")
    assert ro_state == blk_state and ro_crack == 0, (
        f"Region-8 RO mirror ({ro_state=}, {ro_crack=}) != raw blocked FCSM "
        f"({blk_state=}, crack=0) — the block is not faithfully APB-readable")
    dut._log.info(
        "[block] OK: master parked in a defined non-LINK_DATA state, crack "
        "blocked, asymmetric-RX block faithfully reported via Region-8 RO "
        "(field-debuggable over APB, no ILA needed)")


@cocotb.test(expect_fail=True)
async def test_asymmetric_rx_recovery_via_swi_recal(dut):
    """Documented reproducer of the OPEN staggered-bring-up blocker (§9.8).
    Exercises the genuine SWI_RECAL coordinated re-arm; expect_fail until
    I²C-coordinated training / timing-determinism work lands."""
    m = _fcsm(dut, "m")
    await _bring_master_up_slave_frozen(dut)
    for _ in range(200):
        await ClockCycles(dut.master_clk, 25)
        if _resolvable(m.state) and int(m.state.value) >= 1:
            break

    # --- genuine re-arm: bring the slave up, then SWI_RECAL coordinated
    #     retrain (train+recal) on BOTH sides, then release recal ---------
    cocotb.start_soon(Clock(dut.slave_clk, CLK_PS, unit="ps").start())
    await ClockCycles(dut.master_clk, 2)
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)
    await lock_slave(dut)
    s = _fcsm(dut, "s")

    for side in ("m", "s"):
        await ctrl_write(dut, side, R8_SWI_TRAINING_MODE, 0x3)  # train+recal
    await ClockCycles(dut.master_clk, 400)
    for side in ("m", "s"):
        await ctrl_write(dut, side, R8_SWI_TRAINING_MODE, 0x1)  # recal falling
    await ClockCycles(dut.master_clk, 400)
    for side in ("m", "s"):
        await ctrl_write(dut, side, R8_SWI_TRAINING_MODE, 0x0)  # training off

    m_max = s_max = m_crack = 0
    for _ in range(8000):
        await ClockCycles(dut.master_clk, 25)
        if _resolvable(m.state):
            m_max = max(m_max, int(m.state.value))
        if _resolvable(s.state):
            s_max = max(s_max, int(s.state.value))
        if _resolvable(m.crack_pkt_seen_rx) and int(m.crack_pkt_seen_rx.value):
            m_crack = 1
        if m_max >= LINK_DATA and s_max >= LINK_DATA and m_crack:
            break
    dut._log.info(f"[recover] master_max={m_max} slave_max={s_max} "
                  f"master_crack_seen={m_crack}")
    assert m_max >= LINK_DATA and s_max >= LINK_DATA and m_crack == 1, (
        f"asymmetric-RX recovery did not complete (master_max={m_max}, "
        f"slave_max={s_max}, crack={m_crack}). EXPECTED until the staggered "
        f"-bring-up blocker (§9.8) is fixed — a late RX joiner does not "
        f"converge in the zero-jitter pair TB even with the SWI_RECAL "
        f"coordinated re-arm. If this XPASSes, recovery now works — promote "
        f"this test to a hard PASS.")
