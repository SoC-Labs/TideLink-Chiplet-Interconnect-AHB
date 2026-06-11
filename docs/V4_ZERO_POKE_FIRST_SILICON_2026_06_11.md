# V4 Zero-Poke — First Silicon Attempt (2026-06-11 ~00:40)

**Result: PARTIAL SUCCESS — autonomous role resolution + calibration + one-sided
link-up with ZERO APB writes.** First-ever zero-poke attempt on bridge1
(PLAN_TIDELINK_INTEGRATION §3 I5 / §4 V4), image `v34-i2-autonomy`
(commit `6e22f98`, manifests staged at `~/tidelink_artefacts/v34` on
mapstone-dev).

## Procedure

Flash-only deploy on both dies (scp + fpga_manager sysfs load — the
`deploy_pair.sh` poke section *not* run), 20 s settle, APB **reads** only.
Image canary `0x44032190 = 0x4F420100` confirmed v34 on both dies.

## Observations (Region 4 NEGO_STATUS @0x094, ROLE @0x084, SWI_LANE @0x108)

| | die_a (z2_02, strap=0) | die_b (z2_03, strap=1) |
|---|---|---|
| autoneg | `lost=1`, parked ST_NEGO_DONE | `won=1`, walked to ST_TRAIN_DONE |
| role_locked / role | **1 / slave** | **1 / master** |
| cal_done | **1** | **1** |
| FCSM / cr / ck | **4 (LINK_IDLE)** / 1 / 1 | 2 (CREDITS_ACK_WAIT) / 1 / **0** |

## What this proves

1. **The P15/P16 I2C harness is wired and functional** — `won`/`lost` are
   complementary across the dies; arbitration cannot resolve asymmetrically
   without a live bus.
2. **POR autonomy works on silicon**: `NEGO_CFG_RESET=0x61` +
   `NEGO_TRAIN_CFG_RESET` + strap priority engage autoneg, run the I2C
   mask-handshake + training sub-flow, lock roles, and run the calibrator —
   no software anywhere.
3. **test_24's role-swap finding reproduced on silicon**: the parallel
   flashes complete seconds apart; the early die exhausts its solo claim and
   parks ST_NEGO_DONE-lost (slave), the late die wins unopposed (master).
   Boot order beat strap preference, exactly as the sim gate predicted.

## The remaining gap

die_b never decodes die_a's CRACK (stable `fcsm=2, ck=0` while die_a sits at
`fcsm=4, cr=1, ck=1`). One-directional short-packet decode failure = the
documented marginal-eye residual (AUTOCAL_CLOSURE residuals #1/#2 family).
The SW-coordinated flow papers over this with the converge loop's re-deploy
lottery + M12 bootstrap; the autonomous flow has no such crutch, so it parks.

**Conclusion: the autonomy stack (L3) is silicon-proven end-to-end; the
blocker for full zero-poke bilateral link-up is the old PHY's marginal RX
eye — precisely what the new PHY (Hamming-threshold checker + PHY-owned
deskew, tidelink-gpio-phy-deskew) replaces.** Re-attempt V4 after the S2/S3
PHY integration rather than hardening the old PHY further.
