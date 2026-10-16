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
# THE RELEASE-MANAGER QUERY (read-only GET; release manager interfaces.md 26.7):
#   GET <rm>/api/v1/bump-check?component=<id>&path=<p>&from=<sha>&to=<sha>&root=<sha>
#   200 {"verdict": "PASS"|"FAIL"|"UNVERIFIED"|"WARN"|null, "url": "<job page>",
#        "command": "nanosoc-rm test-bump <configuration> <path> <to>", "note": ...}
#   `root` is this tree's commit BEFORE the move (the range's base): a PASS
#   counts only for a test-bump of exactly this move from exactly that commit.
#   Auth: "Authorization: Bearer $NANOSOC_RM_TOKEN" (a reader token,
#   `nanosoc-rm executor token new <name> --reader`).
# <rm> comes from $NANOSOC_RM_URL, else `git config nanosoc.rmUrl`.
#
# JUDGING A LOCAL RUN (--run-local) matches the release manager: `forbid` and
# `require` are LITERAL substrings (never regexes), a declared `rows` format is
# the release manager's to parse (so it is not a PASS here), and a move passes
# only when EVERYTHING its run set needs ran and passed: this tree's affected
# capabilities, the compose entry's capabilities of the moved submodule (or,
# with no compose entry, its own blocking gates), read at the moved commit.
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
    """(manifest dict or None, why-not) of the tree at commit `tip` (never its work tree)."""
    rc, text = git("show", "%s:%s" % (tip, MANIFEST), cwd=cwd, check=False)
    if rc:
        return None, "no %s at %s" % (MANIFEST, tip[:12])
    return parse_manifest(text)


def parse_manifest(text):
    """(manifest dict or None, why-not) from the file's text."""
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


def _hits(entry, path, component=None):
    """Does an affected_by entry name the moved path (itself, a directory above it) or its component?"""
    e = str(entry).strip("/")
    return e == path or path.startswith(e + "/") or (component is not None and e == component)


def affected(manifest, path, component=None):
    """(own capabilities whose affected_by names path, compose entries for path)."""
    caps = [c for c in manifest.get("capabilities") or []
            if isinstance(c, dict) and any(_hits(x, path, component) for x in (c.get("affected_by") or []))]
    comp = [c for c in manifest.get("compose") or []
            if isinstance(c, dict) and str(c.get("path", "")).strip("/") == path]
    return caps, comp


def runs_on_bump(cap):
    when = cap.get("when") or ["on_bump"]
    when = [when] if isinstance(when, str) else when
    return "on_bump" in when and not cap.get("manual")


def sub_manifest(root, path, commit):
    """(manifest or None, why) of the submodule at `path`, read at `commit` from its own checkout. A checkout
    whose HEAD is not `commit` is refused: running its work tree would test another commit than the move."""
    sub = os.path.join(root, path)
    if not os.path.exists(os.path.join(sub, ".git")):
        return None, "%s is not checked out here" % path
    rc, head = git("-C", sub, "rev-parse", "HEAD", check=False)
    if rc or head.strip() != commit:
        return None, "%s is checked out at %s, not the moved commit %s" % (
            path, head.strip()[:12] or "?", commit[:12])
    rc, text = git("-C", sub, "show", "%s:%s" % (commit, MANIFEST), check=False)
    if rc:
        return None, "no %s in %s at %s" % (MANIFEST, path, commit[:12])
    return parse_manifest(text)


def run_set(manifest, path, sub, component=None):
    """[(owner path, capability)] a move of `path` must run (release manager plan._side): the compose entry's
    named capabilities of the moved tree when this tree composes it, else the moved tree's own blocking gates;
    plus this tree's capabilities whose affected_by names the path. `sub` is the moved tree's manifest (or None:
    the caller reports what could not be read). Only capabilities that run on a bump."""
    out = []
    caps, comp = affected(manifest, path, component)
    own = [c for c in (sub or {}).get("capabilities") or [] if isinstance(c, dict)]
    entry = next((c for c in comp if runs_on_bump({"when": c.get("when")})), None) if comp else None
    if comp:
        if entry is not None:
            by_id = {c.get("id"): c for c in own}
            for cid in entry.get("run") or []:
                out.append((path, by_id.get(cid) or {"id": cid, "_missing": True}))
    else:
        out += [(path, c) for c in own if c.get("gate", "block") == "block" and runs_on_bump(c)]
    out += [("", c) for c in caps if runs_on_bump(c)]
    return out


def tier_num(cap):
    m = TIER_RE.match(str(cap.get("tier", "")))
    return int(m.group(1)) if m else 99


def rm_url(cwd=None):
    url = os.environ.get("NANOSOC_RM_URL", "").strip()
    if not url:
        rc, out = git("config", "--get", "nanosoc.rmUrl", cwd=cwd, check=False)
        url = out.strip() if rc == 0 else ""
    return url.rstrip("/")


def ask_rm(base_url, component, path, old, new, root, timeout=5.0, reply=None):
    """(verdict or None, detail). None means no answer: unreachable, refused, unknown. `reply`, a dict, gets
    the whole answer (its `command` names the configuration the release manager would test)."""
    if not base_url:
        return None, "no release-manager URL (set NANOSOC_RM_URL or git config nanosoc.rmUrl)"
    q = urllib.parse.urlencode({"component": component, "path": path,
                                "from": old, "to": new, "root": root})
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
    if isinstance(doc, dict) and reply is not None:
        reply.update(doc)
    verdict = doc.get("verdict") if isinstance(doc, dict) else None
    if not isinstance(verdict, str):
        note = doc.get("note") if isinstance(doc, dict) else None
        return None, "release manager holds no test-bump of this move%s" % (": " + note if note else "")
    return verdict.upper(), doc.get("url") or ""


def run_capability(cap, root):
    """(passed, detail) for one capability run in `root` (the tree that declares it), judged as the release
    manager judges it: exit status, then `forbid` and `require` as literal substrings of the log."""
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
        if str(pat) in text:
            return False, "output contains forbidden %r (log %s)" % (pat, log.name)
    reqs = list(v.get("require") or [])
    if isinstance(v.get("require_count"), dict):
        reqs.append(v["require_count"])
    for rq in reqs:
        if not (isinstance(rq, dict) and rq.get("pattern")):
            continue
        n = text.count(str(rq["pattern"]))
        if n < int(rq.get("min", 1)):
            return False, "%d x %r, want >= %s (log %s)" % (n, rq["pattern"], rq.get("min", 1), log.name)
    if v.get("rows"):
        # Row formats (junit, regress-table, ...) are parsed by the release manager only: an unread row may be
        # a failure, so exit + forbid + require alone is not a PASS here.
        return False, "exit/forbid/require ok, but its rows (%s) are judged by the release manager only (log %s)" \
            % ((v["rows"] or {}).get("format"), log.name)
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
            rsha = new_branch_base(lsha, "--remotes=%s" % remote, cwd=cwd)
            if not rsha:
                continue
        ranges.append((rsha, lsha))
    return ranges


def new_branch_base(tip, *not_refs, cwd=None):
    """The base of a NEW branch: the parent of its oldest commit that no other known branch holds (git rev-list
    TIP --not <refs>), so only the branch's own commits are checked, not every move since the default branch.
    TIP itself when the branch adds no commit; the root commit's empty parent is not a commit, so a branch whose
    whole history is new is checked from its root."""
    rc, out = git("rev-list", "--reverse", tip, "--not", *not_refs, cwd=cwd, check=False)
    new = out.split() if rc == 0 else []
    if not new:
        return tip
    rc, parent = git("rev-parse", "--verify", "--quiet", new[0] + "^", cwd=cwd, check=False)
    return parent.strip() if rc == 0 and parent.strip() else new[0]


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
            reply = {}
            for c in caps:
                say("    affects %-18s %s  %s" % (c.get("id"), c.get("tier", "?"),
                                                  c.get("run", c.get("command", ""))))
            for c in comp:
                say("    composes %s:%s (%s)" % (path, ",".join(c.get("run") or []), c.get("when", "")))
            if manifest and not caps and not comp:
                say("    no declared capability is affected_by %s" % path)
            verdict, detail = ask_rm(base_url, component, path, old, new, base, reply=reply)
            if verdict == "PASS":
                say("    release manager: PASS %s" % detail)
                continue
            if verdict:
                say("    release manager: %s %s" % (verdict, detail))
            else:
                say("    release manager: no verdict — %s" % detail)
            if run_local and manifest:
                sub, sub_why = sub_manifest(root, path, new)
                if sub is None:
                    say("    run-local: the moved tree's capabilities are not read: %s" % sub_why)
                todo = run_set(manifest, path, sub)
                bad = 0 if sub is not None else 1
                if not todo:
                    say("    run-local: nothing in the run set of %s" % path)
                if todo:
                    for owner, c in todo:
                        label = ("%s:%s" % (owner, c.get("id"))) if owner else c.get("id")
                        if c.get("_missing"):
                            say("    run-local %-18s NOT RUN  composed, but %s does not declare it" % (label, path))
                            bad += 1
                            continue
                        if c.get("gate", "block") != "block":
                            say("    run-local %-18s skipped  gate: report" % label)
                            continue
                        if tier_num(c) > max_tier:
                            say("    run-local %-18s NOT RUN  tier %s is above --max-tier t%d" % (
                                label, c.get("tier"), max_tier))
                            bad += 1
                            continue
                        if c.get("regenerates") and os.environ.get("NANOSOC_GEN_OK") != "1":
                            # It writes generated RTL (and today, sources a
                            # set_env.sh to do it). Not here: a sandbox with
                            # NANOSOC_GEN_OK=1 only. Not run is not passed.
                            say("    run-local %-18s NOT RUN  regenerates: true "
                                "(sandbox with NANOSOC_GEN_OK=1 only)" % label)
                            bad += 1
                            continue
                        key = (tip, owner, c.get("id"))
                        if key not in ran:          # one tree, one run per capability
                            ran[key] = run_capability(c, os.path.join(root, owner) if owner else root)
                        ok, d = ran[key]
                        say("    run-local %-18s %s  %s" % (label, "PASS" if ok else "FAIL", d))
                        bad += 0 if ok else 1
                    if not bad:
                        continue
            unresolved += 1
            say("    to check it: %s" % (reply.get("command") if isinstance(reply.get("command"), str)
                                         else "nanosoc-rm test-bump <configuration> %s %s" % (path, new)))
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
