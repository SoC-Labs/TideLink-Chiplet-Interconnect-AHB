import mmap,struct,sys
A=0x840321F8
f=open("/dev/mem","r+b",buffering=0)
m=mmap.mmap(f.fileno(),0x1000,mmap.MAP_SHARED,mmap.PROT_READ,offset=A & ~0xFFF)
v=struct.unpack("<I",m[A&0xFFF:(A&0xFFF)+4])[0]
mk=(v>>24)&0xFF
print("OBS 0x%08X = 0x%08X  marker=0x%02X %s"%(A,v,mk,"OK(0xB5)" if mk==0xB5 else "*** NOT 0xB5 - UNDECODED, DO NOT TRUST ***"))
if mk==0xB5:
    print("  [10] xhb_stall_stuck_sticky = %d   (hazard-list-full/deadlock witness)"%((v>>10)&1))
    print("  [ 9] sub_err_sticky          = %d   (read ERROR backstop fired)"%((v>>9)&1))
    print("  [ 8] sub_wr_stuck_sticky     = %d   <== synth-B backstop fired?"%((v>>8)&1))
    print("  [7:5] sub_wr_os_hwm          = %d   (outstanding-write high-water mark)"%((v>>5)&7))
    print("  [ 4] pipe_hprot_r[2]         = %d   (bufferable/EWR seen)"%((v>>4)&1))
    print("  [3:1] sub_wr_os_ctr          = %d   (live outstanding count)"%((v>>1)&7))
    print("  [ 0] xhb_sub_hreadyout_raw   = %d   (live bridge ready)"%(v&1))
