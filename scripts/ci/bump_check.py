#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# scripts/ci/bump_check.py — is every submodule-pointer move in a push or PR
# backed by a passing bump check?
#
# Copyright 2026, SoC Labs (www.soclabs.org)
# -----------------------------------------------------------------------------
# ONE SCRIPT, TWO STRENGTHS (release-manager decision 3, 2026-10-16):
#
#   --mode warn    the local pre-push hook. Prints what moved, which declared
#                  capabilities that move affects, and the verdict the release
#                  manager holds for it. ALWAYS exits 0: a hook is bypassed by
#                  --no-verify anyway, so it is an early warning, not a gate.
#   --mode block   CI. Exits 1 unless every moved gitlink has a PASS — from the
#                  release manager, or (--run-local, on a host with the tools)
#                  from running the affected capabilities here. No verdict is
#                  a FAIL: "could not ask" is not "passed".
#
# The authoritative gate is the release manager's own bump decision. This is
# the same question asked earlier, closer to the person who moved the pin.
#
# WHAT "AFFECTED" MEANS. .nanosoc/capabilities.yaml, read AT THE COMMIT UNDER
# TEST (never the working tree), lists capabilities; each names the gitlink
# paths whose move must re-run it in `affected_by`. `compose:` entries name the
# submodule's own capabilities that run in this tree's context on a bump.
#
# THE RELEASE-MANAGER QUERY (read-only GET; the endpoint is the contract this
# script proposes — until the server implements it, the answer is "no verdict"):
#   GET <rm>/api/v1/bump-check?component=<id>&path=<p>&from=<sha>&to=<sha>&tree=<sha>
#   200 {"verdict": "PASS"|"FAIL"|"UNVERIFIED"|..., "url": "<job page>"}
#   Auth: "Authorization: Bearer $NANOSOC_RM_TOKEN" when that is set.
# <rm> comes from $NANOSOC_RM_URL, else `git config nanosoc.rmUrl`.
#
# Needs python3 >= 3.6 and nothing else to list moves; PyYAML to read the
# manifest (without it the moves are still reported, and block mode fails).
# -----------------------------------------------------------------------------
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ZERO = "0" * 40
MANIFEST = ".nanosoc/capabilities.yaml"
TIER_RE = re.compile(r"^t(\d+)$")


def git(*args, cwd=None, check=True):
    p = subprocess.run(["git"] + list(args), cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, universal_newlines=True)
    if check and p.returncode:
        raise RuntimeError("git %s: %s" % (" ".join(args), p.stderr.strip()))
    return p.stdout if check else (p.returncode, p.stdout)


def changed_gitlinks(base, tip, cwd=None):
    """[(path, old_sha, new_sha)] for every gitlink added, moved or removed."""
    out = git("diff", "--raw", "--no-abbrev", "--no-renames", base, tip, cwd=cwd)
    moves = []
    for line in out.splitlines():
        # :<old mode> <new mode> <old sha> <new sha> <status>\t<path>
        m = re.match(r"^:(\d{6}) (\d{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) \w+\t(.+)$", line)
        if m and "160000" in (m.group(1), m.group(2)):
            old = m.group(3) if m.group(1) == "160000" else ZERO
            new = m.group(4) if m.group(2) == "160000" else ZERO
            moves.append((m.group(5), old, new))
    return moves


def load_manifest(tip, cwd=None):
    """(manifest dict or None, why-not)."""
    rc, text = git("show", "%s:%s" % (tip, MANIFEST), cwd=cwd, check=False)
    if rc:
        return None, "no %s at %s" % (MANIFEST, tip[:12])
    try:
        import yaml
    except ImportError:
        return None, "PyYAML is not installed, so %s cannot be read" % MANIFEST
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return None, "%s does not parse: %s" % (MANIFEST, str(e).splitlines()[0])
    if not isinstance(doc, dict):
        return None, "%s is not a mapping" % MANIFEST
    # Two spellings are accepted (release-manager schemas/capabilities.schema.json):
    # capabilities|tiers, compose|composes, run|command, cwd|workdir.
    doc["capabilities"] = doc.get("capabilities") or doc.get("tiers") or []
    doc["compose"] = doc.get("compose") or doc.get("composes") or []
    if not isinstance(doc["capabilities"], list) or not isinstance(doc["compose"], list):
        return None, "%s: capabilities/compose must be lists" % MANIFEST
    return doc, ""


def affected(manifest, path):
    """(own capabilities whose affected_by names path, compose entries for path)."""
    caps = [c for c in manifest.get("capabilities") or []
            if isinstance(c, dict) and path in (c.get("affected_by") or [])]
    comp = [c for c in manifest.get("compose") or []
            if isinstance(c, dict) and c.get("path") == path]
    return caps, comp


def tier_num(cap):
    m = TIER_RE.match(str(cap.get("tier", "")))
    return int(m.group(1)) if m else 99


def rm_url(cwd=None):
    url = os.environ.get("NANOSOC_RM_URL", "").strip()
    if not url:
        rc, out = git("config", "--get", "nanosoc.rmUrl", cwd=cwd, check=False)
        url = out.strip() if rc == 0 else ""
    return url.rstrip("/")


def ask_rm(base_url, component, path, old, new, tree, timeout=5.0):
    """(verdict or None, detail). None means no answer: unreachable, refused, unknown."""
    if not base_url:
        return None, "no release-manager URL (set NANOSOC_RM_URL or git config nanosoc.rmUrl)"
    q = urllib.parse.urlencode({"component": component, "path": path,
                                "from": old, "to": new, "tree": tree})
    req = urllib.request.Request("%s/api/v1/bump-check?%s" % (base_url, q),
                                 headers={"Accept": "application/json"})
    tok = os.environ.get("NANOSOC_RM_TOKEN", "").strip()
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            doc = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return None, "release manager answered HTTP %d" % e.code
    except (urllib.error.URLError, OSError, ValueError) as e:
        return None, "release manager not reachable (%s)" % getattr(e, "reason", e)
    verdict = doc.get("verdict") if isinstance(doc, dict) else None
    if not isinstance(verdict, str):
        return None, "release manager reply has no verdict"
    return verdict.upper(), doc.get("url") or ""


def run_capability(cap, root):
    """(passed, detail) for one capability, judged by its verdict: block."""
    run = cap.get("run", cap.get("command"))
    if isinstance(run, list):
        argv = [str(x) for x in run]
    elif isinstance(run, str) and run.strip():
        argv = ["bash", "--noprofile", "--norc", "-c", run]
    else:
        return False, "no run command"
    cwd = cap.get("cwd", cap.get("workdir")) or "."
    v = cap.get("verdict") or {}
    want = v.get("exit", 0)
    budget = cap.get("budget_s") or 3600
    logdir = os.path.join(root, "build", "bump_check")      # build/ is gitignored
    os.makedirs(logdir, exist_ok=True)
    log = tempfile.NamedTemporaryFile(prefix="%s_" % cap.get("id", "cap"), suffix=".log",
                                      dir=logdir, delete=False)
    try:
        p = subprocess.run(argv, cwd=os.path.join(root, cwd),
                           stdout=log, stderr=subprocess.STDOUT, timeout=budget)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        log.close()
        return False, "exceeded budget_s=%s (log %s)" % (budget, log.name)
    log.close()
    with open(log.name, errors="replace") as f:
        text = f.read()
    if rc != want:
        return False, "exit %d, want %d (log %s)" % (rc, want, log.name)
    for pat in v.get("forbid") or []:
        if re.search(pat, text):
            return False, "output matches forbidden %r (log %s)" % (pat, log.name)
    reqs = list(v.get("require") or [])
    if isinstance(v.get("require_count"), dict):
        reqs.append(v["require_count"])
    for rq in reqs:
        if not (isinstance(rq, dict) and rq.get("pattern")):
            continue
        n = len(re.findall(rq["pattern"], text))
        if n < int(rq.get("min", 1)):
            return False, "%d x %r, want >= %s (log %s)" % (n, rq["pattern"], rq.get("min", 1), log.name)
    if v.get("rows"):
        # Row formats (junit, regress-table, ...) are the release manager's job;
        # exit + forbid + require is all this script judges. Say so.
        return True, "ok on exit/forbid/require; rows %s not parsed here (log %s)" % (
            v["rows"].get("format"), log.name)
    return True, "ok (log %s)" % log.name


def pre_push_ranges(stdin, remote, cwd=None):
    """[(base, tip)] from git's pre-push stdin: <lref> <lsha> <rref> <rsha>."""
    ranges = []
    for line in stdin.read().splitlines():
        parts = line.split()
        if len(parts) != 4 or parts[1] == ZERO:
            continue                       # malformed, or a branch deletion
        lsha, rsha = parts[1], parts[3]
        if rsha == ZERO:
            # A new branch: compare against what the remote already has.
            rc, out = git("merge-base", lsha, "refs/remotes/%s/HEAD" % remote, cwd=cwd, check=False)
            if rc:
                rc, out = git("rev-list", "--max-parents=0", lsha, cwd=cwd, check=False)
                out = out.split()[-1] if rc == 0 and out.split() else ""
            rsha = out.strip()
            if not rsha:
                continue
        ranges.append((rsha, lsha))
    return ranges


def check(ranges, mode, run_local=False, max_tier=2, cwd=None, out=sys.stdout):
    """0 = nothing to block; 1 = block (only ever returned in block mode)."""
    root = git("rev-parse", "--show-toplevel", cwd=cwd).strip()
    base_url = rm_url(cwd=root)
    say = lambda s="": print(s, file=out)
    unresolved = 0
    seen = set()
    ran = {}
    for base, tip in ranges:
        moves = changed_gitlinks(base, tip, cwd=root)
        if not moves:
            continue
        tree = git("rev-parse", tip + "^{tree}", cwd=root).strip()
        manifest, why = load_manifest(tip, cwd=root)
        component = (manifest or {}).get("component") or os.path.basename(root)
        say("bump-check: %d submodule pointer move(s) in %s..%s" % (len(moves), base[:12], tip[:12]))
        if manifest is None:
            say("  NOTE: %s" % why)
        for path, old, new in moves:
            if (path, new) in seen:
                continue
            seen.add((path, new))
            say("  %s  %s -> %s" % (path, old[:12], new[:12]))
            if new == ZERO:
                say("    removed: nothing to test; review it by hand")
                continue
            caps, comp = affected(manifest, path) if manifest else ([], [])
            for c in caps:
                say("    affects %-18s %s  %s" % (c.get("id"), c.get("tier", "?"),
                                                  c.get("run", c.get("command", ""))))
            for c in comp:
                say("    composes %s:%s (%s)" % (path, ",".join(c.get("run") or []), c.get("when", "")))
            if manifest and not caps and not comp:
                say("    no declared capability is affected_by %s" % path)
            verdict, detail = ask_rm(base_url, component, path, old, new, tree)
            if verdict == "PASS":
                say("    release manager: PASS %s" % detail)
                continue
            if verdict:
                say("    release manager: %s %s" % (verdict, detail))
            else:
                say("    release manager: no verdict — %s" % detail)
            if run_local and manifest:
                todo = [c for c in caps if c.get("gate", "block") == "block"
                        and not c.get("manual") and tier_num(c) <= max_tier]
                if not todo:
                    say("    run-local: no blocking capability at <= t%d to run" % max_tier)
                else:
                    bad = 0
                    for c in todo:
                        if c.get("regenerates") and os.environ.get("NANOSOC_GEN_OK") != "1":
                            # It writes generated RTL (and today, sources a
                            # set_env.sh to do it). Not here: a sandbox with
                            # NANOSOC_GEN_OK=1 only. Not run is not passed.
                            say("    run-local %-18s NOT RUN  regenerates: true "
                                "(sandbox with NANOSOC_GEN_OK=1 only)" % c.get("id"))
                            bad += 1
                            continue
                        key = (tip, c.get("id"))
                        if key not in ran:          # one tree, one run per capability
                            ran[key] = run_capability(c, root)
                        ok, d = ran[key]
                        say("    run-local %-18s %s  %s" % (c.get("id"), "PASS" if ok else "FAIL", d))
                        bad += 0 if ok else 1
                    if not bad:
                        continue
            unresolved += 1
            say("    to check it: nanosoc-rm test-bump <configuration> %s --to %s"
                % (os.path.basename(path), new))
            say("    or, on a host with the tools:")
            say("      python3 scripts/ci/bump_check.py --mode block --run-local --range %s..%s"
                % (base[:12], tip[:12]))
    if not unresolved:
        return 0
    if mode == "warn":
        say("bump-check: WARNING — %d move(s) without a passing bump check. "
            "Pushing anyway; CI and the release manager will block it." % unresolved)
        return 0
    say("bump-check: FAIL — %d move(s) without a passing bump check" % unresolved)
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0] if __doc__ else None)
    ap.add_argument("--mode", choices=("warn", "block"), default="warn")
    ap.add_argument("--range", action="append", default=[], metavar="BASE..TIP")
    ap.add_argument("--pre-push", metavar="REMOTE",
                    help="read git's pre-push ref lines from stdin")
    ap.add_argument("--run-local", action="store_true",
                    help="block mode: run the affected capabilities here when the RM has no PASS")
    ap.add_argument("--max-tier", type=int, default=2)
    a = ap.parse_args(argv)
    try:
        ranges = [tuple(r.split("..", 1)) for r in a.range]
        if a.pre_push:
            ranges += pre_push_ranges(sys.stdin, a.pre_push)
        if not ranges:
            ap.error("give --range BASE..TIP or --pre-push REMOTE")
        return check(ranges, a.mode, run_local=a.run_local, max_tier=a.max_tier)
    except Exception as e:                  # noqa: BLE001 — a warn hook must never break a push
        print("bump-check: could not check (%s)" % e, file=sys.stderr)
        return 0 if a.mode == "warn" else 1


if __name__ == "__main__":
    sys.exit(main())
