#!/usr/bin/env python3
"""kr260_onchip_autonomy.py — the HARDWARE-AUTONOMY proof for the KR260 on-chip PAIR.

Runs ON the board, as root. Issues ZERO register writes. It polls both TideLink
instances of the on-chip pair (fpga/targets/kr260-pair-onchip) and PASSES only
when the pair has, entirely on its own from POR, negotiated roles, completed the
GENUINE peer-mask handshake, and brought the link up:

  §5.4 pass criteria (KR260_PAIR_ONCHIP_PLAN.md) — ALL must hold on BOTH dies:
    1. STATUS   0x2108  [19:17] fcsm == 4  AND  [16] cal == 1.
    2. Roles complementary — ROLE_CFG 0x2080[0] differs between the dies
       (exactly one master; 0 = master, 1 = slave), and role is LOCKED
       (ROLE_STATUS 0x2084[1] == 1) on both.
    3. Positive handshake proof — OBS_MASK_HS 0x2194 [19] mask_hs_match == 1 on
       both, AND the gate opened BY MATCH not by a strap: [20] gate_open must
       EQUAL [19] mask_hs_match. gate_open==1 while match==0 means the gate was
       forced by mask_hs_bypass_i / apb_debug_unlock_i — a SHAM handshake.
    4. apb_debug_unlock GPIO reads 0 THROUGHOUT. If the link only comes up after
       a debug-unlock write, that is a RED FLAG (the handshake did not complete)
       — a bug to fix, never a workaround. Checked every poll iteration.

A firmware recipe is not a deliverable: this script never writes a bring-up
poke. With NEGO_CFG_RESET=0x61 baked (autoneg-on-at-POR) and HONEST_MASK_HS=1
(the mask-handshake ports un-hacked, W1), the pair must reach the state above
with no host writes at all.

Register offsets are verified against the RTL read mux (cited inline). This is a
pure-poll proof; it writes nothing and touches only the apb + debug apertures,
never ahb_ptp/phc/ahb_sub/ahb_tx.

SAFETY: same PS<->PL training-entry wedge hazard as the smoke test — the first
APB read after a PL load can hang the PS with NO AXI timeout. Every poll
iteration's reads run in a short-lived WORKER subprocess (this file re-invoked
with --worker) under a parent-enforced wall-clock timeout; a hang is reported as
WEDGED and the parent aborts, freeing the shell. We do NOT invent an AXI
timeout. (Best-effort: a wedged AXI read may leave the worker stuck
uninterruptibly, but the controlling script returns.)

Usage (after `make -C fpga deploy TARGET=kr260-pair-onchip`; do NOT run
kr260_onchip_smoke.py --unlock first, or reload the PL if you did):

    sudo python3 pynq_host/scripts/kr260_onchip_autonomy.py
    sudo python3 pynq_host/scripts/kr260_onchip_autonomy.py --timeout 180

Exit status: 0 = autonomy PROVEN (zero writes); 1 = timed out with criteria
unmet; 2 = a probe WEDGED; 3 = RED FLAG (debug_unlock asserted — sham gate).
"""
import argparse
import ctypes
import mmap
import os
import subprocess
import sys
import tempfile
import time

PAGE = 4096

# --- Canonical on-chip map (mirrors overlay.py:onchip_instance_map and
# --- fpga/targets/kr260-pair-onchip/addrmap.tcl). inst1 = inst0 | stride.
INST_STRIDE = 0x08000000
APB_BASE_0   = 0x84030000
DEBUG_BASE_0 = 0x84041000   # axi_gpio_debug_unlock (must read 0 throughout)

def apb_base(inst):   return APB_BASE_0   | (inst * INST_STRIDE)
def debug_base(inst): return DEBUG_BASE_0 | (inst * INST_STRIDE)

# --- APB register offsets, verified against src/rtl/local_overrides/
# --- axi_chiplet_controller.sv and src/rtl/fifo/tidelink_apb_regs.sv:
#   STATUS      0x2108  Region 8 slot 2   ctrl:1934-1948  [19:17] fcsm, [16] cal_done
#   ROLE_CFG    0x2080  Region 4 slot 0   ctrl:907        [0] role_cfg(0=mst/1=slv), [1] role_lock
#   ROLE_STATUS 0x2084  Region 4 slot 1   ctrl:908-909    [0] role_effective, [1] role_locked
#   OBS_MASK_HS 0x2194  Region C slot 5   ctrl:2018-2031  [19] mask_hs_match, [20] mask_hs_gate_open
STATUS_OFF      = 0x2108
ROLE_CFG_OFF    = 0x2080
ROLE_STATUS_OFF = 0x2084
OBS_MASK_HS_OFF = 0x2194
GPIO_DATA_OFF   = 0x000

FCSM_LINK = 4   # STATUS[19:17] target state (bilateral fcsm==4 == link up)


def _decode(status, role_cfg, role_status, mask_hs, debug):
    return {
        "fcsm":         (status >> 17) & 0x7,
        "cal":          (status >> 16) & 0x1,
        "role_cfg":     role_cfg & 0x1,           # 0 = master, 1 = slave
        "role_eff":     role_status & 0x1,        # RO effective role (== role_cfg once locked)
        "role_locked":  (role_status >> 1) & 0x1,
        "mask_match":   (mask_hs >> 19) & 0x1,
        "gate_open":    (mask_hs >> 20) & 0x1,
        "debug_unlock": debug & 0x1,
    }


# =============================================================================
# Worker mode: single-shot batched /dev/mem snapshot of both instances. Single
# aligned 32-bit ctypes loads ONLY (the struct-module byte-slice path emits ~5
# narrow bus accesses per word; see tl_poke.py). Runs in a child so the parent
# can bound each poll iteration with a wall-clock timeout.
# =============================================================================
def _worker_main(argv):
    # argv is a flat list of absolute addresses (hex); print one word each.
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    maps = {}

    def rd(addr):
        base = addr & ~(PAGE - 1)
        if base not in maps:
            maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                                   mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        return ctypes.c_uint32.from_buffer(maps[base], addr - base).value

    for a in argv:
        sys.stdout.write("0x%08x\n" % rd(int(a, 0)))
    return 0


def _snapshot_addrs():
    """The exact address list the worker reads each iteration, in a fixed order
    the parent unpacks. Two instances x 5 registers = 10 reads. Zero writes."""
    addrs = []
    for inst in (0, 1):
        b = apb_base(inst)
        addrs += [b + STATUS_OFF, b + ROLE_CFG_OFF, b + ROLE_STATUS_OFF,
                  b + OBS_MASK_HS_OFF, debug_base(inst) + GPIO_DATA_OFF]
    return addrs


# =============================================================================
# Parent side: spawn the snapshot worker, enforce a timeout by hand (never block
# on an unkillable child), classify the result.
# =============================================================================
def _run_worker(addrs, timeout):
    """Return (status, [ints]) with status in {'ok','wedged','err'}."""
    out = tempfile.TemporaryFile(mode="w+")
    try:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--worker",
             *("0x%x" % a for a in addrs)],
            stdout=out, stderr=subprocess.DEVNULL)
    except Exception as e:  # noqa: BLE001
        out.close()
        return "err", None
    deadline = time.monotonic() + timeout
    while proc.poll() is None:
        if time.monotonic() > deadline:
            try:
                proc.kill()      # SIGKILL; do NOT waitpid — a wedged-AXI child
            except Exception:    # may be uninterruptible, but the parent is free.
                pass
            out.close()
            return "wedged", None
        time.sleep(0.02)
    out.seek(0)
    text = out.read()
    out.close()
    if proc.returncode != 0:
        return "err", None
    vals = [int(line, 16) for line in text.split() if line.strip()]
    if len(vals) != len(addrs):
        return "err", None
    return "ok", vals


def sample(timeout):
    """One timed snapshot. Returns (status, {0:decoded, 1:decoded}) or
    (status, None) for wedged/err."""
    status, vals = _run_worker(_snapshot_addrs(), timeout)
    if status != "ok":
        return status, None
    d = {}
    for i, inst in enumerate((0, 1)):
        s, rc, rs, mh, dbg = vals[i * 5:i * 5 + 5]
        d[inst] = _decode(s, rc, rs, mh, dbg)
    return "ok", d


def _criteria(d):
    """Return (passed, reasons[]) for a decoded {0:.., 1:..} snapshot."""
    reasons = []
    for inst in (0, 1):
        s = d[inst]
        if s["fcsm"] != FCSM_LINK:
            reasons.append("inst%d fcsm=%d (want %d)" % (inst, s["fcsm"], FCSM_LINK))
        if s["cal"] != 1:
            reasons.append("inst%d cal=%d (want 1)" % (inst, s["cal"]))
        if s["role_locked"] != 1:
            reasons.append("inst%d role not locked" % inst)
        if s["mask_match"] != 1:
            reasons.append("inst%d mask_hs_match=0" % inst)
        # gate opened by MATCH, not by a strap: gate_open must EQUAL match.
        if s["gate_open"] != s["mask_match"]:
            reasons.append("inst%d gate_open=%d != match=%d (SHAM gate — strap forced it)"
                           % (inst, s["gate_open"], s["mask_match"]))
    # Complementary roles: exactly one master (role_cfg==0).
    masters = [inst for inst in (0, 1) if d[inst]["role_cfg"] == 0]
    if len(masters) != 1:
        reasons.append("roles not complementary (masters=%s, want exactly 1)" % masters)
    return (len(reasons) == 0), reasons


def _fmt(d):
    def one(inst):
        s = d[inst]
        return ("inst%d[%s]: fcsm=%d cal=%d role_cfg=%d(%s) locked=%d "
                "match=%d gate=%d dbg=%d"
                % (inst, "mst" if s["role_cfg"] == 0 else "slv",
                   s["fcsm"], s["cal"], s["role_cfg"],
                   "master" if s["role_cfg"] == 0 else "slave",
                   s["role_locked"], s["mask_match"], s["gate_open"],
                   s["debug_unlock"]))
    return one(0) + "  |  " + one(1)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="overall seconds to wait for autonomous link-up")
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between poll iterations")
    ap.add_argument("--worker-timeout", type=float, default=8.0,
                    help="seconds a single snapshot may take before WEDGED")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("ERROR: need root for /dev/mem (use sudo)", file=sys.stderr)
        return 2

    print("KR260 on-chip PAIR autonomy proof — ZERO WRITES, pure poll.")
    print("Waiting up to %.0fs for POR->autoneg->mask-handshake->role_lock->link "
          "on BOTH dies.\n" % args.timeout)

    deadline = time.monotonic() + args.timeout
    last = None
    it = 0
    while True:
        status, d = sample(args.worker_timeout)
        if status == "wedged":
            print("\n[WEDGED] snapshot hung >%.0fs — PS<->PL bus wedged (likely "
                  "training-entry). ABORTING; the board needs a PL reload."
                  % args.worker_timeout)
            return 2
        if status == "err":
            # worker died (SIGBUS / undecoded / short read). Do not spin forever
            # on a broken image; report and stop.
            print("\n[ERROR] snapshot worker died (bus error / undecoded read / "
                  "short read). Is this the on-chip pair image?")
            return 3
        it += 1
        last = d

        # RED FLAG check EVERY iteration: apb_debug_unlock must be 0 throughout.
        for inst in (0, 1):
            if d[inst]["debug_unlock"] != 0:
                print("\n[RED FLAG] inst%d apb_debug_unlock=1 — the mask gate is "
                      "being forced by a strap, not the handshake. This VOIDS the "
                      "autonomy proof (a bug to fix, never a workaround)." % inst)
                print("  " + _fmt(d))
                return 3

        passed, reasons = _criteria(d)
        remaining = deadline - time.monotonic()
        print("[t+%5.1fs] %s" % (args.timeout - max(remaining, 0), _fmt(d)))
        if passed:
            print("\nAUTONOMY PROVEN — zero host writes.")
            print("  Both dies: fcsm==4, cal==1, role_lock==1.")
            print("  Roles complementary: inst%d master / inst%d slave."
                  % ((0, 1) if d[0]["role_cfg"] == 0 else (1, 0)))
            print("  Genuine peer-mask handshake: mask_hs_match==1 on both and "
                  "gate_open==match (NOT strap-forced).")
            print("  apb_debug_unlock==0 on both throughout.")
            return 0

        if remaining <= 0:
            break
        time.sleep(min(args.interval, max(remaining, 0)))

    print("\nAUTONOMY NOT PROVEN — timed out after %.0fs (%d polls)."
          % (args.timeout, it))
    if last is not None:
        _, reasons = _criteria(last)
        print("  last: " + _fmt(last))
        print("  unmet: " + "; ".join(reasons))
    print("  Do NOT paper over with a debug-unlock write — root-cause the stuck "
          "stage (§5.4).")
    return 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        sys.exit(_worker_main(sys.argv[2:]))
    sys.exit(main())
