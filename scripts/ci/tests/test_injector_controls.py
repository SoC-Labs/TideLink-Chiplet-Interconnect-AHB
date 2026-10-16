#!/usr/bin/env python3
"""Unit controls for pynq_host/hw_regress/injector_controls.py (the shared injector must-fail controls).

Pure Python, no board, no simulator.  Each control is shown to PASS on a healthy register model and to FAIL on a
broken one -- the library is the instrument both the KR260 tool and the cocotb benches trust, so it must be
seen going red.

    python3 scripts/ci/tests/test_injector_controls.py
"""
import os
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "pynq_host", "hw_regress"))
sys.path.insert(0, os.path.join(REPO, "scripts", "ci"))
import injector_controls as ic  # noqa: E402
import check_host_addrs as L    # noqa: E402

BAD = 0


def check(name, cond, detail=""):
    global BAD
    print("%-4s %s%s" % ("ok" if cond else "BAD", name, ("   " + str(detail)) if (detail and not cond) else ""))
    BAD += not cond


class Regs:
    """A tiny register file with knobs: drop (writes ignored), ro_unless_unlocked (slave-die RO APB)."""
    def __init__(self, drop=False, slave=False, stuck=None, slow=False):
        self.v, self.drop, self.slave, self.stuck, self.slow = {}, drop, slave, stuck, slow
        self.unlocked, self.unlock_log, self.reads = False, [], 0
        self.pending = {}

    def rd(self, a):
        self.reads += 1
        if self.stuck is not None:
            return self.stuck
        if a in self.pending and self.slow:                 # a CDC: the value shows up on the 2nd read after the write
            self.pending[a] -= 1
            if self.pending[a] < 0:
                return self.v.get(a, 0)
            return 0
        return self.v.get(a, 0)

    def wr(self, a, val):
        if self.drop or (self.slave and not self.unlocked):
            return
        self.v[a] = val
        self.pending[a] = 1

    def unlock(self, on):
        self.unlocked = on; self.unlock_log.append(on)


BASE = 0x84030000
nosleep = lambda s: None

# ---- C-REG-ADDR
rm = L.build_map(REPO)
check("C-REG-ADDR: ERRINJ_OFFSET equals the RDL link_error_injection offset", rm.abs[ic.ERRINJ_OFFSET][0] == "link_error_injection", rm.abs.get(ic.ERRINJ_OFFSET))
check("C-REG-ADDR: every UNMAPPED_ALIASES entry is really unmapped in the RDL map", all(a not in rm.abs for a in ic.UNMAPPED_ALIASES))
for off, why in ((0x003C, "alias"), (0x0240, "another register"), (0x23D, "unaligned")):
    try:
        ic.Injector(lambda a: 0, lambda a, v: None, BASE, offset=off)
        check("C-REG-ADDR: offset 0x%04x (%s) refused at construction" % (off, why), False)
    except ic.ControlError as e:
        check("C-REG-ADDR: offset 0x%04x (%s) refused at construction" % (off, why), True)
r = Regs()
try:
    ic.Injector(r.rd, r.wr, BASE, offset=0x3C, sleep=nosleep)
except ic.ControlError:
    pass
check("C-REG-ADDR: refusal happens before ANY write", r.v == {} and r.reads == 0)

# ---- C-REG-HOLD / arm
r = Regs(); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep, unlock=r.unlock)
a = inj.arm(0xA1, 5, 3)
check("hold: healthy register -> OK and value read back", a.ok and a.value == ic.arm_value(0xA1, 5, 3) and r.v[BASE + 0x23C] == a.value, a.status)
check("hold: disarm reads back 0", inj.disarm() and r.v[BASE + 0x23C] == 0)
r = Regs(drop=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep, unlock=r.unlock)
a = inj.arm(0xA1, 5, 0)
check("hold: writes dropped (the unmapped-alias symptom) -> NO_HOLD, not OK", a.status == "NO_HOLD" and not a.ok, a.status)
r = Regs(stuck=0x00000001); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep)
check("hold: register not 0 before the arm -> NOT_ZERO", inj.arm(0xA1, 5, 0).status == "NOT_ZERO")
r = Regs(slow=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep)
check("hold: a value that only settles after the CDC (late read) still OK", inj.arm(0xA1, 5, 0).ok)

# ---- slave-die debug unlock
r = Regs(slave=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep, unlock=r.unlock)
check("unlock: slave-die RO APB arms only because the unlock is raised", inj.arm(0xA1, 5, 0).ok and r.unlocked)
inj.disarm()
check("unlock: relocked after disarm", not r.unlocked and r.unlock_log[-1] is False)
r = Regs(slave=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep, unlock=None)
check("unlock: without the unlock the slave die does not hold -> NO_HOLD", inj.arm(0xA1, 5, 0).status == "NO_HOLD")
r = Regs(drop=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep, unlock=r.unlock)
inj.arm(0xA1, 5, 0)
check("unlock: a FAILED arm never leaves the die unlocked", not r.unlocked and r.unlock_log == [True, False], r.unlock_log)
r = Regs(slave=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep, unlock=r.unlock)
try:
    with inj.armed(0xA1, 5, 0) as arm:
        assert arm.ok
        raise RuntimeError("test body blew up")
except RuntimeError:
    pass
check("unlock: armed() disarms and relocks on an exception", not r.unlocked and r.v[BASE + 0x23C] == 0)

# ---- C-INJ-INERT
r = Regs(); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep)
errs, info = ic.run_wrong_id_control(inj, lambda: 0, lambda: (0, 0))
check("C-INJ-INERT: selective injector (nothing changes) -> no errors", errs == [], errs)
cnt = {"n": 0}
def moving():
    cnt["n"] += 1; return (cnt["n"], 0)
r = Regs(); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep)
errs, info = ic.run_wrong_id_control(inj, lambda: 0, moving)
check("C-INJ-INERT: a counter that moves under a wrong-DataID arm -> error", any("moved a CRC counter" in e for e in errs), errs)
r = Regs(); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep)
errs, info = ic.run_wrong_id_control(inj, lambda: 2, lambda: (0, 0))
check("C-INJ-INERT: corrupted data under a wrong-DataID arm -> error", any("not selective" in e for e in errs), errs)
r = Regs(drop=True); inj = ic.Injector(r.rd, r.wr, BASE, sleep=nosleep)
errs, info = ic.run_wrong_id_control(inj, lambda: 0, lambda: (0, 0))
check("C-INJ-INERT: injector that cannot be armed -> error (control cannot run)", errs and "cannot run" in errs[0], errs)

# ---- C-INJ-LIVE (simulation form: `fired` observable) -- golden strings kept from the pre-library tests
check("C-INJ-LIVE: fired 1, counter +1 -> clean", ic.shot_errors(1, 1) == [])
e = ic.shot_errors(0, 0)
check("C-INJ-LIVE: shot never fired -> 'injector fired 0x, wanted 1 ... vacuous'", e == ["ERROR shot: injector fired 0x, wanted 1 (tx pkts None); vacuous"] or e[0].startswith("ERROR shot: injector fired 0x, wanted 1"), e)
e = ic.shot_errors(1, 0, tx_pkts=7)
check("C-INJ-LIVE: fired but counter +0 -> ERROR detect (vacuous)", e == ["ERROR detect: fired 1 but CRC counter +0 (wanted +1); vacuous"], e)
check("C-INJ-LIVE: header-field case documents +0 and passes only when it is +0", ic.shot_errors(1, 0, expect_crc=0) == [] and ic.shot_errors(1, 1, expect_crc=0) != [])
check("C-INJ-LIVE: two-hit shot needs fired == 2", ic.shot_errors(2, 2, want_hits=2) == [] and ic.shot_errors(1, 1, want_hits=2) != [])
# board form
check("board classify: +1 and exact -> EFFECTIVE", ic.classify_board_shot(1, True) == "EFFECTIVE")
check("board classify: +0 and exact -> INERT (never a pass by itself)", ic.classify_board_shot(0, True) == "INERT")
check("board classify: +0 and data wrong (silent corruption) -> FAIL", ic.classify_board_shot(0, False) == "FAIL")
check("board classify: +2 or detected-but-wrong -> FAIL", ic.classify_board_shot(2, True) == "FAIL" and ic.classify_board_shot(1, False) == "FAIL")

# ---- C-COUNT-EXPECT
lg = ic.ShotLedger()
for i in range(5):
    lg.add(1, 1, "s%d" % i)
check("C-COUNT-EXPECT: 5 shots, 5 counts, total +5 -> clean", lg.errors(total_delta=5, expect_each=1) == [])
check("C-COUNT-EXPECT: counter moved +7 over the run but shots account for +5 -> error", lg.errors(total_delta=7) != [])
lg = ic.ShotLedger(); lg.add(1, 1, "a"); lg.add(1, 0, "b")
check("C-COUNT-EXPECT: a fired shot with no counter movement (eaten) -> error", any("silently eaten" in x for x in lg.errors(expect_each=1)))
lg = ic.ShotLedger(); lg.add(0, 3, "c")
check("C-COUNT-EXPECT: counter moved with NO shot fired (the counter lies) -> error", any("counter lies" in x for x in lg.errors()))

print("TEST_INJECTOR_CONTROLS_RESULT=%s" % ("PASS" if not BAD else "FAIL"))
sys.exit(1 if BAD else 0)
