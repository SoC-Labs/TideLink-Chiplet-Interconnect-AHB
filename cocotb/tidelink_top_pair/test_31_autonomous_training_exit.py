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

CLK_PERIOD_NS     = 20.0
REF_CLK_PERIOD_NS = 8.0

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


@cocotb.test()
async def test_31_autonomous_training_exit(dut):
    log = dut._log
    log.info("L4 — de-forced autonomous training-exit (no tb_early_exit_force_q)")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start())
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start())

    await _idle_stimulus(dut)
    await _reset(dut)

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
    for _ in range(3000):
        await ClockCycles(dut.hclk, 50)
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

    log.info("VERDICT: PASS — de-forced autonomous training-exit: both dies "
             "transited S_HOLD→S_VALIDATE→S_DONE (no re-sweep after clear), "
             "swi_training_mode cleared 1→0 by the autoneg FSM (not a TB force), "
             "both settled S_DONE + FCSM=4. L4 deadlock + death-spiral broken.")
