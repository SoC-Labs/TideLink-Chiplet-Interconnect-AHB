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
#
# ---------------------------------------------------------------------------
# SoC SELECTION (added 2026-07-16 — hardware-safety). Every literal below is
# the Z2 map and is now passed through _R() / tl_socmap.remap().
#
#   unset / TIDELINK_SOC=z2  -> IDENTITY. Bit-identical to every prior release.
#   TIDELINK_SOC=kr260       -> control 0x4403_xxxx -> 0x8403_xxxx,
#                               data    0x84xx_xxxx -> 0xA4xx_xxxx.
#
# This tool carries ~30 CONTROL-plane literals. Before this change it read NO
# env at all, so an operator following fpga/docs/KR260_PORT.md's
# "export TIDELINK_TX_BASE=0xA4000000" advice got a tool still poking Z2
# control addresses on a KR260 — UNDECODED on ZynqMP, i.e. an AXI access with
# no responder and NO timeout: hard PS hang, power-cycle to recover.
# TIDELINK_TX_BASE alone can never fix that; only TIDELINK_SOC moves control.
# ---------------------------------------------------------------------------
import mmap, struct, os, sys, time, ctypes

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
try:
    from tl_socmap import SocMapError, remap as _R, resolve_soc, tx_base, rxfifo_base
except ImportError as _e:  # deployed as a lone file next to no tl_socmap.py
    # FAIL LOUD on a relocating SoC; stay IDENTITY on the z2 default so an
    # existing single-file deployment of tl39.py keeps working unchanged.
    if os.environ.get("TIDELINK_SOC", "").strip().lower() not in ("", "z2"):
        sys.stderr.write(
            "tl39: TIDELINK_SOC=%r requires pynq_host/tl_socmap.py, which is not\n"
            "importable (%s). Refusing to run: without it every address below is a\n"
            "Z2 literal, and Z2 control addresses are UNDECODED on ZynqMP (AXI hang,\n"
            "power-cycle to recover). Copy tl_socmap.py next to tl39.py's parent dir.\n"
            % (os.environ.get("TIDELINK_SOC"), _e))
        sys.exit(2)
    class SocMapError(RuntimeError): pass
    def _R(a, **_kw): return a
    def resolve_soc(): return "z2"
    def tx_base(z2_default=0x84000000): return z2_default
    def rxfifo_base(z2_default=0x84010000): return z2_default

# Validate the SoC selection BEFORE opening /dev/mem or building the register
# table, so a typo ("TIDELINK_SOC=kr250") is a clean one-line refusal rather
# than a traceback — and, critically, never a silent fall-back to the Z2 map.
try:
    _SOC = resolve_soc()
except SocMapError as _e:
    sys.stderr.write("\ntl39: REFUSING to run — %s\n\n" % _e)
    sys.exit(2)

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

R8       = _R(0x44032100)   # slot0: [0] swi_training_mode  [1] SWI_RECAL
SLIPLO   = _R(0x44032104)   # SWI_BIT_SLIP_LO: [23:0] slip, [27:24] word_pin, [28] auto_dis
OBS      = _R(0x44032108)   # lk/flt/cal/fcsm/llrx/cr/ck/...
TRAINCFG = _R(0x4403210C)
OBSCAL   = _R(0x44032198)   # [3:0] V2 cal FSM state, [20] live training_mode
EPOCH    = _R(0x44032140)   # SWI_EPOCH_STATUS (V2): [0]=epoch_anchored [6:1]=epoch_span
SYNCCNT  = _R(0x44032114)   # [31:16] = saturating SYNC-detected count (RX). >0 = coherent SYNC reassembled
TXSYNC   = _R(0x44032120)   # SYNC-OBS (V2): [15:0]=tx_sync_ins_cnt [16]=idle_lvl [17]=train_lvl [31:24]=0x5C
RXDET2   = _R(0x44032124)   # mask-aware per-lane SYNC-DETECT: [15:0]=sync_seen_cnt [23:16]=per-lane sticky [31:24]=0x5D
LANEMASK = _R(0x44032128)   # SWI_SYNC_LANE_MASK [7:0] (default 0xFF) for the per-lane detector
RAWWORD  = _R(0x4403212C)   # dbg_raw_word[127:0] best-match post-deskew word (4x32b: 0x2C,0x30,0x34,0x38)
SLICEMAP = _R(0x4403213C)   # per-RX-lane -> carried TX-slice idx (8x4b). identity=0x76543210 POR=0xFFFFFFFF
PKTLEN   = _R(0x44032008)   # Packet Word Length (RO) - length of received packet
STATUS   = _R(0x44032010)   # [0]returner_busy [1]fifo_overrun [2]fifo_underrun [3]master_error [4]packet_committed
CREDIT   = _R(0x4403200C)   # Credit Count (RO) - NOT fifo occupancy
ECCCNT   = _R(0x44032114)   # [31:16]=sync_det_cnt [15:0]=ecc_corrupted_cnt (RX long-pkt header-ECC fails)
PERF_ID  = _R(0x440320FC)   # ==0x50460100 if perf block live
PERF_CTRL= _R(0x440320A0)   # 0x1=en 0x5=en+clr 0x3=freeze-snapshot
PERF_TXP = _R(0x440320C8)   # tx_pkt_count
PERF_RXP = _R(0x440320CC)   # rx_pkt_count (committed)
PERF_TXW = _R(0x440320D0)   # tx_word_count (a2l handshakes - data LEFT this die)
PERF_RXW = _R(0x440320D4)   # rx_word_count (l2a handshakes - data ARRIVED at peer)
PHASEOFF = _R(0x44032118)   # SWI_PHASE_OFFSET 8x4-bit per-lane sub-bit-cell sample point (OR-merged w/ calibrator)
LIVEMATCH= _R(0x44032144)   # [7:0] live per-lane SYNC-match-since-clear vector [31:24]=0x5E (non-sticky oracle)
PWP_VAL  = _R(0x44032148)   # per-lane word-pin override value (8x4-bit, lane L=[4L+3:4L])
PWP_EN   = _R(0x4403214C)   # [7:0] per-lane word-pin override enable (1=use SW pin, 0=auto)
LOCKTHR  = _R(0x44032160)
# GP1-split V2 bitstreams (2026-06-12): data apertures moved off GP0.
#   AHB_TX  = 0x84000000 (was 0x44000000)   RX FIFO = 0x84010000 (was 0x44010000)
# On KR260 these relocate to 0xA4000000 / 0xA4010000. tx_base()/rxfifo_base()
# also honour the legacy TIDELINK_TX_BASE / TIDELINK_RXFIFO_BASE overrides, but
# CROSS-CHECK them against TIDELINK_SOC and abort on disagreement rather than
# let a half-configured run poke the wrong plane.
TXBASE   = tx_base(0x84000000)
RXBASE   = rxfifo_base(0x84010000)

# ---------------------------------------------------------------------------
# ADDRESS CONTRACT for `rd` / `wr` (and therefore for every caller, notably
# fpga/hw_regression/td_v2_hwlib.sh's a()/b() helpers):
#
#   Addresses on the command line are Z2-CANONICAL. tl39 relocates them for the
#   selected SoC. Callers pass Z2 literals verbatim and must NOT pre-relocate.
#
# This deliberately puts EXACTLY ONE remap in the chain. The alternative
# (callers relocate, tl39 takes absolutes) invites a double-remap — a shell
# script mapping 0x4403_2100 -> 0x8403_2100 and tl39 mapping it again would
# land at 0x8803_2100: undecoded, i.e. the very bus hang this is here to stop.
# On z2 the remap is an identity, so this contract is a no-op there.
#
# NB this differs from tl_poke.py, whose rd/wr genuinely do take absolutes
# (it has no register table to relocate). tl39 owns ~30 Z2 literals, so
# Z2-canonical is the only contract that keeps them meaningful.
# ---------------------------------------------------------------------------
def _arg_addr(s):
    try:
        a = int(s, 16)
    except ValueError:
        sys.stderr.write("tl39: bad hex address %r\n" % s); sys.exit(2)
    try:
        return _R(a, what="command-line address")
    except SocMapError as e:
        sys.stderr.write(
            "\ntl39: REFUSING the access — %s\n\n"
            "Addresses are Z2-CANONICAL: pass the Z2 literal (e.g. 0x44032100) and\n"
            "tl39 relocates it for TIDELINK_SOC=%s. Do not pass a pre-relocated\n"
            "address — that would be remapped a second time.\n"
            % (e, os.environ.get("TIDELINK_SOC", "z2")))
        sys.exit(2)


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
    print("0x%08x" % rd(_arg_addr(sys.argv[2])))
elif cmd == "wr":
    wr(_arg_addr(sys.argv[2]), int(sys.argv[3], 16))
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
    # -------------------------------------------------------------------------
    # CORRECTED 2026-07-09. The comment that used to sit here claimed the RX
    # window is "a 32-slot ADDRESSED ring, NOT a pop-FIFO". That is WRONG. It
    # also contradicted this file's own docstring above ("rxn ... sequential
    # pops"). Believing it produced a string of meaningless delivery counts.
    #
    # The RTL (src/rtl/fifo/tidelink_fifo_ctrl.sv) is unambiguous:
    #   :141  translated_haddr = haddr + (hwrite ? write_ptr_r : read_ptr_r)
    #         -> a read returns SRAM[(haddr + read_ptr)>>2]. The base MOVES;
    #            offset i is NOT slot i.
    #   :107  read_complete = valid & (haddr == read_target_addr_r) & ~hwrite
    #   :118  on read_complete: read_ptr += (packet_delta<<2)   <- POP
    #         -> reading the packet's LAST word pops the whole packet.
    #   :201  a read of offset 0 latches the packet length from SRAM[31:20]
    #         -> a drain MUST start at offset 0.
    #   :184  a WRITE to offset 0 latches a NEW packet length -> writing zeros
    #         to "clear" the window starts a bogus packet and walks write_ptr.
    #
    # Correct usage: `drain` (below). Never random-access, never write to RXBASE.
    # Credit-instrumented version: pynq_host/scripts/tlfifo.py
    # -------------------------------------------------------------------------
    n = int(sys.argv[2])
    print(" ".join("0x%08x" % rd(RXBASE + i * 4) for i in range(n)))
elif cmd == "drain":
    # Pop exactly one packet, correctly: hdr + dest + payload.
    hdr = rd(RXBASE)                  # arms the length latch (fifo_ctrl:201)
    length = (hdr >> 20) & 0xFFF      # payload word count
    total = length + 2                # hdr + dest + payload
    words = [hdr] + [rd(RXBASE + i * 4) for i in range(1, total)]
    # the read of offset (length+1)*4 == read_target fires the pop
    print("len=%d %s" % (length, " ".join("0x%08x" % w for w in words)))
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
