#!/usr/bin/env python3
"""Red/green control: the sim gate must not dirty its own tree.

WHAT IT PROTECTS. cocotb/tidelink_a2l_replay_cdc/Makefile selects a DUT-source
include file and writes it with a PARSE-TIME `$(shell echo ... > ...)`, so every
invocation of that bench rewrites it. Until 2026-09-11 the target was four
TRACKED files, cocotb/tidelink_a2l_replay_cdc/dut_src{,_1,_3,_5}.f, and the
content written was this worktree's ABSOLUTE path. `make sim_gate` therefore
dirtied its own tree partway through: GATE_STAMP flipped from <sha>-clean to
<sha>-dirty and sim_gate_summary refused to report PASS. Measured 2026-09-09 on
cba9774d -- a genuine 68 PASS / 3 FAIL / 3 XFAIL run produced 38 clean + 36
dirty stamps and exited 2.

THE CONTROL HAS TO BE ABLE TO GO RED, or it is decoration. Point it at a
pre-fix tree and every case below fails:

    git worktree add --detach /tmp/prefix <commit-before-the-fix>
    python3 scripts/ci/tests/test_gate_selfclean.py --repo /tmp/prefix

Run: python3 scripts/ci/tests/test_gate_selfclean.py [--repo DIR]
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
DEFAULT_REPO = HERE.parents[3]

BENCH = "cocotb/tidelink_a2l_replay_cdc"
FLISTS = ["flists/tidelink_a2l_replay_cdc%s.flist" % t for t in ("", "_1", "_3", "_5")]


def git(repo, argv):
    r = subprocess.run(["git", "-C", str(repo)] + argv,
                       capture_output=True, text=True)
    return r.returncode, r.stdout


class Results:
    def __init__(self):
        self.rows = []

    def check(self, label, ok, detail=""):
        self.rows.append((label, ok, detail))
        print("  %-4s %-46s %s" % ("PASS" if ok else "FAIL", label, detail))

    def failures(self):
        return [r for r in self.rows if not r[1]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(DEFAULT_REPO))
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    R = Results()

    if not (repo / "Makefile").is_file():
        print("COULD-NOT-EVALUATE: no Makefile at %s" % repo)
        return 2

    # ── 1. the generated DUT-source lists must not be TRACKED ────────────────
    rc, out = git(repo, ["ls-files", "%s/dut_src.f" % BENCH,
                         "%s/dut_src_1.f" % BENCH, "%s/dut_src_3.f" % BENCH,
                         "%s/dut_src_5.f" % BENCH])
    tracked = [l for l in out.split() if l]
    R.check("generated dut_src*.f are not tracked", not tracked,
            "tracked: %s" % ", ".join(tracked) if tracked else "")

    # ── 2. the bench must write them somewhere git ignores ───────────────────
    mk = (repo / BENCH / "Makefile")
    text = mk.read_text(errors="replace") if mk.is_file() else ""
    writes_into_bench = "DUT_SRC_F := $(CURDIR)/dut_src" in text
    R.check("DUT_SRC_F is not $(CURDIR)/dut_src*.f", not writes_into_bench,
            "bench Makefile still writes into its own tracked directory"
            if writes_into_bench else "")

    # The path it DOES use must be one git ignores. Ask git, do not pattern-match.
    target = None
    for line in text.splitlines():
        if line.strip().startswith("DUT_SRC_F") and "=" in line:
            target = line.split("=", 1)[1].strip()
    probe = None
    if target:
        probe = (target.replace("$(DUT_SRC_GEN_DIR)",
                                "imp/gen/a2l_replay_cdc")
                       .replace("$(TIDELINK_HOME)/", "")
                       .replace("$(DUT_SRC_TAG)", ""))
    if probe:
        rc, _ = git(repo, ["check-ignore", "-q", probe])
        R.check("git ignores the generated path", rc == 0,
                "" if rc == 0 else "git check-ignore says %s is NOT ignored" % probe)
    else:
        R.check("git ignores the generated path", False,
                "could not read DUT_SRC_F out of the bench Makefile")

    # ── 3. the flists must point at that same ignored location ───────────────
    bad = []
    for rel in FLISTS:
        f = repo / rel
        if not f.is_file():
            bad.append("%s missing" % rel)
            continue
        for line in f.read_text(errors="replace").splitlines():
            if line.strip().startswith("-f") and "dut_src" in line:
                inc = line.split(None, 1)[1].strip()
                probe = inc.replace("${TIDELINK_HOME}/", "")
                rc, _ = git(repo, ["check-ignore", "-q", probe])
                if rc != 0:
                    bad.append("%s -> %s (not ignored)" % (rel, inc))
    R.check("flist -f includes point at an ignored path", not bad,
            "; ".join(bad))

    # ── 4. the written CONTENT must not be worktree-specific ─────────────────
    R.check("generated content is ${TIDELINK_HOME}-rooted",
            "$${TIDELINK_HOME}/$(DUT_SRC_REL)" in text,
            "" if "$${TIDELINK_HOME}/$(DUT_SRC_REL)" in text
            else "the bench writes an absolute path, so the file is "
                 "worktree-specific and every clone rewrites it")

    # ── 5. THE DYNAMIC ONE: parse the real bench Makefile, tree must not move ─
    # This is the case that actually reproduces the defect rather than asserting
    # a property that implies it. Needs cocotb-config on PATH for the bench's
    # `include $(shell cocotb-config --makefiles)/Makefile.sim`.
    rc, before = git(repo, ["status", "--porcelain"])
    if rc != 0:
        print("  SKIP  dynamic parse check (git status unavailable)")
    elif before.strip():
        print("  SKIP  dynamic parse check: tree is already dirty, so a change "
              "caused by the parse could not be attributed. Commit or stash first.")
    elif not shutil.which("cocotb-config"):
        print("  SKIP  dynamic parse check: cocotb-config not on PATH "
              "(run `source ./set_env.sh` to include it).")
    else:
        env = dict(os.environ)
        env["TIDELINK_HOME"] = str(repo)
        for node in ("13", "1", "3", "5"):
            # A target that does not exist: make PARSES the whole Makefile --
            # which is when the $(shell ...) write happens -- then errors out
            # without running any recipe. Exactly the trigger, nothing else.
            subprocess.run(["make", "-C", str(repo / BENCH),
                            "NODE=" + node, "__control_no_such_target__"],
                           capture_output=True, text=True, env=env)
        rc, after = git(repo, ["status", "--porcelain"])
        moved = sorted(set(after.splitlines()) - set(before.splitlines()))
        R.check("parsing the bench Makefile leaves the tree clean", not moved,
                "parse dirtied: %s" % "; ".join(moved))

    fails = R.failures()
    print("\ngate_selfclean control: %d/%d cases passed"
          % (len(R.rows) - len(fails), len(R.rows)))
    if fails:
        print("A gate that dirties its own tree cannot report PASS. See 915b58ce.")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
