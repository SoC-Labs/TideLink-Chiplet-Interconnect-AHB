#!/usr/bin/env python3
# arm_read.py — read the TideLink bring-up ARM chain over eth_ss_0 (RO, standard regs).
# role_lock / mask-handshake / training / nego / cal — to A/B deps vs override.
import mmap, struct
WINDOW=0x400000000; TLAPB=0x2E030000
def main():
    f=open("/dev/mem","r+b",buffering=0)
    m=mmap.mmap(f.fileno(),0x4000,mmap.MAP_SHARED,mmap.PROT_READ,offset=WINDOW+TLAPB)
    def rd(o): return struct.unpack("<I",m[o:o+4])[0]
    role=rd(0x2084); r8=rd(0x2100); nego=rd(0x2094); mh=rd(0x21F4); ls=rd(0x2108)
    print("ROLE_STATUS 0x2084 = 0x%08x  effective_role=%d role_locked=%d"%(role,role&1,(role>>1)&1))
    print("R8          0x2100 = 0x%08x  swi_training_mode_r=%d swi_recal_r=%d"%(r8,r8&1,(r8>>1)&1))
    print("NEGO_STATUS 0x2094 = 0x%08x  (mask_mismatch bit8=%d)"%(nego,(nego>>8)&1))
    print("OBS_MASK_HS 0x21F4 = 0x%08x"%mh)
    print("  autoneg_local_match[16]=%d local_fail[17]=%d mask_hs_match[19]=%d gate_open[20]=%d wlink_result[22:21]=%d verified[23]=%d"
          %((mh>>16)&1,(mh>>17)&1,(mh>>19)&1,(mh>>20)&1,(mh>>21)&3,(mh>>23)&1))
    print("SWI_LANE    0x2108 = 0x%08x  cal_done=%d fcsm=%d cr_seen=%d"%(ls,(ls>>16)&1,(ls>>17)&7,(ls>>23)&1))
    rl=(role>>1)&1; tr=r8&1; go=(mh>>20)&1
    print("SUMMARY: role_locked=%d training=%d mask_gate_open=%d cal_done=%d"%(rl,tr,go,(ls>>16)&1))
if __name__=="__main__": main()
