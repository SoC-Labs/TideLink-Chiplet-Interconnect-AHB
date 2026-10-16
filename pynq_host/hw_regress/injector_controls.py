#!/usr/bin/env python3
"""injector_controls.py - must-fail controls for the Wlink LINK_ERROR_INJECTION injector (APB 0x23C).

ONE implementation of the injector's instrument checks, used by every injection test:
  * the KR260 board tool      pynq_host/hw_regress/rev2hw.py          (synchronous, /dev/mem)
  * the cocotb simulations    cocotb/common/injector_ctl_cocotb.py     (async APB)
  * their offline selftests   pynq_host/hw_regress/selftest_rev2hw.py, scripts/ci/tests/test_injector_controls.py

WHY (docs/ERROR_INJECTION_FINDINGS.md, TL-059 evidence audit 2026-10-14): a host tool wrote the
UNMAPPED alias 0x003C instead of 0x23C.  A write to an unmapped APB address is silently dropped, the
CRC counter of an untouched design reads 0, and "0 errors, all exact" looks like a PASS.  Nothing
required that arming the injector make anything happen.  Every "no effect observed" result is
vacuous unless the harness shows it CAN produce an effect.  The controls here make that mechanical:

  C-REG-ADDR     the injector offset IS the RDL address (0x23C), never the 0x003C alias; checked before
                 a single write is issued (ControlError = HARNESS_BROKEN).
  C-REG-HOLD     0x23C reads 0 before an arm, and reads back exactly what was armed (it is a holding
                 register, so a write that did not land is detected, including the slave-die
                 read-only-APB case below).
  C-INJ-INERT    armed for a DataID nobody uses: counters unchanged, data exact, disarm clean.
  C-INJ-LIVE     armed for the right DataID: the receiver's counter moves.  A shot that the injector
                 FIRED (sim: observable) with no counter movement is an ERROR; a counter that moved
                 with no shot fired is an ERROR too (the instrument lies in both directions).
  C-COUNT-EXPECT shots fired == counter increments over the whole run (no silently eaten shot, no
                 counter motion outside a shot).

Slave-die debug unlock: on kr260-pair-onchip die_b is the SLAVE and axi_chiplet_controller makes
external APB READ-ONLY on a slave unless apb_debug_unlock_i is high (writes silently dropped; proven on
HW 2026-10-14).  `Injector(unlock=fn)` raises the unlock only while the injector is armed and ALWAYS
restores it (context manager, exception safe); a failed arm never leaves the die unlocked.

Pure Python 3, no hardware, no cocotb import: safe on the board, the build host and in a simulator.
"""
import contextlib
import time

ERRINJ_OFFSET = 0x023C           # unified APB offset of link_error_injection (src/rdl/wlink_regs.rdl)
ENABLE_BIT = 1 << 24             # [24] enable; the 0->1 edge arms ONE shot

# Offsets that look like the injector but are NOT mapped (writes silently dropped).  Extend, never trim.
UNMAPPED_ALIASES = {
    0x003C: "absolute 0x3C is unmapped in the Wlink PHY region (0x00-0x0C); LINK_ERROR_INJECTION is 0x23C. "
            "Writes there are dropped and an untouched design reads 0 errors (TL-038 evidence, invalid).",
}


class ControlError(Exception):
    """The harness itself is broken (HARNESS_BROKEN): nothing measured with it is evidence."""


def arm_value(did, byte, bit):
    return ENABLE_BIT | ((bit & 7) << 16) | ((byte & 0xFF) << 8) | (did & 0xFF)


def assert_injector_offset(offset):
    """C-REG-ADDR.  Raise ControlError unless `offset` is exactly the RDL injector offset."""
    if offset in UNMAPPED_ALIASES:
        raise ControlError("injector offset 0x%04x is an unmapped alias: %s" % (offset, UNMAPPED_ALIASES[offset]))
    if offset != ERRINJ_OFFSET:
        raise ControlError("injector offset 0x%04x != RDL link_error_injection 0x%04x" % (offset, ERRINJ_OFFSET))


# ---------------------------------------------------------------------------------------------
# Pure evaluators (shared by the sync and the async drivers: the SAME decision text everywhere)
# ---------------------------------------------------------------------------------------------
def hold_ok(wrote, readbacks):
    """C-REG-HOLD.  `readbacks` is the sequence of reads after the write (the register may settle
    through a CDC); it holds iff the LAST read equals what was written."""
    return bool(readbacks) and readbacks[-1] == wrote


def shot_errors(fired, crc_delta, want_hits=1, expect_crc=None, tx_pkts=None):
    """C-INJ-LIVE for an observable injector (simulation: `fired` = shots the injector actually fired).
    Returns the list of violated-invariant strings (empty == the instrument proved itself)."""
    want_crc = fired if expect_crc is None else expect_crc
    errs = []
    if fired != want_hits:
        errs.append("ERROR shot: injector fired %sx, wanted %s (tx pkts %s); vacuous" % (fired, want_hits, tx_pkts))
    if crc_delta != want_crc:
        errs.append("ERROR detect: fired %s but CRC counter +%s (wanted +%s); vacuous" % (fired, crc_delta, want_crc))
    return errs


def classify_board_shot(crc_delta, data_exact):
    """C-INJ-LIVE on the board, where `fired` is not observable (no fired counter in the RTL).
    EFFECTIVE: counter +1 and the data is exact.  INERT: counter +0 and data exact (the corrupted byte
    is not covered by the CRC or not in this packet; counted, never a pass by itself).  Anything else
    (counter moved by != 1, or data wrong with the counter quiet) is FAIL."""
    if data_exact and crc_delta == 1:
        return "EFFECTIVE"
    if data_exact and crc_delta == 0:
        return "INERT"
    return "FAIL"


def wrong_id_errors(bad, counters_unchanged, disarmed):
    """C-INJ-INERT.  A wrong-DataID arm must change nothing."""
    errs = []
    if bad:
        errs.append("a wrong-DataID arm corrupted %d packet(s): the injector is not selective" % bad)
    if not counters_unchanged:
        errs.append("a wrong-DataID arm moved a CRC counter: the injector is not selective")
    if not disarmed:
        errs.append("disarm did not read back 0")
    return errs


class ShotLedger:
    """C-COUNT-EXPECT.  Record every shot; `errors()` must be empty or the run is not evidence.

    add(fired, delta): `fired` is the injector's shot count for this shot (sim) or None when it is not
    observable (board); `delta` is the receiver counter movement caused by it.
    finish(total_delta): the receiver counter movement over the WHOLE run, including the gaps between
    shots; it must equal the sum of the per-shot movements (otherwise something other than the
    shots moved the counter, or a shot's count was eaten)."""

    def __init__(self):
        self.rows = []

    def add(self, fired, delta, label=""):
        self.rows.append((fired, delta, label))

    def errors(self, total_delta=None, expect_each=None):
        errs = []
        for fired, delta, label in self.rows:
            if fired is not None and fired == 0 and delta:
                errs.append("%s: counter moved +%s with NO shot fired (the counter lies)" % (label or "shot", delta))
            if fired is not None and expect_each is not None and fired and delta != expect_each:
                errs.append("%s: %s shot(s) fired but counter +%s (a silently eaten shot)" % (label or "shot", fired, delta))
        if total_delta is not None:
            s = sum(r[1] for r in self.rows)
            if total_delta != s:
                errs.append("counter moved +%s over the run but the shots account for +%s: motion outside a shot "
                            "or a shot not counted" % (total_delta, s))
        return errs


class ArmResult:
    """status: OK / NOT_ZERO (register not 0 before the arm) / NO_HOLD (read back != written)."""

    def __init__(self, status, value, seen=None):
        self.status, self.value, self.seen = status, value, seen or []

    @property
    def ok(self):
        return self.status == "OK"

    def __bool__(self):
        return self.ok

    def why(self):
        return {"OK": "armed", "NOT_ZERO": "0x23C not zero before arm",
                "NO_HOLD": "0x23C did not hold the armed value"}[self.status]


# ---------------------------------------------------------------------------------------------
# Synchronous driver (board)
# ---------------------------------------------------------------------------------------------
class Injector:
    """Synchronous injector driver: Injector(rd, wr, base, offset=ERRINJ_OFFSET, unlock=fn).

    rd(addr)->int, wr(addr, val).  `unlock(on: bool)` is the slave-die debug unlock (None = not needed).
    Raises ControlError at construction if `offset` is not the RDL injector offset."""

    def __init__(self, rd, wr, base, offset=ERRINJ_OFFSET, unlock=None, sleep=time.sleep, log=None,
                 settle=0.005, slow=(0.05, 0.5)):
        assert_injector_offset(offset)
        self.rd, self.wr, self.addr = rd, wr, base + offset
        self.unlock, self.sleep, self.log = unlock, sleep, log or (lambda *_a: None)
        self.settle, self.slow = settle, slow

    def _unlock(self, on):
        if self.unlock is not None:
            self.unlock(on)

    def arm(self, did, byte, bit):
        """C-REG-HOLD around an arm.  On any failure the unlock is dropped again."""
        r = self._arm(did, byte, bit)
        if not r.ok:
            self._unlock(False)            # failed arm: never leave the slave die unlocked
        return r

    def _arm(self, did, byte, bit):
        a = self.addr
        self._unlock(True)
        self.wr(a, 0); self.sleep(self.settle)
        if self.rd(a) != 0:
            return ArmResult("NOT_ZERO", None)
        val = arm_value(did, byte, bit)
        self.wr(a, val); self.sleep(self.settle)
        seen = [self.rd(a)]
        if seen[0] != val:
            # 2026-10-13: die_b's 0x23C failed this check and the value was thrown away.  Record what it
            # actually reads, and whether it settles (CDC into the link clock) before calling it a failure.
            for dt in self.slow:
                self.sleep(dt); seen.append(self.rd(a))
            self.log("  arm 0x%08x wrote 0x%08x; read %s" % (a, val, ", ".join("0x%08x" % s for s in seen)))
        return ArmResult("OK" if hold_ok(val, seen) else "NO_HOLD", val, seen)

    def disarm(self):
        self.wr(self.addr, 0); self.sleep(self.settle)
        ok = self.rd(self.addr) == 0
        self._unlock(False)
        return ok

    @contextlib.contextmanager
    def armed(self, did, byte, bit):
        """with inj.armed(did, byte, bit) as r: ...   Disarms and relocks on every exit path."""
        r = self.arm(did, byte, bit)
        try:
            yield r
        finally:
            if r.ok:
                self.disarm()

    def reads_zero(self):
        return self.rd(self.addr) == 0


def run_wrong_id_control(inj, drive, counters, did=0x7E, byte=5, bit=0):
    """C-INJ-INERT, synchronous.  `drive()` sends the control packets and returns how many were NOT
    delivered exactly; `counters()` returns a comparable snapshot of the receiver CRC counters.
    Returns (errors, info) with info = dict(armed=ArmResult, bad=int, unchanged=bool, disarmed=bool)."""
    c1 = counters()
    r = inj.arm(did, byte, bit)
    if not r.ok:
        return ["injector %s (wrong-DataID control cannot run)" % r.why()], dict(armed=r)
    bad = drive()
    dis = inj.disarm()
    unchanged = counters() == c1
    return wrong_id_errors(bad, unchanged, dis), dict(armed=r, bad=bad, unchanged=unchanged, disarmed=dis)
