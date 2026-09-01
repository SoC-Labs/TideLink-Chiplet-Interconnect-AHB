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
#   2  COULD-NOT-EVALUATE  the Region-F obs plane is not present in this
#                          bitstream (marker != 0xAD), so the AXI-node half of
#                          the verdict could not be read at all
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
# Control: scripts/ci/tests/test_health_snapshot.py
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


def decode(swi, st, credits, ofc, rf):
    """Pure: raw register words -> the decoded fields the verdict uses."""
    return {
        "swi": swi, "st": st, "credits": credits, "ofc": ofc, "rf": rf,
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
    }


def evaluate(d, allow_missing_regionf=False):
    """Pure: decoded fields -> (exit_code, label, [reasons]).

    Three verdicts. `not present` is COULD-NOT-EVALUATE, never HEALTHY."""
    faults = []
    if d["fcsm"] != 4:
        faults.append("fcsm=%d (want 4 LINK_IDLE)" % d["fcsm"])
    if not d["cal"]:
        faults.append("cal_done=0")
    if d["sticky"]:
        faults.append("STATUS sticky[3:1]=0x%X (MASTER_ERR/UNDER/OVER)" % d["sticky"])
    if d["fe_full"]:
        faults.append("fe_rx_full=1")

    if d["present"]:
        if not d["healthy_bit"]:
            faults.append("Region-F data_healthy=0")
        if d["tgt_ws"]:
            faults.append("Region-F tgt wedge-sticky=0x%02X" % d["tgt_ws"])
        if d["ini_ws"]:
            faults.append("Region-F ini wedge-sticky=0x%02X" % d["ini_ws"])
        if faults:
            return EXIT_FAULT, "FAULT", faults
        return EXIT_HEALTHY, "HEALTHY", []

    # Region-F absent: the AXI-node half of the verdict is UNREADABLE.
    unknown = ("Region-F marker=0x%02X (expect 0x%02X) — the AXI-node obs "
               "plane is not present in this bitstream, so data_healthy and "
               "the wedge-sticky bits could not be read"
               % (d["marker"], REGF_MARKER_EXPECTED))
    if faults:
        # A fault elsewhere is decisive regardless of Region-F.
        return EXIT_FAULT, "FAULT", faults + [unknown]
    if allow_missing_regionf:
        # Deliberately NOT the string "HEALTHY": consumers match on
        # `"RESULT: HEALTHY" in out` (kr260_eth_regress.py:406,
        # campaign_iter.py:331), and a run whose Region-F half was never read
        # must not satisfy that substring.
        return EXIT_HEALTHY, "OK-REGIONF-UNCHECKED", [
            unknown + " — tolerated by --allow-missing-regionf"]
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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--allow-missing-regionf", action="store_true",
                    help="treat an absent Region-F obs plane as tolerable "
                         "(old bitstream). OFF by default: an unreadable half "
                         "of the verdict is COULD-NOT-EVALUATE (exit 2), not "
                         "HEALTHY.")
    args = ap.parse_args(argv)

    f = open("/dev/mem", "r+b", buffering=0)
    m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED, mmap.PROT_READ,
                  offset=WINDOW + TLAPB)

    def rd(o):
        return struct.unpack("<I", m[o:o + 4])[0]

    d = decode(rd(0x2108), rd(0x2010), rd(0x200C) & 0x1FFF, rd(0x219C), rd(0x21E0))
    m.close()
    f.close()

    render(d)
    rc, label, reasons = evaluate(d, allow_missing_regionf=args.allow_missing_regionf)
    for r in reasons:
        print("  - %s" % r)
    print("RESULT: %s (exit %d)" % (label, rc))
    return rc


if __name__ == "__main__":
    sys.exit(main())
