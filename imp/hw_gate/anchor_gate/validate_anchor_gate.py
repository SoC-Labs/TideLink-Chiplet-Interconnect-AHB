#!/usr/bin/env python3
# =============================================================================
# validate_anchor_gate.py — retrospective validation of the ANCHOR-PAIR RETRY
#                           GATE against the n=20 overnight campaign.
#
# NO HARDWARE IS TOUCHED. This replays the gate predicate over 20 runs whose
# delivery outcome is already recorded, and reports a confusion matrix. The
# point is to spend zero rig time proving the classifier is at least
# self-consistent with the evidence that motivated it.
#
# It imports the predicate from pynq_host/scripts/anchor_pair_gate.py — the SAME
# code the live orchestrator calls. If they ever diverge, this validation is
# worthless, so it must not be re-implemented here.
#
# Inputs, per run directory imp/hw_gate/overnight/run_NN/tl035_baseline/:
#   04_bringup_a.log / 04_bringup_b.log  -> the two RE-ANCHORED verdicts
#   00_run.log                           -> delivery truth, taken as the
#       PRE-INJECT die_b-local `VERIFY n/16 byte-exact` (step 6e). Pre-inject
#       and die_b-LOCAL are both load-bearing: the post-inject verify is after a
#       deliberate fault injection (runs 10 and 13 legitimately read 13/16 and
#       12/16 there), and reading back over the link would let the verifier
#       itself wedge.
#
#   usage: validate_anchor_gate.py [--root imp/hw_gate/overnight] [--mode pair]
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS = os.path.normpath(os.path.join(_HERE, "..", "..", "..",
                                         "pynq_host", "scripts"))
sys.path.insert(0, _SCRIPTS)
try:
    from anchor_pair_gate import (ACCEPT, REJECT, UNKNOWN, classify,  # noqa: E402
                                  parse_bringup_file, MODES)
except ImportError as e:
    sys.exit("cannot import anchor_pair_gate from %s: %s" % (_SCRIPTS, e))

# "21:11:22.211 pre_inject die_b LOCALMEM: VERIFY 16/16 byte-exact"
_RE_PRE_VERIFY = re.compile(
    r"pre_inject\s+die_b\s+LOCALMEM:.*?VERIFY\s+(\d+)\s*/\s*(\d+)\s+byte-exact")
# the rejected candidate gate, for contrast only
_RE_27890000 = re.compile(r"0x27890000")


def delivery_of(run_log):
    """(passed, total) from the PRE-INJECT die_b-local verify, or None."""
    try:
        with open(run_log, "r", errors="replace") as f:
            txt = f.read()
    except OSError:
        return None
    m = _RE_PRE_VERIFY.search(txt)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def has_27890000(path):
    try:
        with open(path, "r", errors="replace") as f:
            return bool(_RE_27890000.search(f.read()))
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser(
        description="Retrospective replay of the anchor-pair retry gate over a "
                    "campaign of known-outcome runs. Touches no hardware.")
    ap.add_argument("--root", default=os.path.normpath(
        os.path.join(_HERE, "..", "overnight")),
        help="campaign root holding run_NN/ dirs")
    ap.add_argument("--arm", default="tl035_baseline",
                    help="arm subdirectory inside each run_NN/")
    ap.add_argument("--mode", default="pair", choices=MODES)
    ap.add_argument("--expect", default="09,15,19",
                    help="comma-separated run numbers the gate SHOULD flag "
                         "(the known delivery failures)")
    args = ap.parse_args()

    runs = sorted(d for d in os.listdir(args.root)
                  if re.fullmatch(r"run_\d+", d))
    if not runs:
        sys.exit("no run_NN dirs under %s" % args.root)

    rows = []
    for r in runs:
        base = os.path.join(args.root, r, args.arm)
        la = os.path.join(base, "04_bringup_a.log")
        lb = os.path.join(base, "04_bringup_b.log")
        a = parse_bringup_file(la)
        b = parse_bringup_file(lb)
        verdict, why = classify(a["reanchored"], b["reanchored"],
                                a["linkup"], b["linkup"], mode=args.mode)
        deliv = delivery_of(os.path.join(base, "00_run.log"))
        rows.append({
            "run": r, "a": a, "b": b, "verdict": verdict, "why": why,
            "deliv": deliv,
            # contrast only — NOT part of the gate
            "cand_lane_status": has_27890000(la) or has_27890000(lb),
        })

    def yn(v):
        return "?" if v is None else ("YES" if v else "NO")

    print("=" * 78)
    print("ANCHOR-PAIR RETRY GATE — retrospective replay (mode=%s)" % args.mode)
    print("root: %s" % args.root)
    print("NO HARDWARE TOUCHED. %d runs replayed." % len(rows))
    print("=" * 78)
    print("%-7s %-9s %-9s %-8s %-10s %s"
          % ("run", "anchor_a", "anchor_b", "gate", "delivery", "span a/b"))
    print("-" * 78)
    for x in rows:
        d = x["deliv"]
        dstr = "-" if d is None else "%d/%d" % d
        flagged = x["verdict"] != ACCEPT
        span = "%s/%s" % (
            "-" if x["a"]["sr_span_meas"] is None else x["a"]["sr_span_meas"],
            "-" if x["b"]["sr_span_meas"] is None else x["b"]["sr_span_meas"])
        print("%-7s %-9s %-9s %-8s %-10s %s%s"
              % (x["run"], yn(x["a"]["reanchored"]), yn(x["b"]["reanchored"]),
                 "FLAG" if flagged else "pass", dstr, span,
                 "   <<<" if flagged else ""))

    # --- stratification by anchor pair --------------------------------------
    print()
    print("Delivery stratified by anchor pair (the measurement this gate encodes)")
    print("-" * 78)
    strata = {}
    for x in rows:
        k = "%s/%s" % (yn(x["a"]["reanchored"]), yn(x["b"]["reanchored"]))
        strata.setdefault(k, []).append(x)
    for k in ("YES/YES", "NO/NO", "NO/YES", "YES/NO"):
        grp = strata.get(k, [])
        if not grp:
            continue
        ok = sum(1 for x in grp
                 if x["deliv"] and x["deliv"][0] == x["deliv"][1])
        print("  %-8s n=%-3d delivered byte-exact: %d/%d" % (k, len(grp), ok, len(grp)))
    other = [k for k in strata if k not in ("YES/YES", "NO/NO", "NO/YES", "YES/NO")]
    for k in other:
        print("  %-8s n=%-3d  (UNEXPECTED pair state — inspect)" % (k, len(strata[k])))

    # --- confusion matrix ----------------------------------------------------
    def delivered(x):
        d = x["deliv"]
        return None if d is None else (d[0] == d[1])

    tp = [x for x in rows if x["verdict"] != ACCEPT and delivered(x) is False]
    fp = [x for x in rows if x["verdict"] != ACCEPT and delivered(x) is True]
    fn = [x for x in rows if x["verdict"] == ACCEPT and delivered(x) is False]
    tn = [x for x in rows if x["verdict"] == ACCEPT and delivered(x) is True]
    nod = [x for x in rows if delivered(x) is None]

    print()
    print("CONFUSION MATRIX  (flagged = gate rejects the pair and re-rolls)")
    print("-" * 78)
    print("                      delivery FAILED    delivery OK")
    print("  gate FLAGGED        %-18d %d" % (len(tp), len(fp)))
    print("  gate passed         %-18d %d" % (len(fn), len(tn)))
    if nod:
        print("  (no delivery datum: %s)" % ", ".join(x["run"] for x in nod))
    print()
    print("  true  positives (caught)      : %s" % (
        ", ".join(x["run"] for x in tp) or "none"))
    print("  FALSE positives (wasted retry): %s" % (
        ", ".join(x["run"] for x in fp) or "none"))
    print("  FALSE negatives (missed)      : %s" % (
        ", ".join(x["run"] for x in fn) or "none"))

    # --- contrast: the REJECTED SWI_LANE_STATUS candidate --------------------
    cand = [x for x in rows if x["cand_lane_status"]]
    cand_fp = [x for x in cand if delivered(x) is True]
    cand_tp = [x for x in cand if delivered(x) is False]
    print()
    print("CONTRAST — the REJECTED candidate gate (0x27890000 in the bring-up log)")
    print("-" * 78)
    print("  would flag: %s" % (", ".join(x["run"] for x in cand) or "none"))
    print("  of those, delivered OK (false positives): %s"
          % (", ".join(x["run"] for x in cand_fp) or "none"))
    print("  of those, actually failed (true positives): %s"
          % (", ".join(x["run"] for x in cand_tp) or "none"))
    print("  -> SWI_LANE_STATUS[29]/[25] are llrx_valid/is_short_pkt: free-running")
    print("     RX packet classification, not anchor state. DO NOT gate on them.")

    # --- pass/fail of THIS validation ---------------------------------------
    want = {("run_%02d" % int(s)) for s in args.expect.split(",") if s.strip()}
    got = {x["run"] for x in rows if x["verdict"] != ACCEPT}
    print()
    print("=" * 78)
    ok = (got == want) and not fp and not fn
    if ok:
        print("VALIDATION PASS — gate flags exactly %s and nothing else."
              % ", ".join(sorted(want)))
    else:
        print("VALIDATION FAIL — expected to flag %s, actually flagged %s"
              % (sorted(want), sorted(got)))
    print()
    print("HONESTY (do not drop this when quoting the matrix):")
    print("  * n=3 on the failing arm. 3/3 is suggestive, NOT settled.")
    print("  * This is a RETROSPECTIVE fit to the same 20 runs that motivated the")
    print("    predicate. It shows self-consistency and the ABSENCE of false")
    print("    positives; it is NOT independent confirmation.")
    print("  * The campaign cannot separate predictor from symptom. Live hypothesis")
    print("    is anchor-as-WITNESS: reanchored=1 with an all-zero lane_off is")
    print("    bit-identical on the datapath to reanchored=0.")
    print("  * The gate is a cheap MITIGATION, not a proven mechanism.")
    print("=" * 78)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
