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
      byte-lane forever.
  (f) R-B A-FIRST QUIESCED PEER-RENDEZVOUS (2026-07-04): the t33a a-first
      flow, now asserting the rendezvous mechanism directly: the PRIVATE
      zombie episode's WS_FIN_WAITPEER must exit via its FAIL-LOUD timeout
      (ws_rdv_timeout_q 0x21B8[10] — no peer ever quiesces), and on the
      FINAL bilateral episode BOTH dies must be observed parked QUIESCED in
      WS_FIN_WAITPEER (fch_quiesced_r=1) BEFORE their first WS_FINALIZE —
      i.e. the F3 clear + anchor window only opens after the local-AND-peer
      quiesce rendezvous (master polls SWI_LANE_STATUS[27], slave released
      by the FINALIZE_GO write) — with ws_rdv_timeout_q CLEAN at the end
      (released by the GO, not the timeout) + the full data oracle. Pre-R-B
      RTL: the locally-timed windows never overlap under a-first arm skew
      (silicon 0x57000005 both, rea=0/0).

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
WS_FIN_WAITPEER = 10                  # R-B: quiesced peer-rendezvous hold
WS_MIDSCAN = {2, 3, 4, 5, 6, 7, 9, 10}  # LANE..FINALIZE + CLRLOW + RDV-WAIT
                                         # = abortable (episode binding)
# R-B: the autoneg's finalize-rendezvous states (post-ST_TRAIN_DONE phase)
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
        assert v["insert_en"] == 1 and v["robust"] == 1, (
            f"[{tag}] {name}: D2 REGRESSION — beacons/robust not up in data "
            f"mode (insert_en={v['insert_en']} robust={v['robust']})")
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
    mc = _ctrl(dut, "m")
    ok, w = await _wait_sig(dut, lambda: _si(mc.winscan_done), 1,
                            max_cycles=2_500_000)
    assert ok, ("(a) MASTER private-episode winscan_done never rose — the "
                "zombie-bypass arc (forced lock-qual -> ST_TRAIN_EXIT -> "
                "training fall -> scan -> FIX-3 fail-open) is broken")
    priv = _obs_snapshot(dut, "m")
    log.info(f"(a) private episode done at t={w*CLK_PERIOD_NS/1000:.0f}us: {priv}")
    assert priv["anc_to"] == 1, (
        "(a) private zombie episode did NOT fail open (0x21B8[2]=0)? The "
        "beacon-less peer cannot anchor — precondition for the stagger bug "
        "not established (did the zombie beacon?)")
    # R-B: ST_FIN_RDV/ST_FIN_GO are legal parking spots here — the private
    # winscan's WS_FIN_WAITPEER raised local_fin_wait_i, and the autoneg's
    # rendezvous poll of the zombie may still be draining its last I2C
    # transaction when winscan_done (rendezvous-timeout -> fail-open) rises;
    # it abandons back to ST_TRAIN_DONE at the next poll boundary.
    assert _si(_autoneg(dut, "m").state_r) in (ST_TRAIN_DONE, ST_FIN_RDV,
                                               ST_FIN_GO), (
        f"(a) master not parked ST_TRAIN_DONE(/FIN_RDV/FIN_GO) after the "
        f"bypass exit (an={_si(_autoneg(dut,'m').state_r)}) — private episode "
        f"did not complete via the zombie-bypass arc")
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
        if _si(c.ws_state_r) in WS_FINALIZE_STATES:
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
    log.info(f"(e) verify-retry latched on both dies at "
             f"t={waited*CLK_PERIOD_NS/1000:.0f}us with anchors latched and "
             f"winscan_done held — releasing the wrong-slot force")

    for side in ("m", "s"):
        _vfy_lane_net(dut, side).value = Release()

    # The in-flight retry re-clears + re-anchors; the now-unforced verify
    # passes and the pair must converge to the full byte-exact oracle.
    await _assert_end_state(dut, tb, log, "e")

    # The per-episode evidence sticky must survive to the end (cleared only
    # at WS_ARM — no new episode ran after the release).
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert _si(_ctrl(dut, side).ws_vfy_retry_q) == 1, (
            f"(e) {name}: ws_vfy_retry_q (0x21B8[9]) not sticky at end — the "
            f"episode's verify-retry evidence was lost")
    log.info("VERDICT (e): PASS — verify-fail HELD the release and forced the "
             "clear-retry (0x21B8[9]); post-release the re-anchor verified and "
             "both dies reached the full byte-exact oracle")


# ---------------------------------------------------------------------------
# (f) R-B A-FIRST QUIESCED PEER-RENDEZVOUS (2026-07-04). Silicon: a-first arm
# order starved BOTH dies (0x21B8=0x57000005 both, rea=0/0) — the
# locally-timed quiesce/finalize windows never overlapped. Fix: each die
# parks QUIESCED in WS_FIN_WAITPEER before its F3 clear/anchor window; the
# master polls the slave's SWI_LANE_STATUS[27] (quiesced-in-wait) over I2C
# and writes the slave's FINALIZE_GO (0x211C) once BOTH are quiesced —
# releasing the two windows within one I2C write of each other. The slave
# cannot poll; the GO write is its release (the L4 slave-release idiom).
# This variant asserts the mechanism on the t33a a-first flow.
# ---------------------------------------------------------------------------
async def _rdv_monitor(dut, side, seen, stop):
    """Track, per current episode, whether the die was observed parked
    QUIESCED in WS_FIN_WAITPEER BEFORE its first WS_FINALIZE/WS_FIN_CLRLOW
    observation. The per-episode flag reset keys on the SCAN states (2..6,
    thousands of cycles) rather than the 1-cycle WS_ARM, so the 20-cycle
    sampler cannot miss it — a stale private-episode waitpeer_q can never
    leak into the final episode's verdict. The WAITPEER (>= one ~40k-cycle
    I2C poll iteration) and FINALIZE (>= the 100k sim dwell) windows are
    likewise sample-proof."""
    WS_SCAN_STATES = {1, 2, 3, 4, 5, 6}   # ARM..PICK: pre-finalize, per-episode
    c = _ctrl(dut, side)
    while not stop[0]:
        await ClockCycles(dut.hclk, 20)
        st = _si(c.ws_state_r)
        if st in WS_SCAN_STATES:
            seen[side]["waitpeer_q"] = False
            seen[side]["finalize"] = False
            seen[side]["waitpeer_before_finalize"] = False
        elif st == WS_FIN_WAITPEER and _si(c.fch_quiesced_r) == 1:
            seen[side]["waitpeer_q"] = True
        elif st in WS_FINALIZE_STATES and not seen[side]["finalize"]:
            seen[side]["finalize"] = True
            seen[side]["waitpeer_before_finalize"] = seen[side]["waitpeer_q"]


@cocotb.test()
async def test_33f_a_first_quiesced_rendezvous(dut):
    """(f) a-first: the private zombie episode's rendezvous must FAIL-LOUD
    (ws_rdv_timeout_q), and the final bilateral episode must show BOTH dies
    quiesced-in-WS_FIN_WAITPEER BEFORE finalize, released by the GO (clean
    ws_rdv_timeout_q) + the full data oracle."""
    log = dut._log
    log.info("(f) A-FIRST QUIESCED PEER-RENDEZVOUS")
    tb = PairTB(dut)
    await _setup(dut, tb)

    stop = [False]
    seen = {s: {"waitpeer_q": False, "finalize": False,
                "waitpeer_before_finalize": False} for s in ("m", "s")}
    for side in ("m", "s"):
        cocotb.start_soon(_rdv_monitor(dut, side, seen, stop))

    try:
        _force_zombie_bypass(dut, "m")
        await _apb_arm(tb, "m", priority=1)
        log.info("(f) MASTER armed first (zombie-bypass private episode)")

        # Private episode: the rendezvous can never complete (the zombie's
        # winscan never runs, its [27] reads 0, no GO ever arrives) — the
        # WS_FIN_WAITPEER FAIL-LOUD timeout must fire and the finalize then
        # proceeds locally (fail-open anchor, as in t33a). Budget: bypass
        # walk ~233k + scan + rendezvous timeout (400k sim) + FINALIZE
        # fail-open (5 retries).
        mc = _ctrl(dut, "m")
        ok, w = await _wait_sig(dut, lambda: _si(mc.winscan_done), 1,
                                max_cycles=3_000_000)
        assert ok, ("(f) MASTER private-episode winscan_done never rose — the "
                    "rendezvous timeout path deadlocked the zombie episode?")
        assert _si(mc.ws_rdv_timeout_q) == 1, (
            "(f) private zombie episode: ws_rdv_timeout_q (0x21B8[10]) NOT "
            "latched — the WS_FIN_WAITPEER fail-loud timeout did not fire "
            "although no peer could ever rendezvous (a dead/V1/manual peer "
            "would DEADLOCK the autonomous bring-up)")
        assert seen["m"]["waitpeer_q"], (
            "(f) private episode: master never observed QUIESCED in "
            "WS_FIN_WAITPEER — the quiesce does not precede the rendezvous "
            "hold")
        log.info(f"(f) private episode: rendezvous timed out fail-loud "
                 f"(0x21B8[10]) at t={w*CLK_PERIOD_NS/1000:.0f}us — arming "
                 f"the late die")

        # Final bilateral episode (the a-first tail): the retrain re-runs
        # training; both winscans rebind (FIX-1) and must now rendezvous.
        await _late_die_convergence(dut, tb, log, "f")
    finally:
        stop[0] = True

    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        assert seen[side]["waitpeer_before_finalize"], (
            f"(f) {name}: NOT observed quiesced in WS_FIN_WAITPEER before its "
            f"first WS_FINALIZE of the final episode — the F3 clear/anchor "
            f"window opened without the peer rendezvous (the a-first "
            f"non-overlap window is back)")
        assert _si(c.ws_rdv_timeout_q) == 0, (
            f"(f) {name}: ws_rdv_timeout_q latched on the FINAL bilateral "
            f"episode — the rendezvous was released by the fail-loud timeout, "
            f"not the GO (I2C poll/[27]/FINALIZE_GO machinery broken)")
        assert _si(c.ws_vfy_retry_q) == 0, (
            f"(f) {name}: ws_vfy_retry_q latched on a clean sim eye — the "
            f"anchor-verify should pass first try here")
    log.info("VERDICT (f): PASS — private episode failed loud (0x21B8[10]); "
             "final bilateral episode rendezvous-aligned BOTH dies' quiesced "
             "windows before finalize (GO-released, timeout clean) and "
             "delivered the full byte-exact oracle")
