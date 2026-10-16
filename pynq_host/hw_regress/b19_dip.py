#!/usr/bin/env python3
"""b19_dip.py - B19 negative control on the live onchip link, the compute-73 procedure used in Wave C
(td-bisect/kr260-wavec-b08145a-2026-10-01-results/b19_dip_restore.py), with the verdict computed here.

  die_a 0x84030208 <- 0x00027F00 (swi_enable dip), then <- 0x00027F07 (RESTORE).  ALWAYS BOTH.
  A dip without the restore leaves die_a bits[2:1]=0 and the next soak hard-wedges the PS (Wave C, 2026-10-01).

Runs ON the board as root.  PASS needs:
  mid-dip   die_a 0x208 reads 0x00027f01   (TL-052 shim holds swi_enable while the host wrote 0x27F00)
  restored  die_a 0x208 reads 0x00027f07 at +10 ms and +1 s;   die_b 0x208 stays 0x00027f07 throughout
  OBS_FC_CREDIT (0x219C) top byte 0xFC and bit 9 unchanged pre -> +1 s on both dies
"""
import mmap, os, struct, sys, time
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
maps = {}
def m(a):
    b = a & ~0xFFFF
    if b not in maps:
        maps[b] = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return maps[b], a - b
def rd(a): mm, o = m(a); return struct.unpack("<I", mm[o:o+4])[0]
def wr(a, v): mm, o = m(a); mm[o:o+4] = struct.pack("<I", v)
BASES = (("die_a", 0x84030000), ("die_b", 0x8C030000))
S = {}
def snap(tag):
    S[tag] = {}
    for die, base in BASES:
        v = (rd(base + 0x208), rd(base + 0x2108), rd(base + 0x219C))
        S[tag][die] = v
        print(f"{tag} {die}: 0x208={v[0]:#010x} 0x2108={v[1]:#010x} OBS_FC_CREDIT(0x219C)={v[2]:#010x}", flush=True)
snap("pre")
print("DIP: die_a 0x84030208 <- 0x00027F00 then 0x00027F07 (compute-73 procedure, live link)", flush=True)
wr(0x84030208, 0x00027F00); time.sleep(0.001); snap("mid")
wr(0x84030208, 0x00027F07)
time.sleep(0.01); snap("p10ms")
time.sleep(1.0); snap("p1s")
ok, why = True, []
def need(c, msg):
    global ok
    if not c:
        ok = False; why.append(msg)
need(S["pre"]["die_a"][0] == 0x27F07 and S["pre"]["die_b"][0] == 0x27F07, "pre-dip 0x208 not 0x27f07 on both dies (%#x/%#x)" % (S["pre"]["die_a"][0], S["pre"]["die_b"][0]))
need(S["mid"]["die_a"][0] == 0x27F01, "mid-dip die_a 0x208 = %#x, expected 0x27f01 (TL-052 swi_enable hold)" % S["mid"]["die_a"][0])
for t in ("p10ms", "p1s"):
    need(S[t]["die_a"][0] == 0x27F07, "%s die_a 0x208 = %#x, expected 0x27f07 (restore)" % (t, S[t]["die_a"][0]))
    need(S[t]["die_b"][0] == 0x27F07, "%s die_b 0x208 = %#x, expected 0x27f07" % (t, S[t]["die_b"][0]))
for die, _ in BASES:
    a, b = S["pre"][die][2], S["p1s"][die][2]
    need((a >> 24) == 0xFC and (b >> 24) == 0xFC, "%s OBS_FC_CREDIT top byte not 0xFC (%#x -> %#x)" % (die, a, b))
    need(((a >> 9) & 1) == ((b >> 9) & 1), "%s OBS_FC_CREDIT bit 9 changed (%#x -> %#x)" % (die, a, b))
print("VERDICT: %s B19 control: dip 0x27F00 then restore 0x27F07 on the live link%s" % ("PASS" if ok else "FAIL", "" if ok else " :: " + "; ".join(why)))
sys.exit(0 if ok else 1)
