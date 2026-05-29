# Calibrator HW Failure Audit — 2026-05-29

Read-only forensic audit of the S_PROBE empirical HW failure on branch
`feat/td-gpio-phy-integration` at worktree
`/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ` (HEAD `f2ab31c`, parent
`925e647` — bitstream validated this morning).

Goal: explain why `S_PROBE` (spec
`deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md §7.3`) — claimed to
eliminate the AUTOCAL=1 M→S asymmetric corruption — does NOT hold on silicon.

This commit (`f2ab31c`) forces `AUTOCAL_ENABLE=1'b0` as a workaround
(`src/rtl/tidelink_top.sv:1891`). The audit examines the AUTOCAL=1 path that
fails in commit `925e647`.

---

## Executive summary

**Root cause is in the integration layer, not in `S_PROBE` itself.** When
Stage 6 (`8409d6b`) ported `S_PROBE` from `f900e07`, it simultaneously
**switched the per-cycle scoring predicate** from the lane checker's binary
`lane_locked[i]` (consecutive-match counter, resets on every miss) to a
continuous **`dwell_min_dist_i[5*i +: 5] <= LOCK_DIST_THRESHOLD (5'd3)`**
gate that reads the new `tidelink_lane_checker_single.dwell_min_dist_o`
output.

That `dwell_min_dist_o` is **monotonically decreasing across the entire
training window** — it only resets on `clear_noise_i` or the rising edge of
`training_mode_w_i`
([`tidelink_lane_checker_single.sv:208-216`](../deps/tidelink-gpio-phy/rtl/tidelink_lane_checker_single.sv#L208-L216)).
The calibrator never sends a per-dwell pulse on either input.

Net effect:

- During `S_PROBE` (the first ~64-cycle dwell after the `S_ARM`→`S_PROBE`
  edge) the score path is correct.
- From the moment `S_PROBE` ends, `dwell_min_dist_o` is sticky at whatever
  minimum was last seen and `lane_dist_pass_w[i]` is permanently 1.
- This false-passes every subsequent S_SWEEP dwell. `lane_score`
  saturates at `LANE_SCORE_MAX = 6'h3F` within 16 cycles at every
  `(slip, phase)`, so `any_pass_*` latches the FIRST sweep point
  `(slip=0, phase=0)` and `best_run` reaches 8 contiguous on slip 0..7
  of phase 0.

The `S_PROBE` *probe* result is therefore unverifiable by anything
downstream — its `probe_lane_pass_q` snapshot is the only signal that
reflects a real per-dwell minimum, and S_FINALIZE both prefers the broken
`best_run` path and would never reach the probe-fallback arm.

On master, the broken sweep happens to converge to (0,0) anyway (the
iterator starts there). On slave the same convergence happens, **but
(0,0) on slave is not the real eye centre** — the Y9-SRCC clock-pin path
(NORMAL mapping) sees a different pad/clock skew than Y7-MRCC (SWAP). The
broken sweep can no longer find the working point because it has lost the
ability to distinguish (slip, phase) sites.

This is the same family of bug we patched twice before: a verdict signal
that LOOKS like an in-dwell metric but is in fact a since-training-start
metric. The calibrator's narrative comments still describe "in-dwell
minimum" semantics — see
[`tidelink_phy_align_calibrator.sv:289-299`](../src/rtl/tidelink_phy_align_calibrator.sv#L289-L299)
and `§7.1` of the spec — but the producing FF doesn't implement that.

---

## Per-question verdicts

### A. Is S_PROBE actually being entered? — **LIKELY YES**

`S_ARM` always transitions to `S_PROBE` unconditionally (except `swreset`):
[`tidelink_phy_align_calibrator.sv:745-750`](../src/rtl/tidelink_phy_align_calibrator.sv#L745-L750).

```
S_ARM: begin
    if (swreset)            nxt_state = S_CANCEL;
    else                    nxt_state = S_PROBE;
end
```

There is no AUTOCAL-conditional bypass inside the FSM itself. AUTOCAL=1
just lets the `role_locked` trigger reach the calibrator
([`axi_chiplet_controller.sv:1387-1393`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L1387-L1393)),
which then enters `S_ARM`→`S_PROBE`. **DISPROVED that there is a bypass.**

### B. At S_PROBE entry, are sweep_slip and sweep_phase actually 0? — **DISPROVED (they are 0)**

[`tidelink_phy_align_calibrator.sv:927-973`](../src/rtl/tidelink_phy_align_calibrator.sv#L927-L973):
the `S_ARM` arm clears every iterator (`sweep_slip<=3'd0; sweep_phase<=4'd0`).
S_ARM is also the reset state — so both `rst` and the per-sweep `S_ARM` entry
guarantee `(sweep_slip, sweep_phase) == (0, 0)` for the entire `S_PROBE`
window.

The output mux at
[`tidelink_phy_align_calibrator.sv:1505-1517`](../src/rtl/tidelink_phy_align_calibrator.sv#L1505-L1517)
gates on `lane_done[i]`; in S_PROBE every lane has `lane_done=0`, so each
output is driven from `(sweep_slip, sweep_phase) == (0, 0)`.

This part of the spec is faithfully implemented.

### C. What happens to lanes that don't lock at (0,0) during S_PROBE? — **UNLIKELY to be the dominant bug, but partly broken**

The `S_PROBE → S_SWEEP` "fall-through for remaining lanes" mechanic is
present:
[`tidelink_phy_align_calibrator.sv:1084-1093`](../src/rtl/tidelink_phy_align_calibrator.sv#L1084-L1093)
freezes `lane_score=0` for lanes already `lane_done` after S_PROBE, and
[`1129-1130`](../src/rtl/tidelink_phy_align_calibrator.sv#L1129-L1130) gates
all `run_len` / `best_run` / `any_pass` updates on `!lane_done[i]`. The
output mux at line 1509 keeps the (0,0) latched value for lane_done lanes
regardless of the sweep iterator. So S_PROBE's verdicts ARE protected.

What is **broken** is the verdict itself — the score predicate that decides
which lanes get marked `lane_done=1` at the end of S_PROBE is unreliable.
See Hypothesis H1 below.

### D. LOCK_DIST_THRESHOLD value — **DISPROVED (= 5'd3, matches spec)**

[`tidelink_phy_align_calibrator.sv:640`](../src/rtl/tidelink_phy_align_calibrator.sv#L640):

```
localparam logic [4:0] LOCK_DIST_THRESHOLD = 5'd3;
```

This matches the spec value of T=3. Not the bug.

### E. cr_pkt_seen clearing affecting post-S_PROBE state — **UNLIKELY**

`cr_pkt_seen_i` is consumed only by `S_VALIDATE`
([`tidelink_phy_align_calibrator.sv:849-868`](../src/rtl/tidelink_phy_align_calibrator.sv#L849-L868)),
which is post-`S_HOLD`. The morning HW evidence shows `cal_done=1` and
`crack_pkt_seen=1`, indicating S_VALIDATE succeeded. So this path is not
involved in the (slip, phase) latching. **DISPROVED**.

### F. min_lock_dwells_i=4'h0 interaction with S_PROBE — **DISPROVED**

The `min_lock_dwells_eff` resolution path
([`tidelink_phy_align_calibrator.sv:668-671`](../src/rtl/tidelink_phy_align_calibrator.sv#L668-L671))
correctly treats `4'h0` as "use synth-time default" → `MIN_LOCK_DWELLS = 4`.
The S_PROBE pass criterion is `lane_score[i] >= lock_thresh_6b`
([`tidelink_phy_align_calibrator.sv:1033`](../src/rtl/tidelink_phy_align_calibrator.sv#L1033)) where
`lock_thresh_6b = LOCK_THRESH = 6'd16`
([`tidelink_phy_align_calibrator.sv:218`, `612`](../src/rtl/tidelink_phy_align_calibrator.sv#L612)).
`min_lock_dwells_i` does not feed the S_PROBE check; it only feeds the
S_FINALIZE `best_run >= min_lock_dwells_eff` arm.

So `min_lock_dwells_i=4'h0` doesn't change the S_PROBE pass bar. Not the
bug.

### G. obs_cr_pkt_seen_rx_w → cr_pkt_seen_i connection — **DISPROVED**

[`axi_chiplet_controller.sv:1431`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L1431):

```
.cr_pkt_seen_i         (obs_cr_pkt_seen_rx_w),
```

is correctly hooked to the FCSM observability signal. The morning evidence
`crack_pkt_seen=1` confirms S_VALIDATE saw the peer's CR_PKT and completed.

### H. Clock-domain difference between MRCC and SRCC paths — **MAYBE (secondary)**

The Y7-MRCC vs Y9-SRCC difference is not a calibrator FSM issue per se: the
calibrator runs entirely in `phy_link_rx_rx_link_clk_w`
([`axi_chiplet_controller.sv:1391`](../src/rtl/local_overrides/axi_chiplet_controller.sv#L1391)),
which is the recovered RX clock from the pad. Both pin assignments produce
the same logical clock for the calibrator.

What IS different: the **eye location on the (slip, phase) grid**. With
MRCC clocking the eye may be centred near a different (slip, phase) than
under SRCC clocking, because the clock-to-data skew on the pad pair
differs. A working calibrator should find either eye. But because the
score path (Hypothesis H1) is broken, the calibrator can no longer
distinguish a real eye from a transient hit — so whichever (slip, phase)
happens to be latched first (always (0,0) on master because S_PROBE biases
there; (0,0) on slave because the broken sweep also converges there) is
returned, regardless of whether (0,0) is the actual eye centre on that
clock path.

Net: H is a **consequence of H1**, not an independent bug.

---

## Ranked hypotheses

### H1 (LIKELY, top-1) — `dwell_min_dist_o` is sticky across dwells

**Citation**: `tidelink_lane_checker_single.sv:208-216`:

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dwell_min_dist_o <= 5'd16;
    end else if (clear_noise_i || training_mode_rise) begin
        dwell_min_dist_o <= 5'd16;
    end else if (dist_score < dwell_min_dist_o) begin
        dwell_min_dist_o <= dist_score;
    end
end
```

The signal is "minimum since training_mode rise OR clear_noise pulse",
NOT "minimum since dwell start". The calibrator runs ~129 dwells of 64
cycles each from one `training_mode_rise` edge, so:

- Dwell 1 (S_PROBE): the metric tracks correctly. Score may be 0..16.
- Dwell 2..129 (S_SWEEP, 8 phases × 16 slip-inner steps in the §9.11c
  iterator): metric is monotonic non-increasing, latched at whatever
  minimum any prior dwell achieved.

The calibrator's per-cycle predicate
[`tidelink_phy_align_calibrator.sv:657-658`](../src/rtl/tidelink_phy_align_calibrator.sv#L657-L658):

```
assign lane_dist_pass_w[gdist] =
    (dwell_min_dist_i[5*gdist +: 5] <= LOCK_DIST_THRESHOLD);
```

is therefore "did this lane EVER drop to ≤3 since training started" —
which is sticky-true for almost any real-world lane after the first dwell.

That feeds the S_SWEEP score accumulator at
[`tidelink_phy_align_calibrator.sv:1084-1093`](../src/rtl/tidelink_phy_align_calibrator.sv#L1084-L1093):
`lane_score[i]` saturates to `LANE_SCORE_MAX = 6'h3F` within ~16 cycles
of any dwell from dwell 2 onward, **regardless of whether the current
(slip, phase) point is actually a good eye**.

Downstream consequences:

1. `any_pass_valid[i]` latches at the FIRST S_SWEEP dwell
   ([`tidelink_phy_align_calibrator.sv:1142-1146`](../src/rtl/tidelink_phy_align_calibrator.sv#L1142-L1146)).
   Because S_SWEEP starts at `(sweep_slip=0, sweep_phase=0)` — these are
   preserved from the S_PROBE entry — `any_pass_slip=0, any_pass_phase=0`.
2. `run_len[i]` extends to 8 across slip 0..7 at phase 0, so `best_run=8 ≥
   min_lock_dwells_eff=4` triggers. `best_run_start_phase=0`,
   `best_run_slip=0` (the slip at which the run was found).
3. S_FINALIZE
   ([`tidelink_phy_align_calibrator.sv:1267-1280`](../src/rtl/tidelink_phy_align_calibrator.sv#L1267-L1280))
   takes the `best_run >= min_lock_dwells_eff` arm. centre_off=(8-1)>>1=3,
   so `phase[i] <= 0 + 3 = 3`, `slip[i] <= 0`.

Wait — that latches **phase=3, slip=0**, not (0,0). Re-checking the
ordering at
[`tidelink_phy_align_calibrator.sv:1211-1231`](../src/rtl/tidelink_phy_align_calibrator.sv#L1211-L1231):

```
if (sweep_slip == 3'd7) begin
    sweep_slip <= 3'd0;
    for (int i = 0; i < 8; i++) run_len[i] <= '0;   // reset on slip wrap
    ...
    sweep_phase <= sweep_phase + 4'd1;
end else begin
    sweep_slip <= sweep_slip + 3'd1;
end
```

So slip is inner, phase is outer. run_len tracks slip-axis contiguity per
the §9.11c comment. With sticky pass, run_len reaches 8 by end of phase=0
slip 0..7. best_run becomes 8 with `best_run_start_phase = 0` (the phase
the run was opened at) and `best_run_slip = 0` (the slip seeded by line
1172, but updated to the latest slip if the SAME run extends — which
it does — so best_run_slip ends up at 7).

This means S_FINALIZE latches:
- Master: phase = 0 + (8-1)/2 = 3 (4-bit truncation, OK), slip = 7.
- Slave: same, because the broken score path is symmetric across boards.

But Hypothesis H1's central claim still stands: **the calibrator is no
longer measuring the eye**. Whatever (slip, phase) gets latched is an
artefact of the iterator's reset semantics and the order in which `run_len`
crosses `min_lock_dwells_eff`, not of where the actual eye is.

The morning evidence of 8 lanes locked (`SWI_LANE_STATUS=0x018900ff`) is
consistent with this — the lane_checker's lock criterion uses `dist_match`
(voted distance after sweep ends, where vote_enable = locked_pre &
training_mode & ~sweep_active) which IS recomputed every cycle on real
data. So during the post-S_DONE `swi_training_mode_r=1` window, the
lane_checker DOES report lock — at whatever (slip, phase) the calibrator
happened to latch — but the latched point may be off-eye for slave.

This explains every morning symptom:
- `cal_done=1` — the FSM correctly walks to S_DONE.
- 8 lanes locked, WIRE_OK, canary OK — the latched (slip, phase) happens
  to be inside the training-pattern lock margin even at off-eye points
  (training pattern has min_cyc=8 so the matcher tolerates being a few
  bits off and still hits dist≤3 occasionally on training, especially with
  3-of-3 voting).
- M→S AHB doorbell intermittent / PTP HW_SYNC zero — real FC data has
  no such tolerance; with sample point off-eye, every other word is
  garbled and the FCSM credit handshake breaks.
- NORMAL fails / SWAP works — the working eye is on a different (slip,
  phase) for the two clock-pin orientations, but the calibrator latches
  the same broken value in both cases. SWAP just happens to put the
  working eye closer to phase=3, slip=7, so by chance the broken value
  matches the working point.

### H2 (LIKELY, top-2) — `clear_noise_i` is never pulsed by the calibrator

**Citation**: `axi_chiplet_controller.sv:1360`:

```
.clear_noise_i       (lane_clear_noise_i),
```

`lane_clear_noise_i` is sourced from the APB regs slave
([`tidelink_top.sv:961`](../src/rtl/tidelink_top.sv#L961)) — a 1-cycle pulse
generated when SW writes `SWI_LANE_NOISE_MODE[8]=1`. The calibrator does
NOT pulse this signal. There is no `clear_noise_o` output on the calibrator
at all.

In a healthy design the calibrator would pulse `clear_noise` at every
`S_PROBE` and `S_SWEEP` dwell boundary so the lane_checker resets its
in-dwell minimum tracking in lock-step with the calibrator's dwell counter.
That signal exists in the lane_checker (as the `clear_noise_i` port) but
is unwired at the calibrator side.

This is the same-class bug as H1 — H1 is "the signal is sticky", H2 is
"the calibrator forgot to reset it". Either one being fixed removes the
sticky behaviour.

### H3 (MAYBE, top-3) — phase-OUTER, slip-INNER iteration with sticky scoring loses the eye-centre intent

**Citation**: `tidelink_phy_align_calibrator.sv:1211-1219` (slip-inner
update) + `1183-1207` (the §9.11c comment that explicitly notes the
trade-off).

The §9.11 design comment explicitly says the slip-inner ordering means
"run_len[i] now tracks SLIP-axis contiguity (less meaningful as an 'eye
width' measurement — slip is rotation, not adjacent eye points)" and
expects the `any_pass_valid` fallback to fire instead. With H1's sticky
metric:

- run_len reaches 8 across slip 0..7 at phase 0 because EVERY dwell passes
  (saturating).
- `best_run >= min_lock_dwells_eff` triggers immediately at phase 0.
- The `any_pass_valid` fallback never gets reached for any lane.
- The result is bit-identical across master and slave because both have
  the same iterator and the same sticky-pass behaviour.

Even WITHOUT the H1 sticky bug, the slip-axis run-length tracker is
fundamentally measuring the wrong thing — slip is rotation (not adjacent
eye points), so a run of length N along slip doesn't say anything about
eye width. The original §9.11 design assumed phase-inner / slip-outer
specifically because phase is the actual sub-bit eye axis. Reverting
to §9.11c (phase-outer / slip-inner) on the assumption that "any_pass
will rescue us" only worked when any_pass was correctly gated.

This isn't the primary bug, but fixing H1 alone leaves the eye-centre
logic measuring the wrong axis.

---

## Recommended fixes

### Fix A1 — primary: per-dwell reset of `dwell_min_dist_o`

Add a `sweep_active_i` (or equivalently a per-dwell `dwell_clear_i`) input
to `tidelink_lane_checker_single` that resets `dwell_min_dist_o` to 5'd16
when asserted. Wire it from the calibrator's dwell boundary.

Concrete diff for `tidelink_lane_checker_single.sv`:

```diff
@@ tidelink_lane_checker_single.sv:208 @@
 always_ff @(posedge clk or negedge rst_n) begin
     if (!rst_n) begin
         dwell_min_dist_o <= 5'd16;
-    end else if (clear_noise_i || training_mode_rise) begin
+    end else if (clear_noise_i || training_mode_rise || dwell_clear_i) begin
         dwell_min_dist_o <= 5'd16;
     end else if (dist_score < dwell_min_dist_o) begin
         dwell_min_dist_o <= dist_score;
     end
 end
```

And add a port. On the calibrator side, expose a 1-cycle pulse at every
dwell expiry:

```systemverilog
// In tidelink_phy_align_calibrator.sv — new output:
output wire dwell_clear_o,
...
assign dwell_clear_o = (cur_state == S_PROBE  && dwell_expire) ||
                       (cur_state == S_SWEEP  && dwell_expire);
```

Wire it into the lane_checker through the chiplet_controller. The 1-cycle
pulse fires at the LAST cycle of each dwell, so `dwell_min_dist_o` resets
just before the calibrator advances `sweep_slip`/`sweep_phase` and starts
the next dwell.

### Fix A2 — alternative, simpler: revert calibrator scoring to `lane_locked[i]`

If we don't want to grow the lane_checker interface, restore the original
`f900e07` semantics — the binary `lane_locked[i]` consecutive-match path:

```diff
@@ tidelink_phy_align_calibrator.sv:649-660 @@
-    // Per-lane "this cycle passes" predicate using the new dist-score
-    // metric. lane_dist_pass[i] = (dwell_min_dist_i for lane i is at or
-    // below the LOCK_DIST_THRESHOLD).
-    wire [7:0] lane_dist_pass_w;
-    genvar gdist;
-    generate
-        for (gdist = 0; gdist < 8; gdist = gdist + 1) begin : g_dist_pass
-            assign lane_dist_pass_w[gdist] =
-                (dwell_min_dist_i[5*gdist +: 5] <= LOCK_DIST_THRESHOLD);
-        end
-    endgenerate
+    // f900e07 binary lane_locked path (per-cycle): the new lane_checker's
+    // lane_locked_o uses an internal saturating consecutive-match counter
+    // (see tidelink_lane_checker_single match_count) which already resets
+    // on miss, so a single cycle predicate captures real in-dwell behaviour
+    // without needing the lane_checker to track an in-dwell minimum.
+    wire [7:0] lane_dist_pass_w = lane_locked;
```

This is a smaller change, doesn't touch the submodule, and restores the
calibrator to the scoring semantics the original `f900e07` validation
was performed against. The trade-off: the spec's §7.1 noise-robustness
benefit (a single bit-flip doesn't zero the count) is lost. For
silicon-margin work this is the safer change.

### Fix B — secondary: revert iteration to phase-INNER / slip-OUTER (§9.11)

`tidelink_phy_align_calibrator.sv:1211-1231` reverts §9.11's phase-INNER
ordering to §9.11c's phase-OUTER / slip-INNER. The justification (M/S
sweep-window overlap) is no longer relevant under H1's fix because run-len
tracking now reflects real eye width. Restoring phase-INNER makes
`best_run` measure adjacent sub-bit phases — the actual sample-point eye —
not slip rotations.

```diff
@@ tidelink_phy_align_calibrator.sv:1211 @@
-        if (sweep_slip == 3'd7) begin
-            sweep_slip <= 3'd0;
-            for (int i = 0; i < 8; i++) run_len[i] <= '0;
-            if (sweep_phase == 4'd15) begin
-                // iter_at_end
-            end else begin
-                sweep_phase <= sweep_phase + 4'd1;
-            end
-        end else begin
-            sweep_slip <= sweep_slip + 3'd1;
-        end
+        if (sweep_phase == 4'd15) begin
+            sweep_phase <= 4'd0;
+            for (int i = 0; i < 8; i++) run_len[i] <= '0;
+            if (sweep_slip == 3'd7) begin
+                // iter_at_end
+            end else begin
+                sweep_slip <= sweep_slip + 3'd1;
+            end
+        end else begin
+            sweep_phase <= sweep_phase + 4'd1;
+        end
```

And `iter_at_end` becomes `(sweep_slip == 3'd7) && (sweep_phase == 4'd15)`
which is already its definition at line 691.

This change is independent of A1/A2 — apply in addition to either.

---

## ILA capture plan

A single ILA configuration confirms or falsifies H1 (the top hypothesis)
in one deploy.

Domain: `link_rx_clk_o` (the calibrator's clock). Same clock both ports.
Capture depth: 16384 (covers the entire ~8.2k-cycle sweep).

Probes:

| Signal | Source | Width |
|---|---|---|
| `cur_state` | `u_chiplet_controller.u_calibrator.cur_state` | 4 |
| `sweep_slip` | `u_chiplet_controller.u_calibrator.sweep_slip` | 3 |
| `sweep_phase` | `u_chiplet_controller.u_calibrator.sweep_phase` | 4 |
| `dwell_ctr` | `u_chiplet_controller.u_calibrator.dwell_ctr` | 7 |
| `dwell_min_dist_i` (all 8 lanes) | `u_chiplet_controller.u_calibrator.dwell_min_dist_i` | 40 |
| `lane_dist_pass_w` | `u_chiplet_controller.u_calibrator.lane_dist_pass_w` | 8 |
| `lane_score[0..7]` | `u_chiplet_controller.u_calibrator.lane_score` | 6×8 |
| `lane_done` | `u_chiplet_controller.u_calibrator.lane_done` | 8 |
| `probe_lane_pass_q` | `u_chiplet_controller.u_calibrator.probe_lane_pass_q` | 8 |
| `any_pass_valid` | `u_chiplet_controller.u_calibrator.any_pass_valid` | 8 |
| `best_run[0..7]` | `u_chiplet_controller.u_calibrator.best_run` | 5×8 |
| `best_run_slip[0..7]` | (same) | 3×8 |
| `best_run_start_phase[0..7]` | (same) | 4×8 |
| `slip[0..7]` | (same) | 3×8 |
| `phase[0..7]` | (same) | 4×8 |
| `swi_training_mode_w` | from chiplet_controller | 1 |

**Trigger**: `cur_state` rising edge to `S_ARM` (4'd1). With pre-trigger
50% the buffer covers S_IDLE→S_ARM→S_PROBE→S_SWEEP→S_FINALIZE→S_FINISH→
S_HOLD→S_VALIDATE→S_DONE.

**Verdicts after one capture**:

- **H1 confirmation**: look at `dwell_min_dist_i[5*0 +: 5]` (lane 0)
  as a function of time. If it monotonically decreases from 5'd16 across
  S_PROBE+S_SWEEP and never returns to 5'd16, H1 is CONFIRMED. If it
  resets to 5'd16 at every `dwell_ctr` wrap (every 64 cycles), H1 is
  FALSIFIED.
- **H1 secondary**: look at `lane_dist_pass_w[i]` across S_SWEEP. If it
  stays high after the first dwell on every lane, the calibrator is in
  the broken state.
- **(slip, phase) latch**: read `slip[0..7]` and `phase[0..7]` at S_DONE
  entry. Compare to the SW-readback (already known: cal latches whatever).
  Confirms the broken path produced the observed value.
- **H3 confirmation (independent)**: look at `best_run[i]` and
  `best_run_slip[i]`. If `best_run` reaches `min_lock_dwells_eff=4`
  immediately at the FIRST phase boundary (8 contiguous slips) and
  `best_run_slip` ends at 7 (because the run extended the whole way),
  H3 is consistent with the symptoms.

If H1 is FALSIFIED by this capture, fall back to capturing the
lane_checker's internal `dist_match`, `dist_score`, `dwell_min_dist_o`
inside `u_lane_checker.g_lane[0].u_chk` to verify whether the producing FF
ever resets.

---

## Confidence

**Confidence that fixing H1 (Fix A1 or A2) alone restores M→S doorbells
and PTP sync: 65%.**

What fixing H1 does:
- Makes `lane_dist_pass_w[i]` reflect real per-dwell quality.
- Restores S_PROBE's ability to truly distinguish (0,0)-passes from
  (0,0)-fails on the slave.
- Restores S_SWEEP's ability to score genuinely different (slip, phase)
  sites differently — so `any_pass_valid` and `best_run` would latch the
  ACTUAL first-pass / longest-run site instead of always-(slip=0,
  phase=0).

What it does NOT fix:
- The slip-INNER iteration in §9.11c means run_len still tracks the
  wrong axis. Fix B is recommended in addition.
- The Y9-SRCC vs Y7-MRCC eye-position asymmetry is a real physical
  effect. A working calibrator must find it regardless — H1 fix is
  necessary but the NORMAL-mapping eye centre must actually exist
  somewhere on the (slip, phase) grid for both master and slave. The
  morning evidence (lane lock works at the broken-latched value) suggests
  there IS a usable eye region; the calibrator just isn't finding the
  best point inside it.
- There may be a residual issue with the post-S_DONE vote_enable
  transition: when S_SWEEP ends and `sweep_active_i` drops, the
  lane_checker switches from `dist_raw` to `dist_voted` for both lock
  decision and noise registers. If the calibrator latched a (slip,
  phase) that locks on raw but not on voted (vote sees 3 phase-skewed
  samples from a marginal eye), the lane appears locked during training
  but loses lock the moment FC data starts. The morning evidence of
  `SWI_LANE_STATUS=0x018900ff` is captured during the training-hold
  window so this race is still hidden.

**Independent corruption mechanism to also verify**: the §10 spec says
"USE_T3A=0 ... the calibrator's per-lane (slip, phase) sweep + the new
dual-distance scoring + S_PROBE bias provides equivalent (and better-
validated) alignment". This rests on the calibrator producing the
correct (slip, phase). Once H1 is fixed, run the deploy mapping
NORMAL test. If M→S doorbells still fail, the next suspect is
`WavD2DGpioRx`'s `count` register starting at `4'hf` and free-running
mod-16 from POR
([`src/rtl/local_overrides/WavD2DGpioRx.v:529-533`](../src/rtl/local_overrides/WavD2DGpioRx.v#L529-L533))
— the slave's `count` may start mid-word relative to the master TX
because `io_por_reset` arrives ms-skewed across boards. The calibrator
can compensate with bit_slip, but only if it can MEASURE that the
compensation works — which Fix A1/A2 restores.

**Recommended sequence**:
1. Apply Fix A2 (revert score to `lane_locked` — smallest change, no
   submodule churn).
2. Apply Fix B (phase-INNER iteration).
3. Re-deploy with AUTOCAL_ENABLE=1. ILA capture per above.
4. If still failing, additionally apply Fix A1 (per-dwell reset signal
   into the lane_checker), giving up the cross-submodule bit-exactness
   guarantee.

---

## Files referenced

- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/tidelink_phy_align_calibrator.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/local_overrides/axi_chiplet_controller.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/local_overrides/WavD2DGpioTx.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/local_overrides/WavD2DGpioRx.v`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/src/rtl/tidelink_top.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/deps/tidelink-gpio-phy/rtl/tidelink_lane_checker_single.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/deps/tidelink-gpio-phy/rtl/tidelink_lane_checker.sv`
- `/home/dam1n19/SoCLabs/td-bisect/td-gpio-phy-integ/deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md`
