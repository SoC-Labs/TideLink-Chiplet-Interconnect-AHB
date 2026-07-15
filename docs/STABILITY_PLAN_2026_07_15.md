# TideLink — Reassessment & Stability Plan (2026-07-15)

Synthesis across all active sessions (5+ parallel worktrees). Read this before
picking up work — it is the current consolidated view.

---

## 1. Where we actually are

**Two DIFFERENT problems have been conflated under "autonomy reliability". They are
independent, have different root causes, different fixes, and different owners.**

| | Problem | Nature | Status |
|---|---|---|---|
| **P-A** | Autonomy **CHANNELS** — B→A hard-dead (0/10), A→B/doorbell flaky | **LOGIC** clamp | Root-caused (HW single-variable). Fix in flight. **Silicon-proof pending.** |
| **P-B** | Bring-up **LOTTERY** + lane-7 SYNC fail | **PHYSICAL** capture-clock skew | Root-caused + **measured**. Fix in flight (clock-tree hoist). |

The months-long conflation of these is why nothing converged. They are now separated.

### The stable baseline (do not lose this)
- **RECIPE-mode all-channel bring-up: CERTIFIED 40/40 fresh-POR** (link + A→B + B→A
  byte-exact + doorbell). Clopper-Pearson 100% [91.2%, 100%]. This is the fallback and
  the only currently-shippable bring-up.
- **A tapeout chip-killer fixed + gated**: empty-RX-FIFO phantom pop (f9b94b7).

---

## 2. P-A — Autonomy channels (the deliverable blocker)

**Root cause, hardware single-variable-proven (NOT a hypothesis):** the B→A blocker is
the **MASTER die_a — the B→A RECEIVER — holding its own RX-commit while `autonomy_armed`.**
Causal test on the live drain-guard link: disarm die_b only → B→A still dead; ALSO disarm
die_a (`0x210C=0`) → B→A byte-exact immediately, `fe_rx_ptr` advances. Credit was nonzero
throughout (H2 credit REFUTED); RXCAP showed no SYNC substitution (H1 beacon REFUTED). The
framer CAPTURES words but won't COMMIT to GP1 while die_a is armed.

**CRITICAL REFINEMENT (caught pre-build):** B→A recovered at **R8=0x14 (insert_en STILL 1)**
the instant die_a disarmed. So **`autonomy_armed` ITSELF is the blocker, not `insert_en`/R8[2].**
=> The fix must **RETIRE autonomy** at anchor (replicate `0x210C=0`), not merely clear
insert_en. (`wip/b2a-fix` @ 1c0bed6 targeted insert_en — likely wrong variable;
re-targeted at 4f5223f/8d2f1e3 to event-gated retire-autonomy, per-episode one-shot.)

**My drain guard (0044bef) — necessary but works by ACCIDENT.** The local `Wlink.v` sets
`swi_delay_cycles` POR=0, so GPIO `postcount` never drains to 0, so the guard term is never
true → idle-gated beacons **never fire at all** on silicon. A→B improved 0→7/10 because
beacons were SUPPRESSED, not drain-window-guarded. Keep the guard (it's correct RTL and V1
has it), but know D2's "permanent beacons / peer never dark" is effectively OFF on the
built bitstream — which matters for **re-anchor under drift**, not initial lock.

**Why sim cannot help here:** the pair TB delivers B→A byte-exact even on UNFIXED RTL.
**Green sim_gate does NOT validate this fix.** Silicon-in-the-loop is mandatory.

**P-A acceptance:** on ONE named bitstream, zero-poke autonomous, N=40 fresh-POR,
B→A goes 0→passing AND A→B/doorbell become deterministic; anchor rate preserved.

---

## 3. P-B — The placement lottery + lane-7 (physical)

**MEASURED (routed die_a, 2026-07-14):** lane-7's **capture clock arrives ~7 ns LATER**
than its sibling active lanes (15.281 vs ~8.2–8.8 ns). Data-path skew across the same
lanes = 0.095 ns ⇒ **clock skew is ~70× the data skew.** The lane-7 blocker is **CLOCK
ROUTING, not a damaged conductor and not an analog eye.** It rides a residual fabric LUT
(`wpa_gap_q[3]_i_2`, fanout 372) on the RX capture-clock tree.

This retires several dead ends at once, with evidence:
- Explains why **div-2 "fixed" lane 7** (widened the UI until a fixed 7 ns skew survived).
- Explains why **IDELAY never could** (2.5 ns range vs 7 ns skew — every tap sweep doomed).
- Explains why **`pblock_rx_act` didn't fix it** (co-locating flops ≠ fixing the clock net).
- Confirms **`set_bus_skew` was always a red herring** — dead in every build, and a CDC
  construct that cannot bind a pad→register path anyway; the data skew is already tight.

**Fix in flight:** `phaseB/attack` — hoist the RX capture-clock mux chain into the parent
+ 2 shared BUFGs (get the clock off the LUT2 / fanout-372 general route).

**Note on urgency:** anchor is currently **29/29 on the two newest placements** — so on
those builds the lottery is not biting. But it is **build-dependent**; a rebuild re-rolls
it. The hoist makes it deterministic. **P-B acceptance: rebuild-variance soak — anchor rate
stable across ≥3 independent builds.**

---

## 4. Tapeout blockers (independent of P-A/P-B — must fix before tape)

1. **CHIP-KILLER: ASIC V2 flist pulls the WRONG deskew** (`deps/.../tidelink_lane_deskew.sv`,
   missing the F3c IDLE-ZERO qualifier) **+ ASIC lane mask = `0xFF`** (the E4 mask is
   FPGA-only, via `fpga/filelist.tcl`). ⇒ lane 0 can never commit `sync_seen` ⇒ **the chip
   never anchors.** One source of truth for the deskew + strap the lane mask.
2. **ASIC flow defaults to V1** — every silicon result is V2. Land `ASIC_PHY ?= _v2`.
3. **CI gates are `allow_failure: true`** — `sim_gate` and `merge_guard` cannot fail the
   pipeline. This one boolean is behind most of what shipped broken. Flip both.
4. **Consolidation:** NO single branch has everything (see §6). Assemble ONE candidate.
5. Latent RX-FIFO twins (held-NONSEQ lock; write-side length-latch) — same class as the
   phantom pop that already shipped.

---

## 5. THE BIGGEST STABILITY RISK RIGHT NOW: branch divergence

Five+ sessions are committing to divergent branches. Findings are converging in shared
memory, but the CODE is not. This is the primary instability.

| Branch | Carries | Silicon-proven? |
|---|---|---|
| `wip/phase2-pblock` | RX-FIFO fix, XHB restore, drain guard, harnesses, docs | recipe 40/40; drain guard partial |
| `wip/b2a-fix` | ↑ + event-gated retire-autonomy (the P-A fix) | **PENDING** — sim can't validate |
| `wip/sim-lottery-instrument` | ↑base + sim repro of the beacon/force_always defects | sim only |
| `phaseB/attack` | capture-clock-tree hoist (the P-B fix) | pending rebuild-variance |
| `wip/tapeout-candidate` | ASIC-V2 default, FCSM flist, farm_gate, a405809 revert | — |
| `feat/kr260-*` | KR260 port (pblock, EXTREFCLK mesochronous) | separate target |

**No branch has P-A + P-B + the tapeout fixes together.** Whoever consolidates must merge
ONTO the line carrying the ASIC fixes (tapeout-candidate lineage), or those get lost.

---

## 6. THE PLAN — sequenced, with acceptance evidence

### Phase 0 — Stop the divergence (do FIRST; ~half day, no hardware)
- Designate ONE integration branch off the `tapeout-candidate` lineage (it has the ASIC
  fixes nothing else has). Cherry-pick / merge in: RX-FIFO fix (f9b94b7), XHB restore,
  drain guard (0044bef), the P-A retire-autonomy fix once proven, the P-B hoist once proven.
- `merge_guard` must pass (it asserts the silicon-proven fixes survive the merge).
- **Acceptance:** one branch, `merge_guard` green, full `sim_gate` green, `farm_gate` green.

### Phase 1 — Land + SILICON-PROVE P-A (the deliverable; ~1 day, board-bound)
- Adversarially review the retire-autonomy fix for the D2 peer-starvation risk (turning
  autonomy off before the peer finishes anchoring). Empirically low (both dies anchor 29/29
  before data; `reanchored` is sticky) but must be reviewed, not assumed.
- Build ONE bitstream. Zero-poke autonomous soak, **N=40 fresh-POR**, all channels.
- **Acceptance:** B→A 0→passing, A→B/doorbell deterministic, anchor preserved, on a named
  md5. Because sim is blind here, this soak IS the gate — make it a standing silicon gate.

### Phase 2 — Land + prove P-B (physical determinism; ~1 day, board+build-bound)
- Build the `phaseB/attack` capture-clock hoist. Re-measure lane-7 capture-clock skew
  (target: down from 7 ns toward the ~8 ns sibling arrival — i.e. off the LUT).
- **Rebuild-variance soak**: ≥3 independent builds, autonomous anchor-rate must be stable
  (that is the whole point — kill the build lottery, not just one lucky placement).

### Phase 3 — Tapeout blockers (~1 day)
- ASIC V2 deskew flist + lane-mask strap (chip-killer). Add `asic_v2_elab` + a
  flist-resolution equivalence check to `sim_gate`.
- Flip CI gates to blocking.
- Close the RX-FIFO latent twins.

### Phase 4 — Lock it in
- Certification soak (N=40) on the FINAL consolidated bitstream, both recipe AND autonomous,
  md5 recorded. This is the deliverable evidence.
- Standing silicon-in-the-loop gate for the autonomy fixes (sim cannot cover them).
- Model the peer XHB target so XHB rejoins the blocking sim gate.

---

## 7. Honest risk register
- **P-A fix is silicon-unprovable in sim.** If the retire-autonomy trigger (`ws_anchor_q &&
  ws_verify_q`) is not reached in a fresh POR on die_a (one diagnostic showed `rea a=0`),
  the fix mis-fires. Must confirm the trigger fires per-cycle on hardware.
- **P-B: 29/29 may be a lucky placement**, not a solved lottery. Only the rebuild-variance
  soak settles it. Do not declare P-B fixed on one build.
- **Autonomy % is meaningless without a named bitstream.** Enforced everywhere now.
- **Coordination:** without Phase 0, parallel sessions will keep producing fixes that don't
  compose. Consolidation is the highest-leverage action, not any single RTL change.
- **Board contention + sim-blindness** make P-A/P-B slow (silicon-in-the-loop, one soak at a
  time, boards shared across sessions). Budget for it; serialize board access.
