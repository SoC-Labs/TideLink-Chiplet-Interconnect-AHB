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
#
# ---------------------------------------------------------------------------
# 2026-08-25 TRANSPORT REPAIR. For days this harness manufactured hardware
# failures. It opened a FRESH ssh connection per board call with no multiplexing;
# board sshd runs the OpenSSH defaults (MaxStartups 10:30:100, LoginGraceTime
# 2m), so once 10 unauthenticated connections are pending ~30% of new ones are
# RESET. It then threw away the remote command's stderr (2>/dev/null) AND ssh's
# own stderr, and special-cased rc=124 but not rc=255 -- so a reset connection,
# which yields rc=255 and EMPTY stdout, fell through into the data-mismatch
# branch and was recorded as:
#       T10_read_soak  FAIL  "read mismatch @100: "
# with no detail whatsoever. See RESCUE_2026-08-22/evidence/sysval_a{4,5,6}.json:
# three runs, same empty string. Nothing was wrong with the silicon.
#
# The repair, in order of how much it matters:
#   1. stderr is captured, never discarded, and kept in the failure record.
#   2. exit codes are CLASSIFIED. rc=255 / ssh transport signatures are
#      TRANSPORT_ERROR and can never be reported as a data mismatch. A data
#      mismatch now REQUIRES proof the command ran: the board's own marker
#      (READCHUNK / VERIFY / WRITE) must be present in stdout.
#   3. ControlMaster multiplexing: one connection per board per run instead of
#      one per call -- this removes the MaxStartups cause, not just the symptom.
#   4. transport failures are retried, bounded, with backoff, and the retry
#      count is RECORDED -- a silent retry would hide the signal we just learned
#      to read.
#   5. every failure record says which of those it was, in words.
# A verdict that cannot distinguish "the DUT returned wrong data" from "we could
# not reach the DUT" is not an instrument.
# ---------------------------------------------------------------------------
import subprocess, sys, os, json, time, hashlib, glob, argparse, socket
import re, random, tempfile

A = os.environ.get("DIE_A", "ubuntu@10.22.24.159")
B = os.environ.get("DIE_B", "ubuntu@10.22.24.153")
SCR = os.path.dirname(os.path.abspath(__file__))
BOARD = "~/td/scripts/eth_sysval_board.py"
CHUNK = int(os.environ.get("SYSVAL_READ_CHUNK", "50"))     # <=50 reads per board invocation (CC-5)
SOAK_N = int(os.environ.get("SYSVAL_SOAK_N", "128"))       # basic delivery (small: eye-gate)
ENDUR_BEATS = int(os.environ.get("SYSVAL_ENDUR_BEATS", "2000"))  # the stress/reliability gate
READ_N = int(os.environ.get("SYSVAL_READ_N", "128"))       # basic read coverage (small)

# ---- transport policy --------------------------------------------------------
SSH_RETRIES = int(os.environ.get("SYSVAL_SSH_RETRIES", "3"))      # attempts on TRANSPORT_ERROR
SSH_BACKOFF = float(os.environ.get("SYSVAL_SSH_BACKOFF", "1.0"))  # seconds, doubled each retry
USE_CM      = os.environ.get("SYSVAL_SSH_CM", "1") != "0"         # ControlMaster multiplexing
CM_PERSIST  = os.environ.get("SYSVAL_SSH_CM_PERSIST", "60")
# POR on a genuine data mismatch is OFF by default: a mismatch means the link is
# alive and returning wrong data, so a reset destroys the only state that could
# explain it. POR still fires on a WEDGE, where the board really is stuck.
POR_ON_MISMATCH = os.environ.get("SYSVAL_POR_ON_MISMATCH", "0") == "1"

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

def _safe_cmd(cmd):
    """Redact the sudo password out of anything we are about to record. Belt and
    braces: the password goes to sudo on stdin, never in argv, but a recorded
    command string would still carry it to disk."""
    c = re.sub(r"echo\s+'.*?'\s*\|\s*sudo -S", "echo '***' | sudo -S", cmd or "")
    c = re.sub(r'echo\s+".*?"\s*\|\s*sudo -S', 'echo "***" | sudo -S', c)
    return _mask(c)

# ---- ssh transport -----------------------------------------------------------
OK, TIMEOUT, TRANSPORT_ERROR, RAN = "OK", "TIMEOUT", "TRANSPORT_ERROR", "RAN"
BOARD_ERROR, DATA_MISMATCH = "BOARD_ERROR", "DATA_MISMATCH"

# ssh-level failures: these all mean the command NEVER RAN on the DUT.
_TRANSPORT_RE = re.compile(
    r"kex_exchange_identification|ssh_exchange_identification|"
    r"Connection reset|Connection closed by|Connection refused|Connection timed out|"
    r"No route to host|Network is unreachable|Broken pipe|"
    r"Host key verification failed|Permission denied \(|"
    r"Too many authentication failures|not responding|"
    r"Control socket connect|ControlPath|closed by remote host",
    re.I)

_CM_DIR = None
def _cm_dir():
    """Short path: unix sockets cap around 104 bytes and %C is a short hash."""
    global _CM_DIR
    if _CM_DIR is not None:
        return _CM_DIR or None
    try:
        d = os.path.join(tempfile.gettempdir(), ".tl_cm_%d" % os.getuid())
        os.makedirs(d, mode=0o700, exist_ok=True)
        _CM_DIR = d
    except Exception:
        _CM_DIR = ""
    return _CM_DIR or None

def _ssh_base(host):
    o = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=10"]
    d = _cm_dir() if USE_CM else None
    if d:
        # ONE connection per board for the whole run instead of one per call.
        # This is the actual fix for the MaxStartups resets -- classification
        # only tells you it happened; multiplexing stops it happening.
        o += ["-o", "ControlMaster=auto",
              "-o", "ControlPath=%s/%%C" % d,
              "-o", "ControlPersist=%s" % CM_PERSIST]
    return o

def _clean_err(s):
    """Keep stderr verbatim, minus sudo's own prompt -- which is emitted on every
    single call and would otherwise drown the one line that matters."""
    keep = [ln for ln in (s or "").splitlines()
            if ln.strip() and not ln.strip().startswith("[sudo] password for")]
    return _mask("\n".join(keep)).strip()

def classify(rc, out, err, marker=None):
    """Did the command actually RUN on the DUT, or did we fail to reach it?

    Order matters. Proof of execution beats any transport guess: if the board's
    own output marker is in stdout then the command ran, whatever the exit code,
    and the failure is a real one. Only after that do we treat rc=255 / an ssh
    error signature as transport."""
    if rc == 124:
        return TIMEOUT
    if rc == 0:
        return OK
    if marker and marker in (out or ""):
        return RAN
    if rc == 255 or _TRANSPORT_RE.search(err or ""):
        return TRANSPORT_ERROR
    return RAN

class Res(object):
    """Self-describing result of one board call. Anyone reading a failure record
    must be able to tell 'the DUT returned wrong data' from 'we could not reach
    the DUT' WITHOUT re-deriving it from an empty string."""
    __slots__ = ("rc", "out", "err", "kind", "attempts", "retries", "host", "cmd")
    def __init__(self, rc, out, err, kind, attempts, retries, host, cmd):
        self.rc, self.out, self.err = rc, (out or "").strip(), err
        self.kind, self.attempts, self.retries = kind, attempts, retries
        self.host, self.cmd = host, cmd
    @property
    def ok(self):        return self.kind == OK
    @property
    def transport(self): return self.kind == TRANSPORT_ERROR
    @property
    def ran(self):       return self.kind in (OK, RAN)
    def info(self, kind=None):
        return {"kind": kind or self.kind, "rc": self.rc, "host": _mask(self.host),
                "cmd": _safe_cmd(self.cmd), "attempts": self.attempts,
                "retries": self.retries,
                "reached_dut": self.kind != TRANSPORT_ERROR,
                "stdout": self.out[:600], "stderr": (self.err or "")[:600]}
    def describe(self):
        s = "%s rc=%d" % (self.kind, self.rc)
        if self.retries:
            s += " after %d transport retr%s" % (self.retries,
                                                 "y" if self.retries == 1 else "ies")
        if self.out: s += " stdout=%r" % self.out[:200]
        if self.err: s += " stderr=%r" % self.err[:200]
        if not self.out and not self.err:
            s += " <no stdout and no stderr — the command did not run>"
        return s

def _ssh_once(host, cmd, timeout):
    full = _ssh_base(host) + [host, cmd]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, _clean_err(r.stderr)
    except subprocess.TimeoutExpired as e:
        def _t(x):
            if x is None: return ""
            return x.decode("utf-8", "replace") if isinstance(x, bytes) else x
        return 124, _t(e.stdout), "TIMEOUT after %ss (no response from board)" % timeout

def ssh_run(host, cmd, timeout=30, marker=None, retries=None):
    """Run cmd on host, classify the outcome, retry ONLY transport failures.

    Timeouts are deliberately NOT retried: on this project a board timeout means
    a wedged DUT, which is a real result. Retrying it would paper over the single
    most important signal the harness produces."""
    n = max(1, SSH_RETRIES if retries is None else retries)
    attempts = 0
    rc = out = err = kind = None
    for i in range(n):
        attempts += 1
        rc, out, err = _ssh_once(host, cmd, timeout)
        kind = classify(rc, out, err, marker)
        if kind != TRANSPORT_ERROR:
            break
        if i < n - 1:
            time.sleep(SSH_BACKOFF * (2 ** i) + random.uniform(0, 0.25))
    return Res(rc, out, err, kind, attempts, attempts - 1, host, cmd)

def ssh(host, cmd, timeout=30, marker=None):
    """Back-compat shim: (rc, stdout, stderr)."""
    r = ssh_run(host, cmd, timeout, marker)
    return r.rc, r.out, r.err

def board(host, args, timeout=40, marker=None):
    # root via sudo -S; password on stdin so it never appears in argv.
    # NOTE the absent `2>/dev/null`: the board's stderr -- a python traceback, a
    # sudo failure, a /dev/mem EPERM -- used to be discarded and then surfaced as
    # an empty "mismatch" detail. It is now captured and recorded.
    # -p '': suppress sudo's password PROMPT. Without it sudo writes "[sudo]
    # password for ubuntu: " to the stream and corrupts the FIRST LINE of the
    # board's stdout -- which this repo has been bitten by before. The marker
    # requirement below now makes that fail safe (a corrupted first line reads
    # as TRANSPORT_ERROR, not as a phantom data mismatch) but the corruption
    # should not happen at all.
    cmd = "cd td && echo %r | sudo -S -p '' python3 %s %s" % (PW, BOARD, args)
    return ssh_run(host, cmd, timeout, marker)

def obs(host):
    r = board(host, "obs", 25, marker="{")
    obs.last = r
    for line in r.out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try: return json.loads(line)
            except Exception: pass
    return None
obs.last = None

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
def record(name, verdict, detail="", info=None):
    RESULTS.append({"name": name, "verdict": verdict, "detail": detail,
                    "info": info or {}})
    k = (info or {}).get("kind")
    print("  [%s] %s %s%s" % (verdict.ljust(12), name, detail,
                              "" if not k else "   <%s>" % k))

def _transport_summary():
    n_t = sum(1 for t in RESULTS if t.get("info", {}).get("kind") == TRANSPORT_ERROR)
    n_r = sum(t.get("info", {}).get("retries", 0) or 0 for t in RESULTS)
    return {"transport_errors": n_t, "transport_retries_recorded": n_r,
            "control_master": bool(USE_CM), "ssh_retries_configured": SSH_RETRIES}

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
        "schema":      "kr260_sysval/2",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T_START)),
        "ended_utc":   time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_s":  round(time.time() - T_START, 1),
        "provenance":  _provenance(),
        "transport":   _transport_summary(),
        "tests":       RESULTS,
        "counts":      {k: sum(1 for t in RESULTS if t["verdict"] == k)
                        for k in ("PASS", "FAIL", "INCONCLUSIVE", "SKIPPED")},
        "exit_code":   exit_code,
        # overall is FAIL if anything failed, and INCOMPLETE if we aborted before
        # the data-plane tests ran -- an aborted run is not a pass.
        "overall":     ("FAIL" if any(t["verdict"] == "FAIL" for t in RESULTS)
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
    stale = []; unreached = []
    for host, tag in ((A, "die_a"), (B, "die_b")):
        # no 2>/dev/null: if sha256sum cannot read the file we want to know why
        r = ssh_run(host, "sha256sum ~/td/scripts/eth_sysval_board.py | cut -d' ' -f1", 15)
        if r.transport or not r.out:
            unreached.append("%s %s" % (tag, r.describe())); continue
        want = repo.get("eth_sysval_board.py", "")
        got = r.out.strip()
        if got != want:
            stale.append("%s:eth_sysval_board.py board=%s repo=%s" % (tag, got[:12], want[:12]))
    if unreached:
        record("T1_provenance", "INCONCLUSIVE",
               "could not read board hashes: " + "; ".join(unreached),
               info={"kind": TRANSPORT_ERROR, "reached_dut": False}); return False
    if stale:
        record("T1_provenance", "FAIL", "; ".join(stale)); return False
    record("T1_provenance", "PASS", "board eth_sysval_board.py == repo (both dies)"); return True

# ---- T2 obs_probe ------------------------------------------------------------
def t2_obs_probe():
    oa = obs(A); ra = obs.last
    ob = obs(B); rb = obs.last
    if not oa or not ob:
        bad = ra if not oa else rb
        tag = "die_a" if not oa else "die_b"
        detail = ("TRANSPORT_ERROR: could not reach %s — link health UNKNOWN, not bad: %s"
                  % (tag, bad.describe()) if bad and bad.transport
                  else "obs read failed on %s: %s" % (tag, bad.describe() if bad else "?"))
        record("T2_obs_probe", "INCONCLUSIVE", detail, info=bad.info() if bad else None)
        return None
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
    r = board(A, "write 8 0x%08X" % base, 30, marker="WRITE")
    if r.transport:
        record("T2b_good_eye_canary", "INCONCLUSIVE",
               "TRANSPORT_ERROR: could not reach die_a — no eye verdict possible: %s" % r.describe(),
               info=r.info()); return False
    if r.kind == TIMEOUT or "WRITE" not in r.out:
        record("T2b_good_eye_canary", "FAIL",
               "canary write wedged — BAD-EYE bring-up: %s" % r.describe(),
               info=r.info()); por_die_a(); return False
    r2 = board(B, "verify 8 0x%08X" % base, 30, marker="VERIFY")
    if r2.transport:
        record("T2b_good_eye_canary", "INCONCLUSIVE",
               "TRANSPORT_ERROR: could not reach die_b — no eye verdict possible: %s" % r2.describe(),
               info=r2.info()); return False
    ok = r2.rc == 0 and "8/8" in r2.out
    record("T2b_good_eye_canary", "PASS" if ok else "FAIL",
           r2.out[:120] if r2.out else r2.describe(),
           info=r2.info(None if ok else DATA_MISMATCH))
    if not ok: por_die_a()
    return ok

def t3_delivery_soak(base=0xB6B60000):
    r = board(A, "write %d 0x%08X" % (SOAK_N, base), 60, marker="WRITE")
    if r.transport:
        record("T3_delivery_soak", "INCONCLUSIVE",
               "TRANSPORT_ERROR: could not reach die_a to issue the write: %s" % r.describe(),
               info=r.info()); return False
    if r.kind == TIMEOUT:
        record("T3_delivery_soak", "FAIL", "WEDGE: write timed out: %s" % r.describe(),
               info=r.info()); por_die_a(); return False
    if not r.ok or "WRITE" not in r.out:
        record("T3_delivery_soak", "FAIL", "BOARD_ERROR: write failed: %s" % r.describe(),
               info=r.info(BOARD_ERROR)); return False
    r2 = board(B, "verify %d 0x%08X" % (SOAK_N, base), 60, marker="VERIFY")
    if r2.transport:
        record("T3_delivery_soak", "INCONCLUSIVE",
               "TRANSPORT_ERROR: could not reach die_b to verify: %s" % r2.describe(),
               info=r2.info()); return False
    if "VERIFY" not in r2.out:
        record("T3_delivery_soak", "INCONCLUSIVE",
               "BOARD_ERROR: verify produced no VERIFY marker: %s" % r2.describe(),
               info=r2.info(BOARD_ERROR)); return False
    ok = r2.rc == 0 and ("%d/%d" % (SOAK_N, SOAK_N)) in r2.out
    record("T3_delivery_soak", "PASS" if ok else "FAIL",
           "%d writes: %s" % (SOAK_N, r2.out[:200]),
           info=r2.info(None if ok else DATA_MISMATCH))
    return ok

# ---- T6 endurance (chunked write+verify to ENDUR_BEATS) ----------------------
def t6_endurance(base=0xC7C70000):
    done = 0; step = 256
    while done < ENDUR_BEATS:
        n = min(step, ENDUR_BEATS - done)
        b = (base + done) & 0xFFFFFFFF
        r = board(A, "write %d 0x%08X" % (n, b), 60, marker="WRITE")
        if r.transport:
            record("T6_endurance", "INCONCLUSIVE",
                   "TRANSPORT_ERROR: could not reach die_a at beat %d: %s" % (done, r.describe()),
                   info=r.info()); return None
        if not r.ok:
            record("T6_endurance", "FAIL", "write wedged at beat %d: %s" % (done, r.describe()),
                   info=r.info()); por_die_a(); return False
        o = obs(A)
        if not healthy(o):
            if obs.last is not None and obs.last.transport:
                record("T6_endurance", "INCONCLUSIVE",
                       "TRANSPORT_ERROR: lost die_a obs at beat %d — health UNKNOWN: %s"
                       % (done, obs.last.describe()), info=obs.last.info()); return None
            record("T6_endurance", "FAIL", "Region-F/health fault at beat %d (%s)"
                   % (done, o.get("witness_raw") if o else "no-obs")); por_die_a(); return False
        done += n
    # Final delivery check (die_b local).
    # MERGE 2026-08-26: this call's result was previously DISCARDED and T6 recorded
    # PASS unconditionally, so T6 could not report a delivery failure at all -- only
    # a write wedge or a Region-F fault. Fixed here using the transport-aware
    # classification the rest of this function already uses, rather than the older
    # verify_verdict() helper, so a dead ssh is INCONCLUSIVE and not a data failure.
    r = board(B, "verify %d 0x%08X" % (min(step, ENDUR_BEATS), base), 60, marker="VERIFY")
    if r.transport:
        record("T6_endurance", "INCONCLUSIVE",
               "TRANSPORT_ERROR: could not reach die_b for the final delivery check: %s"
               % r.describe(), info=r.info()); return None
    if not r.ok:
        record("T6_endurance", "FAIL",
               "final delivery check FAILED after %d beats: %s" % (ENDUR_BEATS, r.describe()),
               info=r.info()); por_die_a(); return False
    record("T6_endurance", "PASS", "%d beats, die_a alive, Region-F healthy throughout, delivery verified" % ENDUR_BEATS)
    return True

# ---- T10 cross-die READ soak (die_b seeds local; die_a reads over link) ------
def t10_read_soak(base):
    # Reads back the data T3 already WROTE and die_b already LOCAL-verified as
    # resident in its SRAM — so no extra write load (preserves the eye budget).
    # die_a reads the peer aperture (no local backing -> the read MUST traverse to
    # die_b = a genuine cross-die read), chunked with a Region-F gate between chunks.
    #
    # The four outcomes below are the whole point of the 2026-08-25 repair. They
    # used to collapse into one branch that printed "read mismatch @N: " with an
    # empty detail whenever ssh returned rc=255.
    read_ok = 0; start = 0; retries_absorbed = 0
    while start < READ_N:
        cnt = min(CHUNK, READ_N - start)
        r = board(A, "read_chunk %d %d 0x%08X" % (start, cnt, base), 45, marker="READCHUNK")
        retries_absorbed += r.retries

        # (1) We never reached the DUT. NOT a data verdict, and NOT a reason to
        #     POR a board that is probably perfectly healthy.
        if r.transport:
            record("T10_read_soak", "INCONCLUSIVE",
                   "TRANSPORT_ERROR: could not reach die_a for chunk @%d after %d attempt(s) — "
                   "the read never ran, so NO conclusion about the data: %s"
                   % (start, r.attempts, r.describe()), info=r.info())
            return None

        # (2) The board took the command and never came back = wedged peer read.
        if r.kind == TIMEOUT:
            record("T10_read_soak", "FAIL",
                   "WEDGE: read chunk @%d timed out (%d/%d read ok before wedge): %s"
                   % (start, read_ok, READ_N, r.describe()), info=r.info())
            por_die_a(); return False

        # (3) It ran but produced no marker -> board-side error (traceback, sudo,
        #     /dev/mem). Visible at all only because stderr is no longer discarded.
        if "READCHUNK" not in r.out:
            record("T10_read_soak", "INCONCLUSIVE",
                   "BOARD_ERROR: read chunk @%d returned no READCHUNK marker — the board "
                   "command did not complete, so NO conclusion about the data: %s"
                   % (start, r.describe()), info=r.info(BOARD_ERROR))
            return None

        # (4) Marker present + non-zero exit -> a GENUINE cross-die data mismatch.
        #     The board prints "firstbad idx<N> got0x.. exp0x..", which is the
        #     evidence a mismatch claim has to carry.
        if r.rc != 0:
            record("T10_read_soak", "FAIL",
                   "DATA_MISMATCH: die_a read wrong data from die_b in chunk @%d — %s"
                   % (start, r.out[:240]), info=r.info(DATA_MISMATCH))
            if POR_ON_MISMATCH: por_die_a()
            return False

        read_ok += cnt
        o = obs(A)                     # Region-F gate BETWEEN chunks (CC-5)
        if not healthy(o):
            if obs.last is not None and obs.last.transport:
                record("T10_read_soak", "INCONCLUSIVE",
                       "TRANSPORT_ERROR: lost die_a obs after %d reads — health UNKNOWN: %s"
                       % (read_ok, obs.last.describe()), info=obs.last.info())
                return None
            record("T10_read_soak", "FAIL", "Region-F fault after %d reads (%s)"
                   % (read_ok, o.get("witness_raw") if o else "no-obs"))
            por_die_a(); return False
        start += cnt
    record("T10_read_soak", "PASS",
           "%d/%d cross-die reads byte-exact, no wedge%s"
           % (read_ok, READ_N,
              "" if not retries_absorbed
              else " (%d transport retry/ies absorbed — see transport summary)" % retries_absorbed))
    return True

TESTS = ("T1", "T2", "T2b", "T3", "T10", "T6")

def main():
    global JSON_OUT, USE_CM
    ap = argparse.ArgumentParser(
        description="system-level validation regression for the eth-chiplet KR260 pair")
    ap.add_argument("--json-out", metavar="PATH", default=JSON_OUT,
                    help="write the full verdict set + provenance to PATH as JSON "
                         "(default: $SYSVAL_JSON_OUT, else stdout only)")
    ap.add_argument("--only", metavar="IDS", default=None,
                    help="run only these tests, comma separated (%s). Intended for "
                         "instrument self-checks: it lets one test be driven against a "
                         "known-good or deliberately-corrupted far side." % ",".join(TESTS))
    ap.add_argument("--base", metavar="HEX", default=None,
                    help="override the soak/read base word pattern (e.g. 0xB6B60000)")
    ap.add_argument("--no-control-master", action="store_true",
                    help="disable ssh connection multiplexing, restoring the old "
                         "one-connection-per-call behaviour. Used to exercise the "
                         "transport-failure path deliberately.")
    args = ap.parse_args()
    JSON_OUT = args.json_out
    if args.no_control_master:
        USE_CM = False
    only = set(x.strip() for x in args.only.split(",")) if args.only else None
    def want(t): return only is None or t in only

    print("=== kr260_sysval : system-level validation regression %s ===" % time.strftime("%H:%M:%S"))
    print("    transport: control_master=%s ssh_retries=%d" % (bool(USE_CM), SSH_RETRIES))
    if not PW:
        # Still emit the artefact -- "we could not run" is a result worth keeping,
        # and a missing file is indistinguishable from a run that never started.
        print("ERROR: no password")
        record("T0_preflight", "INCONCLUSIVE", "KR260_PASSWORD unset")
        _summary(2)

    SOAK_BASE = int(args.base, 16) if args.base else 0xB6B60000

    if want("T1"):
        t1_provenance()
    if want("T2"):
        o = t2_obs_probe()
        if not (o and o["healthy"]):
            print("\n== ABORT: link not healthy (FCSM=4 + Region-F) — bring up a good-eye link first ==")
            _summary(2)
    if want("T2b"):
        if not t2b_canary():
            print("\n== BAD-EYE bring-up: SYSVAL_BAD_EYE — data-plane tests skipped, re-bring-up needed ==")
            _summary(2)
    if want("T3"):
        if not t3_delivery_soak(SOAK_BASE):
            print("\n== T3 delivery wedged/failed on a canary-good eye — marginal eye, re-bring-up ==")
            _summary(2)
    # marquee READ coverage: read back T3's landed data (no extra write load), BEFORE
    # the wedge-prone endurance stress
    if want("T10"):
        t10_read_soak(SOAK_BASE)
    # endurance only if the link survived the read soak (T10 PORs die_a on wedge)
    if want("T6"):
        if healthy(obs(A)):
            t6_endurance()
        else:
            record("T6_endurance", "SKIPPED", "link down after T10 read soak (POR'd) — endurance not run")
    _summary(None)

def _summary(force_exit):
    print("\n=== SYSVAL SUMMARY ===")
    npass = sum(1 for t in RESULTS if t["verdict"] == "PASS")
    nfail = sum(1 for t in RESULTS if t["verdict"] == "FAIL")
    ninc  = sum(1 for t in RESULTS if t["verdict"] == "INCONCLUSIVE")
    for t in RESULTS:
        k = t.get("info", {}).get("kind")
        print("  %-14s %s%s" % (t["verdict"], t["name"], "" if not k else "   <%s>" % k))
    print("  ---- %d PASS / %d FAIL / %d INCONCLUSIVE ----" % (npass, nfail, ninc))
    ts = _transport_summary()
    if ts["transport_errors"] or ts["transport_retries_recorded"]:
        print("  ---- transport: %d unreachable, %d retry/ies absorbed (control_master=%s) ----"
              % (ts["transport_errors"], ts["transport_retries_recorded"], ts["control_master"]))
    # An INCONCLUSIVE run must not exit 0: "we could not reach the DUT" is a
    # different thing from "the DUT is good", and exit 0 would assert the latter.
    code = force_exit if force_exit is not None else (1 if nfail else (3 if ninc else 0))
    if JSON_OUT:
        _write_json(JSON_OUT, code)
    sys.exit(code)

if __name__ == "__main__":
    main()
