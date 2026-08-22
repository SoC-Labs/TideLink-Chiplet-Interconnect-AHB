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
# ⚠ KNOWN REGRESSION under the HAZARD-3/N2 fix (2026-08-18, measured, NOT yet
# resolved): test_auto_anchor_delivers_under_skew now FAILS under AUTO_ANCHOR=1
# EPOCH_PROFILE=staircase (m2s delivery comes back all-zero). Root cause,
# confirmed by direct hierarchical monitoring of gpio.io_link_tx_tx_idle over
# the whole bring-up+beacon window (~3144 io_link_tx_tx_link_clk samples on
# each die): io_link_tx_tx_idle reads 0 on EVERY sampled edge -- the link
# layer never once reports itself idle under this specific skew-stress
# profile, so the new idle-qualified auto_anchor term never fires a single
# beacon (0 insertions measured), and the corrector never reanchors. This is
# NOT a testbench artifact -- axi_chiplet_controller.sv's own pre-existing
# comment on the force_always OR-term (search "the idle-gated path is starved
# on this silicon, HW 08-05, so the beacon MUST use force_always") already
# documents that an idle-gated approach was tried and found insufficient on
# real silicon for exactly this reason. The HAZARD-3/N2 fix trades some of
# that beacon EFFECTIVENESS back for DATA SAFETY (never insert over a live
# word) -- the right call for a corruption hazard, but it means auto_anchor's
# ability to actually reanchor a SEVERELY skewed link (this test's 0..7-word
# staircase) is now unproven and needs dedicated follow-up + HW validation,
# not just "does it still corrupt data". NOT wired into sim_gate pending that
# follow-up (it was not wired before this fix either). AUTO_ANCHOR=0 EPOCH_
# PROFILE=staircase (negctl) and AUTO_ANCHOR=1 EPOCH_PROFILE=zero (no_word_
# loss_during_burst) are UNAFFECTED -- confirmed still PASS after the fix.
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
# HAZARD-3 / N2 fix (2026-08-18) — the two tests below close a SEPARATE,
# narrower gap than the raceguard test above. The raceguard test proves the
# apb_clk-domain FSM's OWN idle detector (auto_anchor_tx_idle = ~sync_obs_
# a2l_app_v_1) stops the FSM once REAL app traffic is observed. It does NOT
# prove anything about what happens INSIDE the window where auto_anchor_
# pulse_q genuinely IS live: until this fix, that pulse rode the shared
# swi_sync_force_always_in port, which collapses WavD2DGpio_v2.tx_sync_en_w to
# insert_en alone -- unconditionally dropping BOTH io_link_tx_tx_idle (the
# link layer's OWN, fast-clock-domain "no packet queued" signal) and the
# postcount==0 serialiser-drain guard. A real app word genuinely mid-shift in
# the TX serialiser during that window could be corrupted; the raceguard test
# above cannot see this because in this TB nothing is actually mid-shift when
# it drives its own packets (it races the FSM from the OUTSIDE, at hclk
# granularity). These two tests instead reach INSIDE the fast (io_link_tx_tx_
# link_clk) domain and hierarchically force io_link_tx_tx_idle itself, which
# is the only way to deterministically model "a word IS mid-shift right now"
# without depending on exact SERDES timing.
#
#   test_auto_anchor_force_respects_tx_idle_forced: unit-level mechanism proof
#     -- forces io_link_tx_tx_idle=0 for a short window while auto_anchor_
#     pulse_q is live, asserts tx_sync_en_w stays low throughout, then
#     releases the force and asserts insertion CAN resume (the fix does not
#     wedge the recovery path shut).
#   test_auto_anchor_no_corruption_word_boundary_forced: end-to-end sibling of
#     test_auto_anchor_no_word_loss_during_burst above, PLUS a continuous
#     hierarchical monitor asserting tx_sync_en_w is NEVER sampled high while
#     io_link_tx_tx_idle==0 on either die -- closing the "checks the outcome,
#     not the mechanism" gap a pure end-to-end delivery test would leave open.
#
#   PASS  make AUTO_ANCHOR=1 EPOCH_PROFILE=zero MODULE=test_v2_auto_anchor \
#              TESTCASE=test_auto_anchor_force_respects_tx_idle_forced
#   PASS  make AUTO_ANCHOR=1 EPOCH_PROFILE=zero MODULE=test_v2_auto_anchor \
#              TESTCASE=test_auto_anchor_no_corruption_word_boundary_forced
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release
from pair_v2_common import PairV2TB, run_bringup_full, send_and_check


def gpio(tb, side):
    """Hierarchical handle to the WavD2DGpio_v2 instance (same path used by
    test_v2_beacon_drain_diag.py / test_v2_beacon_drain_corruption.py)."""
    return tb.top(side).u_chiplet_controller.u_wlink.phy.gpio


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


AUTO_ANCHOR_OBS = 0x21F4   # Region F slot 5: [18]=pulse(live), [19]=link_up(live)


@cocotb.test()
async def test_auto_anchor_force_respects_tx_idle_forced(dut):
    """HAZARD-3 / N2 fix, unit-level mechanism proof (see module docstring).

    Brings the pair up to link-up (fcsm=4, bilateral CR/CRACK), then
    DETERMINISTICALLY drives auto_anchor_pulse_q live via a hierarchical
    force at the controller, instead of waiting on the apb_clk FSM's own
    dwell/burst timing (which is real-traffic-timing-sensitive -- CR/CRACK
    handshake packets alone were observed, while characterising this test, to
    sometimes trip the FSM's own app-active quench before dwell(256) ever
    completes under EPOCH_PROFILE=zero; that upstream arming behaviour is
    already covered separately by test_auto_anchor_delivers_under_skew's
    pulsed_ever/dwell_max assertions). This isolates exactly the HAZARD-3/N2
    claim: GIVEN the pulse is live, does the downstream force respect the
    link layer's OWN idle signal?

    While the pulse is forced live, hierarchically FORCEs the master's
    io_link_tx_tx_idle=0 for a short deterministic window -- modelling a real
    application word genuinely mid-shift in the TX serialiser at that exact
    fast-clock instant, something the FSM's own (slow, apb_clk-domain) idle
    detector cannot see. Asserts:
      (1) tx_sync_en_w (the serialiser insertion-enable) stays LOW throughout
          the forced window -- the new io_swi_auto_anchor_force_in &
          io_link_tx_tx_idle term must gate it exactly like the pre-existing
          io_link_tx_tx_idle & postcount==0 term would have, had postcount==0
          been reachable.
      (2) after releasing the force, insertion CAN resume via the auto_anchor
          path once idle genuinely returns -- the fix narrows the beacon, it
          does not wedge it shut (this project's own "recovered state must
          clear, normal path must still work" rule).
    Run: AUTO_ANCHOR=1 EPOCH_PROFILE=zero."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"

    ctrl = tb.top("m").u_chiplet_controller
    g = gpio(tb, "m")

    # --- Deterministically drive auto_anchor_pulse_q live (bypasses the
    # apb_clk FSM's own dwell/burst timing -- see docstring). ---
    ctrl.auto_anchor_pulse_q.value = Force(1)
    await ClockCycles(dut.hclk, 4)
    assert int(g.io_swi_auto_anchor_force_in.value) == 1, (
        "io_swi_auto_anchor_force_in did not follow the forced auto_anchor_"
        "pulse_q -- the new port chain (axi_chiplet_controller.sv -> Wlink.v "
        "-> WlinkGPIOPHY_v2.v -> WavD2DGpio_v2.v) is not wired through")

    # Non-vacuity: the link must be GENUINELY idle right now (no packets sent
    # yet) before we force otherwise, or the "goes low when forced non-idle"
    # check below would not be exercising a real idle->non-idle transition.
    await RisingEdge(g.io_link_tx_tx_link_clk)
    assert int(g.io_link_tx_tx_idle.value) == 1, (
        "io_link_tx_tx_idle was not naturally 1 going into the forced window "
        "-- the test setup is not exercising a real idle->non-idle transition")

    # --- Force io_link_tx_tx_idle=0: models a real word mid-shift RIGHT NOW,
    # in the same fast (io_link_tx_tx_link_clk) domain as the serialiser. ---
    g.io_link_tx_tx_idle.value = Force(0)
    saw_high = False
    edges = 0
    for _ in range(40):
        await RisingEdge(g.io_link_tx_tx_link_clk)
        edges += 1
        if int(g.tx_sync_en_w.value) == 1:
            saw_high = True
    g.io_link_tx_tx_idle.value = Release()

    assert edges > 0, "no io_link_tx_tx_link_clk edges observed during the forced window"
    assert not saw_high, (
        "tx_sync_en_w went HIGH while io_link_tx_tx_idle was forced 0 -- the "
        "auto_anchor beacon forced a SYNC insertion over what should be a live "
        "mid-shift application word. HAZARD-3 / N2 regression: the beacon's "
        "force term is not respecting the link layer's own idle signal.")

    # --- Release and confirm insertion CAN resume once idle genuinely holds
    # again (the fix must not permanently wedge the recovery path). ---
    resumed = False
    for _ in range(80):
        await RisingEdge(g.io_link_tx_tx_link_clk)
        idle         = int(g.io_link_tx_tx_idle.value)
        anchor_force = int(g.io_swi_auto_anchor_force_in.value)
        syncen       = int(g.tx_sync_en_w.value)
        if idle == 1 and anchor_force == 1 and syncen == 1:
            resumed = True
            break
    ctrl.auto_anchor_pulse_q.value = Release()
    assert resumed, (
        "tx_sync_en_w never re-asserted via the auto_anchor path after "
        "io_link_tx_tx_idle was released back to its natural (idle) value -- "
        "the fix appears to have wedged the recovery beacon shut rather than "
        "just narrowing its force window.")
    tb.log.info(f"VERDICT: tx_sync_en_w held low for all {edges} forced-idle=0 "
                f"edges, and resumed via auto_anchor once idle genuinely returned.")


async def _idle_violation_monitor(tb, side, stats):
    """Continuous hierarchical monitor (every io_link_tx_tx_link_clk edge):
    tx_sync_en_w must NEVER be sampled high while io_link_tx_tx_idle==0. This
    checks the MECHANISM directly, unlike a pure end-to-end delivery check
    which could pass by coincidence if no word happened to land on a beacon
    cycle in this particular run while the underlying bypass was still live."""
    g = gpio(tb, side)
    while True:
        await RisingEdge(g.io_link_tx_tx_link_clk)
        try:
            idle   = int(g.io_link_tx_tx_idle.value)
            syncen = int(g.tx_sync_en_w.value)
        except ValueError:
            continue
        stats["edges"] += 1
        if idle == 0:
            stats["non_idle_edges"] += 1
            if syncen == 1:
                stats["violations"] += 1


@cocotb.test()
async def test_auto_anchor_no_corruption_word_boundary_forced(dut):
    """HAZARD-3 / N2 fix, end-to-end sibling of test_auto_anchor_no_word_loss_
    during_burst above. Same scenario (AUTO_ANCHOR=1, ZERO skew, packets
    driven immediately at link-up so they overlap the auto-anchor dwell/burst
    window on BOTH dies), but adds a CONTINUOUS hierarchical monitor sampled
    every io_link_tx_tx_link_clk edge on both gpio instances, asserting
    tx_sync_en_w is never observed high while io_link_tx_tx_idle==0. This
    closes the "checks the outcome, not the mechanism" gap: a purely
    end-to-end byte-exact-delivery test can pass on a seed where no word
    happened to straddle a beacon cycle even though the underlying bypass is
    still present. Run: AUTO_ANCHOR=1 EPOCH_PROFILE=zero."""
    tb = PairV2TB(dut)
    await run_bringup_full(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"

    stats_m = dict(edges=0, non_idle_edges=0, violations=0)
    stats_s = dict(edges=0, non_idle_edges=0, violations=0)
    mon_m = cocotb.start_soon(_idle_violation_monitor(tb, "m", stats_m))
    mon_s = cocotb.start_soon(_idle_violation_monitor(tb, "s", stats_s))

    # NO settle wait — send back-to-back straight through the dwell/burst
    # window on BOTH directions (mirrors the raceguard test above, plus s->m
    # so the slave's gpio/monitor is exercised too).
    for i in range(4):
        await send_and_check(tb, "m", "s", [0xF00D0000 | i, 0x1EAF0000 | i],
                             ctx=f"mech_m2s#{i}")
        await send_and_check(tb, "s", "m", [0xB0BA0000 | i, 0x5A5A0000 | i],
                             ctx=f"mech_s2m#{i}")

    await ClockCycles(dut.hclk, 500)
    mon_m.kill()
    mon_s.kill()

    tb.log.info(f"[mech monitor] M edges={stats_m['edges']} "
                f"non_idle={stats_m['non_idle_edges']} violations={stats_m['violations']}")
    tb.log.info(f"[mech monitor] S edges={stats_s['edges']} "
                f"non_idle={stats_s['non_idle_edges']} violations={stats_s['violations']}")

    assert stats_m["non_idle_edges"] > 0 and stats_s["non_idle_edges"] > 0, (
        "monitor never observed a non-idle (word-in-flight) cycle on one side "
        "-- non-vacuous check failed, the mechanism was never exercised in "
        "this run")
    assert stats_m["violations"] == 0 and stats_s["violations"] == 0, (
        f"tx_sync_en_w sampled HIGH while io_link_tx_tx_idle==0: "
        f"M violations={stats_m['violations']} S violations={stats_s['violations']} "
        f"-- the auto_anchor force bypassed the idle qualifier (HAZARD-3 / N2 "
        f"regression), even though end-to-end delivery above may still look clean.")
