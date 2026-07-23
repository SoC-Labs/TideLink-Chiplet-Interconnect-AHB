"""FAIL-FIRST repro — WS_FIN_WAITPEER NODONE livelock + die_b re-serve thrash.

Silicon failure class (4-agent root cause, 2026-07-07)
-----------------------------------------------------
When die_a (MASTER) starves its LOCAL winscan anchor and falls to the R-B
peer-serve fallback (WS_FIN_WAITPEER), and die_b then SERVES so die_a's anchor
re-latches BUT the re-latched anchor cannot VERIFY (a wrong-slot / marginal-eye
mis-anchor — the die_b byte-lane 0x24->0x5c signature), the WS_FIN_WAITPEER
Phase-2 release gate (ws_anchor_q && ws_verify_q) never fires. On the pre-fix
RTL (4f39fb6) the Phase-2 anchor-timeout exit returned to WS_FINALIZE WITHOUT
latching ws_rdv_timeout_q, so the `!ws_rdv_timeout_q` fallback guard (~L4619)
stayed TRUE and the FSM re-entered WS_FIN_WAITPEER, re-issued the serve GO, and
ping-ponged forever: winscan_done NEVER asserts (the NODONE livelock, which
deadlocks the fch_pending_r handoff) and each re-entry re-thrashes die_b's
credit (repeated re-serves).

FIX-A latches ws_rdv_timeout_q on the Phase-2 anchor-timeout exit, so the
rendezvous is tried EXACTLY ONCE per episode: the next WS_FINALIZE
retry-exhaustion takes the BASE fail-loud arm (winscan_done<=1,
ws_anchor_timeout_q<=1, keep the latched anchor, ->WS_DONE). No deadlock, and
die_b serves at most once.

How this test models it deterministically
-----------------------------------------
Same autonomous zero-poke bring-up + die_b keepalive-peer model as
test_diea_beacon_starvation_repro (keepalive="on": die_b's TX idle slots are
occupied so die_a's LOCAL anchor never latches -> die_a falls to
WS_FIN_WAITPEER; die_b then SERVES on the master's GO, releasing link_idle so
die_a's anchor RE-latches). ADDITIONALLY this test holds die_a's per-lane
exact-compare (the verify) LOW via the t33e injection net
anchor_vfy_lane_w=Force(0), so the re-latched anchor can NEVER satisfy the
Phase-2 verify -> the exact Phase-2 verify-stuck condition.

  * On 4f39fb6: die_a winscan_done never asserts within the budget (the NODONE
    livelock) and die_b ws_serve_cnt / die_a ws_waitpeer_reentry_cnt climb past
    1 (the re-serve/re-entry thrash). The assertions below FAIL (fail-first).
  * After FIX-A: die_a winscan_done asserts (base fail-loud once ws_rdv_timeout_q
    caps the fallback), die_b serves exactly once, die_a enters WS_FIN_WAITPEER
    exactly once. The assertions PASS.

This test does NOT assert data crossing — with the verify held stuck die_a
fail-opens BY DESIGN; the property under test is "winscan_done asserts without
livelock" (FIX-A) and "the serve/re-entry stays bounded" (no thrash).

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_l5 SIM=vcs \
      make MODULE=test_nodone_livelock
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB

# Proven helpers (side-effect-free imports — cocotb collects tests only from
# $MODULE, the test_32/test_33 precedent).
from test_31_autonomous_training_exit import _ctrl, _autoneg, _si
from test_32_die_a_first_zombie_retry import _apb_arm, ST_ERROR
from test_33_arm_stagger_episode_binding import _setup, _obs_snapshot, _vfy_lane_net
from test_diea_beacon_starvation_repro import _model_keepalive_peer

CLK_PERIOD_NS = 20.0

# Winscan FSM state encodings (axi_chiplet_controller.sv).
WS_FINALIZE     = 7
WS_FIN_CLRLOW   = 9
WS_FIN_WAITPEER = 10


def _opt(handle, name):
    """Read a possibly-absent FIX-D obs reg (returns -1 if the signal does not
    exist — e.g. on the pre-FIX-D 4f39fb6 baseline, so the RED run fails on the
    behavioural winscan_done assertion, not on a missing-signal AttributeError)."""
    return _si(getattr(handle, name, None))


async def _waitpeer_edge_counter(dut, side, ev, stop):
    """Count rising transitions of `side`'s ws_state_r into WS_FIN_WAITPEER
    (uses ws_state_r, which exists on ALL builds). The livelock re-enters
    WS_FIN_WAITPEER unboundedly; FIX-A caps it at one entry."""
    c = _ctrl(dut, side)
    prev = -1
    while not stop[0]:
        await ClockCycles(dut.hclk, 40)
        st = _si(c.ws_state_r)
        if st == WS_FIN_WAITPEER and prev != WS_FIN_WAITPEER:
            ev["waitpeer_entries"] += 1
        prev = st


@cocotb.test()
async def test_nodone_livelock(dut):
    """die_a starves into WS_FIN_WAITPEER, die_b serves so its anchor re-latches,
    but die_a's verify is held LOW -> Phase-2 never releases. On 4f39fb6 the FSM
    ping-pongs WS_FIN_WAITPEER<->WS_FINALIZE forever (winscan_done never asserts;
    die_b re-serves). After FIX-A winscan_done asserts (base fail-loud) and the
    serve/re-entry stays bounded."""
    log = dut._log
    log.info("NODONE LIVELOCK repro — die_a served-but-verify-stuck in WS_FIN_WAITPEER")
    tb = PairTB(dut)
    await _setup(dut, tb)

    # Hold die_a's (master's) per-lane exact-compare LOW: the re-latched anchor
    # can never verify (the wrong-slot Phase-2-stuck condition). die_b's verify
    # is left free so die_b completes its own winscan and is READY-TO-SERVE.
    _vfy_lane_net(dut, "m").value = Force(0)

    stop = [False]
    # die_b keepalive-peer model: starve die_a's LOCAL anchor (link_idle=0) until
    # die_b SERVES on the master's GO, then release link_idle so die_a's anchor
    # re-latches in WS_FIN_WAITPEER Phase-2 (where the held verify then stalls it).
    peer_ev = {"latched": False, "last_force_sync": -1, "last_insert_en": -1,
               "last_link_idle": -1, "serve_seen": False,
               "released_on_serve": False}
    cocotb.start_soon(_model_keepalive_peer(dut, "on", stop, peer_ev))

    # Build-agnostic WS_FIN_WAITPEER re-entry edge counter (ws_state_r EXISTS on
    # 4f39fb6, unlike the FIX-D obs regs) — the fast-RED livelock detector: after
    # FIX-A the master enters WS_FIN_WAITPEER EXACTLY ONCE, so >=2 rising entries
    # is the ping-pong livelock and we fail fast instead of running the whole 8M
    # budget out (~70 min) on the pre-fix RTL.
    st_ev = {"waitpeer_entries": 0}
    cocotb.start_soon(_waitpeer_edge_counter(dut, "m", st_ev, stop))

    await _apb_arm(tb, "m", priority=1)
    await _apb_arm(tb, "s", priority=2)
    log.info("both dies role-armed; die_a verify forced low; die_b modelled as "
             "keepalive-then-serve peer")

    mc = _ctrl(dut, "m")
    sc = _ctrl(dut, "s")

    # Evidence tracked across the run (the thrash detectors — new FIX-D obs).
    max_reentry = 0        # die_a ws_waitpeer_reentry_cnt (0x21B8[19:18])
    max_serve   = 0        # die_b ws_serve_cnt_q          (0x21B8[17:16])
    saw_waitpeer = False   # die_a ever parked in WS_FIN_WAITPEER
    saw_verify_stuck = False  # die_a ws_verify_stuck_q (0x21B8[14])

    # Bounded budget for die_a's winscan to TERMINATE. On 4f39fb6 it never does
    # (the livelock) and this loop runs to MAX then the assertion fails; after
    # FIX-A it terminates in ~1.5M and we early-out.
    poll, waited, last = 500, 0, 0
    MAX = 8_000_000
    while waited < MAX:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        max_reentry = max(max_reentry, _opt(mc, 'ws_waitpeer_reentry_cnt'))
        max_serve   = max(max_serve, _opt(sc, 'ws_serve_cnt_q'))
        if _si(mc.ws_state_r) == WS_FIN_WAITPEER:
            saw_waitpeer = True
        if _opt(mc, 'ws_verify_stuck_q') == 1:
            saw_verify_stuck = True
        if _si(mc.winscan_done) == 1:
            log.info(f"die_a winscan_done asserted at "
                     f"t={waited*CLK_PERIOD_NS/1000:.0f}us")
            break
        # Fast-RED: >=2 WS_FIN_WAITPEER entries with winscan_done still 0 is the
        # ping-pong livelock (FIX-A caps entries at 1). Bail out so the RED run
        # fails on the assertion below in ~seconds instead of the full 8M budget.
        if st_ev["waitpeer_entries"] >= 2:
            log.info(f"LIVELOCK detected: {st_ev['waitpeer_entries']} "
                     f"WS_FIN_WAITPEER entries with winscan_done=0 at "
                     f"t={waited*CLK_PERIOD_NS/1000:.0f}us — bailing (fast-RED)")
            break
        if waited - last >= 500_000:
            last = waited
            log.info(f"t={waited*CLK_PERIOD_NS/1000:.0f}us "
                     f"m(ws={_si(mc.ws_state_r)} rea={_si(mc.ws_anchor_q)} "
                     f"vfy={_si(mc.ws_verify_q)} done={_si(mc.winscan_done)} "
                     f"rdv_to={_si(mc.ws_rdv_timeout_q)} "
                     f"reentry={_opt(mc, 'ws_waitpeer_reentry_cnt')} "
                     f"vfy_stuck={_opt(mc, 'ws_verify_stuck_q')}) | "
                     f"s(serve_active={_si(sc.ws_serve_active_r)} "
                     f"serve_cnt={_opt(sc, 'ws_serve_cnt_q')} "
                     f"done={_si(sc.winscan_done)})")

    # Settle so the final obs latch.
    await ClockCycles(dut.hclk, 2000)
    max_reentry = max(max_reentry, _opt(mc, 'ws_waitpeer_reentry_cnt'))
    max_serve   = max(max_serve, _opt(sc, 'ws_serve_cnt_q'))
    m = _obs_snapshot(dut, "m")
    s = _obs_snapshot(dut, "s")

    log.info("================ NODONE-LIVELOCK EVIDENCE ================")
    log.info(f"die_a: winscan_done={m['done']} ws_state={_si(mc.ws_state_r)} "
             f"rea={m['rea']} anc_to={m['anc_to']} "
             f"rdv_timeout={_si(mc.ws_rdv_timeout_q)} "
             f"waitpeer_entered={_opt(mc, 'ws_waitpeer_entered_q')} "
             f"max_reentry_cnt={max_reentry} verify_stuck={saw_verify_stuck} "
             f"saw_waitpeer={saw_waitpeer}")
    log.info(f"die_b: winscan_done={s['done']} max_serve_cnt={max_serve} "
             f"serve_seen={peer_ev['serve_seen']}")
    log.info(f"peer model: latched={peer_ev['latched']} "
             f"released_on_serve={peer_ev['released_on_serve']}")
    log.info("=========================================================")

    stop[0] = True
    await ClockCycles(dut.hclk, 100)
    _vfy_lane_net(dut, "m").value = Release()

    # ---- Harness sanity (fail loud on a broken run, not a livelock verdict) ---
    assert peer_ev["latched"], (
        "die_b keepalive-peer model never latched — die_a never reached its "
        "re-anchor window; harness issue, not a livelock verdict")
    assert s["done"] == 1, (
        f"die_b never completed its own winscan (done={s['done']}) — it cannot "
        f"be ready-to-serve; the asymmetric precondition is not established")
    assert saw_waitpeer, (
        "die_a never entered WS_FIN_WAITPEER — the serve fallback did not engage "
        "(die_a anchored locally? the keepalive starvation is not holding)")
    assert peer_ev["serve_seen"], (
        "die_b never SERVED — the master's FINALIZE_GO rendezvous did not fire; "
        "die_a's Phase-2 re-anchor was never exercised")
    for side in ("m", "s"):
        assert _si(_autoneg(dut, side).state_r) != ST_ERROR, \
            f"[{side}] autoneg parked in terminal ST_ERROR — unrelated crash"

    # ---- THE FIX-A ASSERTION (RED on 4f39fb6 = livelock) ----------------------
    assert m["done"] == 1, (
        f"NODONE LIVELOCK: die_a winscan_done never asserted — "
        f"{st_ev['waitpeer_entries']} WS_FIN_WAITPEER entries observed "
        f"(ws_state_r edges) with winscan_done=0, the WS_FIN_WAITPEER<->"
        f"WS_FINALIZE ping-pong (FIX-D obs ws_waitpeer_reentry_cnt={max_reentry}, "
        f"ws_verify_stuck={saw_verify_stuck}) never let winscan_done rise, so the "
        f"fch handoff deadlocks. FIX-A (latch ws_rdv_timeout_q on the Phase-2 "
        f"anchor-timeout exit) caps the fallback at one attempt -> base fail-loud "
        f"-> winscan_done=1.")
    # Belt-and-braces: even if winscan_done raced to 1, the ws_state_r-edge count
    # (build-agnostic) must show the fallback was NOT re-entered (livelock).
    assert st_ev["waitpeer_entries"] <= 1, (
        f"die_a re-entered WS_FIN_WAITPEER {st_ev['waitpeer_entries']} times "
        f"(ws_state_r edges) — the ping-pong livelock; FIX-A must cap it at 1.")

    # ---- THE THRASH ASSERTIONS (RED on 4f39fb6 = re-serve/re-entry unbounded) -
    # After FIX-A the master enters WS_FIN_WAITPEER exactly once and die_b serves
    # exactly once. On 4f39fb6 both saturate (2-bit) at 3 across the livelock.
    assert max_reentry <= 1, (
        f"die_a re-entered WS_FIN_WAITPEER {max_reentry} times (0x21B8[19:18]) — "
        f"the WS_FINALIZE->WS_FIN_WAITPEER ping-pong (the livelock signature). "
        f"FIX-A must cap this at 1.")
    assert max_serve <= 1, (
        f"die_b re-served {max_serve} times (ws_serve_cnt 0x21B8[17:16]) — the "
        f"credit re-serve thrash the livelock drove. FIX-A must cap this at 1.")

    log.info(f"VERDICT: PASS — die_a winscan_done asserted (no livelock), "
             f"die_a WS_FIN_WAITPEER re-entries={max_reentry}<=1, die_b "
             f"serves={max_serve}<=1 (no re-serve thrash); ws_rdv_timeout_q="
             f"{_si(mc.ws_rdv_timeout_q)} capped the fallback at one attempt")
