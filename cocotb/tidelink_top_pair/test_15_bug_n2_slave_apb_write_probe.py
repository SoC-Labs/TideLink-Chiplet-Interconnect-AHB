"""Bug N2 probe — slave APB write path during ST_TRAIN_ENTER.

Background
----------
After Bug N1 fixes (mask_hs_in_progress + i2c_prescale POR) at HEAD 5a87158,
test_10_autonomous_train_post_por now advances master into ST_TRAIN_ENTER
(state 12) and then on to ST_TRAIN_RUN (state 13), confirming the master's
I²C-write to peer's SWI_TRAINING_MODE @ 0x2100 is being ACK'd by the slave's
i2c_slave block. However, the *master* parks in ST_TRAIN_FAIL (state 17)
~13 ms later because the slave's `swi_training_mode_r` register NEVER
transitions to 1, so the slave never enters training, peer_lane_locked
stays 0x00, peer_cal_done stays 0, and the poll-peer timeout fires.

Master's autoneg FSM (tidelink_autoneg.sv:911-953) in ST_TRAIN_ENTER:
  1. I²C-writes 6 bytes (0x21, 0x00, train_value, 0x00, 0x00, 0x00) to peer.
  2. On peer ACK → pulses local_train_set_pulse_r (sets master's local
     swi_training_mode_r=1, confirmed in test_10 log).
  3. Advances to ST_TRAIN_RUN.

So the I²C transaction reached the slave's i2c_slave_axil_master and
got ACK'd (the master's FSM saw bvalid). But the bytes never landed in
slave's chiplet-controller Region 8 SWI_TRAINING_MODE register.

Path on slave side:
  SCL/SDA → u_i2c_slave (i2c_slave_axil_master)
         → slv_axil_{awaddr,awvalid,wdata,wvalid,bvalid}
         → u_axil2apb (mkaxil2apb_bridge)
         → slv_apb_{psel,paddr,pwrite,pwdata,penable,pready}
         → wl_apb_* mux (axi_chiplet_controller.sv:1391-1432)
         → Wlink core APB port

NOTE the path goes to *Wlink*, not to the chiplet-controller's Region 8.
The Region 8 SWI_TRAINING_MODE register is written via `ctrl_reg_write`
which comes from `tidelink_apb_regs` driven by the *external* APB master
(CPU/AHB), NOT from the I²C-slave's internal AXIL→APB bridge. We probe
this hypothesis here.

We trace, while master is in ST_TRAIN_ENTER:
  - Master i2c_master_axil AXIL transactions (awvalid, awready, awaddr,
    wdata, bvalid, missed_ack)
  - I²C bus pins (scl, sda + per-side tristate enables)
  - Slave I²C-slave state (i2c_slv_busy, i2c_slv_addressed)
  - Slave AXIL master (u_i2c_slave): awvalid, awready, awaddr, wdata,
    wvalid, wready, bvalid
  - Slave APB ingress (slv_apb_*): psel, paddr, penable, pwrite, pwdata
  - Slave APB gate: slv_apb_active, role_is_master, apb_debug_unlock_i
  - Slave chiplet-controller Region 8 inputs: ctrl_reg_write, ctrl_reg_addr,
    ctrl_reg_wdata, region8_write
  - Slave swi_training_mode_r value
  - Slave Wlink APB mux outputs: wl_apb_psel, wl_apb_paddr, wl_apb_pwrite,
    wl_apb_pready

INFO-only — no assertions. Bounded to ~20 ms.

Run
---
    cd cocotb/tidelink_top_pair
    TB_TOP_NO_DUMP=1 BYPASS_AUTONEG=0 \
        TESTCASE=test_15_bug_n2_slave_apb_write_probe \
        make MODULE=test_15_bug_n2_slave_apb_write_probe
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

ST_TRAIN_ENTER = 12
ST_TRAIN_RUN   = 13
ST_TRAIN_POLL  = 14
ST_TRAIN_EXIT  = 15
ST_TRAIN_FAIL  = 17


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _safe_hex(sig, width=4, default="?"):
    v = _safe_int(sig)
    if v < 0:
        return default
    return f"{v:0{width}x}"


def _has(parent, name):
    """True if hierarchy `parent` has attribute `name` (cocotb handle exists)."""
    try:
        _ = getattr(parent, name)
        return True
    except (AttributeError, KeyError):
        return False


@cocotb.test()
async def test_15_bug_n2_slave_apb_write_probe(dut):
    log = dut._log
    log.info("Bug N2 probe — slave APB-write path during ST_TRAIN_ENTER")

    cocotb.start_soon(Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start())
    cocotb.start_soon(Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start())

    # ---- Idle all external stim ----
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

    # ---- Reset ----
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # ---- Hierarchy handles ----
    m_ctl = dut.u_master.u_chiplet_controller
    s_ctl = dut.u_slave.u_chiplet_controller
    m_an  = m_ctl.u_autoneg
    s_an  = s_ctl.u_autoneg

    # Master I²C path
    m_i2cm      = m_ctl.u_i2c_master.i2c_master_inst
    m_i2cm_axil = m_ctl.u_i2c_master

    # Slave I²C path
    s_i2cs        = s_ctl.u_i2c_slave.i2c_slave_inst  # core
    s_i2cs_wrap   = s_ctl.u_i2c_slave                 # i2c_slave_axil_master wrapper
    s_axil2apb    = s_ctl.u_axil2apb                  # mkaxil2apb_bridge

    # ---- Wait for master to enter ST_TRAIN_ENTER (state 12) ----
    log.info("Waiting for master FSM state_r = 12 (ST_TRAIN_ENTER)...")
    target_cycles = 5_000_000 // int(CLK_PERIOD_NS)  # 5 ms cap to reach state 12
    waited = 0
    poll = 500
    entered = False
    while waited < target_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _safe_int(m_an.state_r) == ST_TRAIN_ENTER:
            entered = True
            break

    t_now_ns = cocotb.utils.get_sim_time(unit="ns")
    log.info(
        f"ST_TRAIN_ENTER entry: entered={entered} after {waited} cycles "
        f"({waited * CLK_PERIOD_NS / 1000:.1f} µs), sim {t_now_ns:.0f} ns"
    )
    if not entered:
        log.error(
            f"PREREQ FAIL — master never reached ST_TRAIN_ENTER. "
            f"final m.state={_safe_int(m_an.state_r)} s.state={_safe_int(s_an.state_r)}"
        )
        return

    # ---- Initial snapshot at state-12 entry ----
    log.info("---- AT ST_TRAIN_ENTER ENTRY ----")
    log.info(
        f"M.ctl: role_locked={_safe_int(m_ctl.role_lock_reg)} "
        f"role_is_master={_safe_int(m_ctl.role_is_master)} "
        f"nego_driving={_safe_int(m_ctl.nego_driving)} "
        f"mask_hs_in_progress={_safe_int(m_ctl.mask_hs_in_progress)}"
    )
    log.info(
        f"S.ctl: role_locked={_safe_int(s_ctl.role_lock_reg)} "
        f"role_is_master={_safe_int(s_ctl.role_is_master)} "
        f"apb_debug_unlock_i={_safe_int(s_ctl.apb_debug_unlock_i)} "
        f"i2c_slv_reset={_safe_int(s_ctl.i2c_slv_reset)} "
        f"i2c_slv_addr_reg={_safe_int(s_ctl.i2c_slv_addr_reg):#x} "
        f"swi_training_mode_r={_safe_int(s_ctl.swi_training_mode_r)}"
    )
    log.info(
        f"M.fsm: state_r={_safe_int(m_an.state_r)} txn_step_r={_safe_int(m_an.txn_step_r)} "
        f"axl_state_r={_safe_int(m_an.axl_state_r)} mask_byte_cnt_r={_safe_int(m_an.mask_byte_cnt_r)} "
        f"train_target_value_r={_safe_int(m_an.train_target_value_r)}"
    )
    log.info(
        f"Pins: scl={_safe_int(dut.i2c_scl)} sda={_safe_int(dut.i2c_sda)} | "
        f"M scl_t/sda_t={_safe_int(dut.m_i2c_scl_t)}/{_safe_int(dut.m_i2c_sda_t)} "
        f"S scl_t/sda_t={_safe_int(dut.s_i2c_scl_t)}/{_safe_int(dut.s_i2c_sda_t)}"
    )

    # =====================================================================
    # Dense probe — log on key-signal change.
    # PROBE_CYCLES = 1_000_000 cycles = 20 ms @ 50 MHz hclk.
    # =====================================================================
    log.info("=== DENSE PROBE BEGIN (cap 20 ms; log on change or every 50k cycles) ===")
    PROBE_CYCLES = 1_000_000
    prev_key = None
    last_log_cyc = -10**9
    aw_seen_this_burst = 0
    bv_seen_this_burst = 0
    # Edge-event counters (one increment per rising-edge sample-window)
    slv_awvalid_rises = 0
    slv_apb_psel_rises = 0
    slv_apb_pwrite_writes = 0  # count of cycles where slv_apb_active && slv_apb_psel && slv_apb_pwrite && slv_apb_penable
    region8_write_count = 0
    wl_apb_pready_count = 0
    swi_training_mode_changes = 0
    prev_swi_tm = _safe_int(s_ctl.swi_training_mode_r)

    # Per-state log so we know which phase we're in
    last_state = -1
    state_transitions = []

    for c in range(PROBE_CYCLES):
        await ClockCycles(dut.hclk, 1)

        # === Sample key signals ===
        m_state         = _safe_int(m_an.state_r)
        m_txn           = _safe_int(m_an.txn_step_r)
        m_axl           = _safe_int(m_an.axl_state_r)
        m_axl_done      = _safe_int(m_an.axl_done_r)
        m_bcnt          = _safe_int(m_an.mask_byte_cnt_r)
        m_target        = _safe_int(m_an.train_target_value_r)
        # Master AXIL toward i2c_master_axil
        m_aw_v          = _safe_int(m_ctl.mst_axil_awvalid)  if _has(m_ctl, 'mst_axil_awvalid')  else -1
        m_aw_r          = _safe_int(m_ctl.mst_axil_awready)
        m_aw_addr       = _safe_int(m_ctl.mst_axil_awaddr)   if _has(m_ctl, 'mst_axil_awaddr')   else -1
        m_w_v           = _safe_int(m_ctl.mst_axil_wvalid)   if _has(m_ctl, 'mst_axil_wvalid')   else -1
        m_w_data        = _safe_int(m_ctl.mst_axil_wdata)    if _has(m_ctl, 'mst_axil_wdata')    else -1
        m_b_v           = _safe_int(m_ctl.mst_axil_bvalid)
        m_mack          = _safe_int(m_i2cm_axil.missed_ack_reg) if _has(m_i2cm_axil, 'missed_ack_reg') else -1
        m_i2cm_state    = _safe_int(m_i2cm.state_reg)

        # I²C pins
        scl             = _safe_int(dut.i2c_scl)
        sda             = _safe_int(dut.i2c_sda)
        m_scl_t         = _safe_int(dut.m_i2c_scl_t)
        m_sda_t         = _safe_int(dut.m_i2c_sda_t)
        s_scl_t         = _safe_int(dut.s_i2c_scl_t)
        s_sda_t         = _safe_int(dut.s_i2c_sda_t)

        # Slave I²C-slave core
        s_i2cs_state    = _safe_int(s_i2cs.state_reg)
        s_addressed     = _safe_int(s_ctl.i2c_slv_addressed)
        s_slv_busy      = _safe_int(s_ctl.i2c_slv_busy)

        # Slave AXIL master outputs (i2c_slave_axil_master wrapper)
        s_axil_aw_v     = _safe_int(s_i2cs_wrap.m_axil_awvalid)
        s_axil_aw_r     = _safe_int(s_i2cs_wrap.m_axil_awready)
        s_axil_aw_addr  = _safe_int(s_i2cs_wrap.m_axil_awaddr)
        s_axil_w_v      = _safe_int(s_i2cs_wrap.m_axil_wvalid)
        s_axil_w_data   = _safe_int(s_i2cs_wrap.m_axil_wdata)
        s_axil_w_r      = _safe_int(s_i2cs_wrap.m_axil_wready)
        s_axil_b_v      = _safe_int(s_i2cs_wrap.m_axil_bvalid)

        # Slave AXIL→APB bridge outputs (slv_apb_*) — at module scope of axi_chiplet_controller
        s_apb_psel      = _safe_int(s_ctl.slv_apb_psel)
        s_apb_paddr     = _safe_int(s_ctl.slv_apb_paddr)
        s_apb_penable   = _safe_int(s_ctl.slv_apb_penable)
        s_apb_pwrite    = _safe_int(s_ctl.slv_apb_pwrite)
        s_apb_pwdata    = _safe_int(s_ctl.slv_apb_pwdata)
        s_apb_active    = _safe_int(s_ctl.slv_apb_active)

        # Slave Wlink-APB mux outputs (wl_apb_*) — the actual APB seen by Wlink
        s_wl_psel       = _safe_int(s_ctl.wl_apb_psel)
        s_wl_paddr      = _safe_int(s_ctl.wl_apb_paddr)
        s_wl_pwrite     = _safe_int(s_ctl.wl_apb_pwrite)
        s_wl_pwdata     = _safe_int(s_ctl.wl_apb_pwdata)
        s_wl_pready     = _safe_int(s_ctl.wl_apb_pready)

        # Slave chiplet-controller register-decode inputs
        s_ctrl_w        = _safe_int(s_ctl.ctrl_reg_write)
        s_ctrl_addr     = _safe_int(s_ctl.ctrl_reg_addr)
        s_ctrl_wdata    = _safe_int(s_ctl.ctrl_reg_wdata)
        s_region8_w     = _safe_int(s_ctl.region8_write)
        s_swi_tm        = _safe_int(s_ctl.swi_training_mode_r)

        # === Event counters ===
        if prev_key is not None:
            if s_axil_aw_v == 1 and prev_key.get('s_axil_aw_v') == 0:
                slv_awvalid_rises += 1
            if s_apb_psel == 1 and prev_key.get('s_apb_psel') == 0:
                slv_apb_psel_rises += 1
            if (s_apb_active == 1 and s_apb_psel == 1 and
                s_apb_pwrite == 1 and s_apb_penable == 1 and
                prev_key.get('s_apb_penable') == 0):
                slv_apb_pwrite_writes += 1
            if s_region8_w == 1 and prev_key.get('s_region8_w') == 0:
                region8_write_count += 1
            if s_wl_pready == 1 and prev_key.get('s_wl_pready') == 0 and s_wl_psel == 1:
                wl_apb_pready_count += 1
            if s_swi_tm != prev_swi_tm:
                swi_training_mode_changes += 1
                prev_swi_tm = s_swi_tm
                log.info(
                    f"+{c:6d} ** SLAVE swi_training_mode_r changed → {s_swi_tm} **"
                )

        # === State-transition log ===
        if m_state != last_state:
            t = cocotb.utils.get_sim_time(unit="ns")
            log.info(
                f"+{c:6d} t={t:.0f}ns ** M.state {last_state} → {m_state} "
                f"(txn={m_txn}, axl={m_axl}, bcnt={m_bcnt}) **"
            )
            state_transitions.append((c, last_state, m_state))
            last_state = m_state

        # === Build key for change-detection ===
        key = {
            'm_state': m_state, 'm_txn': m_txn, 'm_axl': m_axl, 'm_axl_done': m_axl_done,
            'm_bcnt': m_bcnt,
            'm_aw_v': m_aw_v, 'm_b_v': m_b_v, 'm_mack': m_mack, 'm_i2cm_state': m_i2cm_state,
            'scl': scl, 'sda': sda,
            's_i2cs_state': s_i2cs_state, 's_addressed': s_addressed, 's_slv_busy': s_slv_busy,
            's_axil_aw_v': s_axil_aw_v, 's_axil_w_v': s_axil_w_v, 's_axil_b_v': s_axil_b_v,
            's_apb_psel': s_apb_psel, 's_apb_penable': s_apb_penable, 's_apb_pwrite': s_apb_pwrite,
            's_apb_active': s_apb_active,
            's_wl_psel': s_wl_psel, 's_wl_pready': s_wl_pready,
            's_ctrl_w': s_ctrl_w, 's_region8_w': s_region8_w, 's_swi_tm': s_swi_tm,
        }

        changed = (prev_key is None) or any(key[k] != prev_key.get(k) for k in key)
        force = (c - last_log_cyc) >= 50_000

        if changed or force:
            t = cocotb.utils.get_sim_time(unit="ns")
            log.info(
                f"+{c:6d} t={t:.0f}ns | "
                f"M.st={m_state:2d} tx={m_txn} axl={m_axl} done={m_axl_done} "
                f"bcnt={m_bcnt} | I2CM.st={m_i2cm_state:2d} mack={m_mack} | "
                f"scl={scl} sda={sda} (M_t={m_scl_t}/{m_sda_t} S_t={s_scl_t}/{s_sda_t}) | "
                f"I2CS.st={s_i2cs_state:2d} addr={s_addressed} busy={s_slv_busy} | "
                f"S.AXIL: aw_v={s_axil_aw_v} aw_r={s_axil_aw_r} "
                f"aw_addr={s_axil_aw_addr:#06x} "
                f"w_v={s_axil_w_v} w_d={s_axil_w_data:#x} b_v={s_axil_b_v} | "
                f"S.APB: act={s_apb_active} sel={s_apb_psel} pen={s_apb_penable} "
                f"pwr={s_apb_pwrite} addr={s_apb_paddr:#06x} "
                f"wd={s_apb_pwdata:#x} | "
                f"S.WL: sel={s_wl_psel} pwr={s_wl_pwrite} pry={s_wl_pready} "
                f"addr={s_wl_paddr:#06x} | "
                f"S.ctrl_w={s_ctrl_w} ctrl_addr={s_ctrl_addr:#x} reg8_w={s_region8_w} "
                f"swi_tm={s_swi_tm}"
            )
            last_log_cyc = c

        prev_key = key

        # === Early-exit conditions ===
        if m_state == ST_TRAIN_FAIL:
            log.info(f"+{c} master entered ST_TRAIN_FAIL — probe captures complete cause.")
            # Give 100 more cycles to log the post-FAIL settle.
            for k in range(100):
                await ClockCycles(dut.hclk, 1)
            break
        if m_state == ST_TRAIN_EXIT:
            log.info(f"+{c} master entered ST_TRAIN_EXIT — training completed (unexpected here).")
            break

    # =====================================================================
    log.info("=== DENSE PROBE END ===")
    log.info("")
    log.info("--- EVENT TALLY ---")
    log.info(f"State transitions seen (master):")
    for (cyc, src, dst) in state_transitions:
        log.info(f"    +{cyc:6d} : state {src} → {dst}")
    log.info(f"")
    log.info(f"slv_axil_awvalid 0→1 rises          : {slv_awvalid_rises}")
    log.info(f"slv_apb_psel    0→1 rises           : {slv_apb_psel_rises}")
    log.info(f"slv_apb writes accepted (active+sel+wr+penable rising) : {slv_apb_pwrite_writes}")
    log.info(f"region8_write   0→1 rises (chiplet) : {region8_write_count}")
    log.info(f"wl_apb_pready   on Wlink ports      : {wl_apb_pready_count}")
    log.info(f"swi_training_mode_r changes (slave) : {swi_training_mode_changes}")
    log.info("")
    log.info("--- FINAL STATE ---")
    log.info(
        f"M.fsm: state_r={_safe_int(m_an.state_r)} "
        f"swi_tm_r={_safe_int(m_ctl.swi_training_mode_r)} "
        f"peer_lane_locked={_safe_int(m_an.peer_lane_locked_r):#x} "
        f"peer_cal_done={_safe_int(m_an.peer_cal_done_r)} "
        f"train_fail={_safe_int(m_an.train_fail_r)}"
    )
    log.info(
        f"S.ctl: state_r={_safe_int(s_an.state_r)} "
        f"swi_tm_r={_safe_int(s_ctl.swi_training_mode_r)} "
        f"role_is_master={_safe_int(s_ctl.role_is_master)} "
        f"apb_debug_unlock_i={_safe_int(s_ctl.apb_debug_unlock_i)}"
    )

    # ----- DIAGNOSIS HINTS -----
    log.info("")
    log.info("--- DIAGNOSIS HINTS ---")
    if swi_training_mode_changes == 0:
        log.info("HINT: slave swi_training_mode_r NEVER changed — confirms Bug N2 signature.")
    if slv_awvalid_rises == 0 and slv_apb_psel_rises == 0:
        log.info("HINT: slave AXIL+APB ingress NEVER fired — write got dropped INSIDE i2c_slave_axil_master core.")
    elif slv_awvalid_rises > 0 and slv_apb_psel_rises == 0:
        log.info("HINT: slave AXIL fired but APB ingress didn't — AXIL→APB bridge dropped the write.")
    elif slv_apb_psel_rises > 0 and region8_write_count == 0:
        log.info(
            "HINT: slave APB ingress fired but region8_write NEVER asserted — "
            "the I²C-driven APB write is routed to wl_apb_* (Wlink), NOT to "
            "tidelink_apb_regs/Region 8. This is the structural Bug N2."
        )
    if region8_write_count > 0 and swi_training_mode_changes == 0:
        log.info("HINT: region8_write asserted but training_mode unchanged — wrong ctrl_reg_addr slot.")
