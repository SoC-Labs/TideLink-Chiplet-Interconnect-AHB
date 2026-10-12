#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# Selftest for kr260_eth_bringup.py step 3a (LL-bootstrap guard) and step 6
# (--traffic-check). Drives the REAL bringup() against a fake backdoor on a
# virtual clock; no /dev/mem, no HW. Run: python3 test_kr260_eth_bringup_guard.py
#
# Each case scripts SWI_LANE_STATUS as a function of virtual time since the
# step-3 training<-0 write and records every WL_LINK_ENABLE_RESET write.
# The last guard case DEFEATS the guard and requires the bootstrap to be seen
# landing on the live link: without it, "no LL writes" could pass vacuously.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import contextlib
import importlib
import io
import os
import signal
import sys
import time as _time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kr260_eth_bringup as kb  # noqa: E402
import kr260_eth_xfer as xfer   # noqa: E402

REAL_TIME, REAL_SLEEP = _time.time, _time.sleep
LL_ALL = [0x00027F08, 0x00027F07]       # swreset ON, ENABLE - no 0x27F00 (B19)
ALL_LL_WRITES = []                        # every WL_LINK_ENABLE_RESET write, all cases


class Clock:
    def __init__(self):
        self.t = 0.0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s


def st_word(cal, fcsm):
    return (cal << 16) | (fcsm << 17)


class FakeBD:
    """status_after(dt) -> (cal_done, fcsm); dt = virtual s since training<-0."""
    def __init__(self, m, clock, status_after, arm_on_enable=False):
        self.m, self.c, self.f = m, clock, status_after
        self.writes, self.t_rel, self.enabled = [], None, False
        self.arm = arm_on_enable

    def rd(self, off):
        m = self.m
        if off == m.REG_ROLE_STATUS:
            return 0x3
        if off == m.REG_WINSCAN_STAT:
            return 1 << 6
        if off == m.REG_EPOCH_STATUS:
            return 1
        if off == m.REG_SWI_LANE_STATUS:
            if self.t_rel is None:
                return st_word(0, 1)
            if self.arm and self.enabled:
                return st_word(1, 4)
            return st_word(*self.f(self.c.t - self.t_rel))
        return 1 << 16                     # FC SM_CONTROL: disable_crc=1 (shipping)

    def wr(self, off, val):
        self.writes.append((off, val))
        if off == self.m.REG_SWI_TRAINING_MODE and val == 0:
            self.t_rel = self.c.t
        if off == self.m.REG_WL_LINK_ENABLE_RESET and val == LL_ALL[-1]:
            self.enabled = True


def run(status_after, patch=None, arm=False, **kw):
    m = importlib.reload(kb)
    if patch:
        patch(m)
    c = Clock()
    m.time.time, m.time.sleep = c.time, c.sleep
    bd = FakeBD(m, c, status_after, arm_on_enable=arm)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = m.bringup(bd, "die_b", 20.0, 10.0, **kw)
    finally:
        _time.time, _time.sleep = REAL_TIME, REAL_SLEEP
    ll = [v for (o, v) in bd.writes if o == m.REG_WL_LINK_ENABLE_RESET]
    ALL_LL_WRITES.extend(ll)
    return rc, ll, out.getvalue()


RESULTS = []


def check(name, got, want):
    ok = got == want
    RESULTS.append(ok)
    print("%-4s %s  (got %s)" % ("PASS" if ok else "FAIL", name, got))


def main():
    v2 = lambda dt: (1, 4) if dt >= 11e-6 else (0, 1)      # V2: live ~11 us after release
    _, ll, out = run(v2)
    check("V2 link self-trains -> no LL writes", ll, [])
    check("... and the output says the bootstrap was SKIPPED", "SKIPPED" in out, True)

    _, ll, _ = run(lambda dt: (1, 6) if dt < 0.1 else (1, 4))
    check("first reads land on SEND_ACK(6) on a live link -> no LL writes", ll, [])

    _, ll, _ = run(lambda dt: (1, 4) if dt >= 0.3 else (0, 1))
    check("link comes up 300 ms after release, inside --ll-settle -> no LL writes", ll, [])

    rc, ll, _ = run(lambda dt: (1, 1), arm=True)
    check("link never self-trains -> bootstrap ON/ENABLE, in order", ll, LL_ALL)
    check("... and step 4 then reports LINK UP (rc 0)", rc, 0)

    _, ll, _ = run(lambda dt: (1, 7), arm=True)
    check("parked in SEND_NACK(7) -> bootstrap runs (it is the recovery)", ll, LL_ALL)

    gave_up = {"v": False}

    def wrap_wait(m):
        real = m.wait_link_live

        def wrapped(bd, settle_s, poll_s=0.01):
            live, st, w = real(bd, settle_s, poll_s)
            gave_up["v"] = gave_up["v"] or not live
            return live, st, w
        m.wait_link_live = wrapped
    _, ll, out = run(lambda dt: (1, 4) if gave_up["v"] else (1, 1), patch=wrap_wait)
    check("live only at the pre-write re-read -> no LL writes", ll, [])
    check("... via the re-read branch", "went live at the last moment" in out, True)

    def defeat(m):
        m.link_live = lambda st: False
    _, ll, _ = run(v2, patch=defeat)
    check("DISCRIMINATION: guard defeated -> bootstrap lands on the live link", ll, LL_ALL)

    # B19: no write to WL_LINK_ENABLE_RESET may land with swi_enable (bit0) clear.
    # The HARDEN shim forces bit0 only when bit3 (swreset) is set, so a write is
    # safe iff bit0 or bit3 is set. Read across EVERY case above, including the
    # guard-defeated one, where the bootstrap lands on a live link.
    dips = ["0x%08x" % v for v in ALL_LL_WRITES if not (v & 0x1) and not (v & 0x8)]
    check("B19: no WL_LINK_ENABLE_RESET write drops swi_enable (bit0=0, bit3=0)", dips, [])
    check("... and the rule was exercised (bootstrap writes were seen)",
          len(ALL_LL_WRITES) >= 2 * len(LL_ALL), True)

    # step 6: traffic_check() reports the forked child's fate
    def fake_xfer(mode):
        mem = {"v": 0xDEADBEEF}
        xfer.program_cam = lambda enable: None

        def wr(phys, val):
            if mode == "sigbus":
                os.kill(os.getpid(), signal.SIGBUS)
            if mode != "drop":
                mem["v"] = val
        xfer.wr = wr
        xfer.rd = lambda phys: 0x7E5A11C3 if mode == "stale" else mem["v"]
    m = importlib.reload(kb)
    for mode, want in (("ok", True), ("drop", False), ("stale", False), ("sigbus", False)):
        fake_xfer(mode)
        with contextlib.redirect_stdout(io.StringIO()):
            ok, msg = m.traffic_check(0x400000000, timeout_s=5)
        check("traffic_check %-6s -> %-4s [%s]" % (mode, "PASS" if want else "FAIL", msg[:48]),
              ok, want)

    print("\n%d/%d PASS" % (sum(RESULTS), len(RESULTS)))
    return 0 if all(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
