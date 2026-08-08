#!/usr/bin/env python3
"""Registry-driven sim_gate coverage checker.

Single source of truth = docs/BUG_REGISTRY.yaml. This binds the bug registry to
the sim gate so a fixed bug can never silently lose its regression test:

  * every bug that CLAIMS gate coverage (verification.in_sim_gate: true) must
    name a resolvable, existing test  -> else HARD FAIL (exit 1);
  * every FIXED bug (status sim_proven/hw_proven/signed_off) that is NOT gated
    is reported as a COVERAGE GAP (a regression waiting to happen) -> WARN, or
    HARD FAIL under --strict.

Born out of the 2026-08 finding that TL-006's ECC fix was 'in_sim_gate: true'
in the registry while its gate (gaps_ecc) was never wired into the aggregate,
and that the 'integ line gate-green' claim was false. Deterministic, no sim.

Usage: python3 scripts/ci/registry_coverage.py [--strict]
Env:   TIDELINK_HOME (repo root); falls back to this file's ../../.. .
"""
import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("registry_coverage: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)

ROOT = os.environ.get("TIDELINK_HOME") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REG = os.path.join(ROOT, "docs", "BUG_REGISTRY.yaml")
MK = os.path.join(ROOT, "Makefile")

FIXED_STATUSES = {"sim_proven", "hw_proven", "signed_off"}
NO_TEST = {"", "n/a", "none", "null", "pending", "tbd", "no", "-"}


def _verification(bug):
    v = bug.get("verification")
    return v if isinstance(v, dict) else {}


def _sim_test(bug):
    return _verification(bug).get("sim_test")


def _in_gate(bug):
    return _verification(bug).get("in_sim_gate") is True


def _test_files(sim_test):
    if not isinstance(sim_test, str):
        return []
    return re.findall(r"[\w./-]+\.py", sim_test)


def _build_test_index(root):
    """basename -> [paths] for every *.py under cocotb/ and uvm/ (test files rarely
    sit at repo root; the registry names them by basename)."""
    idx = {}
    for sub in ("cocotb", "uvm"):
        base = os.path.join(root, sub)
        for dp, _dirs, fns in os.walk(base):
            for fn in fns:
                if fn.endswith(".py"):
                    idx.setdefault(fn, []).append(os.path.join(dp, fn))
    return idx


def _resolvable(f, root, idx):
    """A referenced test file is resolvable if it exists at the literal path OR
    its basename is present anywhere under cocotb/ or uvm/."""
    if os.path.exists(os.path.join(root, f)):
        return True
    return os.path.basename(f) in idx


def main():
    ap = argparse.ArgumentParser(description="sim_gate registry coverage checker")
    ap.add_argument("--strict", action="store_true",
                    help="also fail (exit 1) on FIXED-but-ungated bugs")
    args = ap.parse_args()

    with open(REG) as f:
        reg = yaml.safe_load(f)
    bugs = reg.get("bugs", []) or []
    mk = open(MK).read() if os.path.exists(MK) else ""
    idx = _build_test_index(ROOT)

    fails, warns, gaps = [], [], []
    covered = 0

    for b in bugs:
        bid = b.get("id", "?")
        status = str(b.get("status", ""))
        st = _sim_test(b)

        if _in_gate(b):
            if st is None or str(st).strip().lower() in NO_TEST:
                fails.append(f"{bid}: in_sim_gate:true but sim_test is empty/'{st}'")
                continue
            files = _test_files(st)
            missing = [f for f in files if not _resolvable(f, ROOT, idx)]
            if files and missing:
                fails.append(f"{bid}: in_sim_gate:true but test file(s) not found in tree: {missing}")
                continue
            # Heuristic wiring check: some distinctive token from sim_test should
            # appear in the Makefile (a suite target, token, or test basename).
            toks = {t for t in re.findall(r"[A-Za-z0-9_]{5,}", st)}
            basenames = {os.path.basename(f) for f in files}
            wired = any(t in mk for t in toks) or any(bn in mk for bn in basenames)
            if not wired:
                warns.append(f"{bid}: test '{str(st)[:64]}' not obviously referenced "
                             f"in the Makefile — verify it is actually invoked by sim_gate")
            covered += 1
        elif status in FIXED_STATUSES:
            gaps.append(f"{bid} ({status}): FIXED but in_sim_gate is not true "
                        f"-> can regress without any gate catching it")

    print("=" * 72)
    print(" sim_gate registry coverage  (docs/BUG_REGISTRY.yaml)")
    print("=" * 72)
    print(f"  bugs total                              : {len(bugs)}")
    print(f"  in_sim_gate bugs with a resolvable test : {covered}")
    print(f"  HARD FAILURES                           : {len(fails)}")
    print(f"  wiring warnings                         : {len(warns)}")
    print(f"  FIXED-but-ungated coverage gaps         : {len(gaps)}")
    print("-" * 72)
    for x in fails:
        print("  FAIL  " + x)
    for x in warns:
        print("  WARN  " + x)
    for x in gaps:
        print("  GAP   " + x)
    print("-" * 72)

    rc = 1 if fails else 0
    if args.strict and gaps:
        rc = 1
    print("  RESULT:", "COVERAGE OK" if rc == 0
          else "COVERAGE GAPS — every in_sim_gate bug needs a real gating test")
    sys.exit(rc)


if __name__ == "__main__":
    main()
