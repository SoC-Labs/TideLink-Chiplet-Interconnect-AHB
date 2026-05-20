# CI Cocotb Regression — Proposal

**Author:** dam1n19 · **Date:** 2026-05-20 · **Branch:** `feat/td-combined`
@ `1b9c2d9` · **Status:** Draft — for CI maintainer review.

---

## 1. Goal & Acceptance Test

### Goal
Run the cocotb regression on every merge request **before** the change lands
on `main`, so the class of behavioural regression we saw this week is caught
pre-merge. Concrete worked example:

- Commit `c140573` (HAL lint clean-up) dropped the declaration-time
  `= 1'b0` on `tb_early_exit_force_q` (a sim-only force hook) in
  `src/rtl/tidelink_phy_align_calibrator.sv`. In VCS, the register then
  came out of reset as `X`; the `early_exit_en_w = … | tb_early_exit_force_q`
  poisoning fanned out and broke 3 calibrator T3 integration tests
  (`phy_align/test_autocal_integrated`,
  `phy_align/test_pair_align_staggered_bringup`, and the
  `tidelink_phy_align_calibrator` T3 placeholder). The fix landed as
  `1b9c2d9` after the regression was re-run by hand.
- Today there is **no CI job** that exercises `phy_align/*` end-to-end on
  every push. The existing `cocotb-regression` job runs the **list** in the
  top `cocotb/Makefile` (`tidelink_fifo`, `tidelink_returner`,
  `tidelink_apb_regs`, `tidelink`, `tidelink_ahb`, `tidelink_py_pair`,
  `tidelink_addr_translator`, `tidelink_autoneg`, `tidelink_mul_iter`,
  `tidelink_phc_cdc`, `tidelink_ptp_servo`) — **`phy_align`,
  `tidelink_phy_align_calibrator`, `wlink_pair`/skid, `bank_asymmetry` and
  every `wavd2d_gpiorx_*` are not in that list**. So the X-prop was
  invisible to CI until a human ran the parallel-agent regression manually
  out of `/tmp/td_cocotb_reg_c515b88/`.

### Acceptance test
Replaying `c140573` against this pipeline MUST land the MR red, and the
failing tests MUST be the three `tb_early_exit_force_q`-dependent tests in
`phy_align/*` and `tidelink_phy_align_calibrator/`. See §5: the
`src/rtl/tidelink_phy_align_calibrator.sv` path → suite mapping selects
`phy_align/*` and the calibrator suite into the per-MR fast lane, so the
regression fires automatically on every push touching that file.

---

## 2. Audit — what already runs in CI today

`.gitlab-ci.yml @ 1b9c2d9` has the following cocotb jobs (one job per
subdir, except `cocotb-regression` which is one job sweeping eleven subdirs
serially):

| Job                       | Stage        | Subdir(s)                                                                                                                                                   | allow_failure |
|---------------------------|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------|
| `cocotb-regression`       | `regression` | `tidelink_fifo`, `tidelink_returner`, `tidelink_apb_regs`, `tidelink`, `tidelink_ahb`, `tidelink_py_pair`, `tidelink_addr_translator`, `tidelink_autoneg`, `tidelink_mul_iter`, `tidelink_phc_cdc`, `tidelink_ptp_servo` | no            |
| `cdriver-regression`      | `regression` | `tidelink_ahb` (cdriver MODULE only)                                                                                                                        | no            |
| `cocotb-fc-adapter`       | `new_module` | `tidelink_fc_adapter`                                                                                                                                       | no            |
| `cocotb-top`              | `new_module` | `tidelink_top`                                                                                                                                              | no            |
| `cocotb-ptp`              | `new_module` | `tidelink_ptp`                                                                                                                                              | no            |
| `cocotb-wlink-pair`       | `new_module` | `wlink_pair` (default `test_link_bringup,test_assert_bringup` only)                                                                                          | **yes**       |
| `cocotb-system`           | `system`     | `tidelink_system`                                                                                                                                           | **yes**       |

Total covered: 15 subdirs (one of them only the cdriver MODULE). Two of the
covered jobs are `allow_failure: true`, so they do **not** block merge.

---

## 3. Coverage gap — subdirs NOT in CI today

There are 29 cocotb subdirs with a Makefile + at least one `test_*.py`
(plus `common/` and stub `tidelink_perf_cdriver/`, `axi_chiplet_controller/`
which have no Makefile and are not standalone). Of those 29, the following
**14** are not exercised by any existing CI job:

```
phy_align                          (12 tests — incl. test_autocal_integrated, test_pair_align*)
tidelink_phy_align_calibrator      ( 3 tests — incl. test_calibrator_t3)
wlink_pair (test_pair_skid, test_fpga_repro*, test_hw_repro_probe_seq)
tidelink_idelay_rx                 ( 1 test)
tidelink_rxclk_buf                 ( 1 test)
tidelink_perf                      ( 1 test)
tidelink_perf_congestion           ( 1 test)
bank_asymmetry                     ( 1 test)
wavd2d_gpiorx_clkbuf               ( 1 test)
wavd2d_gpiorx_t3a                  ( 1 test)
wavd2d_gpiorx_t3a_off              ( 1 test)
wavd2d_gpiorx_t3a_timeout          ( 1 test)
tidelink_ahb (RDL header gen, see §6)   — currently failing, masked
tidelink_top_system (UVM, not cocotb — out of scope)
```

This is the gap. Today's manual run covered all 29 subdirs (49 logs in
`/tmp/td_cocotb_reg_c515b88/`, including some MODULE-split phy_align/
wlink_pair runs); CI covers ~15.

---

## 4. Per-MR fast suite (`cocotb:mr_fast`)

### Definition
Targeted ~10-minute lane. Runs on every push to a branch with an open MR,
plus on `main`. Catches the bring-up integration regressions we actually
shipped this month.

Subdirs (12 jobs, fan-out parallel):

| Subdir                              | MODULE filter (if any) | Wall-clock (today's data) |
|-------------------------------------|------------------------|---------------------------|
| `phy_align`                         | (all 12 tests)         | ~7 min                    |
| `tidelink_phy_align_calibrator`     | (all 3 tests)          | ~3 min                    |
| `wlink_pair`                        | `test_link_bringup,test_assert_bringup` | ~2 min   |
| `tidelink_apb_regs`                 | -                      | < 1 min                   |
| `tidelink_addr_translator`          | -                      | < 1 min                   |
| `tidelink_autoneg`                  | -                      | < 1 min                   |
| `tidelink_fifo`                     | -                      | ~1 min                    |
| `tidelink_returner`                 | -                      | ~1 min                    |
| `tidelink_mul_iter`                 | -                      | ~1 min                    |
| `tidelink_phc_cdc`                  | -                      | ~1 min                    |
| `tidelink_ptp_servo`                | -                      | ~1 min                    |
| `tidelink_fc_adapter`               | -                      | ~3 min                    |

Wall-clock estimate: critical path ~7 min (`phy_align`), ~12 jobs in parallel.

### YAML fragment

```yaml
.cocotb_mr_template:
  stage: regression
  needs: [clone, preflight]
  tags: [vcs]
  <<: *vcs_cocotb_setup
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - cd "$WORK_DIR/cocotb/$COCOTB_SUBDIR"
    - make $COCOTB_MAKE_ARGS
  after_script:
    - mkdir -p "cocotb/$COCOTB_SUBDIR"
    - cp "$WORK_DIR/cocotb/$COCOTB_SUBDIR/results.xml"  "cocotb/$COCOTB_SUBDIR/" 2>/dev/null || true
    - cp "$WORK_DIR/cocotb/$COCOTB_SUBDIR/run.log"      "cocotb/$COCOTB_SUBDIR/" 2>/dev/null || true
    # Subdirs without native cocotb JUnit fall back to the UVM-style parser
    - test -f "cocotb/$COCOTB_SUBDIR/results.xml" ||
      python3 "$WORK_DIR/ci/uvm_results_to_junit.py"
        "$WORK_DIR/cocotb/$COCOTB_SUBDIR"
        "cocotb/$COCOTB_SUBDIR/results.xml" || true
  artifacts:
    when: always
    paths: ["cocotb/$COCOTB_SUBDIR/"]
    reports:
      junit: ["cocotb/$COCOTB_SUBDIR/results.xml"]
    expire_in: 14 days

cocotb-mr:phy_align:
  extends: .cocotb_mr_template
  variables: { COCOTB_SUBDIR: phy_align }
cocotb-mr:calibrator:
  extends: .cocotb_mr_template
  variables: { COCOTB_SUBDIR: tidelink_phy_align_calibrator }
cocotb-mr:wlink_pair:
  extends: .cocotb_mr_template
  variables:
    COCOTB_SUBDIR: wlink_pair
    COCOTB_MAKE_ARGS: 'MODULE=test_link_bringup,test_assert_bringup'
# ... (9 more — one per subdir)
```

The cocotb runtime writes `results.xml` natively when `COCOTB_RESULTS_FILE`
is set (default `results.xml`); the fallback `uvm_results_to_junit.py` call
keeps subdirs that overwrite or skip the file aligned with GitLab's JUnit
ingest.

---

## 5. Nightly full suite (`cocotb:nightly`)

Same template, scheduled (`if: $CI_PIPELINE_SOURCE == "schedule"`) — covers
**every** cocotb subdir including the long ones:

| Bucket | Subdirs | Why nightly |
|--------|---------|-------------|
| Long system | `tidelink_top`, `tidelink_system` | 20–40 min sims |
| PHY corner sweep | `phy_align` (MODULE=test_phase_sweep, test_best_of_sweep, test_pair_align_retraining, test_credit_path_observability, test_idelay_tap_wiring) | already in MR fast lane (all-modules) but re-run with COVERAGE=1 |
| PTP | `tidelink_ptp` (all 2 tests) | 5–8 min |
| Skid sweep | `wlink_pair` MODULE=test_pair_skid (SKID_BITS=1..5) | minutes per skid value |
| FPGA repro | `wlink_pair` test_fpga_repro, test_fpga_repro2, test_hw_repro_probe_seq | minutes |
| PHY misc | `tidelink_idelay_rx`, `tidelink_rxclk_buf`, `bank_asymmetry` | secs–minutes |
| GPIORX corners | `wavd2d_gpiorx_clkbuf`, `wavd2d_gpiorx_t3a`, `_t3a_off`, `_t3a_timeout` | minutes |
| Perf | `tidelink_perf`, `tidelink_perf_congestion`, `tidelink_perf_cdriver` (if scaffolded) | minutes |
| C-driver | `tidelink_ahb` (cdriver MODULE) — already covered by `cdriver-regression` | keep |

### YAML fragment

```yaml
cocotb-nightly:
  extends: .cocotb_mr_template
  parallel:
    matrix:
      - COCOTB_SUBDIR: [tidelink_top, tidelink_system, tidelink_ptp,
                        tidelink_idelay_rx, tidelink_rxclk_buf, bank_asymmetry,
                        wavd2d_gpiorx_clkbuf, wavd2d_gpiorx_t3a,
                        wavd2d_gpiorx_t3a_off, wavd2d_gpiorx_t3a_timeout,
                        tidelink_perf, tidelink_perf_congestion]
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule"'
    - if: '$CI_PIPELINE_SOURCE == "web"'
  variables:
    COCOTB_MAKE_ARGS: 'COVERAGE=1'
```

GitLab's `parallel: matrix:` instantiates one job per matrix row — 12 in
parallel, capped only by the `tags: [vcs]` runner pool.

---

## 6. Path → suite mapping (RTL change gate)

The most useful idea: gate test execution on the **scope** of the MR. We
keep the per-MR fast lane (§4) always-on so we never regress something
unobservable, AND we add **mandatory extra subdirs** based on what the MR
touches. Implementation: GitLab `rules:changes:` on each extra job.

| Touched path (regex)                                                | Mandatory extra subdir(s)                                          |
|---------------------------------------------------------------------|--------------------------------------------------------------------|
| `src/rtl/tidelink_phy_align_calibrator\.sv`                         | `phy_align`, `tidelink_phy_align_calibrator`, `wlink_pair`         |
| `src/rtl/tidelink_lane_checker\.sv`                                 | `phy_align`, `wlink_pair`                                          |
| `src/rtl/tidelink_fifo.*` or `src/rtl/fifo/.*`                      | `tidelink_fifo`, `tidelink_returner`, `tidelink_perf`              |
| `src/rtl/tidelink_apb_regs\.sv`                                     | `tidelink_apb_regs`, `tidelink_autoneg`, `tidelink_top`            |
| `src/rtl/tidelink_addr_translator\.sv\|tl_addr_trans_.*\.sv`        | `tidelink_addr_translator`                                         |
| `src/rtl/tidelink_fc_adapter\.sv`                                   | `tidelink_fc_adapter`, `tidelink_top`                              |
| `src/rtl/tidelink_ahb\.sv`                                          | `tidelink_ahb` (when un-quarantined), `tidelink_top`               |
| `src/rtl/tidelink_perf\.sv`                                         | `tidelink_perf`, `tidelink_perf_congestion`                        |
| `src/rtl/tidelink_phc_cdc\.sv\|src/rtl/tidelink_ptp.*\.sv`          | `tidelink_phc_cdc`, `tidelink_ptp`, `tidelink_ptp_servo`           |
| `src/rtl/tidelink_mul_iter\.sv`                                     | `tidelink_mul_iter`                                                |
| `src/rtl/tidelink_returner\.sv`                                     | `tidelink_returner`                                                |
| `src/rtl/tidelink_top\.sv`                                          | `tidelink_top`, `tidelink_system`                                  |
| `src/rtl/.*idelay.*\|src/rtl/.*rxclk.*`                             | `tidelink_idelay_rx`, `tidelink_rxclk_buf`, `phy_align`            |
| `src/rtl/.*gpio.*\|src/rdl/.*\|src/sw/.*tidelink_regs.*`            | `wavd2d_gpiorx_*`, `tidelink_ahb`                                  |
| `src/rdl/.*\|src/sw/.*regs.*generate.*`                             | `tidelink_apb_regs`, `tidelink_ahb` (regen + recompile)            |
| `flist/.*\|deps/.*`                                                 | **full per-MR fast lane**                                          |

YAML pattern (one example):

```yaml
cocotb-mr:phy_align:
  extends: .cocotb_mr_template
  variables: { COCOTB_SUBDIR: phy_align }
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
      changes:
        - src/rtl/tidelink_phy_align_calibrator.sv
        - src/rtl/tidelink_lane_checker.sv
        - src/rtl/*idelay*
        - cocotb/phy_align/**/*
        - cocotb/wlink_pair/**/*
        - flist/**/*
    - if: '$CI_COMMIT_BRANCH == "main"'
```

For c140573 specifically: it touched
`src/rtl/tidelink_phy_align_calibrator.sv` and
`src/rtl/tidelink_perf.sv`. Row 1 of the table selects `phy_align`,
`tidelink_phy_align_calibrator`, and `wlink_pair` into the gating set;
the X-prop on `tb_early_exit_force_q` would have failed the first two
within the 10-minute window. Pre-merge gate fires → MR blocked → fix
goes in as a same-MR follow-up commit, not as a hotfix tail-commit.

---

## 7. Skip-list management

Two cases need a documented escape valve, **never** a silent `|| true`:

1. **Known broken, repair tracked.** `cocotb/tidelink_ahb/` — the `make`
   target fails before any cocotb test runs because `src/sw/Makefile`
   regenerates `tidelink_regs.generated.h` via `systemrdl`, and the
   `.rdl` currently triggers `RDLCompileError: Dynamic assignment to
   property 'hw' is not allowed` (see
   `/tmp/td_cocotb_reg_c515b88/tidelink_ahb__default.log` tail). This
   is downstream of the RDL refactor.

2. **Environment-dependent / WIP.** `cocotb-wlink-pair` and
   `cocotb-system` are already `allow_failure: true` for FPGA-flist
   reasons.

### Mechanism

A single source-of-truth file `ci/cocotb_skip.yml`:

```yaml
# ci/cocotb_skip.yml — known broken / skipped cocotb subdirs.
# CI honours these; humans must keep them current. Each entry has a
# tracking issue and a reason; CI fails the job if the file is older
# than 30 days, to force re-triage.
tidelink_ahb:
  reason: "systemrdl `Dynamic assignment to property 'hw'` blocks header regen post-RDL refactor"
  issue: "#TBD"
  added: 2026-05-20
  added_by: dam1n19
  allow_failure: true
```

Each `cocotb-mr:*` job reads its own row and sets
`allow_failure: !!eval $SKIP_ENTRY.allow_failure` via a thin shell
preflight; entries older than 30 days fail preflight loudly. Net effect:
no `|| true` hidden in scripts, and "still broken" is a quarterly review
item rather than CI background noise.

---

## 8. Sharding / parallelism

GitLab `parallel: matrix:` gives one job per matrix row; per-job sim
build is independent (each subdir has its own `sim_build/`). The
`tags: [vcs]` pool today serves the existing seven cocotb jobs in
parallel without contention; the new design adds ~12 fast-lane jobs and
~12 nightly jobs.

- **Fast lane:** 12 jobs. Critical path = `phy_align` ~7 min. Wall
  clock ~10 min including artifact upload.
- **Nightly:** 12+ jobs. Critical path = `tidelink_system` (today ~40
  min with COVERAGE=1). Wall clock ~45 min.

Today's manual regression (`/tmp/td_cocotb_reg_c515b88/`) is the empirical
upper bound: 49 logs, completed by parallel agents in well under 30 min.
GitLab's `vcs` runner pool can absorb this.

---

## 9. Time / cost per MR

| Pipeline | Today | Proposed (this doc) |
|----------|------:|--------------------:|
| Cocotb subdirs covered                       | 15  | 29 (full nightly) / 12 gated (per-MR fast lane) |
| Per-MR wall clock (cocotb only)              | ~25 min (`cocotb-regression` serial sweep) | ~10 min (parallel fast lane) |
| Distinct tests blocked-on-merge per MR       | ~140 (the eleven-subdir list)              | ~38 fast-lane + path-gated extras |
| `c140573`-class regression caught pre-merge? | **No**                                     | **Yes** — `phy_align` + calibrator on rule §6 row 1 |
| Nightly wall clock                           | n/a (no nightly today)                      | ~45 min unattended |

The fast lane is **faster** than today's `cocotb-regression`
(parallel fan-out vs. serial sweep) AND covers strictly more behaviour
(phy_align + calibrator + wlink_pair smoke that today aren't even in CI).
Nightly covers the long sims that don't belong on a 10-minute MR gate.

---

## 10. Rollout

1. Land `ci/cocotb_skip.yml` + `.cocotb_mr_template` as no-op (no jobs
   reference them yet) — green pipeline.
2. Add `cocotb-mr:phy_align` and `cocotb-mr:calibrator` only — they are
   the highest-value gap. One MR, observable benefit.
3. Add the other fast-lane jobs in one batch.
4. Add the path-to-suite `rules:changes:` map (§6).
5. Retire the monolithic `cocotb-regression` job once each of its
   subdirs has a per-subdir fast-lane job that covers it (avoids
   double-running on `main`).
6. Add the nightly schedule (`cocotb-nightly`).

Step 2 alone closes the `c140573` regression class.
