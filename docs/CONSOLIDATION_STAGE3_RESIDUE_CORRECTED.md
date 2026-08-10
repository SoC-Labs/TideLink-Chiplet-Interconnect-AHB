# Stage 3 Residue — CORRECTED

**Supersedes** `docs/BRANCH_CONSOLIDATION_PLAN_2026_08_10.md:313`
> *"Measured, complete, and bounded: exactly 4 branches, 21 files, zero shipping RTL."*

**Replace with:**
> *Measured, complete, and bounded: **9 branches, 29 files carried** (21 additions + 8 modifications), **zero `src/rtl` carried** — but **three branches carry a `src/rtl` delta that must be REJECTED, not carried**, and **two of the eight new files are netlist- and timing-affecting**.*

Date: 2026-08-10 · Author: residue adjudication pass over `refs/remotes/ethclone/*`
Measured against `integ/tidelink-consolidated-2026-08-07` @ **`c4f9f9e`** (the local ref is **one commit ahead** of the `1037a63` quoted in the task brief — `c4f9f9e` = *"wip(consolidation): drain the trunk worktree — AUTO_ANCHOR_EN surfacing"*, not yet pushed). Every conflict set, blob hash and disposition below was recomputed at `c4f9f9e`.

---

## 1. Verdict

**The `ethclone` fetch adds work to Stage 3; it does not change the consolidation strategy, and the fast-forward promotion of the trunk remains correct.** Nothing in the five new branches contests the trunk's lineage: `ethclone/main` forks at *exactly* local `main@18491ef` and is a 20-commit eth-chiplet tail on top of it (its `src/rtl` tree `bfe2f04` and `flists` tree `073af02` are byte-identical to that fork point — it never touched core RTL); `backup/pre-fcsm-merge-809f038` is a **strict ancestor** of three of the others and contributes nothing unique; `integ/fix-on-selfarm` is a **duplicate lineage** of AXI-datanode fixes the trunk already carries under different SHAs. The trunk is a strict superset on RTL in every direction that matters. What the fetch *does* change is the **size and character of the residue**: the "zero shipping RTL" phrasing must be restated, because two of the five commits worth carrying (`809f038` DEVICE_CLASS, `0ed6d46` MII/RMII constraints) live under `fpga/` yet **do** change the packaged-IP parameter boundary and the timing closure of the eth-chiplet netlist — and because two branches carry a genuine `src/rtl` delta whose danger is that it **auto-merges silently**. The residue is also far smaller than five branches implies: all four eth-chiplet-line branches carry the **identical 8-file `fpga/` delta** (185 insertions / 16 deletions, byte-identical blobs on all four), so this is **one deduplicated pick set of 5 commits**, taken once, from `ethclone/main`.

---

## 2. Corrected residue table

`TRUNK = integ/tidelink-consolidated-2026-08-07 @ c4f9f9e`

| # | Branch | Tip | Ahead | Commits to carry | Files carried | Shipping RTL? | Disposition |
|---|--------|-----|-------|------------------|---------------|---------------|-------------|
| **The original four (unchanged by this fetch)** |
| 3.1 | `integ/gate-plan-2026-07-30` | `b1288ff` | 2 | 2 (whole branch) | **10** (100% docs) | no | `merge --no-ff` — merge-tree CLEAN |
| 3.2 | `feat/unit-regression-from-ethchiplet` | `5eff33a` | 1 | `5eff33a` | **1** (cocotb test) | no | cherry-pick + wire into `sim_gate` |
| 3.3 | `fix/v2-sync-clock-gate` | `2415766` | 4 | `ac643c8 88e867b` | **1** (doc) | no | cherry-pick 2 of 4; SKIP `c8d0e5f`/`2415766` (net-zero pair) |
| 3.4 | `test/i1-selfarm-regression` | `ca495c4` | 5 | `9d7992e 44b0670` *(option a)* | **9** | no | **[DECISION — David]** — see §5.5, the answer has changed |
| **The five new `ethclone` branches** |
| 3.7 | `ethclone/main` | `969a0c9` | 20 | **5**: `e2da121 0ed6d46 4cc9706 26c0712 809f038` | **8** (all `fpga/`, all *modifications*) | **no `src/rtl`** — but **2 files are netlist/timing-affecting** | **cherry_pick_subset — THIS IS THE PICK SOURCE** |
| 3.8 | `ethclone/integ/i1-fcsm-on-proven` | `e175fa6` | 23 | **0** | 0 carried; **1 doc + 5 blobs to archive** | **YES — 5 × `WlinkGenericFCSM*.v`, REJECT** | archive_tag + fixture/doc rescue |
| 3.9 | `ethclone/fix/i1-fcsm-bringup-ethchiplet` | `ff76009` | 21 | **0** | 0 | **YES — 5 × `WlinkGenericFCSM*.v`, REJECT** | archive_tag_only (tag `archive/i1/fix-i1-fcsm-bringup` already exists) |
| 3.10 | `ethclone/backup/pre-fcsm-merge-809f038` | `809f038` | 19 | **0** | 0 | no (`src/rtl` tree `d5e96b3` = merge-base) | archive_tag_only — **strict ancestor of 3.7/3.8/3.9** |
| 3.11 | `ethclone/integ/fix-on-selfarm` | `2db482d` | 3 | **0** | 0 | **YES — `tidelink_top.sv`, REJECT (would regress trunk)** | archive_tag_only |

**Totals: 9 branches · 21 + 8 = 29 files carried · +1 optional archival doc.**

### Why the four eth-chiplet branches collapse to one pick set

All eight files carry **byte-identical blobs on all four branches**, and the **trunk has not touched a single one since the fork** (trunk blob == merge-base blob for every one, at *both* merge-bases `18491ef` and `3ed78fe`):

| File | trunk & both bases | all 4 eth branches |
|------|-------------------|--------------------|
| `fpga/Makefile` | `1400167` | `49d2381` |
| `fpga/fpgahub.toml` | `c465621` | `3108e60` |
| `fpga/vivado_ip/nanosoc_eth_chiplet_vivado_wrapper.v` | `dddf257` | `fc8d46c` |
| `fpga/targets/kr260-eth-chiplet/tidelink_design.tcl` | `8727e3a` | `d151974` |
| `fpga/targets/kr260-eth-chiplet-flip/tidelink_design.tcl` | `cbac04b` | `8b76d01` |
| `fpga/targets/kr260-eth-chiplet{,-flip}/kr260_eth_chiplet_tidelink_timing.xdc` | `72320ce` (both dies) | `0bdce04` (both dies) |
| `fpga/targets/kr260-eth-chiplet/BUILD_NOTES.md` | `592f66e` | `13fefd6` |

**Consequence, and it is the good news in this report: all five cherry-picks apply with ZERO conflicts.** The trunk-side pre-image is the base pre-image, so the three-way apply is a fast-forward on every hunk. No claim in the source adjudications established this; it is verified here by blob identity.

`git log ethclone/backup/pre-fcsm-merge-809f038 --not $TRUNK ethclone/main ethclone/integ/i1-fcsm-on-proven ethclone/fix/i1-fcsm-bringup-ethchiplet` is **EMPTY** — 3.10 has provably zero unique content and collapses to a tag with no loss.

---

## 3. Ordered sequence — slot in as Stage 3.7 … 3.11

> **Standing rule, and here it is mechanical rather than stylistic: CHERRY-PICK, DO NOT MERGE.**
> On both i1-fcsm branches the files that *conflict* (host scripts, flist) are exactly the files that must **NOT** move, while the five shipping `WlinkGenericFCSM*.v` files merge **silently** and adopt branch content unopposed. Merging maximises risk while carrying nothing.

```bash
TRUNK=integ/tidelink-consolidated-2026-08-07     # currently c4f9f9e
git switch $TRUNK
```

### 3.7 — Carry the eth-chiplet build residue, ONCE, from `ethclone/main`

Pick source rationale: `ethclone/main` is the only one of the four that **contains `b98b944`** (it arrived via the non-evil merge `969a0c9`), so it is the least surprising provenance; and its merge/pick surface is the cleanest (`0` conflicts in `fpga/`, `src/rtl`, `flists`, `deps`).

```bash
# (a) fpgahub + Makefile plumbing — ORIGINAL ORDER, adjacent hunks of fpga/Makefile
git cherry-pick e2da121          # fpga/fpgahub.toml +75, fpga/Makefile +14/-1
git cherry-pick 26c0712          # fpga/Makefile +11  (regress_eth_chiplet)

# (b) timing constraints + the measurement that justifies them — TOGETHER
git cherry-pick 0ed6d46          # both kr260-eth-chiplet{,-flip} XDCs, +38/-8
git cherry-pick 4cc9706          # BUILD_NOTES.md +26  (the WNS evidence for 0ed6d46)

# (c) DEVICE_CLASS strap — LAST, and as its own re-package-and-revalidate step
git cherry-pick 809f038          # wrapper .v +21/-7, both design tcls +4 each
```

**Expected conflicts: NONE, on all five.** (Verified: trunk pre-image blob == base pre-image blob for all 8 files.) If any of these *does* conflict, **stop** — it means the trunk moved under you and the adjudication needs re-running.

**Verify after (a)+(b):**
```bash
grep -c 'eth_chiplet'          fpga/fpgahub.toml            # 0 -> 11
grep -c 'kr260_eth'            fpga/Makefile                # 0 -> >=1  (deploy_pair_role arm)
grep -c 'regress_eth_chiplet'  fpga/Makefile                # 0 -> 3
grep -c 'async_sys_rmii'       fpga/targets/kr260-eth-chiplet/kr260_eth_chiplet_tidelink_timing.xdc       # 0 -> 1
grep -c 'async_sys_rmii'       fpga/targets/kr260-eth-chiplet-flip/kr260_eth_chiplet_tidelink_timing.xdc  # 0 -> 1
```

**Verify after (c) — and note the verification is STRUCTURAL, not textual.** Per the standing project rule (*`-verilog_define` never reaches packaged-IP OOC synth; md5 proves nothing*):
```bash
grep -n 'DEVICE_CLASS' fpga/vivado_ip/nanosoc_eth_chiplet_vivado_wrapper.v   # param + .DEVICE_CLASS(...)
grep -n 'CONFIG.DEVICE_CLASS' fpga/targets/kr260-eth-chiplet*/tidelink_design.tcl   # {1} die_a, {2} die_b
# then RE-PACKAGE the IP and confirm the strap reached OOC synth in the packaged IP itself
```
**`809f038` is atomic across its 3 files and requires an IP re-package.** Landing the two `set_property CONFIG.DEVICE_CLASS` tcl hunks against the *un-repackaged* trunk IP errors at BD build; landing the `.v` without re-packaging leaves both dies at the `16'h0001` default and the fix is a silent no-op.

### 3.8 — Rescue the two negative controls and the archival doc, then tag

**The LINK_IDLE fixture set is already rescued** — see §5.5. **The LINK_DATA set is not.**

```bash
# The 0853c4c (LINK_DATA-keyed) hypothesis exists on EXACTLY ONE ref and has no tag.
git tag -a archive/ethclone/i1-fcsm-on-proven ethclone/integ/i1-fcsm-on-proven \
  -m 'ethclone I1 FCSM line: sole carrier of 0853c4c (LINK_DATA emit-gate ungate, silicon-FALSIFIED),
      6d85c68 (CRC-ON reset default, silicon-FALSIFIED) and docs/HANDOVER_KR260_FCSM_BRINGUP.md.
      RTL rejected — see docs/CONSOLIDATION_STAGE3_RESIDUE_CORRECTED.md.'

# Optional, [DECISION - David]: land the prosecution case as an ANNOTATED archive, never as live guidance
git show ethclone/integ/i1-fcsm-on-proven:docs/HANDOVER_KR260_FCSM_BRINGUP.md \
  > docs/archive/HANDOVER_KR260_FCSM_BRINGUP_2026-07-30_SUPERSEDED.md
# ... prepend a header recording: blame RETRACTED by ee15dfd; the
#     "cocotb/tidelink_fcsm_silicon_ratio/ does not exist" claim is FALSE against the trunk.
```

### 3.9 / 3.10 / 3.11 — Archive-only

```bash
git tag -a archive/ethclone/i1-fcsm-bringup-ethchiplet ethclone/fix/i1-fcsm-bringup-ethchiplet \
  -m 'ethclone: ff76009 == e79a5b8 REFUTED LINK_IDLE emit-gate fix (already tagged archive/i1/fix-i1-fcsm-bringup). RTL rejected.'
git tag -a archive/ethclone/pre-fcsm-merge-809f038 ethclone/backup/pre-fcsm-merge-809f038 \
  -m 'ethclone: strict ancestor of ethclone/main and both i1-fcsm branches; zero unique content.'
git tag -a archive/ethclone/fix-on-selfarm ethclone/integ/fix-on-selfarm \
  -m 'ethclone: duplicate lineage of trunk 32d9d5e/9b4c40b/e827199; cherry-picking would REGRESS the trunk.'
git tag -a archive/ethclone/main ethclone/main \
  -m 'ethclone: main@18491ef + 20-commit eth-chiplet tail; the 5 fpga/ commits were carried in Stage 3.7.'
```

### If someone merges anyway — the exact damage, reproduced

| Merge | Tree | Conflicts | What lands **silently** |
|-------|------|-----------|--------------------------|
| `TRUNK × ethclone/main` | `0c80fa8` | 5 add/add, all `pynq_host/scripts/` | — (but all 5 conflicts must resolve **take-trunk**) |
| `TRUNK × backup/pre-fcsm-…` | `8b39474` | same 5 | — |
| `TRUNK × integ/i1-fcsm-on-proven` | `d0141ca` | 6 (the 5 + `flists/tidelink_fpga_v2.flist`) | **all 5 AXI FC nodes**: emit-gate ungate at `WlinkGenericFCSM.v:289/292` + `out_prepend_swi_disable_crc <= 1'h0` at `:713` — **no conflict marker** |
| `TRUNK × fix/i1-fcsm-bringup-ethchiplet` | `5389b15` | 6 (same shape) | **all 5 AXI FC nodes**: `socl_bringup_hold_open` at `:317/321` — **no conflict marker** |
| `TRUNK × integ/fix-on-selfarm` | `7fa196b` | `Makefile`, the cocotb test, `src/rtl/tidelink_top.sv` | — (all three resolve **take-trunk**) |

Resolution rules, without exception:
- **All five `pynq_host/scripts/` add/add conflicts → take TRUNK.** The trunk copies are strict supersets (`xfer` 814 vs 441, `regress` 335 vs 273, `bringup` 324 vs 285, `run.sh` 138 vs 102, `probe` 97 vs 39). Resolving `kr260_eth_bringup.py` toward the branch **reintroduces the FIX-E self-deadlock** (branch polls `calibration_done` *before* releasing `SWI_TRAINING_MODE`; trunk `:200-205` forbids exactly that).
- **`flists/tidelink_fpga_v2.flist` → 100% TRUNK.** `90fe6cc`'s payload is fully absorbed (FCSM 0-4 resolve to `local_overrides` identically on both sides). Taking the branch side would drop `tidelink_tx_gen.sv`, `wlink_wlink_ptp_tl_a2l_48x4.v` (TL-020 defuse), `WlinkEccSyndrome.v`, `WlinkGenericFCReplayV2_{1,3,5}.v` (TL-027 a2l CDC) and the three I4 observability leaves.
- **Never `git checkout <branch> -- src/rtl/local_overrides/WlinkGenericFCSM*.v`.** The auto-merge preserves **Fix G** only by accident (base and branch agree at `state == 3'h5`; only the trunk moved to `3'h4 || 3'h5`). A file-level overwrite **would revert Fix G** and silently reopen the AXI data-node wedge.

---

## 4. MUST-NOT-DROP

Omission of any of these could not be proven safe.

| Item | Why it cannot be dropped |
|------|--------------------------|
| **`0ed6d46`** — MII generated clocks + `async_sys_rmii` group, **both** eth-chiplet XDCs | **The single highest-value item in the residue.** Trunk XDC blob `72320ce` == merge-base; `git grep` over the whole trunk `fpga/` tree returns **zero** hits for `mii_tx_clk`, `mii_rx_clk`, `async_sys_rmii`. Per `4cc9706` this block is the difference between **WNS +0.194 / +0.267 ns, 0 setup failures** and **-2.9 / -3.3 ns, 4 setup failures**. **Without it the trunk cannot rebuild the bitstream the silicon ran.** Must land on **both dies together** or the pair gets asymmetric constraints — a vicious bring-up failure mode. |
| **`809f038`** — `DEVICE_CLASS` per-die strap (finding G1) | Netlist-affecting. Trunk wrapper `dddf257` still carries the now-false comment *"KNOWN GAP (finding G1): DEVICE_CLASS is not a nanosoc_eth_chiplet parameter"*; neither eth-chiplet tcl contains `set_property CONFIG.DEVICE_CLASS`. Without it **both dies strap `0x0001`** = the non-deterministic dual-root TideChart election the trunk logs as TL-034. **Same defect shape as the 08-09 all-zeros root cause** (a wrapper parameter never surfaced ⇒ packaged IP silently ships the wrong strap). 3 files atomic + IP re-package. |
| **`4cc9706`** — `BUILD_NOTES.md` +26 | Docs only, but it is the **sole measurement record** for `0ed6d46` and the only thing that exonerates the residual **-22.x ns hold** (TideLink forwarded-clock RX is at bare-link parity with `kr260-pair-nptp` at -22.489 ns and is winscan-calibrated at runtime; the `rmii_to_mii` CE arcs are multicycle-stable by construction). Drop it and the constraint change lands unexplained and a future engineer re-chases a settled question. |
| **`e2da121`** — `fpga/fpgahub.toml` +75, `fpga/Makefile` +14/-1 | Trunk `fpgahub.toml` blob `c465621` == merge-base with **zero** eth-chiplet entries; trunk `fpga/Makefile` has **zero** `kr260_eth`, so `deploy_pair_role SOC=kr260_eth` still errors *"SOC must be z2 or kr260"*. The trunk can build the pair by `TARGET=` and then **cannot deploy it** — and that pair is the vehicle that ran on silicon and the byte-exact reference for the 08-09 `AUTO_ANCHOR_EN` work. |
| **`26c0712`** — `fpga/Makefile` `regress_eth_chiplet` +11 | The trunk already carries the 335-line `kr260_eth_regress.py` this invokes but has **no entry point** — a dangling asset. Adjacent `fpga/Makefile` hunks; land in the same pass as `e2da121`. |
| **The 5 `0853c4c` FCSM blobs** `703bd05 / 56e735c6 / dd1bd1c3 / 600d3236 / 3ddbb682` (LINK_DATA-keyed) | A **distinct** falsified hypothesis from `e79a5b8`, and `git for-each-ref --contains 0853c4c` returns **exactly one ref**: `refs/remotes/ethclone/integ/i1-fcsm-on-proven`. **No archive tag points at them.** Deleting the branch without tagging destroys the second negative control. Must **never** enter `src/rtl/local_overrides/`. |
| **`docs/HANDOVER_KR260_FCSM_BRINGUP.md`** (`e175fa6`) | Enumerated across every ref in the repo: exists on **exactly one** — `refs/remotes/ethclone/integ/i1-fcsm-on-proven`. It is the only surviving record of the two silicon-falsified experiments. **Do not land as live guidance** (it re-asserts the retracted `b98b944` blame and a claim about a missing sim that is provably false). Archive it **annotated**, or the prosecution case is silently erased. |
| **`refs/tags/archive/i1/strategy-i1-rolelock`** | **The sole carrier of `ee15dfd`**, the retraction that cleared `b98b944`. `git for-each-ref --contains ee15dfd` returns that one tag and nothing else — it is an ancestor of **nothing**, including the trunk. If that tag is ever pruned, **the retraction leaves the repo while the accusation survives on a branch.** Stage 3.5 (salvaging `docs/I1_ROLELOCK_ROOTCAUSE_FIX.md` onto the trunk) is therefore **not optional**. |
| **`refs/tags/archive/i1/fix-i1-fcsm-bringup`** | Sole tag on `e79a5b8`; preserves the LINK_IDLE fixture blobs independently of any branch. |
| **`ethclone/integ/fix-on-selfarm` archive tag** | Content fully absorbed and safe to drop from the merge plan, but tag it to preserve the ethclone SHA trail (`129b029/f9ae87e/2db482d` are re-applied duplicates of trunk `32d9d5e/9b4c40b/e827199`). |

---

## 5. Findings that change more than the runbook

### 5.1 — The `b98b944` dispute: the prosecution case is on these branches, and it lost

Ancestry, verified:

| Ref | contains `b98b944`? |
|-----|---------------------|
| `TRUNK`, `main`, `ethclone/main`, `ethclone/integ/fix-on-selfarm` | **YES** |
| `ethclone/backup/pre-fcsm-merge-809f038`, `ethclone/integ/i1-fcsm-on-proven`, `ethclone/fix/i1-fcsm-bringup-ethchiplet` | **no** |

The three branches that do **not** contain it are the ones cut *to avoid* it — `backup/pre-fcsm-merge-809f038` is literally the rollback snapshot taken on 2026-07-29 when `b98b944` was blamed, and `docs/HANDOVER_KR260_FCSM_BRINGUP.md` is the blame document (*"main commit b98b944 … makes the TideLink d2d link fail to come up … It must not ship as-is"*). **That blame was retracted by `ee15dfd`.** The trunk contains `b98b944` and therefore already embodies the post-retraction position. Those branches are the **pre-retraction fork**, and their entire reason for existing is void.

Two consequences with teeth:

1. **The branches' own tip disproves the branches' own RTL.** `docs/HANDOVER_KR260_FCSM_BRINGUP.md:81-82` records both candidate fixes as *"FALSIFIED — link still down"*: the emit-gate ungate (`0853c4c`) and the `out_prepend_swi_disable_crc` CRC-off reset default (`6d85c68`). No external evidence is needed to reject them.
2. **`ee15dfd` — the retraction — is reachable from no branch at all**, only `refs/tags/archive/i1/strategy-i1-rolelock`. The accusation is on a branch; the retraction is on a tag. That asymmetry is a live documentation hazard and is why Stage 3.5 must actually happen.

### 5.2 — Trunk vs silicon: the trunk **supersedes** the silicon RTL; the gap is in the **build**, not the RTL

The silicon-proven point is **`a04a194`** (2026-07-31, *link up `fcsm=4` with the recovery FCSM on silicon*), and it **is an ancestor of the trunk**. Diffing `a04a194 → TRUNK` over the five shipping FCSM overrides yields **exactly one change**:

```
-    end else if (state == 3'h5) begin
+    end else if (state == 3'h4 || state == 3'h5) begin
+      // SoC Labs (Fix G, 2026-07-31): LINK_IDLE (4) also counts as reached — a
+      // response RX node's TX FSM never enters LINK_DATA (5), so gating only on 5
+      // left socl_l7_bringup_forgive armed forever, masking the CRC->NACK path
+      // (the "recovery present but ineffective" AXI-data-node wedge).
```

So the trunk's FCSM is **silicon-proven plus one documented fix** — strictly newer, not divergent. The training/role-lock story is the same: `SELF_ARM_TRAIN_EN` lives in **4 trunk files** (`src/rtl/tidelink_top.sv`, `src/rtl/asic/tidelink_dft_wrapper.sv`, `src/rtl/local_overrides/axi_chiplet_controller.sv`, `fpga/vivado_ip/tidelink_vivado_wrapper.v`) and **zero files on all four eth-chiplet-line branches**. **Read this the right way round: the eth-chiplet branches are the pre-fix July snapshot. Their RTL is a historical dead end, not "what ran on silicon" in any shippable sense.**

**Two qualifications that no source adjudication raised, and both need recording:**

- **The trunk DOES diverge from the silicon netlist in one place** — `src/rtl/local_overrides/tidelink_autoneg.sv`. `a04a194` carried the 45-line `TRAIN_ENTRY_FALLBACK` training-EXIT PARK arc; the trunk **reverted** it (`a5df514`/`3e9c7f9`, both trunk ancestors). Bounded — the parameter survives in 9 trunk files and defaults `1'b0`, so the arc constant-folds away in any build that does not set it — but it is a **real RTL difference between the trunk and the netlist that reached `fcsm=4`**, and it deserves an explicit decision rather than silent omission.
- **Fix G itself is not silicon-validated.** It landed ~5 hours *after* the silicon run, it is the *only* FCSM difference from the silicon point, and it changes forgive-disarm on **all five** shipping AXI FC nodes. Record it as **sim-proven, not HW-proven**. *"The trunk is newer"* must not be allowed to read as *"the trunk is silicon-proven."*

**The correct form of the "silicon" finding is therefore: an RTL supersession plus a build-reproducibility gap.** The trunk's RTL is ahead of silicon; the trunk's *build* cannot currently reproduce the silicon image, because `0ed6d46`'s constraints are absent. That is what `0ed6d46` buys.

### 5.3 — The silent-merge hazard is real, reproduced, and **not** gated off by an `ifdef`

Both i1-fcsm branches auto-merge **all five shipping AXI FC nodes with no conflict marker**. Verified by building the merge trees and reading the resulting blobs:

- `TRUNK × integ/i1-fcsm-on-proven` → tree **`d0141ca`**, `WlinkGenericFCSM.v` blob `fca5fb8d`: carries the emit-gate ungate at `:289/292` **and** `out_prepend_swi_disable_crc <= 1'h0` at `:713`.
- `TRUNK × fix/i1-fcsm-bringup-ethchiplet` → tree **`5389b15`**, `WlinkGenericFCSM.v` blob `eb836de4`: carries `socl_bringup_hold_open` feeding both gates at `:317/321`.

**And the `ifdef` is a trap.** `ff76009` wraps its change as `` `ifdef SOCL_FCSM_BRINGUP_HOLD_ALWAYS `` → `socl_bringup_hold_open = 1'b0` (the **RED control**, pre-fix behaviour) / `else` → `= ~socl_reached_link_idle` (the **fix**). **The shipping default — no define — is the refuted fix.** Anyone reviewing the diff, seeing an `ifdef`, and concluding "opt-in, therefore inert" would be wrong; the merged blob lands on the FIX arm. The trunk's own `uvm/tidelink_top_system/Makefile:433-440` names this exact SHA: *"the REFUTED emit-gate fix (fix/i1-fcsm-bringup @ e79a5b8) … silicon says this fix does NOT recover I1, so a FAITHFUL sim must STAY RED with it."*

### 5.4 — **The two i1-fcsm branches are TWO distinct dead ends, not one**

They must be archived as two fixtures. `0853c4c` (on `i1-fcsm-on-proven`) ungates on `socl_l7_reached_link_data` — **LINK_DATA, state 5**. `ff76009`/`e79a5b8` (on `fix/i1-fcsm-bringup-ethchiplet`) introduces a **new** sticky `socl_reached_link_idle` and ungates on **LINK_IDLE, state 4**, and its own in-file comment draws the distinction: *"This is NOT the falsified 'open the gate until LINK_DATA' (v1): it keys on LINK_IDLE."* The blobs differ (`703bd05…` vs `bb71e357…`). Both are rejected — the LINK_DATA variant by `e175fa6`'s own handover, the LINK_IDLE variant by the trunk's UVM trust-gate — but conflating them loses a negative control.

### 5.5 — **Stage 3.4's `[DECISION — David]` now has an evidence-backed answer: option (a)**

New finding, not in any source adjudication. The trunk's `FCSM_SRC=fix` negative control is unrunnable — `uvm/tidelink_top_system/Makefile:441` seds the DUT flist to `$(CURDIR)/i1fix_fcsm/WlinkGenericFCSM{,_1..4}.v` and `git ls-tree -r $TRUNK | grep i1fix` returns nothing (and `.gitignore` does not cover it). **Trust-gate (c) is dead on the trunk today.**

`test/i1-selfarm-regression` — Stage 3.4, option (a), `9d7992e` — restores exactly those files, and the blobs are:

```
uvm/tidelink_top_system/i1fix_fcsm/WlinkGenericFCSM.v    bb71e357
                                   WlinkGenericFCSM_1.v  9e50a37e
                                   WlinkGenericFCSM_2.v  3d31123b
                                   WlinkGenericFCSM_3.v  ba038b60
                                   WlinkGenericFCSM_4.v  93253f01
```

**These are byte-for-byte the `e79a5b8` blobs** — the LINK_IDLE refuted fix, in its correct home as a **UVM fixture** rather than in `src/rtl`. So Stage 3.4(a) simultaneously (i) closes the dangling Makefile rule, (ii) revives trust-gate (c), and (iii) discharges the fixture-preservation requirement for one of the two negative controls. Option (b) (delete the rule) does none of that and leaves the I1 trust-gate permanently unrunnable. **Recommend (a).** The remaining rescue is the *LINK_DATA* set (`703bd05…`), which needs the archive tag in §3.8.

### 5.6 — Three factual corrections to fold into the record

1. **`.gitmodules` — the direction in the source notes is backwards.** All five branches carry the merge-base blob `19f3615` **unchanged**; the **TRUNK** is what moved (`5f80942`), rewriting `git@github.com:` → `https://`. `.gitmodules` does not appear in any branch-vs-base diff. The operational advice (keep the trunk's `https` form — it is the portable one for CI and fresh clones) is unchanged, but *"the branch rewrote it to SSH"* is false and must not be recorded as branch churn.
2. **`SOCL_L6_MIN_CR_EMITS` is `8'd32` on the trunk, the branches and the base alike.** Only `SOCL_L7_MIN_CRACK_EMITS_VAL` is `8`, identically on both sides. The claim that *"the trunk additionally lowered L6 to 8"* is wrong; the trunk's own UVM Makefile says so explicitly: *"SOCL_L6_MIN_CR_EMITS stays at its shipping localparam default (8'd32)."* (This matters — Stage 5.1 is a signed decision about exactly these two thresholds.)
3. **The `DEVICE_CLASS` cross-repo precondition is SATISFIED — verified, not assumed.** `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv:47` declares `parameter [15:0] DEVICE_CLASS = 16'h0001` and `:969` threads `.DEVICE_CLASS (DEVICE_CLASS)  // per-die strap (G1) — was hard-defaulted 0x0001`, introduced by parent-repo `55c20e6` (2026-07-29, *"batch-prep: DEVICE_CLASS param (G1)…"* — the matching half of `809f038`, same day, same "batch-prep" tag) and present at parent HEAD `f1b6bb4`. **`809f038` is `must_carry`, not blocked-on-David.** The residual requirement is only that the parent repo be **pinned at or after `55c20e6`**, since `nanosoc_eth_chiplet` is not vendored here. When it lands, **TL-025's text is stale** (*"DEVICE_CLASS is not a nanosoc_eth_chiplet parameter"*, `docs/BUG_REGISTRY.yaml:958`) and should be updated — but note TL-025 (an 8-bit runtime `device_strap` **port**) and finding G1 (a 16-bit compile-time **parameter**) are different defects; landing `809f038` closes **neither** TL-025 nor TL-034, only the determinism half.

### 5.7 — Two process notes

- **Do not open a separate `AUTO_ANCHOR_EN` chase.** The "trunk gap" flagged in the source notes held only at `1037a63`. At the current trunk tip `c4f9f9e` the 08-09 all-zeros fix **is present**: `AUTO_ANCHOR_EN` appears in `fpga/vivado_ip/tidelink_vivado_wrapper.v` (5), both `kr260-pair{,-flip}-nptp/tidelink_design.tcl` (5 / 2), `src/rtl/tidelink_top.sv` (3) and `src/rtl/local_overrides/axi_chiplet_controller.sv` (12). **`c4f9f9e` is not yet pushed** — that is its own [DECISION — David] below.
- **Do not cite the merge-tree tree hashes from the earlier adjudications.** They were computed against a trunk that has since moved. The current values are in §3; the conflict *path sets* are identical, so no disposition changes.

### 5.8 — **The Stage 3.6 gate as written would have missed this entire residue**

Two independent failures, both measured:

```bash
# gate as written, run against the five new branches:
ethclone/main                             A=0     # <- INVISIBLE
ethclone/integ/i1-fcsm-on-proven          A=1     # <- only the handover doc
ethclone/fix/i1-fcsm-bringup-ethchiplet   A=0     # <- INVISIBLE
ethclone/backup/pre-fcsm-merge-809f038    A=0     # <- INVISIBLE
ethclone/integ/fix-on-selfarm             A=0     # <- INVISIBLE
```

1. **It iterates `refs/heads/` only** (32 refs) and never touches `refs/remotes/` (13 ethclone refs).
2. **`--diff-filter=A` only sees additions.** **All 8 carry-files are modifications** — they exist on the trunk at the merge-base blob. The gate would have printed `RESIDUE … : 0` for four of five branches and declared the residue clean while 8 netlist- and build-affecting files sat unmerged.

**Replacement gate — "branch-touched AND still-different-from-trunk", diffed from the merge-base so trunk-ahead noise disappears:**

```bash
T=integ/tidelink-consolidated-2026-08-07
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/ refs/remotes/ refs/tags/archive/); do
  [ "$b" = "$T" ] && continue
  mb=$(git merge-base "$T" "$b") || continue
  git diff --name-only "$mb" "$b" | while read -r f; do
    bb=$(git rev-parse "$b:$f" 2>/dev/null) || { echo "RESIDUE $b : DELETED-ON-BRANCH $f"; continue; }
    tb=$(git rev-parse "$T:$f" 2>/dev/null) || { echo "RESIDUE $b : ONLY-ON-BRANCH  $f"; continue; }
    [ "$bb" != "$tb" ] && echo "RESIDUE $b : DIFFERS $f"
  done
done
```

**VERIFY:** every line it prints must appear on a **written adjudication allow-list** (for the ethclone branches: the 5 `pynq_host/scripts/` supersets, the flist, and the 5 `WlinkGenericFCSM*.v` rejects). This gate is a **review trigger, not an auto-pass** — but unlike the original it cannot return silence while an 8-file netlist-affecting residue exists.

---

## 6. Still needs a human decision

- **[DECISION — David] Stage 3.4 → take option (a).** `git cherry-pick 9d7992e 44b0670` (SKIP `43b5845` patch-dup, `ca495c4` byte-identical). §5.5 shows (a) is the only resolution that revives the trunk's I1 trust-gate (c) *and* preserves the LINK_IDLE negative control as a fixture. Option (b) leaves the gate permanently dead. Still yours to sign, but the evidence now points one way.
- **[DECISION — David] `809f038` re-package and revalidate.** The cherry-pick is clean and the cross-repo precondition is satisfied, but landing it requires: (i) pin `nanosoc-ethernet-chiplet` at or after `55c20e6`; (ii) re-package the eth-chiplet IP; (iii) full rebuild of **both** eth-chiplet targets; (iv) **structural** verification that the strap reached OOC synth. Note `fpga/scripts/check_wrapper_params.sh` currently has **zero** coverage of the eth-chiplet wrapper (`git grep -c -e eth_chiplet -e DEVICE_CLASS -e nanosoc` → 0) — extend it **in the same change**, or `DEVICE_CLASS` can fail to reach OOC synth exactly as `AUTO_ANCHOR_EN` did on 08-09.
- **[DECISION — David] Archive-or-land `docs/HANDOVER_KR260_FCSM_BRINGUP.md`.** It is the only surviving record of the two silicon-falsified experiments and exists on exactly one ref. It also re-asserts a retracted blame and a provably-false claim about a missing sim. Recommend: land under `docs/archive/` **with an annotation header**. Do not land verbatim; do not delete without tagging.
- **[DECISION — David] `tidelink_autoneg.sv` trunk-vs-silicon divergence (§5.2).** The trunk reverted the 45-line `TRAIN_ENTRY_FALLBACK` training-EXIT PARK arc that was in the silicon netlist. Bounded (parameter defaults `1'b0`, arc constant-folds), but it is a real difference from the netlist that reached `fcsm=4` and should be an explicit call, not an inherited default.
- **[DECISION — David] Fix G's status (§5.2).** Trunk-only, post-silicon, touches all five shipping AXI FC nodes, sim-proven but not HW-proven. Record it as such in the tapeout audit trail, or ratify it on hardware.
- **[DECISION — David] Push `c4f9f9e`.** The local trunk ref is one unpushed commit ahead of the `1037a63` that was promoted to origin, and that commit carries the 08-09 `AUTO_ANCHOR_EN` surfacing. Until it is pushed, `origin` and the local trunk disagree about whether the all-zeros fix exists.

---

### One-line summary for the plan

> Stage 3 is **9 branches, 29 files** (21 additions + 8 `fpga/` modifications), **zero `src/rtl` carried** — five clean cherry-picks taken **once** from `ethclone/main` (`e2da121 26c0712 0ed6d46 4cc9706 809f038`), four archive tags, two fixture rescues, and a **replaced Stage 3.6 gate** — because the gate as written returns silence on this entire residue.
