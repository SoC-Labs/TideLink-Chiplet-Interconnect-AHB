#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
flist_semantic.py -- semantic model, differ and gate check for TideLink flists.

WHY THIS EXISTS
---------------
A flist selects which RTL is compiled.  A wrong flist silently changes the
netlist, and this repo has already shipped defects of exactly that class
(AUTO_ANCHOR_EN=1'b0 in a build; header ECC bypassed in the shipping ASIC
because a flist pointed at a deps bypass copy).  Text-level review of a flist
does not answer the only question that matters -- "do these two versions
select the same set of source files, in the same order, with the same
directives?" -- because comment churn, ${VAR} spelling and path normalisation
all move text without moving semantics, and a single re-pointed line moves
semantics without moving much text.

This module answers that question structurally.

TWO-LAYER MODEL (this is the central design decision)
-----------------------------------------------------
Layer A -- the SEMANTIC KEY.  Machine-independent.  Used for equality, for
    `diff`, and by the merge driver.  Expands ONLY ${TIDELINK_HOME} (to a
    repo-root-relative path); every other variable stays symbolic in its
    canonical ${NAME} spelling.  Rationale: CMSDK_DIR, STDCELL_VERILOG et al
    resolve into per-machine or read-only lab IP-library locations, so
    expanding them would let the same pair of blobs compare EQUAL on one
    machine and UNEQUAL on another -- CI and the operator's laptop would
    disagree about whether a merge is safe.

Layer B -- the RESOLVED PATH.  Machine-dependent.  Used ONLY by `check` for
    the on-disk existence test.  Expands every known variable from the live
    environment.

An absolute path is NEVER rewritten in either layer.  It is recorded as its
own record kind (`abs`) and carries its raw text.  This is deliberate: it
makes the absolute-path finding independent of which worktree the tool runs
in, and it stops a path that merely happens to live under the current repo
root from laundering itself into a clean repo-relative record.

ORDER IS SEMANTICS.  Records are never sorted and never de-duplicated.
flists/tidelink_top_full_asic_v2.flist states in its own header that the
$unit-scope constant headers "MUST compile before any user (2026-07-16
chip-killer #1)".

COMMENTS ARE STRIPPED BEFORE ANY EXPANSION.  Six comment lines in
flists/tidelink_top_full_asic_v2.flist contain the token `$unit`; an
envsubst-style pass that ran first would blank them.

FAIL LOUD, NEVER SKIP.  Any line form outside the measured grammar is a hard
parse error (exit 2), not a silent skip -- silently skipping a line is how a
directive gets lost.  An unset variable is an error, never an empty string;
expanding an unset var to "" turns ${FOO}/src/x.v into the absolute path
/src/x.v, which is both wrong and plausible-looking.

USAGE
-----
    flist_semantic.py normalise <file> [--root DIR] [--follow]
    flist_semantic.py key       <file> [--root DIR]
    flist_semantic.py diff      <a> <b> [--root DIR]
    flist_semantic.py check     [<file>...] [--root DIR] [--lenient-env]
                                [--allow FILE] [--no-ratchet]

EXIT CODES
----------
    0  clean / semantically equal
    1  violations found / not equal   (a real finding)
    2  the tool could not run         (bad grammar, bad allowlist, no repo)

    Never exit 0 on a condition of class 2.  fpga/scripts/merge_guard.sh sets
    the precedent verbatim: "refusing to pass a check I could not run".

stdlib only, python3.6+.
"""

from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import datetime

# --------------------------------------------------------------------------
# Grammar and variables -- both MEASURED over all 44 tracked flists at
# 321edbf, and re-measured at 1112d63 and 28409f5 (stable across all three).
# --------------------------------------------------------------------------

# Every variable that really appears in a tracked flist, plus the two that
# cocotb/flist_deps.mk injects into its envsubst environment.  Only the
# braced ${NAME} form occurs; the bare $NAME form appears solely as `$unit`
# inside comment lines, which are gone before expansion runs.
KNOWN_VARS = (
    "TIDELINK_HOME",        # 1529 uses -- the only one Layer A expands
    "CMSDK_DIR",            #   35 uses -- ${ARM_IP_LIBRARY_PATH}/Corstone-101/...
    "CMSDK_FPGA_SRAM_V",    #   13 uses -- set_env.sh two-branch fallback
    "STDCELL_VERILOG",      #    2 uses
    "MEM_PATH",             #    1 use
    "TIDECHART_HOME",       # injected by cocotb/flist_deps.mk
    "ETH_SS_HOME",          # injected by cocotb/flist_deps.mk
)

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
BARE_VAR_RE = re.compile(r"\$(?!\{)([A-Za-z_][A-Za-z0-9_]*)")

# Record kinds.  No others exist; adding one is a grammar change.
KIND_DEFINE = "define"    # +define+MACRO[=VALUE]
KIND_INCDIR = "incdir"    # +incdir+<path>
KIND_INCLUDE = "include"  # -f <path>   (nested filelist)
KIND_SRC = "src"          # a source path
KIND_ABS = "abs"          # a RAW ABSOLUTE source path -- always a finding

# Default allowlist for `check`.  These three are legitimate and permanent.
# They are built in because this tool ships as two files with no companion
# YAML; an external allowlist (--allow) is unioned on top and is the place to
# record anything with an expiry date or an owner.
DEFAULT_ALLOW = (
    {
        "path": "flists/tidelink_cdc_tear.flist",
        "line_match": "cocotb/tidelink_cdc_tear/dut_src.f",
        "rule": "missing_target",
        "reason": ("generated by cocotb/tidelink_cdc_tear/Makefile on every invocation "
                   "and gitignored there; absent in a clean tree by design"),
        "owner": "builtin",
        "expires": "never",
    },
    {
        "path": "flists/tidelink_cdc_tear_l2a.flist",
        "line_match": "cocotb/tidelink_cdc_tear/dut_src.f",
        "rule": "missing_target",
        "reason": ("generated by cocotb/tidelink_cdc_tear/Makefile on every invocation "
                   "and gitignored there; absent in a clean tree by design"),
        "owner": "builtin",
        "expires": "never",
    },
    {
        "path": "flists/tidelink_netlist.flist",
        "line_match": "tidelink_dc_output/tidelink.mapped.v",
        "rule": "missing_target",
        "reason": ("Design Compiler output, produced by synthesis into "
                   "syn/asic/design-compiler/tidelink_dc_output/, not tracked"),
        "owner": "builtin",
        "expires": "never",
    },
)

MIN_REASON_LEN = 40


class GateError(Exception):
    """Class-2 condition: the tool could not run.  Never downgrade to a pass."""


class ParseError(GateError):
    def __init__(self, path, lineno, text, why):
        super(ParseError, self).__init__(
            "%s:%d: %s\n    offending text: %r" % (path, lineno, why, text))
        self.path = path
        self.lineno = lineno


# --------------------------------------------------------------------------
# Record
# --------------------------------------------------------------------------

class Record(object):
    """One semantic entry.  (kind, value) is the identity; the rest is
    provenance used only for reporting."""

    __slots__ = ("kind", "value", "src_file", "lineno", "raw")

    def __init__(self, kind, value, src_file, lineno, raw):
        self.kind = kind
        self.value = value
        self.src_file = src_file
        self.lineno = lineno
        self.raw = raw

    def identity(self):
        return (self.kind, self.value)

    def __eq__(self, other):
        return isinstance(other, Record) and self.identity() == other.identity()

    def __ne__(self, other):
        return not self.__eq__(other)

    def __repr__(self):
        return "%s\t%s" % (self.kind, self.value)


# --------------------------------------------------------------------------
# Repo root
# --------------------------------------------------------------------------

def git_toplevel(start=None):
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=start or os.getcwd(), stderr=subprocess.DEVNULL)
    except Exception:
        return None
    return os.path.realpath(out.decode("utf-8", "replace").strip())


def resolve_root(explicit):
    """TIDELINK_HOME for Layer A.  Explicit --root wins, then $TIDELINK_HOME,
    then the git toplevel.  Every consumer in the repo does the same thing:
    `TIDELINK_HOME ?= $(realpath $(CURDIR)/../..)`."""
    if explicit:
        return os.path.realpath(explicit)
    env = os.environ.get("TIDELINK_HOME")
    if env:
        return os.path.realpath(env)
    top = git_toplevel()
    if top:
        return top
    raise GateError(
        "cannot determine TIDELINK_HOME: pass --root, export TIDELINK_HOME, "
        "or run inside a git worktree")


# --------------------------------------------------------------------------
# Variable expansion
# --------------------------------------------------------------------------

def expand_symbolic(text, root):
    """Layer A: expand ${TIDELINK_HOME} only.  Every other variable stays
    verbatim so the result is machine-independent.

    A variable outside KNOWN_VARS is NOT a parse error -- it is kept symbolic
    and returned in `unknown` so `check` can report it.  Two reasons: a
    genuinely new project variable must not brick the tool, and a typo'd
    variable is still caught, because it stays in the key and therefore still
    makes the two sides compare unequal.  What must never happen is blanking
    it, which is the failure this whole function exists to prevent."""
    unknown = []

    def sub(m):
        name = m.group(1)
        if name == "TIDELINK_HOME":
            return root
        if name not in KNOWN_VARS:
            unknown.append(name)
        return m.group(0)              # keep symbolic, on purpose

    out = VAR_RE.sub(sub, text)
    return out, unknown


def expand_resolved(text, root, environ):
    """Layer B: expand every known variable from the live environment.
    Returns (expanded_text, unset_var_names).  An unset variable is REPORTED,
    never expanded to the empty string -- blanking ${FOO} in ${FOO}/src/x.v
    would silently manufacture the absolute path /src/x.v."""
    unset = []

    def sub(m):
        name = m.group(1)
        if name == "TIDELINK_HOME":
            # `root` ALREADY encodes the precedence --root > $TIDELINK_HOME >
            # git toplevel (see resolve_root).  Consulting the environment
            # again here would let $TIDELINK_HOME silently override an
            # explicit --root, so Layer B would resolve against a different
            # tree than Layer A canonicalised against -- a half-honoured
            # --root, which is precisely the class of silent inconsistency
            # this tool exists to catch.
            return root
        val = environ.get(name)
        if val:
            return val
        unset.append(name)
        return m.group(0)              # left intact so it is visibly unresolved

    return VAR_RE.sub(sub, text), unset


def unknown_vars_in(text):
    """Variable names used that are not in the project's known set.  Reported
    so KNOWN_VARS gets maintained and so a typo is visible even when the
    environment happens to define the misspelling."""
    return [n for n in VAR_RE.findall(text) if n not in KNOWN_VARS]


# --------------------------------------------------------------------------
# Canonicalisation
# --------------------------------------------------------------------------

def canon_path(raw, root):
    """Return (kind_hint, canonical_value).

    kind_hint is 'abs' for a raw absolute path -- which is NEVER rewritten,
    even when it happens to live under the current repo root.  Otherwise the
    path is ${TIDELINK_HOME}-expanded, normalised, and emitted repo-relative
    when it lands inside the root, or verbatim when it is still symbolic."""
    if raw.startswith("/"):
        # Raw absolute.  Normalise separators only; keep the text, because the
        # text IS the finding.
        return KIND_ABS, os.path.normpath(raw)

    expanded, _unknown = expand_symbolic(raw, root)

    if expanded.startswith("${"):
        # Still symbolic (e.g. bare ${CMSDK_FPGA_SRAM_V}, or ${CMSDK_DIR}/...).
        return KIND_SRC, expanded

    if expanded.startswith("/"):
        norm = os.path.normpath(expanded)
        rootn = os.path.normpath(root)
        if norm == rootn:
            return KIND_SRC, "."
        if norm.startswith(rootn + os.sep):
            return KIND_SRC, os.path.relpath(norm, rootn)
        # Expanded out of the tree: keep absolute so the difference is visible.
        return KIND_SRC, norm

    # Already relative.
    return KIND_SRC, os.path.normpath(expanded)


def parse_lines(lines, path, root):
    """Canonicalise in this exact order -- the order is load-bearing.

      1. split on newlines (no other tokenisation)
      2. strip trailing then leading whitespace
      3. drop empty lines
      4. drop // and # comment lines   <-- BEFORE any expansion ($unit trap)
      5. classify the survivor by prefix
      6. canonicalise the path
      7. emit an ORDERED list; never sort, never dedupe
    """
    records = []
    comments = []
    for i, rawline in enumerate(lines, 1):
        line = rawline.rstrip()
        line = line.strip()
        if not line:
            continue
        if line.startswith("//") or line.startswith("#"):
            comments.append((i, line))
            continue

        bare = BARE_VAR_RE.search(line)
        if bare:
            raise ParseError(path, i, line,
                             "bare $%s variable reference; only the braced "
                             "${NAME} form is supported" % bare.group(1))

        try:
            if line.startswith("+define+"):
                val = line[len("+define+"):]
                if not val:
                    raise ValueError("empty +define+")
                records.append(Record(KIND_DEFINE, val, path, i, line))
                continue

            if line.startswith("+incdir+"):
                val = line[len("+incdir+"):]
                if not val:
                    raise ValueError("empty +incdir+")
                kind, canon = canon_path(val, root)
                records.append(Record(
                    KIND_ABS if kind == KIND_ABS else KIND_INCDIR,
                    canon, path, i, line))
                continue

            if line.startswith("-f ") or line.startswith("-F "):
                val = line[3:].strip()
                if not val or " " in val:
                    raise ValueError("malformed nested filelist include")
                kind, canon = canon_path(val, root)
                records.append(Record(
                    KIND_ABS if kind == KIND_ABS else KIND_INCLUDE,
                    canon, path, i, line))
                continue

            if line.startswith("+") or line.startswith("-"):
                raise ValueError(
                    "unsupported directive; the measured grammar is "
                    "+define+, +incdir+, -f <path>, and bare source paths")

            if " " in line or "\t" in line:
                raise ValueError("multi-token source line")

            kind, canon = canon_path(line, root)
            records.append(Record(kind, canon, path, i, line))

        except ParseError:
            raise
        except ValueError as exc:
            raise ParseError(path, i, line, str(exc))

    return records, comments


def parse_file(path, root):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except IOError as exc:
        raise GateError("cannot read %s: %s" % (path, exc))
    return parse_lines(lines, path, root)


def follow_includes(path, root, environ, _seen=None, _chain=None):
    """Expand nested `-f` includes transitively.  Cycle-safe on realpath.

    NOTE the merge driver never uses this: it must compare ONE file, not its
    transitive closure, or an unrelated downstream edit would block a merge
    that does not touch the file being merged."""
    if _seen is None:
        _seen = set()
    if _chain is None:
        _chain = []

    real = os.path.realpath(path)
    if real in _seen:
        raise GateError("nested -f include cycle: %s -> %s"
                        % (" -> ".join(_chain), path))
    _seen.add(real)
    _chain = _chain + [path]

    records, comments = parse_file(path, root)
    out = []
    for rec in records:
        out.append(rec)
        if rec.kind != KIND_INCLUDE:
            continue
        target, unset = resolve_record(rec, root, environ)
        if unset or not os.path.isfile(target):
            continue                    # reported by check(); do not recurse
        # follow_includes returns a (records, comments) PAIR -- unpack it.
        # Extending `out` with the pair itself would append two lists as if
        # they were records and blow up later with a type error.
        sub_recs, sub_comments = follow_includes(
            target, root, environ, _seen, _chain)
        out.extend(sub_recs)
        comments.extend(sub_comments)
    return out, comments


def resolve_record(rec, root, environ):
    """Layer B.  Returns (absolute_path_or_text, unset_var_names)."""
    val = rec.value
    if rec.kind == KIND_DEFINE:
        return val, []
    text, unset = expand_resolved(val, root, environ)
    if unset:
        return text, unset
    if not os.path.isabs(text):
        text = os.path.join(root, text)
    return os.path.normpath(text), []


def semantic_key(records):
    payload = json.dumps([[r.kind, r.value] for r in records],
                         separators=(",", ":"), sort_keys=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


# --------------------------------------------------------------------------
# diff
# --------------------------------------------------------------------------

def record_delta(a_recs, b_recs, a_label="a", b_label="b", limit=40):
    """Index-aligned delta of only the differing positions."""
    out = []
    n = max(len(a_recs), len(b_recs))
    shown = 0
    for i in range(n):
        ra = a_recs[i] if i < len(a_recs) else None
        rb = b_recs[i] if i < len(b_recs) else None
        if ra is not None and rb is not None and ra == rb:
            continue
        if shown >= limit:
            out.append("  ... %d further differing record(s) suppressed"
                       % (n - i))
            break
        out.append("  [%d] %-7s= %s" % (i, a_label, repr(ra) if ra else "<absent>"))
        out.append("  [%d] %-7s= %s" % (i, b_label, repr(rb) if rb else "<absent>"))
        shown += 1
    return out


# --------------------------------------------------------------------------
# allowlist
# --------------------------------------------------------------------------

def parse_allowlist(path):
    """Restricted YAML subset -- deliberately not a general YAML parser, and
    deliberately strict: anything it does not understand is exit 2, so a
    typo can never silently widen the allowlist.

    Schema:
        allow:
          - path: <repo-relative flist>
            line_match: <substring of the offending entry>
            rule: abs_path | missing_target
            reason: <>= 40 chars>
            owner: <name>
            added: <ISO date>
            expires: <ISO date | never>
    """
    required = ("path", "line_match", "rule", "reason", "owner", "expires")
    entries = []
    cur = None
    seen_header = False
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read().split("\n")
    except IOError as exc:
        raise GateError("allowlist unreadable: %s: %s" % (path, exc))

    for i, line in enumerate(raw, 1):
        s = line.split("#", 1)[0].rstrip()
        if not s.strip():
            continue
        if re.match(r"^allow:\s*$", s):
            seen_header = True
            continue
        m = re.match(r"^\s*-\s+([A-Za-z_]+):\s*(.*)$", s)
        if m:
            if cur is not None:
                entries.append(cur)
            cur = {}
            cur[m.group(1)] = m.group(2).strip().strip('"').strip("'")
            continue
        m = re.match(r"^\s+([A-Za-z_]+):\s*(.*)$", s)
        if m and cur is not None:
            cur[m.group(1)] = m.group(2).strip().strip('"').strip("'")
            continue
        raise GateError("allowlist %s:%d: unparseable line: %r" % (path, i, line))

    if cur is not None:
        entries.append(cur)
    if not seen_header:
        raise GateError("allowlist %s: missing top-level 'allow:' key" % path)

    for e in entries:
        missing = [k for k in required if not e.get(k)]
        if missing:
            raise GateError("allowlist %s: entry %r missing required key(s): %s"
                            % (path, e.get("path", "?"), ", ".join(missing)))
        if e["rule"] not in ("abs_path", "missing_target"):
            raise GateError("allowlist %s: entry %s has unknown rule %r"
                            % (path, e["path"], e["rule"]))
        if len(e["reason"]) < MIN_REASON_LEN:
            raise GateError(
                "allowlist %s: entry %s has a %d-character reason; at least %d "
                "are required so the exemption explains itself to a future reader"
                % (path, e["path"], len(e["reason"]), MIN_REASON_LEN))
        e.setdefault("owner", "unknown")
        e["_builtin"] = False
    return entries


def allow_expired(entry, today):
    exp = str(entry.get("expires", "never")).strip()
    if exp == "never":
        return False
    try:
        d = datetime.datetime.strptime(exp, "%Y-%m-%d").date()
    except ValueError:
        raise GateError("allowlist entry %s: expires must be an ISO date or "
                        "'never', got %r" % (entry.get("path"), exp))
    return d < today


# --------------------------------------------------------------------------
# check
# --------------------------------------------------------------------------

class Finding(object):
    def __init__(self, rule, path, lineno, detail):
        self.rule = rule
        self.path = path
        self.lineno = lineno
        self.detail = detail

    def __str__(self):
        return "%-15s %s:%d  %s" % (self.rule, self.path, self.lineno, self.detail)


def tracked_flists(root):
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "--", "*.flist", "*.f"],
            cwd=root, stderr=subprocess.DEVNULL)
    except Exception as exc:
        raise GateError("git ls-files failed in %s: %s" % (root, exc))
    return [p for p in out.decode("utf-8", "replace").split("\n") if p.strip()]


def do_check(paths, root, environ, allow_path, follow=False):
    allows = [dict(a) for a in DEFAULT_ALLOW]
    for a in allows:
        a["_builtin"] = True
    if allow_path:
        allows.extend(parse_allowlist(allow_path))

    today = datetime.date.today()
    for a in allows:
        if allow_expired(a, today):
            raise GateError(
                "allowlist entry for %s expired on %s (owner %s) -- renew it or "
                "fix the underlying violation; the gate will not run on an "
                "expired exemption" % (a["path"], a["expires"], a["owner"]))

    if not paths:
        paths = tracked_flists(root)

    findings = []
    unresolved = []
    used_allow = set()
    total_entries = 0

    for rel in paths:
        full = rel if os.path.isabs(rel) else os.path.join(root, rel)
        if not os.path.isfile(full):
            findings.append(Finding("missing_flist", rel, 0,
                                    "listed for checking but not present on disk"))
            continue
        # ParseError propagates -> exit 2.  Never a silent skip.
        if follow:
            records, _ = follow_includes(full, root, environ)
        else:
            records, _ = parse_file(full, root)
        display = os.path.relpath(os.path.realpath(full), root)

        for rec in records:
            total_entries += 1

            # ---- Rule A: no absolute paths.  Needs no environment at all,
            # so it is enforced unconditionally.
            if rec.kind == KIND_ABS:
                idx = match_allow(allows, display, rec, "abs_path")
                if idx is not None:
                    used_allow.add(idx)
                    continue
                findings.append(Finding(
                    "abs_path", display, rec.lineno,
                    "absolute path %r -- a tracked flist must use "
                    "${TIDELINK_HOME}/... (the convention of every other "
                    "tracked flist). This breaks in any other checkout, and "
                    "because cocotb/flist_deps.mk drops paths that do not "
                    "resolve, a dead absolute path silently removes the DUT "
                    "from the staleness guard's prerequisites."
                    % rec.value))
                continue

            if rec.kind == KIND_DEFINE:
                continue

            # ---- Rule B: every resolved target must exist (Layer B).
            target, unset = resolve_record(rec, root, environ)
            unknown = unknown_vars_in(rec.value)
            if unset or unknown:
                bits = []
                if unset:
                    bits.append("unset: %s" % ", ".join(sorted(set(unset))))
                if unknown:
                    bits.append("not in KNOWN_VARS: %s"
                                % ", ".join(sorted(set(unknown))))
                unresolved.append(Finding(
                    "unset_var", display, rec.lineno,
                    "%s (%s)%s" % (rec.raw, "; ".join(bits),
                                   " -- did you `source ./set_env.sh`?"
                                   if unset else "")))
                continue

            ok = os.path.isdir(target) if rec.kind == KIND_INCDIR \
                else os.path.isfile(target)
            if ok:
                continue

            idx = match_allow(allows, display, rec, "missing_target")
            if idx is not None:
                used_allow.add(idx)
                continue
            findings.append(Finding(
                "missing_target", display, rec.lineno,
                "%s resolves to %s which does not exist" % (rec.raw, target)))

    # ---- Rule C ratchet: an allowlist entry that excuses nothing is itself a
    # finding.  Applied only to entries the operator owns (an external file);
    # built-ins are reported as an advisory because they are not editable
    # without touching this tool.
    stale = []
    for i, a in enumerate(allows):
        if i in used_allow:
            continue
        if a.get("_builtin"):
            stale.append(("advisory", a))
        else:
            stale.append(("finding", a))

    return findings, unresolved, stale, total_entries, len(paths)


def match_allow(allows, display_path, rec, rule):
    for i, a in enumerate(allows):
        if a["rule"] != rule:
            continue
        if a["path"] != display_path:
            continue
        if a["line_match"] not in rec.raw and a["line_match"] not in rec.value:
            continue
        return i
    return None


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def cmd_normalise(args):
    root = resolve_root(args.root)
    if args.follow:
        records, _ = follow_includes(args.file, root, os.environ)
    else:
        records, _ = parse_file(args.file, root)
    for rec in records:
        print("%s\t%s" % (rec.kind, rec.value))
    if args.summary:
        sys.stderr.write("records=%d key=%s root=%s\n"
                         % (len(records), semantic_key(records), root))
    return 0


def cmd_key(args):
    root = resolve_root(args.root)
    records, _ = parse_file(args.file, root)
    print(semantic_key(records))
    return 0


def comment_relation(a_com, b_com):
    """How the two sides' comment blocks relate.  Returns one of:
        identical | a_subset | b_subset | fork
    `fork` means neither side's comments are an ordered subsequence of the
    other's -- two engineers recorded DIFFERENT provenance for the same
    change, and picking one silently destroys evidence."""
    a = [c for _, c in a_com]
    b = [c for _, c in b_com]
    if a == b:
        return "identical"
    a_in_b = is_subsequence(a, b)
    b_in_a = is_subsequence(b, a)
    if a_in_b and not b_in_a:
        return "a_subset"
    if b_in_a and not a_in_b:
        return "b_subset"
    if a_in_b and b_in_a:
        return "identical"
    return "fork"


def cmd_diff(args):
    root = resolve_root(args.root)
    a_recs, a_com = parse_file(args.a, root)
    b_recs, b_com = parse_file(args.b, root)
    ka, kb = semantic_key(a_recs), semantic_key(b_recs)

    la = args.label_a or os.path.basename(args.a)
    lb = args.label_b or os.path.basename(args.b)

    if args.porcelain:
        rel = comment_relation(a_com, b_com)
        has_abs = any(r.kind == KIND_ABS for r in a_recs + b_recs)
        print("equal=%d" % (1 if ka == kb else 0))
        print("key_a=%s" % ka)
        print("key_b=%s" % kb)
        print("records_a=%d" % len(a_recs))
        print("records_b=%d" % len(b_recs))
        print("comments_a=%d" % len(a_com))
        print("comments_b=%d" % len(b_com))
        print("comment_relation=%s" % rel)
        print("has_abs_path=%d" % (1 if has_abs else 0))
        for r in a_recs + b_recs:
            if r.kind == KIND_ABS:
                print("abs_path=%s" % r.value)
        if ka != kb:
            for line in record_delta(a_recs, b_recs, la, lb):
                print("delta=%s" % line.strip())
        return 0 if ka == kb else 1

    if ka == kb:
        print("SEMANTICALLY EQUAL")
        print("  key     : %s" % ka)
        print("  records : %d (both sides)" % len(a_recs))
        print("  comments: %s=%d  %s=%d" % (la, len(a_com), lb, len(b_com)))
        if len(a_com) != len(b_com):
            sub = is_subsequence([c for _, c in a_com], [c for _, c in b_com])
            rev = is_subsequence([c for _, c in b_com], [c for _, c in a_com])
            if sub:
                print("  comments: %s is an ordered SUBSEQUENCE of %s "
                      "(%s is a documentation superset)" % (la, lb, lb))
            elif rev:
                print("  comments: %s is an ordered SUBSEQUENCE of %s "
                      "(%s is a documentation superset)" % (lb, la, la))
            else:
                print("  comments: FORKED -- neither side's comments are a "
                      "subsequence of the other's")
        return 0

    print("NOT SEMANTICALLY EQUAL")
    print("  key     : %s=%s  %s=%s" % (la, ka, lb, kb))
    print("  records : %s=%d  %s=%d" % (la, len(a_recs), lb, len(b_recs)))
    print("  delta   :")
    for line in record_delta(a_recs, b_recs, la, lb):
        print(line)
    return 1


def is_subsequence(small, big):
    it = iter(big)
    return all(any(x == y for y in it) for x in small)


def cmd_check(args):
    root = resolve_root(args.root)
    findings, unresolved, stale, n_entries, n_files = do_check(
        args.files, root, os.environ, args.allow, args.follow)

    rc = 0
    print("flist gate: %d file(s), %d entr%s"
          % (n_files, n_entries, "y" if n_entries == 1 else "ies"))

    if findings:
        rc = 1
        print("")
        print("VIOLATIONS (%d):" % len(findings))
        for f in findings:
            print("  " + str(f))

    if unresolved:
        print("")
        print("UNRESOLVED (%d) -- variable(s) unset in this environment:"
              % len(unresolved))
        for f in unresolved:
            print("  " + str(f))
        if args.lenient_env:
            print("  [--lenient-env] not counted as a failure.")
        else:
            print("  An unset variable is an error, not an empty string: "
                  "blanking ${FOO} in ${FOO}/src/x.v manufactures the "
                  "absolute path /src/x.v.  Pass --lenient-env to demote this "
                  "to a warning (do that when wiring into `make sim_gate`, "
                  "where a missing `source ./set_env.sh` would otherwise mimic "
                  "an RTL break).")
            rc = 1

    hard_stale = [a for kind, a in stale if kind == "finding"]
    soft_stale = [a for kind, a in stale if kind == "advisory"]
    if hard_stale and not args.no_ratchet:
        rc = 1
        print("")
        print("STALE ALLOWLIST (%d) -- the violation each excused is gone; "
              "delete the entry:" % len(hard_stale))
        for a in hard_stale:
            print("  %s  (rule=%s owner=%s)" % (a["path"], a["rule"], a["owner"]))
    if soft_stale:
        print("")
        print("advisory: %d built-in allowlist entr%s matched nothing "
              "(harmless; prune DEFAULT_ALLOW in this file if permanent):"
              % (len(soft_stale), "y" if len(soft_stale) == 1 else "ies"))
        for a in soft_stale:
            print("  %s" % a["path"])

    print("")
    print("RESULT: %s" % ("FAIL" if rc else "PASS"))
    return rc


ROOT_HELP = ("repo root / TIDELINK_HOME (default: $TIDELINK_HOME, else "
             "`git rev-parse --show-toplevel`)")


def build_parser():
    p = argparse.ArgumentParser(
        prog="flist_semantic.py",
        description="Semantic model, differ and gate check for TideLink flists.")
    p.add_argument("--root", default=None, help=ROOT_HELP)
    sub = p.add_subparsers(dest="cmd")

    # --root is accepted BOTH before and after the subcommand.  argparse would
    # normally let the subparser's default clobber a value given up front, so
    # the per-subcommand copies use SUPPRESS: absent means "leave whatever the
    # top-level parsed", present means "override it".
    def add_root(sp):
        sp.add_argument("--root", default=argparse.SUPPRESS, help=ROOT_HELP)

    n = sub.add_parser("normalise", help="print the canonical model, one entry "
                                         "per line, order preserved")
    add_root(n)
    n.add_argument("file")
    n.add_argument("--follow", action="store_true",
                   help="expand nested -f includes transitively")
    n.add_argument("--summary", action="store_true",
                   help="print record count and key to stderr")
    n.set_defaults(func=cmd_normalise)

    k = sub.add_parser("key", help="print the 16-hex semantic key")
    add_root(k)
    k.add_argument("file")
    k.set_defaults(func=cmd_key)

    d = sub.add_parser("diff", help="exit 0 if semantically equal, 1 if not")
    add_root(d)
    d.add_argument("a")
    d.add_argument("b")
    d.add_argument("--label-a", default=None)
    d.add_argument("--label-b", default=None)
    d.add_argument("--porcelain", action="store_true",
                   help="machine-readable key=value output for the merge driver")
    d.set_defaults(func=cmd_diff)

    c = sub.add_parser("check", help="gate: absolute paths and missing targets")
    add_root(c)
    c.add_argument("files", nargs="*",
                   help="flists to check (default: every tracked *.flist / *.f)")
    c.add_argument("--lenient-env", action="store_true",
                   help="demote unset-variable findings to warnings")
    c.add_argument("--allow", default=None,
                   help="external allowlist file (restricted YAML subset)")
    c.add_argument("--no-ratchet", action="store_true",
                   help="do not fail on allowlist entries that match nothing")
    c.add_argument("--follow", action="store_true",
                   help="follow nested -f includes transitively (redundant when "
                        "checking every tracked flist, useful for a single file)")
    c.set_defaults(func=cmd_check)
    return p


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    if not getattr(args, "func", None):
        parser.print_help(sys.stderr)
        return 2
    try:
        return args.func(args)
    except ParseError as exc:
        sys.stderr.write("flist_semantic: PARSE ERROR\n  %s\n" % exc)
        sys.stderr.write("  The measured grammar is: `//` and `#` comments, "
                         "blank lines, `+define+MACRO`, `+incdir+<path>`, "
                         "`-f <path>`, and bare source paths.\n"
                         "  A line outside it is a hard error, never a silent "
                         "skip -- silently skipping is how a directive gets "
                         "lost.\n")
        return 2
    except GateError as exc:
        sys.stderr.write("flist_semantic: CANNOT RUN\n  %s\n" % exc)
        sys.stderr.write("  Refusing to pass a check I could not run.\n")
        return 2
    except Exception:
        # An unexpected crash must NEVER exit 1: exit 1 is this tool's signal
        # for "real violations found", and Python's default for an unhandled
        # exception is also 1.  A caller diffing exit codes would read a bug
        # in the tool as a finding about the repo.  Force it into class 2.
        import traceback
        sys.stderr.write("flist_semantic: INTERNAL ERROR (this is a tool bug)\n")
        traceback.print_exc()
        sys.stderr.write("  Refusing to pass a check I could not run.\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
