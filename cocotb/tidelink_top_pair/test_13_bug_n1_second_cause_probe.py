"""Bug N1 second-cause probe — what's still stuck after nego_driving fix-1.

Background
----------
Bug N1 fix-1 (uncommitted in axi_chiplet_controller.sv) extends
`nego_driving` to cover mask-handshake states 8/9/10 even after
`role_locked` latches (the new `mask_hs_in_progress` wire). This
unsticks the AXIL bus mux but the master FSM is STILL parked in
state 9 (ST_NEGO_MASK_RD_ADDR) for the full 20 ms dwell budget,
per /tmp/td_autonomy_test12_postfix_215125.log.

Post-fix-1 signature:
    nego_driving=1  role_in_nego=0  m_role_locked=1

So the AXIL mux is right, but something downstream is wedging the
I²C transaction. This probe captures everything we need to nail it:

  - master autoneg FSM internals (state_r / txn_step_r / axl_state_r /
    axl_done_r / mask_byte_cnt_r / busy_seen_r / axl_rdata_r)
  - full AXIL handshake on master's I2C path:
       m_axil_aw/w/b/ar/r {valid,ready}  (FSM-side)
       mst_axil_aw/w/b/ar/r {valid,ready} (post-mux, into i2c_master_axil)
       bridge_axil_bvalid (should stay 0 while nego_driving=1)
  - master/slave i2c_*_reset signals (look for glitches mid-state)
  - master i2c_master IP state (state_reg, bus_active, missed_ack)
  - slave i2c_slave IP state (state_reg, bus_addressed, bus_active)
  - SCL/SDA pins + per-side {scl,sda}_t enables (who's holding bus?)
  - both dies' role_locked / role_in_nego / nego_driving / nego_state_w

We log on ANY change of key signals, plus periodic snapshots, for
~5000 cycles (100 µs) after master enters state 9.

Run
---
    cd cocotb/tidelink_top_pair
    TB_TOP_NO_DUMP=1 BYPASS_AUTONEG=0 \
        TESTCASE=test_13_bug_n1_second_cause_probe \
        make MODULE=test_13_bug_n1_second_cause_probe
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

ST_NEGO_MASK_RD_ADDR = 9


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


@cocotb.test()
async def test_13_bug_n1_second_cause_probe(dut):
    log = dut._log
    log.info("Bug N1 second-cause probe (post-fix-1)")

    cocotb.start_soon(Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start())
    cocotb.start_soon(Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start())

    # Idle all stim.
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

    # Reset
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Hierarchy handles
    m_ctl = dut.u_master.u_chiplet_controller
    s_ctl = dut.u_slave.u_chiplet_controller
    m_an  = m_ctl.u_autoneg
    s_an  = s_ctl.u_autoneg

    m_i2cm      = m_ctl.u_i2c_master.i2c_master_inst
    m_i2cm_axil = m_ctl.u_i2c_master
    s_i2cs      = s_ctl.u_i2c_slave.i2c_slave_inst

    # ---- Wait for master to enter state 9 ----
    log.info("Waiting for master FSM state_r = 9 (ST_NEGO_MASK_RD_ADDR)...")
    target_cycles = 5_000_000 // int(CLK_PERIOD_NS)  # 5 ms cap
    waited = 0
    poll = 200
    entered = False
    while waited < target_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _safe_int(m_an.state_r) == ST_NEGO_MASK_RD_ADDR:
            entered = True
            break
    t_now_ns = cocotb.utils.get_sim_time(unit="ns")
    log.info(
        f"State-9 entry: entered={entered} after {waited} cycles "
        f"({waited * CLK_PERIOD_NS / 1000:.1f} µs), sim {t_now_ns:.0f} ns"
    )
    if not entered:
        log.error(f"PREREQ FAIL — never entered state 9. state_r={_safe_int(m_an.state_r)}")
        return

    # Initial snapshot
    log.info("---- AT STATE-9 ENTRY ----")
    log.info(
        f"M: role_locked={_safe_int(m_ctl.role_lock_reg)} role_in_nego={_safe_int(m_ctl.role_in_nego)} "
        f"nego_driving={_safe_int(m_ctl.nego_driving)} role_is_master={_safe_int(m_ctl.role_is_master)} "
        f"i2c_mst_reset={_safe_int(m_ctl.i2c_mst_reset)} i2c_slv_reset={_safe_int(m_ctl.i2c_slv_reset)} "
        f"i2c_prescale={_safe_int(m_ctl.i2c_prescale_reg)} "
        f"mask_hs_in_progress={_safe_int(m_ctl.mask_hs_in_progress)}"
    )
    log.info(
        f"S: role_locked={_safe_int(s_ctl.role_lock_reg)} role_in_nego={_safe_int(s_ctl.role_in_nego)} "
        f"nego_driving={_safe_int(s_ctl.nego_driving)} role_is_master={_safe_int(s_ctl.role_is_master)} "
        f"i2c_mst_reset={_safe_int(s_ctl.i2c_mst_reset)} i2c_slv_reset={_safe_int(s_ctl.i2c_slv_reset)} "
        f"i2c_slv_addr={_safe_int(s_ctl.i2c_slv_addr_reg):#x} "
        f"slv.bus_addressed={_safe_int(s_i2cs.bus_addressed)} slv.state={_safe_int(s_i2cs.state_reg)}"
    )
    log.info(
        f"Pins: scl={_safe_int(dut.i2c_scl)} sda={_safe_int(dut.i2c_sda)} | "
        f"M scl_t/sda_t={_safe_int(dut.m_i2c_scl_t)}/{_safe_int(dut.m_i2c_sda_t)} "
        f"S scl_t/sda_t={_safe_int(dut.s_i2c_scl_t)}/{_safe_int(dut.s_i2c_sda_t)}"
    )

    # ---- Dense probe ----
    log.info("=== DENSE PROBE (100 µs, log on key-signal change) ===")
    PROBE_CYCLES = 5_000
    prev_key = None
    last_log_cyc = -10**9

    for c in range(PROBE_CYCLES):
        await ClockCycles(dut.hclk, 1)
        key = (
            _safe_int(m_an.state_r),
            _safe_int(m_an.txn_step_r),
            _safe_int(m_an.axl_state_r),
            _safe_int(m_an.axl_done_r),
            _safe_int(m_an.mask_byte_cnt_r),
            _safe_int(m_an.busy_seen_r),
            _safe_int(m_an.axl_rdata_r) & 0xFFFF,
            _safe_int(m_i2cm.state_reg),
            _safe_int(m_i2cm.bus_active_reg) if hasattr(m_i2cm, 'bus_active_reg') else -1,
            _safe_int(m_i2cm_axil.missed_ack_reg) if hasattr(m_i2cm_axil, 'missed_ack_reg') else -1,
            _safe_int(s_i2cs.state_reg),
            _safe_int(s_i2cs.bus_addressed),
            _safe_int(dut.i2c_scl),
            _safe_int(dut.i2c_sda),
            _safe_int(m_an.m_axil_awvalid),
            _safe_int(m_an.m_axil_wvalid),
            _safe_int(m_an.m_axil_arvalid),
            _safe_int(m_an.m_axil_bready),
            _safe_int(m_ctl.mst_axil_awready),
            _safe_int(m_ctl.mst_axil_wready),
            _safe_int(m_ctl.mst_axil_bvalid),
            _safe_int(m_ctl.mst_axil_arready),
            _safe_int(m_ctl.mst_axil_rvalid),
            _safe_int(m_ctl.bridge_axil_bvalid),
            _safe_int(m_ctl.i2c_mst_reset),
            _safe_int(m_ctl.nego_driving),
        )
        changed = key != prev_key
        force = (c - last_log_cyc) >= 500
        if changed or force:
            t = cocotb.utils.get_sim_time(unit="ns")
            log.info(
                f"+{c:5d} t={t:.0f}ns | "
                f"M.st={key[0]:2d} tx={key[1]} axl={key[2]} done={key[3]} bcnt={key[4]} bs={key[5]} rd={key[6]:04x} | "
                f"I2CM.st={key[7]:2d} ba={key[8]} mack={key[9]} | "
                f"I2CS.st={key[10]:2d} addr={key[11]} | "
                f"scl={key[12]} sda={key[13]} | "
                f"AXIL FSM: aw={key[14]} w={key[15]} ar={key[16]} br={key[17]} | "
                f"mst: awR={key[18]} wR={key[19]} bV={key[20]} arR={key[21]} rV={key[22]} | "
                f"brd.bV={key[23]} mst_rst={key[24]} nd={key[25]}"
            )
            last_log_cyc = c
        prev_key = key

        if key[0] != ST_NEGO_MASK_RD_ADDR:
            log.info(f"FSM exited state 9 at cycle +{c} -> state {key[0]}.")
            break

    log.info("=== PROBE END ===")
    log.info(
        f"FINAL: m.state={_safe_int(m_an.state_r)} tx={_safe_int(m_an.txn_step_r)} "
        f"axl={_safe_int(m_an.axl_state_r)} done={_safe_int(m_an.axl_done_r)} "
        f"bcnt={_safe_int(m_an.mask_byte_cnt_r)} bs={_safe_int(m_an.busy_seen_r)}"
    )
    log.info(
        f"FINAL: i2cm.state={_safe_int(m_i2cm.state_reg)} "
        f"i2cs.state={_safe_int(s_i2cs.state_reg)} i2cs.bus_addr={_safe_int(s_i2cs.bus_addressed)}"
    )
