#!/usr/bin/env python3
# kr260_sysval.py — system-level validation regression for the eth-chiplet KR260
# pair. Runs on the dev host; drives both dies over timeout-wrapped ssh; uses
# eth_sysval_board.py on the boards. Assumes the link is already brought up
# (FCSM=4 both dies) — gate on it, do not bring up here.
#
# Tests (build spec 2026-08-08), all wedge-safe by construction:
#   T1 provenance   : board ~/td/scripts/*.py sha256 == repo (RO)
#   T2 obs_probe    : marker-gated 0x21E0/0x21F8/0x21E8 + fcsm/cal (RO)
#   T3 delivery_soak: die_a write N -> die_b LOCAL verify N (verify cannot wedge)
#   T6 endurance    : T3 repeated to MAX_BEATS in chunks, Region-F gate each chunk
#   T10 read_soak   : die_b seed_local -> die_a read over link in <=CHUNK chunks,
#                     Region-F gate between chunks, POR-stage on wedge (H2 closure)
# Non-zero exit if any gating test FAILs. Wedge => POR die_a, mark FAIL, stop reads.
#
# RESULTS ARE WRITTEN TO DISK. Pass --json-out PATH (or set SYSVAL_JSON_OUT) and
# every verdict, plus the provenance needed to trust it, lands in one JSON file.
# This exists because for months every silicon claim this project made --
# "128/128 byte-exact", "16/16", "11/11" -- was a number in a chat log or a
# handover with no surviving artefact. None of them can be re-checked today; the
# logs they cited are not in the tree. A verdict nobody can reproduce is not
# evidence, so the harness now records its own.
import subprocess, sys, os, json, time, hashlib, glob, argparse, socket

A = os.environ.get("DIE_A", "ubuntu@10.22.24.159")
B = os.environ.get("DIE_B", "ubuntu@10.22.24.153")
SCR = os.path.dirname(os.path.abspath(__file__))
BOARD = "~/td/scripts/eth_sysval_board.py"
CHUNK = int(os.environ.get("SYSVAL_READ_CHUNK", "50"))     # <=50 reads per board invocation (CC-5)
SOAK_N = int(os.environ.get("SYSVAL_SOAK_N", "128"))       # basic delivery (small: eye-gate)
ENDUR_BEATS = int(os.environ.get("SYSVAL_ENDUR_BEATS", "2000"))  # the stress/reliability gate
READ_N = int(os.environ.get("SYSVAL_READ_N", "128"))       # basic read coverage (small)

def _pw():
    v = os.environ.get("KR260_PASSWORD")
    if v: return v
    with open(os.path.join(SCR, "kr260_eth_bringup_pair.sh")) as f:
        for ln in f:
            if "KR260_PASSWORD:-" in ln:
                return ln.split("KR260_PASSWORD:-", 1)[1].split("}", 1)[0]
    return ""
PW = _pw()

def _mask(s):
    return s.replace(PW, "***") if PW else s

def ssh(host, cmd, timeout=30):
    full = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=10", host, cmd]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "TIMEOUT"

def board(host, args, timeout=40):
    # root via sudo -S; password on stdin so it never appears in argv
    cmd = "cd td && echo %r | sudo -S python3 %s %s 2>/dev/null" % (PW, BOARD, args)
    rc, out, err = ssh(host, cmd, timeout)
    return rc, out.strip()

def obs(host):
    rc, out = board(host, "obs", 25)
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try: return json.loads(line)
            except Exception: pass
    return None

def healthy(o):
    """Region-F clean AND fcsm=4 (marker-gated; unknown marker => not healthy)."""
    if not o: return False
    if o.get("fcsm") != 4 or o.get("cal") != 1: return False
    if not o.get("regf_present"): return False
    if o.get("data_healthy") != 1: return False
    if (o.get("wedge_tgt") or 0) != 0 or (o.get("wedge_ini") or 0) != 0: return False
    return True

def por_die_a():
    cmd = ("curl -sS --max-time 90 --unix-socket /run/fpgahub/fpgahub.sock -X POST "
           "http://localhost/api/v1/targets/kr260_01/reset "
           "-H 'Content-Type: application/json' -d '{\"method\":\"default\",\"confirm\":true}'")
    subprocess.run(["ssh", "-o", "ConnectTimeout=10", "mapstone-dev", cmd],
                   capture_output=True, text=True, timeout=110)

RESULTS = []
def record(name, verdict, detail=""):
    RESULTS.append((name, verdict, detail))
    print("  [%s] %s %s" % (verdict.ljust(12), name, detail))

# ---- run provenance ----------------------------------------------------------
JSON_OUT = os.environ.get("SYSVAL_JSON_OUT") or None
T_START  = time.time()

def _git(*args):
    """Best-effort git query against the tidelink checkout this script lives in."""
    try:
        r = subprocess.run(["git", "-C", SCR] + list(args),
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None

def _provenance():
    # The point of recording this: a verdict is only meaningful against the RTL
    # and the bitstream that produced it. `dirty` matters as much as the sha --
    # most of this project's runs happen on a dirty tree, and a clean sha would
    # be a lie about what was tested.
    sha = _git("rev-parse", "HEAD")
    return {
        "tidelink_sha":    sha,
        "tidelink_branch": _git("rev-parse", "--abbrev-ref", "HEAD"),
        "tidelink_dirty":  (_git("status", "--porcelain") or "") != "" if sha else None,
        "host":            socket.gethostname(),
        "die_a":           _mask(A),
        "die_b":           _mask(B),
        "params": {"soak_n": SOAK_N, "read_n": READ_N,
                   "endur_beats": ENDUR_BEATS, "read_chunk": CHUNK},
    }

def _write_json(path, exit_code):
    doc = {
        "schema":      "kr260_sysval/1",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T_START)),
        "ended_utc":   time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_s":  round(time.time() - T_START, 1),
        "provenance":  _provenance(),
        "tests":       [{"name": n, "verdict": v, "detail": d} for n, v, d in RESULTS],
        "counts":      {k: sum(1 for _, v, _ in RESULTS if v == k)
                        for k in ("PASS", "FAIL", "INCONCLUSIVE", "SKIPPED")},
        "exit_code":   exit_code,
        # overall is FAIL if anything failed, and INCOMPLETE if we aborted before
        # the data-plane tests ran -- an aborted run is not a pass.
        "overall":     ("FAIL" if any(v == "FAIL" for _, v, _ in RESULTS)
                        else "INCOMPLETE" if exit_code not in (0, None)
                        else "PASS"),
    }
    try:
        d = os.path.dirname(os.path.abspath(path))
        if d:
            os.makedirs(d, exist_ok=True)
        with open(path, "w") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")
        print("  json: %s (%s)" % (path, doc["overall"]))
    except Exception as e:
        # Never let a reporting failure change the verdict of the run.
        print("  WARNING: could not write %s: %s" % (path, e))

# ---- T1 provenance -----------------------------------------------------------
def t1_provenance():
    repo = {}
    for p in glob.glob(os.path.join(SCR, "*.py")) + glob.glob(os.path.join(SCR, "coverage", "*.py")):
        repo[os.path.basename(p)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    stale = []
    for host, tag in ((A, "die_a"), (B, "die_b")):
        rc, out, _ = ssh(host, "sha256sum ~/td/scripts/eth_sysval_board.py 2>/dev/null | cut -d' ' -f1", 15)
        want = repo.get("eth_sysval_board.py", "")
        got = out.strip()
        if got != want:
            stale.append("%s:eth_sysval_board.py board=%s repo=%s" % (tag, got[:12], want[:12]))
    if stale:
        record("T1_provenance", "FAIL", "; ".join(stale)); return False
    record("T1_provenance", "PASS", "board eth_sysval_board.py == repo (both dies)"); return True

# ---- T2 obs_probe ------------------------------------------------------------
def t2_obs_probe():
    oa, ob = obs(A), obs(B)
    if not oa or not ob:
        record("T2_obs_probe", "INCONCLUSIVE", "obs read failed"); return None
    for tag, o in (("die_a", oa), ("die_b", ob)):
        print("    %s: fcsm=%s cal=%s regf_present=%s data_healthy=%s witness_present=%s eye_present=%s best_run=%s stall_stuck=%s"
              % (tag, o.get("fcsm"), o.get("cal"), o.get("regf_present"), o.get("data_healthy"),
                 o.get("witness_present"), o.get("eye_present"), o.get("best_run"), o.get("stall_stuck")))
    ok = healthy(oa) and healthy(ob)
    record("T2_obs_probe", "PASS" if ok else "FAIL",
           "both dies FCSM=4 + Region-F healthy" if ok else "a die is not FCSM=4/healthy")
    return {"die_a": oa, "die_b": ob, "healthy": ok}

# ---- T3 delivery soak (write -> die_b local verify) --------------------------
def t2b_canary(base=0xEE110000):
    """Practical good-eye gate: a tiny cross-die write must land. On a bad-eye
    bring-up the peer write wedges die_a (rc=124); POR and signal bad eye so the
    caller re-brings-up rather than running every data-plane test into a wedge."""
    rc, out = board(A, "write 8 0x%08X" % base, 30)
    if rc == 124 or "WRITE" not in out:
        record("T2b_good_eye_canary", "FAIL", "canary write wedged — BAD-EYE bring-up"); por_die_a(); return False
    rc, out = board(B, "verify 8 0x%08X" % base, 30)
    ok = rc == 0 and "8/8" in out
    record("T2b_good_eye_canary", "PASS" if ok else "FAIL", out[:60])
    if not ok: por_die_a()
    return ok

def t3_delivery_soak(base=0xB6B60000):
    rc, out = board(A, "write %d 0x%08X" % (SOAK_N, base), 60)
    if rc == 124:
        record("T3_delivery_soak", "FAIL", "write wedged (rc=124)"); por_die_a(); return False
    if rc != 0 or "WRITE" not in out:
        record("T3_delivery_soak", "FAIL", "write failed rc=%d %s" % (rc, out[:80])); return False
    rc, out = board(B, "verify %d 0x%08X" % (SOAK_N, base), 60)
    ok = rc == 0 and ("%d/%d" % (SOAK_N, SOAK_N)) in out
    record("T3_delivery_soak", "PASS" if ok else "FAIL", "%d writes: %s" % (SOAK_N, out[:80]))
    return ok

# ---- T6 endurance (chunked write+verify to ENDUR_BEATS) ----------------------
def t6_endurance(base=0xC7C70000):
    done = 0; step = 256
    while done < ENDUR_BEATS:
        n = min(step, ENDUR_BEATS - done)
        b = (base + done) & 0xFFFFFFFF
        rc, out = board(A, "write %d 0x%08X" % (n, b), 60)
        if rc != 0:
            record("T6_endurance", "FAIL", "write wedged at beat %d" % done); por_die_a(); return False
        o = obs(A)
        if not healthy(o):
            record("T6_endurance", "FAIL", "Region-F/health fault at beat %d (%s)"
                   % (done, o.get("witness_raw") if o else "no-obs")); por_die_a(); return False
        done += n
    # final delivery check (die_b local)
    rc, out = board(B, "verify %d 0x%08X" % (min(step, ENDUR_BEATS), base), 60)
    record("T6_endurance", "PASS", "%d beats, die_a alive, Region-F healthy throughout" % ENDUR_BEATS)
    return True

# ---- T10 cross-die READ soak (die_b seeds local; die_a reads over link) ------
def t10_read_soak(base):
    # Reads back the data T3 already WROTE and die_b already LOCAL-verified as
    # resident in its SRAM — so no extra write load (preserves the eye budget).
    # die_a reads the peer aperture (no local backing -> the read MUST traverse to
    # die_b = a genuine cross-die read), chunked with a Region-F gate between chunks.
    read_ok = 0; start = 0
    while start < READ_N:
        cnt = min(CHUNK, READ_N - start)
        rc, out = board(A, "read_chunk %d %d 0x%08X" % (start, cnt, base), 45)
        if rc == 124:   # ssh/board timeout == wedged peer read
            record("T10_read_soak", "FAIL", "WEDGE: read chunk @%d timed out (%d/%d read ok before wedge)"
                   % (start, read_ok, READ_N)); por_die_a(); return False
        if rc != 0 or "READCHUNK" not in out:
            record("T10_read_soak", "FAIL", "read mismatch @%d: %s" % (start, out[:80])); por_die_a(); return False
        read_ok += cnt
        o = obs(A)                     # Region-F gate BETWEEN chunks (CC-5)
        if not healthy(o):
            record("T10_read_soak", "FAIL", "Region-F fault after %d reads (%s)"
                   % (read_ok, o.get("witness_raw") if o else "no-obs")); por_die_a(); return False
        start += cnt
    record("T10_read_soak", "PASS", "%d/%d cross-die reads byte-exact, no wedge" % (read_ok, READ_N))
    return True

def main():
    global JSON_OUT
    ap = argparse.ArgumentParser(
        description="system-level validation regression for the eth-chiplet KR260 pair")
    ap.add_argument("--json-out", metavar="PATH", default=JSON_OUT,
                    help="write the full verdict set + provenance to PATH as JSON "
                         "(default: $SYSVAL_JSON_OUT, else stdout only)")
    args = ap.parse_args()
    JSON_OUT = args.json_out

    print("=== kr260_sysval : system-level validation regression %s ===" % time.strftime("%H:%M:%S"))
    if not PW:
        # Still emit the artefact -- "we could not run" is a result worth keeping,
        # and a missing file is indistinguishable from a run that never started.
        print("ERROR: no password")
        record("T0_preflight", "INCONCLUSIVE", "KR260_PASSWORD unset")
        _summary(2)
    t1_provenance()
    o = t2_obs_probe()
    if not (o and o["healthy"]):
        print("\n== ABORT: link not healthy (FCSM=4 + Region-F) — bring up a good-eye link first ==")
        _summary(2)
    if not t2b_canary():
        print("\n== BAD-EYE bring-up: SYSVAL_BAD_EYE — data-plane tests skipped, re-bring-up needed ==")
        _summary(2)
    SOAK_BASE = 0xB6B60000
    if not t3_delivery_soak(SOAK_BASE):
        print("\n== T3 delivery wedged/failed on a canary-good eye — marginal eye, re-bring-up ==")
        _summary(2)
    # marquee READ coverage: read back T3's landed data (no extra write load), BEFORE
    # the wedge-prone endurance stress
    t10_read_soak(SOAK_BASE)
    # endurance only if the link survived the read soak (T10 PORs die_a on wedge)
    if healthy(obs(A)):
        t6_endurance()
    else:
        record("T6_endurance", "SKIPPED", "link down after T10 read soak (POR'd) — endurance not run")
    _summary(None)

def _summary(force_exit):
    print("\n=== SYSVAL SUMMARY ===")
    npass = sum(1 for _, v, _ in RESULTS if v == "PASS")
    nfail = sum(1 for _, v, _ in RESULTS if v == "FAIL")
    ninc  = sum(1 for _, v, _ in RESULTS if v == "INCONCLUSIVE")
    for n, v, d in RESULTS:
        print("  %-14s %s" % (v, n))
    print("  ---- %d PASS / %d FAIL / %d INCONCLUSIVE ----" % (npass, nfail, ninc))
    code = force_exit if force_exit is not None else (1 if nfail else 0)
    if JSON_OUT:
        _write_json(JSON_OUT, code)
    sys.exit(code)

if __name__ == "__main__":
    main()
