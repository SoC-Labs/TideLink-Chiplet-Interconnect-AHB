#!/usr/bin/env python3
"""tl_poke.py — minimal /dev/mem peek/poke + OBS_FC_CREDIT decode (runs ON the PYNQ).

Staged onto the boards over scp by credit_roll_campaign.sh / char_session.sh
(the unjam_fc_node.sh staged-helper pattern — NO inline python through nested
ssh quoting; it mangles). Runs as root (needs /dev/mem).

Commands:
  rd ADDR           -> "0x%08x"           (ADDR hex 0x.. or decimal)
  wr ADDR VAL       -> "wrote ADDR = VAL"
  obs               -> "OBS raw live cm ptr full" — decode of OBS_FC_CREDIT
                       @ 0x4403219C per docs/REGISTER_MAP.md:
                         [7:0]   fe_rx_credit_max (CR/CRACK word_count[15:8])
                         [15:8]  fe_rx_ptr        (ACK/NACK credit-return ptr)
                         [16]    fe_rx_is_full mirror
                         [31:24] presence marker 0xFC
                       Old (pre-2026-06-12) images read 0x00000000 -> live=0;
                       callers must treat cm/ptr as absent in that case.

A PS AXI bus error on any access kills this process with SIGBUS — callers
classify a missing output line as the BUS-ERROR jam class (the same
convention as unjam_fc_node.sh's probe).
"""
import ctypes
import mmap
import os
import sys

PAGE = 4096
OBS_FC_CREDIT = 0x4403219C

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_maps = {}


def _mm(addr):
    base = addr & ~(PAGE - 1)
    if base not in _maps:
        _maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return _maps[base], addr - base


# SoC Labs 2026-07-03: struct.pack_into/unpack_from on an mmap'd /dev/mem buffer
# emits MULTIPLE narrow bus accesses per 32-bit op on this ARMv7 PYNQ (measured
# on silicon: ~5 stores per pack_into write vs 1 for devmem2/ctypes; a2l FIFO
# wptr +5/word). Every "word" write became ~5 AHB transfers -> 5 FC packets ->
# fe credit ceiling (0x1f) exhausted -> the NACK/replay wedge that blocked
# sustained multi-packet A->B for weeks. The ctypes pointer access below is a
# SINGLE aligned u32 load/store (same fix as tl39.py / tlchar.py).
def _u32(m, o):
    return ctypes.cast(ctypes.addressof(ctypes.c_uint32.from_buffer(m, o)),
                       ctypes.POINTER(ctypes.c_uint32))


def rd(addr):
    m, o = _mm(addr)
    return int(_u32(m, o)[0])


def wr(addr, val):
    m, o = _mm(addr)
    _u32(m, o)[0] = val & 0xFFFFFFFF


def main():
    c = sys.argv[1]
    if c == "rd":
        print("0x%08x" % rd(int(sys.argv[2], 0)))
    elif c == "wr":
        a = int(sys.argv[2], 0)
        v = int(sys.argv[3], 0)
        wr(a, v)
        print("wrote 0x%08x = 0x%08x" % (a, v))
    elif c == "obs":
        v = rd(OBS_FC_CREDIT)
        live = 1 if ((v >> 24) & 0xFF) == 0xFC else 0
        print("OBS 0x%08x %d %d %d %d" % (
            v, live, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 1))
    else:
        sys.exit("unknown cmd " + c)


if __name__ == "__main__":
    main()
