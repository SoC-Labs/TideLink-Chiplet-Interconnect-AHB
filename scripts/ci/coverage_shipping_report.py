#!/usr/bin/env python3
"""Turn a merged VCS coverage database into a RANKED LIST OF UNEXERCISED SHIPPING RTL.

The deliverable is deliberately NOT a percentage.  A percentage nobody acts on is
decoration; the actionable artifact is "these specific file:line sites in shipping
RTL are executed by no test in the gate, nearest-the-data-path first".

Input is urg's TEXT report (``urg -format text -report <dir>`` -> modinfo.txt),
which carries, per module definition: the source file(s), the per-metric totals,
the uncovered LINE sites with source text, the uncovered CONDITION rows with the
expression and its line, the per-line BRANCH totals, the un-toggled ports and
signals, and the unhit FSM states/transitions with their line numbers.

SCOPE.  Shipping RTL only:
  * everything under src/rtl/**  (this includes src/rtl/local_overrides/**), and
  * the deps/** files NAMED BY flists/tidelink_top_full_asic_v2.flist.
Testbenches, cocotb/uvm helpers and anything the shipping flist does not reach
are excluded -- coverage of a testbench is noise.  Files under src/rtl that the
V2 ASIC flist does NOT name (V1 overrides, the FPGA SRAM, the DFT wrapper, the
v2shims) are kept but tagged ``src_rtl_non_v2`` and ranked below shipping ones.

RANKING.  Every uncovered item scores (data-path proximity) x (metric weight):
proximity is a per-module tier -- an unexercised arm of the AHB/AXI bridge or the
Wlink packetiser outranks an unhit debug counter -- and the metric weight puts an
uncovered branch/line/FSM-state above a single un-toggled signal, because a
branch that never ran is untested behaviour whereas a signal that never toggled
is often just a tied-off width.
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict

# ─────────────────────────────────────────────────────────────────────────────
# Data-path proximity tiers.  First match wins; ordered most-specific first.
# The point of the tiers is that the report is READ TOP-DOWN and acted on, so an
# unexercised arm of the bridge must not be buried under 400 un-toggled bits of
# an observability counter.
# ─────────────────────────────────────────────────────────────────────────────
TIERS = [
    # 5 — the AHB/AXI/Wlink data path itself.  An unexercised arm here is an
    #     untested way for real traffic to be mishandled.
    (5, "datapath-bridge", [
        r"xhb500_ahb_to_axi_bridge", r"xhb500_axi_to_ahb_bridge",
        r"cmsdk_ahb_to_sram", r"cmsdk_ahb_to_apb",
        r"tidelink_ahb", r"tidelink_fifo_ahb",
    ]),
    (5, "datapath-link", [
        r"AXI4ToWlink", r"GeneralBusToWlink", r"ShortPacketToWlink", r"TideLinkToWlink",
        r"WlinkGenericFC", r"WlinkTxPstate", r"WlinkRxPstate",
        r"tidelink_fc_adapter", r"tidelink_tx_gen",
        r"tidelink_fifo_ctrl", r"tidelink_fifo_mem", r"tidelink_fifo\b", r"tidelink_returner",
        r"tidelink_sram",
        r"tidelink_addr_translator", r"tl_addr_trans_cam", r"tl_addr_trans_regs",
        # The Wlink link layers, routers, packet FIFOs and the CRC/ECC that gate
        # a packet's acceptance ARE the data path -- an uncovered arm in any of
        # them is an untested way for a real packet to be mishandled.
        r"WlinkRxLinkLayer", r"WlinkTxLinkLayer", r"WlinkRxRouter", r"WlinkTxRouter",
        r"WlinkCrcGen", r"WlinkEccSyndrome",
        r"^WavFIFO", r"^FIFO2$", r"^FIFOL1$",
        # The per-channel FC node FIFOs (aw/w/b/ar/r, a2l and l2a) and their
        # pointer logic ARE the AXI data path across the die boundary.
        r"^wlink_wlink_", r"WavFIFOMem", r"WavFIFOPtrLogic", r"WavReplayFIFOPtrLogic",
    ]),
    # 4 — link bring-up / recovery / PHY word path.  Not carrying payload bytes,
    #     but a wedge here stops the data path dead (this is where the silicon
    #     wedges have historically lived).
    (4, "link-control", [
        r"tidelink_autoneg", r"tidelink_lane_deskew", r"tidelink_phy_align_calibrator",
        r"tidelink_phy_", r"WavD2DGpio", r"Wlink\w*Phy", r"WlinkGpio", r"WlinkGeneric(?!FC)",
        r"tidelink_top\b", r"axi_chiplet_controller", r"Wlink\b", r"i2c_master", r"i2c_slave",
        r"tidelink_lane_checker", r"tidelink_idelay_rx", r"tidelink_link_clk_div",
        # I2C sideband: AXI4 -> mkaxi2axil_bridge -> i2c_master_axil -> SCL/SDA,
        # and SCL/SDA -> i2c_slave_axil_master -> mkaxil2apb_bridge -> internal APB.
        # Bring-up critical (dead I2C parks NEGO) but NOT the payload data path.
        r"mkaxi2axil_bridge", r"mkaxil2apb_bridge", r"^axis_fifo$",
        r"tidelink_rxclk_buf",
    ]),
    # 3 — configuration / register planes.  Wrong config is a real failure mode,
    #     but the register file itself is not carrying traffic.
    (3, "config-regs", [
        r"tidelink_apb_regs", r"tidelink_apb_addr_ctrl", r"tidelink_eye_regs",
        r"tidelink_link_rate", r"apb", r"APBFanout", r"cmsdk_apb",
    ]),
    # 2 — PTP / timing side path.
    (2, "ptp-timing", [
        r"tidelink_ptp", r"tidelink_phc", r"tidelink_mul_iter", r"tidelink_clkfreq_check",
    ]),
    # 1 — observability / debug.  An unhit debug counter is the LEAST urgent
    #     thing in this report; that is the whole reason for ranking.
    (1, "observability", [
        r"_obs\b", r"fcemit_obs", r"winscan_obs", r"_dbg", r"debug",
        r"tidelink_perf",
    ]),
]
# 2 — structural cells and register slices.  On the data path physically, but
#     they are 10-line primitives whose uncovered items are almost always an
#     unused generic port, not untested behaviour.
CELL_TIER = (2, "cell-primitive")
CELL_PAT = re.compile(
    r"(xhb500_(flop|or|sync|xor|bypass_regd_slice|forward_regd_slice|reverse_regd_slice))"
    r"|(Wav(And|ClockGate|ClockInv|ClockMux|DemetReset|LatchModel|latch_model"
    r"|MultibitSync|ResetSync))"
    r"|(_regd_slice)", re.I)

DEFAULT_TIER = (3, "other-shipping")

METRIC_WEIGHT = {
    "line":       10,   # a statement that never ran
    "branch":     10,   # an arm that never ran
    "fsm_state":   9,   # a state the design never entered
    "cond":        8,   # a term that never controlled the result
    "fsm_trans":   7,   # a transition never taken
    "toggle":      3,   # a signal/port that never changed value
}


def tier_for(module: str, path: str):
    if CELL_PAT.search(module):
        return CELL_TIER
    for score, name, pats in TIERS:
        for p in pats:
            if re.search(p, module, re.I):
                return (score, name)
    return DEFAULT_TIER


# ─────────────────────────────────────────────────────────────────────────────
# Scope
# ─────────────────────────────────────────────────────────────────────────────
def expand_flist(flist, root):
    """Resolve the ${VAR} references a VCS flist uses into real paths."""
    env = dict(os.environ)
    env.setdefault("TIDELINK_HOME", root)
    out = []
    with open(flist) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            if line.startswith("+") or line.startswith("-"):
                continue

            def sub(m):
                return env.get(m.group(1), m.group(0))
            line = re.sub(r"\$\{(\w+)\}", sub, line)
            if "${" in line:
                continue
            out.append(os.path.realpath(line))
    return out


def build_scope(root, flist):
    """-> {realpath: area-tag}.  area in {shipping_v2, src_rtl_non_v2, vendor_flist}."""
    scope = {}
    for f in expand_flist(flist, root):
        rel = os.path.relpath(f, root)
        if rel.startswith(".."):
            scope[f] = "vendor_flist"      # e.g. the CMSDK files under /research
        else:
            scope[f] = "shipping_v2"
    for dirpath, _dirs, files in os.walk(os.path.join(root, "src", "rtl")):
        for fn in files:
            if fn.endswith((".sv", ".v")):
                p = os.path.realpath(os.path.join(dirpath, fn))
                scope.setdefault(p, "src_rtl_non_v2")
    return scope


# ─────────────────────────────────────────────────────────────────────────────
# modinfo.txt parsing
# ─────────────────────────────────────────────────────────────────────────────
SPLIT_RE = re.compile(r"(?m)^=+\n(Module(?: Instance)? : .*)\n=+\n")
SECT_RE = re.compile(
    r"(?m)^(Line|Cond|Toggle|Branch|FSM) Coverage for Module : (.*)$")


def split_modules(path):
    with open(path, errors="replace") as fh:
        txt = fh.read()
    parts = SPLIT_RE.split(txt)
    hdrs, bodies = parts[1::2], parts[2::2]
    for h, b in zip(hdrs, bodies):
        h = h.strip()
        if not h.startswith("Module : "):
            continue                      # skip the per-instance duplicates
        yield h[len("Module : "):].strip(), b


def sections(body):
    marks = list(SECT_RE.finditer(body))
    out = {}
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
        out.setdefault(m.group(1).lower(), body[m.end():end])
    return out


def source_files(body):
    m = re.search(r"(?m)^Source File\(s\) : *\n(.*?)\n\n", body, re.S)
    if not m:
        return []
    return [os.path.realpath(x.strip()) for x in m.group(1).split("\n") if x.strip()]


def module_scores(body):
    m = re.search(r"(?m)^SCORE +LINE +COND +TOGGLE +FSM +BRANCH *\n(.*)$", body)
    if not m:
        return {}
    vals = m.group(1).split()
    keys = ["score", "line", "cond", "toggle", "fsm", "branch"]
    return {k: (None if v == "--" else float(v)) for k, v in zip(keys, vals)}


# --- LINE -------------------------------------------------------------------
LINE_TOTAL_RE = re.compile(r"(?m)^TOTAL\s+(\d+)\s+(\d+)\s+[\d.]+\s*$")
# "147        0/1     ==>          singles_burst <= ..."
LINE_HIT_RE = re.compile(r"(?m)^(\d+)\s+(\d+)/(\d+)\s+(==>)?\s?(.*)$")


def parse_line(sec):
    tot = cov = 0
    m = LINE_TOTAL_RE.search(sec)
    if m:
        tot, cov = int(m.group(1)), int(m.group(2))
    misses = []
    for m in LINE_HIT_RE.finditer(sec):
        if int(m.group(2)) == 0:
            misses.append((int(m.group(1)), m.group(5).strip()))
    return tot, cov, misses


# --- COND -------------------------------------------------------------------
COND_TOTAL_RE = re.compile(r"(?m)^Conditions\s+(\d+)\s+(\d+)\s")


def parse_cond(sec):
    tot = cov = 0
    m = COND_TOTAL_RE.search(sec)
    if m:
        tot, cov = int(m.group(1)), int(m.group(2))
    misses = []
    for blk in re.finditer(
            r"(?m)^ LINE\s+(\d+)\s*\n EXPRESSION (.*?)\n(.*?)(?=\n LINE\s+\d|\Z)",
            sec, re.S):
        ln, expr, tail = int(blk.group(1)), blk.group(2).strip(), blk.group(3)
        n = len(re.findall(r"(?m)\bNot Covered\s*$", tail))
        if n:
            misses.append((ln, expr, n))
    return tot, cov, misses


# --- BRANCH -----------------------------------------------------------------
BR_TOTAL_RE = re.compile(r"(?m)^Branches\s+(\d+)\s+(\d+)\s")
BR_ROW_RE = re.compile(r"(?m)^(IF|CASE|TERNARY|CASEZ|CASEX)\s+(\d+)\s+(\d+)\s+(\d+)\s+[\d.]+")


def parse_branch(sec):
    tot = cov = 0
    m = BR_TOTAL_RE.search(sec)
    if m:
        tot, cov = int(m.group(1)), int(m.group(2))
    misses = []
    for m in BR_ROW_RE.finditer(sec):
        kind, ln, t, c = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        if c < t:
            misses.append((ln, kind, t - c, t))
    return tot, cov, misses


# --- TOGGLE -----------------------------------------------------------------
TG_TOTAL_RE = re.compile(r"(?m)^Total Bits\s+(\d+)\s+(\d+)\s")
TG_ROW_RE = re.compile(
    r"(?m)^(\S+)\s+(Yes|No)\s+(Yes|No)\s+(Yes|No)(?:\s+(INPUT|OUTPUT|INOUT))?\s*$")


def parse_toggle(sec):
    tot = cov = 0
    m = TG_TOTAL_RE.search(sec)
    if m:
        tot, cov = int(m.group(1)), int(m.group(2))
    misses = []
    for m in TG_ROW_RE.finditer(sec):
        name, t, hl, lh, direction = m.groups()
        if "No" in (t, hl, lh):
            kind = "never" if t == "No" else ("no 1->0" if hl == "No" else "no 0->1")
            misses.append((name, kind, direction or "signal"))
    return tot, cov, misses


# --- FSM --------------------------------------------------------------------
def parse_fsm(sec):
    st_tot = st_cov = tr_tot = tr_cov = 0
    for m in re.finditer(r"(?m)^States\s+(\d+)\s+(\d+)\s", sec):
        st_tot += int(m.group(1)); st_cov += int(m.group(2))
    for m in re.finditer(r"(?m)^Transitions\s+(\d+)\s+(\d+)\s", sec):
        tr_tot += int(m.group(1)); tr_cov += int(m.group(2))
    misses = []
    for blk in re.finditer(
            r"(?m)^State, Transition and Sequence Details for FSM :: (\S+)\n-+\n(.*?)"
            r"(?=\n(?:Summary for FSM|State, Transition)|\Z)", sec, re.S):
        fsm, body = blk.group(1), blk.group(2)
        cur = None
        for raw in body.split("\n"):
            if raw.startswith("states"):
                cur = "fsm_state"; continue
            if raw.startswith("transitions"):
                cur = "fsm_trans"; continue
            m = re.match(r"^(\S+)\s+(\d+)\s+(Covered|Not Covered)\s*$", raw)
            if m and cur and m.group(3) == "Not Covered":
                misses.append((cur, fsm, m.group(1), int(m.group(2))))
    return st_tot, st_cov, tr_tot, tr_cov, misses


# ─────────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modinfo", required=True)
    ap.add_argument("--flist", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--top", type=int, default=30)
    args = ap.parse_args()

    root = os.path.realpath(args.root)
    scope = build_scope(root, args.flist)
    os.makedirs(args.out, exist_ok=True)

    items = []              # every uncovered item, flat
    per_file = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    modules_seen, modules_in_scope = 0, 0
    unmatched = []
    all_modules = set()
    module_src = {}

    for mod, body in split_modules(args.modinfo):
        modules_seen += 1
        all_modules.add(mod)
        srcs = source_files(body)
        hit = [s for s in srcs if s in scope]
        if not hit:
            if srcs:
                unmatched.append((mod, srcs[0]))
            continue
        modules_in_scope += 1
        src = hit[0]
        rel = os.path.relpath(src, root) if not os.path.relpath(src, root).startswith("..") else src
        module_src[mod] = rel
        area = scope[src]
        tier, tier_name = tier_for(mod, src)
        sec = sections(body)

        def add(metric, line, detail, extra=None):
            items.append({
                "metric": metric, "module": mod, "file": rel, "line": line,
                "detail": detail, "extra": extra or {},
                "tier": tier, "tier_name": tier_name, "area": area,
                "rank": tier * METRIC_WEIGHT[metric],
                # Within one tier, order by HOW MUCH is missing. Without this the
                # per-metric lists come out alphabetical by filename, which buries
                # an 18-of-37-arms hole under a string of 1-of-2 ternaries.
                "sev": (extra or {}).get("missing", 1) + (extra or {}).get("uncovered_rows", 0),
            })

        if "line" in sec:
            t, c, miss = parse_line(sec["line"])
            per_file[rel]["line"][0] += t; per_file[rel]["line"][1] += c
            for ln, txt in miss:
                add("line", ln, txt[:160])
        if "cond" in sec:
            t, c, miss = parse_cond(sec["cond"])
            per_file[rel]["cond"][0] += t; per_file[rel]["cond"][1] += c
            for ln, expr, n in miss:
                add("cond", ln, expr[:160], {"uncovered_rows": n})
        if "branch" in sec:
            t, c, miss = parse_branch(sec["branch"])
            per_file[rel]["branch"][0] += t; per_file[rel]["branch"][1] += c
            for ln, kind, nmiss, ntot in miss:
                add("branch", ln, f"{kind}: {nmiss}/{ntot} arms never taken",
                    {"missing": nmiss, "total": ntot})
        if "toggle" in sec:
            t, c, miss = parse_toggle(sec["toggle"])
            per_file[rel]["toggle"][0] += t; per_file[rel]["toggle"][1] += c
            for name, kind, direction in miss:
                add("toggle", None, f"{name} ({direction}): {kind}", {"signal": name})
        if "fsm" in sec:
            st, sc, tt, tc, miss = parse_fsm(sec["fsm"])
            per_file[rel]["fsm_state"][0] += st; per_file[rel]["fsm_state"][1] += sc
            per_file[rel]["fsm_trans"][0] += tt; per_file[rel]["fsm_trans"][1] += tc
            for kind, fsm, name, ln in miss:
                add(kind, ln, f"FSM {fsm}: {name} never {'entered' if kind=='fsm_state' else 'taken'}",
                    {"fsm": fsm, "name": name})

    # ── the instrument check ────────────────────────────────────────────────
    check = instrument_check(items, per_file)

    # ── outputs ─────────────────────────────────────────────────────────────
    with open(os.path.join(args.out, "uncovered_shipping.jsonl"), "w") as fh:
        for it in sorted(items, key=lambda x: (-x["rank"], -x.get("sev", 1), x["file"], x["line"] or 0)):
            fh.write(json.dumps(it) + "\n")

    totals = defaultdict(lambda: [0, 0])
    for rel, mets in per_file.items():
        if scope.get(os.path.realpath(os.path.join(root, rel)), "") == "src_rtl_non_v2":
            continue
        for k, (t, c) in mets.items():
            totals[k][0] += t; totals[k][1] += c

    lines = []
    lines.append("UNEXERCISED SHIPPING RTL — merged coverage over the whole sim_gate")
    lines.append("=" * 78)
    lines.append(f"modinfo            : {args.modinfo}")
    lines.append(f"modules in report  : {modules_seen}")
    lines.append(f"modules in scope   : {modules_in_scope}")
    lines.append(f"files in scope     : {len(per_file)}")
    lines.append(f"modules out of scope (TB/helpers, excluded as noise) : {len(unmatched)}")
    lines.append("")

    # ── files the gate NEVER ELABORATED ────────────────────────────────────
    # A shipping file with no module block in the merged database was not
    # compiled into ANY suite that ran.  That is 0% coverage of the strongest
    # possible kind and it does not appear in any percentage, so it has to be
    # called out separately or it is invisible.
    covered_rel = set(per_file)
    mods_reported = set(all_modules)
    shadowed = []   # ASIC-flist file whose modules were simulated FROM ANOTHER FILE
    never = []
    for p_abs, area in sorted(scope.items()):
        if area == "src_rtl_non_v2":
            continue
        rel = os.path.relpath(p_abs, root)
        if rel.startswith(".."):
            rel = p_abs
        if rel in covered_rel:
            continue
        kind = classify_uninstrumented(p_abs)
        # A file can also be absent because ANOTHER file in scope defines a
        # module of the same name and won the elaboration (the xhb500 mst/slv
        # cell copies, deps/ vs src/rtl/local_overrides/).  That is a build
        # artifact, not an untested-RTL finding, and must not be reported as one.
        if kind == "NEVER-ELABORATED":
            mods = set(re.findall(r"(?m)^\s*module\s+(\w+)", open(p_abs, errors="replace").read()))
            clash = mods & mods_reported
            if clash:
                kind = "dup-defn"
                for m in sorted(clash):
                    other = module_src.get(m, "?")
                    if other != rel:
                        shadowed.append((rel, m, other))
        never.append((rel, kind))
    lines.append("SHIPPING FILES WITH NO COVERAGE DATA AT ALL (no suite elaborated them,")
    lines.append("or they contain no coverable RTL — packages/headers/interfaces)")
    lines.append("-" * 78)
    if not never:
        lines.append("  (none)")
    for rel, kind in never:
        lines.append(f"  [{kind:<14}] {rel}")
    lines.append("")
    # How much of the shipping tree is invisible to this measurement?
    def sloc(path):
        try:
            return sum(1 for l in open(path, errors="replace")
                       if l.strip() and not l.strip().startswith("//"))
        except OSError:
            return 0
    ship_total = sum(sloc(p_abs) for p_abs, a in scope.items() if a != "src_rtl_non_v2")
    never_sloc = sum(sloc(os.path.join(root, r) if not os.path.isabs(r) else r)
                     for r, k in never if k in ("NEVER-ELABORATED", "dup-defn"))
    lines.append(f"  UNMEASURED FRACTION: {never_sloc} of {ship_total} shipping SLOC "
                 f"({100.0*never_sloc/ship_total if ship_total else 0:.1f}%) sits in files with NO "
                 f"coverage data at all")
    lines.append("")
    lines.append("SHADOWED ASIC SOURCES — the file the ASIC flist ships was NOT the file")
    lines.append("simulated; a same-named module from a different file won elaboration.")
    lines.append("Coverage of the substitute says NOTHING about the ASIC source.")
    lines.append("-" * 78)
    if not shadowed:
        lines.append("  (none)")
    for rel, m, other in sorted(set(shadowed)):
        lines.append(f"  {m:<38} ASIC ships {rel}")
        lines.append(f"  {'':<38} sim ran    {other}")
    lines.append("")
    lines.append("OVERALL, SCOPED TO SHIPPING RTL (src/rtl/** + flist-named deps; TB excluded)")
    lines.append(f"  {'metric':<12} {'covered':>10} {'total':>10} {'pct':>8}")
    for k in ["line", "cond", "branch", "toggle", "fsm_state", "fsm_trans"]:
        t, c = totals[k]
        pct = (100.0 * c / t) if t else float("nan")
        lines.append(f"  {k:<12} {c:>10} {t:>10} {pct:>7.2f}%")
    lines.append("")
    lines.append("INSTRUMENT CHECK (step 6 — must be UNCOVERED or the report is not trustworthy)")
    for l in check["report"]:
        lines.append("  " + l)
    lines.append(f"  VERDICT: {check['verdict']}")
    lines.append("")

    lines.append(f"TOP {args.top} RANKED UNEXERCISED ITEMS")
    lines.append("-" * 78)
    for i, it in enumerate(rank_collapsed(items)[:args.top], 1):
        loc = f"{it['file']}:{it['line']}" if it["line"] else it["file"]
        lines.append(f"{i:>3}. [{it['tier_name']:<17}] {it['metric']:<10} {loc}")
        lines.append(f"     module {it['module']}")
        lines.append(f"     {it['detail']}")
    lines.append("")

    for metric, title, n in [
            ("branch",     "UNCOVERED BRANCH ARMS (never-taken arms, nearest-data-path first)", 25),
            ("fsm_state",  "FSM STATES THE DESIGN NEVER ENTERED", 25),
            ("fsm_trans",  "FSM TRANSITIONS NEVER TAKEN", 20),
            ("cond",       "DEAD CONDITIONS (a term that never controlled the result)", 25),
            ("toggle",     "NEVER-TOGGLED SIGNALS/PORTS (data-path tiers only)", 25)]:
        sel = [i for i in items if i["metric"] == metric]
        if metric == "toggle":
            sel = [i for i in sel if i["tier"] >= 4]
        sel.sort(key=lambda x: (-x["rank"], -x.get("sev", 1), x["file"], x["line"] or 0))
        lines.append(title)
        lines.append("-" * 78)
        if not sel:
            lines.append("  (none)")
        for it in sel[:n]:
            loc = f"{os.path.basename(it['file'])}:{it['line']}" if it["line"] else os.path.basename(it["file"])
            lines.append(f"  [{it['tier_name']:<17}] {loc:<44} {it['module']}")
            lines.append(f"      {it['detail'][:150]}")
        lines.append(f"  ... {len(sel)} total in scope")
        lines.append("")

    lines.append("PER-FILE SUMMARY (shipping scope, worst line coverage first)")
    lines.append("-" * 78)
    rows = []
    for rel, mets in per_file.items():
        lt, lc = mets["line"]
        rows.append((100.0 * lc / lt if lt else 999.0, rel, mets))
    for pct, rel, mets in sorted(rows):
        if pct > 998:
            continue
        bt, bc = mets["branch"]; tt, tc = mets["toggle"]
        area = scope.get(os.path.realpath(os.path.join(root, rel)), "?")
        tag = {"shipping_v2": "SHIP", "vendor_flist": "VEND", "src_rtl_non_v2": "nonV2"}.get(area, "?")
        lines.append(f"  [{tag:<5}] line {pct:6.2f}%  branch {(100.0*bc/bt if bt else float('nan')):6.2f}%  "
                     f"tgl {(100.0*tc/tt if tt else float('nan')):6.2f}%  {rel}")

    txt = "\n".join(lines)
    with open(os.path.join(args.out, "unexercised_shipping_rtl.txt"), "w") as fh:
        fh.write(txt + "\n")
    print(txt)

    if args.check_only:
        sys.exit(0 if check["ok"] else 3)
    if not check["ok"]:
        print("\n*** INSTRUMENT CHECK FAILED — do not publish this report ***", file=sys.stderr)
        sys.exit(3)


def classify_uninstrumented(path):
    """Distinguish 'no suite compiled it' from 'nothing here is coverable'."""
    try:
        txt = open(path, errors="replace").read()
    except OSError:
        return "unreadable"
    if path.endswith((".svh", ".vh", ".h")):
        return "header"
    has_mod = re.search(r"(?m)^\s*module\s+\w", txt)
    only_pkg = re.search(r"(?m)^\s*package\s+\w", txt) and not has_mod
    if only_pkg:
        return "package"
    if re.search(r"(?m)^\s*interface\s+\w", txt) and not has_mod:
        return "interface"
    if not has_mod:
        return "no-module"
    return "NEVER-ELABORATED"


def rank_collapsed(items):
    """Collapse contiguous uncovered LINE runs inside one module so the top of the
    list is 30 DISTINCT findings, not 30 consecutive lines of one always block."""
    out, byline = [], defaultdict(list)
    for it in items:
        if it["metric"] == "line":
            byline[(it["file"], it["module"])].append(it)
        else:
            out.append(it)
    for (f, m), group in byline.items():
        group.sort(key=lambda x: x["line"])
        run = [group[0]]
        for it in group[1:]:
            if it["line"] - run[-1]["line"] <= 3:
                run.append(it)
            else:
                out.append(_collapse(run)); run = [it]
        out.append(_collapse(run))
    out.sort(key=lambda x: (-x["rank"], -(x["extra"].get("run_len", 1)),
                            -x.get("sev", 1), x["file"], x["line"] or 0))
    return out


def _collapse(run):
    head = dict(run[0])
    if len(run) > 1:
        head["detail"] = (f"lines {run[0]['line']}-{run[-1]['line']} "
                          f"({len(run)} statements) never executed | {run[0]['detail']}")
        head["extra"] = dict(head["extra"], run_len=len(run))
        head["rank"] = head["rank"] + min(len(run), 10)
    return head


def instrument_check(items, per_file):
    """The known-unexercised XHB500 non-singles / burst arm MUST report uncovered.

    `singles_burst` is loaded from `~hprot[3] || hexcl || hburst == BUR_INCR`
    (core_addr.sv:147) and consumed at :166; the burst-type/length mux at :210+
    is gated on `cntrl_2_out.hprot[3] & !cntrl_2_out.hexcl`.  No test in the gate
    drives HPROT[3], so that whole arm is dead by construction.  If this report
    calls it covered, the report is measuring something other than this design.
    """
    F = "core_addr.sv"
    rep, found = [], {}
    for it in items:
        if F not in it["file"] or "chiplet_slv" not in it["file"]:
            continue
        key = None
        if it["metric"] in ("line", "branch") and it["line"] and 205 <= it["line"] <= 240:
            key = "burst_arm"
        elif it["metric"] == "toggle" and it["extra"].get("signal", "").split("[")[0] in ("burst_int", "len_int"):
            # burst_int / len_int are the OUTPUTS of the dead arm.  They are the
            # sharp toggle marker; `singles_burst` itself is NOT, because it is a
            # 1-bit reg that necessarily toggles 1->0 on every reset regardless of
            # whether the arm it selects ever runs (measured: it toggles both ways,
            # while the arm stays 1/5 branch-covered).
            key = "burst_outputs_toggle"
        elif it["metric"] in ("line", "cond", "branch") and it["line"] in (146, 147, 166):
            key = "singles_burst_load"
        if key:
            found.setdefault(key, []).append(it)

    seen_file = any("core_addr.sv" in f and "chiplet_slv" in f for f in per_file)
    rep.append(f"xhb500_..._chiplet_slv_core_addr.sv present in merged db : {seen_file}")
    for k in ("burst_arm", "singles_burst_load", "burst_outputs_toggle"):
        hits = found.get(k, [])
        if hits:
            ex = hits[0]
            rep.append(f"{k:<22} UNCOVERED ({len(hits)} item(s)) e.g. "
                       f"{ex['file'].split('/')[-1]}:{ex['line']} [{ex['metric']}] {ex['detail'][:70]}")
        else:
            rep.append(f"{k:<22} NOT REPORTED AS UNCOVERED  <-- investigate")

    ok = seen_file and bool(found.get("burst_arm")) and bool(found.get("burst_outputs_toggle"))
    if not seen_file:
        verdict = ("FAIL — the XHB500 slave bridge is not in the merged database at all; "
                   "the run did not cover the design it claims to")
    elif ok:
        verdict = ("PASS — the known-unexercised non-singles/burst arm reports UNCOVERED, "
                   "so the instrument is not manufacturing coverage")
    else:
        verdict = ("FAIL — the known-unexercised burst arm reports COVERED; "
                   "DO NOT PUBLISH THIS REPORT")
    return {"ok": ok, "verdict": verdict, "report": rep}


if __name__ == "__main__":
    main()
