#!/usr/bin/env python3
# =============================================================================
# kr260_eth_bringup.py — PS-side TideLink link bring-up for the nanoSoC
#                        ETH-CHIPLET on a plain-Ubuntu KR260.
#
# WHAT THIS IS
# ------------
# The on-silicon equivalent of verif/g2_soc_pair/test_g2_soc_pair.py's link
# bring-up, driven from the ZynqMP PS instead of a cocotb AHB master. It brings
# the internal TideLink die-to-die link up to FCSM=4 (LINK_IDLE, bilateral) by
# writing the SAME TideLink-APB register recipe the sim proves, reached through
# the eth_ss_0 AHB backdoor.
#
# NO FIRMWARE, NO SWD PROBE. D2D_PORT.md §3 ("Who can reach what") is explicit:
# `d2d` is an outbound target of the PS-facing masters, so "link bring-up — role
# strap, calibration poll, training drop — can be driven with no CPU firmware
# running, the way tidelink's own pynq_host scripts drive it over the PS bus."
# This is that script, for the eth-chiplet.
#
# THE ADDRESS MODEL — why NOT the bare-link map (this is the wedge trap)
# ---------------------------------------------------------------------
# The bare-link kr260-pair-* tooling (tl_socmap.py, tl39.py, kr260_afi.sh) pokes
# TideLink at 0x8403_xxxx / 0x8000_0000. On the ETH-CHIPLET those are UNDECODED
# PL addresses — reading one hangs the ZynqMP PS AXI bus with no timeout (JTAG
# POR to recover). DO NOT use the bare-link tools here.
#
# The eth-chiplet PS reaches the SoC ONLY through the eth_ss_0 backdoor. On the
# built kr260-eth-chiplet bitstream that window is the HPM0_FPD HIGH aperture:
#
#     PS phys 0x4_0000_0000 .. 0x4_FFFF_FFFF   (tidelink.hwh MEMRANGE, eth_ss_0)
#     PS phys 0x4_0000_0000 + A   ->   SoC HADDR A            (clean base-strip)
#
# So a SoC-internal address A is reachable from the PS at WINDOW_BASE + A. The
# TideLink APB lives at SoC 0x2E03_0000 (the chiplet-decode tlapb bridge), hence
# the PS reaches it at 0x4_2E03_0000. This tool ONLY touches the TideLink CONFIG
# APB (0x2E03_xxxx); it never touches the peer DATA aperture (0x2F..) — that is
# the historically wedge-prone path (docs/D2D_HREADY_LOOP.md).
#
# WHY IN-WINDOW ACCESS IS SAFE (won't wedge like the bare-link canary did)
# -----------------------------------------------------------------------
# The SoC's eth_ss AHB matrix has a CMSDK default slave on the FREE-RUNNING
# system clock: an undecoded in-window transfer returns HREADY=1 + SLVERR rather
# than hanging. The config-APB registers themselves terminate (real APB HREADY).
# The class of hang the bare-link canary hit was an *out-of-window* PL access
# with no SmartConnect responder — which this tool cannot issue (it refuses any
# address outside the eth_ss_0 window / TideLink APB span).
#
# THE PAIR PROCEDURE (matches the runbook's pair-safety rule)
# ----------------------------------------------------------
#   POWER-CYCLE both boards -> deploy die_a image to one, die_b (-flip) to the
#   other -> run THIS on BOTH boards together. Each die's cal_done only asserts
#   once BOTH have role-locked and the forwarded-clock RX trains against the
#   peer over the ribbon, so the two independent runs self-synchronise. Success
#   on both = FCSM==4 (LINK_IDLE) with calibration_done==1.
#
# Default action is --status (READ-ONLY, safe: reads only RO APB registers).
# --bringup performs the write sequence.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import mmap
import os
import struct
import sys
import time

# --- eth_ss_0 backdoor window (PS physical) ---------------------------------
WINDOW_BASE = 0x400000000          # HPM0_FPD high aperture; tidelink.hwh:4112

# --- SoC-internal TideLink APB (reached via the chiplet-decode tlapb bridge) -
# Offsets are IDENTICAL to test_g2_soc_pair.py / tidelink REGISTER_MAP.md, so
# every tidelink register address stays valid after one base substitution.
TLAPB_SOC_BASE = 0x2E030000        # SoC HADDR of the TideLink APB region
_WLINK_BANK    = 0x0000            # bank 0: Wlink chiplet-controller regs (8 KB)
_TIDELINK_BANK = 0x2000            # bank 1: TideLink config + status (8 KB)

# Register offsets, RELATIVE TO TLAPB_SOC_BASE.
REG_WL_LINK_ENABLE_RESET = _WLINK_BANK    + 0x0208   # 0x2E030208 (Wlink LL enable/reset)
REG_ROLE_CFG             = _TIDELINK_BANK  + 0x0080   # 0x2E032080 (RW role select+lock)
REG_ROLE_STATUS          = _TIDELINK_BANK  + 0x0084   # 0x2E032084 (RO effective role)
REG_SWI_TRAINING_MODE    = _TIDELINK_BANK  + 0x0100   # 0x2E032100 (sim "SLOT0")
REG_SWI_LANE_STATUS      = _TIDELINK_BANK  + 0x0108   # 0x2E032108 (RO cal/fcsm/lanes)

# ROLE_CFG (0x2080): bit[0]=role (0 master, 1 slave), bit[1]=role_lock.
ROLE_CFG_MASTER_LOCK = 0x02        # role_lock=1, role=0 -> master / grandmaster (die_a)
ROLE_CFG_SLAVE_LOCK  = 0x03        # role_lock=1, role=1 -> slave              (die_b)

# 3-write LL bootstrap into WL_LINK_ENABLE_RESET; order matters (swreset first
# clears CR/CRACK sticky), exactly as test_g2_soc_pair.py.
LL_SWRESET_ON  = 0x00027F08
LL_SWRESET_OFF = 0x00027F00
LL_ENABLE      = 0x00027F07

FCSM_LINK_IDLE = 4                 # link-up criterion (bilateral)

# Map span from TLAPB_SOC_BASE: 16 KB covers the highest offset we touch (0x2108).
_MAP_SPAN = 0x4000
_ROLE_NAMES = {"die_a": (ROLE_CFG_MASTER_LOCK, 0, "master/grandmaster"),
               "die_b": (ROLE_CFG_SLAVE_LOCK,  1, "slave")}


class Backdoor:
    """mmap of the TideLink APB, reached through the eth_ss_0 PS backdoor.

    Only the 16 KB TideLink-APB span is mapped, so no accessor in this class can
    reach the wedge-prone peer aperture or any out-of-window PL address.
    """

    def __init__(self, window_base=WINDOW_BASE):
        self.map_phys = window_base + TLAPB_SOC_BASE      # e.g. 0x4_2E03_0000
        if self.map_phys % mmap.PAGESIZE != 0:
            raise ValueError("map base 0x%X not page-aligned" % self.map_phys)
        self._f = open("/dev/mem", "r+b", buffering=0)
        try:
            self._m = mmap.mmap(self._f.fileno(), _MAP_SPAN,
                                mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE,
                                offset=self.map_phys)
        except (PermissionError, OSError) as e:
            self._f.close()
            raise SystemExit(
                "mmap /dev/mem @ 0x%X failed: %s\n"
                "  - run as root (sudo), and\n"
                "  - if STRICT_DEVMEM blocks it, the board needs /dev/mem access "
                "to PL apertures.\n"
                "  Confirm the eth-chiplet bitstream is loaded (fpga_manager="
                "operating)." % (self.map_phys, e))

    def rd(self, off):
        return struct.unpack("<I", self._m[off:off + 4])[0]

    def wr(self, off, val):
        self._m[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)

    def close(self):
        try:
            self._m.close()
        finally:
            self._f.close()


def decode_status(v):
    return {
        "raw": v,
        "lane_locked": v & 0xFF,
        "lane_fault": (v >> 8) & 0xFF,
        "cal_done": (v >> 16) & 1,
        "fcsm": (v >> 17) & 0x7,
        "cr_seen": (v >> 23) & 1,
        "crack_seen": (v >> 24) & 1,
    }


def print_status(bd, prefix=""):
    role_st = bd.rd(REG_ROLE_STATUS)
    st = decode_status(bd.rd(REG_SWI_LANE_STATUS))
    eff = role_st & 1
    print("%sROLE_STATUS  0x2E032084 = 0x%08X  (effective_role=%d -> %s)"
          % (prefix, role_st, eff, "slave" if eff else "master"))
    print("%sSWI_LANE_STAT 0x2E032108 = 0x%08X" % (prefix, st["raw"]))
    print("%s   calibration_done=%d  fcsm=%d%s  lane_locked=0x%02X "
          "lane_fault=0x%02X  cr_seen=%d crack_seen=%d"
          % (prefix, st["cal_done"], st["fcsm"],
             "  (LINK_IDLE)" if st["fcsm"] == FCSM_LINK_IDLE else "",
             st["lane_locked"], st["lane_fault"], st["cr_seen"], st["crack_seen"]))
    return st


def bringup(bd, role, cal_timeout, converge_timeout):
    cfg, want_eff, human = _ROLE_NAMES[role]
    print("=== eth-chiplet TideLink bring-up: %s (%s) ===" % (role, human))
    print("--- initial status ---")
    print_status(bd, "   ")

    # 1. role select + lock.
    print("--- 1. ROLE_CFG <- 0x%02X (role_lock=1, role=%d) ---" % (cfg, want_eff))
    bd.wr(REG_ROLE_CFG, cfg)
    time.sleep(0.01)
    eff = bd.rd(REG_ROLE_STATUS) & 1
    if eff != want_eff:
        print("   WARN: effective_role reads %d, expected %d (role not locked yet?)"
              % (eff, want_eff))
    else:
        print("   effective_role=%d confirmed" % eff)

    # 2. wait for calibration_done. On silicon the calibrator runs the real
    #    winscan against the PEER die over the ribbon — so this only completes
    #    when the far board has ALSO role-locked and is training. A timeout here
    #    almost always means "peer not up / ribbon" not "this die broken".
    print("--- 2. poll calibration_done (needs the peer die + ribbon) ---")
    deadline = time.time() + cal_timeout
    cal = 0
    while time.time() < deadline:
        cal = decode_status(bd.rd(REG_SWI_LANE_STATUS))["cal_done"]
        if cal:
            break
        time.sleep(0.02)
    if not cal:
        print("   cal_done did NOT assert in %.1fs." % cal_timeout)
        print("   Check: peer board running this too? ribbon seated? die_a<->die_b "
              "images not swapped?")
        print_status(bd, "   ")
        return 2
    print("   cal_done=1")

    # 3. to data mode: clear training mode, then the 3-write LL bootstrap.
    print("--- 3. to-data-mode: SWI_TRAINING_MODE<-0, then LL enable sequence ---")
    bd.wr(REG_SWI_TRAINING_MODE, 0)
    time.sleep(0.005)
    for val in (LL_SWRESET_ON, LL_SWRESET_OFF, LL_ENABLE):
        bd.wr(REG_WL_LINK_ENABLE_RESET, val)
        time.sleep(0.005)

    # 4. converge -> FCSM==4 (LINK_IDLE).
    print("--- 4. poll FCSM==%d (LINK_IDLE) ---" % FCSM_LINK_IDLE)
    deadline = time.time() + converge_timeout
    st = decode_status(bd.rd(REG_SWI_LANE_STATUS))
    while time.time() < deadline:
        st = decode_status(bd.rd(REG_SWI_LANE_STATUS))
        if st["fcsm"] == FCSM_LINK_IDLE and st["cal_done"]:
            break
        time.sleep(0.02)
    ok = st["fcsm"] == FCSM_LINK_IDLE and st["cal_done"]
    print_status(bd, "   ")
    if ok:
        print("RESULT: LINK UP — %s reached FCSM=4 (LINK_IDLE), cal_done=1." % role)
        print("        (M1 done once BOTH dies report this.)")
        return 0
    print("RESULT: NOT converged — fcsm=%d (want %d), cal_done=%d. See status above."
          % (st["fcsm"], FCSM_LINK_IDLE, st["cal_done"]))
    return 3


def main():
    ap = argparse.ArgumentParser(
        description="PS-side TideLink bring-up/status for the KR260 eth-chiplet "
                    "(via the eth_ss_0 backdoor). Default action is read-only "
                    "status.")
    ap.add_argument("--bringup", action="store_true",
                    help="perform the link bring-up write sequence (default is "
                         "read-only --status)")
    ap.add_argument("--status", action="store_true",
                    help="read-only status dump (effective role + calibration/"
                         "FCSM); this is the default action.")
    ap.add_argument("--role", choices=("die_a", "die_b"),
                    help="die_a=master/grandmaster, die_b=slave. Required with "
                         "--bringup.")
    ap.add_argument("--window-base", default=hex(WINDOW_BASE),
                    help="eth_ss_0 PS window base (default 0x400000000; the "
                         "HPM0_FPD high aperture per tidelink.hwh).")
    ap.add_argument("--cal-timeout", type=float, default=20.0,
                    help="seconds to wait for calibration_done (default 20).")
    ap.add_argument("--converge-timeout", type=float, default=10.0,
                    help="seconds to wait for FCSM=4 after LL enable (default 10).")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: needs root for /dev/mem (run under sudo).", file=sys.stderr)
        return 4
    try:
        wb = int(args.window_base, 0)
    except ValueError:
        print("ERROR: --window-base %r not an integer." % args.window_base,
              file=sys.stderr)
        return 4

    bd = Backdoor(wb)
    try:
        if not args.bringup:
            print("=== eth-chiplet TideLink status (read-only) @ window 0x%X ===" % wb)
            print("(This is the SAFE aliveness check: reads only RO APB registers.)")
            print_status(bd, "   ")
            print("Run with --bringup --role die_a|die_b to bring the link up.")
            return 0
        if not args.role:
            print("ERROR: --bringup requires --role die_a|die_b.", file=sys.stderr)
            return 4
        return bringup(bd, args.role, args.cal_timeout, args.converge_timeout)
    finally:
        bd.close()


if __name__ == "__main__":
    sys.exit(main())
