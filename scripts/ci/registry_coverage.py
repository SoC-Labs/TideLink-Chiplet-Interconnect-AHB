#!/usr/bin/env python3
"""Registry-driven sim_gate coverage checker.

Single source of truth = docs/BUG_REGISTRY.yaml. This binds the bug registry to
the sim gate so a fixed bug can never silently lose its regression test:

  * every bug that CLAIMS gate coverage (verification.in_sim_gate: true) must
    name a resolvable, existing test  -> else HARD FAIL (exit 1);
  * every FIXED bug (status sim_proven/hw_proven/signed_off) that is NOT gated
    is reported as a COVERAGE GAP (a regression waiting to happen) -> WARN, or
    HARD FAIL under --strict;
  * every bug CLAIMING HARDWARE PROOF (status hw_proven/signed_off, or
    verification.hw_validated: true) must name a stat()-able
    verification.evidence path AND a verification.vehicle from a fixed set
    -> else HARD FAIL (exit 1).

The hardware rule was added 2026-09-11, after a truth pass found that all three
`hw_proven` entries (TL-003, TL-005, TL-007) rested on prose in docs/ with no
retained artefact of any kind, and that imp/hw_gate/SIGNOFF_LEDGER_2026_08_13.md
had said so a month earlier without anything changing. A hardware verdict nobody
can re-open is indistinguishable from one that never happened, and it is the
expensive direction of wrong: a false red costs time, a false green ships.

Born out of the 2026-08 finding that TL-006's ECC fix was 'in_sim_gate: true'
in the registry while its gate (gaps_ecc) was never wired into the aggregate,
and that the 'integ line gate-green' claim was false. Deterministic, no sim.

FALSE-GREEN B7, fixed 2026-08-26 -- the existence check used to be

    files = _test_files(st)                  # only *.py paths
    missing = [f for f in files if not _resolvable(f, ROOT, idx)]
    if files and missing:                    # <-- `files and`
        HARD FAIL

so when `sim_test` named no `.py` at all, `files == []`, the check was SKIPPED
and the bug still counted as covered -- against the promise three paragraphs
up. That was 7 of the 17 gated bugs: TL-020, TL-022, TL-025, TL-027, TL-029,
TL-030, TL-034. Those seven name a sim_gate TARGET, a SUITE LABEL or a cocotb
DIRECTORY rather than a file path, which is legitimate; what was not legitimate
was scoring "I could not check this" as "checked and fine".

The checker now resolves all four kinds of referent and distinguishes three
verdicts, never collapsing the third into the first:

  COVERED               every referent extracted from sim_test resolves to
                        something that exists in the tree
  HARD FAIL             a referent is DANGLING -- it names a .py, a
                        sim_gate_* target, a suite label or a cocotb/uvm
                        directory that does not exist
  HARD FAIL (uncheckable)
                        sim_test is non-empty but contains NO checkable
                        referent of any kind, so the promise above cannot be
                        verified. Fail closed: an unverifiable claim of
                        coverage is not coverage.

Usage: python3 scripts/ci/registry_coverage.py [--strict]
                                               [--registry PATH] [--makefile PATH]
Env:   TIDELINK_HOME (repo root); falls back to this file's ../../.. .
Control: scripts/ci/tests/test_registry_coverage.py
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

# --- hardware-proof evidence discipline (2026-09-11) -------------------------
# Kept in step with docs/BUG_REGISTRY.yaml `legend.vehicle` and
# `hw_evidence_policy`. Changing either without the other is itself a defect.
HW_CLAIM_STATUSES = {"hw_proven", "signed_off"}
VEHICLES = {"onchip", "eth-pair", "z2", "asic-mirror-sim"}


def _verification(bug):
    v = bug.get("verification")
    return v if isinstance(v, dict) else {}


def _sim_test(bug):
    return _verification(bug).get("sim_test")


def _in_gate(bug):
    return _verification(bug).get("in_sim_gate") is True


def _claims_hw(bug):
    """True iff this entry asserts that hardware proved something.

    Two independent ways to say it, and both must be caught: the coarse `status`
    (hw_proven / signed_off) and the explicit per-entry flag
    `verification.hw_validated: true`. `hw_tested` is deliberately NOT a trigger —
    it is used across this registry for "a board was involved", including runs that
    FAILED or were inconclusive, and promoting those to a proof claim would produce
    false reds on honest entries.
    """
    if str(bug.get("status", "")) in HW_CLAIM_STATUSES:
        return True
    return _verification(bug).get("hw_validated") is True


def _evidence_paths(bug):
    ev = _verification(bug).get("evidence")
    if ev is None:
        return []
    if isinstance(ev, str):
        ev = [ev]
    if not isinstance(ev, list):
        return []
    return [str(p).strip() for p in ev if str(p).strip()]


def _hw_evidence_failures(bugs, root):
    """HARD failures for entries claiming hardware proof without the receipts.

    Requires BOTH a stat()-able evidence path and a legal vehicle. Not one or the
    other: a path with no vehicle does not say which rig, and a vehicle with no
    path is the exact shape (`hw_evidence: "die_a survives ..."`) this check
    exists to stop.
    """
    fails = []
    for b in bugs:
        if not _claims_hw(b):
            continue
        bid = b.get("id", "?")
        v = _verification(b)
        paths = _evidence_paths(b)
        if not paths:
            fails.append(
                f"{bid}: claims hardware proof (status={b.get('status')!r}, "
                f"hw_validated={v.get('hw_validated')!r}) but verification.evidence "
                f"is empty. Free-text hw_evidence does not count — name a file.")
        else:
            missing = [p for p in paths
                       if not os.path.exists(os.path.join(root, p))]
            if missing:
                fails.append(
                    f"{bid}: claims hardware proof but verification.evidence does not "
                    f"exist on disk: {missing}")
        veh = v.get("vehicle")
        if veh is None or str(veh).strip() == "":
            fails.append(
                f"{bid}: claims hardware proof but verification.vehicle is unset "
                f"(need one of {sorted(VEHICLES)})")
        elif str(veh).strip() not in VEHICLES:
            fails.append(
                f"{bid}: verification.vehicle {veh!r} is not one of "
                f"{sorted(VEHICLES)}")
    return fails


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


# --- referent extraction (false-green B7) ----------------------------------
# `sim_test` is free text. Four kinds of referent name something CONCRETE that
# either exists or does not; everything else in the string is prose and is
# ignored. A referent that is extracted MUST resolve.

_RE_GATE_TARGET = re.compile(r"\bsim_gate_[A-Za-z0-9_]+\b")
_RE_TB_DIR = re.compile(r"\b(?:cocotb|uvm)/[A-Za-z0-9_][A-Za-z0-9_./-]*")
_RE_WORD = re.compile(r"[A-Za-z0-9_]{4,}")


def _make_targets(mk_text):
    """Every `sim_gate_<name>:` rule head defined in the Makefile."""
    return set(re.findall(r"^(sim_gate_[A-Za-z0-9_]+)\s*:(?!=)", mk_text, re.M))


def _make_suite_labels(mk_text):
    """Every suite label the gate can score, i.e. the first argument of a
    sim_gate_run / sim_gate_sentinel call."""
    return set(re.findall(
        r"\$\(call\s+sim_gate_(?:run|sentinel)\s*,\s*([A-Za-z0-9_]+)", mk_text))


def _referents(sim_test, mk_targets, mk_labels):
    """Return [(kind, token)] for every checkable referent in `sim_test`."""
    out = []
    if not isinstance(sim_test, str):
        return out
    seen = set()

    def add(kind, tok):
        key = (kind, tok)
        if key not in seen:
            seen.add(key)
            out.append(key)

    for f in _test_files(sim_test):
        add("file", f)
    for t in _RE_GATE_TARGET.findall(sim_test):
        add("target", t)
    for d in _RE_TB_DIR.findall(sim_test):
        # trim trailing punctuation picked up from prose
        d = d.rstrip("./-,;:)`\'\"")
        if not d.endswith(".py"):
            add("dir", d)
    # A bare word is only a referent if it is exactly a known suite label.
    for w in _RE_WORD.findall(sim_test):
        if w in mk_labels:
            add("suite", w)
    return out


def _resolve_referent(kind, tok, root, idx, mk_targets, mk_labels):
    """(ok, detail). `ok` False means the referent is DANGLING."""
    if kind == "file":
        return _resolvable(tok, root, idx), "test file"
    if kind == "target":
        return tok in mk_targets, "Makefile target"
    if kind == "dir":
        return os.path.isdir(os.path.join(root, tok)), "testbench directory"
    if kind == "suite":
        return tok in mk_labels, "sim_gate suite label"
    return False, "unknown referent kind"


def main():
    ap = argparse.ArgumentParser(description="sim_gate registry coverage checker")
    ap.add_argument("--strict", action="store_true",
                    help="also fail (exit 1) on FIXED-but-ungated bugs")
    ap.add_argument("--registry", default=REG,
                    help="registry YAML to check (default docs/BUG_REGISTRY.yaml). "
                         "Exists so scripts/ci/tests/ can feed this checker synthetic "
                         "specimens and require it to go RED.")
    ap.add_argument("--makefile", default=MK,
                    help="Makefile to check suite wiring against")
    ap.add_argument("--evidence-root", default=ROOT,
                    help="root that verification.evidence paths resolve against")
    args = ap.parse_args()

    with open(args.registry) as f:
        reg = yaml.safe_load(f)
    bugs = reg.get("bugs", []) or []
    mk = open(args.makefile).read() if os.path.exists(args.makefile) else ""
    idx = _build_test_index(ROOT)
    mk_targets = _make_targets(mk)
    mk_labels = _make_suite_labels(mk)

    fails, warns, gaps = [], [], []
    covered = 0
    uncheckable = 0

    for b in bugs:
        bid = b.get("id", "?")
        status = str(b.get("status", ""))
        st = _sim_test(b)

        if _in_gate(b):
            if st is None or str(st).strip().lower() in NO_TEST:
                fails.append(f"{bid}: in_sim_gate:true but sim_test is empty/'{st}'")
                continue

            refs = _referents(st, mk_targets, mk_labels)

            # THIRD VERDICT (false-green B7): sim_test is non-empty but names
            # nothing checkable. The old code reached this state with
            # `files == []`, skipped the check and counted the bug as covered.
            if not refs:
                uncheckable += 1
                fails.append(
                    f"{bid}: in_sim_gate:true but sim_test names NOTHING CHECKABLE "
                    f"— no .py file, no sim_gate_* target, no sim_gate suite label "
                    f"and no cocotb/ or uvm/ directory in "
                    f"'{str(st)[:80]}'. COULD-NOT-EVALUATE, which is not coverage.")
                continue

            dangling = []
            for kind, tok in refs:
                ok, what = _resolve_referent(kind, tok, ROOT, idx,
                                             mk_targets, mk_labels)
                if not ok:
                    dangling.append(f"{tok} ({what} does not exist)")
            if dangling:
                fails.append(
                    f"{bid}: in_sim_gate:true but sim_test references "
                    f"{dangling} — dangling referent(s), so the claimed gate "
                    f"coverage cannot exist")
                continue

            # Heuristic wiring check: some distinctive token from sim_test should
            # appear in the Makefile (a suite target, token, or test basename).
            toks = {t for t in re.findall(r"[A-Za-z0-9_]{5,}", st)}
            basenames = {os.path.basename(f) for k, f in refs if k == "file"}
            wired = any(t in mk for t in toks) or any(bn in mk for bn in basenames)
            if not wired:
                warns.append(f"{bid}: test '{str(st)[:64]}' not obviously referenced "
                             f"in the Makefile — verify it is actually invoked by sim_gate")
            covered += 1
        elif status in FIXED_STATUSES:
            gaps.append(f"{bid} ({status}): FIXED but in_sim_gate is not true "
                        f"-> can regress without any gate catching it")

    hw_fails = _hw_evidence_failures(bugs, args.evidence_root)
    fails.extend(hw_fails)

    print("=" * 72)
    print(" sim_gate registry coverage  (docs/BUG_REGISTRY.yaml)")
    print("=" * 72)
    print(f"  bugs total                              : {len(bugs)}")
    print(f"  in_sim_gate bugs with a resolvable test : {covered}")
    print(f"  ... of which UNCHECKABLE (fail-closed)   : {uncheckable}")
    print(f"  HARD FAILURES                           : {len(fails)}")
    print(f"  wiring warnings                         : {len(warns)}")
    print(f"  FIXED-but-ungated coverage gaps         : {len(gaps)}")
    print(f"  unbacked hardware-proof claims          : {len(hw_fails)}")
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
