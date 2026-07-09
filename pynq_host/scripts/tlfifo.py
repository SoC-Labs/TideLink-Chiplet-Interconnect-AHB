#!/usr/bin/env python3
# Correct TideLink RX drain: the window at 0x8401_0000 is a PACKET FIFO with a moving
# read pointer and pop-on-terminal-read (tidelink_fifo_ctrl.sv:107,118-119,141,201-214).
# It is NOT an addressed ring. Rules: start at offset 0, read strictly sequentially to
# (len+2) words, never random-access, NEVER write to the window.
import mmap, os, sys, ctypes
PAGE = 4096
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
maps = {}
def mm(a):
    b = a & ~(PAGE - 1)
    if b not in maps:
        maps[b] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return maps[b], a - b
def rd(a):
    m, o = mm(a); return ctypes.c_uint32.from_buffer(m, o).value

FIFO   = 0x84010000
STATUS = 0x44032010    # bit4 = packet available
CREDIT = 0x4403200C    # current_credit_count (plain RO, no side effect)

def drain_one(base=FIFO):
    hdr    = rd(base + 0)              # arms read-side length; clears committed IRQ
    length = (hdr >> 20) & 0xFFF       # payload words
    total  = length + 2                # hdr + dest + payload
    words  = [hdr] + [rd(base + i*4) for i in range(1, total)]
    return length, words               # read of (len+1)*4 == read_target -> pops packet

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "drain"
    if cmd == "status":
        s = rd(STATUS); c = rd(CREDIT)
        print("STATUS=0x%08x avail=%d underrun=%d CREDIT=%d" % (s, (s>>4)&1, (s>>2)&1, c))
    elif cmd == "drain":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        for k in range(n):
            s = rd(STATUS)
            if not ((s >> 4) & 1):
                print("pkt%d: EMPTY (STATUS=0x%08x)" % (k, s)); break
            c0 = rd(CREDIT)
            length, w = drain_one()
            c1 = rd(CREDIT)
            print("pkt%d: len=%d credit %d->%d (delta=%d) words=%s"
                  % (k, length, c0, c1, c1-c0, " ".join("0x%08x" % x for x in w)))
