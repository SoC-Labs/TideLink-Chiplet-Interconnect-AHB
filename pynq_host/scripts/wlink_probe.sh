#!/bin/bash
# Diagnostic dump of Wlink + TideLink APB register state on a paired
# Pynq-Z2 board. Run from a host with SSH access to the board's PYNQ
# Linux (e.g. mapstone-dev). Useful for triaging bring-up failures
# where link_active is asserted but FC sideband traffic isn't crossing.
#
# Discovered Wlink APB region layout (relative to the unified APB base
# at MMIO 0x4403_0000, i.e. Wlink occupies offsets 0x0000..0x1FFF):
#
#   0x0000  PHY                    (config: pream/post-count, polarity
#                                   — default reads as 0x00010701)
#   0x0200  Link layer (CRC + FCSM bookkeeping)
#   0x1000  AXI AR FC channel  (id 0x80)
#   0x1100  AXI AW FC channel  (id 0x81)
#   0x1200  AXI R  FC channel  (id 0x82)
#   0x1300  AXI W  FC channel  (id 0x83)
#   0x1400  AXI B  FC channel  (id 0x84)
#   0x1600  GeneralBus FC      (id 0xa0)
#   0x1700  TideLink FC        (id 0xa1)
#
# Each FC region's 32-byte header has the same shape:
#   [0x00] channel byte-pattern (0x44..0x47 for TideLink)
#   [0x04] channel id
#   [0x08] activity bit (1 if traffic has been seen on this channel)
#   [0x0c] reserved (0)
#   [0x10] FC config (0x00020601 = data-width/tag/active flags)
#   [0x14] FC params (0x00000708)
#
# Notes:
#   * swi_enable is W1S in the link layer with POR default = 1, so all
#     FC channels are enabled out of reset. Don't waste time chasing
#     "FC disabled" if you see [0x08]=0 — it just means no traffic has
#     crossed yet on that channel.
#   * The PHY APB only exposes config; it does NOT expose link-up state.
#     Health must be inferred from FC activity counters or by sending a
#     test packet and watching the peer's CURRENT_CREDITS drop.
#
# **HAZARD — DO NOT WRITE TO AHB_TX (0x4400_0000) UNTIL LINK IS PROVEN UP.**
# If the Wlink TX FC node is wedged (e.g. RX deserializer not synced with
# the peer, ribbon wiring wrong, or RX clock unusable), the FC adapter
# never asserts HREADY back. The AXI4-Lite-to-AHB-Lite bridge in the BD
# then stalls indefinitely, SmartConnect blocks, and the PS Linux mmap
# write hangs in kernel space — taking down SSH and requiring a
# hardware power-cycle of the board (UART reboot may not recover it).
#
# Verified on bench (2026-04-27): writing a 4-word packet to AHB_TX on
# z2_02 broke its SSH session immediately and the PS would not respond
# to subsequent ping. fpgahub UART reboot did not recover it within
# 4 min; physical power-cycle was needed.
#
# Safe read-only probes (this script's APB reads, doorbell triggers,
# strap writes, role_lock writes) do NOT have this problem because they
# target paths that always complete locally regardless of link state.
#
# Usage:
#   wlink_probe.sh BOARD_IP
set -e
BOARD_IP="${1:?BOARD_IP required}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"

PY='import mmap,struct,os
fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC); P=4096
def mm(a,sz=P):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd,pages,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
WL=0x44030000
LABELS = {
    0x000: "PHY",
    0x200: "LinkCRC",
    0x1000:"AXI_AR  FC",
    0x1100:"AXI_AW  FC",
    0x1200:"AXI_R   FC",
    0x1300:"AXI_W   FC",
    0x1400:"AXI_B   FC",
    0x1600:"GenBus  FC",
    0x1700:"TideLnk FC",
}
print("== Wlink region snapshot ==")
for base,label in LABELS.items():
    r,o=mm(WL+base, 64)
    vals=[struct.unpack_from("<I",r,o+i)[0] for i in (0,4,8,0xC,0x10,0x14)]
    activity = "  active" if (base>=0x1000 and vals[2]==1) else ""
    print("  0x{:04x} {:11s}: ".format(base,label) + " ".join("{:08x}".format(v) for v in vals) + activity)
# Lane control: derived ActiveLanes (RO) and per-lane Mask (RW).
ll,lo=mm(WL+0x200, 64)
al = struct.unpack_from("<I",ll,lo+0x10)[0]
lm = struct.unpack_from("<I",ll,lo+0x14)[0]
print("  0x0210 ActiveLanes : tx={} rx={} (popcount(mask)-1 each; +1 = lane count)".format(al & 0xFFFF, (al>>16) & 0xFFFF))
print("  0x0214 LaneMask    : tx=0x{:04x} rx=0x{:04x}".format(lm & 0xFFFF, (lm>>16) & 0xFFFF))
tl,to=mm(0x44032000)
def rd(off): return struct.unpack_from("<I",tl,to+off)[0]
print()
print("== TideLink APB snapshot ==")
print("  PAIR_BASE_ADDR    : 0x{:08x}".format(rd(0x00)))
print("  REL_THRESHOLD     :", rd(0x04))
print("  PACKET_WORD_LENGTH:", rd(0x08))
print("  CURRENT_CREDITS   :", rd(0x0c), "(/4096 MAX)")
print("  TIDELINK_VERSION  : 0x{:08x}".format(rd(0x14)))
print("  CTRL_LOCK         :", rd(0x1c))
print("  RELEASED_ACC      :", rd(0x20))
print("  DOORBELL_RESP_ACC :", rd(0x24))
print("  PAIR_CREDIT_CTR   :", rd(0x28))
print("  ROLE_CFG          : 0x{:08x} (lock={}, cfg={})".format(rd(0x80),(rd(0x80)>>1)&1,rd(0x80)&1))
print()
print("== Region 8: Chiplet Extended (PHY align + I2C train) ==")
print("  SWI_TRAINING_MODE : 0x{:08x} (mode={})".format(rd(0x100), rd(0x100)&1))
print("  SWI_BIT_SLIP_LO   : 0x{:08x}".format(rd(0x104)))
v=rd(0x108)
print("  SWI_LANE_STATUS   : 0x{:08x} (locked=0x{:02x}, fault=0x{:02x}, cal_done={})".format(v, v&0xFF, (v>>8)&0xFF, (v>>16)&1))
print("  NEGO_TRAIN_CFG    : 0x{:08x}".format(rd(0x10C)))
print("  NEGO_TRAIN_STATUS : 0x{:08x}".format(rd(0x110)))
print("  PHY_ALIGN_ID      : 0x{:08x} (expect 0x50410100)".format(rd(0x11C)))
# Legacy interim shim addresses (delete after Phase 5 migration completes).
ws,wso=mm(0x44031000)
def rd_wl(off): return struct.unpack_from("<I",ws,wso+off)[0]
print()
print("== [LEGACY-INTERIM-SHIM @ 0x4403_1000] -- migrate to Region 8 ==")
print("  SWI_BIT_SLIP       : 0x{:08x}".format(rd_wl(0x00)))
print("  SWI_TRAINING_MODE  : 0x{:08x}".format(rd_wl(0x04)))'

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR xilinx@$BOARD_IP "echo '$PASS' | sudo -S python3 -c '$PY' 2>&1"
