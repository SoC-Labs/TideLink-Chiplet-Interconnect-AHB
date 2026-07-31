"""PTP timestamp mailbox (Region 3) APB write-protect test for
tidelink_apb_regs.

The mailbox (offsets 0x060-0x07C) is documented in tidelink_apb_regs.sv:526
as "written by FC SIDEBAND" — i.e. it should be read-only from the plain APB
register interface, only ever updated by the internal FC-sideband path (see
tidelink_ptp_servo.sv:220, which unconditionally latches mbox_reg_write into
mbox_sec_lo_r/mbox_sec_hi_r/mbox_ns_r).

But mbox_reg_write is formed at tidelink_apb_regs.sv:527 as:
    assign mbox_reg_write = apb_write && (apb_region == 4'b0011);
with NO source qualifier distinguishing the FC-sideband path from a plain
external APB write (CPU, debugger, or any other bus master driving
psel/penable/pwrite/paddr/pwdata). Region 3 also has no pslverr case in the
apb_region case block (unlike every other read-only region — Region C, D, F
all raise pslverr on a write), so today an external write into the PTP
mailbox is silently accepted with zero rejection.

This test drives a plain external-style APB write to offset 0x068 (Region 3,
mbox_reg_addr == 2, which lands on mbox_sec_lo_r) and asserts mbox_reg_write
is NOT asserted. This is the CORRECT/intended behavior and is EXPECTED TO
FAIL against the current, unmodified RTL — that failure is the proof the
defect exists. The RTL fix itself is tracked/applied separately; this file
must not be used to justify touching src/rtl/**.

2026-07-31 UPDATE — the fix landed one layer UP, not here, so this test
stays RED permanently and is deliberately NOT wired into sim_gate.
tidelink_apb_regs.sv alone cannot distinguish a genuine FC-sideband write
from a plain external one (both arrive as the same psel/penable/pwrite on
the shared bus by the time they reach this module) — only the caller, which
sees the pre-mux arbiter signal, can. tidelink_top.sv now gates the
mbox_reg_write it forwards to the servo with fc_cfg_apb_active (see the
"SoC Labs mailbox-RO fix" comment there). The end-to-end regression that
proves the actual fix — RED with the fix reverted, GREEN with it applied —
is cocotb/tidelink_top_pair_v2/test_v2_mbox_apb_writeprotect.py, which IS
gated (sim_gate_v2_mbox_writeprotect). This file is kept only as the
root-cause reproduction that justified the fix, not as a regression gate.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# Region 3 (mailbox) base = 3 << 5 = 0x060. Sub-offset mbox_reg_addr == 2
# (paddr[4:2] == 2, i.e. +0x008) lands on mbox_sec_lo_r, a confirmed-live
# register per tidelink_ptp_servo.sv:220.
OFF_MBOX_SEC_LO = 0x068


async def setup(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())
    for sig in ("psel", "penable", "pwrite", "paddr", "pwdata",
                "packet_word_length", "current_credit_count", "read_complete",
                "returner_busy", "fifo_overrun", "fifo_underrun",
                "master_error", "packet_committed"):
        getattr(dut, sig).value = 0
    dut.ctrl_reg_rdata.value = 0
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


async def apb_write_decode(dut, addr, data):
    """Drive a plain external-style APB write (SETUP then ACCESS phase,
    same idiom as test_region_f_decode.py's apb_write_decode) and sample the
    combinational mailbox decode signals in the ACCESS phase."""
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 1
    dut.paddr.value = addr & 0xFFF
    dut.pwdata.value = data
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    res = dict(mbox_write=int(dut.mbox_reg_write.value),
               mbox_addr=int(dut.mbox_reg_addr.value),
               mbox_wdata=int(dut.mbox_reg_wdata.value),
               pslverr=int(dut.pslverr.value))
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    return res


@cocotb.test()
async def test_mailbox_not_writable_from_plain_apb(dut):
    """A plain external APB write to the PTP timestamp mailbox (Region 3,
    offset 0x068 -> mbox_sec_lo_r) must NOT assert mbox_reg_write: the
    mailbox is documented as written only by the FC SIDEBAND path, not by
    an arbitrary external APB bus master.

    EXPECTED TO FAIL against the current RTL: mbox_reg_write has no source
    qualifier (tidelink_apb_regs.sv:527), so this plain APB write DOES
    assert it.
    """
    await setup(dut)
    w = await apb_write_decode(dut, OFF_MBOX_SEC_LO, 0xDEAD_BEEF)
    assert w["mbox_write"] == 0, (
        "PTP mailbox accepted a plain external APB write (should be "
        f"FC-SIDEBAND-only, not reachable from a bare psel/penable/pwrite "
        f"bus master): {w}"
    )
