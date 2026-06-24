# CI: V1 silicon BILATERAL regression flow (build → deploy → test)

This document describes the GitLab CI pipeline that regression-tests the
**V1 8-lane TideLink bilateral link on silicon** (the bridge1 PYNQ-Z2 pair),
its trigger model, the runner it needs, and the manual fallback when no HW
runner is registered.

Baseline under test: tag **`v1-silicon-bilateral-2026-06-23`** (commit
`142a7ca`) — B→A data delivery reliable, A→B a ~13% marginal-RX lottery
(die_b flip build, LUT-driven `pad_clk_rx`; fix = flip-XDC BUFG + word-window).

---

## 1. The three stages

The flow lives in **`ci/regression-flow.gitlab-ci.yml`**, `include:`d from the
top-level `.gitlab-ci.yml`. It adds three jobs:

| Job              | Stage             | Runner tag            | When                         | Blocks pipeline? |
|------------------|-------------------|-----------------------|------------------------------|------------------|
| `v1-sim-gate`    | `regression`      | `vcs`                 | every push / MR              | **yes** (RTL guard) |
| `v1-build-flip`  | `v1_build`        | `tidelink-fpga-build` | manual / nightly schedule    | no (manual)      |
| `v1-deploy-test` | `v1_deploy_test`  | `tidelink-hw`         | manual / nightly schedule    | no (`allow_failure`) |

### `v1-sim-gate` — cheap, per-push (no boards)
Runs the integrated paired-die cocotb sim
(`cocotb/tidelink_top_pair`, `MODULE=test_tidelink_pair_doorbell`) — two
cross-wired `tidelink_top` instances, the pre-silicon analogue of the B↔A
link (AHB → Wlink FC/credit → PHY → RX FIFO). This catches RTL regressions
**without** touching the boards and is the per-commit guard. It emits cocotb's
native `results.xml` as JUnit. Wrapper: `ci/v1_sim_gate.sh`.

> This implements the "**sim-gate every HW deploy**" policy: if the pair sim
> is red, do not bother kicking the build/deploy stages.

### `v1-build-flip` — build the bitstreams (Vivado runner)
Wraps `fpga/scripts/build_farm.sh` to build **both** halves of the pair:

- `pynq-z2-pair-all`      → die_a (master, non-flip), built `@local`
- `pynq-z2-pair-flip-all` → die_b (slave, **flip** — the half the A→B fix lives in), built `@srv04936`

It sources `set_env.sh` (deriving `CMSDK_DIR` / `XHB500_IP_DIR` /
`CMSDK_FPGA_SRAM_V` from `ARM_IP_LIBRARY_PATH=/research/AAA/ip_library` and
generating the XHB500 bridge IP), runs the farm build (~45 min/half; the
8-lane pair closes slowly, so `timeout: 8h`), then collects
`tidelink.{bit,bin,hwh}` per target into a CI artefact (`fpga_bits/`).
Wrapper: `ci/v1_build_flip.sh`. Override `BUILD_TARGETS` to build just the
flip half during a fix campaign.

### `v1-deploy-test` — deploy + bilateral gate (HW runner)
Wraps `ci/v1_deploy_test.sh`, which:

1. stages the built `tidelink.bit` (die_a) + `tidelink-flip.bit` (die_b) to
   `~/td_v1_deploy/` on **mapstone-dev** via tar-over-ssh (rsync/scp are flaky
   between the dev hosts — see `docs/BOARD_DEPLOY_RUNBOOK.md` §3); a non-`/tmp`
   path is mandatory because `fpgahubd` has `PrivateTmp`;
2. syncs the commit's `pynq_host/scripts/td_bilateral_regression.sh` +
   `td_v1_b2a_proof.sh` to mapstone-dev;
3. runs **`pynq_host/scripts/td_bilateral_regression.sh`** there with
   `PROOF=program` (programs both dies, captures the lease), which:
   - **B→A gate** (must PASS): re-runs the proven-good direction up to
     `BTOA_TRIES` times; the first PASS satisfies it. A total failure here =
     the *link* regressed (eye / credit / ribbon / build), → hard FAIL.
   - **A→B lottery sample**: runs the A→B proof `ATOB_RUNS` times and requires
     `≥ ATOB_MIN` passes (see §3).
   Each direction uses `td_v1_b2a_proof.sh`, which rolls the marginal-eye link
   to a clean state then sends a **fresh random** payload (so a PASS can never
   be a stale-FIFO artefact) and returns a hard PASS/FAIL + exit code.
4. **always releases the fpgahub lease** (the gate's own `EXIT`/`INT`/`TERM`
   trap calls `td_v1_b2a_proof.sh --release`, and the wrapper adds a
   belt-and-braces `fpgahub pair lease release bridge1` on its own exit);
5. pulls back a per-direction **JUnit** (`bilateral_junit.xml`) + the run log.

Verdict: **BILATERAL OK** iff (B→A gate PASS) AND (A→B ≥ `ATOB_MIN`); exit `0`
only then. The job is `allow_failure: true` so a single flaky marginal-eye
bring-up does not redden the whole pipeline — the JUnit + exit code still
record the verdict.

---

## 2. Why NOT per-commit

An FPGA flip build is **~45 min/half** and the HW regression is **~35 min** on
the **shared** bridge1 boards under a single **fpgahub lease**. Running either
per push would serialise every commit behind hardware and starve interactive
board users. So the heavy stages are **`when: manual`** and/or driven by a
**scheduled (nightly) pipeline**, never per-commit. Only the cheap
`v1-sim-gate` runs on every push.

### Trigger model (the `rules:` on the heavy jobs)
```yaml
rules:
  - if: '$CI_PIPELINE_SOURCE == "schedule" && $RUN_V1_REGRESSION == "1"'   # nightly
    when: always
  - if: '$CI_COMMIT_BRANCH == "ci/regression-flow"'                        # flow dev
    when: manual
  - if: '$CI_PIPELINE_SOURCE == "web"'                                     # web button
    when: manual
  - when: manual                                                          # default: click ▶
```

**To run the full flow nightly**, create a GitLab **Scheduled Pipeline**
(Project → Build → Pipeline schedules) with a CI/CD variable
**`RUN_V1_REGRESSION=1`** (and optionally `USE_PINNED_BITS=1` for a test-only
schedule that skips the ~hours build and reuses the pinned bitstreams already
on mapstone-dev). Recommended cron: nightly, off-peak.

**To run on demand**, open the pipeline for any commit and click ▶ on
`v1-build-flip` then `v1-deploy-test` (or just `v1-deploy-test` with
`USE_PINNED_BITS=1`).

---

## 3. `ATOB_MIN` — the A→B reliability knob

`td_bilateral_regression.sh` requires `≥ ATOB_MIN` of `ATOB_RUNS` A→B passes.

- **Current baseline → `ATOB_MIN=1`** (the value wired into the job). A→B is a
  ~13% marginal-RX lottery on the die_b flip build, so demanding `1/15` proves
  A→B is **not totally dead** (catches a *total* A→B regression) without
  requiring the unfixed eye to behave deterministically.
- **After the die_b flip-XDC BUFG / word-window fix lands** (when A→B should be
  reliable), **raise `ATOB_MIN` to ~12** (of 15) so an A→B *reliability*
  regression reddens the gate. Change it in one place — the
  `v1-deploy-test` job's `variables: ATOB_MIN:` in
  `ci/regression-flow.gitlab-ci.yml` — or override per-run via a CI/CD variable.

---

## 4. Runner requirements + how to register the HW runner

Existing runners (already registered for this project): `vcs` (Synopsys VCS,
used by `v1-sim-gate` and the wider cocotb/UVM suite) and `xcelium` (HAL lint).
The flow needs **two more tags**:

### `tidelink-fpga-build` — the Vivado build runner
A runner (shell or docker-with-mounts executor) that has:
- **Vivado 2024.1** on `PATH` (or at `VIVADO_BIN`; default
  `/apps/Xilinx/Vivado/2024.1/bin/vivado`);
- the **Arm IP library** mounted at **`/research/AAA/ip_library`**
  (read-only is fine — `set_env.sh` only reads it);
- **passwordless ssh** to the farm host(s) named in `BUILD_TARGETS`
  (e.g. `srv04936`) — see `fpga/scripts/setup_farm_ssh.sh`; Vivado 2024.1 at
  the same path + the same `/research` mount on each farm host;
- the **PHC sibling repo** at `$HOME/SoCLabs/ptp-hardware-clock-ahb`
  (`PHC_REPO_DIR`) for the `-all` BD's `package_phc_ip` step (skipped if absent);
- a git checkout with submodules (the job sets `GIT_STRATEGY: clone` +
  `GIT_SUBMODULE_STRATEGY: recursive`).

The existing `srv04936` farm host that already builds these targets by hand is
the natural place to register this runner.

### `tidelink-hw` — the bridge1 HW runner
A runner that has only a **key-based SSH alias `mapstone-dev`** (user `david`)
in its `~/.ssh/config`. **It does not need board routes itself** — mapstone-dev
(10.22.27.178) is the single host that can reach the boards' PS-management
network (die_a `192.168.4.101`, die_b `192.168.2.101`) and holds the
**`fpgahub` CLI** (`/opt/fpgahub/bin/fpgahub`). `ci/v1_deploy_test.sh` proxies
everything through `ssh mapstone-dev …`; `td_v1_b2a_proof.sh` then `sshpass`es
into the boards from there. mapstone-dev needs:
- a checkout at `/home/david/SoCLabs/tidelink` (the scripts are synced into it
  per-run; `REMOTE_REPO_DIR` overrides the path);
- `sshpass` + the board password (`$TIDELINK_BOARD_PASS`, default `xilinx`);
- `fpgahub` configured for the `bridge1` pair.

This mirrors the existing `bridge1-runner` used by the `hwtest:*` jobs, which
is documented the same way ("must have mapstone-dev SSH access + fpgahub").
If a `bridge1-runner` is already registered, you can either re-tag it
`tidelink-hw` or add `tidelink-hw` to its tag list.

#### Registering a runner (reference)
```bash
# On the chosen host (the farm box for build; the mapstone-dev-reachable box for HW):
sudo gitlab-runner register \
  --url https://git.soton.ac.uk/ \
  --registration-token <PROJECT_RUNNER_TOKEN> \
  --executor shell \
  --description "tidelink-<fpga-build|hw>" \
  --tag-list "tidelink-fpga-build"   # or "tidelink-hw"
# Then verify it shows "online" under Project → Settings → CI/CD → Runners.
```
Set a single-concurrency limit on `tidelink-hw` (`concurrent = 1` in
`config.toml`) so two pipelines can't fight over the boards; the lease is the
second line of defence.

### If no HW runner is registered
The heavy jobs stay `when: manual` and simply are **never started** — pipelines
stay green (the `v1-sim-gate` still runs and gates RTL). Use the manual
fallback below until a runner is registered.

---

## 5. Manual fallback (no CI runner needed)

Everything CI does, you can do by hand from a repo checkout **on mapstone-dev**
(or any host with the SSH alias). Two entry points:

### `make regression` — run the bilateral gate against an already-deployed pair
```bash
# On mapstone-dev, boards already programmed + lease held:
make regression
# == pynq_host/scripts/td_bilateral_regression.sh with the CI defaults
#    (PROOF=link, B→A gate + A→B×15 need ≥1; raise ATOB_MIN after the fix).
```
To also program the dies first (full cold flow):
```bash
PROOF=program \
BIT_A=~/td_v1_deploy/tidelink.bit BIT_B=~/td_v1_deploy/tidelink-flip.bit \
  pynq_host/scripts/td_bilateral_regression.sh
```

### Full build → deploy → test by hand
```bash
# 1. Build (on the farm box), per docs/BOARD_DEPLOY_RUNBOOK.md §3:
bash fpga/scripts/build_farm.sh \
     pynq-z2-pair-all@local \
     pynq-z2-pair-flip-all@srv04936
#    -> imp/fpga/output/<target>/tidelink.bit

# 2. Stage + run the gate via the same wrapper CI uses (from any host with the
#    mapstone-dev SSH alias):
ARTIFACT_DIR=imp/fpga/output \
BIT_A_SRC=imp/fpga/output/pynq-z2-pair-all/tidelink.bit \
BIT_B_SRC=imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit \
ATOB_MIN=1 \
  bash ci/v1_deploy_test.sh
#    -> stages bits, runs td_bilateral_regression.sh on mapstone-dev,
#       releases the lease, writes ci_artifacts/regression/bilateral_*.{xml,log}
```

The single per-direction primitive is always
`pynq_host/scripts/td_v1_b2a_proof.sh` (`--program` / `--dir BtoA|AtoB` /
`--rolls` / `--release`).

---

## 6. Lease safety (don't leak the shared boards)

Every layer releases the `bridge1` lease:

- `td_v1_b2a_proof.sh --program` captures a releasable token to
  `${TMPDIR:-/tmp}/td_v1_lease_bridge1.token`; `--release` frees it.
- `td_bilateral_regression.sh` traps `EXIT`/`INT`/`TERM` and calls
  `td_v1_b2a_proof.sh --release` (unless `RELEASE=0`), so even a `SIGTERM`
  from a CI runner preempt frees the boards.
- `ci/v1_deploy_test.sh` traps its own exit and additionally runs
  `fpgahub pair lease release bridge1` on mapstone-dev as a backstop.

If a lease is ever left held (e.g. a host died), free it manually:
```bash
ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair lease release bridge1"
```

---

## 7. File map

| Path | Role |
|------|------|
| `.gitlab-ci.yml` | top-level; `include:`s the flow + declares the new stages |
| `ci/regression-flow.gitlab-ci.yml` | the three jobs (sim / build / deploy_test) |
| `ci/v1_sim_gate.sh` | runs the paired-die cocotb gate, collects JUnit |
| `ci/v1_build_flip.sh` | wraps `build_farm.sh`, collects `.bit/.bin/.hwh` |
| `ci/v1_deploy_test.sh` | stages bits to mapstone-dev, runs the gate, releases the lease |
| `pynq_host/scripts/td_bilateral_regression.sh` | the BILATERAL PASS/FAIL gate (B→A + A→B) |
| `pynq_host/scripts/td_v1_b2a_proof.sh` | per-direction primitive (program/roll/prove) |
| `Makefile` (`regression` target) | manual fallback entry point |
