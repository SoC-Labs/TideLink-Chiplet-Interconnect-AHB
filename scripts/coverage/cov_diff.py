#!/usr/bin/env python3
"""cov_diff.py - the only part of a coverage number that is worth anything.

    python3 scripts/coverage/cov_diff.py --base BASE_DIR --head HEAD_DIR
    python3 scripts/coverage/cov_diff.py --base b/ --head h/ --format text
    python3 scripts/coverage/cov_diff.py --selftest

Each DIR is a coverage artifact's `report/` + `unexercised/` content, i.e. it
holds cov_summary.json and (optionally) unexercised_scoped.json and
cov_manifest.json.

EXIT CODES -- this is a gate, so they are the interface:
    0  PASS      nothing regressed
    1  REGRESSED coverage was lost, or something newly stopped being exercised
    2  REVIEW    comparable, but a human must look (the SCOPE changed, or the
                 same inputs produced a different result)
    3  REFUSED   the comparison is not valid and no number is reported

WHY `REFUSED` IS A FIRST-CLASS OUTCOME
--------------------------------------
The prov.* schema this project already ships gets one thing right that almost
every homegrown manifest gets wrong: `UNVERIFIED:<reason>` is not a value, and
any comparison involving one must be REFUSED rather than resolved. Refusal is
the whole safety property. A diff that quietly treats "could not tell" as a
number is how `git_dirty:false` came to mean "could not evaluate the tree".

Concretely, this program refuses to compare when:

  * either side is a PARTIAL merge. A suite that did not run and code that was
    never reached are indistinguishable in the resulting database, so every
    delta computed across a partial merge is uninterpretable -- and it is
    uninterpretable in the flattering direction, because a suite that failed to
    launch looks exactly like a clean run of a smaller design.
  * either side's coverage_id or input_closure_id is UNVERIFIED. Two
    indeterminate runs must NOT compare equal: `UNVERIFIED:x == UNVERIFIED:x` is
    refused explicitly, because the alternative is that two runs which each
    failed to identify themselves are reported as a reproducible replicate.
  * either side is missing cov_summary.json.

AND WHY A SCOPE CHANGE CANNOT PASS
----------------------------------
The easiest way to make this metric go up is not to write a test. It is to add
a line to SCOPE.txt. So scope_sha256 is part of the compared identity, a change
to it downgrades the best possible verdict to REVIEW, and the diff prints the
scope digests side by side. The reason field on every scope rule is what makes
that review a five-second job instead of an archaeology exercise.

THE 2x2
-------
Reported on every run, because it is the question people actually have:

    closure same + coverage same   REPLICATE      the run reproduces
    closure same + coverage DIFF   NONDETERMINISM same inputs, different
                                                  result. A seed, a race or a
                                                  flaky suite -- a bug report,
                                                  not a coverage delta.
    closure DIFF + coverage same   INERT          something changed that the
                                                  suite cannot see
    closure DIFF + coverage DIFF   ORDINARY       an ordinary change; read the
                                                  per-module table

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import argparse
import json
import os
import sys

METRICS = ("line", "cond", "toggle", "fsm", "branch")
UNV = "UNVERIFIED:"

PASS, REGRESSED, REVIEW, REFUSED = 0, 1, 2, 3
NAMES = {PASS: "PASS", REGRESSED: "REGRESSED", REVIEW: "REVIEW",
         REFUSED: "REFUSED"}


def is_unv(v):
    return isinstance(v, str) and v.startswith(UNV)


def load(d):
    """Accepts either a flat directory of the three JSON files, or an unpacked
    coverage artifact root (report/ unexercised/ manifest/). Both, because the
    flat form is what a fetched-and-extracted baseline looks like and the
    artifact form is what cov_pack.sh just produced -- and requiring the caller
    to know which is how a comparison ends up silently comparing nothing."""
    out = {}
    for key, fn, sub in (("summary", "cov_summary.json", "report"),
                         ("unexercised", "unexercised_scoped.json", "unexercised"),
                         ("manifest", "cov_manifest.json", "manifest")):
        for p in (os.path.join(d, fn), os.path.join(d, sub, fn)):
            if os.path.exists(p):
                out[key] = json.load(open(p))
                break
        else:
            out[key] = None
    return out


def refusals(side, art):
    """-> list of reasons this side cannot participate in a comparison."""
    r = []
    s = art.get("summary")
    if s is None:
        return ["%s: no cov_summary.json" % side]
    if s.get("completeness") != "complete":
        r.append("%s: merge is %s -- a delta across a partial merge is "
                 "uninterpretable, and uninterpretable in the flattering "
                 "direction" % (side, s.get("completeness")))
    if is_unv(s.get("coverage_id")) or not s.get("coverage_id"):
        r.append("%s: coverage_id is %s" % (side, s.get("coverage_id")))
    m = art.get("manifest")
    if m is not None:
        cid = m.get("digests", {}).get("input_closure_id")
        if is_unv(cid):
            # NOT a refusal on its own -- the coverage RESULT is still
            # comparable, we simply cannot say whether the inputs matched. The
            # 2x2 degrades to "unknown closure", which is reported as such.
            pass
    return r


def cell_2x2(base, head):
    """The four-way classification, with the fail-closed equality rule."""
    def closure(art):
        m = art.get("manifest")
        return m.get("digests", {}).get("input_closure_id") if m else None

    cb, ch = closure(base), closure(head)
    kb = base["summary"].get("coverage_id")
    kh = head["summary"].get("coverage_id")

    if cb is None or ch is None:
        cl = "UNKNOWN-CLOSURE"
    elif is_unv(cb) or is_unv(ch):
        # THE RULE. Two runs that each failed to identify their inputs are not
        # a replicate of each other however identical the failure text.
        cl = "UNKNOWN-CLOSURE"
    else:
        cl = "same" if cb == ch else "diff"

    cov = "same" if (kb and kh and kb == kh) else "diff"

    if cl == "UNKNOWN-CLOSURE":
        return "UNKNOWN-CLOSURE/%s" % cov, (
            "the inputs could not be identified on at least one side, so "
            "'same inputs' cannot be established -- only the RESULT is compared")
    if cl == "same" and cov == "same":
        return "REPLICATE", "same inputs, same result -- the run reproduces"
    if cl == "same" and cov == "diff":
        return "NONDETERMINISM", (
            "SAME INPUTS, DIFFERENT RESULT. This is a bug report, not a "
            "coverage delta: a seed, a race, or a suite that does not always "
            "run the same stimulus")
    if cl == "diff" and cov == "same":
        return "INERT", ("the inputs changed and the coverage did not -- the "
                         "suite cannot see this change")
    return "ORDINARY", "inputs and coverage both moved -- read the table"


def metric_deltas(b, h):
    out = {}
    for k in ("score",) + METRICS:
        vb, vh = b.get(k), h.get(k)
        if vb is None and vh is None:
            continue
        out[k] = {"base": vb, "head": vh,
                  "delta": (None if (vb is None or vh is None)
                            else round(vh - vb, 4)),
                  # 'was collected, now is not' is a REGRESSION of the
                  # measurement even when no percentage moved. It is how a
                  # metric silently stops being gathered.
                  "collection": ("lost" if (vb is not None and vh is None)
                                 else "gained" if (vb is None and vh is not None)
                                 else "same")}
    return out


def unexercised_index(art):
    u = art.get("unexercised")
    if not u:
        return None
    return {(f["module"], "+".join(f.get("metrics_zero") or [])): f
            for f in u.get("findings", [])}


def compare(base, head, tol=0.0, blocking_scopes=("own", "shipping-vendor")):
    res = {"schema": "tidelink-coverage-diff/1", "verdict": None,
           "refusals": [], "notes": [], "cell": None,
           "total": {}, "modules": {}, "unexercised": {}}

    res["refusals"] = refusals("base", base) + refusals("head", head)
    if res["refusals"]:
        res["verdict"] = NAMES[REFUSED]
        return REFUSED, res

    sb, sh = base["summary"], head["summary"]
    cell, why = cell_2x2(base, head)
    res["cell"] = {"cell": cell, "meaning": why}

    scope_changed = sb.get("scope_sha256") != sh.get("scope_sha256")
    res["scope"] = {"base": sb.get("scope_sha256"), "head": sh.get("scope_sha256"),
                    "changed": scope_changed}
    if scope_changed:
        res["notes"].append(
            "SCOPE.txt CHANGED between these two artifacts. The cheapest way to "
            "raise a coverage number is to exclude something; this comparison "
            "therefore cannot return PASS. Read the reason field on the changed "
            "rules.")

    res["total"] = metric_deltas(sb.get("total", {}), sh.get("total", {}))

    mods_b, mods_h = sb.get("modules", {}), sh.get("modules", {})
    regressed, gone, arrived = [], [], []
    for m in sorted(set(mods_b) | set(mods_h)):
        if m not in mods_h:
            gone.append(m)
            continue
        if m not in mods_b:
            arrived.append(m)
            continue
        d = metric_deltas(mods_b[m], mods_h[m])
        bad = {k: v for k, v in d.items()
               if (v["delta"] is not None and v["delta"] < -tol)
               or v["collection"] == "lost"}
        if bad:
            regressed.append({"module": m, "metrics": bad})
        res["modules"][m] = d
    res["module_changes"] = {"regressed": regressed,
                             "disappeared": gone, "appeared": arrived}

    ib, ih = unexercised_index(base), unexercised_index(head)
    newly, resolved = [], []
    if ib is not None and ih is not None:
        for k, f in sorted(ih.items()):
            if k not in ib:
                newly.append(f)
        for k, f in sorted(ib.items()):
            if k not in ih:
                resolved.append(f)
        res["unexercised"] = {
            "newly_unexercised": newly, "resolved": resolved,
            "base_count": len(ib), "head_count": len(ih)}
    else:
        res["unexercised"] = {"UNVERIFIED": "one side has no "
                              "unexercised_scoped.json; newly-unexercised "
                              "cannot be computed and is NOT reported as zero"}
        res["notes"].append(
            "unexercised lists were not both present -- the newly-unexercised "
            "count is NOT zero, it is unmeasured")

    # ---- verdict -------------------------------------------------------
    blocking_new = [f for f in newly if f.get("scope") in blocking_scopes]
    verdict = PASS
    if regressed or gone or blocking_new:
        verdict = REGRESSED
    elif cell == "NONDETERMINISM":
        verdict = REVIEW
    if scope_changed and verdict == PASS:
        verdict = REVIEW
    if cell.startswith("UNKNOWN-CLOSURE") and verdict == PASS:
        verdict = REVIEW
        res["notes"].append(
            "inputs could not be identified on at least one side; a PASS would "
            "assert a comparison that was not actually anchored")

    res["verdict"] = NAMES[verdict]
    res["blocking_newly_unexercised"] = blocking_new
    return verdict, res


def render(res):
    L = []
    L.append("coverage diff -- verdict %s" % res["verdict"])
    if res["refusals"]:
        L.append("")
        L.append("REFUSED. No coverage number is reported, because:")
        for r in res["refusals"]:
            L.append("  - %s" % r)
        return "\n".join(L) + "\n"
    c = res["cell"]
    L.append("cell: %s -- %s" % (c["cell"], c["meaning"]))
    L.append("scope: base=%s head=%s%s"
             % (str(res["scope"]["base"])[:12], str(res["scope"]["head"])[:12],
                "  CHANGED" if res["scope"]["changed"] else ""))
    L.append("")
    L.append("%-8s %8s %8s %8s  %s" % ("metric", "base", "head", "delta", "collection"))
    for k, v in sorted(res["total"].items()):
        L.append("%-8s %8s %8s %8s  %s"
                 % (k, v["base"], v["head"],
                    "--" if v["delta"] is None else "%+.2f" % v["delta"],
                    v["collection"]))
    mc = res.get("module_changes", {})
    if mc.get("regressed"):
        L.append("")
        L.append("REGRESSED modules (%d) -- coverage that used to exist and "
                 "does not now:" % len(mc["regressed"]))
        for r in mc["regressed"]:
            bits = ", ".join(
                "%s %s->%s" % (k, v["base"], v["head"])
                for k, v in sorted(r["metrics"].items()))
            L.append("  %-44s %s" % (r["module"][:44], bits))
    if mc.get("disappeared"):
        L.append("")
        L.append("modules that VANISHED from the report (%d): %s"
                 % (len(mc["disappeared"]), ", ".join(mc["disappeared"][:10])))
        L.append("  a module that stopped appearing is not a module at 100%%; "
                 "it is a module nothing compiled or nothing instantiated.")
    if mc.get("appeared"):
        L.append("")
        L.append("new modules in the report (%d): %s"
                 % (len(mc["appeared"]), ", ".join(mc["appeared"][:10])))
    u = res.get("unexercised") or {}
    if "newly_unexercised" in u:
        L.append("")
        L.append("newly unexercised: %d   resolved: %d   (base %d -> head %d)"
                 % (len(u["newly_unexercised"]), len(u["resolved"]),
                    u["base_count"], u["head_count"]))
        for f in res.get("blocking_newly_unexercised", [])[:20]:
            L.append("  BLOCKING T%d %-40s [%s] %s"
                     % (f["tier"], f["module"][:40], f["scope"], f["detail"]))
        for f in u["resolved"][:10]:
            L.append("  resolved   T%d %-40s [%s]"
                     % (f["tier"], f["module"][:40], f["scope"]))
    for n in res.get("notes", []):
        L.append("")
        L.append("NOTE: %s" % n)
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------
# selftest -- offline, no store, no simulator
# --------------------------------------------------------------------------

def _write(d, name, obj):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w") as fh:
        json.dump(obj, fh)


def selftest():
    import tempfile
    ok = True

    def say(what, cond):
        nonlocal ok
        print("  %-64s %s" % (what, "ok" if cond else "FAIL"))
        ok = ok and cond

    root = tempfile.mkdtemp(prefix="covdiff-selftest-")

    def art(d, cov_id, closure, modules, unex, complete="complete",
            scope="s1"):
        _write(d, "cov_summary.json",
               {"completeness": complete, "coverage_id": cov_id,
                "scope_sha256": scope, "total": {"score": 50.0, "line": 50.0},
                "modules": modules})
        _write(d, "unexercised_scoped.json",
               {"findings": unex})
        _write(d, "cov_manifest.json",
               {"digests": {"input_closure_id": closure}})

    print("cov_diff selftest")

    # 1. identical -> PASS + REPLICATE
    a, b = os.path.join(root, "a"), os.path.join(root, "b")
    mods = {"m1": {"line": 90.0, "toggle": 80.0}}
    art(a, "cov1", "clo1", mods, [])
    art(b, "cov1", "clo1", mods, [])
    v, r = compare(load(a), load(b))
    say("identical artifacts -> PASS/REPLICATE",
        v == PASS and r["cell"]["cell"] == "REPLICATE")

    # 2. a metric drops -> REGRESSED
    c = os.path.join(root, "c")
    art(c, "cov2", "clo2", {"m1": {"line": 80.0, "toggle": 80.0}}, [])
    v, r = compare(load(a), load(c))
    say("line 90 -> 80 is REGRESSED", v == REGRESSED)

    # 3. a metric stops being COLLECTED -> REGRESSED even with no % drop
    d = os.path.join(root, "d")
    art(d, "cov3", "clo3", {"m1": {"line": None, "toggle": 80.0}}, [])
    v, r = compare(load(a), load(d))
    say("line collected -> not collected is REGRESSED (no % moved)",
        v == REGRESSED)

    # 4. partial merge -> REFUSED, and no number reported
    e = os.path.join(root, "e")
    art(e, "cov4", "clo4", mods, [], complete="partial")
    v, r = compare(load(a), load(e))
    say("partial merge -> REFUSED", v == REFUSED and r["refusals"])
    say("REFUSED reports no total deltas", not r["total"])

    # 5. two UNVERIFIED closures must NOT read as a replicate
    f, g = os.path.join(root, "f"), os.path.join(root, "g")
    art(f, "cov1", "UNVERIFIED:incomplete-closure", mods, [])
    art(g, "cov1", "UNVERIFIED:incomplete-closure", mods, [])
    v, r = compare(load(f), load(g))
    say("two identical UNVERIFIED closures are NOT a REPLICATE",
        r["cell"]["cell"].startswith("UNKNOWN-CLOSURE"))
    say("  ...and that downgrades PASS to REVIEW", v == REVIEW)

    # 6. same closure, different coverage -> NONDETERMINISM -> REVIEW
    h = os.path.join(root, "h")
    art(h, "covX", "clo1", mods, [])
    v, r = compare(load(a), load(h))
    say("same closure, different coverage -> NONDETERMINISM",
        r["cell"]["cell"] == "NONDETERMINISM" and v == REVIEW)

    # 7. scope change cannot PASS
    i = os.path.join(root, "i")
    art(i, "cov1", "clo1", mods, [], scope="s2")
    v, r = compare(load(a), load(i))
    say("a SCOPE.txt change cannot return PASS", v == REVIEW)

    # 8. a newly unexercised shipping-vendor module blocks
    j = os.path.join(root, "j")
    art(j, "cov5", "clo5", mods,
        [{"tier": 2, "module": "xhb500_core_addr", "scope": "shipping-vendor",
          "metrics_zero": ["branch"], "detail": "branch arm never taken"}])
    v, r = compare(load(a), load(j))
    say("new tier-2 finding in shipping-vendor scope -> REGRESSED",
        v == REGRESSED and r["blocking_newly_unexercised"])

    # 9. a newly unexercised HARNESS module does not block
    k = os.path.join(root, "k")
    art(k, "cov6", "clo6", mods,
        [{"tier": 1, "module": "some_bfm", "scope": "harness",
          "metrics_zero": ["line"], "detail": "harness"}])
    v, r = compare(load(a), load(k))
    say("new finding in harness scope does NOT block", v == PASS)

    # 10. a module vanishing is a regression, not a 100%
    l = os.path.join(root, "l")
    art(l, "cov7", "clo7", {}, [])
    v, r = compare(load(a), load(l))
    say("a module vanishing from the report is REGRESSED", v == REGRESSED)

    print("cov_diff selftest: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--head")
    ap.add_argument("--tol", type=float, default=0.0,
                    help="tolerated percentage drop per metric (default 0.0 -- "
                         "coverage percentages are exact for the same tests, so "
                         "a tolerance mostly buys the right to ignore a real loss)")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--out", default=None)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()
    if not (a.base and a.head):
        ap.error("--base and --head are required (or --selftest)")

    v, res = compare(load(a.base), load(a.head), tol=a.tol)
    text = json.dumps(res, indent=2, sort_keys=True) if a.format == "json" \
        else render(res)
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text)
    print(text)
    return v


if __name__ == "__main__":
    sys.exit(main())
