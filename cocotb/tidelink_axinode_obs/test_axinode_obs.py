"""Unit test for tidelink_axinode_obs (silicon-feedback item I4).

Proves the AXI data-node observability word reflects an injected data-node
stall: a live per-channel stall bit, a sticky wedge witness once the stall
persists past the threshold, the aggregate data-nodes-healthy bit dropping,
and the sticky response-error witness.

The tb wrapper shrinks WEDGE_LOG2 to 4 (16 cycles) so the wedge witness is
reachable quickly; the shipping controller instantiates the default (12).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

MARKER = 0xAD
# obs_axinodes bit layout (see src/rtl/tidelink_axinode_obs.sv)
B_STALL_LIVE = 0       # [9:0]   {ini(r,ar,b,w,aw), tgt(r,ar,b,w,aw)}
B_WEDGE      = 10      # [19:10]
B_TGT_ERR    = 20
B_INI_ERR    = 21
B_ANY_STALL  = 22
B_HEALTHY    = 23
B_MARKER     = 24
# per-side channel bit offsets within a 5-bit {r,ar,b,w,aw} field
CH_AW, CH_W, CH_B, CH_AR, CH_R = 0, 1, 2, 3, 4


def obs(dut):
    return int(dut.obs_axinodes.value)


def field(val, lo, width):
    return (val >> lo) & ((1 << width) - 1)


async def start(dut):
    cocotb.start_soon(Clock(dut.app_clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.apb_clk, 10, units="ns").start())
    # Tie every handshake off (no stall, no transfers).
    for sig in ("tgt_aw_valid", "tgt_aw_ready", "tgt_w_valid", "tgt_w_ready",
                "tgt_b_valid", "tgt_b_ready", "tgt_b_err",
                "tgt_ar_valid", "tgt_ar_ready", "tgt_r_valid", "tgt_r_ready",
                "tgt_r_err", "ini_aw_valid", "ini_aw_ready", "ini_w_valid",
                "ini_w_ready", "ini_b_valid", "ini_b_ready", "ini_b_err",
                "ini_ar_valid", "ini_ar_ready", "ini_r_valid", "ini_r_ready",
                "ini_r_err"):
        getattr(dut, sig).value = 0
    dut.resetn.value = 0
    await ClockCycles(dut.app_clk, 4)
    dut.resetn.value = 1
    await ClockCycles(dut.app_clk, 4)


@cocotb.test()
async def test_reset_healthy(dut):
    """Out of reset: marker present, healthy set, nothing stalled/wedged."""
    await start(dut)
    v = obs(dut)
    assert field(v, B_MARKER, 8) == MARKER, f"marker {hex(v)}"
    assert field(v, B_HEALTHY, 1) == 1, f"expected healthy at reset, {hex(v)}"
    assert field(v, B_STALL_LIVE, 10) == 0, f"stall_live nonzero, {hex(v)}"
    assert field(v, B_WEDGE, 10) == 0, f"wedge nonzero, {hex(v)}"
    assert field(v, B_ANY_STALL, 1) == 0, f"any_stall set, {hex(v)}"


@cocotb.test()
async def test_injected_stall_wedges_target_aw(dut):
    """A held tgt-AW stall shows live, then latches the wedge witness and
    drops the healthy bit; deasserting clears live but keeps the sticky wedge."""
    await start(dut)

    # Inject: AW valid asserted, ready never returns (link-down signature).
    dut.tgt_aw_valid.value = 1
    dut.tgt_aw_ready.value = 0

    # After a few cycles the LIVE stall must be visible (past the 2-flop CDC
    # latency but before the 16-cycle persistence threshold, so no wedge yet).
    await ClockCycles(dut.app_clk, 6)
    v = obs(dut)
    tgt_live = field(v, B_STALL_LIVE, 5)
    assert (tgt_live >> CH_AW) & 1 == 1, f"AW live stall not seen, {hex(v)}"
    assert field(v, B_ANY_STALL, 1) == 1, f"any_stall not set, {hex(v)}"

    # Hold past the wedge threshold (WEDGE_LOG2=4 -> 16 cyc) + CDC.
    await ClockCycles(dut.app_clk, 30)
    v = obs(dut)
    tgt_wedge = field(v, B_WEDGE, 5)
    assert (tgt_wedge >> CH_AW) & 1 == 1, f"AW wedge witness not latched, {hex(v)}"
    assert field(v, B_HEALTHY, 1) == 0, f"healthy still set after wedge, {hex(v)}"

    # Release the stall: live clears, sticky wedge + unhealthy remain.
    dut.tgt_aw_valid.value = 0
    await ClockCycles(dut.app_clk, 6)
    v = obs(dut)
    assert field(v, B_STALL_LIVE, 10) == 0, f"live stall stuck, {hex(v)}"
    assert field(v, B_ANY_STALL, 1) == 0, f"any_stall stuck, {hex(v)}"
    assert (field(v, B_WEDGE, 5) >> CH_AW) & 1 == 1, f"wedge not sticky, {hex(v)}"
    assert field(v, B_HEALTHY, 1) == 0, f"healthy recovered w/o reset, {hex(v)}"


@cocotb.test()
async def test_response_error_sticky(dut):
    """A completed initiator R handshake carrying resp[1] latches ini_resp_err
    and drops healthy; a clean handshake never does."""
    await start(dut)

    # Clean R completion (resp OK) — must NOT flag an error.
    dut.ini_r_valid.value = 1
    dut.ini_r_ready.value = 1
    dut.ini_r_err.value = 0
    await ClockCycles(dut.app_clk, 2)
    dut.ini_r_valid.value = 0
    dut.ini_r_ready.value = 0
    await ClockCycles(dut.app_clk, 3)
    v = obs(dut)
    assert field(v, B_INI_ERR, 1) == 0, f"clean handshake flagged error, {hex(v)}"
    assert field(v, B_HEALTHY, 1) == 1, f"healthy dropped on clean txn, {hex(v)}"

    # Error R completion (resp[1]=1) — must latch the sticky witness.
    dut.ini_r_valid.value = 1
    dut.ini_r_ready.value = 1
    dut.ini_r_err.value = 1
    await ClockCycles(dut.app_clk, 2)
    dut.ini_r_valid.value = 0
    dut.ini_r_ready.value = 0
    dut.ini_r_err.value = 0
    await ClockCycles(dut.app_clk, 4)
    v = obs(dut)
    assert field(v, B_INI_ERR, 1) == 1, f"ini resp-error not latched, {hex(v)}"
    assert field(v, B_HEALTHY, 1) == 0, f"healthy still set after resp error, {hex(v)}"
