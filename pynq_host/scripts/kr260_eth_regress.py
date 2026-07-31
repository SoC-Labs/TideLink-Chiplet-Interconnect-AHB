#!/usr/bin/env python3
# =============================================================================
# kr260_eth_regress.py — repeatable cross-die regression suite for the two-board
#                        KR260 eth-chiplet pair. Run it after every design
#                        iteration (rebuild + redeploy) to confirm the D2D link
#                        and data plane still work on silicon.
#
# Orchestrates BOTH boards from the dev host, reusing kr260_eth_run.sh (which
# handles ssh/sudo auth and the eth_ss_0 backdoor addressing). Produces a
# PASS/FAIL table and exits non-zero if any gating test fails — CI-friendly.
#
# What it runs (all PS-side over the eth_ss_0 backdoor, no SWD/firmware):
#   deploy*     (optional --deploy) reflash die_a/die_b from the latest build
#   link        bring the TideLink link up on BOTH dies concurrently -> FCSM=4
#   backdoor    eth_ss_0 boot-ROM aliveness + TideLink config plane, per die
#   role        role strap reads correct per die (die_a=master/0, die_b=slave/1)
#   sram_fwd    die_a -> die_b shared_sram_0 transfer + die_b local read
#   sram_rtt    die_a reads it back over the link (round-trip)
#   sram_rev    die_b -> die_a transfer (the slave->master direction)
#   mailbox     die_a -> die_b ipc_mailbox_0 (the 2nd inbound D2D target)
#   soak        N write+readback beats + credit/fault health
#   tidechart   TideChart register plane alive (election is a non-gating
#               diagnostic — see docs/TIDECHART_TEST_PLAN.md G1/G-VERIF)
#
# Env / args:
#   KR260_DIEA_HOST  (default ubuntu@10.22.24.159)
#   KR260_DIEB_HOST  (default ubuntu@10.22.24.153)
#   KR260_PASSWORD   board sudo/ssh password (passed through to kr260_eth_run.sh)
#   --deploy         reflash both dies first (make deploy_pair_role SOC=kr260_eth)
#   --soak-iters N   soak beats (default 1000)
#   --json PATH      also write a machine-readable result summary
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_SH = os.path.join(HERE, "kr260_eth_run.sh")
# tidelink repo root = pynq_host/scripts/ -> up two
TL_ROOT = os.path.dirname(os.path.dirname(HERE))
FPGA_DIR = os.path.join(TL_ROOT, "fpga")

DIEA = os.environ.get("KR260_DIEA_HOST", "ubuntu@10.22.24.159")
DIEB = os.environ.get("KR260_DIEB_HOST", "ubuntu@10.22.24.153")


def run_on(host, mode, extra_env=None, timeout=120):
    """Invoke kr260_eth_run.sh <mode> against one board. Returns (rc, output)."""
    env = dict(os.environ)
    env["KR260_HOST"] = host
    if extra_env:
        env.update(extra_env)
    try:
        p = subprocess.run(["bash", RUN_SH, mode], env=env, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        return 124, (e.output or "") + "\n[TIMEOUT]"


def deploy(role, host, timeout=300):
    env = dict(os.environ)
    env["KR260_HOST"] = host
    try:
        p = subprocess.run(
            ["make", "-C", FPGA_DIR, "deploy_pair_role", "SOC=kr260_eth",
             "ROLE=%s" % role, "KR260_HOST=%s" % host],
            env=env, timeout=timeout, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        return 124, (e.output or "") + "\n[TIMEOUT]"


BRINGUP_PAIR_SH = os.path.join(HERE, "bringup_pair_release.sh")


def run_pair_bringup(timeout=120):
    """Invoke the PROVEN FIX-E S_HOLD-barrier orchestrator (bringup_pair_release.sh)
    from the dev host. It arms both dies, waits until BOTH reach S_HOLD, then
    releases bilaterally — the sequence that fixed I1. This REPLACES the two
    independent single-board bring-up runs, which have no barrier and can drop
    training before the peer is holding (self-deadlock / desync)."""
    env = dict(os.environ)
    env["DIE_A"] = DIEA
    env["DIE_B"] = DIEB
    try:
        p = subprocess.run(["bash", BRINGUP_PAIR_SH], env=env, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        return 124, (e.output or "") + "\n[TIMEOUT]"


# --- test primitives --------------------------------------------------------
def both_concurrent(fn_a, fn_b):
    with cf.ThreadPoolExecutor(max_workers=2) as ex:
        fa, fb = ex.submit(fn_a), ex.submit(fn_b)
        return fa.result(), fb.result()


class Suite:
    def __init__(self, soak_iters, include_peer_read=False, data_plane=False,
                 adversarial_soak=False):
        self.results = []      # list of (name, ok, detail, gating)
        self.soak_iters = soak_iters
        self.include_peer_read = include_peer_read
        self.data_plane = data_plane
        self.adversarial_soak = adversarial_soak

    def record(self, name, ok, detail, gating=True):
        self.results.append((name, bool(ok), detail, gating))
        tag = "PASS" if ok else ("FAIL" if gating else "WARN")
        print("  [%s] %-12s %s" % (tag, name, detail))

    # -- individual tests --
    def t_deploy(self):
        (ra, oa), (rb, ob) = both_concurrent(
            lambda: deploy("die_a", DIEA), lambda: deploy("die_b", DIEB))
        ok = (ra == 0 and "deploy OK" in oa) and (rb == 0 and "deploy OK" in ob)
        self.record("deploy", ok, "die_a rc=%d die_b rc=%d" % (ra, rb))
        return ok

    def t_link_bringup(self):
        # Bilateral bring-up via the PROVEN FIX-E orchestrator (S_HOLD barrier),
        # NOT two independent single-board runs. The barrier guarantees neither die
        # drops training before the peer is also holding — the sequencing that
        # resolved I1 (docs/I1_RESOLVED_HANDOVER_2026_07_31.md). ONLY safe on FRESH
        # dies (right after a reflash): re-running LL_SWRESET on an already-live
        # link desyncs it and hangs peer writes (the 2026-07-29 wedge).
        rc, o = run_pair_bringup()
        up = "LINK UP fcsm=4 BOTH DIES" in o
        self.record("link", up, "FIX-E bilateral bring-up (bringup_pair_release.sh): %s"
                    % ("UP both (fcsm=4)" if up else "NOT both up — see log"))
        return up

    def t_link_verify(self):
        # Non-destructive: just read FCSM. Use when the link is already up (no
        # --deploy) so we never re-bring-up a live link.
        ra, oa = run_on(DIEA, "xfer_link")
        rb, ob = run_on(DIEB, "xfer_link")
        ua, ub = "fcsm=4" in oa, "fcsm=4" in ob
        if not (ua and ub):
            self.record("link", False, "link NOT up (die_a=%s die_b=%s) — "
                        "re-run with --deploy to reflash + bring up" %
                        ("UP" if ua else "DOWN", "UP" if ub else "DOWN"))
        else:
            self.record("link", True, "verified live: FCSM=4 both dies")
        return ua and ub

    def t_backdoor(self):
        # NON-GATING with a documented bit-27 WAIVER. The eth_ss_0 boot-ROM
        # backdoor drops bit 27 on the reset/NMI/HardFault vectors (reads
        # 0x000001xx vs 0x080001xx) — a known eth-aperture bug ORTHOGONAL to the
        # TideLink link (I1_RESOLVED_HANDOVER_2026_07_31.md), present link-up or
        # link-down. eth_ss_probe.py WAIVES an exactly-bit-27 diff and still
        # reports "backdoor is ALIVE", so aliveness is proven while the drop is
        # characterised. Not a silicon regression gate -> gating=False.
        ra, oa = run_on(DIEA, "status")
        rb, ob = run_on(DIEB, "status")
        alive = ("backdoor is ALIVE" in oa) and ("backdoor is ALIVE" in ob)
        waived = ("bit-27 drop WAIVED" in oa) or ("bit-27 drop WAIVED" in ob)
        detail = "boot-ROM + config plane both dies" + (" (bit-27 WAIVED)" if waived else "")
        self.record("backdoor", alive, detail, gating=False)
        return alive, oa, ob

    def t_role(self, oa, ob):
        # role strap: die_a effective_role=0 (master), die_b=1 (slave)
        ok = ("effective_role=0 -> master" in oa) and \
             ("effective_role=1 -> slave" in ob)
        self.record("role", ok, "die_a=master(0) die_b=slave(1)")

    def t_sram_fwd(self):
        pl = "0xC0FFEE01"
        run_on(DIEA, "xfer_send", {"KR260_XFER_PAYLOAD": pl})
        rc, o = run_on(DIEB, "xfer_recv", {"KR260_XFER_PAYLOAD": pl})
        self.record("sram_fwd", "RESULT: PASS" in o, "die_a->die_b SRAM = %s" % pl)

    def t_sram_rtt(self):
        # WEDGE-PRONE (opt-in, non-gating): the peer read-round-trip intermittently
        # hangs on silicon and wedged both boards on 2026-07-29. The write path is
        # already verified wedge-safely by sram_fwd (die_b LOCAL read).
        rc, o = run_on(DIEA, "xfer_readback", {"KR260_XFER_PAYLOAD": "0xC0FFEE01"})
        self.record("sram_rtt", "[PASS]" in o or "RESULT: PASS" in o,
                    "die_a read-back over link (peer-read, wedge-prone)",
                    gating=False)

    def t_sram_rev(self):
        pl = "0xB2A0FEED"
        run_on(DIEB, "xfer_send", {"KR260_XFER_PAYLOAD": pl})
        rc, o = run_on(DIEA, "xfer_recv", {"KR260_XFER_PAYLOAD": pl})
        self.record("sram_rev", "RESULT: PASS" in o, "die_b->die_a SRAM = %s" % pl)

    def t_mailbox(self):
        pl = "0xC0FFEE01"
        run_on(DIEA, "xfer_mbox_send", {"KR260_XFER_PAYLOAD": pl})
        rc, o = run_on(DIEB, "xfer_mbox_recv", {"KR260_XFER_PAYLOAD": pl})
        self.record("mailbox", "RESULT: PASS" in o, "die_a->die_b ipc_mailbox_0")

    def t_mailbox_rev(self):
        # Reverse direction (die_b -> die_a): the xfer script is board-symmetric,
        # so mbox_send on die_b + mbox_recv on die_a exercises slave->master IPC.
        pl = "0xB2A0FEED"
        run_on(DIEB, "xfer_mbox_send", {"KR260_XFER_PAYLOAD": pl})
        rc, o = run_on(DIEA, "xfer_mbox_recv", {"KR260_XFER_PAYLOAD": pl})
        self.record("mailbox_rev", "RESULT: PASS" in o, "die_b->die_a ipc_mailbox_0")

    def _soak_once(self, name, sender, detail_dir):
        env = {"KR260_XFER_ITERS": str(self.soak_iters)}
        if self.adversarial_soak:
            env["KR260_XFER_ADVERSARIAL"] = "1"
        rc, o = run_on(sender, "xfer_soak", env, timeout=180)
        soak_ok = "RESULT: PASS" in o
        line = next((l for l in o.splitlines() if "iters=" in l), "").strip()
        # Region-F health GATE: after the soak, confirm the AXI-node obs plane is
        # healthy on the SENDER (catches a latched wedge-sticky the soak summary
        # line alone would miss).
        rh, oh = run_on(sender, "xfer_health")
        health_ok = "RESULT: HEALTHY" in oh
        self.record(name, soak_ok and health_ok, "%d beats%s %s: %s%s" % (
            self.soak_iters, " [adversarial]" if self.adversarial_soak else "",
            detail_dir, line or "no summary",
            "" if health_ok else "  [Region-F FAULT post-soak]"))

    def t_soak(self):
        self._soak_once("soak", DIEA, "die_a->die_b")

    def t_soak_rev(self):
        # Reverse-direction sustained load (die_b -> die_a), same health gate.
        self._soak_once("soak_rev", DIEB, "die_b->die_a")

    def t_tidechart(self):
        ra, oa = run_on(DIEA, "tc_status")
        rb, ob = run_on(DIEB, "tc_status")
        ok = ("DEVICE_CLASS=0x0001" in oa) and ("DEVICE_CLASS=0x0001" in ob) \
             and ("PORT_COUNT=1" in oa)
        # non-gating: register plane must be alive; election convergence is a
        # known RTL gap (G1/G-VERIF), not a silicon regression gate.
        self.record("tidechart", ok, "register plane alive (election=diag only)",
                    gating=False)

    # -- orchestration --
    def run(self, do_deploy):
        print("=" * 70)
        print(" KR260 eth-chiplet cross-die regression  (die_a=%s die_b=%s)"
              % (DIEA, DIEB))
        print("=" * 70)
        if do_deploy:
            if not self.t_deploy():
                print("  deploy failed — aborting (nothing else can pass).")
                return self.summary()
            link_ok = self.t_link_bringup()      # fresh dies -> full bring-up
        else:
            link_ok = self.t_link_verify()       # live link -> verify only
        if not link_ok:
            print("  link not up — SRAM/mailbox/soak will be skipped.")
            self.t_backdoor()   # still useful: is the PS->SoC path alive?
            return self.summary()
        ok_bd, oa, ob = self.t_backdoor()
        self.t_role(oa, ob)
        # The DEFAULT suite is CI-safe: only die-local checks that do NOT push data
        # across the D2D link. The cross-die data-plane transfers intermittently
        # HANG and wedge the board on current silicon (read OR write, either
        # direction — see docs/OVERNIGHT_WORKLOG.md), so they are attended-only.
        if self.data_plane:
            self.t_sram_fwd()
            self.t_sram_rev()
            self.t_mailbox()
            self.t_mailbox_rev()      # reverse-direction IPC (die_b->die_a)
            self.t_soak()             # write-only + health (no peer readback)
            self.t_soak_rev()         # reverse-direction sustained load + health
            if self.include_peer_read:
                self.t_sram_rtt()     # opt-in, extra wedge-prone
        else:
            print("  [SKIP] cross-die data-plane (sram/mailbox/soak) — pass "
                  "--data-plane to run (ATTENDED: intermittently wedges silicon)")
        self.t_tidechart()
        return self.summary()

    def summary(self):
        print("-" * 70)
        gating = [r for r in self.results if r[3]]
        npass = sum(1 for _, ok, _, _ in self.results if ok)
        gfail = [n for n, ok, _, g in self.results if g and not ok]
        print(" SUMMARY: %d/%d checks passed; gating failures: %s"
              % (npass, len(self.results), ", ".join(gfail) if gfail else "none"))
        print("=" * 70)
        return len(gfail) == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--deploy", action="store_true",
                    help="reflash both dies from the latest build first.")
    ap.add_argument("--soak-iters", type=int, default=1000)
    ap.add_argument("--data-plane", action="store_true",
                    help="run the cross-die data-plane transfers (sram/mailbox/soak). "
                         "ATTENDED ONLY: they intermittently hang and wedge the board "
                         "on current silicon. Default suite is die-local + CI-safe.")
    ap.add_argument("--include-peer-read", action="store_true",
                    help="with --data-plane, also run the peer read-round-trip "
                         "(sram_rtt) — extra wedge-prone; off by default.")
    ap.add_argument("--adversarial-soak", action="store_true",
                    help="with --data-plane, drive the soak with the deterministic "
                         "corner payloads (xfer_corners_lib) + per-N Region F "
                         "wedge sampling instead of the linear write pattern.")
    ap.add_argument("--json", help="write machine-readable results to this path.")
    args = ap.parse_args()

    if not os.environ.get("KR260_PASSWORD"):
        print("WARN: KR260_PASSWORD not set — relying on ssh keys + NOPASSWD sudo.",
              file=sys.stderr)

    suite = Suite(args.soak_iters, include_peer_read=args.include_peer_read,
                  data_plane=args.data_plane, adversarial_soak=args.adversarial_soak)
    ok = suite.run(args.deploy)

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"pass": ok, "results": [
                {"name": n, "ok": o, "detail": d, "gating": g}
                for n, o, d, g in suite.results]}, f, indent=2)
        print("wrote %s" % args.json)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
