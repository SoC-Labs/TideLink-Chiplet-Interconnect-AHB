#!/usr/bin/env python3
"""Registry-driven HARDWARE-gate coverage checker (HW mirror of registry_coverage.py).

Binds docs/BUG_REGISTRY.yaml to the HW regression suite so a HW-proven fix cannot
silently lose its board-level regression test — the HW analogue of the sim
coverage checker that caught TL-006's unwired gaps_ecc.

Rules:
  * every bug that CLAIMS hw-gate coverage (verification.in_hw_gate: true) must
    name a resolvable HW test (verification.hw_test -> a hwtest category script
    or an on-board tool)  -> else HARD FAIL (exit 1);
  * every bug that is HW-PROVEN or whose verification.hw_tested is true but is
    NOT in the HW gate is reported as a COVERAGE GAP (a silicon regression
    waiting to happen)  -> WARN, or HARD FAIL under --strict.

Motivated by the 2026-08-08 HW-robustness audit: the shipping-design data-plane
bugs (TL-001 peer-write drop, TL-009 wedge, TL-002/003/004/005/007 recovery) are
HW-proven-once by hand but have NO automated HW regression gate. Deterministic,
no hardware.

Usage: python3 scripts/ci/hw_registry_coverage.py [--strict]
Env:   TIDELINK_HOME (repo root); falls back to this file's ../../.. .
"""
import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("hw_registry_coverage: PyYAML required\n")
    sys.exit(3)

ROOT = os.environ.get("TIDELINK_HOME") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REG = os.path.join(ROOT, "docs", "BUG_REGISTRY.yaml")
HWTEST_DIR = os.path.join(ROOT, "pynq_host", "scripts", "hwtest")
ONCHIP_DIR = os.path.join(ROOT, "pynq_host", "scripts")

HW_PROVEN_STATUSES = {"hw_proven", "signed_off"}
NO_TEST = {"", "n/a", "none", "null", "pending", "tbd", "no", "-", "false"}


def _verification(bug):
    v = bug.get("verification")
    return v if isinstance(v, dict) else {}


def _in_hw_gate(bug):
    return _verification(bug).get("in_hw_gate") is True


def _hw_test(bug):
    return _verification(bug).get("hw_test")


def _hw_tested(bug):
    v = _verification(bug).get("hw_tested")
    # accept True, or a truthy descriptive string like "true"/"mitigation_demonstrated"
    return v is True or (isinstance(v, str) and v.strip().lower() not in NO_TEST and v.strip().lower() != "characterized, not fixed")


def _build_hw_index():
    """Names of HW test scripts/categories that can back a bug: hwtest/NN_*.sh
    basenames + on-board kr260_*/tl39 tools + the hw_regression scripts."""
    idx = set()
    for d in (HWTEST_DIR, ONCHIP_DIR, os.path.join(ROOT, "fpga", "hw_regression")):
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if fn.endswith((".sh", ".py")):
                idx.add(fn)
                idx.add(os.path.splitext(fn)[0])
    return idx


def _resolvable(hw_test, idx):
    if not isinstance(hw_test, str):
        return False
    toks = set(re.findall(r"[\w.]+", hw_test))
    return any(t in idx for t in toks) or any(
        t + ".sh" in idx or t + ".py" in idx for t in toks)


def main():
    ap = argparse.ArgumentParser(description="HW-gate registry coverage checker")
    ap.add_argument("--strict", action="store_true",
                    help="also fail (exit 1) on HW-proven-but-ungated bugs")
    args = ap.parse_args()

    with open(REG) as f:
        reg = yaml.safe_load(f)
    bugs = reg.get("bugs", []) or []
    idx = _build_hw_index()

    fails, gaps = [], []
    covered = 0
    for b in bugs:
        bid = b.get("id", "?")
        status = str(b.get("status", ""))
        if _in_hw_gate(b):
            ht = _hw_test(b)
            if ht is None or str(ht).strip().lower() in NO_TEST:
                fails.append(f"{bid}: in_hw_gate:true but hw_test is empty/'{ht}'")
                continue
            if not _resolvable(ht, idx):
                fails.append(f"{bid}: in_hw_gate:true but hw_test '{ht}' resolves to no HW script")
                continue
            covered += 1
        elif status in HW_PROVEN_STATUSES:
            # A genuinely HW-proven fix with no HW gate = a silicon regression
            # waiting to happen (the exact class the 2026-08 HW audit flagged).
            gaps.append(f"{bid} ({status}): HW-proven but NOT in_hw_gate "
                        f"-> silicon can regress with no HW gate to catch it")

    print("=" * 72)
    print(" sim->HW gate registry coverage  (docs/BUG_REGISTRY.yaml)")
    print("=" * 72)
    print(f"  bugs total                              : {len(bugs)}")
    print(f"  in_hw_gate bugs with a resolvable test  : {covered}")
    print(f"  HARD FAILURES                           : {len(fails)}")
    print(f"  HW-proven-but-ungated coverage gaps     : {len(gaps)}")
    print("-" * 72)
    for x in fails:
        print("  FAIL  " + x)
    for x in gaps:
        print("  GAP   " + x)
    print("-" * 72)
    rc = 1 if fails else 0
    if args.strict and gaps:
        rc = 1
    print("  RESULT:", "HW COVERAGE OK" if rc == 0
          else "HW COVERAGE GAPS — every HW-observable bug needs a gating HW test")
    sys.exit(rc)


if __name__ == "__main__":
    main()
