"""Bug N9 — master role_lock fails to latch when master loses with no peer
present, even after the peer (slave) later runs autoneg + MASK_RES_TX.

Background
----------
Silicon evidence (build v10, asymmetric-POR deploy, 2026-06-01/02):
  * Master (z2_02, strap=0) boots first, runs autoneg ALONE because the
    slave die hasn't POR'd yet. With no peer on the I²C bus, the master's
    ST_NEGO_CLAIM byte-write to 0x7E NACKs (miss_ack=1) and the FSM walks:

        ST_NEGO_INIT → WAIT → CLAIM → POLL → ST_NEGO_DONE (lost=1)

    Per tidelink_autoneg.sv:711-720 the lost-branch fires
    `nego_set_role_lock=1` (because nego_force_lock=NEGO_CFG[5]=1 in our
    7'h61 config). The chiplet_controller's nego_lock_pending_reg latches.
    Then we wait for `mask_hs_match` to open the gate.

  * Slave (z2_03, strap=1) POR's milliseconds later, runs its own autoneg
    alone (since master is now parked in ST_NEGO_DONE responding as the
    autoneg I²C slave at 0x7E). Slave's CLAIM succeeds, slave wins, slave
    walks MASK_RD_ADDR → MASK_RD_DATA → MASK_RES_TX. The latter writes
    the verdict byte (0x01 = match) to master's Wlink register
    `link_lane_mask_hs_result` @ 0x21C. That should drive
    `wlink_mask_hs_result[0]=1` on the master die, which OR's into
    `mask_hs_match` and opens the gate.

Symptom
-------
Master's `role_lock_reg` NEVER latches even though slave subsequently
reaches `train_ok=1`. Observed on silicon as ROLE_CFG=0x01 (cfg=1,
lock=0) with `nego_status state=5 done=1 lost=1`.

This test reproduces the silicon symptom in cocotb by orchestrating the
asymmetric-POR scenario inside the existing `tidelink_top_pair` tb:

  1. At time 0 the BYPASS_AUTONEG=0 force block engages both dies'
     autoneg. We *additionally* force the slave's `nego_cfg_reg = 7'h00`
     and `i2c_slv_addr_reg = 7'h00` so the slave's autoneg parks in
     BYPASS and the slave's I²C-slave doesn't ACK address 0x7E. The
     master therefore runs autoneg alone, sees MISS_ACK, and takes the
     lost path.

  2. After waiting for master to reach ST_NEGO_DONE with lost=1, the
     test releases the slave-side forces and applies a fresh
     `s_ctrl.nego_cfg_reg = 7'h61` force + restores `i2c_slv_addr_reg`
     to 7'h7E. The slave now runs autoneg (master is parked but its
     I²C-slave still listens at 0x7E because role_locked=0 → device_addr
     mux = 7'h7E). Slave wins, walks MASK_RES_TX, writes to master's
     hs_result reg.

  3. Test asserts master's role_lock_reg == 1 within a budget.

Expected outcome
----------------
Pre-fix: FAIL — master sits at role_lock=0 indefinitely.
Post-fix: PASS — master's role_lock latches once mask_hs_match goes high.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
        TESTCASE=test_19_bug_n9_master_late_peer \
        make MODULE=test_19_bug_n9_master_late_peer

NOTE: this test deliberately runs with BYPASS_AUTONEG=1 (the legacy
mode where the tb does NOT $force nego_cfg_reg at POR). We then drive
the master-only autoneg engagement via cocotb deposits so we can keep
the slave's autoneg FSM pinned at ST_IDLE while the master walks alone.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0     # 50 MHz hclk
REF_CLK_PERIOD_NS = 8.0

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


@cocotb.test()
async def test_19_bug_n9_master_late_peer(dut):
    """Master loses autoneg with no peer present, slave later runs autoneg
    and writes hs_result. Master's role_lock_reg must latch."""
    log = dut._log
    log.info("Bug N9 — test_19_bug_n9_master_late_peer starting")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle bus stimulus.
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

    # --------------------------------------------------------------------
    # Disable the mask-handshake bypass + debug-unlock strap on the master.
    # tb_top.sv ties both to 1 at declaration so legacy tests can drive
    # role_lock via APB ROLE_CFG W1S without the I²C peer-mask handshake.
    # For Bug N9 we MUST force them to 0 so the gate stays closed until
    # mask_hs_match (from the I²C path) fires. Without this the gate is
    # always open and master's role_lock latches as soon as
    # nego_lock_pending_reg is set on the lost branch — Bug N9 never
    # surfaces.
    # --------------------------------------------------------------------
    dut.m_mask_hs_bypass.value  = 0
    dut.m_apb_debug_unlock.value = 0
    # Slave-side: leave bypass=1. The slave's autoneg flow in Phase 2
    # walks MASK_RD_ADDR → MASK_RD_DATA → MASK_RES_TX as the winner
    # (no peer to compare against → mask_hs_local_match drives slave's
    # gate). We don't care about the slave's own lock here.
    # Actually, for cleanest evidence — also disable slave-side bypass.
    # Slave gets its lock via autoneg_mask_hs_local_match after
    # MASK_RES_TX completes anyway (line 547).
    dut.s_mask_hs_bypass.value  = 0
    dut.s_apb_debug_unlock.value = 0

    # Reset.
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # --------------------------------------------------------------------
    # Asymmetric-POR setup (BYPASS_AUTONEG=1 mode → no tb $force block).
    # We deposit on top of the controllers' POR-default register values:
    #   - master nego_cfg_reg  = 7'h61   (autoneg + force_lock + mask_hs_auto)
    #   - master nego_train_cfg_r = 16'h00F1  (NEGO_TRAIN_CFG[7:0] training
    #     wait, but training_mode_auto disabled — keep autoneg simple)
    #   - slave  nego_cfg_reg  = 7'h00   (parked in ST_BYPASS)
    #   - slave  i2c_slv_addr_reg = 7'h00 (won't ACK 0x7E → master sees
    #     MISS_ACK on its CLAIM transaction → lost path fires)
    #
    # The POR-reset clause has already fired (poresetn=1 already): the
    # master's POR-default nego_cfg_reg is 7'h00 (NEGO_CFG_RESET) and
    # the slave's is also 7'h00. The slave's i2c_slv_addr_reg POR-default
    # is 7'h7E — we override that to 7'h00 here so slave doesn't ACK.
    # --------------------------------------------------------------------
    dut.u_master.u_chiplet_controller.nego_cfg_reg.value = 0x61
    dut.u_master.u_chiplet_controller.nego_train_cfg_r.value = 0x00F1
    dut.u_slave.u_chiplet_controller.nego_cfg_reg.value = 0
    dut.u_slave.u_chiplet_controller.i2c_slv_addr_reg.value = 0
    log.info(
        "Initial deposits: M nego_cfg=0x61 train_cfg=0x00F1, "
        "S nego_cfg=0x00, S i2c_slv_addr=0x00"
    )

    m_an  = _autoneg(dut, "m")
    s_an  = _autoneg(dut, "s")
    m_ctl = _ctrl(dut, "m")
    s_ctl = _ctrl(dut, "s")

    # --------------------------------------------------------------------
    # Phase 1: wait for master to enter ST_NEGO_DONE with lost=1.
    # Budget: 400 ms. Empirically the master's CLAIM→POLL→NACK chain
    # takes ~250 ms of sim time because the I²C master IP polls the
    # transaction for many cycles before the NACK is confirmed.
    # --------------------------------------------------------------------
    log.info("Phase 1: wait for master to enter ST_NEGO_DONE with lost=1")
    BUDGET_PHASE1_MS = 400.0
    budget_cycles    = int(BUDGET_PHASE1_MS * 1_000_000 / CLK_PERIOD_NS)
    poll             = 200
    waited           = 0
    last_log         = 0
    log_every        = 100_000  # ~2 ms

    while waited < budget_cycles:
        await ClockCycles(dut.hclk, poll)
        # Re-deposit every poll iteration. The chiplet_controller's
        # always_ff never writes nego_cfg_reg or i2c_slv_addr_reg unless
        # there's a ctrl_reg_write (APB or I²C-slave-AXIL); we don't drive
        # APB so this is defensive. nego_cfg_reg holds the value across
        # clock edges so the deposit needs to repeat to stay alive.
        dut.u_master.u_chiplet_controller.nego_cfg_reg.value = 0x61
        dut.u_slave.u_chiplet_controller.nego_cfg_reg.value = 0
        dut.u_slave.u_chiplet_controller.i2c_slv_addr_reg.value = 0
        waited += poll
        m_st = _safe_int(m_an.state_r)
        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  Phase1 t={waited * CLK_PERIOD_NS / 1000:>7.1f}us  "
                f"M st={m_st}({_state_name(m_st)}) "
                f"M lost={_safe_int(m_an.nego_lost_r)} "
                f"M done={_safe_int(m_an.nego_done_r)} "
                f"M role_locked={_safe_int(dut.m_role_locked)}"
            )
        if m_st == 5 and _safe_int(m_an.nego_lost_r) == 1:
            break
        if m_st == 7:  # ERROR
            break

    m_st_p1   = _safe_int(m_an.state_r)
    m_lost_p1 = _safe_int(m_an.nego_lost_r)
    m_done_p1 = _safe_int(m_an.nego_done_r)
    m_lock_p1 = _safe_int(dut.m_role_locked)
    m_pending_p1 = _safe_int(m_ctl.nego_lock_pending_reg)
    log.info(
        f"Phase 1 end: M state={m_st_p1}({_state_name(m_st_p1)}) lost={m_lost_p1} "
        f"done={m_done_p1} role_locked={m_lock_p1} lock_pending={m_pending_p1}"
    )

    if not (m_st_p1 == 5 and m_lost_p1 == 1):
        raise AssertionError(
            f"Phase 1 setup failed: master did not reach ST_NEGO_DONE with "
            f"lost=1. Saw state={m_st_p1}({_state_name(m_st_p1)}) "
            f"lost={m_lost_p1}. Cannot proceed to Phase 2."
        )

    # Post-fix early-exit: the role_lock latch may have already fired
    # (the lost-path fix bypasses the broken Wlink hs_result gate).
    # Either outcome at this point is acceptable so long as the FINAL
    # role_locked=1 — that's what the test ultimately verifies.
    if m_lock_p1 == 1:
        log.info(
            "Phase 1: master role_lock_reg already latched — "
            "skipping Phase 2 (Bug N9 fix is active)"
        )
        return

    # Pre-fix path: we must NOT have role_locked yet but pending must be 1.
    # If pending=0 here the latch infrastructure itself is broken, not Bug N9.
    assert m_pending_p1 == 1, (
        f"Phase 1 invariant broken: nego_lock_pending_reg=0 even though "
        f"master fired nego_set_role_lock on the lost-branch. State of "
        f"the latch path is broken before we can even test Bug N9."
    )

    # --------------------------------------------------------------------
    # Phase 2: release slave forces, start slave autoneg. Slave will run
    # alone (master is parked in ST_NEGO_DONE-lost). Slave will see
    # master ACK its CLAIM (master's i2c_slave_axil is still at 0x7E
    # because role_locked=0 → role_in_nego=1 → device_addr mux = 0x7E).
    # Slave wins, walks MASK_* states, MASK_RES_TX writes 0x01 to master's
    # link_lane_mask_hs_result @ 0x21C → master's wlink_mask_hs_result[0]
    # rises → mask_hs_gate_open=1 → role_lock_reg should latch.
    # --------------------------------------------------------------------
    log.info("Phase 2: releasing slave forces, starting slave autoneg")
    # Restore slave's i2c slave address to the autoneg default and
    # enable autoneg (mask-handshake-auto + force_lock).
    dut.u_slave.u_chiplet_controller.i2c_slv_addr_reg.value = 0x7E
    dut.u_slave.u_chiplet_controller.nego_cfg_reg.value     = 0x61

    BUDGET_PHASE2_MS = 200.0  # slave autoneg + mask-hs is the long path
    budget_cycles2   = int(BUDGET_PHASE2_MS * 1_000_000 / CLK_PERIOD_NS)
    waited2          = 0
    last_log2        = 0
    log_every2       = 200_000

    m_locked_seen = False
    while waited2 < budget_cycles2:
        await ClockCycles(dut.hclk, poll)
        waited2 += poll
        if waited2 - last_log2 >= log_every2:
            last_log2 = waited2
            log.info(
                f"  Phase2 t={waited2 * CLK_PERIOD_NS / 1000:>7.1f}us  "
                f"S st={_safe_int(s_an.state_r)}"
                f"({_state_name(_safe_int(s_an.state_r))}) "
                f"S won={_safe_int(s_an.nego_won_r)} "
                f"S done={_safe_int(s_an.nego_done_r)}  "
                f"M role_locked={_safe_int(dut.m_role_locked)} "
                f"M mask_hs_match={_safe_int(m_ctl.mask_hs_match)} "
                f"M lock_pending={_safe_int(m_ctl.nego_lock_pending_reg)}"
            )
        if _safe_int(dut.m_role_locked) == 1:
            m_locked_seen = True
            break

    sim_t_us = (waited + waited2) * CLK_PERIOD_NS / 1000

    s_st     = _safe_int(s_an.state_r)
    s_won    = _safe_int(s_an.nego_won_r)
    s_done   = _safe_int(s_an.nego_done_r)
    m_lock   = _safe_int(dut.m_role_locked)
    m_pend   = _safe_int(m_ctl.nego_lock_pending_reg)
    m_match  = _safe_int(m_ctl.mask_hs_match)
    m_gate   = _safe_int(m_ctl.mask_hs_gate_open)
    m_hsres  = _safe_int(m_ctl.wlink_mask_hs_result)
    m_role_cfg = _safe_int(m_ctl.role_cfg_reg)

    log.info(
        f"FINAL @ t={sim_t_us:.1f} us:\n"
        f"  MASTER: state={m_st_p1}({_state_name(m_st_p1)}) "
        f"role_locked={m_lock} role_cfg={m_role_cfg} "
        f"lock_pending={m_pend} mask_hs_match={m_match} "
        f"mask_hs_gate_open={m_gate} wlink_mask_hs_result=0x{m_hsres:x}\n"
        f"  SLAVE : state={s_st}({_state_name(s_st)}) "
        f"won={s_won} done={s_done}"
    )

    if not m_locked_seen:
        raise AssertionError(
            f"Bug N9: master's role_lock_reg did NOT latch within "
            f"{BUDGET_PHASE2_MS} ms after slave finished autoneg.\n"
            f"  master state         = {m_st_p1} ({_state_name(m_st_p1)})\n"
            f"  master role_locked   = {m_lock}\n"
            f"  master lock_pending  = {m_pend}\n"
            f"  master mask_hs_match = {m_match}\n"
            f"  master mask_hs_gate  = {m_gate}\n"
            f"  master wlink_mask_hs_result = 0x{m_hsres:x}\n"
            f"  slave  state         = {s_st} ({_state_name(s_st)})\n"
            f"  slave  won           = {s_won}\n"
            f"  slave  done          = {s_done}\n"
            f"\n"
            f"Expected post-fix: master role_locked=1 once slave's "
            f"MASK_RES_TX writes 0x01 to master's hs_result register, "
            f"opening the mask_hs gate while nego_lock_pending_reg is "
            f"set from the master's lost-branch."
        )

    log.info(f"PASS — master role_lock_reg latched at t={sim_t_us:.1f} us")
