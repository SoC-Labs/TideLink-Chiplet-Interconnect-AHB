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
            tm = _si(_ctrl(dut, side).swi_training_mode_r)
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

        # Early-out once BOTH dies have transited hold and reached done.
        if all(seen_hold.values()) and all(seen_done.values()):
            log.info(f"both dies transited S_HOLD → S_DONE by "
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
    # (1) THE key NEW assertion: both calibrators actually PASSED THROUGH S_HOLD
    #     (state 6) — the reachable rendezvous the fix targets.
    assert seen_hold["m"], (
        "MASTER calibrator NEVER entered S_HOLD (state 6) — the training sweep "
        "did not converge; the de-forced flow is broken upstream of the fix")
    assert seen_hold["s"], (
        "SLAVE calibrator NEVER entered S_HOLD (state 6)")

    # (2) swi_training_mode_r rose then fell on both dies — driven by the autoneg
    #     FSM's local_train_clr_pulse at ST_TRAIN_EXIT, NOT a TB force.
    assert train_hi["m"] and train_hi["s"], (
        "swi_training_mode_r never went HIGH on both dies — the autonomous "
        "training run did not engage")
    assert train_cleared["m"], (
        "MASTER swi_training_mode_r was HELD HIGH (never cleared 1→0) — the "
        "training-exit DEADLOCK is still present (this is exactly the L4 bug)")
    assert train_cleared["s"], (
        "SLAVE swi_training_mode_r was HELD HIGH (never cleared 1→0) — "
        "training-exit deadlock still present")

    # (3) Having cleared training, the S_HOLD gate opens and both calibrators
    #     advance to S_DONE (cal_done=1). PROVES the S_HOLD→S_VALIDATE→S_DONE
    #     transit happened because the FSM cleared training, not a bypass.
    assert seen_done["m"], (
        "MASTER calibrator never reached S_DONE after S_HOLD — the S_HOLD gate "
        "never opened (swi_training_mode_r not cleared bilaterally)")
    assert seen_done["s"], (
        "SLAVE calibrator never reached S_DONE after S_HOLD")

    # (4) The autoneg FSM must NOT have tripped ST_TRAIN_FAIL — it should have
    #     rendezvoused on both-in-S_HOLD and taken ST_TRAIN_EXIT.
    m_an = _si(_autoneg(dut, "m").state_r)
    s_an = _si(_autoneg(dut, "s").state_r)
    assert m_an != ST_TRAIN_FAIL, (
        f"MASTER autoneg ended in ST_TRAIN_FAIL (17) — the mask-aware "
        f"POLL_PEER rendezvous did not fire (an_state={m_an})")

    # (5) FCSM is asserted AFTER the handoff window in (7) below. At this loop
    #     break the calibrators have only just reached S_DONE and the autonomous
    #     FC handoff (FCCTRL drive on training-clear) has not completed yet, so
    #     FCSM is legitimately still 1 here — do NOT assert on it at this instant.
    log.info(f"FCSM at cal-S_DONE break: M={_si(_fcsm(dut,'m').state)} "
             f"S={_si(_fcsm(dut,'s').state)} (handoff pending; asserted below)")

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

    # ---- (11) AUTONOMOUS SYNC-OFF at the verified+held anchor (2026-07-15,
    #      INVERTED from the old D2 "never blind-OFF" gate, which ENSHRINED the
    #      B->A autonomy channel bug: it asserted insert_en==1 in data mode and
    #      called insert_en=0 a "D2 REGRESSION", while the RTL that pins
    #      insert_en=1 is precisely what dead-locks the receiver on silicon).
    #
    #      SILICON PROOF (project_autonomy_rootcause_sync_clamp_2026_07_14,
    #      project_drainguard_necessary_not_sufficient_b2a_residual_2026_07_14):
    #      under autonomy_armed the D2 heal re-drove swi_sync_insert_en_r=1 every
    #      cycle — textually LATER than the APB R8 decode in the SAME always_ff,
    #      so NBA last-write-wins pinned R8-effective at 0x14. At 0x14 die_a (the
    #      MASTER = the B->A RECEIVER) CAPTURES incoming words (RXCAP proven) but
    #      NEVER COMMITS them to the GP1 app FIFO (B->A 0/10 on fresh-POR silicon;
    #      disarming 0x210C=0 -> B->A byte-exact IMMEDIATELY, credit was fine).
    #      The sim TB is BLIND to that beacon-substitution / RX-commit-hold (it
    #      delivered clean data with the corrupting RTL) — which is exactly why
    #      the OLD assertion "proved" the wrong thing.
    #
    #      The fix event-gates a STICKY SYNC-OFF one-shot (sync_off_done_q) on
    #      the winscan's OWN verified+held anchor (ws_anchor_q && ws_verify_q, the
    #      exact WS_FINALIZE release gate). Post-anchor the autonomous data-mode
    #      state must land on R8-effective 0x10 (insert_en=0, hold released) — the
    #      config the manual recipe uses, PROVEN 40/40 all-channels byte-exact.
    #      robust STAYS 1 (deskew re-hunt / drift self-heal). force_always and
    #      winscan_force_sync (the SCAN beacons, OR'd separately at the Wlink
    #      ports) stay 0 in data mode (force drops at the FINALIZE exit).
    await ClockCycles(dut.hclk, 100_000)   # >> the retired 1024-cycle settle
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        ie   = _si(c.swi_sync_insert_en_r)
        rb   = _si(c.swi_sync_robust_detect_r)
        fa   = _si(c.swi_sync_force_always_r)
        wf   = _si(c.winscan_force_sync)
        hq   = _si(c.sync_cfg_hold_q)
        anc  = _si(c.ws_anchor_q)
        vfy  = _si(c.ws_verify_q)
        offd = _si(c.sync_off_done_q)
        log.info(f"{name} SYNC-OFF data-mode state: insert_en={ie} robust={rb} "
                 f"force_always={fa} winscan_force={wf} hold={hq} "
                 f"anchor={anc} verify={vfy} sync_off_done={offd}")
        assert offd == 1, (
            f"{name}: SYNC-OFF one-shot NEVER latched (sync_off_done_q=0) — the "
            f"verified+held anchor (ws_anchor_q && ws_verify_q) was never reached "
            f"in data mode (anchor={anc} verify={vfy}). Either the fix regressed "
            f"anchoring or the FSM never released FINALIZE.")
        assert ie == 0, (
            f"{name}: swi_sync_insert_en_r=1 in data mode — the SYNC-OFF one-shot "
            f"must strip the idle beacon at the verified anchor. SILICON: R8=0x14 "
            f"pins die_a's RX-commit (B->A 0/10); the autonomous steady state must "
            f"land on R8-effective 0x10 (recipe config, 40/40 byte-exact). "
            f"project_autonomy_rootcause_sync_clamp_2026_07_14")
        assert hq == 0, (
            f"{name}: sync_cfg_hold_q=1 in data mode — the D2 heal must RELEASE at "
            f"the verified anchor so it stops re-clamping insert_en to 1")
        assert rb == 1, (
            f"{name}: swi_sync_robust_detect_r=0 — robust must STAY 1 (tol-5 framer "
            f"re-hunt / drift self-heal); the SYNC-OFF fix keeps robust/tol/mask")
        assert fa == 0, (
            f"{name}: swi_sync_force_always_r=1 in data mode — force-always is the "
            f"R4 word-deleter and must NEVER be set autonomously")
        assert wf == 0, (
            f"{name}: winscan_force_sync still 1 after FINALIZE — force must drop "
            f"at the FINALIZE exit")

    # ---- (11b) NO SYNC BEACON is inserted while data is flowing (2026-07-15).
    #      Per the sync-clamp note: a beacon launched into a packet substitutes a
    #      0 for a payload word (the silicon (h) garble). With insert_en=0 and
    #      force_always=0 the TX inserter (tx_sync_en_w) is dead, so the TX
    #      sync-insert count must be FROZEN across a steady data-mode dwell. This
    #      is the sim-observable proxy for "tx_sync_ins_cnt does not increment
    #      while a packet is in flight" — the TB cannot model the RX substitution,
    #      but it CAN prove the inserter has stopped firing.
    for side, name in (("m", "MASTER"), ("s", "SLAVE")):
        c = _ctrl(dut, side)
        cnt0 = _si(c.obs_tx_sync_ins_cnt_w)
        await ClockCycles(dut.hclk, 20_000)
        cnt1 = _si(c.obs_tx_sync_ins_cnt_w)
        log.info(f"{name} TX sync-insert count over data-mode dwell: "
                 f"{cnt0} -> {cnt1}")
        assert cnt1 == cnt0, (
            f"{name}: tx_sync_ins_cnt incremented in data mode ({cnt0}->{cnt1}) "
            f"AFTER the SYNC-OFF one-shot — a beacon launched into a live packet "
            f"substitutes a payload word (the silicon (h) garble). The inserter "
            f"must be idle once insert_en=0 & force_always=0.")

    log.info("VERDICT: PASS — de-forced autonomous training-exit: both dies "
             "transited S_HOLD→S_VALIDATE→S_DONE (no re-sweep after clear), "
             "swi_training_mode cleared 1→0 by the autoneg FSM (not a TB force), "
             "both settled S_DONE + FCSM=4; the fch bootstrap drove EXACTLY "
             "0x27f09→0x27f01→0x27f07 on both dies; post-bootstrap FCSM=4; "
             "AHB_TX data crossed BYTE-EXACT; and at the verified+held anchor the "
             "SYNC-OFF one-shot LATCHED (sync_off_done_q=1), stripping insert_en "
             "to land on R8-effective 0x10 (recipe config) with the TX inserter "
             "FROZEN in data mode. L4 deadlock + death-spiral + R1 credit wedge "
             "+ B->A SYNC-clamp (project_autonomy_rootcause_sync_clamp) covered.")
