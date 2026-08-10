#!/usr/bin/env python3
# =============================================================================
# cov_perf_thresholds.py — PERF-MONITOR coverage gate (real THRESHOLD assertion).
#
# Closes the perf-monitor gap: today's hwtest/11_perf_counters.sh is LIVENESS
# ONLY (">=1 counter advanced under a doorbell"). This gate turns the perf block
# into an ASSERTING threshold check on the eth-chiplet, over the eth_ss_0
# backdoor:
#
#   * LATENCY from the perf timestamps: link latency = t(RX_FIRST) - t(TX_START),
#     FIFO-drain latency = t(RX_DONE) - t(RX_FIRST), total = t(RX_DONE) -
#     t(TX_START); each asserted <= a (calibratable) bound.
#   * STALL FRACTION  tx_stall/tx_word and rx_stall/rx_word asserted <= budget.
#   * CREDIT-STARVE   credit_starve/sample asserted <= budget; starve_sticky
#     (PERF_CONG_STATE[20]) asserted 0 unless --allow-starve-sticky.
#   * DECODES PERF_CONG_STATE (0x20F8): ewma_credit[12:0], level[17:16],
#     trend[19:18], starve_sticky[20] — the first test in the suite to decode it.
#   * RETIRES the dead ECCCNT half (0x2114 ecc_corrupted[15:0] ties 0 in silicon)
#     with an explicit SKIP line — never gated on.
#
# Perf register map (offsets from TLAPB 0x2E030000; ground truth
# src/rtl/tidelink_perf.sv register read mux):
#   0x20A0 PERF_CTRL      [0]enable [1]freeze [4]irq_en
#   0x20AC TS_VALID       [0]tx_ts_valid [1]rx_first_valid [2]rx_done_valid [3]freeze
#   0x20B0/B4 TX_START ns/sec   0x20B8/BC RX_FIRST ns/sec   0x20C0/C4 RX_DONE ns/sec
#   0x20C8/CC TX/RX_PKT   0x20D0/D4 TX/RX_WORD   0x20D8/DC TX/RX_STALL
#   0x20E0 LINK_BUSY  0x20E4 CREDIT_STARVE  0x20E8 SAMPLE
#   0x20EC DBG_LINK_STATUS  0x20F0/F4 TX/RX_INFLIGHT  0x20F8 PERF_CONG_STATE
#   0x20FC PERF_ID = 0x5046_0100 (readable sanity)
#   (ns fields are 30-bit [29:0]; absolute_ns = sec*NS_PER_SEC + ns.)
#
# WEDGE-SAFETY: reading the perf plane is combinational RO (cannot wedge). The
# workload that POPULATES the timestamps is pluggable via --induce:
#   none      pure RO — assert on whatever the perf block last latched (e.g. after
#             a soak). CI-safe, wedge-proof, no FCSM gate needed.
#   doorbell  ring the far doorbell N times (a control-plane packet; does NOT
#             cross the AXI DATA plane) to induce a bounded, low-wedge-risk flow.
#             FCSM=4 gated.
#   peerwrite ATTENDED — reuse the PROVEN kr260_eth_xfer.py --mode soak (A->B) for
#             a real bounded data-plane workload. Wedge-prone; FCSM=4 gated;
#             JTAG-POR staged on a hang.
# Every board access is subprocess-timeout-wrapped by cov_common (a timeout ==
# a PS-bus WEDGE). The perf plane is die-LOCAL, so the measurement is read on the
# SENDER die (default die_a) and needs no peer read.
#
# Self-shipping single file: the default (dev-host) path ships THIS file to the
# die and runs it `--on-board` in one timeout-wrapped ssh; `--on-board` is the
# board-local /dev/mem agent (stdlib only). Run ON mapstone-dev:
#   export KR260_PASSWORD=...
#   python3 cov_perf_thresholds.py --induce doorbell --doorbell-n 8
#   python3 cov_perf_thresholds.py --induce none          # RO, post-soak analysis
#   python3 cov_perf_thresholds.py --induce peerwrite --iters 256   # attended
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import base64
import os
import sys

WINDOW = 0x400000000
TLAPB = 0x2E030000

# (name, offset-from-TLAPB) — read in this order both pre and post.
PERF_REGS = [
    ("PERF_CTRL", 0x20A0), ("TS_VALID", 0x20AC),
    ("TX_START_NS", 0x20B0), ("TX_START_SEC", 0x20B4),
    ("RX_FIRST_NS", 0x20B8), ("RX_FIRST_SEC", 0x20BC),
    ("RX_DONE_NS", 0x20C0), ("RX_DONE_SEC", 0x20C4),
    ("TX_PKT", 0x20C8), ("RX_PKT", 0x20CC),
    ("TX_WORD", 0x20D0), ("RX_WORD", 0x20D4),
    ("TX_STALL", 0x20D8), ("RX_STALL", 0x20DC),
    ("LINK_BUSY", 0x20E0), ("CREDIT_STARVE", 0x20E4), ("SAMPLE", 0x20E8),
    ("DBG_LINK_STATUS", 0x20EC), ("TX_INFLIGHT", 0x20F0), ("RX_INFLIGHT", 0x20F4),
    ("PERF_CONG_STATE", 0x20F8), ("PERF_ID", 0x20FC),
    ("SWI_LANE", 0x2108), ("STATUS", 0x2010), ("ECCCNT", 0x2114),
]
PERF_CTRL = 0x20A0
DOORBELL = 0x2014
NS_MASK = 0x3FFFFFFF        # ns fields are [29:0]
PERF_ID_EXPECT = 0x50460100

# ============================================================================
# ON-BOARD AGENT (board-local /dev/mem; STDLIB ONLY — no cov_common import here).
# Prints `PRE name 0xVAL` then optionally induces, then `POST name 0xVAL`.
# ============================================================================
def _onboard(args):
    import mmap
    import struct
    import time
    try:
        f = open("/dev/mem", "r+b", buffering=0)
        m = mmap.mmap(f.fileno(), 0x4000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=WINDOW + TLAPB)
    except (OSError, PermissionError) as e:
        print("ONBOARD_ERR mmap /dev/mem failed: %s (root? bitstream loaded?)" % e)
        return 3

    def rd(o):
        return struct.unpack("<I", m[o:o + 4])[0]

    def wr(o, v):
        m[o:o + 4] = struct.pack("<I", v & 0xFFFFFFFF)

    def snap(label):
        for name, off in PERF_REGS:
            print("%s %s 0x%08X" % (label, name, rd(off)))

    snap("PRE")
    if args.enable:
        cur = rd(PERF_CTRL)
        wr(PERF_CTRL, cur | 0x1)              # PERF_CTRL[0] enable
        print("NOTE perf_enable set PERF_CTRL=0x%08X" % rd(PERF_CTRL))
    if args.doorbell_n > 0:
        for _ in range(args.doorbell_n):
            wr(DOORBELL, 0x1)                 # trigger a doorbell pulse to the peer
            time.sleep(0.02)
        time.sleep(0.2)
        print("NOTE rang doorbell x%d" % args.doorbell_n)
    snap("POST")
    m.close()
    f.close()
    return 0


# ============================================================================
# DEV-HOST ORCHESTRATOR
# ============================================================================
def _ship_run(cc, ip, onboard_args, timeout, stage):
    """Ship THIS file to `ip` and run it --on-board in one timeout-wrapped ssh.
    base64 -> /tmp so the coverage dir need not be staged on the board."""
    b64 = base64.b64encode(open(os.path.abspath(__file__), "rb").read()).decode()
    fn = "/tmp/%s" % os.path.basename(__file__)
    remote = "echo %s | base64 -d > %s && python3 %s %s" % (b64, fn, fn, onboard_args)
    return cc.ssh_board(ip, remote, timeout, stage)


def _parse_snaps(out):
    pre, post = {}, {}
    for ln in out.splitlines():
        t = ln.split()
        if len(t) == 3 and t[0] in ("PRE", "POST"):
            try:
                (pre if t[0] == "PRE" else post)[t[1]] = int(t[2], 16)
            except ValueError:
                pass
    return pre, post


def _abs_ns(snap, base, ns_per_sec):
    return snap["%s_SEC" % base] * ns_per_sec + (snap["%s_NS" % base] & NS_MASK)


def _decode_cong(v):
    return {"ewma_credit": v & 0x1FFF, "level": (v >> 16) & 3,
            "trend": (v >> 18) & 3, "starve_sticky": (v >> 20) & 1, "raw": v}


def _devhost(args):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cov_common as cc

    ip = cc.DIE_A_IP if args.die == "a" else cc.DIE_B_IP
    cc.banner("PERF-MONITOR THRESHOLD GATE — die_%s (%s), induce=%s"
              % (args.die, ip, args.induce))

    # FCSM gate only when we intend to induce link traffic.
    if args.induce in ("doorbell", "peerwrite"):
        cc.require_pair_fcsm4(cc.DIE_A_IP, cc.DIE_B_IP)

    # peerwrite: reuse the PROVEN on-board soak for a real bounded data workload
    # BEFORE we snapshot the (die-local) perf plane.
    if args.induce == "peerwrite":
        print("-- inducing bounded data-plane workload (kr260_eth_xfer soak A->B) --")
        try:
            rc, out = cc.board_python(
                cc.DIE_A_IP, "%s --mode soak --iters %d --seed 0x%X --win 16"
                % (cc.XFER, args.iters, args.seed), cc.T_STREAM, "perf_soak")
            print(out.rstrip())
            if rc != 0:
                print("  NOTE soak rc=%d (workload may be partial; continuing to read perf)" % rc)
        except cc.WedgeTimeout as e:
            print("  !! WEDGE: soak timed out (stage=%s) — PS bus hung." % e.stage)
            cc.por_stage(cc.DIE_A_IP, "perf soak wedge")
            print("RESULT: FAIL — workload wedged the link before perf could be sampled.")
            return 1

    enable = args.induce in ("doorbell", "peerwrite")
    dn = args.doorbell_n if args.induce == "doorbell" else 0
    ob = "--on-board%s%s" % (" --enable" if enable else "",
                             (" --doorbell-n %d" % dn) if dn else "")
    try:
        rc, out = _ship_run(cc, ip, ob, cc.T_STREAM, "perf_read")
    except cc.WedgeTimeout as e:
        print("  !! WEDGE: perf read timed out (stage=%s)." % e.stage)
        cc.por_stage(ip, "perf read wedge")
        print("RESULT: FAIL — even the RO perf read hung (bus already wedged).")
        return 1
    if rc != 0 or "ONBOARD_ERR" in out:
        print(out.rstrip())
        print("RESULT: FAIL — on-board perf agent error (rc=%d)." % rc)
        return 1

    pre, post = _parse_snaps(out)
    need = {"TX_START_NS", "RX_FIRST_NS", "RX_DONE_NS", "PERF_CONG_STATE", "SWI_LANE"}
    if not need.issubset(post):
        print(out.rstrip())
        print("RESULT: FAIL — perf snapshot incomplete (missing %s)."
              % ",".join(sorted(need - set(post))))
        return 1

    return _verdict(args, pre, post)


def _verdict(args, pre, post):
    fails, notes = [], []

    # --- readable / ID sanity -------------------------------------------------
    pid = post.get("PERF_ID", 0)
    if pid != PERF_ID_EXPECT:
        fails.append("PERF_ID 0x%08X != 0x%08X (perf block absent/wrong build)"
                     % (pid, PERF_ID_EXPECT))
    swi = post["SWI_LANE"]
    fcsm, cal = (swi >> 17) & 7, (swi >> 16) & 1
    link_up = fcsm == 4 and cal == 1
    print("  SWI_LANE=0x%08X fcsm=%d cal=%d -> %s   PERF_ID=0x%08X   PERF_CTRL=0x%08X"
          % (swi, fcsm, cal, "UP" if link_up else "DOWN", pid, post.get("PERF_CTRL", 0)))
    if not link_up:
        fails.append("link not FCSM=4 (fcsm=%d cal=%d)" % (fcsm, cal))

    # --- counter deltas (use deltas if the workload advanced anything) --------
    def delta(name):
        return (post.get(name, 0) - pre.get(name, 0)) & 0xFFFFFFFF
    d = {k: delta(k) for k in ("TX_WORD", "RX_WORD", "TX_STALL", "RX_STALL",
                               "CREDIT_STARVE", "SAMPLE", "TX_PKT", "RX_PKT")}
    fresh = any(d[k] for k in ("TX_WORD", "RX_WORD", "TX_PKT", "RX_PKT"))
    src = d if fresh else {k: post.get(k, 0) for k in d}
    print("  workload=%s  TX_pkt=%d RX_pkt=%d  TX_word=%d RX_word=%d  TX_stall=%d "
          "RX_stall=%d  credit_starve=%d sample=%d"
          % ("fresh(delta)" if fresh else "absolute(no fresh traffic)",
             src["TX_PKT"], src["RX_PKT"], src["TX_WORD"], src["RX_WORD"],
             src["TX_STALL"], src["RX_STALL"], src["CREDIT_STARVE"], src["SAMPLE"]))
    if not fresh:
        notes.append("no fresh traffic captured (asserting on absolute counters/"
                     "last-latched timestamps; use --induce for a bounded workload)")

    # --- LATENCY from timestamps ---------------------------------------------
    ts = post.get("TS_VALID", 0)
    tx_v, rxf_v, rxd_v = ts & 1, (ts >> 1) & 1, (ts >> 2) & 1
    print("  TS_VALID=0x%X (tx=%d rx_first=%d rx_done=%d)" % (ts, tx_v, rxf_v, rxd_v))
    if tx_v and rxf_v and rxd_v:
        nps = args.ns_per_sec
        t_start = _abs_ns(post, "TX_START", nps)
        t_first = _abs_ns(post, "RX_FIRST", nps)
        t_done = _abs_ns(post, "RX_DONE", nps)
        link_ns = t_first - t_start
        drain_ns = t_done - t_first
        # tolerate a single ns-counter rollover (sec:ns wrap between events).
        if link_ns < 0:
            link_ns += nps
            notes.append("link latency wrapped one ns-rollover")
        if drain_ns < 0:
            drain_ns += nps
            notes.append("drain latency wrapped one ns-rollover")
        total_ns = link_ns + drain_ns
        print("  LATENCY  link(TX_START->RX_FIRST)=%d ns  drain(RX_FIRST->RX_DONE)=%d ns"
              "  total=%d ns" % (link_ns, drain_ns, total_ns))
        if link_ns > args.max_link_ns:
            fails.append("link latency %d ns > bound %d ns" % (link_ns, args.max_link_ns))
        if drain_ns > args.max_drain_ns:
            fails.append("drain latency %d ns > bound %d ns" % (drain_ns, args.max_drain_ns))
        if total_ns > args.max_total_ns:
            fails.append("total latency %d ns > bound %d ns" % (total_ns, args.max_total_ns))
        if link_ns < 0 or drain_ns < 0:
            fails.append("negative latency after rollover fix (timestamps stale/torn)")
    else:
        notes.append("timestamps not all valid — latency assertion SKIPPED "
                     "(run with --induce to populate TX_START/RX_FIRST/RX_DONE)")

    # --- STALL FRACTION -------------------------------------------------------
    def frac(a, b):
        return (src[a] / src[b]) if src[b] else 0.0
    tx_sf = frac("TX_STALL", "TX_WORD")
    rx_sf = frac("RX_STALL", "RX_WORD")
    print("  STALL-FRACTION  tx=%.4f rx=%.4f (budget %.4f)"
          % (tx_sf, rx_sf, args.max_stall_frac))
    if src["TX_WORD"] and tx_sf > args.max_stall_frac:
        fails.append("tx stall fraction %.4f > budget %.4f" % (tx_sf, args.max_stall_frac))
    if src["RX_WORD"] and rx_sf > args.max_stall_frac:
        fails.append("rx stall fraction %.4f > budget %.4f" % (rx_sf, args.max_stall_frac))

    # --- CREDIT-STARVE --------------------------------------------------------
    starve_sf = frac("CREDIT_STARVE", "SAMPLE")
    print("  CREDIT-STARVE-FRACTION  %.4f (budget %.4f)" % (starve_sf, args.max_starve_frac))
    if src["SAMPLE"] and starve_sf > args.max_starve_frac:
        fails.append("credit-starve fraction %.4f > budget %.4f"
                     % (starve_sf, args.max_starve_frac))

    # --- PERF_CONG_STATE decode (first test to decode it) ---------------------
    cg = _decode_cong(post["PERF_CONG_STATE"])
    lvl = ("OK", "WARN", "CONGESTED", "CRITICAL")[cg["level"]]
    trd = ("flat", "rising", "falling", "-")[cg["trend"]]
    print("  PERF_CONG_STATE=0x%08X  ewma_credit=%d level=%d(%s) trend=%d(%s) "
          "starve_sticky=%d" % (cg["raw"], cg["ewma_credit"], cg["level"], lvl,
                                cg["trend"], trd, cg["starve_sticky"]))
    if cg["starve_sticky"] and not args.allow_starve_sticky:
        fails.append("PERF_CONG_STATE starve_sticky latched (credit starvation seen; "
                     "pass --allow-starve-sticky to waive)")

    # --- DEAD counter: explicitly retired ------------------------------------
    print("  SKIP  ECCCNT 0x2114 ecc_corrupted[15:0]=%d — DEAD counter (ties 0 in "
          "silicon); NOT gated." % (post.get("ECCCNT", 0) & 0xFFFF))

    for n in notes:
        print("  note: %s" % n)
    ok = not fails
    if not ok:
        for fl in fails:
            print("  FAIL: %s" % fl)
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "perf within all thresholds" if ok else "%d threshold(s) breached" % len(fails)))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Perf-monitor threshold gate (eth-chiplet).")
    ap.add_argument("--on-board", action="store_true",
                    help="internal: run the board-local /dev/mem agent.")
    ap.add_argument("--enable", action="store_true", help="on-board: set PERF_CTRL enable.")
    ap.add_argument("--doorbell-n", type=int, default=0, help="on-board: doorbell rings.")
    # dev-host:
    ap.add_argument("--die", choices=("a", "b"), default="a",
                    help="which die's (local) perf plane to sample (default a).")
    ap.add_argument("--induce", choices=("none", "doorbell", "peerwrite"),
                    default="doorbell", help="workload to populate the perf plane.")
    ap.add_argument("--iters", type=int, default=256, help="peerwrite: soak beats.")
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0xC0FFEE)
    # thresholds (CALIBRATE against a golden run — defaults are conservative placeholders):
    ap.add_argument("--max-link-ns", type=int, default=200000, help="link-latency bound ns.")
    ap.add_argument("--max-drain-ns", type=int, default=200000, help="drain-latency bound ns.")
    ap.add_argument("--max-total-ns", type=int, default=400000, help="total-latency bound ns.")
    ap.add_argument("--max-stall-frac", type=float, default=0.30, help="stall/word budget.")
    ap.add_argument("--max-starve-frac", type=float, default=0.10, help="starve/sample budget.")
    ap.add_argument("--allow-starve-sticky", action="store_true",
                    help="do not fail on PERF_CONG_STATE starve_sticky.")
    ap.add_argument("--ns-per-sec", type=int, default=1000000000,
                    help="ns rollover for sec:ns timestamp math (default 1e9).")
    args = ap.parse_args()
    if args.on_board:
        return _onboard(args)
    return _devhost(args)


if __name__ == "__main__":
    sys.exit(main())
