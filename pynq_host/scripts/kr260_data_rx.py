#!/usr/bin/env python3
"""kr260_data_rx.py — CORRECT strided RX-FIFO reader for the TideLink pair.

⚠️ WHY THIS EXISTS (2026-07-22, hard-won on real KR260 hardware):
The RX FIFO at ahb_fifo (PS-visible 0xA401_0000) is a STREAMING FIFO — each
delivered packet is queued at an ADVANCING 16-byte offset (pkt k payload at
+0x10*k+8), and read_ptr advances by (len+1)*4 when you read at read_target_addr
(tidelink_fifo_ctrl.sv:167,179). A receiver that reads a FIXED offset (e.g. 0x8)
only ever sees packet 0 and reports every later packet as "dropped" — which
manufactured a multi-day phantom "intermittent delivery / framer-lock lottery".
There is NO such lottery: read the FIFO at strided offsets and delivery is
reliable (measured 12/12 byte-exact, in order). ALWAYS read strided.

Usage (on the board, as root):
  python3 kr260_data_rx.py dump [N]      # dump N (default 16) FIFO entries, strided
  python3 kr260_data_rx.py check <hexcsv>  # verify a comma-separated list of expected
                                           # payload tags appear in order, byte-exact
Data apertures are PS-visible at 0xA400_0000 (ahb_tx) / 0xA401_0000 (ahb_fifo)
on KR260 (the FPD HPM0_FPD window). NOT 0x8400_0000 (internal decode; writing it
HARD-WEDGES the PS — a JTAG POR is the only recovery).
"""
import mmap, os, struct, sys

RX_BASE = 0xA4010000
STRIDE  = 0x10          # bytes per length-2 packet (4 words); adjust for other lengths
PAY_OFF = 0x08          # payload word offset within a packet slot


def _open():
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    return fd, mmap.mmap(fd, 0x2000, offset=RX_BASE)


def entries(n):
    fd, m = _open()
    out = []
    for k in range(n):
        base = k * STRIDE
        m.seek(base)
        w = [struct.unpack("<I", m.read(4))[0] for _ in range(4)]
        out.append((k, base, w))
    m.close(); os.close(fd)
    return out


def dump(n=16):
    for k, base, w in entries(n):
        if w[0] == 0 and w[2] == 0:
            continue
        hdr, pay, cpl = w[0], w[2], w[3]
        ok = "OK" if cpl == (pay ^ 0xFFFFFFFF) else "??"  # xsend convention: word3 = ~payload
        print("pkt%-2d @+0x%03x: hdr=0x%08x pay=0x%08x cpl=0x%08x %s"
              % (k, base, hdr, pay, cpl, ok))


def check(expected):
    got = [w[2] for _, _, w in entries(len(expected) + 8)]
    found, i = 0, 0
    for exp in expected:
        while i < len(got) and got[i] != exp:
            i += 1
        if i < len(got):
            found += 1; i += 1
    print("DELIVERY (strided): %d / %d byte-exact, in order" % (found, len(expected)))
    return found == len(expected)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "dump"
    if cmd == "dump":
        dump(int(sys.argv[2]) if len(sys.argv) > 2 else 16)
    elif cmd == "check":
        exp = [int(x, 0) & 0xFFFFFFFF for x in sys.argv[2].split(",")]
        sys.exit(0 if check(exp) else 1)
    else:
        sys.exit(__doc__)
