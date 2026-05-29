"""Fix B — autonomous SLAVE self-lock via the real 0x21C lane-mask-handshake
result register (SHORTCOMINGS-14a/14b).

Before this change, Wlink.v hard-tied `assign mask_hs_result_o = 2'b00;`, so a
slave-role axi_chiplet_controller had NO hardware path to open its mask_hs
gate:

    mask_hs_match     = wlink_mask_hs_result[0] | autoneg_mask_hs_local_match
    mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i

The slave never walks the autoneg MASK states (only the master does), so
`autoneg_mask_hs_local_match` is always 0 on the slave. With the 0x21C path
dead, `wlink_mask_hs_result[0]` was also always 0 — meaning a slave could
ONLY latch role_lock via `mask_hs_bypass_i = 1` (the bring-up bypass,
hard-tied 1 on FPGA / default-1 in this TB).

Fix B implements the real `link_lane_mask_hs_result @ 0x21C` register: the
peer's autoneg master delivers a verdict byte over I2C into this side's APB
(MASK_RES_TX -> 0x21C; 0x01 = masks MATCH, 0x02 = MISMATCH). Wlink latches
it sticky and drives `mask_hs_result_o = {fail, match}`.

These tests drive the genuine gate path (mask_hs_bypass_i = 0) in the real
two-chiplet wlink_pair harness, mirroring cocotb/phy_align/
test_rtl_fix_coverage.py conventions: explicit negative controls first, then
the positive, with a hierarchical connectivity assert on mask_hs_result_o.

  test_01 (NEGATIVE): bypass=0, NO verdict          -> slave must NOT lock
  test_02 (NEGATIVE): bypass=0, verdict 0x02 (fail) -> slave must NOT lock
  test_03 (POSITIVE): bypass=0, verdict 0x01 (match)-> slave self-locks
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

WL_LANE_MASK_HS_RESULT = 0x021C   # Wlink reg; chiplet APB is 1:1 to Wlink
VERDICT_MATCH = 0x01
VERDICT_FAIL  = 0x02


async def setup(dut):
    """Start both clocks and POR both chiplets (mirrors wlink_pair setup)."""
    cocotb.start_soon(Clock(dut.master_clk, 20000, unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  20000, unit="ps").start())
    for p in ("m", "s"):
        getattr(dut, f"{p}_apb_psel").value = 0
        getattr(dut, f"{p}_apb_penable").value = 0
        getattr(dut, f"{p}_apb_pwrite").value = 0
        getattr(dut, f"{p}_apb_paddr").value = 0
        getattr(dut, f"{p}_apb_pwdata").value = 0
        getattr(dut, f"{p}_apb_pprot").value = 0
        getattr(dut, f"{p}_apb_pstrb").value = 0
        getattr(dut, f"{p}_ctrl_reg_write").value = 0
        getattr(dut, f"{p}_ctrl_reg_addr").value = 0
        getattr(dut, f"{p}_ctrl_reg_wdata").value = 0
    dut.m_poresetn.value = 0
    dut.s_poresetn.value = 0
    dut.m_hresetn.value = 0
    dut.s_hresetn.value = 0
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def ctrl_write(dut, side, addr, data):
    sig_w = getattr(dut, f"{side}_ctrl_reg_write")
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_d = getattr(dut, f"{side}_ctrl_reg_wdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr
    sig_d.value = data
    sig_w.value = 1
    await RisingEdge(dut.apb_clk)
    sig_w.value = 0


async def apb_write(dut, side, addr, data):
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwdata = getattr(dut, f"{side}_apb_pwdata")
    pstrb = getattr(dut, f"{side}_apb_pstrb")
    pready = getattr(dut, f"{side}_apb_pready")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 1
    pwdata.value = data
    pstrb.value = 0xF
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            break
    psel.value = 0
    pen.value = 0
    pwr.value = 0


async def apb_read(dut, side, addr):
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pready = getattr(dut, f"{side}_apb_pready")
    prdata = getattr(dut, f"{side}_apb_prdata")
    await RisingEdge(dut.apb_clk)
    psel.value = 1
    paddr.value = addr & 0x1FFF
    pwr.value = 0
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            data = int(prdata.value)
            break
    psel.value = 0
    pen.value = 0
    return data


async def _drive_slave(dut, verdict=None):
    """Common slave self-lock stimulus with the mask_hs bypass DISABLED.

    `s_apb_debug_unlock=1` is set ONLY to let the cocotb APB write reach
    Wlink (it gates the Wlink-APB write-passthrough mux). It is NOT a
    mask_hs_gate term in axi_chiplet_controller.sv, so it cannot itself
    open the gate — held identical across all three tests so the ONLY
    independent variable is the 0x21C verdict (Fix B).
    """
    await setup(dut)
    # Close the bring-up bypass: the gate can now ONLY open via the real
    # wlink_mask_hs_result[0] that Fix B produces.
    dut.s_mask_hs_bypass.value = 0
    dut.s_apb_debug_unlock.value = 1
    await ClockCycles(dut.slave_clk, 5)

    if verdict is not None:
        await apb_write(dut, "s", WL_LANE_MASK_HS_RESULT, verdict)
        await ClockCycles(dut.slave_clk, 5)

    # SW W1S of ROLE_CFG[1] (role=slave, lock) — the role-lock request.
    await ctrl_write(dut, "s", 0, 0x03)
    await ClockCycles(dut.slave_clk, 50)

    locked = int(dut.s_role_locked.value)
    is_master = int(dut.s_role_is_master.value)
    hs_res = int(dut.u_slave.u_wlink.mask_hs_result_o.value)
    match_q = int(dut.u_slave.u_wlink.hs_result_match_q.value)
    fail_q = int(dut.u_slave.u_wlink.hs_result_fail_q.value)
    # NOTE: 0x21C has a write sniffer + mask_hs_result_o drive but no
    # generated-regfile READ path, so an apb_read of 0x21C is meaningless
    # and intentionally not used as an oracle. The genuine proof is the
    # hierarchical mask_hs_result_o (Fix B connectivity) and s_role_locked
    # (gate behaviour).
    dut._log.info(
        "slave: is_master=%d role_locked=%d mask_hs_result_o=%s "
        "(match_q=%d fail_q=%d)",
        is_master, locked, format(hs_res, "02b"), match_q, fail_q)
    return locked, hs_res


@cocotb.test()
async def test_01_no_verdict_no_selflock(dut):
    """NEGATIVE CONTROL: mask_hs_bypass=0 and no 0x21C verdict written.

    Proves the gate is genuinely closed without Fix B's contribution —
    i.e. the bypass really is off and nothing else (incl. apb_debug_unlock)
    opens the mask_hs gate for a slave.
    """
    locked, hs_res = await _drive_slave(dut, verdict=None)
    assert hs_res == 0b00, (
        f"mask_hs_result_o=0b{hs_res:02b} without any 0x21C write — "
        "Fix B sniffer latched spuriously")
    assert locked == 0, (
        "slave role_locked latched with bypass=0 and NO match verdict — "
        "the gate is being opened by something other than Fix B "
        "(negative control failed)")


@cocotb.test()
async def test_02_fail_verdict_no_selflock(dut):
    """NEGATIVE CONTROL: mask_hs_bypass=0, verdict 0x02 (peer says MISMATCH).

    A 0x02 verdict must set only the `fail` bit (mask_hs_result_o[1]); the
    `match` bit (bit[0], the gate opener) must stay 0, so the slave must
    NOT self-lock. Proves it is specifically the 0x01 MATCH verdict — not
    "any write to 0x21C" — that opens the gate.
    """
    locked, hs_res = await _drive_slave(dut, verdict=VERDICT_FAIL)
    assert hs_res == 0b10, (
        f"mask_hs_result_o=0b{hs_res:02b}, expected 0b10 "
        "(fail=1, match=0) for a 0x02 verdict — Fix B mis-decoded the "
        "verdict byte")
    assert locked == 0, (
        "slave role_locked latched on a FAIL verdict — the match bit must "
        "gate role_lock, not merely any 0x21C activity")


@cocotb.test()
async def test_03_match_verdict_selflock(dut):
    """POSITIVE: mask_hs_bypass=0, verdict 0x01 (peer says masks MATCH).

    This is the autonomous slave self-lock that Fix B enables: the 0x01
    verdict sets mask_hs_result_o[0] -> mask_hs_match -> mask_hs_gate_open,
    so the slave's role_lock latches with NO bypass — the autonomous
    replacement for the manual bring-up bypass.
    """
    locked, hs_res = await _drive_slave(dut, verdict=VERDICT_MATCH)
    assert hs_res == 0b01, (
        f"mask_hs_result_o=0b{hs_res:02b}, expected 0b01 "
        "(match=1, fail=0) — Fix B connectivity broken")
    assert locked == 1, (
        "slave role_locked did NOT latch on a MATCH verdict with "
        "mask_hs_bypass=0 — Fix B failed to open the gate (the slave "
        "still cannot self-lock autonomously)")
