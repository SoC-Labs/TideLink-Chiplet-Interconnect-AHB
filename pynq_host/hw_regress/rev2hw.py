#!/usr/bin/env python3
"""rev2hw.py - extra hardware checks for the rev-2 compute-port image (kr260-pair-onchip). Runs ON the
board as root (/dev/mem).  Staged by hw_test.sh to ~/td/rev2hw/.  Contains no credentials.

  rev2hw.py regs                      read-only register preflight (every register the other commands use)
  rev2hw.py a7obs                     read-only: AUTO_ANCHOR_OBS (0x21F4) of both dies, 3 samples
  rev2hw.py a7window                  A7: beacon stops on the first AXI traffic, no word lost (WRITES through die_a ahb_sub)
  rev2hw.py crc ctl   --dir a2b|b2a   controls: quiet counters, wrong-DataID arm is inert (writes 0x23C of the TX die)
  rev2hw.py crc sweep --dir a2b|b2a [--n 7]   CRC injection on the sideband node (DataID 0xA1), N effective shots
  rev2hw.py crc stats --dir a2b|b2a --n N [--expect-fixed]   statistics: N single shots (byte 4..11 x bit 0..7 rotated), outcome counts, Wilson 95%
                                      --expect-fixed (or env EXPECT_FIXED=1): acceptance mode for a TL-059 fixed image, VERDICT PASS only if
                                      every detected shot was replayed EXACTLY once (0 lost, 0 stray, 0 dup); default = measurement mode
  rev2hw.py stream --dir a2b|b2a [--n N] [--len 28] [--gap S]   stream-start / NACK-revert-storm observation (see cmd_stream; no
                                      revert counter exists in the RTL, so it reports delivery exactness, latency, Ack/Nack-FIFO
                                      full / almost-full samples, CRC counters and the Region F / 0x21F8 witnesses before vs after)
  rev2hw.py health                    both dies fcsm==4 and cal==1

Registers used (all documented as decoded; nothing else is touched.  0x8403_xxxx / 0x8C03_xxxx addresses
that are not documented hang the PS, so there is NO read of TLAPB+0x3C, the unmapped alias):
  per die, APB base A=0x84030000 B=0x8C030000 (stride 0x08000000):
    +0x2108 STATUS [19:17] fcsm [16] cal     +0x21F4 AUTO_ANCHOR_OBS (docs/AUTO_ANCHOR_HW_DIAGNOSTIC_2026_08_04.md)
    +0x023C Wlink LINK_ERROR_INJECTION ([7:0] DataID [15:8] byte [18:16] bit [24] enable; 0->1 edge arms ONE shot)
    +0x1704 / +0x1714 / +0x1720 sideband (TideLink FC node 6) DataID / SM_CONTROL [16]=1 means CRC check OFF / CRC error count
    +0x1708 TX FC FIFO [0]=empty   +0x1710 Ack/Nack FIFO [0] empty [1] full [2] half [3] almost-empty [4] almost-full (stream only)
    +0x21E0 OBS_AXI_NODES (marker 0xAD)   +0x21F8 witness word (marker 0xB5)   (stream only, read pre/post, both documented)
    +0x2004 REL_THRESHOLD +0x200C RX credit +0x2010 RX status[4]=avail +0x201C RX ctrl(2=flush) +0x2030 PAIR_CREDIT_EN
  data plane: ahb_tx A=0xA4000000 B=0xAC000000, rx fifo A=0xA4010000 B=0xAC010000, ahb_sub A=0x80000000 B=0x88000000

Exit status: 0 PASS, 1 FAIL, 4 INCONCLUSIVE (nothing was proven either way), 2 usage/precondition.
"""
import argparse, ctypes, mmap, os, sys, time

SIDEBAND_ID = 0xA1
APB = {"a": 0x84030000, "b": 0x8C030000}
TX = {"a": 0xA4000000, "b": 0xAC000000}
FIFO = {"a": 0xA4010000, "b": 0xAC010000}
SUB = {"a": 0x80000000, "b": 0x88000000}
NAME = {"a": "die_a", "b": "die_b"}
STATUS, ERRINJ, AAOBS = 0x2108, 0x023C, 0x21F4
N6 = 0x1700                       # sideband FC node
DATAID, SMCTL, CRCCNT = 0x04, 0x14, 0x20
TXFIFO, ACKNACK = 0x08, 0x10          # FC node: TX FC FIFO status, Ack/Nack FIFO status (docs/REGISTER_MAP.md FC node table)
REGF, WITNESS = 0x21E0, 0x21F8
REL, CREDIT, RXST, RXCTL, PAIR_EN = 0x2004, 0x200C, 0x2010, 0x201C, 0x2030

_fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}


def _mm(a):
    b = a & ~0xFFF
    if b not in _maps:
        _maps[b] = mmap.mmap(_fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return _maps[b], a - b


def rd(a):
    m, o = _mm(a)
    return ctypes.c_uint32.from_buffer(m, o).value


def wr(a, v):
    m, o = _mm(a)
    ctypes.c_uint32.from_buffer(m, o).value = v & 0xFFFFFFFF


def P(*a):
    print(*a, flush=True)


def verdict(ok, what, code_fail=1, fail=None):
    P("VERDICT: %s %s" % ("PASS" if ok else "FAIL", what if ok or fail is None else fail))
    return 0 if ok else code_fail


def inconclusive(what):
    P("VERDICT: INCONCLUSIVE %s" % what)
    return 4


def rdn(label, addr):
    """Read with the address printed first, so a hang names the register."""
    P("  read %-28s 0x%08x ..." % (label, addr))
    v = rd(addr)
    P("       -> 0x%08x" % v)
    return v


# ------------------------------------------------------------------ link / anchor decode
def status(d):
    s = rd(APB[d] + STATUS)
    return (s >> 17) & 7, (s >> 16) & 1, s


def link_ok(tries=10):
    for _ in range(tries):
        sa, sb = status("a"), status("b")
        if sa[0] == 4 and sa[1] == 1 and sb[0] == 4 and sb[1] == 1:
            return True
        time.sleep(0.05)
    return False


def anchor(d):
    v = rd(APB[d] + AAOBS)
    return dict(raw=v, dwell=v & 0xFFFF, ever=(v >> 16) & 1, done=(v >> 17) & 1, pulse=(v >> 18) & 1,
                up=(v >> 19) & 1, idle=(v >> 20) & 1, reanch=(v >> 21) & 1, train=(v >> 22) & 1, en=(v >> 23) & 1)


def show_anchor(tag, d, x):
    P("A7OBS %-8s %s raw=0x%08x en=%d link_up=%d tx_idle=%d pulse=%d done=%d ever=%d reanchored=%d dwell_max=%d"
      % (tag, NAME[d], x["raw"], x["en"], x["up"], x["idle"], x["pulse"], x["done"], x["ever"], x["reanch"], x["dwell"]))


def state_of(x):
    if not x["en"]:
        return "OFF"
    if x["pulse"]:
        return "RUNNING"
    if x["done"]:
        return "DONE"
    return "IDLE"


# ------------------------------------------------------------------ commands
def cmd_health(_):
    ok = link_ok()
    for d in "ab":
        f, c, s = status(d)
        P("health %s STATUS=0x%08x fcsm=%d cal=%d" % (NAME[d], s, f, c))
    return verdict(ok, "both dies fcsm==4 and cal==1")


def cmd_regs(_):
    ok = True
    for d in "ab":
        base = APB[d]
        P("== %s (APB 0x%08x)" % (NAME[d], base))
        s = rdn("STATUS", base + STATUS)
        f, c = (s >> 17) & 7, (s >> 16) & 1
        P("       fcsm=%d cal=%d" % (f, c))
        if f != 4 or c != 1:
            P("  FAIL: link not up"); ok = False
        # 2026-10-13 diagnostic (read-only): die_b's 0x23C did not hold a write. Is die_b's Wlink 0x2xx
        # bank readable at all? Known non-zero values on a live link: 0x208 EnableReset 0x27F07,
        # 0x214 lane mask 0xE4E4 (onchip), 0x234 LinkStatus 0x18 (seen on eth silicon-like images).
        for off, nm in ((0x200, "WL 0x200"), (0x208, "WL 0x208 EnableReset"), (0x214, "WL 0x214 lane mask"),
                        (0x234, "WL 0x234 LinkStatus")):
            rdn(nm, base + off)
        e = rdn("LINK_ERROR_INJECTION 0x23C", base + ERRINJ)
        if e != 0:
            P("  FAIL: 0x23C does not read its reset value 0 (wrong address or design); nothing will be written"); ok = False
        a = rdn("AUTO_ANCHOR_OBS", base + AAOBS)
        show_anchor("regs", d, anchor(d))
        did = rdn("sideband node DataID", base + N6 + DATAID)
        if (did & 0xFF) != SIDEBAND_ID:
            P("  FAIL: sideband DataID is 0x%02x, expected 0x%02x" % (did & 0xFF, SIDEBAND_ID)); ok = False
        sm = rdn("sideband node SM_CONTROL", base + N6 + SMCTL)
        if (sm >> 16) & 1:
            P("  FAIL: sideband CRC check is OFF (SM_CONTROL[16]=1); the shipped default is ON, nothing to test"); ok = False
        else:
            P("       sideband CRC checking is ON")
        rdn("sideband node CRC errors", base + N6 + CRCCNT)
    return verdict(ok, "register preflight (0x23C==0, sideband DataID 0xA1, sideband CRC check ON, link up) on both dies",
                   fail="register preflight failed (see the FAIL lines above)")


def cmd_a7obs(_):
    st = {}
    for i in range(3):
        for d in "ab":
            x = anchor(d); show_anchor("s%d" % i, d, x); st[d] = x
        time.sleep(0.03)
    P("A7OBS_STATE die_a=%s die_b=%s" % (state_of(st["a"]), state_of(st["b"])))
    if st["a"]["en"] == 0 or st["b"]["en"] == 0:
        return verdict(False, "AUTO_ANCHOR_EN is 0 in this image (the A7 logic is not in the build)")
    return verdict(True, "AUTO_ANCHOR_OBS readable on both dies (information only; the stop test is a7window)")


def cmd_a7window(args):
    NW = 16
    if not link_ok():
        return verdict(False, "link not up on both dies: no write issued")
    pre = {d: anchor(d) for d in "ab"}
    for d in "ab":
        show_anchor("pre", d, pre[d])
    if not (pre["a"]["en"] and pre["b"]["en"]):
        return verdict(False, "AUTO_ANCHOR_EN=0: A7 logic absent from this image")
    t0 = time.time()
    while not (pre["a"]["pulse"] or pre["b"]["pulse"]) and not (pre["a"]["done"] and pre["b"]["done"]) and time.time() - t0 < 1.0:
        time.sleep(0.02); pre = {d: anchor(d) for d in "ab"}
    running = [d for d in "ab" if pre[d]["pulse"]]
    if not running:
        return inconclusive("the beacon is not running (die_a %s, die_b %s): it finished before the test, so stop-on-AXI was NOT exercised. "
                            "Re-run from POR (hw_test.sh --from 19) and start the window test sooner after the PL load"
                            % (state_of(pre["a"]), state_of(pre["b"])))
    # control: the beacon must still be running after an idle wait, so a later stop is caused by the traffic
    time.sleep(0.2)
    mid = {d: anchor(d) for d in "ab"}
    for d in "ab":
        show_anchor("idle+200ms", d, mid[d])
    for d in running:
        if not mid[d]["pulse"] or mid[d]["done"]:
            return inconclusive("%s beacon stopped by itself during the 200 ms idle control (state %s): the window closed before the burst"
                                % (NAME[d], state_of(mid[d])))
    P("A7 control: beacon still RUNNING on %s after 200 ms with no traffic" % ", ".join(NAME[d] for d in running))
    # burst: NW single-beat writes through die_a ahb_sub, landing in die_b's ahb_mng BRAM
    seed = int(time.time() * 1000) & 0xFFFF
    pat = lambda i: (0xA7000000 | ((i & 0xFF) << 16) | seed)
    P("A7 burst: %d x 32-bit writes to 0x%08x.. (die_a ahb_sub), seed 0x%04x" % (NW, SUB["a"], seed))
    for i in range(NW):
        wr(SUB["a"] + 4 * i, pat(i))
    P("A7 burst: writes completed (no PS hang)")
    post = []
    for tag, dly in (("post+0", 0.0), ("post+100ms", 0.1), ("post+1s", 0.9)):
        time.sleep(dly)
        row = {d: anchor(d) for d in "ab"}
        post.append((tag, row))
        for d in "ab":
            show_anchor(tag, d, row[d])
    stopped = all((not row[d]["pulse"]) and row[d]["done"] for tag, row in post[1:] for d in running)
    P("A7 stop: dies that were RUNNING: %s -> stopped (pulse=0, done=1) at +100ms and +1s: %s" % (",".join(NAME[d] for d in running), stopped))
    if not link_ok():
        return verdict(False, "link degraded after the burst (fcsm/cal): no readback attempted")
    bad = []
    P("A7 readback: %d x 32-bit reads through die_a ahb_sub (the data sits in die_b's ahb_mng BRAM)" % NW)
    for i in range(NW):
        v = rd(SUB["a"] + 4 * i)
        if v != pat(i):
            bad.append((i, v, pat(i)))
    for i, v, e in bad[:4]:
        P("  MISMATCH word %d got 0x%08x expected 0x%08x" % (i, v, e))
    P("A7 readback: %d/%d words byte-exact" % (NW - len(bad), NW))
    if not link_ok():
        return verdict(False, "link degraded after the readback")
    if bad:
        return verdict(False, "word(s) lost or wrong through the window (%d of %d)" % (len(bad), NW))
    return verdict(stopped, "A7: beacon (%s) stopped on the first AXI traffic (idle control: still running), %d/%d words byte-exact"
                   % (",".join(NAME[d] for d in running), NW, NW),
                   fail="A7: the beacon was still running or not done after the AXI burst on %s (see the A7OBS post lines)" % ",".join(NAME[d] for d in running))


# ------------------------------------------------------------------ sideband data path (same protocol as kr260_onchip_soak.py)
class Path:
    def __init__(self, direction):
        self.t, self.r = ("a", "b") if direction == "a2b" else ("b", "a")
        self.dir = direction

    def setup(self):
        wr(APB[self.r] + REL, 0)          # immediate per-pop credit release on the receiver
        wr(APB[self.t] + PAIR_EN, 1)      # pair-credit tracking on the sender
        wr(APB[self.r] + RXCTL, 0x2)      # flush the receiver RX (EN=0, FLUSH=1)
        time.sleep(0.02)

    def avail(self):
        return (rd(APB[self.r] + RXST) >> 4) & 1

    def room(self):
        return rd(APB[self.r] + CREDIT)

    def send(self, tag, length=2, timeout=2.0):
        t0 = time.time()
        while self.room() < length + 2:       # never write ahb_tx without receiver room: an overrun hangs the PS
            if time.time() - t0 > timeout:
                return False
            time.sleep(0.001)
        words = [(length & 0xFFF) << 20, 0, tag & 0xFFFFFFFF, (tag ^ 0xFFFFFFFF) & 0xFFFFFFFF]
        for j, v in enumerate(words):
            wr(TX[self.t] + 4 * j, v)
        return True

    def send_stream(self, tag, length, timeout=2.0):
        """One packet of `length` payload words (header, 0, then payload) through ahb_tx; gated on receiver room like send()."""
        t0 = time.time()
        while self.room() < length + 2:
            if time.time() - t0 > timeout:
                return False
            time.sleep(0.001)
        words = [(length & 0xFFF) << 20, 0] + stream_payload(tag, length)
        for j, v in enumerate(words):
            wr(TX[self.t] + 4 * j, v)
        return True

    def drain_one(self):
        hdr = rd(FIFO[self.r]); total = min(((hdr >> 20) & 0xFFF) + 2, 64)
        return [hdr] + [rd(FIFO[self.r] + i * 4) for i in range(1, total)]

    def collect(self, first_wait=2.0, settle=0.08):
        """Wait for a packet, then wait `settle` for any replay duplicate, drain everything."""
        pk, t0 = [], time.time()
        while not self.avail() and time.time() - t0 < first_wait:
            time.sleep(0.001)
        time.sleep(settle)
        while self.avail() and len(pk) < 8:
            pk.append(self.drain_one())
        return pk

    def crc(self):
        return rd(APB[self.r] + N6 + CRCCNT) & 0xFFFF

    def errinj_addr(self):
        return APB[self.t] + ERRINJ


def stream_payload(tag, length):
    return [((tag + i) ^ (i << 24) ^ 0xA5A5A5A5) & 0xFFFFFFFF for i in range(length)]


def exact_stream(pk, tag, length):
    return len(pk) == 1 and pk[0][0] == ((length & 0xFFF) << 20) and pk[0][2:] == stream_payload(tag, length) and len(pk[0]) == length + 2


def exact(pk, tag):
    return len(pk) == 1 and len(pk[0]) >= 4 and pk[0][2] == tag and pk[0][3] == (tag ^ 0xFFFFFFFF) & 0xFFFFFFFF


# die_b is the SLAVE on kr260-pair-onchip, and axi_chiplet_controller makes external APB to the Wlink
# bank READ-ONLY on a slave unless apb_debug_unlock_i is high (writes silently dropped; proven on HW
# 2026-10-14, errprobe). The onchip image builds DEBUG_UNLOCK_DEFAULT=0, so assert die_b's unlock GPIO
# only while its injector is armed, and restore it on disarm. Silicon builds force unlock on.
DBG_UNLOCK = {"a": 0x84041000, "b": 0x8C041000}


def _unlock(path, on):
    if path.t == "b":
        wr(DBG_UNLOCK["b"], 1 if on else 0); time.sleep(0.001)


def arm(path, did, byte, bit):
    v = _arm(path, did, byte, bit)
    if not v:
        _unlock(path, False)       # failed arm: never leave die_b unlocked
    return v


def _arm(path, did, byte, bit):
    a = path.errinj_addr()
    _unlock(path, True)
    wr(a, 0); time.sleep(0.005)
    if rd(a) != 0:
        return None
    val = (1 << 24) | ((bit & 7) << 16) | ((byte & 0xFF) << 8) | (did & 0xFF)
    wr(a, val); time.sleep(0.005)
    r = rd(a)
    if r != val:
        # 2026-10-13: die_b's 0x23C failed this check and the value was thrown away. Record what it
        # actually reads, and whether it settles (CDC into the link clock) before calling it a failure.
        seen = [r]
        for dt in (0.05, 0.5):
            time.sleep(dt); seen.append(rd(a))
        P("  arm 0x%08x wrote 0x%08x; read 0x%08x @5ms, 0x%08x @55ms, 0x%08x @555ms" % (a, val, seen[0], seen[1], seen[2]))
        r = seen[-1]
    return val if r == val else False          # False: the register did not hold what was written


def disarm(path):
    a = path.errinj_addr()
    wr(a, 0); time.sleep(0.005)
    ok = rd(a) == 0
    _unlock(path, False)
    return ok


def cmd_crc_ctl(args):
    p = Path(args.dir)
    P("CRC-CTL dir=%s  tx=%s rx=%s" % (p.dir, NAME[p.t], NAME[p.r]))
    if not link_ok():
        return verdict(False, "link not up: nothing sent")
    if rd(p.errinj_addr()) != 0:
        return verdict(False, "0x23C of %s does not read 0: nothing written" % NAME[p.t])
    p.setup()
    ok = True
    # control 1: clean traffic, counters must not move
    c0 = {d: rd(APB[d] + N6 + CRCCNT) & 0xFFFF for d in "ab"}
    bad = 0
    for i in range(16):
        tag = 0x7C100000 + i
        if not p.send(tag):
            P("  FAIL: no receiver credit (not wedged) at packet %d" % i); ok = False; break
        if not exact(p.collect(), tag):
            bad += 1
    c1 = {d: rd(APB[d] + N6 + CRCCNT) & 0xFFFF for d in "ab"}
    P("CTL1 quiet: 16 clean packets, bad=%d, sideband CRC counters a %d->%d b %d->%d" % (bad, c0["a"], c1["a"], c0["b"], c1["b"]))
    if bad or c0 != c1:
        ok = False; P("  FAIL: clean traffic must be byte-exact with counters unchanged")
    # control 2: injector armed for a DataID nobody uses must be inert (the injector is selective)
    v = arm(p, 0x7E, 5, 0)
    P("CTL2 arm DataID 0x7E byte5 bit0: 0x23C readback = %s" % ("0x%08x" % v if v else v))
    if not v:
        ok = False; P("  FAIL: 0x23C is not a holding register (readback differs from the write)")
    bad = 0
    for i in range(4):
        tag = 0x7C200000 + i
        if not p.send(tag):
            ok = False; break
        if not exact(p.collect(), tag):
            bad += 1
    dis = disarm(p)
    c2 = {d: rd(APB[d] + N6 + CRCCNT) & 0xFFFF for d in "ab"}
    P("CTL2 wrong-DataID armed: 4 packets, bad=%d, CRC counters unchanged=%s, disarmed=%s" % (bad, c2 == c1, dis))
    if bad or c2 != c1 or not dis:
        ok = False; P("  FAIL: a wrong-DataID arm must change nothing")
    if not link_ok():
        ok = False; P("  FAIL: link degraded")
    return verdict(ok, "CRC controls %s: clean traffic exact with quiet counters; wrong-DataID arm inert; 0x23C holds its value" % p.dir,
                   fail="CRC controls %s failed (see the FAIL lines above)" % p.dir)


CANDIDATES = [(5, 0), (6, 1), (8, 2), (5, 3), (6, 5), (8, 4), (5, 6), (6, 7), (8, 0), (9, 1), (10, 2), (7, 3), (11, 4), (9, 5), (10, 6), (7, 7)]


def postmortem(p, tag):
    """2026-10-14: a detected sideband shot (CRC +1) whose packet never arrived. Information only:
    late delivery? node wedged or just one packet lost? what do the sideband node registers say?"""
    late = p.collect(first_wait=2.0, settle=0.15)
    P("  PM late delivery within +2 s: %d packet(s)%s" % (len(late), " EXACT" if exact(late, tag) else (" " + " ".join("%s" % [("0x%08x" % w) for w in pk[:4]] for pk in late[:3]) if late else "")))
    P("  PM link_ok=%s" % link_ok())
    for d in "ab":
        regs = " ".join("+%02x=0x%08x" % (o, rd(APB[d] + N6 + o)) for o in range(0, 0x28, 4))
        P("  PM %s sideband node 0x%04x: %s" % (NAME[d], N6, regs))
        P("  PM %s SWI_LANE 0x2108=0x%08x" % (NAME[d], rd(APB[d] + 0x2108)))
    t2 = tag ^ 0x00F00000
    sent = p.send(t2)
    pk2 = p.collect(first_wait=3.0, settle=0.15) if sent else []
    P("  PM fresh clean packet: sent=%s received=%s -> %s" % (sent, len(pk2), "node ALIVE (one packet lost)" if exact(pk2, t2) else "node NOT delivering (wedged or stuck)"))
    P("  PM crc counters after: a=%d b=%d" % (rd(APB["a"] + N6 + CRCCNT) & 0xFFFF, rd(APB["b"] + N6 + CRCCNT) & 0xFFFF))


def cmd_crc_sweep(args):
    p = Path(args.dir)
    want = args.n
    P("CRC-SWEEP dir=%s  tx=%s (inject at 0x%08x) rx=%s (counter 0x%08x) DataID 0x%02x, want %d effective shots"
      % (p.dir, NAME[p.t], p.errinj_addr(), NAME[p.r], APB[p.r] + N6 + CRCCNT, SIDEBAND_ID, want))
    if not link_ok():
        return verdict(False, "link not up: nothing sent")
    if rd(p.errinj_addr()) != 0:
        return verdict(False, "0x23C of %s does not read 0: nothing written" % NAME[p.t])
    sm = rd(APB[p.r] + N6 + SMCTL)
    if (sm >> 16) & 1:
        return verdict(False, "receiver sideband CRC check is OFF (SM_CONTROL=0x%08x): injection cannot be detected" % sm)
    p.setup()
    eff, inert, fails, attempts = 0, 0, 0, 0
    for byte, bit in CANDIDATES:
        if eff >= want:
            break
        attempts += 1
        tag = 0x5C000000 + (attempts << 8) + byte
        c0 = p.crc()
        v = arm(p, SIDEBAND_ID, byte, bit)
        if not v:
            P("SHOT %2d byte=%2d bit=%d: FAIL 0x23C %s" % (attempts, byte, bit, "not zero before arm" if v is None else "did not hold the armed value"))
            fails += 1; break
        if not p.send(tag):
            disarm(p); P("SHOT %2d: FAIL no receiver credit (not wedged)" % attempts); fails += 1; break
        pk = p.collect(first_wait=3.0, settle=0.15)
        dis = disarm(p)
        c1 = p.crc()
        d = (c1 - c0) & 0xFFFF
        good = exact(pk, tag)
        if good and d == 1:
            res = "EFFECTIVE"; eff += 1
        elif good and d == 0:
            res = "INERT(byte not covered by the CRC or not in this packet)"; inert += 1
        else:
            res = "FAIL"; fails += 1
        P("SHOT %2d byte=%2d bit=%d: arm=0x%08x crc %d->%d (delta %d) packets=%d data=%s disarmed=%s -> %s"
          % (attempts, byte, bit, v, c0, c1, d, len(pk), "exact" if good else "BAD", dis, res))
        if res == "FAIL":
            if d == 0 and not good:
                P("  SILENT CORRUPTION or lost packet: no CRC count and the data is not the sent word")
            postmortem(p, tag)
            break
        if not link_ok():
            P("  FAIL: link degraded after the shot"); fails += 1; break
    P("CRC-SWEEP %s: effective=%d inert=%d fail=%d attempts=%d" % (p.dir, eff, inert, fails, attempts))
    ok = fails == 0 and eff >= want
    if not ok and fails == 0:
        return verdict(False, "only %d of %d wanted shots were effective (%d inert): the injection may not reach this packet" % (eff, want, inert))
    return verdict(ok, "%s: %d/%d single-bit shots on DataID 0xA1 detected (CRC counter +1 each), data exact, 0 silent corruption, link healthy"
                   % (p.dir, eff, want), fail="%s CRC sweep failed: effective=%d/%d inert=%d fail=%d (see the SHOT lines above)" % (p.dir, eff, want, inert, fails))


def wilson(k, n, z=1.959964):
    """Wilson score 95% interval for k/n (returns (lo, hi) as fractions; (0, 1) when n == 0)."""
    if n <= 0:
        return 0.0, 1.0
    ph = k / n
    den = 1 + z * z / n
    c = (ph + z * z / (2 * n)) / den
    h = z * ((ph * (1 - ph) / n + z * z / (4 * n * n)) ** 0.5) / den
    return max(0.0, c - h), min(1.0, c + h)


def fmt_ci(k, n):
    lo, hi = wilson(k, n)
    return "%d/%d = %.1f%% (Wilson95 %.1f%%..%.1f%%)" % (k, n, 100.0 * k / n if n else 0.0, 100 * lo, 100 * hi)


STATS_MAX_N = 64        # hard cap: bounded single shots, never a free-running driver


def classify(pk, tag):
    """Outcome of ONE shot's collect window: EXACT / LOST / DUP / STRAY."""
    if not pk:
        return "LOST"
    if exact(pk[:1], tag):
        if all(exact([x], tag) for x in pk):
            return "EXACT" if len(pk) == 1 else "DUP"
        return "STRAY"
    return "STRAY"


def cmd_crc_stats(args):
    """Statistics for the sideband CRC-replay question: of the shots whose CRC error was DETECTED (counter +1),
    how many were replayed byte-exact and how many were lost?  One armed single shot per iteration (0->1 edge arms ONE
    shot, disarmed straight after), payload byte 4..11 and bit 0..7 rotated, DataID 0xA1.  After every shot a fresh clean
    packet proves the node still delivers (the control); the run stops only if that fails twice or the link degrades.
    Host-drivable data path is the sideband ahb_tx only; AXI data nodes (ahb_sub) are not driven here."""
    p = Path(args.dir)
    n = args.n
    if n < 1 or n > STATS_MAX_N:
        return verdict(False, "--n must be 1..%d (bounded single shots)" % STATS_MAX_N)
    P("CRC-STATS dir=%s tx=%s (inject at 0x%08x) rx=%s (counter 0x%08x) DataID 0x%02x, %d shots, collect window 3 s"
      % (p.dir, NAME[p.t], p.errinj_addr(), NAME[p.r], APB[p.r] + N6 + CRCCNT, SIDEBAND_ID, n))
    P("CRC-STATS note: only the sideband (ahb_tx) path is host-drivable here; the AXI-data-node control is replaced by one "
      "fresh clean sideband packet after every shot (and 8 before the first).")
    if not link_ok():
        return verdict(False, "link not up: nothing sent")
    if rd(p.errinj_addr()) != 0:
        return verdict(False, "0x23C of %s does not read 0: nothing written" % NAME[p.t])
    sm = rd(APB[p.r] + N6 + SMCTL)
    if (sm >> 16) & 1:
        return verdict(False, "receiver sideband CRC check is OFF (SM_CONTROL=0x%08x): injection cannot be detected" % sm)
    p.setup()
    ctl_ok = ctl_n = 0
    c0 = p.crc()
    for i in range(8):                        # pre-controls: clean traffic exact, counter quiet
        tag = 0x5E000000 + i
        if not p.send(tag):
            return verdict(False, "pre-control: no receiver credit")
        ctl_n += 1
        ctl_ok += 1 if exact(p.collect(), tag) else 0
    if ctl_ok != 8 or p.crc() != c0:
        return verdict(False, "pre-controls failed (clean %d/8, counter %d->%d): link not clean before any injection" % (ctl_ok, c0, p.crc()))
    P("CTL pre: 8/8 clean packets exact, CRC counter quiet at %d" % c0)
    cnt = {"EXACT": 0, "LOST": 0, "STRAY": 0, "DUP": 0}
    inert = undet_bad = late = credit_resets = shots = fails = 0
    degraded = None
    rows = []
    for i in range(n):
        byte, bit = 4 + (i % 8), (i + i // 8) % 8
        tag = 0x5D000000 + (i << 8) + byte
        # residue from a previous shot must not be mistaken for this one
        resid = p.collect(first_wait=0.0, settle=0.0)
        if resid:
            P("  residue before shot %d: %d packet(s) %s" % (i + 1, len(resid), " ".join("0x%08x" % x[2] for x in resid if len(x) > 2)))
        crc0 = p.crc()
        v = arm(p, SIDEBAND_ID, byte, bit)
        if not v:
            degraded = "0x23C %s at shot %d" % ("not zero before arm" if v is None else "did not hold the armed value", i + 1); break
        if not p.send(tag):
            disarm(p); p.setup(); credit_resets += 1
            if not p.send(tag):
                degraded = "no receiver credit at shot %d (even after RX flush)" % (i + 1); break
        pk = p.collect(first_wait=3.0, settle=0.15)
        dis = disarm(p)
        shots += 1
        d = (p.crc() - crc0) & 0xFFFF
        oc = classify(pk, tag)
        if d == 0:
            if oc == "EXACT":
                res = "INERT"; inert += 1
            else:
                res = "UNDETECTED_" + oc; undet_bad += 1
        else:
            res = oc; cnt[oc] += 1
        # liveness control: a fresh clean packet must be delivered; a late copy of the shot packet is recorded
        t2 = (tag ^ 0x00F00000) & 0xFFFFFFFF
        alive, extra = False, []
        for attempt in (1, 2):
            if not p.send(t2):
                p.setup(); credit_resets += 1
                if not p.send(t2):
                    break
            pk2 = p.collect(first_wait=3.0 if attempt == 1 else 6.0, settle=0.15)
            extra += [x for x in pk2 if not (len(x) > 2 and x[2] == t2)]
            if any(len(x) > 3 and x[2] == t2 and x[3] == (t2 ^ 0xFFFFFFFF) & 0xFFFFFFFF for x in pk2):
                alive = True; break
            t2 = (t2 + 1) & 0xFFFFFFFF
        lateflag = any(len(x) > 2 and x[2] == tag for x in extra)
        if lateflag and oc == "LOST":
            late += 1
        link = link_ok()
        P("SHOT %2d byte=%2d bit=%d arm=0x%08x crc %d->%d (d=%d) pkts=%d -> %-15s control=%s%s link=%s disarmed=%s"
          % (i + 1, byte, bit, v, crc0, crc0 + d, d, len(pk), res, "alive" if alive else "DEAD",
             " LATE-COPY-ARRIVED-AFTER-WINDOW" if lateflag else "", link, dis))
        if pk and oc in ("STRAY", "DUP"):
            P("  PKTS " + " | ".join(" ".join("0x%08x" % w for w in x[:4]) for x in pk[:4]) + "  (sent tag 0x%08x)" % tag)
        rows.append((byte, bit, d, oc, res, alive))
        if not alive:
            degraded = "fresh clean packet NOT delivered after shot %d (twice): node wedged" % (i + 1); break
        if not link:
            degraded = "link degraded (fcsm/cal) after shot %d" % (i + 1); break
    detected = sum(cnt.values())
    P("")
    P("CRC-STATS SUMMARY dir=%s" % p.dir)
    P("  shots run          %d of %d wanted" % (shots, n))
    P("  detected (crc +1)  %d     inert (crc +0, data exact) %d     undetected-bad (crc +0, lost/wrong) %d" % (detected, inert, undet_bad))
    P("  outcomes | detected:  EXACT(replayed) %d   LOST %d   STRAY/WRONG %d   DUP %d" % (cnt["EXACT"], cnt["LOST"], cnt["STRAY"], cnt["DUP"]))
    P("  lost packet arrived late (after its 3 s window, seen in the control window): %d" % late)
    P("  liveness controls  %d/%d fresh clean packets delivered after a shot; pre-controls %d/%d; credit resets %d"
      % (sum(1 for r in rows if r[5]), len(rows), ctl_ok, ctl_n, credit_resets))
    P("  P(lost | detected)  = %s" % fmt_ci(cnt["LOST"], detected))
    P("  P(exact | detected) = %s" % fmt_ci(cnt["EXACT"], detected))
    P("  P(stray | detected) = %s" % fmt_ci(cnt["STRAY"] + cnt["DUP"], detected))
    P("  by payload byte (detected: lost/total):  " + "  ".join(
        "b%d:%d/%d" % (b, sum(1 for r in rows if r[0] == b and r[3] == "LOST" and r[2]), sum(1 for r in rows if r[0] == b and r[2])) for b in range(4, 12)))
    if degraded:
        P("STATS_RESULT=LINK_DEGRADED  (%s)" % degraded)
        return verdict(False, "", fail="CRC stats %s stopped: %s" % (p.dir, degraded))
    if shots < n:
        P("STATS_RESULT=INCOMPLETE")
        return verdict(False, "", fail="CRC stats %s ran %d of %d shots" % (p.dir, shots, n))
    if undet_bad:
        P("STATS_RESULT=UNDETECTED_BAD  (%d shot(s) with no CRC count and the packet lost or wrong: silent corruption or a counter that does not count)" % undet_bad)
        return verdict(False, "", fail="CRC stats %s: %d shot(s) lost/corrupted WITHOUT a CRC count (see UNDETECTED lines)" % (p.dir, undet_bad))
    if detected == 0:
        P("STATS_RESULT=INCONCLUSIVE  (no detected CRC error in %d shots)" % shots)
        return inconclusive("no shot produced a detected CRC error: nothing to estimate")
    expect_fixed = bool(getattr(args, "expect_fixed", False)) or os.environ.get("EXPECT_FIXED", "0") == "1"
    elo = wilson(cnt["EXACT"], detected)[0]
    if expect_fixed:
        # Acceptance mode for a TL-059 fixed image: every detected CRC error must be replayed exactly once.
        why = []
        if cnt["LOST"]: why.append("%d lost" % cnt["LOST"])
        if cnt["STRAY"]: why.append("%d stray/wrong" % cnt["STRAY"])
        if cnt["DUP"]: why.append("%d duplicated" % cnt["DUP"])
        if cnt["EXACT"] != detected: why.append("exact %d != detected %d" % (cnt["EXACT"], detected))
        P("  P(replayed exactly once | detected) = %s   Wilson95 lower bound %.1f%%" % (fmt_ci(cnt["EXACT"], detected), 100 * elo))
        P("STATS_RESULT=%s exact=%d detected=%d lost=%d stray=%d dup=%d undetected_bad=%d exact_wilson95_lo=%.3f"
          % ("FIXED_FAIL" if why else "FIXED_PASS", cnt["EXACT"], detected, cnt["LOST"], cnt["STRAY"], cnt["DUP"], undet_bad, elo))
        if why:
            return verdict(False, "", fail="CRC stats %s EXPECT_FIXED: not every detected shot was replayed exactly once: %s" % (p.dir, ", ".join(why)))
        return verdict(True, "EXPECT_FIXED %s: %d/%d detected CRC errors replayed exactly once (0 lost, 0 stray, 0 dup, 0 undetected-bad); Wilson95 lower bound %.1f%%"
                       % (p.dir, cnt["EXACT"], detected, 100 * elo))
    lo = wilson(cnt["LOST"], detected)[0]
    res = "BUG_REPRODUCED" if cnt["LOST"] > 0 else "NO_LOSS_OBSERVED"
    P("STATS_RESULT=%s lost=%d detected=%d stray=%d dup=%d undetected_bad=%d lost_wilson95_lo=%.3f"
      % (res, cnt["LOST"], detected, cnt["STRAY"], cnt["DUP"], undet_bad, lo))
    return verdict(True, "measurement valid, link healthy, all controls delivered: %s dir=%s lost %s; stray/wrong %d dup %d undetected-bad %d"
                   % (res, p.dir, fmt_ci(cnt["LOST"], detected), cnt["STRAY"], cnt["DUP"], undet_bad))


STREAM_MAX_N = 16               # hard cap: bounded starts per direction per run
STREAM_LAT_MAX = 0.100          # s from send to first RX-available: a clean 30-word packet crosses in ~ms; >100 ms = SLOW (storm suspect)
STREAM_WITNESS_MASK = 0x00007F00   # 0x21F8 [14:8] fault stickies (TL-021/042/044); [7:0] are live/HWM fields and are ignored
REGF_FAULT_MASK = 0x003FFC00       # 0x21E0 wedge-sticky [19:10] + resp-error [21:20]; [23] healthy is checked separately


def _witness(tag):
    """Read-only, marker-gated snapshot of the two documented data-plane health words (die_a, die_b)."""
    out = {}
    for d in "ab":
        rf, wi = rd(APB[d] + REGF), rd(APB[d] + WITNESS)
        out[d] = (rf, wi)
        P("STREAM-WITNESS %-5s %s 0x21E0=0x%08x (marker %s) 0x21F8=0x%08x (marker %s)"
          % (tag, NAME[d], rf, "ok" if rf >> 24 == 0xAD else "ABSENT", wi, "ok" if wi >> 24 == 0xB5 else "ABSENT"))
    return out


def _witness_changed(w0, w1):
    bad = []
    for d in "ab":
        rf0, wi0 = w0[d]; rf1, wi1 = w1[d]
        if rf1 >> 24 == 0xAD and (rf1 & REGF_FAULT_MASK) & ~(rf0 & REGF_FAULT_MASK):
            bad.append("%s 0x21E0 new fault bits 0x%x" % (NAME[d], (rf1 & REGF_FAULT_MASK) & ~(rf0 & REGF_FAULT_MASK)))
        if rf1 >> 24 == 0xAD and not (rf1 >> 23) & 1 and (rf0 >> 23) & 1:
            bad.append("%s 0x21E0 data_nodes_healthy dropped" % NAME[d])
        if wi1 >> 24 == 0xB5 and (wi1 & STREAM_WITNESS_MASK) & ~(wi0 & STREAM_WITNESS_MASK):
            bad.append("%s 0x21F8 new fault bits 0x%x" % (NAME[d], (wi1 & STREAM_WITNESS_MASK) & ~(wi0 & STREAM_WITNESS_MASK)))
    return bad


def cmd_stream(args):
    """Stream-start / NACK-revert-storm observation for TL-059 design E (L9b/L9c gated off when link CRC is on).

    WHAT IS OBSERVABLE (searched main a652c73e, 2026-10-14): there is NO tx_revert / NACK / replay counter anywhere in the APB
    map.  FC node regs are only DataID(0x04) SM_CONTROL(0x14) CRC-errors(0x20) plus the TX FC FIFO status (0x08) and the
    Ack/Nack FIFO status (0x10, flags only, no count).  Region F 0x21E0 and the 0x21F8 witness cover the AXI data nodes / XHB500,
    not the sideband.  A revert storm therefore shows up only indirectly:
      (1) delivery: the stream is lost, truncated, duplicated or wrong (exactness of the 28-word packet);
      (2) latency: send -> RX-available far above a clean crossing (STREAM_LAT_MAX);
      (3) the sender's Ack/Nack FIFO sitting FULL or ALMOST-FULL (a flood of NACKs the node cannot drain): polled as fast as
          /dev/mem allows from the send until RX-available + 150 ms, counted in samples;
      (4) CRC counters unchanged (a clean run: a storm is NOT a CRC event, so a CRC movement here invalidates the run);
      (5) Region F / 0x21F8 witnesses unchanged.
    Absence of all five is "NO_STORM_OBSERVED", which is weaker than a counter and is reported as such.
    Start 1 of the FIRST direction run after a bring-up is the genuine cold stream start; starts 2..N are warm (idle gap between).
    No link-enable dip is used: on this image TL-052 holds swi_enable through the 0x27F00 dip (mid-dip reads 0x27f01), so the dip
    is not a stream-start trigger.  Cold starts come from POR + deploy cycles (hw_test.sh BRINGUPS=N).
    """
    p = Path(args.dir)
    n, length, gap = args.n, args.len, args.gap
    if n < 1 or n > STREAM_MAX_N or length < 1 or length > 60 or gap < 0.0 or gap > 5.0:
        return verdict(False, "--n must be 1..%d, --len 1..60, --gap 0..5 s (bounded)" % STREAM_MAX_N)
    P("STREAM dir=%s tx=%s rx=%s DataID 0x%02x, %d starts of %d payload words (%d words on ahb_tx), idle gap %.2f s, latency limit %.0f ms"
      % (p.dir, NAME[p.t], NAME[p.r], SIDEBAND_ID, n, length, length + 2, gap, STREAM_LAT_MAX * 1000))
    P("STREAM note: no revert/NACK counter exists in this RTL; storm = non-exact delivery OR latency OR Ack/Nack FIFO full/almost-full OR CRC/witness movement.")
    if not link_ok():
        return verdict(False, "link not up: nothing sent")
    for d in "ab":                             # named reads: a hang here names the register (documented FC-node regs, first HW read)
        rdn("%s TX FC FIFO (node6+0x08)" % NAME[d], APB[d] + N6 + TXFIFO)
        rdn("%s Ack/Nack FIFO (node6+0x10)" % NAME[d], APB[d] + N6 + ACKNACK)
    sm = rd(APB[p.r] + N6 + SMCTL)
    P("STREAM receiver sideband CRC check is %s (SM_CONTROL=0x%08x); design E is only exercised with CRC ON" % ("OFF" if (sm >> 16) & 1 else "ON", sm))
    if (sm >> 16) & 1:
        return verdict(False, "receiver sideband CRC check is OFF: design E gating (L9b/L9c off) is not exercised, test is not meaningful")
    p.setup()
    w0 = _witness("pre")
    crc0 = {d: rd(APB[d] + N6 + CRCCNT) & 0xFFFF for d in "ab"}
    rows, fail_reasons = [], []
    for i in range(n):
        tag = 0x57000000 + (p.dir == "b2a") * 0x00800000 + (i << 8) + (length & 0xFF)
        if gap and i:
            time.sleep(gap)
        resid = p.collect(first_wait=0.0, settle=0.0)
        if resid:
            P("  residue before start %d: %d packet(s)" % (i + 1, len(resid)))
        full = afull = nonempty = samples = txbusy = 0
        if not p.send_stream(tag, length):
            fail_reasons.append("no receiver credit at start %d" % (i + 1)); break
        t0 = time.time(); lat = None
        while True:
            now = time.time()
            st = rd(APB[p.t] + N6 + ACKNACK); samples += 1
            full += (st >> 1) & 1; afull += (st >> 4) & 1; nonempty += 0 if st & 1 else 1
            txbusy += 0 if rd(APB[p.t] + N6 + TXFIFO) & 1 else 1
            if lat is None and p.avail():
                lat = now - t0
            if lat is not None and now - t0 >= lat + 0.15:
                break
            if lat is None and now - t0 > 3.0:
                break
            time.sleep(0.0002)                 # poll as fast as the PS allows, but yield
        pk = p.collect(first_wait=0.0, settle=0.0)
        oc = "LOST" if not pk else ("EXACT" if exact_stream(pk, tag, length) else ("DUP" if len(pk) > 1 and all(exact_stream([x], tag, length) for x in pk) else "STRAY/SHORT"))
        crcd = {d: ((rd(APB[d] + N6 + CRCCNT) & 0xFFFF) - crc0[d]) & 0xFFFF for d in "ab"}
        slow = lat is not None and lat > STREAM_LAT_MAX
        flags = []
        if oc != "EXACT": flags.append(oc)
        if slow: flags.append("SLOW")
        if full or afull: flags.append("ACKNACK_FIFO_FULL(%d full,%d almost-full)" % (full, afull))
        if any(crcd.values()): flags.append("CRC_MOVED(a+%d,b+%d)" % (crcd["a"], crcd["b"]))
        link = link_ok()
        if not link: flags.append("LINK_DEGRADED")
        P("START %2d%s tag=0x%08x pkts=%d -> %-6s latency=%s acknack nonempty/full/almost-full=%d/%d/%d of %d samples, txfifo busy %d  crc_delta a+%d b+%d  link=%s%s"
          % (i + 1, " (first after setup)" if i == 0 else "", tag, len(pk), oc, "%.1f ms" % (lat * 1000) if lat is not None else "NONE in 3 s",
             nonempty, full, afull, samples, txbusy, crcd["a"], crcd["b"], link, "  !! " + " ".join(flags) if flags else ""))
        rows.append((oc, lat, full, afull, bool(any(crcd.values())), flags))
        if flags:
            fail_reasons.append("start %d: %s" % (i + 1, " ".join(flags)))
        if oc != "EXACT" or not link:
            break                              # never keep driving a path that already misdelivered
    w1 = _witness("post")
    for b in _witness_changed(w0, w1):
        fail_reasons.append("witness: " + b)
    lats = sorted(r[1] for r in rows if r[1] is not None)
    med = lats[len(lats) // 2] if lats else float("nan")
    ex = sum(1 for r in rows if r[0] == "EXACT")
    P("")
    P("STREAM SUMMARY dir=%s starts=%d of %d wanted  exact=%d/%d  latency median %.2f ms max %.2f ms (limit %.0f ms)"
      % (p.dir, len(rows), n, ex, len(rows), med * 1000, (lats[-1] if lats else float("nan")) * 1000, STREAM_LAT_MAX * 1000))
    P("  Ack/Nack FIFO full samples %d  almost-full samples %d  CRC counter moved in %d start(s)  witness changes %d"
      % (sum(r[2] for r in rows), sum(r[3] for r in rows), sum(1 for r in rows if r[4]), len(_witness_changed(w0, w1))))
    P("  revert/NACK counter: NOT AVAILABLE in this RTL (verdict rests on delivery + latency + FIFO flags + witnesses)")
    if len(rows) < n and not fail_reasons:
        fail_reasons.append("only %d of %d starts ran" % (len(rows), n))
    if fail_reasons:
        P("STREAM_RESULT=STORM_SUSPECT  (%s)" % "; ".join(fail_reasons[:4]))
        return verdict(False, "", fail="stream %s: %s" % (p.dir, "; ".join(fail_reasons[:4])))
    P("STREAM_RESULT=NO_STORM_OBSERVED exact=%d/%d median_ms=%.2f max_ms=%.2f" % (ex, len(rows), med * 1000, lats[-1] * 1000))
    return verdict(True, "stream %s: %d/%d %d-word starts delivered exactly once, latency <= %.0f ms, Ack/Nack FIFO never full/almost-full, CRC counters and witnesses unchanged (no revert counter exists: absence of a storm, not a count of 0)"
                   % (p.dir, ex, len(rows), length, STREAM_LAT_MAX * 1000))


def cmd_errprobe(_):
    """2026-10-14 diagnostic for 'die_b 0x23C does not hold a write'. Writes the injector with the
    ENABLE bit CLEAR (0x0000057E: DataID 0x7E, byte 5, bit 0, enable 0), so nothing can be injected,
    and records exactly what each die reads back and when. Restores 0. Information only."""
    if not link_ok():
        return verdict(False, "link not up: nothing written")
    held = {}
    for d in "ab":
        a = APB[d] + ERRINJ
        r0 = rd(a)
        wr(a, 0x0000057E)
        seq = [rd(a), rd(a), rd(a)]
        time.sleep(0.001); seq.append(rd(a))
        time.sleep(0.1); seq.append(rd(a))
        wr(a, 0); z = rd(a)
        held[d] = all(v == 0x0000057E for v in seq)
        P("ERRPROBE %s 0x%08x before=0x%08x after-write: %s ; after-clear=0x%08x"
          % (NAME[d], a, r0, " ".join("0x%08x" % v for v in seq), z))
    P("ERRPROBE_RESULT die_a_holds=%s die_b_holds=%s" % (held["a"], held["b"]))
    # H1 discriminator (TRACE.md 2026-10-14): die_b is the slave; axi_chiplet_controller makes external
    # APB read-only on a slave unless apb_debug_unlock_i is set. Assert die_b's unlock GPIO, retry, restore.
    DBG_B, STRAP_B = 0x8C041000, 0x8C040000
    P("ERRPROBE die_b strap GPIO 0x%08x = 0x%08x (1 = slave)" % (STRAP_B, rd(STRAP_B)))
    u0 = rd(DBG_B); P("ERRPROBE die_b debug_unlock GPIO 0x%08x before = 0x%08x" % (DBG_B, u0))
    a = APB["b"] + ERRINJ
    wr(DBG_B, 1); time.sleep(0.001)
    wr(a, 0x0000057E); seq = [rd(a), rd(a)]; time.sleep(0.1); seq.append(rd(a))
    wr(a, 0); z = rd(a)
    wr(DBG_B, u0 & 1); u1 = rd(DBG_B)
    unl = all(v == 0x0000057E for v in seq)
    P("ERRPROBE die_b UNLOCKED write 0x0000057E: %s ; after-clear=0x%08x ; unlock restored to 0x%08x"
      % (" ".join("0x%08x" % v for v in seq), z, u1))
    P("ERRPROBE_H1 die_b_holds_when_unlocked=%s (True = slave read-only APB mux is the cause)" % unl)
    return verdict(True, "errprobe recorded (information only)")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    for n in ("regs", "a7obs", "a7window", "health", "errprobe"):
        sp.add_parser(n)
    c = sp.add_parser("crc")
    c.add_argument("mode", choices=("ctl", "sweep", "stats"))
    c.add_argument("--dir", choices=("a2b", "b2a"), required=True)
    c.add_argument("--n", type=int, default=7)
    c.add_argument("--expect-fixed", action="store_true", dest="expect_fixed")
    st = sp.add_parser("stream")
    st.add_argument("--dir", choices=("a2b", "b2a"), required=True)
    st.add_argument("--n", type=int, default=4)
    st.add_argument("--len", type=int, default=28)
    st.add_argument("--gap", type=float, default=0.3)
    a = ap.parse_args()
    if os.geteuid() != 0:
        P("must run as root (/dev/mem)"); return 2
    P("rev2hw %s start %s" % (a.cmd, time.strftime("%F %T")))
    if a.cmd == "crc":
        return {"ctl": cmd_crc_ctl, "sweep": cmd_crc_sweep, "stats": cmd_crc_stats}[a.mode](a)
    if a.cmd == "stream":
        return cmd_stream(a)
    return {"regs": cmd_regs, "a7obs": cmd_a7obs, "a7window": cmd_a7window, "health": cmd_health, "errprobe": cmd_errprobe}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
