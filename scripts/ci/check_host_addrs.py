#!/usr/bin/env python3
"""check_host_addrs.py - reject host-script register addresses that are not in the register map.

WHY (TL-059 evidence audit, 2026-10-14): a KR260 error-injection tool wrote the UNMAPPED alias 0x003C instead
of LINK_ERROR_INJECTION at 0x23C.  A write to an unmapped APB address is silently dropped; the CRC counter of
an untouched design reads 0, and "0 errors, all exact" looked like a PASS.  Months of CRC-injection evidence
rested on it.  Nothing compared the addresses host scripts use with the register map.  This does.

WHAT IT CHECKS (static, no hardware, a second or two):
  * It builds the register map from the AUTHORITATIVE sources:
        src/rdl/*.rdl            SystemRDL, composed as tidelink_unified_regs.rdl does
                                 (wlink 0x0000, TideLink 0x2000, address translator 0x4000);
        docs/REGISTER_MAP.md     the tables of RTL-only registers that have no RDL (Regions 8, 10, C, D, F
                                 observability, role/autoneg), absolute 0x2xxx rows;
        src/rdl/phc_regs.rdl     the PHC's own separate APB map (only for files that talk to the PHC).
  * It AST-parses every Python file under pynq_host/ , fpga/hw_regression/ and scripts/ (not scripts/ci/tests)
    and extracts the register offsets/addresses the code uses:
        1. integer assignments  NAME = 0x...  (module/class/function level, tuple assignments, folded constants)
        2. literal address arguments of register accessors  rd/wr/read/write/peek/poke/rd32/wr32/rdn/...
        3. BASE + 0x...  where BASE looks like a register base (APB, TLAPB, base, die ...)
    and judges each one (rules below).  Foreign blocks that are not TideLink registers (TideChart TC_*, the
    IPC mailbox, ...) are skipped by name and COUNTED in the report, never silently.

RULES (exit 1 on any finding):
  R1 unmapped   an offset in 0x100..0x7FFF (or an SoC-absolute address inside a known APB aperture) that is not a
                register of the map.  Short offsets (<0x100) are node/block-relative and cannot be judged by value.
  R2 alias      the historical unmapped alias 0x003C (any int assignment or accessor literal): ErrInjection is
                0x023C.  A legitimately block-relative 0x3C must carry   # regmap-lint: relative <reason>
                on the same line; a bare 0x3C/0x003C never passes.
  R3 name-bound a constant whose name denotes a known register (ERRINJ -> link_error_injection, STATUS ->
                status, ...) but whose value is not that register's address (or in-block offset): a valid
                address of the WRONG register is as bad as an unmapped one.
  R4 allowlist  scripts/ci/host_addr_allowlist.txt entries need a reason and must still match something.

Per-line escape:   # regmap-lint: ignore <reason>     (reason mandatory; counted in the report)

USAGE
  check_host_addrs.py                      scan the repo (exit 0 clean, 1 findings, 2 cannot evaluate)
  check_host_addrs.py --list               print every extracted constant and its verdict
  check_host_addrs.py --root DIR FILE...   scan only these files, resolving the map from DIR (used by the selftest)
  check_host_addrs.py --map                dump the register map

A map that cannot be built (missing RDL, unparsable composition) is exit 2, "could not evaluate", never a pass.
"""
import argparse
import ast
import os
import re
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

SCAN_DIRS = ("pynq_host", "fpga/hw_regression", "scripts")
SKIP_DIRS = ("scripts/ci/tests", "pynq_host/hw_regress/__pycache__", "__pycache__", ".git")
ALIAS_UNMAPPED = {
    0x003C: "unmapped alias; LINK_ERROR_INJECTION is 0x023C (TL-038 evidence invalidated by this exact value)",
}
RELATIVE_MAX = 0x100                       # offsets below this are block/node-relative: judged by R2/R3 only
ABS_MAX = 0x7FFF                           # unified APB is 15-bit

# SoC-level APB apertures a literal may sit in (base, size).  Every entry has a citation; a literal in an
# aperture is judged by (literal - base) against the map; one outside every aperture is not an APB address.
APB_APERTURES = (
    (0x44030000, 0x8000),   # PYNQ-Z2 pair maps (pynq_host/tl_socmap.py APERTURES 'apb' z2_base)
    (0x84030000, 0x8000),   # KR260 die_a / PYNQ-Z2 GP1 (tl_socmap.py APERTURES 'apb' kr260_base)
    (0x8C030000, 0x8000),   # KR260 kr260-pair-onchip die_b (scripts/kr260_onchip_soak.py B_APB)
    (0x2E030000, 0x8000),   # ethernet-chiplet TLAPB window (scripts/fcemit_read.py TLAPB)
)

# Foreign register blocks reached through the same /dev/mem helpers: not TideLink APB registers.
FOREIGN_PREFIXES = ("TC_", "IPC_", "PHC_", "TIDECHART_", "TCH_")

# Names that are never register offsets.
NON_REG = re.compile(r"(?i)(^|_)(SHIFT|MASK|BITS?|WIDTH|COUNT|SPAN|RANGE|PAGE|SIZE|STRIDE|MAX|MIN|TTL|LEN|STEP|"
                     r"TIMEOUT|MARKER|DWELL|POINTS|READS|SCORES|LANES|DEFAULT|EXPECTED|FOLD|EXCL|PORT|CREDITS|"
                     r"NWORDS|SEED|TAG|MS|US|NS|HZ|MHZ|BAUD|RETRIES|ITER|ITERS|LIMIT|THRESH|DELAY)(_|$)")

# Register names hosts use for TideLink APB registers -> RDL/doc register name (R3).  Matching is on the
# constant's name after stripping OFF/OFFSET/REG/ADDR/R/A_ decorations and underscores, upper-cased.
NAME_BINDINGS = {
    "ERRINJ": "link_error_injection", "ERRINJECT": "link_error_injection", "ERRINJECTION": "link_error_injection",
    "ERRINJ0": "link_error_injection", "LINKERRORINJECTION": "link_error_injection",
    "ENABLERESET": "link_enable_reset", "LINKENABLERESET": "link_enable_reset",
    "LANEMASK": "link_lane_mask", "WLINKLANEMASK": "link_lane_mask", "LINKLANEMASK": "link_lane_mask",
    "ACTIVELANES": "link_active_lanes", "WLINKACTIVELANES": "link_active_lanes", "LINKACTIVELANES": "link_active_lanes",
    "SWILANESTATUS": "swi_lane_status", "SWILANE": "swi_lane_status", "LANESTATUS": "swi_lane_status",
    "ROLECFG": "role_cfg", "ROLESTATUS": "role_status", "ROLELOCK": "role_cfg",
    "RELTHRESHOLD": "release_threshold", "RELEASETHRESHOLD": "release_threshold",
    "CREDITCOUNT": "credit_count", "PAIRBASE": "pair_base_addr",
    "PAIRCREDITCOUNTER": "pair_credit_counter", "PAIRCREDITCONSUME": "pair_credit_consume",
    "PAIRENABLE": "pair_credit_counter_en", "PAIREN": "pair_credit_counter_en",
    "RELEASEDACC": "released_credits_acc", "RELEASEACC": "release_acc",
}

_HEX = re.compile(r"0[xX][0-9A-Fa-f_]+")


def _hx(s):
    return int(s.replace("_", ""), 16)


# --------------------------------------------------------------------------------------------------
# Register map
# --------------------------------------------------------------------------------------------------
class RegMap:
    """absolute unified-APB word offsets -> (name, source); plus per-block relative views and the PHC map."""

    def __init__(self):
        self.abs = {}          # offset -> (name, source)
        self.by_name = {}      # register name (lower) -> sorted list of absolute offsets
        self.rel = {}          # register name -> in-block offsets (for R3: ERRINJ may be 0x23C absolute or 0x3C in wlink-link block)
        self.phc = {}          # PHC map offset -> name
        self.problems = []

    def add(self, off, name, src):
        self.abs.setdefault(off, (name, src))
        self.by_name.setdefault(name.lower(), []).append(off)

    def contains(self, off):
        return off in self.abs


def _strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


_INST = re.compile(r"^\s*(\w+)\s+(\w+)\s*(?:\[(\d+)\])?\s*@\s*(0[xX][0-9A-Fa-f_]+)\s*(?:\+=\s*(0[xX][0-9A-Fa-f_]+))?\s*;", re.M)
_ADDRMAP = re.compile(r"^\s*addrmap\s+(\w+)\b[^{]*\{", re.M)
_EXTERNAL = re.compile(r"^\s*external\s+(\w+)\s+(\w+)\s*@\s*(0[xX][0-9A-Fa-f_]+)\s*;", re.M)


def parse_rdl(path):
    """-> {addrmap_name: [(inst, type, count, offset, stride)]}  (instances at the addrmap's top level)."""
    text = _strip_comments(open(path, errors="replace").read())
    maps, ams = {}, list(_ADDRMAP.finditer(text))
    for i, m in enumerate(ams):
        body_start = m.end()
        depth, j = 1, body_start
        while j < len(text) and depth:
            c = text[j]
            depth += (c == "{") - (c == "}")
            j += 1
        body = text[body_start:j]
        # keep only depth-0 instance lines of this addrmap body (register type definitions contain `field` lines
        # with no '@', so a flat regex over the body is sufficient and robust)
        ents = []
        for im in _INST.finditer(body):
            typ, inst, cnt, off, stride = im.groups()
            if typ in ("field", "reg", "addrmap", "regfile", "external", "enum"):
                continue
            ents.append((inst, typ, int(cnt) if cnt else 1, _hx(off), _hx(stride) if stride else 4))
        maps[m.group(1)] = ents
    return maps


def build_map(root):
    rm = RegMap()
    rdl = os.path.join(root, "src", "rdl")
    need = ["wlink_regs.rdl", "tidelink_regs.rdl", "tidelink_ptp_regs.rdl", "tidelink_perf_regs.rdl",
            "tidelink_addr_translator_regs.rdl", "tidelink_unified_regs.rdl", "phc_regs.rdl"]
    for n in need:
        if not os.path.isfile(os.path.join(rdl, n)):
            raise SystemExit("check_host_addrs: cannot evaluate: %s missing (the register map cannot be built)" % os.path.join(rdl, n))
    # composition, as the unified map declares it (checked, not assumed)
    ut = _strip_comments(open(os.path.join(rdl, "tidelink_unified_regs.rdl")).read())
    ext = {m.group(2): (m.group(1), _hx(m.group(3))) for m in _EXTERNAL.finditer(ut)}
    want = {"wlink": ("wlink_regs", 0x0000), "tidelink": ("tidelink_regs", 0x2000),
            "addr_translator": ("tidelink_addr_translator_regs", 0x4000)}
    for inst, (typ, base) in want.items():
        if ext.get(inst) != (typ, base):
            raise SystemExit("check_host_addrs: cannot evaluate: tidelink_unified_regs.rdl no longer maps %s=%s @ 0x%04x (found %r); "
                             "update the composition in check_host_addrs.py" % (inst, typ, base, ext.get(inst)))
    comp = [("wlink_regs.rdl", "wlink_regs", 0x0000), ("tidelink_regs.rdl", "tidelink_regs", 0x2000),
            ("tidelink_ptp_regs.rdl", "tidelink_ptp_regs", 0x2000), ("tidelink_perf_regs.rdl", "tidelink_perf_regs", 0x2000),
            ("tidelink_addr_translator_regs.rdl", "tidelink_addr_translator_regs", 0x4000)]
    for fn, top, base in comp:
        maps = parse_rdl(os.path.join(rdl, fn))
        if top not in maps or not maps[top]:
            raise SystemExit("check_host_addrs: cannot evaluate: no instances parsed from %s addrmap %s" % (fn, top))
        for inst, typ, cnt, off, stride in maps[top]:
            if typ in maps:                                   # nested addrmap (fc_node_regs)
                for sinst, _t, scnt, soff, sstr in maps[typ]:
                    for k in range(scnt):
                        rm.add(base + off + soff + k * sstr, "%s.%s" % (inst, sinst), fn)
                        rm.rel.setdefault(sinst.lower(), set()).add(soff + k * sstr)
            else:
                for k in range(cnt):
                    rm.add(base + off + k * stride, inst if cnt == 1 else "%s[%d]" % (inst, k), fn)
                rm.rel.setdefault(inst.lower(), set()).add(off)
    # registers that exist only in RTL: absolute 0x2xxx rows of the TideLink-region tables in REGISTER_MAP.md
    doc = os.path.join(root, "docs", "REGISTER_MAP.md")
    if not os.path.isfile(doc):
        raise SystemExit("check_host_addrs: cannot evaluate: docs/REGISTER_MAP.md missing")
    reg_table = False
    lines = open(doc, errors="replace").read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|\s*$", lines[i + 1]):
            cells = [c.strip().lower() for c in line.strip().strip("|").split("|")]
            reg_table = len(cells) >= 2 and cells[0] == "offset" and cells[1].startswith("name")   # "Offset | Name" tables only
            continue
        if not reg_table:
            continue
        m = re.match(r"^\|\s*(0x2[0-9A-Fa-f]{3}(?:\s*(?:-|/)\s*0x2[0-9A-Fa-f]{3})?)\s*\|\s*([^|]*)\|", line)
        if not m:
            continue
        addrs, name = m.group(1), re.sub(r"[`*]", "", m.group(2)).strip()
        hx = [_hx(x) for x in re.findall(r"0x[0-9A-Fa-f]+", addrs)]
        offs = range(hx[0], hx[1] + 1, 4) if ("-" in addrs and len(hx) == 2) else hx
        if name.startswith("(") or re.search(r"(?i)reserved|\bRAZ\b", name):
            continue                                   # reserved slots are not registers a host may use
        for o in offs:
            if (o & 3) == 0:
                rm.add(o, "doc:" + (name or "?"), "docs/REGISTER_MAP.md")
                rm.rel.setdefault(("doc:" + (name or "?")).lower(), set()).add(o - 0x2000)
    # PHC (separate APB port, own map)
    pm = parse_rdl(os.path.join(rdl, "phc_regs.rdl"))
    for top, ents in pm.items():
        for inst, typ, cnt, off, stride in ents:
            for k in range(cnt):
                rm.phc[off + k * stride] = inst
    return rm


# --------------------------------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------------------------------
ADDR_FUNCS = {"rd": 0, "wr": 0, "read": 0, "write": 0, "rd32": 0, "wr32": 0, "read32": 0, "write32": 0, "peek": 0,
              "poke": 0, "mmio_read": 0, "mmio_write": 0, "apb_rd": 0, "apb_wr": 0, "reg_rd": 0, "reg_wr": 0,
              "rdn": 1, "rd_apb": 0, "wr_apb": 0, "read_reg": 0, "write_reg": 0}
BASE_LIKE = re.compile(r"(?i)(^|_)(apb|tlapb|base|die|bank|window|aper)")


def fold(node, env):
    """Constant-fold ints, names bound to ints (env), + - * << | &.  Returns int or None."""
    if isinstance(node, ast.Constant) and isinstance(node.value, int) and not isinstance(node.value, bool):
        return node.value
    if isinstance(node, ast.Name):
        return env.get(node.id)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        v = fold(node.operand, env)
        return -v if v is not None else None
    if isinstance(node, ast.BinOp):
        a, b = fold(node.left, env), fold(node.right, env)
        if a is None or b is None:
            return None
        ops = {ast.Add: lambda x, y: x + y, ast.Sub: lambda x, y: x - y, ast.Mult: lambda x, y: x * y,
               ast.LShift: lambda x, y: x << y, ast.BitOr: lambda x, y: x | y, ast.BitAnd: lambda x, y: x & y}
        f = ops.get(type(node.op))
        return f(a, b) if f else None
    return None


def _name_of(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Subscript):
        return _name_of(node.value)
    if isinstance(node, ast.Call):
        return _name_of(node.func)
    return ""


class Item:
    def __init__(self, path, line, kind, name, value, base=None):
        self.path, self.line, self.kind, self.name, self.value, self.base = path, line, kind, name, value, base

    def key(self):
        return "%s:%d" % (self.path, self.line)


def _hexlit(node, src):
    """True if the expression contains a numeric literal written in hex (register offsets always are)."""
    for c in ast.walk(node):
        if isinstance(c, ast.Constant) and isinstance(c.value, int) and not isinstance(c.value, bool):
            seg = ast.get_source_segment(src, c) or ""
            if seg.lower().startswith("0x"):
                return True
    return False


def extract(path, src):
    """-> (items, pragmas{line: ('relative'|'ignore', reason)}, parse_error)"""
    pragmas = {}
    for i, l in enumerate(src.splitlines(), 1):
        m = re.search(r"#\s*regmap-lint:\s*(relative|ignore)\b\s*(.*)$", l)
        if m:
            pragmas[i] = (m.group(1), m.group(2).strip())
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        return [], pragmas, "syntax error: %s" % e
    env, items = {}, []
    # pass 1: module-wide int constants (so  ERRINJ = 0x23C ; wr(BASE + ERRINJ)  and folded constants resolve)
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign) and len(n.targets) == 1:
            t, v = n.targets[0], fold(n.value, env)
            if isinstance(t, ast.Name) and v is not None:
                env.setdefault(t.id, v)
            elif isinstance(t, ast.Tuple) and isinstance(n.value, ast.Tuple) and len(t.elts) == len(n.value.elts):
                for te, ve in zip(t.elts, n.value.elts):
                    fv = fold(ve, env)
                    if isinstance(te, ast.Name) and fv is not None:
                        env.setdefault(te.id, fv)
    # pass 2: items
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign):
            tgts = []
            if len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                tgts = [(n.targets[0].id, n.value)]
            elif len(n.targets) == 1 and isinstance(n.targets[0], ast.Tuple) and isinstance(n.value, ast.Tuple) \
                    and len(n.targets[0].elts) == len(n.value.elts):
                tgts = [(te.id, ve) for te, ve in zip(n.targets[0].elts, n.value.elts) if isinstance(te, ast.Name)]
            for name, val in tgts:
                v = fold(val, env)
                base = None
                if v is None and isinstance(val, ast.BinOp) and isinstance(val.op, ast.Add):
                    # NAME = <non-constant base> + 0xNNN
                    for a, b in ((val.left, val.right), (val.right, val.left)):
                        bv = fold(b, env)
                        if bv is not None and fold(a, env) is None:
                            v, base = bv, _name_of(a) or "?"
                if v is not None and v >= 0 and _hexlit(val, src):
                    items.append(Item(path, n.lineno, "assign", name, v, base))
        elif isinstance(n, ast.Call):
            fn = _name_of(n.func)
            if fn in ADDR_FUNCS and len(n.args) > ADDR_FUNCS[fn]:
                a = n.args[ADDR_FUNCS[fn]]
                v = fold(a, env)
                if v is not None and v >= 0 and not isinstance(a, ast.Name) and _hexlit(a, src):
                    items.append(Item(path, n.lineno, "call:" + fn, "", v))
                elif isinstance(a, ast.BinOp) and isinstance(a.op, ast.Add):
                    for x, y in ((a.left, a.right), (a.right, a.left)):
                        yv = fold(y, env)
                        if yv is not None and fold(x, env) is None and not isinstance(y, ast.Name) and _hexlit(y, src):
                            items.append(Item(path, n.lineno, "call:" + fn, "", yv, _name_of(x) or "?"))
        elif isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
            for x, y in ((n.left, n.right), (n.right, n.left)):
                yv = fold(y, env)
                if isinstance(y, ast.Constant) and yv is not None and RELATIVE_MAX <= yv <= ABS_MAX \
                        and fold(x, env) is None and BASE_LIKE.search(_name_of(x) or ""):
                    items.append(Item(path, n.lineno, "base+", "", yv, _name_of(x)))
    return items, pragmas, None


# --------------------------------------------------------------------------------------------------
# Judgement
# --------------------------------------------------------------------------------------------------
def _norm(name):
    n = name.upper()
    n = re.sub(r"^(R_|A_|REG_|OFF_|ADDR_)", "", n)
    n = re.sub(r"(_OFF|_OFFSET|_ADDR|_REG)$", "", n)
    return n.replace("_", "")


def uses_phc(src):
    return bool(re.search(r"(?i)\bphc\b|phc_apb|PHC_BASE", src))


def judge(it, rm, phc_file, pragmas):
    """-> (verdict, detail).  verdict: OK / SKIP-* / R1 / R2 / R3 / PRAGMA-*."""
    pr = pragmas.get(it.line)
    v, nm = it.value, it.name
    if pr and pr[0] == "ignore":
        return ("PRAGMA-IGNORE", pr[1]) if pr[1] else ("R4", "regmap-lint: ignore needs a reason")
    # R2 first: the historical alias, by value alone
    if v in ALIAS_UNMAPPED:
        if pr and pr[0] == "relative" and pr[1]:
            return "PRAGMA-RELATIVE", pr[1]
        return "R2", "0x%04x: %s" % (v, ALIAS_UNMAPPED[v])
    if any(nm.upper().startswith(p) for p in FOREIGN_PREFIXES):
        return "SKIP-FOREIGN", "foreign register block (%s)" % nm
    if v >= 0x1000_0000:
        for b, size in APB_APERTURES:
            if b <= v < b + size:
                off = v - b
                # judged as the in-aperture offset: INCLUDING the alias rule (TLAPB + 0x3C is the historical bug)
                r = judge(Item(it.path, it.line, it.kind, nm, off, it.base), rm, phc_file, pragmas)
                return (r[0], "%s [SoC 0x%08x = aperture 0x%08x + 0x%x]" % (r[1], v, b, off)) if r[0] != "SKIP-REL" \
                    else ("SKIP-REL", "0x%x in APB aperture 0x%08x: relative" % (off, b))
        return "SKIP-SOC", "0x%x: not in a known APB aperture" % v
    # name-bound (R3): the constant names a register; its value must be that register
    bind = NAME_BINDINGS.get(_norm(nm)) if nm else None
    if bind:
        offs = rm.rel.get(bind) or set()
        absn = {o for o in rm.by_name.get(bind, [])}
        if not (offs or absn):
            return "R3", "%s binds to register %s which is not in the map (stale binding in check_host_addrs.py)" % (nm, bind)
        if v not in offs and v not in absn:
            return "R3", "%s = 0x%x but register %s is at %s" % (nm, v, bind, ", ".join("0x%03x" % o for o in sorted(absn or offs)))
    if phc_file and v in rm.phc and v < RELATIVE_MAX * 8:
        return "OK-PHC", "PHC map: %s" % rm.phc[v]
    if v < RELATIVE_MAX:
        return "SKIP-REL", "0x%x block/node-relative (not judged by value)" % v
    if v > ABS_MAX:
        return "SKIP-RANGE", "0x%x above the 15-bit APB space" % v
    if nm and NON_REG.search(nm):
        return "SKIP-NONREG", "name %s is not a register offset" % nm
    if rm.contains(v):
        return "OK", rm.abs[v][0]
    return "R1", "0x%04x%s is not a register of the map%s (unmapped writes are dropped silently)" % (v, " (%s)" % nm if nm else "", " (not word-aligned)" if v & 3 else "")


def load_allowlist(path):
    ents = []
    if os.path.isfile(path):
        for i, l in enumerate(open(path), 1):
            if not l.strip() or l.lstrip().startswith("#"):
                continue
            f = l.rstrip("\n").split("\t")
            if len(f) < 3 or not f[2].strip():
                raise SystemExit("%s:%d: allowlist entries are  path<TAB>token<TAB>reason  and the reason is mandatory" % (path, i))
            ents.append(dict(path=f[0], token=f[1], reason=f[2], line=i, used=0))
    return ents


def scan_files(root):
    out = []
    for d in SCAN_DIRS:
        for dp, dn, fn in os.walk(os.path.join(root, d)):
            rel = os.path.relpath(dp, root)
            if any(rel == s or rel.startswith(s + os.sep) for s in SKIP_DIRS):
                dn[:] = []
                continue
            dn[:] = [x for x in dn if x != "__pycache__"]
            out += [os.path.join(dp, f) for f in fn if f.endswith(".py")]
    return sorted(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=REPO)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--map", action="store_true")
    ap.add_argument("files", nargs="*")
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root)
    rm = build_map(root)
    if a.map:
        for o in sorted(rm.abs):
            print("0x%04x  %-34s %s" % (o, rm.abs[o][0], rm.abs[o][1]))
        return 0
    files = [os.path.abspath(f) for f in a.files] if a.files else scan_files(root)
    allow = load_allowlist(os.path.join(root, "scripts", "ci", "host_addr_allowlist.txt"))
    findings, counts, n_items, rows, perr = [], {}, 0, [], []
    for f in files:
        rel = os.path.relpath(f, root)
        src = open(f, errors="replace").read()
        items, pragmas, err = extract(rel, src)
        if err:
            perr.append("%s: %s" % (rel, err)); continue
        phc_file = uses_phc(src)
        for it in items:
            n_items += 1
            verdict, detail = judge(it, rm, phc_file, pragmas)
            if verdict in ("R1", "R2", "R3"):
                hit = [e for e in allow if e["path"] == rel and re.search(e["token"], "%s=0x%x" % (it.name, it.value))]
                if hit:
                    for e in hit: e["used"] += 1
                    verdict, detail = "ALLOWLIST", hit[0]["reason"]
            counts[verdict] = counts.get(verdict, 0) + 1
            rows.append((it, verdict, detail))
            if verdict in ("R1", "R2", "R3", "R4"):
                findings.append("%s:%d: %s %s" % (rel, it.line, verdict, detail))
    for e in allow:
        if not e["used"]:
            findings.append("scripts/ci/host_addr_allowlist.txt:%d: R4 stale allowlist entry (matches nothing): %s %s" % (e["line"], e["path"], e["token"]))
    if a.list:
        for it, v, d in rows:
            print("%-14s %s %-22s 0x%x  %s" % (v, it.key(), (it.name or it.kind), it.value, d))
    for p in perr:
        findings.append("%s: could not parse (a script that cannot be parsed cannot be vetted)" % p)
    print("check_host_addrs: %d files, %d address constants extracted; map has %d registers (+%d PHC)"
          % (len(files), n_items, len(rm.abs), len(rm.phc)))
    print("check_host_addrs: " + ", ".join("%s=%d" % kv for kv in sorted(counts.items())))
    if findings:
        for f in findings:
            print("FINDING " + f)
        print("HOST_ADDR_LINT_RESULT=FAIL (%d finding(s))" % len(findings))
        return 1
    if n_items == 0:
        print("HOST_ADDR_LINT_RESULT=ERROR (extracted nothing: the lint cannot evaluate; refusing to pass)")
        return 2
    print("HOST_ADDR_LINT_RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
