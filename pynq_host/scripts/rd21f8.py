#!/usr/bin/env python3
"""rd21f8.py — read the XHB500 leak/stall witness word at 0x8403_21F8 (KR260, run as root).

RECONSTRUCTED 2026-08-19 from the RTL decode (tidelink_top.sv:1852-1882). The original lived in
/tmp on the board and has been lost; the only recorded reading survives in a session transcript.
This exists so the measurement is reproducible rather than anecdotal.

DISCIPLINE — the marker is not optional:
  A missing 0xB5 marker means THE INSTRUMENT IS NOT ANSWERING. It does NOT mean "all bits zero".
  Never interpret a value whose marker is absent. (Same trap as 0x2158, which the V2 eye_shim path
  can win and return all-zeros with no marker.)

⚠ UNTESTED DIFFERENCE vs the original (which HAS silicon miles on it, preserved alongside as
rd21f8_ORIGINAL_2026-08-19.py): the original opened /dev/mem "r+b" (read-write); this opens
O_RDONLY|O_SYNC. Read-only is safer for an instrument and O_SYNC is more correct for MMIO (keeps the
mapping uncached, so a stale cache line cannot be served). Both should be fine for PROT_READ/
MAP_SHARED — but this version has NOT yet run on the board. CONFIRM THE MARKER READS 0xB5 ON A FIRST
HEALTHY READ before trusting any field. If it ever comes back marker-absent, suspect the open mode
before suspecting the link.

ALWAYS capture the BASELINE as well as the wedged read — the wedged word proves nothing about the
instrument on its own.
  BASELINE (healthy, recorded)  0xB5000001   stickies clear, raw = 1
  DURING WEDGE (recorded)       0xB5000498

Field decode (tidelink_top.sv:1874-1882):
  [0]     xhb_sub_hreadyout_raw      live
  [3:1]   sub_wr_os_ctr              live outstanding-write count (hazard list, saturates at 4)
  [4]     pipe_hprot_r[2]            bufferable/EWR seen on the peer path
  [7:5]   sub_wr_os_hwm              high-water mark, monotonic
  [8]     sub_wr_stuck_sticky        SET-ONLY, clears only on !hresetn -> 0 means NEVER fired since reset
  [9]     sub_err_sticky
  [10]    xhb_stall_stuck_sticky     hazard-list stall witness
  [31:24] marker, must be 0xB5
"""
import mmap, os, struct, sys

ADDR = 0x840321F8
page = ADDR & ~0xFFF
off  = ADDR & 0xFFF
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m  = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
v  = struct.unpack("<I", m[off:off+4])[0]

marker = (v >> 24) & 0xFF
print("0x%08X = 0x%08X" % (ADDR, v))
if marker != 0xB5:
    print("  MARKER 0x%02X != 0xB5 -> INSTRUMENT NOT ANSWERING. Do NOT read the fields as data." % marker)
    sys.exit(2)
print("  marker                 0xB5 OK")
print("  [0]  raw hreadyout     %d" % (v & 1))
print("  [3:1] sub_wr_os_ctr    %d   (hazard list; 4 = SATURATED)" % ((v >> 1) & 7))
print("  [4]  pipe_hprot_r[2]   %d   (1 = bufferable/EWR on the peer path)" % ((v >> 4) & 1))
print("  [7:5] sub_wr_os_hwm    %d" % ((v >> 5) & 7))
print("  [8]  wr_stuck_sticky   %d   (SET-ONLY; 0 = write backstop NEVER fired since reset)" % ((v >> 8) & 1))
print("  [9]  err_sticky        %d" % ((v >> 9) & 1))
print("  [10] stall_stuck       %d   (hazard-list stall witness)" % ((v >> 10) & 1))
