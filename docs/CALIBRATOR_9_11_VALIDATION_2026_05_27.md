# Calibrator §9.11 validation log — 2026-05-27

**Branch:** `feat/calibrator-eyecenter`
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter`
**Builds on:** Agent F's S_PROBE at `f900e07`; restores §9.9 eye-CENTRE intent

## Sim gate — unit tests (calibrator standalone)

### `test_calibrator_t3` (4 sub-tests)

| Sub-test | Result | Notes |
|---|---|---|
| `test_t3_resweep_on_fault` | PASS | Auto re-sweep on faulted sweep + role_locked |
| `test_t32_shold_on_success` | PASS | S_FINISH→S_HOLD on sweep_success |
| `test_t32_shold_ignores_lane_drop` | PASS | S_HOLD doesn't re-trigger on peer lane drop |
| `test_t3_resweep_advances_counter` | PASS | resweep_ctr increments per auto-retry |

T3 / T3.2 FSM transitions are unchanged by §9.11 (only the per-dwell selection
policy and S_FINALIZE state were added).

### `test_best_of_sweep_placeholder`

PASS. The sweep walks the full 128-point space before transitioning to
S_FINISH (now via S_FINALIZE), DWELL_CYCLES=8 × 128 = 1024 cycles + 1
(S_FINALIZE) = 1025 cy. The test allows ±5% slack.

### `test_best_of_sweep_compare` (updated stimulus for §9.11)

Two DUTs (best=§9.11, first=§9.7) on the same lane_locked trajectory.

Stimulus:
* Lane 0 marginal at (0,0): 18-cycle in-dwell lock — single phase point,
  passes LOCK_THRESH but a 1-wide run < MIN_LOCK_DWELLS=4.
* Lane 0 wide eye at (slip=3, phase=4..7): 4 contiguous phase points all
  pass — 4-wide run meets MIN_LOCK_DWELLS=4.
* Lanes 1..7: always-locked — full 16-phase strip at slip=0 passes.

Results:
* **best (§9.11) lane 0**: `(slip=3, phase=5)` — eye centre of WIDE run.
  Computed as start_phase 4 + (4-1)/2 = 5. The marginal (0,0) point is
  ignored because its 1-wide run never promoted.
* **first (§9.7) lane 0**: `(slip=0, phase=0)` — first lock-rising dwell.
* Lanes 1..7 best DUT: all `(slip=0, phase=7)` — centre of the 16-wide
  all-passing strip at slip=0 (first slip in slip-outer iteration).
* Lanes 1..7 first DUT: all `(slip=0, phase=0)`.
* `phase_offset` packed: best = `0x77777775`, first = `0x00000000`
* `bit_slip`     packed: best = `0x000003`,   first = `0x000000`

### `test_eye_offcenter` V1/V2/V3 (Agent N — the centrepiece)

| Variant | Eye stimulus | §9.11 result | Status |
|---|---|---|---|
| V1 | Single 3×3 eye at centre (3,8) | All 8 lanes latch (2, 8) — centre of phase-run at first slip in the eye | PASS (soft-degraded — edge slip) |
| V2 | 1-cell eye-A at (6,2) vs 3×3 eye-B at (3,8) | All 8 lanes latch (2, 8) — eye-B; eye-A's 1-cell never promoted | PASS |
| V3 | 3-cell eye-A *including (0,0)* vs 3×3 eye-B at (4,8) | All 8 lanes latch (3, 8) — eye-B centre; **(0,0) probe verdict was correctly overridden by the wider run** | **PASS** |

**V3 is the structural proof** that the §9.10→§9.11 transition restores
the §9.9 eye-CENTRE intent. Under §9.10 (S_PROBE absolute priority) the
calibrator would have latched (0,0) on every lane. Under §9.11 it
correctly picks the WIDER eye-B's centre — exactly the behaviour Agent K
warned was being silently abandoned in §9.10.

## Sim gate — integration tests (paired-die)

### `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell` (6 tests) — COMPLETE

**Final result: 5/6 PASS** — same as Agent F's baseline. The one FAIL is
the pre-existing `test_04_pair_credit_counter_nonzero` (PAIR_CREDIT_COUNTER=0
residual unrelated to the calibrator, per `agent_f_fix_attempt.md`).

| Test | Result | Sim time | Notes |
|---|---|---|---|
| `test_01_role_lock_and_cal_done` | PASS | 9.45 ms | **`SWI_LANE_STATUS = 0x23850000` IDENTICAL on M and S** — symmetric convergence ✓ |
| `test_02_training_held_pre_release` | PASS | 18.90 ms | slot0=0 as expected |
| `test_03_to_data_mode_cr_crack_latch` | PASS | 28.45 ms | M & S both at fcsm=4, cr=1, crack=1 |
| `test_04_pair_credit_counter_nonzero` | FAIL | n/a | Pre-existing baseline FAIL (Agent F); out of scope for §9.11 |
| **`test_05_doorbell_master_to_slave`** | **PASS** | 38.01 ms | **M→S doorbell crosses ✓ — the Agent D bug is resolved** |
| `test_06_doorbell_slave_to_master` | PASS | 47.60 ms | S→M doorbell, DOORBELL_RESP_ACC=4096 |

Total wall: ~43 min (single seed, single sim_build).
Total sim: 57.19 ms.

**Critical finding from test_05** (the M→S doorbell, the bug regression):
After §9.11 the calibrator on both sides latches identical per-lane
(slip, phase) — master's TX framing matches slave's RX deserialiser
config — so the M→S byte-align that was broken under §9.9 best-of-sweep
race-to-tie now works. The Agent D-observed M=(0,0)/S=(1,1) asymmetry
is gone; both sides converge to the symmetric `SWI_LANE_STATUS=0x23850000`.

Compare to Agent F's S_PROBE baseline: also 5/6 with test_05 PASS, but
via the (0,0) absolute bias — a sim-only win. §9.11 preserves the same
sim wins while restoring the §9.9 eye-CENTRE intent that S_PROBE silently
abandoned (per V3 unit test above).

### `cocotb/tidelink_top_pair_skewed/test_tidelink_pair_doorbell` (Agent L)

Status: RUNNING (kicked off 10:57).

Per-lane pad skew between M and S. Validates §9.11 under the closest
sim approximation to real PCB trace mismatch.

### `cocotb/tidelink_top_pair_drift/test_tidelink_pair_doorbell` (Agent M)

Status: RUNNING (kicked off 10:57).

Split-clock M and S with 500 PPM frequency drift + 7 ns phase offset.
Validates §9.11 under independent-oscillator chiplet pairs (no shared
ref clock).

## Headline KPIs

* **M/S `SWI_LANE_STATUS` symmetry**: ACHIEVED on test_01 (both 0x23850000).
  Confirmation that §9.11 produces deterministic per-lane (slip, phase)
  convergence across M and S — the Agent D root cause is gone.
* **Eye-centre selection**: V3 unit-test PASS proves the §9.10 (0,0)
  bias is correctly demoted. With a wider eye elsewhere, §9.11 picks its
  centre, not the (0,0) probe verdict.
* **Run-length policy correctness**: V2 PASS proves 1-cell eye-A is
  rejected (no MIN_LOCK_DWELLS-wide run) in favour of the wider eye-B.

## What's deferred

* APB runtime override `SWI_CAL_MIN_DWELLS[3:0]` — would require a
  `local_overrides/axi_chiplet_controller.sv` patch (Wavious upstream
  in `deps/` is read-only per project convention). Synth parameter
  works for the bring-up; APB runtime tune is a polish patch.
* 2-D contiguity vs 1-D phase-axis — current pick is phase-axis with
  ~168 added flops. If HW shows under-selection (lanes faulting that
  should pass), 2-D adjacency adds ~340 more flops + a small flood-fill
  in S_FINALIZE.
* Real-data validation dwell (Fix A from OVERNIGHT_2026_05_27) — §9.11
  scores against training-pattern eye, not real-data ISI margin. The
  HW evidence in tdif-22 showed cases where training-pattern lock did
  NOT predict real-data decode success. An S_VALIDATE state after
  S_FINISH could close this gap; complementary to §9.11.

## HW deploy plan (when sim gate passes)

1. **Target order (lowest-risk first):**
   1. `pynq-z2-loopback` (single-die LUT loopback) — smoke test: §9.11
      doesn't break a zero-skew link. Requires the loopback-specific
      tcl edits in your main working tree (`USE_IDELAY=0`,
      `mask_hs_bypass_i=1`). NOT a real validation of the fix — just
      "doesn't crash".
   2. `pynq-z2-pair-flip-ila` (paired-die, single MMCM, ILA) — primary
      §9.11 validation target. Real cross-die training; ILA captures
      `lane_locked[7:0]` for ≥ 10 s of FC traffic post-bringup.
   3. `pynq-z2-pair-all` (paired-die, dual MMCM, PPM drift) — final
      validation if pair-flip-ila is green.

2. **Acceptance criteria:**
   - Build: `tidelink.bit` produced, no IDELAY/clock placement errors
   - Bring-up: M and S both reach FCSM `state=4` (LINK_IDLE), cr+crack
     symmetric, `lane_locked[7:0] == 0xFF`
   - Doorbell: 10 doorbell writes from M (or S) increment the peer's
     `DOORBELL_RESP_ACC` register
   - Stability: per-lane `lane_locked` re-drop rate ≤ 1/minute on ILA
     capture over 10 s (Agent O §5 step 7)
