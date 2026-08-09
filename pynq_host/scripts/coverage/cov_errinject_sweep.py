#!/usr/bin/env python3
# =============================================================================
# cov_errinject_sweep.py — DIRECTIONAL ERR-INJECT SWEEP as a REPEATABLE GATE.
#
# Closes the V-plan gap: "one-shot single-bit inject on EACH AXI data node, on
# the CORRECT (transmitting) die, then resume a short stream — assert die_a stays
# alive AND the stream lands byte-exact (die_b LOCAL verify) — and MEASURE the
# W-byte-0 residual wedge RATE over K trials with JTAG-POR-staged recovery."
#
# DIRECTIONAL INJECTION RULE (verified on silicon — the trap this gate avoids):
#   the Wlink injector corrupts a die's OUTGOING packets on a data_id, so inject
#   on the TRANSMITTING die:
#     AW 0x80  initiator TX -> inject die_a, provoke with a WRITE
#     W  0x81  initiator TX -> inject die_a, provoke with a WRITE
#     AR 0x83  initiator TX -> inject die_a, provoke with a READ
#     B  0x82  target    TX -> inject die_b, provoke with a WRITE (die_b's resp)
#     R  0x84  target    TX -> inject die_b, provoke with a READ  (die_b's data)
#   Injecting B/R on die_a is a NO-OP (die_a never sends them) — the vacuous
#   "survive" this gate is built to reject.
#
# The injector is one-shot / self-clears, so exactly ONE outgoing packet (the
# first after arming) is corrupted; the resumed stream then tests RECOVERY. With
# the header-ECC restore a single byte-0 (data_id/word_count) flip is CORRECTED
# at RX, so each node's byte-0 injection should leave die_a ALIVE and the data
# byte-exact. Bytes/bits are swept (default {byte0/bit0, byte1/bit0}).
#
# VERDICT (per node x byte/bit):
#   PASS = die_a stays ALIVE (link readable) AND, for a WRITE node, the resumed
#          stream is byte-exact in die_b LOCAL SRAM; for a READ node, the peer
#          readback returns the expected word (die_a-side — wedge-prone).
#   FAIL = die_a wedged (link read times out == WEDGE) or residual corruption.
#
# W-BYTE-0 RESIDUAL RATE (the open marginal item): K trials of inject-W-byte0 +
#   short write stream; report ALIVE/WEDGED and the wedge RATE. A wedge stages
#   JTAG-POR; with COV_AUTO_POR=1 it POR-recovers + re-brings-up and CONTINUES,
#   otherwise it STOPS at the first wedge (attended).
#
# WEDGE-RISK: HIGH — this test DELIBERATELY provokes the recovery gap. ATTENDED,
#   JTAG-POR staged. NEVER run unattended on a contended board.
#
# Run ON mapstone-dev:
#   export KR260_PASSWORD=...
#   python3 cov_errinject_sweep.py                       # full matrix + W soak
#   python3 cov_errinject_sweep.py --nodes W,B --wsoak 0 # matrix subset, no soak
#   COV_AUTO_POR=1 python3 cov_errinject_sweep.py --wsoak 20
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import cov_common as cc

KNOWN = 0xC0FFEE01          # arming/readback sentinel written to 0x2F001000
STREAM_N = 32               # resume-stream length after the corrupted beat

# node -> (data_id, inject_die_ip, op)   op: 'w'=provoke with write, 'r'=with read
NODES = {
    "AW": (0x80, cc.DIE_A_IP, "w"),
    "W":  (0x81, cc.DIE_A_IP, "w"),
    "AR": (0x83, cc.DIE_A_IP, "r"),
    "B":  (0x82, cc.DIE_B_IP, "w"),
    "R":  (0x84, cc.DIE_B_IP, "r"),
}


def _arm_cam_a():
    """One arming access on die_a: programs CAM 0x2F->0x2D and writes KNOWN to
    0x2F001000 (so a subsequent readback has a known target). Returns rc/out."""
    return cc.board_python(cc.DIE_A_IP, "%s --mode sender --payload 0x%08X"
                           % (cc.XFER, KNOWN), cc.T_ARM, "arm")


def _die_a_alive():
    """die_a liveness via an RO link read. A WedgeTimeout == WEDGE (bus hung)."""
    up, txt = cc.fcsm4(cc.DIE_A_IP)
    return up, txt


def _bringup_pair():
    """Re-bring-up both dies after a POR (COV_AUTO_POR path). Returns True on UP."""
    sh = os.path.join(cc.SCRIPTS_DIR, "bringup_pair_release.sh")
    if not os.path.exists(sh):
        print("     (bringup_pair_release.sh not found — cannot auto re-bring-up.)")
        return False
    try:
        p = subprocess.run(["bash", sh], timeout=240, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True,
                           env=dict(os.environ))
        print(p.stdout.rstrip())
        return "LINK UP" in p.stdout
    except Exception as e:
        print("     bringup_pair_release.sh failed: %s" % e)
        return False


def run_node(node, byte, bit, base):
    """One (node, byte, bit) inject+resume corner. Returns a result dict.
    result['wedge'] True => the link is DOWN; the caller must stop/recover."""
    data_id, inj_ip, op = NODES[node]
    inj_lbl = cc.IP_TO_TARGET.get(inj_ip.split("@")[-1], inj_ip)
    print("-- node %s (id=0x%02X) inject@%s op=%s byte=%d bit=%d --"
          % (node, data_id, inj_lbl, op, byte, bit))
    res = {"node": node, "byte": byte, "bit": bit, "op": op,
           "inject_die": inj_lbl, "alive": False, "byte_exact": False,
           "wedge": False, "verdict": "FAIL"}
    try:
        # 1. arm CAM + sentinel on die_a.
        _arm_cam_a()
        # 2. arm the one-shot injector on the TRANSMITTING die.
        cc.inject(inj_ip, data_id, byte, bit)
        # 3. provoke: the first outgoing packet is the corrupted one.
        if op == "w":
            cc.board_python(cc.DIE_A_IP, "%s write %d 0x%08X" % (cc.SOAK_FWD, STREAM_N, base),
                            cc.T_STREAM, "stream_w")
        else:  # read node — peer readback (WEDGE-PRONE, die_a-side)
            cc.board_python(cc.DIE_A_IP, "%s --mode readback --payload 0x%08X"
                            % (cc.XFER, KNOWN), cc.T_STREAM, "readback")
        # 4. disarm the injector (self-clears, but be explicit).
        cc.inject_off(inj_ip)
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: access timed out (host=%s stage=%s)." % (e.host, e.stage))
        res["wedge"] = True
        cc.regf_snapshot(cc.DIE_B_IP, "survivor(die_b) ")
        cc.por_stage(e.host, "errinject %s wedge" % node)
        return res

    # 5. die_a liveness (RO link read; timeout == WEDGE).
    try:
        alive, txt = _die_a_alive()
    except cc.WedgeTimeout:
        alive, txt = False, "WEDGE (link read timed out)"
    res["alive"] = alive
    print("  die_a: %s" % txt)
    if not alive:
        res["wedge"] = True
        cc.por_stage(cc.DIE_A_IP, "errinject %s post-inject wedge" % node)
        return res

    # 6. byte-exactness.
    if op == "w":
        try:
            rvc, rout = cc.board_python(cc.DIE_B_IP, "%s verify %d 0x%08X"
                                        % (cc.SOAK_FWD, STREAM_N, base),
                                        cc.T_VERIFY, "verify")
            print("  die_b LOCAL verify: %s" % rout.strip().splitlines()[-1])
            res["byte_exact"] = rvc == 0
        except cc.WedgeTimeout:
            print("  !! WEDGE: die_b local verify timed out.")
            res["wedge"] = True
            cc.por_stage(cc.DIE_B_IP, "errinject %s verify wedge" % node)
            return res
    else:
        # read node: the readback mode already printed PASS/FAIL; re-run one clean
        # readback (injector off now) to confirm the returned word is exact.
        try:
            rvc, rout = cc.board_python(cc.DIE_A_IP, "%s --mode readback --payload 0x%08X"
                                        % (cc.XFER, KNOWN), cc.T_VERIFY, "readback_verify")
            print("  die_a readback (post): %s"
                  % (rout.strip().splitlines()[-1] if rout.strip() else "(no output)"))
            res["byte_exact"] = rvc == 0
        except cc.WedgeTimeout:
            print("  !! WEDGE: die_a readback verify timed out.")
            res["wedge"] = True
            cc.por_stage(cc.DIE_A_IP, "errinject %s readback wedge" % node)
            return res

    ok = res["alive"] and res["byte_exact"] and not res["wedge"]
    res["verdict"] = "PASS" if ok else "FAIL"
    print("  -> %s (alive=%s byte_exact=%s)" % (res["verdict"], res["alive"], res["byte_exact"]))
    return res


def w_byte0_soak(trials, base0):
    """Measure the residual W-byte-0 wedge RATE over `trials`. POR-staged."""
    cc.banner("W BYTE-0 RESIDUAL WEDGE RATE : %d trials (inject W@die_a byte0 bit0)"
              % trials)
    ok = wed = attempted = 0
    trial_log = []
    for i in range(1, trials + 1):
        # gate each trial: if the link is down (a prior wedge, not recovered), stop.
        up, _ = cc.fcsm4(cc.DIE_A_IP)
        up_b, _ = cc.fcsm4(cc.DIE_B_IP)
        if not (up and up_b):
            print("  trial %d: link not FCSM=4 (recovery pending) — stopping soak." % i)
            break
        attempted += 1
        base = (base0 + i) & 0xFFFFFFFF
        try:
            _arm_cam_a()
            cc.inject(cc.DIE_A_IP, 0x81, 0, 0)
            cc.board_python(cc.DIE_A_IP, "%s write %d 0x%08X" % (cc.SOAK_FWD, STREAM_N, base),
                            cc.T_STREAM, "wsoak_write")
            cc.inject_off(cc.DIE_A_IP)
            alive, _ = _die_a_alive()
        except cc.WedgeTimeout as e:
            alive = False
            print("  trial %d: WEDGE (host=%s stage=%s)" % (i, e.host, e.stage))
        if not alive:
            wed += 1
            trial_log.append((i, "WEDGE"))
            print("  W#%d WEDGED" % i)
            cc.por_stage(cc.DIE_A_IP, "W byte-0 soak trial %d wedge" % i)
            if os.environ.get("COV_AUTO_POR") == "1":
                print("  COV_AUTO_POR=1 -> attempting re-bring-up to continue soak ...")
                if not _bringup_pair():
                    print("  re-bring-up failed — stopping soak.")
                    break
            else:
                print("  (attended) stopping soak at first wedge; recover + rerun "
                      "with COV_AUTO_POR=1 to auto-continue.")
                break
            continue
        # alive: confirm byte-exact via die_b local read.
        try:
            rvc, _ = cc.board_python(cc.DIE_B_IP, "%s verify %d 0x%08X"
                                     % (cc.SOAK_FWD, STREAM_N, base), cc.T_VERIFY, "verify")
        except cc.WedgeTimeout:
            rvc = 1
        ok += 1
        trial_log.append((i, "ALIVE" + ("/exact" if rvc == 0 else "/MISMATCH")))
    rate = (wed / attempted) if attempted else 0.0
    print("  W byte-0: ALIVE=%d WEDGED=%d of %d attempted  (wedge rate=%.1f%%)"
          % (ok, wed, attempted, 100.0 * rate))
    return {"alive": ok, "wedged": wed, "attempted": attempted, "rate": rate,
            "trials": trial_log}


def main():
    ap = argparse.ArgumentParser(
        description="Directional err-inject sweep gate + W-byte-0 residual rate.")
    ap.add_argument("--nodes", default="AW,W,AR,B,R",
                    help="comma list of nodes to sweep (default all 5).")
    ap.add_argument("--bytebits", default="0:0,1:0",
                    help="comma list of byte:bit pairs to inject (default 0:0,1:0).")
    ap.add_argument("--wsoak", type=int, default=10,
                    help="W-byte-0 residual-rate trials (0 to skip).")
    args = ap.parse_args()

    nodes = [n.strip() for n in args.nodes.split(",") if n.strip()]
    for n in nodes:
        if n not in NODES:
            print("ERROR: unknown node %r (choose from %s)" % (n, ",".join(NODES)))
            return 4
    bytebits = []
    for tok in args.bytebits.split(","):
        b, _, bt = tok.partition(":")
        bytebits.append((int(b, 0), int(bt, 0)))

    cc.banner("DIRECTIONAL ERR-INJECT SWEEP (ATTENDED, JTAG-POR staged)")
    try:
        cc.require_pair_fcsm4(cc.DIE_A_IP, cc.DIE_B_IP)
    except SystemExit as e:
        print("GATE ABORTED: %s" % e)
        return 2

    results = []
    stopped = False
    for node in nodes:
        if stopped:
            break
        for (byte, bit) in bytebits:
            base = (0xB0000000 | (NODES[node][0] << 8) | (byte << 4) | bit) & 0xFFFFFFFF
            r = run_node(node, byte, bit, base)
            results.append(r)
            if r["wedge"]:
                print("STOP: wedge on node %s — halting the matrix until recovery." % node)
                stopped = True
                break

    soak = None
    if args.wsoak > 0 and not stopped:
        soak = w_byte0_soak(args.wsoak, 0xB0C00000)
    elif args.wsoak > 0 and stopped:
        print("(skipping W byte-0 soak: matrix wedged; recover first.)")

    cc.banner("ERR-INJECT SWEEP SUMMARY")
    matrix_ok = bool(results) and all(r["verdict"] == "PASS" for r in results)
    for r in results:
        print("  %-2s byte%d/bit%d inject@%s : %s%s"
              % (r["node"], r["byte"], r["bit"], r["inject_die"], r["verdict"],
                 "  (WEDGE)" if r["wedge"] else ""))
    if soak is not None:
        print("  W byte-0 residual: ALIVE=%d WEDGED=%d/%d  rate=%.1f%%"
              % (soak["alive"], soak["wedged"], soak["attempted"], 100.0 * soak["rate"]))
    # the matrix is the gate; the W-byte-0 rate is a MEASUREMENT (non-gating —
    # a known marginal residual the ECC logic-fix does not fully eliminate).
    print("RESULT: %s%s"
          % ("PASS — every node recovered a byte-0 flip, die_a alive, data exact"
             if matrix_ok else "FAIL — see matrix detail above",
             "" if soak is None else "  |  W byte-0 wedge rate = %.1f%% (measurement)"
             % (100.0 * soak["rate"])))
    return 0 if matrix_ok else 1


if __name__ == "__main__":
    sys.exit(main())
