#!/usr/bin/env python3
"""Red/green control for scripts/ci/sim_gate_env_check.py.

WHAT IT PROTECTS. sim_gate_env_check ran exactly two tests -- `command -v vcs`
and `command -v cocotb-config`. A shell with VCS on PATH but WITHOUT `source
./set_env.sh` passed, then every suite died at parse in 3-5 s with
"Error-[SFCOR] Source file \"${CMSDK_FPGA_SRAM_V}\" cannot be opened" and
sim_gate_run wrote a correctly-stamped FAIL for each one: a full red table that
measured nothing, after paying the launch cost of a 45-95 minute gate.

HOW IT TESTS. Each case builds a SYNTHETIC mini-repo with the shape the checker
reads -- a Makefile with a sim_gate recipe driving a bench, a bench Makefile
naming a flist, a flist containing a ${VAR} -- then breaks exactly one thing and
asserts the checker's exit code AND that the named failure class appears in its
output. Pure Python and git; no simulator, a couple of seconds.

The READY cases are the negative control: a checker that failed everything would
satisfy the four red cases on its own, so the balance is asserted explicitly at
the end rather than inferred from the count.

THE CONTROL HAS TO BE ABLE TO GO RED. Point it at a checker that cannot report:
    printf '#!/bin/sh\\nexit 0\\n' > /tmp/always_ok && chmod +x /tmp/always_ok
    python3 scripts/ci/tests/test_sim_gate_env_check.py --checker /tmp/always_ok
Every red case then fails. That is the pre-fix behaviour: the old check could
not produce any of these four verdicts.

Run: python3 scripts/ci/tests/test_sim_gate_env_check.py [--checker PATH]
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
CHECKER = REPO / "scripts" / "ci" / "sim_gate_env_check.py"

ROOT_MK = "sim_gate_fifo:\n\t$(MAKE) -C cocotb/tidelink_fifo MODULE=x\n"
BENCH_MK = "COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fifo.flist\n"
BENCH_MK_SITE = ("SITE_VARS_REQUIRED += VIP_HOME\n"
                 "include $(TIDELINK_HOME)/mk/site.mk\n"
                 "COMPILE_ARGS += -f $(TIDELINK_HOME)/flists/tidelink_fifo.flist\n")
FLIST = ("+incdir+${TIDELINK_HOME}/src\n"
         "${TIDELINK_HOME}/src/a.v\n"
         "${CMSDK_DIR}/logical/models/cmsdk_fpga_sram.v\n")


def git(cwd, argv, **kw):
    return subprocess.run(["git", "-C", str(cwd)] + argv,
                          capture_output=True, text=True, **kw)


def make_repo(td, with_submodule=False, site_contract=False):
    """A minimal checkout with the shape the checker reads."""
    root = Path(td) / "repo"
    for d in ("flists", "cocotb/tidelink_fifo", "src", "mk"):
        (root / d).mkdir(parents=True, exist_ok=True)
    (root / "Makefile").write_text(ROOT_MK)
    if site_contract:
        # the REAL site contract, so the control tests what the benches include
        (root / "mk/site.mk").write_text((REPO / "mk" / "site.mk").read_text())
        (root / "cocotb/tidelink_fifo/Makefile").write_text(BENCH_MK_SITE)
    else:
        (root / "cocotb/tidelink_fifo/Makefile").write_text(BENCH_MK)
    (root / "flists/tidelink_fifo.flist").write_text(FLIST)
    (root / "src/a.v").write_text("module a; endmodule\n")

    cmsdk = Path(td) / "cmsdk" / "logical" / "models"
    cmsdk.mkdir(parents=True, exist_ok=True)
    (cmsdk / "cmsdk_fpga_sram.v").write_text("// stub\n")

    git(root, ["init", "-q", "."])
    git(root, ["add", "-A"])
    git(root, ["-c", "user.email=c@c", "-c", "user.name=c", "commit", "-qm", "base"])

    if with_submodule:
        sub = Path(td) / "sub"
        sub.mkdir(parents=True, exist_ok=True)
        git(sub, ["init", "-q", "."])
        (sub / "f.txt").write_text("x\n")
        git(sub, ["add", "-A"])
        git(sub, ["-c", "user.email=c@c", "-c", "user.name=c", "commit", "-qm", "i"])
        git(root, ["-c", "protocol.file.allow=always", "submodule", "add", "-q",
                   str(sub), "deps/thing"])
        git(root, ["-c", "user.email=c@c", "-c", "user.name=c", "commit", "-qm", "s"])
        git(root, ["submodule", "deinit", "-f", "deps/thing"])

    return root, str(Path(td) / "cmsdk")


def run(checker, root, env_over, extra=()):
    env = dict(os.environ)
    env["TIDELINK_HOME"] = str(root)
    for k, v in env_over.items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v
    r = subprocess.run([sys.executable, str(checker), "--repo", str(root),
                        "--skip-tools", *extra],
                       capture_output=True, text=True, env=env, timeout=300)
    return r.returncode, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checker", default=str(CHECKER))
    args = ap.parse_args()
    checker = Path(args.checker)
    if not checker.is_file():
        print("COULD-NOT-EVALUATE: no checker at %s" % checker)
        return 2

    cases, failures = [], 0

    def case(label, want_rc, want_text, rc, out):
        ok = (rc == want_rc) and (want_text in out)
        cases.append((label, want_rc))
        print("  %-4s %-38s rc=%d (want %d)"
              % ("PASS" if ok else "FAIL", label, rc, want_rc))
        if not ok:
            if want_text not in out:
                print("        expected %r in the output, not found" % want_text)
            for line in out.splitlines()[:14]:
                print("        %s" % line)
        return 0 if ok else 1

    # ── GREEN: a complete environment on a clean tree ────────────────────────
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td)
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk})
        failures += case("complete env, clean tree", 0, "READY", rc, out)

    # ── RED 1: an unset ${VAR} the flists use ────────────────────────────────
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td)
        rc, out = run(checker, root, {"CMSDK_DIR": None})
        failures += case("unset flist var", 1, "UNSET-VAR", rc, out)

    # ── RED 2: set, but resolving to a path that does not exist ──────────────
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td)
        rc, out = run(checker, root, {"CMSDK_DIR": str(Path(td) / "nope")})
        failures += case("var set to a missing path", 1, "MISSING-PATH", rc, out)

    # ── RED 3: an uninitialised submodule ────────────────────────────────────
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td, with_submodule=True)
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk})
        failures += case("uninitialised submodule", 1, "SUBMODULE", rc, out)

    # ── RED 4: a dirty tree at launch ────────────────────────────────────────
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td)
        (root / "src" / "a.v").write_text("module a; wire w; endmodule\n")
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk})
        failures += case("dirty tree at launch", 1, "DIRTY-TREE", rc, out)

        # ...and --allow-dirty must downgrade ONLY that one.
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk}, extra=("--allow-dirty",))
        failures += case("--allow-dirty downgrades it", 0, "READY", rc, out)

    # ── RED 6: a bench whose site contract (mk/site.mk) names an unset var ───
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td, site_contract=True)
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk, "VIP_HOME": None})
        failures += case("site var unset (mk/site.mk)", 1, "SITE-CONTRACT", rc, out)
        # ...and with it set, the same bench is READY (the probe itself is inert).
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk, "VIP_HOME": str(Path(td))})
        failures += case("site var set -> READY", 0, "READY", rc, out)
    # ── RED 5: it must refuse to say READY when it examined nothing ──────────
    with tempfile.TemporaryDirectory() as td:
        root, cmsdk = make_repo(td)
        (root / "Makefile").write_text("all:\n\t@true\n")   # no sim_gate recipes
        rc, out = run(checker, root, {"CMSDK_DIR": cmsdk})
        failures += case("empty closure is COULD-NOT-EVALUATE", 2,
                         "COULD-NOT-EVALUATE", rc, out)

    n_green = sum(1 for _, want in cases if want == 0)
    n_red = sum(1 for _, want in cases if want != 0)
    if n_green < 2 or n_red < 4:
        print("COULD-NOT-EVALUATE: the case list lost its red/green balance "
              "(%d green, %d red)" % (n_green, n_red))
        return 2

    print("\nsim_gate_env_check control: %d/%d cases passed"
          % (len(cases) - failures, len(cases)))
    if failures:
        print("The env check cannot produce a verdict it exists to produce. "
              "A gate that starts on a broken environment records "
              "correctly-stamped, meaningless results.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
