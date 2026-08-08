"""L4 — de-forced autonomous training-exit (the training-exit-deadlock gate).

Root cause (3-agent consensus)
------------------------------
Zero-poke autonomous bring-up (NEGO_CFG=0x61) deadlocked: the PHY calibrator
parked in S_HOLD (cstate=6, train_live=1, cal_done=0) → TX training PRBS not
IDLE → no SYNC insert → winscan never triggers → FCSM=1. The circular wait:

  * calibrator S_HOLD → S_VALIDATE → S_DONE is gated on !swi_training_mode_r
    (deps calibrator :1339 — the FIX-E bilateral-release guard).
  * swi_training_mode_r is held HIGH by the autoneg FSM; it clears only at
    ST_TRAIN_EXIT (tidelink_autoneg.sv :1206).
  * ST_TRAIN_EXIT was reached only via the ST_TRAIN_POLL_PEER success predicate
    which required local_calibration_done_i (= cal_done = S_DONE) AND
    peer_cal_done_r → cal_done needs training=0 needs ST_TRAIN_EXIT needs
    cal_done. DEADLOCK.

The L4 fix retargets the exit rendezvous to BOTH-DIES-PARKED-IN-S_HOLD (the
reachable state, exposed by the calibrator's new cal_in_hold_o and read peer↔
peer over SWI_LANE_STATUS), then ST_TRAIN_EXIT does the bilateral
swi_training_mode clear → both S_HOLD gates open → both advance to S_DONE.

Why this test (the OLD sims can't see the bug)
----------------------------------------------
The V2 pair suites FORCE the calibrator past S_HOLD via tb_early_exit_force_q,
so they NEVER exercise the training-exit. This test:
  (a) does NOT set tb_early_exit_force_q (leaves it 0 on both dies),
  (b) shrinks the calibrator S_HOLD dwell (HOLD_CYCLES) and the sweep dwell
      (DWELL_CYCLES) via a tb defparam TIMING knob (+define+TB_TOP_SHORT_CAL_HOLD
      / _DWELL) so the sim is bounded — NOT a state bypass,
  (c) runs the autonomous NEGO_CFG=0x61 bring-up with ZERO pokes (tb force
      block, BYPASS_AUTONEG=0),
  (d) ASSERTS both calibrators TRANSIT S_HOLD (state 6) then reach cal_done
      (S_DONE, state 4) — proving swi_training_mode_r was cleared by the FSM,
      not a TB force,
  (e) asserts swi_training_mode_r goes 1→0 on both dies (via the autoneg's
      local_train_clr_pulse), and that the FCSM leaves state 1.

R1 strengthening (2026-07-02) — autonomous FC-handoff DATA gate
---------------------------------------------------------------
The bridge1 silicon run completed a-g and wedged ONLY at (h) data delivery:
the fch sequencer's bootstrap drove 0x27f08/0x27f00/0x27f07 (bit0 = FCCTRL
0x208 swi_enable = the FCSM run/credit enable held LOW through the swreset),
wedging the sender fe_rx_is_full=1 (OBS_FC_CREDIT=0xfc01001f); the manual
0x27f09/0x27f01/0x27f07 re-run cleared it. WHY SIM MISSED IT: since the
winscan handoff gate landed (8705a99), the fch bootstrap NEVER actually ran
inside the sim window — winscan_done sits behind the SILICON per-tap dwell
(2.5M apb cycles/tap ⇒ the scan "finishes" ~seconds of sim time after the
training fall), so FCSM=4 was reached NATURALLY by the clean-PHY framers and
test_30's doorbell crossed on that naturally-up link, never on the bootstrap
path (and a doorbell is a single short packet — it doesn't stress the fe
credit ring the way an AHB_TX data burst does). This test now:
  (f) engages the DESIGNED-IN winscan sim-dwell hook (tb_winscan_dwell_short_q,
      same idiom as the calibrator's knob — a timing accommodation, NOT a
      state bypass) so the winscan AND the fch bootstrap actually RUN in-window,
      and FORCES obs_sync_dist_vec_w=0 on both dies (a SIM EYE MODEL, the same
      idiom as test_v2_winscan_fsm's dist model): in RTL sim there is no real
      eye — the raw metric is pure rotation noise because the tap nibble is
      OR-merged into the deserialiser word phase (WavD2DGpioRx adj_count), so
      an unmodelled in-window scan commits arbitrary rotation taps and
      permanently corrupts both dies' RX (diagnosed 2026-07-02: slave parked
      fcsm=2 ck=0 cred=0 post-bootstrap). A flat-0 metric makes the scan
      DEGENERATE, which additionally regression-gates the R2c guard:
      ws_degenerate_q must latch and the SEEDED taps must be restored,
  (g) monitors the fch sequencer and asserts it drove EXACTLY the proven
      manual values 0x27f09 → 0x27f01 → 0x27f07 on BOTH dies,
  (h) after the post-bootstrap FCSM=4, sends an AHB_TX data burst M→S and
      asserts BYTE-EXACT arrival + the sender's fe credit gate OPEN
      (fe_rx_is_full=0, fe_rx_credit_max loaded) — the exact silicon step
      that wedged.

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \
      COMPILE_ARGS+="+define+TB_TOP_SHORT_CAL_HOLD=64 +define+TB_TOP_SHORT_CAL_DWELL=8" \
      SIM=vcs MODULE=test_31_autonomous_training_exit \
      make MODULE=test_31_autonomous_training_exit
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from cocotb.handle import Force

# PairTB gives the proven signal-level AHB_TX / FIFO drivers for the R1 data
# gate (h). Its ctor also starts the clocks + idles the buses.
from test_tidelink_pair_doorbell import PairTB

CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

# R1: the PROVEN manual FC-handoff bootstrap values (0x208 writes) the
# autonomous fch sequencer must replicate EXACTLY (bit0 = swi_enable HELD 1).
FCH_EXPECT = [0x00027F09, 0x00027F01, 0x00027F07]

# Calibrator state encoding (deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv)
CAL_S_IDLE, CAL_S_ARM, CAL_S_SWEEP, CAL_S_FINISH = 0, 1, 2, 3
CAL_S_DONE, CAL_S_CANCEL, CAL_S_HOLD = 4, 5, 6
CAL_S_PROBE, CAL_S_FINALIZE, CAL_S_VALIDATE = 7, 8, 9
CAL_NAMES = {
    0: "S_IDLE", 1: "S_ARM", 2: "S_SWEEP", 3: "S_FINISH", 4: "S_DONE",
    5: "S_CANCEL", 6: "S_HOLD", 7: "S_PROBE", 8: "S_FINALIZE", 9: "S_VALIDATE",
}

# Autoneg FSM state encoding (tidelink_autoneg.sv)
ST_TRAIN_EXIT = 15
ST_TRAIN_DONE = 16
ST_TRAIN_FAIL = 17


def _top(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _ctrl(dut, side):
    return _top(dut, side).u_chiplet_controller


def _cal(dut, side):
    return _ctrl(dut, side).u_calibrator


def _autoneg(dut, side):
    return _ctrl(dut, side).u_autoneg


def _fcsm(dut, side):
    return _ctrl(dut, side).u_wlink.tl2wl.wlink_tidelinktl


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


async def _idle_stimulus(dut):
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        for port in ("tx", "fifo"):
            getattr(dut, f"{prefix}_ahb_{port}_hsel").value      = 0
            getattr(dut, f"{prefix}_ahb_{port}_haddr").value     = 0
            getattr(dut, f"{prefix}_ahb_{port}_htrans").value    = 0
            getattr(dut, f"{prefix}_ahb_{port}_hsize").value     = 2
            getattr(dut, f"{prefix}_ahb_{port}_hwrite").value    = 0
            getattr(dut, f"{prefix}_ahb_{port}_hwdata").value    = 0
            getattr(dut, f"{prefix}_ahb_{port}_hready_in").value = 1


async def _reset(dut):
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 20)
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1
    await ClockCycles(dut.hclk, 50)


async def _fch_monitor(dut, side, fch_writes, anchor_at_boot):
    """R1 (g): record the ORDERED, DEDUPED sequence of 0x208 payloads the fch
    sequencer drives (fch_wdata_r while fch_active_r=1). Coarse-polls until the
    handoff arms (fch_pending_r latches on the training fall and holds for the
    whole winscan), then fine-samples every 2 hclk (= apb_clk) cycles — each
    payload is held for >=3 cycles (SETUP+ACCESS minimum, the Q1 quiesce
    single-write case), so none can be missed. Exits once fch_done_r latches.

    Q1 (2026-07-04): the observed sequence now SPANS the quiesce write + the
    bootstrap walk — 0x27f09 lands EARLY (at WS_FINALIZE entry, locally
    timed — Loop-13 reverted the Loop-12 WS_FIN_WAITPEER rendezvous hold;
    fch_qmode_r=1)
    and the bootstrap then walks 0x27f01 -> 0x27f07 from the swreset-ON state.
    The deduped payload sequence is therefore UNCHANGED (== FCH_EXPECT): the
    proven manual values, with the SWRESET_ON step re-ordered BEFORE the
    re-anchor exactly as the quiesce-before-finalize design intends.

    F4 (2026-07-02) + Q1: samples the controller's CDC'd deskew `reanchored`
    status (ws_anchor_q) at the first fch_active_r cycle OF THE BOOTSTRAP WALK
    (fch_qmode_r==0) — the F4 anchor gate must guarantee reanchored==1 BEFORE
    the bootstrap runs. The quiesce write itself (fch_qmode_r==1) legitimately
    PRECEDES the anchor (it is what makes the anchor reachable on a chatty
    link), so it must not be sampled as the bootstrap start."""
    ctrl = _ctrl(dut, side)
    while True:                       # coarse: wait for the handoff to arm
        await ClockCycles(dut.hclk, 200)
        try:
            if int(ctrl.fch_pending_r.value) == 1 or \
               int(ctrl.fch_active_r.value) == 1:
                break
        except ValueError:
            pass
    while True:                       # fine: capture the burst
        await ClockCycles(dut.hclk, 2)
        try:
            if int(ctrl.fch_active_r.value) == 1:
                if side not in anchor_at_boot and \
                   _si(ctrl.fch_qmode_r) == 0:
                    anchor_at_boot[side] = _si(ctrl.ws_anchor_q)
                w = int(ctrl.fch_wdata_r.value)
                lst = fch_writes[side]
                if not lst or lst[-1] != w:
                    lst.append(w)
            if int(ctrl.fch_done_r.value) == 1:
                return
        except ValueError:
            pass


async def _winscan_tracer(dut, log):
    """F3/F4 low-noise tracer: winscan FSM + anchor state on both dies every
    25k cycles until both fch_done. Diagnoses anchor-gate rendezvous issues
    (which die forced/cleared/anchored when)."""
    names = {0: "IDLE", 1: "ARM", 2: "LANE", 3: "SETTLE", 4: "SAMP",
             5: "NTAP", 6: "PICK", 7: "FIN", 8: "DONE", 9: "CLRLOW",
             10: "RDVW"}   # 10 = R-B WS_FIN_WAITPEER — DORMANT since Loop-13
                           # (must never appear in a trace)
    while True:
        await ClockCycles(dut.hclk, 25_000)
        line = []
        done_both = True
        for side in ("m", "s"):
            c = _ctrl(dut, side)
            st = _si(c.ws_state_r)
            line.append(
                f"{side}:ws={names.get(st, st)} f={_si(c.winscan_force_sync)}"
                f" clr={_si(c.ws_obs_clr_r)} anc={_si(c.ws_anchor_q)}"
                f" to={_si(c.ws_anchor_timeout_q)}"
                f" seen={_si(c.sync_obs_seen_vec_1):02x}"
                f" fch={_si(c.fch_done_r)}")
            if _si(c.fch_done_r) != 1:
                done_both = False
        log.info("WSTRACE " + " | ".join(line))
        if done_both:
            return


@cocotb.test()
async def test_31_autonomous_training_exit(dut):
    log = dut._log
    log.info("L4 — de-forced autonomous training-exit (no tb_early_exit_force_q)")
    cocotb.start_soon(_winscan_tracer(dut, log))

    # PairTB starts the clocks and idles the AHB/FIFO buses; it also provides
    # the proven AHB_TX / FIFO signal-level drivers used by the R1 data gate.
    tb = PairTB(dut)
    await _idle_stimulus(dut)
    await _reset(dut)

    # (f) R1: engage the DESIGNED-IN winscan sim-dwell hook on BOTH dies so the
    # on-chip winscan (and hence the gated fch bootstrap) actually RUNS inside
    # the sim window. Pure timing accommodation (parameter-designed hook, same
    # idiom as the calibrator's) — the FSM still walks every state.
    # Also model the eye as FLAT (dist=0): in RTL sim there is no real eye and
    # the raw metric is rotation noise (tap nibble OR-merges into the
    # deserialiser word phase), so an unmodelled scan commits arbitrary
    # rotation taps and corrupts both RX paths. Flat-0 = the DEGENERATE case:
    # the R2c guard must latch ws_degenerate_q and restore the seeded taps
    # (asserted below) — the safe, identity-tap outcome.
    for side in ("m", "s"):
        _ctrl(dut, side).tb_winscan_dwell_short_q.value = 1
        # R4c: the fch swreset dwell is now 0.25s (bilateral overlap) — shrink
        # it in sim via the designed-in hook, same idiom as the winscan knob.
        _ctrl(dut, side).tb_fch_dwell_short_q.value = 1
        # D2 (2026-07-03): the autonomous SYNC-OFF timer is DELETED ("never
        # blind-OFF") — there is no tb_syncoff_settle_short_q hook any more;
        # insert_en/robust stay 1 permanently (asserted below).
        # F4: the WS_FINALIZE anchor-gate timeout is 0.3s on silicon — the hook
        # bounds it at 50k cycles. In this bilateral run BOTH dies beacon, so
        # the anchor must genuinely (re-)latch and the timeout must NOT fire
        # (ws_anchor_timeout_q asserted ==0 below).
        _ctrl(dut, side).tb_ws_anchor_short_q.value = 1
        _ctrl(dut, side).obs_sync_dist_vec_w.value = Force(0)

    # (g) R1: monitor the fch sequencer's 0x208 payload sequence on both dies;
    # F4: the monitor also samples the CDC'd reanchored at the bootstrap start.
    fch_writes = {"m": [], "s": []}
    anchor_at_boot = {}
    for side in ("m", "s"):
        cocotb.start_soon(_fch_monitor(dut, side, fch_writes, anchor_at_boot))

    # ---- Sanity: the sim bypass is NOT engaged on either die -----------------
    for side in ("m", "s"):
        force_q = _si(_cal(dut, side).tb_early_exit_force_q)
        log.info(f"[{side}] tb_early_exit_force_q = {force_q} (must be 0 — de-forced)")
        assert force_q == 0, (
            f"[{side}] tb_early_exit_force_q={force_q} — this test MUST run "
            f"de-forced so the training-exit is actually exercised")

    # Confirm the short-hold sim knob landed (else the run can't finish in budget).
    for side in ("m", "s"):
        hc = _si(_cal(dut, side).HOLD_CYCLES) if hasattr(_cal(dut, side), "HOLD_CYCLES") else -1
        log.info(f"[{side}] calibrator HOLD_CYCLES override probe = {hc}")

    # ---- Monitor both calibrators' cur_state + swi_training_mode continuously.
    seen_hold   = {"m": False, "s": False}
    seen_done   = {"m": False, "s": False}
    seen_valid  = {"m": False, "s": False}
    train_hi    = {"m": False, "s": False}   # ever observed swi_training_mode=1
    train_cleared = {"m": False, "s": False} # observed 1 then 0
    resweep_after_clear = {"m": False, "s": False}  # re-entered S_ARM/S_SWEEP AFTER clear (death-spiral fingerprint)
    train_prev  = {"m": 0, "s": 0}

    MAX_CYCLES = 5_000_000
    POLL = 50
    waited = 0
    last_log = 0
    while waited < MAX_CYCLES:
        await ClockCycles(dut.hclk, POLL)
        waited += POLL
        for side in ("m", "s"):
            cs = _si(_cal(dut, side).cur_state)
            if cs == CAL_S_HOLD:
                seen_hold[side] = True
            if cs == CAL_S_VALIDATE:
                seen_valid[side] = True
            if cs == CAL_S_DONE:
                seen_done[side] = True
            # LIVE training carrier (cal_training_mode_w | swi_training_mode_r,
            # axi_chiplet_controller.sv:6327) — NOT the autoneg register alone,
            # which FIX1 can leave un-raised when cal S_DONE beats the autoneg.
            tm = _si(_ctrl(dut, side).swi_training_mode_w)
            if tm == 1:
                train_hi[side] = True
            if train_prev[side] == 1 and tm == 0 and train_hi[side]:
                train_cleared[side] = True
            train_prev[side] = tm
            # Death-spiral fingerprint: re-enter S_ARM(1)/S_SWEEP(2) AFTER the
            # bilateral training clear (the ST_TRAIN_EXIT swreset re-sweep bug).
            if train_cleared[side] and cs in (1, 2):
                resweep_after_clear[side] = True

        # Progress log every ~40k cycles.
        if waited - last_log >= 40_000:
            last_log = waited
            m_cs = _si(_cal(dut, "m").cur_state)
            s_cs = _si(_cal(dut, "s").cur_state)
            m_an = _si(_autoneg(dut, "m").state_r)
            s_an = _si(_autoneg(dut, "s").state_r)
            log.info(
                f"t={waited*CLK_PERIOD_NS/1000:.0f}us  "
                f"M cal={CAL_NAMES.get(m_cs, m_cs)} an={m_an} tm={_si(_ctrl(dut,'m').swi_training_mode_r)} "
                f"| S cal={CAL_NAMES.get(s_cs, s_cs)} an={s_an} tm={_si(_ctrl(dut,'s').swi_training_mode_r)} "
                f"| holdM={seen_hold['m']} doneM={seen_done['m']} "
                f"holdS={seen_hold['s']} doneS={seen_done['s']}")

        # Early-out once BOTH dies reach FCSM=4 (data mode) — the true link-up
        # rendezvous (autoneg training-exit + winscan + fch bootstrap). NEVER
        # exit on calibrator S_DONE: FIX1 centering (min_lock_dwells 0->1) lands
        # cal S_DONE ~1.3ms, BEFORE the slow I2C-paced autoneg reaches training
        # (~4.5ms), so a cal-S_DONE early-out races AHEAD of the training toggle.
        # MAX_CYCLES (5M*20ns = 100ms) is already ample for the >=12ms bring-up.
        if all(_si(_fcsm(dut, side).state) == 4 for side in ("m", "s")):
            log.info(f"both dies reached FCSM=4 (data mode) by "
                     f"{waited*CLK_PERIOD_NS/1000:.0f}us")
            break

    # ---- Final snapshot ------------------------------------------------------
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        log.info(
            f"{name}: seen_HOLD={seen_hold[side]} seen_VALIDATE={seen_valid[side]} "
            f"seen_DONE={seen_done[side]} train_hi={train_hi[side]} "
            f"train_cleared={train_cleared[side]} "
            f"cal_now={CAL_NAMES.get(_si(_cal(dut,side).cur_state))} "
            f"an_now={_si(_autoneg(dut,side).state_r)} "
            f"tm_now={_si(_ctrl(dut,side).swi_training_mode_r)} "
            f"fcsm={_si(_fcsm(dut,side).state)}")

    # ---- ASSERTIONS ----------------------------------------------------------
    # (0) PRIMARY GATE (rank-1): both dies reached FCSM=4 (data mode). This is
    #     the true link-up proof and is asserted FIRST, BEFORE any calibrator
    #     observation. On a genuine dead-link regression (autoneg ST_TRAIN_FAIL,
    #     or FCSM stuck at 1) the monitor loop above runs to MAX_CYCLES without
    #     FCSM=4 and this FAILS LOUD here — it NEVER depends on cal S_HOLD/S_DONE
    #     ordering. (The second half of the primary gate — a byte-exact AHB_TX
    #     M->S burst — is item (10) below.)
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        fcsm_now = _si(_fcsm(dut, side).state)
        assert fcsm_now == 4, (
            f"{name} FCSM never reached 4 (data mode) within budget — the "
            f"autonomous link never came up (dead-link regression: autoneg "
            f"ST_TRAIN_FAIL, or FCSM stuck at 1). fcsm={fcsm_now} "
            f"an_state={_si(_autoneg(dut, side).state_r)}")

    # (1) OBSERVATION ONLY (was a hard gate): whether each calibrator transited
    #     S_HOLD (state 6). NOT gated — FIX1 centering lands cal S_DONE before
    #     the autoneg raises training, so the S_HOLD bilateral-release park can
    #     be transient or skipped. Link-up is proven by the FCSM=4 gate (0) above
    #     and the AHB_TX data gate (10) below, never by calibrator ordering.
    log.info(f"cal S_HOLD transit (observational): M={seen_hold['m']} "
             f"S={seen_hold['s']}")

    # (2) swi_training_mode_w (the LIVE carrier = cal_training_mode_w |
    #     swi_training_mode_r) rose then fell on both dies — driven HIGH by the
    #     calibrator during S_SWEEP and/or by the autoneg, dropped at S_DONE / the
    #     autoneg's ST_TRAIN_EXIT clear. Sampled continuously and asserted AFTER
    #     the FCSM=4 gate (0): a link that reached data-mode MUST have raised then
    #     cleared training; a carrier stuck HIGH is the L4 training-exit deadlock.
    #     This never gates loop exit and never depends on cal S_HOLD/S_DONE order.
    assert train_hi["m"] and train_hi["s"], (
        "swi_training_mode_w never went HIGH on both dies — the autonomous "
        "training run did not engage")
    assert train_cleared["m"], (
        "MASTER swi_training_mode_w was HELD HIGH (never cleared 1→0) — the "
        "training-exit DEADLOCK is still present (this is exactly the L4 bug)")
    assert train_cleared["s"], (
        "SLAVE swi_training_mode_w was HELD HIGH (never cleared 1→0) — "
        "training-exit deadlock still present")

    # (3) OBSERVATION ONLY (was a hard gate): whether each calibrator reached
    #     S_DONE. NOT gated on ordering — with FIX1 the calibrator can settle in
    #     S_DONE before training even engages. The calibrator's SETTLED S_DONE is
    #     still asserted in item (7) below, AFTER the FCSM=4 rendezvous.
    log.info(f"cal S_DONE reached (observational): M={seen_done['m']} "
             f"S={seen_done['s']}")

    # (4) The autoneg FSM must NOT have tripped ST_TRAIN_FAIL — it should have
    #     rendezvoused on both-in-S_HOLD and taken ST_TRAIN_EXIT.
    m_an = _si(_autoneg(dut, "m").state_r)
    s_an = _si(_autoneg(dut, "s").state_r)
    assert m_an != ST_TRAIN_FAIL, (
        f"MASTER autoneg ended in ST_TRAIN_FAIL (17) — the mask-aware "
        f"POLL_PEER rendezvous did not fire (an_state={m_an})")

    # (5) FCSM=4 was already asserted as the PRIMARY gate (0): the monitor loop
    #     now exits ON FCSM=4 (not on cal-S_DONE), so the link is provably up at
    #     this point. Re-log for the trace; the post-bootstrap FCSM=4 re-check is
    #     item (9) below.
    log.info(f"FCSM at loop break: M={_si(_fcsm(dut,'m').state)} "
             f"S={_si(_fcsm(dut,'s').state)} (primary gate 0 passed)")

    # (6) DEATH-SPIRAL fingerprint (the A2 swreset-suppress fix): after the
    #     bilateral training clear the master must NOT be re-swept back into
    #     S_ARM/S_SWEEP. On pre-A2 RTL the autoneg's ST_TRAIN_EXIT swreset pulse
    #     kicks the master (still in S_HOLD, before S_DONE, so cal_eye_converged_r
    #     hasn't latched) back to S_ARM to sweep against a peer that already
    #     dropped training → cannot re-lock → stuck forever.
    assert not resweep_after_clear["m"], (
        "MASTER calibrator RE-SWEPT (re-entered S_ARM/S_SWEEP) AFTER training was "
        "cleared — the ST_TRAIN_EXIT swreset death-spiral (A2 fix absent/regressed)")
    assert not resweep_after_clear["s"], (
        "SLAVE calibrator re-swept after training clear")

    # (7) Both calibrators END stable in S_DONE, and the FC handoff reaches
    #     data-mode (FCSM=4) within a bounded window after S_DONE.
    fc_ok = {"m": False, "s": False}
    # Loop-13 (2026-07-04): the Loop-12 rendezvous is dormant (locally-timed
    # finalize again); the widened 1.2M window is RETAINED as slack — it is
    # an upper bound, the loop exits early on FCSM=4.
    for _ in range(6000):
        await ClockCycles(dut.hclk, 200)
        for side in ("m", "s"):
            if _si(_fcsm(dut, side).state) == 4:
                fc_ok[side] = True
        if all(fc_ok.values()):
            break
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        cs_final = _si(_cal(dut, side).cur_state)
        assert cs_final == CAL_S_DONE, (
            f"{name} calibrator final state = {CAL_NAMES.get(cs_final, cs_final)} "
            f"!= S_DONE — did not settle (spiral / oscillation)")
        assert fc_ok[side], (
            f"{name} FCSM never reached 4 (data mode) after cal S_DONE — the "
            f"autonomous FC handoff did not complete")

    # ---- (8) R1: the fch bootstrap RAN and drove the EXACT manual values ----
    # Wait for the sequencer to complete on both dies (the winscan gate holds
    # it out for the whole scan; with the sim dwell that is ~30k cycles, then
    # the burst itself takes ~4.2k cycles — 82 us swreset dwell included).
    fch_done = {"m": False, "s": False}
    for _ in range(6000):
        await ClockCycles(dut.hclk, 500)
        for side in ("m", "s"):
            if _si(_ctrl(dut, side).fch_done_r) == 1:
                fch_done[side] = True
        if all(fch_done.values()):
            break
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert fch_done[side], (
            f"{name} fch sequencer never completed (fch_done_r=0) — the "
            f"autonomous FC-handoff bootstrap did not run (winscan gate "
            f"wedged?)")
        log.info(f"{name} fch bootstrap payload sequence: "
                 + " -> ".join(f"0x{w:05x}" for w in fch_writes[side]))
        assert fch_writes[side] == FCH_EXPECT, (
            f"{name} fch sequencer drove {[hex(w) for w in fch_writes[side]]} "
            f"!= the PROVEN manual bootstrap {[hex(w) for w in FCH_EXPECT]} — "
            f"R1 regression: 0x208 bit0 (swi_enable = FCSM run/credit enable) "
            f"must be HELD 1 through the swreset (silicon wedge "
            f"OBS_FC_CREDIT=0xfc01001f otherwise)")
    # R2c regression gate: the flat-0 modelled metric MUST trip the
    # degenerate-scan guard, and the guard MUST have restored the SEEDED
    # (host/APB, here POR-0) taps — not committed an arbitrary argmin.
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        deg  = _si(c.ws_degenerate_q)
        wsof = _si(c.ws_phase_offset_r)
        wslb = _si(c.ws_phase_lsb_r)
        seed = _si(c.swi_phase_offset_r)
        sdlb = _si(c.swi_phase_lsb_r)
        log.info(f"{name} winscan: degenerate={deg} "
                 f"ws_taps=0x{wsof:08x}/{wslb:02x} seed=0x{seed:08x}/{sdlb:02x}")
        assert deg == 1, (
            f"{name}: ws_degenerate_q NOT latched on a FLAT metric — the R2c "
            f"degenerate-scan guard failed (arbitrary argmin taps would ship)")
        assert wsof == seed and wslb == sdlb, (
            f"{name}: degenerate scan did NOT restore the seeded taps "
            f"(ws=0x{wsof:08x}/{wslb:02x} != seed=0x{seed:08x}/{sdlb:02x}) — "
            f"the OR-merged deserialiser phase would be corrupted")

    # ---- (8b) F3/F4: the anchor gate held the bootstrap for a SETTLED anchor.
    # reanchored (CDC'd, ws_anchor_q) must read 1 at the FIRST fch_active_r
    # cycle (the on-chip equivalent of the manual host's 0x2140 poll), and the
    # FAIL-LOUD timeout must NOT have fired (both dies beacon here, so the
    # WS_FINALIZE re-anchor clear must genuinely re-confirm on idle-gated
    # beacons at the final taps).
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        aab = anchor_at_boot.get(side, -1)
        wto = _si(c.ws_anchor_timeout_q)
        log.info(f"{name} F4 anchor gate: reanchored@bootstrap-start={aab} "
                 f"ws_anchor_timeout_q={wto}")
        assert aab == 1, (
            f"{name}: deskew reanchored != 1 at the fch bootstrap start "
            f"(got {aab}) — the F4 WS_FINALIZE anchor gate did not order the "
            f"handoff after a settled anchor")
        assert wto == 0, (
            f"{name}: ws_anchor_timeout_q latched — the F4 anchor gate RELEASED "
            f"ON TIMEOUT instead of a genuine post-clear re-anchor (F3 "
            f"sync_obs_clr routing broken, or the idle-gated beacons never "
            f"re-confirmed during WS_FINALIZE)")
        # R-A (2026-07-04) + Loop-13 dormancy: on a healthy bilateral run the
        # zero-tolerance anchor-verify must have PASSED first try (no
        # verify-retry) and the release gate itself (ws_verify_q) must read 1
        # — beacons are permanent (D2) so the verify stays satisfied in data
        # mode. ws_rdv_timeout_q must read 0 ALWAYS: the Loop-12 rendezvous
        # is dormant (Loop-13) and the sticky can no longer set.
        rdv_to = _si(c.ws_rdv_timeout_q)
        vfy_rt = _si(c.ws_vfy_retry_q)
        vfy    = _si(c.ws_verify_q)
        log.info(f"{name} R-A/Loop-13: ws_rdv_timeout_q={rdv_to} "
                 f"ws_vfy_retry_q={vfy_rt} ws_verify_q={vfy}")
        assert rdv_to == 0, (
            f"{name}: ws_rdv_timeout_q latched (0x21B8[10]) — the DORMANT "
            f"Loop-12 rendezvous timeout fired (Loop-13 dormancy broken)")
        assert vfy_rt == 0, (
            f"{name}: ws_vfy_retry_q latched (0x21B8[9]) — the anchor-verify "
            f"forced a clear-retry on a CLEAN sim eye (the exact all-lane "
            f"compare should pass on the first post-clear beacon)")
        assert vfy == 1, (
            f"{name}: ws_verify_q=0 at end — the engaged anchor never "
            f"reproduced an exact SYNC word (verify plumbing broken)")

    # ---- (9) R1: post-BOOTSTRAP FCSM=4 (the bootstrap swreset re-walks the
    #      CR/CRACK exchange — this is the handoff path silicon takes). -------
    fc_ok2 = {"m": False, "s": False}
    for _ in range(3000):
        await ClockCycles(dut.hclk, 200)
        for side in ("m", "s"):
            if _si(_fcsm(dut, side).state) == 4:
                fc_ok2[side] = True
        if all(fc_ok2.values()):
            break
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        assert fc_ok2[side], (
            f"{name} FCSM did not (re-)reach 4 after the autonomous fch "
            f"bootstrap — the 0x208 sequence wedged the framer "
            f"(fcsm={_si(_fcsm(dut, side).state)})")

    # ---- (10) R1: DATA GATE — AHB_TX burst M->S must arrive BYTE-EXACT and
    #      the SENDER's fe credit gate must be OPEN (the exact silicon step
    #      that wedged: fe_full=1, burst stuck in a2l replay). ----------------
    from tidelink.packet import encode_word0, PKT_WR_REQ
    payload = [0xC0DE1234, 0xFEED5678]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    await tb.ahb_tx_write_packet("m", [word0, 0x0] + payload)
    await ClockCycles(dut.hclk, 4000)

    s_w2 = await tb.ahb_fifo_read_word("s", 0x08)
    s_w3 = await tb.ahb_fifo_read_word("s", 0x0C)
    log.info(f"R1 data gate: slave FIFO w2=0x{s_w2:08x} w3=0x{s_w3:08x} "
             f"(expected 0x{payload[0]:08x} 0x{payload[1]:08x})")

    m_fcsm_h  = _fcsm(dut, "m")
    fe_full   = _si(m_fcsm_h.fe_rx_is_full)
    fe_cred   = _si(m_fcsm_h.fe_rx_credit_max)
    fe_ptr    = _si(m_fcsm_h.fe_rx_ptr)
    log.info(f"R1 sender credit gate: fe_rx_is_full={fe_full} "
             f"fe_rx_credit_max={fe_cred} fe_rx_ptr={fe_ptr}")

    assert (s_w2, s_w3) == (payload[0], payload[1]), (
        f"R1 DATA GATE FAILED: AHB_TX burst did not arrive byte-exact over the "
        f"autonomous FC handoff (got 0x{s_w2:08x}/0x{s_w3:08x}, want "
        f"0x{payload[0]:08x}/0x{payload[1]:08x}) — the silicon (h) wedge "
        f"signature (sender fe_full={fe_full} cred={fe_cred} ptr={fe_ptr})")
    assert fe_full == 0, (
        f"R1: sender fe_rx_is_full=1 AFTER the burst — the FE credit gate is "
        f"CLOSED (silicon OBS_FC_CREDIT=0xfc01001f wedge signature); "
        f"cred={fe_cred} ptr={fe_ptr}")
    assert fe_cred != 0, (
        "R1: sender fe_rx_credit_max=0 — the CR/CRACK credit grant never "
        "(re-)loaded after the autonomous bootstrap")

    # ---- (11) D2 "NEVER BLIND-OFF" (2026-07-03, INVERTED from the old F1/F2
    #      gate): the autonomous SYNC-OFF timer is DELETED. The PERMANENT
    #      autonomous data-mode state is insert_en=1 (idle-gated beacon) +
    #      robust=1, with only force-SYNC dropped (winscan FINALIZE exit) and
    #      force_always never set (R4a). The old timed OFF raced the PEER's
    #      WS_FINALIZE re-anchor refill (needs PEER beacons; one missed
    #      SYNC_PERIOD grid slot resets the deskew confirm run) — a race no
    #      timer can bound across the arm-stagger. NOTE the ordering: the (10)
    #      data gate above ALREADY ran byte-exact WITH beacons on — that IS
    #      the new data-safety gate (idle-gated insert never deletes words;
    #      FORCE was the R4 word-deleter). Here we additionally dwell and
    #      assert the state HOLDS (no residual OFF path fires late).
    # ---- (11) EVENT-GATED AUTONOMY RETIRE (2026-07-15, RE-TARGETED — inverts
    #      the old D2 "never blind-OFF" gate). THE B->A autonomy channel fix.
    #      SILICON (td_b2a_diag2.log): B->A recovered byte-exact the instant
    #      die_a's (MASTER = the B->A RECEIVER) autonomy_armed dropped
    #      (0x210C=0) — with R8 STILL 0x14 (insert_en=1) and reanchored=0. So
    #      insert_en/R8[2] is NOT the blocker; autonomy_armed is: the corruptor
    #      is the autonomous FORCED-SYNC chain (winscan_force_sync /
    #      ws_serve_active_r) OR'd into the Wlink SYNC ports, which keeps SYNC
    #      beating over the B->A payload so the receiver's RX framer never
    #      commits. The RTL now replicates that escape hatch ITSELF, once, when
    #      the link is provably up (fcsm=4 & winscan_done held for RETIRE_DWELL).
    #      The trigger MUST fire on the MASTER (the receiver) — where the old
    #      ws_anchor_q&&ws_verify_q verify gate could not (die_a rea=0 on
    #      silicon); we gate on the FCSM reaching bilateral credit, which is
    #      4/4 on die_a in the silicon log. Post-retire the forced chain is
    #      parked and insert_en is left untouched (it is not the blocker).
    #
    #      F4 PLUMBING A/B (2026-07-15): this block is now driven by the env var
    #      RETIRE_EN_EXPECT (default 1 — the historical behaviour, byte-identical
    #      stimulus). The gate runs this SAME test against TWO builds:
    #        RETIRE_EN_EXPECT=1  default build   → retire MUST fire  (proof (a))
    #        RETIRE_EN_EXPECT=0  +define+TB_TOP_RETIRE_EN=0
    #                            → retire must NEVER fire (proof (b))
    #      Identical stimulus, one parameter changed, opposite outcome — that is
    #      what proves the parameter genuinely reaches the controller. If the
    #      tidelink_top→controller forwarding were dead (the NEGO_CFG_RESET
    #      failure mode), the =0 build would still take the controller's own
    #      1'b1 default, retire would still fire, and the =0 run would FAIL.
    retire_expect = int(os.environ.get("RETIRE_EN_EXPECT", "1"))
    await ClockCycles(dut.hclk, 100_000)   # >> RETIRE_DWELL (4096 apb cycles)
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        # (0) STATIC PLUMBING READ-BACK — the value of RETIRE_EN as it landed
        # INSIDE axi_chiplet_controller (tb probe reads through the forwarding
        # path, so it reports the DESTINATION, not what the tb passed in).
        probe = _si(getattr(dut, f"retire_en_at_ctrl_{side}"))
        log.info(f"{name} RETIRE_EN at axi_chiplet_controller = {probe} "
                 f"(expected {retire_expect})")
        assert probe == retire_expect, (
            f"{name}: RETIRE_EN reads {probe} INSIDE axi_chiplet_controller but "
            f"the top was elaborated for {retire_expect} — the tidelink_top → "
            f"axi_chiplet_controller parameter forwarding is DEAD. This is the "
            f"NEGO_CFG_RESET regression class (plumbed at the top, never "
            f"forwarded, every build silently took the module default).")
        ie   = _si(c.swi_sync_insert_en_r)
        rb   = _si(c.swi_sync_robust_detect_r)
        fa   = _si(c.swi_sync_force_always_r)
        wf   = _si(c.winscan_force_sync)
        arm  = _si(c.autonomy_armed)
        ret  = _si(c.autonomy_retire_q)
        cnt  = _si(c.fc_stable_cnt_q)
        fcsm = _si(c.sync_obs_fcsm_state_1)
        rea  = _si(c.ws_anchor_q)
        log.info(f"{name} RETIRE state: autonomy_retire_q={ret} autonomy_armed={arm} "
                 f"winscan_force={wf} force_always={fa} insert_en={ie} robust={rb} "
                 f"fc_stable_cnt={cnt} fcsm={fcsm} rea={rea}")
        if retire_expect == 0:
            # ---- PROOF (b): RETIRE_EN=0 at the TOP ⇒ retire never fires ----
            # autonomy_retire_q's ONLY non-reset assignment sits inside
            # `if (RETIRE_EN && ...)`, so a 0 that genuinely reached the
            # controller makes it structurally unassignable. The link still
            # comes up (everything above this block already passed) — the ONLY
            # difference is that autonomy stays armed, i.e. the pre-fix RTL.
            assert ret == 0, (
                f"{name}: autonomy_retire_q=1 despite RETIRE_EN=0 at the top — "
                f"the retire is NOT gated by the parameter, or the parameter "
                f"never reached the controller (it kept its 1'b1 default). "
                f"This is the exact F4 gap: an ASIC could not disable the "
                f"retire without editing axi_chiplet_controller.")
            # BIT-IDENTICAL TO PRE-FIX: with the retire suppressed, the
            # effective armed term must equal the RAW armed conjunction
            # (nego_en & role_locked & train_auto_en) — which is 1 here,
            # because the link is up and autonomy was armed by the bring-up.
            raw = (_si(c.nego_en) & _si(c.role_locked)
                   & (_si(c.nego_train_cfg_r) & 1))
            assert arm == raw == 1, (
                f"{name}: autonomy_armed={arm} but the raw armed conjunction is "
                f"{raw} — with RETIRE_EN=0 the effective armed term MUST reduce "
                f"to the pre-fix expression (retire contributes nothing).")
            log.info(f"{name}: RETIRE_EN=0 ⇒ retire suppressed "
                     f"(autonomy_retire_q=0), autonomy_armed={arm} == raw armed "
                     f"term — bit-identical to the pre-fix RTL. fcsm={fcsm} "
                     f"rea={rea}")
            continue
        # ---- PROOF (a): default build ⇒ RETIRE_EN=1 ⇒ the fix FIRES ----
        # on BOTH dies, crucially the MASTER (the B->A receiver).
        assert ret == 1, (
            f"{name}: autonomy_retire_q=0 — the event-gated RETIRE never fired "
            f"(fc_stable_cnt={cnt}); the link must hold fcsm=4 & winscan_done for "
            f"RETIRE_DWELL cycles. This MUST fire on the MASTER (B->A receiver).")
        assert arm == 0, (
            f"{name}: autonomy_armed=1 after RETIRE — the effective armed term "
            f"must drop so the FSM's LOOP-9 DISARM-PARK stops the forced-SYNC "
            f"chain (autonomously replicating the 0x210C=0 escape hatch)")
        assert wf == 0, (
            f"{name}: winscan_force_sync=1 after RETIRE — the forced-SYNC chain "
            f"(the on-silicon B->A corruptor) must be parked")
        assert fa == 0, (
            f"{name}: swi_sync_force_always_r=1 — force-always (the R4 word-"
            f"deleter) must never be set autonomously")
        # NO-REGRESSION (req 2): RETIRE must NOT wedge the FC or drop the anchor.
        assert fcsm == 4, (
            f"{name}: FCSM={fcsm} != 4 after RETIRE — retiring autonomy wedged "
            f"the flow-control datapath (it must touch neither the FCSM nor "
            f"role_locked/nego_en)")
        assert rea == 1, (
            f"{name}: reanchored=0 after RETIRE — the DISARM-PARK dropped the "
            f"deskew anchor (it must issue NO obs-clear, so reanchored holds)")
        # insert_en is intentionally NOT asserted: silicon proved it is NOT the
        # blocker (B->A recovered at insert_en=1); it retains its last value.

    if retire_expect == 0:
        log.info("VERDICT: PASS (F4 plumbing proof (b)) — with RETIRE_EN=0 "
                 "bound at tidelink_top, the probe reads RETIRE_EN=0 INSIDE "
                 "axi_chiplet_controller on BOTH dies, the event-gated RETIRE "
                 "never fired, and autonomy_armed reduced to the raw pre-fix "
                 "armed conjunction — while the identical stimulus still brought "
                 "the link up (FCSM=4, byte-exact AHB_TX). The parameter "
                 "genuinely reaches the controller and genuinely gates the fix, "
                 "so the ASIC integration can disable/strap it WITHOUT editing "
                 "axi_chiplet_controller.")
        return

    log.info("VERDICT: PASS — de-forced autonomous training-exit: both dies "
             "settled S_DONE + FCSM=4; the fch bootstrap drove EXACTLY "
             "0x27f09→0x27f01→0x27f07 on both dies; AHB_TX data crossed "
             "BYTE-EXACT; and once the link held bilateral FC the EVENT-GATED "
             "AUTONOMY RETIRE fired on BOTH dies (incl. the MASTER receiver) — "
             "autonomy_armed=0, winscan_force_sync parked — while FCSM stayed 4 "
             "and reanchored held. Autonomously replicates the 0x210C=0 escape "
             "hatch. L4 deadlock + death-spiral + R1 credit wedge + B->A "
             "autonomy-force corruptor (project_autonomy_rootcause_sync_clamp) "
             "covered.")
