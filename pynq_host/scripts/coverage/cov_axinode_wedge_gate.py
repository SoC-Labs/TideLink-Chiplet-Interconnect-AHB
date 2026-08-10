#!/usr/bin/env python3
# =============================================================================
# cov_axinode_wedge_gate.py — P0 BLOCKER GATE.
#
# Closes the V-plan gap: "AXI data nodes sustained + REVERSE direction wedge
# gate". Drives a BOUNDED write stream in BOTH directions — A->B (proven) and
# B->A (the UNTESTED reverse) — and gates on the Region F AXI-node obs plane
# (OBS_AXI_NODES 0x21E0) being sampled PER BEAT: data_nodes_healthy must stay 1
# and NO wedge-sticky may latch over N beats. A timeout on any board access is a
# PS-bus WEDGE and fails the gate.
#
# HOW (wedge-safe, non-duplicative — reuses the proven on-board modes):
#   * Per direction, sender_ip runs `kr260_eth_xfer.py --mode soak --adversarial
#     --health-every 1` : an ON-BOARD write loop that samples snap_health()
#     (Region F data_healthy + wedge-sticky) EVERY beat and FAILS FAST (rc 1)
#     the instant a wedge-sticky latches — BEFORE the PS AXI bus saturates. rc 0
#     == data_nodes_healthy held 1 and no wedge-sticky over all N beats.
#   * The DATA-PLANE verdict is a die_b (receiver) LOCAL read: `--mode soak_recv`
#     reconstructs the same seed stream and checks last-writer-wins in local SRAM.
#     A local read never traverses the link -> the verifier itself cannot wedge.
#   * The whole sender run is subprocess-timeout-wrapped: a timeout == WEDGE.
#
# REVERSE (B->A) is symmetric at the address level (each die's 0x2F aperture,
# CAM 0x2F->0x2D, lands in the PEER's 0x2D shared_sram_0) but has NEVER run on
# silicon -> it is ATTENDED / wedge-prone and stages JTAG-POR on a wedge.
#
# WEDGE-RISK: MEDIUM fwd / HIGH rev (sustained peer writes cross the AXI data
#   nodes; the reverse path is unproven). Attended. JTAG-POR staged.
# PASS  : both requested directions -> sender rc 0 (healthy every beat) AND
#         receiver byte-exact AND no timeout.
# FAIL  : any wedge-sticky / data_healthy=0 / mismatch / timeout(=WEDGE).
#
# Run ON mapstone-dev (owns both boards). Do NOT run on the eth-chiplet blind —
# confirm fcsm=4 (the gate does this) and stage POR.
#
#   export KR260_PASSWORD=...
#   python3 cov_axinode_wedge_gate.py --iters 500 --seed 0xC0FFEE
#   python3 cov_axinode_wedge_gate.py --direction fwd            # forward only
#   python3 cov_axinode_wedge_gate.py --direction rev            # untested reverse
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import cov_common as cc


def run_direction(direction, iters, seed, win):
    """Drive + gate ONE direction. Returns a result dict."""
    sender_ip, recv_ip, s_lbl, r_lbl = cc.role_ips(direction)
    attended = direction == "rev"
    tag = "%s->%s (%s)" % (s_lbl, r_lbl, "UNTESTED reverse — ATTENDED"
                           if attended else "proven forward")
    cc.banner("DIRECTION %s : %d-beat sustained AXI-node wedge gate" % (tag, iters))

    res = {"direction": direction, "sender": sender_ip, "recv": recv_ip,
           "iters": iters, "seed": seed, "wedge": False, "healthy": False,
           "data_exact": False, "verdict": "FAIL"}

    # 0. both dies must be FCSM=4 (RO gate; a WedgeTimeout here == pre-wedged bus).
    cc.require_pair_fcsm4(sender_ip, recv_ip)

    # 1. pre-snapshot Region F on both dies (RO, wedge-safe) for the report.
    print("-- pre-run Region F snapshot --")
    cc.regf_snapshot(sender_ip, "sender ")
    cc.regf_snapshot(recv_ip, "recv   ")

    # 2. SENDER: on-board per-beat sampled adversarial soak (fail-fast on wedge).
    #    --health-every 1 -> OBS_AXI_NODES sampled every beat; rc 1 == a beat
    #    latched a wedge-sticky / dropped data_healthy; a timeout == WEDGE.
    print("-- streaming %d beats on %s (per-beat OBS_AXI_NODES sampling) --" % (iters, s_lbl))
    args = ("%s --mode soak --adversarial --iters %d --seed 0x%X --win %d "
            "--health-every 1" % (cc.XFER, iters, seed, win))
    try:
        rc, out = cc.board_python(sender_ip, args, cc.T_STREAM, "soak")
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: sender stream timed out (stage=%s) -> PS bus hung." % e.stage)
        res["wedge"] = True
        # snapshot the RECEIVER (only did nothing yet / RO) — it is the survivor.
        cc.regf_snapshot(recv_ip, "survivor(recv) ")
        cc.por_stage(sender_ip, "sender stream wedge")
        return res
    print(out.rstrip())
    res["healthy"] = rc == 0

    # 3. RECEIVER: LOCAL-read data-plane verify (cannot wedge).
    print("-- receiver LOCAL verify on %s (no link traversal) --" % r_lbl)
    try:
        rvc, rout = cc.board_python(
            recv_ip, "%s --mode soak_recv --iters %d --seed 0x%X --win %d"
            % (cc.XFER, iters, seed, win), cc.T_VERIFY, "soak_recv")
    except cc.WedgeTimeout as e:
        # a LOCAL read that hangs means even this die's backdoor is saturated.
        print("  !! WEDGE: receiver local verify timed out (stage=%s)." % e.stage)
        res["wedge"] = True
        cc.por_stage(recv_ip, "receiver verify wedge")
        return res
    print(rout.rstrip())
    res["data_exact"] = rvc == 0

    # 4. post-snapshot for the record.
    print("-- post-run Region F snapshot --")
    cc.regf_snapshot(sender_ip, "sender ")
    cc.regf_snapshot(recv_ip, "recv   ")

    ok = res["healthy"] and res["data_exact"] and not res["wedge"]
    res["verdict"] = "PASS" if ok else "FAIL"
    print("-- direction %s verdict: %s (healthy=%s data_exact=%s wedge=%s) --"
          % (direction, res["verdict"], res["healthy"], res["data_exact"], res["wedge"]))
    if not ok and not res["wedge"]:
        # a rc-1 without a timeout means the on-board fail-fast caught a latched
        # wedge-sticky (it already printed the ladder); stage POR anyway.
        cc.por_stage(sender_ip, "on-board wedge-sticky (fail-fast)")
    return res


def main():
    ap = argparse.ArgumentParser(
        description="P0 AXI-node sustained + REVERSE wedge gate (dev-host, "
                    "wedge-safe, both directions).")
    ap.add_argument("--direction", choices=("fwd", "rev", "both"), default="both",
                    help="fwd=A->B (proven), rev=B->A (UNTESTED, attended), both.")
    ap.add_argument("--iters", type=int, default=500, help="beats per direction.")
    ap.add_argument("--seed", default="0xC0FFEE", help="deterministic stream seed.")
    ap.add_argument("--win", type=int, default=16, help="cycling window in words.")
    args = ap.parse_args()

    seed = int(args.seed, 0) & 0xFFFFFFFF
    dirs = ["fwd", "rev"] if args.direction == "both" else [args.direction]

    results = []
    for d in dirs:
        try:
            results.append(run_direction(d, args.iters, seed, args.win))
        except SystemExit as e:                 # fcsm gate abort -> stop the gate
            print("GATE ABORTED: %s" % e)
            return 2

    cc.banner("AXI-NODE WEDGE GATE SUMMARY")
    allok = True
    for r in results:
        allok &= r["verdict"] == "PASS"
        print("  %-3s %s->%s : %s%s" % (
            r["direction"], cc.IP_TO_TARGET.get(r["sender"], r["sender"]),
            cc.IP_TO_TARGET.get(r["recv"], r["recv"]), r["verdict"],
            "  (WEDGE)" if r["wedge"] else ""))
    print("RESULT: %s" % ("PASS — data plane held healthy both directions"
                          if allok else "FAIL — see per-direction detail above"))
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
