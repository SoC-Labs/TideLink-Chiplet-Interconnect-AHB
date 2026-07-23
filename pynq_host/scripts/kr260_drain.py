#!/usr/bin/env python3
# kr260_drain.py -- CORRECT KR260 RX-FIFO drain (port of pynq_host/scripts/tlfifo.py
# drain_one() to KR260 absolute addresses). The RX FIFO is a STREAMING packet FIFO:
# to POP a packet you must read word0 FIRST (arms the per-packet length latch ->
# sets read_target_addr_r = (len+1)<<2), then read SEQUENTIALLY through (len+2)
# words. The read landing on read_target fires read_complete -> pops -> RETURNS
# CREDIT. A fixed-offset read never pops. NEVER write to the FIFO window.
#
# KR260 (ZynqMP) absolute addresses (FPD/relocated):
#   FIFO   window : 0xA401_0000  (PS-visible RX FIFO data aperture)
#   STATUS reg    : 0x8403_2010  ([4]=packet available, [2]=underrun)
#   CREDIT reg    : 0x8403_200C  (current credit_count, RO, no side-effect)
#   FLUSH  (CTRL) : 0x8403_201C  (bit[1]=FLUSH self-clearing; EN bit0 must be 0)
import mmap, os, sys, ctypes
PAGE = 4096
FIFO   = 0xA4010000
STATUS = 0x84032010
CREDIT = 0x8403200C
CTRL   = 0x8403201C
REL_THRESHOLD = 0x84032004   # REG_REL_THRESHOLD; POR=20. The credit-return to the
                             # far-end TX only fires once accumulated released
                             # credit crosses this. The bring-up does NOT program
                             # it, so with the default a single small drain frees
                             # NOTHING back to the sender (sim-proven 2026-07-23) —
                             # the sender's credit pool then depletes and its next
                             # ahb_tx write HANGS the bus. `setup` sets it to 0 so
                             # every pop releases immediately.

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}
def _mm(a):
    b = a & ~(PAGE - 1)
    if b not in _maps:
        _maps[b] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return _maps[b], a - b
def rd(a):
    m, o = _mm(a); return ctypes.c_uint32.from_buffer(m, o).value
def wr(a, v):
    m, o = _mm(a); ctypes.c_uint32.from_buffer(m, o).value = v & 0xFFFFFFFF

def drain_one(base=FIFO):
    hdr    = rd(base + 0)                 # arms length latch; sets read_target
    length = (hdr >> 20) & 0xFFF          # payload words
    total  = length + 2                   # hdr + dest + payload
    words  = [hdr] + [rd(base + i*4) for i in range(1, total)]
    return length, words                  # last read == read_target -> pops

def status():
    s = rd(STATUS); c = rd(CREDIT)
    return s, (s >> 4) & 1, (s >> 2) & 1, c

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        s, avail, ur, c = status()
        print("STATUS=0x%08x avail=%d underrun=%d CREDIT=%d" % (s, avail, ur, c))
    elif cmd == "setup":
        # Receiver-side setup for a sustained soak: immediate per-pop credit
        # release so the far-end sender's credit actually recovers as we drain.
        wr(REL_THRESHOLD, 0)
        print("setup: REL_THRESHOLD=0 (immediate per-pop credit release)")
    elif cmd == "flush":
        wr(CTRL, 0x2)                     # EN=0, FLUSH=1
        s, avail, ur, c = status()
        print("flushed; STATUS=0x%08x avail=%d CREDIT=%d" % (s, avail, c))
    elif cmd == "drain":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 64
        popped = 0
        for k in range(n):
            s, avail, ur, c0 = status()
            if not avail:
                print("EMPTY after %d pops (STATUS=0x%08x CREDIT=%d)" % (popped, s, c0))
                break
            length, w = drain_one()
            _, _, _, c1 = status()
            pay = w[2] if len(w) > 2 else 0
            cpl = w[3] if len(w) > 3 else 0
            ok = "OK" if cpl == (pay ^ 0xFFFFFFFF) else "??"
            print("pop%-3d len=%d credit %d->%d (d=%+d) pay=0x%08x %s"
                  % (popped, length, c0, c1, c1 - c0, pay, ok))
            popped += 1
        print("TOTAL_POPPED=%d" % popped)
    elif cmd == "vseq":
        # vseq <start> <count>: drain <count> pkts, check tag==start+k byte-exact, in order
        import time as _t
        start = int(sys.argv[2], 0); cnt = int(sys.argv[3])
        good = bad = drained = 0
        for k in range(cnt):
            s, avail, ur, c = status()
            if not avail:
                for _ in range(200):           # wait for in-flight packet
                    _t.sleep(0.002); s, avail, ur, c = status()
                    if avail: break
                if not avail: break
            length, w = drain_one(); drained += 1
            pay = w[2] if len(w) > 2 else 0
            cpl = w[3] if len(w) > 3 else 0
            exp = (start + k) & 0xFFFFFFFF
            if pay == exp and cpl == (pay ^ 0xFFFFFFFF): good += 1
            else: bad += 1
        print("VSEQ start=0x%08x cnt=%d drained=%d good=%d bad=%d"
              % (start, cnt, drained, good, bad))
        sys.exit(0 if (good == cnt and bad == 0) else 1)
    elif cmd == "verify":
        # verify: <hexcsv of expected payload tags> -- drain, check byte-exact in order
        exp = [int(x, 0) & 0xFFFFFFFF for x in sys.argv[2].split(",")]
        got = []
        for _ in range(len(exp) + 8):
            s, avail, ur, c = status()
            if not avail: break
            length, w = drain_one()
            if len(w) > 2: got.append(w[2])
        found = i = 0
        for e in exp:
            while i < len(got) and got[i] != e: i += 1
            if i < len(got): found += 1; i += 1
        print("DELIVERY(drained): %d/%d byte-exact in order; popped=%d"
              % (found, len(exp), len(got)))
        sys.exit(0 if found == len(exp) else 1)
