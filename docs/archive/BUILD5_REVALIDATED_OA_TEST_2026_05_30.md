# Build #5 RE-VALIDATED — the "downstream wedge" was a TEST ARTEFACT

**Date:** 2026-05-30 12:30-13:00 BST
**Build under test:** #5 (commit `f10e6fe` on `fix/fcsm-l7-wedge-watchdog`, F-1 watchdog only) — same bins as `BUILD5_HW_VALIDATION_2026_05_29.md`
**Test recipe change:** **DO NOT** call `td_set_train.py` after deploy. Skip the `SWI_TRAINING_MODE=1` write entirely.
**Lease:** acquired 12:16 BST, released after test.

## Headline

**Build #5 functionally delivers M→S doorbells when the test does NOT write `SWI_TRAINING_MODE`.**

Per Agent Q's strategic options doc, the multi-deploy test recipe `/tmp/multi_deploy_test.sh` had been writing `SWI_TRAINING_MODE=1` on both sides before ringing doorbells. Per RTL gates:
- `WavD2DGpioTx.v:252-256` substitutes training pattern for FC bytes when `training_mode_tx` is high
- `Wlink.v:1952` holds peer LL_RX in reset when `training_mode_rxsync` is high

So when both sides held training_mode HIGH, doorbells were RTL-suppressed at the TX mux, never reached the slave, and the master's returner ended up in a "busy" state that LOOKED like a wedge but was actually correct behaviour for a downstream sink that's intentionally stalled.

## Verified results (build #5, no training_mode write)

```
=== O-A TEST: build #5 deployed, NO training_mode write ===
--- master  ---
LANE_STATUS=0x23890000 lock=0x00 cd=1 TM=0
--- slave   ---
LANE_STATUS=0x01890000 lock=0x00 cd=1 TM=0
=== Master rang 100 doorbells ===
rang 100
slave DB_RESP=65535  REG_STATUS=0x00000000  LANE_STATUS=0x01890000   ← DELIVERED, SATURATED
master REG_STATUS=0x00000000                                        ← NOT busy
```

- **M→S doorbells DELIVERED**: slave `REG_DOORBELL_RESP_ACC` saturated at `65535` (16-bit max). 100 master rings → many credits crossed.
- **Master returner_busy = 0**: NO sticky wedge.
- **lock=0x00 + cd=1 both sides**: PHY layer fine; lane_checker can't match the FC payload because training pattern isn't being driven — that's CORRECT post-bringup behaviour. `cal_done=1` is the proper health gate (per `docs/HANDOFF_REPORT_2026_05_29.md` §6).

## What this means

**The entire build #4 → #5 → #6 chain was chasing a phantom bug.** The "downstream wedge" did not exist at silicon. It existed only in the multi-deploy test recipe that wrote `SWI_TRAINING_MODE=1`. Specifically:
- Build #4's "FCSM stuck at state 7" was likely real (placement-perturbation triggered an L7 NACK trap that the existing forgive gate couldn't clear) BUT
- The doorbell tests on build #4 / #5 / #6 weren't measuring whether the FCSM wedge actually blocked traffic — they were measuring whether `SWI_TRAINING_MODE=1` blocks doorbells (it does, that's the design).
- F-1 (watchdog clearing send_nack_req) presumably DID fix the build #4 FCSM wedge — we just couldn't tell because the doorbell test was confounded.
- F-1.5 was unnecessary. Its catastrophic HW failure (build #6 PS kernel-hang) was the only real consequence of the "fix".

## Remaining real bugs (pre-existing, NOT session-caused)

These persist on build #5 with the corrected test recipe:

| Bug | Symptom | Notes |
|---|---|---|
| **A** AHB packet RX at slave | TX completes (`PASS_TX n=1 0.17ms`) but slave AHB_FIFO reads `RX n=0` | Long-standing — see `docs/DEMUX_ISSUE_DETAILED_REPORT_2026_05_29.md`. Not caused by F-1 / F-1.5. |
| **B** PTP HW_SYNC at slave | Slave `PTP_STATUS` bit[2] = 0; master `PTP_CTRL` write 0x0d reads back 0x05 (bit 3 GM-mode not sticking) | Pre-existing — `docs/BUG_DIAGNOSES_2026_05_29.md`. Slave-RX gate + master initiator bit 3 stickiness both real. |
| **C** S→M doorbell direction | Slave rings 100 doorbells → master `REG_DOORBELL_RESP_ACC` stays at 0 | New observation. Slave-as-initiator may need separate config (cfg=1 might gate doorbell direction). Pre-existing. |

## Forensic explanation of the build #6 catastrophe (Agent R)

Even though F-1.5 turned out to be unnecessary, Agent R's Vivado forensics nailed down EXACTLY why it crashed when implemented:

- **NOT a synthesis pathology.** F-1.5 synthesized cleanly: no multi-driver, no latch inference, no async-reset issue, no timing violations (WNS +26 ns, 0 failing endpoints). The `state` FF stayed as 3× FDCE; F-1.5 added one LUT level to the D-input mux and nothing else.
- **Real cause: FSM consistency violation across companion registers.** The Chisel-emitted FCSM uses a single-FSM-controls-many-registers pattern. **Ten** other always_blocks gate on `state == 3'h7` and execute their state-7 housekeeping based on the OLD `state` value. F-1.5 forced `state ← 4` in one cycle, so the companion blocks saw `state==7` for case-arm selection but the state register said "we've left". Result: one cycle where the FSM says "exited via auto_tx_out_advance" but the LL_TX bus did NOT advance → peer receives a malformed/truncated NACK header.
- **Hang propagation chain** (cited file:line in `BUILD6_VIVADO_FORENSICS_2026_05_30.md` §5):
  - Slave `rx_state_r` ([tidelink_fc_adapter.sv:474](src/rtl/tidelink_fc_adapter.sv#L474)) lands in `RX_ADDR_PHASE` with `!rx_is_fifo && !rx_is_ext` →
  - `rx_cfg_active = 1` ([line 524](src/rtl/tidelink_fc_adapter.sv#L524)) →
  - `fc_rx_cfg_psel = 1` ([line 528](src/rtl/tidelink_fc_adapter.sv#L528)) →
  - `fc_cfg_apb_psel` ([tidelink_top.sv:670](src/rtl/tidelink_top.sv#L670)) → **`tl_regs_pready = 0`** ([line 931](src/rtl/tidelink_top.sv#L931)) for the entire APB region.
  - Returner's cross-link AHB write (triggered by the LOCAL APB doorbell write at `0x44032014`) stalls → SmartConnect holds AXI-Lite → PS Linux `mmap` write hangs in uninterruptible kernel I/O → physical power-cycle required.
- **Why sim missed it**: H's `Force()` bypasses the very FSM-consistency hazard the bug exploits.
- **Recommended F-1.5 redesign** (R's Option B): wrap `auto_tx_out_advance` to OR-in `socl_l7_wdog_force_clear` so the FCSM exits state-7 via the existing well-tested `_GEN_115` arc — all companion registers update consistently.

This corroborates P's "partner-register desync" hypothesis and E's earlier pointer-rewind concern. Three independent agents convergently identified the same RTL mechanism via three different framings.

If F-1.5 is ever revisited (it isn't needed per the test-methodology fix above, but if it were), Option B is the safe pattern.

## Lessons learned for future autonomous loops

1. **Validate the test recipe BEFORE concluding silicon is broken.** Agent G surfaced the training_mode hypothesis early; subsequent loops should have given it more weight before committing to 3 unnecessary FPGA build cycles (~6 wall hours + 1 unrecoverable PS hang requiring physical intervention).

2. **The Force-based sim test was misleading.** It passed F-1.5 because cocotb `Force()` doesn't model multi-driver synthesis hazards. The agent that designed the sim test (H) explicitly flagged this limitation in §7 of its doc — should have been a stronger warning sign.

3. **HW catastrophic failures (PS hang requiring physical power-cycle) are RTL-design Class-A warnings.** Any next F-1.5 redesign must validate that the proposed pattern can't multi-drive or breach reset semantics, ideally via Vivado synth-only sanity build BEFORE deploying to silicon.

## What's now on origin

- `fix/fcsm-l7-wedge-watchdog` @ `cbcd4ef` — F-1 only, F-1.5 reverted, sim regression tests preserved
- `sim/l7-wedge-repro` and `sim/l7-wedge-repro-postwdog` — H's regression tests
- `main` — build #3 era; should consider merging F-1 from the fix branch once we decide if it's actually needed (per this revalidation, even F-1 may not be needed — see "do nothing" option in Q's strategy doc)

## Recommended next steps (in priority order)

1. **Re-test build #3 with the corrected recipe** — if it also delivers, F-1 is unnecessary; ship build #3 as v1
2. **Investigate Bug A independently** — different workstream, separate diagnosis (Bug A's root cause is FC RX FSM `rx_pkt_type` decode per `BUG_DIAGNOSES_2026_05_29.md` §A-1, not FCSM-related)
3. **Investigate Bug B independently** — master PTP_CTRL bit 3 stickiness is a separate diagnostic; needs APB tracing
4. **Investigate S→M asymmetry** — never previously characterized; may need slave-side role-cfg deep-dive
5. **Decide on F-1 disposition** — keep on fix branch as defence-in-depth, OR merge to main + ship, OR remove entirely if revalidation shows it's not needed
