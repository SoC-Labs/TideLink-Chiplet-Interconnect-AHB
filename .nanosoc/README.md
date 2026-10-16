# .nanosoc/

What the nanoSoC release manager reads from this repository, at the commit it is testing.

| File | What it is |
|---|---|
| `capabilities.yaml` | What TideLink can test: commands, tools, budgets, how to read each verdict, and which `deps/*` moves re-run each one (`affected_by`). Schema: nanoSoC-Release-Manager `schemas/capabilities.schema.json`. |

A superproject that pins TideLink (the ethernet chiplet) names which of these run in its own context under its `compose:` list, by `id`. Keep the ids stable.

## Submodule bumps

A change that moves a `deps/*` pointer needs a passing bump check.

| Where | Strength | How |
|---|---|---|
| Your clone | warns | `make bump-hook` installs `scripts/hooks/pre-push` (or chain it from your own pre-push hook) |
| CI | blocks | `.github/workflows/bump-check.yml`, job `submodule-bump-gate` |
| Release manager | blocks | its bump gate; the authority |

Run the CI check locally: `make bump-check BUMP_BASE=origin/main` (add `RUN_LOCAL=1` on a host with the tools).
Point the hook and the check at the release manager once per clone: `git config nanosoc.rmUrl https://<host>:<port>`.

`scripts/ci/bump_check.py` and its test are copies of the ones in nanosoc-ethernet-chiplet. Keep them identical.
