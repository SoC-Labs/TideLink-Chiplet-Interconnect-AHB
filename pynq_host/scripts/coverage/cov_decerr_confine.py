#!/usr/bin/env python3
# =============================================================================
# cov_decerr_confine.py — INBOUND-CONFINEMENT DECERR GATE.
#
# Closes the V-plan gap: "a peer write CAM-retargeted to an EXCLUDED byte (not
# the two legal inbound targets 0x2D sram / 0x23 mailbox) must DECERR cleanly on
# die_b, land NOWHERE, and NOT wedge either die." Inbound is confined to 0x2D +
# 0x23; a CAM replace to any other byte must hit die_b's default slave and take
# a 2-cycle AHB error, not corrupt SRAM and not stall an AXI node.
#
# HOW (wedge-safe, non-duplicative — reuses proven on-board corner modes):
#   die_a  `kr260_eth_xfer.py --mode decerr --excl 0x2C` :
#            (1) seeds a SENTINEL into die_b 0x2D via the PROVEN 0x2F->0x2D path,
#            (2) reprograms the CAM replace-byte to an EXCLUDED byte and fires a
#                POISON peer write, asserting PS-side that the access RETURNS (no
#                bus hang) and the link stays HEALTHY (the errored access wedged
#                no node). rc 0 == survived + healthy.
#   die_b  `kr260_eth_xfer.py --mode decerr_verify` :
#            a LOCAL read of 0x2D — must still be the SENTINEL, NEVER the poison.
#            rc 0 == confinement held (nothing leaked). LOCAL read -> can't wedge.
#
# This gate ties the two halves into ONE orchestrated pass/fail, and can SWEEP
# all three excluded bytes {0x2A, 0x2C, 0x2E}. Every access is timeout-wrapped
# (timeout == WEDGE); a wedge stages JTAG-POR.
#
# WEDGE-RISK: MEDIUM. The poison peer write SHOULD DECERR cleanly, but it is a
#   peer access that crosses the link -> attended, JTAG-POR staged. Injecting a
#   malformed-target write is exactly the kind of access that could expose a
#   node-recovery gap.
# PASS  : for every swept excluded byte -> die_a survived + link healthy AND
#         die_b still reads the sentinel (poison landed nowhere).
# FAIL  : die_a wedged, OR link unhealthy after the poison, OR poison leaked into
#         0x2D on die_b, OR any timeout (=WEDGE).
#
# Run ON mapstone-dev:
#   export KR260_PASSWORD=...
#   python3 cov_decerr_confine.py                     # sweep 0x2A,0x2C,0x2E
#   python3 cov_decerr_confine.py --excl 0x2C         # single byte
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import cov_common as cc

EXCLUDED_BYTES = (0x2A, 0x2C, 0x2E)   # replace-bytes that are NOT inbound targets
LEGAL_TARGETS = (0x2D, 0x23)          # sram, mailbox — the ONLY confined inbound


def run_one(excl, seed):
    """One excluded-byte confinement corner. Returns a result dict."""
    a_ip, b_ip = cc.DIE_A_IP, cc.DIE_B_IP
    cc.banner("DECERR CONFINE : CAM replace -> 0x%02X (excluded)  seed=0x%X" % (excl, seed))
    res = {"excl": excl, "seed": seed, "survived": False, "confined": False,
           "wedge": False, "verdict": "FAIL"}

    if excl in LEGAL_TARGETS:
        print("  ERROR: 0x%02X is a LEGAL inbound target, not an excluded byte — "
              "this gate needs an EXCLUDED byte (%s)."
              % (excl, ",".join("0x%02X" % b for b in EXCLUDED_BYTES)))
        return res

    # 0. both dies FCSM=4.
    cc.require_pair_fcsm4(a_ip, b_ip)

    # 1. die_a: seed sentinel (proven path) + poison the excluded byte.
    print("-- die_a: seed sentinel via 0x2F->0x2D, then POISON excluded 0x%02X --" % excl)
    try:
        rc, out = cc.board_python(
            a_ip, "%s --mode decerr --seed 0x%X --excl 0x%02X" % (cc.XFER, seed, excl),
            cc.T_STREAM, "decerr")
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: die_a decerr access timed out (stage=%s)." % e.stage)
        res["wedge"] = True
        cc.regf_snapshot(b_ip, "survivor(die_b) ")   # die_b only did local work
        cc.por_stage(a_ip, "decerr poison wedge")
        return res
    print(out.rstrip())
    res["survived"] = rc == 0        # rc 0 == survived + link healthy after poison

    # 2. die_b: LOCAL-read confinement verify (must still be the sentinel).
    print("-- die_b: LOCAL verify 0x2D holds the sentinel, not the poison --")
    try:
        rvc, rout = cc.board_python(
            b_ip, "%s --mode decerr_verify --seed 0x%X" % (cc.XFER, seed),
            cc.T_VERIFY, "decerr_verify")
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: die_b local verify timed out (stage=%s)." % e.stage)
        res["wedge"] = True
        cc.por_stage(b_ip, "decerr_verify wedge")
        return res
    print(rout.rstrip())
    res["confined"] = rvc == 0

    ok = res["survived"] and res["confined"] and not res["wedge"]
    res["verdict"] = "PASS" if ok else "FAIL"
    print("-- excl 0x%02X verdict: %s (survived=%s confined=%s wedge=%s) --"
          % (excl, res["verdict"], res["survived"], res["confined"], res["wedge"]))
    if not ok and not res["wedge"]:
        cc.por_stage(a_ip, "confinement fault (no timeout)")
    return res


def main():
    ap = argparse.ArgumentParser(
        description="Inbound-confinement DECERR gate (excluded-byte peer write "
                    "must DECERR on die_b without wedging).")
    ap.add_argument("--excl", default=None,
                    help="single excluded replace-byte (0x2A/0x2C/0x2E). Omit to "
                         "sweep all three.")
    ap.add_argument("--seed", default="0xD00D", help="deterministic sentinel seed.")
    args = ap.parse_args()

    seed = int(args.seed, 0) & 0xFFFFFFFF
    bytes_to_test = ([int(args.excl, 0) & 0xFF] if args.excl
                     else list(EXCLUDED_BYTES))

    results = []
    for b in bytes_to_test:
        try:
            results.append(run_one(b, seed))
        except SystemExit as e:
            print("GATE ABORTED: %s" % e)
            return 2
        if results[-1]["wedge"]:
            print("STOP: wedge encountered — not continuing the sweep until "
                  "recovery + re-bring-up.")
            break

    cc.banner("DECERR CONFINEMENT GATE SUMMARY")
    allok = bool(results) and all(r["verdict"] == "PASS" for r in results)
    for r in results:
        print("  excl 0x%02X : %s%s" % (r["excl"], r["verdict"],
                                        "  (WEDGE)" if r["wedge"] else ""))
    print("RESULT: %s" % ("PASS — excluded inbound writes DECERR cleanly, confined"
                          if allok else "FAIL — see detail above"))
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
