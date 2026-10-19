# CI runner: self-hosted GitHub Actions runner for the sim gate

Workflow: `.github/workflows/sim-gate.yml`. Driver: `ci/sim_gate_ci.sh`.

| Trigger | Job (status-check name) | What runs | Budget |
|---|---|---|---|
| `pull_request` to `main` | `sim_gate_quick` | gate self-checks, registry coverage, host-address lint, registry HTML freshness, `make fc_sva`, `make sim_gate_quick` | job timeout 120 min |
| nightly 01:17 UTC, or manual `mode=full` | `sim_gate_full` | same static checks, full `make sim_gate`, `make fc_sva_full`, VC Formal proof if `TL_RUN_FORMAL=1` | job timeout 360 min |

A job is red when the driver writes `GATE_EXIT != 0`. The driver exits 0 once it has produced its
files, so artifacts are always uploaded; a final step then fails the job from `GATE_EXIT`.
Artifacts (30 days): `summary.txt`, per-step logs, `sim_gate/*.status` and `*.log`, `fc_sva/summary.txt`.

## 1. Register the runner (David, needs repo admin)

Do this on the lab server that has VCS, as the unprivileged user that owns the licences. Do not run it as root.

1. GitHub: repository `SoC-Labs/TideLink-Chiplet-Interconnect-AHB` -> Settings -> Actions -> Runners -> New self-hosted runner -> Linux x64.
   GitHub shows a download URL and a short-lived registration token (about 1 hour). The token needs repo admin. Do not store it anywhere.
2. Follow the download/extract commands GitHub shows, into a directory outside any repo checkout (for example `~/actions-runner-tidelink`).
3. Configure with exactly these labels (the workflow selects `[self-hosted, linux, vcs]`; `self-hosted` and `linux` are added automatically):
   ```
   ./config.sh --url https://github.com/SoC-Labs/TideLink-Chiplet-Interconnect-AHB \
               --token <TOKEN-FROM-THE-PAGE> --labels vcs --name tidelink-vcs-1 --work _work
   ```
4. Create `<runner dir>/.env` (see section 2), then install and start it as a service so it survives logout:
   ```
   sudo ./svc.sh install <runner-user>      # or run ./run.sh under tmux if you have no sudo
   sudo ./svc.sh start
   ```
   Re-read `.env` by restarting the service after every edit.
5. Check: Settings -> Actions -> Runners shows `tidelink-vcs-1` Idle with labels `self-hosted, Linux, X64, vcs`.
   Then run Actions -> sim-gate -> Run workflow (mode `quick`) once by hand.

## 2. Environment the runner needs

Set in `<runner dir>/.env` (KEY=value lines, no `export`). None of these live in the repo.

| Variable | Meaning |
|---|---|
| `CHIPLET_HOME` | pinned external chiplet tree for the gates (the "pinned-chiplet-home" at commit 1ef68f1). Unpinned = tc_pair suites FAIL in seconds. |
| `TIDECHART_HOME` | pinned TideChart tree. |
| `TL_SITE_ENV` | absolute path of the lab `site.env` (tool and IP roots; see `site.env.example`). The driver copies it to `./site.env` (mode 600). Never committed, never printed, never uploaded. |
| `TL_XHB500_GENERATED` | directory holding the generated XHB500 files; copied to `deps/xhb500/generated` when absent. |
| `TL_RUN_FORMAL=1` | optional: also run the VC Formal proof and its mutant in the nightly. |
| `PATH`, `LM_LICENSE_FILE`, `SNPSLMD_LICENSE_FILE` | VCS, Verdi and Python on `PATH`; licence servers as for an interactive shell. Put them in `.env` or in the service user's profile. |

The driver stops with exit 3 and a `::error::` line naming the missing variable.

Software on the runner: VCS (the version used by `set_env.sh`), Python 3 with cocotb as in `set_env.sh`, `git` with
submodule support, `bash`. VC Formal (`module load vc_formal`) only for the optional formal step. Git submodule URLs must be
reachable from the runner (`actions/checkout` fetches them recursively with the job token; if a submodule is in a private repo,
add a read-only deploy key or PAT as a secret and pass it to checkout `token:`).

## 3. Licences and concurrency

- One runner, one job at a time. Quick and full gates both use many VCS licences and the full gate compiles four-plus simulators.
  Do not register a second runner on the same host. Queued jobs wait; a newer push to the same PR cancels that PR's older run.
- The nightly and a PR run can collide: the PR job waits for the nightly (up to 6 h). Move the cron if that hurts.
- Hosts are shared with interactive users: runs are sequential and the SVA target runs one simulation at a time.
- If licences are exhausted the failure appears as a compile error in a `*.log`; re-run the job, do not edit the gate.

## 4. Make the quick gate a required check on `main`

Requires one green run first (the check name must have reported once).

1. Settings -> Branches -> Add branch protection rule (or Rulesets -> New branch ruleset), branch name pattern `main`.
2. Enable: Require a pull request before merging; Require status checks to pass before merging; Require branches to be up to date.
3. In the status-check search add `sim_gate_quick`. Do not add `sim_gate_full` (it does not run on PRs).
4. Optional: Do not allow bypassing the above settings.

With the CLI: `gh api -X PUT repos/SoC-Labs/TideLink-Chiplet-Interconnect-AHB/branches/main/protection --input protection.json`
with `required_status_checks.contexts = ["sim_gate_quick"]`, `strict = true`, `required_pull_request_reviews`, `enforce_admins`, `restrictions = null`.

## 5. Security notes (self-hosted runner)

- The job runs PR code with the runner user's rights and licences. The workflow only runs for PRs whose head repo is this repo
  (forks are skipped). A skipped required check counts as passed, so keep forking disabled or set Settings -> Actions ->
  General -> "Require approval for all outside collaborators".
- The workflow has `permissions: contents: read` and no secrets. Keep it that way.
- No path filters on purpose: a required check skipped by `paths-ignore` never reports and blocks the PR.

## 6. Known gaps

- `make sim_gate_inventory` exits 2 on main eb94efac (lists the whole suite list as ORPHAN) and is therefore not in the driver.
- The quick gate runtime is not yet measured on this runner (plan estimate: 25 to 40 minutes); set the timeout after the first run.
- `.gitlab-ci.yml` is stale (documents 204 cocotb tests; the gate has 87) and is not used by this workflow.
