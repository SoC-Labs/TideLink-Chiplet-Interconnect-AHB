#!/usr/bin/env python3
# =============================================================================
# campaign_iter.py — ONE iteration of the KR260 eth-chiplet weekend soak.
#
# A single, fully-seeded iteration state machine. Everything an iteration does is
# reproducible from `--seed S` alone (derive_plan is pure); a failing weekend run
# is replayed bit-for-bit with:  campaign_iter.py --seed S
#
# Assumes the link is ALREADY UP (FCSM=4 both dies) — the outer driver
# (weekend_campaign.sh) POR-reflashes-brings-up FRESH dies before calling us, per
# the hard safety rule "bring-up only on freshly-POR'd dies; never re-bring-up a
# live link". We only run the wedge-safe data plane on top.
#
# What one iteration does:
#   1. derive_plan(seed): randomise the corner (direction, workload, soak length,
#      teardown timing, role-swap, rare peer-readback probe, payload class).
#   2. Verify link FCSM=4 both dies (RO). Down -> NOCONVERGE, no soak.
#   3. Arm the CAM once (xfer sender / mbox_send) — kr260_eth_soak_fwd.py write
#      does NOT arm the CAM itself.
#   4. Soak in ~200-beat chunks with the WEDGE-SAFE model: sender fires peer WRITES
#      (crosses the link); receiver reads its OWN local SRAM back (no link
#      traversal on the read => the verify can never wedge). Between chunks, append
#      a flight-recorder health line per die (RO snapshot).
#   5. Every board/peer access is subprocess-timeout-wrapped. A timeout == a PS-bus
#      WEDGE (the eth-chiplet AXI data plane hangs with NO software timeout).
#   6. On WEDGE or MISMATCH: snapshot the SURVIVING die (the one that only did local
#      reads), write failures/iterN_seedS.json (plan + snapshots + one-line repro),
#      THEN trigger a JTAG-POR of the wedged board.
#   7. Classify PASS | MISMATCH | WEDGE | NOCONVERGE and append one JSON line to
#      OUT/iterations.jsonl.
#
# Companion artifacts (in the parent scripts/ dir): xfer_corners_lib.py provides
# the seeded golden generator golden(seed,i) + the BOARD-SIDE snap_health() and the
# pure classify_wedge(h) (CLASSIC|AXI_WEDGE|HELD_REPLAY|NONE); health_snapshot.py is
# the on-board RO one-shot dump. Because snap_health() reads /dev/mem on the board,
# from the dev host we drive health_snapshot.py over ssh, parse its dump, and feed
# the parsed dict to xfer_corners_lib.classify_wedge(h) (pure). The soak base is
# anchored to xfer_corners_lib.golden(seed,0). Every companion call has a
# self-contained fallback (parsing the proven kr260_eth_xfer.py fc_health mode, and
# a local copy of the classify heuristic) so the weekend run never dies on a
# companion-API mismatch at 3am.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import hashlib
import json
import math
import os
import random
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))                 # .../scripts/weekend
SCRIPTS_DIR = os.path.dirname(HERE)                               # .../scripts
POR_SH = os.path.join(HERE, "por_recover.sh")
sys.path.insert(0, SCRIPTS_DIR)

# ---- companion library (assume-exists, fall back if the API drifts) ---------
try:
    import xfer_corners_lib as xcl
except Exception:                                                 # pragma: no cover
    xcl = None

# ---- board / addressing constants -------------------------------------------
DEFAULT_A_IP = os.environ.get("KR260_DIEA_IP", "10.22.24.159")    # kr260_01
DEFAULT_B_IP = os.environ.get("KR260_DIEB_IP", "10.22.24.153")    # kr260_02
IP_TO_TARGET = {DEFAULT_A_IP: "kr260_01", DEFAULT_B_IP: "kr260_02"}
PW = os.environ.get("KR260_PASSWORD", "soclabs2026")
KR260_USER = os.environ.get("KR260_USER", "ubuntu")
DEST_DIR = os.environ.get("KR260_DEST", "td")

# board-side scripts (staged at ~/td/scripts/ by the deploy)
SOAK_FWD = "scripts/kr260_eth_soak_fwd.py"
XFER = "scripts/kr260_eth_xfer.py"
HEALTH1 = "scripts/health_snapshot.py"

CHUNK_BEATS = int(os.environ.get("CHUNK_BEATS", "200"))
AXI_NODES = ("AW", "W", "B", "AR", "R")                           # the wedge-prone data nodes

# per-access subprocess timeouts (seconds). A hit == WEDGE.
T_WRITE = int(os.environ.get("T_WRITE", "60"))
T_VERIFY = int(os.environ.get("T_VERIFY", "60"))
T_HEALTH = int(os.environ.get("T_HEALTH", "45"))
T_ARM = int(os.environ.get("T_ARM", "60"))


class WedgeTimeout(Exception):
    """A board/peer access hung past its subprocess timeout == PS-bus wedge."""
    def __init__(self, host, stage):
        super().__init__("WEDGE host=%s stage=%s" % (host, stage))
        self.host = host
        self.stage = stage


# =============================================================================
# Plan derivation — PURE, reproducible from seed alone.
# =============================================================================
def _seed_int(namespace, seed):
    """Stable process-independent integer seed. (random.Random(tuple-with-str) is
    NOT reproducible: CPython salts str hashing via PYTHONHASHSEED.)"""
    h = hashlib.sha256(("%s:%d" % (namespace, int(seed))).encode()).hexdigest()
    return int(h[:16], 16)


def derive_plan(seed):
    rng = random.Random(_seed_int("kr260-eth-weekend", seed))

    # payload class -> how the golden base is picked (soak writes base+i so the
    # receiver's local read verifies base+i deterministically).
    pclass = rng.choice(["increment", "walking_ones", "low_entropy",
                         "high_entropy", "doorbell_isolated"])
    base = golden_base(seed, pclass, rng)

    # direction: weight toward reverse (slave->master), TideLink's flagged-hard dir.
    direction = "rev" if rng.random() < 0.60 else "fwd"

    workload = rng.choices(["sram", "mailbox", "mixed"], weights=[6, 2, 2])[0]

    # soak length: log-uniform 100..20000 beats.
    lo, hi = 100.0, 20000.0
    soak_len = int(round(10 ** rng.uniform(math.log10(lo), math.log10(hi))))
    soak_len = max(100, min(20000, soak_len))

    teardown = rng.choices(["graceful", "abrupt", "early"], weights=[5, 3, 2])[0]

    # role-swap every Kth seed: exercise both physical boards in both roles.
    role_swap_k = int(os.environ.get("ROLE_SWAP_K", "4"))
    role_swap = (seed % role_swap_k) == 0

    # rare wedge-prone peer-readback probe (opt-in extra coverage).
    readback_probe = rng.random() < 0.15

    a_ip, b_ip = DEFAULT_A_IP, DEFAULT_B_IP
    if role_swap:
        a_ip, b_ip = b_ip, a_ip                                  # die_a image -> other board
    role_map = {"die_a": a_ip, "die_b": b_ip}

    # direction picks which role is the SENDER (peer-writer) / RECEIVER (local-read)
    if direction == "fwd":
        sender_role, recv_role = "die_a", "die_b"
    else:
        sender_role, recv_role = "die_b", "die_a"

    return {
        "seed": seed,
        "payload_class": pclass,
        "payload_base": base & 0xFFFFFFFF,
        "direction": direction,
        "sender_role": sender_role,
        "recv_role": recv_role,
        "workload": workload,
        "soak_len": soak_len,
        "chunk_beats": CHUNK_BEATS,
        "teardown": teardown,
        "role_swap": role_swap,
        "readback_probe": readback_probe,
        "role_map": role_map,
        "sender_ip": role_map[sender_role],
        "recv_ip": role_map[recv_role],
        "repro": "campaign_iter.py --seed %d" % seed,
    }


def golden_base(seed, pclass="increment", rng=None):
    """Deterministic 32-bit soak base for kr260_eth_soak_fwd.py (which writes
    base+i and the receiver verifies base+i locally). We tie the base to the
    companion's seeded generator — xfer_corners_lib.golden(seed, 0) — so the soak
    payload is anchored in the same golden stream, with a version-stable local
    fallback for isolation. (soak_fwd uses the base+i ramp, NOT xcl.golden's
    per-beat payload classes — that richer generator drives kr260_eth_xfer.py's
    own corner mode, a separate path.)"""
    if xcl is not None and hasattr(xcl, "golden"):
        try:
            v, _cls = xcl.golden(int(seed), 0)
            return int(v) & 0xFFFFFFFF
        except Exception:
            pass
    if rng is None:
        rng = random.Random(_seed_int("golden", seed))
    if pclass == "walking_ones":
        return (1 << (seed % 32)) & 0xFFFFFFFF
    if pclass == "low_entropy":
        return 0xA5A50000
    if pclass == "doorbell_isolated":
        return 0x00000001                                        # the T2 isolated-doorbell corner
    if pclass == "high_entropy":
        return rng.getrandbits(32)
    # increment
    return (0xC0FFEE00 ^ ((seed * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF


# =============================================================================
# Board access — every call subprocess-timeout-wrapped. Timeout => WedgeTimeout.
# =============================================================================
def _ssh_board(host, remote, timeout, stage):
    """Run `remote` on the board as root over ssh. Returns (rc, combined_output).
    Raises WedgeTimeout if the access hangs past `timeout` (== PS-bus wedge)."""
    full = "cd %s && echo '%s' | sudo -S bash -c %s" % (DEST_DIR, PW, _shq(remote))
    cmd = ["sshpass", "-p", PW, "ssh",
           "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15",
           "-o", "ServerAliveInterval=15", "%s@%s" % (KR260_USER, host), full]
    try:
        p = subprocess.run(cmd, timeout=timeout, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        raise WedgeTimeout(host, stage)


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def board_python(host, script_args, timeout, stage):
    return _ssh_board(host, "python3 %s" % script_args, timeout, stage)


# ---- soak primitives (wedge-safe) -------------------------------------------
def arm_cam(sender_ip, workload):
    """Issue the single CAM-arming access after bring-up, before the first chunk.
    kr260_eth_soak_fwd.py write does NOT arm the CAM. SRAM path -> xfer sender
    (CAM 0x2F->0x2D); mailbox path -> mbox_send (CAM 0x2F->0x23)."""
    mode = "mbox_send" if workload == "mailbox" else "sender"
    rc, out = board_python(sender_ip, "%s --mode %s --payload 0x%08X"
                           % (XFER, mode, 0xC0FFEE01), T_ARM, "arm")
    return rc, out


def soak_write(sender_ip, n, base):
    rc, out = board_python(sender_ip, "%s write %d 0x%08X" % (SOAK_FWD, n, base),
                           T_WRITE, "write")
    return rc, out


def soak_verify(recv_ip, n, base):
    """Receiver reads its OWN local SRAM (no link traversal). rc 0 == all byte-exact.
    Returns (ok, ok_count, firstbad_dict_or_None)."""
    rc, out = board_python(recv_ip, "%s verify %d 0x%08X" % (SOAK_FWD, n, base),
                           T_VERIFY, "verify")
    ok = rc == 0 and "byte-exact" in out
    okc, firstbad = _parse_verify(out)
    return ok, okc, firstbad


def _parse_verify(out):
    m = re.search(r"VERIFY\s+(\d+)/(\d+)\s+byte-exact", out)
    okc = int(m.group(1)) if m else 0
    fb = re.search(r"firstbad=idx(\d+)\s+got0x([0-9A-Fa-f]+)\s+exp0x([0-9A-Fa-f]+)", out)
    firstbad = None
    if fb:
        idx = int(fb.group(1))
        firstbad = {"idx": idx, "addr": "0x%08X" % (0x2D001000 + idx * 4),
                    "got": "0x%08X" % int(fb.group(2), 16),
                    "exp": "0x%08X" % int(fb.group(3), 16)}
    return okc, firstbad


def mbox_beat(sender_ip, recv_ip, payload):
    """One mailbox message crossing: sender writes slot0 (peer, crosses link),
    receiver reads local mailbox. Returns (ok, detail)."""
    board_python(sender_ip, "%s --mode mbox_send --payload 0x%08X" % (XFER, payload),
                 T_WRITE, "mbox_send")
    rc, out = board_python(recv_ip, "%s --mode mbox_recv --payload 0x%08X" % (XFER, payload),
                           T_VERIFY, "mbox_recv")
    return ("RESULT: PASS" in out), out


def readback_probe(sender_ip, base):
    """The rare, opt-in, WEDGE-PRONE peer READ round-trip (one shot). soak_fwd has
    no readback mode, so use the proven kr260_eth_xfer.py readback (peer read that
    traverses the link — this is the wedge-prone access, hence timeout-wrapped)."""
    rc, out = board_python(sender_ip, "%s --mode readback --payload 0x%08X" % (XFER, base),
                           T_VERIFY, "readback")
    return ("PASS" in out), out


# ---- health snapshot (RO) ---------------------------------------------------
# Region F wedge-sticky / live-stall bit order is {r, ar, b, w, aw} = bit0..bit4
# (xfer_corners_lib._regf_names). Map those bits to the AXI node names.
REGF_NODE_BITS = ("R", "AR", "B", "W", "AW")


def snap_health(ip, role, timeout=T_HEALTH):
    """RO health snapshot of one die. The companion snap_health()/classify_wedge()
    are BOARD-SIDE (they read /dev/mem locally), so from the dev host we drive the
    canonical on-board RO one-shot health_snapshot.py over ssh and parse its dump.
    Then we classify with xfer_corners_lib.classify_wedge(h) (pure — operates on the
    parsed dict). On a hung PS bus this ssh itself times out -> {'timeout': True}
    (also a WEDGE indicator: even RO backdoor reads hang once the bus saturates)."""
    try:
        rc, out = board_python(ip, "%s" % HEALTH1, timeout, "health")
    except WedgeTimeout:
        return {"timeout": True, "role": role, "ip": ip, "ts": time.time()}
    h = _parse_health_snapshot(out)
    h.update({"role": role, "ip": ip, "ts": time.time(), "raw": out.strip()})
    h["wedge_class"] = classify_health(h)
    h["wedge_nodes"] = wedge_nodes(h)
    return h


def _hx(pat, out, default=0, base=16):
    m = re.search(pat, out)
    return int(m.group(1), base) if m else default


def _parse_health_snapshot(out):
    """Parse health_snapshot.py's text dump into the dict shape classify_wedge(h)
    expects (a superset of xfer_corners_lib.snap_health())."""
    swi = _hx(r"SWI_LANE\s+0x2108\s*=\s*0x([0-9A-Fa-f]+)", out)
    st = _hx(r"STATUS\s+0x2010\s*=\s*0x([0-9A-Fa-f]+)", out)
    rf = _hx(r"RegionF\s+0x21E0\s*=\s*0x([0-9A-Fa-f]+)", out)
    fcsm = (swi >> 17) & 7
    cal = (swi >> 16) & 1
    marker = (rf >> 24) & 0xFF
    present = marker == 0xAD
    h = {
        "swi_lane": swi, "fcsm": fcsm, "cal": cal,
        "cr_seen": (swi >> 23) & 1, "crack": (swi >> 24) & 1,
        "fe_rx_full": (swi >> 31) & 1,
        "link_up": (fcsm == 4 and cal == 1),
        "status": st, "sticky": st & 0xE,
        "credit": _hx(r"CREDIT_CNT\s+0x200C\s*=\s*(\d+)", out, base=10),
        "regf_raw": rf, "regf_marker": marker, "regf_present": present,
        "tgt_wsticky": (rf >> 10) & 0x1F, "ini_wsticky": (rf >> 15) & 0x1F,
        "tgt_live": rf & 0x1F, "ini_live": (rf >> 5) & 0x1F,
        "tgt_resperr": (rf >> 20) & 1, "ini_resperr": (rf >> 21) & 1,
        "data_healthy": (rf >> 23) & 1,
        "result_healthy": "RESULT: HEALTHY" in out,
    }
    return h


def wedge_nodes(h):
    """The AXI node(s) named by the Region F wedge-sticky bits (authoritative
    per-node wedge signature). Union of target+initiator sticky."""
    if not h.get("regf_present"):
        return []
    mask = (h.get("tgt_wsticky", 0) | h.get("ini_wsticky", 0)) & 0x1F
    return [name for i, name in enumerate(REGF_NODE_BITS) if (mask >> i) & 1]


def classify_health(h):
    """Wedge class for a parsed health dict: prefer the companion classifier
    (xfer_corners_lib.classify_wedge(h) -> CLASSIC|AXI_WEDGE|HELD_REPLAY|NONE);
    fall back to the same heuristic locally."""
    if xcl is not None and hasattr(xcl, "classify_wedge"):
        try:
            r = xcl.classify_wedge(h)
            if isinstance(r, str):
                return r
        except Exception:
            pass
    if h.get("fe_rx_full"):
        return "CLASSIC"
    if h.get("regf_present") and (h.get("tgt_wsticky") or h.get("ini_wsticky")):
        return "AXI_WEDGE"
    if h.get("regf_present") and (h.get("tgt_live") or h.get("ini_live")
                                  or h.get("tgt_resperr") or h.get("ini_resperr")):
        return "HELD_REPLAY"
    if h.get("sticky"):
        return "HELD_REPLAY"
    return "NONE"


def fc_health(ip, timeout=T_HEALTH):
    """Per-node Wlink FC snapshot (RO) via kr260_eth_xfer.py fc_health — gives the
    per-node CRC-error count + Ack/Nack-FIFO state the Region F sticky plane does
    not carry. Sampled at wedge time to enrich the taxonomy. Never raises."""
    try:
        rc, out = board_python(ip, "%s --mode fc_health" % XFER, timeout, "fc_health")
    except WedgeTimeout:
        return {"timeout": True}
    nodes = {}
    for line in out.splitlines():
        m = re.match(r"\s*(AW|W|B|AR|R|GenBus|TideLink)\s+(\d+)\s+(\d)/(\d)/(\d)\s+(\d)",
                     line)
        if m:
            nodes[m.group(1)] = {"crc": int(m.group(2)), "empty": int(m.group(3)),
                                 "full": int(m.group(4)), "half": int(m.group(5)),
                                 "txfifo_empty": int(m.group(6))}
    return nodes


def build_taxonomy(surviving, fc_nodes, last_good_sender, meta):
    """Fold the surviving-die health + per-node FC into a taxonomy: the wedge
    class, the Region-F-named node(s), per-node CRC-hot / non-empty from fc_health,
    and a one-line reason. last_good_sender is the most diagnostic (captured just
    before the wedge, on the die that then hung)."""
    crc_hot, nonempty = [], []
    for name in AXI_NODES:
        nd = (fc_nodes or {}).get(name)
        if isinstance(nd, dict):
            if nd.get("crc", 0) > 0:
                crc_hot.append(name)
            if nd.get("empty", 1) == 0:
                nonempty.append(name)
    # authoritative node names from whichever snapshot has the sticky bits
    wnodes = []
    for snap in (last_good_sender, surviving):
        wnodes = wedge_nodes(snap) if isinstance(snap, dict) else []
        if wnodes:
            break
    cls = None
    for snap in (surviving, last_good_sender):
        if isinstance(snap, dict) and not snap.get("timeout"):
            cls = snap.get("wedge_class") or classify_health(snap)
            break
    node = (wnodes or crc_hot or nonempty or ["?"])[0]
    if node == "?":
        reason = ("no per-node evidence (both the wedged sender snapshot and the "
                  "Region F sticky read hung — full PS-bus saturation)")
    elif node in crc_hot:
        reason = "%s CRC-hot (bit error, drift/eye; no socl_reack backstop)" % node
    elif node in wnodes:
        reason = "%s wedge-sticky latched (AXI FC node stopped emitting)" % node
    else:
        reason = "%s non-empty Ack/Nack FIFO (credit/ACK stall)" % node
    return {"class": cls, "node": node, "wedge_nodes": wnodes,
            "crc_hot": crc_hot, "nonempty": nonempty,
            "stage": meta.get("stage"), "reason": reason}


# =============================================================================
# JSONL result emit + failure snapshot
# =============================================================================
def append_jsonl(out_dir, obj):
    path = os.path.join(out_dir, "iterations.jsonl")
    with open(path, "a") as f:
        f.write(json.dumps(obj, sort_keys=True) + "\n")


def append_recorder(out_dir, seed, role, snap):
    path = os.path.join(out_dir, "recorder", "die_%s_seed%d.jsonl" % (role, seed))
    with open(path, "a") as f:
        f.write(json.dumps(snap, sort_keys=True) + "\n")
    return os.path.relpath(path, out_dir)


def write_failure(out_dir, plan, verdict, wedge, taxonomy, snapshots, iter_n):
    name = "iter%s_seed%d.json" % (iter_n if iter_n is not None else "X", plan["seed"])
    path = os.path.join(out_dir, "failures", name)
    doc = {
        "verdict": verdict,
        "seed": plan["seed"],
        "iter": iter_n,
        "plan": plan,
        "wedge": wedge,
        "taxonomy": taxonomy,
        "snapshots": snapshots,
        "repro": plan["repro"],
        "ts": time.time(),
    }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
    return os.path.relpath(path, out_dir)


def trigger_por(out_dir, ip):
    """JTAG-POR the wedged board (via por_recover.sh). Best-effort; the outer
    driver also POR-reflashes both dies at the start of the next iteration."""
    target = IP_TO_TARGET.get(ip)
    if not target:
        return
    env = dict(os.environ)
    env["OUT"] = out_dir
    try:
        subprocess.run(["bash", POR_SH, target], env=env, timeout=600)
    except Exception as e:                                       # never let POR crash the iter
        sys.stderr.write("trigger_por: %s\n" % e)


# =============================================================================
# The iteration
# =============================================================================
def mailbox_budget(soak_len):
    # mailbox messages are per-ssh (slow); cap them but keep them seed-scaled.
    return max(4, min(64, soak_len // 200))


def run_iteration(plan, out_dir, iter_n):
    seed = plan["seed"]
    sender_ip, recv_ip = plan["sender_ip"], plan["recv_ip"]
    sender_role, recv_role = plan["sender_role"], plan["recv_role"]
    t0 = time.time()

    result = {
        "seed": seed, "iter": iter_n, "ts_start": t0,
        "direction": plan["direction"], "workload": plan["workload"],
        "soak_len": plan["soak_len"], "teardown": plan["teardown"],
        "role_swap": plan["role_swap"], "readback_probe": plan["readback_probe"],
        "payload_class": plan["payload_class"],
        "payload_base": "0x%08X" % plan["payload_base"],
        "beats_done": 0, "chunks_done": 0,
        "mismatch": None, "wedge": None, "failure_file": None,
        "credit": {"min": None, "max": None, "recovered": False},
        "recorder": {}, "repro": plan["repro"], "verdict": "PASS",
    }
    last_good = {"die_a": None, "die_b": None}
    cc_seen = []

    def record(role, ip):
        snap = snap_health(ip, role)
        if not snap.get("timeout"):
            last_good[role] = snap
            cc = snap.get("credit")
            if isinstance(cc, int):
                cc_seen.append(cc)
        result["recorder"][role] = append_recorder(out_dir, seed, role, snap)
        return snap

    def finish(verdict):
        result["verdict"] = verdict
        result["ts_end"] = time.time()
        result["wall_s"] = round(result["ts_end"] - t0, 2)
        if cc_seen:
            result["credit"]["min"] = min(cc_seen)
            result["credit"]["max"] = max(cc_seen)
            # credit "recovered" = counter dipped then climbed back (drain/refill).
            result["credit"]["recovered"] = (min(cc_seen) < max(cc_seen)
                                             and cc_seen[-1] >= cc_seen[0])
        append_jsonl(out_dir, result)
        return result

    def on_wedge(exc, stage_hint=None):
        stage = getattr(exc, "stage", stage_hint) or stage_hint
        wedged_ip = getattr(exc, "host", None)
        wedged_role = sender_role if wedged_ip == sender_ip else recv_role
        surv_role = recv_role if wedged_role == sender_role else sender_role
        surv_ip = plan["role_map"][surv_role]
        # snapshot the SURVIVING die (the one that only did local reads) — the
        # wedged die's PS bus is saturated and will itself hang.
        surv = snap_health(surv_ip, surv_role)
        surv_fc = fc_health(surv_ip)
        meta = {"stage": stage, "wedged_ip": wedged_ip, "wedged_role": wedged_role}
        tax = build_taxonomy(surv, surv_fc, last_good.get(sender_role), meta)
        result["wedge"] = {"host": wedged_ip, "role": wedged_role,
                           "stage": stage, "target": IP_TO_TARGET.get(wedged_ip),
                           "class": tax.get("class"), "taxonomy": tax}
        snaps = {"surviving": surv, "surviving_fc": surv_fc,
                 "last_good_die_a": last_good.get("die_a"),
                 "last_good_die_b": last_good.get("die_b")}
        result["failure_file"] = write_failure(out_dir, plan, "WEDGE",
                                               result["wedge"], tax, snaps, iter_n)
        trigger_por(out_dir, wedged_ip)                          # THEN recover
        return finish("WEDGE")

    # -- 2. link must be UP on both (RO). Down -> NOCONVERGE, no soak. ---------
    sa = snap_health(sender_ip, sender_role)
    sb = snap_health(recv_ip, recv_role)
    for role, snap in ((sender_role, sa), (recv_role, sb)):
        if not snap.get("timeout"):
            last_good[role] = snap
    if sa.get("timeout") or sb.get("timeout") or \
       not sa.get("link_up") or not sb.get("link_up"):
        return finish("NOCONVERGE")

    # -- 3. arm the CAM ONCE before the first chunk ---------------------------
    try:
        arm_cam(sender_ip, "sram" if plan["workload"] != "mailbox" else "mailbox")
    except WedgeTimeout as e:
        return on_wedge(e, "arm")

    # -- 4/5. soak in chunks, wedge-safe, flight-recorder between chunks -------
    soak_len = plan["soak_len"]
    workload = plan["workload"]
    # teardown timing shapes how far we actually run the soak.
    if plan["teardown"] == "early":
        soak_len = min(soak_len, plan["chunk_beats"])            # stop after ~1 chunk
    n_chunks = max(1, (soak_len + plan["chunk_beats"] - 1) // plan["chunk_beats"])
    # 'abrupt' teardown: stop ~2/3 in without a graceful settle.
    abrupt_stop = int(n_chunks * 2 / 3) if plan["teardown"] == "abrupt" else n_chunks

    mbox_left = mailbox_budget(soak_len)
    try:
        for ci in range(n_chunks):
            if plan["teardown"] == "abrupt" and ci >= abrupt_stop and ci >= 1:
                break
            n = min(plan["chunk_beats"], soak_len - result["beats_done"])
            if n <= 0:
                break
            # choose this chunk's transport (mixed alternates, re-arming the CAM)
            use_mbox = (workload == "mailbox") or (workload == "mixed" and ci % 2 == 1)
            base_c = (plan["payload_base"] + ci) & 0xFFFFFFFF

            if use_mbox:
                if workload == "mixed":
                    arm_cam(sender_ip, "mailbox")               # re-arm 0x2F->0x23
                msgs = min(max(1, n // 4), mbox_left)
                good = 0
                for j in range(msgs):
                    ok, _ = mbox_beat(sender_ip, recv_ip, (base_c + j * 4) & 0xFFFFFFFF)
                    if not ok:
                        result["mismatch"] = {"addr": "0x23000000", "got": "?",
                                              "exp": "0x%08X" % ((base_c + j * 4) & 0xFFFFFFFF),
                                              "kind": "mailbox"}
                        return finish("MISMATCH")
                    good += 1
                mbox_left -= msgs
                result["beats_done"] += good * 4
            else:
                if workload == "mixed":
                    arm_cam(sender_ip, "sram")                  # re-arm 0x2F->0x2D
                soak_write(sender_ip, n, base_c)
                ok, okc, firstbad = soak_verify(recv_ip, n, base_c)
                result["beats_done"] += okc
                if not ok:
                    result["mismatch"] = firstbad or {"note": "verify failed, no firstbad"}
                    return finish("MISMATCH")

            result["chunks_done"] += 1
            # flight-recorder health line per die between chunks
            record(sender_role, sender_ip)
            record(recv_role, recv_ip)

            if workload == "mailbox" and mbox_left <= 0:
                break

        # -- 6b. rare opt-in wedge-prone peer-readback probe ------------------
        if plan["readback_probe"] and plan["teardown"] != "abrupt":
            ok, _ = readback_probe(sender_ip, plan["payload_base"])
            result["readback_probe_result"] = "PASS" if ok else "FAIL"

    except WedgeTimeout as e:
        return on_wedge(e)

    return finish("PASS")


# =============================================================================
# Entry points
# =============================================================================
def _print_env(plan):
    print("SEED=%d" % plan["seed"])
    print("DIE_A_IP=%s" % plan["role_map"]["die_a"])
    print("DIE_B_IP=%s" % plan["role_map"]["die_b"])
    print("DIRECTION=%s" % plan["direction"])
    print("WORKLOAD=%s" % plan["workload"])
    print("SOAK_LEN=%d" % plan["soak_len"])
    print("TEARDOWN=%s" % plan["teardown"])
    print("ROLE_SWAP=%d" % (1 if plan["role_swap"] else 0))
    print("PAYLOAD_CLASS=%s" % plan["payload_class"])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--iter", type=int, default=None,
                    help="iteration index for labelling (informational).")
    ap.add_argument("--out", default=None, help="campaign output dir.")
    ap.add_argument("--print-plan", action="store_true",
                    help="print the derived plan as JSON and exit (RO, no board).")
    ap.add_argument("--print-env", action="store_true",
                    help="print shell KEY=VALUE for the outer driver and exit (RO).")
    ap.add_argument("--record-noconverge", action="store_true",
                    help="append one NOCONVERGE line to iterations.jsonl and exit "
                         "(RO; used by the driver when bring-up never reached fcsm=4).")
    args = ap.parse_args()

    plan = derive_plan(args.seed)

    if args.print_plan:
        print(json.dumps(plan, indent=2, sort_keys=True))
        return 0
    if args.print_env:
        _print_env(plan)
        return 0

    if not args.out:
        sys.stderr.write("ERROR: --out is required for a real iteration.\n")
        return 2
    os.makedirs(os.path.join(args.out, "failures"), exist_ok=True)
    os.makedirs(os.path.join(args.out, "recorder"), exist_ok=True)

    if args.record_noconverge:
        append_jsonl(args.out, {
            "seed": args.seed, "iter": args.iter, "verdict": "NOCONVERGE",
            "direction": plan["direction"], "workload": plan["workload"],
            "soak_len": plan["soak_len"], "role_swap": plan["role_swap"],
            "teardown": plan["teardown"], "beats_done": 0, "chunks_done": 0,
            "ts_start": time.time(), "ts_end": time.time(), "wall_s": 0.0,
            "repro": plan["repro"],
        })
        return 0

    res = run_iteration(plan, args.out, args.iter)
    print("iter seed=%d verdict=%s beats=%d chunks=%d dir=%s workload=%s"
          % (args.seed, res["verdict"], res["beats_done"], res["chunks_done"],
             plan["direction"], plan["workload"]))
    return 0 if res["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
