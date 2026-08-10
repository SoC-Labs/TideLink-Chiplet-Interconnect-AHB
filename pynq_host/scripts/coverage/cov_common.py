#!/usr/bin/env python3
# =============================================================================
# cov_common.py — shared dev-host helpers for the KR260 eth-chiplet COVERAGE
#                 gates (cov_*.py). Runs on the dev host (mapstone-dev), drives
#                 BOTH boards over timeout-wrapped ssh, and reuses the PROVEN
#                 on-board modes rather than re-poking /dev/mem.
#
# Design rules baked in (the wedge-safety mandate):
#   * The eth-chiplet AXI data plane wedges the PS bus with NO software timeout,
#     so EVERY board/ssh access is subprocess-timeout-wrapped. A timeout == a
#     PS-bus WEDGE and is reported as such (WedgeTimeout).
#   * Pass/fail verdicts come from die_b (or the surviving die) LOCAL reads so
#     the verifier itself can never wedge.
#   * Gates REFUSE to run unless BOTH dies report FCSM=4 (require_pair_fcsm4).
#   * JTAG-POR recovery is STAGED: por_stage() prints the exact manual recovery
#     and, only when COV_AUTO_POR=1, invokes weekend/por_recover.sh. A draft run
#     never POR-cycles a board unless the operator opts in.
#   * Board password is taken from KR260_PASSWORD (env) — NEVER hardcoded here.
#
# This is a LIBRARY, not a runnable gate. It intentionally mirrors the access
# layer of weekend/campaign_iter.py so the two harnesses behave identically.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import os
import shlex
import subprocess
import sys
import time

# --- locations ---------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))          # .../scripts/coverage
SCRIPTS_DIR = os.path.dirname(HERE)                         # .../scripts
POR_SH = os.path.join(SCRIPTS_DIR, "weekend", "por_recover.sh")

# --- board / addressing (IPs are not secrets; overridable via env) -----------
DIE_A_IP = os.environ.get("KR260_DIEA_IP", "10.22.24.159")  # kr260_01, initiator
DIE_B_IP = os.environ.get("KR260_DIEB_IP", "10.22.24.153")  # kr260_02, target
KR260_USER = os.environ.get("KR260_USER", "ubuntu")
DEST_DIR = os.environ.get("KR260_DEST", "td")               # board-side stage dir
IP_TO_TARGET = {DIE_A_IP: "kr260_01", DIE_B_IP: "kr260_02"}

# board-side scripts (staged at ~/td/scripts/ by deploy_pair.sh) — REUSED, not
# reimplemented. These are the proven, wedge-tested access modes.
XFER = "scripts/kr260_eth_xfer.py"          # sender/recv/soak/soak_recv/decerr/link/...
SOAK_FWD = "scripts/kr260_eth_soak_fwd.py"  # write N / verify N (die_b LOCAL read)
POKE = "scripts/eth_tlapb_poke.py"          # read/write/inject/injectoff/anchorobs
HEALTH1 = "scripts/health_snapshot.py"      # RO one-shot health dump

# --- SoC-internal addresses (PS phys = WINDOW + off) -------------------------
WINDOW = 0x400000000
TLAPB = 0x2E030000
REG_SWI_LANE_STATUS = 0x2108
REG_OBS_AXI_NODES = 0x21E0     # Region F AXI-node obs plane
REG_AUTO_ANCHOR_OBS = 0x21F4
REG_EPOCH_STATUS = 0x2140
REGF_MARKER = 0xAD

# --- per-access subprocess timeouts (seconds). A hit == WEDGE. ---------------
T_GATE = int(os.environ.get("COV_T_GATE", "20"))     # link/health RO check
T_POKE = int(os.environ.get("COV_T_POKE", "20"))     # a single register poke
T_ARM = int(os.environ.get("COV_T_ARM", "45"))       # CAM arm
T_STREAM = int(os.environ.get("COV_T_STREAM", "120"))  # a bounded write stream
T_VERIFY = int(os.environ.get("COV_T_VERIFY", "60"))   # die_b local verify
T_HEALTH = int(os.environ.get("COV_T_HEALTH", "30"))   # RO health snapshot


class WedgeTimeout(Exception):
    """A board/ssh access hung past its subprocess timeout == PS-bus wedge."""

    def __init__(self, host, stage):
        super().__init__("WEDGE host=%s stage=%s" % (host, stage))
        self.host = host
        self.stage = stage


def password():
    """Board ssh password from env only. NEVER hardcode it (deliberate deviation
    from the older scripts' soclabs2026 default — the coverage gates require the
    operator to export it)."""
    pw = os.environ.get("KR260_PASSWORD")
    if not pw:
        sys.exit("ERROR: KR260_PASSWORD is not set. `export KR260_PASSWORD=...` "
                 "before running the coverage gates (the pw is never hardcoded).")
    return pw


# =============================================================================
# Timeout-wrapped board access (a timeout is a WEDGE, not a soft error).
# =============================================================================
def ssh_board(host, remote, timeout, stage):
    """Run `remote` on the board as root over ssh. Returns (rc, combined_output).
    Raises WedgeTimeout if the access hangs past `timeout` (== PS-bus wedge)."""
    pw = password()
    # -p '' suppresses sudo's "[sudo] password for ..." prompt. Without it the
    # prompt is written to stderr, which is merged into stdout (below) and corrupts
    # the FIRST output line — dropping whatever a gate prints first (tidechart's
    # TC STATUS register, obs_health's SWI_LANE line, etc.). Root cause of the
    # cross-gate false-verdicts; the password still arrives via stdin (echo | -S).
    full = "cd %s && echo %s | sudo -S -p '' bash -c %s" % (
        shlex.quote(DEST_DIR), shlex.quote(pw), shlex.quote(remote))
    cmd = ["sshpass", "-p", pw, "ssh",
           "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15",
           "-o", "ServerAliveInterval=15", "%s@%s" % (KR260_USER, host), full]
    try:
        p = subprocess.run(cmd, timeout=timeout, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        raise WedgeTimeout(host, stage)


def board_python(host, script_args, timeout, stage):
    return ssh_board(host, "python3 %s" % script_args, timeout, stage)


def alive(host, timeout=8):
    """Cheap liveness probe: ping + a trivial ssh. NOT a wedge verdict on its own
    (the PS bus can hang while Linux still pings), but a fast negative signal."""
    ip = host.split("@")[-1]
    try:
        if subprocess.run(["ping", "-c1", "-W2", ip],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            return False
        return subprocess.run(["sshpass", "-p", password(), "ssh",
                               "-o", "StrictHostKeyChecking=no",
                               "-o", "ConnectTimeout=%d" % timeout,
                               "%s@%s" % (KR260_USER, ip), "true"],
                              timeout=timeout + 4,
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (subprocess.TimeoutExpired, Exception):
        return False


# =============================================================================
# FCSM=4 gate (RO, wedge-safe) — reuse kr260_eth_xfer.py --mode link.
# =============================================================================
def fcsm4(ip, timeout=T_GATE):
    """(up, text). up == True iff the die reports FCSM=4 & cal=1. A WedgeTimeout
    here means the die's PS bus is ALREADY hung (even RO backdoor reads stall)."""
    try:
        rc, out = board_python(ip, XFER + " --mode link", timeout, "link")
    except WedgeTimeout:
        return False, "WEDGE (ssh timed out reading link status)"
    up = rc == 0 and "UP" in out
    return up, out.strip().splitlines()[-1] if out.strip() else ""


def require_pair_fcsm4(a_ip, b_ip):
    """Abort (SystemExit 2) unless BOTH dies are FCSM=4. Every gate calls this
    first — refusing to drive a down/half link is the primary wedge guard."""
    ua, ta = fcsm4(a_ip)
    ub, tb = fcsm4(b_ip)
    print("  FCSM gate  die_a(%s): %s" % (a_ip, ta))
    print("  FCSM gate  die_b(%s): %s" % (b_ip, tb))
    if not (ua and ub):
        print("ABORT: link not FCSM=4 on both dies. Bring up on freshly-POR'd dies "
              "first (bringup_pair_release.sh). Refusing to drive the data plane "
              "(wedge risk).", file=sys.stderr)
        raise SystemExit(2)


# =============================================================================
# Register read via eth_tlapb_poke.py (RO offsets only — cannot wedge).
# =============================================================================
def read_reg(ip, off, timeout=T_POKE):
    """Read one TLAPB register (offset from TLAPB) via `poke read`. Returns
    (value_or_None, raw). None on a parse miss / non-zero rc."""
    rc, out = board_python(ip, "%s read 0x%X" % (POKE, off), timeout, "poke_read")
    val = None
    for tok in out.split():
        if tok.startswith("0x"):
            try:
                val = int(tok, 16)
                break
            except ValueError:
                pass
    return (val if rc == 0 else None), out.strip()


# =============================================================================
# Error injector arm/disarm via eth_tlapb_poke.py (one-shot, self-clears).
# =============================================================================
def inject(ip, data_id, byte, bit, timeout=T_POKE):
    return board_python(ip, "%s inject 0x%02X %d %d" % (POKE, data_id, byte, bit),
                        timeout, "inject")


def inject_off(ip, timeout=T_POKE):
    return board_python(ip, "%s injectoff" % POKE, timeout, "injectoff")


# =============================================================================
# Region F (OBS_AXI_NODES 0x21E0) pure decoder — for reporting.
# bit order of the 5-bit node masks is {r, ar, b, w, aw} = bit0..bit4.
# =============================================================================
_REGF_NODES = ("r", "ar", "b", "w", "aw")


def _mask_names(mask):
    return ",".join(n for i, n in enumerate(_REGF_NODES) if (mask >> i) & 1) or "-"


def decode_regf(rf):
    """Decode OBS_AXI_NODES into a dict + a human string. present == marker 0xAD."""
    marker = (rf >> 24) & 0xFF
    d = {
        "raw": rf,
        "marker": marker,
        "present": marker == REGF_MARKER,
        "data_healthy": (rf >> 23) & 1,
        "tgt_live": rf & 0x1F,
        "ini_live": (rf >> 5) & 0x1F,
        "tgt_wsticky": (rf >> 10) & 0x1F,
        "ini_wsticky": (rf >> 15) & 0x1F,
        "tgt_resperr": (rf >> 20) & 1,
        "ini_resperr": (rf >> 21) & 1,
    }
    if not d["present"]:
        d["text"] = ("RegionF=0x%08X marker=0x%02X (expect 0xAD) -> obs plane NOT "
                     "in this bitstream" % (rf, marker))
    else:
        d["text"] = ("RegionF=0x%08X data_healthy=%d  wedge-sticky tgt{%s} ini{%s}"
                     "  live tgt{%s} ini{%s}  resp-err tgt=%d ini=%d"
                     % (rf, d["data_healthy"], _mask_names(d["tgt_wsticky"]),
                        _mask_names(d["ini_wsticky"]), _mask_names(d["tgt_live"]),
                        _mask_names(d["ini_live"]), d["tgt_resperr"], d["ini_resperr"]))
    return d


def regf_snapshot(ip, tag="", timeout=T_HEALTH):
    """RO read + decode of OBS_AXI_NODES on one die. Returns the decode dict (with
    'timeout': True on a hung bus). Prints a one-liner."""
    try:
        val, raw = read_reg(ip, REG_OBS_AXI_NODES, timeout)
    except WedgeTimeout:
        print("  %sRegionF(%s): WEDGE (ssh timed out — PS bus hung)" % (tag, ip))
        return {"timeout": True, "present": False, "data_healthy": 0}
    if val is None:
        print("  %sRegionF(%s): read failed (%s)" % (tag, ip, raw))
        return {"present": False, "data_healthy": 0}
    d = decode_regf(val)
    print("  %s%s: %s" % (tag, ip, d["text"]))
    return d


# =============================================================================
# STAGED JTAG-POR recovery.
# =============================================================================
def por_stage(ip, reason="wedge", out_dir=None):
    """Stage recovery for a wedged board. ALWAYS prints the exact manual recovery.
    Only when COV_AUTO_POR=1 does it actually invoke weekend/por_recover.sh (so a
    draft run never POR-cycles a board unexpectedly). Returns True iff a POR was
    actually issued."""
    target = IP_TO_TARGET.get(ip.split("@")[-1], "?")
    print("  ---- JTAG-POR STAGED (%s) : board %s (%s) ----" % (reason, target, ip))
    print("     PS bus is (or may be) wedged — recovery is JTAG-POR ONLY, never "
          "`sudo reboot`. Run ON mapstone-dev:")
    print("       OUT=<campaign_out> bash %s %s" % (POR_SH, target))
    print("     or the raw fpgahub reset:")
    print("       curl -s --unix-socket /run/fpgahub/fpgahub.sock -X POST \\")
    print("         http://localhost/api/v1/targets/%s/reset \\" % target)
    print("         -H 'Content-Type: application/json' -d '{\"method\":\"default\","
          "\"confirm\":true}'")
    print("     then re-bring-up with bringup_pair_release.sh.")
    if os.environ.get("COV_AUTO_POR") != "1" or target == "?":
        print("     (COV_AUTO_POR!=1 -> NOT auto-issued; recovery left to the operator.)")
        return False
    env = dict(os.environ)
    if out_dir:
        env["OUT"] = out_dir
    try:
        print("     COV_AUTO_POR=1 -> issuing por_recover.sh %s ..." % target)
        subprocess.run(["bash", POR_SH, target], env=env, timeout=600)
        return True
    except Exception as e:                       # never let recovery crash the gate
        print("     por_recover.sh failed: %s" % e)
        return False


def role_ips(direction):
    """(sender_ip, recv_ip, sender_label, recv_label) for a direction.
       'fwd' = A->B (proven), 'rev' = B->A (untested — attended)."""
    if direction == "fwd":
        return DIE_A_IP, DIE_B_IP, "die_a", "die_b"
    return DIE_B_IP, DIE_A_IP, "die_b", "die_a"


def banner(title):
    print("=" * 78)
    print(title)
    print("=" * 78)


if __name__ == "__main__":
    # Not a gate — a tiny no-HW self-check of the pure decoder + config echo.
    print("cov_common self-check (no board access):")
    print("  die_a=%s die_b=%s user=%s dest=%s" % (DIE_A_IP, DIE_B_IP, KR260_USER, DEST_DIR))
    print("  por_recover.sh present: %s" % os.path.exists(POR_SH))
    demo = (REGF_MARKER << 24) | (1 << 23)     # marker + data_healthy, all clean
    print("  decode_regf(clean): %s" % decode_regf(demo)["text"])
    wedged = (REGF_MARKER << 24) | (1 << 12)   # tgt wedge-sticky on 'b' (bit2 of tgt)
    print("  decode_regf(b-wedged): %s" % decode_regf(wedged)["text"])
