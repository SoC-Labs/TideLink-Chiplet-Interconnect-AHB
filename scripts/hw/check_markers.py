#!/usr/bin/env python3
"""check_markers.py - prove the five compute-chiplet fixes are in the sources an FPGA build uses.

  check_markers.py --tree DIR [--mode source|built] [--groups a7,h30,h31,tl036,errinj,asic,tl059] [--flist NAME]

source mode: resolves flists/<NAME> (default tidelink_fpga_v2.flist, the file the manifest must name)
             exactly as fpga/filelist.tcl does (${VAR} expansion, comments, V2 shims followed through
             their `include), then checks each marker against the preprocessed text of the file the
             flist would compile.  A marker whose file is not in the flist is reported NOT_IN_BUILD.
built mode:  checks the packaged-IP copies Vivado actually synthesised
             (DIR/imp/fpga/tidelink_ip/src/<basename>) and also that each copy still matches the
             source (STALE otherwise).

Every marker is a regex on COMMENT-STRIPPED, `ifdef-EVALUATED text (TIDELINK_PHY_V2 defined,
TL033_LEGACY_WDOG undefined), so a fix that only exists inside a dead ifdef arm, or only in a
comment, does not count.  Absence markers ("the old gate is gone") are checked the same way.
Exit 0 only if every selected marker is PASS.  Exit 1 otherwise.  Exit 2 on usage errors.
"""
import argparse, os, re, sys

DEFAULT_FLIST = "tidelink_fpga_v2.flist"
BUILD_DEFINES = {"TIDELINK_PHY_V2"}          # TL033_LEGACY_WDOG deliberately NOT defined


# ---------------------------------------------------------------- text helpers
def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", " ", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def preprocess(text, defines):
    """Evaluate `define/`undef/`ifdef/`ifndef/`elsif/`else/`endif on comment-stripped text."""
    defs = set(defines)
    out, stack = [], []          # stack entries: [parent_active, taken, active]
    active = True
    for line in strip_comments(text).split("\n"):
        m = re.match(r"\s*`(ifdef|ifndef|elsif|else|endif|define|undef)\b\s*(\w+)?", line)
        if m:
            d, name = m.group(1), m.group(2)
            if d in ("ifdef", "ifndef"):
                cond = (name in defs) if d == "ifdef" else (name not in defs)
                stack.append([active, cond, active and cond])
                active = stack[-1][2]
            elif d == "elsif":
                top = stack[-1]
                cond = name in defs
                top[2] = top[0] and (not top[1]) and cond
                top[1] = top[1] or cond
                active = top[2]
            elif d == "else":
                top = stack[-1]
                top[2] = top[0] and not top[1]
                top[1] = True
                active = top[2]
            elif d == "endif":
                top = stack.pop()
                active = top[0]
            elif d == "define" and active and name:
                defs.add(name)
            elif d == "undef" and active and name:
                defs.discard(name)
            continue
        if active:
            out.append(line)
    return "\n".join(out)


def balanced_region(text, start_re):
    """Text from the first match of start_re (which must end at 'begin') to its matching 'end'."""
    m = re.search(start_re, text)
    if not m:
        return None
    depth, i = 1, m.end()
    for tok in re.finditer(r"\b(begin|end)\b", text[i:]):
        depth += 1 if tok.group(1) == "begin" else -1
        if depth == 0:
            return text[m.start(): i + tok.end()]
    return None


# ---------------------------------------------------------------- flist resolution
def resolve_flist(tree, flist_name):
    """Return (files, missing, defines_in_flist). files = ordered list of real paths."""
    path = os.path.join(tree, "flists", flist_name)
    if not os.path.isfile(path):
        raise SystemExit("flist not found: %s" % path)
    env = dict(os.environ)
    env.update({"TIDELINK_HOME": tree, "SOCLABS_TIDELINK_DIR": tree})

    def expand(s):
        return re.sub(r"\$\{(\w+)\}|\$(\w+)", lambda m: env.get(m.group(1) or m.group(2), m.group(0)), s)

    raw, incdirs, defines = [], [], set()
    for line in open(path, errors="replace"):
        line = line.split("//")[0].strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("+incdir+"):
            incdirs += [expand(p) for p in line[len("+incdir+"):].split("+") if p]
        elif line.startswith("+define+"):
            defines |= set(line[len("+define+"):].split("+"))
        elif line.startswith(("+", "-")):
            continue
        else:
            raw.append(expand(line.split()[0]))
    files, missing = [], []
    for p in raw:
        if "/v2shims/" in p:                       # follow the shim's `include to the real source
            if not os.path.isfile(p):
                missing.append(p); continue
            inc = re.search(r'`include\s+"([^"]+)"', open(p, errors="replace").read())
            tgt = None
            if inc:
                for d in incdirs:
                    cand = os.path.join(d, inc.group(1))
                    if os.path.isfile(cand):
                        tgt = cand; break
            if tgt: files.append(tgt)
            else:   missing.append(p + " (include target not found)")
            continue
        (files if os.path.isfile(p) else missing).append(p)
    return files, missing, defines


# ---------------------------------------------------------------- markers
# kind: present / absent (regex on preprocessed text); region_present / region_absent (inside a
# balanced begin..end region found with `region`); stmt_absent (a `wire NAME = ...;` statement
# must not contain `bad`); in_flist / not_in_flist (path substring check); tree_present/tree_absent
# (host scripts: plain file in the tree, not an RTL flist member).
def M(id, group, file, kind, rx, region=None, bad=None, note=""):
    return dict(id=id, group=group, file=file, kind=kind, rx=rx, region=region, bad=bad, note=note)

CTRL = "axi_chiplet_controller.sv"
PHY = "WavD2DGpio_v2.v"
CAL = "tidelink_phy_align_calibrator_v2.sv"
FC6 = "WlinkGenericFCSM_6.v"

MARKERS = [
    # ---- A7: auto-anchor SYNC beacon must not overwrite a live word; must stop on AXI traffic
    M("a7.phy.tx_idle_q_reg",   "a7", PHY,  "present", r"\breg\s+tx_idle_q\b"),
    M("a7.phy.tx_idle_q_flop",  "a7", PHY,  "present", r"tx_idle_q\s*<=\s*io_link_tx_tx_idle\b"),
    M("a7.phy.sync_gate",       "a7", PHY,  "present", r"io_swi_auto_anchor_force_in\s*&\s*io_link_tx_tx_idle\s*&\s*tx_idle_q\b"),
    M("a7.phy.old_gate_gone",   "a7", PHY,  "absent",  r"io_swi_auto_anchor_force_in\s*&\s*io_link_tx_tx_idle\s*\)"),
    M("a7.ctl.axi_any_valid",   "a7", CTRL, "present", r"axi_a2l_any_v\s*=\s*axi_tgt_0_aw_valid\s*\|\s*axi_tgt_0_w_valid\s*\|\s*axi_tgt_0_ar_valid\s*\|\s*axi_ini_0_b_valid\s*\|\s*axi_ini_0_r_valid"),
    M("a7.ctl.two_flop_sync",   "a7", CTRL, "present", r"sync_axi_a2l_v_1\s*<=\s*sync_axi_a2l_v_0"),
    M("a7.ctl.stop_input",      "a7", CTRL, "present", r"auto_anchor_tx_idle\s*=\s*~\(\s*sync_obs_a2l_app_v_1\s*\|\s*sync_axi_a2l_v_1\s*\)"),
    M("a7.ctl.old_stop_gone",   "a7", CTRL, "absent",  r"auto_anchor_tx_idle\s*=\s*~sync_obs_a2l_app_v_1\s*;"),
    # ---- H30: calibrator swreset merge registered in apb_clk
    M("h30.reg",                "h30", CTRL, "present", r"\breg\s+cal_swreset_q\b"),
    M("h30.merge_flop",         "h30", CTRL, "present", r"cal_swreset_q\s*<=\s*swi_recal_r\s*\|"),
    M("h30.port_uses_q",        "h30", CTRL, "present", r"\.swreset\s*\(\s*cal_swreset_q\s*\)"),
    M("h30.old_comb_merge_gone","h30", CTRL, "absent",  r"\.swreset\s*\(\s*swi_recal_r\s*\|"),
    # ---- H31: S_CANCEL exit uses the synchronised level
    M("h31.s_cancel_uses_sync", "h31", CAL, "region_present", r"!\s*swreset_sync\b", region=r"\bS_CANCEL\s*:\s*begin"),
    M("h31.s_cancel_raw_gone",  "h31", CAL, "region_absent",  r"!\s*swreset\b",      region=r"\bS_CANCEL\s*:\s*begin"),
    # ---- TL-036: sideband FCSM_6 state-7 watchdog survives a real CRC error
    M("tl036.fcsm6_is_local_override", "tl036", FC6, "in_flist", r"src/rtl/local_overrides/WlinkGenericFCSM_6\.v"),
    M("tl036.force_clear_ungated",     "tl036", FC6, "stmt_absent", r"wire\s+socl_l7_wdog_force_clear\s*=\s*([^;]*);", bad=r"real_crc_seen",
      note="the effective (non-legacy) force_clear must not contain real_crc_seen"),
    M("tl036.force_clear_threshold",   "tl036", FC6, "present", r"wire\s+socl_l7_wdog_force_clear\s*=\s*\(\s*socl_l7_wdog_cnt\s*==\s*SOCL_L7_WDOG_THRESHOLD\s*\)\s*;"),
    M("tl036.state7_exit_on_force_clear","tl036", FC6, "present", r"_GEN_115\s*=\s*\(\s*auto_tx_out_advance\s*\|\s*socl_l7_wdog_force_clear\s*\)\s*\?\s*3'h4\s*:\s*state"),
    M("tl036.progress_clears_counter", "tl036", FC6, "present", r"wire\s+socl_l7_wdog_progress\s*=\s*auto_tx_out_advance\s*;"),
    M("tl036.counter_not_held_by_crc", "tl036", FC6, "absent",  r"else\s+if\s*\(\s*socl_l7_real_crc_seen\s*\)\s*begin\s*socl_l7_wdog_cnt\s*<="),
    M("tl036.legacy_define_absent",    "tl036", "*",  "no_define", r"TL033_LEGACY_WDOG",
      note="no flist +define+ and no `define of the negative-control macro in any compiled file"),
    # TL-059 design E (2026-10-14): L9b/L9c gated by the CRC-disable config bit (active only with CRC off)
    M("tl059.crc_off_term",            "tl059", FC6, "present", r"wire\s+socl_l9_crc_off\s*=\s*out_prepend_swi_disable_crc\s*;"),
    M("tl059.l9_gated",                "tl059", FC6, "present", r"&\s*socl_l9_crc_off"),
    M("tl059.always_define_absent",    "tl059", "*",  "no_define", r"SOCL_L9_ALWAYS"),
    # ---- host script fix: ErrInjection is TLAPB+0x23C, not the unmapped alias 0x3C
    M("errinj.lib_uses_023C",   "errinj", "pynq_host/scripts/xfer_corners_lib.py", "tree_present", r"REG_ERR_INJECT\s*=\s*_TLAPB\s*\+\s*0x023C"),
    M("errinj.lib_alias_gone",  "errinj", "pynq_host/scripts/xfer_corners_lib.py", "tree_absent",  r"REG_ERR_INJECT\s*=\s*_TLAPB\s*\+\s*0x0*3[Cc]\b"),
    M("errinj.poke_uses_023C",  "errinj", "pynq_host/scripts/eth_tlapb_poke.py",   "tree_present", r"wr\(\s*0x023C\s*,"),
    M("errinj.poke_alias_gone", "errinj", "pynq_host/scripts/eth_tlapb_poke.py",   "tree_absent",  r"wr\(\s*0x0*3[Cc]\s*,"),
    # ---- EMA 000->010 + SRAM macro from AW: ASIC-only, must be in the tree and must NOT be in the FPGA build
    M("asic.sram_ema_010",      "asic", "src/rtl/fifo/asic/tidelink_sram.sv", "tree_present", r"\.EMA\s*\(\s*3'b010\s*\)"),
    M("asic.sram_ema_000_gone", "asic", "src/rtl/fifo/asic/tidelink_sram.sv", "tree_absent",  r"\.EMA\s*\(\s*3'b000\s*\)"),
    M("asic.sram_by_aw",        "asic", "src/rtl/fifo/asic/tidelink_sram.sv", "tree_present", r"AW\s*==\s*13\b"),
    M("asic.file_not_in_fpga_flist", "asic", "src/rtl/fifo/asic/tidelink_sram.sv", "not_in_flist", r""),
    M("asic.fpga_sram_in_flist",     "asic", "src/rtl/fifo/fpga/tidelink_sram.sv", "in_flist",     r""),
]


def find_in_list(files, name):
    return [f for f in files if f.endswith("/" + name) or os.path.basename(f) == name]


def run(tree, mode, groups, flist_name):
    files, missing, flist_defs = resolve_flist(tree, flist_name)
    rows = []
    pkg_dir = os.path.join(tree, "imp", "fpga", "tidelink_ip", "src")
    if mode == "built" and not os.path.isdir(pkg_dir):
        raise SystemExit("built mode: %s does not exist (no packaged IP - was package_ip run?)" % pkg_dir)
    for mk in MARKERS:
        if mk["group"] not in groups:
            continue
        res = lambda s, d="": rows.append((mk["id"], s, mk["file"], d))
        k, f = mk["kind"], mk["file"]
        if k in ("tree_present", "tree_absent"):
            p = os.path.join(tree, f)
            if not os.path.isfile(p):
                res("FILE_ABSENT", p); continue
            txt = strip_comments(open(p, errors="replace").read())
            hit = re.search(mk["rx"], txt)
            ok = bool(hit) if k == "tree_present" else not hit
            res("PASS" if ok else ("MISSING" if k == "tree_present" else "STILL_PRESENT"), (hit.group(0)[:70] if hit else ""))
            continue
        if k in ("in_flist", "not_in_flist"):
            inflist = [x for x in files if x.endswith(f)] if "/" in f else find_in_list(files, f)
            if k == "not_in_flist":
                res("PASS" if not inflist else "IN_BUILD", (inflist[0] if inflist else "not compiled by " + flist_name))
            else:
                pat = mk["rx"] or re.escape(f)
                ok = any(re.search(pat, x) for x in inflist)
                res("PASS" if ok else "NOT_IN_BUILD", (inflist[0] if inflist else "absent from " + flist_name))
                if ok and mode == "built" and os.path.basename(f) == "tidelink_sram.sv":
                    pk = open(os.path.join(pkg_dir, "tidelink_sram.sv"), errors="replace").read()
                    good = "cmsdk_fpga_sram" in pk and "rf_16k" not in strip_comments(pk)
                    res("PASS" if good else "WRONG_SRAM_BUILT", "packaged tidelink_sram.sv %s" % ("is the BRAM wrapper" if good else "is not the FPGA wrapper"))
            continue
        if k == "no_define":
            bad = [d for d in flist_defs if re.search(mk["rx"], d)]
            for x in files:
                t = open(x, errors="replace").read()
                if re.search(r"`define\s+" + mk["rx"], strip_comments(t)):
                    bad.append(x)
            if mode == "built":
                for fn in os.listdir(pkg_dir):
                    t = open(os.path.join(pkg_dir, fn), errors="replace").read()
                    if re.search(r"`define\s+" + mk["rx"], strip_comments(t)):
                        bad.append(os.path.join(pkg_dir, fn))
            res("PASS" if not bad else "DEFINED", ", ".join(bad[:2]))
            continue
        # RTL markers: file must be a member of the flist
        cands = find_in_list(files, f)
        if not cands:
            res("NOT_IN_BUILD", "%s is not compiled by %s" % (f, flist_name)); continue
        src = cands[-1]
        if mode == "built":
            pk = os.path.join(pkg_dir, os.path.basename(src))
            if not os.path.isfile(pk):
                res("NOT_PACKAGED", pk); continue
            srctext, pktext = open(src, errors="replace").read(), open(pk, errors="replace").read()
            if srctext not in pktext:
                res("STALE", "packaged copy differs from %s" % os.path.relpath(src, tree)); continue
            text = pktext
        else:
            text = open(src, errors="replace").read()
        pp = preprocess(text, BUILD_DEFINES)
        if k == "present":
            h = re.search(mk["rx"], pp); res("PASS" if h else "MISSING", (re.sub(r"\s+", " ", h.group(0))[:70] if h else ""))
        elif k == "absent":
            h = re.search(mk["rx"], pp); res("PASS" if not h else "STILL_PRESENT", (re.sub(r"\s+", " ", h.group(0))[:70] if h else ""))
        elif k in ("region_present", "region_absent"):
            reg = balanced_region(pp, mk["region"])
            if reg is None:
                res("REGION_ABSENT", "no region matching %s" % mk["region"]); continue
            h = re.search(mk["rx"], reg)
            ok = bool(h) if k == "region_present" else not h
            res("PASS" if ok else ("MISSING" if k == "region_present" else "STILL_PRESENT"), (re.sub(r"\s+", " ", h.group(0))[:70] if h else ""))
        elif k == "stmt_absent":
            st = re.search(mk["rx"], pp)
            if not st:
                res("MISSING", "statement not found"); continue
            res("PASS" if not re.search(mk["bad"], st.group(1)) else "STILL_PRESENT", re.sub(r"\s+", " ", st.group(1))[:70])
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--mode", choices=("source", "built"), default="source")
    ap.add_argument("--groups", default="a7,h30,h31,tl036,errinj,asic,tl059")
    ap.add_argument("--flist", default=DEFAULT_FLIST)
    a = ap.parse_args()
    tree = os.path.abspath(a.tree)
    groups = set(a.groups.split(","))
    rows = run(tree, a.mode, groups, a.flist)
    w = max(len(r[0]) for r in rows)
    print("check_markers: tree=%s mode=%s flist=%s groups=%s" % (tree, a.mode, a.flist, ",".join(sorted(groups))))
    for id_, st, f, d in rows:
        print("  [%-13s] %-*s  %s%s" % (st, w, id_, os.path.basename(f) if f != "*" else "(all compiled files)", ("  :: " + d) if d else ""))
    bad = [r for r in rows if r[1] != "PASS"]
    per = {}
    for r in rows:
        g = r[0].split(".")[0]
        per.setdefault(g, [0, 0]); per[g][0 if r[1] == "PASS" else 1] += 1
    print("check_markers: " + "  ".join("%s %d/%d" % (g, v[0], v[0] + v[1]) for g, v in sorted(per.items())))
    print("MARKERS_RESULT=%s (%d of %d markers pass)" % ("PASS" if not bad else "FAIL", len(rows) - len(bad), len(rows)))
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
