"""Autonomous on-chip IDELAY WINSCAN FSM — V2 deskew base.

Proves the new winscan FSM (src/rtl/local_overrides/axi_chiplet_controller.sv,
"AUTONOMOUS ON-CHIP IDELAY WINSCAN FSM" block) replicates the host software
winscan() loop on-chip: per active lane it sweeps the 32 IDELAY taps, samples
the per-lane SYNC Hamming distance, and PICKS the argmin-distance tap — the last
autonomy layer that lets the cross-lane deskew `reanchored` latch fire without a
host poke.

Why a modelled SYNC_DIST
------------------------
In simulation the RX IDELAY is passthrough (USE_IDELAY=0), so the tap has zero
datapath effect and the real PHY would report a flat (≈0) SYNC distance on every
tap — the FSM could not "find a centre". So this test MODELS the silicon eye:
a coroutine continuously forces the controller's obs_sync_dist_vec_w as a
function of the FSM's currently-applied per-lane tap (ws_phase_offset_r /
ws_phase_lsb_r), shaped high off-centre with a per-lane minimum at TAP_OPT[L].
The FSM must then converge each active lane's picked tap onto TAP_OPT[L].

The FSM is armed exactly as the production autonomous path arms it: nego_en &
role_locked & the training-mode falling edge. Here those are driven as TB forces
(stand-ins for the production strap), after the proven SW bring-up reaches
role-lock + cal_done. The dwell is shrunk via the designed-in
`tb_winscan_dwell_short_q` hook (same idiom as the calibrator's
tb_early_exit_force_q) so the 32-tap × 4-lane sweep fits the sim budget.

Run
---
    cd cocotb/tidelink_top_pair_v2
    make EPOCH_PROFILE=zero MODULE=test_v2_winscan_fsm \
        TESTCASE=test_v2_winscan_fsm_picks_centre
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force

from pair_v2_common import (
    PairV2TB,
    CLK_PERIOD_NS,
)

# Per-lane "true centre" tap the modelled eye minimises at (0..31). The
# autonomous arm (_arm_winscan -> nego_en=1 + training rise) drives the on-chip
# SYNC-detect config (axi_chiplet_controller.sv "AUTONOMOUS SYNC-DETECT CONFIG
# DRIVE"), which — since M2 (2026-07-02) — sets swi_sync_lane_mask_r =
# wlink_rx_lane_mask (single source of truth: 0xFF POR in this 8-lane sim,
# 0xE4 on the TD_AUTO_LANE_MASK_E4 silicon build) instead of a hardcoded
# bridge1 0xE4 literal. In sim ALL 8 lanes therefore scan; distinct optima per
# lane prove the FSM tracks an independent argmin for each.
#
# R2 model note (2026-07-02): the FSM now TEAR-QUALIFIES its samples (accepts a
# sample only when two consecutive reads of the CDC'd distance are EQUAL, with
# a spacing dwell between accepted samples). This model is compatible by
# construction: it forces the obs vector every cycle to a DETERMINISTIC
# function of the currently-applied tap, so the value is rock-stable between
# tap changes — exactly like real silicon between IDELAY reloads — and the
# two-equal-reads qualifier passes immediately.
TAP_OPT = {0: 14, 1: 9, 2: 20, 3: 5, 4: 17, 5: 11, 6: 24, 7: 3}

# Active set = the sim POR wlink_rx_lane_mask (0xFF) => all 8 lanes (M2).
ACTIVE_LANES = list(range(8))


def _ctrl(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller


def _applied_tap(ctrl, lane):
    """The tap the FSM is currently driving for `lane`:
    tap = (ws_phase_offset_r[4L+:4] << 1) | ws_phase_lsb_r[L]."""
    nib_word = int(ctrl.ws_phase_offset_r.value)
    lsb_word = int(ctrl.ws_phase_lsb_r.value)
    nib = (nib_word >> (4 * lane)) & 0xF
    lsb = (lsb_word >> lane) & 0x1
    return (nib << 1) | lsb


def _model_dist(tap, opt):
    """Eye model: SYNC Hamming distance is 0 at the optimum tap and rises with
    distance away from it, saturating at 5-bit max. Min at `opt`, monotone on
    each side — a clean unique argmin so the FSM's argmin is deterministic."""
    d = abs(tap - opt)
    return min(d, 31)


async def _sync_dist_model(tb, side, opt_map, active):
    """Continuously force obs_sync_dist_vec_w (8×5b) on `side`'s controller as a
    function of the FSM's applied per-lane tap. Runs for the whole test."""
    ctrl = _ctrl(tb.dut, side)
    vec_sig = ctrl.obs_sync_dist_vec_w
    while True:
        word = 0
        for lane in range(8):
            if lane in active:
                tap = _applied_tap(ctrl, lane)
                d = _model_dist(tap, opt_map[lane])
            else:
                d = 31
            word |= (d & 0x1F) << (5 * lane)
        vec_sig.value = Force(word)   # force: obs_sync_dist_vec_w is PHY-driven
        await ClockCycles(tb.dut.hclk, 1)


async def _bringup_to_role_cal(tb):
    """Proven SW bring-up: POR -> calibrator sim bypass -> role_lock -> cal_done.
    Leaves the link trained + lanes locked (SYNC-detect-capable), the same point
    the autonomous autoneg FSM reaches before it would arm the winscan."""
    await tb.reset()
    tb.force_calibrator_sim_bypass()
    await tb.do_role_lock()
    assert await tb.wait_role_locked(), "role_locked did not assert on both dies"
    m_st, s_st = await tb.wait_cal_done()
    tb.log.info(f"post-autocal: M=0x{m_st:08x} S=0x{s_st:08x}")
    return m_st, s_st


def _arm_winscan(tb, side):
    """Stand in for the production autonomous arm: nego_en=1, role already
    locked, then pulse swi_training_mode 1->0 to create the falling edge the FSM
    (and the FC handoff) arm on. Also engage the sim dwell-shrink hook."""
    ctrl = _ctrl(tb.dut, side)
    # nego_en = nego_cfg_reg[0]
    cur = int(ctrl.nego_cfg_reg.value)
    ctrl.nego_cfg_reg.value = cur | 0x1
    # sim dwell shrink (designed-in hook on the FSM)
    ctrl.tb_winscan_dwell_short_q.value = 1


async def _pulse_training_fall(tb, side):
    ctrl = _ctrl(tb.dut, side)
    ctrl.swi_training_mode_r.value = 1
    await ClockCycles(tb.dut.hclk, 4)
    ctrl.swi_training_mode_r.value = 0   # falling edge -> ws_arm_kick + fch arm
    await ClockCycles(tb.dut.hclk, 4)


async def _wait_winscan_done(tb, side, max_cycles=400_000, poll=200):
    ctrl = _ctrl(tb.dut, side)
    waited = 0
    while waited < max_cycles:
        await ClockCycles(tb.dut.hclk, poll)
        waited += poll
        try:
            if int(ctrl.winscan_done.value) == 1:
                return True, waited
        except ValueError:
            pass
    return False, waited


@cocotb.test()
async def test_v2_winscan_fsm_picks_centre(dut):
    """The on-chip winscan FSM sweeps each active lane and PICKS the modelled
    per-lane argmin tap; winscan_done asserts; the FSM owns the taps while
    scanning and holds the picked centres after."""
    log = dut._log
    log.info("winscan FSM: autonomous per-lane IDELAY centre selection")

    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)

    # Model the silicon eye on the MASTER controller (the die under scan).
    cocotb.start_soon(_sync_dist_model(tb, "m", TAP_OPT, ACTIVE_LANES))
    await ClockCycles(dut.hclk, 10)

    ctrl = _ctrl(dut, "m")
    # Pre-condition: FSM dormant -> does NOT own the taps (SW/host path intact).
    assert int(ctrl.winscan_owns_taps.value) == 0, \
        "winscan must be dormant (not owning taps) before it is armed"

    _arm_winscan(tb, "m")
    await _pulse_training_fall(tb, "m")

    # The FSM should now be running: owning taps + forcing SYNC.
    await ClockCycles(dut.hclk, 50)
    assert int(ctrl.winscan_owns_taps.value) == 1, \
        "winscan FSM did not take tap ownership after the arm kick"

    ok, w = await _wait_winscan_done(tb, "m")
    assert ok, f"winscan_done never asserted (after {w} cycles)"
    log.info(f"winscan_done after {w} cycles ({w * CLK_PERIOD_NS / 1000:.1f} us)")

    # Verify each active lane's PICKED tap is the modelled argmin (== TAP_OPT[L]).
    # The eye model is a clean unimodal V with a unique minimum, so the FSM's
    # strict-< argmin must land exactly on TAP_OPT[L].
    mismatches = []
    for lane in ACTIVE_LANES:
        picked = _applied_tap(ctrl, lane)
        if picked != TAP_OPT[lane]:
            mismatches.append((lane, picked, TAP_OPT[lane]))
        log.info(f"  lane {lane}: picked tap={picked} (opt={TAP_OPT[lane]})")
    assert not mismatches, (
        "winscan FSM picked the WRONG tap on lane(s) "
        + ", ".join(f"L{l}: got {g} want {w}" for l, g, w in mismatches))

    # R2c: the modelled metric VARIES with the tap, so the degenerate-scan
    # guard must NOT have fired (the picks above are real argmins, not the
    # middle-tap fallback).
    assert int(ctrl.ws_degenerate_q.value) == 0, (
        "ws_degenerate_q latched on a VARYING metric — the flat-scan detector "
        "is over-triggering (would discard real winscan results)")

    # The FSM must HOLD ownership (the picked centres stay applied) and have
    # dropped force-SYNC (idle-gated) at finalize.
    assert int(ctrl.winscan_owns_taps.value) == 1, \
        "winscan FSM dropped tap ownership after DONE (centres would be lost)"
    assert int(ctrl.winscan_force_sync.value) == 0, \
        "winscan FSM left force-SYNC on after finalize (reanchor idle-gate)"

    log.info("VERDICT: PASS — autonomous on-chip winscan picked every active "
             "lane's modelled eye centre; winscan_done asserted; taps held.")


@cocotb.test()
async def test_v2_winscan_dormant_when_not_armed(dut):
    """REGRESSION GUARD: with no autonomous arm (nego_en=0, the SW/host path),
    the winscan FSM stays dormant — it never takes tap ownership nor forces
    SYNC, and the APB-written tap regs are left untouched. This is the property
    that keeps the proven manual/SW data path bit-identical."""
    log = dut._log
    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)

    ctrl = _ctrl(dut, "m")
    # Even a training-mode fall must NOT arm the FSM while nego_en=0.
    ctrl.swi_training_mode_r.value = 1
    await ClockCycles(dut.hclk, 4)
    ctrl.swi_training_mode_r.value = 0
    await ClockCycles(dut.hclk, 2000)

    assert int(ctrl.winscan_owns_taps.value) == 0, \
        "winscan FSM armed with nego_en=0 — would corrupt the SW/host tap path"
    assert int(ctrl.winscan_force_sync.value) == 0, \
        "winscan FSM forced SYNC with nego_en=0 — must stay at strap value"
    assert int(ctrl.winscan_done.value) == 0, \
        "winscan_done set with nego_en=0 — handoff gate would mis-fire"
    log.info("VERDICT: PASS — winscan FSM dormant on the SW path (nego_en=0).")


def _fch_pending(tb, side):
    try:
        return int(_ctrl(tb.dut, side).fch_pending_r.value)
    except (AttributeError, ValueError):
        return -1


def _fch_active(tb, side):
    try:
        return int(_ctrl(tb.dut, side).fch_active_r.value)
    except (AttributeError, ValueError):
        return -1


@cocotb.test()
async def test_v2_winscan_gates_handoff_ordering(dut):
    """ORDERING PROOF: the FC data-mode handoff sequencer waits for the winscan.

    This is the new wiring the prompt asks for — SYNC-detect -> winscan ->
    reanchored -> handoff. The handoff arm (fch_arm) is gated on winscan_done, so
    the 0x208 LL bootstrap must NOT start until the per-lane centres are picked.
    We prove the ordering directly on the controller's internal handoff state:

      1. arm via the production gate (nego_en & role_locked & training-fall);
      2. WHILE the winscan is sweeping (winscan_done=0), the handoff is LATCHED
         pending (fch_pending_r=1) but has NOT started the 0x208 burst
         (fch_active_r stays 0) — i.e. the handoff is held off behind the scan;
      3. once winscan_done rises, fch_pending_r releases and the handoff burst
         runs (fch_active_r pulses) — the correct SYNC-detect->winscan->handoff
         order. (Bilateral FCSM=4 + data over the autonomous handoff is a known
         v2-harness limitation, proven instead on the V1 harness test_30 with
         TIDELINK_PHY_V2=1; here we prove the on-chip ORDERING the winscan adds.)
    """
    log = dut._log
    log.info("winscan FSM: handoff-ordering gate (handoff waits for winscan)")

    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)
    cocotb.start_soon(_sync_dist_model(tb, "m", TAP_OPT, ACTIVE_LANES))
    await ClockCycles(dut.hclk, 10)

    ctrl = _ctrl(dut, "m")
    _arm_winscan(tb, "m")
    await _pulse_training_fall(tb, "m")

    # During the scan: handoff pending but held off (NOT bursting on 0x208).
    await ClockCycles(dut.hclk, 100)
    assert int(ctrl.winscan_done.value) == 0, "winscan finished too fast to observe the gate"
    assert int(ctrl.winscan_owns_taps.value) == 1, "winscan should be running"
    assert _fch_pending(tb, "m") == 1, \
        "handoff did not latch pending on the training-fall"
    # Sample fch_active across the scan: it must stay 0 (handoff held off).
    handoff_started_early = False
    for _ in range(200):
        await ClockCycles(dut.hclk, 50)
        if int(ctrl.winscan_done.value) == 1:
            break
        if _fch_active(tb, "m") == 1:
            handoff_started_early = True
            break
    assert not handoff_started_early, (
        "FC handoff 0x208 burst STARTED before winscan_done — the ordering gate "
        "failed (handoff must wait out the winscan)")

    ok, w = await _wait_winscan_done(tb, "m")
    assert ok, f"winscan_done never asserted (after {w} cycles)"

    # After winscan_done: the pending handoff releases (fch_pending_r clears) and
    # the burst runs (fch_active_r pulses) — observe at least one active cycle.
    released = False
    burst_ran = False
    for _ in range(400):
        await ClockCycles(dut.hclk, 20)
        if _fch_pending(tb, "m") == 0:
            released = True
        if _fch_active(tb, "m") == 1:
            burst_ran = True
        if released and burst_ran:
            break
    assert released, "handoff pending did not release after winscan_done"
    assert burst_ran, "handoff 0x208 burst did not run after winscan_done"

    log.info("VERDICT: PASS — the FC handoff was held off (pending, no 0x208 "
             "burst) for the whole winscan, then released + ran the bootstrap "
             "AFTER winscan_done: SYNC-detect -> winscan -> handoff ordering "
             "is correctly gated on winscan_done.")
