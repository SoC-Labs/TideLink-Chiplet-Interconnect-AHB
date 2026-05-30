"""Bug N3 probe — slave calibrator never re-arms after training_mode rises.

Background
----------
After Bug N1 + N2 fixes (HEAD 8296697), test_10_autonomous_train_post_por
shows:

  t=  1665 µs  master enters ST_TRAIN_ENTER (state 12), issues 6-byte I²C
               write of swi_training_mode_r := 1 to peer at 0x2100. The
               Bug N2 fix routes this through to slave's chiplet-controller
               Region 8 register, so slave's swi_training_mode_w now goes
               high mid-run.
  t≈14461 µs   master parks in ST_TRAIN_FAIL (state 17) — POLL_PEER timed
               out because slave's peer_cal_done never went 1
               (peer_lane_locked DID flip to 0xFF, but cal_done stayed 0).

Hypothesis (BUG_N3):
  The slave's calibrator triggers only on (role_locked_rise) OR
  (swreset_fall & role_locked). See tidelink_phy_align_calibrator.sv:497-501:

      wire role_locked_rise = role_locked & ~role_locked_q;
      wire swreset_fall     = ~swreset    &  swreset_q;
      assign trigger_now    = role_locked_rise | (swreset_fall & role_locked);

  Test_10 timeline:
    t≈ 61 µs   slave's role_locked rises → calibrator triggers →
               S_ARM → S_PROBE → S_SWEEP against swi_training_mode_w=0
               data (master's TX is NOT in training mode yet) → fails to
               find an eye → ends at S_DONE (terminal) with cal_done set
               to a failure result or unset.
    t≈ 2.3 ms  master's I²C write lands → slave's swi_training_mode_w
               rises (per Bug N2 fix) → slave's lane_checker sees the
               training pattern → lane_locked_o goes 0xFF.
               BUT the calibrator already finished its only sweep. There
               is NO re-arm trigger for "training_mode came up after
               role_locked".

  ST_TRAIN_ENTER does NOT generate local_swreset_pulse — only ST_TRAIN_EXIT
  does (at the end of training). So in autonomous bring-up the slave never
  re-arms its calibrator against the live training pattern, and cal_done
  is never set against a valid sweep.

What this probe checks
----------------------
Sample, on the slave die, at three points:
  T0:  shortly after role_locked first rises (~62 µs)
  T1:  ~2.5 ms (after master's Bug N2 I²C write has landed and slave's
       swi_training_mode_w should be high)
  T2:  ~5 ms (well after master would have hit ST_TRAIN_POLL_PEER)

Signals (slave hierarchy):
  - calibrator cur_state (FSM state)
  - calibrator calibration_done (cal_done_w output)
  - calibrator swreset input
  - swi_training_mode_w
  - lane_locked_w
  - role_locked
  - local_swreset_pulse_w
  - local_training_mode_set_w
  - master FSM state_r

Expected (hypothesis confirmed):
  T0: cur_state advances away from S_IDLE — calibrator triggered by
      role_locked_rise.
  T1: cur_state has reached S_DONE (9) [or via S_HOLD/S_VALIDATE].
      swi_training_mode_w == 1 (because of Bug N2 fix).
      lane_locked_w == 0xFF (live training pattern decoded).
      swreset still 0 → NO re-arm trigger.
  T2: cur_state still S_DONE. calibration_done still showing the stale
      result from the first failed sweep.

If T1 shows cur_state != S_DONE (still sweeping), OR calibration_done==1
with a successful result — hypothesis is wrong, stop and report.

INFO-only — no assertions. Bounded to ~7 ms sim time.

Run
---
    cd cocotb/tidelink_top_pair
    TB_TOP_NO_DUMP=1 BYPASS_AUTONEG=0 \
        TESTCASE=test_17_bug_n3_calibrator_retrigger_probe \
        make MODULE=test_17_bug_n3_calibrator_retrigger_probe
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0       # 50 MHz hclk / apb_clk
REF_CLK_PERIOD_NS = 8.0

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


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _safe_hex(sig, width=2, default="?"):
    v = _safe_int(sig)
    if v < 0:
        return default
    return f"{v:0{width}x}"


def _cal_state(v):
    return CAL_STATE_NAMES.get(v, f"UNKNOWN({v})")


@cocotb.test()
async def test_17_bug_n3_calibrator_retrigger_probe(dut):
    """Probe: slave calibrator should re-arm when training_mode comes up
    mid-run. If it does not, Bug N3 is confirmed."""
    log = dut._log
    log.info("Bug N3 probe — slave calibrator re-arm path")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle all bus stimulus.
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
    s_ctl = dut.u_slave.u_chiplet_controller
    s_cal = s_ctl.u_calibrator
    s_an  = s_ctl.u_autoneg
    m_an  = dut.u_master.u_chiplet_controller.u_autoneg

    def snapshot(label):
        t_ns = cocotb.utils.get_sim_time(unit="ns")
        cur  = _safe_int(s_cal.cur_state)
        log.info(f"---- {label} @ t={t_ns:.0f} ns ----")
        log.info(
            f"  slave cal cur_state    = {cur} ({_cal_state(cur)})"
        )
        log.info(
            f"  slave cal calibration_done = "
            f"{_safe_int(s_cal.calibration_done)}"
        )
        log.info(
            f"  slave cal swreset (in)     = "
            f"{_safe_int(s_cal.swreset)}"
        )
        log.info(
            f"  slave cal role_locked (in) = "
            f"{_safe_int(s_cal.role_locked)}"
        )
        log.info(
            f"  slave swi_training_mode_w  = "
            f"{_safe_int(s_ctl.swi_training_mode_w)}"
        )
        log.info(
            f"  slave swi_training_mode_r  = "
            f"{_safe_int(s_ctl.swi_training_mode_r)}"
        )
        log.info(
            f"  slave lane_locked_w        = 0x"
            f"{_safe_hex(s_ctl.lane_locked_w, 2)}"
        )
        log.info(
            f"  slave cal_lane_fault_w     = 0x"
            f"{_safe_hex(s_ctl.cal_lane_fault_w, 2)}"
        )
        log.info(
            f"  slave role_locked (top)    = "
            f"{_safe_int(s_ctl.role_locked)}"
        )
        log.info(
            f"  slave local_swreset_pulse_w        = "
            f"{_safe_int(s_ctl.local_swreset_pulse_w)}"
        )
        log.info(
            f"  slave local_training_mode_set_w    = "
            f"{_safe_int(s_ctl.local_training_mode_set_w)}"
        )
        log.info(
            f"  master FSM state_r = {_safe_int(m_an.state_r)}"
        )
        log.info(
            f"  slave  FSM state_r = {_safe_int(s_an.state_r)}"
        )

    # T0: ~62 µs — just after slave role_locked rises and calibrator
    # should have triggered on the role_locked edge.
    target_t0_ns = 62_000
    cycles_to_t0 = int(target_t0_ns / CLK_PERIOD_NS) - 75
    await ClockCycles(dut.hclk, cycles_to_t0)
    snapshot("T0 ~62 µs (post role_locked rise)")

    # Sample a few more times during the first sweep window to watch
    # the FSM walk states.
    for label, target_us in [
        ("T0.5  100 µs", 100),
        ("T0.6  300 µs", 300),
        ("T0.7  800 µs", 800),
        ("T0.8 1500 µs", 1500),
    ]:
        target_ns = target_us * 1_000
        now_ns = int(cocotb.utils.get_sim_time(unit="ns"))
        delta = target_ns - now_ns
        if delta > 0:
            await ClockCycles(dut.hclk, max(1, int(delta / CLK_PERIOD_NS)))
        snapshot(label)

    # T1: ~2.5 ms — after master's I²C write to slave's training_mode
    # should have landed (per Bug N2 fix).
    target_t1_ns = 2_500_000
    now_ns = int(cocotb.utils.get_sim_time(unit="ns"))
    delta = target_t1_ns - now_ns
    if delta > 0:
        await ClockCycles(dut.hclk, int(delta / CLK_PERIOD_NS))
    snapshot("T1 ~2.5 ms (post Bug N2 I²C write)")

    # T2: ~5 ms — well into POLL_PEER attempts.
    target_t2_ns = 5_000_000
    now_ns = int(cocotb.utils.get_sim_time(unit="ns"))
    delta = target_t2_ns - now_ns
    if delta > 0:
        await ClockCycles(dut.hclk, int(delta / CLK_PERIOD_NS))
    snapshot("T2 ~5 ms (deep in POLL_PEER)")

    # Hypothesis verdict.
    final_cur = _safe_int(s_cal.cur_state)
    final_cal_done = _safe_int(s_cal.calibration_done)
    final_tm_w = _safe_int(s_ctl.swi_training_mode_w)
    final_lane = _safe_int(s_ctl.lane_locked_w)

    log.info("==== Bug N3 hypothesis verdict ====")
    log.info(
        f"  Final slave cal cur_state    = {final_cur} ({_cal_state(final_cur)})"
    )
    log.info(f"  Final slave cal calibration_done = {final_cal_done}")
    log.info(f"  Final slave swi_training_mode_w  = {final_tm_w}")
    log.info(f"  Final slave lane_locked_w        = 0x{final_lane:02x}"
             if final_lane >= 0 else "  Final slave lane_locked_w        = ??")

    if final_cal_done == 1 and final_lane == 0xFF:
        log.info(
            "  VERDICT: cal_done IS asserted with all lanes locked. "
            "Hypothesis REFUTED — Bug N3 is somewhere else."
        )
    elif final_tm_w == 1 and final_cal_done == 0:
        log.info(
            "  VERDICT: training_mode UP but cal_done STUCK at 0. "
            "Hypothesis CONFIRMED — calibrator has no re-arm path "
            "after training_mode rises mid-run."
        )
    else:
        log.info(
            "  VERDICT: ambiguous — see snapshots above. "
            f"tm_w={final_tm_w} cal_done={final_cal_done} "
            f"lane=0x{final_lane:02x}"
        )
