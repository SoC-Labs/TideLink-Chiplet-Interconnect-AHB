"""MIDSTREAM lane-mask change — the silicon 0xE5 reproduction attempt.

HYPOTHESIS
----------
test_v2_lane_mask_sweep proves the RTL byte geometry is popcount-GENERIC: every
lane count 2..8, contiguous and non-contiguous, is byte-exact both directions
when the mask is latched BEFORE bring-up. So "odd lane count breaks the framer"
is not an RTL defect.

But the silicon procedure is different. On silicon the FPGA build POR-defaults
the Wlink lane mask to 0xE4 (Wlink.v:2438 `LANE_MASK_RESET`, gated by
TD_AUTO_LANE_MASK_E4, injected ONLY into the FPGA build at fpga/filelist.tcl:119
— "so it reaches only the FPGA build, never the sims"). The link therefore
TRAINS at 0xE4. Only afterwards does the operator write 0x214=0xe5e5 to try 5
lanes.

Two things make that mid-flight change unsafe:

 1. `pynq_host/overlay.py:320-328` (set_lane_mask docstring) states the
    contract explicitly: "Both ends of the link must program identical masks
    BEFORE the link is enabled (or with the link held in reset/disabled). The
    hardware does not enforce this; mismatch produces silent corruption."

 2. `axi_chiplet_controller.sv:2097` latches the SYNC/anchor detector mask from
    the datapath mask — `swi_sync_lane_mask_r <= wlink_rx_lane_mask` — inside a
    ONE-SHOT (`sync_cfg_on_fired_q <= 1'b1`). It fires once, during autonomous
    bring-up. A later 0x214 write moves the DATAPATH to K=5 but leaves the
    SYNC/anchor mask STALE at 0xE4.

That leaves the tx/rx datapath geometry (K=5) inconsistent with the
SYNC/anchor view (K=4) — the exact asymmetry class that
test_v2_lane_mask_negctl proves yields an ALL-ZERO RX, which is precisely the
silicon signature (link trains, fcsm=4, reanchored=1, GP1 RX all zeros).

WHAT THIS TEST DOES
-------------------
Reproduces the silicon SEQUENCE rather than the silicon mask:
    POR at 0xE4  ->  full bring-up (link trains, one-shots latch at 0xE4)
                 ->  write the mask to 0xE5 mid-flight
                 ->  send data
and reports what lands. It is DIAGNOSTIC (it records the outcome and asserts
only the things that are certain), not a pass/fail gate, because the silicon
POR path also involves the autonomous nego sequence this TB bypasses.

Run:
    make EPOCH_PROFILE=zero MODULE=test_v2_lane_mask_midstream
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, run_bringup_full, make_packet

BRINGUP_MASK = 0xE4      # what silicon POR-defaults to (TD_AUTO_LANE_MASK_E4)
TARGET_MASK = 0xE5       # what the operator then asks for (adds lane 0)
APB_WL_LANE_MASK = 0x0214
PAYLOAD = [0xCAFE0001, 0xCAFE0002]


def _wlink(tb, side):
    return tb.top(side).u_chiplet_controller.u_wlink


def force_mask(tb, mask):
    for side in ("m", "s"):
        wl = _wlink(tb, side)
        wl.swi_tx_lane_mask.value = Force(mask)
        wl.out_prepend_swi_rx_lane_mask.value = Force(mask)


def release_mask(tb):
    for side in ("m", "s"):
        wl = _wlink(tb, side)
        wl.swi_tx_lane_mask.value = Release()
        wl.out_prepend_swi_rx_lane_mask.value = Release()


def read_sync_mask(tb, side):
    """The SYNC/anchor detector mask — the one-shot-latched mirror."""
    try:
        return int(tb.top(side).u_chiplet_controller.swi_sync_lane_mask_r.value)
    except (AttributeError, ValueError):
        return -1


async def _deliver(tb, ctx):
    words = make_packet(PAYLOAD)
    await tb.ahb_tx_write_packet("m", words)
    await ClockCycles(tb.dut.hclk, 3000)
    got = [await tb.ahb_fifo_read_word("s", i * 4) for i in range(4)]
    ok = all(got[i] == words[i] for i in range(4))
    allzero = all(g == 0 for g in got)
    tb.log.info(f"  [{ctx}] sent=[{', '.join(f'0x{w:08x}' for w in words)}] "
                f"rx=[{', '.join(f'0x{w:08x}' for w in got)}] -> "
                f"{'BYTE-EXACT' if ok else ('ALL ZEROS' if allzero else 'CORRUPT')}")
    return ok, allzero, got


@cocotb.test()
async def test_01_midstream_mask_change(dut):
    """Bring up at 0xE4, then move the datapath mask to 0xE5 mid-flight."""
    tb = PairV2TB(dut)
    await tb.reset()

    # --- Phase 1: POR + bring-up at the silicon POR mask (0xE4) -------------
    force_mask(tb, BRINGUP_MASK)
    await ClockCycles(dut.hclk, 50)
    force_mask(tb, BRINGUP_MASK)
    tb.log.info(f"  [phase1] bringing up at mask 0x{BRINGUP_MASK:02X} "
                f"(K={bin(BRINGUP_MASK).count('1')}) — the silicon POR default")
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "bring-up at 0xE4 failed"
    await ClockCycles(dut.hclk, 500)
    for side, name in (("m", "M"), ("s", "S")):
        tb.log.info(f"  [phase1] {name}: swi_sync_lane_mask_r="
                    f"0x{read_sync_mask(tb, side):02x} (one-shot latched view)")

    ok_before, _, _ = await _deliver(tb, "phase1-0xE4-control")
    assert ok_before, ("control failed: 0xE4 must deliver byte-exact before the "
                       "midstream change — INSTRUMENT FAULT")

    # --- Phase 2: operator moves the datapath mask to 0xE5 mid-flight -------
    tb.log.info(f"  [phase2] LIVE LINK: writing 0x214 = 0x{TARGET_MASK:02x}"
                f"{TARGET_MASK:02x} (mask -> 0x{TARGET_MASK:02X}, K=5) "
                f"WITHOUT a re-POR — the silicon procedure")
    release_mask(tb)
    for side in ("m", "s"):
        try:
            await tb.apb(side).write(APB_WL_LANE_MASK,
                                     (TARGET_MASK << 8) | TARGET_MASK)
        except Exception as e:                      # noqa: BLE001
            tb.log.warning(f"[{side}] APB lane-mask write failed: {e}")
    force_mask(tb, TARGET_MASK)
    await ClockCycles(dut.hclk, 2000)

    for side, name in (("m", "M"), ("s", "S")):
        wl = _wlink(tb, side)
        tx = int(wl.swi_tx_lane_mask.value)
        rx = int(wl.out_prepend_swi_rx_lane_mask.value)
        sync = read_sync_mask(tb, side)
        tb.log.info(f"  [phase2] {name}: datapath tx=0x{tx:02x} rx=0x{rx:02x} "
                    f"| SYNC/anchor mask=0x{sync:02x}")
        if sync != -1 and sync != tx:
            tb.log.error(
                f"  [phase2] {name}: MASK SPLIT — datapath K="
                f"{bin(tx).count('1')} (0x{tx:02x}) but SYNC/anchor mask is "
                f"STALE at 0x{sync:02x} (K={bin(sync).count('1')}). This is the "
                f"one-shot at axi_chiplet_controller.sv:2097 failing to track a "
                f"midstream 0x214 write.")

    ok_after, allzero_after, got = await _deliver(tb, "phase2-0xE5-midstream")

    tb.log.info("=" * 70)
    tb.log.info(f"  MIDSTREAM RESULT: 0xE4 control delivered={ok_before}; "
                f"after mask->0xE5 delivered={ok_after} allzero={allzero_after}")
    if not ok_after and allzero_after:
        tb.log.info("  *** REPRODUCED the silicon signature: link stayed "
                    "trained, payload went ALL ZEROS after a midstream mask "
                    "change ***")
    elif ok_after:
        tb.log.info("  Midstream change was absorbed cleanly in sim — the "
                    "silicon all-zeros is NOT explained by the mask-change "
                    "sequence alone.")
    tb.log.info("=" * 70)
