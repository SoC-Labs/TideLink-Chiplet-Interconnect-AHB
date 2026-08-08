# TideLink regression-prevention harness — run-each-time playbook

Two cooperating layers keep bugs fixed and stop new regressions. The registry
(`docs/BUG_REGISTRY.yaml`) is the single source of truth binding them.

## Layer 1 — the deterministic gate (runs every commit / CI; NOT Claude)

`make sim_gate` is now **tip-stamped, fail-loud, and coverage-checked** so a green
summary provably belongs to the current commit (the 2026-08 audit proved the old
gate could report a *different branch's* run as green).

| Command | Use |
|---|---|
| `make sim_gate_regressions` | **The authoritative CI entrypoint.** Runs registry coverage, then the tip-stamped fail-loud aggregate. Use this, not bare `make sim_gate`. |
| `make sim_gate_registry_coverage` | Static, no sim: fails if any `in_sim_gate: true` bug lacks a resolvable test; flags fixed-but-ungated bugs. `REGCOV_ARGS=--strict` also fails on ungated fixed bugs. |
| `make sim_gate_one TOKEN=sim_gate_v2_data SUITE=v2_pair_data` | Sanctioned single-suite run that **propagates failure** (bare `make sim_gate_<x>` records status and exits 0 — never trust it for verification). |

Guarantees now enforced:
- **Provenance**: every `.status` carries `<sha>-<dirty>`; the summary refuses PASS unless all match the current tip (kills cross-branch / stale false-green).
- **Exit-on-FAIL**: single-suite / CI runs exit non-zero on FAIL (`SIM_GATE_NONFATAL=1` opts into record-and-continue, which only the aggregate uses).
- **Coverage**: every registry bug marked `in_sim_gate: true` must name a real, resolvable test.

**Rule:** never claim "gate green" from `imp/sim_gate/` contents alone — only from a
fresh `make sim_gate_regressions` on a clean checkout of the tip under test.

## Layer 2 — the dynamic Claude bug-lifecycle workflow (run on demand)

`.claude/workflows/tidelink-bug-lifecycle.js` — invoke with
`Workflow({name: "tidelink-bug-lifecycle"})`. Each run it **discovers the current
state** (runs coverage, reads the live gate failures + ungated fixed bugs), then:

1. **Triage** — one independent agent per failing suite / gap: *stale-test* (the test
   encodes old behavior a deliberate fix changed → update it) vs *real functional
   break* (RTL regressed → fix / gate / decision).
2. **Verify** — a stale-test fix is only "safe" if the updated test still FAILS on a
   reverted RTL (non-vacuous); otherwise it becomes a proposal, not an auto-commit.
3. **Synthesize** — auto-apply the sim-verified low-risk fixes (test updates, flist
   fixes, gate coverage), and surface anything netlist-affecting or a tradeoff (the
   calibrator HW levers) as a decision.

Every fix it lands must add/point a gating test so Layer 1 pins it forever — a fix
is not "done" until `make sim_gate_registry_coverage` shows it covered.

## When to run what

- **Every commit / MR**: `make sim_gate_regressions` (Layer 1).
- **After a gate goes red, or periodically to hunt bugs**: the Layer-2 workflow.
- **Before trusting any "green"**: confirm the stamp in the summary is the current tip.
