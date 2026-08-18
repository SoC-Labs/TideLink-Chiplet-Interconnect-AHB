"""Unit gate for tidelink_link_rate_regs — the reset-domain property.

THE PROPERTY: a warm reset must not change the rate the divider is using.

This is the regression guard for a defect that was real and severe. The bank
originally reset ratio_req_r / src_sticky_r on hresetn while
tidelink_link_clk_div resets on poresetn, so a fabric warm reset retimed a LIVE
link (measured 20 ns -> 5 ns with poresetn high throughout) and then bricked the
knob: role_locked was 1 by that point, so every repair write was refused.

The fix moved that state into the POR domain. An independent reviewer then
reverted the fix in a shadow tree and found nothing in the repo caught it. These
tests are what catch it.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Copyright 2026, SoC Labs (www.soclabs.org)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_NS = 10.0

REG_ID   = 0x00
REG_CTRL = 0x04
REG_STAT = 0x08


async def _start(dut):
    cocotb.start_soon(Clock(dut.hclk, CLK_NS, units="ns").start())
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = 0
    dut.pwdata.value = 0
    dut.pstrb.value = 0xF
    dut.role_locked_i.value = 0
    dut.ratio_eff_i.value = 0
    dut.hresetn.value = 0
    dut.poresetn.value = 0
    for _ in range(5):
        await RisingEdge(dut.hclk)
    dut.poresetn.value = 1
    dut.hresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.hclk)


async def _apb_write(dut, addr, data, strb=0xF):
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 1
    dut.paddr.value = addr
    dut.pwdata.value = data
    dut.pstrb.value = strb
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    assert int(dut.pready.value) == 1, f"pready must be 1 in the access phase (addr 0x{addr:x})"
    assert int(dut.pslverr.value) == 0, f"pslverr must be 0 (addr 0x{addr:x})"
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0


async def _apb_read(dut, addr):
    await RisingEdge(dut.hclk)
    dut.psel.value = 1
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = addr
    await RisingEdge(dut.hclk)
    dut.penable.value = 1
    await RisingEdge(dut.hclk)
    assert int(dut.pready.value) == 1, f"pready must be 1 (addr 0x{addr:x})"
    assert int(dut.pslverr.value) == 0, f"pslverr must be 0 (addr 0x{addr:x})"
    val = int(dut.prdata.value)
    dut.psel.value = 0
    dut.penable.value = 0
    return val


async def _settle(dut, n=3):
    """Let a CTRL write commit.

    The bank uses a TWO-PHASE COMMIT: ctrl_pend_r latches at the access edge and
    ctrl_commit = ctrl_pend_r & ~role_locked_i takes effect on the following
    edge. That interlock exists so a write cannot straddle the edge on which
    role_lock rises. So ratio_o is NOT valid in the same cycle the write ends —
    this wait is the protocol, not a papered-over race.
    """
    for _ in range(n):
        await RisingEdge(dut.hclk)
    await Timer(1, units="ns")


async def _warm_reset(dut, cycles=3):
    """Pulse hresetn only. poresetn stays HIGH — that is the whole point."""
    await RisingEdge(dut.hclk)
    dut.hresetn.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.hclk)
    dut.hresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.hclk)


@cocotb.test()
async def test_warm_reset_does_not_change_the_rate(dut):
    """THE regression guard. Set a ratio, lock the role, warm-reset, and assert
    the rate the divider is being handed is untouched.

    Revert the reset-domain fix and this test fails. That is its only job."""
    await _start(dut)

    await _apb_write(dut, REG_CTRL, 2)          # /4
    await _settle(dut)
    assert int(dut.ratio_o.value) == 2, "precondition: the bank should present /4"
    assert int(dut.src_sticky_o.value) == 1, "precondition: sticky should be set"

    # Link comes up. From here a rate change is a safety violation, not a knob.
    dut.role_locked_i.value = 1
    dut.ratio_eff_i.value = 2
    for _ in range(5):
        await RisingEdge(dut.hclk)

    await _warm_reset(dut)

    assert int(dut.ratio_o.value) == 2, (
        f"WARM RESET RETIMED A LIVE LINK: ratio_o went 2 -> {int(dut.ratio_o.value)} "
        "with poresetn HIGH. This is the reset-domain defect: the bank's "
        "rate-determining state must live in the POR domain, because the divider "
        "it controls resets on poresetn.")
    assert int(dut.src_sticky_o.value) == 1, (
        "WARM RESET CLEARED src_sticky: the bank has silently handed ownership of "
        "the ratio back to the hardware port while the link is up.")


@cocotb.test()
async def test_cold_reset_still_clears(dut):
    """The fix must not go too far. A cold POR must still restore /1 bypass —
    otherwise the signed-off power-on configuration is not restorable."""
    await _start(dut)
    await _apb_write(dut, REG_CTRL, 3)
    await _settle(dut)
    assert int(dut.ratio_o.value) == 3

    dut.poresetn.value = 0
    dut.hresetn.value = 0
    for _ in range(5):
        await RisingEdge(dut.hclk)
    dut.poresetn.value = 1
    dut.hresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.hclk)

    assert int(dut.ratio_o.value) == 0, (
        f"cold POR must restore /1 bypass, got {int(dut.ratio_o.value)}")
    assert int(dut.src_sticky_o.value) == 0, (
        "cold POR must return ratio ownership to the hardware port")


@cocotb.test()
async def test_write_after_role_lock_is_refused(dut):
    """The sequencing rule: the rate may only change before role-lock."""
    await _start(dut)
    await _apb_write(dut, REG_CTRL, 1)
    await _settle(dut)
    assert int(dut.ratio_o.value) == 1

    dut.role_locked_i.value = 1
    for _ in range(3):
        await RisingEdge(dut.hclk)

    await _apb_write(dut, REG_CTRL, 4)
    await _settle(dut)
    assert int(dut.ratio_o.value) == 1, (
        f"a CTRL write after role-lock was ACCEPTED (ratio {int(dut.ratio_o.value)}); "
        "changing the rate on a live link invalidates the calibrator's phase offset")


@cocotb.test()
async def test_id_reads_back(dut):
    """Proves the bank is actually decoding rather than the bus reading 0 —
    without this, every other test could pass against a dead slave."""
    await _start(dut)
    val = await _apb_read(dut, REG_ID)
    assert val == 0x4C43_4401, f"ID reads 0x{val:08x}, expected 0x4C434401"
