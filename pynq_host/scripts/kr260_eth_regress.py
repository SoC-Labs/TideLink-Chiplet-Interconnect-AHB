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
#   provenance  board ~/td/scripts/eth_sysval_board.py sha256 == repo (HYGIENE-2,
#               runs FIRST; a mismatch is gating AND aborts the data plane)
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
#   KR260_PASSWORD   board sudo/ssh password (passed through to kr260_eth_run.sh;
#                    also used by the direct-ssh provenance + interlock gates)
#   --deploy         reflash both dies first (make deploy_pair_role SOC=kr260_eth)
#   --soak-iters N   soak beats (default 1000)
#   --config-only    HYGIENE-1: skip the cross-die data plane (ON by default). A
#                    bare run drives the WEDGE-SAFE transfers behind a FCSM=4 +
#                    Region-F safety interlock; no delivery witness -> the top-line
#                    is CONFIG-ONLY (delivery UNPROVEN), never a bare green.
#   --include-peer-read  also run the wedge-prone peer read-round-trip (opt-in)
#   --json PATH      also write a machine-readable result summary
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import shlex
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

# HYGIENE-2 provenance + HYGIENE-1 interlock: the board-side sysval helper whose
# sha256 we pin, and the marker-gated obs plane (0x21E0/0x21E8/0x2108) it reads for
# the safety interlock. Both gates reach the board via direct ssh (below), NOT
# through kr260_eth_run.sh (which has no mode for eth_sysval_board.py).
BOARD_SYSVAL_REMOTE = "~/td/scripts/eth_sysval_board.py"
LOCAL_SYSVAL = os.path.join(HERE, "eth_sysval_board.py")


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


# --- direct board ssh (for the RO provenance + interlock gates only) ---------
# kr260_eth_run.sh has no mode for eth_sysval_board.py, so the HYGIENE-2 provenance
# gate and the HYGIENE-1 safety interlock reach the board directly. Auth mirrors
# kr260_eth_run.sh: sshpass -e (SSHPASS from env, NEVER in argv) when KR260_PASSWORD
# is set + sshpass is present, else key auth (BatchMode); on-board root via sudo -S
# with the password on stdin.
_HAVE_SSHPASS = None


def have_sshpass():
    global _HAVE_SSHPASS
    if _HAVE_SSHPASS is None:
        _HAVE_SSHPASS = subprocess.run(
            ["bash", "-c", "command -v sshpass"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    return _HAVE_SSHPASS


def ssh_capture(host, remote_cmd, timeout=20):
    """Run remote_cmd on a board (host='user@ip') over ssh. Returns
    (rc, combined_output); rc=124 on timeout (a hung RO access == an unreachable or
    wedged board)."""
    pw = os.environ.get("KR260_PASSWORD", "")
    opts = ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15"]
    env = dict(os.environ)
    if pw and have_sshpass():
        env["SSHPASS"] = pw
        cmd = ["sshpass", "-e", "ssh"] + opts + [host, remote_cmd]
    else:
        cmd = ["ssh", "-o", "BatchMode=yes"] + opts + [host, remote_cmd]
    try:
        p = subprocess.run(cmd, env=env, timeout=timeout, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        return 124, (e.output or "") + "\n[TIMEOUT]"


def board_obs(host, timeout=25):
    """Read eth_sysval_board.py `obs` (marker-gated Region-F / eye / fcsm JSON) as
    root on a board. RO config-plane read -> wedge-safe. Returns the decoded dict,
    or None if the read failed / could not be parsed. NB: the board path uses ~ so
    it must be expanded by the LOGIN shell before sudo — do NOT wrap in `bash -c`
    (that re-expands ~ under root's home). Password goes in on stdin (sudo -S)."""
    pw = os.environ.get("KR260_PASSWORD", "")
    if pw:
        remote = "echo %s | sudo -S python3 %s obs" % (
            shlex.quote(pw), BOARD_SYSVAL_REMOTE)
    else:
        remote = "sudo -n python3 %s obs" % BOARD_SYSVAL_REMOTE
    rc, out = ssh_capture(host, remote, timeout)
    for ln in out.splitlines():
        ln = ln.strip()
        if ln.startswith("{"):
            try:
                return json.loads(ln)
            except Exception:
                pass
    return None


def regf_healthy(o):
    """HYGIENE-1 interlock + CC-3 predicate. A die is safe to drive iff FCSM=4,
    calibrated, the Region-F marker 0xAD is PRESENT (regf_present), data_healthy=1,
    and no wedge-sticky on either side. Marker ABSENT (obs plane not in the
    bitstream) => NOT healthy — never green on a missing obs plane (CC-3)."""
    if not o:
        return False
    if o.get("fcsm") != 4 or o.get("cal") != 1:
        return False
    if not o.get("regf_present"):
        return False
    if o.get("data_healthy") != 1:
        return False
    if (o.get("wedge_tgt") or 0) != 0 or (o.get("wedge_ini") or 0) != 0:
        return False
    return True


class Suite:
    def __init__(self, soak_iters, include_peer_read=False, config_only=False,
                 adversarial_soak=False):
        self.results = []      # list of (name, ok, detail, gating)
        self.soak_iters = soak_iters
        self.include_peer_read = include_peer_read
        # HYGIENE-1: the data plane is ON by default now; --config-only opts out.
        self.config_only = config_only        # operator explicitly asked config-only
        self.data_plane = not config_only      # attempt the data plane unless told not to
        self.downgraded = False                # interlock/provenance forced config-only
        self.adversarial_soak = adversarial_soak
        # HYGIENE-3: names of die-local reads that PROVED bytes landed. A bare green
        # top-line requires >=1 of these; else CONFIG-ONLY (delivery UNPROVEN).
        self.delivery_witnesses = []
        self.provenance_ok = None              # HYGIENE-2 gate result

    def record(self, name, ok, detail, gating=True, delivery=False):
        self.results.append((name, bool(ok), detail, gating))
        tag = "PASS" if ok else ("FAIL" if gating else "WARN")
        print("  [%s] %-12s %s" % (tag, name, detail))
        # HYGIENE-3: a passing die-local delivery test (bytes moved AND verified by
        # a local read) is the ONLY thing that lets the summary print a bare green.
        if ok and delivery:
            self.delivery_witnesses.append(name)

    # -- HYGIENE-2 provenance gate (runs FIRST, RO ssh+sha256, cannot wedge) --
    def t_provenance(self):
        """Compare the board-side ~/td/scripts/eth_sysval_board.py sha256 against
        the repo copy on BOTH dies. Board-side script drift is the confirmed cause
        of the 'verify prints nothing' false result, so a mismatch makes every
        downstream delivery verdict untrustworthy -> a FAIL here is gating (non-zero
        exit) AND aborts the data plane (run() downgrades to config-only). Pure ssh
        + sha256: RO, cannot wedge. Runs before t_link_* so a stale board is caught
        before any traffic."""
        try:
            want = hashlib.sha256(open(LOCAL_SYSVAL, "rb").read()).hexdigest()
        except OSError as e:
            self.provenance_ok = False
            self.record("provenance", False,
                        "repo eth_sysval_board.py unreadable: %s" % e)
            return False
        drift = []
        for host, tag in ((DIEA, "die_a"), (DIEB, "die_b")):
            rc, out = ssh_capture(
                host, "sha256sum %s 2>/dev/null | cut -d' ' -f1"
                % BOARD_SYSVAL_REMOTE, 20)
            got = ""
            for tok in out.split():
                if len(tok) == 64 and all(c in "0123456789abcdef" for c in tok):
                    got = tok
                    break
            if got != want:
                drift.append("%s(board=%s repo=%s)"
                             % (tag, got[:12] if got else "MISSING", want[:12]))
        self.provenance_ok = not drift
        self.record("provenance", self.provenance_ok,
                    "eth_sysval_board.py board==repo both dies" if self.provenance_ok
                    else "STALE/MISSING -> " + "; ".join(drift))
        return self.provenance_ok

    # -- HYGIENE-1 data-plane safety interlock (RO obs, cannot wedge) --
    def t_dataplane_interlock(self):
        """Mandatory before ANY peer traffic: require FCSM=4 on both dies (already
        established by t_link_*) AND a Region-F health check on both (marker 0xAD
        present + data_healthy, no wedge-sticky) via the marker-gated obs plane.
        Returns True iff both dies are data-plane-safe; a False result makes run()
        AUTO-DOWNGRADE to config-only with a loud warn — never traffic onto a
        marginal/unhealthy link, never a silent green."""
        oa, ob = board_obs(DIEA), board_obs(DIEB)
        ha, hb = regf_healthy(oa), regf_healthy(ob)
        for tag, o, h in (("die_a", oa, ha), ("die_b", ob, hb)):
            if not o:
                print("    %s obs UNREADABLE (RO read failed/timeout)" % tag)
            else:
                print("    %s fcsm=%s cal=%s regf_present=%s data_healthy=%s "
                      "wedge_tgt=%s wedge_ini=%s -> %s"
                      % (tag, o.get("fcsm"), o.get("cal"), o.get("regf_present"),
                         o.get("data_healthy"), o.get("wedge_tgt"),
                         o.get("wedge_ini"), "HEALTHY" if h else "UNHEALTHY"))
        ok = ha and hb
        # NON-gating: the interlock is a SAFETY gate, not a test — its verdict is
        # surfaced via the top-line CONFIG-ONLY downgrade, not as a gating failure.
        self.record("interlock", ok,
                    "FCSM=4 + Region-F healthy both dies (marker 0xAD + data_healthy)"
                    if ok else "link NOT data-plane-safe -> AUTO-DOWNGRADE",
                    gating=False)
        return ok

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
        self.record("sram_fwd", "RESULT: PASS" in o, "die_a->die_b SRAM = %s" % pl,
                    delivery=True)   # die_b LOCAL read == a delivery witness (HYGIENE-3)

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
        self.record("sram_rev", "RESULT: PASS" in o, "die_b->die_a SRAM = %s" % pl,
                    delivery=True)   # die_a LOCAL read == a delivery witness (HYGIENE-3)

    def t_mailbox(self):
        pl = "0xC0FFEE01"
        run_on(DIEA, "xfer_mbox_send", {"KR260_XFER_PAYLOAD": pl})
        rc, o = run_on(DIEB, "xfer_mbox_recv", {"KR260_XFER_PAYLOAD": pl})
        self.record("mailbox", "RESULT: PASS" in o, "die_a->die_b ipc_mailbox_0",
                    delivery=True)   # die_b LOCAL mbox_recv == a delivery witness (HYGIENE-3)

    def t_mailbox_rev(self):
        # Reverse direction (die_b -> die_a): the xfer script is board-symmetric,
        # so mbox_send on die_b + mbox_recv on die_a exercises slave->master IPC.
        pl = "0xB2A0FEED"
        run_on(DIEB, "xfer_mbox_send", {"KR260_XFER_PAYLOAD": pl})
        rc, o = run_on(DIEA, "xfer_mbox_recv", {"KR260_XFER_PAYLOAD": pl})
        self.record("mailbox_rev", "RESULT: PASS" in o, "die_b->die_a ipc_mailbox_0",
                    delivery=True)   # die_a LOCAL mbox_recv == a delivery witness (HYGIENE-3)

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
        # CC-3 / item 5: health_snapshot's "RESULT: HEALTHY" goes green even when the
        # Region-F marker 0xAD is ABSENT (its predicate is `not present or ...`), so
        # AND regf_present in explicitly. health_snapshot prints "marker=0xAD" only
        # when the obs plane is actually in the bitstream.
        regf_present = "marker=0xAD" in oh
        health_ok = ("RESULT: HEALTHY" in oh) and regf_present
        self.record(name, soak_ok and health_ok, "%d beats%s %s: %s%s" % (
            self.soak_iters, " [adversarial]" if self.adversarial_soak else "",
            detail_dir, line or "no summary",
            "" if health_ok else
            ("  [Region-F marker 0xAD ABSENT]" if not regf_present
             else "  [Region-F FAULT post-soak]")))

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
        # HYGIENE-2: script-provenance gate FIRST, before the link tests. A stale or
        # missing board-side eth_sysval_board.py makes every delivery verdict a lie;
        # a FAIL here is gating (non-zero exit) AND aborts the data plane.
        self.t_provenance()
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
        # HYGIENE-1: the data plane is ON by default now. Only WEDGE-SAFE transfers
        # (die-local-verify writes + IPC) run by default; the wedge-prone peer read
        # stays behind --include-peer-read. Before ANY peer traffic BOTH interlocks
        # must hold:
        #   (1) provenance PASS — board helpers match the repo, and
        #   (2) FCSM=4 + Region-F health on both dies (t_dataplane_interlock).
        # Either failing AUTO-DOWNGRADES to config-only with a loud warn — never a
        # silent green, never traffic onto a bad/marginal link.
        if not self.data_plane:
            print("  [CONFIG-ONLY] --config-only: cross-die data plane skipped. "
                  "Delivery UNPROVEN (see top-line).")
        elif not self.provenance_ok:
            self.downgraded = True
            self._warn_downgrade(
                "script-provenance FAILED — board eth_sysval_board.py != repo. "
                "Delivery verdicts would be untrustworthy; refusing the data plane.")
        elif not self.t_dataplane_interlock():
            self.downgraded = True
            self._warn_downgrade(
                "data-plane SAFETY INTERLOCK FAILED — not FCSM=4 + Region-F healthy "
                "on both dies. Refusing to drive traffic onto a marginal link.")
        else:
            self.t_sram_fwd()
            self.t_sram_rev()
            self.t_mailbox()
            self.t_mailbox_rev()      # reverse-direction IPC (die_b->die_a)
            self.t_soak()             # write-only + health (no peer readback)
            self.t_soak_rev()         # reverse-direction sustained load + health
            if self.include_peer_read:
                self.t_sram_rtt()     # opt-in, extra wedge-prone
        self.t_tidechart()
        return self.summary()

    def _warn_downgrade(self, why):
        """Loud, un-missable auto-downgrade banner (HYGIENE-1: never a silent green)."""
        bar = "!" * 66
        print("  " + bar)
        print("  !! WARN: AUTO-DOWNGRADE to CONFIG-ONLY (delivery will be UNPROVEN).")
        print("  !!       %s" % why)
        print("  " + bar)

    def summary(self):
        print("-" * 70)
        npass = sum(1 for _, ok, _, _ in self.results if ok)
        gfail = [n for n, ok, _, g in self.results if g and not ok]
        witnessed = len(self.delivery_witnesses) >= 1
        print(" SUMMARY: %d/%d checks passed; gating failures: %s"
              % (npass, len(self.results), ", ".join(gfail) if gfail else "none"))
        # HYGIENE-3 delivery-interlock: a bare green REQUIRES >=1 die-local delivery
        # witness (bytes moved AND verified by a local read). No witness -> the
        # top-line is CONFIG-ONLY (delivery UNPROVEN), never a bare green.
        if witnessed:
            print(" delivery witnesses: %s (bytes moved AND die-local verified)"
                  % ", ".join(self.delivery_witnesses))
        else:
            print(" delivery witnesses: NONE — no die-local read proved bytes landed")
        if gfail:
            top, ok = "FAIL (gating: %s)" % ", ".join(gfail), False
        elif witnessed:
            top, ok = "PASS", True
        else:
            top = "CONFIG-ONLY (delivery UNPROVEN)"
            # Honest exit: green (0) ONLY for an explicitly-requested config-only run
            # that hit no gating failure. A default-mode run that moved zero bytes —
            # skipped or auto-downgraded onto a bad link — is NOT green.
            ok = self.config_only and not self.downgraded
        print(" TOP-LINE: %s" % top)
        print("=" * 70)
        return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--deploy", action="store_true",
                    help="reflash both dies from the latest build first.")
    ap.add_argument("--soak-iters", type=int, default=1000)
    ap.add_argument("--config-only", action="store_true",
                    help="run ONLY the die-local config plane (link/backdoor/role/"
                         "tidechart); skip ALL cross-die data-plane traffic. HYGIENE-1: "
                         "the data plane is ON by default now — a bare run drives the "
                         "WEDGE-SAFE transfers (die-local-verify writes + IPC) behind a "
                         "FCSM=4 + Region-F safety interlock. --config-only reports "
                         "CONFIG-ONLY (delivery UNPROVEN), never a bare green.")
    ap.add_argument("--include-peer-read", action="store_true",
                    help="also run the peer read-round-trip (sram_rtt) — extra "
                         "wedge-prone; OFF by default even with the data plane on.")
    ap.add_argument("--adversarial-soak", action="store_true",
                    help="drive the soak with the deterministic corner payloads "
                         "(xfer_corners_lib) + per-N Region F wedge sampling instead of "
                         "the linear write pattern (ignored under --config-only).")
    ap.add_argument("--json", help="write machine-readable results to this path.")
    args = ap.parse_args()

    if not os.environ.get("KR260_PASSWORD"):
        print("WARN: KR260_PASSWORD not set — relying on ssh keys + NOPASSWD sudo.",
              file=sys.stderr)

    suite = Suite(args.soak_iters, include_peer_read=args.include_peer_read,
                  config_only=args.config_only, adversarial_soak=args.adversarial_soak)
    ok = suite.run(args.deploy)

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"pass": ok,
                       "delivery_witnesses": suite.delivery_witnesses,
                       "config_only": suite.config_only,
                       "downgraded": suite.downgraded,
                       "results": [
                           {"name": n, "ok": o, "detail": d, "gating": g}
                           for n, o, d, g in suite.results]}, f, indent=2)
        print("wrote %s" % args.json)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
