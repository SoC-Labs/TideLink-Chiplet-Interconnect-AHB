# CI Lint Gate Plan — Verilator + Cadence HAL + RDL

**Author:** dam1n19 · **Branch:** `feat/td-combined` (worktree `/home/dam1n19/td_idelay_wt`) · **Tip:** `1b9c2d9` · **Date:** 2026-05-20

This document proposes the PR-level lint gates that will prevent new RTL-quality regressions from landing on `feat/*` branches and `main`. It is a written proposal — no changes are made to `.gitlab-ci.yml`, `lint/`, RTL, cocotb or `flist/`.

## 1. Why each lint gates

| Lint | Tool | What it catches | Today's state |
|------|------|-----------------|---------------|
| Verilator | `verilator --lint-only -sv -Wall` | WIDTH mismatches, UNUSED nets, SYNCASYNCNET, PINMISSING; fast (~5 min) feedback in plain Linux containers | 0 errors / 77 warnings in `src/rtl/*`; 838 warnings whole elab (`docs/RTL_LINT_REPORT.md`) |
| Cadence HAL | `hal -64bit -sv -check ALL_RTL` | Sign-off-grade RTL/structural/synth checks: CLKDMN, RTLINI, VERCAS, GLTASR; what the ASIC backend will use at handoff | 0 errors all three engines (halcheck/halsynth/halstruct) on full ASIC flist after `c140573`; ~10k+324+3,734 warnings (mostly waivable style on PHY-align block) |
| RDL | `rdl2c.py` + `make -C src/sw generate` + `cc -c tidelink_test_wrappers.c` | Silent register-field drop (the regex bug fixed today), `_Static_assert` mismatch between generated header and cocotb wrappers | New job; surfaces the failure mode that bit on `1b9c2d9` |

Today the `.gitlab-ci.yml` already has a HAL job (`hal-lint`, line 164) and a SpyGlass-CDC job (`spyglass-cdc`, line 187) but both run `make -C lint lint-each` / `make -C cdc cdc` — they fail the pipeline on **any** non-zero exit from HAL, which is fine when the baseline is clean today but is brittle to drift (a single new vendor warning escalating to ERROR could redline the pipeline). There is **no Verilator job** and **no RDL/generate smoke test**.

## 2. Baselines & drift management — recommendation **Strategy B**

Three options were considered:

- **A — Per-module baseline counts in `lint/baselines/`.** Store today's per-file warning totals as JSON; pipeline diffs new run vs. baseline and fails on any positive delta. *Pro:* simple; *con:* every legitimate RTL edit that changes a line number perturbs the per-file count even when the warning class is unchanged. Drift is high; humans review-and-bump the baseline weekly. Tried this pattern on past projects — it generates noise PRs.

- **B — Filter the lint output through a known-waivable strip script.** Run both Verilator and HAL, then pass `*.log` through a `lint/scripts/scope_filter.py` that:
  1. Drops every line not anchored in `src/rtl/`.
  2. For HAL, strips lines matching the design-info-waived classes (already file-scoped; this is just re-applying the same rule set as a textual safety net).
  3. Counts ERROR-class messages → if `> 0`, fail.
  4. Counts WARNING-class messages → emit as a GitLab MR note (advisory; never a job failure).

  *Pro:* the only persisted state is the filter script (versioned in git, reviewable in PRs); errors are caught **immediately** without baseline-bump PRs; warnings still get visibility. *Con:* a brand-new error class that we haven't seen before still slips through if it lands in a vendor file. That is acceptable because vendor IP is upstream-owned (Wlink/XHB500/CMSDK) and not in scope for TideLink sign-off.

- **C — Tool-native waivers only (`hal -nocheck`, `-design_info`, `verilator -Wno-*`).** This is what is in place today: `lint/hal.tcl` and `lint/hal.design_info`. *Pro:* fewest moving parts; *con:* baselines do drift — once `tidelink_perf.sv` carries 60 warnings, adding a 61st is invisible unless the diff is explicit.

**Recommended: B with C as the substrate.** Keep the `-nocheck`/`-design_info` waivers (Strategy C) — they are the right place to express *intent* (toggle-handshake CDC is a real waiver, not a sweeping-under-the-rug). Layer Strategy B on top to gate on the **scope filter** so that any new ERROR-class message in `src/rtl/` aborts the pipeline. This catches what `c140573` would have caught — the VERCAS / RTLINI / CLKDMN errors that pre-`c140573` were ERROR-class and visible in `src/rtl/` — without needing per-file count baselines.

## 3. YAML fragments (proposed, not applied)

```yaml
# Adds to the existing `lint:` stage; alphabetises before hal-lint.

verilator-lint:
  stage: lint
  needs: [clone, preflight]
  tags: [docker]                  # ordinary linux runner; verilator-4.028+ in container
  script:
    - export TIDELINK_HOME="$WORK_DIR"
    - export ARM_IP_LIBRARY_PATH=/research/AAA/ip_library
    - export CMSDK_DIR="$CMSDK_DIR"
    - export CMSDK_FPGA_SRAM_V="$CMSDK_FPGA_SRAM_V"
    - envsubst < "$WORK_DIR/flist/tidelink_top_full_asic.flist" \
        | grep -v '^//' | grep -v '^#' | grep -v '^$' > /tmp/full.flist.resolved
    - >
      verilator --lint-only -sv -Wall
      -Wno-fatal -Wno-VARHIDDEN -Wno-SYMRSVDWORD
      -Wno-DECLFILENAME -Wno-PINMISSING -Wno-BLKANDNBLK
      --top-module tidelink_top
      $(cat /tmp/full.flist.resolved) 2>&1 | tee verilator_lint.log
    - python3 "$WORK_DIR/lint/scripts/scope_filter.py" \
        --tool verilator --scope src/rtl/ \
        --fail-on error verilator_lint.log
  artifacts:
    when: always
    paths: [verilator_lint.log]
    expire_in: 30 days

# hal-lint already exists at .gitlab-ci.yml:164. The proposal here is to wrap
# the `make lint-each` invocation with the same scope_filter so that ERRORs
# specifically inside src/rtl/ gate the job, while vendor-IP errors do not.

hal-lint:
  # ... existing definition retained ...
  after_script:
    - cp -r "$WORK_DIR/lint/"*_hal.log "$WORK_DIR/lint/"*_hal.xml . 2>/dev/null || true
    - python3 "$WORK_DIR/lint/scripts/scope_filter.py" \
        --tool hal --scope src/rtl/ \
        --fail-on error "$WORK_DIR/lint/"*_hal.log

rdl-lint:
  stage: lint
  needs: [clone, preflight]
  tags: [docker]
  script:
    - cd "$WORK_DIR"
    - python3 -m pip install --user systemrdl-compiler --quiet
    # 1. RDL→C header generation must succeed (catches the regex bug)
    - make -C src/sw clean
    - make -C src/sw generate
    # 2. Compile cocotb wrapper against generated header — _Static_asserts
    #    catch register-layout drift
    - cc -c -I"$WORK_DIR/src/sw" -o /tmp/tw.o \
        "$WORK_DIR/cocotb/tidelink_ahb/tidelink_test_wrappers.c"
    # 3. Sanity: expected register count in the canonical header
    - grep -c '^\s*__IO\|^\s*__I \|^\s*__O ' \
        "$WORK_DIR/src/sw/tidelink_regs.generated.h" \
        | awk '$1 < 40 { print "ERROR: too few fields in tidelink_regs"; exit 1 }'
  artifacts:
    when: on_failure
    paths:
      - src/sw/*.generated.h
    expire_in: 30 days
```

The `lint/scripts/scope_filter.py` would be ~80 lines: read log lines, regex-match `*E,*`/`*W,*` (HAL) or `%Error/%Warning` (Verilator), check the captured `(file,line)` against the `--scope` prefix, emit a markdown summary, exit non-zero if `--fail-on error` and any in-scope ERROR remains.

## 4. Triggers

The three lint jobs run on:

- Every push to `feat/*` branches (developer feedback before MR).
- Every merge request, irrespective of target branch (`$CI_MERGE_REQUEST_IID`).
- Scheduled nightly on `main` to catch silent vendor IP drift.

Explicitly **not on tag pushes** (release builds skip lint; they should run on the commit that was already gated). Use GitLab's `workflow:rules:` rather than `only:` to compose.

```yaml
.lint-trigger: &lint-trigger
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH =~ /^feat\//'
    - if: '$CI_COMMIT_BRANCH == "main" && $CI_PIPELINE_SOURCE == "schedule"'
```

## 5. Failure modes — how to debug from the MR

| Symptom | Likely cause | First-pass debug |
|---------|--------------|------------------|
| `verilator-lint` fails with `WIDTH` ERROR | Width mismatch in a new assign | Look at `verilator_lint.log` artifact; the line/col is in the message; common cause is `assign foo[31:0] = {N{bar}}` where `N*width(bar) != 32` |
| `hal-lint` fails with `CLKDMN` ERROR in a non-`tidelink_phc_cdc.sv` file | New CDC introduced without `lint_checking ... CLKDMN off` scope | Either add an explicit 2-flop synchroniser, OR (if it's a genuine toggle-handshake) add the file path to `lint/hal.design_info` with a justification comment |
| `hal-lint` fails with `RTLINI` ERROR in `src/rtl/` | Variable initialised in declaration | Drop the `= 1'b0`; use `always_ff` reset assignment instead. Today's `tb_early_exit_force_q` fix is the canonical pattern |
| `rdl-lint` fails on `make generate` | RDL syntax error or `systemrdl-compiler` API drift | Run `python3 scripts/rdl2c.py src/rdl/<file>.rdl` locally and read the traceback |
| `rdl-lint` fails on `cc -c tidelink_test_wrappers.c` | `_Static_assert` offset mismatch — generated header drifted from C wrappers | Either fix the RDL to put fields back, or update the offsets in `tidelink_test_wrappers.c`. This is the failure mode that bit today |

Each job uploads its log as a `when: always` artifact (`verilator_lint.log`, `*_hal.log`, `src/sw/*.generated.h`), so the MR reviewer can drill in without re-running.

## 6. Migration plan

The new gates land in two phases to avoid a wall of red on existing in-flight branches:

**Phase 1 (week 1) — advisory.** All three jobs added with `allow_failure: true`. Pipeline reports red/green for visibility but does not block merges. Run for one full week to gather data: do any false positives pop up? Are runners stable? This is the chance to fine-tune `scope_filter.py` and add missing waivers.

**Phase 2 (week 2) — gating.** Drop `allow_failure: true` on Verilator and HAL. Keep `rdl-lint` gating from day one (it is a fast, deterministic check with a clean baseline). Add a brief note to `docs/USER_GUIDE.md` explaining the local-reproduction commands (already in `RTL_LINT_REPORT.md` and `HAL_LINT_REPORT.md` — link to those).

**Rollback plan:** flip `allow_failure: true` back on if a real-world regression in the lint flow blocks an urgent merge. The waiver of last resort is `[skip lint]` in the commit message, gated by `CI_COMMIT_MESSAGE =~ /\[skip lint\]/` — use sparingly, document in MR.

---

**Authors note:** the `c140573`-class HAL ERRORS (`VERCAS`, `RTLINI`, three `CLKDMN`) all live in `src/rtl/` and are exactly what Strategy B's scope filter catches. If today's gates had been in place a week ago, the pre-`c140573` commits that introduced those errors would have failed the MR and the cleanup work captured in `docs/HAL_LINT_REPORT.md` would have happened at PR-review time, not as a separate sign-off pass.

## 7. Companion proposals

This lint plan is one of three CI-design proposals on `feat/td-combined`:

- `docs/CI_LINT_PLAN.md` (this file) — Verilator + HAL + RDL static-analysis gates.
- `docs/CI_FPGA_PLAN.md` — FPGA build + HW reliability runtime gate.
- (TBD) cocotb regression coverage gate.

The three are independent (different stages, different runners) and can land separately. The recommended order is RDL → Verilator → HAL → FPGA → cocotb, because earlier-in-list gates are cheaper to run and catch broader classes of regression.
