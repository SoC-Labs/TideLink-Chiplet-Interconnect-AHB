#!/usr/bin/env python3
"""Red/green control for scripts/ci/sim_gate_integrity.py.

The guard exists to catch a divergence between the suites `make sim_gate`
invokes and the suites `sim_gate_summary` scores. A guard that cannot go red
is worth nothing, so this harness mutates a COPY of the real Makefile to
manufacture each divergence and asserts the guard's exit code.

  0 = clean, 1 = divergence found, 2 = could-not-evaluate.

Run: python3 scripts/ci/tests/test_sim_gate_integrity.py
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
GUARD = REPO / "scripts" / "ci" / "sim_gate_integrity.py"
MAKEFILE = REPO / "Makefile"


def run_guard(makefile_path):
    p = subprocess.run(
        [sys.executable, str(GUARD), "--makefile", str(makefile_path)],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def mutate(text, kind):
    """Manufacture one specimen of the defect class."""
    if kind == "invoked_not_scored":
        # Remove two suites from the SCORED list while leaving them invoked.
        # This is the literal B6 defect as it stood on rev2/consolidated.
        out = text.replace("\ta2l_replay_cdc_7 a2l_replay_cdc_9 \\\n", "")
        assert out != text, "could not remove a2l_replay_cdc_7/_9 from the scored list"
        return out
    if kind == "scored_not_invoked":
        # Add a suite to the scored list that nothing invokes. This is the
        # 71dde385 polarity: the summary reports MISS forever.
        out = text.replace(
            "\ta2l_wready_tear \\\n",
            "\ta2l_wready_tear a_suite_nothing_invokes \\\n", 1)
        assert out != text, "could not add a phantom suite to the scored list"
        return out
    if kind == "unparseable":
        # Rename the scored variable: the guard must say COULD-NOT-EVALUATE,
        # never OK.
        out = re.sub(r"^SIM_GATE_ALL_SUITES(\s*:=)",
                     r"SIM_GATE_ALL_SUITES_RENAMED\1", text, count=1, flags=re.M)
        assert out != text, "could not rename SIM_GATE_ALL_SUITES"
        return out
    if kind == "no_recipe":
        # Rename the gate target itself. Parsing zero invoked suites must not
        # read as a pass.
        out = text.replace(
            "\nsim_gate: sim_gate_integrity sim_gate_env_check sim_gate_clean_builds\n",
            "\nsim_gate_renamed: sim_gate_env_check sim_gate_clean_builds\n", 1)
        assert out != text, "could not rename the sim_gate target"
        return out
    raise AssertionError("unknown mutation %r" % kind)


CASES = [
    # (mutation, expected rc, substring that must appear)
    (None,                 0, "OK — every invoked suite is scored"),
    ("invoked_not_scored", 1, "INVOKED BUT NOT SCORED: suite 'a2l_replay_cdc_7'"),
    ("scored_not_invoked", 1, "SCORED BUT NOT INVOKED: suite 'a_suite_nothing_invokes'"),
    ("unparseable",        2, "COULD-NOT-EVALUATE"),
    ("no_recipe",          2, "COULD-NOT-EVALUATE"),
]


def main():
    if not GUARD.is_file():
        print("FAIL: guard not found at %s" % GUARD)
        return 2
    base = MAKEFILE.read_text(errors="replace")

    failures = 0
    ran = 0
    with tempfile.TemporaryDirectory() as td:
        for kind, want_rc, want_text in CASES:
            ran += 1
            text = base if kind is None else mutate(base, kind)
            mf = Path(td) / ("Makefile.%s" % (kind or "pristine"))
            mf.write_text(text)
            rc, out = run_guard(mf)
            label = kind or "pristine tree"
            ok = (rc == want_rc) and (want_text in out)
            if ok:
                print("  PASS  %-20s rc=%d" % (label, rc))
            else:
                failures += 1
                print("  FAIL  %-20s rc=%d (wanted %d)" % (label, rc, want_rc))
                if want_text not in out:
                    print("        expected text not found: %r" % want_text)
                print("        ---- guard output ----")
                for line in out.splitlines():
                    print("        %s" % line)

    if ran != len(CASES):
        print("COULD-NOT-EVALUATE: ran %d of %d cases" % (ran, len(CASES)))
        return 2
    print("sim_gate_integrity self-test: %d/%d cases passed" % (ran - failures, ran))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
