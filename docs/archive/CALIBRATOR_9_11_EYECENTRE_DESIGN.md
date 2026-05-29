# Calibrator §9.11 eye-centre selection — design note

**Date:** 2026-05-27
**Branch:** `feat/calibrator-eyecenter` head `52ac307`
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter`
**Builds on:** `feat/calibrator-bug-fix` head `f900e07` (Agent F's S_PROBE)
**Implements:** Agent O proposal §3, with a phase-axis correction

## What §9.11 changes

The calibrator's `(slip, phase)` selection policy is rewritten from
"highest in-dwell score" (§9.9) and "(0,0) S_PROBE absolute bias" (§9.10)
to **centre of the widest contiguous PHASE-axis run that passes
LOCK_THRESH**. Concretely:

1. **Iteration order flipped.** Was phase-OUTER, slip-INNER (§9.7). Now
   **slip-OUTER, phase-INNER**, so the inner-loop axis is the actual
   sub-bit sample-point eye dimension on the GPIO PHY. `bit_slip` is a
   16-bit window rotation; typically one slip value is "right", so it
   makes the OUTER axis.

2. **Run-length tracker added.** At each `dwell_expire` in `S_SWEEP`,
   per lane:
   ```
   if lane_score >= LOCK_THRESH:
       if run_len == 0: cur_run_start_phase = sweep_phase
       run_len += 1
       if (run_len) >= MIN_LOCK_DWELLS && (run_len) > best_run:
           best_run             = run_len
           best_run_start_phase = cur_run_start_phase
           best_run_slip        = sweep_slip
   else:
       run_len = 0
   ```
   `run_len` resets when `sweep_phase` wraps 15→0 (new slip).

3. **S_PROBE demoted to advisory.** Same dwell at (0,0), but the
   verdict is RECORDED into `probe_lane_pass_q[i]` and S_PROBE no longer
   sets `lane_done[i]`. The full S_SWEEP always runs. The probe verdict
   is consulted ONLY as a fallback in S_FINALIZE.

4. **`S_FINALIZE` state added** (4'd8, one cycle). Per lane:
   ```
   if best_run[i] >= MIN_LOCK_DWELLS:
       slip[i]  = best_run_slip[i]
       phase[i] = best_run_start_phase[i] + (best_run[i]-1)/2   # eye centre
       lane_done[i] = 1
   elif probe_lane_pass_q[i]:
       slip[i]  = 0; phase[i] = 0
       lane_done[i] = 1
   else:
       lane_fault_q[i] = 1
       lane_done[i] = 1
   ```

5. **`MIN_LOCK_DWELLS` parameter** (default 4 = 25% of 16-phase axis).
   Matches the tdif-22 empirical eye width (~6/16 phase combos passed
   per OVERNIGHT_2026_05_27_FINDINGS.md §4). Lowering to 1 reduces the
   policy to "first passing point wins" (§9.7-like). Runtime APB
   override deferred to a follow-on patch (would require a local-override
   axi_chiplet_controller change to add `SWI_CAL_MIN_DWELLS[3:0]`).

## Why not the strict Agent O proposal

Agent O's pseudocode tracked run-length along SWEEP ORDER, which with
the original phase-outer/slip-inner iteration meant SLIP-axis contiguity.
That is wrong for this PHY:

* `phase_offset[3:0]` (per-lane) is the SUB-BIT sample point on the
  GPIO deserialiser — the **actual eye axis**. Adjacent phase values
  capture adjacent sample points on the data eye.
* `bit_slip[2:0]` (per-lane) right-rotates the captured 16-bit window
  after capture. Adjacent slip values do NOT capture adjacent eye
  points; typically ONE slip value yields correctly byte-aligned data,
  others give shifted-byte garbage.

So a 4-wide *slip* run would measure 4 different rotation candidates
all passing — meaningless. A 4-wide *phase* run measures 4 consecutive
sub-bit sample points all passing — directly the eye width.

The pseudocode in Agent O §3 mentions `cur_run_start_slip` AND
`cur_run_start_phase` — suggesting 2-D adjacency might also be
considered. We chose 1-D phase-axis here for flop budget (~168 added
flops vs ~512 for true 2-D mask + flood-fill); 2-D could be retrofitted
later if HW shows under-selection.

## Test coverage on this branch

| Test | Where | Result |
|---|---|---|
| `test_calibrator_t3` (×4 sub-tests) | `cocotb/tidelink_phy_align_calibrator/` | PASS |
| `test_best_of_sweep_placeholder` | same dir | PASS |
| `test_best_of_sweep_compare` | same dir | PASS (updated for §9.11) |
| `test_eye_offcenter` V1/V2/V3 (Agent N) | same dir | PASS — V3 is the centrepiece |
| `tidelink_top_pair/test_tidelink_pair_doorbell` | `cocotb/tidelink_top_pair/` | RUNNING |
| `tidelink_top_pair_skewed` (Agent L) | `cocotb/tidelink_top_pair_skewed/` | PENDING |
| `tidelink_top_pair_drift` (Agent M) | `cocotb/tidelink_top_pair_drift/` | PENDING |

### V3 (`test_eye_offcenter_zero_vs_wide`) — the bias-vs-centre proof

V3 stimulus paints two eyes on every lane:
* eye-A at `{(0,0), (0,1), (1,0)}` — 3 cells including (0,0)
* eye-B at `{(3..5) × (7..9)}` — 9 cells, NOT including (0,0)

Under §9.10 (Agent F S_PROBE absolute bias): every lane would latch
(0,0) — the probe-pass overrides the wider eye-B. Test FAILS.

Under §9.11 (this branch, MIN_LOCK_DWELLS=3): every lane latches
**(3, 8)** — the centre of eye-B. The (0,0) probe verdict is
overridden by the wider run. Test PASSES.

This is empirical evidence that the §9.10→§9.11 transition correctly
restores the §9.9 eye-CENTRE design intent.

## Open follow-ups (deferred from this commit)

1. **APB runtime override** (`SWI_CAL_MIN_DWELLS[3:0]`). Needs
   `local_overrides/axi_chiplet_controller.sv` patch + Region 8
   register decode. Out of scope for the bring-up fix; would land as a
   separate commit.
2. **2-D adjacency contiguity** if HW shows phase-only is too
   restrictive. ~3× flop budget; defer until HW evidence requires.
3. **Real-data validation dwell** (Fix A from OVERNIGHT_2026_05_27).
   §9.11 still scores against the training-pattern eye, not real-data
   ISI margin. Could add an S_VALIDATE state after S_FINISH that
   re-arms the sweep if real-data decode fails. Complementary to
   §9.11; not a replacement.

## HW deploy checklist

Before building a bitstream:

1. Restore `AUTOCAL_ENABLE(1'b1)` at
   [src/rtl/tidelink_top.sv:1630](src/rtl/tidelink_top.sv#L1630)
   (currently 1'b0 as the HW workaround). The §9.11 fix is the
   replacement for AUTOCAL=0.
2. Pick a low-risk target first:
   `pynq-z2-loopback` (internal LUT loopback, no pads, no PPM drift) —
   confirms the calibrator doesn't break a zero-skew link before
   testing real boards.
3. Then `pynq-z2-pair-flip-ila` (single MMCM, no PPM drift, ILA on
   board) — confirms cross-die at known-good skew.
4. ILA capture per Agent O §5 step 7: `lane_locked[7:0]` for 10s of
   FC traffic post-bringup. Target metric: per-lane re-drop rate ≤
   1/minute. Higher → raise MIN_LOCK_DWELLS via APB (once that
   follow-up lands).

## Related memory entries

* [[project-tidelink-calibrator-fix-2026-05-27]] — Agent F's S_PROBE fix
* [[project-autocal0-hw-workaround-2026-05-27]] — the diagnostic that
  pinned the bug to the calibrator
* [[project-tidelink-sim-repro-2026-05-26]] — the cocotb repro this
  branch validates against
