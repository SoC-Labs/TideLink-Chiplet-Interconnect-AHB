"""FAIL-FIRST repro — first-armed MASTER falls into WS_FIN_WAITPEER while its
peer CANNOT SERVE (still arming) = the die_b first-armed 83%->58% regression.

Silicon failure class (4-agent root cause, 2026-07-07)
-----------------------------------------------------
The WS_FINALIZE peer-serve fallback (~L4619) entered WS_FIN_WAITPEER on
`role_is_master && !ws_anchor_q && !ws_rdv_timeout_q` with NO "peer is up" term.
So the FIRST-armed die (its peer still arming — it CANNOT serve) fell into
WS_FIN_WAITPEER, stalled for the whole rendezvous window, and its Phase-1/Phase-2
re-clear DESTROYED the sticky anchor that would otherwise late-heal. FIX-B adds
`&& peer_ready_to_serve_w` (the peer's SWI_LANE_STATUS[27] captured by the
master's side-effect-free ST_FIN_RDV poll): with the peer un-armed (peer[27]=0)
the fallback is FALSE and control falls to the BASE fail-open (Loop-14 83% path,
sticky anchor preserved). Only a 2nd-armed die whose peer is already in data mode
takes the serve.

The reset-stagger lever + why this test does NOT use s/m_por_gate
----------------------------------------------------------------
The task's intended lever was s/m_por_gate (hold the peer in POR reset while the
first die finalizes). EMPIRICALLY that is infeasible here: a fully POR-held peer
also holds its I2C slave + SDA, so the FIRST-armed die LOSES its own role
negotiation (observed: master 'm' armed priority 1 reached ST_NEGO_DONE with
lost=1 -> it became the SLAVE, so `role_is_master` is false and the fallback
never fires — the premise breaks). This test therefore realises the SAME
engineering condition ("first die reaches WS_FINALIZE while its peer cannot
serve") with the proven test_33f idiom: a reset-RELEASED but UN-ARMED zombie
peer. The zombie's I2C responds (so the first die role-locks as MASTER) but it is
un-armed (autonomy_armed=0 -> SWI_LANE_STATUS[27]=0 -> peer_ready_to_serve_w=0 ->
it cannot serve) — the exact "peer still arming" state. Only the first='m'
ordering is run: the reverse (first='s') is blocked by a role-arbitration
artifact in the zombie harness (see the NOTE at the bottom of this file).

  * On 4f39fb6: the first die (master) ENTERS WS_FIN_WAITPEER prematurely
    (ws_waitpeer_entered_q=1 / observed in WS_FIN_WAITPEER) though the peer
    cannot serve -> the assertion FAILS (fail-first).
  * After FIX-B: peer_ready_to_serve_w=0 -> the first die takes the base
    fail-open (no WS_FIN_WAITPEER while peer un-armed) -> PASS.

Then the peer is ARMED + a retrain kicked, and BOTH dies must converge
(winscan_done=1, reanchored=1, FCSM=4) on the bilateral episode.

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_l5 SIM=vcs \
      make MODULE=test_armorder_peer_absent
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_tidelink_pair_doorbell import PairTB

from test_31_autonomous_training_exit import (
    _ctrl, _autoneg, _si, _idle_stimulus, _reset,
)
from test_32_die_a_first_zombie_retry import (
    _apb_arm, ST_BYPASS, ST_ERROR, APB_NEGO_TRAIN_CFG,
)
from test_33_arm_stagger_episode_binding import (
    _deposit_hooks, _obs_snapshot, _force_zombie_bypass, _release_zombie_bypass,
    _wait_sig, WS_FIN_WAITPEER, NEGO_TRAIN_CFG_RETRAIN,
)

CLK_PERIOD_NS = 20.0


async def _waitpeer_monitor(dut, side, ev, stop):
    """Record whether `side` is EVER observed in WS_FIN_WAITPEER while ev['absent']
    is set (the peer-cannot-serve phase) — the premature-entry evidence
    (sample-proof at a 20-cycle period)."""
    c = _ctrl(dut, side)
    while not stop[0]:
        await ClockCycles(dut.hclk, 20)
        if ev["absent"] and _si(c.ws_state_r) == WS_FIN_WAITPEER:
            ev["waitpeer_while_absent"] = True


async def _retrain(tb, side):
    apb = tb.m_apb if side == "m" else tb.s_apb
    await apb.write(APB_NEGO_TRAIN_CFG, NEGO_TRAIN_CFG_RETRAIN)


async def _run_armorder(dut, first):
    """first = the die armed FIRST (as MASTER, priority 1). The OTHER die is a
    reset-released but un-armed zombie (present for nego, cannot serve) while the
    first die finalizes, then it is armed as the slave for convergence."""
    log = dut._log
    peer = "s" if first == "m" else "m"
    tag = f"first={first}"
    log.info(f"ARM-ORDER PEER-ABSENT — {tag} (peer {peer} un-armed zombie)")
    tb = PairTB(dut)

    await _idle_stimulus(dut)
    await _reset(dut)
    await _deposit_hooks(dut)
    await ClockCycles(dut.hclk, 200)

    for side in ("m", "s"):
        assert _si(_autoneg(dut, side).state_r) == ST_BYPASS, (
            f"[{tag}] {side} autoneg not in ST_BYPASS pre-arm "
            f"(state={_si(_autoneg(dut, side).state_r)})")

    stop = [False]
    ev = {"absent": True, "waitpeer_while_absent": False}
    cocotb.start_soon(_waitpeer_monitor(dut, first, ev, stop))

    # Drive the first die's PRIVATE winscan episode against the un-armed zombie
    # (test_33f idiom): force its local lane-lock so the autoneg's local-only
    # bypass reaches ST_TRAIN_EXIT -> a private training fall -> the winscan runs.
    _force_zombie_bypass(dut, first)
    await _apb_arm(tb, first, priority=1)
    log.info(f"[{tag}] first die armed as MASTER (private episode); peer {peer} "
             f"left UN-ARMED (cannot serve)")

    fc = _ctrl(dut, first)

    def _opt(name):
        # Read a possibly-absent FIX-D obs reg (returns -1 on the pre-FIX-D
        # 4f39fb6 baseline, so the RED run fails on the ws_state_r-based monitor
        # assertion, not on a missing-signal AttributeError).
        return _si(getattr(fc, name, None))

    # The first die's private winscan must TERMINATE (fail-loud bounded): with the
    # zombie beacon-less the anchor gate exits via the FIX-3 retry timeouts, then
    # the fallback decision -> (FIX-B) base fail-open, winscan_done rises.
    ok, w = await _wait_sig(dut, lambda: _si(fc.winscan_done), 1,
                            max_cycles=5_000_000)
    # Sample the premature-entry stickies WHILE THE PEER IS STILL UN-ARMED.
    waitpeer_entered = _opt("ws_waitpeer_entered_q")
    anc_to = _si(fc.ws_anchor_timeout_q)
    rdv_to = _si(fc.ws_rdv_timeout_q)
    role_m = _si(getattr(dut, first + "_role_locked"))
    log.info(f"[{tag}] first-die private episode done={_si(fc.winscan_done)} "
             f"(t={w*CLK_PERIOD_NS/1000:.0f}us) role_locked={role_m} "
             f"waitpeer_entered={waitpeer_entered} "
             f"waitpeer_seen_by_monitor={ev['waitpeer_while_absent']} "
             f"anc_to={anc_to} rdv_to={rdv_to}")

    # ---- Harness sanity (a broken run, not a FIX-B verdict) -------------------
    assert ok, (
        f"[{tag}] first-die private winscan never terminated (winscan_done=0 "
        f"after {w} cycles) — the private episode did not run/fail-loud; harness "
        f"issue, not a premature-entry verdict")
    assert role_m == 1, (
        f"[{tag}] first die never role-locked as MASTER — the fallback is "
        f"role_is_master-gated, so the premise is not established (nego lost?)")

    # ---- THE FIX-B ASSERTION (RED on 4f39fb6 = premature WAITPEER entry) -------
    assert waitpeer_entered == 0 and not ev["waitpeer_while_absent"], (
        f"[{tag}] first-die (MASTER) entered WS_FIN_WAITPEER while its peer could "
        f"NOT serve (ws_waitpeer_entered_q={waitpeer_entered}, "
        f"monitor={ev['waitpeer_while_absent']}) — the fallback fired with no "
        f"peer able to serve, stalling the rendezvous and destroying the sticky "
        f"anchor (the die_b first-armed 83%->58% regression). FIX-B "
        f"(peer_ready_to_serve_w gate) must make it take the base fail-open "
        f"instead (ws_anchor_timeout_q={anc_to}).")
    log.info(f"[{tag}] GOOD — first die did NOT prematurely enter WS_FIN_WAITPEER "
             f"(peer_ready gate held); it base-failed-open (anc_to={anc_to})")

    # ---- Arm the peer; the bilateral episode must converge --------------------
    ev["absent"] = False
    _release_zombie_bypass(dut, first)
    await _apb_arm(tb, peer, priority=2)
    log.info(f"[{tag}] peer {peer} armed (slave); waiting its role-lock")
    okrl, wrl = await _wait_sig(dut, lambda: _si(getattr(dut, peer + "_role_locked")),
                                1, max_cycles=4_000_000)
    assert okrl, f"[{tag}] peer never role-locked after arming"
    await _retrain(tb, first)
    log.info(f"[{tag}] retrain kicked on the master (bilateral episode)")

    # Convergence: BOTH dies winscan_done=1, anchor-timeout clear, rea=1, FCSM=4.
    poll, waited, last = 200, 0, 0
    snaps = None
    while waited < 9_000_000:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        snaps = {s: _obs_snapshot(dut, s) for s in ("m", "s")}
        if all(v["done"] == 1 and v["anc_to"] == 0 and v["rea"] == 1
               and v["fcsm"] == 4 for v in snaps.values()):
            log.info(f"[{tag}] CONVERGED at t={waited*CLK_PERIOD_NS/1000:.0f}us: "
                     f"m={snaps['m']} s={snaps['s']}")
            break
        if waited - last >= 400_000:
            last = waited
            log.info(f"[{tag}] t={waited*CLK_PERIOD_NS/1000:.0f}us "
                     f"m={snaps['m']} | s={snaps['s']}")

    stop[0] = True
    await ClockCycles(dut.hclk, 100)

    for side, name in (("m", "die_a"), ("s", "die_b")):
        v = snaps[side]
        assert v["done"] == 1, (
            f"[{tag}] {name}: winscan_done=0 at end — the bilateral episode did "
            f"not complete (first-armed starvation not recovered)")
        assert v["anc_to"] == 0, (
            f"[{tag}] {name}: ws_anchor_timeout_q sticky at end — the FINAL "
            f"episode failed open instead of re-anchoring")
        assert v["rea"] == 1, f"[{tag}] {name}: reanchored=0 at end"
        assert v["fcsm"] == 4, f"[{tag}] {name}: FCSM={v['fcsm']} != 4"
    for side in ("m", "s"):
        assert _si(_autoneg(dut, side).state_r) != ST_ERROR, \
            f"[{tag}] [{side}] autoneg parked in terminal ST_ERROR"

    log.info(f"VERDICT ({tag}): PASS — no premature WS_FIN_WAITPEER while peer "
             f"could not serve, and both dies converged after the peer armed")


@cocotb.test()
async def test_armorder_peer_absent_m_first(dut):
    """die_a-first: master 'm' armed first against the un-armed 's' zombie must
    NOT enter WS_FIN_WAITPEER while 's' cannot serve, then both converge."""
    await _run_armorder(dut, first="m")


# NOTE — the reverse ordering (first='s') is NOT run: in the BYPASS_AUTONEG zombie
# harness the role arbitration against an un-armed peer is physically biased —
# 's' armed priority 1 against the un-armed 'm' zombie reaches ST_NEGO_DONE with
# lost=1 (it becomes the SLAVE, observed 2026-07-07), so `role_is_master` is false
# and the master fallback under test never fires (a harness artifact of arbitrating
# without a real peer, NOT a FIX-B gap: the peer_ready_to_serve_w gate is role-based
# and symmetric, and is fully exercised by first='m' here, by test_nodone_livelock,
# and by test_diea_beacon_starvation_repro). A future harness that can force 's'
# master against a zombie should re-enable it via `_run_armorder(dut, first="s")`.
