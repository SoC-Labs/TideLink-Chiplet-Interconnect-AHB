# WAIVER — TL-024: FIX 2 (autonomous lock threshold 5→6) regresses masked/staggered autonomous bring-up

**Status:** RATIFIED (David, 2026-08-08) — keep threshold 6, sentinel the regression.
**Class:** known-live defect under waiver (same contract as F14-B / TL-029).
**Netlist impact:** none — this waiver is Makefile/test-harness + docs only; the RTL and the HW-proven bitstream are unchanged.

## What the defect is

FIX 2 relaxed the autonomous per-lane Hamming lock threshold 5→6
(`src/rtl/local_overrides/axi_chiplet_controller.sv:3961`,
`lane_lock_thresh_eff = nego_en ? {8{3'd6}} : lane_lock_thresh_i`). It is the ~10×
KR260 peer-write soak lever (TL-001/TL-009): threshold 6 lets a marginally-over-
threshold lane accumulate lock-score so a real eye-centre framing is found instead
of the (0,0) framing lottery.

At threshold 6, two blocking autonomous sim suites regress — the link never comes up:
- `v2_mask_hs_bilateral` (masked bilateral bring-up)
- `t33_arm_stagger_episode_bind` (staggered/asymmetric episode bind)

Both fail identically: the autoneg FSM cycles `NEGO_DONE_PRE→TRAIN_ENTER→TRAIN_RUN→
TRAIN_POLL_PEER→TRAIN_FAIL→…` (state 11→12→13→14→17→11) and FCSM stays at 1 (never
reaches LINK_IDLE=4).

## Why it can't be fixed with a "path-aware" threshold (root-caused 2026-08-08)

The 5→6 knob has **exactly one** functional consumer: the binary `lane_locked`
(`tidelink_lane_checker_single.sv`: `is_match ≤ lock_thresh` → LOCK_CONSEC=8 →
`locked_o`), which feeds only the autoneg `ST_TRAIN_POLL_PEER` bilateral rendezvous
(`local_lock_qual_w == 8'hFF` on both dies, `tidelink_autoneg.sv:1432-1437`). The
calibrator's framing/eye-centre selection uses a **separate, threshold-independent**
distance metric (`LOCK_DIST_THRESHOLD=3`) — so there is no distinct "data-framing
lock" to relax. The benefit (a marginal-*good* lane locks at 6 on real HW → training
exits → soak runs) and the harm (a *spurious* lane locks at 6 in masked/staggered
sim → the bilateral rendezvous never closes → TRAIN_FAIL) are the **same** decision,
in the **same** state, separated only by an *unobservable* scenario. No runtime
signal the RTL carries distinguishes them; path-aware is not viable.

## The disposition (ratified)

Keep threshold 6 (preserve the ~10× soak and the HW-proven bitstream), and treat the
two masked/staggered bring-up failures as tolerated known-defects:
- **`v2_mask_hs_bilateral` → XFAIL sentinel `v2_mask_hs_regress`** (~600 s): runs each
  gate, tolerated only while the failure signature is the documented TRAIN_FAIL /
  FCSM-never-4. If it starts passing (defect gone) or fails differently → XCHG →
  investigate.
- **`t33_arm_stagger_episode_bind` → tracked-standalone**: removed from the per-run
  blocking gate because its 10M-cycle livelock budget makes it a ~3.5 h run,
  unsuitable for a per-commit gate. Same root cause as `v2_mask_hs_regress` above,
  which gates the class. Run standalone (`make sim_gate_t33`) in nightly/full mode to
  track. A bounded reproduce (budget-override knob) is a follow-up.

**This documents a REAL regression — it does not hide a test artifact.** Autonomous
masked/staggered bring-up is genuinely dead in sim at threshold 6.

## The alternative (if the autonomous masked/staggered bring-up must work)

Revert `:3961` 6→5 (netlist-affecting → David signs; also update
`test_v2_autonomous_sync_detect.py` `AUTO_LOCK_THRESH` 6→5). This restores all
autonomous sim bring-ups but **loses the ~10× peer-write soak** and re-arms the
marginal-eye training-exit failure on HW — pushing the weight onto the physical
TL-009 workstream (P-B-lottery BUFG hoist / re-pin die_b SRCC / widen the a2l window).
Reverting would also let the `xfail_epoch_shipping_corrector` XCHG (TL-030) be
re-checked to localize it to FIX 2 vs FIX 1.
