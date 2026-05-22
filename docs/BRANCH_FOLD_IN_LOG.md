# TideLink Branch Fold-In Log

Date: 2026-05-22
Operator: dam1n19 (David Mapstone)
Baseline `main` HEAD: `9e84ebe` (= origin/main)
Submodule `deps/axi-chiplet-controller` pin: `2f602d1` (unchanged throughout)

## Goal

Fold the SAFE unique-unmerged branches (test / lint / CI / coverage improvements
with ZERO hardware-regression risk) into `main` via **cherry-pick** (NEVER merge).
The candidate branches sit on the old rc1 lineage that contains commit `51b5169`
(the USE_CLKBUF *strip* that caused the 0/16 regression); merging any of them
would re-pull the strip and destroy the 16/16 fix. Only the branch-specific
headline commits were cherry-picked.

Reference analysis: `docs/BRANCH_TRIM_PLAN.md`.

## Method

For each branch the unique headline commit(s) were identified from the trim plan,
content-verified to touch only test / cocotb / uvm / lint / ci / scripts / docs
files (no `src/rtl/*.sv`, no submodule pointer), then cherry-picked with `-x`.
After every cherry-pick the diff was re-checked for any `src/rtl/*.sv` or `deps/`
change before proceeding.

## Folded (9 commits, new `main` HEAD = `7e27b84`)

| New SHA | Source SHA | Branch | Files |
|---|---|---|---|
| 204d350 | 8d27ebb | feat/cocotb-robust-silicon-replication | Makefile + cocotb/lint/{Makefile.synth,xdc_lint.py,test_*} + cocotb/sim_robust/* (1640 lines) |
| 2b5bc34 | 7ab9806 | fix/bug22-uvm-mask-strobe-fsm | 10 UVM test files (2-word FIFO header / MAX_CREDITS-6) |
| 3cec21b | 06720f2 | fix/bug24-watcher-path-migration | scripts/td-bisect-watcher.sh |
| 91e7d3e | 77df87d | fix/ci-fpgahub-install | .gitlab-ci.yml (git-URL fpgahub install) — trivial conflict resolved to branch version |
| 76b65dd | 2a33c03 | feat/test-credit-path-regression | cocotb/wlink_pair/test_credit_handshake_end_to_end.py + test_fcsm_io_rx_reset_sticky.py |
| 081c9b9 | f1cd95c | feat/test-credit-path-regression | cocotb/wlink_pair/test_asymmetric_rx_credit_block_recovery.py |
| 54e7ee3 | 797aa64 | feat/td-calibrator-resweep | cocotb/phy_align/test_t3_staggered_lottery.py |
| 187fa9c | 2856c4f | feat/td-calibrator-resweep | cocotb/phy_align/test_t32_shold_peerhold.py |
| 7e27b84 | 90750f6 | feat/test-calibrator-skew-window | cocotb/phy_align/README.md + test_calibrator_skew_window.py |

`cocotb/sim_robust/tb_calibrator_robust.sv` is a cocotb *testbench*, not synthesized
design RTL (it lives under `cocotb/`, not `src/rtl/`).

### Conflicts resolved
- `fix/ci-fpgahub-install` (77df87d): one trivial content conflict in
  `.gitlab-ci.yml` — the relative-path vs git-URL fpgahub install. Resolved to the
  branch's git-URL install (the purpose of the branch). CI-only file.

## Skipped + flagged

| Branch | Source SHA | Reason |
|---|---|---|
| fix/bug10-sv-anti-pattern-allow-list | 7316a5f | **Irresolvable modify/delete conflict.** The commit modifies `cocotb/lint/Makefile` and `cocotb/lint/sv_anti_pattern_lint.py`, but neither file is tracked on `main` (consolidation removed them). Cherry-pick produced a modify/delete conflict; per guardrails (non-trivial conflict on a supposedly-safe branch) the pick was aborted and the branch skipped. To fold later, the base lint files must first be re-introduced or the allow-list re-authored against current `main` lint tooling. |

## Excluded by instruction (HW-regression risk / unclear) — NOT touched
fix/calibrator-structural (4504861, synthesized calibrator RTL),
feat/credit-path-observability (0cf9117, synthesized APB observability RTL),
feat/i2c-autonomous-lock*, feat/calibrator-phase-sweep, feat/slow-clock-obs,
feat/td-bisect-a2-out, worktree-agent-*.

## Verification (post-fold, HEAD = 7e27b84)

- Files touched since baseline `9e84ebe`: ONLY
  .gitlab-ci.yml, Makefile, cocotb/**, scripts/td-bisect-watcher.sh, uvm/**/tests/*.sv.
- `git diff --name-only 9e84ebe..7e27b84 | grep -E '^(src/rtl/.*\.sv|deps/)'` → **NONE**.
- `grep -c USE_CLKBUF deps/axi-chiplet-controller/logical/wlink/WavD2DGpioRx.v` → **12** (unchanged).
- Submodule `deps/axi-chiplet-controller` HEAD → **2f602d1** (unchanged; no parent-repo pointer change).

No synthesized RTL and no submodule pin changed, so the 100% 16/16 hardware
lane-lock result cannot have regressed.
