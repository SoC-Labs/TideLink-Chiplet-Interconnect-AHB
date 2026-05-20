# CI FPGA Build + HW-Regression Gate — Proposal

**Author:** dam1n19 · **Date:** 2026-05-20 · **Branch:** `feat/td-combined`
@ `1b9c2d9` · **Status:** Draft — for CI maintainer review.

---

## 1. Goal & Acceptance Test

### Goal
Prevent the class of regression seen this morning — commit `ce91961` produced a
**passing Vivado bitstream** but on real silicon the lane-lock catastrophically
dropped from a **14.30/16 mean to 0/16** over the 30-deploy reliability run.
Pure synthesis / static checks cannot catch this: the only oracle is a real
PYNQ-Z2 pair.

### Acceptance test (the bar this proposal must clear)
Replaying the `ce91961` change against the proposed pipeline MUST land the
pipeline **red** before merge. Concretely:

- `fpga:build_pair_concurrent` produces two bitstreams (master + flip-master).
  Synthesis closure is **not** sufficient as a gate; build alone would let
  `ce91961` through.
- `fpga:hw_reliability` deploys both bitstreams, runs 20 closed-loop deploys
  via `bringup_reliability.sh`, asserts `combined mean ≥ 10/16` AND
  `FCSM-running count ≥ 1/20`. Under `ce91961` (mean=0/16, FCSM=0/30) both
  thresholds collapse → JUnit fail → MR blocked.

This pairing (build + behavioural HW-on-bench) is the **only** scheme that
catches today's failure mode, because the failure mode is "synth-clean,
silicon-dead".

---

## 2. Existing Infra Audit

| Asset                                          | Status     | Notes                                                                                                  |
| ---------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------ |
| `.gitlab-ci.yml` stage `fpga` (`fpga-pair`)    | **Live**   | Tags: `[fpga]`; rules: main / feat/fpga-flow / scheduled / web. `allow_failure: true`. Single job today: invokes `actions run ci_pair_role_aware` via the fpgahub manifest. |
| `ci/fpga_run_pair.sh`                          | **Live**   | Acquires fpgahub background-tier lease with `--requeue-on-revoke`; heartbeats; loops on `lease wait` after revoke up to `MAX_REVOKES=5`; emits per-attempt JSON + step snapshots; converts to JUnit. **Already wired** to `fpga-pair` (line 698 of `.gitlab-ci.yml`). |
| `ci/fpga_runs_to_junit.py`                     | **Live**   | Consumes the artefact bundle above; maps `cancelled+revoked` → `<skipped type="preempted">`. |
| `fpga/Makefile :: build_pair_concurrent`       | **Live**   | Runs `pynq-z2-pair-all@local pynq-z2-pair-flip-all@local` in parallel on the host. Outputs to `imp/fpga/output/<TARGET>/{tidelink.bit,tidelink.hwh}`. |
| `fpga/Makefile :: build_pair_farmed`           | **Live**   | Same fan-out but slave goes to `$(FARM_HOST)` via ssh+rsync. Halves wall time but needs the farm host. |
| `pynq_host/scripts/bringup_reliability.sh`     | **Live**   | "Safe-ops only (no AHB_TX, no doorbell). Cannot wedge boards." Default `N_DEPLOYS=30`. Emits `SUMMARY` block with `combined min/max/mean` and `FCSM both ≥ 2` count. |
| `pynq_host/scripts/bringup_pair_converge.sh`   | **Live**   | Closed-loop variant — exits on first 16/16. Better as a **smoke** test (faster), worse as a regression gate (early-exit hides skew). |
| `fpgahub` CLI                                  | **Live**   | `chassis lease acquire/release/heartbeat`; `pair status bridge1`. v1 chassis = `pynq_z2_02`. |

**Gap:** the existing `fpga-pair` job hits `ci_pair_role_aware` (a fpgahub
manifest composite) — it does **not** invoke our own Makefile build, nor does
it invoke `bringup_reliability.sh`. The manifest composite is a black box from
the MR's perspective; it bakes in whatever the manifest was authored for, not
the head-of-branch fpga/Makefile. The proposal below splits that into
explicit `build` + `hw` jobs so the MR's RTL+constraints actually get
exercised.

---

## 3. Proposed New Jobs (YAML — do NOT add yet)

To be inserted in `.gitlab-ci.yml` stage `fpga`, **alongside or replacing**
the existing `fpga-pair` job (decision deferred to §6).

```yaml
# ---------------------------------------------------------------------------
# fpga:build_pair_concurrent — Vivado bitstreams from head-of-branch RTL.
# ---------------------------------------------------------------------------
fpga:build_pair_concurrent:
  stage: fpga
  needs: [clone, preflight]
  tags: [vivado, fpga-build]            # NEW runner tag — Vivado installed,
                                        # NOT the bench runner. ~32 GB RAM rec.
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_COMMIT_BRANCH == "feat/td-combined"'
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_PIPELINE_SOURCE == "schedule"'
  timeout: 50m                          # ~25 min typical, 2x margin
  variables:
    FPGA_INSERT_DEBUG_CORE: "1"         # keep ILA so post-mortem still works
  cache:
    key: "vivado-ip-$CI_COMMIT_REF_SLUG"
    paths:
      - imp/fpga/tidelink_ip/
      - fpga/vivado_ip/
    policy: pull-push
  script:
    - cd "$WORK_DIR"
    - make -C fpga build_pair_concurrent
  artifacts:
    when: always
    paths:
      - imp/fpga/output/pynq-z2-pair-all/tidelink.bit
      - imp/fpga/output/pynq-z2-pair-all/tidelink.hwh
      - imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit
      - imp/fpga/output/pynq-z2-pair-flip-all/tidelink.hwh
      - imp/fpga/run/*/*.log
    expire_in: 5 days

# ---------------------------------------------------------------------------
# fpga:hw_reliability — 20-deploy statistical char on the real PYNQ-Z2 pair.
# ---------------------------------------------------------------------------
fpga:hw_reliability:
  stage: fpga
  needs:
    - job: fpga:build_pair_concurrent
      artifacts: true
  tags: [fpga]                          # existing single-concurrency runner
  resource_group: bridge1               # serialises across pipelines
  timeout: 30m
  variables:
    FPGAHUB_PAIR_CHASSIS: "pynq_z2_02"
    FPGAHUB_LEASE_TTL_S:  "1800"
    FPGAHUB_LEASE_WAIT_S: "5400"        # 90 min queue cap (HW slot is scarce)
    FPGAHUB_MAX_REVOKES:  "3"
    FPGAHUB_BIN:          "/opt/fpgahub/bin/fpgahub"
    N_DEPLOYS:            "20"
    PASS_COMBINED_MEAN:   "10.0"        # see §5
    PASS_FCSM_RUNNING:    "1"           # ≥1 deploy with FCSM both ≥ 2
  before_script:
    - export PATH="/opt/fpgahub/bin:$PATH"
    - '"$FPGAHUB_BIN" --version'
  script:
    - cd "$WORK_DIR"
    # acquire lease (idempotent — re-uses fpga_run_pair.sh's helpers)
    - bash ci/fpga_hw_reliability.sh    # NEW — see §3.1 below
  after_script:
    - mkdir -p fpga/ci_logs
    - cp -r "$WORK_DIR/fpga/ci_logs/." fpga/ci_logs/ 2>/dev/null || true
  artifacts:
    when: always
    paths:
      - fpga/ci_logs/
    reports:
      junit: fpga/ci_logs/reliability.xml
    expire_in: 30 days

# ---------------------------------------------------------------------------
# fpga:hw_i2c_autoneg — optional, gated on bridge1 too. ~3 min runtime.
# ---------------------------------------------------------------------------
fpga:hw_i2c_autoneg:
  stage: fpga
  needs:
    - job: fpga:build_pair_concurrent
      artifacts: true
    - job: fpga:hw_reliability          # serialise: reliability first
  tags: [fpga]
  resource_group: bridge1
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_PIPELINE_SOURCE == "schedule"'
    # NOT on MR by default — the i2c autoneg surface is moving fast
  allow_failure: true                   # not yet a hard gate
  timeout: 15m
  script:
    - cd "$WORK_DIR"
    - bash ci/fpga_hw_i2c_autoneg.sh    # NEW — wraps deploy_pair_autoneg.sh
                                        # + nego_probe_fast.py + JUnit
  artifacts:
    when: always
    paths:
      - fpga/ci_logs/
    reports:
      junit: fpga/ci_logs/i2c_autoneg.xml
    expire_in: 30 days
```

### 3.1 `ci/fpga_hw_reliability.sh` (new — sketch)

```bash
#!/usr/bin/env bash
# 1. Acquire fpgahub lease (reuse acquire/release/trap idiom from
#    ci/fpga_run_pair.sh — factor into ci/_fpgahub_lease.sh).
# 2. Push imp/fpga/output/pynq-z2-pair-all/tidelink.{bit,hwh,bin}
#    AND ...pynq-z2-pair-flip-all/... to MASTER_IP and SLAVE_IP.
# 3. Run N_DEPLOYS=20 bringup_reliability.sh, tee to ci_logs/reliability.log
# 4. Parse SUMMARY block: combined_mean, fcsm_running_count.
# 5. Emit ci_logs/reliability.xml with one <testcase> per assertion:
#       reliability.combined_mean  fail if < $PASS_COMBINED_MEAN
#       reliability.fcsm_running   fail if < $PASS_FCSM_RUNNING
# 6. Release lease on EXIT/INT/TERM (trap, like fpga_run_pair.sh L66).
```

Three things this script must do that the existing `fpga_run_pair.sh`
**doesn't**:

1. **Push our own artefact** rather than asking the fpgahub manifest to build
   it. The whole point of separating build from deploy is that the MR's bits
   get exercised.
2. **Run `bringup_reliability.sh`** rather than the manifest composite — that
   script is the regression-grade oracle (statistical, no early-exit,
   non-wedging).
3. **Threshold-fail on summary**, not on `actions run`'s exit code.

---

## 4. Triggers & Concurrency

### Triggers
- **MR events**: build + reliability (catches the developer's MR before
  merge). i2c_autoneg gated to scheduled/main to keep MR pipelines fast.
- **Push to `feat/td-combined` and `main`**: build + reliability +
  i2c_autoneg (full sweep).
- **Schedule (nightly)**: everything, plus we could add a longer 30-deploy
  reliability run as a separate `fpga:hw_reliability_long`.
- **Other branches**: no FPGA jobs by default — would saturate runners.
  Developers opt in via web/manual pipeline trigger.

### Concurrency
- `fpga:build_pair_concurrent` uses `tags: [vivado, fpga-build]` — needs a
  new runner (TBC with CI maintainer). The build farms two TARGETs locally,
  so the runner host needs **≥2 Vivado-license slots** + sufficient RAM for
  parallel implementation. Falls back to serial cleanly if either fails.
- `fpga:hw_reliability` uses `tags: [fpga]` (existing single runner on
  mapstone-dev) AND `resource_group: bridge1` to **serialise across
  pipelines** — only one MR at a time can hold the PYNQ pair, even if two
  GitLab pipelines start concurrently. fpgahub's background-tier lease still
  layers underneath so a human dev can preempt the CI run.
- `fpga:hw_i2c_autoneg` shares `resource_group: bridge1` so it queues behind
  reliability.

---

## 5. Failure Threshold Tuning

### Data
This morning's healthy-baseline characterisation (`bringup_reliability.sh`
N=30 on `feat/td-combined @ 56a8aca`):

- combined **mean = 14.30/16**, min = 12, max = 16
- 16/16 perfect ≈ 23%
- 14+/16 near ≈ 87%
- FCSM both ≥ 2 ≈ 73%

`ce91961` failure under the same harness:

- combined mean = **0/16**
- 14+/16 near = 0%
- FCSM both ≥ 2 = 0%

### Proposed thresholds (for N=20)
| Metric                    | Threshold        | Headroom vs baseline           | Catches ce91961?               |
| ------------------------- | ---------------- | ------------------------------ | ------------------------------ |
| `combined_mean ≥ 10/16`   | hard fail        | baseline 14.30 → 4.30 headroom | YES (0 < 10)                   |
| `fcsm_running ≥ 1/20`     | hard fail        | baseline ~73% → ~14.6/20       | YES (0 < 1)                    |
| `combined_min ≥ 6/16`     | warn only        | baseline min 12 → 6 headroom   | YES (informational)            |

Rationale: a one-tailed lower bound at **mean=10** sits ~4σ below the
baseline mean assuming σ≈1 across deploys (observed spread 12–16 is consistent
with σ≈1.3). False-positive rate < 0.1%. False-negative rate vs ce91961-class
failures is essentially zero (a 14 → 0 collapse is a 14σ event).

The **`fcsm_running ≥ 1`** assertion is the real teeth: it catches the
"link looks alive but FCSM is stuck" mode that ce91961 exemplified, even if
some weird sweet-spot happened to give mean=11/16 (it didn't, but defence in
depth).

We do **not** assert on perfect 16/16 — current baseline rate is 23% so an
N=20 sample passing 0 perfect runs has p ≈ (0.77)^20 ≈ 0.006 false-positive
rate, which we'd see twice per year on green code. Not worth it.

---

## 6. Open Questions for the CI Maintainer

1. **Vivado runner**: does a `[vivado, fpga-build]` GitLab runner exist
   today, or do we need to register one on srv04936 (where farm builds
   currently land)? If new, ~32 GB RAM + Vivado 2024.2 + `xc7z020clg400-1`
   licence is the minimum spec.
2. **Replace or supplement `fpga-pair`?** The current `fpga-pair` job calls
   the fpgahub manifest `ci_pair_role_aware` composite (an opaque
   build-and-stress combo). I propose **replacing** it with the explicit
   `fpga:build_pair_concurrent` + `fpga:hw_reliability` pair — same wall
   time, much sharper diagnostic when something breaks. If maintainers
   prefer to keep `fpga-pair` running in parallel for transition, both can
   share `resource_group: bridge1`.
3. **Cache invalidation**: `cache.key` uses `$CI_COMMIT_REF_SLUG` so each
   branch gets its own Vivado IP cache. Acceptable? Alternative is per-MR
   keys (slower, but fewer cross-branch surprises).
4. **Artefact retention**: 5 days for bitstreams. Is that enough for the
   typical post-merge bisect window? `main` push artefacts could go to 30
   days at the cost of ~150 MB × 30 days × ~10 commits/wk ≈ 45 GB.
5. **PYNQ-Z2 board wedging recovery**: `bringup_reliability.sh` is
   safe-ops-only by design (see file header). Any **future** HW test that
   could wedge a board MUST go through a separate `fpga:hw_destructive`
   stage with a power-cycle hook in `after_script` (PYNQ-Z2 boards have no
   remote power; would need an additional fpgahub action). Out of scope for
   this proposal — captured here so it doesn't get forgotten.
6. **Lease release atomicity**: the existing `release_lease` trap in
   `ci/fpga_run_pair.sh` is fire-and-forget (`|| true`). If a GitLab job is
   `cancel`'d at exactly the wrong moment, the lease could leak until TTL
   (1 h). Acceptable, but worth a "stale lease reaper" cron on the fpgahub
   side — already on fpgahub roadmap per `docs/PROPOSAL_BACKGROUND_TIER.md`.

---

## Time & Cost Summary

| Job                                  | Wall (typical) | Wall (worst)   | Runner          |
| ------------------------------------ | -------------- | -------------- | --------------- |
| `fpga:build_pair_concurrent`         | ~25 min        | ~50 min        | vivado          |
| `fpga:hw_reliability` (lease + 20×)  | ~15 min        | ~25 min        | fpga (bridge1)  |
| `fpga:hw_i2c_autoneg`                | ~3 min         | ~10 min        | fpga (bridge1)  |
| **Pipeline total (MR, serial)**      | **~40 min**    | **~75 min**    |                 |
| **Pipeline total (with queue wait)** | ~50 min        | ~3h (worst)    |                 |

Inside the **1h MR budget** in the typical case; **above** the 4h hard limit
only if both queue wait and the worst-case build coincide. The fpgahub
background-tier preemption keeps the bench available for humans, at the cost
of CI re-attempting; `MAX_REVOKES=3` bounds that. Acceptable.
