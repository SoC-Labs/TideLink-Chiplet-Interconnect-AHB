#!/usr/bin/env python3
"""TideLink XDC lint — pure-Python port of fpga/scripts/verify_xdc.tcl.

Catches the silicon-only failure mode where a Vivado XDC constraint is
silently dropped (Bug #6). The failure fingerprint that this lint guards
against is the one we have repeatedly seen on the PYNQ-Z2 pair bring-up:

    cal_done = 0, fault byte = 0x00, lk = 0x00, fs = 0, cr = 0

i.e. RX clock recovery / IDELAY arming never initiates because a clocking
or pin-placement constraint was dropped at elaboration time, NOT because
the RTL was wrong.

The two synth-time defects we have actually shipped to silicon and which
this checker would have caught BEFORE silicon:

  Bug #6.a  Procedural Tcl at column 0 in an XDC file
            (`if`/`catch`/`info script`/`get_files`/...).
            Vivado emits `[Designutils 20-1307] command not allowed in
            XDC` and DROPS the constraint silently — no design failure
            until the link wedges on real hardware.

  Bug #6.b  Multi-pin `get_pins -hier -filter {NAME =~ "*..*"}` feeding
            a `create_generated_clock` / `set_input_delay`. Vivado emits
            `[Constraints 18-359]` and ignores the constraint. Bug #6
            again.

This script is a static lint — it does NOT need Vivado on PATH. Use it
as a CI gate AND a pre-cocotb-sim gate: if any XDC file fails the lint,
abort the sim flow (because once the FPGA bitstream is built with broken
constraints, the cocotb suite won't catch it — that's the entire reason
we lost a deploy cycle to Bug #6).

Exit code is 0 if no findings, 1 otherwise. Findings are emitted as
`<path>:<line>: <CODE> <message>` so editors / CI logs can jump to them.

Usage:
    python3 xdc_lint.py [--allow PATTERN ...] <file-or-dir> [<file-or-dir> ...]

Default scan: all XDC files under `fpga/targets/`.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List

CODE_PROCEDURAL = "XDC_PROCEDURAL_TCL"      # bug #6.a
CODE_MULTI_PIN  = "XDC_MULTI_PIN_FILTER"    # bug #6.b
CODE_NESTED_PROC = "XDC_NESTED_PROC_TCL"    # bug #6.a (nested)
CODE_CATCH_BLOCK = "XDC_CATCH_BLOCK"        # bug #6.a

# Procedural Tcl that Vivado refuses to honour inside an XDC.
# (`set` and `set_property` / `get_*` / `create_*` are legal — those are
# Vivado object queries, not procedural Tcl flow control.)
_PROCEDURAL_RE = re.compile(
    r"^\s*(if|catch|file|info\s+script|info\s+exists|get_files"
    r"|foreach|proc|source)\s"
)
_CATCH_RE = re.compile(r"^\s*catch\s*\{")
_NESTED_PROC_RE = re.compile(
    r"\[(file\s+\w+|info\s+script|info\s+exists|get_files)\s"
)
# `get_pins -hier -filter {NAME =~ "*/foo*"}` — wildcard glob that may
# yield >1 pin and silently feed a clock/delay constraint without an
# `lindex 0` reduction.
_MULTI_PIN_RE = re.compile(
    r"get_pins\s+-hier\s+-filter\s+\{NAME\s*=~\s*\"\*/[^\"]*\*[^\"]*\"\}"
)
_LINDEX_GUARD_RE = re.compile(r"\[lindex\s+\[get_pins")


@dataclass
class Finding:
    path: Path
    line: int
    code: str
    text: str

    def __str__(self) -> str:
        # STABLE CONTENT KEY (2026-08-24) -- see the same field on
        # sv_anti_pattern_lint.Finding. For XDC the discriminator is the
        # offending constraint itself, whitespace-collapsed, which is already
        # carried in `text`. fpga/farm_gate.sh ratchets on this instead of the
        # line number. Additive trailing token; existing parsers are unaffected.
        base = f"{self.path}:{self.line}: {self.code} {self.text}"
        return f"{base}  [key={self.key}]" if self.key else base

    @property
    def key(self) -> str:
        """The quoted constraint at the tail of `text`, else the whole message."""
        m = re.search(r"'([^']*)'\s*$", self.text)
        raw = m.group(1) if m else self.text
        return re.sub(r"\s+", " ", raw).strip()[:120]


def scan_xdc(path: Path, allow_patterns: List[re.Pattern]) -> List[Finding]:
    findings: List[Finding] = []
    try:
        text = path.read_text(errors="replace")
    except OSError as e:
        print(f"warning: cannot read {path}: {e}", file=sys.stderr)
        return findings

    for lineno, raw in enumerate(text.splitlines(), start=1):
        # Strip comments
        line = re.sub(r"#.*$", "", raw)
        if not line.strip():
            continue
        # Allow-list (per-line)
        if any(p.search(raw) for p in allow_patterns):
            continue

        if _PROCEDURAL_RE.search(line):
            findings.append(
                Finding(path, lineno, CODE_PROCEDURAL,
                        f"procedural Tcl inside XDC (Vivado will drop "
                        f"constraint, [Designutils 20-1307]): {line.strip()!r}")
            )
        if _CATCH_RE.search(line):
            findings.append(
                Finding(path, lineno, CODE_CATCH_BLOCK,
                        f"catch {{...}} block inside XDC (silent failure on "
                        f"any nested error, [Designutils 20-1307]): "
                        f"{line.strip()!r}")
            )
        if _NESTED_PROC_RE.search(line):
            findings.append(
                Finding(path, lineno, CODE_NESTED_PROC,
                        f"nested procedural Tcl inside [...] substitution "
                        f"(Vivado may drop, [Designutils 20-1307]): "
                        f"{line.strip()!r}")
            )
        if _MULTI_PIN_RE.search(line) and not _LINDEX_GUARD_RE.search(line):
            findings.append(
                Finding(path, lineno, CODE_MULTI_PIN,
                        f"multi-pin get_pins glob NOT reduced by `lindex 0` — "
                        f"feeds clock/delay constraint with >1 pin "
                        f"([Constraints 18-359]): {line.strip()!r}")
            )

    return findings


def iter_xdcs(paths: Iterable[str]) -> Iterable[Path]:
    for p in paths:
        pp = Path(p)
        if pp.is_dir():
            for xdc in sorted(pp.rglob("*.xdc")):
                yield xdc
        elif pp.is_file() and pp.suffix == ".xdc":
            yield pp


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["fpga/targets"],
                    help="XDC files or directories (default: fpga/targets)")
    ap.add_argument("--allow", action="append", default=[],
                    help="Regex of lines to allow (skip)")
    ap.add_argument("--quiet", "-q", action="store_true")
    args = ap.parse_args(argv)

    allow_patterns = [re.compile(p) for p in args.allow]

    total: List[Finding] = []
    n_files = 0
    for xdc in iter_xdcs(args.paths):
        n_files += 1
        total.extend(scan_xdc(xdc, allow_patterns))

    if not args.quiet:
        print(f"scanned {n_files} XDC file(s)")
    if not total:
        if not args.quiet:
            print("OK — no XDC anti-patterns detected")
        return 0
    for f in total:
        print(str(f))
    print(f"FAIL — {len(total)} XDC finding(s) across {n_files} file(s)")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
