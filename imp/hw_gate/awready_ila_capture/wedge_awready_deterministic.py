#!/usr/bin/env python3
# =============================================================================
# wedge_awready_deterministic.py  —  DELIBERATE awready-wedge inducer (ATTENDED)
# -----------------------------------------------------------------------------
#   *** THIS SCRIPT DELIBERATELY BRICKS THE DIE IT RUNS ON. ***
#
#   It is the DIRECTED stimulus for the two-core ILA capture of the D2D
#   write-wedge root (hypothesis H1: the AW-node a2l_fc_replay window fills on
#   peer-ACK/credit silence and s_axi_awready dies with no self-clear).
#
#   Mechanism (documented in kr260_credit_tx.py): a blind batch write to the TX
#   aperture ahb_tx=0xA4000000 that OUTRUNS the peer's returned credit
#   deterministically fills the a2l_fc_replay outstanding window -> a2l_full=1
#   -> s_axi_awready low permanently.  This is the credit/FC layer (H1) itself,
#   NOT the XHB500/ahb_sub boundary that the errinject tooling exercises.
#
#   0xA4000000 (ahb_tx) and 0x84030000 (credit APB) are the bare-link addresses
#   that the standing safety rule says NEVER blind-write, PRECISELY because
#   doing so wedges the PS.  This tool does the forbidden thing on purpose, once,
#   for the capture.  It therefore requires:
#     * explicit human authorization for THIS board-brick (David's call — a
#       general "run HW validation" directive does NOT cover it);
#     * the ILA armed FIRST (trigger = sustained s_axi_awvalid & ~s_axi_awready);
#     * por_recover.sh (JTAG-POR) staged to un-brick the die afterward;
#     * board-lease held for the target die.
#
#   Runs ON the KR260 (mmaps /dev/mem).  Mirrors kr260_credit_tx.send_packet but
#   REMOVES the credit-gating wait loop — that removal is the whole point.
#
#   SAFETY INTERLOCK: refuses to write anything unless the caller passes
#   --i-understand-this-bricks-the-board.  Without it, it only reads + reports
#   (a dry run), so no other session can wedge a board by launching it blind.
# =============================================================================
import os, sys, mmap, ctypes, time, argparse

TX_BASE   = 0xA4000000            # ahb_tx aperture  (blind write here == wedge)
APB_BASE  = 0x84030000            # TideLink FIFO APB
OFF_PAIR_COUNTER = 0x2028         # REG_PAIR_CREDIT_COUNTER (peer credit, local view; RO)
OFF_PAIR_ENABLE  = 0x2030         # REG_PAIR_CREDIT_ENABLE

_fd = None
_maps = {}
def _mm(a):
    global _fd
    if _fd is None:
        _fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    b = a & ~0xFFF
    if b not in _maps:
        _maps[b] = mmap.mmap(_fd, 0x4000 if b == APB_BASE else 0x1000,
                             mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return _maps[b], a - b
def rd(a):
    m, o = _mm(a); return ctypes.c_uint32.from_buffer(m, o).value
def wr(a, v):
    m, o = _mm(a); ctypes.c_uint32.from_buffer(m, o).value = v & 0xFFFFFFFF

def pair_credit():
    return rd(APB_BASE + OFF_PAIR_COUNTER)

def send_packet(tag, length=2):
    # identical framing to kr260_credit_tx.send_packet: [hdr(len), dest, tag, ~tag]
    m, o = _mm(TX_BASE)
    hdr = (length & 0xFFF) << 20
    words = [hdr, 0x00000000, tag & 0xFFFFFFFF, (tag ^ 0xFFFFFFFF) & 0xFFFFFFFF]
    for j, v in enumerate(words):
        ctypes.c_uint32.from_buffer(m, o + 4 * j).value = v

def main():
    ap = argparse.ArgumentParser(description="DELIBERATE awready-wedge inducer (ATTENDED, bricks the die).")
    ap.add_argument("--start", type=lambda x: int(x, 0), default=0xE0DE0000,
                    help="first packet tag (default 0xE0DE0000).")
    ap.add_argument("--count", type=int, default=64,
                    help="packets to blind-send with NO credit gating (default 64 >> any window).")
    ap.add_argument("--len", type=int, default=2, help="payload words (delta = len+2).")
    ap.add_argument("--i-understand-this-bricks-the-board", dest="armed", action="store_true",
                    help="REQUIRED to actually write. Without it this is a read-only dry run.")
    a = ap.parse_args()
    delta = a.len + 2

    c0 = pair_credit()
    print("[pre] pair_credit=%d  delta=%d  count=%d  -> will outrun by ~%d packets"
          % (c0, delta, a.count, a.count - (c0 // delta if delta else 0)))

    if not a.armed:
        print("DRY RUN: no --i-understand-this-bricks-the-board flag -> refusing to write.")
        print("         (this guard exists so no session wedges a board by accident.)")
        return 0

    print("!!! ARMING: blind-sending %d packets to ahb_tx=0x%08X with NO credit gating." % (a.count, TX_BASE))
    print("!!! The ILA must already be armed on (s_axi_awvalid & ~s_axi_awready). POR recovery must be staged.")
    sent = 0
    for i in range(a.count):
        send_packet((a.start + i) & 0xFFFFFFFF, a.len)   # NO wait-for-credit: this is the deliberate overrun
        sent += 1
    # a read AFTER the overrun will itself likely wedge (PS bus) — that IS the signature; wrap it.
    try:
        cN = pair_credit()
        print("SENT=%d  pair_credit_now=%d  (no PS wedge on readback — check ILA for awready state)" % (sent, cN))
    except Exception as e:
        print("SENT=%d  READBACK WEDGED (%s) == PS-bus wedge signature. Capture the ILA, then JTAG-POR." % (sent, e))
    return 0

if __name__ == "__main__":
    sys.exit(main())
