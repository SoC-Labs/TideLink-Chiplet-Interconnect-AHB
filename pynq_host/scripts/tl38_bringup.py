#!/usr/bin/env python3
"""tl38_bringup.py — V2 (v38 epoch-deskew) manual hold/recal/freeze bring-up.

Synthesised from the 2026-06-13 multi-agent analysis:
  * the on-chip autoneg FSM perpetually re-asserts training_mode (master holds
    it until bilateral lk=0xff, which never happens) -> it fights host pokes,
    so DISABLE auto-train first (0x10C=0).
  * both calibrators free-run S_SWEEP simultaneously and never present a stable
    reference -> HOLD training (slot0=0x1) on both to stop the mutual sweep,
    THEN pulse a single coordinated recal, THEN FREEZE (slot0=0x2) from the
    held lk=ff state (never slot0=0x0 on V2 -> short-timeout S_VALIDATE).
  * lane-checker match threshold must relax 0x160 3->5; the skewed RX (die_a /
    z2_02 non-flip) must force word_pin=5 (0x104=0x15000000).

Runs ON the board (mmap /dev/mem). Control regs base 0x44032000.

Commands:
  setup [wp]   auto-train off + thresh relax (+ word_pin=5 if 'wp') + HOLD(0x1)
  recal        slot0: 0x3 -> (10ms) -> 0x1   (single recal pulse, training held)
  freeze       slot0 = 0x2
  probe        decode 0x108 + OBS_CAL
"""
import mmap, struct, os, sys, time

PAGE = 4096
BASE = 0x44032000
R_SLOT0, R_BITSLIP, R_LANE, R_TRAINCFG, R_THRESH, R_OBSCAL = 0x100, 0x104, 0x108, 0x10C, 0x160, 0x198

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
def rd(o): return struct.unpack_from("<I", m, o)[0]
def wr(o, v): struct.pack_into("<I", m, o, v & 0xFFFFFFFF)

def probe():
    v = rd(R_LANE); c = rd(R_OBSCAL) & 0xF
    st = {0:"IDLE",1:"ARM",2:"SWEEP",4:"DONE",5:"CANCEL",6:"HOLD",9:"VALIDATE"}.get(c, "?")
    print("  0x108=0x%08x lk=0x%02x ft=0x%02x cal=%d fcsm=%d cr=%d ck=%d llv=%d | cal_state=%d(%s) slot0=0x%x wp=%d"
          % (v, v & 0xff, (v >> 8) & 0xff, (v >> 16) & 1, (v >> 17) & 7,
             (v >> 23) & 1, (v >> 24) & 1, (v >> 29) & 1, c, st,
             rd(R_SLOT0), (rd(R_BITSLIP) >> 24) & 0xf))

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "setup":
        wr(R_TRAINCFG, 0x00000000)               # train_auto_en=0
        wr(R_THRESH,   0x55555555)               # lane-checker Hamming thresh 3->5
        if len(sys.argv) > 2 and sys.argv[2] == "wp":
            wr(R_BITSLIP, 0x15000000)            # word_pin=5, auto_dis=1
        wr(R_SLOT0, 0x1)                         # HOLD training (stop mutual sweep)
        time.sleep(0.05)
        print("  setup: train_auto_en=0 thresh=0x%08x bitslip=0x%08x slot0=0x%x"
              % (rd(R_THRESH), rd(R_BITSLIP), rd(R_SLOT0)))
    elif cmd == "recal":
        wr(R_SLOT0, 0x3); time.sleep(0.010)      # recal asserted, training held
        wr(R_SLOT0, 0x1); time.sleep(0.02)       # recal falling edge -> re-sweep under hold
        probe()
    elif cmd == "freeze":
        wr(R_SLOT0, 0x2); time.sleep(0.05)       # latch slip/phase, drop training, epoch anchors
        probe()
    elif cmd == "probe":
        probe()
    else:
        sys.exit("unknown cmd " + cmd)
