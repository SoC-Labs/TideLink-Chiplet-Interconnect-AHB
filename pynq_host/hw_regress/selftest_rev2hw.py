#!/usr/bin/env python3
"""selftest_rev2hw.py - run on the BUILD HOST (no /dev/mem, no board): drives rev2hw.py's check logic against a
simulated register model and shows each check PASSES on a healthy model and FAILS (or is INCONCLUSIVE) on a
broken one.  This is the evidence that the hardware checks cannot pass vacuously.

  python3 selftest_rev2hw.py          exit 0 only if every case behaves as listed in CASES

Also exercises the shared injector controls (injector_controls.py): the 0x003C alias is refused before any
write, a slave-die injector only works with the debug unlock raised and is relocked on every exit path, a
phantom counter move under a wrong-DataID arm fails the inert control, a dead counter is never a pass.
"""
import io, os, re, sys, time, contextlib, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
_RAW = open(os.path.join(HERE, "rev2hw.py")).read()
SRC = _RAW.replace('_fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)', "_fd = None")
assert SRC != _RAW, "selftest could not neutralise the /dev/mem open in rev2hw.py (the source changed): fix the selftest"

APB = {"a": 0x84030000, "b": 0x8C030000}
TX = {"a": 0xA4000000, "b": 0xAC000000}
FIFO = {"a": 0xA4010000, "b": 0xAC010000}
SUB_A = 0x80000000


class Model:
    """Two dies. Knobs let a case break one thing."""
    def __init__(self, **k):
        self.k = dict(inj_works=True, inj_holds=True, crc_on=True, silent_corrupt=False, beacon="a7", mem_drop=None,
                      beacon_done=False, link_up=True, wrong_id_hits=False, status_stuck=False, replay="ok",
                      stream="ok", avail_delay_polls=0, fifo_flood=False, regf_fault_after_tx=False,
                      slave_ro=False, phantom_crc_armed=False, crc_dead=False, gap_noise=False)
        self.k.update(k)
        self.r = {}
        self.txbuf = {"a": [], "b": []}
        self.q = {"a": [], "b": []}          # RX queues
        self.crc = {"a": 0, "b": 0}
        self.armed = {"a": False, "b": False}
        self.prev_enable = {"a": 0, "b": 0}
        self.beacon_run = {"a": not self.k["beacon_done"], "b": not self.k["beacon_done"]}
        self.beacon_done = {"a": self.k["beacon_done"], "b": self.k["beacon_done"]}
        self.sub = {}
        self.readcnt = {"a": 0, "b": 0}
        self.nhit = 0
        self.wedged = {"a": False, "b": False}
        self.polls = {"a": 0, "b": 0}
        self.sent_any = False
        self.unlock_b = 0
        self.unlock_log = []          # every write to die_b's debug-unlock GPIO
        self.blocked_writes = 0       # slave-die 0x23C writes dropped for lack of the unlock

    def die_of(self, a):
        for d in "ab":
            if APB[d] <= a < APB[d] + 0x8000: return d, a - APB[d]
        return None, None

    def rd(self, a):
        d, o = self.die_of(a)
        if d:
            if o == 0x2108: return ((4 if self.k["link_up"] else 0) << 17) | (1 << 16)
            if o == 0x23C: return self.r.get(a, 0) if self.k["inj_holds"] else 0
            if o == 0x21F4:
                run, done = self.beacon_run[d], self.beacon_done[d]
                return (1 << 23) | (1 << 20) | (1 << 19) | (int(run) << 18) | (int(done) << 17) | (1 << 16) | 0x100
            if o == 0x1704: return 0xA1
            if o == 0x1714: return 0 if self.k["crc_on"] else 0x10708
            if o == 0x1720: return 0 if self.k["crc_dead"] else self.crc[d]
            if o == 0x200C: return 4096
            if o == 0x2010:
                if not self.q[d]: return 0
                self.polls[d] += 1
                return (1 << 4) if self.polls[d] > self.k["avail_delay_polls"] else 0
            if o == 0x1708: return 1
            if o == 0x1710:
                if self.k["fifo_flood"] and self.sent_any: return 0x10 | 0x02    # almost-full + full: a NACK flood the node cannot drain
                return 0x9 if self.sent_any else 0x9                              # empty + almost-empty (ACK traffic only)
            if o == 0x21E0: return (0xAD << 24) | (1 << 23) | (0x400 if (self.k["regf_fault_after_tx"] and self.sent_any) else 0)
            if o == 0x21F8: return (0xB5 << 24) | 0x1
            return self.r.get(a, 0)
        for d in "ab":
            if FIFO[d] <= a < FIFO[d] + 0x10000:
                off = (a - FIFO[d]) // 4
                if not self.q[d]: return 0
                pk = self.q[d][0]; v = pk[off] if off < len(pk) else 0
                if off == len(pk) - 1: self.q[d].pop(0)
                return v
        if SUB_A <= a < SUB_A + 0x1000: return self.sub.get(a, 0)
        return 0

    def wr(self, a, v):
        if a == 0x8C041000:
            self.unlock_b = v & 1; self.unlock_log.append(v & 1); return
        d, o = self.die_of(a)
        if d:
            if o == 0x23C:
                if d == "b" and self.k["slave_ro"] and not self.unlock_b:
                    self.blocked_writes += 1; return          # slave die: external APB read-only without the unlock
                en = (v >> 24) & 1
                if self.k["inj_works"] and en and not self.prev_enable[d]:
                    self.armed[d] = (v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 7)
                self.prev_enable[d] = en
            self.r[a] = v; return
        for d in "ab":
            if TX[d] <= a < TX[d] + 0x10000:
                self.txbuf[d].append(v)
                if len(self.txbuf[d]) == ((self.txbuf[d][0] >> 20) & 0xFFF) + 2:
                    pk, self.txbuf[d] = self.txbuf[d], []
                    rx = "b" if d == "a" else "a"
                    arm = self.armed[d]
                    self.sent_any = True
                    if self.wedged[rx]: return
                    if not arm:
                        sm = self.k["stream"]
                        if len(pk) > 4 and sm != "ok":                                   # stream-start misbehaviour (only for long packets)
                            if sm == "lose": return
                            if sm == "dup": self.q[rx].append(pk); self.q[rx].append(list(pk)); self.polls[rx] = 0; return
                            if sm == "short": self.q[rx].append(pk[:-3] + [0, 0, 0]); self.polls[rx] = 0; return
                            if sm == "corrupt": bad = list(pk); bad[9] ^= 0x100; self.q[rx].append(bad); self.polls[rx] = 0; return
                    if self.k["gap_noise"] and not arm and (pk[2] >> 20) & 0xF == 0xF:
                        self.crc[rx] += 1                                                # counter moves OUTSIDE any shot (liveness packet)
                    if arm and self.k["phantom_crc_armed"] and arm[0] != 0xA1:
                        self.crc[rx] += 1                                                # the counter lies under a wrong-DataID arm
                    hit = arm and (arm[0] == 0xA1 or (self.k["wrong_id_hits"] and arm[0] == 0x7E)) and arm[1] >= 5
                    if arm and arm[0] == 0xA1 and arm[1] < 5: hit = False          # ECC-protected header byte: inert
                    if hit:
                        self.armed[d] = False
                        if self.k["silent_corrupt"]:
                            bad = list(pk); bad[2] ^= 1 << arm[2]; self.q[rx].append(bad)    # delivered wrong, no CRC count
                        elif self.k["crc_on"]:
                            if not self.k["crc_dead"]: self.crc[rx] += 1
                            self.nhit += 1; m = self.k["replay"]           # detected, NACK, replay -> good copy
                            if m == "ok": self.q[rx].append(pk)
                            elif m == "lose": pass                                            # replay never delivers (the bug)
                            elif m == "lose_odd":
                                if self.nhit % 2: pass
                                else: self.q[rx].append(pk)
                            elif m == "dup": self.q[rx].append(pk); self.q[rx].append(list(pk))
                            elif m == "stray":
                                bad = list(pk); bad[2] ^= 1 << arm[2]; self.q[rx].append(bad)
                            elif m == "wedge": self.wedged[rx] = True
                        else:
                            bad = list(pk); bad[2] ^= 1 << arm[2]; self.q[rx].append(bad)
                    else:
                        self.q[rx].append(pk)
                    self.polls[rx] = 0
                return
        if SUB_A <= a < SUB_A + 0x1000:
            if self.k["mem_drop"] == (a - SUB_A) // 4: pass                                   # a word lost
            else: self.sub[a] = v
            if self.k["beacon"] == "a7":
                for dd in "ab": self.beacon_run[dd] = False; self.beacon_done[dd] = True      # A7: AXI traffic stops the beacon
            return


def load(model, overrides=None):
    ns = {"__name__": "rev2hw_sim", "__file__": os.path.join(HERE, "rev2hw.py")}
    exec(compile(SRC, "rev2hw.py", "exec"), ns)
    ns["rd"], ns["wr"] = model.rd, model.wr
    clk = [1000.0]                         # virtual clock: sleeps advance it, so 3 s collect windows cost no real time
    def _sleep(s): clk[0] += s
    ns["time"] = types.SimpleNamespace(time=lambda: clk[0], sleep=_sleep, strftime=time.strftime)
    ns.update(overrides or {})
    return ns


def run(model, fn, overrides=None, **kw):
    ns = load(model, overrides)
    args = types.SimpleNamespace(**kw)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = ns[fn](args)
    out = buf.getvalue()
    return rc, out


CASES = [
    # (name, knobs, fn, kwargs, rc[, required output substring])
    ("stats a2b: replay ok -> no loss",            {}, "cmd_crc_stats", dict(dir="a2b", n=30), 0, "STATS_RESULT=NO_LOSS_OBSERVED"),
    ("stats b2a: replay ok -> no loss",            {}, "cmd_crc_stats", dict(dir="b2a", n=30), 0, "STATS_RESULT=NO_LOSS_OBSERVED"),
    ("stats: replay lost every time (the bug)",    dict(replay="lose"), "cmd_crc_stats", dict(dir="a2b", n=30), 0, "BUG_REPRODUCED"),
    ("stats: replay lost every 2nd (rate ~50%)",   dict(replay="lose_odd"), "cmd_crc_stats", dict(dir="b2a", n=30), 0, "P(lost | detected)  = 13/26"),
    ("stats: duplicate delivery counted DUP",      dict(replay="dup"), "cmd_crc_stats", dict(dir="a2b", n=16), 0, "DUP 14"),
    ("stats: wrong data counted STRAY",            dict(replay="stray"), "cmd_crc_stats", dict(dir="a2b", n=16), 0, "STRAY/WRONG 14"),
    ("stats: node wedges after a loss -> stop",    dict(replay="wedge"), "cmd_crc_stats", dict(dir="a2b", n=30), 1, "STATS_RESULT=LINK_DEGRADED"),
    ("stats: silent corruption counted undetected", dict(silent_corrupt=True), "cmd_crc_stats", dict(dir="a2b", n=16), 1, "STATS_RESULT=UNDETECTED_BAD"),
    ("stats: injector never reaches TX -> inconclusive", dict(inj_works=False), "cmd_crc_stats", dict(dir="a2b", n=16), 4, "STATS_RESULT=INCONCLUSIVE"),
    ("stats: injector register does not hold",     dict(inj_holds=False), "cmd_crc_stats", dict(dir="a2b", n=8), 1, ""),
    ("stats: receiver CRC check OFF",              dict(crc_on=False), "cmd_crc_stats", dict(dir="a2b", n=8), 1, ""),
    ("stats: link down",                           dict(link_up=False), "cmd_crc_stats", dict(dir="a2b", n=8), 1, ""),
    ("stats: n above the hard cap rejected",       {}, "cmd_crc_stats", dict(dir="a2b", n=65), 1, ""),
    # EXPECT_FIXED acceptance semantics
    ("fixed: replay ok -> FIXED_PASS",             {}, "cmd_crc_stats", dict(dir="a2b", n=30, expect_fixed=True), 0, "STATS_RESULT=FIXED_PASS exact=26 detected=26"),
    ("fixed b2a: replay ok -> FIXED_PASS",         {}, "cmd_crc_stats", dict(dir="b2a", n=30, expect_fixed=True), 0, "Wilson95 lower bound 87.1%"),
    ("fixed: lose every time (unfixed image) -> FAIL", dict(replay="lose"), "cmd_crc_stats", dict(dir="a2b", n=30, expect_fixed=True), 1, "STATS_RESULT=FIXED_FAIL"),
    ("fixed: lose every 2nd -> FAIL",              dict(replay="lose_odd"), "cmd_crc_stats", dict(dir="b2a", n=30, expect_fixed=True), 1, "13 lost"),
    ("fixed: duplicate delivery -> FAIL",          dict(replay="dup"), "cmd_crc_stats", dict(dir="a2b", n=16, expect_fixed=True), 1, "duplicated"),
    ("fixed: wrong data -> FAIL",                  dict(replay="stray"), "cmd_crc_stats", dict(dir="a2b", n=16, expect_fixed=True), 1, "stray/wrong"),
    ("fixed: silent corruption still ERROR",       dict(silent_corrupt=True), "cmd_crc_stats", dict(dir="a2b", n=16, expect_fixed=True), 1, "STATS_RESULT=UNDETECTED_BAD"),
    ("fixed: no detected shot -> inconclusive",    dict(inj_works=False), "cmd_crc_stats", dict(dir="a2b", n=16, expect_fixed=True), 4, "STATS_RESULT=INCONCLUSIVE"),
    ("fixed: node wedge still LINK_DEGRADED",      dict(replay="wedge"), "cmd_crc_stats", dict(dir="a2b", n=30, expect_fixed=True), 1, "STATS_RESULT=LINK_DEGRADED"),
    # stream-start / storm observation
    ("stream a2b healthy -> no storm",             {}, "cmd_stream", dict(dir="a2b", n=4, len=28, gap=0.3), 0, "STREAM_RESULT=NO_STORM_OBSERVED exact=4/4"),
    ("stream b2a healthy -> no storm",             {}, "cmd_stream", dict(dir="b2a", n=4, len=28, gap=0.3), 0, "STREAM_RESULT=NO_STORM_OBSERVED"),
    ("stream: stream lost -> storm suspect",       dict(stream="lose"), "cmd_stream", dict(dir="b2a", n=4, len=28, gap=0.3), 1, "STREAM_RESULT=STORM_SUSPECT"),
    ("stream: duplicated -> storm suspect",        dict(stream="dup"), "cmd_stream", dict(dir="b2a", n=4, len=28, gap=0.3), 1, "DUP"),
    ("stream: truncated/zeroed tail -> suspect",   dict(stream="short"), "cmd_stream", dict(dir="a2b", n=4, len=28, gap=0.3), 1, "STRAY/SHORT"),
    ("stream: one wrong word -> suspect",          dict(stream="corrupt"), "cmd_stream", dict(dir="a2b", n=4, len=28, gap=0.3), 1, "STRAY/SHORT"),
    ("stream: slow delivery (storm latency)",      dict(avail_delay_polls=2000), "cmd_stream", dict(dir="b2a", n=4, len=28, gap=0.3), 1, "SLOW"),
    ("stream: Ack/Nack FIFO flooded",              dict(fifo_flood=True), "cmd_stream", dict(dir="b2a", n=4, len=28, gap=0.3), 1, "ACKNACK_FIFO_FULL"),
    ("stream: Region F fault appears",             dict(regf_fault_after_tx=True), "cmd_stream", dict(dir="a2b", n=4, len=28, gap=0.3), 1, "new fault bits"),
    ("stream: receiver CRC check OFF -> invalid",  dict(crc_on=False), "cmd_stream", dict(dir="a2b", n=4, len=28, gap=0.3), 1, ""),
    ("stream: link down",                          dict(link_up=False), "cmd_stream", dict(dir="a2b", n=4, len=28, gap=0.3), 1, ""),
    ("stream: n above cap rejected",               {}, "cmd_stream", dict(dir="a2b", n=17, len=28, gap=0.3), 1, ""),
    ("stream: len 2 (old packet size) still ok",   {}, "cmd_stream", dict(dir="a2b", n=2, len=2, gap=0.3), 0, "NO_STORM_OBSERVED"),
    # (name, model knobs, function, kwargs, expected rc)
    ("sweep a2b healthy",                          {}, "cmd_crc_sweep", dict(dir="a2b", n=7), 0),
    ("sweep b2a healthy",                          {}, "cmd_crc_sweep", dict(dir="b2a", n=7), 0),
    ("sweep: injector register does not hold",     dict(inj_holds=False), "cmd_crc_sweep", dict(dir="a2b", n=7), 1),
    ("sweep: arm never reaches the TX (no effect)", dict(inj_works=False), "cmd_crc_sweep", dict(dir="a2b", n=7), 1),
    ("sweep: silent corruption (no CRC count)",    dict(silent_corrupt=True), "cmd_crc_sweep", dict(dir="a2b", n=7), 1),
    ("sweep: receiver CRC check OFF",              dict(crc_on=False), "cmd_crc_sweep", dict(dir="a2b", n=7), 1),
    ("ctl healthy a2b",                            {}, "cmd_crc_ctl", dict(dir="a2b"), 0),
    ("ctl: injector not selective (hits 0x7E)",    dict(wrong_id_hits=True), "cmd_crc_ctl", dict(dir="a2b"), 1),
    ("a7window healthy (stops on AXI, data exact)", {}, "cmd_a7window", dict(), 0),
    ("a7window: beacon never stops (pre-A7 RTL)",  dict(beacon="old"), "cmd_a7window", dict(), 1),
    ("a7window: a word lost through the window",   dict(mem_drop=5), "cmd_a7window", dict(), 1),
    ("a7window: beacon already done",              dict(beacon_done=True), "cmd_a7window", dict(), 4),
    ("a7window: link down",                        dict(link_up=False), "cmd_a7window", dict(), 1),
    ("regs healthy",                               {}, "cmd_regs", dict(), 0),
    ("regs: sideband CRC check OFF",               dict(crc_on=False), "cmd_regs", dict(), 1),
    # --- shared injector controls (injector_controls.py): each one must be able to FAIL ---------------
    ("sweep: 0x003C alias refused, nothing written", {}, "cmd_crc_sweep", dict(dir="a2b", n=7), 1, "HARNESS_BROKEN",
        dict(ERRINJ=0x003C), lambda m: not any((a & 0x7FFF) == 0x3C for a in m.r)),
    ("stats: 0x003C alias refused",                {}, "cmd_crc_stats", dict(dir="a2b", n=8), 1, "unmapped alias", dict(ERRINJ=0x003C)),
    ("ctl: 0x003C alias refused",                  {}, "cmd_crc_ctl", dict(dir="a2b"), 1, "HARNESS_BROKEN", dict(ERRINJ=0x003C)),
    ("errprobe: 0x003C alias refused",             {}, "cmd_errprobe", dict(), 1, "HARNESS_BROKEN", dict(ERRINJ=0x003C)),
    ("ctl: a wrong offset that is not an alias",   {}, "cmd_crc_ctl", dict(dir="a2b"), 1, "!= RDL", dict(ERRINJ=0x0240)),
    ("sweep b2a: slave-die RO APB works only with the unlock; relocked", dict(slave_ro=True), "cmd_crc_sweep", dict(dir="b2a", n=7), 0, "",
        {}, lambda m: m.unlock_b == 0 and m.blocked_writes == 0 and 1 in m.unlock_log),
    ("sweep b2a: unlock never raised -> arm does not hold -> FAIL", dict(slave_ro=True), "cmd_crc_sweep", dict(dir="b2a", n=7), 1, "",
        dict(_unlock=lambda path, on: None), lambda m: m.blocked_writes > 0),
    ("ctl b2a: slave-die ctl passes and relocks",  dict(slave_ro=True), "cmd_crc_ctl", dict(dir="b2a"), 0, "",
        {}, lambda m: m.unlock_b == 0 and m.blocked_writes == 0),
    ("stats b2a: failed arm never leaves die_b unlocked", dict(inj_holds=False), "cmd_crc_stats", dict(dir="b2a", n=8), 1, "",
        {}, lambda m: m.unlock_b == 0),
    ("ctl: counter moves under a wrong-DataID arm", dict(phantom_crc_armed=True), "cmd_crc_ctl", dict(dir="a2b"), 1, "not selective"),
    ("stats: counter moves between shots (C-COUNT-EXPECT)", dict(gap_noise=True), "cmd_crc_stats", dict(dir="a2b", n=8), 1, "STATS_RESULT=COUNT_MISMATCH"),
    ("sweep: CRC counter dead (reads 0) is never a pass", dict(crc_dead=True), "cmd_crc_sweep", dict(dir="a2b", n=7), 1),
    ("stats: CRC counter dead -> inconclusive, not pass", dict(crc_dead=True), "cmd_crc_stats", dict(dir="a2b", n=8), 4, "STATS_RESULT=INCONCLUSIVE"),
]


def main():
    bad = 0
    for case in CASES:
        name, knobs, fn, kw, want = case[:5]
        need = case[5] if len(case) > 5 else ""
        overrides = case[6] if len(case) > 6 else None
        post = case[7] if len(case) > 7 else None
        m = Model(**knobs)
        rc, out = run(m, fn, overrides, **kw)
        ok = rc == want and need in out and (post is None or bool(post(m)))
        bad += not ok
        last = [l for l in out.splitlines() if l.startswith("VERDICT")]
        print("%-4s %-46s rc=%d (expected %d)  %s" % ("ok" if ok else "BAD", name, rc, want, (last[-1][:110] if last else "")))
        if not ok:
            print(out[-1200:])
    print("SELFTEST_RESULT=%s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
