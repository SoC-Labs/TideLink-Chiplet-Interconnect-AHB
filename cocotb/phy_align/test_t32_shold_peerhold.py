"""T3.2 S_HOLD peer-aware-training-hold validator + negative control.

WHAT T3.2 IS (commit d69be51, src/rtl/tidelink_phy_align_calibrator.sv)
-----------------------------------------------------------------------

On real HW the two chiplets' `role_lock` assert ms apart (SSH-staggered
fpga_manager loads). With the T3 continuous-resweep fix (commit b248148)
both nodes keep re-sweeping with `training_mode` high until their windows
overlap and a sweep finally locks all lanes (`sweep_success = ~|lane_fault_q`).
But pre-T3.2, the FIRST node to reach a genuinely all-locked sweep took
`S_FINISH → S_DONE` *immediately*: `calibration_done` rose, `training_mode`
dropped, and its TX training pattern vanished — abandoning the still-skewed
peer mid-convergence (an HW-confirmed first-to-succeed deadlock).

T3.2 inserts a new FSM state **S_HOLD = 4'd6**. On `sweep_success`,
`S_FINISH` now goes to `S_HOLD` (NOT straight to `S_DONE`). S_HOLD keeps
`training_mode = 1` and `calibration_done = 0` for `HOLD_CYCLES` calibrator
clocks (param, default `8*128*DWELL_CYCLES`), so the first-to-succeed node
keeps feeding the peer a continuous training pattern long enough for the
skew-delayed peer to ALSO reach `sweep_success`; only then does S_HOLD →
S_DONE (`calibration_done` rises late). Output equations changed to
`training_mode = S_ARM || S_SWEEP || S_HOLD` and
`calibration_done = (S_DONE only)`.

THE DISCRIMINATOR (model-independent, FSM-level)
------------------------------------------------

This `tb_top` cannot model full mutual HW convergence (see the sibling
test cocotb/phy_align/test_t3_staggered_lottery.py), so — exactly like
that test — we assert the robust FSM-level signature that *is* precisely
the committed RTL change, not an end-to-end "both converge" outcome.

Scenario: SKID_BITS=3 (uniform per-lane skid that the calibrator's
slip/phase sweep fully corrects), autocal force-enabled on both sides via
the `autocal_force_enable_q` hierarchical hook, both role-locked. Every
lane locks within one sweep on BOTH sides → `lane_fault==0x00` →
`sweep_success` is genuinely true (no faults — the *success* branch, the
opposite of test_t3_staggered_lottery's all-stuck fault branch).

  * T3.2 PASS  : after the sweep completes the calibrator enters
                 **S_HOLD** — observable as `cal_state_w == 6` with
                 `training_mode == 1` AND `calibration_done == 0`,
                 and that (state==6, train==1, done==0) condition is held
                 CONTINUOUSLY for a long bounded window
                 (HOLD_WINDOW_APB apb cycles, >> the 1-cycle S_FINISH and
                 >> a full sweep, but << the default ~524288-apb-cycle
                 HOLD_CYCLES). `calibration_done` does NOT rise within the
                 window — it only rises *later*, when S_HOLD eventually
                 times out to S_DONE (proven structurally by the RTL's
                 `hold_ctr >= HOLD_MAX → S_DONE` edge; see "Modelling
                 limitation" below for why we do not burn the full
                 ~0.5 M-cycle hold in sim).

  * PRE-T3.2 FAIL (negative control, parent commit 797aa64): there is no
                 S_HOLD state at all (max state is S_CANCEL=5) and
                 `S_FINISH` on `sweep_success` goes straight to `S_DONE`,
                 so right after the sweep `calibration_done` is 1,
                 `training_mode` is 0, and `cal_state_w` is 4 — `state==6`
                 NEVER occurs and the peer-hold window is absent. The
                 `state==6 / training_mode==1 / done==0` assertion fires.

Negative control procedure (verified PASS → FAIL → PASS):
  git -C <repo> show 797aa64:src/rtl/tidelink_phy_align_calibrator.sv \
      > src/rtl/tidelink_phy_align_calibrator.sv
  rm -rf cocotb/wlink_pair/sim_build ; re-run  → THIS TEST MUST FAIL
  git -C <repo> checkout src/rtl/tidelink_phy_align_calibrator.sv
  rm -rf cocotb/wlink_pair/sim_build ; re-run  → PASSES again

Invocation (from cocotb/phy_align/):
    make MODULE=test_t32_shold_peerhold SKID_BITS=3

MODELLING LIMITATION + WORKAROUND
---------------------------------

The default HOLD_CYCLES = 8*128*DWELL_CYCLES = 32768 calibrator (link)
clocks ≈ 524288 apb cycles (the calibrator clock is the recovered RX link
clock, pad_clk/16, and pad_clk == apb_clk here). The calibrator is
instantiated *without* a parameter override inside the in-`deps/`
axi_chiplet_controller (`tidelink_phy_align_calibrator u_calibrator (...)`,
no `#(...)`), and that file is out of scope to edit, so HOLD_CYCLES cannot
be shrunk through the TB's parameter mechanism. Running the full hold to
observe the late S_DONE would cost ~0.5 M apb cycles of sim per run × the
3-run PASS/FAIL/PASS cycle. Instead — exactly as the task statement
permits — we assert the S_HOLD behaviour over a bounded window
(HOLD_WINDOW_APB) that is enormous relative to the transient S_FINISH
(~1 cycle) yet tiny relative to HOLD_CYCLES. That window alone is
sufficient and decisive to distinguish the two RTLs: pre-T3.2 has
`calibration_done==1 / training_mode==0 / state==4` essentially
immediately after the sweep and NEVER reaches state 6, whereas T3.2 holds
`state==6 / training_mode==1 / calibration_done==0` for the entire window.
The eventual S_HOLD→S_DONE late rise of `calibration_done` is guaranteed
structurally by the RTL (`else if (hold_ctr >= HOLD_MAX) nxt_state =
S_DONE;` plus the saturating `hold_ctr`), so it does not need 0.5 M cycles
of wall-clock to re-derive here.
"""

import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import setup, lock_master, lock_slave


# Calibrator FSM state encoding (see tidelink_phy_align_calibrator.sv).
S_IDLE, S_ARM, S_SWEEP, S_FINISH, S_DONE, S_CANCEL, S_HOLD = (
    0, 1, 2, 3, 4, 5, 6
)

# The calibrator clock is the recovered RX link clock = pad_clk/16, and
# pad_clk == apb_clk in this tb_top. One full sweep is at worst
# 128 (phase×slip) × DWELL_CYCLES(32) = 4096 link clocks ≈ 65536 apb
# cycles; with SKID_BITS=3 all lanes lock early so the observed sweep is
# far shorter (~1.9k apb cycles), but we size the timeout conservatively.
SWEEP_TIMEOUT_APB = 70000          # generous: full worst-case sweep + margin

# S_HOLD observation window. >> the ~1-cycle S_FINISH and >> a full sweep,
# but << the default HOLD_CYCLES (8*128*32 = 32768 link clocks ≈ 524288
# apb cycles). 6000 apb cycles ≈ 375 link clocks of continuously-held
# S_HOLD — decisively distinguishes T3.2 (holds) from pre-T3.2 (S_DONE
# immediately, never state 6). See "MODELLING LIMITATION" in the header.
HOLD_WINDOW_APB = 6000


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _force_autocal_enable(dut, side, on):
    """Hierarchical-force autocal_force_enable_q so the calibrator's
    role_locked input rises with role_lock_reg (same hook the
    autocal_integrated / staggered-lottery tests use)."""
    _chiplet(dut, side).autocal_force_enable_q.value = 1 if on else 0


def _cal_state(dut, side):
    return int(_chiplet(dut, side).cal_state_w.value)


def _cal_done(dut, side):
    return int(_chiplet(dut, side).cal_calibration_done_w.value)


def _cal_lane_fault(dut, side):
    return int(_chiplet(dut, side).cal_lane_fault_w.value)


def _cal_training_mode(dut, side):
    return int(_chiplet(dut, side).cal_training_mode_w.value)


@cocotb.test()
async def test_t32_shold_peer_aware_training_hold(dut):
    """Genuine sweep_success → S_HOLD holds training_mode high / cal_done
    low for a long bounded window (T3.2); pre-T3.2 jumps straight to
    S_DONE (negative control fails this)."""

    # 1. Enable the calibrator on both sides BEFORE coming out of POR.
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)

    # 2. Boot both sides (clocks started inside setup()).
    await setup(dut)

    # 3. Lock both roles → role_locked rises → calibrator triggers a sweep.
    #    With SKID_BITS=3 the per-lane slip/phase sweep corrects every
    #    lane, so every lane locks within one sweep on BOTH sides and the
    #    sweep is a GENUINE success (lane_fault stays 0x00). This is the
    #    sweep_success branch — the opposite of test_t3_staggered_lottery's
    #    all-stuck fault branch.
    await lock_master(dut)
    await lock_slave(dut)

    # 4. Wait for the sweep to finish and S_HOLD to be entered on BOTH
    #    sides. We key off cal_state_w == S_HOLD (==6). On pre-T3.2 there
    #    is no state 6 at all, so this loop will instead observe S_DONE /
    #    calibration_done and the post-loop assertions fire.
    entered_hold_m = entered_hold_s = -1
    sdone_m = sdone_s = -1                 # first apb cycle cal_done seen
    fault_seen_m = fault_seen_s = 0
    prev_m = prev_s = -1
    for i in range(SWEEP_TIMEOUT_APB):
        await ClockCycles(dut.apb_clk, 1)
        sm, ss = _cal_state(dut, "m"), _cal_state(dut, "s")
        if _cal_lane_fault(dut, "m"):
            fault_seen_m = 1
        if _cal_lane_fault(dut, "s"):
            fault_seen_s = 1
        if _cal_done(dut, "m") and sdone_m < 0:
            sdone_m = i
        if _cal_done(dut, "s") and sdone_s < 0:
            sdone_s = i
        if sm == S_HOLD and entered_hold_m < 0:
            entered_hold_m = i
        if ss == S_HOLD and entered_hold_s < 0:
            entered_hold_s = i
        if sm != prev_m or ss != prev_s:
            dut._log.info(
                f"[T3.2 +{i:6d}] "
                f"m(state={sm} done={_cal_done(dut,'m')} "
                f"fault=0x{_cal_lane_fault(dut,'m'):02x} "
                f"train={_cal_training_mode(dut,'m')}) "
                f"s(state={ss} done={_cal_done(dut,'s')} "
                f"fault=0x{_cal_lane_fault(dut,'s'):02x} "
                f"train={_cal_training_mode(dut,'s')})")
            prev_m, prev_s = sm, ss
        # T3.2: both entered S_HOLD — proceed to the hold-window check.
        if entered_hold_m >= 0 and entered_hold_s >= 0:
            break
        # PRE-T3.2 fast-fail: a genuine sweep_success has latched S_DONE
        # (calibration_done) on a side without state 6 ever appearing.
        # There is no S_HOLD in that RTL, so keep going only long enough
        # to make the diagnostic clear, then stop.
        if (sdone_m >= 0 or sdone_s >= 0) and (
                entered_hold_m < 0 and entered_hold_s < 0):
            # Give a few cycles for both sides to settle for the log.
            for _ in range(8):
                await ClockCycles(dut.apb_clk, 1)
            dut._log.info(
                f"[T3.2 +{i}] calibration_done latched without ever "
                f"entering S_HOLD (state never 6) — pre-T3.2 signature.")
            break

    dut._log.info(
        f"[T3.2] sweep phase done: entered_hold m={entered_hold_m} "
        f"s={entered_hold_s} ; first cal_done m={sdone_m} s={sdone_s} ; "
        f"fault_seen m={fault_seen_m} s={fault_seen_s} ; "
        f"FINAL m(state={_cal_state(dut,'m')} done={_cal_done(dut,'m')} "
        f"fault=0x{_cal_lane_fault(dut,'m'):02x} "
        f"train={_cal_training_mode(dut,'m')}) "
        f"s(state={_cal_state(dut,'s')} done={_cal_done(dut,'s')} "
        f"fault=0x{_cal_lane_fault(dut,'s'):02x} "
        f"train={_cal_training_mode(dut,'s')})")

    # ---- Sanity: the scenario must really be a GENUINE sweep_success ----
    # (no faulted lanes), else the discriminator would be testing the
    # wrong branch and the negative control would be vacuous.
    assert fault_seen_m == 0 and fault_seen_s == 0, (
        f"A lane faulted (m={fault_seen_m} s={fault_seen_s}) — this test "
        f"requires a GENUINE all-lanes-lock sweep_success (the T3.2 "
        f"S_FINISH→S_HOLD branch). Check SKID_BITS=3 is passed.")

    # ---- THE DISCRIMINATOR — this IS the committed d69be51 change -------
    #
    # T3.2: on sweep_success S_FINISH must go to S_HOLD, NOT S_DONE. So
    # both sides MUST have entered state 6. Pre-T3.2 has no S_HOLD state
    # and goes straight to S_DONE — these assertions fire there.
    assert entered_hold_m >= 0, (
        "MASTER calibrator never entered S_HOLD (cal_state_w==6) after a "
        f"genuine sweep_success. first cal_done seen at apb cycle "
        f"{sdone_m}, final state={_cal_state(dut,'m')}. PRE-T3.2 "
        "SIGNATURE: S_FINISH went straight to S_DONE (calibration_done "
        "asserted, training_mode dropped) — the first-to-succeed node "
        "abandons the skew-delayed peer (the HW-confirmed deadlock T3.2 "
        "fixes by inserting S_HOLD).")
    assert entered_hold_s >= 0, (
        "SLAVE calibrator never entered S_HOLD (cal_state_w==6) after a "
        f"genuine sweep_success. first cal_done seen at apb cycle "
        f"{sdone_s}, final state={_cal_state(dut,'s')}. PRE-T3.2 "
        "SIGNATURE: S_FINISH went straight to S_DONE — no peer-aware "
        "training hold.")

    # Re-sync to the later-entering side so the window below starts only
    # once BOTH sides are in S_HOLD together.
    while _cal_state(dut, "m") != S_HOLD or _cal_state(dut, "s") != S_HOLD:
        await ClockCycles(dut.apb_clk, 1)

    # ---- The S_HOLD peer-hold window: training_mode HIGH and
    #      calibration_done LOW held CONTINUOUSLY for a long bounded
    #      window (>> S_FINISH, >> a sweep, << default HOLD_CYCLES). On
    #      pre-T3.2 this is unreachable (no state 6); on T3.2 it must hold
    #      the whole window — calibration_done does NOT rise here (it only
    #      rises later when S_HOLD times out to S_DONE; see header
    #      MODELLING LIMITATION). --------------------------------------
    for w in range(HOLD_WINDOW_APB):
        await ClockCycles(dut.apb_clk, 1)
        for sd in ("m", "s"):
            st = _cal_state(dut, sd)
            tm = _cal_training_mode(dut, sd)
            cd = _cal_done(dut, sd)
            assert st == S_HOLD, (
                f"{sd} left S_HOLD after only {w} apb cycles (state={st}) "
                f"— S_HOLD must persist for HOLD_CYCLES (default ≈ 524288 "
                f"apb cycles); a {HOLD_WINDOW_APB}-cycle window is a tiny "
                f"fraction of that. Pre-T3.2 has no S_HOLD at all.")
            assert tm == 1, (
                f"{sd} dropped training_mode during S_HOLD after {w} apb "
                f"cycles — T3.2 must keep the TX training pattern UP "
                f"throughout S_HOLD so the skew-delayed peer can also "
                f"reach sweep_success (the whole point of the peer-aware "
                f"hold).")
            assert cd == 0, (
                f"{sd} asserted calibration_done during S_HOLD after {w} "
                f"apb cycles — T3.2 must hold calibration_done LOW "
                f"throughout S_HOLD; it may only rise LATER when S_HOLD "
                f"times out to S_DONE. An early rise is the pre-T3.2 "
                f"immediate-release behaviour.")
        if w % (HOLD_WINDOW_APB // 6) == 0:
            dut._log.info(
                f"[T3.2 hold +{w:5d}/{HOLD_WINDOW_APB}] "
                f"m(state={_cal_state(dut,'m')} "
                f"train={_cal_training_mode(dut,'m')} "
                f"done={_cal_done(dut,'m')}) "
                f"s(state={_cal_state(dut,'s')} "
                f"train={_cal_training_mode(dut,'s')} "
                f"done={_cal_done(dut,'s')})")

    dut._log.info(
        f"[T3.2] PASS — genuine sweep_success entered S_HOLD on BOTH "
        f"sides (m@apb {entered_hold_m}, s@apb {entered_hold_s}) and held "
        f"state==6 / training_mode==1 / calibration_done==0 continuously "
        f"for {HOLD_WINDOW_APB} apb cycles (>> the 1-cycle S_FINISH and "
        f">> a full sweep, << the ~524288-cycle default HOLD_CYCLES). "
        f"calibration_done did NOT rise in the window — the first-to-"
        f"succeed node keeps feeding the skew-delayed peer a continuous "
        f"training pattern instead of abandoning it (commit d69be51, "
        f"S_HOLD). It only releases (→S_DONE, calibration_done late) when "
        f"the hold counter saturates — structurally guaranteed by the "
        f"RTL.")
