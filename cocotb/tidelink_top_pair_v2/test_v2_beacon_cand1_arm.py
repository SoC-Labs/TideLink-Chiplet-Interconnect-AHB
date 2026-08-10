# =============================================================================
# BEACON CANDIDATE-1 NON-VACUITY (2026-08-10) — does the autonomous SYNC-config
# one-shot arm at LINK-UP when training NEVER rises?
#
# Cand-1 (axi_chiplet_controller.sv ~:2361/:2382) fires the one-shot on
#   (swi_training_mode_r || sync_obs_fcsm_state_1[2])          [training OR link-up]
# instead of `swi_training_mode_r` alone. The rank-1 dead-I2C bare-link bug: NEGO
# NACK-parks, swi_training_mode_r NEVER rises, so the shipping (training-only)
# one-shot never fires -> detector stays POR (insert_en=0, tol=0) -> all-zeros.
#
# The one-shot SET is scoped to `if (autonomy_armed)` (nego_en & role_locked &
# nego_train_cfg_r[0] & ~autonomy_retire_q). The "link-up WITHOUT prior training"
# state is intrinsically the BROKEN dead-I2C state — a healthy autonomous flow
# always raises training BEFORE link-up, so no natural bring-up reaches it. We
# therefore reconstruct it directly: after role/cal bring-up, FORCE autonomy_armed=1
# (idiom already used elsewhere in this suite) and FORCE sync_obs_fcsm_state_1=4
# (link-up, bit[2]=1) while holding swi_training_mode_r=0.
#
# A/B (operator runs both; the ONLY delta is the controller RTL):
#   A cand-1  (current tree)                    -> PASS  (fired=1, insert_en=1, tol=5)
#   B baseline(one-shot = training-only, HEAD)  -> FAIL  (fired=0, insert_en=0, tol=0)
#
# Discriminator = tol (POR 0 vs cand-1 5) + insert_en + fired; mask is NOT used
# (wlink_rx_lane_mask==0xFF==POR on a clean 8-lane sim).
#
# Run: make EPOCH_PROFILE=zero MODULE=test_v2_beacon_cand1_arm
# =============================================================================
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from pair_v2_common import PairV2TB
from test_v2_winscan_fsm import _ctrl, _bringup_to_role_cal


def _si(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError):
        return default


def _probe(ctrl):
    return {
        "autonomy":  _si(ctrl.autonomy_armed),
        "training":  _si(ctrl.swi_training_mode_r),
        "linkup":    (_si(ctrl.sync_obs_fcsm_state_1) >> 2) & 1,
        "fired":     _si(ctrl.sync_cfg_on_fired_q),
        "insert_en": _si(ctrl.swi_sync_insert_en_r),
        "tol":       _si(ctrl.swi_sync_tol_r),
        "mask":      _si(ctrl.swi_sync_lane_mask_r),
    }


@cocotb.test()
async def test_cand1_sync_cfg_arms_at_linkup_without_training(dut):
    """Cand-1 arms the SYNC config at link-up with training held 0. On BASELINE
    (training-only one-shot) it does NOT — the rank-1 dead-I2C all-zeros bug."""
    tb = PairV2TB(dut)
    await _bringup_to_role_cal(tb)

    ctrl = _ctrl(dut, "m")

    # --- POR pre-condition: SYNC config dark (the shipping dead-I2C state) ---
    pre = _probe(ctrl)
    tb.log.info(f"[cand1-arm] pre (POR): {pre}")
    assert pre["insert_en"] == 0 and pre["tol"] == 0 and pre["fired"] == 0, (
        f"pre-config not at POR ({pre}) — bring-up already armed the SYNC config; "
        f"the reconstruction below would not isolate cand-1's link-up trigger.")

    # --- Reconstruct the dead-I2C 'link-up, training never rose' state ---
    ctrl.swi_training_mode_r.value = 0                 # training HELD low (deposit holds)
    ctrl.autonomy_armed.value      = Force(1)          # nego path armed (the SET gate)
    ctrl.sync_obs_fcsm_state_1.value = Force(4)        # FCSM data region -> link_up bit[2]=1
    await ClockCycles(dut.hclk, 40)                    # let the apb_clk one-shot resolve

    post = _probe(ctrl)
    tb.log.info(f"[cand1-arm] post (autonomy=1, link_up=1, training=0): {post}")

    # release forces before asserting (so a failure dump is clean)
    ctrl.autonomy_armed.value = Release()
    ctrl.sync_obs_fcsm_state_1.value = Release()

    # --- Non-vacuous context: the reconstruction is the intended one ---
    assert post["autonomy"] == 1, f"autonomy_armed force did not hold ({post})"
    assert post["linkup"] == 1,   f"link-up force did not hold ({post})"
    assert post["training"] == 0, (
        f"swi_training_mode_r={post['training']} != 0 — training leaked high, so a "
        f"pass could ride the training path instead of cand-1's link-up trigger.")

    # --- THE CAND-1 CLAIM (FAILS on the baseline training-only one-shot) ---
    assert post["fired"] == 1, (
        "BASELINE would show sync_cfg_on_fired_q=0: training-only one-shot never "
        "fires with training=0. Cand-1 fires it on link-up.")
    assert post["insert_en"] == 1, (
        f"swi_sync_insert_en_r={post['insert_en']} (expected 1). Baseline leaves it 0 "
        f"(SYNC beacon DARK) == the rank-1 dead-I2C all-zeros root cause.")
    assert post["tol"] == 5, (
        f"swi_sync_tol_r={post['tol']} (expected 5). Baseline stays POR 0. This is the "
        f"clean discriminator: 0 vs 5, independent of lane health.")

    tb.log.info(f"VERDICT: cand-1 armed SYNC config at link-up with training=0 "
                f"(fired=1, insert_en=1, tol=5, mask=0x{post['mask']:02x}).")
