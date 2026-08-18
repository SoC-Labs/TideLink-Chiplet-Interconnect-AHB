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
REG_EPOCH_STATUS         = _TIDELINK_BANK  + 0x0140   # 0x2E032140 (RO reanchor bit0)
REG_WINSCAN_STAT         = _TIDELINK_BANK  + 0x01E4   # 0x2E0321E4 (RO winscan; [6]=in_hold/S_HOLD)

# ROLE_CFG (0x2080): bit[0]=role (0 master, 1 slave), bit[1]=role_lock.
ROLE_CFG_MASTER_LOCK = 0x02        # role_lock=1, role=0 -> master / grandmaster (die_a)
ROLE_CFG_SLAVE_LOCK  = 0x03        # role_lock=1, role=1 -> slave              (die_b)

# 3-write LL bootstrap into WL_LINK_ENABLE_RESET; order matters (swreset first
# clears CR/CRACK sticky), exactly as test_g2_soc_pair.py.
LL_SWRESET_ON  = 0x00027F08
LL_SWRESET_OFF = 0x00027F00
LL_ENABLE      = 0x00027F07

FCSM_LINK_IDLE = 4                 # link-up criterion (bilateral)

# --- TL-018: link-CRC checking on the five AXI data-plane FC nodes ------------
# Each Wlink FC node has SM Control at base+0x14 with bit[16] = `disable_crc`,
# and a 16-bit RO CRC-error counter at base+0x20 (docs/REGISTER_MAP.md §2.3).
# Bases are in the Wlink bank, so they are reachable through this same backdoor
# (the map span covers the whole 0x0000-0x7FFF bridge aperture).
#
# WHY THIS IS HERE. The five AXI nodes ship with checking DISABLED — the FPGA
# flist pulls src/rtl/local_overrides/WlinkGenericFCSM{,_1..4}.v, whose reset
# value is `out_prepend_swi_disable_crc <= 1'h1` (:747 / :725). With that bit
# set, `crc_corrupt` is forced 0, so a bit-flip anywhere in a packet's app
# payload — peer WRITE DATA, read data, address, BID/BRESP — is accepted
# silently: no counter moves, no NACK is sent, nothing is replayed, and the AHB
# master is told the access SUCCEEDED. Sim-proven both ways, 2026-08-14:
#   test_crc_off_silently_corrupts_write_data -> wrong word in peer memory
#   test_crc_on_detects_write_data_corruption -> detected, NACK'd, byte-exact
# (cocotb/tidelink_axi_datanode_recovery, `make gaps_crc`).
#
# The `report` default below only READS. It is deliberately not `on`: enabling
# checking arms the NACK/replay path, and the ONE time an enabled CRC has run on
# a live link (2026-06-14, Z2 pair) it saturated crc_errors and parked the FCSM
# in SEND_NACK — which the 2026-07-21 root-cause concluded was the CRC correctly
# catching REAL corruption on a marginal eye, not a false fire. On a bad eye,
# `on` converts silent corruption into a visible stall, which is the right trade
# for a research chip but is NOT free. Ratify it with a soak before defaulting.
FC_AXI_NODES = (("AW", 0x1000), ("W", 0x1100), ("B", 0x1200),
                ("AR", 0x1300), ("R", 0x1400))
FC_SM_CONTROL   = 0x14             # [16] disable_crc (RW)
FC_CRC_ERRORS   = 0x20             # [15:0] CRC errors seen (RO)
FC_DISABLE_CRC_BIT = 16

# Map span from TLAPB_SOC_BASE. The real aperture is 32 KB, not the 16 KB this
# used to map, and the old value could not reach the upper half of the bridge.
#
# EVIDENCE (RTL, not inference):
#   1. The AHB->APB bridge is 15-bit:
#        nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv:682
#          cmsdk_ahb_to_apb #(.ADDRWIDTH(15)) u_tlapb_bridge (...)
#      and its PADDR net is `wire [14:0] tlapb_paddr;` (:368), so the bridge
#      decodes paddr[14:0] => 2**15 = 0x8000 bytes.
#   2. tidelink_top.sv:845-854 splits that 15-bit window into FOUR 8 KB
#      quadrants on paddr[14:13]:
#        00 = Wlink chiplet controller   0x0000-0x1FFF
#        01 = TideLink config/status     0x2000-0x3FFF
#        10 = address translator (CAM)   0x4000-0x5FFF
#        11 = reserved, UNDECODED        0x6000-0x7FFF
#      A 0x4000 span stops exactly at the top of quadrant 01, so quadrants 10
#      and 11 were unreachable from this tool. kr260_eth_xfer.py:46 already
#      addresses the CAM at `_TLAPB + 0x4000`, i.e. above the old span.
#
# WIDENING IS SAFE, and does not weaken the containment argument above. The
# chiplet decode gives the whole of SoC 0x2E03_0000-0x2E03_FFFF (64 KB) to the
# tlapb bridge (chiplet_d2d_decode.sv:136, `blk == 4'h3` on haddr[19:16]), so
# 0x8000 stays wholly inside the decoded tlapb block: it cannot reach the
# wedge-prone peer aperture at 0x2F.. (a_peer is haddr[24]) and cannot leave
# the eth_ss_0 window. Quadrant 11 is undecoded in tidelink_top, and the
# response mux (:872-880) falls through to pready=1/pslverr=0 for it, so a
# stray access there terminates rather than hanging.
_MAP_SPAN = 0x8000
_ROLE_NAMES = {"die_a": (ROLE_CFG_MASTER_LOCK, 0, "master/grandmaster"),
               "die_b": (ROLE_CFG_SLAVE_LOCK,  1, "slave")}


class Backdoor:
    """mmap of the TideLink APB, reached through the eth_ss_0 PS backdoor.

    Only the 32 KB TideLink-APB span is mapped (the full ADDRWIDTH(15) bridge
    aperture; see _MAP_SPAN), so no accessor in this class can reach the
    wedge-prone peer aperture or any out-of-window PL address.
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


def crc_state(bd):
    """Read SM Control[16] + the CRC-error counter for the five AXI data nodes.

    Pure reads of the Wlink bank; no side effects. Returns a list of
    (name, base, sm_control, checking_enabled, crc_errors)."""
    out = []
    for name, base in FC_AXI_NODES:
        sm = bd.rd(_WLINK_BANK + base + FC_SM_CONTROL)
        ce = bd.rd(_WLINK_BANK + base + FC_CRC_ERRORS) & 0xFFFF
        out.append((name, base, sm, not (sm >> FC_DISABLE_CRC_BIT) & 1, ce))
    return out


def print_crc_state(bd, prefix=""):
    """Report the AXI data plane's link-CRC state. TL-018: this is invisible on
    every existing bring-up path — the user-guide's 'CRC clean' check reads only
    the TideLink node (0x1720 = FCSM_6), which is the ONE node that already
    resets with checking on, so it says nothing about the AXI data path.

    INSTRUMENT CAVEAT (verify the instrument before the DUT): `crc_errors` is
    force-zeroed on every io_rx_clk edge where the demetted app enable is low
    (WlinkGenericFCSM.v:761-763), so `crc_errors == 0` does NOT prove no error
    ever fired. Read `checking` first: while checking=off the counter is pinned
    at 0 BY CONSTRUCTION and carries no information at all."""
    st = crc_state(bd)
    n_on = sum(1 for _, _, _, en, _ in st)
    print("%sAXI data-plane link CRC (TL-018):" % prefix)
    for name, base, sm, en, ce in st:
        print("%s   %-2s @0x%04X  SM_CONTROL=0x%08X  checking=%-3s  crc_errors=%d%s"
              % (prefix, name, base, sm, "ON" if en else "OFF", ce,
                 "  (pinned 0: checking off)" if not en else ""))
    if n_on == 0:
        print("%s   => ALL FIVE AXI NODES HAVE CRC CHECKING OFF. A corrupted "
              "payload byte is accepted SILENTLY: no counter, no NACK, no "
              "replay, and the master is told the access succeeded." % prefix)
    elif n_on < len(st):
        print("%s   => MIXED (%d/%d on). The link is only as trustworthy as its "
              "weakest node." % (prefix, n_on, len(st)))
    return st


def set_crc_check(bd, on):
    """Clear (on=True) or set (on=False) `disable_crc` on the five AXI FC nodes,
    with a read-back verify per node. Returns True if every node took the write.

    Read-modify-write: SM Control also holds link_en_wait[7:0] and
    ack_dly_count[15:8], and `ack_dly_count=4` is HW-validated — a blind write
    would silently re-time the link."""
    ok = True
    for name, base, sm, en, _ in crc_state(bd):
        want = (sm & ~(1 << FC_DISABLE_CRC_BIT)) if on else (sm | (1 << FC_DISABLE_CRC_BIT))
        if want != sm:
            bd.wr(_WLINK_BANK + base + FC_SM_CONTROL, want)
        got = bd.rd(_WLINK_BANK + base + FC_SM_CONTROL)
        good = ((got >> FC_DISABLE_CRC_BIT) & 1) == (0 if on else 1)
        print("   %-2s @0x%04X  0x%08X -> 0x%08X (readback 0x%08X) %s"
              % (name, base, sm, want, got, "OK" if good else "*** WRITE DID NOT TAKE ***"))
        ok = ok and good
    return ok


def bringup(bd, role, cal_timeout, converge_timeout, crc_check="report"):
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

    # 1b. hold training HIGH while RX aligns (I1 self-arm fix,
    #     docs/I1_SELFARM_FIX.md). With SELF_ARM_TRAIN_EN=1 the ROLE_CFG write
    #     above self-latches role_lock; the calibrator then needs
    #     SWI_TRAINING_MODE=1 to decode the peer's training pattern. On this
    #     chiplet nego_en=0 (NEGO_CFG_RESET=7'h00), so the autoneg never raises
    #     training — the PS must. Step 3 drops it to 0 (the falling edge to data).
    print("--- 1b. SWI_TRAINING_MODE <- 1 (hold training for RX alignment) ---")
    bd.wr(REG_SWI_TRAINING_MODE, 1)
    time.sleep(0.005)

    # 2. wait until the calibrator reaches S_HOLD (WINSCAN_STAT[6]=in_hold).
    #    CRITICAL (I1 FIX-E): do NOT poll cal_done here. S_HOLD->S_VALIDATE is
    #    gated on (hold_ctr>=HOLD_MAX && !swi_training_mode_r)
    #    (tidelink_phy_align_calibrator_v2.sv:1499) — cal_done can NEVER assert
    #    while training is held. Polling cal_done before releasing training is a
    #    self-deadlock (the original I1 bring-up bug: the die parks in S_HOLD).
    #    So wait for S_HOLD instead, then release training (step 3) to advance.
    print("--- 2. poll winscan in_hold (S_HOLD reached; needs peer die + ribbon) ---")
    deadline = time.time() + cal_timeout
    inhold = 0
    while time.time() < deadline:
        inhold = (bd.rd(REG_WINSCAN_STAT) >> 6) & 1
        if inhold:
            break
        time.sleep(0.02)
    if not inhold:
        print("   S_HOLD (in_hold) not reached in %.1fs." % cal_timeout)
        print("   Check: peer board running this too? ribbon seated? die_a<->die_b "
              "images not swapped?")
        print_status(bd, "   ")
        return 2
    print("   in_hold=1 (calibrator parked in S_HOLD, training still held)")

    # 2b. bilateral-coordination settle: both dies must be in S_HOLD *before*
    #     either drops training — the first to release stops sending the training
    #     pattern the peer still needs to lock. When both dies run this recipe in
    #     parallel (POR'd together) they reach S_HOLD within ms; a short settle
    #     lets the peer arrive. For a strict barrier use bringup_pair_release.sh.
    time.sleep(1.0)

    # 3. FIX-E release: drop training -> S_HOLD->S_VALIDATE (hold_ctr expired) ->
    #    VAL_TIMEOUT_TO_DONE -> S_DONE -> cal_done. Then the 3-write LL bootstrap.
    print("--- 3. to-data-mode: SWI_TRAINING_MODE<-0 (FIX-E release), then LL enable ---")
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

        # 4b. TL-018 — AXI data-plane link-CRC checking. Sequenced HERE, after
        #     FCSM=4 and before any data traffic: CR/CRACK are short packets and
        #     carry no CRC at all, so nothing before this point is affected, and
        #     the first DATA packet is the first one that can be checked.
        #     `report` (the default) only reads.
        print("--- 4b. AXI data-plane link CRC (TL-018), mode=%s ---" % crc_check)
        if crc_check in ("on", "off"):
            want_on = crc_check == "on"
            if not set_crc_check(bd, want_on):
                print("WARNING: CRC-check write did not take on every AXI node. "
                      "The data plane is in a MIXED state — see the report below.")
        print_crc_state(bd, "   ")
        if crc_check == "on":
            print("   NOTE: checking is now ARMED. A real corruption will now NACK "
                  "and replay instead of committing silently. On a marginal eye "
                  "that can present as a stalled link (2026-06-14 Z2: crc_errors "
                  "saturated, FCSM parked in SEND_NACK) — that is the CRC doing "
                  "its job, not a new defect. Watch crc_errors AND fcsm together.")

        # 5. poll the AUTONOMOUS re-anchor (EPOCH_STATUS 0x2140 bit0). The
        #    controller AUTO_ANCHOR beacon latches the deskew re-anchor within
        #    ~8s of link-up with NO manual pulse. It is a marginal-eye lottery
        #    per bring-up (like FCSM=4 itself); if it does not latch, the caller
        #    should RETRY the bring-up (each retry re-runs winscan = a fresh eye).
        print("--- 5. poll AUTONOMOUS re-anchor (EPOCH_STATUS bit0, up to 12s) ---")
        rdl = time.time() + 12.0
        # Keep the FULL word, not just bit0. Bits [6:1] are sr_span_meas — the
        # measured skew span — and masking them off with `& 1` threw away the
        # only quantitative bring-up-quality number the design exposes. The n=20
        # campaign (2026-08-13) found delivery fails in EXACTLY the runs where
        # die_a re-anchored and die_b did NOT, so the anchor bit is the
        # stratifier; the span is what could turn that binary signal into one
        # that explains itself. Cheap to log, impossible to recover afterwards.
        epoch_raw = bd.rd(REG_EPOCH_STATUS)
        rea = epoch_raw & 1
        while time.time() < rdl and not rea:
            time.sleep(0.1)
            epoch_raw = bd.rd(REG_EPOCH_STATUS)
            rea = epoch_raw & 1
        print("    EPOCH_STATUS = 0x%08x (reanchored=%d sr_span_meas=%d)"
              % (epoch_raw, rea, (epoch_raw >> 1) & 0x3F))
        if rea:
            print("RESULT: RE-ANCHORED — %s EPOCH_STATUS bit0=1 (deskew locked, no "
                  "manual pulse). M1 done once BOTH dies report this." % role)
            return 0
        print("RESULT: LINK UP but NOT RE-ANCHORED — %s EPOCH_STATUS bit0=0 after "
              "12s. Marginal-eye lottery; RETRY the bring-up (both dies)." % role)
        return 4
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
    ap.add_argument("--crc-check", choices=("report", "on", "off"), default="report",
                    help="TL-018: link-CRC checking on the five AXI data-plane FC "
                         "nodes. 'report' (default) only READS SM_CONTROL[16] and "
                         "the CRC counters — the AXI nodes ship with checking OFF, "
                         "which makes a corrupted payload byte a SILENT wrong "
                         "value in peer memory. 'on' clears disable_crc on all "
                         "five (detect + NACK + replay; sim-proven byte-exact, "
                         "NOT yet ratified on hardware). 'off' restores the "
                         "shipping default.")
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
            print_crc_state(bd, "   ")
            print("Run with --bringup --role die_a|die_b to bring the link up.")
            return 0
        if not args.role:
            print("ERROR: --bringup requires --role die_a|die_b.", file=sys.stderr)
            return 4
        return bringup(bd, args.role, args.cal_timeout, args.converge_timeout,
                       args.crc_check)
    finally:
        bd.close()


if __name__ == "__main__":
    sys.exit(main())
