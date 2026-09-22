# Scope — Synchronized bring-up to catch a BILATERAL anchor window and prove end-to-end delivery (KR260 pair)

**Status:** scoping doc for David. Uncommitted. Written 2026-08-10 immediately after the cand-2 HW session.
**Prereq established this session:** cand-2 (`TRAIN_ENTRY_FALLBACK=1`) autonomously arms the SYNC beacon on
BOTH dies on silicon (`0x2128=0x5E4` tol=5/mask=0xE4, `R8` insert_en=1) — the *digital* dark-beacon root
cause is closed. What remains is a **physical** problem: the pair only ever anchors **one side at a time**,
and cross-die delivery needs **both** dies anchored (the credit loop is bidirectional).

---

## 1. Objective
Reliably reach a state where **both dies have `EPOCH anc=1`** (bilateral reanchor) so the credit loop closes,
then demonstrate **≥12-packet byte-exact cross-die delivery both directions** on a cand-2 build. This proves
the beacon fix carries all the way to data, not just to register state.

## 2. Root cause of the bilateral miss (measured + RTL-grounded)
Two independent residuals, both **orthogonal to cand-2**:

1. **Role-lock skew → word-counter misalignment (the "lottery").**
   `WavD2DGpioRx_v2.count` free-runs mod-16 **from role_lock**; the two dies' word-boundary counters start
   with whatever skew separates their role_lock instants. On silicon this session, sequential POR+deploy put
   role_lock **~1 minute apart** — vastly outside the alignment budget. The RTL skew-bridge is **S_HOLD**
   (`tidelink_phy_align_calibrator.sv`, first die to lock holds `training_mode` for
   `HOLD_CYCLES = 8·128·DWELL_CYCLES = 8·128·64 = 65,536` link-clock cycles ≈ **0.5–1.5 ms**, clock TBC §7).
   A ~1-minute skew is ~10⁴–10⁵× the S_HOLD budget, so only the first-locking die anchors. **Fix = make both
   dies' role_lock land within ~HOLD_CYCLES of each other.**

   **CLOCK CONFIRMED (2026-08-10, static from the KR260 XDC):** the calibrator/S_HOLD counter clocks on
   `phy_link_rx_rx_link_clk_w` = the **/16 recovered RX word clock**. `create_clock -period 320.000
   pad_clk_rx` ⇒ pad_clk_rx = 3.125 MHz ⇒ word clock ≈ **195 kHz**. So `HOLD_CYCLES = 65,536` word cycles ≈
   **336 ms** (not ~1 ms). **This makes the sync EASY**: a plain parallel `fpgautil` launch (fan-out skew
   ~10–50 ms) is ~7–30× *inside* the 336 ms budget — no NTP / shared-timestamp precision needed. The ~1-min
   sequential skew is what breaks (≫336 ms). My earlier concurrent-load attempt failed **only** on die_b's
   sshd not being up post-POR (`Connection refused`), a boot race — NOT on skew.
2. **die_a RX marginal eye.** `MIN_LOCK_DWELLS` was cut 4→2 with the RTL comment *"die_a marginal eye has
   only 2-3 consecutive passing phases."* Even with zero skew, die_a's RX may not set all-4-lane sticky
   `sync_seen` inside one clear-to-clear window. This is a **hardware eye** limit, not timing.

Observed this session: die_b landed `anc=1` 1/4 sequential attempts; die_a landed `anc=1` in 0 valid
attempts. Consistent with (a) skew dominating + (b) die_a being the weaker eye.

## 3. What is already in place (do NOT rebuild these)
- **`USE_SHARED_CAP_BUFG`** (the RX capture-clock hoist — `fpga/docs/KR260_CAPTURE_CLOCK_TREE.md`, *"this is
  the fix"* for the eye) **auto-tracks `USE_CLKBUF=1`** on `kr260-pair-*`, and the cand-2 build has
  `USE_CLKBUF=1'b1`. So the capture-clock lever is **already pulled** in the deployed bitstream.
- **cand-2 beacon arm** — confirmed autonomous on both dies.
- **`SWI_FORCE_RECAL`** (R8[6], W1P) — a firmware recal trigger that re-runs the calibrator **without a POR**.
- **Credit-safe delivery tools** — `kr260_credit_tx.py` (TX 0xA4000000, credit-gated, STALLs instead of
  wedging) + `kr260_data_rx.py` (RX 0xA4010000, strided). These worked this session; reuse as-is.

## 4. Approaches, ranked

### A — Parallel PL load with sshd-barrier (PRIMARY; keeps cand-2 fully autonomous)
Because the S_HOLD budget is **~336 ms** (§2), the sync is easy — a plain **parallel** `fpgautil -b … -f Full`
on both boards (fan-out skew ~10–50 ms ≪ 336 ms) puts nego + role_lock inside budget → S_HOLD bridges → both
anchor. **No NTP / shared-timestamp needed.** The one thing that MUST be fixed vs the failed attempt: **wait
for BOTH boards' sshd to answer after POR before launching the loads** (the earlier concurrent run died on
die_b `Connection refused`, a boot race, not skew).
- Sequence: POR both → poll until `ssh true` succeeds on BOTH → launch both `fpgautil`(+AFI) in parallel
  (background) → wait → probe bilateral `anc`.
- Re-roll: role_lock is **W1S / POR-only clear**, so each attempt = POR both → parallel load (~2–3 min).
  With the skew now inside budget, **if skew was the only blocker, bilateral should land at ~1** (vs the
  sequential ~1/36). If die_a still won't anchor, the residual is die_a's **eye**, not timing → go to C.
- Keeps autoneg/cand-2 active (role_lock via nego force_lock, not a host poke) → still an autonomous result.

### B — Synchronized recal (FAST probe; may or may not re-roll the skew)
Poke `SWI_FORCE_RECAL` (R8[6]) on both dies at a shared `T`. Re-runs the calibrator in ~ms (no POR).
- **Caveat:** recal re-rolls the **eye/tap search** but the word-counter skew is tied to **role_lock**, which
  recal does NOT reset. So B helps only if die_a is **eye-limited at fixed skew** (a recal finds a better tap
  in the same alignment). Cheap to try between A's POR cycles; low cost, uncertain yield. Use as a
  fast inner-loop after a synchronized load.

### C — Per-lane RX IDELAY tuning on die_a (attack the marginal eye directly)
If A gives tight skew but die_a still won't anchor, nudge die_a's 4 active-lane (`{2,5,6,7}`) RX IDELAY taps
to re-center its eye (the calibrator does this, but die_a's 2-3-phase window may need a manual bias / wider
`MIN_LOCK_DWELLS=1` build, or a fixed tap offset). This is a targeted eye fix, not a timing fix.

### D — Fallback / accept
If neither A+B nor C lands bilateral on die_a's eye, the honest position stands: **cand-2 closes the digital
bug; die_a's RX eye is a hardware ceiling on this board.** Options then: (i) swap to a different KR260 pair
(eye is board/lane specific), (ii) the `kr260-pair-onchip` single-board vehicle (no ribbon, cleaner eye —
the memory's lottery-free path), or (iii) ship the logical fix and document the physical residual.

## 5. Recommended staged plan
1. ~~Confirm the S_HOLD real-time budget~~ **DONE (§2/§7):** ≈336 ms → parallel load suffices, no NTP.
2. **`kr260_sync_bringup.sh` — BUILT (2026-08-10, `pynq_host/scripts/`, syntax-checked, not yet run).**
   POR→wait-both-sshd→PARALLEL `fpgautil`+AFI→autonomous converge→probe bilateral `anc`→credit-safe delivery
   BOTH directions, looping `ATTEMPTS` times. Just needs a leased pair to run:
   `source ./set_env.sh; KR260_PASSWORD=<board-password> ATTEMPTS=6 bash pynq_host/scripts/kr260_sync_bringup.sh`.
3. **Run A** for ~5 POR cycles; record per-die `anc` land-rate with tight skew vs the sequential baseline
   (die_b 1/4, die_a 0/4). If die_a's rate rises → skew was the blocker.
4. **Interleave B** (synchronized recal) as a fast inner loop between A's POR cycles.
5. On the **first bilateral window**, run the credit-safe delivery test (`kr260_credit_tx.py 0xDA7A0001 12`
   on die_a → `kr260_data_rx.py check …` on die_b), then reverse direction. This is the milestone.
6. If die_a still never anchors → **C** (IDELAY / `MIN_LOCK_DWELLS=1` micro-rebuild) or **D** (onchip vehicle
   / different pair).

## 6. Success criteria
- Bilateral `anc=1` observed on both dies in the same window.
- `kr260_data_rx.py check` reports **12/12 byte-exact, in order**, die_a→die_b.
- Reverse (die_b→die_a) also 12/12.
- Recorded: bitstream md5s (cand-2), the per-die `anc` land-rate under synchronized vs sequential load, and
  the raw register dumps — for the certification archive.

## 7. Risks & open items
- **HOLD_CYCLES window — RESOLVED:** calibrator clocks on the /16 RX word clock ≈ 195 kHz (pad_clk_rx 320 ns
  ÷16), so `HOLD_CYCLES` ≈ **336 ms**. A parallel `fpgautil` (~10–50 ms skew) is comfortably inside → sync is
  NOT the hard part. (No NTP / shared-timestamp needed — that section of the original plan is over-engineered
  and dropped.)
- **die_a marginal eye is now the PRIMARY suspect** — RTL literally flags it (`MIN_LOCK_DWELLS` 4→2, *"die_a
  marginal eye has only 2-3 consecutive passing phases"*). With skew removed by A, if die_a still won't
  anchor, this is the ceiling → C (IDELAY / `MIN_LOCK_DWELLS=1` micro-rebuild) or D (different pair / onchip).
- **role_lock is POR-only clear** — every skew re-roll costs a ~2-min POR; keep the inner loop (B) for speed.
- **Board contention** — this needs the kr260 pair leased; coordinate (the pair was contended from
  mapstone-dev this session).
- **Tooling gotcha (logged):** after `kpor`, wait for BOTH boards' sshd before any deploy (a concurrent
  deploy raced die_b's boot this session → `Connection refused`).

## 8. Effort
- Tooling (`kr260_sync_bringup.sh` + clock confirm): ~0.5 day.
- Run A/B campaign + delivery test: ~0.5 day of board time (POR-cycle bound).
- Contingency C (IDELAY tune or `MIN_LOCK_DWELLS=1` micro-rebuild + re-run): +0.5–1 day.
- **Total ~1–2 days**, gated on a leased kr260 pair. cand-2 itself needs nothing further — this is purely the
  physical-convergence demonstration.

## 9. One-line recommendation
Build the **shared-`T` synchronized loader (A)** and measure die_a's `anc` land-rate under tight skew; that
single experiment separates "skew-limited" (A fixes it → delivery) from "die_a-eye-limited" (needs C or a
different vehicle). Everything else (beacon, capture-clock, delivery tooling) is already in hand.
