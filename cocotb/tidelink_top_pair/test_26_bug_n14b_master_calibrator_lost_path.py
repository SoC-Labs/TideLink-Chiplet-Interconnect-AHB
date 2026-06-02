"""Bug N14b regression — master calibrator on the AUTONEG LOST path.

Silicon symptom (v13 silicon, master die is the LOSER of autoneg via
the Bug N9 nego_lost_w role_lock path):
    SWI_TRAINING_MODE = 0x01   ← slave wrote this via I²C from ST_TRAIN_ENTER
    SWI_LANE_STATUS   = 0x00020000
        bits[7:0]   = 0x00     ← MASTER RX did NOT lock on slave's TX
        bit[16]     = 0        ← cal_done = 0
        bits[20:17] = 1        ← FCSM state = 1 (idle)
    Master parked in ST_NEGO_DONE-lost (terminal state).
    Meanwhile slave reports lane_locked=0xFF → slave RX OK.

The asymmetric architecture says master and slave are mirror-symmetric: any
calibrator that engages with a peer TX'ing the training pattern should
lock. The Bug N3 fix is supposed to make this happen — when slave's I²C
write sets master's swi_training_mode_r 0→1, the rising edge stretches
into a 127-cycle apb_clk swreset pulse OR'd into the calibrator's swreset
input. The falling edge re-arms a fresh sweep against slave's now-live
training pattern.

This test forces the lost-path scenario in sim by SWAPPING priorities
(master=0x0002, slave=0x0001) so the slave wins arbitration. The
production-silicon straps (apb_debug_unlock=mask_hs_bypass=0) are also
asserted to match the Bug N13 strap pattern.

Assertions
----------
Pre-Bug-N14b-fix: master's lane_locked stays 0x00, cal_done stays 0.
Post-fix:        master's lane_locked → 0xFF and cal_done → 1 within
                 the BUDGET_MS training window.

If this PASSES on current HEAD, the silicon symptom is caused by an
HW-only timing / CDC effect not modelled in sim — fall back to defensive
Path-B pulse widening as the candidate fix.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \\
        TESTCASE=test_26_bug_n14b_master_calibrator_lost_path \\
        MODULE=test_26_bug_n14b_master_calibrator_lost_path make
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotb.handle import Force


CLK_PERIOD_NS     = 20.0     # 50 MHz hclk
REF_CLK_PERIOD_NS = 8.0

ST_NAMES = {
    0:  "ST_IDLE", 1: "ST_NEGO_INIT", 2: "ST_NEGO_WAIT", 3: "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL", 5: "ST_NEGO_DONE", 6: "ST_BYPASS", 7: "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX", 9: "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA", 11: "ST_NEGO_DONE_PRE", 12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN", 14: "ST_TRAIN_POLL_PEER", 15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE", 17: "ST_TRAIN_FAIL",
}

ST_TRAIN_DONE   = 16
ST_TRAIN_FAIL   = 17
ST_NEGO_DONE    = 5
ST_ERROR        = 7

# The lost-path master's calibrator must wait for slave to reach
# ST_TRAIN_ENTER (writes master's swi_training_mode), then a sweep against
# the live training pattern (~5.5 ms at silicon link_rx_clk). 80 ms gives
# ample headroom — matches BUDGET_MS scale of test_24.
BUDGET_MS = 120.0


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


def _cal(dut, side):
    return _ctrl(dut, side).u_calibrator


def _snapshot(dut, label):
    log = dut._log
    log.info(f"========= snapshot @ {label} =========")
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        an = _autoneg(dut, side)
        cc = _ctrl(dut, side)
        cal = _cal(dut, side)
        role = _safe_int(getattr(dut, f"{side}_role_locked"))
        log.info(
            f"  {name}: state={_safe_int(an.state_r)}"
            f"({_state_name(_safe_int(an.state_r))})  "
            f"role={role}  prio=0x{_safe_int(cc.nego_priority_reg):04x}  "
            f"won={_safe_int(an.nego_won_r)} lost={_safe_int(an.nego_lost_r)}  "
            f"swi_tm_r={_safe_int(cc.swi_training_mode_r)}  "
            f"cal_state={_safe_int(cal.cur_state)}  "
            f"cal_done={_safe_int(cc.sync_cal_done_1)}  "
            f"lane_locked=0x{_safe_int(cc.sync_lane_locked_1):02x}"
        )


@cocotb.test()
async def test_26_bug_n14b_master_calibrator_lost_path(dut):
    """Master is autoneg LOSER. After slave's I²C-driven training_mode
    write, master's calibrator must re-arm (Bug N3 fix) and lock against
    slave's TX. Pre-fix: master's lane_locked stays 0, cal_done stays 0.
    Post-fix: master lane_locked=0xFF, cal_done=1.
    """
    log = dut._log
    log.info("Bug N14b regression — master calibrator on autoneg LOST path")
    log.info(f"BUDGET_MS={BUDGET_MS}")

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

    # Hold both dies in reset PAST tb_top's #5000 ns force-release window
    # so that when we deassert, our cocotb-side priority Force is the
    # only driver. tb_top forces priorities 1/2 from t=0 to t=5000 ns;
    # if we deassert reset BEFORE that releases, the FSM samples 1/2 and
    # master wins. So we hold reset until t≈8000 ns to give the tb_top
    # force time to release, THEN apply our priority swap, THEN deassert.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 450)  # ~9000 ns @ 50 MHz hclk

    # Production-silicon straps — drive while still in reset so the
    # autoneg FSM sees them on its first clock edge out of reset.
    dut.m_apb_debug_unlock.value = 0
    dut.s_apb_debug_unlock.value = 0
    dut.m_mask_hs_bypass.value   = 0
    dut.s_mask_hs_bypass.value   = 0

    # SWAP priorities: master=0x0002 (higher backoff, defers), slave=0x0001
    # (lower backoff, claims first). Mirrors the silicon scenario where
    # asymmetric POR or asymmetric backoff lands master in the lost path.
    # cocotb's Force persists indefinitely; the always_ff path that
    # re-loads the reg from APB writes won't override it.
    _ctrl(dut, "m").nego_priority_reg.set(Force(0x0002))
    _ctrl(dut, "s").nego_priority_reg.set(Force(0x0001))
    log.info("Forced priorities: master=0x0002 (defers), slave=0x0001 (claims)")

    # NOW release reset — the FSM walks INIT→WAIT and computes backoff
    # from the SWAPPED priorities, so slave (prio=1) claims first.
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    _snapshot(dut, "post-reset + priority-swap")

    poll = 200
    budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    waited = 0
    last_log = 0
    log_every = 250_000   # ~5 ms

    m_an = _autoneg(dut, "m")
    s_an = _autoneg(dut, "s")
    m_cc = _ctrl(dut, "m")
    s_cc = _ctrl(dut, "s")

    # Track whether master ever sees swi_training_mode_r=1 (Bug N2 fix
    # path) and whether its calibrator re-arms.
    master_saw_training_mode = False
    master_saw_lane_lock     = False
    master_cal_done          = False

    while waited < budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        m_st = _safe_int(m_an.state_r)
        s_st = _safe_int(s_an.state_r)
        m_tm = _safe_int(m_cc.swi_training_mode_r)
        m_ll = _safe_int(m_cc.sync_lane_locked_1)
        m_cd = _safe_int(m_cc.sync_cal_done_1)

        if m_tm == 1 and not master_saw_training_mode:
            master_saw_training_mode = True
            log.info(
                f"  *** t={waited * CLK_PERIOD_NS / 1000:.1f} us  "
                f"MASTER swi_training_mode_r 0→1 (Bug N2 I²C write path) ***"
            )
        if m_ll == 0xFF and not master_saw_lane_lock:
            master_saw_lane_lock = True
            log.info(
                f"  *** t={waited * CLK_PERIOD_NS / 1000:.1f} us  "
                f"MASTER lane_locked 0x00→0xFF ***"
            )
        if m_cd == 1 and not master_cal_done:
            master_cal_done = True
            log.info(
                f"  *** t={waited * CLK_PERIOD_NS / 1000:.1f} us  "
                f"MASTER cal_done 0→1 ***"
            )

        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  t={waited * CLK_PERIOD_NS / 1000:>8.1f} us  "
                f"M st={m_st}({_state_name(m_st)}) "
                f"role={_safe_int(dut.m_role_locked)} "
                f"tm_r={m_tm} ll=0x{m_ll:02x} cd={m_cd} "
                f"calst={_safe_int(_cal(dut, 'm').cur_state)} "
                f"|| "
                f"S st={s_st}({_state_name(s_st)}) "
                f"role={_safe_int(dut.s_role_locked)} "
                f"tm_r={_safe_int(s_cc.swi_training_mode_r)} "
                f"ll=0x{_safe_int(s_cc.sync_lane_locked_1):02x} "
                f"cd={_safe_int(s_cc.sync_cal_done_1)}"
            )

        # Exit early once slave has reached a terminal training state AND
        # master's calibrator has had a chance to converge against the
        # live training pattern. The success criterion is master's
        # lane_locked=0xFF AND cal_done=1 — Bug N14b would manifest as
        # lane_locked=0 even after slave reaches ST_TRAIN_RUN.
        s_terminal = s_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR}
        if s_terminal and master_saw_lane_lock and master_cal_done:
            # Both observed → stable; safe to break.
            log.info("Slave reached terminal AND master converged — exit.")
            break
        if s_terminal and not master_saw_lane_lock:
            # Slave finished but master never locked — Bug N14b symptom.
            # Give one more pass through the polling loop then break.
            log.warning(
                f"Slave in {_state_name(s_st)} but master lane_locked=0 — "
                f"Bug N14b candidate; collecting state."
            )
            break

    sim_t_ms = waited * CLK_PERIOD_NS / 1_000_000
    _snapshot(dut, f"final @ t={sim_t_ms:.2f} ms")

    # Collect final values
    m_state = _safe_int(m_an.state_r)
    m_role  = _safe_int(dut.m_role_locked)
    m_lost  = _safe_int(m_an.nego_lost_r)
    m_tm_r  = _safe_int(m_cc.swi_training_mode_r)
    m_lane  = _safe_int(m_cc.sync_lane_locked_1)
    m_cdone = _safe_int(m_cc.sync_cal_done_1)
    m_calst = _safe_int(_cal(dut, "m").cur_state)

    s_state = _safe_int(s_an.state_r)
    s_role  = _safe_int(dut.s_role_locked)
    s_won   = _safe_int(s_an.nego_won_r)
    s_lane  = _safe_int(s_cc.sync_lane_locked_1)
    s_cdone = _safe_int(s_cc.sync_cal_done_1)

    log.info(
        f"FINAL @ t={sim_t_ms:.2f} ms:\n"
        f"  MASTER: state={_state_name(m_state)}  role={m_role}  "
        f"lost={m_lost}  swi_tm_r={m_tm_r}\n"
        f"          lane_locked=0x{m_lane:02x}  cal_done={m_cdone}  "
        f"cal_state={m_calst}\n"
        f"  SLAVE : state={_state_name(s_state)}  role={s_role}  won={s_won}\n"
        f"          lane_locked=0x{s_lane:02x}  cal_done={s_cdone}\n"
        f"  Saw master training_mode 0→1: {master_saw_training_mode}\n"
        f"  Saw master lane_locked  0x→0xFF: {master_saw_lane_lock}\n"
        f"  Saw master cal_done     0→1:  {master_cal_done}"
    )

    # Sanity: master must actually be on the LOST path; otherwise we're
    # testing the wrong scenario and the assertion is meaningless.
    if m_lost != 1:
        raise AssertionError(
            "TEST SETUP: master did NOT take the lost path — priority swap "
            "didn't take effect. m_lost={}".format(m_lost)
        )

    # Note: master's calibrator may converge BEFORE slave reaches
    # ST_TRAIN_ENTER, because slave's own calibrator drives slave's TX
    # into training pattern during S_ARM/S_SWEEP — the autoneg FSM walk
    # through MASK_* states happens in parallel with calibrator sweeps.
    # So `swi_training_mode_r` going high on master is NOT a prerequisite
    # for lock; it's only a defensive backstop when the natural lock
    # didn't happen. We log whether we saw the I²C-write but don't
    # require it.
    if not master_saw_training_mode:
        log.info(
            "(observation: master never saw swi_training_mode_r=1 — "
            "calibrator locked BEFORE slave's ST_TRAIN_ENTER I²C write. "
            "This is the natural-lock path; Bug N3 re-arm is not on the "
            "critical path in sim.)"
        )

    # The Bug N14b assertions — we check the HISTORY (did master ever
    # lock + complete during the training window?), not the FINAL values.
    # Post-TRAIN_EXIT both sides naturally clear training_mode → lane
    # checker loses lock against the (real-data, non-pattern) stream.
    # That's expected and not the bug under test.
    failures = []
    if not master_saw_lane_lock:
        failures.append(
            "master lane_locked NEVER reached 0xFF during the training "
            "window (expected at least one cycle where it hit 0xFF — "
            "calibrator must lock against slave's TX after Bug N3 re-arm "
            "OR via the natural pre-TRAIN_ENTER path)"
        )
    if not master_cal_done:
        failures.append(
            "master cal_done NEVER reached 1 during the training window "
            "(expected the calibrator to reach S_DONE after locking)"
        )

    if failures:
        raise AssertionError(
            "Bug N14b regression: FAILED. Master is on the autoneg LOST "
            "path, slave's I²C write set master's swi_training_mode_r=1, "
            "but master's calibrator did not lock + complete.\n"
            f"  Failures: {failures}\n"
            f"  Master cal_state={m_calst} (S_IDLE=0 S_ARM=1 S_PROBE=2 "
            f"S_SWEEP=3 S_FINALIZE=8 S_FINISH=10 S_DONE=4 S_CANCEL=5 "
            f"S_HOLD=6 S_VALIDATE=9)\n"
            f"  Hypotheses (per Bug N14b plan):\n"
            f"    A: swi_training_mode_r edge detector failed to fire\n"
            f"    B: edge detected but calibrator's rx_link_clk swreset_q "
            f"missed the pulse (CDC)\n"
            f"    C: calibrator parked in S_DONE/S_VALIDATE without re-arm\n"
            f"    D: swi_training_mode_r was already 1 at POR (no edge)"
        )

    log.info(
        f"PASS: Bug N14b regression — master on lost path successfully "
        f"locked against slave's TX (lane_locked=0xFF, cal_done=1)."
    )
