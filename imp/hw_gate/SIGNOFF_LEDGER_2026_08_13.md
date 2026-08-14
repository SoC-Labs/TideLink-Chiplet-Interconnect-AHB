# TideLink hardware sign-off ledger — 2026-08-13

**Scope:** `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink`, branch
`integ/tidelink-consolidated-2026-08-07`, tip `d317c98242f9f688085d28b3e00c8c8debf79fbf`
(working tree **dirty**: 15 modified tracked files + 5 untracked).
**Registry sources:** `docs/BUG_REGISTRY.yaml` (TL-001..TL-035, committed) and
`docs/BUG_REGISTRY_ADDITIONS_2026_08_13.yaml` (TL-036..TL-042, **UNTRACKED** — treated
throughout as *proposed*, not landed).
**Read-only analysis.** Nothing was committed, built, deployed, or modified outside this file.

---

## 0. How to read this

Validation level, strictly applied:

| Level | Bar |
|---|---|
| **HW-VALIDATED** | A machine-generated hardware artefact exists, with build provenance, that **would have FAILED if the bug were present**. Cited by file:line. Only this counts as closed. |
| **HW-ATTEMPTED** | Hardware ran, but the result is void, ambiguous, confounded, or measures something other than the defect. |
| **SIM-ONLY** | Sim proof exists (ideally a non-vacuity A/B); no qualifying hardware. |
| **CLAIMED** | Asserted as fixed/proven somewhere, with no evidence locatable on disk. |
| **OPEN** | Not fixed. |
| **N/A** | Build/process/hygiene item with no hardware-observable behaviour. Structural verification given instead. |

Four rules were applied without exception, because this project has been burned by each:

1. **A gate suite passing is SIM evidence, never hardware evidence.**
2. **An "all clean" reading from an instrument that cannot see the failure is not evidence.**
   Region F `OBS_AXI_NODES` (0x21E0) `0xad800000` is uninformative — see §5.
3. **A run where the link never reached fcsm=4 tests nothing** about the data plane
   (`TL042_RUN1_VOID_2026_08_13.md:5`).
4. **A fix that passed sim and was then rejected on hardware is OPEN, not fixed**
   (`TL042_HW_RESULT_REJECTED_2026_08_13.md:6-8`).

A fifth was added during this audit: **a fix commit that does not exist, or does not touch the
files it claims, is not evidence.** One cited SHA (`2c32c2b`, TL-009) does not resolve in this
repo at all.

---

## 1. Headline counts

| Level | Count | IDs |
|---|---:|---|
| **HW-VALIDATED** | **0** | — |
| **HW-ATTEMPTED** | **3** | TL-006, TL-035, TL-042 |
| **SIM-ONLY** | **13** | TL-002, TL-003, TL-004, TL-005, TL-008, TL-010, TL-020, TL-022, TL-024, TL-026, TL-027, TL-032, TL-041 *(TL-041 counted here for its fix; its process/audit-trail risk is separately OPEN)* |
| **CLAIMED** | **1** | TL-007 |
| **OPEN** | **20** | TL-001, TL-009, TL-011, TL-014, TL-018, TL-019, TL-021, TL-023, TL-025, TL-028, TL-029, TL-030, TL-031, TL-033, TL-034, TL-036, TL-037, TL-038, TL-039, TL-040 |
| **N/A (build/process)** | **5** | TL-012, TL-013, TL-015, TL-016, TL-017 |

*(13 + 3 + 1 + 5 + 20 = 42 — every registry id is assigned a level; none is UNKNOWN.)*

**The headline has not moved since 2026-08-10: still 0 of 42 bugs closed end-to-end.**

What *has* changed is that `imp/hw_gate/` now exists and contains **369 files of real,
provenance-pinned silicon evidence from 2026-08-13** (16 harness runs, 3 ILA captures,
md5-pinned bitstreams, pre-registered predictions, and — unusually and creditably — explicit
VOID and REJECTED records). That evidence is genuine and valuable. It just does not happen to
**close** anything: it re-opened more than it closed.

Specifically, the 08-13 campaign produced:
- **2 retractions** of previously-asserted findings (the TL-035 "signature conversion";
  the "lost B on the return path" thesis for the `ini_aw` subset);
- **1 fix rejected on hardware after passing sim** (TL-042 candidate);
- **1 fix shown present-but-ineffective** (TL-035);
- **1 mechanism positively measured for the first time** (TL-042 instance 2, §6);
- **0 bugs promoted to closed.**

---

## 2. The ledger

Severity and registry status are quoted from the registry as-found. **LEVEL** is assigned here.

| ID | Title (abbrev.) | Sev | Registry status | **LEVEL** | Basis |
|---|---|---|---|---|---|
| TL-001 | Peer-write DATA-drop (die_b reads 0) | rank1_critical | root_caused | **OPEN** | **Reproduced on HW 2026-08-13, 5 of 15 bring-ups.** `repeats/r2_baseline/.../06b_regionf_gate.log:23-24` (`4/16 folded words byte-exact … RESULT: FAIL`), `06e_localmem_pre.log:1` (`VERIFY 0/16 … got0x00000000`). See §7 for a new predictor. |
| TL-002 | Early HREADYOUT on peer write (`wr_hold_r`) | high | sim_proven | **SIM-ONLY** | `imp/sim_gate/axi_datanode_recovery.log:5922` `test_write_hold_hreadyout_waits_for_w_beat passed`. **Caveat:** the *data-landing* test is `@cocotb.test(skip=True)` (`cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_writehold.py:203`) — the gate proves the hreadyout **ordering** invariant, not that the payload lands. HW contra-evidence in §6. |
| TL-003 | Fix K — XHB500 hazard-list BID mux | high | **hw_proven** | **SIM-ONLY** | Genuine non-vacuous sim pair: `axi_datanode_recovery.log` `test_axi_bid_corrupt_wedges_no_fix PASS` + `test_axi_bid_corrupt_recovers_fixk PASS`. **No HW log exists** — see §8. |
| TL-004 | F-1 — I5 backstop drives illegal AHB ERROR | high | sim_proven | **SIM-ONLY** | `imp/sim_gate/axi_datanode_gaps.status` `PASS 417s`; `gaps_backstop::test_i5_error_is_ahb_legal` PASS. Registry is honest (`hw_tested: false`). |
| TL-005 | F-2 — I5 backstop never restores (synth-B) | high | **hw_proven** | **SIM-ONLY** | Sim solid: `gaps_backstop` 6/6 + `gaps_nodes::test_axi_b_error_wedges_no_fix` (non-vacuity). HW claim rests on a **narrative doc, not a log** (`docs/AXI_DATANODE_OKAY_FIX_HWPROOF_2026_08_02.md:44-48`) and on **one** inject class. §8, §9. |
| TL-006 | W-byte-0 header-ECC restore | high | sim_proven | **HW-ATTEMPTED** | Sim: `gaps_ecc` 6/6 with an ASIC_MIRROR=2 non-vacuity arm. HW: registry's own `hw_validation_2026_08_08` records ATTEMPTED-and-gated. **Structural win:** the ASIC flist re-point HAS landed — `flists/tidelink_top_full_asic_v2.flist:253` now names `src/rtl/local_overrides/WlinkEccSyndrome.v`. byte-1 remains sim-only (TL-038). |
| TL-007 | synth-B OKAY (not SLVERR) | high | **hw_proven** | **CLAIMED** | `sim_test: pending_agent:2` — a **placeholder that was never filled in**. `scripts/ci/registry_coverage.py` flags it: `GAP TL-007 (hw_proven): FIXED but in_sim_gate is not true`. HW = same narrative doc as TL-005, no log. **The single most overstated row.** |
| TL-008 | txgen ownership-mux hijack | high | sim_proven | **SIM-ONLY** | `imp/sim_gate/txgen_ext_hijack.status` `PASS 2s`, 2/2. Registry already self-corrected from `hw_proven` — a good precedent. |
| TL-009 | die_a PS wedge under sustained writes | high | root_caused | **OPEN** | Wedge reproduced **8/8** on 08-13 (§4). Its first ground-truth bullet is unsound (§5) and its signoff cites **`2c32c2b`, an object that does not exist in this repo** (§8). |
| TL-010 | F13 PTP — mailbox RO + convergence gap | high | fix_built | **SIM-ONLY** | `imp/sim_gate/v2_mbox_writeprotect.status` `PASS 2s`, 1/1. **Weak assertion:** the test is single-sided (`after == before`) and passes if the mailbox is dead or tied off. Two-board convergence never run. Cross-check TL-041. |
| TL-011 | F19 PHY BIST unwired | high | deferred | **OPEN** | Registry's own instrument finding: 1 PASS / 10 FAIL in this env. `grep phy_bist Makefile` = 0. No 08-13 evidence. |
| TL-012 | `_generate_xhb500` pipefail | high | fix_built | **N/A** | Structurally verified: `5be494b` exists, is an ancestor of HEAD, touches exactly `set_env.sh`, `.gitmodules`, `flists/tidelink_fpga.flist`. |
| TL-013 | V1 flist no longer elaborates | medium | fix_built | **N/A** | Same commit; `asic_v1_elab PASS 8s` 08-13 corroborates elaboration health. Retire-or-keep is a decision. |
| TL-014 | Duplicate PHY submodule | low | deferred | **OPEN** | Decision, coupled to TL-013. |
| TL-015 | Land tidelink on `main` | high | deferred | **N/A** | Process. Note: **three** clones now diverge (`SoCLabs/tidelink`, the integ line, and this off-repo eth-chiplet clone which is where all silicon evidence lives). |
| TL-016 | SSH → HTTPS in `.gitmodules` | medium | fix_built | **N/A** | `5be494b`, verified. |
| TL-017 | `tl_data_mode_o` lint break (FYI) | fyi | wontfix | **N/A** | Signed off as FYI. |
| TL-018 | ASIC FCSM CRC resets ON, FPGA OFF | medium | root_caused | **OPEN** | Verified live: `src/rtl/local_overrides/WlinkGenericFCSM.v:747` `<= 1'h1` (**CRC checking OFF**) vs `deps/.../WlinkGenericFCSM.v:636` `<= 1'h0` and `local_overrides/WlinkGenericFCSM_6.v:1194` `<= 1'h0`. **Should be re-rated `high` — see §4.** |
| TL-019 | ASIC flist pins FCSM 0-5 to deps | high | root_caused | **OPEN** | Verified live: `flists/tidelink_top_full_asic_v2.flist:315-320` all `deps/`. Consequence: **neither** the TL-035 watchdog fix **nor** any `socl_` recovery hook reaches the tapeout netlist. |
| TL-020 | ASIC flist hygiene / obs modules | high | sim_proven | **SIM-ONLY** | 08-13: `asic_v1_elab PASS 8s`, `asic_v2_elab PASS 9s`, `dft_wrapper_elab PASS 9s`. Genuinely closed on the elaboration axis. |
| TL-021 | First-silicon debuggability gaps | high | root_caused | **OPEN** | Spec-ready, David-gated. Sharpened by 08-13: the wedge was only localisable with an ILA, which silicon will not have. |
| TL-022 | RX-FIFO `rf_16k` never functionally simulated | medium | sim_proven | **SIM-ONLY** | 08-13 `fifo_rx_randinit`: the phantom-pop guard tests `test_41`/`test_42` **PASS** under adversarial init. `in_hw_gate: true` is a **paper claim** — §9. |
| TL-023 | Mailbox slot-select ICG runt pulse | low | open | **OPEN** | Gate-level, needs the pnr netlist. Unchanged. |
| TL-024 | FIX1/FIX2 regress 14 blocking suites | rank1_critical | root_caused | **SIM-ONLY** | 12/14 fixed (`t31 PASS 257s`); 2 waived as live defects — `v2_mask_hs_regress` **XFAIL** 597s. The **"~10x peer-write soak" HW claim has no log** and its named gate is scoped to the lottery-free vehicle — §8, §9. |
| TL-025 | tc_pair `.device_strap` undefined port | medium | root_caused | **OPEN** | ⚠ The 08-13 run gives **no information**: `tc_pair_smoke` FAILs in 0s with `MISSING DEPENDENCY /src/rtl/tidechart_shim.sv` — a *location* artefact of running from this clone, not the device_strap error. Must be re-run from the primary worktree. |
| TL-026 | Pipeline `pair_credit_next` | medium | sim_proven | **SIM-ONLY** | 40k-cycle dual-instance equivalence + negative control. Ungated (`registry_coverage.py` GAP). Netlist-affecting → David. |
| TL-027 | a2l replay nodes `_1/_3/_5` unhardened | high | root_caused | **SIM-ONLY** | Sim: `a2l_replay_cdc_{1,3,5}` all **PASS** 08-13, reproduce-first A/B per node. ⚠ **Registry UNDERSTATES:** the netlist change has already LANDED — `flists/tidelink_fpga_v2.flist:269,281,284` and `tidelink_top_full_asic_v2.flist:283,298,304` all point at `local_overrides`, while the registry still says `commit: null`, `status: root_caused`. §10. |
| TL-028 | Unconstrained D2D RX word clock | high | root_caused | **OPEN** | ASIC SDC has it; FPGA XDC does not. Low FPGA leverage per the registry's own correction. |
| TL-029 | F14-B data-mode wedge (waived) | medium | deferred | **OPEN** | 08-13 sentinel `xfail_f14b_datamode_wedge` **XFAIL** 55s — defect present and unchanged. Recovery = **POR of both dies**. MVP-relevant (§4). |
| TL-030 | EPOCH shipping-default corrector | medium | open | **OPEN** | 08-13 sentinel **XFAIL** 35s, re-baselined signature PASS=1 FAIL=2, s→m `rx=[0,0,0,0]`. The shipping default still has a **known all-zeros direction**. |
| TL-031 | No SW-readable bring-up eye/BER metric | medium | open | **OPEN** | **Materially advanced by the 08-13 data — a candidate metric already exists in the shipped register map. See §7. Highest-value MVP item in the registry.** |
| TL-032 | Calibrator wrap-straddle splits the eye | high | sim_proven | **SIM-ONLY** | `imp/sim_gate/calibrator_wrap.status` `PASS 3s`, `test_wrap_straddle_eye_is_not_split` 1/1. **No HW A/B** — it was never ridden on a build and land-rate-tested, which is exactly what §7 now makes cheap. |
| TL-033 | No credit-underflow protection (13-bit wrap) | high | open | **OPEN** | ⚠ A whitebox test now exists — `test_43_credit_underflow_saturates_whitebox` — and it **FAILs in both FIFO suites** on a stale precondition probe (`cocotb/tidelink_fifo/test_tidelink_fifo.py:1914`, `header length capture failed (got 0, want 8)`). **The property is untested, and this is one of the 7 gate reds.** |
| TL-034 | TideChart register-map defects | medium | open | **OPEN** | Unchanged; TideChart owner. |
| TL-035 | State-7 NACK watchdog dead after first CRC | high | root_caused | **HW-ATTEMPTED** | Best-run-of-the-campaign, and it still does not close. §3. |
| TL-036 | TL-035 fix omits `WlinkGenericFCSM_6` | medium | root_caused *(proposed)* | **OPEN** | Verified: `_6` carries neither `TL033_LEGACY_WDOG` nor `socl_l7_wdog_progress`, at HEAD or in the working tree. |
| TL-037 | No AXI firewall / timeout on the write path | high | open *(proposed)* | **OPEN** | Consequence HW-demonstrated 8/8: `tl035_tl035/07_errinject_sweep.log:12-22` — ssh timeout, **"recovery is JTAG-POR ONLY"**. **Top MVP item (§4).** |
| TL-038 | `errinject B --inj-byte 1` still wedges | high | open *(proposed)* | **OPEN** | HW evidence is narrative but contemporaneous and specific: `docs/AXI_DATANODE_OKAY_FIX_HWPROOF_2026_08_02.md:47` — `B, byte 1 (word_count) | WEDGED (SSH timeout)`. Not re-run since 08-02. |
| TL-039 | ILA/obs plane mis-scoped | medium | root_caused *(proposed)* | **OPEN** | Confirmed by my own re-analysis of the 08-12 capture (§6). Operationally worked around for die_a on 08-13; **die_b still has no AXI-node probes**. |
| TL-040 | `dbg_a2l_wedged` trigger cannot fire | medium | root_caused *(proposed)* | **OPEN** | Confirmed independently (§6). Worked around by re-triggering on `dbg_ahb_sub_hreadyout==0`; the inert trigger is still in the RTL. |
| TL-041 | `servo_locked` change inside a "No functional intent" commit | high | sim_proven *(proposed)* | **SIM-ONLY** *(fix)* / **OPEN** *(process)* | Independently confirmed: `b0e9334` body says *"No functional intent"*, the hunk comment says *"BEHAVIOUR-CHANGING FIX"*; reached the trunk via `a9ff715`; tests are in a **different** commit (`9622c3d`); `grep ptp_servo Makefile` = **0** and there is **no PTP log in `imp/sim_gate/` at all**. |
| TL-042 | CLASS: backstops keyed on a signal the wedge suppresses | high | root_caused *(proposed)* | **OPEN** | Instance 2 **positively measured on silicon** (§6) — the strongest single result of the campaign. Candidate fix **REJECTED on hardware** (§3). |

---

## 3. The three HW-ATTEMPTED rows, in detail

### TL-035 — hardware ran, with the best discipline in the project's history, and the result is null

The run is exemplary: arms md5-pinned per die (`8947a50d`/`5979d88c` fixed vs
`9eadebb8`/`13573e46` baseline), die_b's image **byte-identical across every run** so die_a's
bitstream is the only variable, abort-on-mismatch, fresh JTAG POR, and predictions written down
first (`PREREGISTERED_PREDICTIONS_2026_08_13.md`).

The result:

- **Delivery PASSED** (`tl035_tl035/06b_regionf_gate.log:23-24`, 200-beat adversarial stream,
  `16/16 folded words byte-exact`).
- **The wedge still happened** on a single AW byte-0/bit-0 inject
  (`tl035_tl035/00_run.log:48`, `AW byte0/bit0 inject@kr260_01 : FAIL (WEDGE)`; `:60` `die_a=DOWN`).
- The one positive claim — that TL-035 *converted* die_b's failure signature from all-clean to
  `ini_aw` — was **retracted the same day** when the pre-registered falsifier fired:
  `PREREGISTERED_PREDICTIONS_2026_08_13.md:196-211`, and `repeats/FINAL_TALLY.txt:11-14` shows
  `0xad408020` appearing on **3 baseline** and **2 tl035** runs. The signature is nondeterministic.

**Honest status (the registry's own words, which I endorse): "NO DEMONSTRATED EFFECT on this
failure, in either direction."** It is HW-ATTEMPTED, not HW-VALIDATED, because the run tested
*"does TL-035 fix the AW wedge?"* (no) and never tested *"is the watchdog now re-armable after a
real CRC?"* — the defect itself was never measured.

Two further facts that must travel with this row:

1. **The fix is uncommitted.** `git log --all -S 'TL033_LEGACY_WDOG'` returns nothing. It exists
   only as working-tree modifications to `src/rtl/local_overrides/WlinkGenericFCSM{,_1,_2,_3,_4}.v`.
   One `git checkout` destroys the netlist that all of the above evidence was built from.
2. **Part-B is already in that working tree**, despite the registry marking it
   **BLIND-MERGE-FORBIDDEN** pending an attended ILA:
   `wire [2:0] _GEN_115 = (auto_tx_out_advance | socl_l7_wdog_force_clear) ? 3'h4 : state;`
   The attended-ILA decision the registry demands has **not** been discharged —
   `auto_tx_out_advance` has still never been probed.

### TL-042 — candidate fix rejected on hardware. Correctly recorded, but the causal claim overshoots

`TL042_HW_RESULT_REJECTED_2026_08_13.md:6` — *"the fix is HARMFUL. Not committed. RTL reverted to
HEAD."* Not committing was the right call, and TL-042 stays **OPEN**.

But the *reason* recorded is stronger than the data supports, and the ledger should say so:

| Claim in the rejection doc | What the logs show |
|---|---|
| "baseline **16/16**, TL-042 fix **0/16**" (`:20-21`) | Correct per run, but the **identical 0/16 all-zeros result occurs on the BASELINE arm** (`repeats/r2_baseline/.../06e_localmem_pre.log:1`, 11:49) **and on the TL-035 arm** (`repeats/r4_tl035/.../06e_localmem_pre.log:1`, 12:06). The failure is not unique to the fix. |
| "Every run below had a HEALTHY bring-up: fcsm=4 both dies" (`:15-16`) | True but **incomplete**. In every failing run die_b read `SWI_LANE_STATUS=0x27890000`; in every passing run it read `0x05890000` (§7). That variable is **recorded at step 5, before any peer write is issued**, so it cannot be a consequence of a `wr_hold_r` timeout. It was not controlled for and not reported. |
| n | **2**. Against a background failure rate of 2/13 on the control arms. |

Fisher-exact on 3/3 bad draws for the fix arm vs 2/12 elsewhere gives p≈0.02 — *suggestive*, not
established, and the proposed mechanism (`synth_b_pending` is a term of `wr_hold_clr`, so
asserting it defeats the TL-002 hold) is a sound **RTL reading** that this experiment did not
separate from the pre-existing bring-up lottery.

**Disposition:** keep the rejection (correct and prudent), but restate the finding as
*"NOT VALIDATED — 0/2, confounded by a bring-up draw that also fails on both control arms"*
rather than *"HARMFUL"*. The genuinely durable output of that document is its process lesson,
which is excellent and should be preserved verbatim: *"A passing escape test is not a safety
test"* (`:72`) — the sim test asserted only that the hold escapes, never that
`synth_b_pending` clears or that a normal write still lands.

### TL-006 — hardware attempted twice, gated both times

08-08: attempted on the pair, blocked by the wedge before a clean injection window existed
(registry `hw_validation_2026_08_08`). 08-13: the errinject sweep **halts at the AW node**
(`tl035_tl035/07_errinject_sweep.log:22-23`, *"STOP: wedge on node AW — halting the matrix"*),
so the W and B injections that are TL-006's actual regression check **were never reached in any
2026-08-13 run**. The ECC restore remains sim-proven and structurally landed in both flists;
it is not HW-validated, and on current rig behaviour it *cannot be* until the AW wedge is
survivable.

---

## 4. MVP blockers — bar: "works most of the time, and is recoverable"

Ordered by how much they threaten that bar. Data corruption and unrecoverable wedges dominate;
observability items are explicitly **not** blockers.

### Tier 1 — blocks the MVP bar outright

| ID | Why it blocks | Cheapest path |
|---|---|---|
| **TL-037** | **This is the "recoverable" half of the bar, entirely.** A single corrupted AW header byte takes the board from "one failed write" to "ssh dead, JTAG-POR only" — **8/8 deterministic** on 08-13. There is no software-visible timeout anywhere on the path. | Instantiate AXI Firewall/Timeout in the eth-chiplet block design; return DECERR on expiry. Non-RTL, FPGA-only, no tapeout risk. **Highest value-per-effort item in the whole registry.** ASIC needs the equivalent in RTL — do not let the FPGA fix mask that. |
| **TL-018** | **Silent data corruption.** The five AXI data-plane FC nodes on the **shipping FPGA line** reset with link CRC checking **OFF** (`WlinkGenericFCSM.v:747` `<= 1'h1`), and the project's own gated test names the consequence — `test_axi_b_crc_off_silent_payload` **PASSES**, i.e. the silent-acceptance path is characterised and live. A research chip that cannot distinguish good data from bad fails the bar even when it "works". Registry rates this `medium`; **it should be `high`.** | Decide the reset value deliberately, or make the bring-up script set CTRL bit[16]. SW-recoverable either way — but it is currently set **nowhere**. |
| **TL-033** | **Silent data corruption.** Unconditional credit decrement wraps a 13-bit counter → unread data silently overwritten. And it is now **worse than untested**: the test that would prove it aborts in its own precondition (`test_tidelink_fifo.py:1914`), so it contributes a gate red while covering nothing. | Fix the stale probe first (it is a one-line handle rename, already half-done uncommitted), *then* judge the property. |
| **TL-042 / TL-009** | The wedge itself. Deterministic on one injected header bit, unrecoverable without JTAG POR. With TL-037 in place this degrades to "a failed write" and stops being a Tier-1 blocker — **which is why TL-037 outranks it.** | Do not build another backstop until §6's constraint is honoured. |

### Tier 2 — blocks "most of the time", but is detectable and retryable

| ID | Why | Note |
|---|---|---|
| **TL-001** | ~1 bring-up in 3 delivers zeros (5/15 on 08-13). | **Not a blocker if TL-031 lands** — §7 shows the bad draw is detectable *before* any data is sent, so the orchestrator can reject and re-POR. |
| **TL-031** | The enabler for the above. Currently rated `medium`/`open`; on this evidence it is the **single highest-leverage MVP item after TL-037**. | §7 — and it may need **no netlist change at all**. |
| **TL-030** | The shipping default (`EPOCH_ANCHOR_EN=0`) has a **known all-zeros direction** (s→m), live as an XFAIL sentinel. | Decide the ship default. |
| **TL-029** | All-lane data-flip during data mode wedges the link until **both dies POR**. Waived, defect live. | Acceptable *only* if the recovery story is "POR is cheap and automated". |
| **TL-038** | A second, uncovered wedge class (B byte-1 / word_count). | Unmeasured since 08-02. |

### Explicitly NOT MVP blockers
TL-011 (BIST — a first-silicon risk, not an MVP-function risk), TL-021, TL-026, TL-034,
TL-039/TL-040 (instrument defects — they cost engineering time, not function), TL-013/14/16/17,
TL-023, TL-025, TL-020 (done). **TL-041 is not an MVP blocker but is a tapeout-record blocker**
and should not be deferred on that basis.

---

## 5. Bugs whose only evidence is an instrument now known — or suspected — to be dead

Being precise here matters, because the campaign produced a *correction to its own correction*.

### Region F `OBS_AXI_NODES` (0x21E0)

The harness self-reports the sampler DEAD:
`control_baseline/tl035_baseline/00_run.log:41-44` —
*"stall bits NEVER moved under active write load. Treat the sampler as DEAD (TL-039/TL-040):
every all-clean Region F read is MEANINGLESS, including TL-009's 0xad800000."*

**That verdict is itself unsound, and the tree already says so.**
`tl035_tl035/06d_LIVENESS_RESULT_IS_INVALID.md:9-26`: `stall_live[9:0]` is **combinational**
(`valid & ~ready` on that cycle); the probe polls over SSH at ~1 sample/second against a ~10⁸
cycle/s domain, so 17–23 samples inspect ~20 cycles out of ~10⁹. **A test with no power
returning a negative is not evidence of absence.** The sampler is neither convicted nor cleared.

⚠ Note that this correction file exists in `tl035_tl035/` and
`tl035_baseline.aborted_sshratelimit/` but **not** in `control_baseline/`, `retry2/`,
`rep_tl042_r3/` or `overnight/run_01/`, whose `00_run.log`s therefore still carry the
un-annotated "DEAD" verdict. Anyone reading only the newest run directory gets the retracted
claim. **Propagate the correction file, or drop the verdict from the harness.**

**The operational conclusion is the same either way, and it is the one to carry forward:**
a Region F `0xad800000` at a wedge is **AMBIGUOUS** and proves nothing, because
(a) by construction `wedge_sticky`/`stall_live` need `valid & ~ready` and `resp_err` latches
only on a *completed* handshake, so a **never-driven B is invisible to this word**
(`src/rtl/tidelink_axinode_obs.sv:65-90`); and (b) sampler liveness is unproven. The harness
prints exactly this, correctly, at `control_baseline/.../00_run.log:57-60`.

**Bugs affected — their only "clean" reading came from this instrument:**

| Bug | The dead-instrument reading | Consequence |
|---|---|---|
| **TL-009** | `ground_truth_2026_08_07` bullet 1: *"Region F reads HEALTHY (0xad800000) … ⇒ NOT an FC-node wedge."* | **This inference was never entitled.** It is what pushed the investigation to "per-write resource leak" and then to the physical-eye story. The additions file's proposed amendment (`ADDITIONS:278-298`) is correct and should be merged. |
| **TL-005 / TL-042 (all-clean draws)** | `0xad800000` post-inject read as "no wedge on die_b". | Uninformative. The one time it *was* informative was when the **memory readback** was added (`PREREGISTERED_PREDICTIONS:296-320`) — the injected write's own signature value `0xB0008000` proved the data landed. **Memory readback, not Region F, is the trustworthy instrument.** |

### ECCCNT (0x2114) — documented-dead

Ties 0 in the shipped build; a `0xFFFF` read there is an undecoded/floating read, not a
measurement. **No row in this ledger rests on it.** It is named here only because it produced
the retracted "rig eye degraded" narrative, and because `0x8403_xxxx` is UNDECODED on this
platform (the eth-chiplet APB is `0x2E032xxx`) — a read there hard-wedges the PS and reads as
"degraded rig".

### `dbg_a2l_wedged` — inert by construction (TL-040)

Independently re-verified from the raw CSV, parsing **hex-first**:
`ila_2026_08_12/ila_capture_run/ila_capture.csv` — `dbg_a2l_wedged = 0x0 in all 4096 samples`,
`TRIGGER` asserted once (the forced trigger-position marker), and
`ila_capture_run/summary.txt:2` records `RESULT: ILA capture timeout`. The same capture shows
`dbg_fcsm_state = 0x4` (LINK_IDLE) for all 4096 samples — i.e. the probed FCSM is the
**sideband** node sitting idle (TL-039), not the AXI node that wedged. **Any conclusion drawn
from the 08-12 capture about the AXI write path is void**, including the reading that "all four
mechanisms are refuted".

---

## 6. The one thing that was genuinely measured — and independently re-verified here

TL-042 instance 2 is the strongest result in `imp/hw_gate/`, and I re-derived it from the raw
CSVs rather than taking the summary's word (hex-first parsing, per the decode-bug correction the
tree itself records at `ila_tl035_run_round2/summary.txt:43-48`).

**Round 2, `ila_tl035_run_round2/ila_capture.csv`, 43 probes, 4096 samples, die_a wedged:**

| Probe | Value across the window |
|---|---|
| `dbg_ahb_sub_hreadyout` | `0` — **all 4096** (the bus is held) |
| `dbg_wr_hold_r` | `1` — **all 4096** |
| `dbg_wr_hold_clr` | `0` — all 4096 (never clears) |
| `dbg_ext_is_nonseq` | `0` — all 4096 ⇒ **override-mux rank 3 is FALSE** |
| `dbg_pipe_valid_r`, `dbg_rd_pipe_r` | `0` — all 4096 |
| `sub_aw_accept` | `0` — all 4096 (**the write never reached `s_axi`**) |
| `sub_wr_os_ctr` | `0` — all 4096 |
| `synth_b_pending`, `sub_wr_stuck_fire` | `0` — all 4096 (**the backstop never arms**) |
| `sub_stall_ctr_r` | ramps to **`0x10000` = 2¹⁶** (**the timer genuinely expires**) |
| `dbg_fcsm_state` | `0x4` throughout — link healthy, not a link failure |

Round 1 (`ila_tl035_run/ila_capture.csv`) corroborates the counter behaviour: a clean monotonic
`0x159f → 0x259e` ramp with **zero resets** in the window, `distinct = 4096`.

**This is a positive measurement, not an absence:** a timer that genuinely expires, and an arming
condition — `sub_wr_stuck_fire = (osr_expired | stall_expired) & (sub_wr_os_ctr != 0)` — that
**cannot be satisfied because the wedge prevents the counter it keys on from ever incrementing.**
With rank 3 false, rank 5 (`wr_hold_r`) is the **sole** term holding `hreadyout` low, which
implicates TL-002's guard directly: it clears on `synth_b_pending`, which cannot assert here.

**The constraint this imposes on every future fix** — and the most reusable output of the whole
campaign — is that a backstop on this path must arm and clear on the **consequence** (sustained
PS-facing stall) and never on an intermediate signal the wedge suppresses. Two well-reasoned
fixes were designed and killed by measurement before implementation; both would have passed
review. Honour this before spending another build.

⚠ **Two caveats that must travel with this result.** (i) These are **die_a ILA-inserted builds**
with **no paired no-core control**, which the project's own protocol requires
(`PREREGISTERED_PREDICTIONS:138-146`) because ILA insertion has itself caused this wedge class on
this design (`WlinkGenericFCSM_6.v:129-138`, build #4, 5/5 deploys wedged). (ii) The analysis
output was never captured — `ila_tl035_run*/run.log` contains only the echoed analysis script,
not its stdout. The numbers above are mine, from the CSVs. **Redirect that stdout into the run
log**, or the next reader will have to re-derive it too.

---

## 7. New finding: the bring-up lottery is predictable from a register that already ships

This fell out of tabulating all 15 harness runs and does not appear in any document in the tree.

| die_b `SWI_LANE_STATUS` (0x2E032108) at step 5 | Runs | Delivery outcome |
|---|---:|---|
| `0x05890000` | **10** | `16/16 folded words byte-exact`, LOCALMEM `16/16` — **10 of 10** |
| `0x27890000` | **5** | `4/16 folded` / LOCALMEM `0/16` all-zeros, or bring-up VOID — **5 of 5** |

Perfect separation, n=15, across **three different die_a bitstreams**
(`9eadebb8` baseline, `8947a50d` tl035, `0366c344` tl042) and one constant die_b image.
Fisher exact ≈ 3×10⁻⁴. Runs: `control_baseline`, `repeats/r{1..4}_{baseline,tl035}`,
`retry2`, `rep_tl042_r3`, `tl035_{baseline,tl035,tl042}`,
`tl035_baseline.aborted_sshratelimit`, `overnight/run_01`.

Both dies read `fcsm=4`, `cal_done=1`, `cr_seen=1`, `crack_seen=1` in **every** one of these
runs — so **`fcsm=4` is not a data-plane predictor and `0x2108[30:24]` appears to be**, on this
dataset.

**Why this matters:**

1. **TL-031 may not need a netlist change.** Its premise is *"there is no SW-readable
   end-of-bring-up margin, so the orchestrator cannot reject a marginal eye and re-winscan"*.
   This says a candidate discriminator is already readable over APB in the shipped design. If it
   holds prospectively, the MVP recovery story becomes: read 0x2108 after bring-up → if not
   `0x05890000`, re-POR and retry. That converts TL-001 from a blocker into a bounded retry.
2. **It gives every future A/B a covariate to control.** The TL-042 rejection (§3) is confounded
   precisely because this variable was uncontrolled.
3. **It cheapens TL-032's HW A/B**, which currently has none: land-rate against a *predicted*
   draw is far more powerful than against a raw coin flip.

**Held with appropriate scepticism.** This is a *retrospective* correlation, n=15, one rig, one
day, one direction (die_a→die_b), and the project has been burned by exactly this shape before:
memory records an 08-06 investigation that **refuted** a land↔`0x27` correlation as
"return-traffic bits, not an eye predictor" — though note that the registry's own 08-07 FIX-1
run recorded *"land had 0x05890000, drop had 0x27890000"*, i.e. **the same direction as this
dataset**, and it was the 08-06 run that was opposite. So there are two contradicting datasets
and this is the larger one.

**Do not write this into the registry as measured.** The falsifiable test is cheap and a
20-run baseline campaign is already in flight (§11): **pre-declare `0x05890000` ⇒ PASS,
`0x27890000` ⇒ FAIL before reading the results, and score it.** One line of analysis over data
being collected anyway.

---

## 8. Rows where the registry status OVERSTATES the evidence

**These are the most dangerous rows in the table.** Each is machine-readable, each is consumed by
`campaign.awaiting_david_signoff`, and each would read to a signer as "hardware-proven".

| # | Row | The claim | What is actually on disk |
|---|---|---|---|
| **1** | **TL-007** | `status: hw_proven` | ⚠ **`sim_test: pending_agent:2`** — a placeholder never filled in. `registry_coverage.py` prints `GAP TL-007 (hw_proven): FIXED but in_sim_gate is not true` **and then prints `RESULT: COVERAGE OK`**. HW evidence is a narrative table, no log. **Demote to `sim_proven` at best; it is CLAIMED.** |
| **2** | **TL-003** | `status: hw_proven`, `hw_evidence: "silicon-confirmed die_a wedge #3 -> survives to #6"` | No log. A recursive search for every cited HW artefact (`hw_fix3*`, `hw_purewrite.log`, `hw_regionf_soak.log`, `hw_diea_dmesg.log`, `hw_paced.log`, `onchip_landrate.log`, `*ecc_hwverify*.log`) returns **nothing** in this tree. Sim evidence *is* genuine and non-vacuous. **Demote to `sim_proven`.** |
| **3** | **TL-005** | `status: hw_proven` | Same narrative-only basis (`AXI_DATANODE_OKAY_FIX_HWPROOF_2026_08_02.md:44-48`), scope = **one** inject class on **one** node. And the 08-13 ILA shows `synth_b_pending` **never asserts** at the observed wedge (§6) — positive evidence the backstop does not arm in the failure that actually happens. **Demote, and adopt the proposed `hw_scope` field.** |
| **4** | **TL-009** | `signoff.claude_verdict` names *"the P-B-lottery killer (shared-cap BUFG hoist, **commit 2c32c2b**)"* as the actionable lever | 🔴 **`git cat-file -t 2c32c2b` → `fatal: Not a valid object name`.** No object with that prefix exists in this repo. The named next step for the dominant HW blocker points at nothing. |
| **5** | **TL-024** | `in_hw_gate: true`, `hw_test: hwtest_gate.sh`, *"FIX 2 is the ~10x peer-write soak lever"* | The 10x soak has **no log**. `hwtest_gate.sh` is scoped `TARGET=kr260-pair-onchip` — the **lottery-free** vehicle, which by the registry's own account (`onchip_landrate.log` 4/4 × 500/500) is saturated before and after and **structurally cannot show the defect**. The gate has never run. |
| **6** | **TL-022** | `in_hw_gate: true`, `hw_test: 14_rx_fifo_phantom_pop.sh` | The script exists but sources a Z2-ONLY guard that `exit 3`s on a non-Z2 SoC and hardcodes `0x4403_xxxx`, which is **UNDECODED on this ZynqMP rig and hangs the PS**. It is not merely un-run — **it is un-runnable on the rig the evidence comes from.** |
| **7** | **TL-006** | `in_hw_gate: true`, `hw_test: kr260_eth_ecc_hwverify.sh` | Never completed. On 08-13 the sweep halts at AW before reaching W or B (`tl035_tl035/07_errinject_sweep.log:22`). |
| **8** | **TL-010** | `in_sim_gate: true` reads as covered | The gated test has **one** assertion, `after == before`, and passes if the mailbox is dead, tied off, or renamed. Cross-check TL-041: any PTP convergence claim may have been taken on a `servo_locked` that could never latch. |

### The meta-problem behind rows 5–7

`scripts/ci/hw_registry_coverage.py` prints **`RESULT: HW COVERAGE OK`** with
**`in_hw_gate bugs with a resolvable test : 6`**. Its definition of "resolvable"
(`hw_registry_coverage.py:78-83`) is *a token in the string matches a filename in a script
index*. **It checks that a file with that name exists — nothing more.** It cannot tell an
un-runnable Z2-only script from a green run, and it has never required that a run happened.

Its sibling `registry_coverage.py` prints **`RESULT: COVERAGE OK`** on the same invocation in
which it lists three FIXED-but-ungated gaps.

**This is the same vacuous-gate shape the project has already been bitten by twice** (the
2026-07-30 both-branches-`tt_pass` hwtest bug; the ASIC `summarise_check` that scores
`check_timing` PASS on a grep miss). Recommended minimum: make `in_hw_gate: true` require a
`hw_run_log:` field pointing at an artefact **under `imp/hw_gate/`**, and make both checkers
exit non-zero when they print a gap.

---

## 9. Where the registry UNDERSTATES — the mirror-image risk

Overstatement is the loud failure. This one is quieter and, for a tapeout, worse: **netlist
changes that have shipped while the registry still reads "not fixed".**

- **TL-027** — `status: root_caused`, `commit: null`, and yet
  `flists/tidelink_fpga_v2.flist:269,281,284` **and**
  `flists/tidelink_top_full_asic_v2.flist:283,298,304` already point all three AXI write-path
  a2l replay nodes at `src/rtl/local_overrides/`. The **tapeout netlist carries this change
  today** while the registry says it does not. (Sim backing is real — `a2l_replay_cdc_{1,3,5}`
  all PASS 08-13 — but the sim flists are **uncommitted and contain hard-coded absolute paths to
  this clone**, so those PASSes are not reproducible elsewhere.)
- **TL-006** — the registry's A3 reads as open-ish, but the ASIC flist re-point **has** landed
  (`tidelink_top_full_asic_v2.flist:253`). The shipping ASIC now carries header ECC.
- **TL-035** — the inverse hazard: the fix **is** in the netlist that was hardware-tested, is in
  **no commit**, and includes the Part-B change the registry forbids merging blind.

---

## 10. Provenance warnings on the evidence itself

Anyone citing this ledger downstream needs these five — starting with the one that puts all of it
at risk.

0. 🔴 **The entire evidence tree is gitignored.** `.gitignore:98` is `imp/*`, and
   `git ls-files imp/` returns **2 files** (`imp/ASIC/Makefile`, `imp/ASIC/README.md`). So
   **`imp/hw_gate/` (369 files, every hardware artefact this ledger cites) and `imp/sim_gate/`
   (110 files) are untracked, ignored, single-copy, and invisible to any clone** — including this
   file. A `git clean -xdf`, a fresh checkout, or a lost machine takes all of it. It also means
   the registry's `in_hw_gate: true` rows can never be substantiated by anything a reviewer can
   fetch. **Fix before anything else in this document: un-ignore `imp/hw_gate/` (or a curated
   `imp/hw_gate/evidence/` subtree) and commit the run directories, ILA CSVs, verdicts and
   pre-registrations.** This is a two-line change and it is the difference between a sign-off
   ledger and an anecdote.

1. **The on-disk `imp/sim_gate/` run is not green.** One contiguous `make sim_gate`,
   2026-08-13 19:39–20:54, stamped `d317c98242f9-dirty` (matches HEAD — the cross-branch trap
   does *not* apply here): **44/51 blocking PASS, 7 FAIL, 3/3 sentinels XFAIL. Verdict:
   `FAILURES DETECTED`.** Of the 7 FAILs, **5 never simulated at all** (`tc_pair_smoke`,
   `tc_pair_election_datamode`, `eth_relay_m0/m1`, `eth_regs_shape_a` — `MISSING DEPENDENCY`,
   an artefact of running from this off-repo clone where the sibling repos do not resolve) and
   **2 are stale white-box probes** (`test_tidelink_fifo.py:1914`), already patched
   uncommitted. **It is not citable as green, and the 5 are un-evidenced rather than failed.**
2. 🔴 **That sim_gate run was made against RTL that no longer exists.** It includes
   `test_wr_hold_stuck_escapes_tl042 PASS` at `axi_datanode_recovery.log:6508`, with the
   candidate's own telltale at `:6504`
   (`escaped_at=65518 … synth_b_pending=1 holdclr_only=1`). The TL-042 candidate was
   **reverted at ~21:15** (`TL042_HW_RESULT_REJECTED_2026_08_13.md:85`). **Every `tidelink_top.sv`
   suite in `imp/sim_gate/` — `axi_datanode_recovery`, `axi_datanode_gaps` and all their
   sub-targets — was run against the rejected RTL.** Those PASSes need re-running against the
   reverted tree before they are cited.
3. **`imp/sim_gate/` holds exactly one run and is wiped at the start of every aggregate**
   (`Makefile:1414`). There is no historical series, and re-running destroys what is there.
4. **The `-dirty` half of the stamp identifies nothing.** 13 tracked files were modified at run
   time, including the five FCSM overrides carrying the (uncommitted) TL-035 fix and the +68-line
   ILA instrumentation in `axi_chiplet_controller.sv`. **None of the 08-13 evidence, sim or
   hardware, is reproducible from git.**

---

## 11. Live campaign — this ledger is a snapshot

A 20-run baseline land-rate campaign was **in flight** while this was written:
`imp/hw_gate/overnight/driver.log:1-4` (`CAMPAIGN START: baseline arm, runs 1..20`,
`run_01 END harness_rc=0`, `run_02 START`), driver PID live. `run_01` is already folded into the
§7 tally (die_b `0x05890000` → `16/16`, `overnight/run_01/tl035_baseline/00_run.log:33,47`).

**Recommendation: before those results are read, pre-declare the §7 prediction**
(`die_b 0x2108 == 0x05890000` ⇒ delivery PASS; `0x27890000` ⇒ FAIL). It costs nothing, the data
is being collected regardless, and it converts a 20-run baseline into a proper test of the
cheapest MVP lever in the registry.

---

## 12. What would actually close a row

For the next engineer, the shortest paths from here to a **HW-VALIDATED** row:

| Target | What is needed |
|---|---|
| **TL-005 / TL-007** (fastest) | `errinject --node B --inj-byte 0` on a `0x05890000` bring-up, die_a alive afterwards, log retained under `imp/hw_gate/` with md5-pinned bitstreams **and committed** (§10.0). **Blocked only by the AW wedge halting the sweep first** — run the B node standalone rather than through the matrix. |
| **TL-006** | The same, extended to W byte-0 and AW byte-0 with the ECC arm A/B'd against a no-ECC build. Needs TL-037 (or a standalone B-first sweep) to survive long enough. |
| **TL-035** | A test that actually sets `socl_l7_real_crc_seen` — in sim (`test_l7_wedge_repro.py` drives `WlinkGenericFCSM_6` via the bring-up-forgive path and never sets the sticky, so `nack_wedge_recovery PASS` does **not** validate it) and on HW as a second-CRC-error re-arm check. **And commit the fix.** |
| **TL-001 / TL-031** | Score §7's prediction on the overnight campaign. If it holds: a bring-up qualification gate, no netlist change, and TL-001 stops being MVP-blocking. |
| **TL-042** | Do not build until a backstop's arming condition is shown to hold **in the wedged state** (§6). And re-run the rejected candidate's arm with die_b's `0x2108` recorded and controlled. |

---

*Compiled 2026-08-13 from `docs/BUG_REGISTRY.yaml`, `docs/BUG_REGISTRY_ADDITIONS_2026_08_13.yaml`,
`imp/hw_gate/**` (369 files), `imp/sim_gate/**` (110 files), `docs/REPO_ASSESSMENT_2026_08_10.md`,
and direct re-analysis of the three ILA CSVs and the git history. Read-only; nothing committed.*
