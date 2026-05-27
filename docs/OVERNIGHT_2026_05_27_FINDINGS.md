# Overnight bring-up debug session — findings 2026-05-26→27

## Builds completed

| Build | RTL | HW result |
|---|---|---|
| tdif-20 | AUTOCAL=0 (no calibrator) | FAIL: PHY can't byte-align without calibrator on real ribbon-skew |
| tdif-21 | Calibrator (0,0) snap-back + AUTOCAL=1 restored | FAIL: (0,0) never locks on HW → fix is no-op; slave cal_done=0 stuck |
| tdif-22 | + BRINGUP_SAFETY_TIMEOUT_SWEEPS=16 watchdog + cal_state ILA | PARTIAL: both cal_done=1 reliably, but FCSM lottery persists |
| tdif-23 | + full doorbell-path ILA probes (commit aac8afc) | DIAGNOSTIC: now have observability for all doorbell-path gates |

## What we proved

1. **BRINGUP_SAFETY_TIMEOUT_SWEEPS watchdog works** (commits 3ed1fc5 + a08e350). Both calibrators reliably reach S_DONE within ~16 sweeps. Unblocks the cal_done=0 deadlock seen on tdif-18/19/21.

2. **Per-direction (phase, slip) lottery persists at the calibrator level**. The calibrator scores phase/slip per lane based on T3A comma-hunt during training, but the chosen point doesn't reliably decode actual data packets. Same RTL, different deploys produce different end-states.

3. **SW recal cycle does NOT re-roll the lottery**. 4 deploys × 16 recals = 0 doorbells crossed. The calibrator deterministically picks the same (phase, slip) per deploy startup state.

4. **SW phase_offset sweep**: 6/16 (M, S) combos reach bilateral LINK_IDLE on tdif-22:
   - `(0,0), (1,3), (2,2), (3,0), (3,1), (3,3)`
   - **In ALL 6, doorbells DO NOT CROSS**. Silent link mode.

5. **Asymmetric direction failure dominates**. Most deploys land:
   - Master receives slave's CR packet → advances to SEND_CREDITS2; never receives CRACK → stuck
   - Slave can't receive master's CR → stuck at SEND_CREDITS1
   - OR mirror image (slave receives, master doesn't)
   - One direction's RX is fundamentally broken per deploy due to lottery pick

6. **One successful run early in the session** (`converge_retry` attempt 1, tdif-22): both at LINK_IDLE + S_DOORBELL_RESP went 0 → 0x2000. NOT reproducible across 4+8 subsequent attempts. Confirms it's a lottery outcome, not a deterministic fix.

## ILA evidence at the FCSM RX boundary (tdif-23 passive)

**SLAVE** (when calibrator completes cleanly):
- `rx_in_sop=1` for ~28% of cycles, `rx_in_data_id=0x01` for ALL receiving cycles
- `pkt_is_data_pkt=0` always — slave doesn't classify 0x01 as data (data_id=0xa1 expected)
- 0x01 is likely the CR packet ID — slave IS receiving and correctly identifying CR

**MASTER**:
- `rx_in_sop=0` for ALL 4096 samples — master's RX is completely deaf
- Calibrator at S_DONE with cal_done=1
- Master's chosen (phase, slip) on its RX path doesn't decode slave's TX bits

## Root cause (current best hypothesis)

The calibrator's "lock" criterion is **too permissive** for the actual data path. It scores based on per-lane T3A comma-hunt within the training pattern, which is repetitive and forgiving. The chosen (phase, slip) often passes the training criterion but is on the EDGE of the timing eye, so when the training stops and arbitrary data bits arrive, the deserialiser samples wrong.

This is why:
- cal_done asserts (training validation passed)
- FCSM enters LINK_IDLE (credit exchange uses simple repetitive packets)
- Real data packets get sampled wrong → silent link

The bug is at the calibrator's **scoring** mechanism, not its FSM control flow.

## Possible fixes (not yet built)

**Fix A — Validate phase/slip with real packets, not just training.** After T3A reports lock, hold the link in a "validation phase" where master sends a known data packet pattern with the actual `swi_data_id_1` value, and the receiver checks decode integrity. Re-arm sweep if decode fails.

**Fix B — Per-direction handshake after S_DONE.** Each side broadcasts a unique "hello" packet over the data path; the receiver acks via a side channel. If hello not received within N cycles, force re-sweep with phase offset perturbed.

**Fix C — Smarter scoring with margin requirement.** Instead of "is locked", require "lock holds across a 3-cycle phase window" — picks the centre of the eye not the edge.

**Fix D — Tap into wlink_pair sim test infrastructure** to find the exact threshold/scoring boundary that produces unreliable picks. Adjust LOCK_THRESH or sweep granularity.

All of these are non-trivial RTL changes (multi-hour iterations). Recommend prioritising Fix C as the lowest-risk + likely-highest-impact.

## Files of interest

- `src/rtl/tidelink_phy_align_calibrator.sv` — calibrator FSM (commits 1070375, 3ed1fc5)
- `src/rtl/local_overrides/WavD2DGpioRx.v` — T3A FSM and re-arm logic (L11 EDGE)
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v` — credit clamp + FCSM observability (L10)
- `src/rtl/tidelink_top.sv:1880` — cal_state + doorbell-path ILA probes (a08e350, aac8afc)
- `pynq_host/scripts/investigate_passive_vs_converge.sh` — dual-die ILA capture harness
- `pynq_host/scripts/phase_sweep_tdif22.sh` — 4×4 (M_PHASE, S_PHASE) sweep
- `pynq_host/scripts/targeted_doorbell_ila.sh` — doorbell-triggered ILA capture

## ILA artefact paths on mapstone-dev (for replay)

- `/home/david/td_milestone_stage/investigate_tdif{20,21,22,23}/` — full passive+converge captures
- `/home/david/td_milestone_stage/tdif23_targeted_*` — doorbell-triggered captures

## What to try next

1. **Re-run multi-iter stats on tdif-22 with a longer SW retry loop** (e.g., 64 recals or 16 redeploys). The single success at attempt 1/16 of run-1 suggests ~5–10% per-deploy success rate. With enough retries, statistical convergence might happen.

2. **Capture cal_state_dbg_w during a SUCCESSFUL deploy** — currently we don't know what calibrator state distinguishes a lucky deploy from a stuck one. Need a long monitor capture across many deploys with the watchdog.

3. **Build tdif-24 with Fix C (margin-requiring lock scoring)** — change `LOCK_THRESH` calculation in calibrator to require sustained lock across multiple cycles, picking the centre of the eye not the edge.

4. **Verify wlink_pair cocotb tests still pass** on the tdif-22 RTL — the calibrator changes haven't been sim-validated against the full TB suite, only the lottery harness.

## Known unsolved issues at end of session

- Per-direction lottery in calibrator's (phase, slip) pick
- Silent link mode (LINK_IDLE reachable but data doesn't flow)
- Calibrator's scoring doesn't predict real-data decode success
- SW retry doesn't help because recal is deterministic per deploy state
- One stalled FCSM debug agent (a0f15d46418148478) ran 9+ hours with no commits — may need manual TaskStop

Build pipeline is healthy; lease management is healthy; ILA infrastructure is now mature.
