# TideLink v1-RC — Strategic Pivot 2026-05-21

## What this document says

After 13 rebuilds and ~10 HW tests over ~14 hours, we could not bisect
the lane-0+7 lock regression to a single commit. The MORNING bitstream
(at `/tmp/tidelink_deploy/` on mapstone-dev, dated 2026-05-20 11:10)
**continues to lock 14+/16 reliably** with FCSM advancing — verified
multiple times today including an end-of-session sanity check at 03:00.

Every rebuild from any state in our session's history gives at best
12/16 deterministic with FCSM stuck at IDLE, even with sub at the same
`de44db6` HEAD as morning's working build. The exact RTL/IP-cache/Vivado
state difference that makes morning's bitstream work could not be
isolated within available time.

**v1-RC artifact**: the morning's pre-built bitstream at
`mapstone-dev:/tmp/tidelink_deploy/tidelink{,-flip}.bin` (md5
`e2bd4d9f...` master, `0f752a05...` flip).

**v1-RC tag (local-only)**: applied to `feat/td-combined` at branch tip
post-revert (where W9/V7 XDC is active and Bug #3 structural fix is
in tree).

## What WAS achieved this session — all in tree at v1-RC

### RTL fixes (silicon-validated where applicable)
- **Bug #3 structural fix** (`a510bae` sub): added `default:` clause
  on autoneg state_nxt case. Same class as `be5eed2`'s txn_step_nxt fix.
  ASIC-portable; no synthesis attributes.
- **nego_driving decouple** (`467b889` sub, in lineage): autoneg works
  on silicon (verified: master wins, slave loses, both `role_locked=1`,
  `nego_done=1`, I2C bus active).
- **be5eed2 txn_step_nxt latch fix** (in sub lineage).
- **`tb_early_exit_force_q` reset-driven init** (`1b9c2d9`): fixes 2
  calibrator-T3 sim X-prop failures introduced by `c140573`'s HAL fix.
- **Sticky-once-locked `SWI_LANE_STATUS`** (`50d394f`): debug
  instrumentation for the lane-lock regression hunt (proves lanes 0+7
  never transiently lock).
- **RDL preprocessor regex fix** (`7fd12a4`): recovered 11 register
  fields that were being silently dropped from
  `tidelink_regs.generated.h` due to a trailing-comment regex bug.
- **`tidelink_test_wrappers.c` static_assert fix** (`91af70d`).

### Lint
- **HAL-clean** (`c140573`) in TideLink RTL scope: 0 errors. Vendor IP
  errors scoped to per-subdir waivers (no blanket `-nocheck`).
- **Verilator-clean** (838 warnings, 77 in `src/rtl/`, 0 errors).

### Documentation
- `docs/ASIC_HARD_IP_INVENTORY.md` (reconciled to 100 MHz line rate)
- `docs/ASIC_POWER_PLAN.md` (UPF, 4× active power for 100 MHz)
- `docs/ASIC_DFT_PLAN.md`
- `docs/GPIO_PHY_ARCHITECTURE.md` (dual-rate FPGA/ASIC tables)
- `docs/SHORTCOMINGS.md`
- `docs/ECC_REENABLE_REGRESSION.md`
- `docs/HAL_LINT_REPORT.md` + `RTL_LINT_REPORT.md`
- `docs/LANE_LOCK_REGRESSION_ANALYSIS.md` (the lane-0+7 deep-dive)
- `docs/LANE_0_7_DEEP_DIVE.md` (XDC + crosstalk hypothesis)
- `docs/REGRESSION_CANDIDATE_HUNT.md` (morning-vs-now diff hunt)
- `docs/V2_DEFERRALS.md`
- `docs/CI_AUDIT.md` + `CI_FPGA_PLAN.md` + `CI_LINT_PLAN.md` + `CI_COCOTB_PLAN.md`

### Cocotb
- 8 stale top-level test copies consolidated (subdir copies are
  authoritative).
- New `test_hw_repro_probe_seq.py` integrated and fixed for the local
  tb_top.
- ECC re-enable sim regression: 4/4 PASS.

### CI plans (proposals, not yet wired)
- 4 plans landed as `docs/CI_*_PLAN.md`. Existing pipeline audit
  shows last 10 runs all red; `fpga-pair` gated off dev branches +
  `allow_failure: true`. Plans are ready for integration in v2.

### Submodule (`deps/axi-chiplet-controller`)
- Current pin: `a510bae` on `feat/bug3-structural-fix` (= de44db6 +
  cherry-pick 467b889 + cherry-pick be5eed2 + structural default
  state_nxt assignment).
- All silicon-autoneg fixes in tree.

## Known regression (v2 Bug #4)

Any rebuild from the current parent + any sub combination produces:
- Lane lock 12/16 deterministic (lanes 0+7 never lock)
- `cal_done=0`, `fcsm=0` (FCSM stuck at IDLE)
- Autoneg still works (`role_locked=1`, `nego_done=1`)
- I2C bus active
- AHB end-to-end NOT tested (link layer not advancing)

The morning's bitstream (built BEFORE this session began) does not
exhibit this regression and remains the v1-RC artifact.

**v2 Bug #4 candidates** (no single-commit bisect possible within
session time):
1. Vivado IP cache / build-environment drift
2. BD-generation timing dependent on commit history
3. Sub-Wlink Chisel-regen artifact difference
4. Interaction between mark_debug attrs (now reverted) and BD
   construction
5. Some untracked file in the worktree that persists across builds

Unblock recipe: full from-scratch worktree rebuild (delete
`imp/fpga/project` entirely, reclone submodule), or get an old-but-
known-good Vivado project checkpoint to anchor from.

## What to do now

1. **Tag**: `git tag -a v1-RC -m "..." HEAD` — local only, never push.
2. **Use morning's bitstream**: `mapstone-dev:/tmp/tidelink_deploy/`
   files for any v1 demo or test session.
3. **Defer the rebuild fix** to v2 — capture as Bug #4 in
   `docs/V2_DEFERRALS.md`.
4. **DO NOT delete the morning's bitstream from `/tmp/tidelink_deploy/`
   on mapstone-dev** — it is the v1-RC binary artefact.
