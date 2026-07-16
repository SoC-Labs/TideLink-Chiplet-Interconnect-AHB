#!/usr/bin/env python3
# tl36.py - TideLink v36 (PHY V2, 6.25 MHz link) bring-up helper. /dev/mem mmap.
# v36 = v35 recipe at the silicon-validated 6.25 MHz / 160 ns link rate; the
# register surface is identical to v35 (PHY-version-agnostic), so this is
# tl35.py + an explicit `freeze` (slot0=0x2) and `lockthresh` convenience cmd.
# Usage (as root): python3 tl36.py <cmd> [args]
#   probe [N [GAP]]   one-line decoded obs snapshot xN
#   rd ADDR | wr ADDR VAL
#   lockthresh        wr 0x44032160 = 0x55555555  (per-lane Hamming thresh 3->5)
#   hold              slot0=1  (swi_training_mode hold + TX training drive)
#   arm               slot0=1, 10ms, slot0=3, 2ms, slot0=1  (FIX-F Opt-2 fresh sweep under hold)
#   freeze            slot0=0x2  (drop training, HOLD SWI_RECAL high -> S_CANCEL/S_DONE,
#                                 latched per-lane alignment applied, carriers -> FC data)
#   release           slot0=0
#   recal             pulse slot0 bit1 keeping bit0 as-is
#   txword VAL        write VAL to 0x44000000 (master M->S data test)
#   rxword            read 0x44010000 (slave local RX FIFO)
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
# @0x44010000) consume 5x. ctypes.c_uint32.from_buffer is exactly one aligned
# load/store per .value. Do not revert to struct. (matches tl39.py, commit 7ce05c6)
def _u32(a):
    m, o = mm(a); return ctypes.c_uint32.from_buffer(m, o)
def rd(a):
    return _u32(a).value
def wr(a, v):
    _u32(a).value = v & 0xFFFFFFFF

R8       = 0x44032100   # slot0: [0] swi_training_mode(hold+drive)  [1] SWI_RECAL
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

def probe():
    s   = rd(OBS); slot0 = rd(R8); cal = rd(OBSCAL); ng = rd(NEGO)
    ts  = rd(TRAINST); sync = rd(SYNCCNT) >> 16
    lk = s & 0xff; flt = (s >> 8) & 0xff; cd = (s >> 16) & 1; fcsm = (s >> 17) & 7
    llrx = (s >> 21) & 3; cr = (s >> 23) & 1; ck = (s >> 24) & 1
    llv = (s >> 29) & 1; a2l = (s >> 30) & 1; full = (s >> 31) & 1
    print("lk=0x%02x(%d) flt=0x%02x cal=%d fcsm=%d llrx=%d cr=%d ck=%d llv=%d a2l=%d full=%d | "
          "slot0=%d cstate=%d tm=%d | nego st=%d done=%d err=%d won=%d lost=%d | "
          "train ok=%d fail=%d prog=%d tst=%d plk=0x%02x | sync=%d obs=0x%08x"
          % (lk, popc(lk), flt, cd, fcsm, llrx, cr, ck, llv, a2l, full,
             slot0 & 3, cal & 0xf, (cal >> 20) & 1,
             ng & 0xf, (ng >> 4) & 1, (ng >> 5) & 1, (ng >> 6) & 1, (ng >> 7) & 1,
             ts & 1, (ts >> 1) & 1, (ts >> 2) & 1, (ts >> 4) & 0xf, (ts >> 8) & 0xff,
             sync, s), flush=True)

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
else:
    print("unknown cmd", cmd); sys.exit(2)
