"""TL-021 first-silicon observability — sim proof for the two LOW-RISK subitems.

Runs on the tidelink_v2_smoke DUT (a single real `tidelink_top`, V2 swap set,
APB-only). HELD FOR DAVID — netlist-affecting, uncommitted.

Subitem (2) — i2c_slv_reset SW override @ SoC 0x2088[7]:
  New default-0 debug bit `i2c_slv_dbg_force_reg` decoded from Region-4 slot 2
  bit[7]. Gates i2c_slv_reset = ~hresetn | (role_is_master & ~force). Default 0
  is bit-identical to production (i2c_slv held in reset whenever master).
  NON-VACUOUS: unpatched RTL has no bit[7] -> readback stays 0 and i2c_slv_reset
  stays asserted while master; the override assertions FAIL unpatched, PASS patched.

Subitem (3) — ext_stall_err_q -> obs 0x21F8[11] (V2-only, additive):
  Pack tidelink_top's sticky ext_stall_err_q into xhb_sub_obs_word[11] (was a
  spare 0 in the {8'hB5,13'h0,...} word) -> Region-F slot 6 -> SoC 0x21F8[11].
  NON-VACUOUS: unpatched RTL packs a constant 0 at [11]; after depositing
  ext_stall_err_q=1 the read of 0x21F8[11] is 0 unpatched, 1 patched.

APB master + bring-up modeled on cocotb/tidelink_v2_smoke/test_tidelink_v2_smoke.py.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS     = 20.0   # 50 MHz hclk
REF_CLK_PERIOD_NS = 8.0    # Wlink PLL ref

APB_R4_I2C_SLV_ADDR = 0x2088   # HW 0x4403_2088, Region 4 slot 2 (I2C_SLV_ADDR)
APB_RF_XHB_SUB_OBS  = 0x21F8   # HW 0x4403_21F8, Region F slot 6 (XHB_SUB_OBS, V2-only)

XHB_SUB_OBS_SIG = 0xB5         # bits [31:24] signature of xhb_sub_obs_word


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
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.ref_clk, REF_CLK_PERIOD_NS, unit="ns").start())
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
async def test_tl021_i2c_slv_reset_override(dut):
    """Subitem (2): SoC 0x2088[7]=1 releases i2c_slv_reset while master; default 0 = bit-identical."""
    apb = await bring_up(dut)
    ctrl = dut.u_dut.u_chiplet_controller

    # Precondition: this DUT is strapped master, so production ties i2c_slv_reset
    # asserted (= role_is_master). Prove that baseline first.
    rim = int(dut.role_is_master.value)
    dut._log.info(f"role_is_master = {rim}")
    assert rim == 1, "precondition: DUT must be master (i2c_slv held in reset by construction)"

    rst_default = int(ctrl.i2c_slv_reset.value)
    dut._log.info(f"default i2c_slv_reset = {rst_default}")
    assert rst_default == 1, f"default i2c_slv_reset expected 1 (master), got {rst_default}"

    rb_default = await apb.read(APB_R4_I2C_SLV_ADDR)
    dut._log.info(f"default 0x2088 readback = 0x{rb_default:08x}")
    assert ((rb_default >> 7) & 1) == 0, \
        f"0x2088[7] default expected 0, got 0x{rb_default:08x}"

    # Write the override bit (keep addr[6:0]=0x5A so we also prove it is preserved).
    await apb.write(APB_R4_I2C_SLV_ADDR, (1 << 7) | 0x5A)
    await ClockCycles(dut.hclk, 3)

    rst_forced = int(ctrl.i2c_slv_reset.value)
    rb_forced = await apb.read(APB_R4_I2C_SLV_ADDR)
    dut._log.info(f"after 0x2088[7]=1 -> i2c_slv_reset={rst_forced}, readback=0x{rb_forced:08x}")

    # NON-VACUOUS assertions (FAIL against unpatched RTL: bit doesn't exist).
    assert ((rb_forced >> 7) & 1) == 1, \
        f"0x2088[7] should read 1 after override write (unpatched: bit absent), got 0x{rb_forced:08x}"
    assert (rb_forced & 0x7F) == 0x5A, \
        f"i2c_slv_addr[6:0] must be preserved (=0x5A), got 0x{rb_forced:08x}"
    assert rst_forced == 0, \
        f"i2c_slv_reset must DEASSERT (0) with override + master (unpatched: stays 1), got {rst_forced}"

    # Clear the override -> bit-identical to production (reset re-asserts).
    await apb.write(APB_R4_I2C_SLV_ADDR, 0x5A)
    await ClockCycles(dut.hclk, 3)
    rst_cleared = int(ctrl.i2c_slv_reset.value)
    dut._log.info(f"after clearing override -> i2c_slv_reset={rst_cleared}")
    assert rst_cleared == 1, \
        f"clearing override must restore i2c_slv_reset = role_is_master = 1, got {rst_cleared}"


@cocotb.test()
async def test_tl021_ext_stall_err_obs(dut):
    """Subitem (3): ext_stall_err_q=1 -> read SoC 0x21F8[11]=1; =0 when clear. Additive, V2-only."""
    apb = await bring_up(dut)
    top = dut.u_dut

    # Baseline: POR clears ext_stall_err_q -> 0x21F8[11] must be 0. Also sanity
    # the path is alive via the 0xB5 signature byte.
    e_por = int(top.ext_stall_err_q.value)
    dut._log.info(f"POR ext_stall_err_q = {e_por}")
    assert e_por == 0, f"ext_stall_err_q expected 0 after POR, got {e_por}"

    w_lo = await apb.read(APB_RF_XHB_SUB_OBS)
    dut._log.info(f"0x21F8 (ext=0) = 0x{w_lo:08x}")
    assert (w_lo >> 24) == XHB_SUB_OBS_SIG, \
        f"0x21F8 signature byte expected 0x{XHB_SUB_OBS_SIG:02x} (path alive), got 0x{w_lo:08x}"
    assert ((w_lo >> 11) & 1) == 0, \
        f"0x21F8[11] expected 0 when ext_stall_err_q=0, got 0x{w_lo:08x}"

    # Deposit the sticky flag. In idle the always_ff does not re-assign it
    # (only POR clears / limit sets), so the deposit holds.
    top.ext_stall_err_q.value = 1
    await ClockCycles(dut.hclk, 2)
    e_dep = int(top.ext_stall_err_q.value)
    obs = int(top.xhb_sub_obs_word.value)
    dut._log.info(f"deposited ext_stall_err_q={e_dep}, xhb_sub_obs_word=0x{obs:08x}")
    assert e_dep == 1, "deposit of ext_stall_err_q did not hold (idle branch must not overwrite)"

    w_hi = await apb.read(APB_RF_XHB_SUB_OBS)
    dut._log.info(f"0x21F8 (ext=1) = 0x{w_hi:08x}")
    # NON-VACUOUS assertion (FAIL against unpatched RTL: [11] is a constant 0).
    assert ((w_hi >> 11) & 1) == 1, \
        f"0x21F8[11] must be 1 with ext_stall_err_q=1 (unpatched: stays 0), got 0x{w_hi:08x}"
    assert (w_hi >> 24) == XHB_SUB_OBS_SIG, \
        f"0x21F8 signature byte expected 0x{XHB_SUB_OBS_SIG:02x}, got 0x{w_hi:08x}"
    # Additive: ONLY bit[11] differs from the ext=0 baseline.
    assert (w_hi & ~(1 << 11)) == (w_lo & ~(1 << 11)), \
        f"only bit[11] should change: w0=0x{w_lo:08x} w1=0x{w_hi:08x}"

    # Clear -> bit[11] returns to 0.
    top.ext_stall_err_q.value = 0
    await ClockCycles(dut.hclk, 2)
    w_clr = await apb.read(APB_RF_XHB_SUB_OBS)
    dut._log.info(f"0x21F8 (ext=0 again) = 0x{w_clr:08x}")
    assert ((w_clr >> 11) & 1) == 0, \
        f"0x21F8[11] expected 0 after clearing ext_stall_err_q, got 0x{w_clr:08x}"
