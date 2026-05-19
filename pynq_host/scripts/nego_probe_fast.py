#!/usr/bin/env python3
# Fast-poll headless I2C activity probe (no ILA needed). Run on a board
# via /dev/mem. Writes NEGO_PRIORITY + NEGO_CFG=0x61, then samples
# NEGO_STATUS/ROLE_STATUS at ~5 ms over ~5 s capturing every unique
# (state, all flags) tuple so transient CLAIM-window activity isn't
# missed.
# Key MMIO observable: ROLE_STATUS bit[2] i2c_slv_busy reflects the
# i2c_slave core's bus_active state. The master's own i2c_slave is on
# the same on-chip net as its master, so master.i2c_busy going non-zero
# = master pad driven on-chip (rules out D' core-not-driving).
# Slave.i2c_busy going non-zero = master's I2C edges physically crossed
# W9/V7 (rules out B ribbon-not-carrying).
import mmap, struct, os, time, sys

TL = 0x44032000
I2C_PRESCALE, NEGO_CFG = 0x8C, 0x90
NEGO_STATUS, ROLE_STATUS = 0x94, 0x84
NEGO_PRIORITY = 0x98
STATE = {0:"IDLE",1:"INIT",2:"WAIT",3:"CLAIM",4:"POLL",5:"DONE",
         6:"BYPASS",7:"ERROR",8:"MASK_RES_TX",9:"MASK_RD_ADDR",10:"MASK_RD_DATA"}
ROLE = sys.argv[1] if len(sys.argv) > 1 else "auto"
PRIO = {"master": 1, "slave": 0xFFFF}.get(ROLE, 0x00A5)

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=TL)
def rd(o): return struct.unpack_from("<I", m, o)[0]
def wr(o, v): struct.pack_into("<I", m, o, v)

wr(I2C_PRESCALE, 200)
wr(NEGO_PRIORITY, PRIO)
wr(NEGO_CFG, 0x61)
print("role=%s NEGO_CFG=0x%x I2C_PRESCALE=%d NEGO_PRIORITY=0x%x" % (
      ROLE, rd(NEGO_CFG), rd(I2C_PRESCALE) & 0xFFFF, rd(NEGO_PRIORITY)))

# Fast capture: ~5 ms polling over 5 s = ~1000 samples. Print only on
# UNIQUE (ns,rs) so we see every transition without spam.
seen = []
saw_busy = saw_addr = saw_sda = saw_match = saw_fail = 0
t0 = time.time()
deadline = t0 + 5.0
while time.time() < deadline:
    ns, rs = rd(NEGO_STATUS), rd(ROLE_STATUS)
    key = (ns, rs)
    if not seen or seen[-1][2] != key:
        dt_ms = int((time.time() - t0) * 1000)
        seen.append((dt_ms, len(seen), key))
    if (rs >> 2) & 1: saw_busy = 1     # i2c_slv_busy ever seen
    if (rs >> 3) & 1: saw_addr = 1     # i2c_slv_addressed ever seen
    if (ns >> 8) & 1: saw_sda = 1      # sda_start_detect ever seen
    if ns & 0x10:    saw_match = 1     # nego_done
    if (ns >> 9) & 1: saw_fail = 1     # mask_mismatch
    time.sleep(0.005)

for dt, idx, (ns, rs) in seen:
    st = ns & 0xF
    print("t=%5dms NEGO_STATUS=0x%03x [%s done=%d err=%d won=%d lost=%d sda=%d "
          "mismatch=%d] ROLE_STATUS=0x%x [locked=%d i2c_busy=%d i2c_addr=%d]" % (
          dt, ns, STATE.get(st, "?%d" % st), (ns>>4)&1, (ns>>5)&1, (ns>>6)&1,
          (ns>>7)&1, (ns>>8)&1, (ns>>9)&1, rs, (rs>>1)&1, (rs>>2)&1, (rs>>3)&1))

print("--- STICKY (any sample over 5 s) ---")
print("EVER i2c_busy=%d  EVER i2c_addr=%d  EVER sda_start_seen=%d  EVER nego_done=%d  EVER mask_mismatch=%d" % (
      saw_busy, saw_addr, saw_sda, saw_match, saw_fail))
states = {s[2][0] & 0xF for s in seen}
print("states visited: " + " ".join(STATE.get(s, str(s)) for s in sorted(states)))
if saw_addr:
    print("VERDICT: I2C peer-mask handshake REACHED ADDRESS MATCH -> bus works + slave engaged.")
elif saw_busy:
    print("VERDICT: bus activity SEEN but no address match -> wire OK but addressing/protocol issue.")
elif saw_sda:
    print("VERDICT: SDA-START SEEN -> at least one edge crossed; partial channel.")
else:
    print("VERDICT: NO bus activity observed at all (i2c_busy/i2c_addr/sda_start ALL stayed 0 across 5s).")
    print("         (If this is the MASTER, its own slave-core should see its own drive on-chip;")
    print("         i2c_busy=0 on master suggests D' core not driving OR address-mux disengaged.")
    print("         If this is the SLAVE, signal not crossing externally -> B/D/A.)")
