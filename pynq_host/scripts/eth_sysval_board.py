#!/usr/bin/env python3
# eth_sysval_board.py — board-side primitives for the system-level validation suite
# (SYSVAL). Runs as root ON a KR260 die, reaching the SoC through the PS FPD
# backdoor (WINDOW 0x4_0000_0000 + SoC addr). Wedge-safe by construction: verify
# and seed_local are die-LOCAL (no link traversal); read_chunk is the only
# link-traversing read and is BOUNDED (caller chunks it with a Region-F gate
# between chunks — the board /dev/mem read has no internal timeout).
#
# Marker-gated obs (per the build spec, 2026-08-08):
#   0x21E0 Region-F   marker 0xAD : [23]data_healthy [20]tgt_resperr [21]ini_resperr
#                                   [14:10]wedge_tgt [19:15]wedge_ini
#   0x21F8 witness    marker 0xB5 : [0]hreadyout [3:1]wr_os [4]buf [7:5]hwm
#                                   [8]synth_b [9]err [10]stall_stuck
#   0x21E8 WINSCAN_EYE marker 0x25: [5:0]best_run [13]lane_passed [16:14]lane_sel
#   0x2108 SWI_LANE            : [16]cal [19:17]fcsm
#
# CAM (die_a initiator): rule 0x2F->0x2D so peer aperture 0x2F001000 maps to die_b
# local SRAM 0x2D001000 for BOTH writes and reads.
#
# modes:
#   obs                        -> JSON of marker-gated observables (RO, cannot wedge)
#   write   <N> <BASEHEX>      -> die_a: program CAM, write BASE+k to 0x2F001000+k*4
#   verify  <N> <BASEHEX>      -> die_b: LOCAL read 0x2D001000+k*4, expect BASE+k
#   seed_local <N> <BASEHEX>   -> die_b: LOCAL write BASE+k to 0x2D001000+k*4
#   read_chunk <START> <CNT> <BASEHEX>  -> die_a: read 0x2F001000+k*4 over the link
#                                          for k in [START,START+CNT), expect BASE+k
import mmap, struct, sys, json
WINDOW    = 0x400000000
TLAPB     = 0x2E030000
PEER_BASE = 0x2F001000          # die_a peer aperture (CAM 0x2F -> die_b 0x2D)
LOCAL_BASE= 0x2D001000          # die_b local shared_sram_0 landing
REGF      = TLAPB + 0x21E0
WITNESS   = TLAPB + 0x21F8
EYE       = TLAPB + 0x21E8
SWI_LANE  = TLAPB + 0x2108
CAM_BASE  = TLAPB + 0x4000
CAM_CTRL  = TLAPB + 0x4004
CAM_RULE0 = TLAPB + 0x4010
RULE_2F_2D= (0x2D << 16) | (0x2F << 8) | 1     # 0x002D2F01

def _map(phys, size):
    off = phys & ~0xFFF; po = phys & 0xFFF
    f = open("/dev/mem", "r+b", buffering=0)
    span = ((size + po + 0xFFF) & ~0xFFF) + 0x1000
    return mmap.mmap(f.fileno(), span, mmap.MAP_SHARED,
                     mmap.PROT_READ | mmap.PROT_WRITE, offset=off), po

def _rd(phys):
    m, po = _map(phys, 4); v = struct.unpack("<I", m[po:po+4])[0]; m.close(); return v
def _wr(phys, val):
    m, po = _map(phys, 4); m[po:po+4] = struct.pack("<I", val & 0xFFFFFFFF); m.close()

def _program_cam():
    _wr(WINDOW + CAM_BASE, 0)
    _wr(WINDOW + CAM_RULE0, RULE_2F_2D)
    _wr(WINDOW + CAM_CTRL, 1)

def _obs():
    rf = _rd(WINDOW + REGF); wt = _rd(WINDOW + WITNESS)
    ey = _rd(WINDOW + EYE);  ls = _rd(WINDOW + SWI_LANE)
    regf_present    = ((rf >> 24) & 0xFF) == 0xAD
    witness_present = ((wt >> 24) & 0xFF) == 0xB5
    eye_present     = ((ey >> 24) & 0xFF) == 0x25
    o = {
        "regf_raw": "0x%08x" % rf, "regf_present": regf_present,
        "data_healthy": (rf >> 23) & 1 if regf_present else None,
        "tgt_resperr":  (rf >> 20) & 1 if regf_present else None,
        "ini_resperr":  (rf >> 21) & 1 if regf_present else None,
        "wedge_tgt":    (rf >> 10) & 0x1F if regf_present else None,
        "wedge_ini":    (rf >> 15) & 0x1F if regf_present else None,
        "witness_raw": "0x%08x" % wt, "witness_present": witness_present,
        "stall_stuck": (wt >> 10) & 1 if witness_present else None,
        "synth_b":     (wt >> 8) & 1 if witness_present else None,
        "wr_err":      (wt >> 9) & 1 if witness_present else None,
        "wr_hwm":      (wt >> 5) & 7 if witness_present else None,
        "eye_raw": "0x%08x" % ey, "eye_present": eye_present,
        "best_run":    ey & 0x3F if eye_present else None,
        "lane_passed": (ey >> 13) & 1 if eye_present else None,
        "lane_sel":    (ey >> 14) & 7 if eye_present else None,
        "swi_lane_raw": "0x%08x" % ls, "fcsm": (ls >> 17) & 7, "cal": (ls >> 16) & 1,
    }
    print(json.dumps(o))

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "obs"
    if mode == "obs":
        _obs(); return
    N    = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    base = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0xA5A50000
    if mode == "write":
        _program_cam()
        m, po = _map(WINDOW + PEER_BASE, N * 4)
        for i in range(N):
            m[po + i*4: po + i*4 + 4] = struct.pack("<I", (base + i) & 0xFFFFFFFF)
        m.close()
        print("WRITE %d words base=0x%08x -> peer 0x%08x" % (N, base, PEER_BASE))
    elif mode == "seed_local":
        m, po = _map(WINDOW + LOCAL_BASE, N * 4)
        for i in range(N):
            m[po + i*4: po + i*4 + 4] = struct.pack("<I", (base + i) & 0xFFFFFFFF)
        m.close()
        print("SEED_LOCAL %d words base=0x%08x -> local 0x%08x" % (N, base, LOCAL_BASE))
    elif mode == "verify":
        m, po = _map(WINDOW + LOCAL_BASE, N * 4)
        ok = 0; first = None
        for i in range(N):
            v = struct.unpack("<I", m[po + i*4: po + i*4 + 4])[0]
            if v == ((base + i) & 0xFFFFFFFF): ok += 1
            elif first is None: first = (i, v, (base + i) & 0xFFFFFFFF)
        m.close()
        print("VERIFY %d/%d byte-exact%s" % (ok, N,
              "" if ok == N else "  firstbad idx%d got0x%08x exp0x%08x" % first))
        sys.exit(0 if ok == N else 1)
    elif mode == "read_chunk":
        start = N                                   # argv2 = START
        cnt   = int(sys.argv[3])                    # argv3 = COUNT
        base  = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0xA5A50000
        _program_cam()
        hi = start + cnt
        m, po = _map(WINDOW + PEER_BASE, hi * 4)
        ok = 0; first = None
        for i in range(start, hi):
            v = struct.unpack("<I", m[po + i*4: po + i*4 + 4])[0]   # read OVER the link
            if v == ((base + i) & 0xFFFFFFFF): ok += 1
            elif first is None: first = (i, v, (base + i) & 0xFFFFFFFF)
        m.close()
        print("READCHUNK %d/%d start=%d%s" % (ok, cnt, start,
              "" if ok == cnt else "  firstbad idx%d got0x%08x exp0x%08x" % first))
        sys.exit(0 if ok == cnt else 1)
    else:
        print("usage: eth_sysval_board.py obs|write|verify|seed_local|read_chunk ...",
              file=sys.stderr); sys.exit(2)

if __name__ == "__main__":
    main()
