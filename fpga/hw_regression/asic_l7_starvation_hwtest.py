#!/usr/bin/env python3
"""asic_l7_starvation_hwtest.py - host-side driver for the AXI FC-node
state-7 (SEND_NACK) emit-starvation recovery question, on a KR260 running the
kr260-pair-onchip image.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors

David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)

===========================================================================
STATUS: WRITTEN, NEVER RUN. No board has executed this file.
===========================================================================

WHAT QUESTION THIS ASKS
-----------------------
cocotb/tidelink_top_pair_v2/test_asic_l7_starvation_backstop.py proves in
simulation that the AW flow-control node, parked in state 7 with
auto_tx_out_advance forced 0, LEAVES state 7 on the FPGA file set (the
TL-033 watchdog forces the exit at src/rtl/local_overrides/WlinkGenericFCSM.v
:426) and NEVER leaves it on the file set that tapes out
(deps/.../WlinkGenericFCSM.v:315 has only the auto_tx_out_advance term).
This asks the same question of an image built from the tapeout sources.

WHAT THIS CANNOT DO, STATED UP FRONT
------------------------------------
It cannot read state. Verified on the RTL of this branch, not assumed:

  * Neither file-set copy of WlinkGenericFCSM{,_1.._4} declares ANY io_obs_*
    port, so the five divergent AXI nodes publish nothing.
  * The one FCSM state on APB, 0x2108[19:17], comes from Wlink.v:1951
    .io_obs_fcsm_state(...) on the `tl2wl` instance = TideLinkToWlink ->
    WlinkGenericFCSM_6, which BOTH flists take from src/rtl/local_overrides
    (130 socl_ hits, watchdog included). The one readable FCSM state is the
    one FCSM that does not diverge.

So there is no register that says "state 7", and there is no Force/Release on
silicon. This test is BEHAVIOURAL: it induces the condition by a documented
natural route, then asks whether the AXI data path CAME BACK.

  RECOVERY OBSERVED  a wedge signature was seen AND the path resumed
  WEDGE OBSERVED     a wedge signature was seen AND it never cleared
  COULD NOT EVALUATE anything else - including "the stimulus never produced
                     a wedge signature", which is NOT a pass

The middle outcome is the one this image exists to look for. The third is a
real and likely outcome and is reported as itself; "natural-cause induction
is a characterised dead end on kr260-pair-onchip" is already on the record
for the neighbouring TL-042 awready work, and this test must not launder a
non-event into a green.

HOW THE CONDITION IS INDUCED
----------------------------
The five AXI nodes ship with CRC checking DISABLED
(out_prepend_swi_disable_crc reset 1). Clearing FC_SM_CONTROL[16] on a node
arms the NACK/replay path. The ONE time an enabled CRC ran on a live link
(2026-06-14, Z2 pair) it saturated crc_errors and parked the FCSM in
SEND_NACK - the 2026-07-21 root cause concluded that was the CRC correctly
catching real corruption on a marginal eye, not a false fire
(pynq_host/scripts/kr260_eth_bringup.py:113-124, docs/CRC_ROOTCAUSE.md:267).
That is the only documented natural route to state 7 on hardware, so it is
the route used here - and because it is not free, it is OPT-IN
(--arm-crc plus --i-accept-nack-arming) and the default mode reads only.

WHAT IS OBSERVED
----------------
0x21E0 OBS_AXI_NODES [19:15]/[14:10] wedge-sticky per channel (a channel
stalled >= 2**12 app_clk: tidelink_axinode_obs.sv:38-44, "a genuine wedge,
not congestion") and [23] data_nodes_healthy; 0x21EC FCEMIT_STAT sop_seen vs
grant_seen ("presented but never granted" = the emit-starvation signature).
Both are marker-gated (0xAD / 0xE1) and an absent marker routes to
COULD NOT EVALUATE, never to a verdict.

TRANSPORT
---------
ONE ssh ControlMaster connection for the whole run, per
pynq_host/scripts/kr260_sysval.py:109-134 - that is the actual fix for the
sshd MaxStartups resets that produced a corpus of phantom read failures on
2026-08-24, not merely a way to classify them. Every board command must
return the marker key "tl_asic_l7"; a command that did not produce it did not
run, whatever its exit code, and cannot contribute to a verdict.

EXIT CODES (mirroring pynq_host/scripts/kr260_sysval.py:614-616)
  0  RECOVERY OBSERVED
  1  WEDGE OBSERVED           <- the finding this image was built to look for
  2  aborted before any measurement (preflight refused)
  3  COULD NOT EVALUATE

USAGE
  ./asic_l7_starvation_hwtest.py --host kr260-01 [--json-out r.json]
  ./asic_l7_starvation_hwtest.py --host kr260-01 --arm-crc AW \
        --i-accept-nack-arming
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

MARKER_KEY = "tl_asic_l7"
AGENT_LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "asic_l7_board_agent.py")
AGENT_REMOTE = "/tmp/asic_l7_board_agent.py"

RECOVERY, WEDGE, INCONCLUSIVE, ABORTED = \
    "RECOVERY_OBSERVED", "WEDGE_OBSERVED", "COULD_NOT_EVALUATE", "ABORTED"

OK, TIMEOUT, TRANSPORT_ERROR, RAN = "OK", "TIMEOUT", "TRANSPORT_ERROR", "RAN"

_TRANSPORT_RE = re.compile(
    r"kex_exchange_identification|ssh_exchange_identification|"
    r"Connection reset|Connection closed by|Connection refused|Connection timed out|"
    r"No route to host|Network is unreachable|Broken pipe|"
    r"Host key verification failed|Permission denied \(|"
    r"Too many authentication failures|not responding|"
    r"Control socket connect|ControlPath|closed by remote host", re.I)


# ---------------------------------------------------------------------------
# Transport: ONE ControlMaster for the whole run.
# ---------------------------------------------------------------------------
class Ssh(object):
    def __init__(self, host, user, password, persist=120, retries=3):
        self.host, self.user, self.password = host, user, password
        self.persist, self.retries = persist, retries
        self._cm_dir = None

    def cm_dir(self):
        if self._cm_dir is None:
            # Short path: unix sockets cap near 104 bytes and %C is a hash.
            d = os.path.join(tempfile.gettempdir(), ".tl_asicl7_cm_%d" % os.getuid())
            try:
                os.makedirs(d, mode=0o700, exist_ok=True)
                self._cm_dir = d
            except Exception:
                self._cm_dir = ""
        return self._cm_dir or None

    def base(self):
        o = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
             "-o", "ConnectTimeout=10"]
        d = self.cm_dir()
        if d:
            o += ["-o", "ControlMaster=auto",
                  "-o", "ControlPath=%s/%%C" % d,
                  "-o", "ControlPersist=%d" % self.persist]
        return o

    def close_master(self):
        d = self.cm_dir()
        if not d:
            return
        try:
            subprocess.run(self.base() + ["-O", "exit",
                                          "%s@%s" % (self.user, self.host)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=15)
        except Exception:
            pass

    def run(self, cmd, timeout=45, marker=None):
        """Run cmd; classify; retry ONLY transport failures.

        Timeouts are deliberately NOT retried: on this project a board timeout
        means a wedged DUT, which is the single most important signal this
        harness can produce. Retrying it would paper over the finding."""
        argv = self.base() + ["%s@%s" % (self.user, self.host), cmd]
        attempts, last = 0, None
        for attempt in range(self.retries + 1):
            attempts += 1
            try:
                p = subprocess.run(argv, capture_output=True, timeout=timeout)
                rc, out, err = p.returncode, p.stdout.decode("utf-8", "replace"), \
                    p.stderr.decode("utf-8", "replace")
            except subprocess.TimeoutExpired:
                rc, out, err = 124, "", "local wall clock %.0fs expired" % timeout
            kind = self.classify(rc, out, err, marker)
            last = Res(rc, out, err, kind, attempts, self.host, cmd)
            if kind != TRANSPORT_ERROR:
                return last
            time.sleep(1.0 * (attempt + 1))
        return last

    @staticmethod
    def classify(rc, out, err, marker=None):
        """Proof of execution beats any transport guess: if the board's own
        marker is in stdout then the command RAN, whatever the exit code."""
        if rc == 124:
            return TIMEOUT
        if marker and marker in (out or ""):
            return OK if rc == 0 else RAN
        if rc == 0:
            return OK
        if rc == 255 or _TRANSPORT_RE.search(err or ""):
            return TRANSPORT_ERROR
        return RAN


class Res(object):
    __slots__ = ("rc", "out", "err", "kind", "attempts", "host", "cmd")

    def __init__(self, rc, out, err, kind, attempts, host, cmd):
        self.rc, self.out, self.err = rc, out, err
        self.kind, self.attempts, self.host, self.cmd = kind, attempts, host, cmd

    @property
    def reached_board(self):
        return self.kind in (OK, RAN)

    def json(self):
        """The board's one marker-bearing JSON line, or None.

        None here means NO RESULT. It never means 'nothing was wrong'."""
        for line in (self.out or "").splitlines():
            line = line.strip()
            if not line.startswith("{") or MARKER_KEY not in line:
                continue
            try:
                return json.loads(line)
            except Exception:
                return None
        return None

    def describe(self):
        s = "rc=%d kind=%s attempts=%d" % (self.rc, self.kind, self.attempts)
        if not (self.out or self.err):
            s += "  <no stdout and no stderr - the command did not run>"
        return s


# ---------------------------------------------------------------------------
# Verdict accumulator
# ---------------------------------------------------------------------------
class Report(object):
    def __init__(self):
        self.steps = []
        self.verdict = None
        self.why = ""

    def step(self, name, state, detail="", data=None):
        rec = {"step": name, "state": state, "detail": detail}
        if data is not None:
            rec["data"] = data
        self.steps.append(rec)
        print("  [%-12s] %-28s %s" % (state, name, detail))
        return rec

    def settle(self, verdict, why):
        self.verdict, self.why = verdict, why
        print("")
        print("=" * 72)
        print("  VERDICT: %s" % verdict)
        print("  %s" % why)
        print("=" * 72)


def board(sh, agent_args, timeout=60):
    cmd = ("echo %s | sudo -S -p '' python3 %s %s" %
           (sh.password, AGENT_REMOTE, agent_args))
    return sh.run(cmd, timeout=timeout, marker=MARKER_KEY)


def stage_agent(sh, rep):
    if not os.path.isfile(AGENT_LOCAL):
        rep.step("stage-agent", "ABORT", "missing %s" % AGENT_LOCAL)
        return False
    with open(AGENT_LOCAL, "rb") as f:
        body = f.read()
    argv = sh.base() + ["%s@%s" % (sh.user, sh.host), "cat > %s" % AGENT_REMOTE]
    try:
        p = subprocess.run(argv, input=body, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        rep.step("stage-agent", "ABORT", "timed out staging the agent")
        return False
    if p.returncode != 0:
        rep.step("stage-agent", "ABORT",
                 "rc=%d %s" % (p.returncode, p.stderr.decode("utf-8", "replace")[:200]))
        return False
    # Prove the staged copy runs AND emits the marker. An agent that stages
    # but cannot execute would otherwise turn every later read into a silent
    # "no data" that reads like "nothing wrong".
    r = board(sh, "obs", timeout=45)
    if not r.reached_board or r.json() is None:
        rep.step("stage-agent", "ABORT",
                 "staged agent produced no marker (%s)" % r.describe())
        return False
    rep.step("stage-agent", "ok", "agent live at %s" % AGENT_REMOTE)
    return True


def preflight(sh, rep):
    """Verify the INSTRUMENT before the DUT.

    Returns (ok, selftest_json). Anything short of a fully proven instrument
    means COULD NOT EVALUATE - a missing marker must never become a verdict
    about the design."""
    r = board(sh, "selftest", timeout=60)
    js = r.json()
    if js is None:
        rep.step("preflight", "NO-RESULT",
                 "selftest returned no marker (%s)" % r.describe())
        return False, None
    if js.get("reader_dead"):
        rep.step("preflight", "NO-RESULT",
                 "reader dead: every observability word read all-0/all-1, so "
                 "every 'bit clear' below would be vacuous")
        return False, js
    if js.get("missing_markers"):
        rep.step("preflight", "NO-RESULT",
                 "presence markers absent: %s" % "; ".join(js["missing_markers"]))
        return False, js
    a, b = js["die_a"], js["die_b"]
    if not (a["link_ok"] and b["link_ok"]):
        rep.step("preflight", "ABORT",
                 "link not up (die_a cal=%d fcsm6=%d, die_b cal=%d fcsm6=%d) - "
                 "refusing to touch ahb_sub" %
                 (a["status"]["cal_done"], a["status"]["fcsm6"],
                  b["status"]["cal_done"], b["status"]["fcsm6"]))
        return False, js
    rep.step("preflight", "ok",
             "markers present; link up both dies; healthy a=%d b=%d" %
             (a["axi_nodes"]["data_nodes_healthy"],
              b["axi_nodes"]["data_nodes_healthy"]), js)
    return True, js


def wedge_signature(die_json):
    """The positive marker this test requires before it will call ANYTHING a
    result: a sticky wedge bit, or health cleared, or a node that presented a
    packet and was never granted an emit."""
    an, fe = die_json["axi_nodes"], die_json["fcemit"]
    if not (an["present"] and fe["present"]):
        return None
    sig = {
        "wedge_any": an["wedge_any"],
        "unhealthy": int(an["data_nodes_healthy"] == 0),
        "starved_any": fe["starved_any"],
        "tgt_wedge": an["tgt_wedge"], "ini_wedge": an["ini_wedge"],
        "starved": fe["starved"],
    }
    sig["present"] = int(sig["wedge_any"] or sig["unhealthy"] or sig["starved_any"])
    return sig


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True, help="KR260 hostname or IP")
    ap.add_argument("--user", default="ubuntu")
    ap.add_argument("--password", default=os.environ.get("TD_BOARD_PW", "xilinx"))
    ap.add_argument("--words", type=int, default=256,
                    help="cross-die words per traffic burst")
    ap.add_argument("--offset", default="0x00001000",
                    help="byte offset into the peer window")
    ap.add_argument("--burst-timeout", type=float, default=10.0,
                    help="wall clock for ONE ahb_sub burst; exceeding it IS "
                         "the wedge observation")
    ap.add_argument("--recovery-window", type=float, default=20.0,
                    help="seconds to keep re-probing after a wedge signature "
                         "before calling it permanent. The TL-033 watchdog "
                         "fires at 16384 io_tx_clk (~164us at 100 MHz), so "
                         "this is ~5 orders of magnitude of margin")
    ap.add_argument("--arm-crc", default="",
                    help="node to arm CRC checking on (AW|W|B|AR|R). NOT FREE: "
                         "arms the NACK/replay path")
    ap.add_argument("--i-accept-nack-arming", action="store_true",
                    help="required alongside --arm-crc")
    ap.add_argument("--json-out", default="")
    args = ap.parse_args()

    if args.arm_crc and not args.i_accept_nack_arming:
        print("REFUSED: --arm-crc arms the NACK/replay path on a live link. "
              "The one time an enabled CRC ran on a live link it saturated "
              "crc_errors and parked the FCSM in SEND_NACK. Pass "
              "--i-accept-nack-arming if that is what you want.", file=sys.stderr)
        return 2

    rep = Report()
    sh = Ssh(args.host, args.user, args.password)
    result = {"host": args.host, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                          time.gmtime())}
    try:
        print("== ASIC file-set L7 starvation recovery probe ==")
        print("   host=%s  words=%d  recovery-window=%.1fs" %
              (args.host, args.words, args.recovery_window))
        print("")

        if not stage_agent(sh, rep):
            rep.settle(ABORTED, "could not put a working agent on the board")
            return 2

        ok, pre = preflight(sh, rep)
        result["preflight"] = pre
        if not ok:
            rep.settle(INCONCLUSIVE if pre else ABORTED,
                       "the instrument was not proven before the DUT; no "
                       "statement about the design is warranted")
            return 3 if pre else 2

        # --- baseline: the wedge detector must be CLEAR before we induce ---
        base_a = wedge_signature(pre["die_a"])
        base_b = wedge_signature(pre["die_b"])
        result["baseline"] = {"die_a": base_a, "die_b": base_b}
        if base_a["present"] or base_b["present"]:
            rep.step("baseline", "NO-RESULT",
                     "a wedge signature was ALREADY present before any "
                     "stimulus (a=%r b=%r) - this run cannot attribute a "
                     "later wedge to the stimulus" % (base_a, base_b))
            rep.settle(INCONCLUSIVE,
                       "pre-existing wedge signature; power-cycle and re-run")
            return 3
        rep.step("baseline", "ok", "wedge detector clear on both dies")

        # --- optionally arm CRC on one AXI node ---------------------------
        if args.arm_crc:
            r = board(sh, "fc_crc_set 0 %s 0" % args.arm_crc, timeout=45)
            js = r.json()
            if js is None or not js.get("ok"):
                rep.step("arm-crc", "NO-RESULT", r.describe())
                rep.settle(INCONCLUSIVE, "could not arm CRC; nothing induced")
                return 3
            rep.step("arm-crc", "ok",
                     "die_a %s disable_crc -> 0 (NACK/replay armed)" % args.arm_crc,
                     js)
            result["arm_crc"] = js

        # --- induce: sustained cross-die AXI traffic ----------------------
        # ahb_sub is AW/W/B on write and AR/R on read - i.e. the five nodes
        # that DIFFER between the file sets. The tx_gen/RX-FIFO path used by
        # kr260_onchip_soak.py would NOT exercise them: that is FCSM_6.
        seen_sig, seen_at, bursts = None, None, 0
        t_end = time.time() + args.recovery_window
        while time.time() < t_end and seen_sig is None:
            bursts += 1
            r = board(sh, "traffic 0 %d %s %.1f" %
                      (args.words, args.offset, args.burst_timeout),
                      timeout=args.burst_timeout + 30)
            js = r.json()
            if r.kind == TIMEOUT and js is None:
                # The ssh call itself out-ran its wall clock with no marker.
                # That is a board that stopped answering - a wedge of the
                # WHOLE PS, which is a different and worse thing than an AXI
                # node wedge, and it is not attributable to state 7.
                rep.step("traffic", "NO-RESULT",
                         "board stopped answering entirely (%s) - PS-level "
                         "hang, not attributable to an FC node" % r.describe())
                rep.settle(INCONCLUSIVE, "board unreachable mid-test; JTAG POR "
                                         "likely required before any re-run")
                return 3
            if js is None:
                rep.step("traffic", "NO-RESULT", r.describe())
                rep.settle(INCONCLUSIVE, "traffic command produced no marker")
                return 3
            if js.get("refused"):
                rep.step("traffic", "ABORT", js.get("why", ""))
                rep.settle(ABORTED, "agent refused the access on safety grounds")
                return 2
            if js.get("wedged"):
                # The worker did not return inside its wall clock. THIS is a
                # positive wedge marker in its own right.
                seen_sig = {"kind": "ahb_sub_hang", "detail": js.get("detail")}
                seen_at = bursts
                rep.step("traffic", "WEDGE-SIG",
                         "burst %d: ahb_sub access did not complete (%s)" %
                         (bursts, js.get("detail")), js)
                break
            sa = wedge_signature(js["post_die_a"])
            sb = wedge_signature(js["post_die_b"])
            if sa is None or sb is None:
                rep.step("traffic", "NO-RESULT",
                         "presence marker vanished mid-run")
                rep.settle(INCONCLUSIVE, "observability marker lost mid-run")
                return 3
            if sa["present"] or sb["present"]:
                seen_sig = {"kind": "obs", "die_a": sa, "die_b": sb}
                seen_at = bursts
                rep.step("traffic", "WEDGE-SIG",
                         "burst %d: wedge signature appeared (a=%s b=%s)" %
                         (bursts, sa["present"], sb["present"]), js)
                break
            res = js.get("result") or {}
            rep.step("traffic", "ok",
                     "burst %d: %d/%d words verified, no wedge signature" %
                     (bursts, res.get("good", 0), res.get("words", 0)))

        result["bursts"] = bursts
        result["wedge_signature"] = seen_sig

        if seen_sig is None:
            # The stimulus never reached the condition. Say so. This is the
            # honest and expected outcome of a natural-cause induction on
            # this vehicle, and it is NOT a pass.
            rep.settle(INCONCLUSIVE,
                       "%d bursts produced no wedge signature at all, so there "
                       "was nothing to recover from. This says NOTHING about "
                       "whether the tapeout FCSMs recover - only that this "
                       "stimulus did not park one. Escalate the stimulus "
                       "(--arm-crc) or accept that natural-cause induction is "
                       "a dead end on this vehicle." % bursts)
            return 3

        # --- discriminate: did it come back? ------------------------------
        rep.step("recovery-watch", "run",
                 "wedge seen at burst %d; watching %.1fs for recovery "
                 "(watchdog fires at ~164us, so absence over this window is "
                 "not a timing artefact)" % (seen_at, args.recovery_window))
        deadline = time.time() + args.recovery_window
        recovered, probes = False, 0
        while time.time() < deadline:
            probes += 1
            r = board(sh, "obs", timeout=45)
            js = r.json()
            if js is None:
                # Losing the board while watching for recovery is itself
                # evidence of a hang, but it is not the FC-node evidence we
                # can attribute, so it stays inconclusive.
                rep.step("recovery-watch", "NO-RESULT", r.describe())
                rep.settle(INCONCLUSIVE,
                           "lost the board while watching for recovery")
                return 3
            sa = wedge_signature(js["die_a"])
            sb = wedge_signature(js["die_b"])
            live_clear = not (sa["wedge_any"] or sb["wedge_any"] or
                              sa["unhealthy"] or sb["unhealthy"])
            if live_clear:
                recovered = True
                break
            time.sleep(0.5)
        result["recovery_probes"] = probes

        if not recovered:
            # SAFETY CHECK even on the wedge branch: prove the reader still
            # works, so "still wedged" is a measurement and not a dead probe.
            r = board(sh, "selftest", timeout=60)
            js = r.json()
            if js is None or js.get("reader_dead"):
                rep.step("post-check", "NO-RESULT",
                         "reader no longer trustworthy; the 'still wedged' "
                         "reading cannot be relied on")
                rep.settle(INCONCLUSIVE,
                           "wedge seen but the instrument failed afterwards")
                return 3
            rep.step("post-check", "ok", "reader still live; wedge is a real reading")
            rep.settle(WEDGE,
                       "an AXI data-node wedge signature appeared and did NOT "
                       "clear within %.1fs (%d probes). On the FPGA file set "
                       "the TL-033 watchdog would have forced the state-7 exit "
                       "~164us in. Record the image sha256 alongside this "
                       "result." % (args.recovery_window, probes))
            result["verdict"] = WEDGE
            return 1

        # --- recovery branch: an escape test is not a safety test ---------
        rep.step("recovery-watch", "ok",
                 "wedge signature cleared after %d probes" % probes)
        r = board(sh, "traffic 0 %d %s %.1f" %
                  (args.words, args.offset, args.burst_timeout),
                  timeout=args.burst_timeout + 30)
        js = r.json()
        if js is None or js.get("wedged") or not (js.get("result") or {}).get("good"):
            rep.step("post-recovery-traffic", "NO-RESULT",
                     "the path did not carry clean traffic after 'recovery'")
            rep.settle(INCONCLUSIVE,
                       "the wedge indication cleared but the NORMAL path did "
                       "not work afterwards, so 'recovery' is not established "
                       "- a passing escape test is not a safety test")
            return 3
        res = js["result"]
        rep.step("post-recovery-traffic", "ok",
                 "%d/%d words verified after recovery" %
                 (res.get("good", 0), res.get("words", 0)))
        rep.settle(RECOVERY,
                   "a wedge signature appeared, cleared within %.1fs, and the "
                   "normal cross-die path carried clean traffic afterwards." %
                   args.recovery_window)
        result["verdict"] = RECOVERY
        return 0

    finally:
        # Always disarm what we armed, and always drop the master.
        try:
            if args.arm_crc:
                board(sh, "fc_crc_set 0 %s 1" % args.arm_crc, timeout=45)
        except Exception:
            pass
        result["steps"] = rep.steps
        result["verdict"] = rep.verdict
        result["why"] = rep.why
        if args.json_out:
            try:
                with open(args.json_out, "w") as f:
                    json.dump(result, f, indent=2, sort_keys=True)
                print("wrote %s" % args.json_out)
            except Exception as e:
                print("could not write %s: %r" % (args.json_out, e), file=sys.stderr)
        sh.close_master()


if __name__ == "__main__":
    sys.exit(main())
