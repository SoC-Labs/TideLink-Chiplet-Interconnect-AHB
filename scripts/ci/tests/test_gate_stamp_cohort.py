#!/usr/bin/env python3
"""Red/green control for the gate provenance stamp and sim_gate_summary.

WHAT IT PROTECTS. Three properties of the stamp, all of which had, or would
have had, a fail-open shape:

  1. THE COHORT STAMP. Every sim_gate suite runs in its own recursive $(MAKE),
     and so does sim_gate_summary; each re-parses the Makefile and re-evaluates
     the `:=` GATE_DIRTY from `git status --porcelain`. The summary was therefore
     comparing gate-START stamps against a gate-END value, so ANY mid-run tree
     change made every .status look "STALE / CROSS-BRANCH" and the gate refused
     PASS naming the wrong cause. sim_gate now records the stamp once into
     $(SIM_GATE_DIR)/.gate_stamp and the summary scores against that, reporting a
     mid-run change as its own verdict, "TREE CHANGED DURING THE RUN".

  2. THE FLIST DIGEST. <sha>-<dirty> identifies the COMMIT, not the FILE SET
     compiled. The stamp carries an md5 of the flist contents so it identifies
     both. This test also pins the property that made the digest safe to add:
     the stamp stays ONE whitespace-free token, because sim_gate_summary parses
     it as field 4 of the .status line (`set -- $$line; stamp=$$4`).

  3. "COULD NOT TELL" MUST NOT LOOK LIKE "FINE". GATE_DIRTY printed `clean` when
     git ERRORED (a failed command produces no output, and `test -n ""` is
     false) -- the same shape as the `git_dirty:false` that shipped in
     build_provenance_fail_open, 2026-08-24. GATE_FLISTS would have digested the
     empty string to a plausible-looking d41d8cd9 when the glob matched nothing.

THE CONTROL HAS TO BE ABLE TO GO RED. Point it at a pre-fix worktree:
    git worktree add --detach <dir> <commit-before-the-fix>
    python3 scripts/ci/tests/test_gate_stamp_cohort.py --repo <dir>
The digest, the unknown-marker and the cohort cases all go red there.

Run: python3 scripts/ci/tests/test_gate_stamp_cohort.py [--repo DIR]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
DEFAULT_REPO = HERE.parents[3]


def make(repo, goals, env=None, **overrides):
    argv = ["make", "-C", str(repo), "--no-print-directory"] + list(goals)
    argv += ["%s=%s" % kv for kv in overrides.items()]
    e = dict(os.environ)
    e["TIDELINK_HOME"] = str(repo)
    if env:
        e.update({k: v for k, v in env.items() if v is not None})
        for k, v in env.items():
            if v is None:
                e.pop(k, None)
    r = subprocess.run(argv, capture_output=True, text=True, env=e, timeout=300)
    return r.returncode, r.stdout + r.stderr


def stamp_of(repo, env=None):
    # --eval injects a throwaway target that prints GATE_STAMP, so the stamp is
    # read from the real Makefile's own evaluation rather than reconstructed.
    argv = ["make", "-C", str(repo), "--no-print-directory",
            "--eval=__print_gate_stamp__:;@echo $(GATE_STAMP)",
            "__print_gate_stamp__"]
    e = dict(os.environ)
    e["TIDELINK_HOME"] = str(repo)
    if env:
        for k, v in env.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
    r = subprocess.run(argv, capture_output=True, text=True, env=e, timeout=300)
    return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""


def status_line(name, verdict, stamp):
    return "%-28s %-4s %6ss %s\n" % (name, verdict, "5", stamp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(DEFAULT_REPO))
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    if not (repo / "Makefile").is_file():
        print("COULD-NOT-EVALUATE: no Makefile at %s" % repo)
        return 2

    rows, failures = [], 0

    def check(label, ok, detail=""):
        nonlocal failures
        rows.append(ok)
        if not ok:
            failures += 1
        print("  %-4s %-44s %s" % ("PASS" if ok else "FAIL", label, detail))

    now = stamp_of(repo)
    print("  stamp under test: %r" % now)

    # ── shape ────────────────────────────────────────────────────────────────
    check("stamp is a single whitespace-free token",
          bool(now) and len(now.split()) == 1,
          "" if now and len(now.split()) == 1
          else "sim_gate_summary reads it as field 4 of the .status line; a "
               "space would shift every later field")
    check("stamp carries a flist digest",
          bool(re.search(r"-f[0-9a-f]{8}$|-fnoflists$", now)),
          "" if re.search(r"-f[0-9a-f]{8}$|-fnoflists$", now)
          else "no -f<digest> suffix: the stamp identifies the commit but not "
               "the file set that was compiled")

    # ── "could not tell" must not read as "fine" ─────────────────────────────
    with tempfile.TemporaryDirectory() as td:
        broken = stamp_of(repo, env={"TIDELINK_HOME": td})
        bad = ("-clean" in broken) or re.search(r"-fd41d8cd9?$", broken)
        check("a repo it cannot read yields an UNKNOWN stamp",
              not bad and bool(broken),
              "" if not bad else "stamp %r claims clean/real-digest for a tree "
                                 "it could not read" % broken)
        print("        (unreadable-repo stamp: %r)" % broken)

    # ── cohort verdicts ──────────────────────────────────────────────────────
    with tempfile.TemporaryDirectory() as td:
        d = Path(td) / "gate"

        def summary(cohort, statuses, suites):
            import shutil
            shutil.rmtree(d, ignore_errors=True)
            d.mkdir(parents=True)
            if cohort is not None:
                (d / ".gate_stamp").write_text(cohort + "\n")
            for name, stamp in statuses:
                (d / (name + ".status")).write_text(status_line(name, "PASS", stamp))
            return make(repo, ["sim_gate_summary"],
                        SIM_GATE_DIR=str(d), SIM_GATE_SUITES=" ".join(suites),
                        SIM_GATE_SENTINELS="")

        rc, out = summary(now, [("suiteA", now)], ["suiteA"])
        check("consistent cohort -> PASS", rc == 0 and "ALL SUITES PASS" in out,
              "" if rc == 0 else "rc=%d" % rc)

        foreign = "deadbeefcafe-clean-fabc12345"
        rc, out = summary(foreign, [("suiteA", foreign)], ["suiteA"])
        check("tree changed mid-run -> named verdict",
              rc != 0 and "TREE CHANGED DURING THE RUN" in out,
              "" if "TREE CHANGED DURING THE RUN" in out
              else "a mid-run tree change is not reported as its own cause "
                   "(rc=%d)" % rc)

        rc, out = summary(now, [("suiteA", now), ("suiteB", foreign)],
                          ["suiteA", "suiteB"])
        check("foreign .status inside a cohort -> STALE",
              rc != 0 and "STALE / CROSS-BRANCH" in out,
              "" if "STALE / CROSS-BRANCH" in out else "rc=%d" % rc)

        rc, out = summary(None, [("suiteA", now)], ["suiteA"])
        check("no cohort file -> falls back to the derived stamp",
              rc == 0 and "ALL SUITES PASS" in out,
              "" if rc == 0 else "ad-hoc single-suite use regressed (rc=%d)" % rc)

    print("\ngate stamp/cohort control: %d/%d cases passed"
          % (len(rows) - failures, len(rows)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
