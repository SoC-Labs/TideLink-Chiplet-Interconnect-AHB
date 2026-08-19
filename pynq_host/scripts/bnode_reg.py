#!/usr/bin/env python3
# Targeted B-node recovery probe helpers (run on a die).
#   arm    -> write injector 0x2E03_003C = 0x01000082 (enable|B DataID 0x82) — run on the B-SENDER (die_b)
#   disarm -> write injector 0x2E03_003C = 0
#   read   -> B-node FC CRC (0x1220) + RegionF (0x21E0) + SWI_LANE (0x2108) — run on the INITIATOR (die_a)
import mmap, struct, sys
WINDOW = 0x400000000; TLAPB = 0x2E030000
f = open('/dev/mem', 'r+b')
m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=WINDOW + TLAPB)
def rd(o): return struct.unpack('<I', m[o:o+4])[0]
def wr(o, v): m[o:o+4] = struct.pack('<I', v)
act = sys.argv[1] if len(sys.argv) > 1 else 'read'
if act == 'arm':
    wr(0x003C, 0x01000082); print("armed injector 0x003C=0x%08X (B DataID 0x82)" % rd(0x003C))
elif act == 'disarm':
    wr(0x003C, 0x00000000); print("disarmed injector 0x003C=0x%08X" % rd(0x003C))
else:
    bcrc = rd(0x1220) & 0xFFFF; rf = rd(0x21E0); lane = rd(0x2108)
    print("B-CRC(0x1220)=%d  RegionF(0x21E0)=0x%08X marker=0x%02X healthy=%d wedge_tgt=0x%02X wedge_ini=0x%02X  fcsm=%d"
          % (bcrc, rf, (rf>>24)&0xFF, (rf>>23)&1, (rf>>10)&0x1F, (rf>>15)&0x1F, (lane>>17)&7))
