# TideLink CI Pipeline Audit

**Branch:** `feat/td-combined` @ `1b9c2d9` &middot; **Date:** 2026-05-20
**Source:** `.gitlab-ci.yml` (950 lines) + `ci/*` (7 helpers) + `fpga/fpgahub.toml`
**Remote:** `git@git.soton.ac.uk:soclabs/tidelink.git` (project id 14703)

---

## 1. Stages and jobs

The pipeline has 10 stages and (per the live remote) **26 jobs**. The yml in
this worktree defines 24; the live pipeline at iid 168 (pipeline 17655) also
shows `formality-lec` (synthesis) which is not in this worktree's yml — it is
either added on `main`/another branch or stripped here. Everything except
`fpga-pair` runs on every push (no `rules`, no `only/except`, no MR-only
filter, no `workflow:` block). There are no scheduled-only or manual jobs.

| Stage       | Job                       | Trigger                  | allow_fail | Notes |
|-------------|---------------------------|--------------------------|------------|-------|
| setup       | `clone`                   | every push               | no         | Clones + recurses + clones PHC sidecar |
| setup       | `preflight`               | every push               | no         | EDA-path + binary sanity check |
| lint        | `strip-generalbus-check`  | every push               | no         | `ci/check_strip_generalbus.sh` |
| lint        | `hal-lint`                | every push               | no         | Cadence HAL, `make lint-standalone` + `lint-each` |
| lint        | `spyglass-cdc`            | every push               | no         | SpyGlass CDC |
| regression  | `cocotb-regression`       | every push               | no         | `make -C cocotb coverage` (all envs) |
| regression  | `cdriver-regression`      | every push               | no         | C-driver-in-the-loop on `tidelink_ahb` |
| regression  | `uvm-regression`          | every push               | no         | 4 UVM tests `uvm/tidelink` |
| new_module  | `cocotb-fc-adapter`       | every push               | no         | 24 tests |
| new_module  | `cocotb-top`              | every push               | no         | 14 tests |
| new_module  | `uvm-fc-adapter`          | every push               | no         | 5 tests |
| new_module  | `uvm-integration`         | every push               | no         | 3 tests |
| new_module  | `uvm-top-system`          | every push               | **yes**    | curated 10 tests, env stabilising |
| new_module  | `cocotb-ptp`              | every push               | no         | PHC sidecar required |
| new_module  | `cocotb-wlink-pair`       | every push               | **yes**    | 6 tests, env stabilising |
| system      | `cocotb-system`           | every push               | **yes**    | 25 stress tests |
| system      | `uvm-system`              | every push               | **yes**    | 12 stress tests |
| system      | `uvm-ptp-stress`          | every push               | **yes**    | 2 tests |
| system      | `uvm-ptp-chain`           | every push               | **yes**    | chain tests |
| fpga        | `fpga-pair`               | **rules-gated** (see §3) | **yes**    | Real Pynq-Z2 pair via fpgahub |
| synthesis   | `synth-fifo`              | needs cocotb-regression  | **yes**    | DC, `tidelink` + `tidelink_fc_adapter` |
| synthesis   | `synth-top`               | needs cocotb-regression  | **yes**    | DC, blackboxed XHB500/Wlink |
| synthesis   | `synth-top-full`          | needs cocotb-regression  | **yes**    | DC, full top with XHB500+Wlink |
| coverage    | `coverage-merge`          | needs many               | (implicit) | `urg` merge of all VDBs |
| pages       | `dashboard`               | needs many; `when: always`| no        | HTML + Markdown wiki push |
| cleanup     | `cleanup`                 | `when: always`            | no        | `rm -rf $WORK_DIR` |

**Stale logic / TODOs:** none in the yml (zero `TODO`/`FIXME` comments).
Soft markers: line 446 calls out "curated TESTS list ... allow_failure while
the env stabilises" for `uvm-top-system`; line 504/672 similar wording for
`cocotb-wlink-pair` and `fpga-pair`. These are not stale per se but signal
known fragility. Stage 7/8 are double-numbered in comments (synthesis is
labelled "Stage 7" *and* coverage is "Stage 7"; dashboard is "Stage 8";
cleanup is "Stage 9"). The `MERGE_REQUEST` source is never mentioned, so MR
pipelines run nothing differently than branch pushes.

## 2. Jobs by category

- **Build (RTL/FPGA/ASIC):**
  - ASIC synth = `synth-fifo`, `synth-top`, `synth-top-full` (DC only, all `allow_failure`).
  - FPGA bitstream = **only inside `fpga-pair` via fpgahub** (steps `build_z2_pair_all` + `build_z2_pair_flip_all` from the manifest). No standalone "build bitstream and archive" job exists.
  - Standalone RTL elab = none beyond what HAL/SpyGlass/VCS-compile do as a side-effect.

- **Sim:**
  - cocotb = `cocotb-regression` (umbrella, 16 envs hard-coded in `after_script`), `cdriver-regression`, `cocotb-fc-adapter`, `cocotb-top`, `cocotb-ptp`, `cocotb-system`, `cocotb-wlink-pair` (7 jobs total).
  - UVM = `uvm-regression`, `uvm-fc-adapter`, `uvm-integration`, `uvm-top-system`, `uvm-system`, `uvm-ptp-stress`, `uvm-ptp-chain` (7 jobs total).
  - Lint = `hal-lint` (HAL, Cadence Xcelium), `spyglass-cdc` (Synopsys CDC).
  - **No Verilator job. No HAL-lint MR-gating. No rdl2c.py syntax check.**

- **HW (touches a real board):** `fpga-pair` only.

- **Reports:** `coverage-merge` (URG), `dashboard` (HTML + wiki push), `parse_ppa.py` (consumed by dashboard).

- **Utility:** `strip-generalbus-check`, `preflight`, `cleanup`.

## 3. What's broken / non-functional today

- **Mass red on `cocotb-regression`** in the last ~10 pipelines (iid 159–172). Every regression / new_module / system cocotb job has been failing on `feat/i2c-autonomous-lock-integ` since 2026-05-19. `feat/fpga-flow` tip (iid 159) shows the same pattern — all 12 sim jobs red, dashboard still publishes (because it's `when: always`). The CI is *running* but *almost nothing is passing*.

- **`fpga-pair` is rules-gated to `main` / `feat/fpga-flow` / scheduled / web only** (lines 677–681). It does **not** run on `feat/td-combined`, `feat/td-idelay-slaveclk`, `feat/i2c-autonomous-lock-integ`, or any MR. Every consolidated bring-up branch silently skips real-board CI.

- **Hard-coded user/research paths** (line 44–47): `/research/AAA/ip_library/...` and `/research/AAA/.../BP210/...` for the cmsdk_fpga_sram workaround. These are runner-local; any new runner without this NFS mount fails preflight.

- **EDA paths pinned to `/eda/synopsys/2022-23/`** (lines 35–42). When the site upgrades to 2024-xx the entire pipeline breaks at preflight.

- **`cocotb-regression`'s `after_script` env list (lines 246, 255) is hand-maintained** and already drifts from the on-disk `cocotb/` tree. Missing from the list: `axi_chiplet_controller`, `bank_asymmetry`, `phy_align`, `tidelink_idelay_rx`, `tidelink_perf_cdriver`, `tidelink_phy_align_calibrator`, `tidelink_rxclk_buf`, `wavd2d_gpiorx_*`. If any of those fail, the artifact bundle and JUnit report don't show it.

- **`dashboard` hard-codes `lint` modules to 3 names** (`generate_dashboard.py:166`: `tidelink_fifo_ctrl, tidelink_returner, tidelink_apb_regs`). The HAL Makefile actually lints `tidelink_fifo`, `tidelink`, `tidelink_top_asic`, `tidelink_top_full_asic` too — those logs exist as artefacts but aren't surfaced.

- **`dashboard` regression env list (`generate_dashboard.py:135`) hard-codes 6 envs**, far fewer than `.gitlab-ci.yml` collects. Most of the cocotb signal is invisible in the published dashboard / wiki.

- **`fpga-pair` `allow_failure: true`** — a real-board regression never reddens the pipeline. Comment line 674 acknowledges this is intentional "while it stabilises". As of today (2026-05-20) it is the only thing that could have caught ce91961, and it isn't a gate.

- **`synth-*` jobs all `allow_failure: true`** — synthesis regression cannot fail the pipeline.

- **`dashboard` pushes to wiki using `${CI_JOB_TOKEN}`** (line 909). If the project wiki is disabled the push fails silently (`|| echo "WARNING"`); easy to miss.

- **No `MERGE_REQUEST_EVENT` workflow** — MRs do not get a different (faster) gate. Devs cannot tell a passing MR pipeline from a passing push pipeline.

## 4. Coverage gaps

### Would the current CI have caught ce91961?

**No.** Sequence:

a. *Does any CI job build the FPGA bitstream?* Yes — inside `fpga-pair` (`build_z2_pair_all` + `flip_all`). But `fpga-pair` only runs on `main` / `feat/fpga-flow` / schedule / web. ce91961 landed on a development branch (it was reverted in b9b26e2 before reaching `main`), so `fpga-pair` would not have triggered on the offending push.

b. *Does any job deploy to a real board?* Same job — same gating.

c. *Does any job measure lane-lock convergence (14/16 → 0/16)?* The `stress_pair` action in `fpgahub.toml` runs `pynq_host.stress.runner --pair` with a 600 s budget, then `fpga_runs_to_junit.py` records pass/fail and the run tail. There is **no explicit threshold check on lane-lock count, prbs error rate, or per-lane convergence** at the CI level — it relies entirely on the runner's own exit code. A drop from 14/16 to 0/16 would surface only if `pynq_host.stress.runner` returns non-zero. Worth confirming.

Even if `fpga-pair` had run, `allow_failure: true` (line 676) means a real-board regression wouldn't block the merge.

### Other gating gaps

- **HAL lint on PRs:** runs on every push but is not MR-gated (no MR-only workflow). Effectively gated, but indistinguishable from a push gate.
- **Verilator lint:** not present at all.
- **Full cocotb regression on PRs:** runs on every push, including MRs (because `MERGE_REQUEST_EVENT` is not filtered out). Today's 789-test count is far higher than what the yml + dashboard expose — many envs aren't tracked.
- **RDL preprocessor (`scripts/rdl2c.py`) check:** not in CI. The silent regex regression that dropped 11 register fields today would not have been caught — the `.generated.h` files in `src/sw/` are committed but never diff-checked vs. a fresh regen.
- **Submodule pin changes:** `clone` does `--recurse-submodules` then `git submodule update --init --recursive` on the pipeline SHA, which is correct. But nothing verifies that the pinned submodule sha is a fast-forward of `axi-chiplet-controller/master` or that the submodule itself passes its own CI. A bad submodule bump (e.g. removing nego_driving) lands silently.
- **Bitstream byte-equality / hash:** no job archives or compares bitstreams. Two builds with different RTL but the same passing sims look identical to CI.
- **No coverage threshold gate.** `urg` merges, dashboard publishes a %, but the pipeline doesn't fail on regression.

## 5. Recent run history

Last 10 pipelines (from `glab api /pipelines`):

| iid | status   | ref                              | sha       | when             |
|-----|----------|----------------------------------|-----------|------------------|
| 173 | pending  | feat/i2c-autonomous-lock-integ   | b481394f  | 2026-05-20 18:03 |
| 172 | canceled | feat/i2c-autonomous-lock-integ   | b5d7e201  | 2026-05-20 14:33 |
| 171 | canceled | feat/i2c-autonomous-lock-integ   | a657306d  | 2026-05-20 14:07 |
| 170 | canceled | feat/i2c-autonomous-lock-integ   | 6db874ac  | 2026-05-20 13:58 |
| 169 | canceled | feat/i2c-autonomous-lock-integ   | c6c644bc  | 2026-05-20 13:40 |
| 168 | canceled | feat/i2c-autonomous-lock-integ   | c8407bc0  | 2026-05-20 13:06 |
| 167 | canceled | feat/i2c-autonomous-lock-integ   | 6fd1517a  | 2026-05-20 12:52 |
| 166 | canceled | feat/i2c-autonomous-lock-integ   | 6fd1517a  | 2026-05-20 12:52 |
| 165 | **failed** | feat/i2c-autonomous-lock-integ | e22528af  | 2026-05-19 23:02 |
| 164 | canceled | feat/i2c-autonomous-lock-integ   | 3de5ebe9  | 2026-05-19 22:59 |

Pass rate over last 20: roughly 0 green, 1 failed at completion, the rest cancelled (dev pushed-over-push) or pending. Last green pipeline I can find via the API in this window: none. Recently-failing jobs (from iid 165): `cocotb-regression`, `cdriver-regression`, `uvm-regression`, `cocotb-fc-adapter`, `cocotb-top`, `uvm-fc-adapter`, `uvm-integration`, `cocotb-ptp`, `cocotb-wlink-pair`, `cocotb-system`, `uvm-system`. Greens are limited to: `clone`, `preflight`, `strip-generalbus-check`, `hal-lint`, `spyglass-cdc`, `uvm-top-system` (curiously), `uvm-ptp-stress`, `uvm-ptp-chain`, `dashboard`, `cleanup`. `fpga-pair` is skipped or failed depending on branch.

The CI is *running but mostly red*. The dashboard still ships green-looking metrics because `generate_dashboard.py` only counts the 6 envs it knows about — most red envs are not visible.

## 6. Top 5 priority fixes

1. **Add an `fpga-build-only` gate that runs on every PR and rejects on bitstream regression** (no board needed). Build both pair bitstreams in CI runners, archive `.bit`/`.bin`, fail on build error or excessive utilisation/timing slack regression. Drop `allow_failure: true` from this gate. Would have caught ce91961 immediately — see `docs/CI_FPGA_PLAN.md`.

2. **Un-hard-code the dashboard env list.** `generate_dashboard.py:135` and `:166` should glob `cocotb/*` and `lint/*_hal.log` so every passing/failing env shows up. Today, *most* of the 789-test signal is invisible to the published dashboard and wiki. This is why nobody noticed all jobs going red for weeks.

3. **Gate cocotb regression as `MERGE_REQUEST_EVENT`-only fast path + push full**, and remove `allow_failure: true` from `cocotb-system`, `uvm-system`, `uvm-top-system`, `cocotb-wlink-pair`. With them allow-failing, "green" only means lint passed. See `docs/CI_COCOTB_PLAN.md`.

4. **Add an `rdl-check` job** that runs `scripts/rdl2c.py` against every `src/rdl/*.rdl` and diffs the output against the committed `*_regs.generated.h`. Today's silent regex bug (11 register fields lost) is in the class of regression CI is blind to.

5. **Add a Verilator lint job** (`--lint-only -Wall`) as a fast PR gate that runs in <1 min and is uncoupled from VCS tooling. Verilator catches X-prop, blocking-in-clocked, multi-driver, and width-mismatch issues HAL routinely misses. See `docs/CI_LINT_PLAN.md`.

Honourable mentions: drop hard-coded `/research/AAA/...` paths (use `ARM_IP_LIBRARY_PATH` env var consistently), de-duplicate "Stage 7" comments, add a `workflow:` block to suppress duplicate MR+push pipelines, and stop `allow_failure: true` on `synth-top-full` once it converges.
