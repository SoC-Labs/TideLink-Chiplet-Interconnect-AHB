# Agent I — phy_align / calibrator test corpus mining

**Date:** 2026-05-26
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix`
**Branch:** `feat/sim-tidelink-top-pair-regression`
**Scope:** Inventory + run + git-archaeology on existing phy_align + calibrator
test corpora to shortcut the `AUTOCAL_ENABLE=1` M→S sideband-stuck bug
investigation.

---

## 1. Test corpus index

### 1a. `cocotb/phy_align/`  (pair-level, full Wlink master+slave)

| Test                                              | What it tests                                                                                                                              | Expected | Run (this branch) |
|---|---|---|---|
| `test_autocal_integrated.py`                      | End-to-end §9.6 in-RTL autocal: role-lock alone drives sweep to S_DONE; FCSM reaches state≥4. **Uses `_force_early_exit(...)` ⇒ bypasses S_HOLD.** | PASS    | **PASS** (84.6 µs sim) |
| `test_best_of_sweep.py`                           | §9.9 pointer-only file — `@skip`s; real test lives in `cocotb/tidelink_phy_align_calibrator/`.                                              | SKIP    | not run (skipped)      |
| `test_calibrator_skew_window.py`                  | §9 SEARCH-WINDOW contract: bit-slip ∈ [0..7] × phase ∈ [0..15] × DWELL=32; structural + dynamic traversal with `STUCK_LANES_MASK=16`.       | PASS    | not run (long)         |
| `test_capture_timing_margin.py`                   | DRAFT (not in CI) — autocal convergence under asymmetric per-lane skid + dead-lane negative control.                                       | (draft) | not run                |
| `test_credit_path_observability.py`               | Region-8 RO ECC counters + FCSM/byte-align obs upper bits in SWI_LANE_STATUS. **Uses `_force_early_exit(...)`.**                            | PASS    | not run                |
| `test_idelay_tap_wiring.py`                       | Structural check: per-lane IDELAYE2 tap source is `swi_phase_offset_w` byte-for-byte; bypass when USE_IDELAY=0.                            | PASS    | not run                |
| `test_pair_align.py`                              | §9 baseline: SW sweep of `swi_bit_slip` per lane 0..7; FCSM→state 4 on both sides with uniform `SKID_BITS=N`.                                | PASS    | **PASS** (556 ms sim)  |
| `test_pair_align_asymmetric.py`                   | §9 per-lane mode: different skid per lane, calibration recovers each per `SKID_LANE<n>` env vars.                                          | PASS    | not run                |
| `test_pair_align_asymmetric_master_slave.py`      | M→S and S→M routes with INDEPENDENT per-lane patterns — the two halves must converge independently.                                        | PASS    | not run                |
| `test_pair_align_partial_failure.py`              | Dead lane (`STUCK_LANES_MASK=16`): the sweep records lane 4 as un-locked; FCSM stuck at 1.                                                 | (needs param) | not run             |
| `test_pair_align_retraining.py`                   | §9.4: re-enter training after the link is up, re-sweep, re-exit; FCSM comes back to state≥4.                                               | PASS    | not run                |
| `test_pair_align_staggered_bringup.py`            | §9.8 NEGATIVE reproducer for the FPGA staggered-bringup autocal failure (slave faults 8 lanes). **Uses `_force_early_exit(...)`.**          | PASS-as-reproducer | **PASS** (243 µs sim) |
| `test_phase_sweep.py`                             | §9.7 per-lane slip×phase sweep — structural positive + negative control. **Uses `_force_early_exit(...)`.**                                 | PASS    | not run                |
| `test_rtl_fix_coverage.py`                        | Targeted: `apb_debug_unlock_i` opens mask_hs gate; SWI_RECAL re-triggers calibrator (cancel + re-sweep).                                    | PASS    | not run                |
| **`test_t32_shold_peerhold.py`**                  | **Pair-level T3.2 S_HOLD validator: with SKID_BITS=3, both sides hit sweep_success → both enter S_HOLD (state=6) with training_mode=1, cal_done=0.** | **PASS** | **FAIL** (1.4 ms sim) — see §2 |
| `test_t3_staggered_lottery.py`                    | T3 staggered-trigger reproducer + negative control (FSM-level discriminator, all-stuck fault branch).                                       | PASS    | not run                |

### 1b. `cocotb/tidelink_phy_align_calibrator/` (single-DUT, standalone)

| Test (file::test)                                                    | What it tests                                                                                                              | Status (this branch) |
|---|---|---|
| `test_calibrator_t3.py::test_t3_resweep_on_fault`                    | lane_locked=0x00 across one sweep → FSM S_FINISH→S_ARM (not →S_DONE); cal_done stays 0; train stays 1.                       | **PASS** |
| `test_calibrator_t3.py::test_t32_shold_on_success`                   | lane_locked=0xFF across one sweep → FSM S_FINISH→S_HOLD (state=6) with train=1, cal_done=0; later S_HOLD→S_DONE.            | **PASS** |
| `test_calibrator_t3.py::test_t32_shold_ignores_lane_drop`            | Drop lane_locked → 0x00 while in S_HOLD: FSM MUST hold S_HOLD until HOLD_CYCLES — no re-sweep, no premature release.       | **PASS** |
| `test_calibrator_t3.py::test_t3_resweep_advances_counter`            | resweep_ctr increments on each S_FINISH→S_ARM; trigger_now (role_locked rise) clears it.                                    | **PASS** |
| `test_best_of_sweep_compare.py`                                      | TB_VARIANT=compare; TWO calibrator DUTs (best-of-sweep vs first-match) seeing identical lane_locked, must pick DIFFERENT (slip,phase). | not run |
| `test_best_of_sweep_placeholder.py::test_best_of_sweep_default_walks_full_space` | Silicon-default best-of-sweep walks the full 1024-cycle 128-point space before S_FINISH.                                   | **PASS** |

---

## 2. Tests that already reproduce SOMETHING relevant to the bug

### **★ `cocotb/phy_align/test_t32_shold_peerhold.py` — fails on THIS branch**

Repro:
```sh
cd cocotb/phy_align
rm -rf sim_build ../wlink_pair/sim_build
make MODULE=test_t32_shold_peerhold SKID_BITS=3
```

Symptom on this branch (`feat/sim-tidelink-top-pair-regression`):
```
1400320.00ns INFO  [T3.2] sweep phase done: entered_hold m=-1 s=-1 ;
                   first cal_done m=-1 s=-1 ; fault_seen m=0 s=0 ;
                   FINAL m(state=2 done=0 fault=0x00 train=1)
                         s(state=2 done=0 fault=0x00 train=1)
AssertionError: MASTER calibrator never entered S_HOLD (cal_state_w==6)
  after a genuine sweep_success.
```

What this means:
- Both calibrators sit forever at `state=2` (S_SWEEP), `cal_done=0`,
  `training_mode=1`, `lane_fault=0x00`.
- They never advance to S_FINISH. So they never enter S_HOLD, never
  reach S_DONE.
- The assertion the test makes (S_HOLD entered) is true on **other**
  branches (the test's own header documents PASS→FAIL→PASS with a
  pre-T3.2 RTL swap). On THIS branch the FSM never even reaches the
  S_FINISH decision point.
- This is consistent with a different latent bug — `lane_locked` not
  rising in this pair TB, so the sweep walks 128 points × 32 dwell ×
  many resweeps without ever scoring a lane.

This is NOT yet a unit-level isolator of the M→S corruption bug — it
isolates a *different* failure mode (lane_checker not locking in the
pair TB at all). But it sits in the same blast radius (calibrator FSM
under a paired tb_top, no `_force_early_exit`) and the failure is loud
and fast (29 s wall, 1.4 ms sim).

### `cocotb/phy_align/test_pair_align_staggered_bringup.py` — passes as a NEGATIVE reproducer

This test's `@cocotb.test()` is explicitly written to ASSERT the bug is
still present (slave faults all 8 lanes). Header §"NOTE — §9
INTEGRATION" calls out:

> "the failure STILL reproduces: the second-running side faults all 8
> lanes. The assertion is NOT flipped to success — the I²C-coordinated
> training path that would fix staggered bring-up is gated by
> SHORTCOMINGS-14a"

Repro:
```sh
cd cocotb/phy_align
rm -rf sim_build ../wlink_pair/sim_build
make MODULE=test_pair_align_staggered_bringup SKID_BITS=3
```

This is the closest existing pair-level reproducer of *an* autocal
failure mode but it deliberately uses `_force_early_exit(True, True)`
on both sides to bypass S_HOLD — so it isn't probing the bug as it
manifests on HW + `cocotb/tidelink_top_pair/` (which does NOT use the
hook).

### `cocotb/tidelink_phy_align_calibrator/test_calibrator_t3.py` — all PASS

The single-DUT unit tests cleanly demonstrate that, *given* a clean
`lane_locked` input, the FSM does exactly what T3 + T3.2 specify:
S_HOLD with `training_mode=1` for HOLD_CYCLES, then S_DONE. So the
calibrator FSM itself is not the bug. The bug must be in
*integration* — either:

1. The calibrator never reaches S_DONE in the failing TB and stays in
   S_HOLD or S_SWEEP forever (matches the `test_t32_shold_peerhold`
   failure above and the `swi_training_mode_w` blocking-data
   mechanism), OR
2. The calibrator reaches S_DONE on one side and S_HOLD/S_SWEEP on the
   other → role-asymmetric `cal_training_mode_w` → asymmetric TX gating.

---

## 3. Git archaeology — commits touching the calibrator

`git log --oneline -- src/rtl/tidelink_phy_align_calibrator.sv`:

| Commit  | Message                                                                                  | Relevance to the M→S bug |
|---|---|---|
| `0208493` | docs: fold PHY_ALIGN integration plans                                                  | docs only |
| `b7de2d4` | **Revert** "rtl/lint: CDC fix in calibrator + addr_trans cleanup + docs" — **reverted because HW build #6 had setup violations on gpiorx_*/link_data_pad_clk_reg[*]** | irrelevant (revert); but the revert log itself reveals the calibrator comb chain is on the timing-critical RX-capture path |
| `65472ff` | rtl/lint: CDC fix in calibrator (REVERTED above)                                        | irrelevant |
| `a0df658` | rtl(calibrator): `unique case → case+default` — synth-safety                            | low — cosmetic |
| `28f1312` | rtl: HAL cosmetics                                                                       | low |
| **`c86f17b`** | **fix(§9 calibrator): `tb_early_exit_force_q` bypasses S_HOLD in sim**              | **HIGHLY RELEVANT — see §3.1** |
| `0d85843` | fix(§9 calibrator): best-of-sweep widest-eye latch (replaces first-match-wins)          | introduces best-of-sweep + `tb_early_exit_force_q` hook |
| **`50f7869`** | **fix(calibrator): T3.2 S_HOLD — peer-aware training hold**                          | **HIGHLY RELEVANT — introduces the S_HOLD state that gates `cal_training_mode_w` HIGH for ~1.05M apb cycles in sim** |
| `1e5f4e0` | fix(calibrator): continuous re-sweep until genuinely locked (T3)                        | introduces S_FINISH→S_ARM auto-rearm; training_mode stays HIGH across re-sweeps |
| `5633c69` | calibrator §9.7: per-lane slip×phase sweep + per-lane phase to PHY                      | foundational |
| `794313e` | STEP 1: trunk §9 base — autocal calibrator                                              | initial introduction |

### 3.1 The smoking gun: `c86f17b` commit body

> "T3.2 S_HOLD (commit 50f7869) adds 8·128·DWELL_CYCLES (~65K @
> link_clk_rx, ≈1.05M @ apb_clk in sim) between sweep_success and
> S_DONE → calibration_done asserts."
>
> "Existing integration tests poll cal_done with 4K-8K apb_clk timeouts
> (≈400-800 link cycles), which were sufficient pre-T3.2 (~256 cycles
> to S_DONE) but expire at ~0.4-0.8% of HOLD_CYCLES post-T3.2.
> Diagnostic dumps confirmed: lane_locked=0xff, fault=0x00, state=6
> (S_HOLD) — the link converges cleanly, the test just times out
> waiting for S_DONE."

And the RTL effect of `S_HOLD`:
```
training_mode    = (cur_state == S_ARM) || (cur_state == S_SWEEP)
                || (cur_state == S_HOLD);   // T3.2: hold pattern
calibration_done = (cur_state == S_DONE);
```
(src/rtl/tidelink_phy_align_calibrator.sv:738-740)

And the gating in `axi_chiplet_controller`:
```
wire swi_training_mode_w = cal_training_mode_w | swi_training_mode_r;
```
(deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1372)

So **while the calibrator FSM is in S_HOLD, `swi_training_mode_w=1`,
which (per the README and `WavD2DGpioTx.v` headers) makes the per-lane
TX serialisers emit the FIXED training byte instead of LL data**. Any
FC packet that the FC adapter pushes during this window is dropped on
the floor.

### 3.2 Which tests use the S_HOLD bypass and which don't

`grep -l "tb_early_exit_force_q" cocotb/**/*.py`:
- `cocotb/phy_align/test_autocal_integrated.py`               ← **uses the hook → bypasses S_HOLD → PASSES**
- `cocotb/phy_align/test_phase_sweep.py`                       ← uses the hook
- `cocotb/phy_align/test_pair_align_staggered_bringup.py`      ← uses the hook
- `cocotb/phy_align/test_credit_path_observability.py`         ← uses the hook
- `cocotb/tidelink_phy_align_calibrator/test_best_of_sweep_placeholder.py`

`grep tb_early_exit_force_q cocotb/tidelink_top_pair/` → **NO**.
`grep tb_early_exit_force_q cocotb/tidelink_chiplet_pair_autocal/` → **NO**.

**Inference (HIGH CONFIDENCE):** `cocotb/tidelink_top_pair/` does NOT
drive `tb_early_exit_force_q`, so its calibrator FSMs run the FULL
T3.2 hold cycle. With `AUTOCAL_ENABLE=1`, `wait_cal_done(max_cycles=
500000)` (~500K apb cycles) may or may not outlast the ~1.05M-apb-
cycle S_HOLD window. If the sim window happens to fall inside S_HOLD,
`cal_training_mode_w` stays HIGH on at least one side after the M→S
doorbell-write attempt → master TX is still emitting training pattern,
not the FC-adapter data → slave never sees the packet.

This precisely matches the AUTOCAL=1 failure signature in the handoff
doc (master FCSM visits state 5 for 6 cycles, slave stays at state 4)
— the master FC pushes the packet but the PHY TX is gated.

### 3.3 Other relevant archaeology

- `git log --grep="autocal" -i` highlights **`691916d fix(pynq-host):
  keep swi_enable=1 during LL swreset cycle`** — different but same
  family of "bringup gate gets stuck" issues.
- `git log --grep="calibrator" -i` highlights `7fa1ea5 merge:
  feat/sim-tidelink-top-pair-regression for calibrator debug` — the
  merge into this branch, confirming this is the active debug branch.

---

## 4. Pre-existing design docs

### `cocotb/phy_align/README.md` (verbatim excerpts)

The phy_align README catalogues all 17 tests and a §"Calibrator
skew-window contract" pinning the search window. It does **not**
discuss the S_HOLD blocking-data interaction.

### `cocotb/PHY_TESTS.md` (verbatim)

> "`tidelink_phy_align_calibrator.sv` T3/T3.2 → `cocotb/tidelink_phy_align_calibrator/` (this set): T3 continuous re-sweep on faulted sweep; **T3.2 S_HOLD on sweep_success keeps training_mode HIGH HOLD_CYCLES** and is insensitive to lane_locked drop; resweep_ctr semantics; best-of-sweep silicon default walks full 128-point space."

That **`T3.2 S_HOLD on sweep_success keeps training_mode HIGH
HOLD_CYCLES`** is exactly the M→S blocker mechanism.

### `cocotb/VERIFICATION_PLAN.md`

Comprehensive index of `tidelink_*` test suites; does **not** include
the autocal pair-level harness. No autocal-failure entry. The S_HOLD /
`cal_training_mode_w` interaction is not pinned by any verification
plan test ID.

### `docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md` (this branch)

The bug handoff names "**S_HOLD peer-aware state**" as suspect #3 and
"**`cal_training_mode` post-DONE residual**" as suspect #1, but treats
them separately. The corpus-mining evidence here unifies them: in the
failing TB the FSM may not be in S_DONE at all when the M→S doorbell
fires — it may still be in S_HOLD (or stuck in S_SWEEP, per the
`test_t32_shold_peerhold` failure on this branch).

---

## 5. Verdict — does any existing test isolate the bug at the unit level?

**No — but two existing tests are very close:**

### Closest unit-level coverage that EXISTS

1. **`cocotb/tidelink_phy_align_calibrator/test_calibrator_t3.py::test_t32_shold_on_success`** (unit, PASSES) — proves the FSM correctly enters S_HOLD with `training_mode=1` on `sweep_success`. The calibrator behaves as designed. The bug is therefore **NOT in the calibrator FSM logic** — it's in the *integration consequence* of the calibrator's spec-compliant behaviour.

2. **`cocotb/phy_align/test_t32_shold_peerhold.py`** (pair, FAILS on this branch) — proves that in the pair TB (which does NOT use `tb_early_exit_force_q`), the sweep does not complete normally — both sides park at S_SWEEP forever. So even without S_HOLD, this branch has a separate convergence issue in the pair sim.

### The missing test

**A `tidelink_top_pair`-shaped test that asserts the following invariant:**

> "After role_lock with `AUTOCAL_ENABLE=1`, the calibrator on BOTH sides must reach `cur_state == S_DONE` AND `cal_training_mode_w == 0` within N cycles. While `cal_training_mode_w` is high on ANY side, FC data packets from the FC adapter (master or slave) MUST NOT be expected to land at the peer's FC adapter RX."

There is currently no test that:
- Probes `cal_state_w` AND `cal_training_mode_w` simultaneously in a `tidelink_top_pair`-shaped harness, AND
- Correlates calibrator-state with FC data delivery (an `tl_fc_l2a_valid` assertion gated on `!cal_training_mode_w`).

The closest existing things are `test_calibrator_t3` (unit only, no FC adapter) and `test_tidelink_pair_doorbell` (Agent D, owns the pair-level harness — currently asserts doorbell delivery without observing `cal_training_mode_w`).

### Concrete shortest path to the fix

1. Read `tb.cal_state_name('m')` and `tb.cal_state_name('s')` from the existing `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py::PairTB` immediately before each doorbell write — that probe is *already* exposed (commit `0a538de`). The expected output if this hypothesis is correct: `M=HOLD S=HOLD` or `M=DONE S=HOLD` while `test_05 M→S` fails.
2. If confirmed: the fix is one of:
   - Drive `tb_early_exit_force_q=1` on both `u_calibrator` instances in `cocotb/tidelink_top_pair/tb_top.sv` (parallels the `_force_early_exit` plumbing in phy_align tests).
   - OR shrink `HOLD_CYCLES` via a sim-side parameter override (T3.2 commit message permits a parameter override at instantiation; the current calibrator instantiation in `axi_chiplet_controller.sv` has no `#(...)` so this would need an axi-chiplet-controller edit which is **out of scope for this agent** per the constraints).
   - OR (RTL): make S_HOLD insensitive to the M→S asymmetry by guarding `cal_training_mode_w` with the peer's "I am also locked" signal — but that signal does not exist in the current RTL (T3.2 is open-loop on `HOLD_CYCLES`).

---

## 6. Test inventory file paths (load-bearing)

- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/cocotb/phy_align/README.md` — phy_align corpus index + skew-window contract.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/cocotb/PHY_TESTS.md` — §9 unit-test mapping; T3.2 S_HOLD line is the most relevant single sentence in the docs.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/cocotb/VERIFICATION_PLAN.md` — does NOT cover autocal pair.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md` — bug handoff; suspect list aligns with mining findings.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/src/rtl/tidelink_phy_align_calibrator.sv:738-740` — the `training_mode = ... || S_HOLD` line.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1372` — `swi_training_mode_w = cal_training_mode_w | swi_training_mode_r` integration gate.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/cocotb/tidelink_phy_align_calibrator/test_calibrator_t3.py` — the four unit tests that pin T3/T3.2 spec; all PASS, confirming the bug is integration-side, not FSM-side.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/cocotb/phy_align/test_t32_shold_peerhold.py` — pair-level T3.2 validator that FAILS on this branch.
- `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix/cocotb/phy_align/test_autocal_integrated.py` — uses `_force_early_exit(True)` on both sides; PASSES; the canonical demo that the S_HOLD-bypass hook is what makes integration tests viable.
