#!/usr/bin/env python3
# tl37.py - TideLink v37 (PHY V2, 6.25 MHz link) bring-up helper. /dev/mem mmap.
# v37 = v36 recipe (6.25 MHz / 160 ns) + the SW word-pin override now wired into
# the v2 chiplet controller (HEAD 69a9a8d). Register surface identical to v36
# EXCEPT SWI_BIT_SLIP_LO (slot 0x1, 0x44032104) now also carries:
#   [27:24] = manual global word pin
#   [28]    = auto-disable (1 = force manual, bypass WORD_PIN_AUTO exact-match)
# POR = autonomous (auto_dis=0). This helper adds the word-pin sweep commands.
#
# Usage (as root): python3 tl37.py <cmd> [args]
#   probe [N [GAP]]   one-line decoded obs snapshot xN
#   rd ADDR | wr ADDR VAL
#   lockthresh        wr 0x44032160 = 0x55555555  (per-lane Hamming thresh 3->5)
#   hold              slot0=1
#   arm               slot0=1,10ms,slot0=3,2ms,slot0=1  (fresh sweep under hold)
#   freeze            slot0=0x2  (drop training, latch alignment, FC data carriers)
#   release           slot0=0
#   recal             pulse slot0 bit1 keeping bit0 as-is
#   txword VAL        write VAL to 0x44000000 (master M->S data test)
#   rxword            read 0x44010000 (slave local RX FIFO)
#   wpread            decode SWI_BIT_SLIP_LO: slip[23:0], word_pin[27:24], auto_dis[28]
#   wpset WP [AUTO]   set word_pin=WP, auto_dis=AUTO(default 1), PRESERVE slip[23:0]
#   wpauto            restore autonomous: auto_dis=0, word_pin=0, preserve slip[23:0]
#   wpsweep [GAP]     walk word_pin 0..15 (auto_dis=1), after each: sleep GAP(0.2s),
#                     read+decode 0x108. Logs every wp -> 0x108. Reports hits
#                     (fcsm==4 and cr==1).
import mmap, struct, os, sys, time, ctypes

PAGE = 4096
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
maps = {}
def mm(addr):
    base = addr & ~(PAGE - 1)
    if base not in maps:
        maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                               mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return maps[base], addr - base
# SoC Labs 2026-07-09: rd/wr MUST be single aligned 32-bit bus accesses.
# struct.pack_into/unpack_from on this target emit ~5 AHB beats per logical poke
# (the "5x over-advance phantom"): W1P bits pulse 5x, POP-on-read FIFOs (rxword
# @0x44010000) consume 5x, and wpsweep read-loops perturb what they measure.
# ctypes.c_uint32.from_buffer is exactly one aligned load/store per .value. Do
# not revert to struct. (matches tl39.py, commit 7ce05c6)
def _u32(a):
    m, o = mm(a); return ctypes.c_uint32.from_buffer(m, o)
def rd(a):
    return _u32(a).value
def wr(a, v):
    _u32(a).value = v & 0xFFFFFFFF

R8       = 0x44032100   # slot0: [0] swi_training_mode  [1] SWI_RECAL
SLIPLO   = 0x44032104   # SWI_BIT_SLIP_LO: [23:0] slip, [27:24] word_pin, [28] auto_dis
OBS      = 0x44032108   # lk/flt/cal/fcsm/llrx/cr/ck/...
TRAINCFG = 0x4403210C
TRAINST  = 0x44032110
SYNCCNT  = 0x44032114
PHYID    = 0x4403211C
NEGO     = 0x44032094
OBSCAL   = 0x44032198   # [3:0] V2 cal FSM state, [20] live training_mode
WLCTRL   = 0x44030208
LOCKTHR  = 0x44032160   # per-lane 3-bit Hamming lock threshold

def popc(x): return bin(x).count("1")

def decode_obs(s):
    lk = s & 0xff; flt = (s >> 8) & 0xff; cd = (s >> 16) & 1; fcsm = (s >> 17) & 7
    llrx = (s >> 21) & 3; cr = (s >> 23) & 1; ck = (s >> 24) & 1
    llv = (s >> 29) & 1; a2l = (s >> 30) & 1; full = (s >> 31) & 1
    return dict(lk=lk, flt=flt, cal=cd, fcsm=fcsm, llrx=llrx, cr=cr, ck=ck,
                llv=llv, a2l=a2l, full=full)

def probe():
    s   = rd(OBS); slot0 = rd(R8); cal = rd(OBSCAL); ng = rd(NEGO)
    ts  = rd(TRAINST); sync = rd(SYNCCNT) >> 16
    d = decode_obs(s)
    print("lk=0x%02x(%d) flt=0x%02x cal=%d fcsm=%d llrx=%d cr=%d ck=%d llv=%d a2l=%d full=%d | "
          "slot0=%d cstate=%d tm=%d | nego st=%d done=%d err=%d won=%d lost=%d | "
          "train ok=%d fail=%d prog=%d tst=%d plk=0x%02x | sync=%d obs=0x%08x"
          % (d['lk'], popc(d['lk']), d['flt'], d['cal'], d['fcsm'], d['llrx'],
             d['cr'], d['ck'], d['llv'], d['a2l'], d['full'],
             slot0 & 3, cal & 0xf, (cal >> 20) & 1,
             ng & 0xf, (ng >> 4) & 1, (ng >> 5) & 1, (ng >> 6) & 1, (ng >> 7) & 1,
             ts & 1, (ts >> 1) & 1, (ts >> 2) & 1, (ts >> 4) & 0xf, (ts >> 8) & 0xff,
             sync, s), flush=True)

def wpread():
    v = rd(SLIPLO)
    return v & 0xffffff, (v >> 24) & 0xf, (v >> 28) & 1

cmd = sys.argv[1]
if cmd == "probe":
    n   = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    gap = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    for i in range(n):
        print("t=%6.2f" % (i * gap), end=" ")
        probe()
        if i < n - 1: time.sleep(gap)
elif cmd == "rd":
    print("0x%08x" % rd(int(sys.argv[2], 16)))
elif cmd == "wr":
    wr(int(sys.argv[2], 16), int(sys.argv[3], 16))
elif cmd == "lockthresh":
    wr(LOCKTHR, 0x55555555)
    print("lockthresh=5 (0x%08x)" % rd(LOCKTHR))
elif cmd == "hold":
    wr(R8, 0x1)
elif cmd == "arm":
    wr(R8, 0x1); time.sleep(0.010)
    wr(R8, 0x3); time.sleep(0.002)
    wr(R8, 0x1)
    print("armed (hold+recal pulse)")
elif cmd == "freeze":
    wr(R8, 0x2)
    print("frozen (slot0=0x2, S_CANCEL latched alignment, FC data carriers)")
elif cmd == "release":
    wr(R8, 0x0)
    print("released")
elif cmd == "recal":
    keep = rd(R8) & 1
    wr(R8, keep | 2); time.sleep(0.002); wr(R8, keep)
    print("recal pulsed (hold=%d)" % keep)
elif cmd == "txword":
    wr(0x44000000, int(sys.argv[2], 16))
    print("tx done")
elif cmd == "rxword":
    print("0x%08x" % rd(0x44010000))
elif cmd == "wpread":
    slip, wp, ad = wpread()
    print("SWI_BIT_SLIP_LO=0x%08x  slip[23:0]=0x%06x  word_pin[27:24]=%d  auto_dis[28]=%d  (raw=0x%08x)"
          % (rd(SLIPLO), slip, wp, ad, rd(SLIPLO)))
elif cmd == "wpset":
    wp = int(sys.argv[2]) & 0xf
    ad = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    slip, _, _ = wpread()
    val = (ad << 28) | (wp << 24) | slip
    wr(SLIPLO, val)
    rb = rd(SLIPLO)
    print("wpset word_pin=%d auto_dis=%d slip=0x%06x -> wrote 0x%08x readback 0x%08x"
          % (wp, ad, slip, val, rb))
elif cmd == "wpauto":
    slip, _, _ = wpread()
    wr(SLIPLO, slip)  # word_pin=0, auto_dis=0
    print("wpauto restored (auto_dis=0, word_pin=0, slip=0x%06x) readback 0x%08x"
          % (slip, rd(SLIPLO)))
elif cmd == "wpsweep":
    gap = float(sys.argv[2]) if len(sys.argv) > 2 else 0.2
    slip, _, _ = wpread()
    print("== word_pin sweep 0..15 (preserving slip[23:0]=0x%06x, gap=%.2fs) ==" % (slip, gap))
    hits = []
    for wp in range(16):
        val = (1 << 28) | (wp << 24) | slip
        wr(SLIPLO, val)
        time.sleep(gap)
        s = rd(OBS); d = decode_obs(s)
        mark = ""
        if d['fcsm'] == 4 and d['cr'] == 1:
            mark = "  <== HIT (fcsm=4 cr=1)"; hits.append(wp)
        print("wp=%2d  0x108=0x%08x  lk=0x%02x flt=0x%02x cal=%d fcsm=%d llrx=%d cr=%d ck=%d llv=%d a2l=%d full=%d%s"
              % (wp, s, d['lk'], d['flt'], d['cal'], d['fcsm'], d['llrx'],
                 d['cr'], d['ck'], d['llv'], d['a2l'], d['full'], mark), flush=True)
    if hits:
        print("SWEEP-RESULT: HIT at word_pin=%s" % hits)
    else:
        print("SWEEP-RESULT: no word_pin yields fcsm=4+cr=1")
else:
    print("unknown cmd", cmd); sys.exit(2)
