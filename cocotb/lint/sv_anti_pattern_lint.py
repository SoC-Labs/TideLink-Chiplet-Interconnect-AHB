#!/usr/bin/env python3
"""SystemVerilog anti-pattern lint for TideLink.

Catches the two synth bug classes that bit autoneg on silicon but were sim-
tolerant (hence cocotb missed them):

  Bug class #1 — "latch from missing comb default"
      ------------------------------------------------
      An `always_comb` block has paths where one of its driven signals is
      not assigned. Vivado synth reports `[Synth 8-327] inferring latch
      for variable '<sig>_reg'`. In sim the latch's last value is preserved
      so behaviour matches what the designer probably meant; in silicon the
      latch's enable signal glitches and the FSM gets stuck.
      Example: `txn_step_nxt` in `tidelink_autoneg.sv` (fixed in submodule
      commit `be5eed2`).

  Bug class #2 — "collapsed case from missing default"
      ----------------------------------------------------
      A `case (...)` (or `casex` / `casez`) block over a register has no
      explicit `default:` arm AND no `(* full_case *)` / `unique`/`priority`
      assertion. Vivado synth treats the unenumerated encodings as don't-
      cares and the optimiser is free to collapse downstream conditional
      branches. Synth reports `[Synth 8-155] case statement is not full and
      has no default`. In sim, unmatched arms leave outputs at their prior
      value (effectively a hold), so the simulator-observable behaviour is
      identical to what the designer meant. Example: outer `case (state_r)`
      in `tidelink_autoneg.sv` line 444 (fixed in submodule commit
      `6a757e2`).

The scanner is a simple SystemVerilog tokeniser — not a full parser — but
it is good enough to catch both anti-patterns on the autoneg / chiplet
controller / TideLink RTL.

Exit code is 0 if no findings, 1 otherwise. Findings are emitted as
`<path>:<line>: <CODE> <message>` so editors can jump to them.

Usage:
    python3 sv_anti_pattern_lint.py [--quiet] <file-or-dir> [<file-or-dir> ...]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

CODE_CASE_NO_DEFAULT = "CASE_NO_DEFAULT"   # bug #2
CODE_COMB_NO_DEFAULT = "COMB_NO_DEFAULT"   # bug #1

# Whitelist of files that are NOT first-party / not synth-bound and so
# false positives there are not actionable.
WHITELIST_BASENAMES = {
    # Pure behavioural / verification scaffolding
    "wav_latch_model.sv",
    # Interfaces (modports — no procedural blocks worth checking)
    "apb4_if.sv",
    "axi4_if.sv",
}


def _strip_comments(src: str) -> str:
    """Drop // line comments and /* block */ comments but keep line count."""
    out: List[str] = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            # line comment: skip to newline (preserve \n)
            j = src.find("\n", i)
            if j == -1:
                break
            i = j
        elif ch == "/" and nxt == "*":
            # block comment: skip to */ but emit \n for each newline inside
            j = src.find("*/", i + 2)
            if j == -1:
                break
            for c in src[i + 2 : j]:
                if c == "\n":
                    out.append("\n")
            i = j + 2
        elif ch == '"':
            # string literal: keep as-is, find unescaped closing quote
            j = i + 1
            while j < n and src[j] != '"':
                if src[j] == "\\" and j + 1 < n:
                    j += 2
                else:
                    j += 1
            out.append(src[i : j + 1])
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


# Match a `case (...)` / `casex (...)` / `casez (...)` keyword start.
# Note: we also accept `unique case`, `priority case` — both still REQUIRE
# enumerated coverage at synth time, so for synth purposes they still need
# a default to be safe across tool versions.
_CASE_OPEN_RE = re.compile(
    r"\b(?:(?:unique|unique0|priority)\s+)?(case[xz]?)\b", re.IGNORECASE
)
_ENDCASE_RE = re.compile(r"\bendcase\b", re.IGNORECASE)
_DEFAULT_RE = re.compile(r"\bdefault\s*:", re.IGNORECASE)
_ALWAYS_COMB_RE = re.compile(r"\balways_comb\b|\balways\s*@\s*\*", re.IGNORECASE)


@dataclass
class Finding:
    path: Path
    line: int
    code: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.code} {self.message}"


def _line_of(src: str, idx: int) -> int:
    return src.count("\n", 0, idx) + 1


def _find_matching_end(
    src: str, start: int, open_re: re.Pattern, close_re: re.Pattern
) -> Optional[int]:
    """Return index of the closing keyword that matches the opener at `start`.

    Handles nested openers. `start` should be the index AFTER the opener.
    Returns the index of the close keyword, or None.
    """
    pos = start
    depth = 1
    while pos < len(src):
        m_open = open_re.search(src, pos)
        m_close = close_re.search(src, pos)
        if not m_close:
            return None
        if m_open and m_open.start() < m_close.start():
            depth += 1
            pos = m_open.end()
        else:
            depth -= 1
            if depth == 0:
                return m_close.start()
            pos = m_close.end()
    return None


def scan_case_no_default(path: Path, src: str) -> List[Finding]:
    """Bug class #2 — every case/casex/casez must have a `default:` arm."""
    findings: List[Finding] = []
    pos = 0
    while True:
        m = _CASE_OPEN_RE.search(src, pos)
        if not m:
            break
        # Skip "case" used as a label or `endcase` substring guard:
        # _CASE_OPEN_RE already uses \b boundaries so that's fine.
        # However "case" inside `randcase` is intentional — skip.
        # Check preceding char: if alphanumeric/underscore would have been
        # blocked by \b; but `randcase` is one token so \b("case") at the end
        # would NOT match. Belt-and-braces: check.
        start_kw = m.start(1)
        # `randcase` doesn't take a default — it's a SV stochastic block. Skip.
        # Look backwards for "rand"
        back = src.rfind("rand", max(0, start_kw - 4), start_kw)
        if back == start_kw - 4 and src[back:start_kw] == "rand":
            pos = m.end()
            continue
        # Find the `endcase` that closes this `case` (handle nesting).
        end_idx = _find_matching_end(src, m.end(), _CASE_OPEN_RE, _ENDCASE_RE)
        if end_idx is None:
            break
        body = src[m.end() : end_idx]
        if not _DEFAULT_RE.search(body):
            findings.append(
                Finding(
                    path=path,
                    line=_line_of(src, start_kw),
                    code=CODE_CASE_NO_DEFAULT,
                    message=(
                        "case/casex/casez block without explicit `default:` — "
                        "Vivado may collapse arms (see [Synth 8-155]). Add "
                        "`default: ;` or hold-prev assignment."
                    ),
                )
            )
        pos = end_idx + len("endcase")
    return findings


# Regex to find LHS names assigned with blocking `=` or non-blocking `<=`
# *outside* of conditional bodies. We approximate by scanning each statement
# at the `always_comb` block's top level — but that requires bracket parsing
# beyond regex. Pragmatic approach: collect every LHS that appears anywhere
# in the comb block, then ensure each appears assigned at the BLOCK TOP-LEVEL
# (depth-0 outside any `if`/`case`/`for`).
_ASSIGN_RE = re.compile(
    r"""(?P<lhs>[A-Za-z_][\w]*(?:\s*\[[^\]]+\])*)\s*(?:<?=)(?!=)""",
    re.VERBOSE,
)


def _parse_block_body(src: str, open_idx: int) -> Tuple[str, int]:
    """Given index of `begin` (matched), return (body, end_idx_of_end)."""
    # Find matching end accounting for nested begin/end + case/endcase.
    pos = open_idx
    depth = 1
    body_start = open_idx
    KW = re.compile(r"\b(begin|end|case[xz]?|endcase|fork|join|join_any|join_none)\b")
    while pos < len(src):
        m = KW.search(src, pos)
        if not m:
            return src[body_start:], len(src)
        kw = m.group(1)
        if kw == "begin" or kw == "fork":
            depth += 1
        elif kw == "end" or kw in ("join", "join_any", "join_none"):
            depth -= 1
            if depth == 0:
                return src[body_start : m.start()], m.end()
        # case/endcase don't affect begin/end nesting
        pos = m.end()
    return src[body_start:], len(src)


def _branch_assigned_names(body: str) -> set:
    """Collect every LHS name assigned inside `body` (any depth)."""
    out: set = set()
    for m in _ASSIGN_RE.finditer(body):
        name = m.group("lhs").split("[")[0].strip()
        if name in ("if", "for", "while", "case", "begin", "end",
                    "endcase", "unique", "priority", "casex", "casez",
                    "else"):
            continue
        out.add(name)
    return out


def _top_level_assigned_names(body: str) -> Tuple[set, set]:
    """Return (top_level_lhs, any_lhs) within an `always_comb` body.

    "Top level" means: outside any `if (...)`, `case (...) endcase`, or
    nested `begin .. end`. A signal is also considered "covered" (and so
    added to top_lhs) if it is assigned in EVERY arm of a top-level
    case/casex/casez with an explicit `default:` arm, OR in every branch
    of a top-level if/else-if/else chain that terminates in `else`.
    """
    any_lhs: set = set()
    top_lhs: set = set()
    # Pre-pass: every LHS anywhere (assigned at least once inside the block)
    for m in _ASSIGN_RE.finditer(body):
        name = m.group("lhs").split("[")[0].strip()
        if name in ("if", "for", "while", "case", "begin", "end",
                    "endcase", "casex", "casez"):
            continue
        any_lhs.add(name)

    # Pass 2: walk statement-by-statement.
    i = 0
    n = len(body)
    IDENT = re.compile(r"[A-Za-z_]\w*")

    def skip_ws(p: int) -> int:
        while p < n and body[p].isspace():
            p += 1
        return p

    def skip_parens(p: int) -> int:
        """Given index of '(' return index AFTER matching ')'."""
        assert body[p] == "("
        depth = 1
        p += 1
        while p < n and depth > 0:
            if body[p] == "(":
                depth += 1
            elif body[p] == ")":
                depth -= 1
            p += 1
        return p

    def skip_statement(p: int) -> int:
        """Skip ONE complete statement starting at p WITHOUT recording any
        assignments. Handles begin..end, if/else, for/while, case..endcase,
        and simple `... ;`."""
        p = skip_ws(p)
        if p >= n:
            return p
        m = IDENT.match(body, p)
        if m:
            tok = m.group(0)
            if tok == "begin":
                _, eidx = _parse_block_body(body, m.end())
                return eidx
            if tok in ("case", "casex", "casez"):
                k = body.find("(", m.end())
                if k == -1:
                    return n
                k2 = skip_parens(k)
                end_idx = _find_matching_end(
                    body, k2, _CASE_OPEN_RE, _ENDCASE_RE
                )
                if end_idx is None:
                    return n
                return end_idx + len("endcase")
            if tok in ("unique", "unique0", "priority"):
                return skip_statement(m.end())
            if tok == "if":
                k = body.find("(", m.end())
                if k == -1:
                    return n
                k2 = skip_parens(k)
                p2 = skip_statement(k2)
                p3 = skip_ws(p2)
                em = IDENT.match(body, p3)
                if em and em.group(0) == "else":
                    p3 = skip_statement(em.end())
                return p3
            if tok in ("for", "while", "repeat", "foreach"):
                k = body.find("(", m.end())
                if k == -1:
                    return n
                k2 = skip_parens(k)
                return skip_statement(k2)
            if tok in ("end", "endcase", "else"):
                return m.end()
        # Plain statement: scan for `;` at brace-depth 0
        depth = 0
        q = p
        while q < n:
            c = body[q]
            if c == "(":
                depth += 1
            elif c == ")":
                if depth > 0:
                    depth -= 1
            elif c == ";" and depth == 0:
                return q + 1
            q += 1
        return n

    def parse_case_arms(start: int, end_idx: int) -> Tuple[bool, List[set]]:
        """Parse arms of a case body between `start` (just after `(...)`)
        and `end_idx` (index of `endcase`). Returns (has_default, [per-arm
        assigned-name sets]). Each arm is everything between the arm label
        (`X:` or `default:`) and the next arm label or endcase. Assignments
        within nested begin..end inside an arm are included."""
        arms: List[set] = []
        has_default = False
        text = body[start:end_idx]
        # Find arm starts: label `:` followed by either single stmt or begin
        # An arm label can be: integer literal, identifier list, `default`, or
        # a parenthesised expression. We approximate by splitting on `:` that
        # follows a value/identifier at statement scope (i.e. depth 0).
        # Simpler approach: greedily scan for `default:` and `<expr>:` at
        # depth-0.
        arm_label_re = re.compile(
            r"(?<![A-Za-z_0-9])"
            r"(default\s*:|[^;()]{1,200}?:)"
            r"(?=\s*(?:begin\b|[^=:]))"
        )
        # Build list of arm-label positions; tolerate complexity.
        # Simpler manual scan:
        positions: List[Tuple[int, bool]] = []  # (start-of-body, is_default)
        i = 0
        depth = 0
        ln = len(text)
        while i < ln:
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                if depth > 0:
                    depth -= 1
            elif c == "/":
                # comments already stripped, but be safe
                pass
            elif depth == 0 and c == ":" and i + 1 < ln and text[i + 1] != "=" \
                 and (i == 0 or text[i - 1] not in ":="):
                # Likely an arm label terminator. Find label start (after
                # previous ';', '}', '{', `end`, or beginning).
                k = i - 1
                while k >= 0 and text[k] not in (";", "}", "{"):
                    k -= 1
                lbl = text[k + 1 : i].strip()
                # Strip a trailing `end` (closing previous arm's begin..end)
                # which would otherwise glue onto the label.
                lbl = re.sub(r"^end\b", "", lbl).strip()
                # The actual label is the last token (or the only one).
                # For `default` it's a single keyword. For value lists it
                # may be `3'd0` or `ST_A, ST_B` — last token works for
                # default detection.
                last_tok = lbl.split()[-1] if lbl else ""
                is_def = (last_tok.lower() == "default")
                if is_def:
                    has_default = True
                positions.append((start + i + 1, is_def))
            i += 1
        # Compute arm bodies.
        positions.append((end_idx, False))  # sentinel end
        for idx in range(len(positions) - 1):
            arm_start = positions[idx][0]
            arm_end = positions[idx + 1][0]
            arms.append(_branch_assigned_names(body[arm_start:arm_end]))
        return has_default, arms

    def process_top_statement(p: int) -> int:
        """Process ONE top-level statement at p, recording any top-level
        assignment LHS (or "covered" assignments through full case/if-else),
        then return the index just after that statement."""
        p = skip_ws(p)
        if p >= n:
            return p
        m = IDENT.match(body, p)
        if m:
            tok = m.group(0)
            if tok == "begin":
                _, eidx = _parse_block_body(body, m.end())
                return eidx
            if tok in ("case", "casex", "casez"):
                k = body.find("(", m.end())
                if k == -1:
                    return n
                k2 = skip_parens(k)
                end_idx = _find_matching_end(
                    body, k2, _CASE_OPEN_RE, _ENDCASE_RE
                )
                if end_idx is None:
                    return n
                has_def, arms = parse_case_arms(k2, end_idx)
                if has_def and arms:
                    common = set.intersection(*arms) if arms else set()
                    top_lhs.update(common)
                return end_idx + len("endcase")
            if tok in ("unique", "unique0", "priority"):
                # Skip qualifier, recurse to handle case/if
                return process_top_statement(m.end())
            if tok == "if":
                # if (..) <stmt> [else if (..) <stmt>]* [else <stmt>]
                branches: List[set] = []
                has_else = False
                cur = m.end()
                while True:
                    kpar = body.find("(", cur)
                    if kpar == -1:
                        return n
                    kclose = skip_parens(kpar)
                    body_start = skip_ws(kclose)
                    body_end = skip_statement(body_start)
                    branches.append(_branch_assigned_names(
                        body[body_start:body_end]
                    ))
                    # Check for else
                    after = skip_ws(body_end)
                    em = IDENT.match(body, after)
                    if not em or em.group(0) != "else":
                        break
                    next_after = skip_ws(em.end())
                    # else if?
                    em2 = IDENT.match(body, next_after)
                    if em2 and em2.group(0) == "if":
                        cur = em2.end()
                        continue
                    # plain else
                    has_else = True
                    else_start = next_after
                    else_end = skip_statement(else_start)
                    branches.append(_branch_assigned_names(
                        body[else_start:else_end]
                    ))
                    body_end = else_end
                    break
                if has_else and branches:
                    common = set.intersection(*branches)
                    top_lhs.update(common)
                return body_end
            if tok in ("for", "foreach"):
                # for (..) <stmt>  — synth unrolls; treat body assignments
                # as covered (the loop is exhaustive over a constant range
                # in well-written RTL). This is a deliberate trade-off
                # against false positives like `for (int i=...) vec[i] = ...`.
                kpar = body.find("(", m.end())
                if kpar == -1:
                    return n
                kclose = skip_parens(kpar)
                bstart = skip_ws(kclose)
                bend = skip_statement(bstart)
                top_lhs.update(_branch_assigned_names(body[bstart:bend]))
                return bend
            if tok in ("while", "repeat",
                       "end", "endcase", "else"):
                return skip_statement(p)
        # Treat as a top-level statement candidate
        depth = 0
        q = p
        eq = -1
        while q < n:
            c = body[q]
            if c == "(":
                depth += 1
            elif c == ")":
                if depth > 0:
                    depth -= 1
            elif c == "=" and depth == 0 and eq == -1:
                if (q + 1 < n and body[q + 1] == "=") or \
                   (q > 0 and body[q - 1] in "<>!="):
                    pass
                else:
                    eq = q
            elif c == "<" and depth == 0 and eq == -1 and \
                 q + 1 < n and body[q + 1] == "=":
                eq = q + 1
            elif c == ";" and depth == 0:
                if eq != -1:
                    stmt_lhs = body[p:eq].strip()
                    lhs_match = _ASSIGN_RE.match(stmt_lhs + " =")
                    if lhs_match:
                        name = lhs_match.group("lhs").split("[")[0].strip()
                        if name and name not in (
                            "if", "for", "while", "case", "begin", "end",
                            "endcase", "unique", "priority", "casex", "casez"
                        ):
                            top_lhs.add(name)
                return q + 1
            q += 1
        return n

    while i < n:
        prev_i = i
        i = process_top_statement(i)
        if i <= prev_i:
            i = prev_i + 1

    return top_lhs, any_lhs


def scan_comb_no_default(path: Path, src: str) -> List[Finding]:
    """Bug class #1 — every signal assigned inside an `always_comb` block
    must also have a top-level default assignment (i.e. assignment not
    inside any if/case/for branch). If a signal is only assigned inside a
    conditional, synth infers a latch unless every branch assigns it — a
    fragile pattern, especially when feeding a sequential FSM.
    """
    findings: List[Finding] = []
    pos = 0
    while True:
        m = _ALWAYS_COMB_RE.search(src, pos)
        if not m:
            break
        # Locate the `begin` after this header
        b_idx = src.find("begin", m.end())
        # An always_comb without `begin` is a single statement (single LHS,
        # always assigned) — not at risk.
        if b_idx == -1:
            break
        # Check there's no intervening `;` or other always block start
        between = src[m.end() : b_idx]
        if ";" in between or _ALWAYS_COMB_RE.search(between):
            pos = m.end()
            continue
        body, end_idx = _parse_block_body(src, b_idx + len("begin"))
        top_lhs, any_lhs = _top_level_assigned_names(body)
        # Any signal assigned only inside conditionals (any_lhs - top_lhs)
        # is a candidate for a latch.
        unguarded = sorted(any_lhs - top_lhs)
        # Filter: only flag signals that look like `_nxt`, `_n`, `_d` (next-
        # state nomenclature) or any non-control identifier. We exclude
        # obvious sub-block-scoped temps (heuristic: names that contain a
        # `.` would have been excluded by the LHS regex; this is here as
        # safety). Also drop single-letter loop indices.
        unguarded = [
            u for u in unguarded
            if "." not in u
            and u != ""
            and not (len(u) == 1 and u in "ijkmn")
        ]
        for sig in unguarded:
            findings.append(
                Finding(
                    path=path,
                    line=_line_of(src, m.start()),
                    code=CODE_COMB_NO_DEFAULT,
                    message=(
                        f"signal `{sig}` is assigned only inside conditional "
                        f"branches of this always_comb (no top-level default) "
                        f"— Vivado may infer a latch (see [Synth 8-327]). "
                        f"Add `{sig} = <hold-or-zero>;` above the case/if."
                    ),
                )
            )
        pos = end_idx
    return findings


def scan_file(path: Path) -> List[Finding]:
    try:
        raw = path.read_text(errors="replace")
    except OSError as e:
        print(f"warning: cannot read {path}: {e}", file=sys.stderr)
        return []
    src = _strip_comments(raw)
    findings: List[Finding] = []
    findings.extend(scan_case_no_default(path, src))
    findings.extend(scan_comb_no_default(path, src))
    return findings


def iter_sources(paths: Iterable[str]) -> Iterable[Path]:
    for p in paths:
        pp = Path(p)
        if pp.is_dir():
            for sv in sorted(pp.rglob("*.sv")):
                if sv.name in WHITELIST_BASENAMES:
                    continue
                yield sv
        elif pp.is_file():
            yield pp


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", help="SV files or directories")
    ap.add_argument("--quiet", "-q", action="store_true")
    ap.add_argument(
        "--allow-file",
        action="append",
        default=[],
        help="Basename to skip (additional to built-in whitelist)",
    )
    args = ap.parse_args(argv)

    extra_whitelist = set(args.allow_file)

    total: List[Finding] = []
    n_files = 0
    for sv in iter_sources(args.paths):
        if sv.name in extra_whitelist:
            continue
        n_files += 1
        total.extend(scan_file(sv))

    if not args.quiet:
        print(f"scanned {n_files} SystemVerilog file(s)")
    if not total:
        if not args.quiet:
            print("OK — no anti-patterns detected")
        return 0
    for f in total:
        print(str(f))
    print(f"FAIL — {len(total)} finding(s) across {n_files} file(s)")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
