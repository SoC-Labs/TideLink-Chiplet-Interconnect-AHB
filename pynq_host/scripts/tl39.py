#!/usr/bin/env python3
# tl39.py - TideLink v39 (PHY V2, 6.25 MHz link) bring-up helper. /dev/mem mmap.
# v39 = v37 helper + the epoch-anchor multi-sample exit-confirm fix (sub 0bcede8)
# and, crucially, the NEW measurement instrument:
#   SWI_EPOCH_STATUS 0x44032140  [0]=epoch_anchored (sticky)  [6:1]=epoch_span
# This is THIS die's RX cross-lane deskew anchor engagement. For A->B data die_b
# is the receiver (read die_b's epoch); for B->A read die_a's. Before this build
# anchor engagement could only be inferred from garbled data; now it is readable.
#
# Recipe primitives unchanged from v37. The v39 data recipe uses PER-LANE-AUTO
# word-pin (wpauto = 0x104 word_pin=0/auto_dis=0, slip preserved) — proven to fix
# the credit/send-gate — NOT a forced global word_pin.
#
# Usage (as root): python3 tl39.py <cmd> [args]
#   probe [N [GAP]]   one-line decoded obs snapshot xN (now includes epoch)
#   epoch             decode SWI_EPOCH_STATUS: anchored[0], span[6:1]
#   rd ADDR | wr ADDR VAL
#   lockthresh        wr 0x44032160 = 0x55555555  (per-lane Hamming thresh 3->5)
#   hold | arm | freeze | release | recal
#   wpauto            per-lane-auto: auto_dis=0, word_pin=0, preserve slip[23:0]
#   txword VAL        write VAL to 0x44000000 (master M->S data test)
#   txburst V0 V1..   write words to 0x44000000,+4,+8,... (multi-word packet)
#   rxword            read 0x44010000 (slave local RX FIFO, single pop)
#   rxn N             read N words from 0x44010000 (sequential pops)
#   occ               read RX FIFO occupancy 0x4403200C
import mmap, struct, os, sys, time, ctypes

PAGE = 4096
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
maps = {}
def mm(addr):
    base = addr & ~(PAGE - 1)
    if base not in maps:
        maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                               mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return maps[base], addr - base

# ---------------------------------------------------------------------------
# SoC Labs 2026-07-09: rd()/wr() MUST be single aligned 32-bit bus accesses.
#
# These used struct.unpack_from / struct.pack_into on the mmap buffer. Measured
# on silicon against the a2l write pointer (obs 0x44032158, bits [6:2]):
#
#     struct.pack_into("<I", m, o, v)   ->  wbin advanced by 5   (FIVE bus stores)
#     ctypes.c_uint32.from_buffer(...)  ->  wbin advanced by 1   (one store)
#
# The struct/buffer path does not compile to one 32-bit access on this target;
# each logical poke became ~5 AHB beats. That is the "TX 5x over-advance
# phantom" -- it is the HOST, not the fc_adapter (tx_xfer_lock is exonerated).
# It made A->B appear to die after ~6 app words, because 6 stores x 5 = ~32
# packets = one full pktnum lap, which is where the real (RTL) bug detonated.
# See memory/project_a2b_rootcause_fe_tx_credit_max_2026_07_09.md
#
# rd() is fixed for the same reason and it matters MORE: several apertures are
# POP-on-read (rxn reads 0x44010000 as sequential pops; occ at 0x4403200C).
# A multi-beat "single" read silently consumes extra FIFO entries and corrupts
# the very measurement you are taking. Suspected cause of the still-unexplained
# RX-aperture read model (payloads landing at unrelated slots, "clearing" the
# ring perturbing it). Verify on silicon before trusting any delivery count.
#
# ctypes.c_uint32.from_buffer(m, o) creates a uint32 view AT the mmap offset --
# .value is exactly one aligned 32-bit load/store. Do not "optimise" this back
# to struct, and do not use memoryview slicing (same multi-beat hazard).
# ---------------------------------------------------------------------------
def _u32(a):
    m, o = mm(a)
    return ctypes.c_uint32.from_buffer(m, o)
def rd(a):
    return _u32(a).value
def wr(a, v):
    _u32(a).value = v & 0xFFFFFFFF

R8       = 0x44032100   # slot0: [0] swi_training_mode  [1] SWI_RECAL
SLIPLO   = 0x44032104   # SWI_BIT_SLIP_LO: [23:0] slip, [27:24] word_pin, [28] auto_dis
OBS      = 0x44032108   # lk/flt/cal/fcsm/llrx/cr/ck/...
TRAINCFG = 0x4403210C
OBSCAL   = 0x44032198   # [3:0] V2 cal FSM state, [20] live training_mode
EPOCH    = 0x44032140   # SWI_EPOCH_STATUS (V2): [0]=epoch_anchored [6:1]=epoch_span
SYNCCNT  = 0x44032114   # [31:16] = saturating SYNC-detected count (RX). >0 = coherent SYNC reassembled
TXSYNC   = 0x44032120   # SYNC-OBS (V2): [15:0]=tx_sync_ins_cnt [16]=idle_lvl [17]=train_lvl [31:24]=0x5C
RXDET2   = 0x44032124   # mask-aware per-lane SYNC-DETECT: [15:0]=sync_seen_cnt [23:16]=per-lane sticky [31:24]=0x5D
LANEMASK = 0x44032128   # SWI_SYNC_LANE_MASK [7:0] (default 0xFF) for the per-lane detector
RAWWORD  = 0x4403212C   # dbg_raw_word[127:0] best-match post-deskew word (4x32b: 0x2C,0x30,0x34,0x38)
SLICEMAP = 0x4403213C   # per-RX-lane -> carried TX-slice idx (8x4b). identity=0x76543210 POR=0xFFFFFFFF
PKTLEN   = 0x44032008   # Packet Word Length (RO) - length of received packet
STATUS   = 0x44032010   # [0]returner_busy [1]fifo_overrun [2]fifo_underrun [3]master_error [4]packet_committed
CREDIT   = 0x4403200C   # Credit Count (RO) - NOT fifo occupancy
ECCCNT   = 0x44032114   # [31:16]=sync_det_cnt [15:0]=ecc_corrupted_cnt (RX long-pkt header-ECC fails)
PERF_ID  = 0x440320FC   # ==0x50460100 if perf block live
PERF_CTRL= 0x440320A0    # 0x1=en 0x5=en+clr 0x3=freeze-snapshot
PERF_TXP = 0x440320C8   # tx_pkt_count
PERF_RXP = 0x440320CC   # rx_pkt_count (committed)
PERF_TXW = 0x440320D0   # tx_word_count (a2l handshakes - data LEFT this die)
PERF_RXW = 0x440320D4   # rx_word_count (l2a handshakes - data ARRIVED at peer)
PHASEOFF = 0x44032118   # SWI_PHASE_OFFSET 8x4-bit per-lane sub-bit-cell sample point (OR-merged w/ calibrator)
LIVEMATCH= 0x44032144   # [7:0] live per-lane SYNC-match-since-clear vector [31:24]=0x5E (non-sticky oracle)
PWP_VAL  = 0x44032148   # per-lane word-pin override value (8x4-bit, lane L=[4L+3:4L])
PWP_EN   = 0x4403214C   # [7:0] per-lane word-pin override enable (1=use SW pin, 0=auto)
LOCKTHR  = 0x44032160
# GP1-split V2 bitstreams (2026-06-12): data apertures moved off GP0.
#   AHB_TX  = 0x84000000 (was 0x44000000)   RX FIFO = 0x84010000 (was 0x44010000)
TXBASE   = 0x84000000
RXBASE   = 0x84010000

def popc(x): return bin(x).count("1")

def decode_obs(s):
    return dict(lk=s & 0xff, flt=(s >> 8) & 0xff, cal=(s >> 16) & 1,
                fcsm=(s >> 17) & 7, llrx=(s >> 21) & 3, cr=(s >> 23) & 1,
                ck=(s >> 24) & 1, llv=(s >> 29) & 1, a2l=(s >> 30) & 1,
                full=(s >> 31) & 1)

def epoch_str():
    e = rd(EPOCH)
    return e, e & 1, (e >> 1) & 0x3f

def probe():
    s = rd(OBS); slot0 = rd(R8); cal = rd(OBSCAL); e, anc, span = epoch_str()
    d = decode_obs(s)
    print("lk=0x%02x(%d) flt=0x%02x cal=%d fcsm=%d llrx=%d cr=%d ck=%d llv=%d a2l=%d full=%d | "
          "slot0=%d cstate=%d tm=%d | EPOCH anc=%d span=%d (0x%08x) | obs=0x%08x"
          % (d['lk'], popc(d['lk']), d['flt'], d['cal'], d['fcsm'], d['llrx'],
             d['cr'], d['ck'], d['llv'], d['a2l'], d['full'],
             slot0 & 3, cal & 0xf, (cal >> 20) & 1, anc, span, e, s), flush=True)

def wpread():
    v = rd(SLIPLO); return v & 0xffffff, (v >> 24) & 0xf, (v >> 28) & 1

cmd = sys.argv[1]
if cmd == "probe":
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    gap = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    for i in range(n):
        print("t=%6.2f" % (i * gap), end=" "); probe()
        if i < n - 1: time.sleep(gap)
elif cmd == "epoch":
    e, anc, span = epoch_str()
    print("SWI_EPOCH_STATUS=0x%08x  epoch_anchored[0]=%d  epoch_span[6:1]=%d" % (e, anc, span))
elif cmd == "rd":
    print("0x%08x" % rd(int(sys.argv[2], 16)))
elif cmd == "wr":
    wr(int(sys.argv[2], 16), int(sys.argv[3], 16))
elif cmd == "lockthresh":
    wr(LOCKTHR, 0x55555555); print("lockthresh=5 (0x%08x)" % rd(LOCKTHR))
elif cmd == "hold":
    wr(R8, 0x1)
elif cmd == "arm":
    wr(R8, 0x1); time.sleep(0.010); wr(R8, 0x3); time.sleep(0.002); wr(R8, 0x1)
    print("armed (hold+recal pulse)")
elif cmd == "freeze":
    wr(R8, 0x2); print("frozen (slot0=0x2, latched alignment, FC data carriers)")
elif cmd == "release":
    wr(R8, 0x0); print("released")
elif cmd == "recal":
    keep = rd(R8) & 1; wr(R8, keep | 2); time.sleep(0.002); wr(R8, keep)
    print("recal pulsed (hold=%d)" % keep)
elif cmd == "wpauto":
    slip, _, _ = wpread(); wr(SLIPLO, slip)
    print("wpauto (per-lane-auto: auto_dis=0 word_pin=0 slip=0x%06x) readback 0x%08x"
          % (slip, rd(SLIPLO)))
elif cmd == "txword":
    wr(TXBASE, int(sys.argv[2], 16)); print("tx done")
elif cmd == "txburst":
    vals = [int(x, 16) for x in sys.argv[2:]]
    for i, v in enumerate(vals): wr(TXBASE + i * 4, v)
    print("txburst %d words" % len(vals))
elif cmd == "rxword":
    print("0x%08x" % rd(RXBASE))
elif cmd == "rxn":
    n = int(sys.argv[2])
    # RX aperture 0x84010000 is a 32-slot ADDRESSED ring: slot i is at
    # RXBASE + i*4, NOT a pop-FIFO. Reading RXBASE repeatedly (the old code)
    # only ever returned slot 0, faking a "word0-only" delivery when the whole
    # ring had actually crossed (silicon-proven 2026-07-07: B->A 25/28). Read
    # the addressed slots so the rotation-aware compare sees the real data.
    print(" ".join("0x%08x" % rd(RXBASE + i * 4) for i in range(n)))
elif cmd == "occ":
    print("credit_count=%d (0x%08x)" % (rd(CREDIT) & 0xffff, rd(CREDIT)))
elif cmd == "status":
    v = rd(STATUS)
    print("STATUS=0x%08x committed[4]=%d master_err[3]=%d underrun[2]=%d overrun[1]=%d busy[0]=%d | PKT_WORD_LEN=%d"
          % (v, (v >> 4) & 1, (v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1, rd(PKTLEN)))
elif cmd == "obs2":   # extended 0x108 decode incl is_long_pkt[26]
    s = rd(OBS)
    print("obs=0x%08x a2l_app[20]=%d cr[23]=%d ck[24]=%d short[25]=%d long[26]=%d llv[29]=%d a2l_lnk[30]=%d fe_full[31]=%d"
          % (s, (s>>20)&1, (s>>23)&1, (s>>24)&1, (s>>25)&1, (s>>26)&1, (s>>29)&1, (s>>30)&1, (s>>31)&1))
elif cmd == "ecc":
    v = rd(ECCCNT)
    print("0x114=0x%08x sync_det_cnt[31:16]=%d ecc_corrupted_cnt[15:0]=%d" % (v, (v>>16)&0xffff, v&0xffff))
elif cmd == "phase":
    v = rd(PHASEOFF)
    print("PHASE=0x%08x " % v + " ".join("L%d=%d" % (i, (v>>(4*i))&0xf) for i in range(8)))
elif cmd == "phaseset":   # phaseset LANE VAL  (sets lane nibble, preserves others; OR-merged w/ cal)
    lane = int(sys.argv[2]); val = int(sys.argv[3]) & 0xf
    v = rd(PHASEOFF); v = (v & ~(0xf << (4*lane))) | (val << (4*lane)); wr(PHASEOFF, v)
    print("phaseset L%d=%d -> PHASE=0x%08x" % (lane, val, rd(PHASEOFF)))
elif cmd == "phaseraw":   # phaseraw VAL  (write whole reg)
    wr(PHASEOFF, int(sys.argv[2], 16)); print("PHASE=0x%08x" % rd(PHASEOFF))
elif cmd == "syncclr":    # pulse 0x100 bit[5] (W1, self-clearing); preserves other slot0 bits
    wr(R8, (rd(R8) & 0xF) | 0x20)
    print("sync_obs cleared")
elif cmd == "livematch":  # non-sticky per-lane match vector
    v = rd(LIVEMATCH)
    print("LIVEMATCH=0x%08x marker=0x%02x per_lane=0x%02x [%s]"
          % (v, (v>>24)&0xff, v&0xff, " ".join("L%d=%d" % (i,(v>>i)&1) for i in range(8))))
elif cmd == "pwpset":     # pwpset LANE VAL  (set per-lane word-pin override + enable that lane)
    lane = int(sys.argv[2]); val = int(sys.argv[3]) & 0xf
    pv = rd(PWP_VAL); pv = (pv & ~(0xf << (4*lane))) | (val << (4*lane)); wr(PWP_VAL, pv)
    wr(PWP_EN, rd(PWP_EN) | (1 << lane))
    print("pwp L%d=%d en -> VAL=0x%08x EN=0x%02x" % (lane, val, rd(PWP_VAL), rd(PWP_EN)&0xff))
elif cmd == "pwpclr":     # disable all per-lane overrides (back to auto)
    wr(PWP_EN, 0); wr(PWP_VAL, 0); print("per-lane word-pin override OFF (all auto)")
elif cmd == "pwpread":
    print("PWP_VAL=0x%08x PWP_EN=0x%02x" % (rd(PWP_VAL), rd(PWP_EN)&0xff))
elif cmd == "perf":
    sub = sys.argv[2] if len(sys.argv) > 2 else "read"
    if sub == "en":   wr(PERF_CTRL, 0x5); print("perf enabled+cleared")
    elif sub == "freeze": wr(PERF_CTRL, 0x3); print("perf frozen")
    else:
        print("PERF_ID=0x%08x(live=%d) txpkt=%d rxpkt=%d txword=%d rxword=%d"
              % (rd(PERF_ID), rd(PERF_ID)==0x50460100, rd(PERF_TXP)&0xffffffff,
                 rd(PERF_RXP)&0xffffffff, rd(PERF_TXW)&0xffffffff, rd(PERF_RXW)&0xffffffff))
elif cmd == "syncon":
    wr(R8, rd(R8) | 0x4); print("sync_insert_en=1 (slot0=0x%x)" % rd(R8))
elif cmd == "syncoff":
    wr(R8, rd(R8) & ~0x4); print("sync_insert_en=0 (slot0=0x%x)" % rd(R8))
elif cmd == "synccnt":
    print("sync_detected_cnt=%d (0x%08x)" % (rd(SYNCCNT) >> 16, rd(SYNCCNT)))
elif cmd == "syncforce":
    wr(R8, rd(R8) | 0x8); print("sync_force_always=1 (slot0=0x%x)" % rd(R8))
elif cmd == "synconly":
    wr(R8, rd(R8) & ~0x8); print("sync_force_always=0 (slot0=0x%x)" % rd(R8))
elif cmd == "txsync":
    v = rd(TXSYNC)
    print("TXSYNC=0x%08x marker=0x%02x tx_ins_cnt=%d idle=%d train=%d"
          % (v, (v >> 24) & 0xff, v & 0xffff, (v >> 16) & 1, (v >> 17) & 1))
elif cmd == "syncdet2":
    v = rd(RXDET2)
    print("RXDET2=0x%08x marker=0x%02x sync_seen_cnt=%d per_lane_sticky=0x%02x"
          % (v, (v >> 24) & 0xff, v & 0xffff, (v >> 16) & 0xff))
elif cmd == "syncrobust":
    wr(R8, rd(R8) | 0x10); print("sync_robust_detect=1 (slot0=0x%x)" % rd(R8))
elif cmd == "lanemask":
    wr(LANEMASK, int(sys.argv[2], 16) if len(sys.argv) > 2 else 0xFF)
    print("lane_mask=0x%02x" % (rd(LANEMASK) & 0xff))
elif cmd == "rawword":
    w = [rd(RAWWORD + 4*i) for i in range(4)]
    print("raw_post_deskew = 0x%08x_%08x_%08x_%08x (lane7..0: %s)"
          % (w[3], w[2], w[1], w[0],
             " ".join("L%d=0x%04x" % (i, (w[i//2] >> (16*(i%2))) & 0xffff) for i in range(8))))
elif cmd == "slicemap":
    v = rd(SLICEMAP)
    m = " ".join("rxL%d<-txS%d" % (i, (v >> (4*i)) & 0xf) for i in range(8))
    ident = "IDENTITY" if v == 0x76543210 else ("POR/none" if v == 0xFFFFFFFF else "TRANSFORM")
    print("slicemap=0x%08x [%s] %s" % (v, ident, m))
else:
    print("unknown cmd", cmd); sys.exit(2)
