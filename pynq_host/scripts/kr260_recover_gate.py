#!/usr/bin/env python3
# =============================================================================
# kr260_recover_gate.py — RECOVERY-AFTER-WEDGE GATE (P2-R1, build spec 2026-08-08).
#
# Closes the missing loop (§2.8): wedge -> JTAG-POR -> re-bring-up -> data flows
# again. Runs ON mapstone-dev, drives both dies over timeout-wrapped ssh.
#
# SEQUENCE:
#   0. refuse unless BOTH dies FCSM=4 (require_pair_fcsm4) and COV_AUTO_POR=1
#      (this gate DELIBERATELY wedges — it must be allowed to auto-recover, or it
#       would leave a board bricked; so we refuse to induce a wedge otherwise).
#   1. drive a WEDGE-SAFE write soak on die_a until a wedge is detected
#        - a write-chunk ssh timeout          (== PS-bus WEDGE), or
#        - 0x21F8 witness bit10 (stall_stuck) | bit8 (synth_b), IF witness_present, or
#        - Region-F (0x21E0) fault (data_healthy=0 / wedge-sticky), IF regf_present
#      or until WEDGE_CAP beats with no wedge.
#   2. JTAG-POR the wedged die (por_recover.sh -> fpgahub socket; flock, MAX_POR,
#      PARK). Wait for ping+ssh (por_recover.sh does this and exits 0 on recovered).
#   3. bilateral re-bring-up on the fresh dies (bringup_pair_release.sh).
#   4. short write M + die_b-LOCAL verify (delivery restored) + health check.
#
# PASS iff: (1) POR recovered (no PARK) AND (2) FCSM=4 both dies AND (3) M/M
#   byte-exact AND (4) post-soak HEALTHY (regf_present + data_healthy + no
#   wedge-sticky [CC-3], witness stall==0 if witness_present).
# recovery_latency_s and whether a wedge was actually induced are REPORT-ONLY (CC-4).
#
# WEDGE-SAFETY: deliberately wedges but recovers via the documented JTAG-POR;
#   all verdicts are die_b-LOCAL or RO; every ssh timeout-wrapped; single pair on
#   mapstone-dev; never re-bring-up a LIVE link (only after a POR). Net brick-risk
#   LOW (JTAG-POR is always available).
#
# Run ON mapstone-dev (never on the boards):
#   export KR260_PASSWORD=...          # or derived from the bring-up default
#   COV_AUTO_POR=1 python3 kr260_recover_gate.py
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage"))
import cov_common as cc

WITNESS_OFF = 0x21F8              # marker 0xB5: [8]synth_b [10]stall_stuck
WITNESS_MARKER = 0xB5


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


# --- RO observables via the proven poke-read layer (cannot wedge) ------------
def read_witness(ip):
    try:
        v, _ = cc.read_reg(ip, WITNESS_OFF)
    except cc.WedgeTimeout:
        return {"timeout": True, "present": False}
    if v is None:
        return {"present": False}
    present = ((v >> 24) & 0xFF) == WITNESS_MARKER
    return {"raw": v, "present": present,
            "stall_stuck": (v >> 10) & 1 if present else None,
            "synth_b": (v >> 8) & 1 if present else None}


def safe_regf(ip, tag=""):
    """cc.regf_snapshot already catches WedgeTimeout -> {'timeout':True}."""
    return cc.regf_snapshot(ip, tag)


# --- link-healthy predicate (CC-3: regf_present ANDed in) --------------------
def link_healthy():
    ua, _ = cc.fcsm4(cc.DIE_A_IP)
    ub, _ = cc.fcsm4(cc.DIE_B_IP)
    if not (ua and ub):
        return False, "not FCSM=4 on both dies"
    for tag, ip in (("die_a", cc.DIE_A_IP), ("die_b", cc.DIE_B_IP)):
        d = safe_regf(ip, "  %s " % tag)
        if d.get("timeout"):
            return False, "%s Region-F read WEDGED" % tag
        if not d.get("present"):
            return False, "%s Region-F marker absent (CC-3: not healthy)" % tag
        if not d.get("data_healthy"):
            return False, "%s data_healthy=0" % tag
        if (d.get("tgt_wsticky") or 0) or (d.get("ini_wsticky") or 0):
            return False, "%s wedge-sticky latched" % tag
        w = read_witness(ip)
        if w.get("present") and w.get("stall_stuck"):
            return False, "%s witness stall_stuck=1" % tag
    return True, "FCSM=4 both, Region-F present+healthy+no-sticky, witness stall==0"


# --- deliberate wedge inducer (bounded, timeout-wrapped, RO gates between) ---
def induce_wedge(cap, chunk, base):
    """Returns (wedged_ip_or_None, wedge_reason, beats_driven)."""
    beats = 0
    while beats < cap:
        n = min(chunk, cap - beats)
        try:
            rc, out = cc.board_python(cc.DIE_A_IP, "%s write %d 0x%08X"
                                      % (cc.SOAK_FWD, n, base), cc.T_STREAM, "induce_write")
        except cc.WedgeTimeout:
            return cc.DIE_A_IP, "write chunk ssh timeout @beat %d (PS-bus wedge)" % beats, beats
        if rc != 0 or "WROTE" not in out:
            return cc.DIE_A_IP, "write refused rc=%d @beat %d (%s)" % (rc, beats, _lastline(out)), beats
        beats += n
        # RO wedge-signature gates between chunks.
        w = read_witness(cc.DIE_A_IP)
        if w.get("timeout"):
            return cc.DIE_A_IP, "witness read WEDGED @beat %d" % beats, beats
        if w.get("present") and (w.get("stall_stuck") or w.get("synth_b")):
            return cc.DIE_A_IP, "witness bit10|bit8 set @beat %d" % beats, beats
        d = safe_regf(cc.DIE_A_IP)
        if d.get("timeout"):
            return cc.DIE_A_IP, "Region-F read WEDGED @beat %d" % beats, beats
        if d.get("present") and (not d.get("data_healthy")
                                 or (d.get("tgt_wsticky") or 0) or (d.get("ini_wsticky") or 0)):
            return cc.DIE_A_IP, "Region-F fault @beat %d" % beats, beats
    return None, "no wedge within WEDGE_CAP=%d beats" % cap, beats


# --- documented JTAG-POR recovery (por_recover.sh; rc 0 == recovered) --------
# NOTE: we invoke por_recover.sh DIRECTLY (not via cc.por_stage) so we can read
# its exit code (0 == recovered, 3 == PARK) — cc.por_stage would ALSO issue a POR
# under COV_AUTO_POR=1 (which this gate requires), double-POR'ing the die.
def por_recover(ip, reason):
    target = cc.IP_TO_TARGET.get(ip.split("@")[-1], "?")
    if target == "?":
        print("  cannot map %s to an fpgahub target — POR not issued." % ip)
        return False
    print("  ---- JTAG-POR (recover-after-wedge): board %s (%s) ----" % (target, ip))
    print("     recovery is JTAG-POR ONLY (fpgahub socket), never `sudo reboot`.")
    print(_mask("  issuing por_recover.sh %s (%s) ..." % (target, reason)))
    try:
        p = subprocess.run(["bash", cc.POR_SH, target], env=dict(os.environ),
                           timeout=700, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        print(_mask(p.stdout.rstrip()))
        return p.returncode == 0          # 0 == RECOVERED, 3 == PARKED
    except subprocess.TimeoutExpired:
        print("  por_recover.sh timed out (>700s)")
        return False


def bringup_pair():
    sh = os.path.join(cc.SCRIPTS_DIR, "bringup_pair_release.sh")
    if not os.path.exists(sh):
        print("  bringup_pair_release.sh not found — cannot re-bring-up.")
        return False
    try:
        p = subprocess.run(["bash", sh], env=dict(os.environ), timeout=300,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(_mask(p.stdout.rstrip()))
        return p.returncode == 0 or "LINK UP" in p.stdout
    except subprocess.TimeoutExpired:
        print("  bringup_pair_release.sh timed out (>300s)")
        return False


def main():
    ap = argparse.ArgumentParser(description="Recovery-after-wedge gate (P2-R1).")
    ap.add_argument("--wedge-cap", type=int, default=3000,
                    help="max soak beats to drive looking for a wedge (default 3000).")
    ap.add_argument("--chunk", type=int, default=256,
                    help="soak write chunk size (RO wedge-gate between chunks). Default 256.")
    ap.add_argument("--recover-writes", type=int, default=512,
                    help="M: post-recovery delivery write+verify budget (default 512).")
    args = ap.parse_args()

    cc.banner("RECOVERY-AFTER-WEDGE GATE (P2-R1, ATTENDED, deliberately wedges)")
    if not _PW:
        print("ERROR: no board password.")
        print("RESULT: RECOVER_AFTER_WEDGE INCONCLUSIVE (no password)")
        return 2
    if os.environ.get("COV_AUTO_POR") != "1":
        print("REFUSING: this gate DELIBERATELY induces a wedge and must be allowed to")
        print("auto-recover, or it would leave a board bricked. Re-run with COV_AUTO_POR=1")
        print("on mapstone-dev (fpgahub socket reachable):")
        print("  COV_AUTO_POR=1 python3 kr260_recover_gate.py")
        print("RESULT: RECOVER_AFTER_WEDGE INCONCLUSIVE (COV_AUTO_POR!=1 — not run)")
        return 2

    try:
        cc.require_pair_fcsm4(cc.DIE_A_IP, cc.DIE_B_IP)
    except SystemExit:
        print("RESULT: RECOVER_AFTER_WEDGE INCONCLUSIVE (link not FCSM=4 both dies)")
        return 2

    # 1. drive the wedge-safe soak until a wedge or WEDGE_CAP.
    cc.banner("PHASE 1: induce a wedge (bounded write soak, RO gates between chunks)")
    wedged_ip, reason, beats = induce_wedge(args.wedge_cap, args.chunk, 0xD1D10000)
    wedge_induced = wedged_ip is not None
    print("  wedge_induced=%s  reason=%s  beats_driven=%d" % (wedge_induced, reason, beats))
    target_ip = wedged_ip or cc.DIE_A_IP          # POR die_a if the soak never wedged

    # 2. JTAG-POR the (wedged) die and wait for it to come back.
    cc.banner("PHASE 2: JTAG-POR recovery of %s"
              % cc.IP_TO_TARGET.get(target_ip.split("@")[-1], target_ip))
    t_por0 = time.time()
    recovered = por_recover(target_ip, "recover-after-wedge (%s)" % reason)
    if not recovered:
        print("RESULT: RECOVER_AFTER_WEDGE FAIL (JTAG-POR did not recover the die — PARK/timeout)")
        return 1

    # 3. bilateral re-bring-up on the fresh dies.
    cc.banner("PHASE 3: re-bring-up (bringup_pair_release.sh)")
    brought_up = bringup_pair()
    recovery_latency_s = time.time() - t_por0
    if not brought_up:
        print("  recovery_latency_s=%.1f (report-only)" % recovery_latency_s)
        print("RESULT: RECOVER_AFTER_WEDGE FAIL (POR recovered but link did not re-bring-up)")
        return 1

    # 4. delivery + health after recovery.
    cc.banner("PHASE 4: delivery + health after recovery")
    fa, _ = cc.fcsm4(cc.DIE_A_IP)
    fb, _ = cc.fcsm4(cc.DIE_B_IP)
    fcsm_ok = fa and fb
    print("  FCSM=4 both dies: %s" % fcsm_ok)

    delivered = False
    M = args.recover_writes
    try:
        rc, out = cc.board_python(cc.DIE_A_IP, "%s write %d 0x%08X"
                                  % (cc.SOAK_FWD, M, 0xD2D20000), cc.T_STREAM, "recover_write")
        if rc == 0 and "WROTE" in out:
            rvc, rout = cc.board_python(cc.DIE_B_IP, "%s verify %d 0x%08X"
                                        % (cc.SOAK_FWD, M, 0xD2D20000), cc.T_VERIFY, "recover_verify")
            print("  die_b LOCAL verify: %s" % _lastline(rout))
            delivered = rvc == 0 and ("%d/%d" % (M, M)) in rout
        else:
            print("  post-recovery write failed rc=%d: %s" % (rc, _lastline(out)))
    except cc.WedgeTimeout as e:
        print("  !! WEDGE during post-recovery delivery (stage=%s)" % e.stage)
        cc.por_stage(e.host, "post-recovery delivery wedge")

    healthy, htxt = link_healthy()
    print("  health: %s (%s)" % ("HEALTHY" if healthy else "FAULT", htxt))
    print("  recovery_latency_s=%.1f (report-only, CC-4)   wedge_induced=%s (report-only)"
          % (recovery_latency_s, wedge_induced))

    ok = recovered and fcsm_ok and delivered and healthy
    note = "" if wedge_induced else "  [NOTE: no wedge was induced within WEDGE_CAP — recovery loop exercised from a non-wedged link]"
    print("RESULT: RECOVER_AFTER_WEDGE %s%s"
          % ("PASS — POR recovered, FCSM=4 both, %d/%d landed, healthy" % (M, M) if ok
             else "FAIL — recovered=%s fcsm=%s delivered=%s healthy=%s"
                  % (recovered, fcsm_ok, delivered, healthy), note))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
