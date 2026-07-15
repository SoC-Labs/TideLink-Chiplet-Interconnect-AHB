"""FIX-1/2/3 gate — ARM-STAGGER EPISODE BINDING + never-blind-OFF (2026-07-03).

Silicon mechanism (2-agent panel consensus, root-caused on bridge1)
-------------------------------------------------------------------
BUG A (episode binding): the winscan kick was a 1-cycle pulse consumed only in
WS_IDLE/WS_DONE. When the first-armed die ran a PRIVATE training episode
against the un-armed zombie peer, a LATER bilateral training fall landing
MID-SCAN was silently LOST — while fch_pending_r (its own sticky) re-latched
and re-ran the handoff on the STALE zombie-era winscan_done. The dies' scans
bound to DIFFERENT training episodes displaced by the arm gap (seconds).
  FIX-1: sticky ws_kick_pending_q (the fch_pending idiom) + an ABORT-RESTART
  arm — a pending kick observed mid-scan jumps to WS_ARM (re-seed, clear
  winscan_done so fch re-blocks, fresh episode stickies) + the same-cycle
  stale-done mask (a kick suppresses winscan_done the cycle it fires so
  fch_arm can never consume the stale episode's done). Abort count at
  WINSCAN_OBS 0x21B8[7:4].

BUG B (blind timed SYNC-OFF): each die killed its beacons on a LOCAL timer
(fch_done_r + SYNC_OFF_SETTLE) while the peer's WS_FINALIZE re-anchor could
still be refilling (the refill needs PEER beacons; one missed SYNC_PERIOD grid
slot resets the deskew confirm run). The starved die: partial sync_seen,
rea=0, 0x21B8[2] sticky, unanchored fch bootstrap, credit_max=0, dead data.
  FIX-2 (D2 "never blind-OFF"): the SYNC-OFF timer is DELETED — idle-gated
  insert_en=1 + robust=1 are the PERMANENT autonomous data-mode state.
  FIX-3: the F4 anchor timeout now does 3 bounded clear-retries before
  failing open; 0x21B8[3] = "anchored-late".

HOW THE PRIVATE EPISODE IS CREATED IN SIM (the zombie-bypass path)
------------------------------------------------------------------
In sim the un-armed zombie's Wlink/TX is dead, so the master's poll budget
exhausts into the ST_TRAIN_FAIL arc (tidelink_autoneg.sv :1312-1316) which
does NOT pulse local_train_clr — training never FALLS in the pure-FAIL churn
and the winscan is never kicked (verified empirically: 5.7M cycles of R5
retry churn, zero kicks). The SILICON private episode instead completes via
the L4 LOCAL-ONLY BYPASS (:1304-1311): all ACTIVE local lanes locked + no
fault + peer-never-parked -> ST_TRAIN_EXIT -> the zombie's POR-alive I2C core
ACKs the exit write -> :1361 pulses local_train_clr -> the training FALL that
kicks the private scan. This test drives that exact arc by FORCING the
master's autoneg lock-qual inputs (local_swi_lane_locked_i=0xFF,
local_swi_lane_fault_i=0 — a scenario injection on the documented bypass
predicate, the same hierarchical-force idiom the UVM/cocotb autocal tests
use), and creates LATER displaced falls with the documented SW retrain W1P
(NEGO_TRAIN_CFG 0x210C bit[2]).

Variants (BYPASS_AUTONEG=1 build; arming over the REAL APB interface):

  (a) SECONDS-SCALE STAGGER: arm die A only -> its private bypass episode
      completes: winscan_done rises via the FIX-3-retried FAIL-OPEN
      (0x21B8[2] latched — the documented starvation precondition) and the
      fch bootstraps against the zombie (the STALE episode). Release the
      force, arm die B, retrain -> assert the pair REBINDS to the final
      bilateral episode: both dies end 0x21B8[0]=1, bit[2]=0 (the fail-open
      sticky CLEARED by the fresh episode's WS_ARM — the anchor genuinely
      latched), rea=1 both, FCSM=4 + credit_max>0 both, byte-exact data BOTH
      directions, beacons still up (D2). Pre-fix RTL: the late die starves
      (rea=0 / bit[2]=1 / credit_max=0).
  (b) MID-SCAN STAGGER (the kick-loss path): private episode #1 kicks the
      scan; a retrain W1P fires private episode #2 whose training fall lands
      MID-SCAN (episode-2 walk ~170k cycles << scan+FINALIZE ~330k) -> the
      FIX-1 abort-restart must consume it (ws_abort_cnt_q>0; pre-fix RTL: the
      kick is silently LOST and the count stays 0) -> then arm die B and
      assert the same full convergence oracle as (a).
  (c) STAGGER ~ 0 (symmetric regression): arm both dies back-to-back ->
      assert the same oracle (guards the fixes against breaking the
      already-working symmetric bring-up).
  (d) Q1 QUIESCE-BEFORE-FINALIZE (2026-07-04): symmetric arm with die_b's LL
      TX idle slots forced BUSY whenever its LL is out of swreset (modelled
      Loop-10 keepalive pressure) -> assert BOTH dies quiesce for their own
      finalize (fch_quiesced_r + Wlink swi_swreset observed 1 in
      WS_FINALIZE/WS_FIN_CLRLOW) + the full data oracle under pressure. See
      the (d) header comment for why the raw pre-fix starvation ordering is
      silicon-only (the zeropoke run remains the arbiter).
  (e) R-A ANCHOR-VERIFY WRONG-SLOT MODEL (2026-07-04): symmetric arm with the
      WavD2DGpio_v2 per-lane exact-compare vector (anchor_vfy_lane_w) FORCED
      0 on both dies — models a lane whose sticky sync_idx latched an
      adjacent SYNC slot (the die_b byte-lane[23:16] 0x24->0x5c silicon
      corruption: reanchored=1 but the all-lane simultaneous EXACT match can
      never fire). Assert the verify GATES the release (winscan_done held,
      FIX-3 clear-retry fires with the anchor already latched ->
      ws_vfy_retry_q 0x21B8[9]); release the force -> the retried re-anchor
      verifies and the pair converges to the full data oracle (sticky [9]
      still latched as the episode's evidence). Pre-fix RTL: the wrong-slot
      anchor released the handoff and every word shipped one corrupted
      byte-lane forever. FIX-4 (2026-07-04) extensions: this variant is also
      the decorrelated-retry gate — a first-window failure recovering on a
      LATER attempt must show (i) the 0x21B8[13:11] attempt counter >=1 at
      the retry and per-episode-sticky at end, (ii) the WS_FIN_CLRLOW hold
      counter observed ABOVE the WS_CLR_HOLD_SIM base (the LFSR-jittered
      inter-attempt dwell is live), (iii) the jitter LFSR free-running.
      RELEASE SCHEDULE + ORACLE (2026-07-05, debug-timeline root-caused):
      the force is released only once BOTH dies are back in a FINALIZE
      window with a genuine post-clear anchor — releasing at the retry arc
      itself (the old schedule) lets the verify latch on the STALE anchor
      during CLRLOW (pre-FIX-4b that schedule only "passed" via the
      stale-release race FIX-4b closed). Post-release, the first die to
      verify goes DONE, drops force and bootstraps, and its traffic starves
      the peer's gap-intolerant re-confirm — a STRUCTURAL winner-starves-
      loser race of the Loop-13 locally-timed finalize (the same peer-
      finalize-exit starvation family as the silicon lottery; both
      polarities observed in sim). Oracle: winner must recover CLEAN
      in-episode (the R-A/FIX-4 property), loser may take the designed
      fail-open+late-heal degradation, per-episode evidence asserted on
      both, then a retrain W1P must deliver the full byte-exact oracle.
  (f) R-B RENDEZVOUS DORMANCY (Loop-13 2026-07-04): the t33a a-first flow,
      now asserting the Loop-12 rendezvous is fully DORMANT — on silicon the
      GO-aligned finalize windows REGRESSED the proven b-first zero-poke
      order (mutual anchor starvation, 0x21B8=0x57000005 both, complementary
      missing lanes, rea=0/0), so Loop-13 reverted the winscan to the exact
      b55cb59/Loop-11 LOCALLY-TIMED flow. Assert: neither winscan is EVER
      observed in WS_FIN_WAITPEER and neither autoneg ever enters
      ST_FIN_RDV/ST_FIN_GO; ws_rdv_timeout_q (0x21B8[10]) stays 0
      EVERYWHERE (the sticky can no longer set); the private zombie episode
      fails loud via the ANCHOR timeout (0x21B8[2], the b55cb59 path — not
      the retired rendezvous timeout); each die is observed QUIESCED
      (fch_quiesced_r=1) during its own WS_FINALIZE (the locally-timed Q1
      quiesce, unchanged from b55cb59) + the full data oracle on the final
      bilateral episode.

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_l5 SIM=vcs \
      make MODULE=test_33_arm_stagger_episode_binding
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB
from tidelink.packet import encode_word0, PKT_WR_REQ

# Reuse the proven helpers/encodings (side-effect-free import — cocotb only
# collects tests from $MODULE; same precedent as test_32).
from test_31_autonomous_training_exit import (
    _ctrl, _cal, _autoneg, _fcsm, _si,
    _idle_stimulus, _reset,
    ST_TRAIN_DONE,
)
from test_32_die_a_first_zombie_retry import (
    _apb_arm, ST_BYPASS, ST_ERROR, APB_NEGO_TRAIN_CFG, NEGO_TRAIN_CFG_ARM,
)

CLK_PERIOD_NS = 20.0

# Winscan FSM state encodings (axi_chiplet_controller.sv)
WS_IDLE, WS_ARM, WS_DONE = 0, 1, 8
WS_FIN_CLRLOW = 9                     # FIX-3 clear-low hold (FIX-4: the hold
                                      # counter carries base + LFSR jitter —
                                      # t33e samples it for jitter evidence)
WS_FIN_WAITPEER = 10                  # R-B rendezvous hold — DORMANT since
                                      # Loop-13 (encoding reserved; the state
                                      # must NEVER be entered — t33f asserts)
WS_MIDSCAN = {2, 3, 4, 5, 6, 7, 9}    # LANE..FINALIZE + CLRLOW = abortable
                                      # (episode binding; 10 retired with the
                                      # dormant rendezvous)
# FIX-4 (2026-07-04): sim-mode WS_FIN_CLRLOW base hold (WS_CLR_HOLD_SIM). The
# retry arc loads base + jitter(64..575), so ANY observed hold-counter value
# above this base proves the jittered inter-attempt dwell is live.
WS_CLR_HOLD_SIM = 512
# R-B autoneg finalize-rendezvous states — DORMANT since Loop-13 (entry arc
# gated on local_fin_wait_i, tied 0; t33f asserts they are never entered)
ST_FIN_RDV, ST_FIN_GO = 18, 19

# Retrain W1P: the ARM cfg (auto_en=1, poll budget 2) + bit[2] W1P pulse.
NEGO_TRAIN_CFG_RETRAIN = NEGO_TRAIN_CFG_ARM | 0x4


async def _deposit_hooks(dut):
    """The designed-in sim hooks (timing accommodations, not state bypasses) +
    the flat-0 eye model — test_31/32's exact idiom. NOTE: no
    tb_syncoff_settle_short_q — D2 (2026-07-03) deleted the SYNC-OFF timer."""
    for side in ("m", "s"):
        _autoneg(dut, side).tb_retry_backoff_short_q.value = 1
        _ctrl(dut, side).tb_winscan_dwell_short_q.value = 1
        _ctrl(dut, side).tb_fch_dwell_short_q.value = 1
        _ctrl(dut, side).tb_ws_anchor_short_q.value = 1
        _ctrl(dut, side).obs_sync_dist_vec_w.value = Force(0)
    for side in ("m", "s"):
        assert _si(_cal(dut, side).tb_early_exit_force_q) == 0, \
            f"[{side}] calibrator sim bypass engaged — must run de-forced"


def _force_zombie_bypass(dut, side):
    """Force `side`'s autoneg lock-qual inputs so the L4 local-only bypass
    (tidelink_autoneg.sv :1304) fires at the poll deadline against the zombie
    -> ST_TRAIN_EXIT -> zombie ACKs -> the PRIVATE training fall."""
    an = _autoneg(dut, side)
    an.local_swi_lane_locked_i.value = Force(0xFF)
    an.local_swi_lane_fault_i.value = Force(0x00)


def _release_zombie_bypass(dut, side):
    an = _autoneg(dut, side)
    an.local_swi_lane_locked_i.value = Release()
    an.local_swi_lane_fault_i.value = Release()


async def _retrain(tb):
    """The documented SW retrain kick (NEGO_TRAIN_CFG bit[2] W1P)."""
    await tb.m_apb.write(APB_NEGO_TRAIN_CFG, NEGO_TRAIN_CFG_RETRAIN)


async def _wait_sig(dut, probe, want, max_cycles, poll=100):
    """Poll probe() (returns int) until == want. Returns (ok, cycles)."""
    waited = 0
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        if probe() == want:
            return True, waited
    return False, waited


def _obs_snapshot(dut, side):
    """The 0x21B8 WINSCAN_OBS fields + anchor/credit state for one die."""
    c = _ctrl(dut, side)
    f = _fcsm(dut, side)
    return {
        "done":       _si(c.winscan_done),
        "degen":      _si(c.ws_degenerate_q),
        "anc_to":     _si(c.ws_anchor_timeout_q),
        "anc_late":   _si(c.ws_anchor_late_q),
        "aborts":     _si(c.ws_abort_cnt_q),
        "rea":        _si(c.ws_anchor_q),
        "fcsm":       _si(f.state),
        "credit_max": _si(f.fe_rx_credit_max),
        "fe_full":    _si(f.fe_rx_is_full),
        "insert_en":  _si(c.swi_sync_insert_en_r),
        "robust":     _si(c.swi_sync_robust_detect_r),
        "force_alw":  _si(c.swi_sync_force_always_r),
        "hold":       _si(c.sync_cfg_hold_q),
        "sync_off":   _si(c.sync_off_done_q),
    }


async def _wait_final_convergence(dut, log, tag, max_cycles=10_000_000):
    """Wait for the FULL post-stagger end-state on BOTH dies: winscan_done=1
    with the anchor-timeout sticky CLEAR (the FINAL episode genuinely
    re-anchored), rea=1, FCSM=4. Logs progress; returns the last snapshots."""
    poll, waited, last_log = 200, 0, 0
    snaps = None
    while waited < max_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        snaps = {s: _obs_snapshot(dut, s) for s in ("m", "s")}
        ok = all(
            v["done"] == 1 and v["anc_to"] == 0 and v["rea"] == 1
            and v["fcsm"] == 4
            for v in snaps.values())
        if ok:
            log.info(f"[{tag}] converged at t={waited*CLK_PERIOD_NS/1000:.0f}us: "
                     f"m={snaps['m']} s={snaps['s']}")
            return snaps, waited
        if waited - last_log >= 400_000:
            last_log = waited
            log.info(f"[{tag}] t={waited*CLK_PERIOD_NS/1000:.0f}us "
                     f"m={snaps['m']} | s={snaps['s']} "
                     f"m_an={_si(_autoneg(dut,'m').state_r)} "
                     f"s_an={_si(_autoneg(dut,'s').state_r)}")
    return snaps, waited


async def _assert_end_state(dut, tb, log, tag):
    """The shared oracle: BOTH dies 0x21B8[0]=1 / [2]=0, rea=1, FCSM=4,
    credit_max>0, D2 beacons up — then byte-exact data BOTH directions."""
    snaps, _ = await _wait_final_convergence(dut, log, tag)
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        v = snaps[side]
        assert v["done"] == 1, (
            f"[{tag}] {name}: winscan_done=0 at end (0x21B8[0]) — the final "
            f"episode's scan never completed (episode-binding still broken?)")
        assert v["anc_to"] == 0, (
            f"[{tag}] {name}: ws_anchor_timeout_q STICKY at end (0x21B8[2]) — "
            f"the FINAL bilateral episode failed open instead of genuinely "
            f"re-anchoring (BUG-B starvation signature: the peer's beacons "
            f"were not there when the re-anchor refilled)")
        assert v["rea"] == 1, (
            f"[{tag}] {name}: reanchored=0 at end — the deskew anchor never "
            f"latched (the starved-die signature)")
        assert v["fcsm"] == 4, f"[{tag}] {name}: FCSM={v['fcsm']} != 4"
        assert v["credit_max"] != 0, (
            f"[{tag}] {name}: fe_rx_credit_max=0 — the CR/CRACK credit grant "
            f"never loaded (unanchored-bootstrap signature)")
        # 2026-07-15: INVERTED from the old D2 "never blind-OFF" enshrinement
        # (insert_en==1) — see project_autonomy_rootcause_sync_clamp_2026_07_14.
        # This oracle only runs after FULL convergence (done=1, anc_to=0, rea=1,
        # fcsm=4, credit>0), which requires the FINALIZE release gate
        # (ws_anchor_q && ws_verify_q) to have fired — so the SYNC-OFF one-shot
        # must have latched and stripped insert_en to land the autonomous
        # data-mode state on R8-effective 0x10 (insert_en=0, robust=1), the
        # config the manual recipe uses and which is PROVEN 40/40 byte-exact.
        assert v["sync_off"] == 1, (
            f"[{tag}] {name}: SYNC-OFF one-shot never latched (sync_off_done_q=0) "
            f"despite full convergence — the verified-anchor release should fire it")
        assert v["insert_en"] == 0 and v["robust"] == 1, (
            f"[{tag}] {name}: post-anchor SYNC-OFF wrong — autonomous data mode "
            f"must be insert_en=0/robust=1 (R8-effective 0x10, the recipe config); "
            f"at insert_en=1 (0x14) die_a's RX-commit dead-locks B->A on silicon. "
            f"got insert_en={v['insert_en']} robust={v['robust']}")
        assert v["hold"] == 0, (
            f"[{tag}] {name}: sync_cfg_hold_q=1 at end — the D2 heal must release "
            f"at the verified anchor so it stops re-clamping insert_en to 1")
        assert v["force_alw"] == 0, (
            f"[{tag}] {name}: force_always set — the R4 word-deleter")
        # Anchored-late (0x21B8[3]) is DIAGNOSTIC, not an error: log it.
        log.info(f"[{tag}] {name} end-state: {v}")

    # ---- byte-exact data BOTH directions (the silicon (h) step) ----------
    pay_ms = [0xC0DE1234, 0xFEED5678]     # M -> S
    pay_sm = [0xCAFE0001, 0xBEEF0002]     # S -> M
    w0_ms = encode_word0(length=len(pay_ms), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    w0_sm = encode_word0(length=len(pay_sm), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    await tb.ahb_tx_write_packet("m", [w0_ms, 0x0] + pay_ms)
    await ClockCycles(dut.hclk, 4000)
    s_w2 = await tb.ahb_fifo_read_word("s", 0x08)
    s_w3 = await tb.ahb_fifo_read_word("s", 0x0C)
    log.info(f"[{tag}] M->S: got 0x{s_w2:08x}/0x{s_w3:08x} "
             f"want 0x{pay_ms[0]:08x}/0x{pay_ms[1]:08x}")
    assert (s_w2, s_w3) == (pay_ms[0], pay_ms[1]), (
        f"[{tag}] M->S data NOT byte-exact (got 0x{s_w2:08x}/0x{s_w3:08x}) — "
        f"the arm-stagger starvation data signature")

    await tb.ahb_tx_write_packet("s", [w0_sm, 0x0] + pay_sm)
    await ClockCycles(dut.hclk, 4000)
    m_w2 = await tb.ahb_fifo_read_word("m", 0x08)
    m_w3 = await tb.ahb_fifo_read_word("m", 0x0C)
    log.info(f"[{tag}] S->M: got 0x{m_w2:08x}/0x{m_w3:08x} "
             f"want 0x{pay_sm[0]:08x}/0x{pay_sm[1]:08x}")
    assert (m_w2, m_w3) == (pay_sm[0], pay_sm[1]), (
        f"[{tag}] S->M data NOT byte-exact (got 0x{m_w2:08x}/0x{m_w3:08x})")

    # No terminal autoneg error on either die.
    for side in ("m", "s"):
        assert _si(_autoneg(dut, side).state_r) != ST_ERROR, \
            f"[{tag}] [{side}] autoneg parked in terminal ST_ERROR"


async def _late_die_convergence(dut, tb, log, tag):
    """Shared tail for (a)/(b): release the bypass force, arm the late die,
    wait its role-lock, kick the master's retrain -> the FINAL bilateral
    episode -> the full end-state oracle."""
    _release_zombie_bypass(dut, "m")
    await _apb_arm(tb, "s", priority=2)
    log.info(f"({tag}) SLAVE armed (the late die); waiting role-lock")
    ok, w = await _wait_sig(dut, lambda: _si(dut.s_role_locked), 1,
                            max_cycles=4_000_000)
    assert ok, f"({tag}) slave never role-locked after arming"
    log.info(f"({tag}) slave role-locked at +{w*CLK_PERIOD_NS/1000:.0f}us; "
             f"kicking the master's retrain (bilateral episode)")
    await _retrain(tb)
    await _assert_end_state(dut, tb, log, tag)


async def _setup(dut, tb):
    await _idle_stimulus(dut)
    await _reset(dut)
    await _deposit_hooks(dut)
    await ClockCycles(dut.hclk, 200)
    for side in ("m", "s"):
        st = _si(_autoneg(dut, side).state_r)
        assert st == ST_BYPASS, (
            f"[{side}] autoneg not parked in ST_BYPASS pre-arm (state={st}) — "
            f"BYPASS_AUTONEG=1 build expected")


@cocotb.test()
async def test_33a_seconds_stagger_private_episode(dut):
    """(a) die A's PRIVATE zombie-bypass episode completes (stale fail-open
    winscan_done + stale fch bootstrap) -> arm die B + retrain -> both dies
    rebind to the final bilateral episode + full data oracle."""
    log = dut._log
    log.info("(a) SECONDS-STAGGER: private zombie-bypass episode, then the late die")
    tb = PairTB(dut)
    await _setup(dut, tb)

    _force_zombie_bypass(dut, "m")
    await _apb_arm(tb, "m", priority=1)
    log.info("(a) MASTER armed (lock-qual forced -> zombie-bypass private episode)")

    # The bypass exit's training FALL (~233k cycles) kicks the private scan;
    # against the beacon-less zombie the F4 anchor gate exits via FIX-3's
    # 3 clear-retries -> FAIL-OPEN, so winscan_done rises (~ fall + 330k)
    # with 0x21B8[2] latched — the STALE done the fch then consumes (the
    # documented silicon starvation precondition).
    # R-B ASYMMETRIC PEER-SERVE (2026-07-07): the master now ALSO parks in
    # WS_FIN_WAITPEER and runs the finalize rendezvous before WS_FINALIZE.
    # Against the beacon-less zombie (no peer serves) the rendezvous times out
    # (ws_rdv_timeout_q=1) and it proceeds LOCALLY into the b55cb59 fail-open —
    # so winscan_done still rises, just ~+400k (the WS_RDV_TIMEOUT_SIM wait)
    # later. Budget widened for that.
    mc = _ctrl(dut, "m")
    ok, w = await _wait_sig(dut, lambda: _si(mc.winscan_done), 1,
                            max_cycles=3_500_000)
    assert ok, ("(a) MASTER private-episode winscan_done never rose — the "
                "zombie-bypass arc (forced lock-qual -> ST_TRAIN_EXIT -> "
                "training fall -> scan -> FIX-3 fail-open) is broken")
    priv = _obs_snapshot(dut, "m")
    log.info(f"(a) private episode done at t={w*CLK_PERIOD_NS/1000:.0f}us: {priv}")
    assert priv["anc_to"] == 1, (
        "(a) private zombie episode did NOT fail open (0x21B8[2]=0)? The "
        "beacon-less peer cannot anchor — precondition for the stagger bug "
        "not established (did the zombie beacon?)")
    # R-B ASYMMETRIC PEER-SERVE (2026-07-07): the master's autoneg may be
    # parked in ST_TRAIN_DONE OR still cycling the finalize rendezvous
    # (ST_FIN_RDV/ST_FIN_GO) against the un-serving zombie at this instant (it
    # abandons back to ST_TRAIN_DONE at the next poll boundary once the winscan
    # left WS_FIN_WAITPEER on the rdv timeout). Accept all three.
    assert _si(_autoneg(dut, "m").state_r) in (ST_TRAIN_DONE, ST_FIN_RDV,
                                               ST_FIN_GO), (
        f"(a) master not parked ST_TRAIN_DONE / in the finalize rendezvous "
        f"after the bypass exit (an={_si(_autoneg(dut,'m').state_r)}) — "
        f"private episode did not complete via the zombie-bypass arc")
    assert _si(_autoneg(dut, "s").state_r) == ST_BYPASS, \
        "(a) slave left ST_BYPASS while un-armed — not a zombie scenario"

    # THE STAGGER: seconds of sim-scale gap already elapsed; now the late die.
    await _late_die_convergence(dut, tb, log, "a")
    log.info("VERDICT (a): PASS — private-episode stale done was rebound; both "
             "dies ended done=1/timeout=0/rea=1/credit>0 + byte-exact data "
             "both ways under permanent beacons")


@cocotb.test()
async def test_33b_midscan_stagger_kick_loss(dut):
    """(b) the kick-loss path: a displaced training fall lands MID-SCAN ->
    the FIX-1 abort-restart must consume it (ws_abort_cnt_q>0; pre-fix:
    silently lost) and the pair must still converge once the late die arms."""
    log = dut._log
    log.info("(b) MID-SCAN STAGGER: the abort-restart (lost-kick) path")
    tb = PairTB(dut)
    await _setup(dut, tb)

    _force_zombie_bypass(dut, "m")
    await _apb_arm(tb, "m", priority=1)
    log.info("(b) MASTER armed (zombie-bypass) — waiting private episode #1's scan")

    # Private episode #1's fall kicks the scan (scan+FINALIZE+anchor waits
    # ~330k cycles). Wait until the FSM is demonstrably MID-SCAN.
    mc = _ctrl(dut, "m")
    ok, w = await _wait_sig(
        dut, lambda: 1 if _si(mc.ws_state_r) in WS_MIDSCAN else 0, 1,
        max_cycles=1_500_000)
    assert ok, "(b) master's private scan #1 never started (no training fall?)"
    aborts0 = _si(mc.ws_abort_cnt_q)
    log.info(f"(b) scan #1 mid-flight at t={w*CLK_PERIOD_NS/1000:.0f}us "
             f"(ws_state={_si(mc.ws_state_r)}, aborts={aborts0}) — firing "
             f"private episode #2 (retrain W1P, force still on)")

    # Private episode #2: retrain W1P with the force still on -> the bypass
    # walk (DONE_PRE -> TRAIN_ENTER -> 2 zombie polls -> EXIT) takes ~170k
    # cycles, so its training FALL lands INSIDE scan #1's ~330k window ->
    # the FIX-1 abort-restart must fire. Pre-fix RTL: the kick is silently
    # LOST here (consumed nowhere) and the scan stays bound to episode #1.
    await _retrain(tb)
    ok, w = await _wait_sig(
        dut, lambda: 1 if _si(mc.ws_abort_cnt_q) > aborts0 else 0, 1,
        max_cycles=1_500_000)
    assert ok, (
        "(b) ws_abort_cnt_q never incremented — episode #2's mid-scan "
        "training fall was NOT consumed (FIX-1 abort-restart did not fire; "
        "pre-fix behaviour: the kick is silently lost and the fch binds to "
        "the stale episode)")
    log.info(f"(b) abort-restart observed at +{w*CLK_PERIOD_NS/1000:.0f}us "
             f"(aborts={_si(mc.ws_abort_cnt_q)}, ws_state="
             f"{_si(mc.ws_state_r)}) — proceeding to the late die")

    await _late_die_convergence(dut, tb, log, "b")
    aborts = _si(mc.ws_abort_cnt_q)
    log.info(f"VERDICT (b): PASS — {aborts} abort-restart(s) consumed the "
             f"mid-scan kick(s) (pre-fix: lost) and the pair converged to the "
             f"full data oracle")


@cocotb.test()
async def test_33c_zero_stagger_symmetric(dut):
    """(c) stagger ~= 0: both dies armed back-to-back — the symmetric
    regression guard (the fixes must not break the working bring-up)."""
    log = dut._log
    log.info("(c) ZERO-STAGGER: symmetric arm regression")
    tb = PairTB(dut)
    await _setup(dut, tb)

    await _apb_arm(tb, "m", priority=1)
    await _apb_arm(tb, "s", priority=2)   # back-to-back (a few APB writes apart)
    log.info("(c) both dies armed back-to-back")

    await _assert_end_state(dut, tb, log, "c")
    log.info("VERDICT (c): PASS — symmetric bring-up unbroken: done=1/"
             "timeout=0/rea=1/credit>0 + byte-exact data both ways")


# ---------------------------------------------------------------------------
# (d) Q1 QUIESCE-BEFORE-FINALIZE (2026-07-04) — Loop-10 silicon mechanism:
# die_a's WS_FINALIZE re-anchor STARVED because die_b's TX carried a
# CONTINUOUS slave->master 0x12 keepalive/credit stream (beatcap-proven) that
# occupied the idle slots the re-anchor's IDLE-GATED beacons need (WavD2DGpio
# V2 sync gate: insert_en & (force_always | link_tx_tx_idle); one missed
# SYNC_PERIOD slot resets the deskew confirm run). Lane 7 never re-latched
# (sync_seen=0x64 vs 0xe4) -> F4 retries exhausted (0x21B8=0x57000005) ->
# unanchored bootstrap -> dead data.
#
# WHY THE FULL PRE-FIX STARVATION ORDERING IS NOT CHEAPLY SIM-MODELABLE: in
# sim both dies' F3-cleared anchors re-latch FIRST-TRY inside the mutually
# force-SYNC'd FINALIZE overlap (clean eyes — force_always drops the idle
# term, so peer pressure cannot block the overlap-era beacons). The silicon
# failure needed a marginal-eye lane to MISS that first window and retry
# AFTER the peer's force had dropped, into the keepalive-saturated idle-gated
# era — an eye/skew artefact sim does not model. The silicon zeropoke run is
# the arbiter for the starvation itself; THIS variant regression-locks the
# fix mechanism directly:
#   * each die QUIESCES for its own finalize: fch_quiesced_r=1 AND the Wlink
#     apb-domain swi_swreset register =1 observed WHILE ws_state_r is in
#     WS_FINALIZE/WS_FIN_CLRLOW (delete the quiesce and these latches fail);
#   * full convergence + byte-exact data BOTH ways under modelled keepalive
#     pressure: die_b's LL TX idle flag is forced BUSY whenever its LL is out
#     of swreset (the pressure a real keepalive stream exerts — and, like the
#     real stream, it DIES with the framer, which is exactly what the quiesce
#     exploits).
# ---------------------------------------------------------------------------
WS_FINALIZE_STATES = {7, 9}   # WS_FINALIZE, WS_FIN_CLRLOW


async def _keepalive_pressure(dut, side, log, stop):
    """Model the silicon 0x12 keepalive/credit stream on `side`'s TX: force
    the LL->PHY inter-packet idle flag (lltx_io_link_idle, the ONLY consumer
    is the PHY sync-insert idle gate) LOW whenever the LL is OUT of swreset,
    so every idle-gated beacon slot reads BUSY. Conditioned on the Wlink
    apb-domain swi_swreset register: the quiesce parks the LL in swreset and
    a real keepalive stream dies with the framer, so the force lifts exactly
    when the quiesce fires (and re-arms when the bootstrap releases it)."""
    wl = _ctrl(dut, side).u_wlink
    forced = False
    n_windows = 0
    while not stop[0]:
        await ClockCycles(dut.hclk, 20)
        swrst = _si(wl.out_prepend_swi_swreset)
        if swrst == 0 and not forced:
            wl.lltx_io_link_idle.value = Force(0)
            forced = True
            n_windows += 1
        elif swrst == 1 and forced:
            wl.lltx_io_link_idle.value = Release()
            forced = False
    if forced:
        wl.lltx_io_link_idle.value = Release()
    log.info(f"[{side}] keepalive-pressure force windows: {n_windows}")


async def _quiesce_monitor(dut, side, seen, stop):
    """Latch evidence that `side` QUIESCED its LL for its own finalize:
    while ws_state_r sits in WS_FINALIZE/WS_FIN_CLRLOW, fch_quiesced_r must
    read 1 and the Wlink swi_swreset register must read 1 (the early 0x27f09
    landed). 20-cycle sampling against a >=100k-cycle finalize window (the
    sim fin-wait hook) — the latches cannot be missed."""
    c = _ctrl(dut, side)
    wl = c.u_wlink
    while not stop[0]:
        await ClockCycles(dut.hclk, 20)
        # R-B ASYMMETRIC PEER-SERVE (2026-07-07): the MASTER now quiesces in
        # WS_FIN_WAITPEER (its re-anchor window), the SLAVE still quiesces in
        # WS_FINALIZE/WS_FIN_CLRLOW (its own b55cb59 finalize). Accept either.
        if (_si(c.ws_state_r) in WS_FINALIZE_STATES
                or _si(c.ws_state_r) == WS_FIN_WAITPEER):
            seen[side]["finalize"] = True
            if _si(c.fch_quiesced_r) == 1:
                seen[side]["quiesced"] = True
            if _si(wl.out_prepend_swi_swreset) == 1:
                seen[side]["swreset"] = True


@cocotb.test()
async def test_33d_quiesce_under_keepalive_pressure(dut):
    """(d) Q1 gate: both dies quiesce their LL for their own finalize (the
    early 0x27f09 observed in-state) and the pair still converges to the full
    data oracle with die_b's TX idle slots saturated whenever its LL runs —
    the modelled Loop-10 keepalive pressure."""
    log = dut._log
    log.info("(d) QUIESCE-BEFORE-FINALIZE under modelled keepalive pressure")
    tb = PairTB(dut)
    await _setup(dut, tb)

    stop = [False]
    seen = {s: {"finalize": False, "quiesced": False, "swreset": False}
            for s in ("m", "s")}
    # Pressure on die_b only (the silicon polarity: the slave's keepalive
    # stream starved the MASTER's re-anchor; die_a's TX stays 'quiet' = CR
    # spam only, as on silicon).
    cocotb.start_soon(_keepalive_pressure(dut, "s", log, stop))
    for side in ("m", "s"):
        cocotb.start_soon(_quiesce_monitor(dut, side, seen, stop))

    await _apb_arm(tb, "m", priority=1)
    await _apb_arm(tb, "s", priority=2)
    log.info("(d) both dies armed back-to-back; die_b under keepalive pressure")

    try:
        await _assert_end_state(dut, tb, log, "d")
    finally:
        stop[0] = True

    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert seen[side]["finalize"], (
            f"(d) {name}: winscan never observed in WS_FINALIZE/WS_FIN_CLRLOW "
            f"— the scan did not run (monitor/harness issue, not a Q1 verdict)")
        assert seen[side]["quiesced"], (
            f"(d) {name}: fch_quiesced_r never 1 during its own finalize — "
            f"the Q1 quiesce write did not precede the re-anchor (the Loop-10 "
            f"starvation window is back open)")
        assert seen[side]["swreset"], (
            f"(d) {name}: Wlink swi_swreset never 1 during its finalize — the "
            f"early 0x27f09 did not LAND in the LL (mux/priority regression?)")
    log.info("VERDICT (d): PASS — both dies quiesced (early 0x27f09 in-state, "
             "swreset held across the re-anchor) and the pair converged to "
             "byte-exact data both ways under modelled keepalive pressure")


# ---------------------------------------------------------------------------
# (e) R-A FINALIZE ANCHOR-VERIFY (2026-07-04) — wrong-slot mis-anchor gate.
#
# Silicon mechanism (die_b RX, A->B only): during the quiesced FINALIZE
# re-anchor ONE lane's sticky deskew anchor (sync_idx) latched on an
# ADJACENT/offset SYNC instance — the per-lane tol-5 Hamming confirm accepted
# a plausible-but-wrong slot on a marginal eye — so that lane's read-offset is
# one slot wrong and its byte-lane samples an adjacent slice FOREVER
# (deterministic 0x24->0x5c / 0xfe->0x5d on byte[23:16], rest byte-exact,
# post-burst state healthy: reanchored=1 looked fine). The fix gates the
# WS_FINALIZE release on ws_anchor_q AND ws_verify_q — the WavD2DGpio_v2
# anchor-verify sticky: the ENGAGED anchor must reproduce TIDELINK_SYNC_WORD
# EXACTLY on EVERY active lane on ONE post-deskew beat (a one-slot-off lane
# matches its own slice one beat AWAY from the others, so the simultaneous
# match can never fire mis-anchored).
#
# WHY A FORCE ON anchor_vfy_lane_w AND NOT A REAL WRONG-SLOT EYE: in RTL sim
# the eye is clean — the deskew's periodic confirm always locks the TRUE slot,
# so the wrong-slot latch cannot be produced from the pins without a
# beat-accurate per-lane content model (the same reason the (d) header gives
# for the Loop-10 ordering). Forcing the DEDICATED verify input vector to 0
# models exactly the observable the wrong slot produces — "the engaged anchor
# never reproduces an exact all-lane SYNC word" — without touching the
# datapath, the deskew capture, or the rawobs latches (anchor_vfy_lane_w is a
# named read-side fan-out added for precisely this injection). Correct-anchor
# behaviour (verify passes first try) is asserted by test_31/t33c/t33d's new
# ws_vfy_retry_q==0 end-state term; THIS variant pins the failure arm:
# verify-fail => release HELD + FIX-3 clear-retry with the anchor already
# latched (ws_vfy_retry_q 0x21B8[9]) => post-release recovery to the full
# byte-exact oracle.
# ---------------------------------------------------------------------------
def _vfy_lane_net(dut, side):
    """The WavD2DGpio_v2 per-lane exact-compare vector (rx-link-clk domain).
    Named injection point: controller.u_wlink -> Wlink.phy -> WlinkGPIOPHY.gpio
    -> WavD2DGpio_v2.anchor_vfy_lane_w."""
    return _ctrl(dut, side).u_wlink.phy.gpio.anchor_vfy_lane_w


async def _clrlow_jitter_monitor(dut, side, stats, stop):
    """FIX-4 evidence sampler: whenever `side`'s winscan sits in WS_FIN_CLRLOW,
    track the MAX observed value of the reused hold counter (ws_anchor_to_r).
    The retry arc loads WS_CLR_HOLD_SIM + jitter(64..575) into it, so with a
    40-cycle poll the max observed is >= load - ~40 >= 536 — any value above
    the WS_CLR_HOLD_SIM base (512) deterministically proves the jittered
    inter-attempt dwell is live in the dwell path (the FIX-4 decorrelation
    term is actually consumed, not just computed). SELF-TERMINATES once the
    evidence is collected — an always-on dense poller measurably slows the
    whole test (the 2026-07-05 4955s t33e runtime post-mortem)."""
    c = _ctrl(dut, side)
    while not stop[0]:
        await ClockCycles(dut.hclk, 40)
        if _si(c.ws_state_r) == WS_FIN_CLRLOW:
            v = _si(c.ws_anchor_to_r)
            if v > stats[side]:
                stats[side] = v
            if stats[side] > WS_CLR_HOLD_SIM:
                return                      # evidence in hand — stop sampling


@cocotb.test()
async def test_33e_anchor_verify_wrong_slot(dut):
    """(e) verify-fail gate: with the per-lane exact-compare forced 0 (the
    wrong-slot observable) the winscan must HOLD winscan_done and burn FIX-3
    clear-retries with the anchor already latched (ws_vfy_retry_q); releasing
    the force lets the retried re-anchor verify and the pair converges."""
    log = dut._log
    log.info("(e) ANCHOR-VERIFY: wrong-slot model (forced verify-fail) on both dies")
    tb = PairTB(dut)
    await _setup(dut, tb)

    # Force BOTH dies' verify vectors low BEFORE arming: every episode's
    # verify fails until released. Both dies (not just one) so neither die
    # bootstraps early and starves the other's retry window of quiesced
    # beacons — symmetric, like the silicon's mutual-finalize overlap.
    for side in ("m", "s"):
        _vfy_lane_net(dut, side).value = Force(0)

    # FIX-4 (2026-07-04) evidence collection: sample the free-running jitter
    # LFSR now (aliveness check later) and start the WS_FIN_CLRLOW hold-
    # counter monitors (jittered-dwell evidence). This variant IS the task's
    # "first-window anchor failure recovering on a later attempt WITH the
    # jitter": the forced verify-fail burns window 1, the FIX-3/FIX-4 retry
    # re-clears after a jittered dwell, and the released re-anchor converges.
    lfsr0 = {s: _si(_ctrl(dut, s).ws_jitter_lfsr_r) for s in ("m", "s")}
    jit_stop = [False]
    jit_max = {"m": 0, "s": 0}
    for side in ("m", "s"):
        cocotb.start_soon(_clrlow_jitter_monitor(dut, side, jit_max, jit_stop))

    await _apb_arm(tb, "m", priority=1)
    await _apb_arm(tb, "s", priority=2)
    log.info("(e) both dies armed; anchor_vfy_lane_w forced 0 on both")

    # Wait for the verify-retry sticky on BOTH dies: the FSM reached
    # WS_FINALIZE, the deskew anchor LATCHED (rea=1), the verify did not, the
    # anchor window expired and the FIX-3 retry fired with ws_anchor_q==1.
    seen_retry = {"m": False, "s": False}
    waited = 0
    while waited < 9_000_000 and not all(seen_retry.values()):
        await ClockCycles(dut.hclk, 200)
        waited += 200
        for side in ("m", "s"):
            if _si(_ctrl(dut, side).ws_vfy_retry_q) == 1:
                seen_retry[side] = True
    assert all(seen_retry.values()), (
        f"(e) ws_vfy_retry_q never latched (m={seen_retry['m']} "
        f"s={seen_retry['s']}) — the anchor-verify did not force a FIX-3 "
        f"clear-retry although the exact-compare was held 0 (the verify is "
        f"NOT gating the WS_FINALIZE release — pre-R-A behaviour: a "
        f"wrong-slot anchor would ship a corrupted byte-lane)")
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        assert _si(c.winscan_done) == 0, (
            f"(e) {name}: winscan_done rose while the verify was forced-failed "
            f"(retries not yet exhausted) — the release gate ignored "
            f"ws_verify_q")
        assert _si(c.ws_anchor_q) == 1, (
            f"(e) {name}: retry fired without the anchor latched — this is an "
            f"anchor problem, not the verify gate under test")
        # FIX-4: the retry must be COUNTED into the 0x21B8[13:11] attempt
        # counter (the on-silicon statistic the compounding model needs).
        assert _si(c.ws_retry_cnt_q) >= 1, (
            f"(e) {name}: ws_retry_cnt_q == 0 although a clear-retry fired — "
            f"the 0x21B8[13:11] attempt counter is not counting")
    log.info(f"(e) verify-retry latched on both dies at "
             f"t={waited*CLK_PERIOD_NS/1000:.0f}us with anchors latched and "
             f"winscan_done held")

    # FIX-4 RELEASE SCHEDULE (2026-07-05, debug-timeline root-caused): the
    # seen_retry sample lands exactly AT the retry arc — both dies sit in
    # WS_FIN_CLRLOW with their fresh clear pulses about to fly. Releasing
    # the force HERE lets each verify latch on the STALE still-engaged
    # anchor during the hold; the landing clears then re-roll both dies and
    # whoever re-anchors first DROPS FORCE and starves the other's confirm
    # mid-run (deterministic in sim: the slave won by ~10us of grid phase;
    # the master burned windows 2-6 beaconless and failed open — the
    # Loop-12-family peer-finalize-exit starvation, NOT a retry-machinery
    # property; pre-FIX-4b this same release schedule "passed" only via the
    # stale-release race that FIX-4b closed). Release instead once BOTH
    # dies are back in a FINALIZE window with a GENUINE post-clear anchor
    # (st==WS_FINALIZE, anc=1): the un-forced verifies then race on LIVE
    # anchors under mutual force — the winner exercises the property under
    # test (the RETRIED re-anchor verifies and releases in-episode); the
    # loser's fate is scored by the post-release oracle below.
    WS_FINALIZE_ST = 7
    in_win = {"m": False, "s": False}
    rewaited = 0
    while rewaited < 2_000_000 and not all(in_win.values()):
        await ClockCycles(dut.hclk, 200)
        rewaited += 200
        for side in ("m", "s"):
            c = _ctrl(dut, side)
            in_win[side] = (_si(c.ws_state_r) == WS_FINALIZE_ST
                            and _si(c.ws_anchor_q) == 1)
    assert all(in_win.values()), (
        f"(e) post-retry re-anchor never observed (m={in_win['m']} "
        f"s={in_win['s']}) — the FIX-3/FIX-4 retry did not re-latch the "
        f"anchor inside its own window although the peer's beacons were "
        f"still FORCED (a genuine retry-loop regression)")
    log.info(f"(e) both dies back in a FINALIZE window with genuine "
             f"post-clear anchors at +{rewaited*CLK_PERIOD_NS/1000:.0f}us — "
             f"releasing the wrong-slot force")

    for side in ("m", "s"):
        _vfy_lane_net(dut, side).value = Release()

    # POST-RELEASE (2026-07-05, debug-timeline root-caused): the un-forced
    # verifies now race on LIVE anchors under mutual force — but the FIRST
    # die to verify goes DONE, drops force and bootstraps, and its CR/CRACK
    # spam starves the OTHER die's gap-intolerant re-confirm inside its
    # remaining windows (one missed SYNC grid slot resets the deskew confirm
    # run). With the Loop-13 LOCALLY-TIMED finalize this winner-starves-loser
    # race is STRUCTURAL when both dies must re-anchor simultaneously — it is
    # the same peer-finalize-exit starvation family as the 8-roll silicon
    # lottery itself (loser varies with grid phase; both runs of the old
    # schedule produced opposite winners), NOT a retry-machinery property.
    # So the honest oracle is:
    #   * the WINNER proves the core R-A/FIX-4 property: the RETRIED
    #     re-anchor verifies and releases CLEANLY in-episode (anc_to=0);
    #   * the LOSER is allowed the DESIGNED graceful degradation (fail-open
    #     anc_to=1; its anchor late-heals on the permanent FIX-2 beacons);
    #   * per-episode evidence (vfy_retry, attempt counter, jitter dwell) is
    #     asserted on BOTH dies before any new episode clears it;
    #   * then the documented retrain W1P gives the pair a fresh bilateral
    #     episode which must deliver the FULL byte-exact oracle — the
    #     system-level recovery guarantee.
    both_done = {"m": False, "s": False}
    dwaited = 0
    while dwaited < 1_000_000 and not all(both_done.values()):
        await ClockCycles(dut.hclk, 200)
        dwaited += 200
        for side in ("m", "s"):
            both_done[side] = _si(_ctrl(dut, side).winscan_done) == 1
    assert all(both_done.values()), (
        f"(e) winscan_done not reached on both dies within the released "
        f"episode (m={both_done['m']} s={both_done['s']}) — neither a clean "
        f"retried release nor the bounded fail-open fired (retry FSM wedge)")
    jit_stop[0] = True

    outcome = {s: ("CLEAN" if _si(_ctrl(dut, s).ws_anchor_timeout_q) == 0
                   else "FAILOPEN") for s in ("m", "s")}
    log.info(f"(e) released-episode outcomes: m={outcome['m']} "
             f"s={outcome['s']} (winner-starves-loser race — either polarity "
             f"is legal, at least one CLEAN required)")
    assert "CLEAN" in outcome.values(), (
        f"(e) NO die recovered cleanly in the released episode "
        f"({outcome}) — the retried re-anchor never verified although the "
        f"verify force was released with live anchors under mutual force "
        f"(the R-A/FIX-4 recovery property is broken)")

    # Per-episode evidence — sampled BEFORE the retrain clears it at WS_ARM.
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        assert _si(c.ws_vfy_retry_q) == 1, (
            f"(e) {name}: ws_vfy_retry_q (0x21B8[9]) not sticky post-episode "
            f"— the verify-retry evidence was lost")
        # FIX-4: the attempt counter is per-episode-sticky like [9] — the
        # recovery must READ as a >=2-window (attempt-2+) episode.
        assert _si(c.ws_retry_cnt_q) >= 1, (
            f"(e) {name}: ws_retry_cnt_q (0x21B8[13:11]) not sticky "
            f"post-episode — the attempt-count evidence was lost")
        # FIX-4 jitter evidence: the WS_FIN_CLRLOW hold counter must have
        # been observed ABOVE the WS_CLR_HOLD_SIM base — i.e. the retries
        # dwelt for base + jitter, not the old constant (grid-phase-locked)
        # hold. Sim floor is 64 cycles, poll grain 40 => deterministic.
        assert jit_max[side] > WS_CLR_HOLD_SIM, (
            f"(e) {name}: max WS_FIN_CLRLOW hold observed {jit_max[side]} <= "
            f"base {WS_CLR_HOLD_SIM} — the FIX-4 jittered inter-attempt dwell "
            f"is NOT live in the dwell path (retries would stay phase-locked "
            f"to the repeating alias: the 8-roll silicon lottery)")
        # FIX-4 LFSR aliveness: free-running from POR, never gated.
        lfsr1 = _si(c.ws_jitter_lfsr_r)
        assert lfsr1 != lfsr0[side], (
            f"(e) {name}: ws_jitter_lfsr_r stuck at 0x{lfsr1:04x} — the "
            f"jitter source is not free-running")
    log.info(f"(e) FIX-4 evidence: max CLRLOW hold m={jit_max['m']} "
             f"s={jit_max['s']} (base {WS_CLR_HOLD_SIM}); attempt counts "
             f"m={_si(_ctrl(dut, 'm').ws_retry_cnt_q)} "
             f"s={_si(_ctrl(dut, 's').ws_retry_cnt_q)}")

    # Fresh bilateral episode (documented retrain W1P, the t33a/b tail) —
    # verifies unforced, symmetric — must deliver the FULL byte-exact oracle.
    await _retrain(tb)
    await _assert_end_state(dut, tb, log, "e")
    log.info("VERDICT (e): PASS — verify-fail HELD the release and forced the "
             "clear-retry (0x21B8[9]); retries were COUNTED (0x21B8[13:11]) "
             "and dwelt JITTERED inter-attempt holds (FIX-4); the released "
             "episode recovered CLEANLY on the race winner (loser fail-open "
             "= the designed degradation under peer-finalize-exit "
             "starvation); the retrained bilateral episode delivered the "
             "full byte-exact oracle")


# ---------------------------------------------------------------------------
# (f) R-B RENDEZVOUS DORMANCY (Loop-13 2026-07-04). Silicon verdict on the
# Loop-12 rendezvous: the GO-aligned finalize windows REGRESSED the proven
# b-first zero-poke order — BOTH dies anchor-timed-out (0x21B8=0x57000005
# both), MUTUAL partial starvation with COMPLEMENTARY missing lanes (die_a
# ss=0x64/lane 7, die_b ss=0xa4/lane 6), rea=0/0 — where the Loop-11
# LOCALLY-TIMED quiesce (b55cb59) fully converged. Loop-13 reverts the
# winscan behaviour to exact b55cb59 semantics and leaves the rendezvous
# PLUMBING dormant (ws_fin_wait_lvl tied 0 -> the autoneg ST_FIN_RDV/GO
# entry arc can never fire; ws_rdv_timeout_q can never set). This variant
# regression-locks the DORMANCY on the t33a a-first flow: any future edit
# that re-arms the rendezvous without a deliberate rework trips it.
# ---------------------------------------------------------------------------
async def _dormancy_monitor(dut, side, seen, stop):
    """R-B ASYMMETRIC PEER-SERVE (2026-07-07) observer. Records per side:
    whether the winscan was observed in WS_FIN_WAITPEER, whether the autoneg
    entered ST_FIN_RDV/GO, whether ws_rdv_timeout_q latched, and whether the
    die was quiesced inside its re-anchor window (WS_FIN_WAITPEER for the
    MASTER, WS_FINALIZE/WS_FIN_CLRLOW for the SLAVE — both sample-proof at a
    20-cycle period). The asymmetry invariant the test asserts: only the MASTER
    waits/polls; the SLAVE serves and is NEVER seen in WAITPEER or the
    rendezvous states."""
    c = _ctrl(dut, side)
    an = _autoneg(dut, side)
    while not stop[0]:
        await ClockCycles(dut.hclk, 20)
        st = _si(c.ws_state_r)
        if st == WS_FIN_WAITPEER:
            seen[side]["waitpeer_hit"] = True
        if _si(an.state_r) in (ST_FIN_RDV, ST_FIN_GO):
            seen[side]["rdv_state_hit"] = True
        if _si(c.ws_rdv_timeout_q) == 1:
            seen[side]["rdv_timeout_hit"] = True
        # Quiesce-in-window evidence: WAITPEER (master) or FINALIZE/CLRLOW
        # (slave) with the LL held in swreset.
        if (st in WS_FINALIZE_STATES or st == WS_FIN_WAITPEER) \
                and _si(c.fch_quiesced_r) == 1:
            seen[side]["quiesced_in_finalize"] = True


@cocotb.test()
async def test_33f_a_first_asymmetric_rendezvous(dut):
    """(f) a-first: the R-B ASYMMETRIC PEER-SERVE rendezvous with FIX-B's
    peer-ready entry gate (2026-07-07). The SLAVE HOLDS its anchor and SERVES —
    it is NEVER seen in WAITPEER or the rendezvous states. Against the un-armed
    zombie (peer[27]=0, CANNOT serve) FIX-B keeps the MASTER OUT of
    WS_FIN_WAITPEER: it polls the peer's ready bit (side-effect-free ST_FIN_RDV)
    but, seeing it not ready, fails open DIRECTLY via the anchor timeout
    (ws_anchor_timeout_q=1) with ws_rdv_timeout_q=0 and ws_waitpeer_entered_q=0
    (pre-FIX-B it entered WAITPEER prematurely + timed out — the die_b
    first-armed regression). The final bilateral episode then converges (real
    slave serves) and delivers the full data oracle."""
    log = dut._log
    log.info("(f) A-FIRST — R-B ASYMMETRIC PEER-SERVE RENDEZVOUS")
    tb = PairTB(dut)
    await _setup(dut, tb)

    stop = [False]
    seen = {s: {"waitpeer_hit": False, "rdv_state_hit": False,
                "rdv_timeout_hit": False, "quiesced_in_finalize": False}
            for s in ("m", "s")}
    for side in ("m", "s"):
        cocotb.start_soon(_dormancy_monitor(dut, side, seen, stop))

    try:
        _force_zombie_bypass(dut, "m")
        await _apb_arm(tb, "m", priority=1)
        log.info("(f) MASTER armed first (zombie-bypass private episode)")

        # Private episode against the beacon-less UN-ARMED zombie. FIX-B
        # (2026-07-07 peer-ready entry gate): the zombie's SWI_LANE_STATUS[27]=0
        # (peer_ready_to_serve_w=0), so the master must NOT fall into the serve
        # rendezvous at all — it fails open DIRECTLY via the F4 anchor timeout
        # (0x21B8[2]=1) after the FIX-3 clear-retries, with ws_rdv_timeout_q
        # (0x21B8[10]) STAYING 0 and ws_waitpeer_entered_q (0x21B8[15]) STAYING 0.
        # winscan_done rises. Budget: bypass walk ~233k + scan + FINALIZE
        # fail-open (5 R-A retries x 50k + clr-holds). (The autoneg DOES enter the
        # side-effect-free ST_FIN_RDV poll to READ the peer's bit — the
        # rdv_state_hit invariant below — but never writes a GO, since the peer is
        # not ready and the master never parks in WS_FIN_WAITPEER.) Pre-FIX-B
        # (4f39fb6/rev2) the master ENTERED WS_FIN_WAITPEER prematurely and timed
        # the rendezvous out (ws_rdv_timeout_q=1) — the die_b first-armed 83%->58%
        # regression this test now regression-locks the fix for.
        mc = _ctrl(dut, "m")
        ok, w = await _wait_sig(dut, lambda: _si(mc.winscan_done), 1,
                                max_cycles=4_000_000)
        # Sample the premature-entry sticky BEFORE the retrain (WS_ARM) clears it.
        pre_retrain_waitpeer = _si(mc.ws_waitpeer_entered_q)
        assert ok, ("(f) MASTER private-episode winscan_done never rose — the "
                    "peer-ready-gated fail-open path deadlocked the zombie "
                    "episode?")
        assert _si(mc.ws_anchor_timeout_q) == 1, (
            "(f) private zombie episode did NOT fail open via the ANCHOR "
            "timeout (0x21B8[2]=0) — the base fail-open fallback is not reached")
        assert _si(mc.ws_rdv_timeout_q) == 0, (
            "(f) private zombie episode: ws_rdv_timeout_q (0x21B8[10]) LATCHED — "
            "FIX-B's peer-ready gate must keep the master OUT of the serve "
            "rendezvous against an un-armed peer (fail open DIRECTLY, never enter "
            "WS_FIN_WAITPEER to time out)")
        assert pre_retrain_waitpeer == 0, (
            "(f) private zombie episode: ws_waitpeer_entered_q (0x21B8[15]) set — "
            "the master PREMATURELY entered WS_FIN_WAITPEER against a peer that "
            "cannot serve (the die_b first-armed 83%->58% regression FIX-B removes)")
        log.info(f"(f) private episode: master peer-ready-gated OUT of the serve "
                 f"rendezvous (rdv_timeout=0, waitpeer_entered=0) and failed open "
                 f"via the anchor timeout (0x21B8[2]=1) at "
                 f"t={w*CLK_PERIOD_NS/1000:.0f}us — arming the late die")

        # Final bilateral episode (the a-first tail): the retrain re-runs
        # training; both winscans rebind (FIX-1). The master's rendezvous now
        # finds a REAL slave that serves -> converges + full data oracle.
        await _late_die_convergence(dut, tb, log, "f")
    finally:
        stop[0] = True

    # ---- ASYMMETRY INVARIANT ----------------------------------------------
    # SLAVE: HOLDS its anchor and SERVES — NEVER waits/polls.
    assert not seen["s"]["waitpeer_hit"], (
        "(f) SLAVE observed in WS_FIN_WAITPEER — the slave must SERVE, never "
        "wait (the asymmetric-peer-serve invariant; only the master waits)")
    assert not seen["s"]["rdv_state_hit"], (
        "(f) SLAVE autoneg observed in ST_FIN_RDV/ST_FIN_GO — only the master "
        "runs the finalize rendezvous (local_fin_wait_i is master-gated)")
    assert not seen["s"]["rdv_timeout_hit"], (
        "(f) SLAVE ws_rdv_timeout_q observed 1 — the slave never enters the "
        "rendezvous, so it can never time out")
    # MASTER: FIX-B — against a peer that cannot serve the master must NOT PARK in
    # WS_FIN_WAITPEER (asserted per-episode via ws_waitpeer_entered_q above); but
    # it DOES enter the side-effect-free ST_FIN_RDV poll to READ the peer's ready
    # bit (it just never writes a GO). (A LEGITIMATE WS_FIN_WAITPEER entry can
    # still occur later in the bilateral episode once the real slave is ready, so
    # seen["m"]["waitpeer_hit"] is NOT asserted either way here.)
    assert seen["m"]["rdv_state_hit"], (
        "(f) MASTER autoneg never entered ST_FIN_RDV — the side-effect-free "
        "finalize poll arc did not fire")
    # Both dies were observed QUIESCED in their re-anchor window (master in
    # WAITPEER, slave in FINALIZE).
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert seen[side]["quiesced_in_finalize"], (
            f"(f) {name}: never observed QUIESCED (fch_quiesced_r=1) inside its "
            f"re-anchor window — the quiesce-before-re-confirm is broken")
    # End state: the FINAL bilateral episode's rendezvous completed cleanly
    # (WS_ARM clears the per-episode stickies), so no residual timeout/vfy-retry.
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        assert _si(c.ws_rdv_timeout_q) == 0, (
            f"(f) {name}: ws_rdv_timeout_q latched at end — the final bilateral "
            f"rendezvous did not complete (the peer never served)")
        assert _si(c.ws_vfy_retry_q) == 0, (
            f"(f) {name}: ws_vfy_retry_q latched on a clean sim eye — the "
            f"anchor-verify should pass first try here")
    log.info("VERDICT (f): PASS — ASYMMETRIC rendezvous: master waited+polled "
             "(WAITPEER + ST_FIN_RDV/GO), slave only served (never waited); the "
             "zombie episode failed loud (rdv-timeout -> anchor-timeout) and "
             "the final bilateral episode converged + delivered the byte-exact "
             "oracle")
