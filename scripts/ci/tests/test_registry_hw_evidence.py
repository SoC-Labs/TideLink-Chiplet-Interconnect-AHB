#!/usr/bin/env python3
"""Red/green control for the hardware-proof evidence rule in
scripts/ci/registry_coverage.py.

WHY THIS EXISTS. On 2026-09-11 a truth pass over docs/BUG_REGISTRY.yaml found
that all three entries carrying `status: hw_proven` — TL-003, TL-005, TL-007 —
rested on prose in docs/ and on nothing else. No log, no capture, no verdict
file, no board transcript survived from any of the three sessions. The named
harness had left no output behind. imp/hw_gate/SIGNOFF_LEDGER_2026_08_13.md had
recorded exactly this a month earlier ("No HW log exists", "rests on a narrative
doc, not a log") and no status changed, because nothing in the toolchain could
make the absence produce a failing exit code.

So the rule is now mechanical: an entry claiming hardware proof must name a
file a script can stat() and a vehicle from a fixed set. And this harness is the
control for the rule — a checker whose own failure mode is never exercised is
decoration, and this project has found five diagnostics in one day that could
not report the thing they existed to report.

Every specimen below is a shape the checker MUST reject. Two of them are the
literal shape TL-003/TL-005/TL-007 were in.

Run: python3 scripts/ci/tests/test_registry_hw_evidence.py
     make selfcheck_registry_hw_evidence
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
CHECKER = REPO / "scripts" / "ci" / "registry_coverage.py"
REAL_REGISTRY = REPO / "docs" / "BUG_REGISTRY.yaml"


def specimen(status="hw_proven", extra_verification="", hw_validated=None):
    """One synthetic bug. Gate fields are set so the ONLY thing under test is the
    hardware-evidence rule — otherwise a pass/fail could come from the coverage
    checks this harness is not about."""
    hv = "" if hw_validated is None else \
        "      hw_validated: %s\n" % ("true" if hw_validated else "false")
    return (
        "bugs:\n"
        "  - id: TL-900\n"
        "    title: synthetic specimen\n"
        "    severity: low\n"
        "    status: %s\n"
        "    verification:\n"
        "      sim_test: none\n"
        "      in_sim_gate: false\n"
        "%s%s" % (status, hv, extra_verification)
    )


def run(reg_text, evidence_root=None):
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "reg.yaml"
        p.write_text(reg_text)
        root = evidence_root or td
        r = subprocess.run(
            [sys.executable, str(CHECKER),
             "--registry", str(p),
             "--makefile", str(REPO / "Makefile"),
             "--evidence-root", str(root)],
            capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


EV_OK = "      evidence: imp/hw_gate\n      vehicle: eth-pair\n"

# (label, registry text, expected rc, substring that must appear)
CASES = [
    # ---- MUST FAIL: the shapes that let an unbacked claim through ----------
    ("hw_proven with no evidence and no vehicle (the TL-003/005/007 shape)",
     specimen("hw_proven"), 1, "verification.evidence is empty"),

    ("hw_proven with free-text hw_evidence only — prose is not an artefact",
     specimen("hw_proven",
              '      hw_evidence: "die_a survives errinject B byte0"\n'),
     1, "Free-text hw_evidence does not count"),

    ("hw_proven with a vehicle but no evidence path",
     specimen("hw_proven", "      vehicle: eth-pair\n"),
     1, "verification.evidence is empty"),

    ("hw_proven with an evidence path that does not exist on disk",
     specimen("hw_proven",
              "      evidence: imp/hw_gate/this_run_was_never_kept/\n"
              "      vehicle: onchip\n"),
     1, "does not exist on disk"),

    ("hw_proven with evidence but no vehicle — which rig is not optional",
     specimen("hw_proven", "      evidence: imp/hw_gate\n"),
     1, "verification.vehicle is unset"),

    ("hw_proven with a vehicle outside the enum",
     specimen("hw_proven",
              "      evidence: imp/hw_gate\n      vehicle: some-other-rig\n"),
     1, "is not one of"),

    ("signed_off is a hardware claim too, and is checked the same way",
     specimen("signed_off"), 1, "claims hardware proof"),

    ("hw_validated: true on a NON-hw_proven status still triggers the rule",
     specimen("sim_proven", hw_validated=True), 1, "claims hardware proof"),

    ("one evidence path of two missing still fails",
     specimen("hw_proven",
              "      evidence: [imp/hw_gate, imp/hw_gate/never_written]\n"
              "      vehicle: z2\n"),
     1, "does not exist on disk"),

    # ---- MUST PASS: honest entries must not be made to look guilty ---------
    ("hw_proven with a real path and a legal vehicle",
     specimen("hw_proven", EV_OK), 0, "COVERAGE OK"),

    ("sim_proven with no hardware claim at all",
     specimen("sim_proven"), 0, "COVERAGE OK"),

    ("hw_validated explicitly FALSE is not a claim — the new entries' shape",
     specimen("sim_proven", hw_validated=False), 0, "COVERAGE OK"),

    ("hw_tested: true alone is NOT a proof claim (it covers failed runs too)",
     specimen("root_caused", '      hw_tested: true\n'), 0, "COVERAGE OK"),

    ("every legal vehicle is accepted",
     specimen("hw_proven", "      evidence: imp/hw_gate\n      vehicle: asic-mirror-sim\n"),
     0, "COVERAGE OK"),
]


def seeded_bad_entry():
    """The must-fail run against LIVE data, not a synthetic file.

    Takes the real docs/BUG_REGISTRY.yaml, promotes the first entry to
    hw_proven without giving it evidence, and requires the checker to go red.
    This is the case a synthetic specimen cannot cover: it proves the rule bites
    on the actual file, at its actual size, with its actual formatting.
    """
    text = REAL_REGISTRY.read_text()
    marker = "  - id: TL-001\n"
    assert marker in text, "seed anchor missing — registry restructured?"
    head, sep, tail = text.partition(marker)
    # Force a hardware claim on TL-001 by inserting an explicit flag into its
    # verification block, wherever that block is.
    seeded = head + sep + tail.replace(
        "    verification:\n",
        "    verification:\n      hw_validated: true\n", 1)
    assert "hw_validated: true" in seeded, "seeding failed"
    rc, out = run(seeded, evidence_root=str(REPO))
    ok = (rc == 1 and "TL-001" in out and "claims hardware proof" in out)
    return ok, rc, out


def main():
    if not CHECKER.exists():
        print("MISSING CHECKER: %s" % CHECKER)
        return 3

    failures = 0
    print("=" * 72)
    print(" registry hardware-proof evidence rule — red/green control")
    print("=" * 72)
    for label, text, want_rc, want_sub in CASES:
        rc, out = run(text, evidence_root=str(REPO))
        ok = (rc == want_rc) and (want_sub in out)
        print("  %-4s %s" % ("PASS" if ok else "FAIL", label))
        if not ok:
            failures += 1
            print("        want rc=%s and %r; got rc=%s" % (want_rc, want_sub, rc))
            print("        " + out.replace("\n", "\n        ")[:1500])

    ok, rc, out = seeded_bad_entry()
    print("  %-4s seeded bad entry in the REAL registry goes red" % ("PASS" if ok else "FAIL"))
    if not ok:
        failures += 1
        print("        got rc=%s" % rc)
        print("        " + out.replace("\n", "\n        ")[:1500])

    print("-" * 72)
    if failures:
        print("  RESULT: %d CONTROL FAILURE(S) — the evidence rule cannot produce "
              "its failing verdict, so it is not enforcing anything" % failures)
        return 1
    print("  RESULT: ALL CONTROLS PASS — the rule goes red on every unbacked shape "
          "and green on every honest one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
