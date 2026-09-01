#!/usr/bin/env python3
"""cov_report.py - urg text report -> a canonical, diffable coverage summary.

    python3 scripts/coverage/cov_report.py --report rpt \
        --scope scripts/coverage/SCOPE.txt --out-dir out/

Emits, into --out-dir:

    cov_summary.json         canonical metrics. SMALL. This is the file that
                             gets git-tracked and that cov_diff.py compares.
    unexercised_scoped.json  the scoped never-exercised list, machine form.
    unexercised_scoped.txt   the same, for a human in an MR review.

WHY A CANONICAL SUMMARY AND NOT JUST THE HTML
---------------------------------------------
Measured on this tree, 2026-08-26, merging three real tidelink .vdb databases:

    merged .vdb            2.7  MB   ->  2.35 MB as .tar.zst  (1.15x)
    urg text report        16   MB   ->  173  KB as .tar.zst  (92x)
      of which modinfo.txt  9.1 MB
    urg HTML report        ~11  MB   (22 files, fully regenerable from the .vdb)
    dashboard.txt          1.0  KB
    hierarchy.txt          20   KB

Two consequences drive the whole design. First, the HTML report is four times
the database it was generated from and can be regenerated from it in seconds --
so it is never published, only the .vdb and the text are. Second, a .vdb is
ALREADY internally compressed: zstd -19 buys 15%, not the 13x the GDS
measurement in ARTIFACT_FLOW_PLAN §1.2 recorded. Do not carry that number
across; it is about a different kind of file.

THE ONE THING THIS FILE REFUSES TO DO
-------------------------------------
Report an empty unexercised list as good news. urg prints

    Warning-[URG-NSF] No source found ... Annotated line coverage report will
    not be generated for modules defined in this file.

when the sources it compiled against are not at the recorded path -- which
happens for every netlist-built and every relocated run. In that state urg
emits NO per-line detail, and a naive parser reports zero uncovered lines. That
is the [a zero that measured nothing] class that has already cost this project
a wrong reading. So object-level detail is reported as AVAILABLE or
UNAVAILABLE, and when it is unavailable the list is labelled UNDETERMINED at
that tier and the tier is not scored.

THREE TIERS, because the defect this repository exists to catch is a tier-2 one
-------------------------------------------------------------------------------
  T1  module never exercised at all (every metric 0 or --).
  T2  a metric that is 0.00 in a module whose OTHER metrics are not. A whole
      arm of the module never executed while the module as a whole looks fine.
  T3  the individual uncovered lines/branches. Needs sources at urg time.

The XHB500 `singles_burst` arm -- gated on hprot[3] rather than hburst, so the
non-singles path has never executed in any test at any commit -- is a tier-2
signature exactly. Its module has real line coverage; it is one branch that
never went the other way. A module-level dashboard could never have found it,
which is why T2 is computed and reported separately rather than folded into a
single percentage.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import argparse
import fnmatch
import hashlib
import json
import os
import re
import sys

METRICS = ("line", "cond", "toggle", "fsm", "branch")
SCORE_RE = re.compile(
    r"^\s*(-{2}|\d+\.\d+)\s+(-{2}|\d+\.\d+)\s+(-{2}|\d+\.\d+)\s+"
    r"(-{2}|\d+\.\d+)\s+(-{2}|\d+\.\d+)\s+(-{2}|\d+\.\d+)\s*(\S.*)?$")


def _num(tok):
    """'--' means THE METRIC WAS NOT COLLECTED. It is not 0% and it is not
    100%; it is absent, and it must stay distinguishable from both or a module
    with no FSMs reads as a module whose FSMs were never entered."""
    return None if tok == "--" else float(tok)


# --------------------------------------------------------------------------
# scope
# --------------------------------------------------------------------------

class Scope:
    """A source-path classifier. Every rule carries a REASON; a rule with no
    reason is refused at load time.

    The point is not tidiness. The arm of the XHB500 bridge that shipped
    unexercised lives under deps/xhb500/generated -- a vendor-GENERATED path
    that any reasonable 'exclude third-party code' rule would have hidden. So
    this file makes the shipping/not-shipping distinction explicit and forces
    whoever excludes something to write down why, in a file that shows up in a
    diff."""

    CLASSES = ("own", "shipping-vendor", "harness", "out-of-scope")

    def __init__(self, rules, sha256):
        self.rules = rules          # list of (class, glob, reason)
        self.sha256 = sha256

    @classmethod
    def load(cls, path):
        rules = []
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            h.update(fh.read())
        with open(path) as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                parts = [p.strip() for p in line.split("|")]
                if len(parts) != 3:
                    sys.exit("SCOPE %s:%d: expected '<class> | <glob> | "
                             "<reason>', got %r" % (path, lineno, line))
                klass, glob, reason = parts
                if klass not in cls.CLASSES:
                    sys.exit("SCOPE %s:%d: unknown class %r (want one of %s)"
                             % (path, lineno, klass, ", ".join(cls.CLASSES)))
                if not reason:
                    sys.exit("SCOPE %s:%d: a rule with no reason is refused. "
                             "An unexplained exclusion is how an unexercised "
                             "shipping arm stays invisible." % (path, lineno))
                rules.append((klass, glob, reason))
        return cls(rules, h.hexdigest())

    def classify(self, src):
        """First matching rule wins, so put the specific ones first. An
        unmatched path is 'own': the default is IN scope, never out. A
        classifier that silently drops what it does not recognise is a
        classifier that hides new code."""
        if not src:
            return "own", "no source path recorded -- defaulting IN scope"
        for klass, glob, reason in self.rules:
            if fnmatch.fnmatch(src, glob):
                return klass, reason
        return "own", "no rule matched -- default is IN scope"


# --------------------------------------------------------------------------
# urg text parsing
# --------------------------------------------------------------------------

def parse_dashboard(path):
    """-> {"total": {...}, "n_tests": int|None, "urg_version": str|None}"""
    out = {"total": {}, "n_tests": None, "urg_version": None}
    if not os.path.exists(path):
        return out
    lines = open(path, errors="replace").read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("Version:"):
            out["urg_version"] = line.split(":", 1)[1].strip()
        if line.startswith("Number of tests:"):
            try:
                out["n_tests"] = int(line.split(":", 1)[1])
            except ValueError:
                pass
        if line.strip().startswith("Total Coverage Summary"):
            for nxt in lines[i + 1:i + 5]:
                m = SCORE_RE.match(nxt)
                if m and not (m.group(7) or "").strip():
                    out["total"] = {"score": _num(m.group(1))}
                    out["total"].update(
                        dict(zip(METRICS, [_num(m.group(j)) for j in range(2, 7)])))
                    break
    return out


def parse_modinfo(path):
    """-> {module: {"metrics": {...}, "source": str|None}}

    A module record is a `Module : <name>` line whose PREVIOUS line is a rule of
    '='. That precision matters: modinfo.txt also contains bare `Module :`,
    `Parent :` and `Subtrees :` sub-headings inside instance blocks, and a
    parser keying on 'Module :' alone picks up 300-odd empty names -- measured
    on this tree: 309 matches for '^Module : ', of which the great majority are
    those sub-headings."""
    mods = {}
    if not os.path.exists(path):
        return mods
    lines = open(path, errors="replace").read().splitlines()
    i = 0
    cur = None
    while i < len(lines):
        line = lines[i]
        if (line.startswith("Module : ") and i > 0
                and set(lines[i - 1].strip()) == {"="}):
            name = line[len("Module : "):].strip()
            cur = name or None
            if cur:
                mods.setdefault(cur, {"metrics": {}, "source": None})
                # the first score line with NO trailing name is the module's own
                for j in range(i + 1, min(i + 8, len(lines))):
                    m = SCORE_RE.match(lines[j])
                    if m and not (m.group(7) or "").strip():
                        mods[cur]["metrics"] = {"score": _num(m.group(1))}
                        mods[cur]["metrics"].update(dict(zip(
                            METRICS, [_num(m.group(k)) for k in range(2, 7)])))
                        break
        elif cur and line.startswith("Source File(s)"):
            for j in range(i + 1, min(i + 6, len(lines))):
                s = lines[j].strip()
                if s:
                    mods[cur]["source"] = s
                    break
        i += 1
    return mods


def object_detail_available(report_dir, mods):
    """How much per-object (tier-3) detail did urg actually emit?

    -> "AVAILABLE" | "PARTIAL:n/m" | "UNAVAILABLE:<reason>"

    NOT a boolean, and NOT keyed on the warning text. Measured on this tree:
    urg's `Warning-[URG-NSF] No source found ... Annotated line coverage report
    will not be generated` goes to STDERR ONLY -- modinfo.txt contains no trace
    of it. A checker that greps the report for that warning finds nothing and
    concludes all is well, which is precisely the [a zero that measured nothing]
    failure in a new costume.

    So the measurement is structural instead: a module for which urg collected
    a LINE metric must also have a `Line Coverage for Module : <name>` section.
    Where it does not, urg had no source and tier-3 for that module is missing.
    Measured on the three-database merge used to develop this: 7 line sections
    against 13 parsed modules -- PARTIAL, and the honest answer.

    (Capture urg's stderr into the artifact as urg.log too; cov_pack.sh does.)
    """
    mi = os.path.join(report_dir, "modinfo.txt")
    if not os.path.exists(mi):
        return "UNAVAILABLE:no-modinfo"
    txt = open(mi, errors="replace").read()
    want = [m for m, r in mods.items()
            if (r["metrics"].get("line") is not None
                or r["metrics"].get("branch") is not None)]
    if not want:
        return "UNAVAILABLE:no-line-or-branch-metric-collected"
    have = [m for m in want
            if ("Line Coverage for Module : %s" % m) in txt
            or ("Branch Coverage for Module : %s" % m) in txt]
    if len(have) == len(want):
        return "AVAILABLE"
    if not have:
        return "UNAVAILABLE:urg-emitted-no-per-object-sections"
    return "PARTIAL:%d/%d" % (len(have), len(want))


def sources_missing(urg_log):
    """Count urg's `Warning-[URG-NSF] No source found` -- from urg's STDERR,
    which is the only place it appears.

    A module whose source urg could not open does not get a low line score; it
    gets NO line metric at all, and drops out of every percentage silently. It
    is therefore invisible to the object-detail measurement above, which can
    only speak about modules that HAVE a metric. This counter is the other half:
    it says how much of the design urg was unable to look at.

    -> int, or "UNVERIFIED:no-urg-log". Not 0. A missing log means the question
    was not asked, and 0 would answer it wrongly."""
    if not urg_log or not os.path.exists(urg_log):
        return "UNVERIFIED:no-urg-log"
    txt = open(urg_log, errors="replace").read()
    files = set(re.findall(r"The source file\s*\n?\s*'([^']+)'", txt))
    return len(files) if ("URG-NSF" in txt or files) else 0


# --------------------------------------------------------------------------
# the unexercised list
# --------------------------------------------------------------------------

def unexercised(mods, scope, complete):
    """-> list of findings, each labelled UNCOVERED or UNDETERMINED.

    `complete` is the merge-completeness flag from the manifest. When the merge
    is partial -- some suite did not produce a database -- 'not covered' and
    'not run' are indistinguishable, so EVERY finding downgrades to
    UNDETERMINED. This is not pedantry: an unexercised list read as an absolute
    claim, generated from a partial merge, is a report that manufactures
    confidence out of a missing input."""
    label = "UNCOVERED" if complete else "UNDETERMINED"
    out = []
    for name in sorted(mods):
        rec = mods[name]
        met = rec["metrics"]
        if not met:
            continue
        klass, reason = scope.classify(rec["source"] or "")
        collected = {k: v for k, v in met.items()
                     if k in METRICS and v is not None}
        if not collected:
            continue
        nonzero = [k for k, v in collected.items() if v > 0.0]
        zero = sorted(k for k, v in collected.items() if v == 0.0)
        if not nonzero:
            out.append({"tier": 1, "module": name, "source": rec["source"],
                        "scope": klass, "scope_reason": reason,
                        "metrics_zero": zero, "status": label,
                        "detail": "module never exercised on any collected metric"})
        elif zero:
            out.append({"tier": 2, "module": name, "source": rec["source"],
                        "scope": klass, "scope_reason": reason,
                        "metrics_zero": zero, "status": label,
                        "detail": "metric(s) %s are 0.00 while %s are not -- an "
                                  "arm of this module never executed"
                                  % ("+".join(zero), "+".join(sorted(nonzero)))})
    return out


def canonical_body(dash, mods, unex):
    """The bytes coverage_id is computed over.

    Deliberately EXCLUDES: dates, host, user, absolute paths, the urg command
    line, tool version, file sizes, and the .vdb bytes. Those all change between
    two runs of the same tests on the same RTL, and if they were in here the
    'same inputs, same result' cell of the 2x2 could never be reached.

    Deliberately INCLUDES the module SOURCE BASENAME, not its full path: a run
    from a different worktree covers the same code and must produce the same
    coverage_id, but a module that moved to a different file has genuinely
    changed."""
    return {
        "total": dash.get("total", {}),
        "modules": {m: mods[m]["metrics"] for m in sorted(mods)
                    if mods[m]["metrics"]},
        "sources": {m: os.path.basename(mods[m]["source"] or "")
                    for m in sorted(mods)},
        "unexercised": sorted(
            [(u["tier"], u["module"], "+".join(u["metrics_zero"]))
             for u in unex]),
    }


def coverage_id(body):
    return hashlib.sha256(json.dumps(body, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", required=True, help="urg -report directory")
    ap.add_argument("--scope", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--manifest", default=None,
                    help="cov_identity.py manifest, to inherit run_tag and "
                         "completeness")
    ap.add_argument("--urg-log", default=None,
                    help="urg's captured stdout+stderr; the ONLY place the "
                         "'No source found' warning appears")
    ap.add_argument("--partial", action="store_true",
                    help="force the partial-merge downgrade")
    a = ap.parse_args()

    scope = Scope.load(a.scope)
    dash = parse_dashboard(os.path.join(a.report, "dashboard.txt"))
    mods = parse_modinfo(os.path.join(a.report, "modinfo.txt"))
    detail = object_detail_available(a.report, mods)
    missing_src = sources_missing(a.urg_log)

    complete = not a.partial
    run_tag = None
    if a.manifest and os.path.exists(a.manifest):
        man = json.load(open(a.manifest))
        run_tag = man.get("run_tag")
        exp = man.get("suites", {}).get("expected") or []
        verds = man.get("suites", {}).get("verdicts") or {}
        if exp and len([v for v in verds.values()
                        if not str(v).startswith("UNVERIFIED:")]) < len(exp):
            complete = False

    unex = unexercised(mods, scope, complete)
    body = canonical_body(dash, mods, unex)
    cid = coverage_id(body)

    os.makedirs(a.out_dir, exist_ok=True)
    summary = {
        "schema": "tidelink-coverage-summary/1",
        "run_tag": run_tag,
        "completeness": "complete" if complete else "partial",
        "object_detail": detail,
        "sources_urg_could_not_open": missing_src,
        "n_tests": dash.get("n_tests"),
        "urg_version": dash.get("urg_version"),
        "scope_sha256": scope.sha256,
        "coverage_id": cid,
        "total": body["total"],
        "modules": body["modules"],
        "sources": body["sources"],
        "counts": {
            "modules": len(body["modules"]),
            "tier1": sum(1 for u in unex if u["tier"] == 1),
            "tier2": sum(1 for u in unex if u["tier"] == 2),
        },
    }
    with open(os.path.join(a.out_dir, "cov_summary.json"), "w") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)

    unex_doc = {
        "schema": "tidelink-unexercised/1",
        "run_tag": run_tag,
        "basis": {"completeness": summary["completeness"],
                  "object_detail": detail,
                  "sources_urg_could_not_open": missing_src,
                  "scope_sha256": scope.sha256},
        "findings": unex,
    }
    with open(os.path.join(a.out_dir, "unexercised_scoped.json"), "w") as fh:
        json.dump(unex_doc, fh, indent=2, sort_keys=True)

    with open(os.path.join(a.out_dir, "unexercised_scoped.txt"), "w") as fh:
        fh.write("Scoped unexercised list -- run_tag %s\n" % run_tag)
        fh.write("basis: merge=%s  object-detail=%s  scope=%s\n"
                 % (summary["completeness"], detail, scope.sha256[:12]))
        fh.write("       sources urg could not open: %s\n" % missing_src)
        if missing_src not in (0,) and not str(missing_src).startswith("UNVER"):
            fh.write("\n*** urg could not open %s source file(s). Modules defined\n"
                     "*** in them carry NO line/branch metric at all -- they are\n"
                     "*** absent from every percentage on this page, not scored 0.\n"
                     % missing_src)
        if detail != "AVAILABLE":
            fh.write("\n*** OBJECT-LEVEL DETAIL IS %s. Tier-3 (individual\n"
                     "*** uncovered lines/branches) IS NOT REPORTED HERE and an\n"
                     "*** empty tier-3 must NOT be read as 'all lines covered'.\n"
                     % detail)
        if not complete:
            fh.write("\n*** PARTIAL MERGE: every finding below is UNDETERMINED,\n"
                     "*** not UNCOVERED. A suite that did not run is\n"
                     "*** indistinguishable from code that was not reached.\n")
        for klass in Scope.CLASSES:
            rows = [u for u in unex if u["scope"] == klass]
            if not rows:
                continue
            fh.write("\n== %s (%d) ==\n" % (klass, len(rows)))
            for u in sorted(rows, key=lambda r: (r["tier"], r["module"])):
                fh.write("  T%d %-10s %-48s %s\n"
                         % (u["tier"], u["status"], u["module"][:48],
                            u["detail"]))
        fh.write("\n%d module(s) parsed; tier1=%d tier2=%d\n"
                 % (len(body["modules"]), summary["counts"]["tier1"],
                    summary["counts"]["tier2"]))

    print("cov_report: %d modules, tier1=%d tier2=%d, coverage_id=%s"
          % (len(body["modules"]), summary["counts"]["tier1"],
             summary["counts"]["tier2"], cid[:16]))
    print("cov_report: object_detail=%s completeness=%s"
          % (detail, summary["completeness"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
