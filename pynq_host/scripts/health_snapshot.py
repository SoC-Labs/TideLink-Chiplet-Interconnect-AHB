#!/usr/bin/env python3
# health_snapshot.py — RO one-shot cross-die link health dump (wedge-safe).
# Maps ONLY the TideLink APB span inside the eth_ss_0 window and reads: SWI_LANE
# (cal/fcsm/cr), STATUS+sticky, CREDIT_COUNT, OBS_FC_CREDIT, and Region F (the
# AXI-node obs plane: data_healthy + wedge/live-stall bits). No writes, no peer
# access -> cannot wedge.
#
# EXIT CODES (CI-usable):
#   0  HEALTHY
#   1  FAULT               a fault bit is set
#   2  COULD-NOT-EVALUATE  an obs plane the verdict depends on is not present in
#                          this bitstream (Region F marker != 0xAD, or the 0x21F8
#                          witness marker != 0xB5), so that half of the verdict
#                          could not be read at all
#
# 2026-09-11: the 0x21F8 WITNESS word is now read and graded here. It carries the
# TL-042 / TL-044 containment plane that rev2/integration added
# (src/rtl/tidelink_top.sv:2178 xhb_sub_obs_word):
#     [12] sub_wr_hol_stuck_sticky  TL-042 head-of-line WRITE-age watchdog EXPIRED
#     [13] xhb_dead_r               TL-044 XHB500 declared DEAD; the port is in
#                                   bounded-error containment (live, not sticky)
#     [14] xhb_dead_perm_r          TL-044 containment latched PERMANENTLY after
#                                   XHB_DEAD_RELAPSE_MAX clear/re-arm cycles
# plus the bits that were already in the word ([8] synth-B backstop, [9] 2-cycle
# ERROR backstop, [10] bridge-stall/hazard-list witness, [11] TL-021 ext-stall).
# NOTHING in pynq_host decoded any of the three new bits before this change, so a
# die running under TL-044 containment -- every subsequent transfer retired with a
# bounded AHB ERROR, by design -- read HEALTHY here. Region F cannot see it: the
# FC nodes are fine, the XHB500 is parked, and that asymmetry is TL-044's whole
# premise.
#
# The witness plane is treated EXACTLY like Region F, for the same C3 reason: an
# ABSENT 0xB5 marker is "I could not evaluate the containment plane", which is
# COULD-NOT-EVALUATE, not HEALTHY. --allow-missing-witness is the explicit opt-out
# for a pre-rev2 bitstream, the mirror of --allow-missing-regionf.
#
# FALSE-GREEN C3, fixed 2026-08-26. The verdict used to read
#
#     ok = (... and (not present or (healthy_bit and tgt_ws == 0 and ini_ws == 0)))
#
# so `not present` — the marker being ABSENT, i.e. "I could not evaluate the
# AXI-node plane" — made the whole Region-F term TRUE and the script exited 0
# announcing HEALTHY. The header claimed "Exit 0 if healthy, 1 if a fault bit
# is set (CI-usable)", and every consumer of that exit code inherited the
# fail-open. The fail-CLOSED form was already in a sibling in this same
# directory: kr260_recover_gate.py:110-111,
#     if not d.get("present"):
#         return False, "%s Region-F marker absent (CC-3: not healthy)" % tag
#
# --allow-missing-regionf restores the old tolerance EXPLICITLY, for a
# deliberately older bitstream. It is off by default and says so in the output.
#
# Controls: scripts/ci/tests/test_health_snapshot.py (the C3 verdict)
#           scripts/ci/tests/test_obs_witness_decode.py (the 0x21F8 decode)
import argparse
import mmap
import struct
import sys

WINDOW = 0x400000000
TLAPB = 0x2E030000

EXIT_HEALTHY = 0
EXIT_FAULT = 1
EXIT_COULD_NOT_EVALUATE = 2

REGF_MARKER_EXPECTED = 0xAD
WITNESS_MARKER_EXPECTED = 0xB5


def decode(swi, st, credits, ofc, rf, wt):
    """Pure: raw register words -> the decoded fields the verdict uses.

    `wt` is the 0x21F8 witness word. It is a REQUIRED argument on purpose: a
    default would let a caller that never read the register produce a decode in
    which the containment plane is silently "not present", i.e. exactly the
    fail-open this file was fixed for once already (C3)."""
    witness_present = ((wt >> 24) & 0xFF) == WITNESS_MARKER_EXPECTED
    return {
        "swi": swi, "st": st, "credits": credits, "ofc": ofc, "rf": rf, "wt": wt,
        "fcsm": (swi >> 17) & 7,
        "cal": (swi >> 16) & 1,
        "cr": (swi >> 23) & 1,
        "crack": (swi >> 24) & 1,
        "fe_full": (swi >> 31) & 1,
        "sticky": st & 0xE,
        "marker": (rf >> 24) & 0xFF,
        "healthy_bit": (rf >> 23) & 1,
        "present": ((rf >> 24) & 0xFF) == REGF_MARKER_EXPECTED,
        "tgt_ws": (rf >> 10) & 0x1F,
        "ini_ws": (rf >> 15) & 0x1F,
        "tgt_resp_err": (rf >> 20) & 1,
        "ini_resp_err": (rf >> 21) & 1,
        # --- 0x21F8 witness word, gated on its own 0xB5 presence marker -------
        "wt_marker": (wt >> 24) & 0xFF,
        "wt_present": witness_present,
        "hreadyout":     wt & 1                if witness_present else None,
        "wr_os":         (wt >> 1) & 7         if witness_present else None,
        "wr_hwm":        (wt >> 5) & 7         if witness_present else None,
        "synth_b":       (wt >> 8) & 1         if witness_present else None,
        "wr_err":        (wt >> 9) & 1         if witness_present else None,
        "stall_stuck":   (wt >> 10) & 1        if witness_present else None,
        "ext_stall_err": (wt >> 11) & 1        if witness_present else None,
        "wr_hol_stuck":  (wt >> 12) & 1        if witness_present else None,
        "xhb_dead":      (wt >> 13) & 1        if witness_present else None,
        "xhb_dead_perm": (wt >> 14) & 1        if witness_present else None,
    }


# The 0x21F8 bits that are FAULTS, and what each one means in words. Keep the
# text: a bare "bit 13 set" in a CI log is not diagnosable six months later.
WITNESS_FAULTS = (
    ("xhb_dead_perm", "TL-044 containment latched PERMANENTLY (0x21F8[14]) — the "
                      "XHB500 port relapsed XHB_DEAD_RELAPSE_MAX times and will "
                      "never re-arm; every transfer to it now takes a bounded ERROR"),
    ("xhb_dead",      "TL-044 XHB500 declared DEAD (0x21F8[13]) — the port is in "
                      "bounded-error containment, NOT carrying traffic"),
    ("wr_hol_stuck",  "TL-042 head-of-line write-age watchdog EXPIRED (0x21F8[12]) "
                      "— a write sat at the head of the queue past its age limit "
                      "and was drained by the backstop"),
    ("stall_stuck",   "XHB500 bridge hreadyout stuck low >= 2^12 hclk (0x21F8[10]) "
                      "— hazard-list-full / deadlock witness"),
    ("wr_err",        "2-cycle ERROR read backstop fired (0x21F8[9])"),
    ("synth_b",       "synth-B write backstop fired (0x21F8[8])"),
    ("ext_stall_err", "TL-021 bounded-ext-stall sticky (0x21F8[11])"),
)


def evaluate(d, allow_missing_regionf=False, allow_missing_witness=False):
    """Pure: decoded fields -> (exit_code, label, [reasons]).

    Three verdicts. `not present` is COULD-NOT-EVALUATE, never HEALTHY -- for the
    Region-F plane AND for the 0x21F8 witness plane."""
    faults = []
    if d["fcsm"] != 4:
        faults.append("fcsm=%d (want 4 LINK_IDLE)" % d["fcsm"])
    if not d["cal"]:
        faults.append("cal_done=0")
    if d["sticky"]:
        faults.append("STATUS sticky[3:1]=0x%X (MASTER_ERR/UNDER/OVER)" % d["sticky"])
    if d["fe_full"]:
        faults.append("fe_rx_full=1")

    # --- 0x21F8 witness plane. A set containment bit is a FAULT even when Region
    #     F is spotless: TL-044's premise is a parked XHB500 behind healthy FC
    #     nodes, which Region F cannot see.
    unknown_wt = None
    if d["wt_present"]:
        for key, text in WITNESS_FAULTS:
            if d.get(key):
                faults.append(text)
    else:
        unknown_wt = ("0x21F8 witness marker=0x%02X (expect 0x%02X) — the "
                      "TL-042/TL-044 containment plane is not present in this "
                      "bitstream, so xhb_dead / xhb_dead_perm / wr_hol_stuck "
                      "could not be read"
                      % (d["wt_marker"], WITNESS_MARKER_EXPECTED))

    if d["present"]:
        if not d["healthy_bit"]:
            faults.append("Region-F data_healthy=0")
        if d["tgt_ws"]:
            faults.append("Region-F tgt wedge-sticky=0x%02X" % d["tgt_ws"])
        if d["ini_ws"]:
            faults.append("Region-F ini wedge-sticky=0x%02X" % d["ini_ws"])
        if faults:
            return EXIT_FAULT, "FAULT", faults
        if unknown_wt and not allow_missing_witness:
            return EXIT_COULD_NOT_EVALUATE, "COULD-NOT-EVALUATE", [unknown_wt]
        if unknown_wt:
            return EXIT_HEALTHY, "OK-WITNESS-UNCHECKED", [
                unknown_wt + " — tolerated by --allow-missing-witness"]
        return EXIT_HEALTHY, "HEALTHY", []

    # Region-F absent: the AXI-node half of the verdict is UNREADABLE.
    unknown = ("Region-F marker=0x%02X (expect 0x%02X) — the AXI-node obs "
               "plane is not present in this bitstream, so data_healthy and "
               "the wedge-sticky bits could not be read"
               % (d["marker"], REGF_MARKER_EXPECTED))
    if faults:
        # A fault elsewhere is decisive regardless of Region-F.
        return EXIT_FAULT, "FAULT", faults + [unknown] + \
            ([unknown_wt] if unknown_wt else [])
    if unknown_wt and not allow_missing_witness:
        # Both planes unreadable: still exactly one verdict, and it is not green.
        return EXIT_COULD_NOT_EVALUATE, "COULD-NOT-EVALUATE", [unknown, unknown_wt]
    if allow_missing_regionf:
        # Deliberately NOT the string "HEALTHY": consumers match on
        # `"RESULT: HEALTHY" in out` (kr260_eth_regress.py:406,
        # campaign_iter.py:331), and a run whose Region-F half was never read
        # must not satisfy that substring.
        return EXIT_HEALTHY, "OK-REGIONF-UNCHECKED", [
            unknown + " — tolerated by --allow-missing-regionf"] + \
            ([unknown_wt + " — tolerated by --allow-missing-witness"]
             if unknown_wt else [])
    return EXIT_COULD_NOT_EVALUATE, "COULD-NOT-EVALUATE", [unknown]


def render(d, out=print):
    out("=== eth-chiplet health snapshot (RO, wedge-safe) @ 0x4_2E03_xxxx ===")
    out("  SWI_LANE   0x2108 = 0x%08X  cal=%d fcsm=%d cr=%d crack=%d "
        "fe_rx_full=%d -> %s"
        % (d["swi"], d["cal"], d["fcsm"], d["cr"], d["crack"], d["fe_full"],
           "UP" if (d["fcsm"] == 4 and d["cal"]) else "DOWN"))
    out("  STATUS     0x2010 = 0x%08X  sticky[3:1]=0x%X (MASTER_ERR/UNDER/OVER)"
        % (d["st"], d["sticky"]))
    out("  CREDIT_CNT 0x200C = %d" % d["credits"])
    out("  OBS_FC_CR  0x219C = 0x%08X  (sideband FCSM_6 only — NOT the AXI nodes)"
        % d["ofc"])
    if d["present"]:
        out("  RegionF    0x21E0 = 0x%08X  marker=0x%02X data_healthy=%d  "
            "wedge-sticky tgt=0x%02X ini=0x%02X  resp-err tgt=%d ini=%d"
            % (d["rf"], d["marker"], d["healthy_bit"], d["tgt_ws"], d["ini_ws"],
               d["tgt_resp_err"], d["ini_resp_err"]))
    else:
        out("  RegionF    0x21E0 = 0x%08X  marker=0x%02X (expect 0x%02X) -> "
            "AXI-node obs plane NOT present in this bitstream"
            % (d["rf"], d["marker"], REGF_MARKER_EXPECTED))
    if d["wt_present"]:
        out("  Witness    0x21F8 = 0x%08X  marker=0x%02X hreadyout=%d wr_os=%d "
            "hwm=%d"
            % (d["wt"], d["wt_marker"], d["hreadyout"], d["wr_os"], d["wr_hwm"]))
        out("                              backstops synth_b=%d wr_err=%d "
            "stall_stuck=%d ext_stall=%d"
            % (d["synth_b"], d["wr_err"], d["stall_stuck"], d["ext_stall_err"]))
        out("                              containment wr_hol_stuck=%d "
            "xhb_dead=%d xhb_dead_perm=%d   (TL-042 / TL-044)"
            % (d["wr_hol_stuck"], d["xhb_dead"], d["xhb_dead_perm"]))
    else:
        out("  Witness    0x21F8 = 0x%08X  marker=0x%02X (expect 0x%02X) -> "
            "TL-042/TL-044 containment plane NOT present in this bitstream"
            % (d["wt"], d["wt_marker"], WITNESS_MARKER_EXPECTED))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--allow-missing-regionf", action="store_true",
                    help="treat an absent Region-F obs plane as tolerable "
                         "(old bitstream). OFF by default: an unreadable half "
                         "of the verdict is COULD-NOT-EVALUATE (exit 2), not "
                         "HEALTHY.")
    ap.add_argument("--allow-missing-witness", action="store_true",
                    help="treat an absent 0x21F8 witness plane as tolerable "
                         "(pre-rev2 bitstream without TL-042/TL-044). OFF by "
                         "default, for the same reason as the Region-F flag.")
    args = ap.parse_args(argv)

    f = open("/dev/mem", "r+b", buffering=0)
    m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED, mmap.PROT_READ,
                  offset=WINDOW + TLAPB)

    def rd(o):
        return struct.unpack("<I", m[o:o + 4])[0]

    d = decode(rd(0x2108), rd(0x2010), rd(0x200C) & 0x1FFF, rd(0x219C),
               rd(0x21E0), rd(0x21F8))
    m.close()
    f.close()

    render(d)
    rc, label, reasons = evaluate(d,
                                  allow_missing_regionf=args.allow_missing_regionf,
                                  allow_missing_witness=args.allow_missing_witness)
    for r in reasons:
        print("  - %s" % r)
    print("RESULT: %s (exit %d)" % (label, rc))
    return rc


if __name__ == "__main__":
    sys.exit(main())
