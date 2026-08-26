#!/usr/bin/env python3
"""Which files does the ASIC (tapeout) flist resolve DIFFERENTLY from the FPGA one?

The two flists are not an RTL fork -- they are a FLIST divergence, which is why
it survives review: `git diff` between the two trees shows nothing, because the
difference is *which file each module is taken from*, not what any one file
says.  This script makes that divergence explicit, diffable and checkable.

    scripts/ci/flist_divergence.py                 # human report
    scripts/ci/flist_divergence.py --json          # machine-readable
    scripts/ci/flist_divergence.py --check         # non-zero if the set moved

--check compares against EXPECTED_SHADOW_PAIRS below.  It is deliberately a
hand-maintained list: a NEW divergence is a decision someone must make on
purpose (the 2026-07-29 hold, ratified 2026-08-20, is the standing one), and a
silently-appearing ninth pair is exactly the failure this file exists to catch.

Requires the environment set_env.sh provides (TIDELINK_HOME, CMSDK_DIR, ...);
paths in the flists are ${VAR}-expanded the same way VCS expands them.
"""
import argparse, json, os, re, subprocess, sys

ASIC_FLIST = "flists/tidelink_top_full_asic_v2.flist"
FPGA_FLIST = "flists/tidelink_fpga_v2.flist"

# basename -> (asic path fragment, fpga path fragment).  Checked by --check.
EXPECTED_SHADOW_PAIRS = {
    "WlinkGenericFCSM.v":                ("deps/", "src/rtl/local_overrides/"),
    "WlinkGenericFCSM_1.v":              ("deps/", "src/rtl/local_overrides/"),
    "WlinkGenericFCSM_2.v":              ("deps/", "src/rtl/local_overrides/"),
    "WlinkGenericFCSM_3.v":              ("deps/", "src/rtl/local_overrides/"),
    "WlinkGenericFCSM_4.v":              ("deps/", "src/rtl/local_overrides/"),
    "WlinkGenericFCReplayAddrSync_18.v": ("deps/", "src/rtl/local_overrides/"),
    "i2c_master.v":                      ("deps/", "src/rtl/local_overrides/"),
    "tidelink_sram.sv":                  ("src/rtl/fifo/asic/", "src/rtl/fifo/fpga/"),
}


def resolve(path):
    """Return (source files, non-file options) exactly as VCS would see them."""
    files, opts = [], []
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            line = re.split(r"\s+//", line)[0].strip()
            if not line:
                continue
            line = os.path.expandvars(line)
            (opts if line[0] in "+-" else files).append(line)
    return files, opts


def sloc(path):
    try:
        return sum(1 for l in open(path, errors="replace")
                   if l.strip() and not l.strip().startswith("//"))
    except OSError:
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("TIDELINK_HOME", "."))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--diff", action="store_true", help="print a unified diff per pair")
    a = ap.parse_args()
    root = os.path.abspath(a.root)

    af, aopt = resolve(os.path.join(root, ASIC_FLIST))
    ff, fopt = resolve(os.path.join(root, FPGA_FLIST))
    only_a, only_f = sorted(set(af) - set(ff)), sorted(set(ff) - set(af))
    ba = {os.path.basename(p): p for p in only_a}
    bf = {os.path.basename(p): p for p in only_f}

    def rel(p):
        return os.path.relpath(p, root) if p.startswith(root) else p

    pairs = []
    for b in sorted(set(ba) & set(bf)):
        d = subprocess.run(["diff", "-u", ba[b], bf[b]], capture_output=True, text=True)
        changed = sum(1 for l in d.stdout.splitlines()
                      if l[:1] in "+-" and not l.startswith(("+++", "---")))
        pairs.append(dict(
            basename=b, asic=rel(ba[b]), fpga=rel(bf[b]),
            asic_sloc=sloc(ba[b]), fpga_sloc=sloc(bf[b]),
            diff_lines=changed,
            asic_socl=sum(1 for _ in re.finditer(r"socl_", open(ba[b], errors="replace").read())),
            fpga_socl=sum(1 for _ in re.finditer(r"socl_", open(bf[b], errors="replace").read())),
            diff=d.stdout if a.diff else None))

    unpaired_a = [rel(ba[b]) for b in sorted(ba) if b not in bf]
    unpaired_f = [rel(bf[b]) for b in sorted(bf) if b not in ba]
    out = dict(asic_flist=ASIC_FLIST, fpga_flist=FPGA_FLIST,
               asic_files=len(af), fpga_files=len(ff),
               asic_opts=aopt, fpga_opts=fopt,
               shadow_pairs=pairs,
               asic_only_unpaired=unpaired_a, fpga_only_unpaired=unpaired_f)

    if a.json:
        print(json.dumps(out, indent=2))
    else:
        print(f"ASIC flist : {ASIC_FLIST}  ({len(af)} sources)")
        print(f"FPGA flist : {FPGA_FLIST}  ({len(ff)} sources)")
        print(f"\nSHADOW PAIRS -- same module name, DIFFERENT file ({len(pairs)}):")
        print(f"  {'basename':34s} {'ASIC':>6s} {'FPGA':>6s} {'diff':>6s} {'socl_ A/F':>11s}")
        for p in pairs:
            print(f"  {p['basename']:34s} {p['asic_sloc']:6d} {p['fpga_sloc']:6d} "
                  f"{p['diff_lines']:6d} {p['asic_socl']:5d}/{p['fpga_socl']:<5d}")
            print(f"      ASIC ships {p['asic']}")
            print(f"      FPGA  runs {p['fpga']}")
            if a.diff:
                print("\n".join("      " + l for l in p["diff"].splitlines()))
        tot = sum(p["asic_sloc"] for p in pairs)
        print(f"\n  ASIC-side SLOC behind the shadow: {tot}")
        print(f"\nASIC-only, no FPGA twin ({len(unpaired_a)}):")
        for p in unpaired_a:
            print(f"  {p}")
        print(f"\nFPGA-only, no ASIC twin ({len(unpaired_f)}):")
        for p in unpaired_f:
            print(f"  {p}")

    if a.check:
        got = {p["basename"]: (p["asic"], p["fpga"]) for p in pairs}
        bad = []
        for b, (ax, fx) in EXPECTED_SHADOW_PAIRS.items():
            if b not in got:
                bad.append(f"EXPECTED shadow pair {b} is GONE -- the flists now agree. "
                           f"If that was intentional, update EXPECTED_SHADOW_PAIRS.")
                continue
            ga, gf = got[b]
            if ax not in ga or fx not in gf:
                bad.append(f"{b}: expected ASIC~{ax} FPGA~{fx}, got ASIC={ga} FPGA={gf}")
        for b in got:
            if b not in EXPECTED_SHADOW_PAIRS:
                bad.append(f"NEW shadow pair {b}: ASIC={got[b][0]} FPGA={got[b][1]} -- "
                           f"a divergence appeared that nobody recorded a decision for.")
        if bad:
            print("\nFLIST DIVERGENCE CHECK: FAIL", file=sys.stderr)
            for m in bad:
                print("  " + m, file=sys.stderr)
            return 1
        print(f"\nFLIST DIVERGENCE CHECK: OK ({len(got)} shadow pairs, all expected)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
