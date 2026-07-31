#!/usr/bin/env python3
# fcemit_read.py — read TideLink FCEMIT observability (I1 cr_seen=0 diagnosis).
# Localises the sideband CR handshake: emit (sop) vs grant (advance) vs id vs capture.
# STAT 0x2E03_21EC, IDCNT 0x2E03_21F0 (Region F, unconditional obs). Backdoor RO.
import mmap, struct
WINDOW=0x400000000; TLAPB=0x2E030000
def main():
    f=open("/dev/mem","r+b",buffering=0)
    m=mmap.mmap(f.fileno(),0x4000,mmap.MAP_SHARED,mmap.PROT_READ,offset=WINDOW+TLAPB)
    def rd(o): return struct.unpack("<I",m[o:o+4])[0]
    st=rd(0x21EC); ic=rd(0x21F0); ls=rd(0x2108)
    mk1=(st>>24)&0xFF; mk2=(ic>>24)&0xFF
    print("FCEMIT_STAT  0x21EC = 0x%08x  marker=0x%02x %s"%(st,mk1,"OK" if mk1==0xE1 else "!! expect 0xE1"))
    axi_sop=st&0x1F; sb_sop=(st>>5)&1; gb_sop=(st>>6)&1
    axi_gr=(st>>8)&0x1F; sb_gr=(st>>13)&1; gb_gr=(st>>14)&1
    io_en=(st>>16)&1; out_adv=(st>>17)&1; sop_live=(st>>18)&1
    names=["AW","W","B","AR","R"]
    print("  axi_sop_seen[4:0]  =0x%02x  {%s}"%(axi_sop, ",".join(n for i,n in enumerate(names) if (axi_sop>>i)&1) or "-"))
    print("  axi_grant_seen[12:8]=0x%02x {%s}"%(axi_gr, ",".join(n for i,n in enumerate(names) if (axi_gr>>i)&1) or "-"))
    print("  sb_sop_seen[5]   =%d   sb_grant_seen[13] =%d   (SIDEBAND ch6 = the CR path)"%(sb_sop,sb_gr))
    print("  gb_sop_seen[6]   =%d   gb_grant_seen[14] =%d   (general-bus ch5)"%(gb_sop,gb_gr))
    print("  router_io_enable[16]=%d  out_advance_ever[17]=%d  any_sop_live[18]=%d"%(io_en,out_adv,sop_live))
    print("FCEMIT_IDCNT 0x21F0 = 0x%08x  marker=0x%02x %s"%(ic,mk2,"OK" if mk2==0xE2 else "!! expect 0xE2"))
    id_aw=ic&0xFF; id_sb=(ic>>8)&0xFF; cnt6=(ic>>16)&0xFF
    def idn(v): return {0x8:"CR",0x9:"CRACK"}.get(v,"0x%02x"%v)
    print("  last_id_aw[7:0] =0x%02x (%s)   last_id_sb[7:0]=0x%02x (%s)   ch6_grant_cnt[23:16]=%d"%(id_aw,idn(id_aw),id_sb,idn(id_sb),cnt6))
    print("SWI_LANE     0x2108 = 0x%08x  cal_done=%d fcsm=%d cr_seen=%d"%(ls,(ls>>16)&1,(ls>>17)&7,(ls>>23)&1))
    # verdict
    print("--- LOCALISE ---")
    if not io_en:
        print("  TX router still in RESET (io_enable=0) -> nothing can emit. Clock/reset, not FCSM.")
    elif not sb_sop:
        print("  CR NEVER PRESENTED on sideband (sb_sop_seen=0) -> FCSM_6 never drives SOP: EMIT-side stall (H1). fcsm=%d"%((ls>>17)&7))
    elif sb_sop and not sb_gr:
        print("  CR PRESENTED but NEVER GRANTED (sb_sop=1,sb_grant=0) -> router arbitration starves ch6 (H2/emit-gate).")
    elif sb_gr and idn(id_sb) not in ("CR","CRACK"):
        print("  CR GRANTED but WRONG data_id (last_id_sb=0x%02x) -> H3 packetisation."%id_sb)
    else:
        print("  CR emitted+granted+correct-id on THIS die (cnt=%d,id=%s) -> local emit OK; cr_seen=0 is a CAPTURE/peer-RX problem."%(cnt6,idn(id_sb)))
if __name__=="__main__": main()
