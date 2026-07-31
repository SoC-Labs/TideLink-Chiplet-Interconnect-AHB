#!/usr/bin/env python3
# kr260_eth_soak_fwd.py — wedge-safe D2D soak: sender writes N distinct payloads to
# N distinct peer-aperture offsets (CAM 0x2F->0x2D); receiver reads its OWN local
# SRAM back and verifies. No peer-readback (no link traversal on the read) => cannot
# wedge. Proves sustained isolated-write reliability across many addresses.
#   mode=write  (sender, die_a): program CAM, write BASE+i to 0x2F001000 + i*4
#   mode=verify (recv,   die_b): read 0x2D001000 + i*4, expect BASE+i; print pass count
import mmap, struct, sys
WINDOW=0x400000000
PEER_BASE = 0x2F001000     # sender peer aperture (CAM 0x2F -> die_b 0x2D)
LOCAL_BASE= 0x2D001000     # receiver local shared_sram_0 landing
TLAPB=0x2E030000
CAM_RULE0 = 0x200C         # sender CAM rule0 (full addr _TLAPB+... ) — set via xfer normally
def phys_map(phys, size=0x1000):
    off = phys & ~0xFFF; pageoff = phys & 0xFFF
    f=open("/dev/mem","r+b",buffering=0)
    m=mmap.mmap(f.fileno(), size+0x1000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=off)
    return m, pageoff
def main():
    mode=sys.argv[1]; N=int(sys.argv[2]) if len(sys.argv)>2 else 200
    base=int(sys.argv[3],16) if len(sys.argv)>3 else 0xA5A50000
    if mode=='write':
        # program CAM 0x2F->0x2D via the proven xfer path first (caller does that);
        # here we just fire N writes across N words of the peer aperture.
        m,_=phys_map(WINDOW+PEER_BASE, N*4+0x1000)
        pageoff=(WINDOW+PEER_BASE)&0xFFF
        for i in range(N):
            o=pageoff+i*4; m[o:o+4]=struct.pack("<I",(base+i)&0xFFFFFFFF)
        print("WROTE %d words base=0x%08x to peer aperture 0x%08x"%(N,base,PEER_BASE))
    elif mode=='verify':
        m,_=phys_map(WINDOW+LOCAL_BASE, N*4+0x1000)
        pageoff=(WINDOW+LOCAL_BASE)&0xFFF
        ok=0; firstbad=None
        for i in range(N):
            o=pageoff+i*4; v=struct.unpack("<I",m[o:o+4])[0]
            if v==((base+i)&0xFFFFFFFF): ok+=1
            elif firstbad is None: firstbad=(i,v,(base+i)&0xFFFFFFFF)
        print("VERIFY %d/%d byte-exact%s"%(ok,N, "" if ok==N else "  firstbad=idx%d got0x%08x exp0x%08x"%firstbad))
        sys.exit(0 if ok==N else 1)
if __name__=="__main__": main()
