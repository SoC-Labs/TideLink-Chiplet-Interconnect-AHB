#!/usr/bin/env python3
"""Red/green control for the PYNQ host-test exit verdict (false-green C11).

`pynq_host/test_loopback_pair.py` and `pynq_host/test_single_instance.py`
tallied a `failed` counter, printed it, and ended. Neither file contained a
single `exit`/`sys.exit`, so both always exited 0 — a board failing every check
scored as a pass to any caller reading `$?`.

Two halves, because either alone would be decoration:

  A. UNIT — drive pynq_host/hosttest_verdict.summarise_and_exit() with injected
     out/exit and assert the three verdicts (PASS / FAIL / COULD-NOT-EVALUATE).

  B. STRUCTURAL — AST-scan the host test scripts and assert each one actually
     terminates on a non-zero code. This is the half that fails against the
     pre-fix tree: the scan finds zero exit paths.

The scripts themselves need /dev/mem and a real board, so they cannot be
executed here; the AST scan is the strongest hardware-free statement about
them, and it is exactly the evidence that identified the defect.

Run: python3 scripts/ci/tests/test_hosttest_verdict.py
"""

import ast
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "pynq_host"))

from hosttest_verdict import (  # noqa: E402
    EXIT_COULD_NOT_EVALUATE, EXIT_FAIL, EXIT_PASS, summarise_and_exit, verdict,
)

# Scripts that must exit non-zero when their checks fail.
SCRIPTS = [
    REPO / "pynq_host" / "test_loopback_pair.py",
    REPO / "pynq_host" / "test_single_instance.py",
    REPO / "pynq_host" / "test_td_artifact.py",   # the pattern the others copy
]

EXIT_CALLS = {"exit", "_exit", "summarise_and_exit"}


def has_exit_path(tree):
    """True if the module can terminate the process with a non-zero code."""
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        name = None
        if isinstance(f, ast.Name):
            name = f.id
        elif isinstance(f, ast.Attribute):
            name = f.attr
        if name in EXIT_CALLS:
            return True
    return False


def unit_cases():
    results = []

    def drive(passed, failed):
        lines = []
        codes = []
        summarise_and_exit(passed, failed, name="control",
                           out=lines.append, exit_fn=codes.append)
        return codes[0], "\n".join(lines)

    rc, out = drive(9, 0)
    results.append(("all checks passed -> 0", rc == EXIT_PASS and "PASS" in out))

    rc, out = drive(8, 1)
    results.append(("one check failed -> 1", rc == EXIT_FAIL and "FAIL" in out))

    rc, out = drive(0, 0)
    results.append(("no checks ran -> 2",
                    rc == EXIT_COULD_NOT_EVALUATE
                    and "NOT a pass" in out))

    # The pure function must agree with the printing wrapper.
    results.append(("verdict() pure agrees",
                    verdict(3, 0) == EXIT_PASS
                    and verdict(3, 1) == EXIT_FAIL
                    and verdict(0, 0) == EXIT_COULD_NOT_EVALUATE))
    return results


def structural_cases():
    results = []
    scanned = 0
    for path in SCRIPTS:
        if not path.is_file():
            results.append(("%s exists" % path.name, False))
            continue
        scanned += 1
        tree = ast.parse(path.read_text(errors="replace"))
        results.append(("%s can exit non-zero" % path.name, has_exit_path(tree)))
    # COULD-NOT-EVALUATE guard on the scan itself.
    results.append(("scanned all %d host scripts" % len(SCRIPTS),
                    scanned == len(SCRIPTS)))
    return results


def main():
    failures = 0
    total = 0
    for label, ok in unit_cases() + structural_cases():
        total += 1
        if ok:
            print("  PASS  %s" % label)
        else:
            failures += 1
            print("  FAIL  %s" % label)
    if total < 8:
        print("COULD-NOT-EVALUATE: only %d cases ran" % total)
        return 2
    print("hosttest_verdict self-test: %d/%d cases passed" % (total - failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
