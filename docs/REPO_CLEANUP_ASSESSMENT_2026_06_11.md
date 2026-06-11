# Repo Cleanup & Simplification Assessment — 2026-06-11

Goal: bring `tidelink` to a clean, productisable state for integration, mirroring
the consolidation already done in the sibling repo
[`../tidelink-gpio-phy-deskew`](../../tidelink-gpio-phy-deskew) (commit `b52e002`,
*"consolidate 23 docs into a 5-document product set + archive"*).

## TL;DR

The **code and directory structure are already ~95% clean** — build artifacts are
correctly `.gitignore`d, and the large directories (`syn/`, `imp/`, `cocotb/`,
`uvm/`, `cdc/`, `xprop/`, `lint/`) are genuine source or sign-off infrastructure,
not cruft. The dominant problem is **documentation sprawl**: **134 doc files**
where the sibling repo lives comfortably with **6 active + 11 archived**.

| Area | State | Effort to clean |
|---|---|---|
| Documentation (134 files) | 🔴 Major sprawl | High (judgment) — the headline item |
| `.gitignore` gaps (3 small) | 🟡 Minor | Trivial |
| Tracked sim cruft (7 `verdi_config_file`) | 🟡 Minor | Trivial |
| Working-tree scratch (348 KB, already ignored) | 🟢 Cosmetic | Trivial |
| Directory layout (`flist/`→`flists/`, etc.) | 🟢 Cosmetic | Low |
| Submodule `deps/tidelink-gpio-phy` dirty | 🟡 Needs decision | Low |

---

## 1. Documentation — the headline (134 → ~6 active + curated archive)

The sibling repo's model is the target:

| Active product doc | Folds in from this repo |
|---|---|
| **ARCHITECTURE.md** | `TIDELINK_SPECIFICATION.md`, `PHY_ARCHITECTURE_REFERENCE.md`, `DEPENDENCIES.md`, `FC_NODE_REGISTRY.md`, `ASIC_TIMING_CONSTRAINTS.md`, `CDC_AUDIT_REPORT.md` |
| **IMPLEMENTATION.md** | `TIDELINK_BRINGUP_USER_GUIDE.md` (canonical bring-up), `AUTONEG_PROTOCOL.md`, `PTP_PROTOCOL.md`, `i2c_train/I2C_TRAIN_PROTOCOL.md`, `PHY_LANE_DESKEW_DESIGN_*`, `HW_TEST_SUITE.md` |
| **REGISTER_MAP.md** | `REGISTER_MAP.md` (already canonical — keep) |
| **INTEGRATION_GUIDE.md** | `HW_VALIDATION_RUNBOOK_GPIO_PHY_INTEG.md` + bring-up/wiring sections |
| **VERIFICATION_PLAN.md** | `VPLAN.md` (canonical), HW test matrix, `SHORTCOMINGS.md` (known-issue backlog), sign-off criteria |
| **README.md** (docs index) | new — table + reading order, like the sibling |

Everything else → **`docs/archive/`** (already ~73 files there) with a maintained
`docs/archive/README.md` index, conclusions folded up into the 5 docs above.

### Delete (zero durable value)
- `docs/_obs_raw/` (6 raw probe dumps: `b13_pre_*.txt`)
- `docs/agent_f_probe_dump_post_fix.log` (2k-line raw trace)
- Stale duplicates superseded by newer docs (see overlaps below)

### Known duplicates / overlaps to resolve
- `USER_GUIDE.md` vs `TIDELINK_BRINGUP_USER_GUIDE.md` → keep the bring-up guide, drop/archive `USER_GUIDE.md`.
- `BUG_TRACKER.md` vs `RTL_FREEZE_CHECKLIST.md` vs `OUTSTANDING_WORK_REPORT.md` → one canonical backlog (fold into VERIFICATION_PLAN), archive the rest.
- `SIGN_OFF_STATUS.md` vs `IMPLEMENTATION_STATUS.md` → archive both as point-in-time.
- 5× `PHC_PHASE1_*` + `PHC_DEV_LOG.md` → one archived PHC summary.
- 4× `CALIBRATOR_9_11*` + `CALIBRATOR_HW_FAILURE_AUDIT` → one archived calibrator summary.
- 13× `docs/archive/agent_*.md` working-session logs → keep under archive, index only.
- `REPO_SIMPLIFICATION_ASSESSMENT.md` + `REPO_SIMPLIFICATION_IMPACT.md` (May 23 — a *prior* cleanup attempt that regrew) → superseded by this doc; archive.

### Root-level doc
- `BRINGUP_REPORT.md` (72 KB, tracked, the v0 phase-0 silicon snapshot) → move to `docs/archive/`.

**Net:** active doc surface drops from ~45 root docs to ~6; ~120 files preserved
under a curated, indexed `docs/archive/`.

---

## 2. `.gitignore` gaps (trivial)

Already correctly ignored: `*.svf`, `fpga_*.log`, `fc_output.txt`, all `syn/`,
`imp/`, `cdc/`, `lint/`, `cocotb`/`uvm` `sim_build*` trees, `deps/xhb500/generated/`.

Missing — add:
```
/.Xil/
/.pytest_cache/
**/verdi_config_file
```

---

## 3. Tracked sim cruft (trivial)

7 `verdi_config_file` files are tracked inside `sim_build*` dirs (each is a 1-line
Verdi stub). Remove from the index:
```
git rm --cached cocotb/debug/calibrator_force_bisect/sim_build_*/verdi_config_file \
                cocotb/tidelink_ptp/sim_build_gated/verdi_config_file
```
(then the `**/verdi_config_file` ignore keeps them out).

---

## 4. Working-tree scratch (cosmetic, 348 KB)

25 `default-*.svf` + 12 `fpga_*.log` + `fc_command.log` + `fc_output.txt` sit in the
working tree but are **already gitignored** (not committed). Safe to `rm` to declutter;
no git impact.

---

## 5. Directory layout (cosmetic, optional)

The structure is sound — keep `src/{rtl,rdl,sw}`, `syn/`, `imp/`, `cocotb/`, `uvm/`,
`pynq_host/`, `python/`, `ci/`, `cdc/`, `xprop/`, `lint/`, `flows/`, `v1-release/`.

Optional alignment with the sibling repo:
- `flist/` → **`flists/`** (sibling uses plural).
- Verify `public/index.html` is actually served (GitLab pages stub) — else drop.

Do **NOT** touch: `src/rtl/local_overrides/`, `tidelink_addr_translation.sv`,
`tidelink_ahb.sv` (intentional dormant RTL), or any vendored IP under
`/research/AAA/**` (read-only lab collateral).

---

## 6. Test/verification sprawl (low priority, mostly fine)

- **cocotb**: 30 active regression envs (in `cocotb/Makefile ENVS`), 3 off-regression
  skew/drift variants, 14 `debug/` harnesses. All real. Candidates to prune/re-pin:
  `wav_d2d_gpio_tx_prbs` (superseded by deps PHY checker), `tidelink_phy_align_calibrator`
  default test (fails post-merge — re-pin or move to debug), `tidelink_perf_congestion`
  (Phase-1 only). Heavy untracked build trees (`tidelink_top_pair*` ~106 GB) — reclaim
  with `git clean -fdX cocotb/`.
- **uvm**: 7 testbenches, all actively maintained, no committed artifacts. Leave as-is.

---

## 7. Submodule decision needed

`deps/tidelink-gpio-phy` (branch `feat/standalone-phy-bist`, `0fc5be01`) has
uncommitted RTL/TB/tcl changes + untracked logs. Before integration: commit & push
to the submodule branch and bump the pointer, **or** discard if local-only. The
integration target is the deskewed PHY — confirm which submodule commit is canonical
(see memory: `PLAN_TIDELINK_INTEGRATION.md` is authoritative).

---

## Suggested execution order

1. **Safe mechanical** (no judgment): `.gitignore` gaps, `git rm --cached` verdi files,
   `rm` working-tree scratch, delete `docs/_obs_raw/` + `agent_f_probe_dump_post_fix.log`.
2. **Doc consolidation** (the real work): author the 6 product docs by folding content,
   move the rest to `docs/archive/` with an indexed README, delete confirmed duplicates.
3. **Cosmetic/layout**: `flist/`→`flists/`, prune dead cocotb envs, `public/` check.
4. **Submodule**: resolve `deps/tidelink-gpio-phy` pointer.

Each step is independently committable.
