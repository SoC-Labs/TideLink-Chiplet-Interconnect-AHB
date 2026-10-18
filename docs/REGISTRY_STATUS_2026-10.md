# Registry status, 2026-10 truth pass

Source: docs/BUG_REGISTRY.yaml (59 entries), reviewed against main eb94efac on 2026-10-16, updated 2026-10-17 after PRs #17, #18, #19 and #20 merged and the TL-038 board re-run.
Each reviewed entry carries a `truth_pass_2026_10` block (status_before, owner, reason, next_step).
No simulation or board run was part of this pass.

## Counts by status

| status | before (10-16) | after truth pass | now (10-17) |
|---|---|---|---|
| open | 6 | 0 | 0 |
| root_caused | 13 | 4 | 2 |
| fix_built | 5 | 4 | 0 |
| sim_proven | 27 | 26 | 31 |
| hw_proven | 1 | 1 | 2 |
| deferred | 3 | 16 | 15 |
| closed | 3 | 7 | 8 |
| wontfix | 1 | 1 | 1 |
| signed_off | 0 | 0 | 0 |

No entry has `signoff.approved: true`; only David sets that.

## Genuinely open (need work, not only a decision)

| id | state | owner | next step |
|---|---|---|---|
| TL-001 | root_caused | David | n=20 eth-pair delivery campaign on main (scripts/hw/RUNBOOK.md) |
| TL-009 | root_caused | David | sustained cross-die write soak with TL-037 in the image |

Closed since the truth pass: TL-018 (hw_proven, PR #20), TL-019 (sim_proven, PR #20; no HW vehicle for the
ASIC flist before silicon), TL-051 and TL-055 (sim_proven, PR #18), TL-057 (sim_proven, PR #17),
TL-038 (closed: 0x23C re-run on KR260, no wedge), TL-035 (sim_proven, PR #19).

## Deferred (waiting on a decision, a board, or another repo)

- David, decision: TL-014, TL-021, TL-024 (waiver), TL-029 (waiver), TL-030, TL-045, TL-049.
- David, board run: TL-011, TL-042.
- eth (ASIC repos): TL-023, TL-028.
- TideLink: TL-031, TL-039, TL-040; tidechart repo: TL-034.

## Ungated fixes (Makefile owner)

TL-055 and TL-057 now have gates (PRs #18, #17). Remaining candidate: TL-058 `make sim-wlink-pair`.
