#!/usr/bin/env python3
# health_snapshot.py — RO one-shot cross-die link health dump (wedge-safe).
# Maps ONLY the TideLink APB span inside the eth_ss_0 window and reads: SWI_LANE
# (cal/fcsm/cr), STATUS+sticky, CREDIT_COUNT, OBS_FC_CREDIT, and Region F (the
# AXI-node obs plane: data_healthy + wedge/live-stall bits). No writes, no peer
# access -> cannot wedge. Exit 0 if healthy, 1 if a fault bit is set (CI-usable).
import mmap, struct, sys
WINDOW = 0x400000000; TLAPB = 0x2E030000
f = open("/dev/mem", "r+b", buffering=0)
m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED, mmap.PROT_READ, offset=WINDOW + TLAPB)
def rd(o): return struct.unpack("<I", m[o:o + 4])[0]
swi, st, cc, ofc, rf = rd(0x2108), rd(0x2010), rd(0x200C) & 0x1FFF, rd(0x219C), rd(0x21E0)
fcsm, cal = (swi >> 17) & 7, (swi >> 16) & 1
fe_full, sticky, marker = (swi >> 31) & 1, st & 0xE, (rf >> 24) & 0xFF
healthy_bit, present = (rf >> 23) & 1, ((rf >> 24) & 0xFF) == 0xAD
tgt_ws, ini_ws = (rf >> 10) & 0x1F, (rf >> 15) & 0x1F
print("=== eth-chiplet health snapshot (RO, wedge-safe) @ 0x4_2E03_xxxx ===")
print("  SWI_LANE   0x2108 = 0x%08X  cal=%d fcsm=%d cr=%d crack=%d fe_rx_full=%d -> %s"
      % (swi, cal, fcsm, (swi >> 23) & 1, (swi >> 24) & 1, fe_full,
         "UP" if (fcsm == 4 and cal) else "DOWN"))
print("  STATUS     0x2010 = 0x%08X  sticky[3:1]=0x%X (MASTER_ERR/UNDER/OVER)" % (st, sticky))
print("  CREDIT_CNT 0x200C = %d" % cc)
print("  OBS_FC_CR  0x219C = 0x%08X  (sideband FCSM_6 only — NOT the AXI nodes)" % ofc)
if present:
    print("  RegionF    0x21E0 = 0x%08X  marker=0x%02X data_healthy=%d  "
          "wedge-sticky tgt=0x%02X ini=0x%02X  resp-err tgt=%d ini=%d"
          % (rf, marker, healthy_bit, tgt_ws, ini_ws, (rf >> 20) & 1, (rf >> 21) & 1))
else:
    print("  RegionF    0x21E0 = 0x%08X  marker=0x%02X (expect 0xAD) -> AXI-node obs "
          "plane NOT present in this bitstream" % (rf, marker))
ok = (fcsm == 4 and cal and sticky == 0 and not fe_full
      and (not present or (healthy_bit and tgt_ws == 0 and ini_ws == 0)))
print("RESULT: %s" % ("HEALTHY" if ok else "FAULT (see bits above)"))
m.close(); f.close()
sys.exit(0 if ok else 1)
