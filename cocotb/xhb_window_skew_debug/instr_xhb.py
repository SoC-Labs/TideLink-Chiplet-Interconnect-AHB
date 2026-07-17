"""Instrumented XHB-window probe (scratch, read-only DUT peeks).

Reuses the pair_v2 harness + the already-built sim_build_silicon binary
(EPOCH_PROFILE=silicon, default no-anchor). Goal: split the failure into
(a) did the forward WRITE REQUEST land in the slave BRAM (M->S clean path),
vs (b) is only the B-RESPONSE (S->M skewed path) lost.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from pair_v2_common import PairV2TB, run_bringup_full

APERTURE_BASE = 0x4000_0000


def _peek(dut, path):
    try:
        node = dut
        for p in path.split('.'):
            node = getattr(node, p)
        return int(node.value)
    except Exception:
        return None


@cocotb.test()
async def instr_xhb(dut):
    tb = PairV2TB(dut)
    # idle ahb_sub
    dut.m_ahb_sub_hsel.value = 0
    dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hready.value = 1

    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "no CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    # master RX = S->M path deskew observables
    for nm in ("epoch_anchored_o", "epoch_span_o", "reanchored_o"):
        v = _peek(dut, f"u_master.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.{nm}")
        tb.log.info(f"[instr] master deskew {nm} = {v}")

    # Issue ONE ahb_sub write, DON'T wait for completion — drive the address
    # phase then release, exactly like AHBSubMaster but non-blocking.
    addr = APERTURE_BASE + 0x000
    data = 0xCAFEF00D
    await RisingEdge(dut.hclk)
    dut.m_ahb_sub_hsel.value   = 1
    dut.m_ahb_sub_haddr.value  = addr
    dut.m_ahb_sub_htrans.value = 2
    dut.m_ahb_sub_hsize.value  = 2
    dut.m_ahb_sub_hwrite.value = 1
    dut.m_ahb_sub_hwdata.value = data
    dut.m_ahb_sub_hready.value = 1
    await RisingEdge(dut.hclk)
    dut.m_ahb_sub_hsel.value   = 0
    dut.m_ahb_sub_htrans.value = 0
    dut.m_ahb_sub_hwrite.value = 0

    # Watch: slave BRAM landing (forward path) + master hreadyout (completion).
    landed_at = None
    hro_high_at = None
    for c in range(60000):
        await RisingEdge(dut.hclk)
        bram0 = _peek(dut, "u_s_mng_bram.mem")  # array; peek index 0 below
        try:
            b0 = int(dut.u_s_mng_bram.mem[0].value)
        except Exception:
            b0 = None
        if landed_at is None and b0 == data:
            landed_at = c
            tb.log.info(f"[instr] FORWARD WRITE LANDED in slave BRAM[0]=0x{b0:08x} at +{c} cyc")
        hro = _peek(dut, "m_ahb_sub_hreadyout")
        if landed_at is not None and hro == 1 and c > 3:
            hro_high_at = c
    b0 = None
    try:
        b0 = int(dut.u_s_mng_bram.mem[0].value)
    except Exception:
        pass
    tb.log.info(f"[instr] RESULT slaveBRAM[0]={None if b0 is None else hex(b0)} "
                f"forward_landed={'YES@+%d'%landed_at if landed_at is not None else 'NO'} "
                f"(over 60000 cyc after write; completion handshake back over S->M)")
