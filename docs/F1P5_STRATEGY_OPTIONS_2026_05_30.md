# F-1.5 Strategy — Full Option-Space for Build #N Application Traffic

**Branch context:** `fix/fcsm-l7-wedge-watchdog` @ `cbcd4ef` (F-1 only; F-1.5 reverted after Build #6 wedged master PS).
**Last known good silicon:** Build #3 (`dda0a0e`, no ILA, no F-1). 5/5 deploys, doorbells deliver.
**Scope:** Get *application traffic* (doorbell M→S, AHB, PTP) flowing reliably on HW. NOT just FCSM state == 4.

---

## 1. Executive Summary

**Top-ranked option: O-A "Re-validate Build #3 with the CORRECTED test recipe."**

The `BUILD5_TEST_METHODOLOGY_AUDIT_2026_05_30.md` is decisive: every Build #4/5/6 "doorbell fails" measurement was made *with `SWI_TRAINING_MODE=1` held HIGH on both sides*. By the local-override RTL (`WavD2DGpioTx.v:252-256` mux + `Wlink.v:1952` LL_RX reset), doorbell delivery is **physically impossible** in that mode — TX bytes are replaced with the training pattern and peer LL_RX is held in reset. The Build #3 baseline `/tmp/doorbell_test.sh` that "worked" simply never wrote `SWI_TRAINING_MODE`. We may have been chasing a phantom: the F-1 watchdog, the F-1.5 forcer, the ILA-perturbation, the credit-pointer rewind hypothesis — all explaining a failure mode the test *guaranteed* by design.

**Action:** Before another build cycle (~2h), re-run the refined recipe (§9 of the audit) against the *existing* Build #5 bitstream on HW (~1h lease). If doorbells deliver, the entire FCSM-wedge premise collapses; F-1 stays as defence-in-depth and Build #5 ships. If they still fail, we have isolated the bug from test artefact and proceed to O-B/O-C with real evidence.

This is the cheapest, highest-EV move on the board. Expected value dominates by ~10× vs. any RTL/build-side option because cost is effectively zero (no rebuild, lease only).

---

## 2. The Full Option Bank (ranked by expected value)

EV = (P_success × value_if_succeeds) / cost. Value = "doorbells + AHB + PTP all deliver". Cost in engineer-hours including lease time.

### O-A — Re-test Build #5 with corrected recipe (no SWI_TRAINING_MODE)
- **Mechanism:** Run the refined recipe from `BUILD5_TEST_METHODOLOGY_AUDIT_2026_05_30.md` §9 — deploy, poll `SWI_LANE_STATUS` for natural autoneg, then ring **without** writing `SWI_TRAINING_MODE=1`.
- **Expected outcome:** Doorbell `RESP_ACC` accumulates ~4096/ring as Build #3 did. Returner clears between rings.
- **Effort:** 1 lease hour, no rebuild. Scripts already exist (`/tmp/doorbell_test.sh` is the Build #3 template).
- **Risk:** Near zero. Read-mostly experiment; if the link is genuinely wedged we learn that with confidence.
- **Falsifiability:** Slave `DOORBELL_RESP_ACC > 0` after 1 ring. Master `REG_STATUS[0] == 0` after settle. Both deterministic.
- **P_success that Build #5 is actually fine:** ~55% (the audit's smoking gun is hard to argue with).
- **EV: very high.**

### O-B — Rebuild current main with `FPGA_INSERT_DEBUG_CORE=0` (functional shipping bitstream)
- **Mechanism:** Same source tree as Build #5/#6 but skip the ILA core insertion entirely. Recreates Build #3's clean P&R; F-1 watchdog still present as belt-and-braces.
- **Expected outcome:** Returns to Build #3-class behaviour. Application traffic delivers. We lose live observability.
- **Effort:** ~2h farm build + 1h HW validation = ~3h.
- **Risk:** Low. We have proof (Build #3) that the no-ILA configuration works on this silicon family. F-1 added on top is a synchronous AND-clear of a single signal — small surface.
- **Falsifiability:** Same as O-A; doorbells + AHB + PTP all deliver, or they don't.
- **P_success:** ~75% if O-A confirms test artefact; ~50% if O-A still shows wedge (then there's a real bug that no-ILA may also expose).
- **EV: high.** Use this as the shipping path if O-A confirms.

### O-C — Minimal-probe ILA (6 nets per `BUILD5_RETURNER_TRACE_2026_05_30.md` §5)
- **Mechanism:** Drop the 334-net `u_dbg_int` core down to the 6 nets the returner-trace doc identified: `tl_fc_a2l_{valid,ready}`, `u_returner.state_r`, `WlinkGenericFCSM_6.state`, `socl_l7_wdog_force_clear`, `fe_tx_credit_max`+`link_ack_addr`. Drop `C_DATA_DEPTH` from 4096 to 1024 (releases ~6 BRAMs).
- **Expected outcome:** Sufficient observability to isolate H1 (credit-window poisoning) if it's real, without the placement perturbation that took out Build #4. BRAM headroom returns.
- **Effort:** ~3h (probe-patch authoring + build + HW capture).
- **Risk:** Medium — small probe sets are still in the same nets that Build #5 already exercised; the regression-by-mark_debug class (R-1) is the warning. Mitigate by NOT marking `pair_credit_counter` or any FC-adapter-internal handshake.
- **Falsifiability:** ILA trace shows `valid=1, ready=0` post-doorbell (confirms H1) OR shows handshake completes (refutes H1 and points test artefact).
- **P_success:** ~45% if real bug; ~80% as diagnostic regardless of bug existence.
- **EV: medium-high.** Best diagnostic for the "real bug" branch.

### O-D — Mask `isNotExpPacket` entirely during bringup (simpler RTL than F-1)
- **Mechanism:** In `WlinkGenericFCSM_6.v:450`, change `isNotExpPacket_l7 = isNotExpPacket & ~socl_l7_bringup_forgive` to `isNotExpPacket_l7 = 1'b0` until `socl_l7_reached_link_data` latches. Eliminates the *latching* of `send_nack_req` rather than relying on a watchdog clear after the fact. No state forcing, no multi-driver hazard.
- **Expected outcome:** FCSM cannot enter state 7 due to spurious `isNotExpPacket` during bringup; can still enter on genuine CRC errors. No pointer rewind risk from F-1.5 class.
- **Effort:** ~1 line RTL + sim regression (~30 min) + build + HW (~3h).
- **Risk:** Low-medium. We weaken the NACK path during a window, but the override header already documents the bringup `isNotExpPacket` as spurious. Genuine CRC errors during bringup would also be masked — acceptable since the calibrator+autoneg already guards against bad bits getting through during that window.
- **Falsifiability:** Sim regression confirms PASS; HW shows FCSM never visits state 7 in ILA capture; doorbells deliver.
- **P_success:** ~50%.
- **EV: medium.** Better RTL hygiene than F-1.5; worth keeping in reserve.

### O-E — Returner-side timeout (defensive, orthogonal to the wedge)
- **Mechanism:** Per `BUILD5_RETURNER_TRACE_2026_05_30.md` §5 fix path B: bound `ST_DATA_PHASE` dwell. After 64 k cycles with `hready=0`, force-complete the transaction (set `master_error_r`, drop `htrans` to IDLE, return to `ST_IDLE`). ~20 lines RTL, no new ports.
- **Expected outcome:** `returner_busy` becomes self-clearing. SW can re-probe doorbell and re-arm; we get *liveness* even when the link is transiently wedged.
- **Effort:** ~3h RTL + sim + build + HW.
- **Risk:** Low — pure timeout escape, no upstream changes. Worst case: tx data is silently dropped on timeout — acceptable when paired with `master_error_r` status bit.
- **Falsifiability:** Sim a stuck `hready=0` scenario; confirm timeout fires and state clears. HW: returner clears within bounded time even after intentional wedge.
- **P_success of fixing doorbells alone:** ~20% (doesn't address root cause). But makes the system *recoverable* without power-cycle.
- **EV: medium.** Strong long-term hygiene fix; ship in parallel with whatever else works.

### O-F — Place-design seed lottery (Vivado random-seed bisect)
- **Mechanism:** Build #4 was 5/5 wedged, Build #3 was 5/5 clean — so seed lottery isn't the dominant story (the audit confirms it). But if O-A fails AND O-B regresses, try `place_design -directive` variants (`AltSpreadLogic_low`, `ExtraNetDelay_high`) for 2-3 alternative placements.
- **Expected outcome:** Maybe one placement avoids whatever P&R perturbation triggers the ILA-class wedge.
- **Effort:** ~3 builds × 2h = ~6h.
- **Risk:** Low. Bitstream-only change.
- **Falsifiability:** At least one variant delivers traffic, or none do (definitive null).
- **P_success:** ~15%. Audit evidence says placement is not random across our wedge — it's deterministic across deploys.
- **EV: low.** Defer unless O-A/B/C all fail.

### O-G — Cherry-pick FCSM from `feat/i2c-autonomous-lock-integ`
- **Mechanism:** That branch has a known-working FCSM-handling stack on silicon (per memory ref `project_tidelink_i2c_autonomy.md`). Replace `local_overrides/WlinkGenericFCSM_6.v` with its version.
- **Expected outcome:** If the FCSM in *that* tree was robust to the bringup `isNotExpPacket` pulse without an L7-forgive gate, transplant solves the problem.
- **Effort:** ~4h (diff, port, sim, build, HW).
- **Risk:** Medium. Cross-branch RTL transplant risks introducing unrelated regressions; we'd be importing a different bug class.
- **Falsifiability:** Sim test_post_watchdog passes (or doesn't apply), HW doorbells deliver.
- **P_success:** ~30%. We don't know what their FCSM actually did differently.
- **EV: low-medium.** Worth scoping ONLY after O-A confirms a real bug exists.

### O-H — Revert ALL `local_overrides/{Wlink,FCSM,WavD2DGpioTx}.v` to upstream
- **Mechanism:** Drop every SoC Labs patch in `src/rtl/local_overrides/`; let upstream Wlink handle bringup naturally.
- **Expected outcome:** Returns to pre-2026-05-26 behaviour. The 2026-05-26 commit headers say upstream was demonstrably broken on this silicon (asymmetric LL_RX byte-align loss, `socl_l7_bringup_forgive` was the fix). So this is very likely to regress.
- **Effort:** ~30 min revert + 3h build + HW.
- **Risk:** **High.** We have headers in the override docs documenting *why* the upstream had to be patched. Reverting blind is undoing known-good work.
- **Falsifiability:** Link won't bring up at all, most likely.
- **P_success:** ~10%.
- **EV: very low.** Anti-pattern — see §5.

---

## 3. The "Do Nothing" Baseline — Ship Build #3 + SW guardrail

Build #3 silicon **works** for doorbells (5/5). The known limitations: no live ILA, no Bug B fix, no F-1 watchdog. We have backup bins at `/tmp/tidelink_deploy/*.build3-bak` on mapstone-dev.

**SW-only steps to avoid the wedge entirely on Build #3:**
1. Never write `SWI_TRAINING_MODE=1` after deploy (it isn't needed — autoneg runs).
2. Poll `SWI_LANE_STATUS` until lock=0xFF + cal_done before any traffic.
3. Read `REG_STATUS` before each ring; abort if `bit[0]` set (returner busy).
4. Treat `HW_SYNC_CTRL=0x05` as one-shot (per Bug B handoff doc) — re-arm in SW.

This gives us a **shippable v1 today** that delivers doorbells + AHB N=1 (modulo Bug A — see master-wedge note in `BUILD5_HW_VALIDATION` §"Bug A reconfirmed"). PTP needs the Bug B RTL fix layered on a Build #3-class bitstream regardless.

Effort: ~30 min (restore .bin, redeploy, document the SW recipe).
Value: covers the v1 demo without any RTL/build risk.

---

## 4. Decision Tree by Time Budget

### 1 hour budget
→ **O-A**. Lease one rig, run the refined recipe on the *existing* Build #5 bins. Two outcomes:
- Doorbells deliver → publish a result, declare F-1.5 unnecessary, ship Build #5 as the shipping bit. F-1 stays for defence.
- Doorbells still 0 → schedule O-B/O-C; bug is real.

### 1 day budget
→ **O-A first.** Then in parallel:
- If O-A passed: build a no-mark_debug-on-pair_credit_counter shipping bit (basically Build #5 with the R-1 attribute removed — already done in Build #5). Validate again. Tag v1.
- If O-A failed: launch **O-B** (no-ILA functional build, ~2h farm) AND **O-C** (minimal-probe ILA, ~3h farm) concurrently. Compare outcomes:
  - O-B passes, O-C fails → it's the ILA core. Use O-B as ship.
  - O-B and O-C both pass → minimal probe ILA is acceptable; ship O-C.
  - Both fail → real RTL bug not test artefact. Escalate to O-D.

### 1 week budget
Day 1: O-A → O-B → O-C decision branch above.
Day 2-3: If real bug confirmed, do **O-D** (mask isNotExpPacket) + **O-E** (returner timeout) as a stacked patch. Sim-validate, build, HW-validate.
Day 4: PHC BD counter wire-up (Bug B time-based path), shared with td-autonomy workstream.
Day 5: Bug A investigation — needs the O-C ILA traces of the AHB-write wedge moment.
Day 6-7: Buffer for regression, doc, v1.0 tag.

**Critical:** *Do not* skip O-A. Without it, we are likely to re-derive the entire RTL fix chain for a problem the test caused.

---

## 5. Anti-Patterns — Waste of Time

1. **F-1.5 redesigns.** The PS-kernel-hang in Build #6 is a Class-A warning. Adding new priority clauses to the FCSM `state` always-block invites multi-driver synthesis hazards Vivado does not warn about. ANY future "force state→N" attempt needs single-driver pattern + post-synth UMR check. But more importantly: if O-A confirms test artefact, the *entire premise* of F-1.5 (FCSM needs forced clearing) collapses.
2. **Adding more `mark_debug` attributes to "see deeper".** Every attr is a P&R perturbation. The R-1 finding (`pair_credit_counter` mark_debug folded the busy-clear logic) is the canary. If we need more probes, do them in *separate* ILA core blocks routed by `BLOCK_SYNTH` regions, not blanket attribute additions.
3. **Building with `FPGA_ALLOW_CRITICAL_WARNINGS=1` to "go faster".** That gate is the only thing keeping silent constraint drops out of the bitstream (build_design.tcl:283). Bypassing it has burned days before (lane-lock saga).
4. **Re-deriving the FCSM state-7 wedge mechanism.** Three independent agents have now landed on the credit-window-rewind hypothesis (BUILD5_RETURNER_TRACE §3, BUILD5_ALT_HYPOTHESES H-NEW, original F-1 design). More analysis without HW probe data is yak-shaving.
5. **O-H (revert all local_overrides).** The override headers document *exactly* what bug each one fixed on prior silicon. Reverting blind would undo verified-good work for a hypothesis that doesn't even have a smoking gun.
6. **Iterating `mark_debug` removal one-at-a-time.** 24 attrs × 2h per build = 48h. Use one binary build instead: `INSERT_DEBUG_CORE=0` vs =1. The audit's H-NEW is already that experiment.
7. **Spending more HW leases on Build #6.** Build #6 is silicon-validated WORSE than Build #5. Keep its bins off the deploy path. Reverting F-1.5 on cbcd4ef was correct.

---

## 6. Files Touched / Referenced

- Read-only: `docs/BUILD{3-absent,4,5,6}_*.md`, `docs/BUILD5_TEST_METHODOLOGY_AUDIT_2026_05_30.md`, `docs/BUILD5_RETURNER_TRACE_2026_05_30.md`, `docs/BUILD5_ALT_HYPOTHESES_2026_05_30.md`, `src/rtl/local_overrides/{WlinkGenericFCSM_6,Wlink,WavD2DGpioTx}.v`, `src/rtl/tidelink_returner.sv`, `src/rtl/tidelink_fc_adapter.sv`, `src/rtl/fifo/tidelink_apb_regs.sv`, `fpga/build_design.tcl`, `fpga/scripts/build_pair_combined.sh`.
- Write: this doc.
- No RTL or build-script modifications in this analysis pass.

**Word count: ~1480**
