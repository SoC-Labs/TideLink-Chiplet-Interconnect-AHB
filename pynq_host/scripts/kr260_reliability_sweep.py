#!/usr/bin/env python3
# =============================================================================
# kr260_reliability_sweep.py — DELIVERY-KEYED RELIABILITY SWEEP (P2-R2, spec 2026-08-08).
#
# Quantifies the eth-chiplet bring-up lottery as a DELIVERY land-rate: over N
# independent POR + bring-up cycles, does a fixed write budget actually LAND
# (die_b-LOCAL byte-exact)? Replaces the wrong-metric lock-popcount reliability.
# Runs ON mapstone-dev; drives both dies over timeout-wrapped ssh.
#
# PER CYCLE (fresh, independent link):
#   1. JTAG-POR BOTH dies (por_recover.sh -> fpgahub socket; flock/MAX_POR/PARK).
#   2. bilateral bring-up (bringup_pair_release.sh).
#   3. require FCSM=4 both; capture PRE-SOAK obs (fcsm/cal, Region-F 0x21E0,
#      witness 0x21F8 if witness_present, eye 0x21E8 best_run if eye_present [CC-1:
#      the eye reg is 0x21E8, NOT 0x2150]).
#   4. fixed budget: die_a `soak_fwd write K` (distinct addresses in ONE invocation)
#      then die_b LOCAL `verify K`.
#   5. CLASSIFY:
#        LAND   = >= LAND_K byte-exact AND no wedge
#        DROP   = link up but < LAND_K byte-exact
#        WEDGE  = a write/gate ssh timed out (POR-staged; next cycle re-PORs anyway)
#        NOLINK = POR ok but the link never reached FCSM=4 (bring-up lottery miss)
#
# GATE (pre-registered, CC-4/CC-6):
#   PASS iff land_rate (LAND / cycles executed) >= LAND_FLOOR AND all N cycles
#   completed with no PARK. land_rate is the GATE; mean-writes-to-wedge / mean
#   delivered are REPORT-ONLY.
#
# WEDGE-SAFETY: each bring-up on freshly-POR'd dies; per-access timeout == wedge;
#   bounded single-shot write budget; die_b-LOCAL verify (verifier cannot wedge);
#   POR between cycles; PARK after MAX_POR. Requires COV_AUTO_POR=1 (it POR-cycles
#   the pair N times — refuse otherwise so it never runs unexpectedly).
#
# Run ON mapstone-dev (never on the boards):
#   export KR260_PASSWORD=...          # or derived from the bring-up default
#   COV_AUTO_POR=1 python3 kr260_reliability_sweep.py                 # N=8
#   COV_AUTO_POR=1 python3 kr260_reliability_sweep.py --cycles 12 --out ./sweep_out
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage"))
import cov_common as cc

SWI_LANE_OFF = 0x2108
WITNESS_OFF = 0x21F8
WITNESS_MARKER = 0xB5
EYE_OFF = 0x21E8               # CC-1: WINSCAN_EYE (marker 0x25) — NOT 0x2150
EYE_MARKER = 0x25

# Pre-registered land-rate floor (CC-6). Override via env for a characterised eye.
LAND_FLOOR = float(os.environ.get("RELIABILITY_LAND_FLOOR", "0.75"))


# --- password: derive from the bring-up default, mask it, NEVER echo it -------
def _derive_pw():
    v = os.environ.get("KR260_PASSWORD")
    if v:
        return v
    sh = os.path.join(cc.SCRIPTS_DIR, "kr260_eth_bringup_pair.sh")
    try:
        with open(sh) as f:
            for ln in f:
                if "KR260_PASSWORD:-" in ln:
                    return ln.split("KR260_PASSWORD:-", 1)[1].split("}", 1)[0]
    except OSError:
        pass
    return ""


_PW = _derive_pw()
if _PW and not os.environ.get("KR260_PASSWORD"):
    os.environ["KR260_PASSWORD"] = _PW


def _mask(s):
    s = str(s)
    return s.replace(_PW, "***") if _PW else s


def _lastline(s):
    s = _mask(s).strip()
    return s.splitlines()[-1] if s else ""


# --- RO pre-soak observables via the proven poke-read layer (cannot wedge) ----
def capture_obs(ip):
    o = {}
    try:
        v, _ = cc.read_reg(ip, SWI_LANE_OFF)
        o["fcsm"] = (v >> 17) & 7 if v is not None else None
        o["cal"] = (v >> 16) & 1 if v is not None else None
    except cc.WedgeTimeout:
        o["fcsm"] = o["cal"] = None
    d = cc.regf_snapshot(ip, "    ")            # prints its own one-liner
    o["regf_present"] = bool(d.get("present"))
    o["data_healthy"] = d.get("data_healthy")
    o["tgt_wsticky"] = d.get("tgt_wsticky")
    o["ini_wsticky"] = d.get("ini_wsticky")
    try:
        v, _ = cc.read_reg(ip, WITNESS_OFF)
        wp = v is not None and ((v >> 24) & 0xFF) == WITNESS_MARKER
        o["witness_present"] = wp
        o["stall_stuck"] = (v >> 10) & 1 if wp else None
        o["synth_b"] = (v >> 8) & 1 if wp else None
    except cc.WedgeTimeout:
        o["witness_present"] = False
    try:
        v, _ = cc.read_reg(ip, EYE_OFF)
        ep = v is not None and ((v >> 24) & 0xFF) == EYE_MARKER
        o["eye_present"] = ep
        o["best_run"] = v & 0x3F if ep else None
        o["lane_passed"] = (v >> 13) & 1 if ep else None
    except cc.WedgeTimeout:
        o["eye_present"] = False
    print("    pre-soak obs die_a: fcsm=%s cal=%s regf_present=%s data_healthy=%s "
          "witness_present=%s stall=%s eye_present=%s best_run=%s"
          % (o.get("fcsm"), o.get("cal"), o["regf_present"], o.get("data_healthy"),
             o["witness_present"], o.get("stall_stuck"), o["eye_present"], o.get("best_run")))
    return o


# --- POR both dies in parallel (JTAG issue is flock-serialised inside) --------
def por_both():
    """Returns dict target -> rc (0 recovered, 3 PARK, other = fail)."""
    procs = []
    for tgt in ("kr260_01", "kr260_02"):
        procs.append((tgt, subprocess.Popen(["bash", cc.POR_SH, tgt],
                                             env=dict(os.environ),
                                             stdout=subprocess.PIPE,
                                             stderr=subprocess.STDOUT, text=True)))
    rcs = {}
    for tgt, p in procs:
        try:
            out, _ = p.communicate(timeout=700)
        except subprocess.TimeoutExpired:
            p.kill()
            out, _ = p.communicate()
            out = (out or "") + "\n(por_recover.sh %s timed out)" % tgt
        rcs[tgt] = p.returncode
        print(_mask((out or "").rstrip()))
    return rcs


def bringup_pair():
    sh = os.path.join(cc.SCRIPTS_DIR, "bringup_pair_release.sh")
    if not os.path.exists(sh):
        print("  bringup_pair_release.sh not found — cannot bring up.")
        return False
    try:
        p = subprocess.run(["bash", sh], env=dict(os.environ), timeout=300,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(_mask(p.stdout.rstrip()))
        return p.returncode == 0 or "LINK UP" in p.stdout
    except subprocess.TimeoutExpired:
        print("  bringup_pair_release.sh timed out (>300s)")
        return False


def run_cycle(i, budget, land_k, base):
    """One reliability cycle. Returns a result dict with 'class' in
       {LAND,DROP,WEDGE,NOLINK,PARK}."""
    cc.banner("RELIABILITY CYCLE %d — POR both -> bring-up -> fixed budget %d" % (i, budget))
    res = {"cycle": i, "class": "NOLINK", "verified": 0, "budget": budget, "obs": None}

    # 1. POR both fresh.
    rcs = por_both()
    if 3 in rcs.values():
        res["class"] = "PARK"
        res["detail"] = "PARK: %s" % ",".join("%s=%d" % (t, r) for t, r in rcs.items())
        return res
    if any(r != 0 for r in rcs.values()):
        res["detail"] = "POR failed (no recover): %s" % ",".join("%s=%d" % (t, r) for t, r in rcs.items())
        return res

    # 2. bring up.
    if not bringup_pair():
        res["detail"] = "link did not bring up (bring-up lottery miss)"
        return res

    # 3. FCSM=4 both.
    ua, _ = cc.fcsm4(cc.DIE_A_IP)
    ub, _ = cc.fcsm4(cc.DIE_B_IP)
    if not (ua and ub):
        res["detail"] = "not FCSM=4 both after bring-up"
        return res

    # 4. pre-soak obs (report; feeds the eye/witness classifier report-only).
    res["obs"] = capture_obs(cc.DIE_A_IP)

    # 5. fixed budget write (distinct addresses, ONE invocation) + die_b verify.
    try:
        rc, out = cc.board_python(cc.DIE_A_IP, "%s write %d 0x%08X"
                                  % (cc.SOAK_FWD, budget, base), cc.T_STREAM, "sweep_write")
    except cc.WedgeTimeout as e:
        res["class"] = "WEDGE"
        res["detail"] = "write ssh timeout (stage=%s)" % e.stage
        cc.por_stage(cc.DIE_A_IP, "reliability cycle %d write wedge" % i)
        return res
    if rc != 0 or "WROTE" not in out:
        res["class"] = "DROP"
        res["detail"] = "write refused rc=%d: %s" % (rc, _lastline(out))
        return res
    try:
        rvc, rout = cc.board_python(cc.DIE_B_IP, "%s verify %d 0x%08X"
                                    % (cc.SOAK_FWD, budget, base), cc.T_VERIFY, "sweep_verify")
    except cc.WedgeTimeout as e:
        res["class"] = "WEDGE"
        res["detail"] = "die_b verify ssh timeout (stage=%s)" % e.stage
        cc.por_stage(cc.DIE_B_IP, "reliability cycle %d verify wedge" % i)
        return res
    ll = _lastline(rout)
    verified = 0
    for tok in ll.split():
        if "/" in tok and tok.split("/")[0].isdigit():
            try:
                verified = int(tok.split("/")[0])
                break
            except ValueError:
                pass
    res["verified"] = verified
    res["detail"] = ll
    res["class"] = "LAND" if (rvc == 0 and verified >= land_k) else "DROP"
    print("  cycle %d -> %s (%d/%d byte-exact)" % (i, res["class"], verified, budget))
    return res


def main():
    ap = argparse.ArgumentParser(description="Delivery-keyed reliability sweep (P2-R2).")
    ap.add_argument("--cycles", type=int, default=8, help="N independent POR+bring-up cycles (default 8).")
    ap.add_argument("--budget", type=int, default=512, help="K: per-link write budget (default 512).")
    ap.add_argument("--land-k", type=int, default=None,
                    help="min byte-exact words for a LAND (default = full budget).")
    ap.add_argument("--land-floor", type=float, default=LAND_FLOOR,
                    help="pre-registered land-rate floor to PASS (default %.2f)." % LAND_FLOOR)
    ap.add_argument("--out", default=None, help="dir for reliability.jsonl + sweep.csv (optional).")
    args = ap.parse_args()

    land_k = args.land_k if args.land_k is not None else args.budget

    cc.banner("DELIVERY-KEYED RELIABILITY SWEEP (P2-R2, ATTENDED, N=%d POR cycles)" % args.cycles)
    if not _PW:
        print("ERROR: no board password.")
        print("RESULT: RELIABILITY_SWEEP INCONCLUSIVE (no password)")
        return 2
    if os.environ.get("COV_AUTO_POR") != "1":
        print("REFUSING: this sweep POR-cycles the pair %d times. Re-run with COV_AUTO_POR=1"
              % args.cycles)
        print("on mapstone-dev (fpgahub socket reachable):")
        print("  COV_AUTO_POR=1 python3 kr260_reliability_sweep.py")
        print("RESULT: RELIABILITY_SWEEP INCONCLUSIVE (COV_AUTO_POR!=1 — not run)")
        return 2
    print("  pre-registered LAND_FLOOR=%.2f  budget K=%d  LAND_K=%d (CC-4: land-rate GATES; "
          "MWTW/mean-delivered report-only)" % (args.land_floor, args.budget, land_k))

    results = []
    parked = False
    for i in range(1, args.cycles + 1):
        r = run_cycle(i, args.budget, land_k, (0xE0E00000 + (i << 16)) & 0xFFFFFFFF)
        results.append(r)
        if r["class"] == "PARK":
            print("  PARK on cycle %d — a board is bricked; stopping the sweep." % i)
            parked = True
            break

    executed = [r for r in results if r["class"] != "PARK"]
    n_exec = len(executed)
    counts = {k: sum(1 for r in executed if r["class"] == k)
              for k in ("LAND", "DROP", "WEDGE", "NOLINK")}
    land_rate = (counts["LAND"] / n_exec) if n_exec else 0.0

    # report-only metrics (CC-4).
    landed_words = [r["verified"] for r in executed if r["class"] == "LAND"]
    mean_delivered = (sum(r["verified"] for r in executed) / n_exec) if n_exec else 0.0
    n_wedge = counts["WEDGE"]

    if args.out:
        try:
            os.makedirs(args.out, exist_ok=True)
            with open(os.path.join(args.out, "reliability.jsonl"), "w") as jf:
                for r in results:
                    jf.write(json.dumps(r) + "\n")
            with open(os.path.join(args.out, "sweep.csv"), "w") as cf:
                cf.write("cycle,class,verified,budget,fcsm,cal,regf_present,best_run,witness_present,stall\n")
                for r in results:
                    o = r.get("obs") or {}
                    cf.write("%d,%s,%d,%d,%s,%s,%s,%s,%s,%s\n"
                             % (r["cycle"], r["class"], r.get("verified", 0), r.get("budget", 0),
                                o.get("fcsm"), o.get("cal"), o.get("regf_present"),
                                o.get("best_run"), o.get("witness_present"), o.get("stall_stuck")))
            print("  wrote %s/reliability.jsonl + sweep.csv" % args.out)
        except OSError as e:
            print("  (could not write --out artefacts: %s)" % e)

    cc.banner("RELIABILITY SWEEP SUMMARY")
    for r in results:
        print("  cycle %2d : %-6s  %d/%d  %s"
              % (r["cycle"], r["class"], r.get("verified", 0), r.get("budget", 0),
                 _mask(r.get("detail", ""))[:70]))
    print("  ----")
    print("  executed=%d/%d  LAND=%d DROP=%d WEDGE=%d NOLINK=%d  PARK=%s"
          % (n_exec, args.cycles, counts["LAND"], counts["DROP"], counts["WEDGE"],
             counts["NOLINK"], parked))
    print("  land_rate=%.3f  (GATE: >= %.2f)" % (land_rate, args.land_floor))
    print("  report-only (CC-4): mean_delivered=%.1f words/cycle  wedge_cycles=%d  "
          "MWTW=coarse (single-shot budget K=%d; wedged cycles wedged within K)"
          % (mean_delivered, n_wedge, args.budget))
    print("  report-only: landed-cycle delivered words = %s" % (landed_words or "none"))

    ok = (not parked) and n_exec == args.cycles and land_rate >= args.land_floor
    print("RESULT: RELIABILITY_SWEEP %s"
          % ("PASS — land_rate=%.3f >= floor %.2f over %d cycles, no PARK"
             % (land_rate, args.land_floor, n_exec) if ok
             else "FAIL — land_rate=%.3f floor=%.2f executed=%d/%d parked=%s"
                  % (land_rate, args.land_floor, n_exec, args.cycles, parked)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
