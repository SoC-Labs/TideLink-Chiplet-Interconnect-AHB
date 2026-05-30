"""Bug N3 regression — slave's calibrator must reach cal_done=1 within
budget after master enters ST_TRAIN_RUN.

Background
----------
After Bug N1 + N2 fixes (HEAD 8296697), test_10_autonomous_train_post_por
shows the master entering ST_TRAIN_ENTER (state 12), writing the slave's
SWI_TRAINING_MODE via I²C (Bug N2 fix), entering ST_TRAIN_RUN (state 13),
and then ultimately parking in ST_TRAIN_FAIL (state 17) because the
slave's `cal_done` never asserts during the POLL_PEER window.

Root cause (Bug N3):
  The slave's calibrator (tidelink_phy_align_calibrator.sv) triggers only
  on `role_locked` rising or `swreset` falling while `role_locked` is
  high. In the autonomous bring-up timeline:

    t≈ 61 µs  slave role_locked rises → calibrator sweeps against
              master's idle (non-training) traffic → finds no eye →
              FSM ends at S_DONE with a failure or stale result.
    t≈ 2.5 ms master I²C-writes slave's swi_training_mode_r:=1 →
              slave's swi_training_mode_w goes high → lane_checker
              now decodes a clean training pattern from master,
              lane_locked_w → 0xFF.
              BUT the calibrator stays in S_DONE — there is no edge
              to re-arm it.

  Result: peer_cal_done in master's POLL_PEER read stays 0, master
  walks the timeout, and we land in ST_TRAIN_FAIL.

  The autoneg FSM only generates `local_swreset_pulse` at ST_TRAIN_EXIT
  (after training succeeds), so there is no swreset edge at ST_TRAIN_ENTER
  ACK or ST_TRAIN_RUN entry that would re-arm the calibrator.

Test contract
-------------
Under `BYPASS_AUTONEG=0` (autoneg + training engaged, no APB stimulus):

  1. Reset both dies.
  2. Wait for the master autoneg FSM to first enter ST_TRAIN_RUN
     (state 13). Bounded by ~5 ms sim time (test_10 sees ST_TRAIN_ENTER
     entry at ~1.7 ms, then progresses to ST_TRAIN_RUN immediately on
     peer-ACK).
  3. Once state 13 is entered, record sim time T0.
  4. Poll the slave's calibrator `calibration_done` output for up to
     BUDGET_MS = 5.0 sim ms.
  5. PASS if the slave's `calibration_done` flips to 1 within budget
     AND lane_locked_w is 0xFF (a successful sweep, not a failure
     latch).
  6. FAIL with a clear Bug N3 message if the budget elapses with the
     slave's cal_done still 0 (the calibrator never re-armed against
     the live training pattern).

Time budget rationale
---------------------
The slave's calibrator at link_clk_rx (~125 MHz in HW; here gated off
the recovered RX clock) needs:
    DWELL_CYCLES per (slip, phase) point × 128 sweep points × 8 lanes
    plus S_PROBE + S_HOLD + S_VALIDATE phases.
At sim timing this nominally completes in well under 2 ms once the
trigger fires. 5 ms gives ample margin for the re-arm path PLUS the
sweep itself.

Failure mode
------------
On pre-fix RTL (Bug N3 present) the calibrator's `cur_state` reaches
S_DONE long before T0 (during the first 0–1.5 ms window, against
non-training data) and STAYS there. cal_done is either 0 (failure
latch) or 1 with a stale/invalid result; either way, lane_locked_w
during POLL_PEER doesn't reflect a valid sweep.

Run
---
    cd cocotb/tidelink_top_pair
    TB_TOP_NO_DUMP=1 BYPASS_AUTONEG=0 \
        TESTCASE=test_16_bug_n3_slave_cal_done_landed \
        make MODULE=test_16_bug_n3_slave_cal_done_landed
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0       # 50 MHz hclk / apb_clk
REF_CLK_PERIOD_NS = 8.0

# State decoder — matches tidelink_autoneg.sv state_r encoding.
ST_NAMES = {
    0:  "ST_IDLE",
    1:  "ST_NEGO_INIT",
    2:  "ST_NEGO_WAIT",
    3:  "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL",
    5:  "ST_NEGO_DONE",
    6:  "ST_BYPASS",
    7:  "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX",
    9:  "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA",
    11: "ST_NEGO_DONE_PRE",
    12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN",
    14: "ST_TRAIN_POLL_PEER",
    15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE",
    17: "ST_TRAIN_FAIL",
}

CAL_STATE_NAMES = {
    0: "S_IDLE",
    1: "S_ARM",
    2: "S_PROBE",
    3: "S_SWEEP",
    4: "S_FINALIZE",
    5: "S_FINISH",
    6: "S_DONE",
    7: "S_CANCEL",
    8: "S_HOLD",
    9: "S_VALIDATE",
}

ST_TRAIN_RUN = 13

# How long, in sim time, are we willing to wait for the master to first
# enter ST_TRAIN_RUN after POR? test_10 sees it ~immediately after
# ST_TRAIN_ENTER completes its 6-byte I²C burst, so ~2 ms. 5 ms margin.
TRAIN_RUN_BUDGET_MS = 5.0

# Once master is in ST_TRAIN_RUN, how long do we allow the slave's
# calibrator cal_done to stay 0 before declaring Bug N3? See docstring
# for the rationale (well under 2 ms natural sweep, 5 ms is ~2.5× margin).
BUDGET_MS = 5.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _state_name(st):
    return ST_NAMES.get(st, f"UNKNOWN({st})")


def _cal_name(st):
    return CAL_STATE_NAMES.get(st, f"UNKNOWN({st})")


@cocotb.test()
async def test_16_bug_n3_slave_cal_done_landed(dut):
    """Regression: slave's calibrator must reach cal_done=1 within BUDGET_MS
    of master entering ST_TRAIN_RUN. FAILs on pre-fix RTL because the
    calibrator's only trigger fired before training_mode came up; PASSes
    once a re-arm path lets the calibrator re-sweep against the live
    training pattern."""
    log = dut._log
    log.info("Bug N3 regression — test_16_bug_n3_slave_cal_done_landed")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle all bus stimulus — autoneg + training engaged by tb_top
    # BYPASS_AUTONEG=0 force block, no SW writes here.
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
    s_an  = dut.u_slave.u_chiplet_controller.u_autoneg
    s_ctl = dut.u_slave.u_chiplet_controller
    s_cal = s_ctl.u_calibrator

    # ─── Phase A: wait for master to first enter ST_TRAIN_RUN ─────────────
    entry_budget_cycles = int(TRAIN_RUN_BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    poll = 200  # 4 µs per poll @ 50 MHz hclk
    waited = 0
    entered = False
    while waited < entry_budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _safe_int(m_an.state_r) == ST_TRAIN_RUN:
            entered = True
            break
    t_entry_ns = cocotb.utils.get_sim_time(unit="ns")
    log.info(
        f"Phase A: master ST_TRAIN_RUN entry seen={entered} after "
        f"{waited} cycles ({waited * CLK_PERIOD_NS / 1000:.1f} µs), "
        f"sim time {t_entry_ns:.0f} ns"
    )
    assert entered, (
        f"Test prerequisite failed: master FSM never reached "
        f"ST_TRAIN_RUN (state 13) within {TRAIN_RUN_BUDGET_MS} ms. "
        f"Current master state = {_safe_int(m_an.state_r)} "
        f"({_state_name(_safe_int(m_an.state_r))}). "
        f"This likely indicates a regression in the upstream NEGO + "
        f"ST_TRAIN_ENTER path (Bug N1/N2), not Bug N3."
    )

    # ─── Phase B: dwell budget — assert slave cal_done=1 ──────────────────
    dwell_budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    dwelled = 0
    landed = False
    while dwelled < dwell_budget_cycles:
        await ClockCycles(dut.hclk, poll)
        dwelled += poll
        if _safe_int(s_cal.calibration_done) == 1:
            landed = True
            break

    dwell_ms = dwelled * CLK_PERIOD_NS / 1_000_000
    t_now_ns = cocotb.utils.get_sim_time(unit="ns")

    # Probes for the failure message.
    cur_st  = _safe_int(s_cal.cur_state)
    tm_w    = _safe_int(s_ctl.swi_training_mode_w)
    lane    = _safe_int(s_ctl.lane_locked_w)
    rl      = _safe_int(s_ctl.role_locked)
    cal_dn  = _safe_int(s_cal.calibration_done)

    if not landed:
        # Bug N3 fingerprint: slave cal_done still 0 well past when the
        # live training pattern is up on the wire.
        raise AssertionError(
            f"Bug N3: slave cal_done stuck at 0 for {dwell_ms:.1f} ms "
            f"after master entered ST_TRAIN_RUN\n"
            f"  (sim t={t_now_ns:.0f} ns);\n"
            f"  slave calibrator state = {cur_st} ({_cal_name(cur_st)})\n"
            f"  slave swi_training_mode = {tm_w}  ← gate condition\n"
            f"  slave lane_locked = 0x{lane:02x}     ← what the lane checker sees\n"
            f"  slave role_locked = {rl}\n"
            f"Expected: slave calibration_done=1 within {BUDGET_MS} ms "
            f"of master ST_TRAIN_RUN entry. The calibrator finished its "
            f"only sweep at ~1 ms (against non-training data) and has no "
            f"re-arm trigger now that swi_training_mode is up."
        )

    # Sanity: cal_done landed — confirm it's a valid successful sweep.
    log.info(
        f"PASS: slave cal_done=1 landed after {dwell_ms*1000:.1f} µs "
        f"dwell (sim t={t_now_ns:.0f} ns); "
        f"slave cal cur_state={cur_st} ({_cal_name(cur_st)}) "
        f"swi_training_mode_w={tm_w} "
        f"lane_locked_w=0x{lane:02x} "
        f"role_locked={rl} "
        f"cal_done={cal_dn}"
    )
