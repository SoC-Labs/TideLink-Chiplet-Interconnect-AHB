# test_v2_auto_anchor.py — controller AUTO-ANCHOR (2026-08-04) proof.
#
# The shipping SYNC_REANCHOR deskew corrector only re-anchors on a live SYNC
# beacon, which pair bring-up leaves off on the nego_en=0 / SELF_ARM eth-chiplet
# path -> reanchored=0 -> the RX mis-frames a skewed link (the R1/deskew wedge on
# silicon). The controller AUTO_ANCHOR (axi_chiplet_controller, gated on TX-idle so
# it can never delete a live D2D word) pulses that beacon ONCE at link-up so the
# corrector arms. Proven end-to-end on the pair:
#
#   PASS  make AUTO_ANCHOR=1 EPOCH_PROFILE=staircase MODULE=test_v2_auto_anchor \
#              TESTCASE=test_auto_anchor_delivers_under_skew
#   PASS  make AUTO_ANCHOR=0 EPOCH_PROFILE=staircase MODULE=test_v2_auto_anchor \
#              TESTCASE=test_auto_anchor_negctl_no_anchor_fails   (non-vacuity)
#   PASS  make AUTO_ANCHOR=1 EPOCH_PROFILE=zero      MODULE=test_v2_auto_anchor \
#              TESTCASE=test_auto_anchor_no_word_loss_during_burst  (Defect-A guard)
#
# All run the SYNC_REANCHOR corrector (EPOCH_ANCHOR=0) so the beacon is required.
#
# PAUSE-ACCUMULATE (2026-08-04): on a busy link, FC keepalive can toggle the
# app->link valid more often than ANCHOR_DWELL, and the original FSM RESET the
# dwell on every blip -> len never advanced -> beacon never completed
# (the leading suspect for reanchored=0 on the eth-chiplet HW). The FSM now
# HOLDS dwell/len through app-active blips (pulse still deasserts, so it never
# straddles a live word -- the raceguard test below proves Defect-A safety is
# intact) and only resets dwell on a genuine link-drop. This tb (idle link) can
# prove SAFETY + NO-REGRESSION but NOT the busy-link accumulation benefit -- a
# faithful sub-ANCHOR_DWELL keepalive stream would overflow this RX FIFO. That
# benefit is instead confirmed on HW via the 0x21F4 obs word (dwell_max climbs
# past 256 and pulsed_ever latches under real keepalive traffic).
#
# QUIESCE-AND-BURST (2026-08-05): the HW obs came back dwell_max=256, pulsed_ever=1,
# done=1 but reanchored=0 on BOTH dies -> the burst emitted and COMPLETED, so it was
# NOT starved/fragmented (the app port is idle through bring-up: TXGEN_PRESENT=0, no
# D2D yet, so app_valid=io_app_a2l_valid stays low and the 4096 window was already
# contiguous). The real gap vs the proven MANUAL pulse is BILATERAL TIME-OVERLAP: the
# manual recipe forces SYNC on both dies for ~0.4s SIMULTANEOUSLY, whereas a 4096-cycle
# (~164us) per-die burst fired at each die's own link-up instant is far shorter than the
# ms-scale inter-die bring-up skew, so the two windows never overlapped and neither RX
# saw the peer's SYNC run. Fix: widen ANCHOR_LEN to ~0.4s on silicon (the controller
# keys the short sim window off TB_TOP_AUTO_ANCHOR_EN). This idle-link tb keeps the
# short window and is unchanged by the widen; the overlap fix is HW-proven via 0x21F4.
# NB: the pair Makefile SIM_BUILD key now includes AUTO_ANCHOR — without it the
# AUTO_ANCHOR=1 (deliver/raceguard) and AUTO_ANCHOR=0 (negctl) builds collide in one
# sim_build dir and the negctl silently re-runs the beacon-ON binary (false FAIL).
import cocotb
from cocotb.triggers import ClockCycles
from pair_v2_common import PairV2TB, run_bringup_full, send_and_check


@cocotb.test()
async def test_auto_anchor_delivers_under_skew(dut):
    """AUTO_ANCHOR=1 + staircase skew + SYNC_REANCHOR: the pair delivers ONLY
    because the auto-anchor beacon re-anchors the corrector before app traffic.
    Run: AUTO_ANCHOR=1 EPOCH_PROFILE=staircase."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 6000)   # dwell(256) + burst(4096) + re-anchor latch
    # Instrument check (0x21F4 AUTO_ANCHOR_OBS): prove the FSM actually fired and
    # the obs word is decodable end-to-end (Region F slot 5) BEFORE trusting HW.
    obs = await tb.apb("m").read(0x21F4)
    dwell_max   = obs & 0xFFFF
    pulsed_ever = (obs >> 16) & 1
    done        = (obs >> 17) & 1
    en          = (obs >> 23) & 1
    tb.log.info(f"[auto_anchor obs 0x21F4] raw=0x{obs:08x} dwell_max={dwell_max} "
                f"pulsed_ever={pulsed_ever} done={done} AUTO_ANCHOR_EN={en}")
    assert en == 1, "AUTO_ANCHOR_EN not reflected at 0x21F4 — obs word / param wiring broken"
    assert pulsed_ever == 1, "auto-anchor beacon never emitted (0x21F4 pulsed_ever=0) in sim"
    assert dwell_max >= 256, f"dwell_max={dwell_max} < ANCHOR_DWELL(256) — dwell never completed"
    await send_and_check(tb, "m", "s", [0xA11C0000, 0xC0FFEE01], ctx="auto_anchor_m2s")
    await send_and_check(tb, "s", "m", [0x5A1EAD00, 0xBEEFCAFE], ctx="auto_anchor_s2m")


@cocotb.test()
async def test_auto_anchor_negctl_no_anchor_fails(dut):
    """NEGATIVE CONTROL: same staircase + SYNC_REANCHOR but AUTO_ANCHOR=0 -> no
    beacon -> the corrector never anchors -> a skewed packet does NOT deliver
    byte-exact. Proves the deliver test is non-vacuous.
    Run: AUTO_ANCHOR=0 EPOCH_PROFILE=staircase."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 6000)
    ok, _ = await send_and_check(tb, "m", "s", [0xA11C0000, 0xC0FFEE01],
                                 ctx="negctl_no_anchor", expect_pass=False)
    assert not ok, ("staircase skew delivered byte-exact WITHOUT the auto-anchor "
                    "beacon — the SYNC_REANCHOR corrector should not arm here, so "
                    "the deliver test would be vacuous")


@cocotb.test()
async def test_auto_anchor_no_word_loss_during_burst(dut):
    """Defect-A guard (the corruption race the proposal flagged): with AUTO_ANCHOR=1
    and ZERO skew (so delivery does not depend on the anchor), drive packets
    immediately at link-up — overlapping the auto-anchor's SYNC-burst window. The
    TX-idle gate (~sync_obs_a2l_app_v_1) must suppress the burst while app data
    flows, so EVERY word lands BYTE-EXACT. An ungated force_always burst (the
    proposal as-written) would delete words here. Run: AUTO_ANCHOR=1 EPOCH_PROFILE=zero."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    # NO settle wait — send back-to-back straight through the dwell/burst window.
    for i in range(4):
        await send_and_check(tb, "m", "s", [0xF00D0000 | i, 0x1EAF0000 | i],
                             ctx=f"raceguard_m2s#{i}")
