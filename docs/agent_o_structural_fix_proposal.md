# Agent O — Structural fix proposal for `tidelink_phy_align_calibrator`

**Status:** DESIGN DOC ONLY — no RTL changes in this branch.
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-fix-proposal`
**Branch:** `feat/calibrator-structural-proposal`
**Date:** 2026-05-27
**Reviewers wanted:** D, F, K (the three agents whose findings this doc synthesises)

---

## 1. Root-cause synthesis

The calibrator picks a per-lane `(slip, phase)` that **passes** the lane-checker
LOCK_THRESH bar, not one that **centres** the data eye. Three independent
observations point at the same defect:

* **Agent A (static, S1):** the per-lane best-of-sweep latch
  (`tidelink_phy_align_calibrator.sv:631-664` in the pre-S_PROBE baseline)
  uses a **strict** `>` comparator for score updates and reads the
  end-of-sweep "current dwell" path under the same NBA edge as `best_*`.
  With a saturating 6-bit score, every (slip, phase) pair inside the eye
  produces an identical score; the tie is broken by NBA-race, so master
  and slave — running identical RTL but independent training streams —
  can latch different per-lane tuples for the same lane.
* **Agent D (empirical):** the live sim shows exactly that. Master ends
  at `(slip=0, phase=0)` on every lane, slave ends at `(slip=1, phase=1)`
  on every lane, both with `cal_state=S_DONE`, both with `cal_done=1`.
  The slave's deserialiser is configured for a rotation the master's TX
  never emits → M→S byte-align permanently broken; S→M works because
  it uses master's RX which happened to race to a benign point.
* **Agent K (review of Agent F):** the S_PROBE fix that "biases to (0,0)
  if (0,0) locks" RESOLVES the sim asymmetry but **inverts** the
  §9.9 eye-CENTRE selection intent. A lane whose (0,0) point sits at the
  passing edge of LOCK_THRESH will be latched at the edge even when a
  wider eye exists elsewhere in the 128-point space. On silicon at PVT
  extremes that re-introduces the §9.9 oscillation symptom (per-lane
  `lane_locked` flickering 0xf5/0xfd/0xd5/0xd7) the best-of-sweep policy
  was designed to defeat.
* **HW evidence (tdif-22/23/24 ILA, 4096 samples):** every sample shows
  `crc_corrupt=1` even though `rx_in_data_id=0xa1` decodes cleanly. The
  byte-align passes (training pattern locks); real-data CRC fails. This
  is the empirical signature of an eye-edge pick: training-pattern
  transition density gives a narrower margin than real-data ISI demands,
  so a marginal `(slip, phase)` that satisfies `match_count >=
  LOCK_THRESH` on `{P,P}` does NOT satisfy the eye on random data.

**Root cause in one sentence:** the calibrator's selection policy treats
the LOCK_THRESH-passing bar as the **acceptance criterion** when it is
only a **necessary condition** — eye centring requires picking the
`(slip, phase)` whose locked region is **widest on the sweep grid**, not
the first or the lexicographically-smallest passing point. Lacking that,
two calibrators race independently to different passing points; on
silicon a single calibrator races to the eye edge.

---

## 2. Proposed structural fix — MIN_LOCK_DWELLS + deterministic comparator

The fix has three layered components, each addressing one of the three
findings, designed to co-exist on top of (or replace) the current
S_PROBE state.

### 2.1 Eye-CENTRE selection via MIN_LOCK_DWELLS

Introduce a parameter `MIN_LOCK_DWELLS` (default `4`, configurable
1..16). A `(slip, phase)` point is **acceptable** only if it is one of a
contiguous run of `>= MIN_LOCK_DWELLS` passing points along the
slip-inner sweep order. The latched winner is the **centre** of the
widest contiguous run, not the first passing point.

This implements the HW reviewer's "Fix C" suggestion. The intuition: a
real data eye occupies multiple adjacent grid points; an eye-edge pick
occupies one (or none at saturation but in narrow margin). Requiring N
contiguous neighbours forces the centre.

### 2.2 Deterministic comparator (Agent A's S1 fix, completed)

Replace the strict `>` score comparator with a deterministic ordering:

* Score is the eye-width (run length of contiguous passing dwells), not
  the per-dwell run-length of `lane_locked=1`. Two calibrators presented
  with the same training pattern produce identical eye-width maps →
  identical winners.
* Tie-break on score is **earliest** in slip-inner sweep order.
* End-of-sweep latch ALWAYS reads `best_*` — never the live iterator
  (closes the NBA-race hole at `iter_at_end`).

### 2.3 S_PROBE retained as an OPTIMISATION (not correctness)

S_PROBE stays in the FSM, but its verdict is **advisory**: a lane that
locks at (0,0) records `probe_score[i] = MIN_LOCK_DWELLS`. The full
sweep still runs; at sweep exhaustion the wider-eye winner from the
sweep beats the probe verdict if it is **strictly wider**. If the sweep
finds nothing wider (the common case in sim with bit-exact PHY), the
probe verdict wins by virtue of being the earliest-recorded point.

This preserves the sim convergence Agent F demonstrated AND the silicon
eye-centring §9.9 intended.

---

## 3. Pseudocode

The new datapath replaces lines 615–824 of
`tidelink_phy_align_calibrator.sv`. Score accounting is per-dwell
(unchanged), but eye-width tracking is layered on top.

```systemverilog
// New parameter
parameter int MIN_LOCK_DWELLS = 4;       // contiguous-passing-points required
parameter int EYE_WIDTH_W     = 5;       // ceil(log2(128+1))

// Per-lane eye-width accumulators (replaces best_score's role)
logic [EYE_WIDTH_W-1:0] run_len   [0:7];  // current contiguous run length
logic [EYE_WIDTH_W-1:0] best_run  [0:7];  // longest contiguous run seen
logic [2:0]             best_run_start_slip [0:7];
logic [3:0]             best_run_start_phase[0:7];
logic [2:0]             cur_run_start_slip  [0:7];
logic [3:0]             cur_run_start_phase [0:7];

// New state — S_FINALIZE between S_SWEEP last dwell and S_FINISH
// (one cycle to compute the centre-of-best-run per lane)
typedef enum logic [3:0] {
    S_IDLE, S_ARM, S_PROBE, S_SWEEP, S_FINALIZE,
    S_FINISH, S_DONE, S_CANCEL, S_HOLD
} state_t;

// At each dwell_expire in S_SWEEP:
//   1. Decide whether this (sweep_slip, sweep_phase) "passes" — score >= LOCK_THRESH
//   2. If it passes, extend the run; if not, close the run and compare against best
for (int i = 0; i < 8; i++) begin
    logic dwell_pass = (lane_score[i] >= lock_thresh_6b);
    if (dwell_pass) begin
        if (run_len[i] == 0) begin
            cur_run_start_slip [i] <= sweep_slip;
            cur_run_start_phase[i] <= sweep_phase;
        end
        run_len[i] <= run_len[i] + 1'b1;
    end else begin
        // Run ended — promote to best if wider AND meets MIN_LOCK_DWELLS
        if (run_len[i] > best_run[i] && run_len[i] >= MIN_LOCK_DWELLS) begin
            best_run[i]             <= run_len[i];
            best_run_start_slip [i] <= cur_run_start_slip [i];
            best_run_start_phase[i] <= cur_run_start_phase[i];
        end
        run_len[i] <= 0;
    end
    lane_score[i] <= 6'd0;  // reset for next dwell
end

// S_FINALIZE (NEW, 1-cycle state, entered when sweep_exhausted):
//   - Flush any in-progress run (sweep ended mid-eye)
//   - Compute centre of best_run and latch as final (slip, phase)
for (int i = 0; i < 8; i++) begin
    // Flush in-progress run
    if (run_len[i] > best_run[i] && run_len[i] >= MIN_LOCK_DWELLS) begin
        best_run[i]             <= run_len[i];
        best_run_start_slip [i] <= cur_run_start_slip [i];
        best_run_start_phase[i] <= cur_run_start_phase[i];
    end
end
// One cycle later, compute centre and latch (combinational mux feeding ff)
for (int i = 0; i < 8; i++) begin
    if (best_run[i] >= MIN_LOCK_DWELLS) begin
        // Centre = start + floor((run-1)/2) along slip-inner sweep order
        {phase[i], slip[i]} <= advance_sweep_pos(
            best_run_start_phase[i], best_run_start_slip[i],
            best_run[i] >> 1);
        lane_done[i] <= 1'b1;
    end else if (probe_lane_pass_q[i]) begin
        // Probe-verdict fallback (slip=0, phase=0 locked but eye too narrow
        // anywhere on the grid — accept the probe point as last resort)
        slip[i]      <= 3'd0;
        phase[i]     <= 4'd0;
        lane_done[i] <= 1'b1;
    end else begin
        lane_fault_q[i] <= 1'b1;
    end
end
```

The helper `advance_sweep_pos(phase, slip, n)` walks `n` slip-inner
positions forward from `(phase, slip)` — synthesisable as a small
adder-and-divmod combinational block.

S_PROBE retains its existing datapath (lines 622-662) but **does NOT**
set `lane_done[i]` directly. Instead it records `probe_lane_pass_q[i]
<= 1`. The full sweep still runs (FSM transitions S_PROBE → S_SWEEP
unconditionally on `dwell_expire`, unless `probe_all_locked` AND
`MIN_LOCK_DWELLS == 0` — the optional sim shortcut). At S_FINALIZE the
sweep winner is preferred over the probe verdict whenever it is at
least `MIN_LOCK_DWELLS` wide; the probe is the safety fallback for
silicon where the eye is degenerate.

### 2.4 Backwards-compatibility

* `bit_slip[23:0]` and `phase_offset[31:0]` outputs are unchanged in
  shape and meaning.
* `calibration_done` still rises in S_DONE.
* `lane_fault[7:0]` still indicates per-lane failure to converge.
* `MIN_LOCK_DWELLS = 1` reduces to the current S_PROBE+best-of-sweep
  behaviour bit-for-bit (any single passing point is acceptable; the
  centre of a 1-wide run IS the run itself), so the default 4 can be
  safely lowered to 1 by APB at runtime for any deploy where the eye
  is degenerate.

---

## 4. Silicon-risk assessment

**Requires of silicon:**
* For each lane, there must exist a contiguous run of at least
  `MIN_LOCK_DWELLS` passing `(slip, phase)` points along the slip-inner
  sweep order somewhere in the 128-point grid.
* At default `MIN_LOCK_DWELLS = 4`, the lane needs an eye width of
  at least 4 grid points — given the 16-step phase axis, ~25% margin.
  At the lower-quality deploys we have HW evidence for (tdif-22/23/24)
  the training-pattern lock-only width is ≥ 4 in the captured ILA
  windows; what was lacking is the *centre-of-width* selection.
* `MIN_LOCK_DWELLS` is a synthesis parameter AND should be APB-runtime
  configurable (`SWI_CAL_MIN_DWELLS[3:0]` in Region 8) so silicon at
  variable margin can be tuned per deploy without re-synthesis. See
  open question Q1.

**Does NOT require:**
* No assumption that (0,0) is in the eye. The probe is advisory, not
  mandatory.
* No assumption that master and slave see "the same" training-pattern
  rotation — they each find THEIR widest eye, and that eye is centred
  for THEIR RX path. The deserialiser is configured locally; coordination
  across the die-pair is not needed (this is the same property the
  current FSM assumes; we are not weakening it).
* No new sideband / I²C exchange. Agent E's option (2) is NOT taken;
  this is a single-die-local fix.

**Graceful degradation if no `MIN_LOCK_DWELLS`-wide eye exists:**
* Behaviour falls back to the S_PROBE verdict (if (0,0) locked at all).
* If neither MIN_LOCK_DWELLS-wide eye nor (0,0) probe lock, lane faults
  out (`lane_fault[i] = 1`). The autoneg FSM observes this and can
  re-trigger or report failure.
* APB-lowering `SWI_CAL_MIN_DWELLS` to 1 at runtime reduces the
  policy to "earliest passing point wins", restoring Agent F's S_PROBE
  semantics as a last resort.

**Does NOT close Hole #5 (Agent J's `count` non-determinism).** That is
a PHY-side concern and orthogonal. Recommended to address it
independently per Agent K's H5. The MIN_LOCK_DWELLS fix increases the
probability that the latched `(slip, phase)` survives a `count` phase
that aliases under training; it does not eliminate that hazard.

---

## 5. Validation strategy

Tests the new RTL must pass, in dependency order:

1. **`cocotb/tidelink_phy_align_calibrator/test_best_of_sweep_compare.py::test_best_of_sweep_picks_widest_eye`** —
   the existing unit test that is currently passing only by
   stimulus-timing accident (Agent K §5). Under MIN_LOCK_DWELLS=4 this
   must latch `(WIDE_SLIP=3, WIDE_PHASE=5)`, NOT
   `(MARGINAL_SLIP=0, MARGINAL_PHASE=0)`. Required to confirm §9.9
   intent restored.
2. **`cocotb/tidelink_phy_align_calibrator/test_eye_offcenter.py`** (Agent N,
   in flight) — new unit test parameterised over off-centre eye
   positions on the 128-point grid. Must select the run centre regardless
   of where the eye sits.
3. **Existing `cocotb/tidelink_phy_align_calibrator/test_best_of_sweep_*`** —
   the broader unit-test suite must remain green.
4. **`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py::test_05_*`
   and `::test_06_*`** — integration sim, M→S and S→M doorbells. The
   existing Agent F baseline pass must hold (~6 min loop).
5. **`cocotb/tidelink_top_pair_skewed/`** (Agent L, in flight) — per-lane
   pad-skew variants where the eye is forced off (0,0). The new
   selection must converge symmetrically on M and S to the skewed
   eye centre. This is the primary regression check for the eye-edge
   silicon symptom.
6. **`cocotb/tidelink_top_pair_drift/`** (Agent M, in flight) — slow PPM
   drift between M and S clocks. The eye-centre pick should give a
   wider drift tolerance than the eye-edge pick before the link
   re-calibrates. Quantify the drift margin improvement.
7. **HW gate (post-sim sign-off):** rebuild on `pynq-z2-pair-flip-ila`,
   capture an ILA of `lane_locked[7:0]` over the first 10 s of FC
   traffic post-bringup. Per-lane re-drop rate must be ≤ 1 / minute
   (Agent K §7 item 2). If higher, MIN_LOCK_DWELLS needs raising
   per-deploy.

A test that does NOT exist yet but should be added: a sustained-edge
marginal stimulus regression (Agent K §7 item 6) — a lane that locks
fully at both (0,0) and (3,5). MIN_LOCK_DWELLS=4 must latch (3,5)
centre, not (0,0). Without that regression the §9.9 intent has no
unit-level guard.

---

## 6. Migration plan — S_PROBE retained, semantics changed

**The fix LAYERS on top of Agent F's S_PROBE state**, demoting S_PROBE
from "absolute priority" to "advisory / fallback":

* **Step 1.** Add `MIN_LOCK_DWELLS` parameter + new `run_len/best_run/
  best_run_start_*` flops to the calibrator. Default `MIN_LOCK_DWELLS=4`.
* **Step 2.** Insert `S_FINALIZE` state between S_SWEEP exhaustion and
  S_FINISH (one extra cycle).
* **Step 3.** Modify the per-dwell score-capture in S_SWEEP to also
  update the run-length tracker.
* **Step 4.** Modify the end-of-sweep latch to read from
  `best_run_start_*` plus a centre offset, not from `best_slip/best_phase`.
* **Step 5.** Demote S_PROBE: change line 644 (`lane_done[i] <= 1'b1` in
  the S_PROBE dwell_expire branch) to instead set
  `probe_lane_pass_q[i] <= 1'b1`. Do NOT set `lane_done[i]` or seed
  `best_*` from the probe. The probe verdict is consulted ONLY in
  S_FINALIZE if no MIN_LOCK_DWELLS-wide run was found.
* **Step 6.** Add APB register `SWI_CAL_MIN_DWELLS[3:0]` (Region 8,
  default 4, accepts 0..15) so silicon deploys can tune at runtime.
  Wired into the calibrator via a new top-level input that overrides
  the synthesis-time parameter.

Order matters: steps 1-4 are required for the eye-centre intent to be
realised; step 5 alone (without 1-4) would just remove S_PROBE's
benefit without replacing it. Steps 6 is optional and can land in a
follow-up if Region-8 changes are out of scope for the v2 freeze.

S_PROBE is NOT removed because:
* It provides a deterministic safety net for silicon where the
  best-of-sweep doesn't find a MIN_LOCK_DWELLS-wide run anywhere
  (degraded margin, last-chance fallback).
* It is the cocotb-sim regression's known-good path (Agent F's
  post-fix dump); demoting it preserves the sim pass.
* It is cheap (one state, one register vector).

---

## 7. Open questions for the user

* **Q1. MIN_LOCK_DWELLS = 4 right?** HW reviewer suggested 8; 4 gives
  ~25% phase-axis margin and maximises deploys that find an acceptable
  eye. Recommend synth default 4 with APB-runtime tune
  (`SWI_CAL_MIN_DWELLS`).
* **Q2. Synth-time vs APB-runtime?** Both. Cap APB range at
  `2 * synth-default` to bound `best_run` flop sizing.
* **Q3. Eye-width metric — slip-inner contiguous or 2-D adjacency?**
  Pseudocode uses slip-inner (natural sweep order); 2-D adjacency is
  ~3× flop budget. Stay 1-D unless HW shows under-selection.
* **Q4. Probe vs sweep tie?** Pseudocode prefers the sweep winner
  (eye-centre intent). Cocotb M/S symmetry holds either way on
  bit-exact PHY.
* **Q5. Deprecate `EARLY_EXIT_ON_ALL_LOCKED`?** Yes — the full sweep
  is required to measure run length. Leave the param tied off so
  existing hierarchical forces don't break.
* **Q6. S_FINALIZE timing — one cycle?** Pseudocode is combinational.
  Fallback: split across 2 cycles if ASIC corner needs it; no
  observability change.

---

## 8. Bottom line

The structural fix replaces "any passing point counts" with "the
**centre of the widest contiguous passing run** wins", with S_PROBE
demoted to a safety fallback. This addresses (a) the sim
M=(0,0)/S=(1,1) race-to-tie, (b) the HW edge-of-eye 4096-sample CRC
corruption, AND (c) the §9.9 eye-CENTRE design intent that Agent F's
S_PROBE silently abandoned. All three issues share a common root —
the calibrator was scoring eye **presence**, not eye **centre** — and
a single ~75-line RTL change with one new FSM state addresses the
common cause. The migration order is non-trivial (steps 5 alone is
worse than the current state); steps 1-5 must land together. Step 6
(APB-runtime tune) is decoupled and can follow.
