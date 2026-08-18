"""TL-042 diagnostic — why the synthetic AW accept does not drain the bridge.
Reuses the sim_build_fix simv (patched RTL). Probes pause_addr_submit / the
Q-channel / hazard terms around the moment recovery fires."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

APER_BASE  = 0x4000_0000
HCLK_NS    = 10
REFCLK_NS  = 8
STALL_TH   = 1 << 10
WATCH      = STALL_TH * 3


def _v(h):
    try:    return int(h.value)
    except Exception: return None


def _g(root, path):
    obj = root
    try:
        for p in path.split("."):
            obj = getattr(obj, p)
        return int(obj.value)
    except Exception:
        return None


@cocotb.test()
async def test_diag(dut):
    cocotb.start_soon(Clock(dut.hclk, HCLK_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.ref_clk, REFCLK_NS, unit="ns").start())
    m = dut.u_master
    for s, v in [("hsel",0),("haddr",0),("htrans",0),("hsize",2),("hburst",0),
                 ("hprot",0),("hwrite",0),("hwdata",0),("hready",1)]:
        getattr(dut, f"m_ahb_sub_{s}").value = v
    for s in ("f_awready_en","f_awready_val","f_wready_en","f_wready_val","f_bctrl_en","f_rvalid_en"):
        getattr(dut, s).value = 0
    dut.poresetn.value = 0; dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 50)

    # Q-channel state BEFORE any wedge (baseline)
    dut._log.info(f"[diag] baseline: clk_qacceptn={_g(m,'u_xhb_sub.u_core.clk_qacceptn')} "
                  f"pwr_qacceptn={_g(m,'u_xhb_sub.u_core.pwr_qacceptn')} "
                  f"pause={_g(m,'u_xhb_sub.u_core.u_addr.pause_addr_submit')}")

    # arm wedge
    dut.f_awready_en.value=1; dut.f_awready_val.value=0
    dut.f_wready_en.value=1;  dut.f_wready_val.value=0
    dut.f_bctrl_en.value=1;   dut.f_rvalid_en.value=1
    await ClockCycles(dut.hclk, 5)

    # drive one bufferable write (address phase, then data phase)
    await RisingEdge(dut.hclk)
    dut.m_ahb_sub_hsel.value=1; dut.m_ahb_sub_haddr.value=APER_BASE+0x100
    dut.m_ahb_sub_htrans.value=2; dut.m_ahb_sub_hsize.value=2
    dut.m_ahb_sub_hburst.value=0; dut.m_ahb_sub_hprot.value=0x4
    dut.m_ahb_sub_hwrite.value=1; dut.m_ahb_sub_hready.value=1
    for _ in range(64):
        await RisingEdge(dut.hclk)
        if _v(m.ahb_sub_hreadyout)==1: break
    dut.m_ahb_sub_htrans.value=0; dut.m_ahb_sub_hsel.value=0
    dut.m_ahb_sub_hwdata.value=0xD0D0_0042

    logged = 0
    wedge_snap = False
    for c in range(WATCH):
        await RisingEdge(dut.hclk)
        # one snapshot deep in the wedge (before recovery)
        if (not wedge_snap) and c == 300:
            wedge_snap = True
            dut._log.info(f"[diag] WEDGE c={c}: "
                f"awv={_v(m.s_axi_awvalid)} awr(dn)={_v(m.s_axi_awready)} "
                f"pause={_g(m,'u_xhb_sub.u_core.u_addr.pause_addr_submit')} "
                f"qc_clk={_g(m,'u_xhb_sub.u_core.clk_qacceptn')} "
                f"qc_pwr={_g(m,'u_xhb_sub.u_core.pwr_qacceptn')} "
                f"haz_full={_g(m,'u_xhb_sub.u_core.u_addr.hazard_full')} "
                f"rdy4rd={_g(m,'u_xhb_sub.u_core.u_addr.ready_for_read')} "
                f"brokenB={_g(m,'u_xhb_sub.u_core.u_addr.pending_broken_b_resp')} "
                f"addr_rdyo={_g(m,'u_xhb_sub.u_core.u_addr.address_readyout')} "
                f"raw={_v(m.xhb_sub_hreadyout_raw)}")
        rec = _v(getattr(m, "rec_active"))
        if rec == 1 and logged < 40:
            logged += 1
            dut._log.info(f"[diag] REC c={c}: "
                f"rec={rec} synthAW={_v(m.synth_aw_accept)} synthW={_v(m.synth_w_accept)} "
                f"awv={_v(m.s_axi_awvalid)} awr_brg={_v(m.s_axi_awready_brg)} "
                f"wv={_v(m.s_axi_wvalid)} wr_brg={_v(m.s_axi_wready_brg)} wlast={_v(m.s_axi_wlast)} "
                f"pipe_v={_v(m.pipe_valid_r)} xhb_hsel={_v(m.xhb_sub_hsel)} "
                f"addr_rdyo={_g(m,'u_xhb_sub.u_core.u_addr.address_readyout')} "
                f"os={_v(m.sub_wr_os_ctr)} synthB={_v(m.synth_b_pending)} bready={_v(m.s_axi_bready)} "
                f"raw={_v(m.xhb_sub_hreadyout_raw)} rdyo={_v(m.ahb_sub_hreadyout)}")
        if _v(m.ahb_sub_hreadyout)==1:
            dut._log.info(f"[diag] RECOVERED at c={c}")
            break
    dut._log.info("[diag] done")
