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


# --- test primitives --------------------------------------------------------
def both_concurrent(fn_a, fn_b):
    with cf.ThreadPoolExecutor(max_workers=2) as ex:
        fa, fb = ex.submit(fn_a), ex.submit(fn_b)
        return fa.result(), fb.result()


class Suite:
    def __init__(self, soak_iters):
        self.results = []      # list of (name, ok, detail, gating)
        self.soak_iters = soak_iters

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
        # Full concurrent bring-up — ONLY safe on FRESH dies (right after a
        # reflash). Re-running to_data_mode (LL_SWRESET) on an already-live link
        # desyncs it and hangs the sender's peer writes — the "never PL-reload one
        # side of a live link" hazard that wedged die_a on 2026-07-29.
        (ra, oa), (rb, ob) = both_concurrent(
            lambda: run_on(DIEA, "bringup", {"KR260_ETH_ROLE": "die_a"}),
            lambda: run_on(DIEB, "bringup", {"KR260_ETH_ROLE": "die_b"}))
        ua, ub = "LINK UP" in oa, "LINK UP" in ob
        self.record("link", ua and ub, "brought up fresh: die_a=%s die_b=%s" %
                    ("UP" if ua else "DOWN", "UP" if ub else "DOWN"))
        return ua and ub

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
        ra, oa = run_on(DIEA, "status")
        rb, ob = run_on(DIEB, "status")
        ok = ("backdoor is ALIVE" in oa) and ("backdoor is ALIVE" in ob)
        self.record("backdoor", ok, "boot-ROM + config plane both dies")
        return ok, oa, ob

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
        rc, o = run_on(DIEA, "xfer_readback", {"KR260_XFER_PAYLOAD": "0xC0FFEE01"})
        self.record("sram_rtt", "[PASS]" in o or "RESULT: PASS" in o,
                    "die_a read-back over link")

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

    def t_soak(self):
        rc, o = run_on(DIEA, "xfer_soak",
                      {"KR260_XFER_ITERS": str(self.soak_iters)}, timeout=180)
        line = next((l for l in o.splitlines() if "iters=" in l), "").strip()
        self.record("soak", "RESULT: PASS" in o,
                    "%d beats: %s" % (self.soak_iters, line or "no summary"))

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
        self.t_sram_fwd()
        self.t_sram_rtt()
        self.t_sram_rev()
        self.t_mailbox()
        self.t_soak()
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
    ap.add_argument("--json", help="write machine-readable results to this path.")
    args = ap.parse_args()

    if not os.environ.get("KR260_PASSWORD"):
        print("WARN: KR260_PASSWORD not set — relying on ssh keys + NOPASSWD sudo.",
              file=sys.stderr)

    suite = Suite(args.soak_iters)
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
