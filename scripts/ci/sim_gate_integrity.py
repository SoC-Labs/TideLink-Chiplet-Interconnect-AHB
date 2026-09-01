#!/usr/bin/env python3
"""Structural guard: every sim_gate suite that is INVOKED must also be SCORED.

False-green register B6. `make sim_gate` invoked 63 suites and scored 61:
`sim_gate_a2l_replay_cdc_7` and `_9` were added to the run sequence and to
`.PHONY`, but not to `SIM_GATE_ALL_SUITES`, which is the list
`sim_gate_summary` iterates. A suite that is not in that list contributes no
`.status` line, so its result is never read and it cannot fail the gate.

This is a repeat offence in both directions:
  - `71dde385` registered `tl044_hol_write_age` in SIM_GATE_ALL_SUITES but
    never invoked it; the gate reported it MISS for weeks.
  - the commit whose stated purpose was fixing an unscored-suite bug
    reproduced that bug for `a2l_replay_cdc_7/_9`, and said in its message
    that it had not.

Neither direction is detectable by reading a green summary, so it is checked
mechanically here.

The two sets are derived from the Makefile itself, so the check cannot drift
away from what the gate actually does:

  INVOKED  the `sim_gate_<target>` names recursively invoked from the
           `sim_gate:` (or `sim_gate_quick:`) recipe, mapped through each
           target's `$(call sim_gate_run,<suite>,...)` to a suite label
  SCORED   SIM_GATE_ALL_SUITES + SIM_GATE_SENTINELS
           (SIM_GATE_QUICK_SUITES for the quick gate)

Divergence in EITHER direction is a hard failure, except for the entries in
ALLOWED_INVOKED_UNSCORED below, which are deliberate and carry an in-Makefile
rationale. That allow-list is explicit on purpose: a blanket "invoked but
unscored is fine" rule is what let B6 through.

Exit: 0 clean, 1 divergence, 2 could-not-evaluate (parse produced nothing).
A parse that finds no suites is NOT a pass.
"""

import argparse
import re
import sys
from pathlib import Path

# Suites deliberately invoked without being scored. Each needs a comment
# giving the Makefile line that explains why. Do not add to this list to
# silence a failure — add the suite to SIM_GATE_ALL_SUITES instead.
ALLOWED_INVOKED_UNSCORED = {
    # Makefile ~:1553 "SUPERSEDED (2026-07-19) — DO NOT PROMOTE THIS TARGET."
    # cocotb/fifo_rx_twin2 pins *.PATCHED.sv copies that are a FORK of the FIFO
    # RTL and have drifted. sim_gate_fifo_twin2_tree (suite
    # `fifo_rx_twin2_tree`) is the tree-truthful replacement and IS scored.
    "fifo_rx_twin2",
}


def strip_line_continuations(text):
    return re.sub(r"\\\n", " ", text)


def parse_var(text, name):
    """Return the whitespace-separated tokens of a `NAME := ...` assignment."""
    m = re.search(
        r"^%s\s*:?=\s*(.*)$" % re.escape(name), strip_line_continuations(text), re.M
    )
    if not m:
        return None
    body = m.group(1)
    # Drop trailing comment
    body = body.split("#", 1)[0]
    return [t for t in body.split() if t]


def parse_target_recipe(text, target):
    """Return the recipe lines of `target:` (tab-indented block)."""
    lines = text.splitlines()
    out = []
    in_target = False
    for line in lines:
        if not in_target:
            if re.match(r"^%s\s*:" % re.escape(target), line):
                in_target = True
            continue
        if line.startswith("\t"):
            out.append(line)
            continue
        if line.strip() == "":
            # A blank line inside a recipe ends it in practice for this Makefile.
            break
        break
    return out


def parse_invoked_targets(recipe_lines):
    """sim_gate_<x> names invoked via a recursive $(MAKE) in the recipe."""
    invoked = []
    for line in recipe_lines:
        stripped = line.lstrip("\t")
        if stripped.lstrip().startswith("#") or stripped.lstrip().startswith("@#"):
            continue
        if "$(MAKE)" not in stripped:
            continue
        for m in re.finditer(r"\bsim_gate_[A-Za-z0-9_]+", stripped):
            name = m.group(0)
            if name in ("sim_gate_summary", "sim_gate_env_check",
                        "sim_gate_clean_builds", "sim_gate_integrity"):
                continue
            if name not in invoked:
                invoked.append(name)
    return invoked


def parse_target_to_suite(text):
    """Map `sim_gate_<target>` -> the suite label its sim_gate_run call uses."""
    mapping = {}
    # Walk the raw text: a rule head, then its (possibly continued) recipe.
    lines = text.splitlines()
    current = None
    for line in lines:
        head = re.match(r"^(sim_gate_[A-Za-z0-9_]+)\s*:(?!=)", line)
        if head:
            current = head.group(1)
            continue
        if current is None:
            continue
        if not line.startswith("\t") and line.strip() != "":
            current = None
            continue
        m = re.search(
            r"\$\(call\s+sim_gate_(?:run|sentinel)\s*,\s*([A-Za-z0-9_]+)", line)
        if m:
            mapping[current] = m.group(1)
            current = None
    return mapping


def check(makefile_text, gate_target, scored_vars):
    problems = []
    recipe = parse_target_recipe(makefile_text, gate_target)
    if not recipe:
        return None, ["COULD-NOT-EVALUATE: no recipe parsed for target '%s'" % gate_target]

    invoked_targets = parse_invoked_targets(recipe)
    if not invoked_targets:
        return None, [
            "COULD-NOT-EVALUATE: parsed 0 invoked suites from '%s' — the parser "
            "no longer matches the Makefile, which is not a pass" % gate_target
        ]

    target_to_suite = parse_target_to_suite(makefile_text)

    invoked_suites = []
    for t in invoked_targets:
        suite = target_to_suite.get(t)
        if suite is None:
            problems.append(
                "COULD-NOT-EVALUATE: '%s' is invoked by %s but no "
                "$(call sim_gate_run/sentinel,<suite>,...) was found in its rule "
                "— cannot tell which suite label it writes, so cannot tell if it "
                "is scored" % (t, gate_target)
            )
            continue
        if suite not in invoked_suites:
            invoked_suites.append(suite)

    scored = []
    for var in scored_vars:
        vals = parse_var(makefile_text, var)
        if vals is None:
            return None, ["COULD-NOT-EVALUATE: variable %s not found" % var]
        scored.extend(vals)

    invoked_not_scored = [
        s for s in invoked_suites
        if s not in scored and s not in ALLOWED_INVOKED_UNSCORED
    ]
    scored_not_invoked = [s for s in scored if s not in invoked_suites]

    for s in invoked_not_scored:
        problems.append(
            "INVOKED BUT NOT SCORED: suite '%s' runs in `make %s` but is absent "
            "from %s, so sim_gate_summary never reads its .status and it cannot "
            "fail the gate." % (s, gate_target, " + ".join(scored_vars))
        )
    for s in scored_not_invoked:
        problems.append(
            "SCORED BUT NOT INVOKED: suite '%s' is listed in %s but `make %s` "
            "never runs it, so the summary will report it MISS forever."
            % (s, " + ".join(scored_vars), gate_target)
        )

    stats = {
        "invoked": len(invoked_suites),
        "scored": len(scored),
        "allowed": sorted(
            s for s in invoked_suites if s in ALLOWED_INVOKED_UNSCORED
        ),
    }
    return stats, problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--makefile", default="Makefile")
    args = ap.parse_args()

    path = Path(args.makefile)
    if not path.is_file():
        print("sim_gate_integrity: COULD-NOT-EVALUATE — %s not found" % path,
              file=sys.stderr)
        return 2
    text = path.read_text(errors="replace")

    gates = [
        ("sim_gate", ["SIM_GATE_ALL_SUITES", "SIM_GATE_SENTINELS"]),
        ("sim_gate_quick", ["SIM_GATE_QUICK_SUITES"]),
    ]

    rc = 0
    for target, scored_vars in gates:
        stats, problems = check(text, target, scored_vars)
        if stats is None:
            for p in problems:
                print("sim_gate_integrity: %s" % p)
            rc = max(rc, 2)
            continue
        hard = [p for p in problems if not p.startswith("COULD-NOT-EVALUATE")]
        soft = [p for p in problems if p.startswith("COULD-NOT-EVALUATE")]
        print("sim_gate_integrity: %-15s invoked=%d scored=%d%s"
              % (target, stats["invoked"], stats["scored"],
                 ("  allowed-unscored=%s" % ",".join(stats["allowed"]))
                 if stats["allowed"] else ""))
        for p in soft:
            print("  %s" % p)
            rc = max(rc, 2)
        for p in hard:
            print("  %s" % p)
            rc = max(rc, 1)

    if rc == 0:
        print("sim_gate_integrity: OK — every invoked suite is scored and every "
              "scored suite is invoked.")
    elif rc == 1:
        print("sim_gate_integrity: FAIL — the gate would report on a different "
              "set of suites than it runs.")
    else:
        print("sim_gate_integrity: COULD-NOT-EVALUATE — refusing to report OK.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
