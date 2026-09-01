#!/usr/bin/env python3
"""cov_identity_selftest.py - prove the identity contract FAILS CLOSED.

    python3 scripts/coverage/cov_identity_selftest.py

Offline: builds throwaway git repositories in a temp directory, and for the one
case that cannot be staged with real git (a `git status` that fails while
`git rev-parse` succeeds) it substitutes the subprocess runner directly. No
network, no simulator, no store.

WHY THIS EXISTS AS ITS OWN PROGRAM
----------------------------------
The bug this contract is written against did not look like a bug. It looked
like a manifest, it parsed, every field was populated, and it said the build
was clean. `git_dirty:false` meant "could not evaluate the tree", and one
artifact was stamped `source_commit:"unknown"` AND clean in the same document.
Nothing failed. That is why the fail-closed rules need a test that asserts the
NEGATIVE -- that certain values are impossible -- rather than a test that the
happy path produces a document.

The three assertions that matter are 2, 3 and 4 below. If any of them ever goes
red, the manifest has started lying again in the same direction as last time.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cov_identity as ci  # noqa: E402

OK = True


def say(what, cond):
    global OK
    print("  %-66s %s" % (what, "ok" if cond else "FAIL"))
    OK = OK and cond


def git(repo, *args):
    subprocess.run(["git", "-C", repo] + list(args), check=True,
                   capture_output=True)


def make_repo(dirty=False):
    d = tempfile.mkdtemp(prefix="covid-")
    git(d, "init", "-q")
    git(d, "config", "user.email", "selftest@example.invalid")
    git(d, "config", "user.name", "selftest")
    os.makedirs(os.path.join(d, "flists"), exist_ok=True)
    with open(os.path.join(d, "flists", "tidelink.flist"), "w") as fh:
        fh.write("# selftest\n")
    git(d, "add", "-A")
    git(d, "commit", "-qm", "selftest")
    if dirty:
        with open(os.path.join(d, "flists", "tidelink.flist"), "a") as fh:
            fh.write("# modified after commit\n")
    return d


def scope_file():
    fd, p = tempfile.mkstemp(prefix="scope-", suffix=".txt")
    os.write(fd, b"own | */src/rtl/* | selftest rule\n")
    os.close(fd)
    return p


def main():
    print("cov_identity selftest (offline)")
    scope = scope_file()

    # ---- 1. a clean repo reads clean, and gets a real closure --------------
    clean = make_repo(dirty=False)
    ident = ci.build_identity(clean, scope, ["tidelink.flist"], (), tools=False)
    # tools=False leaves the tool fields UNVERIFIED on purpose, so probe the
    # git half in isolation first.
    say("clean repo -> tree_state == 'clean'", ident["tree_state"] == "clean")
    say("clean repo -> source_commit is a 40-hex sha",
        len(ident["source_commit"]) == 40 and not ci.is_unverified(ident["source_commit"]))

    # ---- 2. THE REGRESSION TEST: rev-parse fails -> NEVER clean ------------
    notrepo = tempfile.mkdtemp(prefix="covid-notrepo-")
    ident2 = ci.build_identity(notrepo, scope, [], (), tools=False)
    say("non-repo -> source_commit is UNVERIFIED",
        ci.is_unverified(ident2["source_commit"]))
    say("non-repo -> tree_state is NOT 'clean'  <<< the 2026-08-24 bug",
        ident2["tree_state"] != "clean")
    say("non-repo -> tree_state is UNVERIFIED (not silently 'dirty' either)",
        ci.is_unverified(ident2["tree_state"]))

    # ---- 3. status fails while rev-parse succeeds -------------------------
    # This is the exact shape of the real failure: rc=128 "expected submodule
    # path ... not to be a symbolic link". Real git will not produce it on
    # demand, so the runner is substituted for the length of this one check.
    real_run = ci._run

    def flaky(cmd, cwd=None, timeout=60):
        if "status" in cmd:
            return False, ("rc=128 fatal: expected submodule path "
                           "'deps/xhb500' not to be a symbolic link")
        return real_run(cmd, cwd=cwd, timeout=timeout)

    ci._run = flaky
    try:
        ident3 = ci.git_identity(clean)
    finally:
        ci._run = real_run
    say("rev-parse OK + status rc=128 -> tree_state NOT 'clean'",
        ident3["tree_state"] != "clean")
    say("  ...and the reason is recorded, not discarded",
        "submodule" in ident3["tree_state"])
    say("  ...and source_commit is still the real sha (not thrown away)",
        len(ident3["source_commit"]) == 40)
    say("NEVER: a known commit with an unevaluable tree scored clean",
        not (len(ident3["source_commit"]) == 40
             and ident3["tree_state"] == "clean"))

    # ---- 4. a dirty tree has NO closure id --------------------------------
    dirty = make_repo(dirty=True)
    identd = ci.build_identity(dirty, scope, ["tidelink.flist"], (), tools=False)
    say("dirty repo -> tree_state == 'dirty'", identd["tree_state"] == "dirty")
    cid, why = ci.closure_id(identd, ["suite_a"])
    say("dirty repo -> input_closure_id is UNVERIFIED (a dirty tree is not "
        "recoverable from any commit)", ci.is_unverified(cid))

    # a clean tree WITH everything measured does get one
    identc = dict(ident)
    identc["tool"] = {"vcs": "T-2022.06-SP2"}
    identc["xhb500_digest"] = "0" * 64
    identc["submodule_pins"] = {}
    cidc, _ = ci.closure_id(identc, ["suite_a"])
    say("clean + fully measured -> a real 64-hex closure id",
        not ci.is_unverified(cidc) and len(cidc) == 64)

    # ---- 5. two indeterminate closures must not be a stable equal ----------
    # The id itself is a LITERAL string, so it CAN be equal -- which is why the
    # comparison side (cov_diff.cell_2x2) refuses on the marker rather than on
    # inequality. Assert the marker survives, so that refusal has something to
    # key on.
    say("an UNVERIFIED closure id carries its reason for the diff to refuse on",
        cid.startswith("UNVERIFIED:") and len(cid) > len("UNVERIFIED:"))

    # ---- 6. a suite with no .status is UNVERIFIED, never PASS -------------
    sd = tempfile.mkdtemp(prefix="covid-suites-")
    with open(os.path.join(sd, "suite_a.status"), "w") as fh:
        fh.write("suite_a PASS 12s\n")
    with open(os.path.join(sd, "suite_c.status"), "w") as fh:
        fh.write("suite_c XFAIL known defect\n")
    v = ci.suite_verdicts(sd, ["suite_a", "suite_b", "suite_c"])
    say("suite with a PASS status reads PASS", v["suite_a"] == "PASS")
    say("suite with NO status file is UNVERIFIED, not PASS and not absent",
        ci.is_unverified(v["suite_b"]) and "no-status" in v["suite_b"])
    say("an XFAIL sentinel is not laundered into PASS", v["suite_c"] == "XFAIL")

    # ---- 7. the run tag is self-describing --------------------------------
    say("a dirty run tag says so in its name",
        ci.run_tag(identd).endswith("-dirty"))
    say("an unknown-commit run tag says so in its name",
        "unknowncommit" in ci.run_tag(ident2))

    # ---- 8. unverified_fields finds them all, by path ----------------------
    bad = ci.unverified_fields({"a": {"b": ci.unverified("x")},
                                "c": ["ok", ci.unverified("y")]})
    say("unverified_fields reports dotted paths",
        sorted(bad) == ["a.b", "c.1"])

    print("cov_identity selftest: %s" % ("PASS" if OK else "FAIL"))
    return 0 if OK else 1


if __name__ == "__main__":
    sys.exit(main())
