#!/usr/bin/env python3
"""TL-045 structural guard: every `tidelink_top` instantiation must connect
`ahb_sub_hexcl`.

WHY THIS EXISTS
    TL-045 refuses a cross-die exclusive access with a two-cycle AHB ERROR and
    never issues it, so it can no longer silently appear to have succeeded. The
    whole mechanism hangs off ONE new input pin, `ahb_sub_hexcl`. An
    instantiation that omits it hands the pin `1'bz` in simulation and a
    constant 0 in synthesis, and a constant 0 means "no exclusive was
    requested" — which is exactly the pre-TL-045 defect, restored, with no
    indication anywhere. Neither a green sim gate nor a clean synthesis run can
    see that: the design is perfectly well-formed, it just cannot tell an
    exclusive from an ordinary access any more.

    There is no safe default the RTL could pick instead. Defaulting the pin
    HIGH would refuse every transfer; defaulting it LOW is the bug. So the
    obligation lives here, where it can be checked mechanically over the whole
    tree, including the wrappers in the parent chiplets.

WHAT IS CHECKED
    Every instantiation of the modules in TRACKED (tidelink_top and the ASIC
    DFT wrapper that re-exports its port) must name `.ahb_sub_hexcl` in its
    port-connection list. Positional instantiations are reported as violations
    outright — a positional connection list cannot be audited for a named pin,
    and adding a port to a positionally-instantiated module silently
    re-associates every connection after it.

    The connection `1'b0` IS accepted. The point is not that every integration
    must support exclusives; it is that every integration must have made a
    DECISION about them and written it down. A tie-off is a decision. An
    omission is not.

WHAT IS NOT CHECKED
    `ahb_sub_hexokay` is an OUTPUT and is constant 0 inside tidelink_top, so an
    unconnected one loses nothing and is not required.

USAGE
    python3 scripts/ci/check_excl_port_wired.py [--root DIR ...]
                                                [--json] [--selftest]

    --root may be given more than once; it defaults to $TIDELINK_HOME (or the
    repo this script lives in). Point it at a parent chiplet to audit that tree
    too:
        python3 scripts/ci/check_excl_port_wired.py \\
            --root . --root ../../nanosoc-ethernet-chiplet

EXIT
    0  every instantiation connects the pin
    1  at least one does not
    2  could-not-evaluate: the scan found NO instantiations at all. A scan that
       finds nothing is NOT a pass — that is how a checker whose file glob
       rotted reports "clean" forever.

CONTROL
    scripts/ci/tests/test_check_excl_port_wired.py drives this parser with
    hand-built instantiations, wired and unwired, and requires the unwired ones
    to be REPORTED. `--selftest` runs the same controls inline.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

# Modules whose instantiations must name the pin. tidelink_dft_wrapper is here
# because it re-exports ahb_sub_hexcl to the ASIC boundary: an instantiation of
# the wrapper that drops the pin loses the marker just as completely as one of
# tidelink_top itself.
TRACKED = ("tidelink_top", "tidelink_dft_wrapper")

REQUIRED_PORT = "ahb_sub_hexcl"

SRC_SUFFIXES = (".v", ".sv", ".vh", ".svh")

# Directories that hold archived / forked copies of the RTL rather than live
# sources. A stale copy under imp/hw_gate is a record of what was built on a
# particular day and must not be edited to satisfy a checker.
SKIP_DIR_PARTS = (
    ".git", "deps", "imp/hw_gate", "v1-release", "scratch_resolved",
    "sim_build", "build", "node_modules",
)


def _skip(path: Path) -> bool:
    s = str(path).replace(os.sep, "/")
    return any(("/" + p + "/") in s or s.endswith("/" + p) for p in SKIP_DIR_PARTS)


def _strip_comments(text: str) -> str:
    """Remove // and /* */ comments, preserving line count.

    Length is NOT preserved character-for-character, so offsets computed on the
    stripped text are only used to count newlines, never to slice the original.
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j == -1:
                break
            out.append(" " * (j - i))
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _match_paren(text: str, open_idx: int):
    """Index just past the ')' matching the '(' at open_idx, or None."""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
    return None


def find_instantiations(text: str, module: str):
    """Yield (line_no, inst_name, conn_text, named) for each instantiation.

    `named` is False when the connection list uses positional association.
    Definitions (`module <name>`) are skipped, as are the parameter override
    list of a `#(...)` so that a parameter named like the port cannot satisfy
    the check.
    """
    src = _strip_comments(text)
    # <module> [#(params)] <instname> ( ... );
    pat = re.compile(
        r"(?<![A-Za-z0-9_$.])" + re.escape(module) + r"(?![A-Za-z0-9_$])"
    )
    for m in pat.finditer(src):
        start = m.start()
        # Skip the module definition itself and any `endmodule : name` label.
        before = src[max(0, start - 40):start]
        if re.search(r"\b(module|endmodule)\s*(:\s*)?$", before):
            continue
        i = m.end()

        def ws(i):
            while i < len(src) and src[i].isspace():
                i += 1
            return i

        i = ws(i)
        # A macro may stand where the parameter override list goes, e.g.
        #     tidelink_top `MASK_PARAMS u_dut ( ... );
        # (cocotb/honest_mask_hs/tb_top.sv). Consuming it here is not cosmetic:
        # without it the instance-name match lands on the macro name, the
        # following token is not '(' and the WHOLE INSTANTIATION IS SKIPPED —
        # i.e. the checker would silently pass a file it never examined. That
        # is the fail-open shape this script exists to prevent, so
        # test_check_excl_port_wired.py pins it.
        while i < len(src) and src[i] == "`":
            mm = re.match(r"`[A-Za-z_][A-Za-z0-9_$]*", src[i:])
            if not mm:
                break
            i = ws(i + len(mm.group(0)))
        # optional parameter override list, possibly via a `define that already
        # expanded to `#( ... )`
        if i < len(src) and src[i] == "#":
            i = ws(i + 1)
            if i < len(src) and src[i] == "(":
                end = _match_paren(src, i)
                if end is None:
                    continue
                i = ws(end)
        # instance name
        nm = re.match(r"[A-Za-z_][A-Za-z0-9_$]*", src[i:])
        if not nm:
            continue
        inst = nm.group(0)
        i = ws(i + len(inst))
        # optional array range on the instance
        if i < len(src) and src[i] == "[":
            depth = 0
            while i < len(src):
                if src[i] == "[":
                    depth += 1
                elif src[i] == "]":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
            i = ws(i)
        if i >= len(src) or src[i] != "(":
            continue
        end = _match_paren(src, i)
        if end is None:
            continue
        conn = src[i:end]
        named = "." in conn
        line_no = src.count("\n", 0, start) + 1
        yield line_no, inst, conn, named


def scan_text(text: str, module: str):
    """Return a list of violation dicts for one file's text."""
    bad = []
    for line_no, inst, conn, named in find_instantiations(text, module):
        if not named:
            bad.append(dict(line=line_no, inst=inst, module=module,
                            why="positional port connections"))
            continue
        if not re.search(r"\.\s*" + re.escape(REQUIRED_PORT) + r"\s*\(", conn):
            bad.append(dict(line=line_no, inst=inst, module=module,
                            why="." + REQUIRED_PORT + " not connected"))
    return bad


def scan_roots(roots):
    total = 0
    violations = []
    scanned_files = 0
    for root in roots:
        root = Path(root).resolve()
        if not root.exists():
            continue
        for p in root.rglob("*"):
            if not p.is_file() or p.suffix not in SRC_SUFFIXES or _skip(p):
                continue
            try:
                text = p.read_text(errors="replace")
            except OSError:
                continue
            if not any(mod in text for mod in TRACKED):
                continue
            scanned_files += 1
            for mod in TRACKED:
                for _l, _i, _c, _n in find_instantiations(text, mod):
                    total += 1
                for v in scan_text(text, mod):
                    v["file"] = str(p)
                    violations.append(v)
    return total, violations, scanned_files


WIRED = """
module tb;
  tidelink_top #(.A(1)) u_dut (
    .hclk (clk),
    .ahb_sub_hsel (sel),
    .ahb_sub_hexcl (1'b0),
    .ahb_sub_hexokay ()
  );
endmodule
"""

UNWIRED = """
module tb;
  tidelink_top #(.A(1)) u_dut (
    .hclk (clk),
    .ahb_sub_hsel (sel)
  );
endmodule
"""

POSITIONAL = """
module tb;
  tidelink_top u_dut (clk, rstn, sel);
endmodule
"""

COMMENTED_OUT = """
module tb;
  tidelink_top u_dut (
    .hclk (clk)
    // .ahb_sub_hexcl (1'b0)
  );
endmodule
"""

DEFINITION_ONLY = """
module tidelink_top (input wire hclk, input wire ahb_sub_hexcl);
endmodule
"""


def selftest():
    """Red/green controls. A checker that cannot produce its failing verdict is
    decoration, so each negative case is asserted to be DETECTED, not merely
    'not crash'."""
    ok = True

    def check(name, text, expect_bad):
        nonlocal ok
        bad = scan_text(text, "tidelink_top")
        got = len(bad)
        verdict = "ok " if got == expect_bad else "FAIL"
        if got != expect_bad:
            ok = False
        print(f"  [{verdict}] {name}: {got} violation(s), expected {expect_bad}"
              + (f"  {bad}" if got != expect_bad else ""))

    print("check_excl_port_wired selftest:")
    check("wired instantiation is clean", WIRED, 0)
    check("UNWIRED instantiation is reported", UNWIRED, 1)
    check("POSITIONAL instantiation is reported", POSITIONAL, 1)
    check("a COMMENTED-OUT connection does not count", COMMENTED_OUT, 1)
    check("the module DEFINITION is not an instantiation", DEFINITION_ONLY, 0)
    # And the could-not-evaluate arm: a scan that finds nothing must not pass.
    n = len(list(find_instantiations(DEFINITION_ONLY, "tidelink_top")))
    if n != 0:
        print(f"  [FAIL] definition counted as {n} instantiation(s)")
        ok = False
    else:
        print("  [ok ] definition contributes no instantiation to the total")
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", action="append", default=[],
                    help="tree to scan (repeatable)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    roots = args.root or [os.environ.get("TIDELINK_HOME")
                          or Path(__file__).resolve().parents[2]]
    total, violations, files = scan_roots(roots)

    if args.json:
        print(json.dumps(dict(total=total, files=files,
                              violations=violations), indent=2))
    else:
        print(f"check_excl_port_wired: {total} instantiation(s) of "
              f"{'/'.join(TRACKED)} across {files} file(s) in "
              f"{', '.join(str(r) for r in roots)}")
        for v in violations:
            print(f"  VIOLATION {v['file']}:{v['line']}  {v['module']} "
                  f"{v['inst']} — {v['why']}")

    if total == 0:
        print("COULD-NOT-EVALUATE: no instantiations found at all. The scan "
              "found nothing, which is not the same as finding nothing wrong "
              "— check --root and SRC_SUFFIXES.", file=sys.stderr)
        return 2
    if violations:
        print(f"FAIL: {len(violations)} instantiation(s) do not connect "
              f".{REQUIRED_PORT}. An unconnected {REQUIRED_PORT} reads 0, "
              f"which means 'not an exclusive', which silently restores the "
              f"pre-TL-045 double-commit. Connect it — 1'b0 is an acceptable "
              f"answer, omission is not.", file=sys.stderr)
        return 1
    print(f"OK: all {total} instantiation(s) connect .{REQUIRED_PORT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
