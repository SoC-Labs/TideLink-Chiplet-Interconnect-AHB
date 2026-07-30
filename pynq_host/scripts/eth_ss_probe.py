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
import mmap, struct, sys

BASE = 0x400000000                      # eth_ss_0 window base (PS phys)
PAGE = 0x1000
EXPECT = [0x18003c00, 0x08000189, 0x080001cd, 0x080001cf]  # bootrom words 0..3
NAMES  = ["init MSP", "reset vec", "NMI vec", "HardFault vec"]

try:
    f = open("/dev/mem", "rb")
except Exception as e:
    print("OPEN /dev/mem FAILED: %s" % e); sys.exit(2)
try:
    m = mmap.mmap(f.fileno(), PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
except Exception as e:
    print("MMAP 0x%011X FAILED: %s" % (BASE, e)); f.close(); sys.exit(3)

vals = [struct.unpack("<I", m[i*4:i*4+4])[0] for i in range(4)]
m.close(); f.close()

ok = True
print("eth_ss_0 boot-ROM read via PS HPM0_FPD @ 0x%011X:" % BASE)
for i, (v, e, nm) in enumerate(zip(vals, EXPECT, NAMES)):
    tag = "PASS" if v == e else "FAIL"
    if v != e: ok = False
    print("  +0x%02X  0x%011X = 0x%08X  expect 0x%08X  [%s] %s"
          % (i*4, BASE + i*4, v, e, tag, nm))
print("RESULT: %s — PS->SoC eth_ss_0 backdoor is %s"
      % ("PASS" if ok else "FAIL", "ALIVE on silicon" if ok else "not matching"))
sys.exit(0 if ok else 1)
