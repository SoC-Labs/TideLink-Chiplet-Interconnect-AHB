"""V2 XHB500 window — bounded-timeout backstop proof (far-terminus wedge).

Companion to test_v2_xhb_window (healthy round-trip) and
test_v2_xhb_window_bridge (silicon comb-loop repro). This one proves the NEW
ahb_sub bounded-stall backstop added to src/rtl/tidelink_top.sv:

    On silicon a sustained window burst (or any transfer that stalls on a link
    hiccup) can leave the master-side XHB500 slv holding ahb_sub_hreadyout LOW
    forever -> the Xilinx axi_ahblite_bridge + Zynq PS interconnect block with
    NO PS-side timeout -> z2_02 wedges off-net (physical power-cycle to recover).

    The backstop mirrors tidelink_fc_adapter.sv's TX_STALL_TIMEOUT: after
    SUB_STALL_TIMEOUT_LOG2 hclk cycles of one transfer held stalled, ahb_sub is
    completed with the standard AHB two-cycle ERROR response (HRESP=ERROR,
    HREADYOUT pulsed high) so the PS un-blocks with a recoverable bus error
    (SIGBUS) instead of hanging.

HOW THIS TEST WEDGES THE FAR TERMINUS
-------------------------------------
A window READ from the master (0x4000_0000) is NON-postable: the master XHB500
slv MUST hold ahb_sub_hreadyout low until the R response returns across the
link from the slave die's ahb_mng BRAM terminus (u_s_mng_bram). We deposit
force_stall=1 on that BRAM (holds its HREADY low), so the peer ahb_mng master
never completes the read, no R crosses back, and ahb_sub_hreadyout would hang
forever WITHOUT the backstop. WITH it, the read completes as HRESP=ERROR within
~2^SUB_STALL_TIMEOUT_LOG2 cycles.

To keep the sim fast the RTL localparam is overridden small at compile time:
    make MODULE=test_v2_xhb_window_stall SIM_BUILD=sim_build_stall \
         EXTRA_DEFINES=+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=8
(2^8 = 256 hclk; production default is 2^16.) The test reads the override from
the TIDELINK_SUB_STALL_TIMEOUT_LOG2 env var to size its wait window.

Run:
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh
    export TIDELINK_PHY_V2=1
    make MODULE=test_v2_xhb_window_stall SIM_BUILD=sim_build_stall \
         EXTRA_DEFINES=+define+TIDELINK_SUB_STALL_TIMEOUT_LOG2=8
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full
from test_v2_xhb_window import AHBSubMaster, _slave_bram_peek

APERTURE_BASE = 0x4000_0000

# Mirror the compile-time RTL override so the wait window tracks the backstop.
_TIMEOUT_LOG2 = int(os.environ.get("TIDELINK_SUB_STALL_TIMEOUT_LOG2", "16"))
_BACKSTOP_CYCLES = 1 << _TIMEOUT_LOG2
# The read must be given comfortably MORE cycles than the backstop needs so a
# failure to fire reads as a genuine hang (TimeoutError), not an under-run.
_READ_TIMEOUT = _BACKSTOP_CYCLES + 4000


@cocotb.test()
async def test_xhb_window_stall_returns_error(dut):
    """A window transfer whose far terminus is wedged must return AHB ERROR
    within the bounded timeout instead of hanging ahb_sub forever."""
    tb = PairV2TB(dut)
    master = AHBSubMaster(dut)          # idles ahb_sub before bring-up
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 1000)

    fcsm_pre = (tb.fcsm_state("m"), tb.fcsm_state("s"))

    # ---- sanity: the window is healthy before we wedge it --------------------
    off_ok, data_ok = 0x040, 0x5A5A_1234
    await master.write(APERTURE_BASE + off_ok, data_ok)
    await ClockCycles(dut.hclk, 8000)
    got_ok = await master.read(APERTURE_BASE + off_ok)
    assert got_ok == data_ok, (
        f"window not healthy pre-stall: wrote 0x{data_ok:08x} read 0x{got_ok:08x}")
    tb.log.info(f"  [stall] pre-stall sanity round-trip OK "
                f"(+0x{off_ok:03x}=0x{got_ok:08x}); backstop={_BACKSTOP_CYCLES} cyc")

    # ---- wedge the far terminus: hold the slave-die BRAM HREADY low ----------
    dut.u_s_mng_bram.force_stall.value = 1
    await ClockCycles(dut.hclk, 4)
    assert int(dut.u_s_mng_bram.force_stall.value) == 1, "stall deposit didn't take"

    # ---- a non-postable READ now cannot complete across the link -------------
    off_stall = 0x080
    got_err = False
    hung = False
    try:
        # Generous timeout: MUST exceed the backstop, so if the backstop is
        # absent/broken this raises TimeoutError (hang) rather than ERROR.
        await master.read(APERTURE_BASE + off_stall, timeout=_READ_TIMEOUT)
    except RuntimeError as e:
        got_err = "HRESP=ERROR" in str(e)
        tb.log.info(f"  [stall] read returned ERROR as expected: {e}")
    except TimeoutError as e:
        hung = True
        tb.log.error(f"  [stall] read HUNG (backstop did not fire): {e}")

    # release so the sim can retire cleanly
    dut.u_s_mng_bram.force_stall.value = 0
    await ClockCycles(dut.hclk, 50)

    fcsm_post = (tb.fcsm_state("m"), tb.fcsm_state("s"))
    tb.log.info(f"  [stall] fcsm m/s: {fcsm_pre} -> {fcsm_post}")

    assert not hung, (
        "ahb_sub HUNG on a wedged far terminus — the bounded-timeout backstop "
        "did NOT complete the transfer (this is the z2_02 PS-wedge bug).")
    assert got_err, (
        "wedged window read did not return HRESP=ERROR — backstop absent or "
        "returned OKAY (which would silently drop the beat).")
    tb.log.info("  [stall] PASS: wedged window transfer terminated with AHB "
                "ERROR within the bounded timeout — PS would un-block (SIGBUS) "
                "instead of hanging.")
