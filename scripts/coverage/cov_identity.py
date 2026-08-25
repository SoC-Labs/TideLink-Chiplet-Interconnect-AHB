#!/usr/bin/env python3
"""cov_identity.py - the FAIL-CLOSED identity of a coverage artifact.

    python3 scripts/coverage/cov_identity.py --out manifest.json \
        --suites-dir imp/sim_gate --scope scripts/coverage/SCOPE.txt

WHY THIS FILE EXISTS
--------------------
This project has shipped a build manifest that said `git_dirty: false` when the
truth was "the tree could not be evaluated", and one that said
`source_commit: "unknown"` AND `git_dirty: false` in the same document -- a
build whose commit git could not determine, recorded as clean. The fix landed
for bitstreams in fpga/scripts/build_provenance.tcl (tl_git_sha, 2026-08-24).
This is the same contract for coverage, written once so nothing has to
re-derive it.

THE CONTRACT, in four rules. Every one of them exists because its absence has
already produced a wrong answer somewhere in this programme.

  R1  A field is either a MEASURED VALUE or the string "UNVERIFIED:<reason>".
      There is no third state and there is no default. Every subprocess call
      here is wrapped; a failure writes UNVERIFIED with the reason, never a
      fallback that looks like a measurement. (This is the prov.* schema-1 rule
      from asic-toolkit, which got it right; do not reinvent it worse.)

  R2  tree_state may read "clean" ONLY when `git rev-parse` succeeded AND
      `git status --porcelain` succeeded AND its output was empty. Any other
      outcome -- non-zero rc, a submodule-symlink rc=128, a timeout -- is
      "UNVERIFIED:<reason>", and NEVER "clean". The failure that motivated this
      was a `[catch]` short-circuit that left `dirty` unset, so an unevaluable
      tree scored as pristine.

  R3  An UNVERIFIED field anywhere in `identity` sets promotable=false. The
      artifact still PUBLISHES -- throwing away coverage evidence because its
      label is imperfect is how instruments end up as a single untracked file
      on one host -- but it can never become the baseline that other runs are
      measured against.

  R4  input_closure_id is NOT computed when any of its inputs is UNVERIFIED.
      It is set to "UNVERIFIED:incomplete-closure". Hashing the literal string
      "UNVERIFIED" would give two DIFFERENT indeterminate runs the SAME id, and
      they would then compare as a replicate of each other. Two unknowns must
      never test equal. cov_diff.py enforces the matching half of this rule.

THE TWO DIGESTS, and why there are two
--------------------------------------
ARTIFACT_FLOW_PLAN_2026-08-23 §7 argues that a run ID must stay ordinal because
the P&R flow is not bit-reproducible, and that digests belong as attributes.
Coverage is the case where that argument pays off, because coverage has a
property GDS does not: the DATABASE is not reproducible (a .vdb embeds the urg
command line, the wall clock and absolute host paths -- see dashboard.txt) but
the coverage CONTENT should be exactly reproducible for the same RTL and the
same tests. So:

  input_closure_id  sha256 over what went IN  (commit, tree state, submodule
                    pins, flist digests, tool version, scope digest, the suite
                    list). Identifies the ATTEMPT.
  coverage_id       sha256 over what came OUT (the canonical per-module metric
                    body and the scoped unexercised list, with every date,
                    host, path and command line stripped). Identifies the
                    RESULT.

Their 2x2 is the whole diagnostic value:

  closure same, coverage same  -> replicate. The run is reproducible.
  closure same, coverage DIFF  -> NONDETERMINISM. Same inputs, different
                                  result: a seed, a race, or a flaky suite.
                                  This cell is a bug report, not a coverage
                                  number.
  closure DIFF, coverage same  -> inert change. Something moved that the test
                                  suite cannot see. Often the honest answer.
  closure DIFF, coverage DIFF  -> an ordinary change. Diff it.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import datetime

SCHEMA = "tidelink-coverage-manifest/1"
UNV = "UNVERIFIED:"


def unverified(reason):
    return UNV + reason


def is_unverified(v):
    return isinstance(v, str) and v.startswith(UNV)


def _run(cmd, cwd=None, timeout=60):
    """-> (ok, text). NEVER raises, NEVER returns a plausible-looking default.

    The caller must map `not ok` onto an UNVERIFIED field. There is deliberately
    no `default=` parameter: a default is how "could not tell" becomes "clean".
    """
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return False, "%s: %s" % (type(e).__name__, e)
    if p.returncode != 0:
        return False, "rc=%d %s" % (p.returncode,
                                    (p.stderr or p.stdout).strip()[:160])
    return True, p.stdout


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except OSError as e:
        return unverified("unreadable:%s" % type(e).__name__)
    return h.hexdigest()


def canonical_sha256(obj):
    """sha256 of a canonical JSON encoding: sorted keys, no whitespace drift."""
    blob = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest()


# --------------------------------------------------------------------------
# identity fields
# --------------------------------------------------------------------------

def git_identity(root):
    """-> {"source_commit":..., "tree_state":..., "branch":...}

    R2 lives here. Read the three assignments below as one statement: there is
    no path through this function that produces tree_state == "clean" without
    both git calls having succeeded.
    """
    out = {}
    ok, sha = _run(["git", "-C", root, "rev-parse", "HEAD"])
    out["source_commit"] = sha.strip() if ok else unverified("rev-parse:" + sha)

    ok, st = _run(["git", "-C", root, "status", "--porcelain"])
    if not ok:
        # THE fail-closed line. An unevaluable tree is not a clean tree.
        out["tree_state"] = unverified("status-unevaluable:" + st)
    elif st.strip():
        out["tree_state"] = "dirty"
        out["dirty_paths"] = len(st.strip().splitlines())
    else:
        out["tree_state"] = "clean"

    ok, br = _run(["git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"])
    out["branch"] = br.strip() if ok else unverified("branch:" + br)
    return out


def submodule_pins(root, paths):
    """The gitlink SHA the superproject PINS -- correct even on a host that
    never ran `submodule update`, which is why it is the pin and not the
    checked-out HEAD."""
    pins = {}
    for p in paths:
        ok, sha = _run(["git", "-C", root, "rev-parse", "HEAD:%s" % p])
        pins[p] = sha.strip() if ok else unverified("no-gitlink")
    return pins


def xhb500_tree_state(root):
    """deps/xhb500/generated is GITIGNORED and is not a submodule, yet four
    flists compile 32 files out of it -- so `git status` is structurally blind
    to it and a manifest without this field says nothing about the XHB500
    bridge RTL that was measured. Same field, same reasons, as the bitstream
    manifest.

    This matters more for coverage than for anything else: the arm of this very
    bridge that shipped unexercised (singles_burst, gated on hprot[3] rather
    than hburst) lives in exactly this tree."""
    gen = os.path.join(root, "deps", "xhb500", "generated")
    script = os.path.join(root, "scripts", "xhb500_tree_digest.sh")
    rec = os.path.join(root, "deps", "xhb500", "TREE.sha256")
    recorded = unverified("no-TREE.sha256")
    if os.path.exists(rec):
        try:
            with open(rec) as fh:
                for line in fh:
                    if line.startswith("tree_digest"):
                        recorded = line.split()[1]
                        break
        except OSError as e:
            recorded = unverified("TREE.sha256:%s" % type(e).__name__)
    if not os.path.isdir(gen):
        return "absent", recorded
    if not os.path.exists(script):
        return unverified("no-digest-script"), recorded
    ok, msg = _run(["bash", script], cwd=root, timeout=300)
    return ("match" if ok else "MISMATCH"), recorded


def flist_digests(root, names):
    """sha256 of each flist FILE. Deliberately the flist text, not its resolved
    closure: the closure depends on site env vars that differ per host, and a
    digest that changes when someone else's CMSDK_DIR changes is not an
    identity. The resolved closure is a separate, harder problem (see
    ARTIFACT_FLOW_PLAN §4); this field is honest about being the smaller
    claim."""
    d = {}
    fdir = os.path.join(root, "flists")
    for n in names:
        p = os.path.join(fdir, n)
        d[n] = sha256_file(p) if os.path.exists(p) else unverified("absent")
    return d


def tool_identity():
    """VCS and urg banners. `vcs -ID` prints the version; failure is UNVERIFIED,
    never a hard-coded string, because a manifest that names a simulator version
    the run did not use is worse than one that admits it does not know."""
    out = {}
    ok, t = _run(["vcs", "-ID"], timeout=120)
    if ok:
        line = next((l for l in t.splitlines() if l.strip()), "")
        out["vcs"] = line.strip()[:200]
    else:
        out["vcs"] = unverified("vcs -ID:" + t)
    ok, t = _run(["urg", "-version"], timeout=120)
    out["urg"] = (t.strip().splitlines() or [""])[0][:200] if ok \
        else unverified("urg -version:" + t)
    out["vcs_home"] = os.environ.get("VCS_HOME") or unverified("VCS_HOME-unset")
    return out


def suite_verdicts(suites_dir, expected):
    """Read imp/sim_gate/*.status. A suite with NO status file is
    UNVERIFIED:no-status -- never absent-and-therefore-fine, and never PASS.

    This project has already been bitten by the inverse: a gate whose suites
    were scored but never invoked, and a pair of vacuous checks that could not
    fail. A coverage artifact that claims a suite contributed must be able to
    show the suite's own verdict."""
    got = {}
    for s in expected:
        p = os.path.join(suites_dir, "%s.status" % s)
        if not os.path.exists(p):
            got[s] = unverified("no-status")
            continue
        try:
            with open(p) as fh:
                txt = fh.read().strip()
        except OSError as e:
            got[s] = unverified("status-unreadable:%s" % type(e).__name__)
            continue
        up = txt.upper()
        for token in ("XFAIL", "XCHG", "XERR", "PASS", "FAIL"):
            if token in up:
                got[s] = token
                break
        else:
            got[s] = unverified("status-unparseable:%r" % txt[:40])
    return got


# --------------------------------------------------------------------------
# assembly
# --------------------------------------------------------------------------

DEFAULT_SUBMODULES = ("deps/tidelink-phy", "deps/tidelink-gpio-phy",
                      "deps/axi-chiplet-controller")
DEFAULT_FLISTS = ("tidelink.flist", "tidelink_top.flist", "tidelink_asic.flist",
                  "tidelink_top_full_asic.flist", "tidelink_fpga.flist",
                  "tidelink_fpga_v2.flist")


def build_identity(root, scope_path, flists, submodules, tools=True):
    ident = {}
    ident.update(git_identity(root))
    ident["submodule_pins"] = submodule_pins(root, submodules)
    xhb_state, xhb_digest = xhb500_tree_state(root)
    ident["xhb500_tree"] = xhb_state
    ident["xhb500_digest"] = xhb_digest
    ident["flists"] = flist_digests(root, flists)
    ident["tool"] = tool_identity() if tools else {
        "vcs": unverified("not-probed"), "urg": unverified("not-probed"),
        "vcs_home": unverified("not-probed")}
    ident["scope_sha256"] = sha256_file(scope_path) if scope_path else \
        unverified("no-scope-file")
    ident["host"] = os.environ.get("HOSTNAME") or \
        (_run(["hostname"])[1].strip() or unverified("hostname"))
    ident["user"] = os.environ.get("USER", unverified("USER-unset"))
    return ident


def unverified_fields(obj, prefix=""):
    """Every UNVERIFIED leaf, by dotted path. This list IS the reason a manifest
    is not promotable; it is emitted so the refusal is explainable rather than
    a bare boolean."""
    out = []
    if isinstance(obj, dict):
        for k, v in sorted(obj.items()):
            out += unverified_fields(v, "%s%s." % (prefix, k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out += unverified_fields(v, "%s%d." % (prefix, i))
    elif is_unverified(obj):
        out.append(prefix.rstrip("."))
    return out


def closure_id(ident, expected_suites):
    """R4: refuse to hash an incomplete closure."""
    body = {
        "source_commit": ident.get("source_commit"),
        "tree_state": ident.get("tree_state"),
        "submodule_pins": ident.get("submodule_pins"),
        "xhb500_digest": ident.get("xhb500_digest"),
        "flists": ident.get("flists"),
        "vcs": ident.get("tool", {}).get("vcs"),
        "scope_sha256": ident.get("scope_sha256"),
        "suites_expected": sorted(expected_suites),
    }
    bad = unverified_fields(body)
    if bad:
        return unverified("incomplete-closure:" + ",".join(bad[:6])), bad
    if body["tree_state"] != "clean":
        # A dirty tree has no closure: the inputs are not recoverable from any
        # commit, so an id that looks reproducible would be a lie.
        return unverified("dirty-tree-has-no-closure"), ["tree_state=dirty"]
    return canonical_sha256(body), []


def run_tag(ident, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    sha = ident.get("source_commit", "")
    if is_unverified(sha):
        short = "unknowncommit"
    else:
        short = sha[:8]
    suffix = "" if ident.get("tree_state") == "clean" else "-dirty"
    return "covrun-%s-%s%s" % (stamp, short, suffix)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.environ.get("TIDELINK_HOME", "."))
    ap.add_argument("--scope", default=None)
    ap.add_argument("--suites-dir", default=None,
                    help="imp/sim_gate -- where the *.status files are")
    ap.add_argument("--suites", default=None,
                    help="comma-separated expected suite list")
    ap.add_argument("--flists", default=",".join(DEFAULT_FLISTS))
    ap.add_argument("--no-tools", action="store_true",
                    help="skip the vcs/urg probes (offline selftest)")
    ap.add_argument("--out", default="-")
    a = ap.parse_args()

    root = os.path.abspath(a.root)
    expected = [s for s in (a.suites or "").split(",") if s]
    ident = build_identity(root, a.scope, a.flists.split(","),
                           DEFAULT_SUBMODULES, tools=not a.no_tools)
    cid, why = closure_id(ident, expected)

    doc = {
        "schema": SCHEMA,
        "run_tag": run_tag(ident),
        "produced_at": datetime.datetime.now(datetime.timezone.utc)
                                .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "identity": ident,
        "suites": {
            "expected": sorted(expected),
            "verdicts": suite_verdicts(a.suites_dir, expected)
            if a.suites_dir else {},
        },
        "digests": {"input_closure_id": cid},
        "verdict": {},
    }
    bad = unverified_fields(doc["identity"]) + \
        ["suites.verdicts." + k for k, v in doc["suites"]["verdicts"].items()
         if is_unverified(v)]
    doc["verdict"] = {
        "publishable": True,          # R3: evidence is always worth keeping
        "promotable": not bad and ident.get("tree_state") == "clean"
        and not is_unverified(cid),
        "unverified_fields": bad,
        "reasons": ([] if not bad else ["identity has %d UNVERIFIED field(s)"
                                        % len(bad)])
        + ([] if ident.get("tree_state") == "clean"
           else ["tree_state=%s" % ident.get("tree_state")]),
    }

    text = json.dumps(doc, indent=2, sort_keys=True)
    if a.out == "-":
        print(text)
    else:
        with open(a.out, "w") as fh:
            fh.write(text + "\n")
        print("cov_identity: wrote %s  run_tag=%s promotable=%s"
              % (a.out, doc["run_tag"], doc["verdict"]["promotable"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
