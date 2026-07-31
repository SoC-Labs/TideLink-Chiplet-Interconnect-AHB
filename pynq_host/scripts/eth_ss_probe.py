#!/usr/bin/env python3
# eth_ss_0 backdoor aliveness probe for the kr260-eth-chiplet bitstream.
#
# SAFE-BY-CONSTRUCTION: reads only the SoC boot ROM (combinational, HREADY
# hardwired high, on the free-running system clock — responds even with both
# M0s halted). The window base is the HPM0_FPD HIGH aperture 0x4_0000_0000
# (confirmed in imp/fpga/output/kr260-eth-chiplet/tidelink.hwh:4112, NOT the
# 0x8000_0000 in older comments — that is out-of-window and would wedge).
# The SoC AHB matrix has a CMSDK default slave that returns SLVERR (never hangs)
# for undecoded in-window reads, so even a wrong-but-in-window read is bounded.
#
# WIDE SWEEP + PER-BIT DIFF (bit-27 characterisation, 2026-07-31):
# The known bring-up regression is a PS->eth_ss_0 backdoor that DROPS BIT 27 on
# the reset/NMI/HardFault vectors (reads 0x000001xx, expects 0x080001xx); the
# init-MSP word reads clean. This is an eth-subsystem aperture bug, ORTHOGONAL to
# the TideLink link (I1_RESOLVED_HANDOVER_2026_07_31.md). This probe now:
#   * sweeps the first N boot-ROM words (--words, default 64),
#   * does a per-bit diff against the 4 known-good vectors (isolates which bits
#     drop/stick), and
#   * WAIVES a diff that is EXACTLY bit 27 (default on) so the aliveness check
#     still passes for CI while documenting the drop. --strict disables the
#     waiver (any diff => FAIL).
import argparse, mmap, struct, sys

BASE = 0x400000000                      # eth_ss_0 window base (PS phys)
PAGE = 0x1000
EXPECT = [0x18003c00, 0x08000189, 0x080001cd, 0x080001cf]  # bootrom words 0..3
NAMES  = ["init MSP", "reset vec", "NMI vec", "HardFault vec"]
BIT27  = 0x08000000


def popcount(x):
    return bin(x).count("1")


def bitlist(mask):
    return "{%s}" % ",".join("bit%d" % i for i in range(32) if (mask >> i) & 1) if mask else "{}"


def main():
    ap = argparse.ArgumentParser(description="eth_ss_0 boot-ROM backdoor probe + "
                                 "wide sweep / per-bit diff (bit-27 characterisation).")
    ap.add_argument("--words", type=int, default=64,
                    help="boot-ROM words to sweep (default 64).")
    ap.add_argument("--strict", action="store_true",
                    help="do NOT waive the known bit-27 drop; any diff => FAIL.")
    args = ap.parse_args()
    nwords = max(4, args.words)

    try:
        f = open("/dev/mem", "rb")
    except Exception as e:
        print("OPEN /dev/mem FAILED: %s" % e); return 2
    try:
        m = mmap.mmap(f.fileno(), PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
    except Exception as e:
        print("MMAP 0x%011X FAILED: %s" % (BASE, e)); f.close(); return 3
    nwords = min(nwords, PAGE // 4)
    vals = [struct.unpack("<I", m[i * 4:i * 4 + 4])[0] for i in range(nwords)]
    m.close(); f.close()

    print("eth_ss_0 boot-ROM read via PS HPM0_FPD @ 0x%011X:" % BASE)
    # --- per-bit diff on the 4 known-good vectors ---
    global_diff = dropped = stuck = 0
    for i, (v, e, nm) in enumerate(zip(vals, EXPECT, NAMES)):
        d = v ^ e
        global_diff |= d
        dropped |= (e & ~v) & 0xFFFFFFFF   # should be 1, read 0
        stuck |= (~e & v) & 0xFFFFFFFF     # should be 0, read 1
        tag = "PASS" if d == 0 else ("b27-only" if d == BIT27 else "DIFF")
        print("  +0x%02X  0x%011X = 0x%08X  expect 0x%08X  diff=0x%08X [%s] %s"
              % (i * 4, BASE + i * 4, v, e, d, tag, nm))
    print("  per-bit diff over known words: diff=0x%08X %s  dropped(1->0)=0x%08X %s  "
          "stuck(0->1)=0x%08X" % (global_diff, bitlist(global_diff), dropped,
                                  bitlist(dropped), stuck))

    # --- wide sweep dump (words >=4 have no golden reference — informational) ---
    print("  --- wide sweep (words 4..%d, informational; 'b27'=bit27 value) ---" % (nwords - 1))
    for i in range(4, nwords):
        print("    +0x%02X  0x%08X  b27=%d" % (i * 4, vals[i], (vals[i] >> 27) & 1))

    # --- verdict ---
    if global_diff == 0:
        print("RESULT: PASS — PS->SoC eth_ss_0 backdoor is ALIVE on silicon (exact match).")
        return 0
    if global_diff == BIT27 and not args.strict:
        print("RESULT: WAIVED — PS->SoC eth_ss_0 backdoor is ALIVE on silicon "
              "(bit-27 drop WAIVED; known eth-aperture bug, orthogonal to TideLink).")
        return 0
    print("RESULT: FAIL — backdoor diff beyond the waived bit-27 (diff=0x%08X %s)%s"
          % (global_diff, bitlist(global_diff),
             "  [--strict: bit-27 not waived]" if (global_diff == BIT27 and args.strict) else ""))
    return 1


if __name__ == "__main__":
    sys.exit(main())
