# =============================================================================
# test_v2_beacon_retire_starve.py — does the UNILATERAL autonomy-retire
# (axi_chiplet_controller.sv branch 2) starve an un-anchored peer of the
# forced-SYNC beacon?  (2026-08-14)
#
# HYPOTHESIS UNDER TEST (from imp/hw_gate/status_decode/SWI_LANE_STATUS_DECODE_2026_08_14.md):
#   The KR260 n=20 baseline campaign failed 3/20, and the 3 failures are exactly
#   the runs with reanchored die_a=1 / die_b=0. Proposed cause: `autonomy_retire_q`
#   BRANCH 2 (`ws_anchor_q && fcsm==4` held for RETIRE_DWELL_SI, HEAD :4862-4866,
#   fired at :4878-4882) has NO peer-anchored term, so die_a retires on its OWN
#   anchor after ~160 ms, dropping `winscan_force_sync`/`ws_serve_active_r` — the
#   forced-SYNC chain the RTL's own re-arm comment (:4843-4844) says "the peer's
#   re-anchor needs" — before die_b has anchored.  die_b then never anchors, its
#   RX stays mis-framed, and the A->B payload lands as all-zeros.
#
# WHAT THIS FILE PROVES / DISPROVES  (run each TESTCASE separately)
#
#   1. test_retire_cannot_fire_in_shipping_posture
#      The branch-2 DWELL is satisfied (rea_up_cnt_q saturates at
#      RETIRE_DWELL_SI) and `autonomy_retire_q` STILL never sets, because the
#      arming conjunction `(nego_en & role_locked & nego_train_cfg_r[0])`
#      (:4878) is false: nego_en=0.  That is the shipping eth-chiplet posture
#      (NEGO_CFG_RESET=7'h00 at src/rtl/tidelink_top.sv:141 and
#      axi_chiplet_controller.sv:84; nanosoc_eth_chiplet.sv:760 does NOT override
#      it; pynq_host/scripts/kr260_eth_bringup.py never writes NEGO_CFG and says
#      so at :193).  Non-vacuity: the dwell really is reached.
#
#   2. test_forced_retire_does_not_starve_peer     [STEEL-MAN / a fortiori]
#      Even when branch 2's dwell is satisfied and the RETIRED state is applied —
#      deliberately, and much EARLIER than the ~160 ms silicon dwell, at the exact
#      moment die_a is anchored and die_b is not — die_a's forced-SYNC output at
#      the Wlink ports does NOT drop, because
#      `auto_anchor_pulse_q` (2026-08-04, :4926-4978) is a FOURTH, independent
#      limb OR'd into the very same Wlink ports (:6656/:6662/:6671) and is gated
#      only by `AUTO_ANCHOR_EN && !auto_anchor_done_q && !swi_training_mode_r` —
#      no `autonomy_armed`, no `autonomy_retire_q`.  die_b then anchors and the
#      pair delivers byte-exact under staircase skew.
#
#   3. test_positive_control_beacon_kill_starves_peer   [NON-VACUITY CONTROL]
#      The back half of the hypothesis IS sound: if die_a's beacon really is
#      absent while die_b is un-anchored, we reproduce EXACTLY the measured
#      YES/NO signature (die_a reanchored=1, die_b reanchored=0) and A->B
#      delivery fails.  So this TB can see beacon starvation; test 2's pass is
#      not a blind spot.  What is refuted is that RETIRE is what removes it.
#
#   4. test_reverse_ordering_dieb_first             [DISCRIMINATING CASE]
#      The mirror of test 2 (die_b anchors first and retires).  The RTL is
#      role-symmetric on this path, so this must behave identically — which is
#      itself evidence AGAINST the hypothesis, whose measured signature is
#      strictly one-directional (NO/YES delivered 4/4).
#
# RUN (from repo root: `source ./set_env.sh` FIRST or every suite dies in ~5 s):
#   cd cocotb/tidelink_top_pair_v2
#   make AUTO_ANCHOR=1 EPOCH_PROFILE=staircase MODULE=test_v2_beacon_retire_starve \
#        TESTCASE=<one of the four above> SIM_BUILD=sim_build_beaconretire_aa1
#
# AUTO_ANCHOR=1 is the SHIPPING eth-chiplet posture
# (imp/fpga/eth_chiplet_ip/src/nanosoc_eth_chiplet.sv:760 sets AUTO_ANCHOR_EN=1'b1).
# EPOCH_PROFILE=staircase makes the anchor LOAD-BEARING for delivery — the
# existing negctl (test_v2_auto_anchor.test_auto_anchor_negctl_no_anchor_fails)
# already proves a staircase-skewed packet does NOT deliver without the anchor.
#
# SIM-vs-SILICON DIVERGENCE, stated up front:
#   Under `+define+TB_TOP_AUTO_ANCHOR_EN` the beacon cap is ANCHOR_LEN=4096
#   (:4913-4917) instead of the silicon 200_000_000, and RETIRE_DWELL_SI is
#   8_000_000 — i.e. in sim the retire dwell is 2000x the beacon window, the
#   INVERSE of silicon (25x the other way).  Branch 2 therefore cannot fire
#   naturally here at all; every test below HOLDS `rea_up_cnt_q` at the threshold
#   with a Force to present the dwell (a plain deposit loses to the always_ff NBA
#   — see _saturate_branch2_dwell), and separately samples the REAL dwell
#   condition every cycle so the presentation is not doing the work.  That is a
#   deliberate, declared reconstruction, and it makes the test STRICTER than
#   silicon: the retire lands early INSIDE the beacon window rather than 25x
#   before its end.
#
# RESULTS (2026-08-14, VCS 2022.06-SP2 / cocotb 2.0.1): all four PASS.
#   -> the hypothesis is REFUTED; the full write-up, with the shipping-vehicle
#      nego_en=0 finding that makes branch 2 unreachable, is in
#      imp/hw_gate/beacon_retire/BEACON_RETIRE_RESULT_2026_08_14.md
# =============================================================================
import os

import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB, send_and_check

# axi_chiplet_controller.sv:4832 — branch-2 silicon dwell.
RETIRE_DWELL_SI = 8_000_000
# axi_chiplet_controller.sv:4831 — branch-1 (sim mutual) dwell.
RETIRE_DWELL = 4096


def _ctrl(dut, side):
    return (dut.u_master if side == "m" else dut.u_slave).u_chiplet_controller


def _wlink(dut, side):
    return _ctrl(dut, side).u_wlink


def _dsk(dut, side):
    """tidelink_lane_deskew instance. NOTE: VCS/VPI exposes this module's
    generate-block members as FLAT, DOTTED child names on the instance itself
    (e.g. child 'g_reanchor.reanchored'), not as nested scopes — see
    test_zz_discover_hierarchy below, which is why that helper is kept."""
    return _ctrl(dut, side).u_wlink.phy.gpio.u_deskew


def _h(obj, flat_name):
    try:
        return getattr(obj, flat_name)
    except AttributeError:
        return obj._id(flat_name, extended=False)


def _reanchored(dut, side):
    """The deskew re-anchor latch (tidelink_lane_deskew.sv:1315 decl, set :1467).
    Same net as epoch_anchored_o (:1524) = EPOCH_STATUS 0x2140 bit0."""
    return _h(_dsk(dut, side), "g_reanchor.reanchored")


def _sync_seen_l(dut, side, lane):
    """Per-lane sticky SYNC-seen latch (tidelink_lane_deskew.sv:536, inside
    g_lane_write[gi].g_sync_capture). Forcing this to 0 on ONE lane holds
    `all_sync_seen` (:1322) low, so the die cannot latch `reanchored` (:1461-1467)
    — while leaving its TX beacon and its per-lane sync_idx capture untouched.
    On Release the lane must WIN A FRESH periodic SYNC CONFIRM run to re-set it
    (self-gating confirm run, :585-600), so the die genuinely needs a LIVE peer
    beacon to anchor afterwards."""
    return _h(_dsk(dut, side), f"g_lane_write[{lane}].g_sync_capture.sync_seen_l")


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _probe(dut, side):
    c = _ctrl(dut, side)
    w = _wlink(dut, side)
    return {
        # --- anchor state (the cross-tab axis) ---
        "reanchored":   _si(_reanchored(dut, side)),
        "ws_anchor_q":  _si(c.ws_anchor_q),
        "fcsm":         _si(c.sync_obs_fcsm_state_1),
        # --- retire block (HEAD :4836-4884) ---
        "retire":       _si(c.autonomy_retire_q),
        "armed":        _si(c.autonomy_armed),
        "nego_en":      _si(c.nego_en),
        "train_auto":   _si(c.nego_train_cfg_r) & 1,
        "role_locked":  _si(c.role_locked),
        "mask_hs_ver":  _si(c.mask_hs_verified_reg),
        "rea_up_cnt":   _si(c.rea_up_cnt_q),
        "fc_stable":    _si(c.fc_stable_cnt_q),
        "winscan_done": _si(c.winscan_done),
        # --- the four OR limbs of the forced-SYNC chain (:6656/:6662/:6671) ---
        "ws_force":     _si(c.winscan_force_sync),
        "ws_serve":     _si(c.ws_serve_active_r),
        "auto_pulse":   _si(c.auto_anchor_pulse_q),
        "auto_done":    _si(c.auto_anchor_done_q),
        "insert_en_r":  _si(c.swi_sync_insert_en_r),
        "force_alw_r":  _si(c.swi_sync_force_always_r),
        # --- what the PHY actually receives (the beacon, at the port) ---
        "PORT_insert":  _si(w.swi_sync_insert_en_in),
        "PORT_force":   _si(w.swi_sync_force_always_in),
        "PORT_robust":  _si(w.swi_sync_robust_detect_in),
    }


def _fmt(p):
    return (f"rea={p['reanchored']} wsq={p['ws_anchor_q']} fcsm={p['fcsm']} | "
            f"retire={p['retire']} armed={p['armed']} nego_en={p['nego_en']} "
            f"train_auto={p['train_auto']} mask_hs={p['mask_hs_ver']} "
            f"rea_up_cnt={p['rea_up_cnt']} fc_stable={p['fc_stable']} "
            f"ws_done={p['winscan_done']} | limbs ws_force={p['ws_force']} "
            f"ws_serve={p['ws_serve']} auto_pulse={p['auto_pulse']} "
            f"auto_done={p['auto_done']} insert_r={p['insert_en_r']} "
            f"force_r={p['force_alw_r']} | PORT insert={p['PORT_insert']} "
            f"force={p['PORT_force']} robust={p['PORT_robust']}")


async def _bringup_fast(tb):
    """run_bringup_full() WITHOUT its 5000-cycle tail — control returns while the
    auto-anchor dwell/beacon window is still ahead of us (in sim that window is
    only ANCHOR_DWELL 256 + ANCHOR_LEN 4096 cycles long)."""
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    m_st, s_st = await tb.wait_cal_done()
    tb.log.info(f"post-autocal: M=0x{m_st:08x} S=0x{s_st:08x} "
                f"cal M={tb.cal_state_name('m')} S={tb.cal_state_name('s')}")
    await tb.do_to_data_mode()


async def _wait_anchor(tb, side, max_cycles=40000):
    """Poll this die's deskew `reanchored` latch."""
    d = _reanchored(tb.dut, side)
    for _ in range(max_cycles // 10):
        await ClockCycles(tb.dut.hclk, 10)
        if _si(d) == 1:
            return True
    return False


async def _saturate_branch2_dwell(tb, side, hold_cycles=40):
    """Present branch 2's DWELL as SATISFIED: hold `rea_up_cnt_q` at
    RETIRE_DWELL_SI so the equality term at :4880-4881 is true.

    A plain DEPOSIT of (RETIRE_DWELL_SI - 2) was tried first and does NOT stick:
    the always_ff at :4862-4866 writes the counter every apb_clk edge, and its
    non-blocking update (computed from the pre-deposit value) lands after the
    deposit, so the counter simply kept free-running (measured 201 / 401 / 601
    across attempts). A held Force is therefore the only faithful way to present
    the ~160 ms dwell inside a ~100 us sim.

    The Force removes the counter's own reset-on-drop, so the caller must
    SEPARATELY assert that `ws_anchor_q && fcsm==4` (the real dwell condition,
    :4862) is genuinely held — otherwise the dwell is being asserted, not shown.
    Returns the observed count."""
    c = _ctrl(tb.dut, side)
    c.rea_up_cnt_q.value = Force(RETIRE_DWELL_SI)
    await ClockCycles(tb.dut.hclk, hold_cycles)
    return _si(c.rea_up_cnt_q)


def _release_branch2_dwell(tb, side):
    _ctrl(tb.dut, side).rea_up_cnt_q.value = Release()


async def _dwell_cond_held(tb, side, cycles=40):
    """Sample the REAL branch-2 dwell condition (:4862) every cycle. Returns
    (held_every_cycle, samples) so a test can prove the dwell was legitimately
    accumulating rather than merely forced."""
    c = _ctrl(tb.dut, side)
    held = True
    n = 0
    for _ in range(cycles):
        await ClockCycles(tb.dut.hclk, 1)
        ok = (_si(c.ws_anchor_q) == 1 and _si(c.sync_obs_fcsm_state_1) == 4)
        held &= ok
        n += 1
    return held, n


async def _force_retire(tb, side):
    """Reconstruct the RETIRED state on `side` in the STRONGEST possible form:
    force `autonomy_retire_q` itself to 1.

    WHY A FORCE AND NOT THE REAL GATE.  The honest route — deposit
    nego_cfg_reg[0]=1 so `(nego_en & role_locked & nego_train_cfg_r[0])` (:4878)
    is true, then saturate the dwell — was tried first and DOES NOT WORK in this
    TB, for a reason worth recording: raising nego_en also arms the winscan FSM
    (`ws_kick_evt`, :5103, is `WINSCAN_FSM_EN & autonomy_armed & ...`), the FSM
    advances to FINALIZE, and that TEARS DOWN THE FC — measured here as
    `fcsm: 4 -> 0` within ~90 us, exactly the silicon winscan LIVELOCK that
    commit cd2db38 describes ("advancing to FINALIZE TEARS DOWN the FC
    (fcsm 4->0)").  With fcsm != 4 the branch-2 counter resets every cycle
    (:4862-4866) and the retire can never latch.  So the natural route is
    self-defeating in this TB; forcing the output is the a-fortiori substitute
    and is STRICTLY more favourable to the hypothesis than reality.

    `autonomy_retire_q` is sticky (:4837-4848) so this models a retire that has
    fired and holds."""
    c = _ctrl(tb.dut, side)
    c.autonomy_retire_q.value = Force(1)
    await ClockCycles(tb.dut.hclk, 20)
    return _probe(tb.dut, side)


def _release_retire(tb, side):
    _ctrl(tb.dut, side).autonomy_retire_q.value = Release()


# =============================================================================
# 1. The shipping vehicle cannot take branch 2 at all.
# =============================================================================
@cocotb.test()
async def test_retire_cannot_fire_in_shipping_posture(dut):
    """CLAUSE-2 CHECK: is branch 2 'really the path taken in the shipping
    configuration'?  Satisfy its DWELL exactly (rea_up_cnt_q saturates at
    RETIRE_DWELL_SI with ws_anchor_q=1 and fcsm=4) and show autonomy_retire_q
    STILL never sets, because nego_en=0 kills the arming conjunction at :4878.
    Run: AUTO_ANCHOR=1 EPOCH_PROFILE=staircase."""
    tb = PairV2TB(dut)
    await _bringup_fast(tb)
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    assert await _wait_anchor(tb, "m"), "die_a never anchored — nothing to time"

    c = _ctrl(dut, "m")
    pre = _probe(dut, "m")
    tb.log.info(f"[shipping-posture] pre : {_fmt(pre)}")

    # Shipping posture precondition (this is the whole point of the test).
    assert pre["nego_en"] == 0, (
        f"nego_en={pre['nego_en']} — this TB is NOT in the shipping eth-chiplet "
        f"posture (NEGO_CFG_RESET=7'h00), so the test would not model the vehicle.")
    assert pre["armed"] == 0, f"autonomy_armed={pre['armed']} with nego_en=0?"

    # NON-VACUITY part 1 — the REAL branch-2 dwell condition (:4862) is genuinely
    # held, i.e. the counter would legitimately be accumulating toward the
    # threshold on silicon.
    held, nsamp = await _dwell_cond_held(tb, "m", cycles=200)
    tb.log.info(f"[shipping-posture] (ws_anchor_q && fcsm==4) held on all "
                f"{nsamp} sampled cycles: {held}; free-running rea_up_cnt_q="
                f"{_si(c.rea_up_cnt_q)}")
    assert held, ("the branch-2 dwell condition was NOT continuously held — the "
                  "counter would reset, so 'retire did not fire' proves nothing")

    # NON-VACUITY part 2 — present the dwell as REACHED.
    cnt = await _saturate_branch2_dwell(tb, "m", hold_cycles=200)
    tb.log.info(f"[shipping-posture] branch-2 dwell presented as {cnt} "
                f"(RETIRE_DWELL_SI={RETIRE_DWELL_SI})")
    post = _probe(dut, "m")
    _release_branch2_dwell(tb, "m")
    tb.log.info(f"[shipping-posture] post: {_fmt(post)}")

    assert post["ws_anchor_q"] == 1 and post["fcsm"] == 4, (
        f"branch-2 counter gate not held (ws_anchor_q={post['ws_anchor_q']} "
        f"fcsm={post['fcsm']}) — the dwell would reset, test is vacuous")
    assert post["rea_up_cnt"] == RETIRE_DWELL_SI, (
        f"rea_up_cnt_q={post['rea_up_cnt']} != RETIRE_DWELL_SI — the branch-2 "
        f"dwell was NOT satisfied, so 'retire did not fire' proves nothing.")

    # THE CLAIM.
    assert post["retire"] == 0, (
        "autonomy_retire_q SET with nego_en=0 — the arming conjunction at :4878 "
        "does not gate the way the RTL text says.")
    # And with autonomy never armed, the two limbs retire would have removed are
    # already dead; the only live beacon limb is auto_anchor.
    assert post["ws_force"] == 0 and post["ws_serve"] == 0, (
        f"winscan_force_sync={post['ws_force']} ws_serve_active_r={post['ws_serve']} "
        f"— non-zero with autonomy_armed=0?")
    tb.log.info("VERDICT: branch-2 dwell SATISFIED (rea_up_cnt_q==RETIRE_DWELL_SI) "
                "and autonomy_retire_q STAYS 0. On the shipping eth-chiplet "
                "posture (nego_en=0) the unilateral retire is UNREACHABLE, and "
                "the forced-SYNC limbs it would drop are already 0.")


# =============================================================================
# 2. Steel-man: fire branch 2 anyway, at the worst possible moment.
# =============================================================================
@cocotb.test()
async def test_forced_retire_does_not_starve_peer(dut):
    """Force the EXACT hypothesised ordering — die_a anchored, die_b NOT — then
    fire branch 2 on die_a and ask whether its forced-SYNC beacon drops and
    whether die_b is consequently starved.
    Run: AUTO_ANCHOR=1 EPOCH_PROFILE=staircase."""
    tb = PairV2TB(dut)
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()

    # Hold die_b un-anchored: one lane's sticky sync_seen forced low.
    blk = _sync_seen_l(dut, "s", 0)
    blk.value = Force(0)
    tb.log.info("[steelman] die_b lane0 sync_seen_l FORCED 0 (die_b cannot anchor)")

    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    await tb.wait_cal_done()
    await tb.do_to_data_mode()
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"

    assert await _wait_anchor(tb, "m"), (
        "die_a never anchored — cannot construct the YES/NO ordering")
    a_pre = _probe(dut, "m")
    b_pre = _probe(dut, "s")
    tb.log.info(f"[steelman] die_a pre-retire : {_fmt(a_pre)}")
    tb.log.info(f"[steelman] die_b pre-retire : {_fmt(b_pre)}")

    # (a) NON-VACUITY part 1 — the intended ordering was achieved.
    assert a_pre["reanchored"] == 1, "die_a not anchored"
    assert b_pre["reanchored"] == 0, (
        f"die_b already anchored (reanchored={b_pre['reanchored']}) — the "
        f"YES/NO ordering was NOT constructed; this test would be vacuous.")
    # The beacon must still be LIVE, or 'die_b did not anchor' would be an
    # artefact of the 4096-cycle sim cap rather than of the retire.
    assert a_pre["auto_pulse"] == 1 and a_pre["auto_done"] == 0, (
        f"die_a's auto-anchor beacon already finished (pulse={a_pre['auto_pulse']} "
        f"done={a_pre['auto_done']}) before the retire — the window closed on its "
        f"own, so nothing about the retire could be concluded.")
    assert a_pre["PORT_force"] == 1, (
        f"die_a swi_sync_force_always_in={a_pre['PORT_force']} before the retire — "
        f"there is no beacon to lose, test is vacuous.")

    # NON-VACUITY part 2 — branch 2's DWELL is presented as satisfied, and
    # branch 1's is NOT (so any retire here is branch 2's).
    cnt = await _saturate_branch2_dwell(tb, "m", hold_cycles=10)
    tb.log.info(f"[steelman] branch-2 dwell presented as {cnt} "
                f"(RETIRE_DWELL_SI={RETIRE_DWELL_SI}); winscan_done="
                f"{_si(_ctrl(dut,'m').winscan_done)}, fc_stable_cnt_q="
                f"{_si(_ctrl(dut,'m').fc_stable_cnt_q)} (branch 1 NOT satisfied)")
    assert cnt == RETIRE_DWELL_SI, (
        f"branch-2 dwell not presentable here (rea_up_cnt_q={cnt}) — say so rather "
        f"than reporting a pass")
    assert _si(_ctrl(dut, "m").fc_stable_cnt_q) != RETIRE_DWELL, \
        "branch 1's dwell is ALSO satisfied — cannot attribute to branch 2"
    # ...and the RETIRED state is then reconstructed at its strongest (see
    # _force_retire's docstring for why the natural gate is self-defeating here).
    at_fire = await _force_retire(tb, "m")
    tb.log.info(f"[steelman] die_a AT-RETIRE   : {_fmt(at_fire)}")
    b_at_fire = _probe(dut, "s")
    tb.log.info(f"[steelman] die_b AT-RETIRE   : {_fmt(b_at_fire)}")

    assert at_fire["retire"] == 1, f"retire reconstruction failed: {_fmt(at_fire)}"
    assert at_fire["armed"] == 0, (
        f"autonomy_armed={at_fire['armed']} with autonomy_retire_q=1 — the retire "
        f"did not take effect on autonomy_armed (:1428)")
    assert b_at_fire["reanchored"] == 0, (
        "die_b anchored before the retire landed — ordering lost")

    # (b) THE CLAIM UNDER TEST: is the forced-SYNC beacon dropped?
    tb.log.info(f"[steelman] beacon at the port across the retire: "
                f"force {a_pre['PORT_force']} -> {at_fire['PORT_force']}, "
                f"insert {a_pre['PORT_insert']} -> {at_fire['PORT_insert']}, "
                f"robust {a_pre['PORT_robust']} -> {at_fire['PORT_robust']}")
    beacon_dropped = (at_fire["PORT_force"] == 0)

    # (c) is the peer consequently unable to anchor?  Release the hold and see.
    blk.value = Release()
    tb.log.info("[steelman] die_b lane0 sync_seen_l RELEASED — die_b must now win a "
                "FRESH periodic SYNC confirm, i.e. it needs a LIVE die_a beacon")
    b_anchored = await _wait_anchor(tb, "s", max_cycles=6000)
    b_post = _probe(dut, "s")
    a_post = _probe(dut, "m")
    tb.log.info(f"[steelman] die_a post        : {_fmt(a_post)}")
    tb.log.info(f"[steelman] die_b post        : {_fmt(b_post)}")

    _release_retire(tb, "m")
    _release_branch2_dwell(tb, "m")

    assert not beacon_dropped, (
        "BEACON DROPPED at the Wlink port when branch 2 fired — the hypothesis's "
        "step 3 HOLDS. (Expected NOT to drop: auto_anchor_pulse_q is OR'd in at "
        ":6656/:6662/:6671 and is not gated by autonomy_armed.)")
    assert b_anchored and b_post["reanchored"] == 1, (
        "die_b failed to anchor after die_a retired — the hypothesis's step 4 "
        "HOLDS (peer starvation).")

    # (d) end-to-end: does the pair still deliver under load-bearing skew?
    await ClockCycles(dut.hclk, 6000)
    await send_and_check(tb, "m", "s", [0xA11C0000, 0xC0FFEE01],
                         ctx="steelman_m2s_after_retire")
    tb.log.info("VERDICT: branch 2 fired on die_a while die_b was UN-anchored; the "
                "forced-SYNC beacon at die_a's Wlink port did NOT drop "
                "(auto_anchor_pulse_q limb); die_b anchored; A->B byte-exact.")


# =============================================================================
# 3. Positive control — a beacon that REALLY stops does starve the peer.
# =============================================================================
@cocotb.test()
async def test_positive_control_beacon_kill_starves_peer(dut):
    """NON-VACUITY CONTROL for test 2.  Suppress die_a's auto-anchor beacon limb
    outright (Force auto_anchor_pulse_q=0) — the state the hypothesis CLAIMS the
    retire produces.  Expect the measured HW signature to reproduce: die_a
    reanchored=1, die_b reanchored=0, A->B delivery FAILS.
    Run: AUTO_ANCHOR=1 EPOCH_PROFILE=staircase."""
    tb = PairV2TB(dut)
    await tb.reset()

    # die_a's beacon limb held OFF for the whole run. die_b's beacon is untouched,
    # so die_a still anchors — exactly the YES/NO configuration.
    ca = _ctrl(dut, "m")
    ca.auto_anchor_pulse_q.value = Force(0)
    tb.log.info("[posctl] die_a auto_anchor_pulse_q FORCED 0 for the whole run")

    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    await tb.wait_cal_done()
    await tb.do_to_data_mode()
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"
    await ClockCycles(dut.hclk, 12000)   # well past dwell(256)+ANCHOR_LEN(4096)

    a = _probe(dut, "m")
    b = _probe(dut, "s")
    tb.log.info(f"[posctl] die_a: {_fmt(a)}")
    tb.log.info(f"[posctl] die_b: {_fmt(b)}")

    assert a["PORT_force"] == 0, (
        f"die_a beacon suppression did not take (PORT_force={a['PORT_force']})")
    assert a["reanchored"] == 1, (
        f"die_a did not anchor (reanchored={a['reanchored']}) — this control needs "
        f"the YES/NO configuration, not NO/NO")
    assert b["reanchored"] == 0, (
        f"die_b anchored ({b['reanchored']}) despite die_a's beacon being dead — "
        f"then die_b's anchor does not depend on die_a's beacon at all and the "
        f"whole starvation mechanism is unsupported")

    ok, got = await send_and_check(tb, "m", "s", [0xA11C0000, 0xC0FFEE01],
                                   ctx="posctl_m2s_starved", expect_pass=False)
    ca.auto_anchor_pulse_q.value = Release()
    assert not ok, (
        "A->B delivered byte-exact with die_a anchored, die_b NOT anchored and "
        "die_a's beacon dead — this TB cannot see beacon starvation, so test 2's "
        "pass would be a blind spot.")
    tb.log.info("VERDICT: a genuinely absent die_a beacon DOES reproduce the "
                f"measured YES/NO signature and kills A->B delivery (got={got}). "
                "The TB is sensitive to exactly the failure the hypothesis "
                "predicts — it simply is not the RETIRE that removes the beacon.")


# =============================================================================
# 4. Discriminating case — reverse ordering (die_b first).
# =============================================================================
@cocotb.test()
async def test_reverse_ordering_dieb_first(dut):
    """The mirror of test 2: die_b (slave) anchors first and retires while die_a
    (master) is un-anchored.  The measured HW cross-tab says NO/YES delivers 4/4
    while YES/NO fails 3/3, so a role asymmetry would have to exist on this path.
    Run: AUTO_ANCHOR=1 EPOCH_PROFILE=staircase."""
    tb = PairV2TB(dut)
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()

    blk = _sync_seen_l(dut, "m", 0)
    blk.value = Force(0)
    tb.log.info("[reverse] die_a lane0 sync_seen_l FORCED 0 (die_a cannot anchor)")

    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    await tb.wait_cal_done()
    await tb.do_to_data_mode()
    assert await tb.wait_cr_crack(), "link did not reach bilateral CR/CRACK"

    assert await _wait_anchor(tb, "s"), "die_b never anchored"
    b_pre = _probe(dut, "s")
    a_pre = _probe(dut, "m")
    tb.log.info(f"[reverse] die_b pre-retire : {_fmt(b_pre)}")
    tb.log.info(f"[reverse] die_a pre-retire : {_fmt(a_pre)}")
    assert b_pre["reanchored"] == 1 and a_pre["reanchored"] == 0, \
        "reverse (NO/YES) ordering not constructed"
    assert b_pre["auto_pulse"] == 1 and b_pre["PORT_force"] == 1, \
        "die_b beacon already over before the retire — vacuous"

    cnt = await _saturate_branch2_dwell(tb, "s", hold_cycles=10)
    assert cnt == RETIRE_DWELL_SI, \
        f"branch-2 dwell not presentable on die_b (rea_up_cnt_q={cnt})"
    at_fire = await _force_retire(tb, "s")
    tb.log.info(f"[reverse] die_b AT-RETIRE  : {_fmt(at_fire)}")
    assert at_fire["retire"] == 1, f"retire reconstruction failed: {_fmt(at_fire)}"
    assert _probe(dut, "m")["reanchored"] == 0, "die_a anchored before the retire"

    beacon_dropped = (at_fire["PORT_force"] == 0)

    blk.value = Release()
    a_anchored = await _wait_anchor(tb, "m", max_cycles=6000)
    tb.log.info(f"[reverse] die_a post       : {_fmt(_probe(dut, 'm'))}")
    _release_retire(tb, "s")
    _release_branch2_dwell(tb, "s")

    assert not beacon_dropped, "die_b's beacon dropped on retire"
    assert a_anchored, "die_a failed to anchor after die_b retired"
    await ClockCycles(dut.hclk, 6000)
    await send_and_check(tb, "m", "s", [0x5A1EAD00, 0xBEEFCAFE],
                         ctx="reverse_m2s_after_retire")
    tb.log.info("VERDICT: the reverse (die_b-first) ordering behaves IDENTICALLY "
                "to test 2 — the retire path is role-SYMMETRIC, so it cannot "
                "explain a one-directional YES/NO-only hardware failure.")


# =============================================================================
# 0. Hierarchy discovery helper (kept: the generate-block names below are the
#    only fragile part of this file, and VCS/VPI names them non-obviously).
# =============================================================================
@cocotb.test(skip=(os.environ.get("COCOTB_TESTCASE", os.environ.get("TESTCASE")) != "test_zz_discover_hierarchy"))
async def test_zz_discover_hierarchy(dut):
    """Print the deskew generate-block children so the handle paths above can be
    re-derived if the RTL is restructured. Not part of any gate."""
    dsk = _ctrl(dut, "m").u_wlink.phy.gpio.u_deskew
    names = sorted(c._name for c in dsk)
    dut._log.info(f"[discover] u_deskew children: {names}")
    for n in names:
        if "reanchor" in n or "lane_write" in n or "sync" in n:
            try:
                sub = getattr(dsk, n)
                dut._log.info(f"[discover]   {n} -> {sorted(c._name for c in sub)}")
            except Exception as e:      # noqa: BLE001 - diagnostic only
                dut._log.info(f"[discover]   {n} -> <{type(e).__name__}: {e}>")
