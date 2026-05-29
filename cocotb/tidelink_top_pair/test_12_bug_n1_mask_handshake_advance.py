"""Bug N1 regression — proves that the autoneg FSM does not get stuck at
ST_NEGO_MASK_RD_ADDR after role_lock latches.

Background
----------
Bug N1 (diagnosed 2026-05-29, see docs/AUTONOMY_PHASE0C_SIM_TRACE.md):

  When `nego_won=1`, `role_lock_reg` latches the very same edge the FSM
  enters ST_NEGO_MASK_RES_TX (state 8) / ST_NEGO_MASK_RD_ADDR (state 9).
  This drops `role_in_nego = nego_en && !role_locked` to 0, which causes
  the `nego_driving` mux in axi_chiplet_controller.sv:1045 to hand the
  I²C-master AXIL bus back to the bridge. The autoneg FSM is then stuck
  in TXN_DATA / AXL_WR_RESP forever, waiting for an `m_axil_bvalid` that
  the now-bridge-owned bus will never deliver.

  Empirically: master gets to state 9 at sim ~65 µs and stays there for
  the full sim window (100+ ms), see test_10 / test_11.

Test contract
-------------
Under `BYPASS_AUTONEG=0` (autoneg engaged, no APB stimulus):

  1. Reset both dies.
  2. Wait for the master autoneg FSM to first enter ST_NEGO_MASK_RD_ADDR
     (state 9). Bounded by an overall sim-time budget (~5 ms — autoneg
     should reach state 9 by ~65 µs).
  3. Once state 9 is entered, record sim time T0.
  4. Continue polling. Assert that within DWELL_BUDGET_MS sim ms of T0,
     the FSM advances PAST state 9 (i.e. to state 10/11/12 — any of
     MASK_RD_DATA, NEGO_DONE_PRE, TRAIN_ENTER).
  5. FAIL with a clear Bug N1 message if the dwell budget elapses with
     the FSM still in state 9.

Failure mode
------------
On current RTL (Bug N1 present) the FSM is parked in state 9
indefinitely → AssertionError raised inside the dwell-budget window
(fail-fast). On fixed RTL the FSM advances within microseconds of
entering state 9 and the test PASSes.

Run
---
    cd cocotb/tidelink_top_pair
    TB_TOP_NO_DUMP=1 BYPASS_AUTONEG=0 \
        TESTCASE=test_12_bug_n1_mask_handshake_advance \
        make MODULE=test_12_bug_n1_mask_handshake_advance
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0       # 50 MHz hclk / apb_clk
REF_CLK_PERIOD_NS = 8.0

# State decoder — matches tidelink_autoneg.sv state_r encoding.
ST_NEGO_MASK_RES_TX  = 8
ST_NEGO_MASK_RD_ADDR = 9
ST_NEGO_MASK_RD_DATA = 10
ST_NEGO_DONE_PRE     = 11
ST_TRAIN_ENTER       = 12

# How long, in sim time, are we willing to wait for the FSM to first
# enter state 9 after POR? Phase 0c trace shows state 9 entry at ~65 µs.
# 5 ms gives a generous margin and fails fast if something else has
# broken the upstream POLL/CLAIM path.
STATE9_ENTRY_BUDGET_MS = 5.0

# Once state 9 is entered, how long do we allow it to dwell before
# declaring Bug N1? The mask-read-address handshake is two address
# bytes over I²C at ~100 kHz, so ~200 µs is the natural upper bound.
# 20 ms is the spec budget per the brief — orders of magnitude above
# the natural completion time, ample even with VCS jitter, and still
# fast enough to fail-fast (5 min sim wall) when the bug is present.
DWELL_BUDGET_MS = 20.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


@cocotb.test()
async def test_12_bug_n1_mask_handshake_advance(dut):
    """Regression: FSM must not stick in ST_NEGO_MASK_RD_ADDR post role_lock.

    See module docstring for full Bug N1 background. This test FAILs on
    pre-fix RTL (FSM parked in state 9) and PASSes once the
    `nego_driving` mux is extended to cover mask-handshake states
    even after role_locked latches.
    """
    log = dut._log
    log.info("Bug N1 regression — test_12_bug_n1_mask_handshake_advance")

    # Start clocks.
    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle all bus stimulus — the FSM is engaged purely by the tb_top
    # BYPASS_AUTONEG=0 force block, no SW writes are performed by this
    # test.
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

    # Reset.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Hierarchy handles.
    m_an  = dut.u_master.u_chiplet_controller.u_autoneg
    m_ctl = dut.u_master.u_chiplet_controller

    # ─── Phase A: wait for master to first enter ST_NEGO_MASK_RD_ADDR ──
    entry_budget_cycles = int(STATE9_ENTRY_BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    poll = 200  # 4 µs per poll @ 50 MHz hclk
    waited = 0
    entered = False
    while waited < entry_budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _safe_int(m_an.state_r) == ST_NEGO_MASK_RD_ADDR:
            entered = True
            break
    t_entry_ns = cocotb.utils.get_sim_time(unit="ns")
    log.info(
        f"Phase A: state-9 entry seen={entered} after {waited} cycles "
        f"({waited * CLK_PERIOD_NS / 1000:.1f} µs), sim time {t_entry_ns:.0f} ns"
    )
    assert entered, (
        f"Test prerequisite failed: master FSM never reached "
        f"ST_NEGO_MASK_RD_ADDR (state 9) within {STATE9_ENTRY_BUDGET_MS} ms. "
        f"Current state = {_safe_int(m_an.state_r)}. "
        f"This likely indicates a regression in the upstream NEGO "
        f"CLAIM/POLL path, not Bug N1."
    )

    # ─── Phase B: dwell budget — assert FSM advances past state 9 ──────
    dwell_budget_cycles = int(DWELL_BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    dwelled = 0
    advanced_to = -1
    while dwelled < dwell_budget_cycles:
        await ClockCycles(dut.hclk, poll)
        dwelled += poll
        st = _safe_int(m_an.state_r)
        if st != ST_NEGO_MASK_RD_ADDR:
            advanced_to = st
            break

    dwell_ms = dwelled * CLK_PERIOD_NS / 1_000_000
    t_now_ns = cocotb.utils.get_sim_time(unit="ns")

    # Probes for the failure message (so a future maintainer can see
    # at-a-glance whether the symptom matches Bug N1's signature).
    nego_driving  = _safe_int(getattr(m_ctl, "nego_driving"))
    role_in_nego  = _safe_int(getattr(m_ctl, "role_in_nego"))
    role_locked   = _safe_int(dut.m_role_locked)

    if advanced_to == -1:
        # Bug N1 fingerprint: stuck in state 9, role_locked latched,
        # role_in_nego dropped, nego_driving==0 → bus is muxed to bridge.
        raise AssertionError(
            f"Bug N1: master stuck in ST_NEGO_MASK_RD_ADDR for "
            f"{dwell_ms:.1f} ms (sim t={t_now_ns:.0f} ns); "
            f"nego_driving={nego_driving} role_in_nego={role_in_nego} "
            f"m_role_locked={role_locked}. "
            f"Expected to advance to MASK_RD_DATA (10) / NEGO_DONE_PRE (11) "
            f"/ TRAIN_ENTER (12)."
        )

    # Sanity-check the advance target — anything past state 9 along the
    # forward path is fine. ST_NEGO_DONE (5) / ST_BYPASS (6) / ST_ERROR
    # (7) would indicate a different fault (e.g. backstep, abort), not
    # the "Bug N1 has been fixed" outcome we're gating on.
    forward_states = {ST_NEGO_MASK_RD_DATA, ST_NEGO_DONE_PRE, ST_TRAIN_ENTER,
                      13, 14, 15, 16}  # 13/14/15 = TRAIN_RUN/POLL_PEER/EXIT, 16 = TRAIN_DONE
    assert advanced_to in forward_states, (
        f"FSM exited state 9 to UNEXPECTED state {advanced_to} after "
        f"{dwell_ms:.1f} ms. Forward-path states are "
        f"{sorted(forward_states)}. This is not Bug N1's signature but "
        f"is also not a clean fix — investigate."
    )

    log.info(
        f"PASS: master advanced ST_NEGO_MASK_RD_ADDR → state {advanced_to} "
        f"after {dwell_ms*1000:.1f} µs dwell (sim t={t_now_ns:.0f} ns); "
        f"nego_driving={nego_driving} role_in_nego={role_in_nego} "
        f"m_role_locked={role_locked}"
    )
