#!/usr/bin/env python3
# =============================================================================
# cov_obs_health_gate.py — OBS-into-gating health test (promotes the RO snapshot
#                          scripts into a single ASSERTING CI gate).
#
# Closes the observability gap: health_snapshot.py / winscan_read.py /
# eth_tlapb_poke.py anchorobs are one-shot DUMPS a human reads. This gate reads
# the whole eth-chiplet observability plane over the eth_ss_0 backdoor and
# ASSERTS health bits, returning rc 0/1 for CI:
#
#   * OBS_AXI_NODES 0x21E0  : marker 0xAD present, data_healthy=1, wedge-sticky
#                             (tgt+ini)=0, resp-err (tgt+ini)=0.
#   * AUTO_ANCHOR_OBS 0x21F4: if AUTO_ANCHOR_EN=1, reanchored=1 (epoch latched).
#   * WINSCAN_STAT 0x21E4   : marker 0xC5 present AND a window locked
#                             (cal_done[4] OR eye_done[11]); WINSCAN_EYE 0x21E8
#                             marker 0x25 present.
#   * per-node FC CRC (node+0x20, AXI nodes AW/W/B/AR/R): CRC DELTA == 0 across
#     two RO samples (a rising CRC == a live bit-error on the data plane).
#   * SWI_LANE 0x2108 fcsm=4 & cal & fe_rx_full=0; STATUS 0x2010 sticky[3:1]=0.
#   * OBS_FC_CREDIT 0x219C reported (sideband FCSM_6 credit — informational).
#
# This is the counterpart to kr260_eth_xfer.py --mode fc_health, but as a
# STANDALONE gate with no data-plane traffic: PURE RO over combinational obs/
# config addresses -> CANNOT WEDGE. Because it cannot wedge it does not REFUSE
# on a down link; instead a down link / missing obs plane FAILS the gate (that
# is the health signal). Runs by default on die_a and die_b and passes only if
# BOTH are healthy. A timeout on any ssh (should never happen for RO reads) is
# still treated as a wedge by cov_common.
#
# Self-shipping single file (see cov_perf_thresholds.py for the pattern):
#   export KR260_PASSWORD=...
#   python3 cov_obs_health_gate.py                 # gate both dies
#   python3 cov_obs_health_gate.py --die a         # one die
#   python3 cov_obs_health_gate.py --settle 0.20   # CRC re-sample gap
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import base64
import os
import sys

WINDOW = 0x400000000
TLAPB = 0x2E030000

REG_SWI_LANE = 0x2108
REG_STATUS = 0x2010
REG_OBS_FC_CREDIT = 0x219C
REG_OBS_AXI_NODES = 0x21E0
REG_WINSCAN_STAT = 0x21E4
REG_WINSCAN_EYE = 0x21E8
REG_AUTO_ANCHOR = 0x21F4
STICKY_MASK = 0xE

# per-node Wlink FC (offsets from TLAPB); CRC-error count is RO at node+0x20.
FC_NODES = (("AW", 0x1000), ("W", 0x1100), ("B", 0x1200), ("AR", 0x1300),
            ("R", 0x1400), ("GenBus", 0x1600), ("TideLink", 0x1700))
FC_AXI_NODES = ("AW", "W", "B", "AR", "R")
FC_CRC = 0x20


# ============================================================================
# ON-BOARD AGENT (RO, STDLIB ONLY). Prints the obs plane + two CRC samples.
# ============================================================================
def _onboard(args):
    import mmap
    import struct
    import time
    try:
        f = open("/dev/mem", "r+b", buffering=0)
        m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED, mmap.PROT_READ,
                      offset=WINDOW + TLAPB)
    except (OSError, PermissionError) as e:
        print("ONBOARD_ERR mmap /dev/mem failed: %s" % e)
        return 3

    def rd(o):
        return struct.unpack("<I", m[o:o + 4])[0]

    for name, off in (("SWI_LANE", REG_SWI_LANE), ("STATUS", REG_STATUS),
                      ("OBS_FC_CREDIT", REG_OBS_FC_CREDIT),
                      ("OBS_AXI_NODES", REG_OBS_AXI_NODES),
                      ("WINSCAN_STAT", REG_WINSCAN_STAT),
                      ("WINSCAN_EYE", REG_WINSCAN_EYE),
                      ("AUTO_ANCHOR", REG_AUTO_ANCHOR)):
        print("OBS %s 0x%08X" % (name, rd(off)))
    for name, base in FC_NODES:
        print("CRC1 %s 0x%08X" % (name, rd(base + FC_CRC) & 0xFFFF))
    time.sleep(args.settle)
    for name, base in FC_NODES:
        print("CRC2 %s 0x%08X" % (name, rd(base + FC_CRC) & 0xFFFF))
    m.close()
    f.close()
    return 0


# ============================================================================
# DEV-HOST ORCHESTRATOR
# ============================================================================
def _ship_run(cc, ip, onboard_args, timeout, stage):
    b64 = base64.b64encode(open(os.path.abspath(__file__), "rb").read()).decode()
    fn = "/tmp/%s" % os.path.basename(__file__)
    remote = "echo %s | base64 -d > %s && python3 %s %s" % (b64, fn, fn, onboard_args)
    return cc.ssh_board(ip, remote, timeout, stage)


def _parse(out):
    obs, crc1, crc2 = {}, {}, {}
    for ln in out.splitlines():
        t = ln.split()
        if len(t) != 3:
            continue
        try:
            v = int(t[2], 16)
        except ValueError:
            continue
        {"OBS": obs, "CRC1": crc1, "CRC2": crc2}.get(t[0], {})[t[1]] = v
    return obs, crc1, crc2


def _gate_one(cc, ip, label, args):
    print("-- %s (%s) --" % (label, ip))
    try:
        rc, out = _ship_run(cc, ip, "--on-board --settle %s" % args.settle,
                            cc.T_HEALTH, "obs_read")
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: obs read timed out (stage=%s) — even RO backdoor hung." % e.stage)
        cc.por_stage(ip, "obs read wedge")
        return False
    if rc != 0 or "ONBOARD_ERR" in out or "OBS SWI_LANE" not in out:
        print(out.rstrip())
        print("  RESULT(%s): FAIL — obs agent error / plane unreadable." % label)
        return False

    obs, crc1, crc2 = _parse(out)
    fails = []

    # --- SWI_LANE / STATUS ---------------------------------------------------
    swi = obs["SWI_LANE"]
    fcsm, cal, fe_full = (swi >> 17) & 7, (swi >> 16) & 1, (swi >> 31) & 1
    link_up = fcsm == 4 and cal == 1
    st = obs["STATUS"]
    sticky = st & STICKY_MASK
    print("  SWI_LANE=0x%08X fcsm=%d cal=%d fe_rx_full=%d -> %s   STATUS=0x%08X sticky[3:1]=0x%X"
          % (swi, fcsm, cal, fe_full, "UP" if link_up else "DOWN", st, sticky))
    if not link_up:
        fails.append("link not FCSM=4 (fcsm=%d cal=%d)" % (fcsm, cal))
    if fe_full:
        fails.append("SWI_LANE[31] fe_rx_is_full latched (CLASSIC ring-full wedge)")
    if sticky:
        fails.append("STATUS sticky[3:1]=0x%X (master-err/under/overrun)" % sticky)

    # --- OBS_AXI_NODES (reuse cov_common.decode_regf) ------------------------
    rf = cc.decode_regf(obs["OBS_AXI_NODES"])
    print("  %s" % rf["text"])
    print("  OBS_FC_CREDIT=0x%08X (sideband FCSM_6 credit — informational)"
          % obs["OBS_FC_CREDIT"])
    if not rf["present"]:
        fails.append("OBS_AXI_NODES marker!=0xAD (AXI-node obs plane NOT in bitstream)")
    else:
        if rf["data_healthy"] != 1:
            fails.append("data_healthy=0")
        if rf["tgt_wsticky"] or rf["ini_wsticky"]:
            fails.append("AXI-node wedge-sticky latched (tgt=0x%02X ini=0x%02X)"
                         % (rf["tgt_wsticky"], rf["ini_wsticky"]))
        if rf["tgt_resperr"] or rf["ini_resperr"]:
            fails.append("AXI-node resp-err latched (tgt=%d ini=%d)"
                         % (rf["tgt_resperr"], rf["ini_resperr"]))

    # --- AUTO_ANCHOR_OBS ------------------------------------------------------
    a = obs["AUTO_ANCHOR"]
    aen, dwell, pulsed = (a >> 23) & 1, a & 0xFFFF, (a >> 16) & 1
    reanch, training = (a >> 21) & 1, (a >> 22) & 1
    print("  AUTO_ANCHOR_OBS=0x%08X AUTO_ANCHOR_EN=%d dwell_max=%d pulsed_ever=%d "
          "reanchored=%d training=%d" % (a, aen, dwell, pulsed, reanch, training))
    if aen:
        if reanch != 1:
            fails.append("AUTO_ANCHOR_EN=1 but reanchored=0 (epoch never re-latched)")
    else:
        print("  note: AUTO_ANCHOR_EN=0 -> auto-anchor not in this build; reanchored not asserted")

    # --- WINSCAN --------------------------------------------------------------
    ws = obs["WINSCAN_STAT"]
    we = obs["WINSCAN_EYE"]
    ws_mk, ws_cald, ws_eyed = (ws >> 24) & 0xFF, (ws >> 4) & 1, (ws >> 11) & 1
    we_mk = (we >> 26) & 0x3F
    locked = ws_cald or ws_eyed
    print("  WINSCAN_STAT=0x%08X marker=0x%02X cal_done=%d eye_done=%d   "
          "WINSCAN_EYE=0x%08X marker=0x%02X" % (ws, ws_mk, ws_cald, ws_eyed, we, we_mk))
    if ws_mk != 0xC5:
        fails.append("WINSCAN_STAT marker 0x%02X != 0xC5 (winscan obs not live)" % ws_mk)
    elif not locked:
        fails.append("WINSCAN never locked a window (cal_done=0 eye_done=0 — capture-phase risk)")
    if we_mk != 0x25:
        fails.append("WINSCAN_EYE marker 0x%02X != 0x25" % we_mk)

    # --- per-node FC CRC deltas ----------------------------------------------
    print("  node      CRC(s1->s2)")
    crc_rose = []
    for name, _ in FC_NODES:
        s1, s2 = crc1.get(name, 0), crc2.get(name, 0)
        rose = name in FC_AXI_NODES and s2 > s1
        if rose:
            crc_rose.append(name)
        print("    %-8s %5d->%-5d%s" % (name, s1, s2, "  <== RISING" if rose else ""))
    if crc_rose:
        fails.append("rising CRC on AXI node(s) %s (live bit-error/drift)"
                     % ",".join(crc_rose))

    ok = not fails
    for fl in fails:
        print("  FAIL: %s" % fl)
    print("  RESULT(%s): %s" % (label, "HEALTHY" if ok else "FAULT"))
    return ok


def _devhost(args):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cov_common as cc

    cc.banner("OBS HEALTH GATE (RO, wedge-proof) — die %s" % args.die)
    dies = []
    if args.die in ("a", "both"):
        dies.append((cc.DIE_A_IP, "die_a"))
    if args.die in ("b", "both"):
        dies.append((cc.DIE_B_IP, "die_b"))
    allok = True
    for ip, lbl in dies:
        allok &= _gate_one(cc, ip, lbl, args)
    print("RESULT: %s" % ("HEALTHY — obs plane clean on all sampled dies" if allok
                          else "FAULT — see per-die detail"))
    return 0 if allok else 1


def main():
    ap = argparse.ArgumentParser(description="OBS-plane health gate (eth-chiplet).")
    ap.add_argument("--on-board", action="store_true", help="internal: RO board agent.")
    ap.add_argument("--die", choices=("a", "b", "both"), default="both")
    ap.add_argument("--settle", type=float, default=0.10, help="CRC re-sample gap (s).")
    args = ap.parse_args()
    if args.on_board:
        return _onboard(args)
    return _devhost(args)


if __name__ == "__main__":
    sys.exit(main())
