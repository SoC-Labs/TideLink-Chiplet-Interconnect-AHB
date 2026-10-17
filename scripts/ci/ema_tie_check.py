#!/usr/bin/env python3
"""TL-057 gate: every TSMC register-file macro instance in the shipping file
sets must tie EMA to 3'b010 and EMAW to 2'b00.

Those are the macro defaults: /research/precompiled_mems/TSMC65/rf_{08k,16k}/*.v
warn "Set Value for EMA doesn't match Default value 2" and "... EMAW ... Default
value 0". TL-057 was EMA tied 3'b000 under a "default" comment, so the check is
on the VALUE, not on the comment. Deterministic, no simulator.

Scope = the file sets of flists/tidelink_fpga_v2.flist and
flists/tidelink_top_full_asic_v2.flist (nested -f followed). A macro instance is
any `rf_<n>k <inst> (` ; each must connect .EMA and .EMAW to a sized constant
equal to the default. A missing connection, a non-constant, or a different
value is a FAIL. The ASIC file set MUST contain at least 2 macro instances
(rf_08k + rf_16k in tidelink_sram.sv): finding none is a FAIL, never a pass, so
a mistyped regex or a flist that dropped the file cannot go green.

Usage: ema_tie_check.py --check            resolve the two flists (default)
       ema_tie_check.py --files F [F ...]  check explicit files (mutant control)
Exit: 0 clean, 1 violation / nothing found, 2 cannot evaluate.
Control: scripts/ci/tests/test_ema_tie_check.py
"""
import argparse, os, re, sys

ROOT = os.environ.get("TIDELINK_HOME") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLISTS = {"fpga_v2": "flists/tidelink_fpga_v2.flist",
          "asic_v2": "flists/tidelink_top_full_asic_v2.flist"}
WANT = {"EMA": (3, 2), "EMAW": (2, 0)}          # port -> (width, value)
MIN_ASIC_INSTANCES = 2

INST = re.compile(r"\b(rf_\d+k)\s+(?:#\s*\([^)]*\)\s*)?(\w+)\s*\(", re.S)


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def parse_const(s):
    m = re.fullmatch(r"\s*(\d+)\s*'\s*([bdhoBDHO])\s*([0-9a-fA-F_]+)\s*", s)
    if not m:
        return None
    base = {"b": 2, "d": 10, "h": 16, "o": 8}[m.group(2).lower()]
    try:
        return int(m.group(1)), int(m.group(3).replace("_", ""), base)
    except ValueError:
        return None


def port_expr(body, port):
    m = re.search(r"\.%s\s*\(" % port, body)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(body) and depth:
        depth += {"(": 1, ")": -1}.get(body[i], 0)
        i += 1
    return body[m.end():i - 1]


def check_text(text, name):
    """Return (instances, violations) for one file's text."""
    text = strip_comments(text)
    insts, bad = [], []
    for m in INST.finditer(text):
        i, depth = m.end(), 1
        while i < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        body = text[m.end():i - 1]
        insts.append("%s:%s %s" % (name, m.group(1), m.group(2)))
        for port, (w, v) in WANT.items():
            e = port_expr(body, port)
            c = parse_const(e) if e is not None else None
            if e is None:
                bad.append("%s: %s %s has no .%s connection" % (name, m.group(1), m.group(2), port))
            elif c is None:
                bad.append("%s: %s %s .%s(%s) is not a sized constant" % (name, m.group(1), m.group(2), port, e.strip()))
            elif c != (w, v):
                bad.append("%s: %s %s .%s(%s) != %d'd%d (macro default)" % (name, m.group(1), m.group(2), port, e.strip(), w, v))
    return insts, bad


def resolve(flist, seen=None):
    seen = seen if seen is not None else set()
    files, unresolved = [], []
    if flist in seen:
        return files, unresolved
    seen.add(flist)
    with open(flist) as f:
        for raw in f:
            line = re.split(r"\s*//", raw.strip())[0].strip()
            if not line or line.startswith("#"):
                continue
            line = os.path.expandvars(line.replace("${TIDELINK_HOME}", ROOT))
            if line.startswith("-f"):
                sub = line[2:].strip()
                if os.path.isfile(sub):
                    a, b = resolve(sub, seen); files += a; unresolved += b
                else:
                    unresolved.append(sub)
            elif line[0] in "+-":
                continue
            elif "$" in line or not os.path.isfile(line):
                unresolved.append(line)
            else:
                files.append(line)
    return files, unresolved


def run_files(files, label):
    insts, bad = [], []
    for p in files:
        i, b = check_text(open(p, errors="replace").read(), os.path.relpath(p, ROOT) if p.startswith(ROOT) else p)
        insts += i; bad += b
    print("ema_tie_check[%s]: %d file(s), %d rf_* macro instance(s)" % (label, len(files), len(insts)))
    return insts, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--files", nargs="+")
    a = ap.parse_args()
    if a.files:
        insts, bad = run_files(a.files, "files")
        if not insts:
            bad.append("no rf_* macro instance found in given files")
    else:
        insts, bad = [], []
        for label, fl in FLISTS.items():
            p = os.path.join(ROOT, fl)
            if not os.path.isfile(p):
                print("ema_tie_check: cannot evaluate, missing %s" % p); return 2
            files, unres = resolve(p)
            if not files:
                print("ema_tie_check: cannot evaluate, %s resolved no files" % fl); return 2
            i, b = run_files(files, label)
            if unres:
                print("ema_tie_check[%s]: note %d unresolved path(s) skipped (e.g. %s)" % (label, len(unres), unres[0]))
            if label == "asic_v2" and len(i) < MIN_ASIC_INSTANCES:
                b.append("asic_v2: expected >= %d rf_* instances, found %d (checker blind or file dropped)" % (MIN_ASIC_INSTANCES, len(i)))
            insts += i; bad += b
    for b in bad:
        print("EMA_TIE FAIL: " + b)
    if bad:
        print("ema_tie_check: FAIL (%d violation(s))" % len(bad)); return 1
    print("ema_tie_check: PASS (%d macro instance(s), all EMA=3'b010 EMAW=2'b00)" % len(insts)); return 0


if __name__ == "__main__":
    sys.exit(main())
