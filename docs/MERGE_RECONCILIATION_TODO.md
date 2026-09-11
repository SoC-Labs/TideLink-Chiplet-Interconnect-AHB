# Merge reconciliation — kr260_sysval T6  ·  **RESOLVED 2026-09-11**

Created 2026-08-26 during the rev2/integration consolidation. **This was a real
outstanding item, not a nit.** It was recorded here rather than resolved at merge
time because resolving it correctly needed a decision, not a patch.

> **STATUS: CLOSED on branch `rev2/land-prep`.** The `rc=3` row is decided (below,
> "How it was closed"), the T6 delivery check reads its answer again, and the
> control is back in `make selfcheck_gates`. The rest of this file is kept as the
> record of what the disagreement WAS — deleting it would lose the reason the
> decision went the way it did.

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

## What WAS true on rev2/integration (before 2026-09-11)

The harness-repair version is in place. **The T6 defect is therefore still present:**
`t6_endurance()` still discards its final delivery check. The fix-falsegreen control
(`scripts/ci/tests/test_kr260_sysval_t6.py`) was removed because it tested
`verify_verdict()`, a helper this version does not have — a control that cannot run
is not a control, and leaving it disabled in `selfcheck_gates` would be a false green.

## What had to be decided, not guessed

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


---

## How it was closed (2026-09-11, branch `rev2/land-prep`)

### 1. The `rc=3` row: **the MARKER decides, not the exit code**

Neither branch's rule was adopted wholesale, because neither exit code alone
carries the information. `classify()` already states the principle this file
lives by — *"proof of execution beats any transport guess: if the board's own
output marker is in stdout then the command ran, whatever the exit code"* — and
the board's `VERIFY` marker is exactly that proof. So the disputed row splits:

| case | verdict | why |
|---|---|---|
| `rc=3`, output present, marker **PRESENT** | `FAIL` (`DATA_MISMATCH`) | the verify body ran and disagreed. A real result. This is harness-repair's answer. |
| `rc=3`, output present, marker **ABSENT** | `INCONCLUSIVE` (`BOARD_ERROR`) | a traceback, a sudo failure, a `/dev/mem` EPERM or a corrupted first line. There is **no evidence the verify body executed**, so there is no data verdict to report. This is fix-falsegreen's answer. |

The same split settles the other disputed rows:

| case | harness-repair wanted | fix-falsegreen wanted | **decided** |
|---|---|---|---|
| `rc=255`, no output | `TRANSPORT_ERROR` → `None` | `INCONCLUSIVE` → `False` | `INCONCLUSIVE`, returning `False`. The *kind* stays `TRANSPORT_ERROR` in the record (harness-repair's vocabulary, which is strictly more informative), the *verdict* is `INCONCLUSIVE` (fix-falsegreen's, which is the one that appears in the JSON counts). Nothing is lost. |
| verdict vocabulary | `OK`/`TIMEOUT`/`TRANSPORT_ERROR` | `PASS`/`FAIL`/`INCONCLUSIVE` | **both, at different layers.** `verify_verdict()` returns `(verdict, detail, info_kind)`: the verdict is the `PASS`/`FAIL`/`INCONCLUSIVE` the summary counts, the kind is the transport/board classification stamped into `info`. They were never actually in conflict — one names the outcome, the other names the cause. |

Decisive point: this is **the same rule `t3_delivery_soak` was already applying**
one screen above in the same file (it records `INCONCLUSIVE` / `BOARD_ERROR`
when `VERIFY` is missing from the output). T3 and T6 now agree instead of
disagreeing silently, which was the worst property of the pre-merge state.

### 2. The T6 delivery check reads its answer

`pynq_host/scripts/kr260_sysval.py`: `verify_verdict(r, n, marker="VERIFY")` is a
pure function over a `Res`, and `t6_endurance()` records what it returns. Its four
dependencies (`board` / `obs` / `por_die_a` / `record`) are injectable, defaulting
to the real ones, so the whole function can be driven with no ssh and no KR260.

POR policy follows T10's, and is asserted in the control: POR on a **wedge**
(`rc=124`), never on a mismatch (the link is alive and returning wrong data; a
reset destroys the only state that explains it) and never on `INCONCLUSIVE`.
`SYSVAL_POR_ON_MISMATCH=1` remains the documented opt-in.

### 3. The control is rewritten against the PRODUCTION classifier

`scripts/ci/tests/test_kr260_sysval_t6.py` builds every specimen through
`SV.classify` / `SV.Res` rather than a copy of them, per step 3 of the original
plan, so it exercises the real transport contract. 19 checks, including **both
halves of the `rc=3` row**, so a future merge that silently picks one semantics
over the other goes red here rather than in silicon.

It is picked up automatically by `make selfcheck_gates` (which globs
`scripts/ci/tests/test_*.py`), and `selfcheck_gates` is now a prerequisite of
`sim_gate`.

**Proven red before being trusted:** with the pre-fix (merge `77db1c5`) copy of
`kr260_sysval.py` restored, the control exits 1.

### 4. Both invariants survive, and each has a case

* **T6 can report a delivery failure** — `delivery mismatch (marker present)`
  records `FAIL` / `DATA_MISMATCH` and returns `False`. Pre-fix: `PASS`.
* **A dead ssh is never reported as a data mismatch** — asserted directly, not
  inferred: two `rc=255` specimens are checked for `info.kind != DATA_MISMATCH`.
