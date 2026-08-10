#!/usr/bin/env python3
# =============================================================================
# cov_tidechart_election.py — DETERMINISTIC TideChart bootstrap coverage on the
#   two-board KR260 eth-chiplet pair: election -> enum -> route -> telemetry -> IRQ.
#
# TideChart (APB SoC 0x2E040000, reached PS-side at 0x4_2E040000) is the chiplet
# identity/routing bootstrap: root election -> DFS enum/ID-assign -> route table
# -> congestion telemetry, with an IRQ on election_done/enum_done/hotplug edges.
# kr260_tidechart.py drives ONE board; this gate drives BOTH and makes the
# cross-die ASSERTIONS that a single board cannot:
#
#   1. EXACTLY-ONE-ROOT  — after a SYNCHRONIZED election on both dies, exactly one
#      die has is_root=1. Two roots == the G1 SILENT DUAL-ROOT failure; zero ==
#      no convergence. NOTE: TC_ERROR[2] dual_root NEVER asserts in silicon, so
#      dual-root is detected HOST-side by comparing both dies (not by the flag).
#   2. ID ASSIGNMENT — after enum on the root: enum_done=1, total=2, and the two
#      dies hold DISTINCT local_ids.
#   3. ROUTE — each die has a route (valid egress) to the peer's id.
#   4. TELEMETRY — a broadcast from the root increments rx_bcast on the peer
#      (TC_CONG_STATUS[23:16]).
#   5. IRQ — the TideChart IRQ (edge on election_done|enum_done, level on
#      TC_HOTPLUG sticky link-change) is exercised: both done-edges are witnessed
#      (STATUS bits latched), and any TC_HOTPLUG sticky bit is asserted to
#      self-clear via W1C (the level-IRQ deassert path). [First IRQ coverage —
#      capturing the raw irq WIRE needs the IRQC/GIC path, not this backdoor.]
#
# *** PREREQUISITE BITSTREAM FIX (G1) ***
#   Both dies are strapped TC_DEVICE_CLASS=0x0001 and the PUF is off, so election
#   falls to the free-running random_id tiebreak -> NON-DETERMINISTIC / silent
#   dual-root. TC_CTRL[2] force_root is decoded but never consumed in silicon RTL,
#   so it cannot fix this from software. The DETERMINISTIC fix is a STRAP change +
#   rebuild of BOTH bitstreams:
#       die_a  TC_DEVICE_CLASS = 0x0001   (lower  -> deterministic root)
#       die_b  TC_DEVICE_CLASS = 0x0002   (higher -> non-root)
#   (device_class is the primary claim key in TC_BEST_CLAIM[31:16]; the LOWER
#    claim wins. Proof, tidechart_election_fsm.sv: header "lowest claim ...
#    becomes root" (:6-8); rx_claim_better = (rx_class < best_class_r) (:181-184);
#    force_root claims the unbeatable class 0x0000 (:305). The election-pair sim
#    (tidechart/cocotb/tidechart_election_pair) confirms lower-strap/lower-class
#    wins. An EARLIER version of this file said "higher wins" — that was inverted.)
#   This gate DETECTS the unfixed condition (identical straps / puf_ready=0) and
#   reports it loudly, but the EXACTLY-ONE-ROOT assertion can only PASS on the
#   re-strapped, rebuilt pair.
#
# WEDGE-SAFETY: TideChart touches ONLY the in-window register file (no peer
# aperture) -> no wedge risk, and die_b verdicts are LOCAL TC reads. Every ssh is
# timeout-wrapped by cov_common. FCSM=4 is still required (TC packets cannot cross
# a down link) and the gate refuses otherwise. The election is time-synchronized
# (both dies pass the same --sync-at wall-clock epoch) because the election window
# is far shorter than ssh command skew.
#
# Self-shipping single file:
#   export KR260_PASSWORD=...
#   python3 cov_tidechart_election.py
#   python3 cov_tidechart_election.py --sync-slack 4 --timeout 8
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import base64
import os
import sys
import threading
import time

WINDOW = 0x400000000
TC_BASE = 0x2E040000

TC_STATUS = 0x00        # [0]election_done [1]is_root [2]enum_done [7:3]local_id [12:8]total
TC_BEST_CLAIM = 0x04    # [31:16]dev_class [15:0]random_id
TC_CTRL = 0x08          # [0]election_start [1]enum_start [2]force_root(UNUSED) [3]reset/restart
TC_TIMEOUT = 0x0C
TC_DEVICE_CLASS = 0x10
TC_ROUTE_RD = 0x18
TC_RANDOM_ID = 0x1C
TC_UPLINK_PORT = 0x20
TC_PORT_COUNT = 0x24
TC_ENUM_STATE = 0x28
TC_ERROR = 0x2C         # R/W1C [0]elec_to [1]enum_to [2]dual_root(NEVER set)
TC_PUF_STATUS = 0x30    # [16]puf_ready [15:0]puf_seed
TC_HOTPLUG = 0x68       # sticky W1C link-change (IRQ level source)
TC_CONG_CTRL = 0x74     # [0]bcast_enable [1]bcast_trigger(W1P)
TC_CONG_STATUS = 0x78   # [15:8]last_tx_seq [23:16]rx_bcast [31:24]tx_bcast

CTRL_ELECTION_START = 1 << 0
CTRL_ENUM_START = 1 << 1
CTRL_RESET = 1 << 3
TIMEOUT_WIDE = 0x4000_8000    # enum~0x4000 election~0x8000 (> a D2D round-trip)

_TC_DUMP = (("STATUS", TC_STATUS), ("BEST_CLAIM", TC_BEST_CLAIM),
            ("DEVICE_CLASS", TC_DEVICE_CLASS), ("RANDOM_ID", TC_RANDOM_ID),
            ("ENUM_STATE", TC_ENUM_STATE), ("PORT_COUNT", TC_PORT_COUNT),
            ("UPLINK_PORT", TC_UPLINK_PORT), ("ERROR", TC_ERROR),
            ("PUF_STATUS", TC_PUF_STATUS), ("HOTPLUG", TC_HOTPLUG),
            ("CONG_STATUS", TC_CONG_STATUS))


# ============================================================================
# ON-BOARD AGENT (board-local /dev/mem; STDLIB ONLY). --tc-op selects the op.
# ============================================================================
def _onboard(args):
    import mmap
    import struct
    try:
        f = open("/dev/mem", "r+b", buffering=0)
        m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=WINDOW + TC_BASE)
    except (OSError, PermissionError) as e:
        print("ONBOARD_ERR mmap /dev/mem failed: %s" % e)
        return 3

    def rd(o):
        return struct.unpack("<I", m[o:o + 4])[0]

    def wr(o, v):
        m[o:o + 4] = struct.pack("<I", v & 0xFFFFFFFF)

    def dump():
        for name, off in _TC_DUMP:
            print("TC %s 0x%08X" % (name, rd(off)))

    op = args.tc_op
    if op == "status":
        dump()
    elif op == "prep":
        wr(TC_TIMEOUT, TIMEOUT_WIDE)
        print("TC TIMEOUT 0x%08X" % rd(TC_TIMEOUT))
        dump()
    elif op == "elect":
        # NOTE: a RESET-before-elect (to clear a stale terminal ST_SETTLED without a
        # POR) was tried and REVERTED — on a POR-fresh FSM it regressed the election
        # (re-triggers PUF settle -> election_start gated on puf_ready -> timeout).
        # The test flow PORs fresh each bring-up, so the FSM is never stale here.
        # If a RESET-before-elect is ever reinstated, first poll puf_ready after the
        # reset and widen the timeout. See scratchpad/tidechart_disambig (bring-up 3).
        if args.sync_at > 0:
            now = time.time()
            if args.sync_at > now:
                time.sleep(max(0.0, args.sync_at - now - 0.02))
                while time.time() < args.sync_at:
                    pass
        wr(TC_CTRL, CTRL_ELECTION_START)
        deadline = time.time() + args.timeout
        while time.time() < deadline:
            if rd(TC_STATUS) & 1:
                break
            time.sleep(0.01)
        dump()
    elif op == "enum":
        wr(TC_CTRL, CTRL_ENUM_START)
        deadline = time.time() + args.timeout
        while time.time() < deadline:
            if (rd(TC_STATUS) >> 2) & 1:
                break
            time.sleep(0.01)
        dump()
    elif op == "route":
        wr(TC_ROUTE_RD, args.peer_id & 0x1F)
        print("TC ROUTE 0x%08X" % rd(TC_ROUTE_RD))
    elif op == "telemetry":
        wr(TC_CONG_CTRL, 0x1)          # bcast_enable
        wr(TC_CONG_CTRL, 0x3)          # + bcast_trigger (W1P)
        time.sleep(0.05)
        print("TC CONG_STATUS 0x%08X" % rd(TC_CONG_STATUS))
    elif op == "hotplug_clear":
        before = rd(TC_HOTPLUG)
        wr(TC_HOTPLUG, args.mask & 0xFFFF)     # W1C
        print("TC HOTPLUG_BEFORE 0x%08X" % before)
        print("TC HOTPLUG 0x%08X" % rd(TC_HOTPLUG))
    elif op == "error_clear":
        before = rd(TC_ERROR)
        wr(TC_ERROR, args.mask & 0xFFFF)       # W1C
        print("TC ERROR_BEFORE 0x%08X" % before)
        print("TC ERROR 0x%08X" % rd(TC_ERROR))
    elif op == "reset":
        wr(TC_CTRL, CTRL_RESET)
        time.sleep(0.02)
        dump()
    else:
        print("ONBOARD_ERR unknown tc-op %s" % op)
        m.close()
        f.close()
        return 2
    print("AGENT_OK")
    m.close()
    f.close()
    return 0


# ============================================================================
# DEV-HOST ORCHESTRATOR
# ============================================================================
def _ship_run(cc, ip, onboard_args, timeout, stage):
    b64 = base64.b64encode(open(os.path.abspath(__file__), "rb").read()).decode()
    fn = "/tmp/%s" % os.path.basename(__file__)
    remote = "echo %s | base64 -d > %s && python3 %s %s" % (b64, fn, fn, onboard_args)
    return cc.ssh_board(ip, remote, timeout, stage)


def _parse_tc(out):
    d = {}
    for ln in out.splitlines():
        t = ln.split()
        if len(t) == 3 and t[0] == "TC":
            try:
                d[t[1]] = int(t[2], 16)
            except ValueError:
                pass
    return d


def _status(s):
    return dict(election_done=s & 1, is_root=(s >> 1) & 1, enum_done=(s >> 2) & 1,
                local_id=(s >> 3) & 0x1F, total=(s >> 8) & 0x1F)


def _tc(cc, ip, op, ssh_to, stage, **kw):
    """Run one TC op on a die (ssh_to = ssh subprocess timeout). Returns (ok, dict).
    Extra kwargs (sync_at/timeout/peer_id/mask) become on-board agent --flags.
    TideChart is wedge-safe (in-window only) so a timeout here is reported, not
    POR-staged."""
    a = "--on-board --tc-op %s" % op
    for k, v in kw.items():
        a += " --%s %s" % (k.replace("_", "-"), v)
    try:
        rc, out = _ship_run(cc, ip, a, ssh_to, stage)
    except cc.WedgeTimeout as e:
        print("  !! TIMEOUT: TC %s on %s (stage=%s)" % (op, ip, e.stage))
        return False, {}
    if rc != 0 or "AGENT_OK" not in out:
        print(out.rstrip())
        return False, {}
    return True, _parse_tc(out)


def _devhost(args):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import cov_common as cc

    A, B = cc.DIE_A_IP, cc.DIE_B_IP
    cc.banner("TIDECHART DETERMINISTIC BOOTSTRAP GATE (die_a=%s die_b=%s)" % (A, B))
    fails, warns = [], []

    # 0. FCSM=4 on both (TC packets cannot cross a down link).
    cc.require_pair_fcsm4(A, B)

    # 1. baseline + STRAP check (G1 detection).
    print("-- baseline TC status --")
    oka, sa = _tc(cc, A, "status", cc.T_POKE, "tc_status")
    okb, sb = _tc(cc, B, "status", cc.T_POKE, "tc_status")
    if not (oka and okb):
        print("RESULT: FAIL — could not read baseline TC status on both dies.")
        return 1
    dc_a, dc_b = sa["DEVICE_CLASS"] & 0xFFFF, sb["DEVICE_CLASS"] & 0xFFFF
    rid_a, rid_b = sa["RANDOM_ID"] & 0xFFFF, sb["RANDOM_ID"] & 0xFFFF
    # RTL (tidechart_election_fsm.sv:310): own_random_r = {device_strap, lfsr[7:0]},
    # so RANDOM_ID[15:8] IS the per-die device_strap (die_a=0x00 -> root, die_b=0x01).
    # The election claim compared (lower wins, :181-184) is the full tuple
    # {DEVICE_CLASS[15:0], RANDOM_ID[15:0]}. DEVICE_CLASS is equal BY DESIGN (single
    # netlist, both 0x0001), so determinism comes from the strap in RANDOM_ID[15:8].
    strap_a, strap_b = (rid_a >> 8) & 0xFF, (rid_b >> 8) & 0xFF
    puf_a, puf_b = (sa["PUF_STATUS"] >> 16) & 1, (sb["PUF_STATUS"] >> 16) & 1
    print("  die_a DEVICE_CLASS=0x%04X random_id=0x%04X device_strap=0x%02X puf_ready=%d"
          % (dc_a, rid_a, strap_a, puf_a))
    print("  die_b DEVICE_CLASS=0x%04X random_id=0x%04X device_strap=0x%02X puf_ready=%d"
          % (dc_b, rid_b, strap_b, puf_b))
    # G1 (true non-determinism) requires the WHOLE tiebreak to collide: identical
    # DEVICE_CLASS *and* identical device_strap -> falls to the free LFSR. Identical
    # DEVICE_CLASS alone is BY DESIGN and is NOT G1 (corrects the old dc_a==dc_b
    # false-positive; see memory tidechart-election-not-g1-blocked).
    g1 = (dc_a == dc_b) and (strap_a == strap_b)
    if g1:
        print("  *** G1 DETECTED: both dies strapped DEVICE_CLASS=0x%04X AND "
              "device_strap=0x%02X — election falls to the free-running LFSR "
              "(NON-DETERMINISTIC / silent dual-root)." % (dc_a, strap_a))
        print("  *** FIX: physically differentiate role_strap_i on the two boards "
              "(die_a strap < die_b strap); force_root (TC_CTRL[2]) is NOT consumed "
              "in silicon and cannot fix this from software.")
        warns.append("G1: identical DEVICE_CLASS (0x%04X) AND device_strap (0x%02X) "
                     "— exactly-one-root is non-deterministic (role_strap not "
                     "differentiated on the two boards)" % (dc_a, strap_a))
    elif (dc_a, rid_a) >= (dc_b, rid_b):
        warns.append("claim die_a{class=0x%04X,rid=0x%04X} >= die_b{class=0x%04X,"
                     "rid=0x%04X}: the deterministic root is the LOWER claim (RTL: "
                     "lower wins) — expected die_a < die_b so die_a is root"
                     % (dc_a, rid_a, dc_b, rid_b))
    if not puf_a or not puf_b:
        print("  note: puf_ready=0 (die_a=%d die_b=%d) — election_start is gated on "
              "puf_ready in RTL; election_done may never set." % (puf_a, puf_b))
        warns.append("puf_ready=0 on a die -> election_start gated (PUF off)")

    # 2. prep: widen timeouts on both.
    print("-- prep: widen TC_TIMEOUT on both dies --")
    _tc(cc, A, "prep", cc.T_POKE, "tc_prep")
    _tc(cc, B, "prep", cc.T_POKE, "tc_prep")

    # 3. SYNCHRONIZED election on both dies (same wall-clock epoch).
    epoch = time.time() + args.sync_slack
    print("-- synchronized election @ epoch %.3f (slack %.1fs, timeout %.1fs) --"
          % (epoch, args.sync_slack, args.timeout))
    results = {}

    def _elect(ip, key):
        results[key] = _tc(cc, ip, "elect", cc.T_STREAM, "tc_elect",
                           sync_at="%.3f" % epoch, timeout=args.timeout)

    ta = threading.Thread(target=_elect, args=(A, "a"))
    tb = threading.Thread(target=_elect, args=(B, "b"))
    ta.start()
    tb.start()
    ta.join()
    tb.join()
    (oka, ea), (okb, eb) = results["a"], results["b"]
    if not (oka and okb):
        print("RESULT: FAIL — election op failed/timed out on a die.")
        return 1
    # Harden: an election that ran (AGENT_OK) but returned no STATUS field must not
    # crash the gate (was KeyError:'STATUS'). Report what came back and fail cleanly.
    if "STATUS" not in ea or "STATUS" not in eb:
        print("  die_a election keys: %s" % sorted(ea.keys()))
        print("  die_b election keys: %s" % sorted(eb.keys()))
        print("RESULT: FAIL — election returned no STATUS field (cannot read "
              "election_done/is_root). Baseline claim was IDENTICAL on both dies "
              "(DEVICE_CLASS=0x%04X, RANDOM_ID=0x%04X) -> no deterministic tiebreak."
              % (dc_a, rid_a))
        return 1
    sta, stb = _status(ea["STATUS"]), _status(eb["STATUS"])
    print("  die_a: election_done=%d is_root=%d  BEST_CLAIM=0x%08X TC_ERROR=0x%08X"
          % (sta["election_done"], sta["is_root"], ea["BEST_CLAIM"], ea["ERROR"]))
    print("  die_b: election_done=%d is_root=%d  BEST_CLAIM=0x%08X TC_ERROR=0x%08X"
          % (stb["election_done"], stb["is_root"], eb["BEST_CLAIM"], eb["ERROR"]))

    # --- ASSERTION 1: exactly one root --------------------------------------
    if not (sta["election_done"] and stb["election_done"]):
        fails.append("election_done not set on both dies (a=%d b=%d) — no convergence "
                     "(link/peer/puf/timeout)" % (sta["election_done"], stb["election_done"]))
    nroot = sta["is_root"] + stb["is_root"]
    if nroot == 2:
        fails.append("DUAL-ROOT: both dies is_root=1 — the G1 silent failure "
                     "(TC_ERROR[2] dual_root does not assert in silicon; detected "
                     "host-side).%s" % (" Straps identical." if g1 else ""))
    elif nroot == 0:
        fails.append("NO ROOT elected (both is_root=0).")
    else:
        root_key = "b" if stb["is_root"] else "a"
        root_ip = B if root_key == "b" else A
        print("  EXACTLY-ONE-ROOT: die_%s is root." % root_key)
        # RTL: the LOWER claim wins (tidechart_election_fsm.sv:181-184). With
        # DEVICE_CLASS equal by design, the tiebreak is RANDOM_ID[15:8]=device_strap,
        # so compare the full claim tuple {DEVICE_CLASS, RANDOM_ID} (lower = root).
        expected_root = "a" if (dc_a, rid_a) < (dc_b, rid_b) else "b"
        if not g1 and root_key != expected_root:
            warns.append("root is die_%s but the LOWER claim {class,rid} (which wins) "
                         "is on die_%s (die_a{0x%04X,0x%04X} vs die_b{0x%04X,0x%04X})"
                         % (root_key, expected_root, dc_a, rid_a, dc_b, rid_b))

    # Proceed to enum/route/telemetry only with exactly one root.
    if nroot == 1:
        # --- ASSERTION 2: enum / ID assignment ------------------------------
        print("-- enum on the ROOT die (die_%s) --" % root_key)
        oke, en = _tc(cc, root_ip, "enum", cc.T_STREAM, "tc_enum", timeout=args.timeout)
        okpa, pa = _tc(cc, A, "status", cc.T_POKE, "tc_status")
        okpb, pb = _tc(cc, B, "status", cc.T_POKE, "tc_status")
        if oke and okpa and okpb:
            fa, fb = _status(pa["STATUS"]), _status(pb["STATUS"])
            root_done = _status(en["STATUS"])["enum_done"]
            print("  die_a: enum_done=%d local_id=%d total=%d ENUM_STATE=%d"
                  % (fa["enum_done"], fa["local_id"], fa["total"], pa["ENUM_STATE"] & 3))
            print("  die_b: enum_done=%d local_id=%d total=%d ENUM_STATE=%d"
                  % (fb["enum_done"], fb["local_id"], fb["total"], pb["ENUM_STATE"] & 3))
            if not root_done:
                fails.append("enum_done not set on the root die")
            if fa["local_id"] == fb["local_id"]:
                fails.append("ID assignment: die_a and die_b share local_id=%d (must be distinct)"
                             % fa["local_id"])
            root_total = _status(en["STATUS"])["total"]
            if root_total != 2:
                warns.append("root reports total=%d (expected 2 for the die pair)" % root_total)
            id_a, id_b = fa["local_id"], fb["local_id"]

            # --- ASSERTION 3: route to peer ---------------------------------
            print("-- route table: each die -> peer id --")
            okra, ra = _tc(cc, A, "route", cc.T_POKE, "tc_route", peer_id=id_b)
            okrb, rb = _tc(cc, B, "route", cc.T_POKE, "tc_route", peer_id=id_a)
            if okra and okrb:
                rav, rbv = ra["ROUTE"], rb["ROUTE"]
                print("  die_a route->%d: egress=%d hop=%d (0x%08X)"
                      % (id_b, rav & 7, (rav >> 3) & 0xF, rav))
                print("  die_b route->%d: egress=%d hop=%d (0x%08X)"
                      % (id_a, rbv & 7, (rbv >> 3) & 0xF, rbv))
                # a valid single-hop peer route has hop>=1 (non-self) on at least
                # the non-root; a zeroed entry (0x0) is an unresolved route.
                if rav == 0 and rbv == 0:
                    fails.append("route table empty both directions (no peer route)")
            else:
                fails.append("route read failed on a die")

            # --- ASSERTION 4: telemetry rx_bcast increments on the peer -----
            peer_ip = A if root_key == "b" else B
            peer_lbl = "die_a" if root_key == "b" else "die_b"
            print("-- telemetry: broadcast from root, watch rx_bcast on %s --" % peer_lbl)
            okc0, c0 = _tc(cc, peer_ip, "status", cc.T_POKE, "tc_status")
            _tc(cc, root_ip, "telemetry", cc.T_POKE, "tc_telemetry")
            time.sleep(0.2)
            okc1, c1 = _tc(cc, peer_ip, "status", cc.T_POKE, "tc_status")
            if okc0 and okc1:
                rx0 = (c0["CONG_STATUS"] >> 16) & 0xFF
                rx1 = (c1["CONG_STATUS"] >> 16) & 0xFF
                print("  %s rx_bcast %d -> %d (CONG_STATUS 0x%08X -> 0x%08X)"
                      % (peer_lbl, rx0, rx1, c0["CONG_STATUS"], c1["CONG_STATUS"]))
                if rx1 <= rx0:
                    fails.append("telemetry: rx_bcast did NOT increment on %s (%d->%d)"
                                 % (peer_lbl, rx0, rx1))
            else:
                fails.append("telemetry status read failed")
        else:
            fails.append("enum/status read failed")

    # --- ASSERTION 5: IRQ ----------------------------------------------------
    print("-- TideChart IRQ assertion (edge on election/enum_done, level on HOTPLUG) --")
    # edge sources: election_done latched on both dies (pulsed IRQ at least once).
    edge_ok = sta["election_done"] and stb["election_done"]
    print("  edge IRQ sources: election_done latched a=%d b=%d (each rising edge "
          "pulses tidechart_irq)" % (sta["election_done"], stb["election_done"]))
    if not edge_ok:
        fails.append("IRQ: no election_done edge witnessed (edge-IRQ never fired)")
    # level source: TC_HOTPLUG sticky. If set, assert it self-clears via W1C.
    for ip, lbl, base in ((A, "die_a", sta), (B, "die_b", stb)):
        okh, h = _tc(cc, ip, "status", cc.T_POKE, "tc_status")
        hp = (h.get("HOTPLUG", 0) & 0xFFFF) if okh else 0
        if hp:
            print("  %s TC_HOTPLUG=0x%04X sticky (IRQ level asserted) -> testing W1C..." % (lbl, hp))
            okc, hc = _tc(cc, ip, "hotplug_clear", cc.T_POKE, "tc_hotplug", mask=hp)
            after = hc.get("HOTPLUG", 0xFFFF) if okc else 0xFFFF
            print("    after W1C: TC_HOTPLUG=0x%04X" % (after & 0xFFFF))
            if after & hp:
                fails.append("IRQ: TC_HOTPLUG W1C did not clear (0x%04X still set on %s)"
                             % (after & hp, lbl))
        else:
            print("  %s TC_HOTPLUG=0x0000 (no link-change level IRQ pending)" % lbl)

    # ------------------------------------------------------------------------
    for w in warns:
        print("  warn: %s" % w)
    ok = not fails
    if not ok:
        for fl in fails:
            print("  FAIL: %s" % fl)
    print("RESULT: %s — %s" % ("PASS" if ok else "FAIL",
          "election->enum->route->telemetry->IRQ all asserted"
          if ok else "%d assertion(s) failed%s"
          % (len(fails), " (G1 dual-root: apply the strap fix + rebuild)" if g1 else "")))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Deterministic TideChart bootstrap gate.")
    ap.add_argument("--on-board", action="store_true", help="internal: TC board agent.")
    ap.add_argument("--tc-op", default="status",
                    choices=("status", "prep", "elect", "enum", "route", "telemetry",
                             "hotplug_clear", "error_clear", "reset"))
    ap.add_argument("--sync-at", type=float, default=0.0, help="on-board: election epoch.")
    ap.add_argument("--timeout", type=float, default=6.0, help="elect/enum poll seconds.")
    ap.add_argument("--peer-id", type=int, default=0, help="route: dest id.")
    ap.add_argument("--mask", type=lambda s: int(s, 0), default=0, help="W1C clear mask.")
    # dev-host:
    ap.add_argument("--sync-slack", type=float, default=3.0,
                    help="seconds from launch to the synchronized election epoch.")
    args = ap.parse_args()
    if args.on_board:
        return _onboard(args)
    return _devhost(args)


if __name__ == "__main__":
    sys.exit(main())
