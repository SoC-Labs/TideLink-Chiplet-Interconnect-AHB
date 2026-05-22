# TideLink Branch & Tag Trim Plan

Generated: 2026-05-22 — analysis to converge the repo on `main`.

## Reference trunk

- `origin/main` = **35d248e** — the consolidated trunk (USE_CLKBUF 16/16 FPGA line +
  TSMC ASIC line + guards + RTL fixes #3/#4/#9/#16/#23). Submodule `origin/main` = 2f602d1.
- Local `main` = **94d5f99** = `origin/main` + 1 commit (`fpga/xdc: fix two latent
  constraint bugs surfaced by the msg gate`). Local `main` is a strict superset of
  `origin/main`, so classification below is done against **local `main`** (anything
  reachable from `origin/main` is also reachable from local `main`). Local `main` is
  one commit ahead of `origin/main` and should be pushed.

## Method

- Ancestry: `git merge-base --is-ancestor <branch> main`.
- Cherry-pick-equivalence: `git cherry main <branch>` plus per-commit
  `git patch-id --stable` lookups against a precomputed set of all `main` patch-ids,
  with **content confirmation** (`git diff main <tip> -- <file>`) for any commit whose
  patch-id did not match (context drift during cherry-pick can change a patch-id even
  when the work is fully present — this happened with `fix/bug16-hal-cosmetics`).
- Most `feat/*` and `fix/*` branches fork from the `feat/td-combined` / `release/v1.0-rc1`
  tip (**57c2810**) and carry exactly **one** headline commit on top; that single commit
  is what was (or wasn't) folded into `main`. The large raw "unique" counts (~85) are the
  shared pre-consolidation history that `main` was rebuilt from, NOT branch-specific work.

## Bucket legend

- **MERGED/FOLDED** — tip is an ancestor of `main`, or the branch's unique commit(s) are
  patch-equivalent / content-identical to commits already on `main`. SAFE TO DELETE.
- **THROWAWAY** — `bisect/*` lane-lock investigation branches; documented in
  `docs/LANE_LOCK_ROOT_CAUSE.md`. SAFE TO DELETE. (Auto-deleted by this run.)
- **UNIQUE-UNMERGED** — has real work not on `main` and not cherry-picked. KEEP / human decision.
- **KEEP-ALWAYS** — trunk, release artifacts, integration lineage, historical lineage.

---

## Branch classification

| Branch | Bucket | Unique commits (branch-specific) | Recommendation |
|---|---|---|---|
| main | KEEP-ALWAYS | — (trunk) | Keep. Push: local main = origin/main + 94d5f99 |
| release/v1.0-rc1 | KEEP-ALWAYS | release artifact (88 raw) | Keep (checked out as primary worktree; has origin) |
| release/v1.0-rc2 | KEEP-ALWAYS | ancestor of main | Keep (release artifact) — or human-delete if rc2 superseded |
| integ/td-unified-main | KEEP-ALWAYS | ancestor of main | Keep (checked out in td-merge worktree; pending XDC-fix push) |
| feat/td-combined | KEEP-ALWAYS | historical lineage (tip 57c2810) | Keep (lineage; has origin) |
| feat/clkfreq-check | MERGED/FOLDED | f88d4ba → FOLDED (main 9d0e967) | Delete-safe |
| feat/td-artifact-store | MERGED/FOLDED | 07fdcdd → FOLDED (main 06d6d8a) | Delete-safe |
| feat/verilator-lint-gate | MERGED/FOLDED | cb103ce → FOLDED (main 011de60) | Delete-safe |
| fix/deploy-provenance-guard | MERGED/FOLDED | 0e9cfe7 → FOLDED (main 5a9312a); 9f2bbab FOLDED | Delete-safe |
| fix/perf-width-truncation | MERGED/FOLDED | cb2cd26 → FOLDED (main b10c433) | Delete-safe |
| fix/xdc-declarative | MERGED/FOLDED | c6375eb → FOLDED (main 6b5b5ea) | Delete-safe |
| fix/deploy-script-robustness | MERGED/FOLDED | 9f2bbab → FOLDED (main d1b6dd0) | Delete-safe |
| fix/bug16-hal-cosmetics | MERGED/FOLDED | e412289 → patch-id differs but content CONFIRMED on main (28f1312; NUM_LANES guard, ENMNFU/USEPAR comments all present) | Delete-safe |
| feat/td-xdc-source-sync | MERGED/FOLDED | 024dc81 → FOLDED (git cherry `-`) | Delete-safe |
| feat/td-asic-determinism-docs | MERGED/FOLDED | b795b3f → all 4 files on main, diff=0 | Delete-safe |
| feat/calibrator-phase-sweep | MERGED/FOLDED | ancestor of main | Delete-safe |
| feat/credit-path-observability | MERGED/FOLDED | ancestor of main | Delete-safe |
| feat/td-determinism-integrated | MERGED/FOLDED | ancestor of main | Delete-safe |
| feat/td-idelay-propagate | MERGED/FOLDED | ancestor of main | Delete-safe |
| feat/td-idelay-slaveclk | MERGED/FOLDED | ancestor of main | Delete-safe |
| feature/tidelink-wlink-integration | MERGED/FOLDED | ancestor of main | Delete-safe (NOTE: has origin/ counterpart; delete local only) |
| strip-generalbus-irq | MERGED/FOLDED | ancestor of main | Delete-safe (NOTE: has origin/ counterpart; delete local only) |
| worktree-agent-a0e0c76e4dac7cd78 | MERGED/FOLDED | ancestor of main (→ c3b8d4e) | Delete-safe (agent scratch) |
| worktree-agent-a37f8bff7dea74917 | MERGED/FOLDED | ancestor of main (→ c3b8d4e) | Delete-safe (agent scratch) |
| worktree-agent-a8636b6f28bbf2b69 | MERGED/FOLDED | ancestor of main (→ c3b8d4e) | Delete-safe (agent scratch) |
| worktree-agent-aed9e63bc196f8aec | MERGED/FOLDED | ancestor of main (→ c3b8d4e) | Delete-safe (agent scratch) |
| worktree-agent-afcda9e78c3a14573 | MERGED/FOLDED | ancestor of main (→ c3b8d4e) | Delete-safe (agent scratch) |
| fix/calibrator-structural | UNIQUE-UNMERGED | 4504861 — replaces `unique case`→`case`+default in calibrator. main STILL has 2 `unique case` (lines 409, 541); fix ABSENT | KEEP — fold the structural fix or supersede |
| fix/bug10-sv-anti-pattern-allow-list | UNIQUE-UNMERGED | 7316a5f — vendor-IP allow-list in `cocotb/lint/sv_anti_pattern_lint.py`; ABSENT on main | KEEP — fold if lint allow-list still wanted |
| fix/bug24-watcher-path-migration | UNIQUE-UNMERGED | 06720f2 — `scripts/td-bisect-watcher.sh` (361 lines); ABSENT on main | KEEP — bisect tooling; fold or drop with bisect cleanup |
| fix/bug22-uvm-mask-strobe-fsm | UNIQUE-UNMERGED | 7ab9806 — UVM tests aligned to 2-word FIFO header (MAX_CREDITS-6); main still has `-5`. PARTIAL fix, not folded | KEEP — finish & fold (known partial) |
| feat/cocotb-robust-silicon-replication | UNIQUE-UNMERGED | 8d27ebb — `cocotb/sim_robust/` suite + `cocotb/lint/xdc_lint.py` (1640 lines); ABSENT on main | KEEP — substantial adversarial test suite |
| fix/ci-fpgahub-install | UNIQUE-UNMERGED | 77df87d — `.gitlab-ci.yml` install fpgahub from git URL; main still installs from relative `../fpgahub` | KEEP — decide CI install strategy |
| feat/test-credit-path-regression | UNIQUE-UNMERGED | 2a33c03, f1cd95c — 3 cocotb credit-path tests; all ABSENT on main | KEEP — fold test coverage |
| feat/td-calibrator-resweep | UNIQUE-UNMERGED | 797aa64, 2856c4f — T3 lottery + T3.2 S_HOLD cocotb validators; ABSENT on main | KEEP — fold test coverage |
| feat/test-calibrator-skew-window | UNIQUE-UNMERGED | 90750f6 — `cocotb/phy_align/test_calibrator_skew_window.py`; ABSENT on main | KEEP — fold test coverage |
| feat/i2c-autonomous-lock | UNIQUE-UNMERGED | 52471e5, 0ea3d08, e55c77b, 57b9d82, ec36ba8 — early i2c autoneg lineage. Autoneg IS broadly on main (d2f2e47 "auto negotiation support"), but these specific commits are not patch-equivalent | KEEP — human to confirm fully superseded before delete |
| feat/i2c-autonomous-lock-integ | UNIQUE-UNMERGED | 25 commits (52471e5…9f81947); i2c integration lineage; has origin/ counterpart (a092251) | KEEP — has remote; consolidation drew from here |
| feat/td-asic-determinism-docs | (see above, FOLDED) | — | — |
| feat/slow-clock-obs | UNIQUE-UNMERGED (experiment) | 634d161 — link clock 25→12.5 MHz timing experiment; ABSENT on main | KEEP/REVIEW — likely throwaway experiment |
| feat/td-bisect-a2-out | UNIQUE-UNMERGED (experiment) | c4de5b1 — bisect: disable IDELAYE2 to isolate regression; ABSENT on main | KEEP/REVIEW — bisect experiment misfiled as feat/* |
| worktree-agent-acec76b893b90a1e4 | UNIQUE-UNMERGED (experiment) | 51d0446 — DIAG lane0↔lane7 pin-swap localiser; ABSENT on main | KEEP/REVIEW — diag experiment in agent scratch branch |

---

## SAFE local-branch deletions (review, then run)

These are MERGED/FOLDED local branches whose work is confirmed on `main`.
NONE are checked out in a worktree. Branches that also exist on `origin/`
(`feature/tidelink-wlink-integration`, `strip-generalbus-irq`) are deleted
LOCALLY only — the remote ref is left untouched.

```sh
git branch -D \
  feat/clkfreq-check \
  feat/td-artifact-store \
  feat/verilator-lint-gate \
  fix/deploy-provenance-guard \
  fix/perf-width-truncation \
  fix/xdc-declarative \
  fix/deploy-script-robustness \
  fix/bug16-hal-cosmetics \
  feat/td-xdc-source-sync \
  feat/td-asic-determinism-docs \
  feat/calibrator-phase-sweep \
  feat/credit-path-observability \
  feat/td-determinism-integrated \
  feat/td-idelay-propagate \
  feat/td-idelay-slaveclk \
  feature/tidelink-wlink-integration \
  strip-generalbus-irq \
  worktree-agent-a0e0c76e4dac7cd78 \
  worktree-agent-a37f8bff7dea74917 \
  worktree-agent-a8636b6f28bbf2b69 \
  worktree-agent-aed9e63bc196f8aec \
  worktree-agent-afcda9e78c3a14573
```

(`worktree-agent-*` may need their stale worktrees pruned first: `git worktree prune`.)

## THROWAWAY — bisect/* (DELETED by this run)

20 branches, all documented in `docs/LANE_LOCK_ROOT_CAUSE.md`. Tip SHAs recorded for
recovery (`git branch <name> <sha>`):

```
bisect/A-xdc-only            2487bd6    bisect/L5-plus-bug4          f27dcf5
bisect/B-bd-build            7f8dc05    bisect/Sa-i2c-prescale       c00a914
bisect/B-bd-build-i2cpin     c064813    bisect/Sb-state-nxt-default  d03acc5
bisect/C-sub-bump            2914309    bisect/Sc-mark-debug-gate    8bc6051
bisect/D-control             8bc6051    bisect/Sd-i2c-stretch        f817a81
bisect/E-bug3-isolated       4b20843    bisect/Xi-idelay             2d04a18
bisect/F-bug4-isolated       211ebc6    bisect/Xp-pad                ce0e221
bisect/L1-xdc                6e2bb35    bisect/Xt-timing             cb071f1
bisect/L2-calib              a682c66    bisect/v1-RC-verify          fcf6b3b
bisect/L3-xdc-calib          66456cd
bisect/L4-plus-bug3          a68e755
```

---

## UNIQUE-UNMERGED — human decision required (DO NOT auto-delete)

Branches holding real work that is NOT on `main`. Listed with the work they hold:

| Branch | Unique work | Suggested action |
|---|---|---|
| fix/bug22-uvm-mask-strobe-fsm | 7ab9806 — UVM tests to 2-word FIFO header (main still `MAX_CREDITS-5`). Known PARTIAL fix | Finish + fold into main |
| fix/calibrator-structural | 4504861 — `unique case`→`case`+default + remove cross-process blocking assigns (synth-class fix) | Fold; main calibrator still has `unique case` |
| feat/cocotb-robust-silicon-replication | 8d27ebb — `cocotb/sim_robust/` adversarial suite + `cocotb/lint/xdc_lint.py` (~1640 lines) | Fold (valuable regression coverage) |
| fix/bug10-sv-anti-pattern-allow-list | 7316a5f — vendor-IP allow-list for sv_anti_pattern_lint | Fold if lint gate keeps the allow-list |
| fix/bug24-watcher-path-migration | 06720f2 — `scripts/td-bisect-watcher.sh` multi-root resolver | Fold or retire with bisect tooling |
| fix/ci-fpgahub-install | 77df87d — `.gitlab-ci.yml` git-URL fpgahub install vs main's relative path | Decide CI install strategy |
| feat/test-credit-path-regression | 2a33c03, f1cd95c — 3 credit-path cocotb tests | Fold test coverage |
| feat/td-calibrator-resweep | 797aa64, 2856c4f — T3 lottery + S_HOLD cocotb validators | Fold test coverage |
| feat/test-calibrator-skew-window | 90750f6 — skew-window contract test | Fold test coverage |
| feat/i2c-autonomous-lock | 52471e5,0ea3d08,e55c77b,57b9d82,ec36ba8 — early i2c autoneg lineage (autoneg itself IS on main) | Confirm superseded, then delete |
| feat/i2c-autonomous-lock-integ | 25-commit i2c integration lineage (has origin/) | Keep until consolidation confirmed complete |
| feat/slow-clock-obs | 634d161 — 25→12.5 MHz timing experiment | Likely throwaway; confirm + delete |
| feat/td-bisect-a2-out | c4de5b1 — IDELAYE2-off bisect experiment (misfiled feat/*) | Throwaway-class; confirm + delete |
| worktree-agent-acec76b893b90a1e4 | 51d0446 — DIAG lane0↔lane7 pin-swap localiser | Diag experiment; confirm + delete |

---

## Tags

| Tag | Points at | On main? | Assessment | Recommendation |
|---|---|---|---|---|
| integ-step1-base | 794313e | yes | Intermediate consolidation step (obsolete pointer) | Human-delete (history captured in main) |
| integ-step2 | 8af80d7 | yes | Intermediate consolidation step | Human-delete |
| integ-step3 | a08ac30 | yes | Intermediate consolidation step | Human-delete |
| integ-step4 | 715c058 | yes | Intermediate consolidation step | Human-delete |
| integ-step5 | bc80f6b | yes | Intermediate consolidation step | Human-delete |
| integ-step6 | 701e203 | yes | Intermediate consolidation step | Human-delete |
| v1-RC | fcf6b3b | no | Pre-consolidation "v1-RC strategic pivot" pointer | Keep or human-delete (superseded by v1.0) |
| v1.0 | 3ac342a | no | v1.0-rc1 release bundle | KEEP — meaningful release tag |

No tags deleted by this run (rules: tags left for human action).

---

## Summary of counts

- KEEP-ALWAYS: 5 (main, release/v1.0-rc1, release/v1.0-rc2, integ/td-unified-main, feat/td-combined)
- MERGED/FOLDED (safe local delete, not auto-run): 22
- THROWAWAY bisect/* (auto-deleted this run): 20
- UNIQUE-UNMERGED (human decision): 14
- Tags: 8 (6 obsolete integ-step pointers, v1-RC superseded, v1.0 keep)
