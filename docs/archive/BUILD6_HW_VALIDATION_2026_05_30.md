# Build #6 (F-1 + F-1.5) HW validation — CATASTROPHIC FAILURE

**Date:** 2026-05-30 10:55-11:00 BST
**Build:** #6 (ILA-instrumented, `FPGA_INSERT_DEBUG_CORE=1`, F-1 watchdog + F-1.5 forced state-7→state-4)
**Commit built:** `09cc0ec` on `fix/fcsm-l7-wedge-watchdog`
**Build SHAs:** master sha256 `09e35b9c…` md5 `a07f1235…`; slave sha256 `18578544…` md5 `5278415f…`
**Wall:** 105m27s (master local, slave srv04936)
**Sim sanity (cocotb F-1.5 verification):** state → 4 confirmed, returner_busy clears, doorbell delivery 0/10 (Force-injection artefact noted)

## ⚠️ HW outcome: master z2_02 WEDGED PS to unrecoverable state on first deploy

Sequence:
1. Deploy #1 of build #6 → both bitstreams loaded cleanly, deploy_pair.sh reported `done`.
2. Wrote `SWI_TRAINING_MODE=1` on both sides via `td_set_train.py` — slave responded OK with `LANE_STATUS=0x000200ff lock=0xff cd=0`.
3. Rang 100 doorbells on master via APB write to 0x44032014.
4. Immediately after the ring: **master SSH dead with `No route to host`**.
5. Subsequent 4 deploy attempts: `DEPLOY-FAIL: z2_02 @ 192.168.4.101: GIVING UP after 2 load attempts — board NOT in 'operating' state`.
6. `fpgahub board reset pynq_z2_02_ps --method uart` returned `ok` but z2_02 stayed unresponsive for 40+ seconds of polling.
7. **Board needs physical power-cycle** — fpgahub hub uhubctl power-cycle is not configured for these boards (`HTTP 400: no hub_switch reference`).

## What this means

F-1.5 is significantly worse than F-1 alone or the pre-fix baseline. Possible reasons:

1. **Multi-driver / undefined-behaviour synthesis race.** F-1.5 adds a new priority clause to the FCSM `state` always-block. Vivado may have synthesized this without warning, but the actual silicon FF could be metastable or driven incorrectly, leading to undefined FCSM behaviour that hangs the AXI-Lite-to-AHB bridge → PS kernel hangs the moment any APB write touches that path.

2. **AHB bus wedge cascading from FCSM.** If forcing state → 4 leaves Wlink's TX FIFO state inconsistent, the FC adapter's response back to the APB transaction may hang `pready`, and SmartConnect would stall the PS write indefinitely. PS Linux watchdog can't recover from this once kernel space is stuck in `mmap` write to /dev/mem.

3. **The doorbell ring path itself is the trigger.** APB write to 0x44032014 — if this triggers a sideband packet through the FCSM that hits the forced-state-4 condition mid-flight, the result could be even worse than the build #5 sticky-busy.

The fact that BUILD #5 (F-1 only) was symptom-stuck-but-recoverable while BUILD #6 (F-1 + F-1.5) is catastrophic suggests F-1.5 introduced a NEW failure mode, not just failed to fix the old one.

## Lease released. State of artefacts

- Build #6 bins backed up on mapstone-dev: `/tmp/tidelink_deploy/{tidelink,tidelink-flip}.bin` (currently active)
- Build #5 bins: `/tmp/tidelink_deploy/*.build5-bak`
- Build #4 bins: `*.build4-bak`
- Build #3 bins: `*.build3-bak`

To restore to a known-working state: `cp /tmp/tidelink_deploy/tidelink.bin.build3-bak /tmp/tidelink_deploy/tidelink.bin` (and same for `-flip`).

## Required next actions

1. **Physical power-cycle of z2_02** — needs human intervention (no remote PS power switch configured in fpgahub).
2. **Once z2_02 returns**: redeploy build #3 to confirm boards are healthy.
3. **Revert F-1.5** on `fix/fcsm-l7-wedge-watchdog` — commit `09cc0ec` should be reverted, leaving F-1 alone (which was at least recoverable on HW).
4. **Re-think the F-1.5 design** — the "force state→4" approach may need a different mechanism. Options to consider:
   - Force via a synchronous-reset path with proper sequencing
   - Use a separate state-override signal that the FCSM's existing always-block consumes (single-driver pattern)
   - Apply only to a shadowed copy of the state, not the live state
   - Insert a 1-cycle reset on LL_TX simultaneously with state forcing
5. **Sim test cannot catch this**: H's existing sim test_post_watchdog_doorbell_delivery passes F-1.5 because it uses cocotb Force which behaves nothing like real silicon. A more realistic sim test would need to model real bringup + watchdog firing during natural traffic — which the existing tests don't.

## Lessons learned

- Don't add priority clauses to existing always-blocks without checking whether Vivado generates a clean FF; might need explicit `always_ff` + `unique case` patterns.
- F-1.5's sim "success" was misleading because the test used Force() which doesn't expose multi-driver hazards.
- Build #6 is silicon-validated to be WORSE than build #5 — keep it off the deploy path.
