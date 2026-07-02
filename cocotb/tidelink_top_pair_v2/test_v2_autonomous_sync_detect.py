"""The LAST autonomy layer — autonomous SYNC-detect config drive.

Goal
----
Prove that, on the AUTONOMOUS (nego_en) path with ZERO host pokes to the
SYNC-detect registers, the autoneg-driven config block in
axi_chiplet_controller.sv ("AUTONOMOUS SYNC-DETECT CONFIG DRIVE") replicates the
host rcp() SYNC-detect configuration on-chip and SEQUENCES it correctly:

    training-RUN (nego_en & role_locked & swi_training_mode_r first ALL-true —
                  R3 2026-07-02: a LEVEL one-shot, not a bare rising edge, so a
                  late-arming die (master-armed-first silicon race) still fires)
        -> SYNC-ON  : swi_sync_lane_mask_r := wlink_rx_lane_mask (M2 2026-07-02:
                      the Wlink RX lane-mask mirror — 0xFF in this 8-lane sim,
                      0xE4 on the TD_AUTO_LANE_MASK_E4 silicon build = the rcp
                      0x2128[7:0] value; single source of truth, no literal)
                      swi_sync_tol_r       := 5      (rcp 0x2128[12:8])
                      swi_sync_insert_en_r/robust := 1 — and NOT force_always
                      (R4a 2026-07-02: force-always persisting into data mode
                      deleted every 32nd payload word — WlinkRxLinkLayer strips
                      the SYNC beat to 0 — the silicon (h)-data garble. Outside
                      the scan the beacon must be IDLE-GATED; the scan-window
                      forcing is winscan_force_sync, OR'd at the Wlink ports by
                      the winscan FSM itself.)
                      word-pin override := 0 / auto_dis := 0  (rcp 0x2104=0, AUTO)
    ... winscan runs (forces SYNC itself via winscan_force_sync), deskew
        reanchor latches in WS_FINALIZE's now-genuinely-idle-gated dwell ...
    winscan_done 0->1   (SYNC stays ON, idle-gated — asserted)
    ... fch 0x208 bootstrap + CR/CRACK re-walk UNDER idle-gated SYNC ...
    fch_done_r 0->1 (+ SYNC_OFF_SETTLE)
        -> SYNC-OFF : swi_sync_insert_en_r/force_always/robust := 0 (= host
                      enter_data_mode R8=0x10 SYNC-off AFTER the bootstrap —
                      R4b 2026-07-02 retime; was keyed on winscan_done), while
                      lane_mask / tol=5 are RETAINED for the deskew.

The ORDERING invariant — SYNC-ON strictly precedes SYNC-OFF, and SYNC-OFF now
fires only AFTER the FC-handoff bootstrap — is asserted directly: SYNC-ON
fires while training is HIGH (the one-shot needs swi_training_mode_r=1); SYNC
is asserted STILL ON right after winscan_done (the R4b retime — the old
winscan_done-keyed OFF must NOT fire there); OFF lands only after fch_done_r
rises (+ settle). The fch swreset dwell rides the designed-in
tb_fch_dwell_short_q hook (R4c: silicon dwell is now 0.25 s; the hook selects
the previous, proven 4095-cycle sim dwell).

Why this harness
----------------
Sim has NO cross-lane skew, so it cannot exercise the winscan/deskew BENEFIT
(reanchor would latch anyway). This test does NOT claim the eye benefit; it
PROVES the config writes fire + sequence. It reuses the winscan FSM test's
scaffolding (force nego_en, drive the training edges, model the eye so the
winscan reaches winscan_done) — the same stand-in for the production
strap/reset-override the winscan test uses, NOT a host SYNC poke.

Additivity (manual/SW path unaffected) is asserted in a second test: with
nego_en=0 the config drive NEVER fires and every swi_sync_* reg holds its POR
default across a training rise/fall.

Run
---
    cd cocotb/tidelink_top_pair_v2
    TB_TOP_NO_DUMP=1 MODULE=test_v2_autonomous_sync_detect \
        make EPOCH_PROFILE=zero
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import (
    PairV2TB,
    CLK_PERIOD_NS,
)

# Reuse the winscan FSM test's eye model + helpers so the on-chip winscan
# reaches winscan_done (needed to observe the SYNC-OFF edge).
from test_v2_winscan_fsm import (
    TAP_OPT,
    ACTIVE_LANES,
    _ctrl,
    _sync_dist_model,
    _bringup_to_role_cal,
)

# Golden rcp() SYNC-detect config (fpga/hw_regression/td_v2_hwlib.sh).
# M2 (2026-07-02): the expected LANE MASK is no longer a constant — the drive
# writes wlink_rx_lane_mask (the Wlink RX lane-mask POR mirror: 0xFF in this
# 8-lane sim, 0xE4 on the TD_AUTO_LANE_MASK_E4 silicon build, where it equals
# the rcp 0x5e4[7:0] value). Derived at runtime via _exp_lane_mask(ctrl).
EXP_SYNC_TOL  = 5      # rcp R_SYNCTOL 0x2128[12:8]


def _exp_lane_mask(ctrl):
    """M2: the SYNC-ON drive's lane-mask source of truth (wlink_rx_lane_mask)."""
    return int(ctrl.wlink_rx_lane_mask.value)


def _read_sync_cfg(ctrl):
    """Snapshot the controller's SYNC-detect config regs."""
    return {
        "lane_mask":   int(ctrl.swi_sync_lane_mask_r.value),
        "tol":         int(ctrl.swi_sync_tol_r.value),
        "insert_en":   int(ctrl.swi_sync_insert_en_r.value),
        "force_always":int(ctrl.swi_sync_force_always_r.value),
        "robust":      int(ctrl.swi_sync_robust_detect_r.value),
        "wp_ovr":      int(ctrl.swi_word_pin_ovr_r.value),
        "wp_auto_dis": int(ctrl.swi_word_pin_auto_dis_r.value),
    }


def _set_nego_en(ctrl, on=True):
    cur = int(ctrl.nego_cfg_reg.value)
    ctrl.nego_cfg_reg.value = (cur | 0x1) if on else (cur & ~0x1)


def _read_wlink_mask(ctrl):
    """The local Wlink tx/rx lane mask (Wlink 0x214 mirror at the controller
    boundary — a BUILD-TIME POR default, not a runtime drive)."""
    return (int(ctrl.wlink_tx_lane_mask.value),
            int(ctrl.wlink_rx_lane_mask.value))


def _read_lock_thresh_eff(ctrl):
    """The effective per-lane lock threshold feeding the lane_checker (the
    nego_en-gated 0x2160 override). 8 x 3-bit; returns lane-0's threshold and
    the raw 24-bit word. The combinational `lane_lock_thresh_eff` wire may be
    collapsed by the sim, so read the lane_checker's lock_thresh_i port (the
    same net) — falling back to the wire name if present."""
    try:
        w = int(ctrl.u_lane_checker.lock_thresh_i.value)
    except (AttributeError, ValueError):
        w = int(ctrl.lane_lock_thresh_eff.value)
    return (w & 0x7), w


async def _training_rise(tb, side):
    """Create the training-RUN rising edge the SYNC-ON drive arms on.
    swi_training_mode_r is procedurally driven but, with no APB write and no
    autoneg ENTER pulse active, a plain deposit holds (same idiom the winscan
    FSM test uses)."""
    ctrl = _ctrl(tb.dut, side)
    ctrl.swi_training_mode_r.value = 0
    await ClockCycles(tb.dut.hclk, 2)
    ctrl.swi_training_mode_r.value = 1     # 0->1 rising edge -> SYNC-ON drive
    await ClockCycles(tb.dut.hclk, 3)


async def _training_fall(tb, side):
    """Drop training -> kicks the winscan FSM (and the FC handoff) on the fall."""
    ctrl = _ctrl(tb.dut, side)
    ctrl.swi_training_mode_r.value = 0
    await ClockCycles(tb.dut.hclk, 3)


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


async def _wait_fch_done(tb, side, max_cycles=100_000, poll=100):
    """R4b: wait for the FC-handoff bootstrap to complete (fch_done_r rise) —
    the new SYNC-OFF trigger. Needs tb_fch_dwell_short_q=1 (R4c) or the
    0.25 s silicon swreset dwell blows the sim budget."""
    ctrl = _ctrl(tb.dut, side)
    waited = 0
    while waited < max_cycles:
        await ClockCycles(tb.dut.hclk, poll)
        waited += poll
        try:
            if int(ctrl.fch_done_r.value) == 1:
                return True, waited
        except ValueError:
            pass
    return False, waited


@cocotb.test()
async def test_v2_autonomous_sync_detect_drive(dut):
    """ZERO-poke autonomous SYNC-detect config: SYNC-ON at training-run, then
    SYNC-OFF after winscan/reanchor — in that order."""
    log = dut._log
    log.info("autonomous SYNC-detect config drive: rcp replication + ordering")

    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)

    ctrl = _ctrl(dut, "m")

    # ---- Pre-condition: POR defaults, drive dormant -----------------------
    # No host wrote the SYNC-detect config; regs sit at reset (the silicon bug:
    # lane_mask=0xFF waits for 8 lanes, only 0xE4 active -> reanchor never).
    pre = _read_sync_cfg(ctrl)
    log.info(f"pre-config (POR defaults): {pre}")
    assert pre["lane_mask"] == 0xFF, \
        f"pre: lane_mask should be POR 0xFF, got 0x{pre['lane_mask']:02x}"
    assert pre["tol"] == 0, f"pre: tol should be POR 0, got {pre['tol']}"
    assert pre["insert_en"] == 0, "pre: insert_en should be POR 0 (SYNC off)"
    assert pre["force_always"] == 0 and pre["robust"] == 0, \
        "pre: force_always/robust should be POR 0"

    # Wlink lane mask (0x214) at POR = 0xFF each (default sim; the FPGA build
    # injects TD_AUTO_LANE_MASK_E4 -> 0xE4). Lock threshold (0x2160) at its
    # gpio-phy default while nego_en=0 (passthrough). 0x214 is a build-time POR
    # default; 0x2160 becomes a runtime nego_en override (below).
    tx0, rx0 = _read_wlink_mask(ctrl)
    log.info(f"pre 0x214 wlink mask: tx=0x{tx0:02x} rx=0x{rx0:02x}")
    assert tx0 == 0xFF and rx0 == 0xFF, (
        f"pre: Wlink lane mask should be POR 0xFF each (tx=0x{tx0:02x} "
        f"rx=0x{rx0:02x}) — the autonomous 0x214 write must not have fired yet")

    # ---- Arm the autonomous path + model the silicon eye -------------------
    # nego_en=1 (= production strap stand-in). The nego_en RISING edge flips the
    # 0x2160 lock-thresh override. Eye model so the winscan reaches winscan_done.
    _set_nego_en(ctrl, True)
    ctrl.tb_winscan_dwell_short_q.value = 1
    # R4c: the fch swreset dwell is 0.25 s on silicon — engage the designed-in
    # sim hook (previous proven 4095-cycle dwell) so fch_done_r (the retimed
    # SYNC-OFF trigger, R4b) arrives inside the sim budget.
    ctrl.tb_fch_dwell_short_q.value = 1
    cocotb.start_soon(_sync_dist_model(tb, "m", TAP_OPT, ACTIVE_LANES))
    await ClockCycles(dut.hclk, 20)

    # ---- 0x214 Wlink lane mask: BUILD-TIME POR default, NOT a runtime drive ---
    # The autonomous path does NOT write 0x214 at runtime — the local Wlink tx/rx
    # lane mask is a POR default (0xFF here; 0xE4 when the FPGA build injects
    # TD_AUTO_LANE_MASK_E4 via fpga/filelist.tcl, build-only so this sim keeps the
    # 8-lane 0xFF oracle). It is therefore CONSTANT across the nego_en edge. The
    # 0xE4 build's data integrity is covered by test_v2_pair_data test_02/03 under
    # a 0xE4 mask + on-silicon Proof-1 (manual rcp 0x214=0xe4e4).
    tx1, rx1 = _read_wlink_mask(ctrl)
    log.info(f"after nego_en 0x214 wlink mask: tx=0x{tx1:02x} rx=0x{rx1:02x} "
             f"(POR default; unchanged by nego_en)")
    assert tx1 == tx0 and rx1 == rx0, (
        f"0x214: Wlink lane mask changed across nego_en "
        f"(tx 0x{tx0:02x}->0x{tx1:02x} rx 0x{rx0:02x}->0x{rx1:02x}) — it must be a "
        f"static POR default (build-config), not a runtime drive")

    EXP_THRESH_WORD = int("101" * 8, 2)   # {8{3'd5}} = 24-bit, all lanes thresh 5
    lt_lane0, lt_word = _read_lock_thresh_eff(ctrl)
    log.info(f"after nego_en 0x2160 lock_thresh_eff=0x{lt_word:06x} "
             f"(lane0={lt_lane0})")
    assert lt_lane0 == 5 and lt_word == EXP_THRESH_WORD, (
        f"0x2160: per-lane lock threshold did NOT become 5 for all lanes "
        f"(lane0={lt_lane0} word=0x{lt_word:06x} want=0x{EXP_THRESH_WORD:06x}) — "
        f"rcp 0x2160=0x55555555 not replicated on the autonomous path")

    # ---- SYNC-ON: training-RUN applies the rcp config ----------------------
    await _training_rise(tb, "m")
    on = _read_sync_cfg(ctrl)
    log.info(f"after training-RUN (SYNC-ON): {on}")

    # M2: the drive's mask value = wlink_rx_lane_mask (0xFF in this sim — same
    # as POR, so the FIRING proof is carried by tol/insert_en/force_always/
    # robust below; on the 0xE4 silicon build this assert additionally pins
    # the mask update itself).
    exp_lane_mask = _exp_lane_mask(ctrl)
    assert on["lane_mask"] == exp_lane_mask, (
        f"SYNC-ON: lane_mask did NOT become wlink_rx_lane_mask=0x{exp_lane_mask:02x} "
        f"(got 0x{on['lane_mask']:02x}) — autonomous SYNC-detect config did not "
        f"fire / M2 single-source-of-truth regressed")
    assert on["tol"] == EXP_SYNC_TOL, (
        f"SYNC-ON: tol did NOT become {EXP_SYNC_TOL} (got {on['tol']})")
    assert on["insert_en"] == 1, "SYNC-ON: insert_en (SYNC_EN) not set"
    # R4a: force_always must NOT be set by the autonomous SYNC-ON — outside the
    # winscan window (which forces via winscan_force_sync at the Wlink ports)
    # the beacon is IDLE-GATED. force_always=1 here would delete every 32nd
    # payload word once FC traffic runs (the silicon (h)-data garble).
    assert on["force_always"] == 0, (
        "R4a REGRESSION: autonomous SYNC-ON set swi_sync_force_always_r — the "
        "idle gate would be dead through data mode, deleting every 32nd "
        "payload word (pktnum/credit desync, fe_full re-wedge)")
    assert on["robust"] == 1, "SYNC-ON: robust_detect not set"
    assert on["wp_ovr"] == 0 and on["wp_auto_dis"] == 0, (
        "SYNC-ON: word-pin not AUTO (rcp 0x2104=0): "
        f"ovr=0x{on['wp_ovr']:x} auto_dis={on['wp_auto_dis']}")

    log.info(f"SYNC-ON verified: lane_mask=0x{exp_lane_mask:02x} "
             f"(=wlink_rx_lane_mask) tol=5 insert_en/robust=1 force_always=0 "
             f"(R4a idle-gated) word-pin=AUTO (0x2128 SYNCTOL replicated)")

    # ---- Drive winscan to completion, observe SYNC-OFF ordering -------------
    # Snapshot that SYNC is STILL on right before winscan_done (proves SYNC-OFF
    # has NOT fired early — it must come AFTER reanchor/winscan_done).
    await _training_fall(tb, "m")      # kicks the winscan FSM
    await ClockCycles(dut.hclk, 50)
    mid = _read_sync_cfg(ctrl)
    assert mid["insert_en"] == 1, (
        "ORDERING VIOLATION: SYNC-insert dropped DURING the winscan (before "
        "winscan_done) — SYNC-OFF must only fire after reanchor")

    ok, w = await _wait_winscan_done(tb, "m")
    assert ok, f"winscan_done never asserted (after {w} cycles)"
    # R4b RETIME GATE: right after winscan_done, SYNC must STILL be ON
    # (idle-gated) — the old winscan_done-keyed OFF must NOT fire here. The
    # fch 0x208 bootstrap (armed on winscan_done, ≥4095-cycle swreset dwell
    # even with the short hook) is only just starting, so sampling a few
    # cycles in is safely inside the bootstrap window.
    await ClockCycles(dut.hclk, 5)
    post_ws = _read_sync_cfg(ctrl)
    log.info(f"after winscan_done (SYNC must STILL be ON): {post_ws}  "
             f"(winscan_done@{w} cyc, {w * CLK_PERIOD_NS / 1000:.1f} us)")
    assert post_ws["insert_en"] == 1, (
        "R4b ORDERING VIOLATION: SYNC-insert dropped AT winscan_done — "
        "SYNC-OFF is retimed to fch_done_r(+settle) so the FC bootstrap's "
        "CR/CRACK re-walk runs UNDER idle-gated SYNC")
    assert post_ws["force_always"] == 0, (
        "R4a: force_always high after the scan — winscan_force_sync must be "
        "the only scan-window forcing and it drops at WS_FINALIZE")

    # ---- SYNC-OFF: retimed to the fch bootstrap completing (R4b) -----------
    okf, wf = await _wait_fch_done(tb, "m")
    assert okf, (
        f"fch_done_r never rose (after {wf} cycles) — the FC-handoff "
        f"bootstrap did not complete (is tb_fch_dwell_short_q forced?)")
    # OFF lands SYNC_OFF_SETTLE (=1024 apb cycles) after the fch_done_r rise;
    # allow a bounded margin.
    off = None
    off_seen = False
    for _ in range(80):
        await ClockCycles(dut.hclk, 50)
        off = _read_sync_cfg(ctrl)
        if off["insert_en"] == 0:
            off_seen = True
            break
    log.info(f"after fch_done(+settle) (SYNC-OFF): {off}  (fch_done@+{wf} cyc)")

    assert off_seen and off["insert_en"] == 0, (
        "SYNC-OFF: insert_en did NOT drop after fch_done_r + settle — data "
        "path would keep beaconing SYNC (host enter_data_mode R8=0x10 not "
        "replicated on the retimed R4b path)")
    assert off["force_always"] == 0, "SYNC-OFF: force_always not 0"
    assert off["robust"] == 0, "SYNC-OFF: robust_detect did not drop"
    # lane_mask / tol RETAINED across data mode (correct for the deskew).
    assert off["lane_mask"] == exp_lane_mask, (
        f"SYNC-OFF: lane_mask must be RETAINED at 0x{exp_lane_mask:02x} "
        f"(=wlink_rx_lane_mask) for the deskew, got 0x{off['lane_mask']:02x}")
    assert off["tol"] == EXP_SYNC_TOL, (
        f"SYNC-OFF: tol must be retained at {EXP_SYNC_TOL}, got {off['tol']}")

    log.info("ORDERING VERIFIED: SYNC-ON (training-run) -> winscan (forced via "
             "winscan_force_sync) -> STILL ON at winscan_done -> fch bootstrap "
             "under idle-gated SYNC -> SYNC-OFF after fch_done(+settle); "
             "lane_mask/tol retained for deskew.")
    log.info("VERDICT: PASS — autonomous SYNC-detect config replicates the host "
             "rcp recipe on-chip with the R4a idle-gated beacon and the R4b "
             "fch_done-retimed SYNC-OFF order.")


@cocotb.test()
async def test_v2_autonomous_sync_detect_manual_path_unaffected(dut):
    """ADDITIVITY: with nego_en=0 (the proven SW-role_lock / manual-recipe
    path) the autonomous SYNC-detect drive NEVER fires — every swi_sync_* reg
    holds its POR default across a training rise/fall. Guarantees the manual
    operating point stays byte-exact."""
    log = dut._log
    log.info("manual-path additivity: nego_en=0 => SYNC-detect drive dormant")

    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)

    ctrl = _ctrl(dut, "m")
    # Explicitly nego_en=0 (manual/SW path). role_locked is already 1.
    _set_nego_en(ctrl, False)
    await ClockCycles(dut.hclk, 5)

    before = _read_sync_cfg(ctrl)

    # Create a training rise/fall — on the manual path the drive must IGNORE it.
    ctrl.swi_training_mode_r.value = 0
    await ClockCycles(dut.hclk, 2)
    ctrl.swi_training_mode_r.value = 1
    await ClockCycles(dut.hclk, 5)
    ctrl.swi_training_mode_r.value = 0
    await ClockCycles(dut.hclk, 5)

    after = _read_sync_cfg(ctrl)
    log.info(f"nego_en=0 config before={before} after={after}")

    assert after["lane_mask"] == before["lane_mask"] == 0xFF, (
        "ADDITIVITY VIOLATION: lane_mask changed on the manual path "
        f"(before=0x{before['lane_mask']:02x} after=0x{after['lane_mask']:02x})")
    assert after["tol"] == 0 and after["insert_en"] == 0 and \
        after["force_always"] == 0 and after["robust"] == 0, (
        "ADDITIVITY VIOLATION: a SYNC-detect bit moved on the manual path "
        f"(after={after}) — nego_en=0 must keep the drive dormant")

    # 0x214 Wlink lane mask stays 0xFF (MSK sequencer dormant at nego_en=0) and
    # the 0x2160 lock-threshold override is a straight passthrough (not forced 5).
    tx, rx = _read_wlink_mask(ctrl)
    assert tx == 0xFF and rx == 0xFF, (
        "ADDITIVITY VIOLATION: Wlink lane mask (0x214) changed on the manual "
        f"path (tx=0x{tx:02x} rx=0x{rx:02x}) — the MSK sequencer must stay "
        f"dormant at nego_en=0")
    lt_lane0, lt_word = _read_lock_thresh_eff(ctrl)
    assert lt_lane0 != 5 or lt_word != int("101" * 8, 2), (
        "ADDITIVITY VIOLATION: lock-threshold override forced 5 on the manual "
        f"path (word=0x{lt_word:06x}) — nego_en=0 must pass the APB value "
        f"through (gpio-phy default 3), not the autonomous 5")

    log.info("VERDICT: PASS — manual/SW path unaffected (drive dormant at "
             "nego_en=0; SYNC-detect POR defaults + 0x214=0xFF + lock-thresh "
             "passthrough held across training rise/fall).")
