#!/usr/bin/env python3
# On-ribbon W9/V7 I2C electrical probe (run ON a board via /dev/mem).
# Enables the autoneg (NEGO_CFG=0x61) with a slow prescale for the weak
# internal pull, then samples NEGO_STATUS/ROLE_STATUS for ~18 s and
# decodes the trajectory. The state path is the electrical evidence:
#   BYPASS(6) only            -> nego_en never took effect
#   WAIT(2) forever           -> back-off never expires / stuck
#   CLAIM(3)->POLL(4) then     -> master drove I2C; if it then advances to
#     MASK_RD_ADDR(9)/RD_DATA(10)/RES_TX(8) the peer ACKed over W9/V7  =>
#     ** I2C CHANNEL PHYSICALLY WORKS **
#   ERROR(7)                  -> global timeout: no I2C completion (channel
#                                dead / weak-pull too slow / peer silent)
#   DONE(5) won|lost, mask_mismatch=0 -> handshake completed cleanly
# i2c_slv_busy/addressed going 1 on the SLAVE = master's I2C physically
# reached it (strong positive electrical signal).
import mmap, struct, os, time, sys

TL = 0x44032000                       # TideLink APB; ctrl_reg window @ +0x80
I2C_PRESCALE, NEGO_CFG = 0x8C, 0x90   # ctrl_reg idx3, idx4
NEGO_STATUS, ROLE_STATUS = 0x94, 0x84 # ctrl_reg idx5, idx1
NEGO_PRIORITY = 0x98                  # ctrl_reg idx6 (pri_sel=0 in 0x61)
ROLE = sys.argv[1] if len(sys.argv) > 1 else "auto"
# Directed back-off: master short (claims fast, drives I2C START), slave
# long (stays in WAIT to catch the master's START over W9/V7).
PRIO = {"master": 1, "slave": 0xFFFF}.get(ROLE, 0x00A5)
STATE = {0:"IDLE",1:"INIT",2:"WAIT",3:"CLAIM",4:"POLL",5:"DONE",
         6:"BYPASS",7:"ERROR",8:"MASK_RES_TX",9:"MASK_RD_ADDR",10:"MASK_RD_DATA"}

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=TL)
def rd(o): return struct.unpack_from("<I", m, o)[0]
def wr(o, v): struct.pack_into("<I", m, o, v)

wr(I2C_PRESCALE, 200)                 # ~slow for weak internal pull
wr(NEGO_PRIORITY, PRIO)               # directed back-off (master<slave)
wr(NEGO_CFG, 0x61)                    # en | force_lock | mask_hs_auto_en
print("role=%s NEGO_CFG=0x%x I2C_PRESCALE=%d NEGO_PRIORITY=0x%x" % (
      ROLE, rd(NEGO_CFG), rd(I2C_PRESCALE) & 0xFFFF, rd(NEGO_PRIORITY)))

seen = []
for i in range(18):
    ns, rs = rd(NEGO_STATUS), rd(ROLE_STATUS)
    st = ns & 0xF
    tag = (st, (ns>>4)&1, (ns>>5)&1, (ns>>6)&1, (ns>>7)&1, (ns>>8)&1,
           (ns>>9)&1, (rs>>1)&1, (rs>>2)&1, (rs>>3)&1)
    if not seen or seen[-1] != tag:
        seen.append(tag)
        print("t=%2ds NEGO_STATUS=0x%03x [%s done=%d err=%d won=%d lost=%d "
              "sda=%d mismatch=%d] ROLE_STATUS=0x%x [locked=%d "
              "i2c_busy=%d i2c_addr=%d]" % (
              i, ns, STATE.get(st, "?%d" % st), (ns>>4)&1, (ns>>5)&1,
              (ns>>6)&1, (ns>>7)&1, (ns>>8)&1, (ns>>9)&1, rs, (rs>>1)&1,
              (rs>>2)&1, (rs>>3)&1))
    time.sleep(1)

states = {s[0] for s in seen}
mask_reached = bool(states & {8, 9, 10})
print("--- VERDICT ---")
print("states seen: " + " ".join(STATE.get(s, str(s)) for s in
      sorted(states)))
if mask_reached:
    print("I2C CHANNEL WORKS: FSM reached MASK_* (peer ACKed over W9/V7).")
elif 7 in states:
    print("NO I2C COMPLETION: hit ERROR (global timeout) — channel dead / "
          "weak-pull too slow / peer not responding.")
elif states <= {6}:
    print("nego_en NOT effective (BYPASS only).")
else:
    print("INCONCLUSIVE: ended in %s — needs the peer enabled + a "
          "coordinated/re-armed attempt." % STATE.get(seen[-1][0], "?"))
