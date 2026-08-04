#!/usr/bin/env python3
# eth_tlapb_poke.py — minimal root-only read/write of the eth-chiplet TideLink
# CONFIG-plane APB, reached through the eth_ss_0 PS FPD backdoor
# (WINDOW_BASE 0x4_0000_0000 + TLAPB_SOC_BASE 0x2E03_0000). Runs ON a KR260 die.
#
# Offsets are RELATIVE to TLAPB_SOC_BASE (i.e. the SoC HADDR low bits):
#   0x2100 R8 (SYNC ctrl: [2]insert_en [3]force_always [4]robust)
#   0x2114 ECCCNT   [31:16]=sync_det_cnt [15:0]=ecc_corrupted_cnt (RO)
#   0x2140 EPOCH_STATUS [0]=epoch_anchored(reanchored, sticky) [6:1]=epoch_span
#   0x21F4 AUTO_ANCHOR_OBS [15:0]dwell_max [16]pulsed_ever [17]done [18]pulse
#          [19]link_up [20]tx_idle [21]reanchored [22]training [23]AUTO_ANCHOR_EN (RO)
#   0x003C ERR_INJECT  [7:0]DataID [15:8]Byte [18:16]Bit [24]Enable
# Only touches CONFIG-plane (combinational/obs) addresses — cannot wedge the bus.
#
#   read  <off>                -> prints 0x%08x
#   write <off> <val>          -> writes, reads back
#   epoch                      -> decodes EPOCH_STATUS + R8
#   anchorpulse                -> R8=0x1C, 0.4s, R8=0x00 (host SYNC-force anchor)
#   anchorobs                  -> decode AUTO_ANCHOR_OBS 0x21F4 (why reanchored latched or not)
#   inject <data_id> <byte> <bit>   -> ERR_INJECT enable (arm this die's injector)
#   injectoff                  -> ERR_INJECT = 0
import mmap, struct, sys, time
WINDOW_BASE = 0x400000000
TLAPB_SOC_BASE = 0x2E030000
_SPAN = 0x4000
_f = open("/dev/mem", "r+b", buffering=0)
_m = mmap.mmap(_f.fileno(), _SPAN, mmap.MAP_SHARED,
               mmap.PROT_READ | mmap.PROT_WRITE, offset=WINDOW_BASE + TLAPB_SOC_BASE)
def rd(off):      return struct.unpack("<I", _m[off:off + 4])[0]
def wr(off, val): _m[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)

cmd = sys.argv[1] if len(sys.argv) > 1 else "epoch"
if cmd == "read":
    print("0x%08x" % rd(int(sys.argv[2], 0)))
elif cmd == "write":
    off, val = int(sys.argv[2], 0), int(sys.argv[3], 0); wr(off, val); print("0x%08x" % rd(off))
elif cmd == "epoch":
    e = rd(0x2140); c = rd(0x2114)
    print("EPOCH_STATUS(0x2140)=0x%08x anchored=%d span=%d  R8(0x2100)=0x%08x  ECCCNT(0x2114) corrupted=%d"
          % (e, e & 1, (e >> 1) & 0x3f, rd(0x2100), c & 0xffff))
elif cmd == "anchorpulse":
    wr(0x2100, 0x1C); time.sleep(0.4); wr(0x2100, 0x00); time.sleep(0.05)
    e = rd(0x2140); print("after-pulse EPOCH_STATUS=0x%08x anchored=%d" % (e, e & 1))
elif cmd == "anchorobs":
    o = rd(0x21F4)
    dwell_max = o & 0xFFFF
    print("AUTO_ANCHOR_OBS(0x21F4)=0x%08x  AUTO_ANCHOR_EN=%d dwell_max=%d pulsed_ever=%d done=%d "
          "pulse=%d link_up=%d tx_idle=%d reanchored=%d training=%d"
          % (o, (o >> 23) & 1, dwell_max, (o >> 16) & 1, (o >> 17) & 1, (o >> 18) & 1,
             (o >> 19) & 1, (o >> 20) & 1, (o >> 21) & 1, (o >> 22) & 1))
    if (o >> 23) & 1 == 0:
        print("  -> AUTO_ANCHOR_EN=0: this build does NOT have auto-anchor (or param off)")
    elif (o >> 16) & 1 == 0 and dwell_max < 256:
        print("  -> dwell_max<256 & pulsed_ever=0: TX never idle long enough (keepalive resets dwell) = gate too strict")
    elif (o >> 16) & 1 == 0:
        print("  -> dwell reached but no emit: blocked between dwell-complete and burst")
    elif (o >> 21) & 1 == 0:
        print("  -> beacon emitted (pulsed_ever=1) but reanchored=0: PHY/peer did not latch")
    else:
        print("  -> pulsed_ever=1 AND reanchored=1: auto-anchor worked")
elif cmd == "inject":
    did, byte, bit = int(sys.argv[2], 0), int(sys.argv[3], 0), int(sys.argv[4], 0)
    val = (1 << 24) | ((bit & 7) << 16) | ((byte & 0xFF) << 8) | (did & 0xFF)
    wr(0x003C, val); print("ERR_INJECT(0x003C)=0x%08x (arm data_id=0x%02x byte=%d bit=%d)" % (rd(0x003C), did, byte, bit))
elif cmd == "injectoff":
    wr(0x003C, 0); print("ERR_INJECT(0x003C)=0x%08x (off)" % rd(0x003C))
else:
    sys.exit("usage: read|write|epoch|anchorpulse|anchorobs|inject|injectoff")
