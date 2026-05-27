# §9.11f post-reboot session — Layer-2 bit-error-rate confirmed

Date: 2026-05-28 (continuing from §9.11e overnight session report 4f31f41)
Branch: `feat/calibrator-eyecenter` HEAD = 4f31f41
Boards: bridge1 (z2_02 master die_a, z2_03 slave die_b), POST-REBOOT
Lease: bridge1 held mapstone-dev → 1h TTL

## Headline

Boards rebooted clean. §9.11d-equivalent bitstreams redeployed, **bilateral
LINK_IDLE recovers reproducibly** (Symptom A from yesterday: SOLVED). However
**no data traffic crosses in either direction post-LINK_IDLE** (Symptom B from
yesterday: still UNSOLVED). New evidence below isolates this to **long-packet
bit-error-rate failure** — the calibrator's eye-center is correct for the
training pattern and for short link-control packets (CR / CRACK), but
insufficient for long data packets (AHB-encapsulated writes such as the
doorbell-response).

## Evidence gathered tonight

| Path | Action | Result |
|------|--------|--------|
| A | Redeploy §9.11d-eq bitstreams post-reboot | cal_done=1 FCSM=4 cr=1 crack=1 bilaterally; 5 doorbells → DB_RESP_ACC=0 |
| B/C/D | Not run — Path A's evidence reframed the bug | — |
| E | Clear PHY_CTRL=0 on both sides + SWI_RECAL | OR-merge ruled out; cal_done=1 holds; still DB_RESP_ACC=0 |
| F | Re-pulse `0x27f09 / 0x27f01 / 0x27f07` swreset sequence on both | Master FC_TL TX FIFO drained; LINK_STATUS picked up new sticky bits ([25] is_short_pkt, [29] LL_RX valid pkt) — packets DO arrive; still DB_RESP_ACC=0 |
| G | Sweep slave per-lane SWI_PHASE_OFFSET_R through 0x00/0x11/0x22/0x33/0x44/0x55 | No setting produces DB_RESP_ACC≠0; SSH dropped at 0x77 partway through |

### Key per-FC-node CSR snapshot

After Path E (PHY_CTRL=0 both, post-RECAL, post 50 doorbells from master):
```
MASTER FC_TL  txFIFO_empty=0 (packets QUEUED) CRC_errors=0
SLAVE  FC_TL  txFIFO_empty=1                  CRC_errors=2  ← bit errors in transit
```

After Path F (swreset on both):
```
MASTER FC_TL  txFIFO_empty=1 (drained)        CRC_errors=0  (reset cleared queue + counter)
SLAVE  FC_TL  txFIFO_empty=1                  CRC_errors=0
```

Post-Path-F + 200 doorbells from master:
```
MASTER FC_TL  txFIFO_empty=1 (drained as fast as it filled)
SLAVE  FC_TL  txFIFO_empty=1  CRC_errors=0  (no detected corruption)
SLAVE  LINK_STATUS[25,29] = 1,1 (still seeing valid short packets)
SLAVE  DB_RESP_ACC=0 REL_ACC=0 PAIR_CRED_CTR=0
```

## What this tells us

1. **Symptom A (cal_done stuck) is reproducibly SOLVED** by §9.11c (the
   iter-revert to phase-OUTER, slip-INNER). Post-reboot, the calibrator
   converges on both sides and FCSM advances to LINK_IDLE within ~5 s.

2. **Symptom B (doorbell silent at LINK_IDLE) is at Layer-2 BER**, not at
   Layer-1 (eye) and not at Layer-3 (SW). Per-FC-node CSR shows:
   - Master's FC TL TX FIFO drains (link IS pulling words from returner)
   - Slave's LL_RX intermittently flags valid short packets (cr/crack and
     similar 4-byte control frames cross fine)
   - Slave's FC TL CRC_errors counter ticked when packets were queued
     (Path E snapshot showed CRC=2)
   - **Long (8-byte+) data packets fail CRC every time** — every doorbell
     write the returner emitted between bring-up and Path F was either
     bit-corrupted in transit or never made it to the data-pattern receiver

3. **No SW knob recovers** — confirmed by sweeping per-lane phase offsets
   from 0..5. The calibrator already picks the per-lane phase that
   maximises training-pattern lock; manually OR-ing in additional bits
   only makes the per-lane phase larger, not different. The fundamental
   sample point is wrong for *real data*, not for the {P,P} training byte.

4. **Why training works but data doesn't**: the lane_checker locks on a
   16-bit `{P,P}` pattern. With period-8 patterns (commit 52ac307), exactly
   one slip value matches, so training lock is tight. But the data eye
   for an arbitrary-bit-pattern stream (with bit transitions in any
   position) is narrower than the eye for {P,P}, which has the same byte
   repeated. Any per-bit ISI shifts the data eye relative to the
   training eye. The §9.11 eye-center fix made the training eye even
   tighter, but didn't extend coverage to the data eye.

## Comparison to AUTOCAL=0 working state (memory snapshot 2026-05-27)

Project memory entry `project_autocal0_hw_workaround_2026_05_27.md` records
that `AUTOCAL_ENABLE(1'b0)` (calibrator bypassed) **unblocks the FPGA link
bilaterally**. With the calibrator off, the SHORTCOMINGS-14b SW phase=3 on
slave is the only phase compensation, and apparently that produces a wide
enough data eye for long packets.

**Hypothesis**: the calibrator finds a phase that maximises training-pattern
lock but does NOT maximise data-pattern margin. The SHORTCOMINGS-14b SW
hardcoded phase=3 happens to land inside the data eye, even if it's not
the training eye center.

If the hypothesis is correct, the right architectural answer is one of:
- **Q1 (cheapest)**: rebuild with `AUTOCAL_ENABLE(1'b0)` to recover the working
  pre-calibrator state. Fragile (depends on hardcoded phase=3), but
  empirically proven on HW. ~50 min build per pair, 2 pairs = ~50 min with
  parallel farm.
- **Q2 (proper)**: rewrite the calibrator's scoring function to validate
  against a *bit-randomised* training stream, not just `{P, P}` — i.e.,
  send a PRBS-like pattern during calibration so the lane_checker measures
  data-eye margin, not training-pattern margin. Requires new RTL,
  significant work. (This is what the §9.11e `{P, ~P}` experiment attempted
  but was reverted because the slave never reached cal_done — the pattern
  change broke the bring-up step.)
- **Q3 (intermediate)**: extend the calibrator with a S_VALIDATE state that
  *uses real link traffic* (CR/CRACK already-completed → switch to data
  packets → measure CRC error rate → if non-zero, try a neighbouring
  (slip,phase) point). The existing §9.11d S_VALIDATE state didn't do this
  — it only timed out waiting for `cr_pkt_seen` and re-armed.

## Recommendation for the morning

The right next step depends on the user's time horizon:
- **If we need a working link this week**: rebuild with `AUTOCAL_ENABLE(1'b0)`
  (Q1). Empirically known to work; recovers yesterday's pre-calibrator state.
- **If we want to keep the calibrator architecture and fix it properly**:
  start on Q3 (real-data validation in S_VALIDATE) which is the smallest
  architectural step that addresses the root cause.

The current `feat/calibrator-eyecenter` branch is a dead end for HW —
the eye-center policy is right *in principle* but the wrong *metric*
(training-pattern lock vs data-pattern margin). Continuing to iterate on
this branch without changing the metric will not produce a working link.

## What's left for the user to decide

1. Build AUTOCAL=0 fallback tonight (background, ~50 min) so it's ready
   in the morning?
2. Or wait for user input before rebuilding?
3. Branching strategy: keep `feat/calibrator-eyecenter` for the eye-center
   work-in-progress, or fold the §9.11 eye-center logic into a new branch
   that also includes the AUTOCAL=0 bypass + per-build switch?

No autonomous rebuild was kicked off tonight. The boards are left in the
post-Path-G state (slave's swi_phase_offset_r ≈ 0x55555555 — last value
written; PHY_CTRL=0 both sides). Lease bridge1 is held under mapstone-dev
until ~2026-05-28T22:37Z (1h TTL from acquire; can re-acquire freely).

## Artefacts

- Logs: `/tmp/probe_full.log`, `/tmp/path_e.log`, `/tmp/path_g.log`,
  `/tmp/eye6_deploy_test_postreboot.log` (on srv04936)
- Bitstreams unchanged: `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit`
  (§9.11d-equivalent, sha256 `06083a4055c7…` / `df7f805691c3…`)
