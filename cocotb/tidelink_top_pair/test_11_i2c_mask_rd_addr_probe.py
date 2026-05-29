"""Phase 0c — focused probe of the ST_NEGO_MASK_RD_ADDR hang (Bug N1).

Background
----------
test_10_autonomous_train_post_por runs the full FSM and observes the master
parked in state 9 (ST_NEGO_MASK_RD_ADDR) for 35 ms+ while the slave sits in
state 5 (ST_NEGO_DONE) with I²C SDA held low. This test reproduces the same
configuration but adds dense per-cycle probing of:

  - autoneg internals: state_r, txn_step_r, axl_state_r, axl_done_r,
    mask_byte_cnt_r, busy_seen_r
  - I²C master IP: state_reg, bus_active, missed_ack_reg, prescale_reg
  - I²C slave IP (slave die): state_reg, bus_addressed, bus_active
  - bus pins: i2c_scl, i2c_sda
  - master AXIL drive: awvalid/wvalid/arvalid/rvalid/rready

It runs only until ~5 µs after the master enters state 9 (or 80 ms wall sim
cap), then dumps a CSV-style log to stdout so we can see exactly which step
the FSM is wedged in and whether the bus is actually ticking.

Hypothesis verdict targets
--------------------------
(1) i2c-slave-precondition: slave's i2c_slv_reset is `~hresetn | role_is_master`,
    so when slave wins role=slave the block is NOT reset. device_address mux
    falls back to 0x7E via role_in_nego=0 path → 0x7E because i2c_slv_addr_reg
    resets to 0x7E. If the slave's bus_addressed never asserts when master
    sends the address byte → hypothesis #1 confirmed.

(2) wire-AND release-after-ACK: trace shows scl=1 sda=0 at the hang point;
    that means SOMEONE has sda_t=0 sda_o=0. Probe both sides' tristate vectors
    to see who is holding it.

(3) sequence mismatch: the master should be pushing 2 address bytes
    (0x02, 0x14) and a cmd_start|cmd_write_multiple. If axl_done_r is firing
    for TXN_DATA but cmd never gets queued, the master IP is the bottleneck.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


@cocotb.test()
async def test_11_i2c_mask_rd_addr_probe(dut):
    log = dut._log
    log.info("Phase 0c — I²C mask-rd-addr probe")

    cocotb.start_soon(Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start())
    cocotb.start_soon(Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start())

    # Idle stimulus everywhere.
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value   = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value    = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value   = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value   = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value   = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value  = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value  = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1

    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)

    # Probe handles
    m_an  = dut.u_master.u_chiplet_controller.u_autoneg
    s_an  = dut.u_slave.u_chiplet_controller.u_autoneg
    m_ctl = dut.u_master.u_chiplet_controller
    s_ctl = dut.u_slave.u_chiplet_controller

    m_i2cm = dut.u_master.u_chiplet_controller.u_i2c_master.i2c_master_inst
    m_i2cm_axil = dut.u_master.u_chiplet_controller.u_i2c_master
    s_i2cs = dut.u_slave.u_chiplet_controller.u_i2c_slave.i2c_slave_inst

    # ---- Wait for master to enter state 9 (or 80 ms timeout) ----
    log.info("Waiting for master to enter state 9 (ST_NEGO_MASK_RD_ADDR)...")
    target_cycles = 80_000_000 // int(CLK_PERIOD_NS)  # 80 ms in cycles
    waited = 0
    poll = 500
    entered = False
    while waited < target_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if _safe_int(m_an.state_r) == 9:
            entered = True
            break
    t_now_ns = cocotb.utils.get_sim_time(unit="ns")
    log.info(
        f"State-9 entry: entered={entered} after {waited} cycles ({waited * CLK_PERIOD_NS / 1000:.1f} µs), sim time {t_now_ns:.0f} ns"
    )
    log.info(
        f"At entry: m_state={_safe_int(m_an.state_r)} s_state={_safe_int(s_an.state_r)} "
        f"m_role_locked={_safe_int(dut.m_role_locked)} s_role_locked={_safe_int(dut.s_role_locked)} "
        f"i2c_scl={_safe_int(dut.i2c_scl)} i2c_sda={_safe_int(dut.i2c_sda)}"
    )
    log.info(
        f"At entry: m_role_is_master={_safe_int(dut.u_master.u_chiplet_controller.role_is_master)} "
        f"s_role_is_master={_safe_int(dut.u_slave.u_chiplet_controller.role_is_master)} "
        f"s_i2c_slv_reset={_safe_int(dut.u_slave.u_chiplet_controller.i2c_slv_reset)}"
    )
    log.info(
        f"At entry: m_i2c_prescale_reg={_safe_int(m_ctl.i2c_prescale_reg)} "
        f"s_i2c_slv_addr_reg={_safe_int(s_ctl.i2c_slv_addr_reg)}"
    )

    if not entered:
        log.error("Master never reached state 9 — see log above for stuck state.")
        return

    # ---- Now probe densely for 200_000 cycles (4 ms) — one cycle per sample,
    #      but only log every 25th cycle, plus log on ANY change of key signals.
    log.info("=== Dense probe begins (4 ms window, log on change + every 25 cycles) ===")
    log.info(
        "cyc | sim_ns | m.state m.txn m.axl m.done m.bcnt m.busy_seen | "
        "i2cm.state i2cm.bus_active i2cm.missed_ack | "
        "i2cs.state i2cs.bus_addr i2cs.bus_active | "
        "scl sda | m_aw m_w m_ar m_r | m_t3.scl_t s_t3.sda_t"
    )

    PROBE_CYCLES = 200_000
    prev_key = None
    for c in range(0, PROBE_CYCLES):
        await ClockCycles(dut.hclk, 1)
        key = (
            _safe_int(m_an.state_r),
            _safe_int(m_an.txn_step_r),
            _safe_int(m_an.axl_state_r),
            _safe_int(m_an.axl_done_r),
            _safe_int(m_an.mask_byte_cnt_r),
            _safe_int(m_an.busy_seen_r),
            _safe_int(m_i2cm.state_reg),
            _safe_int(m_i2cm.bus_active_reg),
            _safe_int(m_i2cm_axil.missed_ack_reg),
            _safe_int(s_i2cs.state_reg),
            _safe_int(s_i2cs.bus_addressed),
            _safe_int(s_i2cs.bus_active_reg) if hasattr(s_i2cs, 'bus_active_reg') else -1,
            _safe_int(dut.i2c_scl),
            _safe_int(dut.i2c_sda),
        )
        changed = key != prev_key
        if changed or (c % 2000 == 0):
            t = cocotb.utils.get_sim_time(unit="ns")
            log.info(
                f"+{c:6d} | t={t:.0f}ns | "
                f"M: st={key[0]:2d} tx={key[1]} axl={key[2]} done={key[3]} bcnt={key[4]} bs={key[5]} | "
                f"I2CM: st={key[6]:2d} ba={key[7]} mack={key[8]} | "
                f"I2CS: st={key[9]:2d} addr={key[10]} ba={key[11]} | "
                f"scl={key[12]} sda={key[13]} | "
                f"m_aw={_safe_int(dut.u_master.u_chiplet_controller.u_autoneg.m_axil_awvalid)} "
                f"m_w={_safe_int(dut.u_master.u_chiplet_controller.u_autoneg.m_axil_wvalid)} "
                f"m_ar={_safe_int(dut.u_master.u_chiplet_controller.u_autoneg.m_axil_arvalid)} | "
                f"sda_t M/S={_safe_int(dut.m_i2c_sda_t)}/{_safe_int(dut.s_i2c_sda_t)} "
                f"scl_t M/S={_safe_int(dut.m_i2c_scl_t)}/{_safe_int(dut.s_i2c_scl_t)}"
            )
        prev_key = key

        # Stop early if FSM has moved past state 9
        if key[0] != 9:
            log.info(f"FSM exited state 9 at cycle +{c} -> state {key[0]}. Stopping probe.")
            break

    log.info("=== Dense probe ends ===")

    # Final snapshot
    log.info(
        f"FINAL: m_state={_safe_int(m_an.state_r)} s_state={_safe_int(s_an.state_r)} "
        f"m_locked={_safe_int(dut.m_role_locked)} s_locked={_safe_int(dut.s_role_locked)}"
    )
    log.info(
        f"FINAL: m.i2c_master.state_reg={_safe_int(m_i2cm.state_reg)} "
        f"m.bus_active={_safe_int(m_i2cm.bus_active_reg)} "
        f"m.missed_ack={_safe_int(m_i2cm_axil.missed_ack_reg)}"
    )
    log.info(
        f"FINAL: s.i2c_slave.state_reg={_safe_int(s_i2cs.state_reg)} "
        f"s.bus_addressed={_safe_int(s_i2cs.bus_addressed)}"
    )
