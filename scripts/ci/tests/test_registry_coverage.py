#!/usr/bin/env python3
"""Red/green control for scripts/ci/registry_coverage.py (false-green B7).

The checker promises that "every bug that CLAIMS gate coverage
(verification.in_sim_gate: true) must name a resolvable, existing test -> else
HARD FAIL". Until 2026-08-26 it did not: the existence check was guarded by
`if files and missing:`, so a `sim_test` naming no `.py` at all produced
`files == []`, skipped the check, and the bug still counted as covered. That
applied to 7 of the 17 gated bugs.

This harness feeds synthetic one-bug registries to the real checker and asserts
its exit code and message, so the promise is mechanically enforced rather than
asserted in a docstring. Each specimen is a shape the old code scored as
COVERED.

Run: python3 scripts/ci/tests/test_registry_coverage.py
"""

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
CHECKER = REPO / "scripts" / "ci" / "registry_coverage.py"
MAKEFILE = REPO / "Makefile"


def registry(sim_test, status="sim_proven", in_gate=True):
    gate = "true" if in_gate else "false"
    return (
        "bugs:\n"
        "  - id: TL-999\n"
        "    title: synthetic specimen\n"
        "    severity: low\n"
        "    status: %s\n"
        "    verification:\n"
        "      sim_test: %s\n"
        "      in_sim_gate: %s\n" % (status, sim_test, gate)
    )


def run(reg_text):
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "reg.yaml"
        p.write_text(reg_text)
        r = subprocess.run(
            [sys.executable, str(CHECKER),
             "--registry", str(p), "--makefile", str(MAKEFILE)],
            capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


# (label, sim_test value, expected rc, substring expected in output)
CASES = [
    # --- must PASS: each of the four referent kinds resolves ---------------
    ("resolvable .py file",
     "'cocotb/tidelink_top_pair_v2/test_v2_pair_data.py'", 0, "COVERAGE OK"),
    ("resolvable sim_gate target",
     "'sim_gate_tc_election'", 0, "COVERAGE OK"),
    ("resolvable suite label",
     "'sim_gate sentinel xfail_f14b_datamode_wedge (XFAIL tolerated)'",
     0, "COVERAGE OK"),
    ("resolvable cocotb directory",
     "'cocotb/tidelink_fifo `make randinit`'", 0, "COVERAGE OK"),

    # --- must FAIL: the B7 specimens ---------------------------------------
    # Free text with no checkable referent. THIS is the shape that used to be
    # scored as covered because `files == []` short-circuited the check.
    ("uncheckable free text",
     "'ran it by hand on the bench, looked fine'", 1, "NOTHING CHECKABLE"),
    ("dangling sim_gate target",
     "'sim_gate_this_target_does_not_exist'", 1, "dangling referent"),
    ("dangling .py file",
     "'cocotb/nowhere/test_does_not_exist.py'", 1, "dangling referent"),
    ("dangling cocotb directory",
     "'cocotb/this_directory_does_not_exist'", 1, "dangling referent"),
    ("empty sim_test",
     "''", 1, "sim_test is empty"),
    ("sim_test: none",
     "'none'", 1, "sim_test is empty"),
]


def main():
    if not CHECKER.is_file():
        print("COULD-NOT-EVALUATE: checker not found at %s" % CHECKER)
        return 2

    failures = 0
    for label, sim_test, want_rc, want_text in CASES:
        rc, out = run(registry(sim_test))
        ok = (rc == want_rc) and (want_text in out)
        if ok:
            print("  PASS  %-28s rc=%d" % (label, rc))
        else:
            failures += 1
            print("  FAIL  %-28s rc=%d (wanted %d)" % (label, rc, want_rc))
            if want_text not in out:
                print("        expected text not found: %r" % want_text)
            for line in out.splitlines():
                print("        %s" % line)

    # A checker that fails EVERYTHING would satisfy the negative cases alone,
    # so the four positive cases above are the negative control. Assert that
    # split explicitly rather than trusting the count.
    n_pass_cases = sum(1 for c in CASES if c[2] == 0)
    n_fail_cases = sum(1 for c in CASES if c[2] == 1)
    if n_pass_cases < 4 or n_fail_cases < 4:
        print("COULD-NOT-EVALUATE: the case list lost its red/green balance "
              "(%d green, %d red)" % (n_pass_cases, n_fail_cases))
        return 2

    print("registry_coverage self-test: %d/%d cases passed"
          % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
