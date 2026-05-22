# TideLink Repository Simplification Assessment

**Date:** 2026-05-22  
**Author:** Analysis of current `main` HEAD (cfef83f)

This document identifies concrete steps to make the repository easier to navigate for new
contributors, with specific removals, consolidations, and structural changes grouped by effort.

---

## 1. Immediate removals (dead code / stale artefacts)

### 1-A. Stale RTL files in `src/rtl/` root

The `src/rtl/` root contains older versions of FIFO-related modules that have been superseded by
the versions in `src/rtl/fifo/`. The newer versions add the FC direct-write interface, packet
`active` tracking, AHB burst-mode fix (NONSEQ-only), credit underflow saturation, full APB
register interface, and PTP/servo pass-through ports.

| Stale file | Superseded by | Status |
|---|---|---|
| `src/rtl/tidelink_fifo.sv` | `src/rtl/fifo/tidelink_fifo.sv` | **Delete** |
| `src/rtl/tidelink_fifo_ctrl.sv` | `src/rtl/fifo/tidelink_fifo_ctrl.sv` | **Delete** |
| `src/rtl/tidelink_returner.sv` | `src/rtl/fifo/tidelink_returner.sv` | **Verify then delete** |

Also verify whether `src/rtl/tidelink_apb_regs.sv` (root) vs `src/rtl/fifo/tidelink_apb_regs.sv`
(fifo subdir) are diverged; keep only the live version.

The SRAM variant files are identical between the two tree locations (confirmed by diff):

| File pair | Action |
|---|---|
| `src/rtl/asic/tidelink_sram.sv` == `src/rtl/fifo/asic/tidelink_sram.sv` | Delete `src/rtl/asic/` copy; use `fifo/asic/` |
| `src/rtl/fpga/tidelink_sram.sv` == `src/rtl/fifo/fpga/tidelink_sram.sv` | Delete `src/rtl/fpga/` copy |
| `src/rtl/generic/tidelink_sram.sv` == `src/rtl/fifo/generic/tidelink_sram.sv` | Delete `src/rtl/generic/` copy |

After these deletions the `src/rtl/asic/`, `src/rtl/fpga/`, and `src/rtl/generic/` directories
become empty and can be removed.

### 1-B. Undocumented alternative RTL implementation

`src/rtl/tidelink_addr_translation.sv` is a 256-entry lookup-table implementation of address
translation that is **not instantiated in the active design**. The design uses `tl_addr_trans_cam.sv`
(8-rule CAM) via `tidelink_addr_translator.sv`. Address translation itself is an essential chiplet
function; this file is an alternative, more expensive implementation suitable only if more than 8
address ranges need to be mapped simultaneously.

The file has no header comment explaining its status or its relationship to `tl_addr_trans_cam.sv`,
so a new contributor cannot tell whether it is the active implementation or an unused alternative.

**Action:** Add a clear header comment to `tidelink_addr_translation.sv` stating it is an
alternative (not the active) implementation and explaining when it would be preferred over the
CAM. Remove it from `cocotb/lint/Makefile.synth` to prevent accidental inclusion in synthesis
flows — an accidental include would synthesise an ~1,500-cell mux tree silently alongside the CAM.

### 1-C. Vivado journal logs at repository root

```
vivado.log
vivado_1442576.backup.log
vivado_1445474.backup.log
vivado_327778.backup.log
vivado_3745175.backup.log
```

These are tool-generated artefacts. Add `vivado*.log` and `vivado*.backup.log` to `.gitignore`
and delete the existing copies. They contain no design information and inflate repository size.

### 1-D. `staging/` directory

The `staging/` directory contains design proposals and sim build artefacts from prior development
work that has since been merged or abandoned:

| Path | Status |
|---|---|
| `staging/phy_align/` | Merged — calibrator is now in `src/rtl/tidelink_phy_align_calibrator.sv` |
| `staging/phy_align/sim_build/` | Compiled sim object files — never belongs in git |
| `staging/apb_redesign/` | APB redesign has been completed; diffs are stale |
| `staging/apb_plumbing/` | Plumbing design note — content should be in `docs/` if worth keeping |
| `staging/i2c_train/` | I2C autoneg training work — verify if superseded by current autoneg RTL |

Recommended action: delete `staging/phy_align/sim_build/` immediately (compiled objects). Review
the remaining staging subdirs and either promote surviving content to `docs/` or delete.

---

## 2. Documentation consolidation

The repository currently has 30+ markdown files. Many overlap, and several are operational logs
or debug artefacts that have no value for a new contributor.

### 2-A. Duplicate specifications

`docs/SPECIFICATION.md` (v1.0, 2026-03-28, 406 lines) and `docs/TIDELINK_SPECIFICATION.md`
(v1.2, 2026-04-05, 1125 lines) cover the same ground. The latter is more complete and more
recent. **Delete `docs/SPECIFICATION.md`** and ensure `TIDELINK_SPECIFICATION.md` is the single
source of truth. Update any cross-references.

### 2-B. Debug and investigation artefacts — delete or archive

| File | Reason to remove |
|---|---|
| `docs/AGENT_BRIEF_FCSM_RX_BUG.md` | Single-session debug brief for a resolved bug; no value for contributors |
| `docs/CREDIT_PATH_DEBUG_PLAN.md` | Debug plan for a resolved issue (credit path now working) |
| `docs/LANE_LOCK_ROOT_CAUSE.md` | Root cause analysis for the lane-lock issue; findings absorbed into `BUG_TRACKER.md` and calibrator source comments |
| `docs/FPGAHUB_DEPLOY_PROPOSAL.md` | Internal tooling proposal; not relevant to anyone using the design |
| `docs/DAP_DEBUG_AXI_AREA_ANALYSIS.md` | Debug analysis for AXI DAP area; resolved and not design-relevant |
| `docs/BRANCH_FOLD_IN_LOG.md` | One-time operational log for a branch merge; historical only |
| `docs/BRANCH_TRIM_PLAN.md` | One-time branch hygiene plan; superseded once executed |
| `BRINGUP_REPORT.md` (root) | Long bringup narrative; useful history but too long for root. Move to `docs/BRINGUP_HISTORY.md` |
| `tidelink-architecture-notes.md` (root) | Informal scratch notes; either promote content to `docs/TIDELINK_SPECIFICATION.md` or delete |

### 2-C. Constraint rationale duplication

`docs/ASIC_SOURCE_SYNC_CONSTRAINTS.md` (470 lines) and `docs/SOURCE_SYNC_CONSTRAINTS_RATIONALE.md`
(335 lines) both document source-synchronous I/O timing constraints for the ASIC target. Merge
into a single file `docs/ASIC_TIMING_CONSTRAINTS.md` and delete both originals.

### 2-D. Integration plan documents that are now complete

| File | Status |
|---|---|
| `docs/PHY_ALIGN_INTEGRATION_PLAN.md` | Calibrator has been integrated; plan is complete |
| `docs/PHY_ALIGN_NEXT_STEPS.md` | Next steps are now tracked in `BUG_TRACKER.md` / `OUTSTANDING_WORK_REPORT.md` |

If the integration history is worth preserving, fold key decisions into `TIDELINK_SPECIFICATION.md`
§PHY-align section and delete these files.

### 2-E. Proposed target documentation structure

After the above consolidation, the `docs/` directory should contain:

```
docs/
├── TIDELINK_SPECIFICATION.md      # Single authoritative spec (was TIDELINK_SPECIFICATION.md)
├── USER_GUIDE.md                  # How to use the IP (keep, update)
├── REGISTER_MAP.md                # Register reference (keep, update)
├── AUTONEG_PROTOCOL.md            # Protocol detail (keep)
├── PTP_PROTOCOL.md                # Protocol detail (keep)
├── FC_NODE_REGISTRY.md            # FC node assignment table (keep)
├── ASIC_TIMING_CONSTRAINTS.md     # Merged ASIC constraint docs (new)
├── BUG_TRACKER.md                 # Active defect tracking (keep)
├── OUTSTANDING_WORK_REPORT.md     # Open work items (keep)
├── IMPLEMENTATION_STATUS.md       # Build/test status matrix (keep)
├── RTL_FREEZE_CHECKLIST.md        # Pre-tape-out checklist (keep)
├── DETERMINISM_VALIDATION.md      # Calibrator convergence evidence (keep)
├── SIM_GUARD_FEASIBILITY.md       # Sim/synth guard study (keep)
├── HAL_LINT_REPORT.md             # HAL lint results (keep)
├── RTL_OPTIMISATION_ANALYSIS.md   # This repo's optimisation findings (new)
└── REPO_SIMPLIFICATION_ASSESSMENT.md  # This document (new)
```

This reduces from 25 docs-directory files to 16, while retaining all design-relevant content.

---

## 3. Source tree structure clarity

### 3-A. Flatten `src/rtl/fifo/` into `src/rtl/`

The FIFO subsystem files live in `src/rtl/fifo/` but everything else lives in `src/rtl/`. Once
the stale root-level duplicates (§1-A) are deleted there is no reason to keep a `fifo/` subdirectory.
Flatten:

```
src/rtl/fifo/tidelink_fifo.sv         → src/rtl/tidelink_fifo.sv
src/rtl/fifo/tidelink_fifo_ahb.sv     → src/rtl/tidelink_fifo_ahb.sv
src/rtl/fifo/tidelink_fifo_ctrl.sv    → src/rtl/tidelink_fifo_ctrl.sv
src/rtl/fifo/tidelink_fifo_mem.sv     → src/rtl/tidelink_fifo_mem.sv
src/rtl/fifo/tidelink_returner.sv     → src/rtl/tidelink_returner.sv
src/rtl/fifo/tidelink_apb_regs.sv     → src/rtl/tidelink_apb_regs.sv
src/rtl/fifo/asic/tidelink_sram.sv    → src/rtl/asic/tidelink_sram.sv
src/rtl/fifo/fpga/tidelink_sram.sv    → src/rtl/fpga/tidelink_sram.sv
src/rtl/fifo/generic/tidelink_sram.sv → src/rtl/generic/tidelink_sram.sv
```

Update all flists accordingly. End state: all RTL files in a single flat `src/rtl/` with the
three target-variant SRAM files in `src/rtl/{asic,fpga,generic}/`.

### 3-B. `imp/` directory — Vivado project (large binary artefact)

`imp/fpga/project/` contains full Vivado project files including placed/routed netlists,
checkpoint files, and IP caches totalling hundreds of MB. This should not be in the main
repository for a hardware IP project. Options:

- **Preferred:** Add `imp/fpga/project/` to `.gitignore` and regenerate from scripts. The
  `fpga/` directory already contains the `build_design.tcl` / `build_pair.sh` flow to do this.
- **Alternative:** Keep only the synthesis/implementation reports (`*.rpt`) and move binary
  checkpoints to a separate artefact store (CI artefact upload).

For a new contributor, having to wait for a full Vivado build before seeing any results is a
significant barrier. Providing a pre-built bitstream download in the CI artefact store would
address this.

### 3-C. `cdc/` directory — SpyGlass output

`cdc/tidelink_top/` contains the full SpyGlass CDC verification run including HTML reports,
compiled netlists, and intermediate files. Like the Vivado project, this is a tool output and
should not be version-controlled. Move reports to `docs/cdc_reports/` (text/HTML only) and
gitignore the rest.

---

## 4. New contributor experience

### 4-A. README.md needs a quick-start section

The current `README.md` should lead with:

1. What TideLink is (2–3 sentences)
2. Prerequisites (Vivado version, Python, cocotb, any licence requirements for Wlink)
3. How to run a single cocotb test in under 5 commands
4. Where to find the register map and user guide
5. How to build and flash the FPGA bitstream

Currently the README references the specification and user guide but does not give a concrete
first-steps path.

### 4-B. `cocotb/` test directory needs a top-level README

`cocotb/` contains 25 test directories with no index of what each tests or how to run them
selectively. A single `cocotb/README.md` with a table of test directories, what each covers,
and approximate runtime would greatly reduce the on-boarding friction. The existing
`cocotb/VERIFICATION_PLAN.md` is a plan document, not a usage guide.

### 4-C. Wlink dependency is opaque to new contributors

The Wlink submodule (`deps/`) is a critical third-party dependency, but there is no documentation
explaining:

- Which Wlink version / commit is locked in `.gitmodules`
- What licence governs use of the Wlink IP
- Which Wlink RTL files are actually used vs. the full submodule tree
- How to regenerate the AXI-chiplet-controller wrappers if the Wlink version changes

A brief `docs/DEPENDENCIES.md` covering submodule purpose, version policy, and licence summary
would prevent confusion for new contributors who encounter the `deps/` directory.

### 4-D. `pynq_host/`, `python/`, and `scripts/` overlap

Three directories provide host-side tooling:

| Directory | Content |
|---|---|
| `pynq_host/` | PYNQ-specific bring-up scripts, bringup pair scripts |
| `python/` | Python utilities (unclear scope) |
| `scripts/` | Build and helper scripts |

New contributors cannot easily tell which directory to look in for a given task. Consolidate into
`scripts/` with subdirectories `scripts/fpga/` (build), `scripts/pynq/` (board interaction), and
`scripts/util/` (shared), or at minimum add a brief README to each.

---

## 5. Summary — quick wins vs. larger changes

### Quick wins (< 1 hour each)

- Delete `vivado*.log` files from root; add to `.gitignore`
- Delete `src/rtl/tidelink_addr_translation.sv`; remove from lint Makefile
- Delete `staging/phy_align/sim_build/` (compiled objects)
- Delete `docs/AGENT_BRIEF_FCSM_RX_BUG.md`, `docs/BRANCH_FOLD_IN_LOG.md`,
  `docs/BRANCH_TRIM_PLAN.md`, `docs/CREDIT_PATH_DEBUG_PLAN.md`
- Delete `docs/SPECIFICATION.md` (superseded by `TIDELINK_SPECIFICATION.md`)

### Medium effort (half day each)

- Delete stale `src/rtl/{tidelink_fifo.sv, tidelink_fifo_ctrl.sv}` root duplicates; verify
  returner and apb\_regs; update all flists
- Merge `ASIC_SOURCE_SYNC_CONSTRAINTS.md` + `SOURCE_SYNC_CONSTRAINTS_RATIONALE.md`
- Write `cocotb/README.md` test index
- Write `docs/DEPENDENCIES.md` for Wlink submodule

### Larger changes (1–2 days)

- Flatten `src/rtl/fifo/` into `src/rtl/` and update all flists and cocotb Makefiles
- Gitignore `imp/fpga/project/` and set up CI artefact store for bitstreams and reports
- Gitignore `cdc/tidelink_top/` and move human-readable reports to `docs/cdc_reports/`
- Rewrite `README.md` with a proper quick-start section
