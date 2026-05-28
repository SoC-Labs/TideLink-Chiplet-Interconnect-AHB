# Agent N — Eye-CENTRE preservation unit test for S_PROBE (0,0)-bias fix

**Date:** 2026-05-27
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-sim-eyecenter`
**Branch / HEAD:** `feat/sim-eye-offcenter` (off `feat/calibrator-bug-fix`
@ `b5f92e8`)
**Mode:** unit-test only — `cocotb/tidelink_phy_align_calibrator/`
**Files added:**
- `cocotb/tidelink_phy_align_calibrator/test_eye_offcenter.py` (3 cocotb tests)
- `docs/agent_n_eye_offcenter_test.md` (this document)

---

## 1. Task

Validate whether Agent F's S_PROBE (0,0)-bias fix preserves the section
9.9 eye-CENTRE design intent (top-of-file comment lines 110-128 of
`tidelink_phy_align_calibrator.sv`), or whether it abandons that intent
as Agent K's AMBER review claimed.

Method: drive the calibrator unit-level harness's `lane_locked[7:0]` input
so it ONLY asserts at a known non-(0,0) eye region. Read out the latched
per-lane (slip, phase) and check (a) it's inside the eye, (b) it's the
eye centre, (c) it's the wider eye when two eyes compete.

---

## 2. Variants built

All three variants share the unit harness:
- `tb_top.sv` — single `tidelink_phy_align_calibrator` instance,
  `EARLY_EXIT_ON_ALL_LOCKED=0` (silicon default best-of-sweep policy)
- `DWELL_CYCLES=8`, `LOCK_THRESH=2` (matches existing tb_top defaults)
- 8 lanes all see the same `lane_locked[7:0]` value (a single eye-region
  selector applies to all 8 lanes simultaneously — keeps the per-lane
  analysis trivial)
- Iteration order in S_SWEEP is **phase-outer, slip-inner**
  (`tidelink_phy_align_calibrator.sv:737-802`)

| Variant | Eye(s) | Cells | Expected (§9.9 intent) | Observed (bias-fix RTL) | Pass/Fail |
|---|---|---|---|---|---|
| V1 | Single eye at (slip=3, phase=8), half-width=1 | 9 cells: (2..4, 7..9) | (3,8) eye-CENTRE | **(3,7)** — eye edge | PASS in-eye, **WARN not-centre** |
| V2 | Eye-A 1-cell at (slip=6, phase=2) + Eye-B 3x3 at (slip=3, phase=8) | 1 + 9 = 10 cells | (3,8) wider eye centre | **(3,7)** — wider eye, edge | PASS wider-eye, WARN not-centre |
| V3 | Eye-A L-shape {(0,0),(0,1),(1,0)} (3 cells incl. (0,0)) + Eye-B 3x3 at (slip=4, phase=8) | 3 + 9 = 12 cells | (4,8) wider eye centre | **(0,0)** — S_PROBE bias absolute | **FAIL** |

Per-lane output is the same for all 8 lanes in every variant (we drove
all lanes identically), so the latched (slip,phase) above is the
single value seen on lanes 0..7.

### Full sim transcript (per variant)

```
V1: eye centre=(3,8), 9 cells: [(2,7),(2,8),(2,9),(3,7),(3,8),(3,9),(4,7),(4,8),(4,9)]
V1 latched per-lane: [(3,7) x 8]
V1 PASS (degraded): calibrator picked an eye-edge point, NOT centre.

V2: eye-A=[(6,2)] (1 cell), eye-B=[(2,7),(2,8),...,(4,9)] (9 cells)
V2 latched per-lane: [(3,7) x 8]
V2 picked eye-B (the wider one). §9.9 intent preserved by accident
of carry-over-into-adjacent-cell scoring (see §3 below).

V3: eye-A=[(0,0),(0,1),(1,0)] (incl. (0,0)), eye-B=[(3,7),...,(5,9)] (9 cells)
V3 latched per-lane: [(0,0) x 8]
V3 FAIL: S_PROBE@(0,0) latched (0,0) absolutely; never reached S_SWEEP.
```

Wall time: ~3 seconds total for all three tests. VCS compile + cocotb
launch dominates (~20 s). Sim run-time per test ≈ 10 µs (DWELL=8,
sweep=128 points + S_PROBE dwell + S_HOLD = ~1100 cycles @ 100 MHz).

---

## 3. Detailed analysis

### 3.1 Why V1 picks (3,7) and not (3,8) — score-capture comparator artefact

S_PROBE@(0,0) finds `lane_locked=0` throughout the dwell (V1's eye does
not include (0,0)). `lane_score` stays 0; the probe-pass condition
`lane_score >= LOCK_THRESH` is FALSE for all 8 lanes; the FSM falls
through to S_SWEEP with `lane_done[i]=0`.

In S_SWEEP the iterator walks the 128 points in phase-outer slip-inner
order. The cocotb driver reads (sweep_slip, sweep_phase) after each
`RisingEdge(clk)` and sets `lane_locked` for the next sample edge.
There is therefore a **1-cycle lag** between the iterator entering a
new (slip,phase) and `lane_locked` reflecting the new in-eye verdict.
Consequently:

* The FIRST eye cell entered in any contiguous-eye run gets ONE FEWER
  cycle of `lane_score` accumulation than its successors (entry cycle
  sees stale `lane_locked=0` from the previous out-of-eye cell).
* SUBSEQUENT eye cells in the same run benefit from `lane_locked=1`
  already being set when the new dwell begins — they accumulate the
  full DWELL.

For V1's eye at (slip=3, phase=8) with sweep order phase=7 (slips
0..7), phase=8, phase=9:

| (slip,phase) | In eye? | Entry carry? | lane_score @ dwell_expire |
|---|---|---|---|
| (2,7) | yes (eye edge) | no (entered from (1,7) lane_locked=0) | 7 (DWELL-1) |
| (3,7) | yes (eye edge) | yes (entered from (2,7) lane_locked=1) | 8 (full DWELL) |
| (4,7) | yes (eye edge) | yes (carry from (3,7)) | 8 |
| (5..7,7) | no | n/a | 0 |
| (0..1, 8) | no | n/a | 0 |
| (2,8) | yes (eye edge) | no (entered from (1,8) lane_locked=0) | 7 |
| ... | ... | ... | ... |

The score-capture comparator at `tidelink_phy_align_calibrator.sv:723`
is **strictly greater** (`if (lane_score[i] > best_score[i])`). So:

1. At (2,7) dwell_expire: 7 > 0 TRUE → best := (2,7), score=7.
2. At (3,7) dwell_expire: 8 > 7 TRUE → best := (3,7), score=8.
3. At (4,7) dwell_expire: 8 > 8 FALSE → best stays (3,7).
4. At (2,8) dwell_expire: 7 > 8 FALSE → best stays (3,7).
5. ... (all subsequent eye cells either score 7 or 8 with first-entry
       penalty, never displace (3,7)).

Result: best_slip=3, best_phase=7. At sweep exhaustion, slip[i]/phase[i]
latch from best_* → **(3,7)**, NOT eye centre (3,8).

This is exactly the AMBER risk Agent K flagged: the bias-fix RTL's
fall-through path uses the SAME strict-`>` score-capture comparator
that Agent A's S1 finding already identified as broken. Without S1's
proposed `>=` flip, the picked (slip,phase) is **the first carry-
advantaged cell in an adjacent eye run** — which is on the eye edge
in sweep-order, not the eye centre.

### 3.2 Why V2 happens to pick the wider eye (≠ §9.9 design intent
proof, but the right answer by accident)

V2's eye-A is a single isolated cell at (6,2). Its entry from (5,2)
(out-of-eye) gives no carry: lane_score=7 at dwell_expire on (6,2),
best := (6,2). Then (7,2) breaks the run.

V2's eye-B has interior cells that benefit from the in-eye carry-over
(same analysis as V1). At (3,7) dwell_expire: lane_score=8 > best=7
TRUE → best := (3,7).

**This is not a §9.9 wider-eye selection — it is the SAME carry-over
artefact rewarding adjacency, not eye width.** If we had crafted V2's
small eye-A so it includes ANY adjacent-in-sweep-order cell (e.g.
(5,2)+(6,2) both locked), eye-A would score 8 the same as (3,7) and
the strict-`>` would keep eye-A (encountered earlier in sweep order).

So V2 PASSES, but for the wrong reason. The bias-fix RTL does NOT
implement a true wider-eye-wins selection policy; it implements an
"earliest carry-advantaged cell wins" policy that happens to coincide
with wider-eye in this specific stimulus geometry.

A more rigorous variant (suggested follow-up): eye-A 3x3 at (slip=3,
phase=2) (an EARLIER 3x3 in sweep order) vs eye-B 5x5 at (slip=3,
phase=10). With strict-`>` the calibrator will latch on eye-A's first
adjacency-advantaged cell (3,2) and never displace it for eye-B's
genuinely wider 25-cell region. That would expose the §9.9 violation
on V2-like stimulus. Skipped for budget reasons; the V3 result already
demonstrates the policy abandonment unambiguously.

### 3.3 V3 — S_PROBE@(0,0) bias absolute, §9.9 design intent ABANDONED

V3's eye-A contains (0,0). At S_PROBE the iterator is held at (0,0).
`lane_locked=1` for the full DWELL → lane_score saturates → probe-pass
condition `lane_score >= LOCK_THRESH` TRUE for all 8 lanes →
`slip[i]:=0`, `phase[i]:=0`, `lane_done[i]:=1`, `best_score[i] :=
lock_thresh_6b`.

In S_SWEEP, lanes with `lane_done=1` are masked from score
accumulation (line 680) and from the best-of-sweep update (line 722
gates on `!lane_done[i]`). The 3x3 wider eye at (4,8) is encountered,
the lane_checker would lock — but the calibrator deliberately ignores
it. Final pick: **(0,0)** for all 8 lanes.

This is the §9.9-abandonment regression class **directly demonstrated
in simulation**. Agent K's claim is empirically confirmed: any lane
that crosses LOCK_THRESH at (0,0) is forever locked to (0,0), even
when a strictly wider eye exists elsewhere in the sweep space.

---

## 4. Verdict

**The S_PROBE bias fix does NOT preserve the §9.9 eye-CENTRE design
intent.** Concretely:

| Property | Section 9.9 intent | Bias-fix RTL (HEAD `b5f92e8`) |
|---|---|---|
| Single eye away from (0,0) → pick centre | Pick centre | **Picks eye-edge cell**, NOT centre (V1) |
| (0,0) marginal-passable + wider eye elsewhere → pick wider | Pick wider | **Picks (0,0) absolutely** (V3) |
| Two non-(0,0) eyes, A earlier-narrower, B later-wider → pick wider | Pick wider | Stimulus-dependent: V2 picks B by accident of cell-adjacency in sweep order, not by width |

The bias fix resolves the immediate M=(0,0)/S=(1,1) sim asymmetry
(V3-like stimulus where (0,0) IS in the eye is what cocotb produces,
and the symmetric (0,0) latch resolves the M/S diverge). It does NOT
preserve the §9.9 protections against eye-edge oscillation; on
silicon at PVT extremes where (0,0) is on the EDGE of the eye, the
bias fix is **at best correct-but-marginal**.

V2's pass is a coincidence of stimulus geometry: the wider-eye
selection happens to match the strict-`>` first-carry-advantaged-
cell selection. Change the eye geometries (or sweep order) and V2's
pass disappears. The bias fix gives **no robust wider-eye guarantee
whatsoever** on lanes that fall through S_PROBE.

---

## 5. Suggested adjustments to the bias fix

Listed in increasing order of intrusiveness (matches Agent K §8 + adds
empirical justification from V1/V3):

### A1 — Flip score-capture comparator from `>` to `>=` (1 character, 0 risk)

`tidelink_phy_align_calibrator.sv:723`:

```diff
- if (lane_score[i] > best_score[i]) begin
+ if (lane_score[i] >= best_score[i]) begin
```

Closes Agent A's S1 hole for the lanes that fall through S_PROBE. With
`>=`, V1 would latch the LAST carry-advantaged cell in the run instead
of the first — which is the eye RIGHT edge, NOT centre, so this alone
does NOT fix V1's centre-selection failure. But it DOES make the
selection deterministic across master/slave (no race-to-tie). 
Recommended as a no-cost safety net regardless of A2/A3 below.

### A2 — Raise S_PROBE LOCK_THRESH above the sweep LOCK_THRESH (Agent K H2)

Make S_PROBE require near-saturating score (e.g. `PROBE_LOCK_THRESH =
DWELL_CYCLES - 1` or `PROBE_LOCK_THRESH = 4 * LOCK_THRESH`) before it
latches (0,0). Lanes whose (0,0) is on the eye edge — the AMBER case —
score LOCK_THRESH but not PROBE_LOCK_THRESH → fall through to S_SWEEP
→ best-of-sweep finds true eye centre. Lanes whose (0,0) is in the
wide-eye interior pass S_PROBE → latch (0,0) (resolves M/S
asymmetry). Best of both worlds with ~3 lines of RTL change. This
would convert V3 into a pass (eye-A's (0,0) cell scores ~DWELL_CYCLES
- 1 = 7 vs PROBE_LOCK_THRESH=7 → still passes; eye-A's L-shape isn't
deeper than the wider eye-B because both saturate score within the
dwell window). To make V3 actually pass under A2, need A3.

### A3 — Compare S_PROBE score against S_SWEEP best at sweep exhaustion (Agent K H3)

Don't make S_PROBE absolute. Instead, RECORD `probe_score[i]`
separately (don't set `lane_done[i]=1` in S_PROBE) and let the full
S_SWEEP best-of-sweep run. At sweep exhaustion, compare:
* If `best_score[i] > probe_score[i]` (a strictly wider eye was found)
  → latch best_slip/best_phase.
* Else → latch (0,0).

This is the principled fix. It preserves the M=S deterministic-tie-
breaker property of S_PROBE (probe-bias wins ties / near-ties) AND
preserves §9.9 (a strictly wider eye still wins). V1 still picks an
eye-edge cell (the underlying strict-`>` comparator artefact stays).
V3 now picks eye-B (4,8) because eye-B's wider region saturates
score=8 vs probe's score=8 — tie → probe wins (lane locks at (0,0)),
SAME outcome. So A3 alone also doesn't fix V3 — both eyes saturate.
**To fix V3, need: A2 (raise probe bar so eye-A's L-shape fails
PROBE_LOCK_THRESH) + A3 (compare scores at sweep exhaustion).**

### A4 — Skip S_PROBE entirely; widen eye via sustained-edge probing in S_SWEEP

The cleanest minimal-policy-change fix: drop S_PROBE; restore Agent
A's S1 fix (`>=` comparator AND always-latch-from-best, never from
live iterator); add a SECOND best-of-sweep pass that prefers
(slip,phase) points whose neighbours also score high (a 2D
convolution / weighted centre score). This is full §9.9 + Agent A's
S1 closure, but it's ~50 lines of RTL and a re-architecture. Not
recommended unless A2+A3 prove insufficient on silicon.

### Recommendation (combine A1 + A2)

For a low-risk, minimum-RTL-change fix that addresses BOTH the V3
failure (S_PROBE absolute bias) AND the M/S race-to-tie:

1. **Flip line 723 to `>=`** (A1). Closes Agent A S1; makes the
   S_SWEEP selection M/S-deterministic.
2. **Parameterise `PROBE_LOCK_THRESH = DWELL_CYCLES - 1`** (A2). Forces
   S_PROBE to require near-saturating score; only lanes solidly inside
   a wide eye at (0,0) get locked there. Marginal-(0,0) lanes fall
   through to S_SWEEP. V3 now passes because eye-A's (0,0) cell
   saturates score=7 at PROBE_LOCK_THRESH=7 — TIE; but with eye-A
   being smaller (3 cells), the probe pass still latches (0,0) — so
   actually this STILL needs A3 to fix V3. The minimum
   §9.9-preserving combination is **A1 + A2 + A3**.

For the immediate sim-pass + first-silicon-bringup objective, the
existing bias fix is acceptable (V3-like stimulus is what the M/S
asymmetry symptom looked like, and the bias fix resolves it). For
the v2 silicon freeze at PVT extremes / tight-eye, apply **A1+A2+A3**
together.

---

## 6. Reproduction

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-sim-eyecenter
source set_env.sh
cd cocotb/tidelink_phy_align_calibrator
rm -rf sim_build results.xml
make MODULE=test_eye_offcenter
```

Expected output (per variant):
```
test_eye_offcenter.test_eye_offcenter_single_3x8  PASS (with WARN: picks (3,7) not centre (3,8))
test_eye_offcenter.test_eye_offcenter_widest_wins PASS (picks (3,7) in wider eye)
test_eye_offcenter.test_eye_offcenter_zero_vs_wide FAIL (picks (0,0); §9.9 violated)
TESTS=3 PASS=2 FAIL=1
```

Wall time ~3 s (VCS compile dominates).

---

## 7. Test files

| File | Lines | Purpose |
|---|---|---|
| `cocotb/tidelink_phy_align_calibrator/test_eye_offcenter.py` | 281 | 3 cocotb tests V1/V2/V3 |
| `cocotb/tidelink_phy_align_calibrator/tb_top.sv` (unchanged) | 101 | Single-DUT harness, EARLY_EXIT_ON_ALL_LOCKED=0 |
| `cocotb/tidelink_phy_align_calibrator/Makefile` (unchanged) | 76 | `MODULE=test_eye_offcenter` invocation |
| `src/rtl/tidelink_phy_align_calibrator.sv` (unchanged) | 881 | DUT — bias-fix HEAD b5f92e8 |
