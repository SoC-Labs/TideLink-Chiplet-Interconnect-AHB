"""The LAST autonomy layer — autonomous SYNC-detect config drive.

Goal
----
Prove that, on the AUTONOMOUS (nego_en) path with ZERO host pokes to the
SYNC-detect registers, the autoneg-driven config block in
axi_chiplet_controller.sv ("AUTONOMOUS SYNC-DETECT CONFIG DRIVE") replicates the
host rcp() SYNC-detect configuration on-chip and SEQUENCES it correctly:

    training-RUN (swi_training_mode_r 0->1, nego_en & role_locked)
        -> SYNC-ON  : swi_sync_lane_mask_r := 0xE4   (rcp 0x2128[7:0])
                      swi_sync_tol_r       := 5      (rcp 0x2128[12:8])
                      swi_sync_insert_en_r/force_always/robust := 1 (rcp R8=0x1D)
                      word-pin override := 0 / auto_dis := 0  (rcp 0x2104=0, AUTO)
    ... winscan runs (forces SYNC itself), deskew reanchor latches ...
    winscan_done 0->1
        -> SYNC-OFF : swi_sync_insert_en_r/force_always/robust := 0 (= host
                      enter_data_mode R8=0x10 SYNC-off AFTER reanchored), while
                      lane_mask=0xE4 / tol=5 are RETAINED for the deskew.

The ORDERING invariant the prompt requires — the autonomous SYNC-ON write
strictly precedes the SYNC-OFF — is asserted directly: SYNC-ON fires on the
training-mode rising edge, SYNC-OFF only after winscan_done rises (which can
only happen after the scan + finalize, i.e. after reanchor). This mirrors the
existing FC-handoff sequencer's R8=0x10 step being driven AFTER reanchor.

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
EXP_LANE_MASK = 0xE4   # rcp R_SYNCTOL 0x2128[7:0]
EXP_SYNC_TOL  = 5      # rcp R_SYNCTOL 0x2128[12:8]


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

    # ---- Arm the autonomous path + model the silicon eye -------------------
    # nego_en=1 (= production strap stand-in). Eye model so the winscan reaches
    # winscan_done (needed to observe the SYNC-OFF edge). dwell-shrink hook.
    _set_nego_en(ctrl, True)
    ctrl.tb_winscan_dwell_short_q.value = 1
    cocotb.start_soon(_sync_dist_model(tb, "m", TAP_OPT, ACTIVE_LANES))
    await ClockCycles(dut.hclk, 5)

    # ---- SYNC-ON: training-RUN rising edge applies the rcp config ----------
    await _training_rise(tb, "m")
    on = _read_sync_cfg(ctrl)
    log.info(f"after training-RUN (SYNC-ON): {on}")

    assert on["lane_mask"] == EXP_LANE_MASK, (
        f"SYNC-ON: lane_mask did NOT become 0x{EXP_LANE_MASK:02x} "
        f"(got 0x{on['lane_mask']:02x}) — autonomous SYNC-detect config did not "
        f"fire on the training-run edge")
    assert on["tol"] == EXP_SYNC_TOL, (
        f"SYNC-ON: tol did NOT become {EXP_SYNC_TOL} (got {on['tol']})")
    assert on["insert_en"] == 1, "SYNC-ON: insert_en (SYNC_EN) not set"
    assert on["force_always"] == 1, "SYNC-ON: force_always not set"
    assert on["robust"] == 1, "SYNC-ON: robust_detect not set"
    assert on["wp_ovr"] == 0 and on["wp_auto_dis"] == 0, (
        "SYNC-ON: word-pin not AUTO (rcp 0x2104=0): "
        f"ovr=0x{on['wp_ovr']:x} auto_dis={on['wp_auto_dis']}")

    log.info("SYNC-ON verified: lane_mask=0xE4 tol=5 insert_en/force_always/"
             "robust=1 word-pin=AUTO (rcp R8=0x1D + 0x2128=0x5e4 replicated)")

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
    # Let the SYNC-OFF edge (winscan_done 0->1) propagate one apb cycle.
    await ClockCycles(dut.hclk, 5)
    off = _read_sync_cfg(ctrl)
    log.info(f"after winscan_done (SYNC-OFF): {off}  (winscan_done@{w} cyc, "
             f"{w * CLK_PERIOD_NS / 1000:.1f} us)")

    assert off["insert_en"] == 0, (
        "SYNC-OFF: insert_en did NOT drop after winscan_done — data path would "
        "keep flooding SYNC (host enter_data_mode R8=0x10 not replicated)")
    assert off["force_always"] == 0, "SYNC-OFF: force_always did not drop"
    assert off["robust"] == 0, "SYNC-OFF: robust_detect did not drop"
    # lane_mask / tol RETAINED across data mode (correct for the deskew).
    assert off["lane_mask"] == EXP_LANE_MASK, (
        f"SYNC-OFF: lane_mask must be RETAINED at 0x{EXP_LANE_MASK:02x} for the "
        f"deskew, got 0x{off['lane_mask']:02x}")
    assert off["tol"] == EXP_SYNC_TOL, (
        f"SYNC-OFF: tol must be retained at {EXP_SYNC_TOL}, got {off['tol']}")

    log.info("ORDERING VERIFIED: SYNC-ON (training-run) preceded SYNC-OFF "
             "(after winscan_done/reanchor); lane_mask/tol retained for deskew.")
    log.info("VERDICT: PASS — autonomous SYNC-detect config replicates the host "
             "rcp recipe on-chip with the correct SYNC-ON-before-SYNC-OFF order.")


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

    log.info("VERDICT: PASS — manual/SW path unaffected (drive dormant at "
             "nego_en=0; POR defaults held across training rise/fall).")
