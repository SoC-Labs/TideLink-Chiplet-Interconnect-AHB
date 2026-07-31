#!/usr/bin/env python3
# =============================================================================
# xfer_corners_lib.py — shared framework for the cross-die corner/soak tests on
#                       the KR260 eth-chiplet pair (PS-side, eth_ss_0 backdoor).
#
# This is a LIBRARY, not a runnable test. It gives kr260_eth_xfer.py's new
# adversarial-soak + corner modes (and any bespoke corner script) three things:
#
#   1. A DETERMINISTIC payload generator — golden()/beat()/final_values() — so a
#      die_a SENDER and a die_b VERIFIER reconstruct the identical stream from a
#      single --seed, with no side-channel. Payload classes stress the delivery
#      path differently (all-0, all-1, walking-1/0, PRBS32, and an addr-xor class
#      that folds the destination offset into the value so a MIS-DELIVERED beat
#      fails its OWN check).
#
#   2. A wedge-aware HEALTH snapshot — snap_health()/health_ok()/classify_wedge()
#      — reading the Region F AXI-node observability plane (0x2E03_21E0) that the
#      root-cause work added specifically because OBS_FC_CREDIT/SWI_LANE only see
#      the FCSM_6 sideband, NOT the five AXI data nodes that actually wedge
#      (docs/CROSS_DIE_WEDGE_ROOTCAUSE.md). A caller can sample this BETWEEN beats
#      and fail-fast on a latched wedge-sticky *before* the PS AXI bus saturates.
#
#   3. A recovery_ladder() that PRINTS the graded recovery guidance (host FLUSH ->
#      LL-swreset re-bringup -> JTAG-POR) so every peer-touching test tells the
#      operator what to do when it wedges.
#
# The rd/wr/link_status/program_cam_rule primitives are imported from
# kr260_eth_xfer.py (the proven, wedge-safe access layer). A local /dev/mem
# fallback keeps the lib importable + unit-testable in isolation.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import struct
import sys
import time

# --- primitives: reuse the proven access layer from kr260_eth_xfer.py --------
# We import the four ground-truth primitives the audit named. If that import
# fails (lib used stand-alone / under a linter), fall back to a local mmap layer
# that is byte-for-byte the same behaviour, so nothing here silently diverges.
try:
    from kr260_eth_xfer import (rd, wr, link_status, program_cam_rule,
                                 WINDOW_BASE)
except Exception:                                            # pragma: no cover
    import mmap
    WINDOW_BASE = 0x400000000

    def _mm(phys):
        page = phys & ~0xFFF
        off = phys - page
        f = open("/dev/mem", "r+b", buffering=0)
        m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
        return f, m, off

    def rd(phys):
        f, m, off = _mm(phys)
        v = struct.unpack("<I", m[off:off + 4])[0]
        m.close(); f.close()
        return v

    def wr(phys, val):
        f, m, off = _mm(phys)
        m[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)
        m.close(); f.close()

    def link_status():
        st = rd(WINDOW_BASE + 0x2E030000 + 0x2108)
        up = ((st >> 17) & 7) == 4 and ((st >> 16) & 1) == 1
        return up, st

    def program_cam_rule(rule_value):
        base = WINDOW_BASE + 0x2E030000
        wr(base + 0x4000, 0)
        wr(base + 0x4010, rule_value)
        wr(base + 0x4004, 1)

# =============================================================================
# Ground-truth register map (SoC-internal offsets; PS phys = WINDOW_BASE + off).
# All verified addresses from the I1-RESOLVED handover / Region-F obs plane.
# =============================================================================
_TLAPB = 0x2E030000

REG_SWI_LANE      = _TLAPB + 0x2108   # [16]cal [19:17]fcsm [23]cr [24]crack [31]fe_rx_is_full
REG_STATUS        = _TLAPB + 0x2010   # sticky [1]OVER [2]UNDER [3]MASTER_ERR
REG_CREDIT_COUNT  = _TLAPB + 0x200C   # RO local free-credit count (13-bit)
REG_OBS_FC_CREDIT = _TLAPB + 0x219C   # RO far-end credit obs (sideband FCSM_6 ONLY)
REG_OBS_AXI_NODES = _TLAPB + 0x21E0   # Region F — the AXI-data-node obs plane
REG_ERR_INJECT    = _TLAPB + 0x003C   # Wlink single-bit error injector

# CAM (address translator) — rule = replace<<16 | match<<8 | en
CAM_BASE  = _TLAPB + 0x4000
CAM_CTRL  = _TLAPB + 0x4004
CAM_RULE0 = _TLAPB + 0x4010

STATUS_STICKY_MASK = 0xE              # bits [3:1]
SWI_FE_RX_FULL     = 1 << 31          # SWI_LANE[31] — the ring-full permanent-wedge flag
FCSM_LINK_IDLE     = 4
REGF_MARKER        = 0xAD             # OBS_AXI_NODES[31:24] fixed marker when obs plane present

# --- per-node Wlink FC health (the five AXI data nodes are the wedge-prone set) --
FC_NODES = (("AW", 0x1000), ("W", 0x1100), ("B", 0x1200), ("AR", 0x1300),
            ("R", 0x1400), ("GenBus", 0x1600), ("TideLink", 0x1700))
FC_AXI_NODES = ("AW", "W", "B", "AR", "R")
FC_TXFIFO  = 0x08     # [0] FIFO empty
FC_ACKNACK = 0x10     # [0]empty [1]full [2]halffull [3]almostempty [4]almostfull
FC_DISCRC  = 0x14     # [16] disable_crc
FC_CRC     = 0x20     # [15:0] CRC error count (RO)

# --- error-injection data-node IDs (0x2E03_003C DataID field) -----------------
INJECT_IDS = {"B": 0x82, "R": 0x84, "W": 0x81}   # data-node targets
INJECT_ID_CR = 0x44                              # sideband CR (do NOT use for data tests)

# --- shared_sram_0 fold: 16 MB peer window -> 8 KB SRAM (offsets fold mod 8 KB) -
SRAM_FOLD = 0x2000    # 8 KB
DEFAULT_WIN = 16      # words in the cycling soak window (matches legacy soak)


# =============================================================================
# 1. DETERMINISTIC PAYLOAD GENERATOR
# =============================================================================
PAYLOAD_CLASSES = ("ZERO", "ONES", "WALK1", "WALK0", "PRBS32", "ADDRXOR")


def _xorshift32(x):
    """Marsaglia xorshift32 — the PRBS32 core. Pure, portable, 32-bit wrap."""
    x &= 0xFFFFFFFF
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= (x >> 17)
    x ^= (x << 5) & 0xFFFFFFFF
    return x & 0xFFFFFFFF


def _mix(seed, i):
    """Deterministic 32-bit hash of (seed, i). Decorrelates class selection from
    the PRBS value so consecutive beats are not trivially related."""
    x = (seed ^ 0x9E3779B9) & 0xFFFFFFFF
    x = _xorshift32(x ^ (((i + 1) * 0x85EBCA6B) & 0xFFFFFFFF))
    x = _xorshift32(x + (i & 0xFFFFFFFF))
    return x


def golden(seed, i):
    """Pure payload function: (value, class_name) for beat i of stream `seed`.

    Offset-INDEPENDENT. The ADDRXOR class returns only its seed-mixed base here;
    beat() folds the destination byte-offset into it (it is the one class whose
    final value depends on where it lands). Both sender and verifier call the
    same function, so the stream is reproducible from just --seed."""
    h = _mix(seed, i)
    cls = PAYLOAD_CLASSES[h % len(PAYLOAD_CLASSES)]
    if cls == "ZERO":
        v = 0x00000000
    elif cls == "ONES":
        v = 0xFFFFFFFF
    elif cls == "WALK1":
        v = (1 << (h % 32)) & 0xFFFFFFFF
    elif cls == "WALK0":
        v = (~(1 << (h % 32))) & 0xFFFFFFFF
    elif cls == "PRBS32":
        v = _xorshift32(h ^ 0xC2B2AE35)
    else:  # ADDRXOR base (beat() XORs the offset in)
        v = ((seed & 0xFFFF0000) ^ 0xA5A50000 ^ (i & 0x0000FFFF)) & 0xFFFFFFFF
    return v, cls


def beat(seed, i, win_words=DEFAULT_WIN):
    """(word_offset, byte_offset, value, class) for beat i over a cycling window
    of `win_words` words. byte_offset is folded mod 8 KB (the shared_sram_0 wrap).
    ADDRXOR folds byte_offset into the value: a beat that lands at the wrong
    offset then fails its own check (mis-delivery detector)."""
    v, cls = golden(seed, i)
    word_off = i % win_words
    byte_off = (word_off * 4) % SRAM_FOLD
    if cls == "ADDRXOR":
        v = (v ^ byte_off) & 0xFFFFFFFF
    return word_off, byte_off, v, cls


def final_values(seed, n, win_words=DEFAULT_WIN):
    """Last-writer-wins expected SRAM state after n beats over the window.

    Because the 16 MB aperture folds onto 8 KB, several beats can alias to one
    physical word; only the LAST writer survives. A verifier that wants to check
    the final SRAM (not each transient beat) uses this. Returns
    {byte_offset: (value, class_name, last_i)}."""
    out = {}
    for i in range(n):
        word_off, byte_off, v, cls = beat(seed, i, win_words)
        out[byte_off] = (v, cls, i)
    return out


# =============================================================================
# 2. WEDGE-AWARE HEALTH SNAPSHOT
# =============================================================================
def snap_health():
    """One RO pass over the health plane. Returns a decoded dict. Reads ONLY
    RO/config-plane addresses inside the eth_ss_0 window -> cannot wedge."""
    swi = rd(WINDOW_BASE + REG_SWI_LANE)
    status = rd(WINDOW_BASE + REG_STATUS)
    credit = rd(WINDOW_BASE + REG_CREDIT_COUNT) & 0x1FFF
    obsfc = rd(WINDOW_BASE + REG_OBS_FC_CREDIT)
    regf = rd(WINDOW_BASE + REG_OBS_AXI_NODES)

    fcsm = (swi >> 17) & 7
    cal = (swi >> 16) & 1
    marker = (regf >> 24) & 0xFF
    h = {
        "swi_lane": swi,
        "fcsm": fcsm,
        "cal": cal,
        "cr_seen": (swi >> 23) & 1,
        "crack": (swi >> 24) & 1,
        "fe_rx_full": (swi >> 31) & 1,
        "link_up": fcsm == FCSM_LINK_IDLE and cal == 1,
        "status": status,
        "sticky": status & STATUS_STICKY_MASK,
        "credit": credit,
        "obs_fc_credit": obsfc,
        "regf_raw": regf,
        "regf_marker": marker,
        "regf_present": marker == REGF_MARKER,
        "tgt_live":     regf & 0x1F,           # [4:0]   live-stall {r,ar,b,w,aw}
        "ini_live":     (regf >> 5) & 0x1F,    # [9:5]   initiator live-stall
        "tgt_wsticky":  (regf >> 10) & 0x1F,   # [14:10] target wedge-sticky
        "ini_wsticky":  (regf >> 15) & 0x1F,   # [19:15] initiator wedge-sticky
        "tgt_resperr":  (regf >> 20) & 1,      # [20]    target resp-err
        "ini_resperr":  (regf >> 21) & 1,      # [21]    initiator resp-err
        "data_healthy": (regf >> 23) & 1,      # [23]    data_nodes_healthy
    }
    return h


def health_ok(h):
    """True when nothing on the health plane indicates a fault. If the Region F
    obs plane is absent from this bitstream (marker != 0xAD) its fields are not
    asserted on — we fall back to SWI_LANE + sticky STATUS only."""
    ok = h["link_up"] and h["sticky"] == 0 and not h["fe_rx_full"]
    if h["regf_present"]:
        ok = ok and h["data_healthy"] == 1 \
            and h["tgt_wsticky"] == 0 and h["ini_wsticky"] == 0 \
            and h["tgt_resperr"] == 0 and h["ini_resperr"] == 0
    return bool(ok)


def classify_wedge(h):
    """Host-side classification of the wedge signature (a HEURISTIC over the obs
    plane, not an authoritative RTL-state decode):

      CLASSIC      SWI_LANE[31] fe_rx_is_full latched — the canonical AXI-node
                   ring-full PERMANENT wedge (docs/CROSS_DIE_WEDGE_ROOTCAUSE.md).
                   PS AXI bus is (or is about to be) saturated -> JTAG-POR only.
      AXI_WEDGE    Region F wedge-sticky latched on a target/initiator AXI node
                   but the ring is not yet full — an AXI FC node has stopped
                   emitting (no socl_reack backstop on silicon).
      HELD_REPLAY  a live-stall / resp-err is currently asserted (or a sticky
                   STATUS master-error) but nothing has latched permanently — a
                   NACK/replay in flight; may still clear with a host FLUSH.
      NONE         healthy.
    """
    if h["fe_rx_full"]:
        return "CLASSIC"
    if h["regf_present"] and (h["tgt_wsticky"] or h["ini_wsticky"]):
        return "AXI_WEDGE"
    if h["regf_present"] and (h["tgt_live"] or h["ini_live"]
                              or h["tgt_resperr"] or h["ini_resperr"]):
        return "HELD_REPLAY"
    if h["sticky"]:
        return "HELD_REPLAY"
    return "NONE"


def _regf_names(mask):
    # bit order per ground truth: [4:0] = {r, ar, b, w, aw} (bit0=r .. bit4=aw)
    names = ("r", "ar", "b", "w", "aw")
    return ",".join(n for i, n in enumerate(names) if (mask >> i) & 1) or "-"


def print_health(h, prefix="  "):
    """Human-readable one-block dump of a snap_health() dict."""
    print("%sSWI_LANE=0x%08X  fcsm=%d cal=%d cr=%d crack=%d fe_rx_full=%d -> %s"
          % (prefix, h["swi_lane"], h["fcsm"], h["cal"], h["cr_seen"],
             h["crack"], h["fe_rx_full"], "UP" if h["link_up"] else "DOWN"))
    print("%sSTATUS=0x%08X sticky[3:1]=0x%X  CREDIT_COUNT=%d  OBS_FC_CREDIT=0x%08X"
          % (prefix, h["status"], h["sticky"], h["credit"], h["obs_fc_credit"]))
    if h["regf_present"]:
        print("%sRegionF=0x%08X (marker=0x%02X)  data_healthy=%d"
              % (prefix, h["regf_raw"], h["regf_marker"], h["data_healthy"]))
        print("%s  live-stall  tgt{%s} ini{%s}   wedge-sticky tgt{%s} ini{%s}"
              "   resp-err tgt=%d ini=%d"
              % (prefix, _regf_names(h["tgt_live"]), _regf_names(h["ini_live"]),
                 _regf_names(h["tgt_wsticky"]), _regf_names(h["ini_wsticky"]),
                 h["tgt_resperr"], h["ini_resperr"]))
    else:
        print("%sRegionF marker=0x%02X (expect 0xAD) -> AXI-node obs plane NOT in "
              "this bitstream; wedge detection falls back to SWI_LANE+sticky only"
              % (prefix, h["regf_marker"]))


def recovery_ladder(cls, prefix="  "):
    """PRINT the graded recovery guidance. Every peer-touching test calls this on
    a wedge so the operator (attended session) knows the escalation path. The
    recommended STARTING rung for `cls` is marked '>>>'."""
    start = {"NONE": -1, "HELD_REPLAY": 1, "AXI_WEDGE": 2, "CLASSIC": 3}.get(cls, 1)
    print("%s---- RECOVERY LADDER (wedge class = %s) ----" % (prefix, cls))
    if cls == "NONE":
        print("%s  health plane clean — no recovery needed." % prefix)
        return
    rungs = [
        (1, "HOST FLUSH (non-destructive, no rebuild)",
         ["CTRL FLUSH: write 0x2E03_201C bit[1]=1 (W1P) to clear sticky faults,",
          "then SWI_FORCE_RECAL if a rising CRC was seen; re-read Region F.",
          "If it clears: resume with SHORTER bursts + re-cal between bursts."]),
        (2, "LL-SWRESET bilateral RE-BRINGUP (link re-init, no POR)",
         ["Re-run bringup_pair_release.sh (the FIX-E S_HOLD-barrier orchestrator)",
          "on BOTH dies. HAZARD: never LL-swreset ONE side of a live link — the",
          "first to reset stops sending the training the peer needs (2026-07-29",
          "wedge). Only use while PS accesses still RETURN (no bus hang yet)."]),
        (3, "JTAG-POR both boards (hard recovery)",
         ["PS AXI bus is saturated (fe_rx_is_full / accesses hang, no timeout).",
          "JTAG-POR BOTH boards via mapstone-dev, then bringup_pair_release.sh.",
          "This is the ONLY recovery once the SmartConnect has wedged."]),
    ]
    for n, title, lines in rungs:
        mark = ">>>" if n == start else "   "
        print("%s%s rung %d: %s" % (prefix, mark, n, title))
        for ln in lines:
            print("%s        %s" % (prefix, ln))


# =============================================================================
# 3. PER-NODE FC + ERROR-INJECTION HELPERS
# =============================================================================
def fc_node_snapshot():
    """Read the per-node Wlink FC registers (RO, safe). Returns
    {name: {"crc":.., "acknack":.., "an_empty":.., "txfifo_empty":..}}."""
    out = {}
    for name, base in FC_NODES:
        an = rd(WINDOW_BASE + _TLAPB + base + FC_ACKNACK)
        out[name] = {
            "crc": rd(WINDOW_BASE + _TLAPB + base + FC_CRC) & 0xFFFF,
            "acknack": an,
            "an_empty": an & 1,
            "an_full": (an >> 1) & 1,
            "txfifo_empty": rd(WINDOW_BASE + _TLAPB + base + FC_TXFIFO) & 1,
        }
    return out


def fc_crc_of(node):
    """Single node's CRC-error count (RO)."""
    base = dict(FC_NODES)[node]
    return rd(WINDOW_BASE + _TLAPB + base + FC_CRC) & 0xFFFF


def error_inject(data_id, byte=0, bit=0):
    """Arm the Wlink single-bit error injector (0x2E03_003C):
       [7:0]DataID [15:8]Byte [18:16]Bit [24]Enable.
    ATTENDED / SINGLE-SHOT: this deliberately corrupts one bit of the next packet
    on `data_id`'s node — on silicon that node has no recovery, so a wedge is the
    EXPECTED-possible outcome (JTAG-POR staged). Returns the value written."""
    val = ((1 << 24) | ((bit & 7) << 16) | ((byte & 0xFF) << 8)
           | (data_id & 0xFF)) & 0xFFFFFFFF
    wr(WINDOW_BASE + REG_ERR_INJECT, val)
    return val


def error_inject_off():
    """Disable the injector (clear enable)."""
    wr(WINDOW_BASE + REG_ERR_INJECT, 0)


def require_link_or_die():
    """Abort (rc 2) unless the local TideLink reports FCSM=4. Mirrors
    kr260_eth_xfer._require_link so corner tests refuse to peer-access a down
    link (wedge risk)."""
    up, st = link_status()
    print("  link SWI_LANE_STATUS=0x%08X fcsm=%d cal=%d -> %s"
          % (st, (st >> 17) & 7, (st >> 16) & 1, "UP" if up else "DOWN"))
    if not up:
        print("ABORT: link not FCSM=4. Bring it up on BOTH boards first "
              "(bringup_pair_release.sh). Refusing to peer-access a down link.",
              file=sys.stderr)
        raise SystemExit(2)


def gate_or_ladder(tag="post"):
    """Sample health; if a wedge is classified, print the class + recovery ladder
    and return (ok=False, cls). Otherwise (True, 'NONE'). Callers use this to
    fail-fast BEFORE the bus hangs."""
    h = snap_health()
    cls = classify_wedge(h)
    if cls != "NONE" or not health_ok(h):
        print("  !! HEALTH FAULT (%s): wedge class=%s" % (tag, cls))
        print_health(h)
        recovery_ladder(cls)
        return False, cls
    return True, cls


if __name__ == "__main__":
    # Not a test — a tiny self-check of the pure payload generator (no HW).
    print("xfer_corners_lib self-check (payload generator only; no /dev/mem):")
    seed = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0xC0FFEE
    n = 12
    for i in range(n):
        wo, bo, v, cls = beat(seed, i, DEFAULT_WIN)
        print("  i=%2d win_off=0x%04X val=0x%08X class=%s" % (i, bo, v, cls))
    fv = final_values(seed, n, DEFAULT_WIN)
    print("  last-writer-wins offsets: %d distinct words" % len(fv))
    # determinism assertion
    assert beat(seed, 5) == beat(seed, 5), "beat() not deterministic!"
    assert golden(seed, 5) == golden(seed, 5), "golden() not deterministic!"
    print("  determinism OK")
