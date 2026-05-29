# Agent K — Independent sceptical review of S_PROBE calibrator fix

**Reviewer role:** read-only, no edits, no sim runs.
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-fix`
**Branch / HEAD:** `feat/calibrator-bug-fix` @ `b5f92e8`
**Fix scope:** `src/rtl/tidelink_phy_align_calibrator.sv` only — adds new
`S_PROBE = 4'd7` state between `S_ARM` and `S_SWEEP`.
**Date:** 2026-05-27

---

## 1. Verdict

**AMBER — works in sim, ships with a concrete, identified silicon-risk
class around the eye-CENTRE design intent.**

The fix is structurally sound and self-consistent. The S_PROBE state really
does dwell at (slip=0, phase=0), really does latch only lanes that pass the
same LOCK_THRESH bar the rest of the FSM honours, and really does fall through
to S_SWEEP for any lane that fails the probe. Re-arm clears `lane_done`
correctly. The lane_checker's period-8 pattern selection
(`tidelink_lane_checker.sv:69-75`) specifically rules out the training-pattern
aliasing hazard Agent J flagged for slip detection: at slip in [0..7] each
(phase, slip) tuple has exactly ONE matching `{P,P}` 16-bit reference value.
So a marginal-but-aligned (0,0) is not a phantom — it really is a working
bit-alignment.

**HOWEVER**, the fix changes the per-lane selection POLICY from "longest
in-dwell run (eye-CENTRE)" to "first point that crosses the LOCK_THRESH bar,
with (0,0) given absolute priority". On silicon where (0,0) is at the EDGE
of the data eye (passes LOCK_THRESH but barely), S_PROBE will latch (0,0)
and S_SWEEP will never get to discover the wide-eye centre at e.g. (3, 5).
This is exactly the section 9.9 eye-edge-oscillation regression the
best-of-sweep policy was DESIGNED to defeat (top-of-file comment lines
110-128). The fix therefore DOES preserve correctness (the lane will lock)
but does NOT preserve the DESIGN INTENT (the lane will lock at the
eye-CENTRE for robust steady-state operation). In a tight-eye /
high-PVT-variation deploy this can re-introduce the original
0xf5/0xfd/0xd5/0xd7 bringup-trajectory oscillation that motivated the
section 9.9 change. Critically, the existing unit test
`cocotb/tidelink_phy_align_calibrator/test_best_of_sweep_compare.py::test_best_of_sweep_picks_widest_eye`
is precisely a regression check for this — see section 5 below; the test
happens to still pass by a hair because the marginal stimulus drops
`lane_locked` mid-dwell at exactly cycle 18, but it's testing the OLD
intent against the NEW behaviour purely by accident of timing.

The fix is the right direction for resolving the *immediate*
M=(0,0)/S=(1,1) asymmetry. It is NOT the right place to stop if the
project is going to silicon at PVT extremes.

---

## 2. Lane-checker semantics audit — does `lane_locked=1` guarantee eye coverage?

**File:** `src/rtl/tidelink_lane_checker.sv`

```systemverilog
localparam logic [7:0] PATTERNS [0:7] = '{
    8'hA3, 8'hB5, 8'hC9, 8'hD3,
    8'h65, 8'h4B, 8'h59, 8'h2D
};
// "period-8 patterns give unambiguous calibration."
wire  [15:0] expected_word = {expected_byte, expected_byte};
wire         is_match      = (word_in == expected_word);
// match_count saturates at 31, locked = (match_count >= LOCK_THRESH).
```

The patterns are explicitly chosen so that **no cyclic rotation by 1..7 of
any PATTERN[i] is equal to PATTERN[i] itself.** That means:

* For a given lane there is **exactly one** value of `bit_slip` in [0..7]
  that makes the rotated 16-bit window equal to `{P,P}`. There is **no
  training-pattern aliasing** in the slip dimension.
* `phase_offset` controls the SAMPLING-POINT alignment (`adj_count = count
  + io_phase_offset` in `WavD2DGpioRx.v:180`) — it does NOT change the
  reference value the checker compares against. A wrong `phase_offset`
  produces a wrong 16-bit `word_in`, which fails the byte-equality check.

**So lane_locked=1 means: at this (slip, phase) we sampled a 16-bit window
that exactly matches the period-8 training byte pair for at least
LOCK_THRESH consecutive cycles.** Because the bytes are period-8 (no
shorter period), this is unambiguous evidence of correct byte alignment
AND correct sample-point selection.

**However** — and this is the load-bearing caveat — the lane_checker is
only running while `training_mode=1` and the peer is transmitting the
training pattern. Once training drops and the link carries real FC packets:

1. The 16-bit window content stops being `{P,P}` for any reference P.
2. The (slip, phase) values that LOCKED on the training pattern are still
   bit-for-bit the same rotation of the captured bits.
3. The lane checker stops asserting `lane_locked`, but the deserialiser
   keeps the same (slip, phase) configuration latched into
   `swi_bit_slip_in / swi_phase_offset_in`.

**The crucial assumption is that "bit-aligned at training" implies
"bit-aligned at FC data".** This holds IFF the per-lane sample-point delay
chain is data-rate-independent (i.e. the eye doesn't move when transition
density changes). On the GPIO PHY in cocotb's bit-exact skid-bypass this
is trivially true. On silicon at high data rates the eye CAN move under
transition-density shifts (ISI), and Agent J's PHY_DESIGN_AUDIT Hole #5
calls out a non-determinism on the `count` register that exacerbates this.
So:

* **In sim**: lane_locked=1 implies correct RX, guaranteed.
* **On silicon with healthy margins**: lane_locked=1 implies correct RX,
  very likely.
* **On silicon at PVT extremes / tight eye**: lane_locked=1 at (slip=0,
  phase=0) MAY NOT guarantee correct RX of real data — the eye centre
  may be at a different (slip, phase) and (0,0) is on the edge. This is
  where the eye-CENTRE design intent matters.

This is the AMBER risk in section 1.

---

## 3. Per-lane mixed scenario analysis — 6 lanes at (0,0), 2 at (1,1)

**Behaviour:** at S_PROBE dwell_expire, the 6 lanes that locked get
`lane_done[i] := 1`, `slip[i] := 0`, `phase[i] := 0`,
`best_score[i] := lock_thresh_6b`, `best_slip[i] := 0`,
`best_phase[i] := 0`. `probe_all_locked` evaluates to 0 (2 lanes failed),
so we go to S_SWEEP.

In S_SWEEP, for the 6 already-done lanes:

* **Output mux** (`tidelink_phy_align_calibrator.sv:846`): `if
  (lane_done[i]) bit_slip_internal[3*i +: 3] = slip[i] /* = 0 */; else =
  sweep_slip /* the live iterator */;` So the 6 already-done lanes drive
  (0,0) to the PHY for the entire remaining sweep. **Correct.**
* **Score update** (lines 679-691): `if (lane_done[i]) lane_score[i] <=
  6'd0;` so the already-done lanes' score is held at 0. The best-of-sweep
  comparator is `if (lane_score[i] > best_score[i])` — with score=0 and
  best_score=16 this never fires. **Correct.**
* **Final-dwell exhaustion latch** (lines 750-796): `if (!lane_done[i])`
  gates the entire latch arm — already-done lanes are not touched.
  **Correct.**

For the 2 still-sweeping lanes:

* They walk all 128 points normally.
* `lane_score` accumulates and `best_score / best_slip / best_phase` are
  updated as before.
* At sweep exhaustion the lane latches from `best_*` (or live iterator
  if the final dwell is the first-locking dwell — line 779).

**This branch is correct.** The fix correctly maintains per-lane
independence for already-done vs still-sweeping lanes. I did not find a
state-corruption bug here.

One subtle gotcha worth flagging for HW: the OTHER 2 lanes are STILL
subject to the original Agent A S1 race-to-tie bug — the S_SWEEP
best-of-sweep latch policy is unchanged for them. So if 2 of 8 lanes need
a non-(0,0) phase, **those 2 lanes can still independently converge to
different (slip, phase) on master vs slave**, re-introducing the original
M=(0,0)/S=(1,1) class of bug for the per-lane subset that didn't lock at
(0,0). Agent F's own "Silicon risk" section acknowledges this; my read
confirms it.

---

## 4. Re-arm path — `lane_done` clearing semantics

**Trigger:** `trigger_now = role_locked_rise | (swreset_fall &
role_locked)` (line 301). Both transitions go S_DONE -> S_ARM (line 512),
S_IDLE -> S_ARM (line 449), or S_FINISH -> S_ARM (line 508 — auto
re-sweep on faulted sweep).

**S_ARM datapath** (lines 596-613):
```systemverilog
S_ARM: begin
    dwell_ctr    <= '0;
    lane_done    <= 8'h00;   // <-- cleared
    lane_fault_q <= 8'h00;
    sweep_slip   <= 3'd0;
    sweep_phase  <= 4'd0;
    for (int i = 0; i < 8; i++) begin
        slip[i]       <= 3'd0;
        phase[i]      <= 4'd0;
        lane_score[i] <= 6'd0;
        best_score[i] <= 6'd0;
        best_slip[i]  <= 3'd0;
        best_phase[i] <= 4'd0;
    end
end
```

S_ARM is one-cycle and unambiguously clears `lane_done` for all 8 lanes
before the next-state transitions into `S_PROBE`. There is no path where
S_PROBE can be entered with stale `lane_done[i]=1` from a previous sweep.
**No stuck-at-(0,0) lockup across re-trigger.**

**One nit:** the comment at lines 545-548 says "Bring-up default
MAX_RESWEEPS=0 ⇒ this just free-runs and retry_exhausted stays 0."
Combined with the S_FINISH -> S_ARM auto re-sweep on `!sweep_success`,
that's a **continuous re-sweep loop with `training_mode` held high**
until both peers converge. With S_PROBE in the loop, every re-sweep
starts with another S_PROBE dwell at (0,0). Each re-sweep that probes a
momentarily-marginal (0,0) will latch (0,0) and discard the sweep — even
if the EYE is no longer at (0,0). This is benign IF (0,0) really is the
eye centre, but is the worst-case behaviour if the eye drifts away from
(0,0) over time (thermal, voltage). Probably out of scope for the current
sim-fix but worth a silicon-deploy ILA on `lane_done` and the latched
`slip[i] / phase[i]` trajectory across multiple re-sweeps.

---

## 5. Best-of-sweep design-intent preservation

**This is where the fix gives up the most.**

Section 9.9 (top-of-file comment lines 110-128) explicitly says:

> FIELD MOTIVATION: with first-match-wins (the section 9.7 policy) the
> chosen (slip,phase) for a marginal lane was the FIRST eye edge
> encountered in the sweep order, not the eye CENTRE. Lanes that just
> barely cleared the 16-consec-match LOCK_THRESH at the eye edge bounced
> in/out of lock in steady state — see bringup_health_probe trajectories
> oscillating 0xf5/0xfd/0xd5/0xd7 (master) and 0xce/0x7f/0xee (slave).
>
> New policy: ... we score each lane's lock-count behaviour at the current
> (slip,phase) and remember the BEST scoring pair per lane.

The S_PROBE fix INVERTS this:

| Scenario | Section 9.9 intent | S_PROBE behaviour |
|---|---|---|
| Lane locks for 17/32 dwell cycles at (0,0), locks for 32/32 at (3,5) | Latch (3,5) — eye centre | Latch (0,0) — eye edge |
| Lane locks for 32/32 at (0,0), locks for 32/32 at (3,5) | Tie — earliest wins per Agent A S1 → (0,0) | Latch (0,0) — same |
| Lane locks for 15/32 at (0,0), locks for 32/32 at (3,5) | Latch (3,5) | Latch (3,5) — S_PROBE didn't pass |
| Lane locks for 32/32 at (0,0), never elsewhere | Latch (0,0) | Latch (0,0) — same |

The CASE 1 row is the eye-edge-oscillation regression class. In sim with
bit-exact skid this scenario doesn't arise because every (slip, phase) is
either fully-locked or fully-broken. On silicon at PVT extremes this
scenario IS the design motivation.

**Cocotb regression evidence:** the existing test
`cocotb/tidelink_phy_align_calibrator/test_best_of_sweep_compare.py::test_best_of_sweep_picks_widest_eye`
sets MARGINAL_RUN_LEN=18, LOCK_THRESH=16, DWELL_CYCLES=32, and expects
the best-of-sweep DUT to latch (WIDE_SLIP=3, WIDE_PHASE=5), NOT
(MARGINAL_SLIP=0, MARGINAL_PHASE=0). With S_PROBE the marginal lane's
`lane_score` reaches 18 at cycle 17 and then RESETS to 0 at cycle 18 when
`lane_locked` drops, so at dwell_expire (cycle 31) `lane_score = 0` and
the probe-pass condition `lane_score >= 16` is FALSE — the lane falls
through to S_SWEEP. The test happens to still pass. **But this is by
sheer accident of stimulus timing.** Change MARGINAL_RUN_LEN from 18 to
19 (or DWELL_CYCLES from 32 to 17) and the lane would score 19 at
dwell_expire and S_PROBE WOULD latch (0,0). The test was written against
the section 9.9 eye-CENTRE intent; the new behaviour preserves it only
because the marginal stimulus deliberately drops lock mid-dwell. A more
realistic sustained-marginal-edge stimulus (lane locked for the full
dwell at (0,0) AND for the full dwell at (3,5)) would now produce the
same answer as the LEGACY first-match-wins behaviour — defeating the
section 9.9 change.

The fix author acknowledges this in `agent_f_fix_attempt.md` "Silicon
risk":

> The bias is preserved only for lanes where it physically works.

— but the framing understates the actual policy change. The fix doesn't
just "prefer (0,0) when it works"; it **discards eye-centre information
for every lane that passes the LOCK_THRESH bar at (0,0)**, even when a
wider eye exists elsewhere in the sweep space. That's a different
statement.

---

## 6. Training-pattern aliasing risk

Agent J's archaeology (`docs/agent_j_branch_archaeology.md:215-222`) says:

> The training bytes happen to **look identical under any `count` phase**
> (period-8 within the byte + {P,P} double-fill), so the misalignment is
> undetectable during training and catastrophic during FC data.

**This claim applies to `count` phase, not to `bit_slip` or
`phase_offset`.**

* `count` is the per-lane mod-16 shift register state inside
  `WavD2DGpioRx`, which determines WHEN the 16-bit `link_data_reg`
  captures. It's a free-running counter that can have arbitrary POR
  initial phase (Hole #5). The training pattern's period-8 byte + `{P,P}`
  16-bit fill means the captured 16-bit word is the same value for any
  `count` initial phase that aligns to a serialiser boundary — the
  lane_checker can't tell these apart on the training pattern.
* `bit_slip` is a separate post-capture rotation. The lane_checker DOES
  see the bit_slip-rotated word and the period-8 PATTERNS[i] table is
  chosen so exactly one `bit_slip` value matches per lane.
* `phase_offset` is a third dimension — it shifts the `adj_count` and
  hence the `link_data_reg` capture moment AND the per-bit-position
  capture (lines 180-198 of `WavD2DGpioRx.v`).

The S_PROBE fix probes (slip=0, phase=0). The training-pattern aliasing
hazard around `count` is **orthogonal** — `count` is not part of the
calibrator's search space. Whether (slip=0, phase=0) actually corresponds
to "RX captures the byte correctly" depends on the `count` initial phase,
which is non-deterministic per power-on.

**Concrete risk:** if `count` happens to have a phase that makes (0,0)
*appear* to lock the lane_checker but actually skews the capture window
so that real FC data is misaligned, the S_PROBE fix will latch (0,0) and
the link will silently mis-decode. This is the **Hole #5 problem in
PHY_DESIGN_AUDIT_2026_05_26.md** — it is upstream of this calibrator fix
and is not introduced by it, but the calibrator fix makes the link more
SENSITIVE to it because (0,0) is the *preferred* point. Previously,
best-of-sweep at least had a chance of finding a (slip, phase) that
compensated for a bad `count` phase by accident.

The PHY audit recommends Fix-E: deterministic `count` startup via APB
`PHY_COUNT_SEED[3:0]`. Without that, S_PROBE@(0,0) plus non-deterministic
`count` is a lottery — fine in cocotb's bit-exact PHY, unknown on
silicon.

---

## 7. Outstanding silicon-deploy risks (concrete things to monitor)

1. **Per-deploy latched (slip, phase) histogram.** On HW deploys, capture
   `slip[i]` and `phase[i]` for both M and S calibrators via APB
   `SWI_LANE_STATUS` reads (or ILA on `u_calibrator.slip`/`phase`).
   * Expect: all 8 lanes at (0,0), both sides match (the sim post-fix
     dump shows this).
   * If: M=(0,0) for some lanes but S=(non-zero,non-zero) for the same
     lanes, the S_PROBE didn't lock on the slave — i.e. (0,0) is OUTSIDE
     the eye on the slave's RX. Investigate IDELAY tap, supply, clock
     skew.

2. **Steady-state lane re-drop rate.** After M→S traffic starts, monitor
   `bringup_health_probe` or `SWI_LANE_LOCK` polling at 100 Hz. If any
   lane drops/recovers > once / second, the eye is at the edge —
   S_PROBE has latched a non-centre point. Re-introduces the section 9.9
   eye-edge-oscillation symptom. **Recommended ILA: `lane_locked[7:0]`
   on a long capture across the first 10 seconds of FC traffic.**

3. **PVT corner sensitivity.** Re-deploy under cold/hot variants if
   possible. If the deploy is fine at room temp but mis-RXs at low
   temp / high voltage, the eye centre shifted away from (0,0) under
   that corner and S_PROBE@(0,0) marginally cleared LOCK_THRESH but is
   no longer covering the new eye centre. This is the AMBER risk
   manifesting.

4. **`count` initial phase.** Add an ILA probe on
   `u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count` after training
   drops, on multiple POR cycles. If different POR cycles show different
   `count` values AND the M→S health varies between those POR cycles,
   Hole #5 is biting through S_PROBE.

5. **Re-sweep loop behaviour with `MAX_RESWEEPS=0`.** If `lane_locked`
   on the silicon flickers during S_PROBE (a real possibility — the
   first locking dwell often sees the peer's training pattern starting
   late), the FSM enters an auto re-sweep loop that re-probes (0,0)
   every time. Verify on HW that `cal_done` rises within an
   engineering-reasonable wall time (the comment says ~few-hundred-µs;
   if it stretches to ms, the probe is racing with the peer's training
   drop).

6. **Cocotb regression coverage.** The current
   `test_best_of_sweep_picks_widest_eye` passes only because of
   stimulus-timing accident (see section 5). Add a regression that
   exercises a sustained-edge marginal pattern (lane locked for the full
   DWELL_CYCLES at both (0,0) and (3,5)) — the new fix WILL fail it,
   exposing the policy change explicitly.

---

## 8. Recommended hardening (if any)

Listed in increasing order of intrusiveness:

### H1 — Add a "S_PROBE bias enable" parameter (cheap, 5 lines)

Wrap the S_PROBE state and the S_ARM -> S_PROBE transition in a parameter
`PROBE_ZERO_BIAS = 1'b1`. Default ON for the cocotb-symmetric integration
deploys; turn OFF for silicon deploys where eye-centre selection matters.
This makes the fix opt-in per-target rather than hard-coding the bias.

### H2 — Increase the S_PROBE LOCK_THRESH bar above the sweep LOCK_THRESH

Instead of using the same `lock_thresh_6b` for both the probe verdict and
the sweep verdict, parameterise the probe verdict with a higher bar
(e.g. `PROBE_LOCK_THRESH = 4 * LOCK_THRESH` if DWELL_CYCLES permits).
This means S_PROBE only latches (0,0) if the eye at (0,0) is WIDE (close
to saturation), not merely passing. Lanes whose (0,0) is on the eye edge
fall through to S_SWEEP and the best-of-sweep finds the true centre.
This is the smallest delta that preserves section 9.9 intent while still
resolving the M=(0,0)/S=(1,1) sim asymmetry.

### H3 — Compare S_PROBE score against S_SWEEP best at end of sweep

Even if S_PROBE latches (0,0), record `probe_score[i]` separately and at
sweep exhaustion compare it against the live `best_score[i]`. If the
S_SWEEP best is STRICTLY GREATER (i.e. a wider eye was found elsewhere),
prefer the S_SWEEP winner. The S_PROBE bias only wins ties or near-ties.
Implements approach #3 + Agent A's S1 fix faithfully: probe-bias wins
ties (resolves M/S asymmetry); best-of-sweep wins on strict eye-width
advantage (preserves section 9.9 intent). ~30 lines of RTL.

### H4 — Sideband-coordinated phase exchange

Agent E's option (2) in `agent_e_force_bisect_results.md`. After both
sides reach S_DONE, exchange per-lane (slip, phase) over I²C, apply
peer's values to local PHY. The "principled" fix. Requires a new I²C
autoneg sub-protocol and per-lane exchange registers. Not minimal but
addresses the fundamental issue (M and S are calibrating two DIFFERENT
RX paths and the search is not co-ordinated).

### H5 — Add `count` reset on training rise (orthogonal but related)

Wire Hole #1's `io_train_rearm` per `PHY_DESIGN_AUDIT_2026_05_26.md`
Fix-A. This makes `count` deterministic across training cycles and
removes the silent-aliasing hazard described in section 6. Independent
of the calibrator change — both are needed for robust silicon.

---

## 9. Confirmation that Agent A's S1 fix is also in this commit (not just S_PROBE)

The task brief asked whether the implemented Approach #3 includes Agent
A's S1 fix (always-latch-from-best, never-from-live-iterator + `>=`
comparator).

**Reading the S_SWEEP final-dwell latch (lines 750-796):**

```systemverilog
} else if (!lane_done[i]) begin
    if (best_score[i] >= lock_thresh_6b) begin
        slip[i]  <= best_slip[i];        // ALWAYS latch from best_*
        phase[i] <= best_phase[i];
    end else if (lane_score[i] >= lock_thresh_6b) begin
        // first-locking-at-final-dwell fallback
        slip[i]  <= sweep_slip;
        phase[i] <= sweep_phase;
    end else begin
        lane_fault_q[i] <= 1'b1;
    end
```

The PRIMARY path always reads `best_*` (never the live iterator). The
SECONDARY fallback to the live iterator is ONLY when the running best
never reached LOCK_THRESH AND the current dwell first crosses it. This
preserves the section 9.9 selection intent for the secondary-path lanes
(the ones that don't get latched by S_PROBE) — i.e. **Agent A's S1 IS
folded in here for the latch step**. Good.

However, the score-capture comparator at line 723 is still **strictly
greater** (`lane_score[i] > best_score[i]`), not `>=`. Agent A's S1
proposal was to make this `>=` so the EARLIER-equal point wins
deterministically. The current implementation does **NOT** apply this
half of S1. For the lanes that fall through to S_SWEEP (the 2-of-8
non-locking-at-(0,0) case), the same race-to-tie that originally
produced M=(0,0)/S=(1,1) is STILL there: if M's training pattern at
(1,5) ties with M's pattern at (3,5) on score, and S's training pattern
at those points ties differently, M can latch (1,5) and S can latch
(3,5). The S_PROBE fix only hides this for lanes where (0,0) works.

**Recommendation:** flip line 723 from `>` to `>=`. One character change.
Closes the Agent-A S1 hole for the still-sweeping subset. (Even better:
combine with H3 above so the probe-bias and the >=-comparator work
together.)

---

## Bottom line

The fix is a competent **integration sim repair** that resolves the
specific M=(0,0)/S=(1,1) symptom Agents D and E identified. The cocotb
post-fix dump (`docs/agent_f_probe_dump_post_fix.log`) confirms slave
`s_fc_l2a_v=1` at cycle 54 — the M->S packet now crosses, baseline
matches expected. test_05_doorbell_master_to_slave passes.

It is NOT a **silicon-readiness** fix. The section 9.9 eye-CENTRE design
intent is partially abandoned, the per-lane race-to-tie hole that Agent
A originally diagnosed is only partially closed (line 723 still uses `>`
not `>=`), and the underlying non-determinism in `count` initial phase
(Hole #5) is now papered over by S_PROBE rather than addressed.

For the immediate sim regression check + first silicon bring-up where
(0,0) happens to be a working point, **ship it**. For sustained
production deploys at PVT extremes, apply H2 + H3 + flip line 723 to
`>=` before the v2 freeze.
