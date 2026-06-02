"""Bug N12 — slv_apb→Wlink read response path probe.

Silicon evidence (build v11, 2026-06-02 z2_02/z2_03 asymmetric-POR deploy):
  Slave (z2_03) running as autoneg WINNER reports
  peer_tx_lane_mask_r=0x00, peer_rx_lane_mask_r=0x00 after running
  ST_NEGO_MASK_RD_DATA against master (z2_02). Expected: master's
  swi_*_lane_mask defaults (0xFF / 0xFF). User hypothesis (Bug N12 #1):
  the slv_apb→Wlink READ response path is broken on the master die,
  returning 0 instead of Wlink's lane_mask register.

Approach
--------
The full autoneg-arbitration cocotb path (test_19, test_21) is too slow
(>10 minutes wall) to exercise the slave-as-winner direction. Instead
this test probes the read path DIRECTLY at the master die:

  1. POR both dies (skip BYPASS_AUTONEG to keep autoneg quiescent).
  2. Force master's chiplet_controller into the "lost" state with
     role_locked=0 (i.e. its i2c_slave is responsive). Specifically,
     set role_in_nego=1 by leaving role_lock_reg=0 and nego_cfg_reg[0]=1
     while strap_i=0 so role_effective=nego_role_w=1 → role_is_master=0
     → i2c_slv_reset=~hresetn (NOT held in reset).
  3. Issue a SystemVerilog hierarchical Force on master's slv_apb_*
     bus to simulate the AXIL→APB bridge driving paddr=0x214 read.
     Observe the bridge_prdata value the bridge would return to its
     AXIL master (i.e. to the I²C-slave's AXIL responder).
  4. Verify bridge_prdata == 0x0000FFFF (Wlink's lane_mask default).

If the read path is correctly wired:
  - bridge_prdata == 0x0000FFFF → PASS (read mux is functional)

If the read path is broken (hypothesis #1):
  - bridge_prdata == 0x00000000 → FAIL (read mux drops Wlink response)

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \\
        TESTCASE=test_23_bug_n12_slv_apb_wlink_read \\
        SIM_BUILD=sim_build_n12_t23 \\
        make MODULE=test_23_bug_n12_slv_apb_wlink_read
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer
from cocotb.handle import Force, Release


CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


@cocotb.test()
async def test_23_bug_n12_slv_apb_wlink_read(dut):
    """Probe the master die's slv_apb→Wlink read response path
    directly by hierarchically forcing slv_apb_* and observing
    slv_apb_bridge_prdata."""
    log = dut._log
    log.info("Bug N12 — test_23 slv_apb→Wlink read response probe")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )

    # Idle inputs.
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
    # Let any tb_top BYPASS_AUTONEG release fire.
    await ClockCycles(dut.hclk, 400)

    # ── Configure master to be in "lost, parked" state ───────────────
    # Master needs role_in_nego=1 (i.e. role_locked=0 AND nego_en=1) so
    # role_effective=nego_role_w. nego_role_r resets to 1 (slave) so
    # role_effective=1 → role_is_master=0 → i2c_slv_reset=~hresetn
    # (i.e. NOT held in reset by role_is_master gate).
    m_ctl = dut.u_master.u_chiplet_controller
    m_ctl.nego_cfg_reg.value = 0x01  # nego_en[0]=1 only
    await ClockCycles(dut.hclk, 10)

    # Verify master's I²C slave is RELEASED from reset.
    role_is_master = _safe_int(m_ctl.role_is_master)
    i2c_slv_reset  = _safe_int(m_ctl.i2c_slv_reset)
    role_in_nego   = _safe_int(m_ctl.role_in_nego)
    log.info(
        f"Master: role_in_nego={role_in_nego} "
        f"role_is_master={role_is_master} i2c_slv_reset={i2c_slv_reset}"
    )
    assert role_is_master == 0 and i2c_slv_reset == 0, (
        f"Test setup failed: master's I²C slave NOT released. "
        f"role_is_master={role_is_master} i2c_slv_reset={i2c_slv_reset}"
    )

    # ── Probe path: drive master's slv_apb_* directly ────────────────
    # The path under test is:
    #   slv_apb_* (driven by AXIL→APB bridge in real flow)
    #     → slv_apb_to_wlink (=slv_apb_active && !slv_apb_ctrl_hit)
    #     → wl_apb_* (driven into Wlink via paddr=0x214)
    #     → wl_apb_prdata returns lane_mask
    #     → slv_apb_bridge_prdata returns wl_apb_prdata (Bug N2 mux)
    # We Force slv_apb_psel/penable/paddr=0x214/pwrite=0 and observe
    # slv_apb_bridge_prdata after one cycle (Wlink's combinational APB
    # read response).
    m_ctl.slv_apb_psel.set(Force(1))
    m_ctl.slv_apb_paddr.set(Force(0x214))
    m_ctl.slv_apb_pwrite.set(Force(0))
    m_ctl.slv_apb_penable.set(Force(0))   # SETUP phase
    m_ctl.slv_apb_pprot.set(Force(0))
    m_ctl.slv_apb_pstrb.set(Force(0))
    m_ctl.slv_apb_pwdata.set(Force(0))
    await ClockCycles(dut.hclk, 1)
    m_ctl.slv_apb_penable.set(Force(1))   # ACCESS phase

    # Wait a few cycles for Wlink's combinational APB to respond.
    await ClockCycles(dut.hclk, 5)

    bridge_prdata = _safe_int(m_ctl.slv_apb_bridge_prdata)
    bridge_pready = _safe_int(m_ctl.slv_apb_bridge_pready)
    bridge_pslverr = _safe_int(m_ctl.slv_apb_bridge_pslverr)
    wl_prdata     = _safe_int(m_ctl.wl_apb_prdata)
    wl_pready     = _safe_int(m_ctl.wl_apb_pready)
    ctrl_hit      = _safe_int(m_ctl.slv_apb_ctrl_hit)
    slv_to_wlink  = _safe_int(m_ctl.slv_apb_to_wlink)

    log.info(
        f"Probe results @ paddr=0x214:\n"
        f"  slv_apb_ctrl_hit       = {ctrl_hit}    (expect 0 — Wlink region)\n"
        f"  slv_apb_to_wlink       = {slv_to_wlink}    (expect 1)\n"
        f"  wl_apb_pready          = {wl_pready}\n"
        f"  wl_apb_prdata          = 0x{wl_prdata:08x}\n"
        f"  slv_apb_bridge_pready  = {bridge_pready}\n"
        f"  slv_apb_bridge_prdata  = 0x{bridge_prdata:08x}\n"
        f"  slv_apb_bridge_pslverr = {bridge_pslverr}"
    )

    # ── Release forces ─────────────────────────────────────────────
    m_ctl.slv_apb_psel.set(Release())
    m_ctl.slv_apb_paddr.set(Release())
    m_ctl.slv_apb_pwrite.set(Release())
    m_ctl.slv_apb_penable.set(Release())
    m_ctl.slv_apb_pprot.set(Release())
    m_ctl.slv_apb_pstrb.set(Release())
    m_ctl.slv_apb_pwdata.set(Release())

    # ── Verdict ───────────────────────────────────────────────────
    # Wlink's swi_*_lane_mask POR default is 8'hFF / 8'hFF (Wlink.v
    # SW.scala defaults). At paddr=0x214 the register decodes to slot 5
    # = link_lane_mask = {rx_lane_mask, tx_lane_mask} = 16'h0000FFFF.
    # If the bridge's read mux is wired correctly, bridge_prdata
    # reflects this. If broken (hypothesis #1), bridge_prdata=0.
    assert ctrl_hit == 0, (
        f"Address decode bug: paddr=0x214 should NOT be ctrl region "
        f"(only 0x4xx/0x8xx/0xCxx are). Got slv_apb_ctrl_hit={ctrl_hit}."
    )
    assert slv_to_wlink == 1, (
        f"Address decode bug: paddr=0x214 should route to Wlink. "
        f"Got slv_apb_to_wlink={slv_to_wlink}."
    )
    assert bridge_prdata == 0x0000FFFF, (
        f"Bug N12 read-mux fault: slv_apb_bridge_prdata=0x{bridge_prdata:08x}, "
        f"expected 0x0000FFFF (Wlink lane_mask POR default). "
        f"wl_apb_prdata=0x{wl_prdata:08x}. If wl_apb_prdata=0xFFFF but "
        f"bridge_prdata=0, the bridge's slv_apb_ctrl_hit mux is hijacking "
        f"the response. If wl_apb_prdata=0, Wlink itself is not returning "
        f"the register on the I²C slv_apb path."
    )

    log.info(
        "PASS: slv_apb_bridge_prdata=0x0000FFFF as expected. "
        "The slv_apb→Wlink READ response path is functional."
    )
