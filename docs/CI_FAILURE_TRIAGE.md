# TideLink CI Failure Triage

**Branch under audit:** `feat/td-combined` @ `51b5169` (pushed; pipeline `#17699 / iid 188` queued at 2026-05-21 07:59 UTC, pending at time of write).
**Companion pipelines on `main` @ `6493e56`:** `#17698` (running).
**Worktree at time of write:** `/home/dam1n19/td_idelay_wt`, local HEAD `16302d2` (4 commits ahead of pushed tip — see §3).
**Source for this triage:** GitLab REST API `pipelines/<id>/jobs` + `jobs/<id>/trace` for pipelines `17696, 17695, 17691, 17683, 17655, 17653, 17652, 17644, 17633` (the last 9 completed pipelines on origin).

---

## 1. Headline

**Pass/fail of the last 10 completed pipelines (iid 159…186):** 0 pipelines green at completion. 5 explicitly `failed`, the remainder `canceled` (dev push-over-push). The failure mode is **identical across every red pipeline**: the same 12 jobs fail and the same 10 pass. This is therefore not a flaky-test problem but a single root cause repeated.

| Job                       | Stage       | allow_fail | Latest result | Duration | Failure mode      |
|---------------------------|-------------|------------|---------------|----------|-------------------|
| clone                     | setup       | no         | PASS          | 47 s     | — |
| preflight                 | setup       | no         | PASS          | 8 s      | — |
| strip-generalbus-check    | lint        | no         | PASS          | 10 s     | — |
| hal-lint                  | lint        | no         | PASS          | 26 s     | — |
| spyglass-cdc              | lint        | no         | PASS          | 90 s     | — |
| uvm-ptp-chain             | system      | yes        | PASS          | 27 s     | — |
| uvm-ptp-stress            | system      | yes        | PASS          | 28 s     | — |
| uvm-top-system            | new_module  | yes        | PASS          | 350 s    | — |
| dashboard                 | pages       | no         | PASS          | 21 s     | — |
| cleanup                   | cleanup     | no         | PASS          | 18 s     | — |
| **cocotb-regression**     | regression  | no         | **FAIL**      | 21 s     | INFRA (pip)        |
| **cdriver-regression**    | regression  | no         | **FAIL**      | 20 s     | INFRA (pip)        |
| **cocotb-fc-adapter**     | new_module  | no         | **FAIL**      | 19 s     | INFRA (pip)        |
| **cocotb-top**            | new_module  | no         | **FAIL**      | 20 s     | INFRA (pip)        |
| **cocotb-ptp**            | new_module  | no         | **FAIL**      | 20 s     | INFRA (pip)        |
| **cocotb-wlink-pair**     | new_module  | yes        | **FAIL**      | 20 s     | INFRA (pip)        |
| **cocotb-system**         | system      | yes        | **FAIL**      | 20 s     | INFRA (pip)        |
| **uvm-regression**        | regression  | no         | **FAIL**      | 69 s     | TEST (stall_test)  |
| **uvm-fc-adapter**        | new_module  | no         | **FAIL**      | 29 s     | TEST (scoreboard)  |
| **uvm-integration**       | new_module  | no         | **FAIL**      | 65 s     | TEST (AHB protocol)|
| **uvm-system**            | system      | yes        | **FAIL**      | 3600 s   | TIMEOUT (test loop)|
| **fpga-pair**             | fpga        | yes        | **FAIL**      | (n/a)    | STALE (allow_fail) |
| coverage-merge            | coverage    | no         | SKIPPED       | —        | upstream needs failed |
| synth-fifo/top/top-full   | synthesis   | yes        | SKIPPED       | —        | upstream needs failed |
| formality-lec             | synthesis   | yes        | SKIPPED       | —        | upstream needs failed |

## 2. Failing jobs — root causes

### Category A — INFRA: every cocotb job dies on the same pip-install line  (7 jobs)

The shared `before_script` in `.vcs_cocotb_setup` (`.gitlab-ci.yml:215`) runs:

```bash
python3 -m pip install --user -e "$WORK_DIR/../fpgahub" --quiet
```

with the error
```
/home/dwn1c21/builds/tidelink/17696/../fpgahub should either be a path to
a local project or a VCS url beginning with svn+, git+, hg+, or bzr+
```

The line was added in commit `c619be4 refactor(cocotb): de-duplicate hal_bridge.py -> fpgahub_sdk.testkit` (now on `main` + `feat/fpga-flow`). The CI runner does **not** have a sibling `../fpgahub` checkout next to the tidelink build dir — the path is **dwn1c21-local only**. The whole `step_script` exits with code 1 before `make` is even invoked. Every job that uses `*vcs_cocotb_setup` (7 of the 12 reds) dies in ~20 s in the `before_script`, never reaches simulation, never produces a `results.xml`.

**Already fixed on `feat/td-combined` @ `51b5169`** — the line was REMOVED on that branch (see §3). Pipeline 17699 should not exhibit this failure once it runs, *because* cocotb/common/hal_bridge.py still ships in-tree on `feat/td-combined` (no `fpgahub_sdk` import anywhere under `cocotb/`).

### Category B — TEST: 3 real UVM failures (3 jobs, 1 `allow_failure`)

These reach the simulator and report real `UVM_ERROR`s:

- **`uvm-regression`** (`uvm/tidelink/tests/tidelink_stall_test.sv:69, 109`): "CREDIT_COUNT mismatch after write / gapped write" — same family as the `MASK_FSM` defects the sister agent on `docs/MASK_FSM_DEFAULTS.md` is investigating.
- **`uvm-fc-adapter`** (`tidelink_fc_adapter_scoreboard.sv:103, 117, 213…224`): "Unexpected FC TX", "22 predicted FC TX items never observed", "6 predicted RX FIFO items never observed". Scoreboard predicts traffic the DUT does not produce — Class A symptom of the masked-strobe FSM bug class.
- **`uvm-integration`** (`svt_err_check_stats.svp:583`, AHB VIP): repeated `register_fail:AMBA:AHB_COMMON:zero_wait_cycle_okay` — DUT asserts `hready=0` during an IDLE transfer. This is an AHB-protocol bug on a TideLink slave port, not a VIP misconfiguration.

### Category C — TIMEOUT: `uvm-system` (1 job)

`uvm-system` ran for the full 3600 s wall-clock and was killed by the runner. The log shows ~258–686 demoted `UVM_ERROR`s per sub-test plus repeating `[TEST] CREDIT_COUNT mismatch` from `test_single_packet.sv:62` and `test_credit_exhaustion.sv:78`. Same defect family as Category B — but the test loop does not exit, it just keeps retrying and burns the budget. `allow_failure: true`, so this is advisory; but it pins a `vcs` runner for an hour every push.

### Category D — STALE: `fpga-pair` (1 job)

Latest trace is empty (`failure_reason=stuck_or_timeout_failure`). `allow_failure: true`, gated to `main` / `feat/fpga-flow` / scheduled / web (line 677 ff). On `feat/fpga-flow` it most often goes `failed` because the runner could not acquire a board — see the open Bug 5 in `BRINGUP_REPORT.md`. Not blocking; not informative either.

### What is NOT broken

- `clone` + `preflight` (env+EDA) pass. The runner image is fine.
- `hal-lint` + `spyglass-cdc` + `strip-generalbus-check` pass. Lint is healthy.
- `uvm-ptp-chain` / `uvm-ptp-stress` / `uvm-top-system` pass — confirming the **UVM toolchain itself** works; only specific tests fail.
- `dashboard` runs `when: always` and ships HTML; this is why the wiki has been advertising green-ish metrics while the CI is mostly red.

## 3. Cross-check vs. recent in-flight commits

| Commit | Title | On origin/feat/td-combined? | Predicted impact on CI |
|--------|-------|------------------------------|------------------------|
| `7fd12a4` | rdl: fix dynamic hw-property assignment for systemrdl-compiler v1.x | **NO** (only on local HEAD) | Should unblock `cocotb-regression` for envs that pre-compile RDL (e.g. `tidelink_ahb`) — but blocked by the bigger pip-install failure upstream. |
| `91af70d` | cocotb: fix tidelink_test_wrappers.c _Static_assert (0x090 -> 0x120) | **NO** (only on local HEAD) | Removes the `_Static_assert` cascade that previously failed `cdriver-regression`; not visible in the current red because pip dies first. |
| `c140573` | lint: HAL-clean v1-RC — rename LOCAL_LINK_STATE_W | reverted in bisect, re-applied as `2b5b6e5` on local HEAD; **not on origin** | Removes the HAL VERCAS error reported under hal-lint; hal-lint already passes today so this is paper-fix until VERCAS strict mode is gated. |
| `4471be1` | cocotb Phase D — sv_anti_pattern_lint added | **YES** (on `feat/td-combined`) | New file `cocotb/lint/sv_anti_pattern_lint.py`; **not yet wired into `.gitlab-ci.yml`** — does nothing in CI until a job is added. |
| `a55d346` (their structural bug-3 fix in `axi-chiplet-controller`) | Submodule | submodule pin not yet bumped on origin | Will move once the in-flight bump lands; no CI job today verifies submodule SHA. |

**Net:** of the 5 session commits, only one (`4471be1`) is actually on the pushed tip and it has zero CI effect because no job invokes the new linter. The pip-install regression that lights up the entire cocotb fleet **is already fixed on `feat/td-combined`** — the line is gone in `.gitlab-ci.yml@51b5169`. The four UVM/TEST failures (Categories B+C) are **not** addressed by any of the session commits and will repeat on the just-queued pipeline 17699.

## 4. Severity triage

| Sev | Category | Jobs | Action |
|-----|----------|------|--------|
| **BLOCKING** | INFRA | `cocotb-regression`, `cdriver-regression`, `cocotb-fc-adapter`, `cocotb-top`, `cocotb-ptp` | Already fixed on `feat/td-combined` — verify pipeline 17699 once it runs. Backport the `.gitlab-ci.yml` change to `main` immediately. |
| **BLOCKING** | TEST | `uvm-regression`, `uvm-fc-adapter`, `uvm-integration` | Real defects (CREDIT_COUNT / FC-TX scoreboard / AHB `zero_wait_cycle_okay`). All cluster in the masked-strobe FSM family currently being chased by the FSM-trace + MASK_FSM_DEFAULTS sister agents. Triage there. |
| **WORKING-AS-DESIGNED** | TIMEOUT | `uvm-system` | `allow_failure: true`. Burns 1 h of runner per push. Suggest splitting into <300 s buckets or `interruptible: true` + 30-minute cap until the underlying credit bug is fixed. |
| **WORKING-AS-DESIGNED** | STALE | `fpga-pair` | `allow_failure: true`, board-acquire flaky. Leave alone until `feat/fpga-flow` lease-grant fix lands. |
| **STALE** | — | `cocotb-system`, `cocotb-wlink-pair` | Both `allow_failure: true`. With pip-install fixed they should run; if they still red with real test failures, move out of `allow_failure` once Class A FSM bugs are resolved. |

## 5. Top 5 fixes — ranked impact/effort

| Rank | Fix | Impact | Effort | Status |
|------|-----|--------|--------|--------|
| 1 | **Backport pip-install removal from `feat/td-combined` to `main`** | Restores ALL 7 cocotb jobs across `main`, `feat/fpga-flow` and any branch that rebases off `main`. Highest blast radius. | 1-line edit + verify pipeline 17698 (running) | ALREADY in `feat/td-combined`; just needs to land on `main` via MR |
| 2 | **Wire `cocotb/lint/sv_anti_pattern_lint.py` into a new `sv-antipattern-lint` lint stage job** | Surfaces the I2C-trilogy class of bugs (and the 3 Class A UVM failures in §2-B) BEFORE they reach UVM. <30 s runtime. | small new job in `.gitlab-ci.yml`, no new tooling | not yet wired (file landed in `4471be1`) |
| 3 | **Add `rdl-check` job** (run `scripts/rdl2c.py` over `src/rdl/*.rdl`, diff against committed `*_regs.generated.h`) | Catches the silent 11-field regex regression that `7fd12a4` had to chase by hand. ~10 s. | <40 lines of yml | not yet wired (planned in `docs/CI_AUDIT.md §6/4`) |
| 4 | **Cap `uvm-system` at 30 min, `interruptible: true`, and split tests into 3 sub-jobs** | Stops the 1 h runner pin per push. Makes the credit-mismatch failure category surface in 1/3 the time. | 30-line yml refactor | open |
| 5 | **Add `workflow:` block to suppress duplicate MR+push pipelines + add a Verilator `--lint-only` fast-PR gate** | Halves runner usage; surfaces X-prop / multi-driver issues in <60 s on MR. | medium (Verilator preset + workflow rules) | open (per `docs/CI_LINT_PLAN.md`) |

## 6. Concrete `.gitlab-ci.yml` patch — Fix #1 (highest impact)

The remediation is **already present** on `feat/td-combined` but missing on `main`. Suggested patch to apply to `main`:

```diff
--- a/.gitlab-ci.yml
+++ b/.gitlab-ci.yml
@@ -218,11 +218,6 @@
     - python3 -m pip uninstall tidelink -y --quiet 2>/dev/null || true
     - python3 -m pip install --user --no-deps -e "$WORK_DIR/python" --quiet
     - find "$WORK_DIR" -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
     - python3 -m pip install --user cocotb cocotbext-ahb systemrdl-compiler --quiet
-    # fpgahub-sdk provides fpgahub_sdk.testkit.HALBridge (Phase 7B): the
-    # byte-identical de-duplicated replacement for the old copy-pasted
-    # cocotb/common/hal_bridge.py. Editable local path install (the SDK
-    # is a sibling workspace repo, not yet published to an index).
-    - python3 -m pip install --user -e "$WORK_DIR/../fpgahub" --quiet

 .vcs_uvm_setup: &vcs_uvm_setup
   before_script:
```

Because `cocotb/common/hal_bridge.py` is still tracked in-tree on `feat/td-combined`, removing the install line does NOT break any cocotb test. If the dedup-to-`fpgahub_sdk` direction is desired long-term, the correct fix is one of:

a. Ship `fpgahub-sdk` to the runner's pre-installed venv (image change, not yml change), OR
b. `pip install fpgahub-sdk` from an internal index (PyPI / Nexus), OR
c. `git clone fpgahub` into a known on-runner path inside `preflight` and adjust the relative path. (Today's CI ASSUMES the runner has it pre-cloned next to `tidelink/`, which is true on dwn1c21's dev box but not on the CI bot's `builds/` dir.)

Option (a) is the cleanest for v1-RC; option (c) is the cheapest stopgap. Either way, do NOT re-add the current `--user -e ../fpgahub` line.

## 7. What to watch on pipeline 17699 (just-queued)

When pipeline 17699 (`feat/td-combined`, sha `51b5169`) finishes, predict:

- **All 7 cocotb jobs should now reach `make` / `cocotb`** because the bad pip line is gone. They will then either PASS or expose new real-DUT failures previously masked by the infra failure. Either outcome is a strict improvement; the prior 9 reds were uninformative.
- **`uvm-regression`, `uvm-fc-adapter`, `uvm-integration`** are still expected to RED — those are real test failures, not infra; no source change has landed that addresses them.
- **`uvm-system`** still expected to TIMEOUT at 3600 s — same reason.
- **`fpga-pair`** is `rules:`-skipped on `feat/td-combined` (gating only `main`/`feat/fpga-flow`/schedule/web), so the job will not show up at all.
- **Counts to expect at completion:** 5 reds remaining (3 UVM + 1 TIMEOUT + dashboard `when: always` PASS), down from 12.

If pipeline 17699 returns 12 reds again, the diagnosis above is wrong and the next step is to fetch its trace and re-triage. If it returns 5 reds the diagnosis is confirmed and §5 ranks 2–5 become the next-week backlog.

---

*Generated 2026-05-21 from API queries against `git.soton.ac.uk/api/v4/projects/14703`.
No source files were modified — proposed diff in §6 is a patch suggestion only.*
