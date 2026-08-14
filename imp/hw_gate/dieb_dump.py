#!/usr/bin/env python3
"""dieb_dump.py — raw dump of die_b's LOCAL shared_sram_0 landing zone.

Read-only, and a LOCAL read: it never traverses the die-to-die link, so it is
safe to run while die_a's PS is wedged (which is exactly when we need it).

Constants mirror kr260_eth_soak_fwd.py:12-14 (WINDOW / LOCAL_BASE), the proven
path for this region.

Why raw words rather than `verify`'s pass count: the pass count cannot say WHICH
address moved, and the discriminator is three-way, not two-way —
  injected marker changed          -> the injected write LANDED (B lost on return)
  only resume-stream addrs changed -> injected beat SILENTLY DROPPED while die_b
                                      kept accepting later writes
  nothing changed                  -> die_b stopped completing entirely (upstream)

  usage: dieb_dump.py [N_WORDS]      (default 32)
"""
import mmap, os, struct, sys

WINDOW = 0x400000000
LOCAL_BASE = 0x2D001000
N = int(sys.argv[1]) if len(sys.argv) > 1 else 32

phys = WINDOW + LOCAL_BASE
pagesize = mmap.PAGESIZE
pagebase = phys & ~(pagesize - 1)
pageoff = phys - pagebase
span = ((pageoff + N * 4 + pagesize - 1) // pagesize) * pagesize

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
try:
    m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ, offset=pagebase)
except Exception as e:
    print("DUMPFAIL %s" % e)
    os.close(fd)
    sys.exit(1)
words = []
for i in range(N):
    o = pageoff + i * 4
    words.append(struct.unpack("<I", m[o:o + 4])[0])
m.close()
os.close(fd)

# One line, parseable, stable ordering: idx0 first. The caller diffs pre vs post.
print("DUMP base=0x%08X n=%d %s" % (LOCAL_BASE, N, " ".join("%08x" % w for w in words)))
