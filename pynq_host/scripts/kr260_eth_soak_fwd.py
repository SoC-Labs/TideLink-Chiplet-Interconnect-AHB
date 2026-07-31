#!/usr/bin/env python3
# kr260_eth_soak_fwd.py — wedge-safe D2D soak: sender writes N distinct payloads to
# N distinct peer-aperture offsets (CAM 0x2F->0x2D); receiver reads its OWN local
# SRAM back and verifies. No peer-readback (no link traversal on the read) => cannot
# wedge. Proves sustained isolated-write reliability across many addresses.
#   mode=write  (sender, die_a): program CAM 0x2F->0x2D (self-contained now), then
#                                write BASE+i to 0x2F001000 + i*4. Refuses if the
#                                local link is not FCSM=4 (peer-write wedge guard).
#   mode=verify (recv,   die_b): read 0x2D001000 + i*4, expect BASE+i; print pass count
# Backward-compatible CLI: `write [N] [BASEHEX]` / `verify [N] [BASEHEX]`.
import mmap, struct, sys
WINDOW=0x400000000
PEER_BASE = 0x2F001000     # sender peer aperture (CAM 0x2F -> die_b 0x2D)
LOCAL_BASE= 0x2D001000     # receiver local shared_sram_0 landing
TLAPB=0x2E030000
CAM_BASE  = TLAPB+0x4000   # CAM global-enable region base
CAM_CTRL  = TLAPB+0x4004   # [0] global_enable
CAM_RULE0 = TLAPB+0x4010   # [0]en [15:8]match [23:16]replace
RULE_2F_2D= (0x2D<<16)|(0x2F<<8)|1   # 0x002D2F01
SWI_LANE  = TLAPB+0x2108   # [16]cal [19:17]fcsm
REGF      = TLAPB+0x21E0   # Region F AXI-node obs plane ([23]data_healthy, marker 0xAD)
def phys_map(phys, size=0x1000):
    off = phys & ~0xFFF; pageoff = phys & 0xFFF
    f=open("/dev/mem","r+b",buffering=0)
    m=mmap.mmap(f.fileno(), size+0x1000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=off)
    return m, pageoff
def _rd32(phys):
    m,po=phys_map(phys); v=struct.unpack("<I",m[po:po+4])[0]; m.close(); return v
def _wr32(phys,val):
    m,po=phys_map(phys); m[po:po+4]=struct.pack("<I",val&0xFFFFFFFF); m.close()
def _link_up():
    st=_rd32(WINDOW+SWI_LANE); return ((st>>17)&7)==4 and ((st>>16)&1)==1, st
def _regf_line():
    rf=_rd32(WINDOW+REGF); present=((rf>>24)&0xFF)==0xAD
    if present:
        return "RegionF=0x%08x data_healthy=%d wedge-sticky tgt=0x%02x ini=0x%02x"%(
            rf,(rf>>23)&1,(rf>>10)&0x1F,(rf>>15)&0x1F)
    return "RegionF=0x%08x (obs plane absent, marker!=0xAD)"%rf
def main():
    mode=sys.argv[1]; N=int(sys.argv[2]) if len(sys.argv)>2 else 200
    base=int(sys.argv[3],16) if len(sys.argv)>3 else 0xA5A50000
    if mode=='write':
        up,st=_link_up()
        print("link SWI_LANE=0x%08x fcsm=%d cal=%d -> %s"%(st,(st>>17)&7,(st>>16)&1,"UP" if up else "DOWN"))
        if not up:
            print("ABORT: link not FCSM=4; refusing peer writes (wedge risk).",file=sys.stderr); sys.exit(2)
        # program CAM 0x2F->0x2D (CTRL armed last so a half-configured rule is never live).
        _wr32(WINDOW+CAM_BASE,0); _wr32(WINDOW+CAM_RULE0,RULE_2F_2D); _wr32(WINDOW+CAM_CTRL,1)
        print("CAM RULE0=0x%08x (0x2F->0x2D), global_enable=1"%RULE_2F_2D)
        m,pageoff=phys_map(WINDOW+PEER_BASE, N*4+0x1000)
        for i in range(N):
            o=pageoff+i*4; m[o:o+4]=struct.pack("<I",(base+i)&0xFFFFFFFF)
        m.close()
        print("WROTE %d words base=0x%08x to peer aperture 0x%08x"%(N,base,PEER_BASE))
        print("  "+_regf_line())
    elif mode=='verify':
        m,pageoff=phys_map(WINDOW+LOCAL_BASE, N*4+0x1000)
        ok=0; firstbad=None
        for i in range(N):
            o=pageoff+i*4; v=struct.unpack("<I",m[o:o+4])[0]
            if v==((base+i)&0xFFFFFFFF): ok+=1
            elif firstbad is None: firstbad=(i,v,(base+i)&0xFFFFFFFF)
        m.close()
        print("VERIFY %d/%d byte-exact%s"%(ok,N, "" if ok==N else "  firstbad=idx%d got0x%08x exp0x%08x"%firstbad))
        sys.exit(0 if ok==N else 1)
    else:
        print("usage: kr260_eth_soak_fwd.py write|verify [N] [BASEHEX]",file=sys.stderr); sys.exit(2)
if __name__=="__main__": main()
