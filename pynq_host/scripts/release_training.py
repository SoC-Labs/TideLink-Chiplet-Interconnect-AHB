#!/usr/bin/env python3
# release_training.py — FIX-E bilateral release: clear SWI_TRAINING_MODE (0x2100 bit0)
# once the die is in S_HOLD, then watch S_HOLD->S_VALIDATE->S_DONE / cal_done / fcsm.
# No RTL change. Run on BOTH dies together (bilateral). RO except the single 0x2100 write.
import mmap, struct, time, sys
WINDOW=0x400000000; TLAPB=0x2E030000
def main():
    f=open("/dev/mem","r+b",buffering=0)
    m=mmap.mmap(f.fileno(),0x4000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=WINDOW+TLAPB)
    def rd(o): return struct.unpack("<I",m[o:o+4])[0]
    def wr(o,v): m[o:o+4]=struct.pack("<I",v)
    def decode(tag):
        r8=rd(0x2100); ls=rd(0x2108); ws=rd(0x21E4)
        print("  [%s] R8=0x%08x(train=%d) SWI_LANE=0x%08x cal_done=%d fcsm=%d cr_seen=%d crack=%d | WINSCAN cal_state=%d in_hold=%d validate=%d done=%d lane_fault=0x%02x"
              %(tag, r8, r8&1, ls,(ls>>16)&1,(ls>>17)&7,(ls>>23)&1,(ls>>24)&1, ws&0xF,(ws>>6)&1,(ws>>10)&1,(ws>>11)&1,(ws>>16)&0xFF))
        return ls
    print("=== BEFORE release ===")
    decode("pre")
    # bilateral release: clear the whole R8 (only bit0 was set) -> SWI_TRAINING_MODE=0
    print("=== WRITE SWI_TRAINING_MODE=0 (0x2100 <- 0) ===")
    wr(0x2100, 0x00000000)
    # watch for ~12s
    t0=time.time()
    while time.time()-t0 < 12.0:
        ls=decode("t+%.1f"%(time.time()-t0))
        if (ls>>16)&1:  # cal_done
            print("*** cal_done ASSERTED ***"); break
        time.sleep(0.8)
    print("=== FINAL ===")
    decode("final")
if __name__=="__main__": main()
