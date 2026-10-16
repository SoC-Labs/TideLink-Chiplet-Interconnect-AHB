#!/usr/bin/env python3
"""Assert every ASIC tool Makefile resolves to the SAME flist and define set.

LEC/STA/DRC must read the RTL synthesis read. Each of fusion-compiler,
formality, primetime, calibre and rtl-architect is evaluated with `make` (no
recipe runs, no EDA tool) through a wrapper that includes the tool Makefile and
prints $(FLIST). Checked for the default and for ASIC_PHY= (V1):
  1. all tools resolve to one file;
  2. the default resolves to the _v2 flist, ASIC_PHY= to the plain _asic one;
  3. the +define+ set of the flist (nested -f followed) agrees with the PHY:
     TIDELINK_PHY_V2 present iff V2.
Usage: asic_flist_consistency.py [--root DIR] [--tools a,b] [--selftest]
Exit 0 consistent, 1 inconsistent, 2 usage/tool error.
"""
import argparse, os, re, subprocess, sys, tempfile

TOOLS = ["fusion-compiler", "formality", "primetime", "calibre", "rtl-architect"]
MODULE = "tidelink_top_full"


def resolve(root, tool, phy):
    """phy None = leave knob at its default; else pass ASIC_PHY=<phy>."""
    mk = os.path.join(root, "syn/asic", tool, "Makefile")
    with tempfile.NamedTemporaryFile("w", suffix=".mk", delete=False) as w:
        w.write("SITE_SOFT_GOALS += __show\ninclude %s\n__show:\n\t@echo FLIST=$(FLIST)\n" % mk)
    try:
        args = ["make", "-s", "-f", w.name, "__show", "TIDELINK_HOME=" + root]
        if phy is not None:
            args.append("ASIC_PHY=" + phy)
        env = dict(os.environ); env.pop("FLIST", None)
        p = subprocess.run(args, cwd=root, capture_output=True, text=True, env=env)
    finally:
        os.unlink(w.name)
    m = re.search(r"^FLIST=(.*)$", p.stdout, re.M)
    if p.returncode or not m:
        return None, (p.stdout + p.stderr).strip().splitlines()[-1:] or ["make failed"]
    return os.path.realpath(m.group(1).strip()), None


def defines(path, seen=None):
    seen = seen if seen is not None else set()
    out = set()
    if path in seen or not os.path.isfile(path):
        return out
    seen.add(path)
    for line in open(path, errors="replace"):
        line = line.split("//")[0].strip()
        for d in re.findall(r"\+define\+(\S+)", line):
            out.add(d)
        m = re.match(r"-f\s+(\S+)", line)
        if m:
            nested = os.path.expandvars(m.group(1))
            out |= defines(nested, seen)
    return out


def check(root, tools):
    bad = []
    for phy, label, want in ((None, "default", "_asic_v2.flist"), ("", "ASIC_PHY=", "_asic.flist")):
        res = {}
        for t in tools:
            f, err = resolve(root, t, phy)
            if f is None:
                bad.append("%s [%s]: cannot resolve: %s" % (t, label, err))
                continue
            res[t] = f
            print("  %-16s %-10s %s" % (t, label, os.path.relpath(f, root)))
        if len(set(res.values())) > 1:
            bad.append("[%s] tools disagree on flist: %s" % (label, sorted(set(os.path.relpath(v, root) for v in res.values()))))
        for t, f in res.items():
            if not f.endswith(MODULE + want):
                bad.append("%s [%s]: expected *%s, got %s" % (t, label, want, os.path.relpath(f, root)))
        for f in set(res.values()):
            v2 = "TIDELINK_PHY_V2" in defines(f)
            if v2 != f.endswith("_v2.flist"):
                bad.append("%s: TIDELINK_PHY_V2 defined=%s inconsistent with its PHY composition" % (os.path.relpath(f, root), v2))
    return bad


def selftest(root):
    """Must-fail fixture: a copy of the tree's syn/asic Makefiles with one tool re-pinned to V1."""
    import shutil
    with tempfile.TemporaryDirectory() as d:
        for sub in ("syn/asic", "flists", "mk"):
            s = os.path.join(root, sub)
            if os.path.isdir(s):
                shutil.copytree(s, os.path.join(d, sub), symlinks=True)
        pt = os.path.join(d, "syn/asic/primetime/Makefile")
        with open(pt, "a") as f:
            f.write("\noverride FLIST := $(TIDELINK_HOME)/flists/$(MODULE)_asic.flist\n")
        bad = check(d, TOOLS)
    if not bad:
        print("SELFTEST FAIL: seeded V1 re-pin in primetime was NOT detected"); return 1
    print("SELFTEST ok: seeded defect detected (%d finding(s))" % len(bad)); return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.realpath(os.path.join(os.path.dirname(__file__), "../..")))
    ap.add_argument("--tools", default=",".join(TOOLS))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.root)
    bad = check(a.root, a.tools.split(","))
    for b in bad:
        print("FAIL:", b)
    print("RESULT:", "FAIL" if bad else "PASS")
    return 1 if bad else 0


sys.exit(main())
