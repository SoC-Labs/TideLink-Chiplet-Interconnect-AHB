"""Region F (AXI data-node OBS) APB-decode test for tidelink_apb_regs (item I4).

Proves the new Region F select routes to the chiplet controller's 2'b00 bank
via ctrl_reg_rf WITHOUT aliasing Region C, that a Region F read returns the
controller's ctrl_reg_rdata, and that Region F is read-only (writes raise
pslverr and are not forwarded as ctrl_reg writes). Region D routing is
re-checked as a regression that the added fold did not disturb it.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# paddr[8:5] region -> base slot-0 byte offset
OFF_REGION_C = 0x180  # 4'b1100 Region C (autoneg OBS)
OFF_REGION_D = 0x1A0  # 4'b1101 Region D (rxcap OBS)
OFF_REGION_F = 0x1E0  # 4'b1111 Region F (AXI data-node OBS)  <-- new

SENTINEL = 0xAD80_0000  # a distinctive controller ctrl_reg_rdata value


async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    for sig in ("psel", "penable", "pwrite", "paddr", "pwdata",
                "packet_word_length", "current_credit_count", "read_complete",
                "returner_busy", "fifo_overrun", "fifo_underrun",
                "master_error", "packet_committed"):
        getattr(dut, sig).value = 0
    dut.ctrl_reg_rdata.value = SENTINEL
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def apb_read_decode(dut, addr):
    """Drive an APB read and, in the ACCESS phase, sample prdata + the
    combinational ctrl_reg decode signals."""
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = addr & 0xFFF
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    res = dict(prdata=int(dut.prdata.value),
               rf=int(dut.ctrl_reg_rf.value),
               rd=int(dut.ctrl_reg_rd.value),
               addr=int(dut.ctrl_reg_addr.value),
               write=int(dut.ctrl_reg_write.value),
               pslverr=int(dut.pslverr.value))
    dut.psel.value = 0
    dut.penable.value = 0
    return res


async def apb_write_decode(dut, addr, data):
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 1
    dut.paddr.value = addr & 0xFFF
    dut.pwdata.value = data
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    res = dict(rf=int(dut.ctrl_reg_rf.value),
               write=int(dut.ctrl_reg_write.value),
               pslverr=int(dut.pslverr.value))
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    return res


@cocotb.test()
async def test_region_f_read_routes_to_controller(dut):
    """Region F slot 0 (0x1E0): rf select set, folded onto ctrl_reg_addr[4:3]
    ==2'b00 slot 0, and prdata returns the controller's ctrl_reg_rdata."""
    await setup(dut)
    r = await apb_read_decode(dut, OFF_REGION_F)
    assert r["rf"] == 1, f"ctrl_reg_rf not asserted for Region F: {r}"
    assert r["addr"] == 0b00_000, f"ctrl_reg_addr not {{2'b00,slot0}}: {r}"
    assert r["prdata"] == SENTINEL, f"Region F prdata != ctrl_reg_rdata: {r}"


@cocotb.test()
async def test_region_f_slot_index(dut):
    """Region F slot 3 (0x1EC): slot index carried on ctrl_reg_addr[2:0]."""
    await setup(dut)
    r = await apb_read_decode(dut, OFF_REGION_F + 0xC)  # slot 3
    assert r["rf"] == 1, f"rf not set: {r}"
    assert r["addr"] == 0b00_011, f"slot 3 not folded to {{2'b00,3}}: {r}"


@cocotb.test()
async def test_region_f_no_region_c_alias(dut):
    """Region C (0x180) must NOT assert rf and stays on ctrl_reg_addr[4:3]==
    2'b11 — proving 4'b1111 was special-cased off the natural 2'b11 alias."""
    await setup(dut)
    rc = await apb_read_decode(dut, OFF_REGION_C)
    assert rc["rf"] == 0, f"Region C wrongly asserted rf: {rc}"
    assert (rc["addr"] >> 3) == 0b11, f"Region C not on 2'b11 select: {rc}"


@cocotb.test()
async def test_region_f_is_read_only(dut):
    """A write to Region F raises pslverr and is NOT forwarded as a ctrl_reg
    write (Region F is observability-only)."""
    await setup(dut)
    w = await apb_write_decode(dut, OFF_REGION_F, 0xFFFF_FFFF)
    assert w["pslverr"] == 1, f"Region F write did not raise pslverr: {w}"
    assert w["write"] == 0, f"Region F write forwarded as ctrl_reg_write: {w}"


@cocotb.test()
async def test_region_d_regression(dut):
    """Region D still folds onto 2'b00 via rd (rf low) — the added Region F
    fold did not disturb the existing Region D routing."""
    await setup(dut)
    rd = await apb_read_decode(dut, OFF_REGION_D)
    assert rd["rd"] == 1 and rd["rf"] == 0, f"Region D select disturbed: {rd}"
    assert rd["addr"] == 0b00_000, f"Region D not folded to 2'b00 slot0: {rd}"
