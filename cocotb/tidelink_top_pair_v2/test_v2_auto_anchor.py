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
