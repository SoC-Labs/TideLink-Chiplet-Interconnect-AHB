#!/usr/bin/env python3
# winscan_read.py — read the I1 winscan/calibrator backdoor obs over eth_ss_0 (RO).
# Markers 0xC5/0x25 prove the obs is live+decoded (not a blind/undecoded read).
import mmap, struct
WINDOW_BASE = 0x400000000
TLAPB = 0x2E030000
SPAN = 0x4000
def main():
    f = open("/dev/mem", "r+b", buffering=0)
    m = mmap.mmap(f.fileno(), SPAN, mmap.MAP_SHARED, mmap.PROT_READ, offset=WINDOW_BASE + TLAPB)
    def rd(off): return struct.unpack("<I", m[off:off+4])[0]
    sig = rd(0x2108); st = rd(0x21E4); eye = rd(0x21E8)
    print("SWI_LANE_STATUS 0x2108 = 0x%08x  cal_done=%d fcsm=%d cr_seen=%d crack_seen=%d"
          % (sig, (sig>>16)&1, (sig>>17)&7, (sig>>23)&1, (sig>>24)&1))
    mk = (st>>24)&0xFF
    print("WINSCAN_STAT   0x21E4 = 0x%08x  marker=0x%02x %s" % (st, mk, "OK" if mk==0xC5 else "!! NOT live (exp 0xC5)"))
    print("  cal_state=%d cal_done=%d val_timeout=%d in_hold=%d training=%d"
          % (st&0xF, (st>>4)&1, (st>>5)&1, (st>>6)&1, (st>>7)&1))
    print("  ever swept=%d hold=%d validate=%d done=%d | any_lock=%d all_fault=%d lane_fault=0x%02x"
          % ((st>>8)&1,(st>>9)&1,(st>>10)&1,(st>>11)&1,(st>>12)&1,(st>>13)&1,(st>>16)&0xFF))
    mk2 = (eye>>26)&0x3F
    print("WINSCAN_EYE    0x21E8 = 0x%08x  marker=0x%02x %s" % (eye, mk2, "OK" if mk2==0x25 else "!! (exp 0x25)"))
    print("  eye_best_run=%d best_phase=%d best_slip=%d lane_passed=%d eye_lane_sel=%d lane_locked=0x%02x"
          % (eye&0x3F,(eye>>6)&0xF,(eye>>10)&7,(eye>>13)&1,(eye>>14)&7,(eye>>18)&0xFF))
    cd=(st>>4)&1; ed=(st>>11)&1; af=(st>>13)&1; lf=(st>>16)&0xFF
    if cd or ed: print("VERDICT: winscan LOCKED -> phase-shift REFUTED; break is downstream")
    elif af or lf==0xFF: print("VERDICT: winscan NEVER found a window -> capture-phase shift CONFIRMED")
    else: print("VERDICT: partial/other (lane_fault=0x%02x)" % lf)
if __name__ == "__main__": main()
