#!/usr/bin/env python3
# =============================================================================
# cov_auto_anchor_verify.py — AUTO_ANCHOR FIRE ASSERTION (RO, wedge-safe).
#
# Closes the V-plan gap: "after bring-up, assert the AUTO_ANCHOR FSM actually
# FIRED the SYNC beacon and the deskew corrector RE-ANCHORED, on BOTH dies."
# This is the on-HW verdict the AUTO_ANCHOR_HW_DIAGNOSTIC doc calls the next
# conclusive one-APB-read cycle (rebuild from 200bce5, AUTO_ANCHOR_EN=1).
#
# HOW (RO / config-plane only -> CANNOT wedge; still timeout-wrapped):
#   Reads AUTO_ANCHOR_OBS 0x21F4 and EPOCH_STATUS 0x2140 on each die via
#   eth_tlapb_poke.py, decodes the full obs word, and applies the doc's verdict
#   table. No peer access, no writes.
#
#   AUTO_ANCHOR_OBS 0x21F4 : [15:0]dwell_max [16]pulsed_ever [17]done [18]pulse
#     [19]link_up [20]tx_idle [21]reanchored [22]training [23]AUTO_ANCHOR_EN
#   EPOCH_STATUS   0x2140  : [0]=reanchored(sticky) [6:1]=epoch_span
#
# VERDICT TABLE (docs/AUTO_ANCHOR_HW_DIAGNOSTIC_2026_08_04.md):
#   EN=0                                  -> build lacks auto-anchor (not a FAIL of
#                                            the FSM — a BITSTREAM gap; rebuild).
#   dwell_max<256 & pulsed_ever=0         -> GATE-TOO-STRICT (keepalive resets the
#                                            dwell; the pause-accumulate fix targets
#                                            this).
#   dwell_max>=256 & pulsed_ever=0        -> EMIT-BLOCKED between dwell and burst.
#   pulsed_ever=1 & reanchored=0          -> PEER-DIDN'T-LATCH (needs a contiguous
#                                            SYNC run -> quiesce-and-burst).
#   pulsed_ever=1 & reanchored=1          -> WORKED.
#
# WEDGE-RISK: NONE (RO obs/config plane only). Unattended-safe.
# PASS  : pulsed_ever=1 AND reanchored=1 on BOTH dies.
# FAIL  : any die not (pulsed_ever & reanchored); each failure is CLASSIFIED so
#         the next action (rebuild / pause-accumulate / quiesce-and-burst) is
#         named, not guessed.
#
# Run ON mapstone-dev (link should already be UP on both dies):
#   export KR260_PASSWORD=...
#   python3 cov_auto_anchor_verify.py
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import cov_common as cc

ANCHOR_DWELL = 256   # the FSM's consecutive-tx-idle dwell target


def decode_anchor(obs, epoch):
    """Pure decode of AUTO_ANCHOR_OBS(0x21F4) + EPOCH_STATUS(0x2140)."""
    d = {
        "raw": obs,
        "dwell_max": obs & 0xFFFF,
        "pulsed_ever": (obs >> 16) & 1,
        "done": (obs >> 17) & 1,
        "pulse": (obs >> 18) & 1,
        "link_up": (obs >> 19) & 1,
        "tx_idle": (obs >> 20) & 1,
        "reanchored": (obs >> 21) & 1,     # CDC'd deskew latch (live obs copy)
        "training": (obs >> 22) & 1,
        "en": (obs >> 23) & 1,
        "epoch_raw": epoch,
        "epoch_anchored": epoch & 1,       # EPOCH_STATUS sticky reanchor latch
        "epoch_span": (epoch >> 1) & 0x3F,
    }
    return d


def classify(d):
    """(verdict, classification, action) per the diagnostic doc's table."""
    if not d["en"]:
        return ("FAIL", "EN=0 (build lacks auto-anchor / param off)",
                "rebuild both dies from 200bce5 with AUTO_ANCHOR_EN=1")
    if d["pulsed_ever"] and d["reanchored"]:
        return ("PASS", "pulsed_ever=1 & reanchored=1 — auto-anchor WORKED", "none")
    if not d["pulsed_ever"] and d["dwell_max"] < ANCHOR_DWELL:
        return ("FAIL", "gate-too-strict (dwell_max=%d<256, pulsed_ever=0): "
                "keepalive keeps resetting the tx-idle dwell" % d["dwell_max"],
                "apply/confirm the pause-accumulate fix (200bce5) that HOLDS dwell "
                "across idle windows")
    if not d["pulsed_ever"] and d["dwell_max"] >= ANCHOR_DWELL:
        return ("FAIL", "emit-blocked (dwell_max=%d>=256 but pulsed_ever=0): "
                "stuck between dwell-complete and the beacon burst" % d["dwell_max"],
                "trace the dwell->burst handoff; obs live bits training=%d tx_idle=%d "
                "link_up=%d localise it" % (d["training"], d["tx_idle"], d["link_up"]))
    if d["pulsed_ever"] and not d["reanchored"]:
        return ("FAIL", "peer-didn't-latch (pulsed_ever=1 but reanchored=0): "
                "beacon emitted, PHY/peer did not latch the re-anchor",
                "switch to quiesce-and-burst (hold off app traffic for the "
                "4096-cycle contiguous SYNC run)")
    return ("FAIL", "unclassified (raw=0x%08X)" % d["raw"],
            "inspect obs live bits manually")


def read_die(ip, label):
    """RO read + decode + classify one die. Returns (result_dict or None)."""
    print("-- %s (%s) --" % (label, ip))
    try:
        obs, obs_raw = cc.read_reg(ip, cc.REG_AUTO_ANCHOR_OBS)
        epoch, ep_raw = cc.read_reg(ip, cc.REG_EPOCH_STATUS)
    except cc.WedgeTimeout as e:
        # even an RO poke timing out means this die's PS bus is saturated.
        print("  !! WEDGE: RO read timed out (stage=%s) — PS bus hung." % e.stage)
        return None
    if obs is None or epoch is None:
        print("  read failed: obs=%s epoch=%s" % (obs_raw, ep_raw))
        return None
    d = decode_anchor(obs, epoch)
    print("  AUTO_ANCHOR_OBS=0x%08X  EN=%d dwell_max=%d pulsed_ever=%d done=%d "
          "pulse=%d link_up=%d tx_idle=%d reanchored=%d training=%d"
          % (d["raw"], d["en"], d["dwell_max"], d["pulsed_ever"], d["done"],
             d["pulse"], d["link_up"], d["tx_idle"], d["reanchored"], d["training"]))
    print("  EPOCH_STATUS=0x%08X  anchored(sticky)=%d span=%d"
          % (d["epoch_raw"], d["epoch_anchored"], d["epoch_span"]))
    verdict, cls, action = classify(d)
    print("  -> %s : %s" % (verdict, cls))
    if verdict != "PASS":
        print("     ACTION: %s" % action)
    d.update({"ip": ip, "label": label, "verdict": verdict,
              "classification": cls, "action": action})
    return d


def main():
    ap = argparse.ArgumentParser(
        description="AUTO_ANCHOR fire assertion (RO): pulsed_ever=1 & "
                    "reanchored=1 on both dies.")
    ap.add_argument("--die", choices=("a", "b", "both"), default="both")
    args = ap.parse_args()

    targets = []
    if args.die in ("a", "both"):
        targets.append((cc.DIE_A_IP, "die_a"))
    if args.die in ("b", "both"):
        targets.append((cc.DIE_B_IP, "die_b"))

    cc.banner("AUTO_ANCHOR FIRE ASSERTION (RO, wedge-safe)")
    results = [read_die(ip, lbl) for ip, lbl in targets]

    cc.banner("AUTO_ANCHOR SUMMARY")
    allok = True
    for (ip, lbl), r in zip(targets, results):
        if r is None:
            allok = False
            print("  %-6s : NO-READ (wedge/parse) — cannot assert" % lbl)
            continue
        allok &= r["verdict"] == "PASS"
        print("  %-6s : %s  (%s)" % (lbl, r["verdict"], r["classification"]))
    print("RESULT: %s" % ("PASS — auto-anchor fired + re-anchored on all dies"
                          if allok else "FAIL — see per-die classification/action"))
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
