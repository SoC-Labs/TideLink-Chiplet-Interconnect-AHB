#!/usr/bin/env python3
# =============================================================================
# kr260_tidechart.py — PS-side TideChart (chiplet identity / routing bootstrap)
#                      driver for the KR260 eth-chiplet, via the eth_ss_0 backdoor.
#
# TideChart is NOT PTP — it's USB/SpaceWire-style enumeration for a TideLink mesh:
# root (grandmaster) election -> ID assignment/enumeration -> routing + telemetry.
# APB at SoC 0x2E04_0000, reached PS-side at 0x4_2E04_0000. Register map from the
# deployed RTL (tidechart_apb_regs.sv); see docs/TIDECHART_TEST_PLAN.md.
#
# Packets only cross the D2D link in data mode (FCSM=4), so bring the TideLink
# link up on both boards first (kr260_eth_bringup.py --bringup). This tool only
# touches the 4 KB in-window register file — no peer-aperture wedge risk.
#
# Modes (run per board):
#   status     read-only baseline (T0): STATUS/DEVICE_CLASS/RANDOM_ID/ENUM_STATE.
#   prep       program the election/enum timeouts with measured margin. The old
#              advice here (election_timeout 0x8000) was MEASURED DUAL-ROOT 6/6
#              on this vehicle; see the ELECTION_TIMEOUT block below.
#   elect      write election_start, poll election_done, report is_root (T1/T2).
#              RUN ON BOTH BOARDS TOGETHER.
#   enum       write enum_start (ROOT only), poll enum_done, report IDs (T3).
#   route      read the route-table entry to the peer id (T4).
#   telemetry  enable+pulse congestion broadcast, read counters (T5).
#   reset      TC_CTRL reset (N3).
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import mmap
import os
import struct
import sys
import time

WINDOW_BASE = 0x400000000
TC_SOC_BASE = 0x2E040000                 # TideChart APB (SoC) -> PS 0x4_2E040000
TL_SWI_LANE_STATUS = 0x2E032108          # TideLink link status (for the FCSM gate)

# Register offsets (from tidechart_apb_regs.sv).
TC_STATUS       = 0x00   # [0]election_done [1]is_root [2]enum_done [7:3]local_id [12:8]total
TC_BEST_CLAIM   = 0x04   # [31:16]dev_class [15:0]random_id (winner)
TC_CTRL         = 0x08   # [0]election_start [1]enum_start [2]force_root [3]reset
                         # [4]timeout_hi_we (write strobe, reads 0)
                         # [23:16]election_timeout[23:16] [31:24]enum_timeout[23:16]
TC_TIMEOUT      = 0x0C   # [15:0]election_timeout [31:16]enum_timeout
TC_DEVICE_CLASS = 0x10   # [15:0]
TC_ROUTE_RD     = 0x18   # write [4:0]dest_id; read [2:0]egress [6:3]hop
TC_RANDOM_ID    = 0x1C   # [15:0]
TC_UPLINK_PORT  = 0x20   # [2:0]port [7]valid
TC_PORT_COUNT   = 0x24   # [2:0]
TC_ENUM_STATE   = 0x28   # 0 UNENUM 1 DISCOVERED 2 ASSIGNED 3 ACTIVE
TC_ERROR        = 0x2C   # [0]elec_to* [1]enum_to* [2]dual_root [3]cap_to [4]silent_root
                         # * [0]/[1] have no hardware setter and always read 0.
                         # [2] dual_root DID have no setter either (it read 0 in
                         # all six confirmed dual-root rounds, 2026-08-26); it and
                         # [4] silent_root are driven as of the TideChart
                         # fix/tidechart-dualroot-timeout-width RTL. On an OLDER
                         # bitstream both still read 0 -- do not treat 0 from an
                         # un-updated image as evidence of a single root.
TC_CONG_CTRL    = 0x74   # [0]bcast_enable [1]bcast_trigger(W1P)
TC_CONG_STATUS  = 0x78   # [15:8]last_tx_seq [23:16]rx_bcast [31:24]tx_bcast
TC_COST_RD      = 0x7C

CTRL_ELECTION_START = 1 << 0
CTRL_ENUM_START     = 1 << 1
CTRL_RESET          = 1 << 3
CTRL_TIMEOUT_HI_WE  = 1 << 4

ERR_DUAL_ROOT   = 1 << 2
ERR_SILENT_ROOT = 1 << 4

# =============================================================================
# ELECTION TIMEOUT -- MEASURED, NOT GUESSED
#
# The old value here, TIMEOUT_WIDE = 0x4000_8000 (election_timeout = 0x8000),
# WAS MEASURED DUAL-ROOT 6/6 on this exact vehicle. Anyone who followed this
# script's "prep" advice got two roots and would reasonably have concluded the
# timeout was not the cause. It was.
#
# kr260 eth-chiplet pair, two boards, 2026-08-26
# (evidence: td-bisect/election-2026-08-26/SUMMARY.json). Reset held constant,
# only election_timeout swept:
#
#   0x1000 (POR), 0x4000, 0x8000, 0xC000, 0xC800, 0xD000  -> DUAL ROOT
#   0xD800, 0xDC00, 0xE000, 0xFFFF                        -> single root
#                                                            (5/5 at 0xFFFF)
#
# Threshold: 53,248 < t <= 55,296 hclk. The register field used to be 16 bits,
# so its ceiling of 65,535 was 1.19x that minimum -- under 20% headroom, and
# NOT enough to be safe against any increase in D2D latency. The field is now
# 24 bits (ceiling 16,777,215) with the high 8 bits of each timeout carried in
# TC_CTRL[31:16], loaded only when CTRL_TIMEOUT_HI_WE is set in the same write.
#
# 262,144 = 4.74x the measured minimum, and is also the hardware default that a
# programmed value of 0 selects.
# =============================================================================
ELECTION_TIMEOUT = 262_144               # 0x04_0000, 4.74x the measured minimum
ENUM_TIMEOUT     = 262_144               # enumeration crosses the same link
TIMEOUT_MAX      = 0x00FF_FFFF

# Retained ONLY so the failure is documented in the file that caused it.
# Do not use: election_timeout 0x8000, measured dual-root 6/6.
TIMEOUT_WIDE_DEPRECATED = 0x4000_8000


def _mm(phys):
    page = phys & ~0xFFF
    off = phys - page
    f = open("/dev/mem", "r+b", buffering=0)
    try:
        m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
    except (OSError, PermissionError) as e:
        f.close()
        raise SystemExit("mmap /dev/mem @ 0x%X failed: %s (root? bitstream loaded?)"
                         % (page, e))
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


def tc_rd(off):
    return rd(WINDOW_BASE + TC_SOC_BASE + off)


def tc_wr(off, val):
    wr(WINDOW_BASE + TC_SOC_BASE + off, val)


def decode_status(s):
    return dict(election_done=s & 1, is_root=(s >> 1) & 1, enum_done=(s >> 2) & 1,
                local_id=(s >> 3) & 0x1F, total=(s >> 8) & 0x1F, raw=s)


def print_status(prefix=""):
    s = decode_status(tc_rd(TC_STATUS))
    dc = tc_rd(TC_DEVICE_CLASS) & 0xFFFF
    rid = tc_rd(TC_RANDOM_ID) & 0xFFFF
    es = tc_rd(TC_ENUM_STATE) & 0x3
    up = tc_rd(TC_UPLINK_PORT)
    print("%sTC_STATUS=0x%08X election_done=%d is_root=%d enum_done=%d local_id=%d total=%d"
          % (prefix, s["raw"], s["election_done"], s["is_root"], s["enum_done"],
             s["local_id"], s["total"]))
    print("%s  DEVICE_CLASS=0x%04X RANDOM_ID=0x%04X ENUM_STATE=%d UPLINK_PORT=0x%X(valid=%d)"
          % (prefix, dc, rid, es, up & 7, (up >> 7) & 1))
    return s


def link_fcsm4():
    st = rd(WINDOW_BASE + TL_SWI_LANE_STATUS)
    return ((st >> 17) & 7) == 4 and ((st >> 16) & 1) == 1, st


def require_link():
    up, st = link_fcsm4()
    print("  TideLink SWI_LANE_STATUS=0x%08X fcsm=%d cal=%d -> %s"
          % (st, (st >> 17) & 7, (st >> 16) & 1, "UP" if up else "DOWN"))
    if not up:
        print("ABORT: TideLink not FCSM=4 — TideChart packets cannot cross. Bring "
              "the link up on both boards first.", file=sys.stderr)
        raise SystemExit(2)


def do_status():
    print("=== TideChart status (read-only) @ 0x4_2E040000 ===")
    s = print_status("  ")
    print("  PORT_COUNT=%d TC_ERROR=0x%08X TC_BEST_CLAIM=0x%08X"
          % (tc_rd(TC_PORT_COUNT) & 7, tc_rd(TC_ERROR), tc_rd(TC_BEST_CLAIM)))
    return 0


def set_timeouts(election, enum_):
    """Program the full 24-bit election and enumeration timeouts.

    Two writes: TC_TIMEOUT carries the low 16 bits of each (legacy layout,
    unchanged), TC_CTRL[31:16] the high 8 bits of each. The high halves load
    only when CTRL_TIMEOUT_HI_WE is set in the same write, so the later
    `TC_CTRL <- CTRL_ELECTION_START` in do_elect() does NOT clobber them.
    """
    election &= TIMEOUT_MAX
    enum_ &= TIMEOUT_MAX
    lo = ((enum_ & 0xFFFF) << 16) | (election & 0xFFFF)
    hi = (CTRL_TIMEOUT_HI_WE
          | (((election >> 16) & 0xFF) << 16)
          | (((enum_ >> 16) & 0xFF) << 24))
    tc_wr(TC_TIMEOUT, lo)
    tc_wr(TC_CTRL, hi)
    return lo, hi


def do_prep():
    print("=== prep: program the election/enum timeouts with measured margin ===")
    lo, hi = set_timeouts(ELECTION_TIMEOUT, ENUM_TIMEOUT)
    rb_t = tc_rd(TC_TIMEOUT)
    rb_c = tc_rd(TC_CTRL)
    print("  TC_TIMEOUT <- 0x%08X (readback 0x%08X)" % (lo, rb_t))
    print("  TC_CTRL    <- 0x%08X (readback 0x%08X)" % (hi, rb_c))

    eff_election = (((rb_c >> 16) & 0xFF) << 16) | (rb_t & 0xFFFF)
    eff_enum = (((rb_c >> 24) & 0xFF) << 16) | ((rb_t >> 16) & 0xFFFF)
    print("  effective election_timeout = %d cycles (%.2fx the measured 55296 "
          "single-root minimum)" % (eff_election, eff_election / 55296.0))
    print("  effective enum_timeout     = %d cycles" % eff_enum)

    if eff_election != ELECTION_TIMEOUT:
        print("WARNING: election_timeout read back as %d, not %d." % (eff_election,
                                                                      ELECTION_TIMEOUT),
              file=sys.stderr)
        if eff_election == (ELECTION_TIMEOUT & 0xFFFF):
            print("         The high half did not stick: this bitstream predates the "
                  "24-bit timeout field. The election is capped at 65535 cycles = "
                  "1.19x the measured minimum and CAN still dual-root. Rebuild with "
                  "TideChart fix/tidechart-dualroot-timeout-width or newer.",
                  file=sys.stderr)
        return 2
    return 0


def do_elect(timeout_s, sync_at=0.0):
    print("=== election (T1/T2): start + poll (RUN ON BOTH BOARDS TOGETHER) ===")
    require_link()
    before = print_status("  before: ")
    if sync_at > 0:
        # Busy-wait to a shared wall-clock epoch so both dies write election_start
        # within NTP tolerance — the election window is <=1.3ms, far shorter than
        # SSH command skew, so both must enter it together.
        now = time.time()
        if sync_at > now:
            time.sleep(max(0.0, sync_at - now - 0.02))
            while time.time() < sync_at:
                pass
        print("  synced start at epoch %.3f (actual %.3f)" % (sync_at, time.time()))
    tc_wr(TC_CTRL, CTRL_ELECTION_START)
    deadline = time.time() + timeout_s
    s = before
    while time.time() < deadline:
        s = decode_status(tc_rd(TC_STATUS))
        if s["election_done"]:
            break
        time.sleep(0.02)
    after = print_status("  after:  ")
    bc = tc_rd(TC_BEST_CLAIM)
    print("  BEST_CLAIM=0x%08X (dev_class=0x%04X random_id=0x%04X)  RANDOM_ID(self)=0x%04X"
          % (bc, (bc >> 16) & 0xFFFF, bc & 0xFFFF, tc_rd(TC_RANDOM_ID) & 0xFFFF))
    if not after["election_done"]:
        print("RESULT: election_done NOT set in %.1fs (peer not started? timeout too "
              "short? link down?)" % timeout_s)
        return 2
    err = tc_rd(TC_ERROR)
    print("  TC_ERROR=0x%08X  dual_root=%d silent_root=%d"
          % (err, (err >> 2) & 1, (err >> 4) & 1))
    if err & ERR_DUAL_ROOT:
        print("RESULT: TC_ERROR.DUAL_ROOT is SET — a claim differing from the one "
              "this die settled on arrived after it settled. The two ends did NOT "
              "agree on a single root.")
        return 3
    if err & ERR_SILENT_ROOT:
        print("RESULT: TC_ERROR.SILENT_ROOT is SET — this die declared itself root "
              "without ever receiving a claim on an active link. Its peer had not "
              "started, or claims are not crossing. Do NOT trust is_root here.")
        return 3
    print("RESULT: election_done=1, is_root=%d, no election-integrity error. "
          "(Exactly one die must be root — compare both boards. Note: on a "
          "bitstream older than the 24-bit-timeout TideChart RTL, TC_ERROR[2] and "
          "[4] read 0 because they have no setter — 0 there proves nothing.)"
          % after["is_root"])
    return 0


def do_enum(timeout_s):
    print("=== enumeration (T3): enum_start on the ROOT die, poll enum_done ===")
    require_link()
    s = decode_status(tc_rd(TC_STATUS))
    if not s["is_root"]:
        print("  NOTE: this die is_root=0 — enum_start on a non-root is a no-op "
              "(N1). Run this on the ROOT die.")
    tc_wr(TC_CTRL, CTRL_ENUM_START)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        s = decode_status(tc_rd(TC_STATUS))
        if s["enum_done"]:
            break
        time.sleep(0.02)
    print_status("  after:  ")
    print("RESULT: enum_done=%d local_id=%d total=%d ENUM_STATE=%d"
          % (s["enum_done"], s["local_id"], s["total"], tc_rd(TC_ENUM_STATE) & 3))
    return 0 if s["enum_done"] else 2


def do_route(peer_id):
    print("=== route table (T4): read entry to dest %d ===" % peer_id)
    tc_wr(TC_ROUTE_RD, peer_id & 0x1F)
    r = tc_rd(TC_ROUTE_RD)
    print("  ROUTE to %d: egress_port=%d hop=%d (raw 0x%08X)"
          % (peer_id, r & 7, (r >> 3) & 0xF, r))
    return 0


def do_telemetry():
    print("=== telemetry (T5): enable + pulse congestion broadcast ===")
    tc_wr(TC_CONG_CTRL, 0x1)
    tc_wr(TC_CONG_CTRL, 0x3)
    time.sleep(0.05)
    cs = tc_rd(TC_CONG_STATUS)
    print("  TC_CONG_STATUS=0x%08X tx_bcast=%d rx_bcast=%d last_tx_seq=%d"
          % (cs, (cs >> 24) & 0xFF, (cs >> 16) & 0xFF, (cs >> 8) & 0xFF))
    return 0


def do_reset():
    print("=== reset (N3): TC_CTRL reset ===")
    tc_wr(TC_CTRL, CTRL_RESET)
    time.sleep(0.02)
    print_status("  after reset: ")
    return 0


def main():
    ap = argparse.ArgumentParser(description="PS-side TideChart driver (KR260 "
                                 "eth-chiplet, eth_ss_0 backdoor).")
    ap.add_argument("--mode", default="status",
                    choices=("status", "prep", "elect", "enum", "route",
                             "telemetry", "reset"))
    ap.add_argument("--peer-id", type=int, default=0, help="route mode: dest id.")
    ap.add_argument("--timeout", type=float, default=5.0,
                    help="elect/enum poll timeout seconds (default 5).")
    ap.add_argument("--sync-at", type=float, default=0.0,
                    help="elect mode: wall-clock epoch to start election (both "
                         "boards pass the same value for a synchronized start).")
    args = ap.parse_args()
    if os.geteuid() != 0:
        print("ERROR: needs root for /dev/mem (sudo).", file=sys.stderr)
        return 4
    return {
        "status": do_status, "prep": do_prep, "reset": do_reset,
        "telemetry": do_telemetry,
        "elect": lambda: do_elect(args.timeout, args.sync_at),
        "enum": lambda: do_enum(args.timeout),
        "route": lambda: do_route(args.peer_id),
    }[args.mode]()


if __name__ == "__main__":
    sys.exit(main())
