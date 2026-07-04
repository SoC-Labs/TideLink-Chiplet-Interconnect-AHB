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
    ... winscan runs (forces SYNC itself via winscan_force_sync); WS_FINALIZE
        (F3/F4 2026-07-02) clears the scan-era sticky anchor and re-confirms
        the deskew reanchor at the FINAL taps under STILL-FORCED beacons (the
        periodic-confirm needs the on-grid beacon), holding winscan_done until
        the CDC'd reanchored reads 1 (fail-loud timeout otherwise); force
        drops at the FINALIZE exit ...
    winscan_done 0->1   (SYNC stays ON, idle-gated — asserted)
    ... fch 0x208 bootstrap + CR/CRACK re-walk UNDER idle-gated SYNC ...
    fch_done_r 0->1
        -> NO SYNC-OFF, EVER (D2 "never blind-OFF", 2026-07-03): the R4b/F2
           fch_done+settle SYNC-OFF timer is DELETED. Each die's local timer
           raced the PEER's WS_FINALIZE re-anchor refill (the refill needs
           PEER beacons; one missed SYNC_PERIOD grid slot resets the deskew
           confirm run — tidelink_lane_deskew_v2 gap_ceil) and no timer bounds
           the cross-die arm/scan skew. insert_en=1 (idle-gated) + robust=1
           are the PERMANENT autonomous data-mode state; only force-SYNC
           drops (winscan FINALIZE exit) and force_always is never set (R4a).
           lane_mask / tol=5 likewise stay set for the deskew.

The ORDERING/PERSISTENCE invariant is asserted directly: SYNC-ON fires while
training is HIGH (the one-shot needs swi_training_mode_r=1); SYNC is asserted
STILL ON right after winscan_done, and STILL ON well after fch_done_r plus a
dwell far exceeding the retired 1024-cycle settle (the D2 gate: any residual
OFF path firing is a regression). The fch swreset dwell rides the designed-in
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


async def _wait_winscan_done(tb, side, max_cycles=2_000_000, poll=200):
    # R-A (2026-07-04): budget widened 700k -> 2M — in this single-die
    # harness the anchor gate walks all 5 FIX-3 clear-retries before failing
    # open (same rationale as the winscan FSM test's helper). Loop-13: the
    # WS_FIN_WAITPEER rendezvous is dormant (no 400k wait); the widened
    # budget is retained as slack.
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
    # (tb_syncoff_settle_short_q is GONE — D2 2026-07-03 deleted the
    # autonomous SYNC-OFF timer; beacon PERMANENCE is asserted below instead.)
    # F4: WS_FINALIZE now holds winscan_done until the CDC'd reanchored reads
    # 1, with a 0.3 s FAIL-LOUD timeout. In this harness only the MASTER is
    # armed — the slave never beacons toward the master's RX, so the anchor
    # cannot re-latch and the gate exits via the TIMEOUT path (that path is
    # exactly the graceful-degradation release; ws_anchor_timeout_q latches,
    # logged below). The hook bounds each wait at 50k cycles; FIX-3
    # (2026-07-03) inserts 3 bounded clear-retries (each a 512-cycle clear-low
    # hold + a fresh 50k wait, all timing out against the beacon-less peer)
    # before the fail-open, so winscan_done arrives after ~205k cycles here.
    ctrl.tb_ws_anchor_short_q.value = 1
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

    # ---- D2 PERMANENCE (2026-07-03, INVERTED from the old SYNC-OFF gate) ---
    # The autonomous SYNC-OFF timer is DELETED ("never blind-OFF"): after the
    # fch bootstrap completes, insert_en (idle-gated) + robust must STAY 1
    # permanently. Dwell far beyond the retired 1024-cycle settle and assert
    # NO residual OFF path fired.
    okf, wf = await _wait_fch_done(tb, "m")
    assert okf, (
        f"fch_done_r never rose (after {wf} cycles) — the FC-handoff "
        f"bootstrap did not complete (is tb_fch_dwell_short_q forced?)")
    await ClockCycles(dut.hclk, 10_000)   # ~10x the retired settle window
    perm = _read_sync_cfg(ctrl)
    log.info(f"post-fch_done dwell (D2 permanence): {perm}  (fch_done@+{wf} cyc)")
    log.info(f"F4 anchor gate (single-die harness, timeout path expected after "
             f"the FIX-3 clear-retries): "
             f"ws_anchor_timeout_q={int(ctrl.ws_anchor_timeout_q.value)}")

    assert perm["insert_en"] == 1, (
        "D2 REGRESSION: insert_en dropped after fch_done_r — the autonomous "
        "SYNC-OFF timer must be GONE; a blind local OFF starves the PEER's "
        "WS_FINALIZE re-anchor refill (partial sync_seen, rea=0, 0x21B8[2], "
        "credit_max=0, dead data)")
    assert perm["force_always"] == 0, (
        "D2: force_always must stay 0 in data mode (never set autonomously — "
        "R4a: force-always is the word-deleter)")
    assert perm["robust"] == 1, (
        "D2: robust_detect must stay 1 permanently (tol-5 framer re-hunt = "
        "drift self-healing against the now-permanent peer beacons)")
    # lane_mask / tol RETAINED across data mode (correct for the deskew).
    assert perm["lane_mask"] == exp_lane_mask, (
        f"D2: lane_mask must be RETAINED at 0x{exp_lane_mask:02x} "
        f"(=wlink_rx_lane_mask) for the deskew, got 0x{perm['lane_mask']:02x}")
    assert perm["tol"] == EXP_SYNC_TOL, (
        f"D2: tol must be retained at {EXP_SYNC_TOL}, got {perm['tol']}")

    log.info("ORDERING/PERSISTENCE VERIFIED: SYNC-ON (training-run) -> winscan "
             "(forced via winscan_force_sync) -> STILL ON at winscan_done -> "
             "fch bootstrap under idle-gated SYNC -> insert_en/robust STILL ON "
             "long after fch_done (D2 permanent beacons); lane_mask/tol "
             "retained for deskew.")
    log.info("VERDICT: PASS — autonomous SYNC-detect config replicates the host "
             "rcp recipe on-chip with the R4a idle-gated beacon held as the D2 "
             "PERMANENT data-mode state (no blind SYNC-OFF).")


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


# ============================================================================
# LOOP-9 (2026-07-03, silicon-root-caused) — MANUAL-RECIPE BEACON AUTHORITY.
#
# The SILICON manual recipe runs with nego_en=1 (NEGO_CFG PORs 0x61 and
# td_v2_hwlib.sh rcp never writes 0x2090) and disarms autonomy ONLY via
# NEGO_TRAIN_CFG 0x210C=0 (train_auto_en=0, the recipe's FIRST write). The
# old drive/winscan/fch gates used nego_en & role_locked — TRUE on every
# manual silicon run — so the winscan FSM kicked on the MANUAL recipe's
# training falls; with the FIX-1 abort-restart the recipe's LAST recal fall
# restarted a ~8 s silicon force-SYNC window (winscan_force_sync ORs into
# insert_en AND force_always at the Wlink ports) that overlapped MANUAL data
# mode: force_always = the R4 word-deleter -> die_b credit_count=4098,
# underrun=1, GP1 zeros, TXSYNC 0x2120=0x5c01ffff, while R8 correctly READ
# 0x10 (the reg was clean; the PORT OR was not). Sim never caught it because
# zero-skew sim beacons are always exact-detected + stripped, so data crosses
# anyway — hence these SIGNAL-LEVEL gates on the actual Wlink port inputs.
# ============================================================================

WS_IDLE = 0
WS_MIDSCAN = {2, 3, 4, 5, 6, 7, 9}


def _wlink_sync_ports(ctrl):
    """The ACTUAL Wlink SYNC port inputs (post any OR-merge) — the nets the
    TX inserter/RX detector really see."""
    return {
        "insert_en":    int(ctrl.u_wlink.swi_sync_insert_en_in.value),
        "force_always": int(ctrl.u_wlink.swi_sync_force_always_in.value),
        "robust":       int(ctrl.u_wlink.swi_sync_robust_detect_in.value),
    }


@cocotb.test()
async def test_v2_manual_recipe_beacon_authority(dut):
    """SILICON-SHAPE manual path: nego_en=1 (POR 0x61) + role_locked +
    train_auto_en=0 (rcp 0x210C=0). After the manual enter_data_mode clears
    R8[2], the WLINK PORT insert_en input must be 0 within N cycles and STAY
    0 (robust bit4 stays 1, force bit3 stays 0 — the manual contract), with
    every autonomous machine dormant. Would have caught the f490dc3 leak."""
    log = dut._log
    log.info("LOOP-9: manual-recipe beacon authority (nego_en=1, auto_en=0)")

    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)
    ctrl = _ctrl(dut, "m")

    # THE SILICON MANUAL CONFIGURATION: nego_en=1 (POR), autonomy disarmed
    # via train_auto_en=0 — the recipe's exact first write.
    _set_nego_en(ctrl, True)
    ctrl.nego_train_cfg_r.value = 0          # rcp: 0x4403210C = 0x0

    # Manual recipe SYNC phase: R8=0x1D equivalent (insert+force+robust set;
    # deposits model the LANDED APB write on the swi_* regs).
    ctrl.swi_sync_insert_en_r.value = 1
    ctrl.swi_sync_force_always_r.value = 1
    ctrl.swi_sync_robust_detect_r.value = 1
    await ClockCycles(dut.hclk, 4)

    # Manual training episode (the recal rise/fall the recipe drives).
    await _training_rise(tb, "m")
    await ClockCycles(dut.hclk, 50)
    await _training_fall(tb, "m")
    await ClockCycles(dut.hclk, 200)

    # Every autonomous machine must be DORMANT despite nego_en=1: the fall
    # must not have kicked the winscan, latched the fch, or fired the drive.
    assert int(ctrl.ws_state_r.value) == WS_IDLE, (
        f"LOOP-9 LEAK: winscan FSM left WS_IDLE on a MANUAL training fall "
        f"(ws_state={int(ctrl.ws_state_r.value)}) — the kick is not scoped "
        f"to train_auto_en")
    assert int(ctrl.winscan_force_sync.value) == 0, \
        "LOOP-9 LEAK: winscan_force_sync high on the manual path"
    assert int(ctrl.winscan_done.value) == 0, \
        "winscan_done set on the manual path"
    assert int(ctrl.fch_pending_r.value) == 0, (
        "LOOP-9 LEAK: fch_pending_r latched on a MANUAL training fall — the "
        "0x208 bootstrap would fire mid-manual-bring-up")
    assert int(ctrl.sync_cfg_hold_q.value) == 0, (
        "LOOP-9 LEAK: sync_cfg_hold_q set on the manual path — the D2 heal "
        "would overwrite manual R8 writes every cycle")

    # Manual enter_data_mode: R8=0x10 (insert=0, force=0, robust KEPT 1).
    ctrl.swi_sync_insert_en_r.value = 0
    ctrl.swi_sync_force_always_r.value = 0
    await ClockCycles(dut.hclk, 16)          # N-cycle authority bound

    # THE PORT-LEVEL GATE: sample the actual Wlink inputs across a long dwell
    # — they must track the regs exactly (dark insert/force, robust up).
    for i in range(100):
        p = _wlink_sync_ports(ctrl)
        assert p["insert_en"] == 0, (
            f"LOOP-9 LEAK (sample {i}): Wlink port swi_sync_insert_en_in=1 "
            f"after the manual R8[2]=0 write — the TX is still beaconing in "
            f"MANUAL data mode (the f490dc3 silicon signature: TXSYNC "
            f"0x5c01ffff with R8 reading 0x10)")
        assert p["force_always"] == 0, (
            f"LOOP-9 LEAK (sample {i}): Wlink port swi_sync_force_always_in=1 "
            f"in manual data mode — the R4 word-deleter is live (credit 4098 "
            f"/ underrun / GP1-zeros signature)")
        assert p["robust"] == 1, (
            f"sample {i}: Wlink port swi_sync_robust_detect_in=0 — the manual "
            f"R8=0x10 contract keeps bit4 (framer re-hunt) up")
        await ClockCycles(dut.hclk, 50)
    # The regs themselves must be untouched (no autonomous rewrite).
    assert int(ctrl.swi_sync_insert_en_r.value) == 0
    assert int(ctrl.swi_sync_force_always_r.value) == 0
    assert int(ctrl.swi_sync_robust_detect_r.value) == 1

    # Paranoid manual recal INSIDE data mode: another rise/fall must change
    # nothing (the fall is the winscan/fch arming edge — still scoped out).
    await _training_rise(tb, "m")
    await ClockCycles(dut.hclk, 20)
    await _training_fall(tb, "m")
    await ClockCycles(dut.hclk, 200)
    p = _wlink_sync_ports(ctrl)
    assert p["insert_en"] == 0 and p["force_always"] == 0, (
        f"LOOP-9 LEAK: a manual mid-data recal re-lit the beacons "
        f"(ports={p})")
    assert int(ctrl.ws_state_r.value) == WS_IDLE and \
        int(ctrl.fch_pending_r.value) == 0, \
        "LOOP-9 LEAK: mid-data manual recal woke the autonomous machinery"

    log.info("VERDICT: PASS — with nego_en=1 (silicon POR) + train_auto_en=0 "
             "(the rcp disarm) every R8 write is authoritative AT THE WLINK "
             "PORTS: insert/force dark in data mode, robust kept, winscan/fch/"
             "drive all dormant across manual training falls.")


@cocotb.test()
async def test_v2_disarm_parks_winscan(dut):
    """LOOP-9 escape hatch: writing 0x210C=0 (train_auto_en=0) while the
    winscan FSM is MID-SCAN must PARK it immediately — force-SYNC drops at
    the Wlink port within a few cycles, tap ownership returns to the APB
    regs, winscan_done clears, and the fch pending latch is flushed. This is
    the documented on-silicon recovery from a live force window."""
    log = dut._log
    log.info("LOOP-9: mid-scan disarm parks the winscan (0x210C=0 escape hatch)")

    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)
    ctrl = _ctrl(dut, "m")

    # Arm the REAL autonomous path (nego_en=1, train_auto_en=1 explicit) and
    # kick a scan (training fall). Eye model keeps the metric live.
    _set_nego_en(ctrl, True)
    ctrl.nego_train_cfg_r.value = 1          # train_auto_en=1 (armed)
    ctrl.tb_winscan_dwell_short_q.value = 1
    ctrl.tb_fch_dwell_short_q.value = 1
    ctrl.tb_ws_anchor_short_q.value = 1
    cocotb.start_soon(_sync_dist_model(tb, "m", TAP_OPT, ACTIVE_LANES))
    await _training_rise(tb, "m")
    await ClockCycles(dut.hclk, 20)
    await _training_fall(tb, "m")

    # Wait until demonstrably mid-scan with force up.
    waited = 0
    while waited < 100_000:
        await ClockCycles(dut.hclk, 20)
        waited += 20
        if int(ctrl.ws_state_r.value) in WS_MIDSCAN and \
           int(ctrl.winscan_force_sync.value) == 1:
            break
    assert int(ctrl.ws_state_r.value) in WS_MIDSCAN, \
        "scan never started — cannot exercise the disarm-park arc"
    log.info(f"mid-scan at ws_state={int(ctrl.ws_state_r.value)} "
             f"force={int(ctrl.winscan_force_sync.value)} — disarming (0x210C=0)")

    # THE DISARM (the manual recipe's first write, mid-scan this time).
    ctrl.nego_train_cfg_r.value = 0
    await ClockCycles(dut.hclk, 8)

    assert int(ctrl.ws_state_r.value) == WS_IDLE, (
        f"DISARM-PARK failed: ws_state={int(ctrl.ws_state_r.value)} != IDLE "
        f"after train_auto_en=0 — a stuck force window would ride into "
        f"manual data mode")
    assert int(ctrl.winscan_force_sync.value) == 0, \
        "DISARM-PARK failed: winscan_force_sync still high"
    assert int(ctrl.winscan_owns_taps.value) == 0, \
        "DISARM-PARK failed: FSM still owns the taps (APB taps must rule)"
    assert int(ctrl.winscan_done.value) == 0, \
        "DISARM-PARK: winscan_done left set"
    assert int(ctrl.fch_pending_r.value) == 0, \
        "DISARM-PARK: stale fch_pending_r survived the disarm"
    p = _wlink_sync_ports(ctrl)
    assert p["force_always"] == int(ctrl.swi_sync_force_always_r.value), \
        f"port force_always diverges from the APB reg after disarm ({p})"
    assert p["insert_en"] == int(ctrl.swi_sync_insert_en_r.value), \
        f"port insert_en diverges from the APB reg after disarm ({p})"

    log.info("VERDICT: PASS — 0x210C=0 mid-scan parks the FSM within cycles: "
             "force dark, taps back to APB, done/pending flushed — R8 "
             "authority restored instantly (the on-silicon escape hatch).")
