#!/usr/bin/env python3
"""Red/green control: `make regression` in cocotb/ must be able to FAIL.

WHAT IT PROTECTS. Commit 2ffc21a5 (2026-08-18) inserted the link_rate_* targets
above the "Regression Summary" block in cocotb/Makefile, which left that block
tab-indented directly under

    .PHONY: link_rate_quick link_rate_full

so make read it as the recipe of `.PHONY` -- a target nothing ever builds.
`regression: $(ENVS)` was left with NO recipe, so it exited 0 no matter how many
environments wrote FAIL into their .result. The CI job and the README recipe
reported success unconditionally from 2026-08-18 until 2026-09-11.

Separately, `run_env` had no dry-run guard: its body carries $(MAKE), which GNU
make runs even under -n/-q/-t, so a "dry" run wrote FAIL into every
<env>/.result and truncated every <env>/run.log. Reproduced live 2026-09-11 --
one `make -C cocotb -p -q regression` overwrote all 31 .result files.

HOW IT TESTS. It copies the repo's real cocotb/Makefile into a temp directory
with two stub environments -- one printing a cocotb PASS line, one printing a
FAIL line -- and overrides ENVS. No simulator, no RTL, about a second. The
positive case (all-pass -> exit 0) is the negative control: a Makefile that
failed unconditionally would satisfy the failing case on its own.

THE CONTROL HAS TO BE ABLE TO GO RED, and the two halves go red against two
DIFFERENT breaks. Measured 2026-09-11:

  Against a pre-fix worktree (`git worktree add --detach <dir> <pre-fix commit>`
  then `--repo <dir>`): 1/4 cases pass. The two summary cases and the -n case go
  red -- "one environment FAILs -> rc=0" is the defect itself.

  Against a copy whose run_env DRY-RUN GUARD is stripped but whose regression
  recipe is intact (write the modified cocotb/Makefile under <dir>/cocotb/ and
  pass `--repo <dir>`): 2/4 cases pass. Both dry-run cases go red, writing
  .result and run.log for runs that never happened.

The `-p -q` case is VACUOUSLY GREEN against a pre-fix tree and this is expected,
not an oversight: pre-fix `regression` has no recipe at all, so make never
traverses to the environment targets and nothing runs. It is a guard against
re-breaking the CURRENT shape, and the guard-stripped copy above is what turns
it red. Do not read its green on an old tree as evidence the guard is present.

Run: python3 scripts/ci/tests/test_regression_exit_code.py [--repo DIR]
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
DEFAULT_REPO = HERE.parents[3]

PASS_STUB = 'all:\n\t@echo "** TESTS=1 PASS=1 FAIL=0 SKIP=0"\nclean:\n\t@true\n'
FAIL_STUB = 'all:\n\t@echo "** TESTS=1 PASS=0 FAIL=1 SKIP=0"\nclean:\n\t@true\n'


def build_fixture(td, makefile):
    root = Path(td)
    shutil.copy(str(makefile), str(root / "Makefile"))
    for name, body in (("envgood", PASS_STUB), ("envbad", FAIL_STUB)):
        (root / name).mkdir()
        (root / name / "Makefile").write_text(body)
    return root


def run_make(root, envs, extra=()):
    r = subprocess.run(["make", "-C", str(root), "regression", "ENVS=" + envs,
                        *extra], capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(DEFAULT_REPO))
    args = ap.parse_args()
    makefile = Path(args.repo).resolve() / "cocotb" / "Makefile"
    if not makefile.is_file():
        print("COULD-NOT-EVALUATE: no cocotb/Makefile at %s" % args.repo)
        return 2

    failures = 0

    # ── 1. NEGATIVE CONTROL: all environments pass -> exit 0 ─────────────────
    with tempfile.TemporaryDirectory() as td:
        root = build_fixture(td, makefile)
        rc, out = run_make(root, "envgood")
        ok = rc == 0 and "PASS=1  FAIL=0" in out
        failures += 0 if ok else 1
        print("  %-4s all environments PASS -> rc=%d (want 0)"
              % ("PASS" if ok else "FAIL", rc))
        if not ok and "PASS=1  FAIL=0" not in out:
            print("        the summary table never printed — `regression` has "
                  "no recipe, so nothing scored the results")

    # ── 2. THE DEFECT: one failing environment MUST make it exit non-zero ────
    with tempfile.TemporaryDirectory() as td:
        root = build_fixture(td, makefile)
        rc, out = run_make(root, "envgood envbad")
        ok = rc != 0
        failures += 0 if ok else 1
        print("  %-4s one environment FAILs -> rc=%d (want non-zero)"
              % ("PASS" if ok else "FAIL", rc))
        if not ok:
            print("        `make regression` reported SUCCESS with a failing "
                  "environment. The summary recipe is not attached to the "
                  "`regression` target.")
        if "PASS=1  FAIL=1" not in out:
            print("        (and the summary table did not print)")

    # ── 3. a dry run must write nothing ──────────────────────────────────────
    # The question-mode case is spelled `-p -q`, not bare `-q`, because that is
    # the incantation that actually fired: plain `-q` stops at the first
    # out-of-date prerequisite, but `-p` forces make to walk the whole database
    # and so runs every $(MAKE)-bearing recipe. `make -C cocotb -p -q
    # regression`, issued 2026-09-11 only to READ the database, is what
    # overwrote all 31 <env>/.result files with FAIL.
    for flags, name in ((["-n"], "--dry-run"), (["-p", "-q"], "--print-data-base --question")):
        with tempfile.TemporaryDirectory() as td:
            root = build_fixture(td, makefile)
            subprocess.run(["make", "-C", str(root), *flags, "regression",
                            "ENVS=envgood envbad"],
                           capture_output=True, text=True, timeout=300)
            wrote = sorted(p.name + "/" + q.name
                           for p in root.iterdir() if p.is_dir()
                           for q in p.iterdir()
                           if q.name in (".result", "run.log"))
            ok = not wrote
            failures += 0 if ok else 1
            print("  %-4s `make %s regression` writes nothing (%s)"
                  % ("PASS" if ok else "FAIL", " ".join(flags), name))
            if wrote:
                print("        it wrote: %s" % ", ".join(wrote))
                print("        GNU make runs $(MAKE) lines even under %s; the "
                      "sub-make does nothing, so the result is recorded as "
                      "FAIL for a run that never happened." % " ".join(flags))

    print("\nregression exit-code control: %d/%d cases passed" % (4 - failures, 4))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
