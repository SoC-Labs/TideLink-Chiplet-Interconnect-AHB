"""Bug N14a regression — winner's own calibrator parks with
calibration_done=0 even though lane_locked=8'hFF and lane_fault=0.
Pre-fix RTL requires local_calibration_done_i=1 in the Bug N10 bypass,
so the winner trips ST_TRAIN_FAIL despite "training succeeded" (lanes
locked). Post-fix RTL relaxes the bypass to lane_locked=0xFF AND
lane_fault=0 only.

Silicon symptom (v13, slave die, role_lock=1, swi_training_mode=1):
    SWI_LANE_STATUS @ 0x44032108 = 0x000200FF
       → lane_locked[7:0]   = 0xFF  ✓
       → lane_fault[15:8]   = 0x00  ✓
       → cal_done[16]       = 0    ✗

    Slave parks in ST_TRAIN_FAIL because Bug N10's TRAIN_POLL_PEER
    timeout bypass requires local_calibration_done_i — and that bit
    stays 0 even with all 8 lanes locked.

Root cause (Path A — predicate over-strict)
-------------------------------------------
The Bug N10 bypass at tidelink_autoneg.sv:1126-1129 was:
    if (!peer_cal_done_r &&
        (local_swi_lane_locked_i == 8'hFF) &&
        local_calibration_done_i &&            <-- this kills it
        (local_swi_lane_fault_i == 8'h00))

`lane_locked=0xFF AND lane_fault=0` is the actual "training succeeded"
condition: every lane has either locked OR faulted out, and no lane
faulted. cal_done is the calibrator's internal bookkeeping. The
calibrator's S_DONE-park / sticky-edge / role_locked_rise sensitivity
makes cal_done non-monotonic with the user-visible lane lock outcome
in some silicon scenarios (Bug N3-class). Dropping the
local_calibration_done_i term keeps the safety predicate (lanes locked,
no fault) and matches the user's intent.

Sim repro
---------
Pin BOTH dies' sync_cal_done_{0,1} to 0 (force) so even the local side
sees cal_done=0. Lane locks come up naturally through training. Pre-fix
RTL falls to ST_TRAIN_FAIL on the winner. Post-fix RTL takes the
relaxed bypass on poll timeout and lands in ST_TRAIN_DONE.

Test contract
-------------
* Pre-fix RTL  : winner (master) parks in ST_TRAIN_FAIL — fails
* Post-fix RTL : winner takes Bug N14a relaxed bypass → ST_TRAIN_DONE

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \\
        TESTCASE=test_25_bug_n14a_cal_done_stuck \\
        make MODULE=test_25_bug_n14a_cal_done_stuck
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotb.handle import Force


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

ST_NAMES = {
    0:  "ST_IDLE", 1: "ST_NEGO_INIT", 2: "ST_NEGO_WAIT", 3: "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL", 5: "ST_NEGO_DONE", 6: "ST_BYPASS", 7: "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX", 9: "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA", 11: "ST_NEGO_DONE_PRE", 12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN", 14: "ST_TRAIN_POLL_PEER", 15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE", 17: "ST_TRAIN_FAIL",
}

ST_TRAIN_DONE = 16
ST_TRAIN_FAIL = 17

BUDGET_MS = 80.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _state_name(st):
    return ST_NAMES.get(st, f"UNKNOWN({st})")


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


def _ctrl(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller


async def wait_state(dut, side, targets, max_cycles, poll=200, log_every=500_000):
    if isinstance(targets, int):
        targets = {targets}
    else:
        targets = set(targets)
    an = _autoneg(dut, side)
    waited = 0
    last_log = 0
    log = dut._log
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        st = _safe_int(an.state_r)
        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  [{side}] t={waited * CLK_PERIOD_NS / 1000:>8.1f} us  "
                f"st={st}({_state_name(st)})  "
                f"won={_safe_int(an.nego_won_r)} "
                f"lost={_safe_int(an.nego_lost_r)} "
                f"train_ok={_safe_int(an.train_ok_r)} "
                f"train_fail={_safe_int(an.train_fail_r)} "
                f"poll_att={_safe_int(an.poll_attempt_r)}"
            )
        if st in targets:
            return st, waited
    return -1, waited


def force_cal_done_low(ctrl):
    """Force this side's CDC-synced cal_done regs to 0 — mimics the
    silicon symptom where calibrator parks with calibration_done=0 even
    though lane lock has converged. Lane-lock regs are LEFT ALONE so
    they can rise naturally through training."""
    ctrl.sync_cal_done_0.set(Force(0))
    ctrl.sync_cal_done_1.set(Force(0))


@cocotb.test()
async def test_25_bug_n14a_cal_done_stuck(dut):
    """Both dies' sync_cal_done_{0,1} forced to 0 throughout training.
    Lane_lock proceeds naturally so peer_lane_locked + local_lane_locked
    both reach 0xFF, but cal_done stays 0 on both sides. Pre-fix Bug
    N10 bypass refuses because local_calibration_done_i=0. Post-fix
    Bug N14a relaxed bypass takes the success path on poll timeout."""
    log = dut._log
    log.info("Bug N14a regression — test_25_bug_n14a_cal_done_stuck")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

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

    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Production-silicon straps (matches test_24 / build v13).
    dut.m_apb_debug_unlock.value = 0
    dut.s_apb_debug_unlock.value = 0
    dut.m_mask_hs_bypass.value   = 0
    dut.s_mask_hs_bypass.value   = 0

    # Pin BOTH dies' local cal_done CDC syncs to 0 — mimics the silicon
    # symptom where the calibrator's S_DONE park failed to assert
    # calibration_done despite lane_locked=0xFF reaching the autoneg
    # block. Note: lane_locked / lane_fault syncs are NOT forced — they
    # come up naturally through training so the bypass predicate's
    # lane_locked==0xFF AND lane_fault==0 terms exercise the real
    # training path. This is the silicon contract: lanes locked,
    # calibrator bookkeeping broken.
    force_cal_done_low(_ctrl(dut, "m"))
    force_cal_done_low(_ctrl(dut, "s"))
    log.info(
        "Forced both dies' sync_cal_done_{0,1}=0 — local + peer "
        "cal_done view will read 0 forever; lane_locked / lane_fault "
        "syncs left to rise naturally."
    )

    # tb_top.sv force release window.
    await ClockCycles(dut.hclk, 300)

    log.info("Waiting for master (winner) to reach ST_TRAIN_DONE or ST_TRAIN_FAIL...")
    budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    st, w = await wait_state(
        dut, "m", {ST_TRAIN_DONE, ST_TRAIN_FAIL, 7},
        max_cycles=budget_cycles
    )
    log.info(
        f"Master reached st={st}({_state_name(st)}) "
        f"after {w * CLK_PERIOD_NS / 1000:.1f} us"
    )

    m_an = _autoneg(dut, "m")
    m_state      = _safe_int(m_an.state_r)
    m_train_ok   = _safe_int(m_an.train_ok_r)
    m_train_fail = _safe_int(m_an.train_fail_r)
    m_peer_lock  = _safe_int(m_an.peer_lane_locked_r) & 0xFF
    m_peer_cal   = _safe_int(m_an.peer_cal_done_r)
    m_peer_fault = _safe_int(m_an.peer_lane_fault_r) & 0xFF
    m_poll_att   = _safe_int(m_an.poll_attempt_r)
    m_won        = _safe_int(m_an.nego_won_r)

    s_state      = _safe_int(_autoneg(dut, "s").state_r)
    s_won        = _safe_int(_autoneg(dut, "s").nego_won_r)

    # Read local lane status snapshots via the controller hierarchy. These
    # come from sync_lane_locked_1 (CDC-synced from the calibrator). With
    # cal_done forced low but lane_locked not forced, lane_locked should
    # naturally reach 0xFF on the trained side.
    m_ctrl = _ctrl(dut, "m")
    m_local_lock  = _safe_int(m_ctrl.sync_lane_locked_1) & 0xFF
    m_local_fault = _safe_int(m_ctrl.sync_lane_fault_1) & 0xFF
    m_local_cal   = _safe_int(m_ctrl.sync_cal_done_1)

    log.info(
        f"FINAL MASTER:\n"
        f"  state={m_state}({_state_name(m_state)})  won={m_won}\n"
        f"  train_ok_r={m_train_ok}  train_fail_r={m_train_fail}\n"
        f"  poll_attempt_r={m_poll_att}\n"
        f"  local_lane_locked=0x{m_local_lock:02x} "
        f"local_lane_fault=0x{m_local_fault:02x} "
        f"local_cal_done={m_local_cal}  (forced 0)\n"
        f"  peer_lane_locked=0x{m_peer_lock:02x} "
        f"peer_lane_fault=0x{m_peer_fault:02x} "
        f"peer_cal_done={m_peer_cal}"
    )
    log.info(f"FINAL SLAVE: state={s_state}({_state_name(s_state)}) won={s_won}")

    # M4e (2026-06-05): primary-success predicate relaxed — bilateral
    # lane_locked=0xFF + no faults is sufficient; cal_done requirements
    # dropped. The Bug N14a hypothesis was correct ('cal_done is internal
    # bookkeeping; lane_locked is the real success signal') but applied at
    # the wrong place (timeout bypass). M4e applies the same insight to
    # the PRIMARY success predicate. With local_cal_done pinned to 0 but
    # lanes naturally locking via the sim's lane_checker, the FSM now
    # correctly reaches ST_TRAIN_DONE — this is the same scenario the
    # original N14a fix targeted, now structurally correct.
    assert m_state == ST_TRAIN_DONE, (
        f"M4e: winner (master) parked in {_state_name(m_state)} "
        f"(expected ST_TRAIN_DONE — bilateral lane_locked=0xFF with no faults "
        f"is sufficient, cal_done not required). "
        f"train_ok={m_train_ok}, train_fail={m_train_fail}, "
        f"local_lane_locked=0x{m_local_lock:02x}, "
        f"local_lane_fault=0x{m_local_fault:02x}, "
        f"local_cal_done={m_local_cal}, poll_attempt_r={m_poll_att}."
    )
    assert m_train_ok == 1, f"train_ok_r expected 1, got {m_train_ok}"
    assert m_train_fail == 0, f"train_fail_r expected 0, got {m_train_fail}"
    log.info(
        "PASS: master reaches ST_TRAIN_DONE on bilateral lane_locked=0xFF "
        "with local_cal_done forced 0 — M4e primary-success applies N14a's "
        "lane-lock-only insight at the right place."
    )
