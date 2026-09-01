# Outstanding merge reconciliation — kr260_sysval T6

Created 2026-08-26 during the rev2/integration consolidation. **This is a real
outstanding item, not a nit.** It is recorded here rather than resolved at merge
time because resolving it correctly needs a decision, not a patch.

## What happened

Two branches independently fixed `pynq_host/scripts/kr260_sysval.py`:

- **`rev2/harness-repair`** — the transport fix. `classify()` / `Res` / ControlMaster,
  so an ssh reset is TRANSPORT_ERROR rather than a fabricated data mismatch. Proven
  on real hardware in both directions. **This is the version that was taken.**
- **`rev2/fix-falsegreen` item 10** — the T6 fix. `t6_endurance()` ran its final
  delivery check and **discarded the result**, recording PASS unconditionally, so T6
  could not report a delivery failure at all. That fix added `verify_verdict()` plus
  dependency injection, and a 10-case control.

Neither was built on the other. They are not textually mergeable.

## What is currently true on rev2/integration

The harness-repair version is in place. **The T6 defect is therefore still present:**
`t6_endurance()` still discards its final delivery check. The fix-falsegreen control
(`scripts/ci/tests/test_kr260_sysval_t6.py`) was removed because it tested
`verify_verdict()`, a helper this version does not have — a control that cannot run
is not a control, and leaving it disabled in `selfcheck_gates` would be a false green.

## What must be decided, not guessed

Re-applying the T6 fix in the harness-repair idiom is easy. The two APIs disagree on
semantics, and the disagreement is real:

| case | harness-repair | fix-falsegreen control expected |
|---|---|---|
| `rc=255`, no output | `TRANSPORT_ERROR` -> return `None` | `INCONCLUSIVE` -> return `False` |
| `rc=3`, output present, marker absent | `FAIL` (it ran and failed) | `INCONCLUSIVE` (conservative) |
| verdict vocabulary | `OK` / `TIMEOUT` / `TRANSPORT_ERROR` | `PASS` / `FAIL` / `INCONCLUSIVE` |

The `rc=3` row is the one that matters: a command that **ran** and returned non-zero
without emitting its marker is either a genuine failure or an ambiguous one, and which
you choose changes what a red T6 means. Picking silently during a merge is how the
original relabel-a-transport-error-as-a-mismatch bug was introduced.

## To close it

1. Decide the `rc=3`-with-output row.
2. Re-apply the T6 delivery check using `board(..., marker="VERIFY")` and the `Res`
   contract (a draft existed and worked — it detected the injected mismatch).
3. Rewrite the control against `SV.classify` / `SV.Res` so it exercises the production
   classifier rather than a copy of it, and re-add it to `selfcheck_gates`.

Both invariants must survive: **T6 must be able to report a delivery failure**, and
**a dead ssh must never be reported as a data mismatch**.
