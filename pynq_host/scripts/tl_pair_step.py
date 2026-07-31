#!/usr/bin/env python3
# tl_pair_step.py — single-die primitive for the bilateral eth-chiplet bring-up
# (I1 self-arm + FIX-E training release). Actions: arm | wait_hold | release |
# poll_up | status. The dev-host orchestrator (bringup_pair_release.sh) sequences
# these across both dies with a barrier so neither drops training before both are
# in S_HOLD. RO except the ROLE_CFG/TRAIN writes in arm/release.
import mmap, struct, time, sys
WINDOW=0x400000000; TLAPB=0x2E030000
OFF={'ROLE_CFG':0x2080,'ROLE_STATUS':0x2084,'TRAIN':0x2100,'LANE':0x2108,'WINSCAN':0x21E4}
def main():
    act=sys.argv[1]
    f=open("/dev/mem","r+b",buffering=0)
    m=mmap.mmap(f.fileno(),0x4000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=WINDOW+TLAPB)
    def rd(o): return struct.unpack("<I",m[o:o+4])[0]
    def wr(o,v): m[o:o+4]=struct.pack("<I",v)
    def lane():
        ls=rd(OFF['LANE']); return ls,(ls>>16)&1,(ls>>17)&7,(ls>>23)&1
    if act=='arm':
        role=sys.argv[2]; cfg=0x02 if role=='die_a' else 0x03
        wr(OFF['ROLE_CFG'],cfg); time.sleep(0.01)
        wr(OFF['TRAIN'],1); time.sleep(0.005)
        print("ARMED role=%s eff=%d train=%d"%(role, rd(OFF['ROLE_STATUS'])&1, rd(OFF['TRAIN'])&1))
    elif act=='wait_hold':
        to=float(sys.argv[2]) if len(sys.argv)>2 else 20.0
        t0=time.time(); ih=0; ws=0
        while time.time()-t0<to:
            ws=rd(OFF['WINSCAN']); ih=(ws>>6)&1
            if ih: break
            time.sleep(0.02)
        print(("HOLD" if ih else "NOHOLD")+" winscan=0x%08x cal_state=%d"%(ws, ws&0xF))
    elif act=='release':
        wr(OFF['TRAIN'],0); print("RELEASED train=%d"%(rd(OFF['TRAIN'])&1))
    elif act=='poll_up':
        to=float(sys.argv[2]) if len(sys.argv)>2 else 10.0
        t0=time.time(); ls,cd,fc,cr=lane()
        while time.time()-t0<to:
            ls,cd,fc,cr=lane()
            if cd and fc==4: break
            time.sleep(0.02)
        print(("UP" if (cd and fc==4) else "DOWN")+" SWI_LANE=0x%08x cal_done=%d fcsm=%d cr_seen=%d"%(ls,cd,fc,cr))
    elif act=='status':
        ls,cd,fc,cr=lane(); print("SWI_LANE=0x%08x cal_done=%d fcsm=%d cr_seen=%d"%(ls,cd,fc,cr))
    else:
        print("ERR unknown action %s"%act); sys.exit(2)
if __name__=="__main__": main()
