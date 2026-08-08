# TideLink — Consolidation + Autonomous Sign-off Roadmap (2026-08-07)

**Owner/approver:** David Mapstone · **Author:** autonomous campaign (Claude Opus 4.8)
**Single source of truth for bug state:** [`docs/BUG_REGISTRY.yaml`](BUG_REGISTRY.yaml) (TL-001..TL-017)

This roadmap does two things: (1) records the branch **consolidation** just performed, and
(2) lays out an ordered, mostly-autonomous path to **sign-off** for every open item —
marking exactly which steps I can execute unsupervised (sim-only, no HW, no netlist decision)
versus which are David-gated decisions.

---

## 0. Consolidation result — ONE branch

**`integ/tidelink-consolidated-2026-08-07` @ `ecef57c`** (pushed to origin — see §7 status).

Topology proved by hash (not by branch name — the branch names diverged across two clones):

```
main 18491ef  ⊂  integ/axirec-on-chiplet 1107151  ⊂  tl001-calibrator 2c249ec  +  docs graft ecef57c
              (recovery / ECC / PTP-RO / CI fixes)   (FIX1, 0x21F8 obs, FIX D, FIX 2)   (registry + summary)
```

- `2c249ec` is a **strict superset** of the integ line, which is a strict superset of `main` — a
  single linear history, **no divergence to merge**. Consolidation = graft the doc-only branch on top.
- Tapeout-critical fixes **confirmed present** on the line by signature (not just branch name):
  `cb33c9f` isolated-write ✔ · `TXGEN_PRESENT=1'b0` in ASIC dft_wrapper (P1 intent) ✔ ·
  `SELF_ARM_TRAIN_EN` I1 silicon fix ✔.
- The stale local `integ/axirec-on-chiplet` copies (`63222b6`, `c6cc6eb`) are **behind** origin's
  authoritative `1107151` — ignore them; origin is truth.
- **Gate status: NOT gate-green — the full `make sim_gate` finished with 14 blocking FAILs (38 PASS)** plus
  `xfail_epoch_shipping_corrector`=**XCHG** ("behaviour changed — investigate"). This is far broader than the
  single t31 regression first seen: **the calibrator/obs work on `2c249ec` (which the eth-chiplet already pins)
  broke a whole swath of autonomous suites, uncaught because the HW-only campaign never re-ran sim_gate.**
  The 14 sort into three families (see **TL-024**):
  - **FIX 1 centering-on** (`min_lock_dwells 0→1`): `t31_autonomous_training_exit`, `t33_arm_stagger_episode_bind`
    (ran **3.5 h** then failed — a hang), `retire_en_plumb` — all "swi_training_mode_r never engaged." **Bisected**:
    `1107151`=PASS, `e5bd29c`=FAIL.
  - **FIX 2 threshold 5→6**: `v2_autonomous_sync_detect` asserts the autonomous lock threshold == 5 and gets 6
    (literally FIX 2); plus the `lane_locked=0x00` family `v2_pair_data` / `epoch_silicon` / `v2_reduced_lane` /
    `v2_mask_hs_bilateral`.
  - **obs work / flist**: `asic_v1_elab` / `asic_v2_elab` / `dft_wrapper_elab` fail to elaborate —
    `tidelink_winscan_obs` not in the ASIC flist (**TL-020**); `tc_pair_smoke` / `tc_pair_election_datamode`
    undefined-port. `epoch_anchor_plumb` also fails.
  **Base run on `1107151` DONE — the split is confirmed:**
  - **~9 NEW** (calibrator/obs work; PASS on `1107151`, confirmed for `v2_pair_data` PASS=3 and
    `v2_autonomous_sync_detect` PASS=4): the FIX 1 training suites + FIX 2 threshold + lane-lock family.
  - **~5 PRE-EXISTING** (FAIL on `1107151` too): `asic_v1/v2_elab` + `dft_wrapper_elab` (TL-020) + `tc_pair_*`.
  - **🔴 Meta-finding:** the **"integ line gate-green / freeze 46-blocking-0-FAIL" claim was FALSE** — `1107151`
    (the eth-chiplet's pin) already carries ≥5 blocking FAILs. The classic verification-audit trap (`imp/sim_gate`
    green = a *different* branch's run / scored-but-never-invoked). So there are **two** problems: reconcile the
    NEW calibrator regressions, **and** the baseline was never really gated.

  **Bottom line: `2c249ec` / this branch is the correct union but is NOT gate-clean — the calibrator "10× soak"
  win added ~9 sim regressions, on top of ~5 pre-existing that a never-run gate had masked. Both need reconciling
  before any sign-off.**

---

## 1. Branch retirement — collapse the sprawl (David-gated: destructive)

25 local branches + 15 worktrees. Classified by containment in the consolidated tip:

**Fully CONTAINED → safe to archive-tag + delete (recoverable, they add nothing):**
`analysis/link-survey-2026-08-01`, `confirm/i1-fix-throughput-2026-07-31`,
`experiment/throughput-overnight-2026-07-31`, `feat/txgen-v1-integration`,
`fix/axi-datanode-recovery`, `fix/z2-drop-park-hook`, `integ/freeze-2026-07-31`,
`integ/i1-fix-2026-07-31`, `integ/z2-override-verify-2026-07-31`, `wip/axirec-test-repoint`, `main`(ancestor).

**UNIQUE but SUPERSEDED (fix already on the line via a different commit; keep only if you want the history):**
`fix/txgen-present-asic-tieoff` (P1 tie-off already on line), `fix/i1-selfarm-rolelock`,
`fix/tidelink-isolated-write-dataloss` (cb33c9f on line), `docs/bug-registry-2026-08-07` (content grafted),
`integ/gate-plan-2026-07-30`, `wip/axirec-header-ecc-probe`, the two `worktree-agent-*` branches.

**PRESERVE — do NOT touch:** `fix/v2-sync-clock-gate` (concurrent session's live WIP),
plus any I1-regression test branch you still want as a standalone reproduce
(`test/i1-fixe-training-release`, `test/i1-selfarm-regression`, `feat/unit-regression-from-ethchiplet` —
their *tests* are worth confirming-present on the line before deletion; see §3a).

*Recommendation:* I can produce an archive-tag-then-delete script (tags `archive/<branch>` for every
retired branch so nothing is lost, then removes clean merged worktrees). **Not executed** — branch/worktree
deletion is destructive and some worktrees belong to the concurrent session. Say the word and I'll stage it.

---

## 2. Sign-off queue — 7 fixes at candidate sign-off (need your approval, **no work left**)

All reached sim_proven / hw_proven with evidence on the consolidated line. Set `signoff.approved`
in the registry to accept:

| Bug | What | State | Evidence |
|-----|------|-------|----------|
| TL-002 | `wr_hold_r` early-HREADYOUT (standalone-IP) | sim_proven | `e28c898`, reproduce pre/post |
| TL-003 | Fix K — XHB500 hazard-list BID mux | hw_proven | `9dfe1da`, silicon #3→#6 |
| TL-004 | F-1 illegal-AHB ERROR → read-only | sim_proven+gated | `41c4107`, gaps_backstop |
| TL-005 | F-2 backstop synth-B DRAIN | hw_proven+gated | `9b4c40b`+`e827199`, survives errinject B |
| TL-006 | W-byte-0 header-ECC restore | sim_proven+gated | `1aaed00`+`63222b6`, gaps_ecc 6/6 |
| TL-007 | synth-B OKAY (not SLVERR) | hw_proven | `e827199` |
| TL-008 | txgen ownership-mux hijack | sim_proven+gated | `383927e` |

---

## 3. Autonomous work items — I can do these unsupervised (sim-only, no HW, no netlist decision)

### 3a. Coverage gaps (close the sign-off holes)
- **TL-001 FIX 1 permanent gated reproduce test** — plumb the calibrator local-override into a tb
  with a `force_recal_i` port so the give-up re-arm invariant is regression-locked (today the deps
  mirror reverts, so it isn't gated). Sim-only.
- **Confirm-present sweep** — verify the I1 FIX-E / SELF_ARM / unit-regression **tests** on the
  branches in §1 are actually wired into `sim_gate` on the consolidated line before those branches are
  retired; wire any that are missing. Sim-only.

### 3b. A2L-CDC handover — *instrument first, do NOT port the fix yet* (agent-evaluated)
The `HANDOVER_A2L_CDC_PORT_WEDGE_FIX` doc is **mechanically accurate but its causal claim is refuted**
by the module's own silicon record (2-slot mailbox can't tear; the real failure is bring-up reset-skew,
not the 10–20-write steady-state wedge; **this exact fix family was refuted on silicon 5×**; it is immune
to the Hamming lever that moved the needle 10×). Verdict: *plausible, not proven — not the TL-009 root cause.*
- **AUTONOMOUS, zero-risk, do this:** port `_13`'s read-only obs taps (`obs_a2l_full`, `obs_a2l_synced_ack`,
  `obs_a2l_wptr/rptr`) onto the **B-channel** data-plane a2l node and surface at APB. This is the
  **decisive discriminating instrument** the campaign never built: on a wedged HW run it resolves
  "die_b never sent B (CDC self-latch)" vs "die_b sent B, die_a RX dropped it (physical eye)" — which
  `0x21F8` alone cannot. Follows the standing "verify the instrument before theorizing about the DUT" rule.
- **AUTONOMOUS sim:** extend `cocotb/tidelink_a2l_replay_cdc/` (today targets `_13` only) to also cover
  `_1` (4-bit/depth-8) and `_3` (6-bit/depth-32) reset-skew false-full A/B. Note in any sign-off that this
  proves the **reset-skew** case only — "idle single-clock sim never tears; silicon is the verifier."
- **NEW latent robustness gap → propose TL-018:** the data-plane a2l replay nodes `_1/_3/_5` are pristine
  (unfixed) `deps/` copies in **both** shipping flists (`tidelink_fpga_v2.flist:259/270/272`,
  `tidelink_top_full_asic_v2.flist:246/257/259`), while `_12/_13` are the fixed overrides. Hardening them
  (copy → override, `w_inc=1'b1` + window guard **+ the addr-sync reset-skew gate the doc omits**) is a real,
  bounded improvement — but gated on the instrument result above, and the doc's flist target is the **V1**
  file by mistake (real target is `tidelink_fpga_v2.flist`).

### 3c. ASIC-line RTL gaps — agent-verified; the shipping ASIC flist lags the FPGA flist
The `HANDOVER_ASIC_LINE_RTL_GAPS` doc is **substantially correct** (every core claim verified at file:line).
The theme: **fixes proven on the FPGA-V2 flist were never re-pointed into the ASIC-V2 flist**, so the
tapeout netlist silently ships the *unfixed* deps modules while the RTL tree contains the fix — grepping the
tree finds the fix and looks done.

**🔴 CRITICAL / reopens TL-006 — header ECC is BYPASSED in the tapeout netlist.**
`tidelink_top_full_asic_v2.flist:233` pulls `deps/…/WlinkEccSyndrome.v` = the 2026-05-05 blanket bypass
(`corrupted=0; corrected=0`), not the `src/rtl/local_overrides/` copy with the `_T` clean-syndrome fix.
Commit `1aaed00` re-pointed **only** `tidelink_fpga_v2.flist` despite its "flists re-pointed" (plural) message.
**The registry's TL-006 "ACTIVE in shipping ASIC" is FALSE** — corrected in [`BUG_REGISTRY.yaml`](BUG_REGISTRY.yaml).

**Tier-1 autonomous (mechanical flist re-point, sim-verifiable via existing `gaps_ecc`, no HW):**
1. **ECC re-point** — ASIC-V2 flist `:233` deps→`local_overrides/WlinkEccSyndrome.v`. One line. Highest
   severity × trivial. *Caveat:* netlist-affecting on the tapeout trunk ⇒ implement + **sim-prove** autonomously,
   but **David signs to land** (registry `signoff_policy`), and pair with a **combined-config sim** (ECC-on
   **together with** the ASIC's CRC-on + FCSM-deps settings — that combination has never been co-simulated).
2. **`gaps_ecc` gate port** — the eth-chiplet `Makefile` `sim_gate_axi_datanode_gaps` runs only
   `gaps_nodes && gaps_backstop`; the wiring commit `63222b6` is object-**absent** from the eth-chiplet submodule.
   Port it so the ECC re-point is regression-locked. (Also: the calibrator cocotb Makefile compiles the *deps
   non-v2* file, so **FIX 1 is untested by any suite** — ties to §3a.)
3. **Flist hygiene** — dedup `tidelink_phy_sync_detect.sv` (listed twice, ASIC-V2 `:190` & `:197`); add
   `tidelink_winscan_obs.sv`+`tidelink_fcemit_obs.sv` to the bare ASIC flist (silicon gets them via the parent
   `nanosoc_eth_chiplet_asic.flist:81-82`; the bare flist won't elaborate without them).

**New registry entries (added as stubs):**
- **TL-018** (medium, decision) — ASIC FCSM CRC **resets ON** (`deps` FCSM `:636`=`1'h0`→CRC-on) while FPGA
  resets OFF (`local :713`=`1'h1`); combination never co-run. SW-recoverable via bit[16].
- **TL-019** (high, decision) — ASIC flist pins AXI-node **FCSM 0-4 to `deps`** (0 `socl_` recovery hooks vs
  66 in `local_overrides`); the 07-31 "hold pending I1 silicon ILA" basis expired when I1 was resolved. Real
  counter-argument: `local` adds a novel state-2 min-CRACK-emit blocking gate that stalled bring-up — re-decide.
- **TL-020** (low) — flist landmine: `wlink_wlink_ptp_tl_a2l_48x4` instantiated (`WavFIFO_23.v:103`, in both v2
  flists) with **no module definition anywhere**; dormant only because the PTP FC node is off (couples TL-010).
- **TL-021** (medium/high, bring-up) — first-silicon debuggability: APB-hit admits only regions 4/8/C (D/F
  incl. the `0x21F8` witness unreachable from I2C); `i2c_slv_reset` holds the master die's inbound door in reset;
  `ext_stall_err_q` sticky not APB-mapped.
- **TL-022** (medium, ASIC-only) — D2D RX-FIFO `rf_16k` macro never functionally simulated with random init;
  interacts with the documented phantom-pop guard's uncovered second case.
- **TL-023** (fyi/low, ASIC-only) — mailbox slot-select from **async `rptr`** (`WavMultibitSync_18.v`) → ICG
  runt-pulse hazard; gate-level claim needs the pnr netlist (unverified in sim).

**Decisions for David (netlist/tapeout, not autonomous):** TL-019 FCSM re-point (with I1-resolved in hand),
TL-018 CRC reset value, TL-023 mailbox sync (verify pnr first), and the landmine/trace-buffer coupling to
TL-010/011.

---

## 4. Tapeout risks — workstreams (need decisions / HW)

- **TL-010 F13 PTP** — RTL mailbox-RO bug fixed+gated (`a0a224c`) on the line; **two-board PTP convergence
  never proven on HW** + PHC hop broken. Autonomous part: land+gate is already on the line. Remaining:
  two-board convergence run (HW) + PHC hop (separate subsystem).
- **TL-011 F19 PHY BIST** — BIST RTL exists but wired into nothing (0 hits in sim_gate/hwtest). Most
  under-mitigated tapeout item. Needs a DFT/BIST harness + first-silicon go/no-go metric. Partly autonomous
  (wire the existing core into a sim_gate PRBS-margin hook); the go/no-go metric is a decision.

---

## 5. TL-009 physical residual — the one genuinely-open technical blocker

Cross-die **write** path works + soaks 10× longer (FIX 2). Residual pinned to the **B-return** direction.
Two live theories, now with a decisive experiment queued (§3b instrument): **physical B-return eye asymmetry**
(registry verdict, best-supported: Hamming lever helped, sibling CDC fix already deployed yet wedge persists)
vs **data-plane a2l CDC self-latch** (handover doc, refuted-family). **Run the instrument (§3b) before any
physical work.** If physical: BUFG hoist port (`USE_SHARED_CAP_BUFG=1`, never `USE_CAP_CLKBUF`) / re-pin die_b
SRCC / accept + increase a2l window depth or Wlink retransmit persistence. All physical/decision, not autonomous RTL.

---

## 6. Decisions for David (not autonomous)

1. **TL-015 — fast-forward `main`.** `main 18491ef` is a clean ancestor of the consolidated line (FF, no
   merge, no rebase — the `b98b944` rebase incident does not recur). Ranges ready. *Note:* an FF all the way
   to `ecef57c` puts the **unsigned** TL-001 calibrator netlist changes on `main`; if you want `main` to carry
   only signed fixes, FF to `1107151` (integ line) and keep the calibrator work on the integ branch until signed.
2. **Branch/worktree retirement** (§1) — approve the archive-tag-then-delete script.
3. **TL-009 physical direction** (§5) — after the §3b instrument result.
4. **TL-013/014** — retire the V1 flist + drop the duplicate `gpio-phy` submodule (coupled).
5. **TL-011 go/no-go metric** — define the first-silicon PHY-BIST pass criterion.

---

## 7. Execution order (what I do next, unsupervised)

1. ⏳ **Gate-verify** the consolidated tip (`make sim_gate`).  *(status: RUNNING — **t31 regression found**, causation
   run on `1107151` in progress; see §0. This is a genuine find, not a blocker to consolidation — the branch is
   still the correct union, but it is **not** gate-green until t31 is root-caused and fixed or the calibrator
   change is reverted/gated.)*
2. ⏳ **Push** `integ/tidelink-consolidated-2026-08-07` to origin. *(status: will push with **honest status** —
   the consolidated union is the right handback artifact regardless; the t31 finding is documented here, not hidden.)*
3. Fold ASIC-line-gaps agent findings into §3c + register any new TL-0xx.
4. **§3b instrument port** (B-channel a2l obs + APB) — the decisive TL-009 experiment, sim-built.
5. **§3a** FIX 1 gated reproduce test + confirm-present sweep.
6. **§3c** mechanical flist re-points (autonomous ones only).
7. Hand back: branch + registry + this roadmap; enumerate the David-gated decisions (§6).

*Gate/push status and per-item progress are updated in place as work lands.*
