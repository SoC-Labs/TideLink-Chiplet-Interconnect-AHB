# TideLink Repository Simplification — Impact Assessment

**Date:** 2026-05-23
**HEAD assessed:** `034376f` (main, post HW-validated build #7)
**Source:** Companion to `docs/REPO_SIMPLIFICATION_ASSESSMENT.md`

This document is a **pre-implementation audit** of the simplification proposals.
No file deletions, renames, or build-system changes are made here. Each
proposal is graded by blast radius, build/test cycles that must re-run, and
recommended scheduling tier.

A "build cycle" below = one full FPGA build + bridge1 16/16 lane-lock HW
validation, ≈ 50 minutes wall-clock.

---

## 1 Inventory

### 1.1 `fpga/targets/` directory map (11 targets)

| Target dir                  | Purpose                                                                                          | XDC files | Status (HW)            |
|-----------------------------|--------------------------------------------------------------------------------------------------|-----------|------------------------|
| `mps3`                      | Arm MPS3 Prototyping Board (bare PL, TRM 100765_0000_04_en). No Zynq PS.                         | n/a       | Inactive (paused)      |
| `pynq-z2-single`            | Wave B1: single Pynq-Z2, Zynq PS as software controller, GPIO PHY pads only.                     | 2         | Baseline single-die    |
| `pynq-z2-loopback`          | Pair design, loopback ribbon; same bitstream both boards, role from `FPGAHUB_LOCAL_ROLE`.        | 2         | Functional             |
| `pynq-z2-pair`              | Paired GPIO bridge, base variant (USE_CLKBUF/USE_IDELAY off).                                    | 2         | Working                |
| `pynq-z2-pair-flip`         | `pair` + lane-flip on slave die (cable cross-strap variant).                                     | 2         | Working                |
| `pynq-z2-pair-ila`          | `pair` + integrated ILA debug cores.                                                             | 2         | Working                |
| `pynq-z2-pair-flip-ila`     | `pair-flip` + ILA.                                                                               | 2         | Working                |
| `pynq-z2-pair-slow`         | `pair` at reduced clock for margin sweeps.                                                       | 2         | Working                |
| `pynq-z2-pair-flip-slow`    | `pair-flip` slow variant.                                                                        | 2         | Working                |
| **`pynq-z2-pair-all`**      | `pair` with all PHY-align knobs (USE_CLKBUF + USE_IDELAY + per-lane delays) **enabled**.         | 4         | **HW-validated 16/16** |
| **`pynq-z2-pair-flip-all`** | `pair-flip` + all PHY-align knobs enabled.                                                       | 4         | **HW-validated 16/16** |

Notes:
- The eight pair* `README.md` files are byte-identical for the documentation
  preamble; the differences live in `tidelink_design.tcl` (different
  `set USE_*`/ila-insert toggles) and in the `*-all` variants' two additional
  XDC files (IDELAYE2 site constraints, BUFG promotion).
- Only `pair-all` and `pair-flip-all` are on the active build-cycle path
  (build #7). The unsuffixed `pair`/`pair-flip` targets are kept as
  "knobs-off" reference baselines; `*-ila`/`*-slow` are debug variants.

### 1.2 `flist/*.flist` directory map (32 flists)

The `(MODULE)_asic.flist` lookup in `syn/asic/common.mk` (line:
`ASIC_FLIST_PATH := $(TIDELINK_HOME)/flist/$(MODULE)_asic.flist`) means a
flist with **zero direct grep hit** may still be consumed when `MODULE` is
iterated through `MODULES = tidelink tidelink_fifo tidelink_fifo_ctrl
tidelink_returner tidelink_apb_regs tidelink_fc_adapter tidelink_top
tidelink_top_full`. The "consumed?" column below accounts for that.

| Flist                                  | Direct consumer(s)                                                          | Consumed? |
|----------------------------------------|------------------------------------------------------------------------------|-----------|
| `tidelink.flist`                       | `cocotb/tidelink/Makefile`, `cocotb/tidelink_py_pair/Makefile`               | YES       |
| `tidelink_addr_translation.flist`      | —                                                                            | **no**    |
| `tidelink_addr_translator.flist`       | —                                                                            | **no**    |
| `tidelink_ahb.flist`                   | `cocotb/tidelink_ahb`, `cocotb/tidelink_system`, `cocotb/tidelink_top`       | YES       |
| `tidelink_apb_addr_ctrl.flist`         | —                                                                            | **no**    |
| `tidelink_apb_regs.flist`              | `cocotb/tidelink_apb_regs/Makefile`                                          | YES       |
| `tidelink_asic.flist`                  | `syn/asic/common.mk` (ASIC_FLIST)                                            | YES       |
| `tidelink_clkfreq_check.flist`         | —                                                                            | **no**    |
| `tidelink_fc_adapter.flist`            | — (but MODULE=`tidelink_fc_adapter` → `_asic` variant via common.mk)         | indirect  |
| `tidelink_fifo.flist`                  | `cocotb/tidelink_fifo/Makefile`                                              | YES       |
| `tidelink_fifo_ahb.flist`              | —                                                                            | **no**    |
| `tidelink_fifo_ctrl.flist`             | — (MODULE iter target)                                                       | indirect  |
| `tidelink_fifo_mem.flist`              | —                                                                            | **no**    |
| `tidelink_fpga.flist`                  | `cocotb/i2c_mask_selflock`, `cocotb/wlink_pair`, `fpga/filelist.tcl`, `lint/verilator/Makefile` | YES (FPGA build) |
| `tidelink_generic.flist`               | —                                                                            | **no**    |
| `tidelink_idelay_rx.flist`             | —                                                                            | **no**    |
| `tidelink_lane_checker.flist`          | —                                                                            | **no**    |
| `tidelink_mul_iter.flist`              | —                                                                            | **no**    |
| `tidelink_netlist.flist`               | `cocotb/tidelink/Makefile` (gate-sim)                                        | YES       |
| `tidelink_perf.flist`                  | —                                                                            | **no**    |
| `tidelink_phc_cdc.flist`               | —                                                                            | **no**    |
| `tidelink_phy_align_calibrator.flist`  | —                                                                            | **no**    |
| `tidelink_phy_align_regs.flist`        | —                                                                            | **no**    |
| `tidelink_ptp.flist`                   | —                                                                            | **no**    |
| `tidelink_ptp_servo.flist`             | —                                                                            | **no**    |
| `tidelink_returner.flist`              | `cocotb/tidelink_returner/Makefile`                                          | YES       |
| `tidelink_rxclk_buf.flist`             | —                                                                            | **no**    |
| `tidelink_top.flist`                   | — (loaded via `_asic` lookup when MODULE=`tidelink_top`)                     | indirect  |
| `tidelink_top_asic.flist`              | `syn/asic/common.mk` MODULE iter (`tidelink_top` → `_asic` lookup)           | indirect  |
| `tidelink_top_full_asic.flist`         | `syn/asic/scripts/tidelink.FC.read_design.tcl`, `syn/asic/common.mk`         | YES (ASIC)|
| `tl_addr_trans_cam.flist`              | —                                                                            | **no**    |
| `tl_addr_trans_regs.flist`             | —                                                                            | **no**    |

Roughly **17 of 32 flists have no consumer at all** (per-module unit-lint
stubs from earlier per-block lint passes). Verifying they are also not
referenced from `lint/spyglass/` waiver imports or `cocotb/lint/` synth
sweeps is a prerequisite before any deletion.

All consumed flists pull RTL from `src/rtl/fifo/*` (the live tree). The
root-level `src/rtl/tidelink_fifo*.sv`, `src/rtl/tidelink_returner.sv`, and
`src/rtl/tidelink_apb_regs.sv` are **not referenced by any flist**.

### 1.3 Top-level artefact and staging areas

| Path                                       | Size on disk | git-tracked?              | Notes                                                                                                  |
|--------------------------------------------|--------------|---------------------------|--------------------------------------------------------------------------------------------------------|
| `v1-release/`                              | 6.7 MB       | **YES** (bitstreams, manifests, README, CHECKSUMS, PROVENANCE, fixes/) | First chiplet drop; binary + provenance archive. Treated as a release pin.       |
| `staging/`                                 | 2.5 MB       | **YES** (20 files, all under `git ls-files`)                          | 7 subdirs: `phy_align/`, `phy_align_integrated/`, `apb_redesign/`, `apb_plumbing/`, `i2c_train/`, `phy_repo_split/`, `staggered_bringup/` |
| `staging/phy_align/sim_build/verdi_config_file` | <1 KB    | **YES** (tracked)                                                     | Stale sim artefact tracked in git.                                                                     |
| `cdc/tidelink_top/`                        | 183 MB       | **gitignored** (`.gitignore` line `cdc/tidelink_top`)                 | SpyGlass output. Already not in repo; only on local disk.                                              |
| `cdc/tidelink_top_new/`                    | 104 KB       | **untracked** (new run dir, current session)                          | Should be gitignored too (covered by `cdc/*summary.rpt` pattern only partly).                          |
| `imp/`                                     | 3.9 GB       | gitignored except `imp/ASIC/` (Makefile + README only)                | Vivado project + checkpoints already excluded from VCS.                                                |
| `vivado*.log`, `*.backup.log` (root, 5 files) | ~40 KB    | **gitignored** (lines 75-76)                                          | Pattern already exists; old files just need deleting from working tree.                                |
| `BRINGUP_REPORT.md` (root)                 | —            | tracked                                                                | Per source doc §2-B, move to `docs/BRINGUP_HISTORY.md`.                                                |
| `tidelink-architecture-notes.md` (root)    | —            | tracked                                                                | Per source doc §2-B, promote or delete.                                                                |

Key observation: **the source assessment over-states the impact of
`imp/fpga/project/` and `cdc/tidelink_top/`** — both are already gitignored
(verified: `git ls-files imp` shows only `imp/ASIC/Makefile` and
`imp/ASIC/README.md`). They occupy local disk only, not repo size.

---

## 2 Per-proposal impact

Risk legend: **L** (low — docs-only or unreferenced files) · **M**
(constraint/RTL move with flist updates) · **H** (touches active build
path — needs HW rebuild + bridge1 16/16).

### §1-A Stale RTL duplicates in `src/rtl/` root
- **Blast radius:** 5 files (3 fifo + apb_regs + returner). All confirmed
  unreferenced by every consumed flist (§1.2). Diff vs `src/rtl/fifo/` shows
  the root copies are older.
- **Risk:** L if exactly-deletion + nothing else changes; raises to **M** if
  combined with §3-A flatten (then flists must be re-pointed).
- **Re-validate:** cocotb regression (`cocotb/tidelink*`, `cocotb/tidelink_fifo`,
  `cocotb/tidelink_returner`, `cocotb/tidelink_apb_regs`) on the simulator
  flow only. No HW build needed because no flist points at the root copies.
- **Cost:** 0 HW build cycles + ~10 min cocotb smoke.

### §1-B Undocumented `tidelink_addr_translation.sv`
- **Blast radius:** RTL file (alternative implementation, not instantiated).
  Removal from `cocotb/lint/Makefile.synth` only.
- **Risk:** L. Adding a header comment is documentation-only; the lint
  Makefile edit is one line.
- **Re-validate:** `make -C cocotb/lint synth` to confirm sweep still
  passes; no HW.
- **Cost:** 0 HW build cycles.

### §1-C Vivado `*.log` files at root
- **Blast radius:** 5 working-tree files. `.gitignore` already covers them
  (lines 75-76). No git changes needed beyond `git rm` if any were
  accidentally tracked (none are — verified).
- **Risk:** L (pure working-tree hygiene).
- **Re-validate:** none.
- **Cost:** 0.

### §1-D `staging/` directory
- **Blast radius:** 7 subdirs, 20 tracked files (mostly markdown + a few
  diffs and one `.sv` of historical I2C-train RTL).
- **Risk:** L for deletion of `staging/phy_align/sim_build/verdi_config_file`
  (stale tool artefact). L-to-M for whole-subdir deletions because
  someone may still link to those docs from a branch.
- **Re-validate:** none for the sim_build file; for full removal, grep for
  cross-refs from `docs/`, `cocotb/`, RTL header comments.
- **Cost:** 0 HW build cycles.

### §2-A Duplicate specifications (`SPECIFICATION.md` vs `TIDELINK_SPECIFICATION.md`)
- **Blast radius:** 1 file deletion; update any cross-link in `README.md`,
  `docs/USER_GUIDE.md`, etc.
- **Risk:** L. Pure docs.
- **Re-validate:** none.
- **Cost:** 0.

### §2-B Debug/investigation artefact docs
- **Blast radius:** 9 markdown files. None are referenced by code or build.
- **Risk:** L. Pure docs.
- **Re-validate:** none. Grep for inter-doc references before deleting (e.g.
  `BUG_TRACKER.md` may link to `LANE_LOCK_ROOT_CAUSE.md`).
- **Cost:** 0.

### §2-C Constraint rationale doc merge
- **Blast radius:** Merge 2 docs (`ASIC_SOURCE_SYNC_CONSTRAINTS.md` +
  `SOURCE_SYNC_CONSTRAINTS_RATIONALE.md`) into one `ASIC_TIMING_CONSTRAINTS.md`.
- **Risk:** L. Pure docs. **Constraints themselves are not touched** —
  this is the rationale prose only.
- **Re-validate:** none.
- **Cost:** 0.

### §2-D Completed integration-plan docs
- **Blast radius:** 2 files. Same as §2-B.
- **Risk:** L.
- **Cost:** 0.

### §3-A Flatten `src/rtl/fifo/` → `src/rtl/`
- **Blast radius:** 6 RTL files + 3 SRAM-variant subdirs. **All consumed
  flists need updating** (`tidelink_fpga.flist`, `tidelink_top.flist`,
  `tidelink_top_asic.flist`, `tidelink_top_full_asic.flist`,
  `tidelink_asic.flist`, `tidelink_fifo.flist`, `tidelink_fifo_ahb.flist`,
  `tidelink_fifo_ctrl.flist`, `tidelink_fifo_mem.flist`,
  `tidelink_returner.flist`, `tidelink_apb_regs.flist`).
- **Risk:** **H**. This is the highest-blast-radius proposal. Every
  cocotb env, every ASIC synthesis pass, and the FPGA build all change
  their file lookup. A typo in any flist breaks one consumer silently
  (elaboration error vs. wrong-version pickup of the stale root copy).
- **Re-validate:** FPGA build #8 (target `pair-all` + `pair-flip-all`) +
  bridge1 16/16. ASIC: `make -C syn/asic MODULE=tidelink_top` re-read. All
  cocotb suites that consume `tidelink_fifo*` flists. Verilator lint.
- **Cost:** **2 HW build cycles** (pair-all then pair-flip-all sequential
  to catch flip-only path) + ~30 min cocotb regression + ~20 min ASIC
  re-elaborate. Total ≈ **2 build cycles, ≈ 2 h aggregate**.
- **Prerequisite:** §1-A must be done first (and merged) so the destination
  filenames are vacant.

### §3-B Gitignore `imp/fpga/project/`
- **Blast radius:** Already done. `.gitignore` line `imp/*` (with
  `!imp/ASIC/`, `!imp/ASIC/Makefile`, `!imp/ASIC/README.md` exceptions)
  ensures `imp/fpga/project/` is excluded. **No action required**; only
  potentially a `git rm -r --cached` if anything snuck in (verified empty
  apart from `imp/ASIC/{Makefile,README.md}`).
- **Risk:** L (verify-only).
- **Cost:** 0.

### §3-C Gitignore `cdc/tidelink_top/`
- **Blast radius:** Already gitignored at `.gitignore:67`. The new
  `cdc/tidelink_top_new/` (current session) is **not yet** covered by an
  explicit pattern — recommend adding `cdc/tidelink_top*/` to the
  gitignore. The text+HTML reports promotion to `docs/cdc_reports/` is a
  separate, optional content move.
- **Risk:** L (one gitignore line edit) → L for content move.
- **Cost:** 0.

### §4-A README quick-start
- **Blast radius:** `README.md` rewrite.
- **Risk:** L. Docs only.
- **Cost:** 0.

### §4-B `cocotb/README.md`
- **Blast radius:** New file, 25-row table.
- **Risk:** L.
- **Cost:** 0.

### §4-C `docs/DEPENDENCIES.md` for Wlink
- **Blast radius:** New file documenting `deps/` submodule.
- **Risk:** L.
- **Cost:** 0.

### §4-D Consolidate `pynq_host/` / `python/` / `scripts/`
- **Blast radius:** Path moves. **Any script invoked by a Makefile or
  fpgahub action will break** when relocated (e.g.
  `scripts/farm_build.sh`, `pynq_host/bringup_pair_*.sh`).
- **Risk:** **M-to-H**. Even though no RTL changes, the bring-up flow uses
  `pynq_host/` paths that fpgahub action shells reference. A rename without
  full sweep of `pynq_host/`, `fpgahub-actions/`, `set_env.sh`, and
  CI YAML can leave dangling references that only fail on next deploy.
- **Re-validate:** Full bring-up dry-run (no HW build needed, but
  fpgahub action invocation must complete).
- **Cost:** ~0 HW build cycles + 1 full deploy dry-run.

---

## 3 Effort summary (build-cycle equivalents)

| Tier                       | Proposals                                                                                              | HW build cycles | Wall-clock |
|----------------------------|--------------------------------------------------------------------------------------------------------|-----------------|------------|
| Pure docs / hygiene        | §1-C, §1-D (sim_build only), §2-A, §2-B, §2-C, §2-D, §3-B verify, §3-C gitignore, §4-A, §4-B, §4-C     | **0**           | ~3 h prose |
| Unreferenced RTL cleanup   | §1-A (delete root duplicates), §1-B (header + lint Makefile)                                           | **0** (cocotb only) | ~30 min   |
| Constraint-free moves      | §1-D (full staging review)                                                                             | **0**           | ~1 h       |
| Build-system / flist edits | §3-A (flatten fifo/), §4-D (consolidate scripts)                                                       | **2 + 1 deploy**| ~3 h       |
| **Total**                  |                                                                                                        | **2**           | ~8 h       |

---

## 4 Recommendation — proposal ordering

### Tier 1 — safe-now (no HW, no constraint/RTL/flist edits) — 10 proposals
1. **§1-C** Delete `vivado*.log` from working tree (already gitignored).
2. **§1-D (subset)** Delete `staging/phy_align/sim_build/verdi_config_file`.
3. **§2-A** Delete `docs/SPECIFICATION.md`; update cross-refs to
   `TIDELINK_SPECIFICATION.md`.
4. **§2-B** Delete the 9 debug/investigation markdowns; move
   `BRINGUP_REPORT.md` to `docs/BRINGUP_HISTORY.md`.
5. **§2-C** Merge `ASIC_SOURCE_SYNC_CONSTRAINTS.md` +
   `SOURCE_SYNC_CONSTRAINTS_RATIONALE.md` → `docs/ASIC_TIMING_CONSTRAINTS.md`.
6. **§2-D** Fold `PHY_ALIGN_INTEGRATION_PLAN.md` + `PHY_ALIGN_NEXT_STEPS.md`
   key decisions into `TIDELINK_SPECIFICATION.md`; delete originals.
7. **§3-C** Add `cdc/tidelink_top*/` to `.gitignore` to cover
   `cdc/tidelink_top_new/`.
8. **§4-A** Rewrite `README.md` with quick-start.
9. **§4-B** Add `cocotb/README.md` test index.
10. **§4-C** Add `docs/DEPENDENCIES.md` (Wlink submodule policy).

### Tier 2 — safe-with-validation (cocotb / lint regression, **no HW**) — 3 proposals
11. **§1-A** Delete `src/rtl/tidelink_fifo.sv`,
    `src/rtl/tidelink_fifo_ctrl.sv`, `src/rtl/tidelink_returner.sv`,
    `src/rtl/tidelink_apb_regs.sv`. Verify with `git grep` for any flist
    or comment ref before delete; run cocotb smoke for affected suites.
12. **§1-B** Add header comment to `src/rtl/tidelink_addr_translation.sv`
    and remove from `cocotb/lint/Makefile.synth`. Run lint sweep.
13. **§1-D (remainder)** Promote `staging/apb_plumbing/DESIGN.md` and any
    surviving content from `staging/` to `docs/`; delete the rest. Grep
    for inbound links first.

### Tier 3 — defer (touches active build path, needs HW build #8) — 2 proposals
14. **§3-A** Flatten `src/rtl/fifo/` into `src/rtl/`. **Prerequisite:**
    Tier-2 §1-A completed and merged so destination filenames are free.
    Requires 2 FPGA build cycles (pair-all + pair-flip-all) and ASIC
    re-elaborate. **Schedule for next planned build window.**
15. **§4-D** Consolidate `pynq_host/` / `python/` / `scripts/`. Requires
    full deploy dry-run and fpgahub action audit. Lower priority than
    §3-A; can be tackled as a separate session.

### Excluded (no-op / already done)
- **§3-B** `imp/fpga/project/` already gitignored — verify only.
- **§3-C** `cdc/tidelink_top/` already gitignored; only the `_new` sibling
  needs the gitignore tweak (included in Tier 1).

---

## 5 Quick-win list (≤ 5 items, no HW build, ordered by impact)

| # | Proposal | Files touched | Impact | Notes |
|---|----------|---------------|--------|-------|
| 1 | **§2-B** Bulk-delete 9 debug/investigation docs + move `BRINGUP_REPORT.md` to `docs/BRINGUP_HISTORY.md` | -9 root/docs files, +1 move | Biggest single reduction of new-contributor navigation noise (~25% of `docs/` index gone, root cleaner) | One commit, no risk; grep inbound links first |
| 2 | **§1-C** + **§3-C** Delete 5 root `vivado*.log` files; add `cdc/tidelink_top*/` to `.gitignore` | -5 untracked files, +1 gitignore line | Cleans working-tree directory listing and stops next CDC run from showing up as untracked clutter | Pure hygiene; no code |
| 3 | **§2-A** + **§2-C** + **§2-D** Spec/constraint-doc consolidation (3 deletes + 1 merged file) | -5 docs, +1 merged constraint doc | Single source-of-truth for spec and ASIC timing rationale; eliminates contradictions | Pure docs |
| 4 | **§4-B** Add `cocotb/README.md` test index (25 dirs) | +1 file | Biggest contributor-velocity gain per byte; no risk | Table of dirs + runtime + purpose |
| 5 | **§4-C** Add `docs/DEPENDENCIES.md` documenting Wlink submodule version, licence, regen procedure | +1 file | Removes opacity around the most critical 3rd-party dep | Brief, ≤ 1 page |

Each of the five quick-wins is mergeable with **no FPGA HW build** and
**no risk of regressing the build #7 16/16 lane-lock state**. None touches
RTL, constraints, flists, or active Makefiles. Together they reduce
`docs/` from ~35 markdowns to ~22 and the root from 2 ad-hoc markdowns to
just `README.md`.

---

## 6 What is explicitly NOT recommended in this pass

- **No deletion or rename of any `fpga/targets/pynq-z2-*` directory.**
  Build #7 depends on `pair-all` and `pair-flip-all`. The source
  assessment does not propose to delete these but a future cleanup
  reviewer might be tempted; this audit defers any target-set reduction
  until the v1 ASIC bring-up is past silicon.
- **No deletion of any `*.flist` file**, even ones with zero consumer
  (§1.2 lists 17 such candidates). They are cheap to keep and several
  may be pulled in by lint/synth flows under workflows not exercised in
  this audit. A separate per-flist audit is appropriate before any
  flist deletion.
- **No constraint (`*.xdc`, `*.sdc`) edits.** Every per-target XDC under
  `pair-all` and `pair-flip-all` is on the HW-validated path.
- **No Makefile edits** beyond §1-B's single-line lint sweep removal and
  Tier-3 §3-A's flist path updates (deferred).

---

## 7 Validation gates summary

| Tier | Required validation                                                    | Gate before commit                                                                             |
|------|-------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| 1    | None (docs/hygiene only)                                                | `git diff --stat` review; `git grep` for any inbound link to a deleted file                    |
| 2    | cocotb suites for affected flist consumers + `cocotb/lint` synth sweep  | All previously-passing cocotb tests still pass; no new lint errors                             |
| 3    | Build #8 on `pair-all` + `pair-flip-all`; bridge1 16/16; ASIC re-elab   | Bitstream programs, autoneg passes, 16/16 lane lock matches build #7; ASIC elab time unchanged |
