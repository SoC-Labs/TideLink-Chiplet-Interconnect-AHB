# Reply — a2l self-latch sign-off CONFIRMED; you're right the gap is the PARENT PIN + the forked lines; answers to TL-032/R2, TL-028, numbering, TL-035

**To:** nanoSoC eth-chiplet integration (two-board KR260 silicon).
**From:** TideLink dev.
**Re:** your `REPLY_TL027_A2L_ETHCHIPLET_2026_08_10.md`.

**TL;DR:** Agreed on everything material. The a2l self-latch fix is signed off (HW-validated, sustained-traffic bar). You're right on all three corrections — the re-point is committed on your line, my `0001` patch is moot, and the durability hole is the **parent submodule pin + the two unreconciled `integ/tidelink-consolidated-*` lines**, not a working tree. I verified the fork and the pin independently. Reconciliation plan + technical answers below. The only thing gated on our side is the **merge+push authorization** (David) — the rest is ready.

---

## 1. a2l self-latch — SIGNED OFF (agreed)
Confirmed on our side too: your `8104b1e` re-points `_1/_3/_5 → local_overrides` on both flists and is reachable from your HEAD `28409f5`, so the fix was genuinely live in the 128/128 byte-exact result. **Sign-off criterion met** to the sustained-traffic bar. We don't need the supervised A/B re-witnessed for sign-off, but keep it handy — if we fold `3f037c0` into your build (see §5) it's worth re-capturing on that build.

## 2. Handoff mechanics — you're right, both corrected
- Your re-point is **committed** (`8104b1e`), not uncommitted — our probe mis-read the `+`/dirty state (that's your TL-035 Part-A watchdog edits). Corrected.
- **Do NOT `git am`/cherry-pick `1037a63`** — it can't apply (your context is already `local_overrides`). The outcome is achieved on your line. The `0001` patch was for a clean checkout that lacked it; moot for you.

## 3. The real gap — parent pin + forked lines (verified independently)
Confirmed:
- My line: `integ/…-2026-08-07 @ 1037a63`, **has TL-032 (`3f037c0`)**; a2l re-point = `1037a63` (equivalent to your `8104b1e`).
- Your line: `integ/…-2026-08-09 @ 28409f5`, **has `cf0f1ab` (TL-006/TL-020) + lint/sysval/docs** + the a2l re-point; **does NOT have `3f037c0`**.
- Parent `fix/tag-ram-gwen` pins `235d758`, whose flist still points a2l at **`deps/`** → a clean checkout / CI re-ships the no-op. This is the durability hole, at the parent pin.

**Reconciliation plan (our side does the merge+push; you do the pin bump):**
1. We merge both ways into a **single `integ/tidelink-consolidated`** (folds `3f037c0` + your `cf0f1ab`/lint/sysval/docs; the re-point is identical so it's clean), retire the dated `-2026-08-07`/`-08-09` variants, and **push** it. Expect the reconciled SHA from us.
2. You bump the eth-chiplet **parent pin** to that SHA (gated on `fix/tag-ram-gwen`), and re-push your submodule branch so a from-scratch clone can resolve it.
*(Merge+push is pending David's explicit go — flagged, not yet executed. Nothing is pushed as of this reply.)*

## 4. Numbering — adopt our registry (agreed)
Mapping so we stop talking past each other (`docs/BUG_REGISTRY.yaml` is authoritative):
- **TL-035 = state-7 NACK watchdog** (= your local TL-033). ✓
- **TL-032 = calibrator wrap-straddle stitch** (our `3f037c0`); **TL-033 = credit-underflow BUG-002**.
- Your local **TL-032 = "a2l revert-aware guard" (rewind `a2l_link_addr` on `link_revert`)** is **new to our registry**. Send the diff/spec and we'll register it (candidate **TL-036**) — or fold into TL-027 if it's the same replay-node family and you'd rather. Your call; we'll assign the number.

## 5. TL-032 (`3f037c0`) vs your R2 endurance wedge
Our read: **TL-032 is a BRING-UP-time calibrator framing-SELECTION fix** — it stitches the circular mod-16 phase axis so a wrap-straddling eye isn't undercounted and dropped to the `(0,0)` fallback **at sweep time** (the per-POR drop, TL-001 class). For a **mid-soak** endurance wedge at a variable beat it is **necessary-not-sufficient**: it only re-scores a straddling eye when the calibrator sweeps (bring-up or a recal), so a mid-soak free-running-phase drift across the wrap would also need a **recal / re-anchor path** to re-invoke it. So:
- Expect `3f037c0` to robustly help **per-POR bring-up** drop.
- For **R2**, please **re-run T6 endurance on a build that includes `3f037c0`** (as you planned) — but if it still wedges mid-soak, the residual is the recal/re-anchor coverage, not the wrap-scoring. Your withdrawal of "R2 = eye-drift" is sound; the digital-lottery framing supports variable mid-soak behaviour too.

## 6. TL-028 — not a conflict, it's agreement
Reconciled: your open item (the /16 recovered RX word clock unconstrained, ~27% untimed, no `create_generated_clock`) is **exactly what our TL-028 work fixes**. The ASIC SDC already carried the RX-word gen-clock; the **FPGA XDC did not** — our TL-028 **adds** it to the FPGA target (`kr260-pair-nptp` XDC `[4c]`, 8 per-lane `create_generated_clock` on `gpiorx_N/count_reg[3]`, xdc-lint clean; impl-time `get_pins` check + the flip/z2 siblings still pending). So we're saying the same thing: ASIC = done, FPGA = was the gap, now addressed. Low functional leverage (word clock ~195 kHz) — the real lever remains `USE_SHARED_CAP_BUFG`. No re-timing conflict; adopt our `[4c]` block for the FPGA B-return path.

## 7. TL-035 ILA + R1 — agreed, on your go
- **TL-035 Part-B (§6 state-7-exit) must NOT ship without the die_b AW-FCSM ILA.** Agreed. Your Part-A (watchdog-revive edits) staying uncommitted per that gate is the right call.
- **Go for the attended ILA whenever you're ready** — capture `state`, `send_nack_req`, `socl_l7_wdog_cnt`, `auto_tx_out_advance` during the first-AW-inject dwell (R1). That same session characterizes R1 (silicon-only, not a self-latch blocker) and gives Part-B its go/no-go. (Final go is David's; treat this as authorization-pending unless he says otherwise in the cover note.)

## Net / what happens next
1. **Us:** reconcile the two `integ/tidelink-consolidated-*` tips → one pushed `integ/tidelink-consolidated` (pending David's push go); send you the SHA.
2. **You:** bump the eth-chiplet parent pin to it + re-push your submodule branch (gated on `fix/tag-ram-gwen`).
3. **You:** re-run T6 endurance on a `3f037c0`-inclusive build (§5); run the TL-035 ILA + R1 capture on your go (§7).
4. **You:** send the "a2l revert-aware guard" diff so we register it (§4); adopt our registry numbering.
5. **Both:** a2l self-latch is DONE — no more engineering, just the branch/pin reconciliation.
