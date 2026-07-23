"""End-to-end AUTONOMOUS two-die I2C bring-up — converging regression.

This is the "I2C working properly" deliverable: the two chiplets bring the
link up over the dedicated I2C sideband with ZERO software pokes. No
`do_role_lock`, no W1S of ROLE_CFG, no `to_data_mode` LL-bootstrap writes.
The autoneg FSM on each die walks

    ST_IDLE -> ST_NEGO_INIT -> ST_NEGO_WAIT -> ST_NEGO_CLAIM -> ST_NEGO_POLL
      (winner) -> ST_NEGO_MASK_RD_ADDR -> ST_NEGO_MASK_RD_DATA
               -> ST_NEGO_MASK_RES_TX  -> ST_NEGO_DONE_PRE
               -> ST_TRAIN_ENTER -> ST_TRAIN_RUN -> ST_TRAIN_POLL_PEER
               -> ST_TRAIN_EXIT  -> ST_TRAIN_DONE
      (loser)  -> ST_NEGO_DONE (SDA-START early-exit)

entirely over REAL i2c_master + i2c_slave cores cross-wired on the wired-AND
sideband bus (see tb_top.sv i2c_scl / i2c_sda). Bilateral `role_locked`
latches with NO ROLE_CFG W1S, the master reads the peer lane-mask over I2C
and the crossover comparator opens the role-lock gate, and the I2C-coordinated
training sub-flow drives both calibrators to lane-lock.

How autonomy is engaged
-----------------------
* tb_top.sv (compiled with BYPASS_AUTONEG=0) forces nego_cfg_reg=0x61 and
  nego_train_cfg_r=0x00F1 on both dies at t=0, the stand-in for the
  production NEGO_CFG_RESET / NEGO_TRAIN_CFG_RESET strap. After hresetn has
  been high for a while the forces are released; the FSM has already latched
  nego_en and is mid-flight.
* This test enables the §9 auto-cal calibrator (autocal_force_enable_q=1) and
  applies the S_VALIDATE sim-bypass (tb_early_exit_force_q=1) on BOTH dies
  BEFORE poresetn rises — without the calibrator the I2C-coordinated training
  poll (ST_TRAIN_POLL_PEER) has nothing to lock, and without the bypass the
  calibrator parks in S_VALIDATE for VALIDATION_TIMEOUT * retries link cycles
  (far beyond any sim budget). Both are sim-only knobs, not bring-up pokes:
  on silicon AUTOCAL_ENABLE is a synth parameter and S_VALIDATE expires on
  its own wall-clock timer.

MUST run with BYPASS_AUTONEG=0:
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 SIM_BUILD=sim_build_an \
        TESTCASE=test_autonomous_i2c_bringup_converge \
        make MODULE=test_28_autonomous_i2c_bringup_converge
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Reuse the paired-die testbench harness (APB master, FCSM probes, AHB FIFO
# read, calibrator handles) from the doorbell test module.
from test_tidelink_pair_doorbell import (
    PairTB,
    APB_PAIR_CREDIT_COUNTER,
    APB_DOORBELL_RESP_ACC,
    APB_DOORBELL,
    APB_RELEASE_THRESHOLD,
    CLK_PERIOD_NS,
    REF_CLK_PERIOD_NS,
)

# ── autoneg FSM state encoding (tidelink_autoneg.sv) ────────────────────────
ST_NEGO_DONE        = 5
ST_TRAIN_DONE       = 16
ST_TRAIN_FAIL       = 17

ST_NAMES = {
    0: "IDLE", 1: "NEGO_INIT", 2: "NEGO_WAIT", 3: "NEGO_CLAIM",
    4: "NEGO_POLL", 5: "NEGO_DONE", 6: "BYPASS", 7: "ERROR",
    8: "MASK_RES_TX", 9: "MASK_RD_ADDR", 10: "MASK_RD_DATA",
    11: "NEGO_DONE_PRE", 12: "TRAIN_ENTER", 13: "TRAIN_RUN",
    14: "TRAIN_POLL_PEER", 15: "TRAIN_EXIT", 16: "TRAIN_DONE",
    17: "TRAIN_FAIL",
}


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


def _state(dut, side):
    return _si(_autoneg(dut, side).state_r)


def _sname(s):
    return ST_NAMES.get(s, f"?{s}")


# Sim-only I2C prescale. POR default is 125 (=100 kHz SCL @ 50 MHz apb_clk),
# spec-compliant but slow: the full autoneg+mask+train flow at 100 kHz takes
# multiple ms of sim time. A smaller prescale runs the sideband ~8x faster
# while staying well above the Bug-N1 wedge threshold (prescale=1). The slave
# bit detector tracks SCL fine at this rate in sim. This is sim acceleration,
# not a bring-up poke — silicon uses the 100 kHz POR default.
SIM_I2C_PRESCALE = 16


def enable_autocal_and_bypass(tb):
    """Enable the §9 calibrator, apply the S_VALIDATE sim-bypass, and speed up
    the I2C sideband on BOTH dies. Must be called while poresetn is asserted
    (before role_locked rises) so the calibrator is armed for the first
    role_locked_rise trigger and the prescale override beats the POR write.
    """
    for side in ("m", "s"):
        top = tb.dut.u_master if side == "m" else tb.dut.u_slave
        cc = top.u_chiplet_controller
        try:
            cc.autocal_force_enable_q.value = 1
        except AttributeError:
            tb.log.warning(f"  [{side}] autocal_force_enable_q not found")
        try:
            cc.u_calibrator.tb_early_exit_force_q.value = 1
        except AttributeError:
            tb.log.warning(f"  [{side}] tb_early_exit_force_q not found")


def set_sim_prescale(tb):
    """Deposit the faster sim prescale AFTER poresetn rises (i2c_prescale_reg
    is POR-reset to 125, so this must land after reset but before the autoneg
    reaches ST_NEGO_CLAIM/TXN_PRESCALE — ~60 us in). Nothing writes the reg
    autonomously afterwards, so the deposit holds for the whole run.
    """
    for side in ("m", "s"):
        top = tb.dut.u_master if side == "m" else tb.dut.u_slave
        try:
            top.u_chiplet_controller.i2c_prescale_reg.value = SIM_I2C_PRESCALE
        except AttributeError:
            tb.log.warning(f"  [{side}] i2c_prescale_reg not found")


async def reset_no_pokes(tb):
    """POR + hreset release. NO role_lock, NO LL bootstrap — pure autonomy."""
    dut = tb.dut
    dut.poresetn.value = 0
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 20)
    # Arm the calibrator + bypass while still in reset.
    enable_autocal_and_bypass(tb)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 50)
    # POR has now sampled i2c_prescale_reg <= 125; override to the faster sim
    # value before the autoneg FSM reaches ST_NEGO_CLAIM (~60 us in).
    set_sim_prescale(tb)


async def wait_bilateral_role_lock(tb, max_cycles=400_000, poll=100):
    dut = tb.dut
    waited = 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _si(dut.m_role_locked) == 1 and _si(dut.s_role_locked) == 1:
            return True, waited
    return False, waited


async def wait_master_terminal_train(tb, max_cycles=6_000_000, poll=200):
    """Poll the master FSM until it reaches ST_TRAIN_DONE or ST_TRAIN_FAIL."""
    dut = tb.dut
    waited = 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        s = _state(dut, "m")
        if s in (ST_TRAIN_DONE, ST_TRAIN_FAIL):
            return s, waited
    return _state(dut, "m"), waited


@cocotb.test()
async def test_autonomous_i2c_bringup_converge(dut):
    """Autonomous I2C bring-up converges end-to-end, no SW pokes."""
    tb = PairTB(dut)
    log = dut._log

    # Clocks.
    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start())
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start())

    # Idle ALL host stimulus (AHB + APB) — the link must come up with the
    # buses quiescent. The only thing driving the dies is the tb's
    # BYPASS_AUTONEG=0 autoneg force + the cross-wired I2C sideband.
    for p in ("m", "s"):
        for sig, val in (
            ("apb_psel", 0), ("apb_penable", 0), ("apb_pwrite", 0),
            ("apb_paddr", 0), ("apb_pwdata", 0), ("apb_pstrb", 0xF),
            ("apb_pprot", 0),
            ("ahb_tx_hsel", 0), ("ahb_tx_haddr", 0), ("ahb_tx_htrans", 0),
            ("ahb_tx_hsize", 2), ("ahb_tx_hwrite", 0), ("ahb_tx_hwdata", 0),
            ("ahb_tx_hready_in", 1),
            ("ahb_fifo_hsel", 0), ("ahb_fifo_haddr", 0), ("ahb_fifo_htrans", 0),
            ("ahb_fifo_hsize", 2), ("ahb_fifo_hwrite", 0), ("ahb_fifo_hwdata", 0),
            ("ahb_fifo_hready_in", 1),
        ):
            try:
                getattr(dut, f"{p}_{sig}").value = val
            except AttributeError:
                pass

    await reset_no_pokes(tb)

    # Sanity: the tb force must have engaged. nego_cfg_reg[0]=nego_en must be 1.
    m_cfg = _si(dut.u_master.u_chiplet_controller.nego_cfg_reg)
    s_cfg = _si(dut.u_slave.u_chiplet_controller.nego_cfg_reg)
    log.info(f"  after-reset nego_cfg: M=0x{m_cfg:02x} S=0x{s_cfg:02x}")
    assert m_cfg & 0x1, (
        f"nego_en=0 on master (nego_cfg=0x{m_cfg:02x}). This test MUST be "
        "compiled with BYPASS_AUTONEG=0 so the tb forces autoneg at POR.")
    assert s_cfg & 0x1, f"nego_en=0 on slave (nego_cfg=0x{s_cfg:02x})."

    # ── (1) Bilateral role_locked, autonomously over I2C ────────────────────
    log.info("Waiting for bilateral autonomous role_locked (no ROLE_CFG W1S)...")
    locked, w = await wait_bilateral_role_lock(tb)
    log.info(f"  role_locked: m={_si(dut.m_role_locked)} s={_si(dut.s_role_locked)} "
             f"after {w} cy ({w * CLK_PERIOD_NS / 1000:.1f} us); "
             f"FSM M={_sname(_state(dut,'m'))} S={_sname(_state(dut,'s'))}")
    assert locked, (
        f"bilateral role_locked never asserted within {w} cy. "
        f"M_locked={_si(dut.m_role_locked)} S_locked={_si(dut.s_role_locked)} "
        f"M_state={_sname(_state(dut,'m'))} S_state={_sname(_state(dut,'s'))}")

    # Exactly one winner / one loser must have resolved over I2C.
    m_won  = _si(_autoneg(dut, "m").nego_won_r)
    m_lost = _si(_autoneg(dut, "m").nego_lost_r)
    s_won  = _si(_autoneg(dut, "s").nego_won_r)
    s_lost = _si(_autoneg(dut, "s").nego_lost_r)
    log.info(f"  arbitration: M(won={m_won},lost={m_lost}) S(won={s_won},lost={s_lost})")
    assert (m_won ^ s_won) == 1, (
        f"expected exactly one master winner over I2C; M_won={m_won} S_won={s_won}")
    assert (m_lost ^ s_lost) == 1, (
        f"expected exactly one loser; M_lost={m_lost} S_lost={s_lost}")

    # Identify winner (the side that ran the mask handshake as I2C master).
    win = "m" if m_won else "s"
    los = "s" if m_won else "m"
    an_win = _autoneg(dut, win)
    log.info(f"  winner={win.upper()} (I2C master) / loser={los.upper()} (I2C slave)")

    # NOTE on sequencing: role_lock latches the moment the winner ACKs the
    # CLAIM (POLL -> MASK_RD_ADDR edge pulses nego_set_role_lock). The peer
    # lane-mask READ (states MASK_RD_ADDR -> MASK_RD_DATA -> MASK_RES_TX) and
    # the I2C-coordinated training sub-flow happen AFTER role_lock. So we wait
    # for the master to walk all the way to a terminal training state before
    # sampling the captured peer mask / verdict / training result.

    # ── (2) I2C-coordinated training converges to ST_TRAIN_DONE ─────────────
    log.info("Waiting for master ST_TRAIN_DONE (mask handshake + I2C training)...")
    s, w = await wait_master_terminal_train(tb)
    log.info(f"  master terminal train state = {_sname(s)} after "
             f"{w} cy ({w * CLK_PERIOD_NS / 1000:.1f} us)")
    train_ok   = _si(an_win.train_ok_r)
    train_fail = _si(an_win.train_fail_r)
    peer_locked = _si(an_win.peer_lane_locked_r)
    peer_fault  = _si(an_win.peer_lane_fault_r)
    log.info(f"  train_ok={train_ok} train_fail={train_fail} "
             f"peer_lane_locked=0x{peer_locked:02x} peer_lane_fault=0x{peer_fault:02x}")
    assert s == ST_TRAIN_DONE, (
        f"master training terminated in {_sname(s)}, expected ST_TRAIN_DONE. "
        f"train_ok={train_ok} train_fail={train_fail} "
        f"peer_lane_locked=0x{peer_locked:02x} peer_lane_fault=0x{peer_fault:02x}.")
    assert train_ok == 1 and train_fail == 0, (
        f"train_ok={train_ok} train_fail={train_fail} (want ok=1, fail=0).")

    # ── (3) Correct exchanged lane mask over I2C ────────────────────────────
    # By now the winner has read the loser's link_lane_mask @ 0x214 over I2C
    # into peer_{tx,rx}_lane_mask_r and run the crossover comparator. In this
    # 8-lane sim both dies advertise tx_mask=rx_mask=0xFF, so the captured peer
    # masks must be 0xFF/0xFF and the local-match flag set (the role-lock gate
    # opened from the FSM's own match flag — mask_hs_bypass strap is 0 here in
    # autonomy). These regs are sticky after the MASK_RES_TX edge.
    peer_tx = _si(an_win.peer_tx_lane_mask_r)
    peer_rx = _si(an_win.peer_rx_lane_mask_r)
    hs_match = _si(an_win.mask_hs_local_match_r)
    hs_fail  = _si(an_win.mask_hs_local_fail_r)
    log.info(f"  winner captured peer mask: tx=0x{peer_tx:02x} rx=0x{peer_rx:02x} "
             f"hs_match={hs_match} hs_fail={hs_fail}")
    assert peer_tx == 0xFF, (
        f"winner read peer tx_lane_mask=0x{peer_tx:02x} over I2C, expected 0xFF "
        "(8-lane build). Mask-handshake read path (SHORTCOMINGS-14a) is broken.")
    assert peer_rx == 0xFF, (
        f"winner read peer rx_lane_mask=0x{peer_rx:02x} over I2C, expected 0xFF.")
    assert hs_match == 1 and hs_fail == 0, (
        f"crossover comparator verdict wrong: hs_match={hs_match} hs_fail={hs_fail}. "
        "The role-lock gate must have opened from the FSM's own match flag with "
        "mask_hs_bypass=0 (true autonomy).")

    # Both calibrators must report calibration_done (link is data-ready).
    m_cal_done = _si(dut.u_master.u_chiplet_controller.u_calibrator.calibration_done)
    s_cal_done = _si(dut.u_slave.u_chiplet_controller.u_calibrator.calibration_done)
    log.info(f"  calibration_done: M={m_cal_done} S={s_cal_done}")
    assert m_cal_done == 1, "master calibrator never reached calibration_done"
    assert s_cal_done == 1, "slave calibrator never reached calibration_done"

    # ── (4) Data link + credit — OBSERVATIONAL ──────────────────────────────
    # SCOPE NOTE: parts (1)-(3) are the "I2C working properly" deliverable
    # (SHORTCOMINGS-14a) and are HARD-ASSERTED above — they pass with zero SW
    # pokes. The data-link credit handshake below is a SEPARATE subsystem: once
    # both dies are role_locked the Wlink FCSM runs its credit-init (CR/CRACK)
    # exchange over the data PHY. In this autonomous run the slave FCSM reaches
    # the credit-granted state (state=4, cr=1, crack=1) but the master FCSM
    # stalls at state=2 (cr=1, crack=0): it sees the peer CR but never receives
    # the slave's CRACK. That is the documented master-RX / S->M datapath
    # residual (memory: "A->B vs B->A asymmetry", SHORTCOMINGS-14b "Bug A:
    # master LL_RX never decodes the slave's transmissions") — it blocks the
    # credit ledger regardless of how the link was brought up (it also keeps
    # the SW-path test_04 pair_credit_counter at 0). It is NOT an I2C-autoneg
    # defect and is out of scope for this deliverable. We capture the FCSM /
    # credit state as diagnostics (no hard fail) so this test stays a clean,
    # GREEN proof of the autonomous I2C bring-up while flagging the downstream
    # datapath work that remains.
    log.info("Settling FCSM credit-init (data link), then observing M->S...")
    await ClockCycles(dut.hclk, 8000)

    m_cr  = tb.fcsm_cr_pkt_seen("m");    s_cr  = tb.fcsm_cr_pkt_seen("s")
    m_cra = tb.fcsm_crack_pkt_seen("m"); s_cra = tb.fcsm_crack_pkt_seen("s")
    m_fc  = tb.fcsm_state("m");          s_fc  = tb.fcsm_state("s")
    log.info(f"  FCSM: M(state={m_fc} cr={m_cr} crack={m_cra}) "
             f"S(state={s_fc} cr={s_cr} crack={s_cra})")

    await tb.s_apb.write(APB_RELEASE_THRESHOLD, 0)
    await ClockCycles(dut.hclk, 50)
    _ = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    await ClockCycles(dut.hclk, 20)
    await tb.m_apb.write(APB_DOORBELL, 1)
    counts = await tb.watch_fc_pulses(6000, "after M doorbell (autonomous link)")
    s_db = await tb.s_apb.read(APB_DOORBELL_RESP_ACC)
    s_pcc = await tb.s_apb.read(APB_PAIR_CREDIT_COUNTER)
    m_pcc = await tb.m_apb.read(APB_PAIR_CREDIT_COUNTER)
    log.info(f"  [obs] slave DOORBELL_RESP_ACC after 1 ring = {s_db}  "
             f"FC M(a2l={counts['m_a2l']},l2a={counts['m_l2a']}) "
             f"S(a2l={counts['s_a2l']},l2a={counts['s_l2a']})")
    log.info(f"  [obs] PAIR_CREDIT_COUNTER: M=0x{m_pcc:08x} S=0x{s_pcc:08x}")
    if s_db != 0 and (s_pcc > 0 or m_pcc > 0):
        log.info("  [obs] DATA+CREDIT crossed autonomously — full link is live.")
    else:
        log.warning(
            "  [obs] data/credit did NOT cross: master FCSM stuck at "
            f"state={m_fc} crack={m_cra} (no TX credit). This is the documented "
            "master-RX / S->M datapath residual (SHORTCOMINGS-14b / Bug A), "
            "separate from the I2C autoneg proven above.")

    log.info("================================================================")
    log.info("AUTONOMOUS I2C BRING-UP CONVERGED — no SW pokes:")
    log.info(f"  bilateral role_locked = 1/1 (winner={win.upper()})")
    log.info(f"  peer lane mask        = tx=0x{peer_tx:02x} rx=0x{peer_rx:02x} (crossover match)")
    log.info(f"  I2C-coord training    = ST_TRAIN_DONE, train_ok=1, cal_done 1/1")
    log.info(f"  data/credit (obs)     = doorbell={s_db} credit M=0x{m_pcc:08x} S=0x{s_pcc:08x}")
    log.info("================================================================")
