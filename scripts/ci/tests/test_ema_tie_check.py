#!/usr/bin/env python3
"""Control for scripts/ci/ema_tie_check.py (TL-057): the checker must go GREEN on
the shipping tidelink_sram.sv and RED on mutants (EMA 000, EMAW 01, missing
port, non-constant, no macro at all). Pure Python."""
import os, re, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CK = os.path.join(ROOT, "scripts/ci/ema_tie_check.py")
SRC = os.path.join(ROOT, "src/rtl/fifo/asic/tidelink_sram.sv")
env = dict(os.environ, TIDELINK_HOME=ROOT)

def run(args):
    r = subprocess.run([sys.executable, CK] + args, capture_output=True, text=True, env=env)
    return r.returncode, r.stdout

def mutant(pat, rep, count=0):
    t = open(SRC).read()
    t2 = re.sub(pat, rep, t, count=count)
    assert t2 != t, "mutation did not change the file: %r" % (pat,)
    d = tempfile.mkdtemp(); p = os.path.join(d, "m.sv"); open(p, "w").write(t2); return p

fails = []
rc, out = run(["--files", SRC])
if rc != 0: fails.append("shipping file should be green: %s" % out)
rc, out = run(["--check"])
if rc != 0: fails.append("--check on the tree should be green: %s" % out)
muts = {
 "EMA 000 both":       (r"\.EMA\s*\(3'b010\)", ".EMA   (3'b000)", 0),
 "EMA 000 first only": (r"\.EMA\s*\(3'b010\)", ".EMA   (3'b000)", 1),
 "EMAW 01":            (r"\.EMAW\s*\(2'b00\)", ".EMAW  (2'b01)", 1),
 "EMA port removed":   (r"\.EMA\s*\(3'b010\),", "", 1),
 "EMA non-constant":   (r"\.EMA\s*\(3'b010\)", ".EMA   (ema_w)", 1),
 "no macro":           (r"\brf_16k\b|\brf_08k\b", "other_mod", 0),
}
for name, (pat, rep, cnt) in muts.items():
    p = mutant(pat, rep, cnt)
    rc, out = run(["--files", p])
    print("mutant %-20s -> rc=%d %s" % (name, rc, out.strip().splitlines()[-1]))
    if rc != 1: fails.append("mutant '%s' not detected (rc=%d)" % (name, rc))
if fails:
    print("test_ema_tie_check: FAIL\n  " + "\n  ".join(fails)); sys.exit(1)
print("test_ema_tie_check: PASS (green on shipping, red on all %d mutants)" % len(muts))
