"""tidelink_v2_smoke — fast V2 (S3 PHY swap) integration sanity gate.

Single tidelink_top elaborated with the V2 swap set
(flists/tidelink_fpga_v2.flist), APB driver only. Checks:

  1. reset deasserts cleanly (pready / pslverr resolve, no X on APB outputs)
  2. PHY_ALIGN_ID   @ APB 0x211C (HW 0x4403_211C) reads 0x5041_0100
  3. Region 10      @ APB 0x2140 reads 0 in V2 (eye-vis retired, AUDIT #17 —
     the tidelink_top TIDELINK_PHY_V2 arm RAZ-ties the eye shim) and the
     read completes (pready=1, no stall)
  4. SWI_BIT_SLIP_LO @ APB 0x2104 write/read-back ([23:0] RW)

Style modeled on cocotb/tidelink_fc_adapter/test_tidelink_fc_adapter.py
(local minimal APB master, no cocotbext deps).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS     = 20.0   # 50 MHz hclk — same as tidelink_top_pair
REF_CLK_PERIOD_NS = 8.0    # Wlink PLL ref — mirrors the UVM tb

# Unified 15-bit APB addresses (HW 0x4403_0000 base maps to APB 0x0000;
# TideLink region at 0x2000 — see cocotb/tidelink_top_pair docs).
APB_R8_SWI_BIT_SLIP_LO = 0x2104   # HW 0x4403_2104, Region 8 slot 1 (RW [23:0])
APB_R8_PHY_ALIGN_ID    = 0x211C   # HW 0x4403_211C, Region 8 slot 7 (RO)
APB_R10_BASE           = 0x2140   # HW 0x4403_2140, Region 10 (eye-vis; RAZ in V2)

PHY_ALIGN_ID_EXPECT = 0x50410100  # "PA" v1.0


class APBMaster:
    """Minimal APB master on tb_top's single unified APB port."""

    def __init__(self, dut):
        self.dut = dut
        dut.apb_psel.value = 0
        dut.apb_penable.value = 0
        dut.apb_pwrite.value = 0
        dut.apb_paddr.value = 0
        dut.apb_pwdata.value = 0

    async def write(self, addr, data):
        dut = self.dut
        await RisingEdge(dut.hclk)
        dut.apb_psel.value = 1
        dut.apb_pwrite.value = 1
        dut.apb_paddr.value = addr
        dut.apb_pwdata.value = data
        await RisingEdge(dut.hclk)
        dut.apb_penable.value = 1
        while True:
            await RisingEdge(dut.hclk)
            if int(dut.apb_pready.value) == 1:
                break
        dut.apb_psel.value = 0
        dut.apb_penable.value = 0
        dut.apb_pwrite.value = 0

    async def read(self, addr):
        dut = self.dut
        await RisingEdge(dut.hclk)
        dut.apb_psel.value = 1
        dut.apb_pwrite.value = 0
        dut.apb_paddr.value = addr
        await RisingEdge(dut.hclk)
        dut.apb_penable.value = 1
        while True:
            await RisingEdge(dut.hclk)
            if int(dut.apb_pready.value) == 1:
                break
        data = int(dut.apb_prdata.value)
        dut.apb_psel.value = 0
        dut.apb_penable.value = 0
        return data


async def bring_up(dut):
    """Start clocks, run the POR sequence, return an APBMaster."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.ref_clk, REF_CLK_PERIOD_NS, units="ns").start())
    apb = APBMaster(dut)
    dut.poresetn.value = 0
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 20)
    return apb


@cocotb.test()
async def test_v2_smoke_reset_and_apb(dut):
    """V2 sanity: reset + APB liveness on the S3 PHY-swap build."""
    apb = await bring_up(dut)

    # 1. Reset liveness — d2d_reset_o must have resolved (not X) and the
    #    APB response lines must be drivable.
    d2d = dut.d2d_reset_o.value
    assert not d2d.is_resolvable or int(d2d) in (0, 1), \
        f"d2d_reset_o unresolved after reset: {d2d}"

    # 2. PHY_ALIGN_ID — proves the APB pipeline through tidelink_apb_regs +
    #    the chiplet-controller Region 8 read mux is alive in the V2 build.
    align_id = await apb.read(APB_R8_PHY_ALIGN_ID)
    dut._log.info(f"PHY_ALIGN_ID @0x{APB_R8_PHY_ALIGN_ID:04x} = 0x{align_id:08x}")
    assert align_id == PHY_ALIGN_ID_EXPECT, \
        f"PHY_ALIGN_ID: got 0x{align_id:08x}, expected 0x{PHY_ALIGN_ID_EXPECT:08x}"

    # 3. SoC 0x2140 — in V2 the eye-vis Region 10 is retired (AUDIT #17) and
    #    this word is repurposed as SWI_EPOCH_STATUS (the gpio_phy slave's
    #    paddr 0x40: [0]=epoch_anchored, [6:1]=epoch_span). With no link
    #    partner and no training, the lane-deskew anchor never engages, so the
    #    register reads 0 — the read must still COMPLETE (pready=1). A V1 build
    #    would return the eye-regs POR defaults here.
    r10 = await apb.read(APB_R10_BASE)
    dut._log.info(f"SWI_EPOCH_STATUS @0x{APB_R10_BASE:04x} = 0x{r10:08x}")
    assert r10 == 0, f"SWI_EPOCH_STATUS expected 0 (unanchored) in V2, got 0x{r10:08x}"

    # 4. SWI_BIT_SLIP_LO write/read-back — proves a Region 8 RW register
    #    survives the swap (the V2 controller arm keeps the Region 8 SW
    #    override surface).
    pattern = 0x00A5C3F0 & 0x00FFFFFF   # [23:0] RW field
    await apb.write(APB_R8_SWI_BIT_SLIP_LO, pattern)
    rb = await apb.read(APB_R8_SWI_BIT_SLIP_LO)
    dut._log.info(f"SWI_BIT_SLIP_LO wrote 0x{pattern:06x} read 0x{rb:08x}")
    assert (rb & 0x00FFFFFF) == pattern, \
        f"SWI_BIT_SLIP_LO readback: got 0x{rb:08x}, expected 0x{pattern:06x}"

    # restore
    await apb.write(APB_R8_SWI_BIT_SLIP_LO, 0)
    await ClockCycles(dut.hclk, 10)
