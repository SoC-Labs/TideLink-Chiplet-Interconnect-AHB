#!/usr/bin/env python3
"""Emit the sideband CRC breadth sweep case list: 'name VAR=val ...' per line."""
import sys
out = []
def add(name, **kw):
    out.append(name + " " + " ".join(f"{k}={v}" for k, v in kw.items()))
S = (0, 1, 2)
for d in ("ab", "ba"):
    for s in S:
        add(f"ctl_none_{d}_s{s}", SB_DIR=d, SB_MODE="none", SB_LEN=2, SB_SEED=s)
    # A. position sweep, single message, idle link
    for L, poss in ((0, (0, 1)), (2, (0, 1, 2, 3)), (6, (0, 1, 3, 6, 7))):
        for p in poss:
            for s in S:
                add(f"pos_L{L}_p{p}_{d}_s{s}", SB_DIR=d, SB_MODE="pos", SB_LEN=L, SB_POS=p, SB_SEED=s)
    # C. traffic density: spacing between AHB-TX words (packets) of one message.
    #    gap=0 back-to-back, 4 (default), 16, 64, 256 near-idle.  L=6 (8 packets): first, middle, last.
    for g in (0, 16, 64, 256):
        for p in (1, 3, 7):
            for s in S:
                add(f"gap{g}_L6_p{p}_{d}_s{s}", SB_DIR=d, SB_MODE="pos", SB_LEN=6, SB_GAP=g, SB_POS=p, SB_SEED=s)
    for g in (0, 64):
        for p in (0, 1):
            for s in S:
                add(f"gap{g}_L2_p{p}_{d}_s{s}", SB_DIR=d, SB_MODE="pos", SB_LEN=2, SB_GAP=g, SB_POS=p, SB_SEED=s)
    for g in (0, 64):
        for s in S:
            add(f"ctl_none_gap{g}_{d}_s{s}", SB_DIR=d, SB_MODE="none", SB_LEN=6, SB_GAP=g, SB_SEED=s)
# B. byte/bit sweep (ab, seed 0): middle (p1) and last (p3) packet
for p in (1, 3):
    for b in range(4, 12):
        add(f"byte{b}_bit0_p{p}", SB_MODE="pos", SB_LEN=2, SB_POS=p, SB_BYTE=b, SB_BIT=0)
    for bit in (3, 7):
        add(f"byte5_bit{bit}_p{p}", SB_MODE="pos", SB_LEN=2, SB_POS=p, SB_BYTE=5, SB_BIT=bit)
# D. diagnostic forces on the receiver (ab)
for f in ("l9b", "l9c", "both"):
    for tag, kw in (("p0", dict(SB_POS=0)), ("p1", dict(SB_POS=1)), ("p3", dict(SB_POS=3)),
                    ("gap0_L6_p3", dict(SB_POS=3, SB_LEN=6, SB_GAP=0)), ("L6_p1", dict(SB_POS=1, SB_LEN=6))):
        for s in (0, 1):
            k = dict(SB_MODE="pos", SB_LEN=2, SB_FORCE=f, SB_SEED=s); k.update(kw)
            add(f"force_{f}_{tag}_s{s}", **k)
    for d in ("ba",):
        add(f"force_{f}_p1_{d}_s0", SB_DIR=d, SB_MODE="pos", SB_LEN=2, SB_POS=1, SB_FORCE=f)
print("\n".join(out))
