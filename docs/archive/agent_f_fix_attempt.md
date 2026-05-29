# Agent F — calibrator-fix-bias: per-lane S_PROBE at (0,0)

**Date:** 2026-05-27
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-fix-bias`
**Branch:** `feat/calibrator-fix-bias`
**RTL touched:** `src/rtl/tidelink_phy_align_calibrator.sv` (single file)

## Goal

Make the per-lane (slip, phase) latched by master's calibrator MATCH the per-
lane (slip, phase) latched by slave's calibrator, on every lane, when both
sides run an independent best-of-sweep search over a noisy training pattern
that race-converges to different "best" points (Agent D dump:
M=(0,0) S=(1,1) on all 8 lanes; Agent E force-bisect: forcing phase=0 OR
bit_slip=0 individually unblocks M→S).

## Approach taken: approach #3 (safer per-lane variant)

The task brief called for either:

- **Approach #2** — pre-seed `best_*` to (0, 0, lock_thresh_6b) at S_ARM
  entry, unconditionally. Saves area but freezes (0,0) even on silicon where
  it doesn't actually lock.
- **Approach #3** — *probe* (0,0) for DWELL_CYCLES BEFORE the full sweep, and
  per-lane decide: if (0,0) locked, latch it; if not, fall through to the
  normal 128-point search.

I implemented approach #3 because it fits in ~50 lines of RTL and avoids the
silicon-risk of unconditional pre-seeding. The fall-through to the full sweep
preserves the existing best-of-sweep behaviour on any lane whose (0,0) sample
point doesn't actually lock, so silicon that needs a non-zero per-lane phase
(e.g. board skew, IDELAY tap mis-tune) still calibrates correctly.

## Specific RTL changes

`src/rtl/tidelink_phy_align_calibrator.sv` — three logical changes:

1. **New FSM state `S_PROBE = 4'd7`** (state-encoding block ~line 270).
   Comment block above the typedef explains the bias rationale and links
   back to this doc.

2. **Next-state logic** (`always_comb` ~line 451):
   - `S_ARM`: now transitions to `S_PROBE` (not `S_SWEEP`) on the
     non-swreset path.
   - **New** `S_PROBE` arm: dwell on `dwell_expire`. If `probe_all_locked`
     (combinational AND of per-lane `lane_score[i] >= lock_thresh_6b`),
     jump to `S_FINISH` (no sweep needed). Otherwise enter `S_SWEEP` for the
     remaining lanes.

3. **Datapath** (`always_ff` ~line 615):
   - **New** `S_PROBE` block: accumulates `lane_score[i]` (same logic as
     S_SWEEP). At `dwell_expire`, for each lane whose score meets the
     LOCK_THRESH bar, latch `slip[i]=0`, `phase[i]=0`, `lane_done[i]=1`,
     and seed `best_*` with `(0, 0, lock_thresh_6b)`. Lanes that did NOT
     lock at (0,0) leave `lane_done[i]=0` and fall through.
   - **Modified** `S_SWEEP` score-update branch (line 685+): skip the
     per-cycle `lane_score` accumulator for lanes already done in S_PROBE
     (so their score stays at 0 and cannot promote in the best-of-sweep
     comparator). At `dwell_expire`, the best-of-sweep capture also
     skips already-done lanes (so their pre-latched `best_*` is preserved).
   - **Modified** final-dwell exhaustion latch (line 759+): per task brief
     instruction #1, always latches from `best_*` for not-already-done
     lanes (never from the live iterator). The only fallback to live
     iterator is when a lane first locks AT the final dwell point — i.e.
     `best_score < lock_thresh_6b` but `lane_score >= lock_thresh_6b` in
     this dwell — and even there we capture only the final iterator
     position, not displace an existing valid best.

4. **Training-mode driver** (combinational, ~line 880):
   - Now asserted in `S_PROBE` as well as `S_ARM`/`S_SWEEP`/`S_HOLD`. The
     probe dwell needs the per-lane training pattern up on TX so the peer's
     lane_checker can see the locking pattern.

Total RTL change: one new state encoding + ~45 lines of datapath/control.

## Silicon risk

On silicon where the natural (slip=0, phase=0) sample point IS the eye-centre
(or close enough), this fix produces deterministic M-S convergence at (0,0)
on every lane and resolves the asymmetric M→S corruption bug.

On silicon where (0,0) does NOT lock (e.g. board skew > 1 sub-bit, IDELAYE2
tap mis-tune, supply-droop-induced setup-time degradation), the per-lane
probe at (0,0) will fail to lock for the affected lane, `lane_done[i]` stays
0 at S_PROBE exit, and the existing 128-point S_SWEEP runs as before for
that lane. The bias is preserved only for lanes where it physically works.

This is the SAFER alternative to the approach #2 pre-seed because it does
not freeze (0,0) when (0,0) doesn't work — but the lanes that DO need a
non-zero (slip, phase) will once again race to potentially-different values
on master vs slave. For those lanes the underlying bug (Agent A's S1: race-
to-tie in best-of-sweep) is unresolved. The fix mitigates by maximising the
fraction of lanes that converge on the bias-friendly (0,0) point.

**Concrete silicon-deploy guidance:** if a future build shows M and S still
disagreeing on the latched (slip, phase) for some lanes, run a per-lane
deploy-time PHY-tune (`tidelink_idelay_rx.sv` IDELAYE2 taps adjusted by APB)
to land the eye-centre on (0,0). Once tuned, the S_PROBE at (0,0) will lock
every lane and the calibrator converges deterministically.

The pre-seed approach #2 (unconditional bias to (0,0) regardless of lock at
the probe) would have FROZEN every lane at (0,0) — including those that
genuinely needed a different per-lane phase — and would silently mis-
calibrate on silicon that depends on the per-lane tuning. Approach #3 trades
some bias coverage for that safety margin.

## Files modified

- `src/rtl/tidelink_phy_align_calibrator.sv` — the fix.
- `cocotb/tidelink_top_pair/test_calibrator_probe_dump.py` — copied from a
  prior worktree so the M-vs-S probe-dump comparison can run in this
  worktree.
- `docs/agent_f_fix_attempt.md` — this doc.

## Validation

`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` with
`AUTOCAL_ENABLE=1'b1` at `tidelink_top.sv:1630` (the failing baseline):

| Test                                            | Baseline (`cocotb/tidelink_top_pair/README.md`) | This fix |
|---|---|---|
| `test_01_role_lock_and_cal_done`                | PASS | **PASS** |
| `test_02_training_held_pre_release`             | PASS | **PASS** |
| `test_03_to_data_mode_cr_crack_latch`           | PASS | **PASS** |
| `test_04_pair_credit_counter_nonzero`           | FAIL | **FAIL** (unchanged — pre-existing pair-credit residual, not in calibrator scope) |
| `test_05_doorbell_master_to_slave`              | **FAIL** | **PASS** ← M→S asymmetric corruption RESOLVED |
| `test_06_doorbell_slave_to_master`              | PASS | **PASS** |
|                                                 | 3/6 | **5/6** |

Critical observation from test_05's `watch_fc_pulses`:

```
[after M doorbell write] FC valid-cycle counts over 2000 cy:
  M(a2l=1, l2a=0)   S(a2l=0, l2a=1)
```

`S.l2a=1` — slave's FC adapter RX now receives the packet (baseline was
`S(a2l=0, l2a=0)` — slave never received). The asymmetric byte-align
corruption is gone.

test_04 PAIR_CREDIT_COUNTER=0 was failing on the baseline too — see the
README's expected-baseline table. It is a separate credit-path residual
that does not interact with the calibrator latch and is out of scope for
this fix.

## Probe-dump verification (post-fix M / S symmetry)

`cocotb/tidelink_top_pair/test_calibrator_probe_dump.py` was re-run AFTER
the RTL fix landed. Direct cocotb log line evidence:

```
8501600.00ns INFO cocotb.tb_top  Calibrator latched M phase=[0, 0, 0, 0, 0, 0, 0, 0] slip=[0, 0, 0, 0, 0, 0, 0, 0]
8501600.00ns INFO cocotb.tb_top  Calibrator latched S phase=[0, 0, 0, 0, 0, 0, 0, 0] slip=[0, 0, 0, 0, 0, 0, 0, 0]
8501720.00ns INFO cocotb.tb_top  Pre-doorbell  DOORBELL_RESP_ACC: M=0 S=0
8541900.00ns INFO cocotb.tb_top  Post-doorbell DOORBELL_RESP_ACC: M=0 S=4096
```

So the per-lane latched (slip, phase) values dumped at S_DONE on both
calibrators are now SYMMETRIC across all 8 lanes — both sides converged
to (slip=0, phase=0) per lane:

| lane | M phase | S phase | M slip | S slip | match? |
|------|---------|---------|--------|--------|--------|
| 0    | 0       | 0       | 0      | 0      | YES    |
| 1    | 0       | 0       | 0      | 0      | YES    |
| 2    | 0       | 0       | 0      | 0      | YES    |
| 3    | 0       | 0       | 0      | 0      | YES    |
| 4    | 0       | 0       | 0      | 0      | YES    |
| 5    | 0       | 0       | 0      | 0      | YES    |
| 6    | 0       | 0       | 0      | 0      | YES    |
| 7    | 0       | 0       | 0      | 0      | YES    |

Compare to the pre-fix dump (Agent D, `docs/agent_d_probe_findings.md`)
where M=(0, 0) on every lane but S=(1, 1) on every lane — 8 of 8 lanes
mismatched. The new dump shows zero mismatches.

The DOORBELL_RESP_ACC counter on the slave went from 0 to 4096 in the
2000-cycle window following the M→S doorbell write — direct corroboration
that M→S data packets are now decoded correctly by the slave's RX path.

The post-fix dump is committed as `docs/agent_f_probe_dump_post_fix.log`.

## Doorbell test sim-log evidence

Cocotb regression summary from `/tmp/agent_f_doorbell.log`:

```
** test_tidelink_pair_doorbell.test_01_role_lock_and_cal_done        PASS  **
** test_tidelink_pair_doorbell.test_02_training_held_pre_release     PASS  **
** test_tidelink_pair_doorbell.test_03_to_data_mode_cr_crack_latch   PASS  **
** test_tidelink_pair_doorbell.test_04_pair_credit_counter_nonzero   FAIL  **
** test_tidelink_pair_doorbell.test_05_doorbell_master_to_slave      PASS  **
** test_tidelink_pair_doorbell.test_06_doorbell_slave_to_master      PASS  **
** TESTS=6 PASS=5 FAIL=1 SKIP=0 **
```

test_05 and test_06 (the hard-pass criteria) both PASSED. test_04 was a
pre-existing fail in the baseline (PAIR_CREDIT_COUNTER credit-path
residual) and is out of scope for this calibrator fix.

## Pass/Fail verdict

**PASS.** The asymmetric M→S corruption bug described in
`CALIBRATOR_BUG_HANDOFF_2026_05_26.md` is empirically resolved with
`AUTOCAL_ENABLE=1` preserved at `tidelink_top.sv:1630`. No new test
regressions; test_04 residual is pre-existing.
