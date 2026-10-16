#!/usr/bin/env python3
"""Must-fail control for scripts/ci/check_host_addrs.py (host-script register-address lint).

The lint exists because a host tool once wrote the unmapped alias 0x003C instead of LINK_ERROR_INJECTION
(0x023C): the write was dropped, the counter read 0, and "all exact" looked like a pass.  A lint that has
never been seen to go red is decoration, so this drives it with specimens and requires each verdict:

  bad_alias_errinj.py      the historical 0x003C alias (both `TLAPB+0x003C` and a plain constant)  -> R2, exit 1
  bad_unmapped.py          offsets / SoC literals that are not registers                          -> R1, exit 1
  bad_wrong_register.py    a valid address of the WRONG register under an injector name           -> R3, exit 1
  good_ok.py               real registers, a justified relative 0x3C, a foreign block             -> exit 0
  map dependence           deleting link_error_injection from a COPY of the RDL turns the good
                           fixture red; deleting the Region F rows from a COPY of the doc turns the
                           real scan red (the lint reads the map, it does not hard-code it)
  allowlist                an entry that matches nothing is a finding; one without a reason is refused
  the real tree            passes, and extracted a non-trivial number of constants (not vacuous)

    python3 scripts/ci/tests/test_check_host_addrs.py
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from contextlib import redirect_stdout

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
LINT = os.path.join(REPO, "scripts", "ci", "check_host_addrs.py")
FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "host_addrs")
sys.path.insert(0, os.path.join(REPO, "scripts", "ci"))
import check_host_addrs as L  # noqa: E402

BAD = 0


def lint(args):
    buf = io.StringIO()
    with redirect_stdout(buf):
        try:
            rc = L.main(args)
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else 2
            buf.write(str(e.code) + "\n")
    return rc, buf.getvalue()


def check(name, cond, detail=""):
    global BAD
    print("%-4s %s%s" % ("ok" if cond else "BAD", name, ("   " + detail) if (detail and not cond) else ""))
    BAD += not cond


def tmp_root():
    """A scratch root with copies of the map sources (so a test can break the copy, never the repo)."""
    d = tempfile.mkdtemp(prefix="host_addrs_")
    shutil.copytree(os.path.join(REPO, "src", "rdl"), os.path.join(d, "src", "rdl"))
    os.makedirs(os.path.join(d, "docs"))
    shutil.copy(os.path.join(REPO, "docs", "REGISTER_MAP.md"), os.path.join(d, "docs"))
    os.makedirs(os.path.join(d, "scripts", "ci"))
    return d


# ---- the real tree -------------------------------------------------------------------------------
rc, out = lint([])
m = re.search(r"(\d+) address constants extracted", out)
check("real tree passes", rc == 0 and "HOST_ADDR_LINT_RESULT=PASS" in out, out[-600:])
check("real tree: non-vacuous (>= 200 constants extracted)", bool(m) and int(m.group(1)) >= 200, out[:200])

rm = L.build_map(REPO)
check("map: link_error_injection is 0x023C (from the RDL, not the doc)", rm.abs.get(0x23C, ("",))[0] == "link_error_injection", repr(rm.abs.get(0x23C)))
check("map: 0x003C is NOT a register", 0x3C not in rm.abs)
check("map: Region F slot 0x21F8 comes from the doc table", rm.abs.get(0x21F8, ("",))[0].startswith("doc:XHB_SUB_OBS"), repr(rm.abs.get(0x21F8)))
check("map: fc_tidelink.crc_errors 0x1720 expanded from the nested addrmap", rm.abs.get(0x1720, ("",))[0] == "fc_tidelink.crc_errors")
check("map: reserved doc slot 0x21FC is not a register", 0x21FC not in rm.abs)

# ---- must-fail specimens --------------------------------------------------------------------------
rc, out = lint([os.path.join(FIX, "bad_alias_errinj.py")])
check("alias fixture: exit 1", rc == 1, out)
check("alias fixture: BOTH spellings flagged R2 (TLAPB+0x003C and ERRINJ=0x003C)", len(re.findall(r"R2 0x003c", out)) == 2, out)

rc, out = lint([os.path.join(FIX, "bad_unmapped.py")])
check("unmapped fixture: exit 1", rc == 1, out)
check("unmapped fixture: 0x2012, 0x2F00 and the SoC literal 0x84032111 flagged R1", len(re.findall(r"R1 ", out)) == 3, out)

rc, out = lint([os.path.join(FIX, "bad_wrong_register.py")])
check("wrong-register fixture: exit 1 with R3 naming link_error_injection 0x23c", rc == 1 and "R3" in out and "link_error_injection" in out and "0x23c" in out, out)

rc, out = lint([os.path.join(FIX, "good_ok.py")])
check("good fixture: exit 0", rc == 0, out)
check("good fixture: the relative 0x3C was accepted ONLY through its pragma", "PRAGMA-RELATIVE=1" in out and "SKIP-FOREIGN=1" in out, out)

# a bare 0x3C without the pragma is never accepted
d = tempfile.mkdtemp(prefix="host_addrs_f_")
bare = os.path.join(d, "bare.py")
open(bare, "w").write("FC_NODE_PTP_REL = 0x3C\n")
rc, out = lint([bare])
check("bare 0x3C without pragma: R2", rc == 1 and "R2" in out, out)
open(bare, "w").write("FC_NODE_PTP_REL = 0x3C   # regmap-lint: relative\n")
rc, out = lint([bare])
check("pragma WITHOUT a reason is not accepted", rc == 1, out)
open(bare, "w").write("def f(wr):\n    wr(0x3C, 1)\n")
rc, out = lint([bare])
check("accessor literal wr(0x3C, ..) flagged", rc == 1 and "R2" in out, out)
open(bare, "w").write("def f(wr, APB):\n    wr(APB + 0x003C, 1)\n")
rc, out = lint([bare])
check("accessor wr(APB + 0x003C, ..) flagged", rc == 1 and "R2" in out, out)
shutil.rmtree(d, ignore_errors=True)

# ---- the lint reads the map ------------------------------------------------------------------------
r = tmp_root()
p = os.path.join(r, "src", "rdl", "wlink_regs.rdl")
t = open(p).read()
t2 = t.replace("link_error_injection_reg link_error_injection @ 0x023C;", "")
assert t != t2, "specimen edit did not apply (RDL changed?)"
open(p, "w").write(t2)
fx = os.path.join(r, "good_ok.py")
shutil.copy(os.path.join(FIX, "good_ok.py"), fx)
rc, out = lint(["--root", r, fx])
check("map dependence: removing link_error_injection from the RDL turns the good fixture red", rc == 1 and "0x023c" in out, out)
shutil.rmtree(r, ignore_errors=True)

r = tmp_root()
p = os.path.join(r, "docs", "REGISTER_MAP.md")
t = open(p).read()
t2 = "\n".join(l for l in t.splitlines() if not l.startswith("| 0x21F8 "))
assert t != t2
open(p, "w").write(t2)
rc, out = lint(["--root", r, os.path.join(REPO, "pynq_host", "hw_regress", "rev2hw.py")])
check("map dependence: removing the 0x21F8 doc row turns rev2hw.py red (doc table is read)", rc == 1 and "0x21f8" in out, out)
shutil.rmtree(r, ignore_errors=True)

r = tmp_root()
os.remove(os.path.join(r, "src", "rdl", "wlink_regs.rdl"))
rc, out = lint(["--root", r, os.path.join(FIX, "good_ok.py")])
check("missing RDL: exit 2 (could not evaluate), never a pass", rc == 2, out)
shutil.rmtree(r, ignore_errors=True)

# ---- allowlist ---------------------------------------------------------------------------------------
r = tmp_root()
al = os.path.join(r, "scripts", "ci", "host_addr_allowlist.txt")
open(al, "w").write("good_ok.py\tNOSUCHTOKEN=0x1\tstale on purpose\n")
shutil.copy(os.path.join(FIX, "good_ok.py"), os.path.join(r, "good_ok.py"))
rc, out = lint(["--root", r, os.path.join(r, "good_ok.py")])
check("allowlist: a stale entry is a finding", rc == 1 and "stale allowlist entry" in out, out)
open(al, "w").write("good_ok.py\tERRINJ=0x\n")
rc, out = lint(["--root", r, os.path.join(r, "good_ok.py")])
check("allowlist: an entry without a reason is refused", rc not in (0, 1) or "reason is mandatory" in out, out)
shutil.rmtree(r, ignore_errors=True)

# ---- CLI exit codes -------------------------------------------------------------------------------------
p = subprocess.run([sys.executable, LINT, os.path.join(FIX, "bad_alias_errinj.py")], capture_output=True, text=True)
check("CLI: bad fixture exits 1 and prints HOST_ADDR_LINT_RESULT=FAIL", p.returncode == 1 and "HOST_ADDR_LINT_RESULT=FAIL" in p.stdout, p.stdout)

print("TEST_CHECK_HOST_ADDRS_RESULT=%s" % ("PASS" if not BAD else "FAIL"))
sys.exit(1 if BAD else 0)
