# fixture: lvs-missing-connection — FAIL BEATS VACUITY

A Calibre LVS report for a layout with **3 nets present in the source netlist
that have no matching layout net**. The correct verdict is **INCORRECT**.

## What it proves

`run_calibre_lvs.sh` used to grade the report as:

```sh
if   grep -q "CORRECT"   "$report"; then  LVS CORRECT
elif grep -q "INCORRECT" "$report"; then  LVS INCORRECT
```

`"INCORRECT"` **contains** `"CORRECT"`, so the first branch matched this report
and the `elif` was unreachable. This fixture contains **3 uppercase INCORRECT
tokens and zero standalone `CORRECT` tokens**, yet the shipped checker graded it
`LVS CORRECT` — and then exited 0, so `make lvs` went green on a mismatch.

`fail beats vacuity`: a checker that cannot distinguish these two reports is not
a checker. The regression control is `ci/checker_controls/control_lvs.sh`.

## Sibling fixtures

| fixture                    | expected verdict     | exit |
|----------------------------|----------------------|------|
| `lvs-missing-connection/`  | `INCORRECT`          | 1    |
| `lvs-clean/`               | `CORRECT`            | 0    |
| `lvs-truncated/`           | `COULD-NOT-EVALUATE` | 2    |
| `lvs-empty/`               | `COULD-NOT-EVALUATE` | 2    |
| *(no file at all)*         | `COULD-NOT-EVALUATE` | 2    |

`lvs-empty/` reproduces the **real** state observed on disk at
`syn/asic/calibre/work/tidelink_top_lvs.rep` — a 0-byte report from a Calibre
run that died in circuit extraction (exit 4). Indeterminate must never grade as
clean.
