#!/usr/bin/env python3
"""Structural CDC-fix gate for TL-051 (R1) and TL-055 (H30).  Deterministic, no sim.

A glitch / metastability fix cannot be shown by a zero-delay RTL simulation, so
these two fixes had no gate at all (registry truth pass 2026-10-16).  This
checker reads the RTL and asserts the flop STRUCTURE the fixes added.  It does
not match wire names alone: every claim is made about clocked always blocks
(non-blocking assignments, their clock) and about which signal a port
connection resolves to.

  TL-051 / R1   src/rtl/local_overrides/axi_chiplet_controller.sv
    for each of i2c_scl_i, i2c_sda_i (asynchronous pad inputs):
      (1) a clocked block on apb_clk has   s1 <= <raw pad>   and   s2 <= s1
      (2) the raw pad token appears nowhere else in the code (declaration and
          named-port formals aside): no consumer reads the pin directly
      (3) s1 (the metastable stage) feeds ONLY s2
      (4) the .i2c_*_i connection of u_autoneg, u_i2c_slave and u_i2c_master
          resolves (through plain wire/assign aliases) to s2

  TL-055 / H30  same file, `ifdef TIDELINK_PHY_V2 branch
      (5) u_calibrator's .swreset connection is ONE identifier, and that
          identifier is a flop: assigned by non-blocking assignment in exactly
          one apb_clk block and by no continuous assign / wire initialiser
          (i.e. it is not the combinational OR-merge of four flops)

  TL-055 / H30 consumer side   src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv
      (6) a clocked block on `clk` has swreset_s1 <= swreset and
          swreset_s2 <= swreset_s1; raw `swreset` is used nowhere else;
          swreset_s1 feeds only swreset_s2; swreset_sync resolves to
          swreset_s2 and is consumed (>= 1 use)

  TL-051 / R2   same calibrator file
      (7) swi_training_hold_i (apb_clk, SW/peer-written) goes through the same
          two-flop chain on `clk` (swi_training_hold_s1 -> swi_training_mode_r);
          the raw input is read once, s1 feeds only the second stage, and the
          second stage is consumed by the S_HOLD -> S_VALIDATE terms

Exit 0 = all hold.  Exit 1 = a structure is missing (every miss is printed; a
structure that cannot be FOUND is a FAIL, never a skip).  Exit 2 = cannot
evaluate (file unreadable).

Usage: scripts/ci/cdc_sync_structure.py [--ctrl PATH] [--cal PATH]
Control (must-fail mutants of every check): scripts/ci/tests/test_cdc_sync_structure.py
Scope note: preprocessor evaluation defines only TIDELINK_PHY_V2 (the ASIC and
FPGA v2 flists define it); the trunk (non-V2) calibrator instance is unchanged
by H30 on purpose and is not gated.
"""
import os
import re
import sys

ROOT = os.environ.get("TIDELINK_HOME") or os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CTRL_DEFAULT = os.path.join(ROOT, "src/rtl/local_overrides/axi_chiplet_controller.sv")
CAL_DEFAULT = os.path.join(ROOT, "src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv")

DEFINES = {"TIDELINK_PHY_V2"}


# --------------------------------------------------------------------------- lexing
def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def preprocess(t, defines=DEFINES):
    """Resolve `ifdef/`ifndef/`else/`endif for the given define set (other macros
    count as undefined).  Line structure is preserved (dropped lines blanked)."""
    out, stack = [], []          # stack of (this_branch_active, parent_active, taken)
    active = True
    for line in t.split("\n"):
        s = line.strip()
        m = re.match(r"`(ifdef|ifndef|elsif)\s+(\w+)", s)
        if m:
            kind, name = m.groups()
            cond = (name in defines)
            if kind == "ifndef":
                cond = not cond
            if kind == "elsif":
                par, taken = stack[-1][1], stack[-1][2]
                a = par and (not taken) and cond
                stack[-1] = (a, par, taken or a)
                active = a
            else:
                stack.append((active and cond, active, cond))
                active = active and cond
            out.append("")
            continue
        if re.match(r"`else\b", s):
            par, taken = stack[-1][1], stack[-1][2]
            a = par and not taken
            stack[-1] = (a, par, True)
            active = a
            out.append("")
            continue
        if re.match(r"`endif\b", s):
            stack.pop()
            active = stack[-1][0] if stack else True
            out.append("")
            continue
        out.append(line if active else "")
    return "\n".join(out)


def code_of(path, pp=True):
    with open(path, errors="replace") as fh:
        t = strip_comments(fh.read())
    return preprocess(t) if pp else t


# --------------------------------------------------------------------------- structure
def _match_end(t, i, open_re, close_re):
    """t[i] is just after an opening token; return index after matching close."""
    depth, pos = 1, i
    rx = re.compile("(%s)|(%s)" % (open_re, close_re))
    while depth:
        m = rx.search(t, pos)
        if not m:
            return len(t)
        depth += 1 if m.group(1) else -1
        pos = m.end()
    return pos


def _stmt_end(t, i):
    """End index of the statement starting at/after t[i]: begin/end block,
    if (...) stmt [else stmt] (recursively), or a plain `...;` statement."""
    i = re.compile(r"\s*").match(t, i).end()
    if re.compile(r"begin\b").match(t, i):
        return _match_end(t, i + 5, r"\bbegin\b", r"\bend\b")
    m = re.compile(r"if\s*\(").match(t, i)
    if m:
        j = _match_end(t, m.end(), r"\(", r"\)")
        j = _stmt_end(t, j)
        e = re.compile(r"\s*else\b").match(t, j)
        return _stmt_end(t, e.end()) if e else j
    j = t.find(";", i)
    return len(t) if j < 0 else j + 1


NBA = re.compile(r"(\w+)\s*(?:\[[^\]]*\])?\s*<=\s*([^;]+);")


def clocked_blocks(t):
    """[(clock, body_text, start, end)] for every always @(posedge clk ...)."""
    blocks = []
    for m in re.finditer(r"\balways(?:_ff)?\s*@\s*\(\s*(?:posedge|negedge)\s+(\w+)[^)]*\)", t):
        end = _stmt_end(t, m.end())
        blocks.append((m.group(1), t[m.end():end], m.start(), end))
    return blocks


def nbas(blocks):
    """[(clock, block_index, lhs, rhs)] over all clocked blocks."""
    out = []
    for bi, (clk, body, _, _) in enumerate(blocks):
        for m in NBA.finditer(body):
            out.append((clk, bi, m.group(1), re.sub(r"\s+", "", m.group(2))))
    return out


def count_tokens(t, name):
    return len(re.findall(r"(?<![\w.$])%s\b" % re.escape(name), t))


def aliases(t):
    """name -> rhs identifier for plain `wire [..] n = id;` / `assign n = id;`."""
    al = {}
    for m in re.finditer(r"\b(?:wire|assign)\s+(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*(\w+)\s*;", t):
        al[m.group(1)] = m.group(2)
    return al


def resolve(name, al):
    for _ in range(6):
        if name in al:
            name = al[name]
        else:
            break
    return name


def instance_body(t, inst):
    ms = list(re.finditer(r"\b%s\s*\(" % re.escape(inst), t))
    if len(ms) != 1:
        return None, len(ms)
    return t[ms[0].end():_match_end(t, ms[0].end(), r"\(", r"\)")], 1


def port_expr(body, port):
    m = re.search(r"\.%s\s*\(" % re.escape(port), body)
    if not m:
        return None
    return re.sub(r"\s+", " ", body[m.end():_match_end(body, m.end(), r"\(", r"\)") - 1]).strip()


def check_sync_chain(t, raw, clock, tag, fails, notes, raw_uses_allowed_decl=True):
    """raw -> s1 -> s2 on `clock`; return (s1, s2) or None."""
    blocks = clocked_blocks(t)
    ns = nbas(blocks)
    s1c = [(c, b, l) for (c, b, l, r) in ns if r == raw and l != raw]
    if len(s1c) != 1:
        fails.append("%s: expected exactly one clocked `X <= %s;` first stage, found %d"
                     % (tag, raw, len(s1c)))
        return None
    c1, b1, s1 = s1c[0]
    if c1 != clock:
        fails.append("%s: first stage %s is clocked by %s, expected %s" % (tag, s1, c1, clock))
        return None
    s2c = [(c, b, l) for (c, b, l, r) in ns if r == s1 and l != s1]
    if len(s2c) != 1:
        fails.append("%s: first stage %s must feed exactly one second-stage flop, found %d"
                     % (tag, s1, len(s2c)))
        return None
    c2, b2, s2 = s2c[0]
    if c2 != clock or b2 != b1:
        fails.append("%s: second stage %s is not in the same %s block as %s" % (tag, s2, clock, s1))
        return None
    # raw token: only the first-stage NBA rhs (+ declaration / named formals)
    stripped = re.sub(r"\b(?:input|output|inout)\b[^;,)]*\b%s\b" % re.escape(raw), " ", t) \
        if raw_uses_allowed_decl else t
    raw_n = count_tokens(stripped, raw)
    if raw_n != 1:
        fails.append("%s: raw %s is read %d times in code; only the single `%s <= %s` is allowed"
                     % (tag, raw, raw_n, s1, raw))
    # s1 may be WRITTEN (reset value + data) any number of times, but READ only
    # by its own second stage: strip declarations, drop write targets, count reads.
    nodecl = re.sub(r"\b(?:reg|logic|wire)\b[^;=]*;", " ", t)
    reads = len(re.findall(r"(?<![\w.$])%s\b(?!\s*(?:\[[^\]]*\])?\s*<=)" % re.escape(s1), nodecl))
    if reads != 1:
        fails.append("%s: metastable stage %s is read %d times (expected 1: only %s)"
                     % (tag, s1, reads, s2))
    notes.append("%s: %s -> %s -> %s on %s" % (tag, raw, s1, s2, clock))
    return s1, s2


# --------------------------------------------------------------------------- checks
def check_tl051(ctrl_code):
    fails, notes = [], []
    al = aliases(ctrl_code)
    for sig in ("scl", "sda"):
        raw = "i2c_%s_i" % sig
        ch = check_sync_chain(ctrl_code, raw, "apb_clk", "TL-051 %s" % raw, fails, notes)
        if not ch:
            continue
        s2 = ch[1]
        for inst in ("u_autoneg", "u_i2c_slave", "u_i2c_master"):
            body, n = instance_body(ctrl_code, inst)
            if body is None:
                fails.append("TL-051: instance %s found %d times (expected 1)" % (inst, n))
                continue
            expr = port_expr(body, raw)
            if expr is None:
                fails.append("TL-051: %s has no .%s connection" % (inst, raw))
                continue
            got = resolve(expr, al)
            if got != s2:
                fails.append("TL-051: %s.%s is driven by `%s` (resolves to %s), not the second "
                             "synchroniser stage %s" % (inst, raw, expr, got, s2))
            else:
                notes.append("TL-051: %s.%s <- %s -> %s" % (inst, raw, expr, s2))
    return fails, notes


def check_tl055_ctrl(ctrl_code):
    fails, notes = [], []
    body, n = instance_body(ctrl_code, "u_calibrator")
    if body is None:
        return ["TL-055: u_calibrator found %d times in the TIDELINK_PHY_V2 branch (expected 1)" % n], notes
    expr = port_expr(body, "swreset")
    if expr is None:
        return ["TL-055: u_calibrator has no .swreset connection"], notes
    if not re.fullmatch(r"\w+", expr):
        return ["TL-055: u_calibrator.swreset is driven by an EXPRESSION `%s`; the source of a CDC "
                "crossing must be a single flop" % expr], notes
    q = expr
    blocks = clocked_blocks(ctrl_code)
    drivers = [(c, b) for (c, b, l, r) in nbas(blocks) if l == q]
    blks = sorted(set(b for _, b in drivers))
    if len(blks) != 1:
        fails.append("TL-055: %s is assigned in %d clocked blocks (expected exactly 1)" % (q, len(blks)))
    elif drivers[0][0] != "apb_clk":
        fails.append("TL-055: %s is clocked by %s, expected apb_clk" % (q, drivers[0][0]))
    cont = re.findall(r"\bassign\s+%s\b|\b(?:wire|logic)\s+(?:\[[^\]]*\]\s*)?%s\s*=" % (q, q), ctrl_code)
    if cont:
        fails.append("TL-055: %s is also driven combinationally (assign/wire initialiser)" % q)
    if not fails:
        notes.append("TL-055: u_calibrator.swreset <- %s, one apb_clk flop, no continuous driver" % q)
    return fails, notes


def check_tl055_cal(cal_code):
    fails, notes = [], []
    ch = check_sync_chain(cal_code, "swreset", "clk", "TL-055 calibrator swreset", fails, notes)
    if not ch:
        return fails, notes
    s2 = ch[1]
    al = aliases(cal_code)
    if resolve("swreset_sync", al) != s2:
        fails.append("TL-055: swreset_sync resolves to %s, expected %s" % (resolve("swreset_sync", al), s2))
    uses = count_tokens(cal_code, "swreset_sync")
    if uses < 2:    # definition + at least one consumer
        fails.append("TL-055: swreset_sync is not consumed (%d token uses)" % uses)
    else:
        notes.append("TL-055: swreset_sync = %s, %d uses" % (s2, uses - 1))
    return fails, notes


def check_tl051_r2(cal_code):
    fails, notes = [], []
    ch = check_sync_chain(cal_code, "swi_training_hold_i", "clk", "TL-051 R2 swi_training_hold_i",
                          fails, notes)
    if ch:
        nodecl = re.sub(r"\b(?:reg|logic|wire)\b[^;=]*;", " ", cal_code)
        reads = len(re.findall(r"(?<![\w.$])%s\b(?!\s*(?:\[[^\]]*\])?\s*<=)" % re.escape(ch[1]), nodecl))
        if reads < 1:
            fails.append("TL-051 R2: second stage %s is never consumed" % ch[1])
        else:
            notes.append("TL-051 R2: %s consumed %d times" % (ch[1], reads))
    return fails, notes


def run(ctrl_path, cal_path):
    ctrl = code_of(ctrl_path)
    cal = code_of(cal_path, pp=False)
    results = []
    for name, f, arg in (("TL-051 i2c pad 2-flop sync", check_tl051, ctrl),
                         ("TL-055 controller swreset single flop", check_tl055_ctrl, ctrl),
                         ("TL-055 calibrator swreset_sync chain", check_tl055_cal, cal),
                         ("TL-051 R2 calibrator training-hold 2-flop sync", check_tl051_r2, cal)):
        fails, notes = f(arg)
        results.append((name, fails, notes))
    return results


def main(argv):
    ctrl, cal = CTRL_DEFAULT, CAL_DEFAULT
    a = argv[1:]
    while a:
        k = a.pop(0)
        if k == "--ctrl":
            ctrl = a.pop(0)
        elif k == "--cal":
            cal = a.pop(0)
        elif k == "--check":
            pass
        else:
            print(__doc__)
            return 2
    for p in (ctrl, cal):
        if not os.path.isfile(p):
            print("CANNOT EVALUATE: %s unreadable" % p)
            return 2
    bad = 0
    for name, fails, notes in run(ctrl, cal):
        for n in notes:
            print("  ok   " + n)
        if fails:
            bad += 1
            for f in fails:
                print("  FAIL " + f)
            print("FAIL %s" % name)
        else:
            print("PASS %s" % name)
    print("cdc_sync_structure: %s" % ("FAIL (%d check group(s) red)" % bad if bad else "PASS (4/4 check groups)"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
