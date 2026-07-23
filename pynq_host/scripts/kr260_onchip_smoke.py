#!/usr/bin/env python3
"""kr260_onchip_smoke.py — plumbing smoke for the KR260 on-chip PAIR. Runs ON the board, as root.

This is NOT a link bring-up and NOT the autonomy proof (that is
kr260_onchip_autonomy.py). It proves ONLY that the dual-instance on-chip
bitstream (fpga/targets/kr260-pair-onchip) is wired and that BOTH TideLink
instances exist with OPPOSITE role straps — the cheapest proof you flashed a
real two-instance image. It says nothing about link-up, eye, autoneg, or data.

Ordered probes (each pass/fail):
  1. inst0 APB aperture responds        (0x8403_0000)
  2. inst1 APB aperture responds        (0x8C03_0000)
  3. inst0 strap GPIO reads 0 (die_a)   (0x8404_0000)
  4. inst1 strap GPIO reads 1 (die_b)   (0x8C04_0000)
  5. (info) each instance's baked PAIR_BASE points at the peer
  6. (opt-in --unlock) a PL register is writable  (debug_unlock GPIO, restored)

SAFETY — three first-class hazards this script is built around:

  * UNDECODED-READ HANG. On ZynqMP a read of an address the PL does not decode
    hangs the AXI bus with NO timeout. So this script touches ONLY the three
    control-plane apertures every on-chip image decodes: apb, strap, debug. It
    NEVER touches ahb_ptp/phc (absent from the phase-1 on-chip bitstream),
    ahb_sub (a read there launches a cross-chiplet transaction that hangs if
    the link is down), or ahb_tx (write hazard, below).

  * PS<->PL TRAINING-ENTRY WEDGE. NEGO_TRAIN_CFG_RESET arms training at POR, and
    die_a's PS<->PL bus has been observed to die at training entry (the fch
    sequencer pins apb_pready low) with NO AXI timeout — so the FIRST APB read
    after a PL load can hang forever. There is no AXI timeout to lean on and we
    do not invent one. Instead every probe runs in a short-lived WORKER
    subprocess (this same file, re-invoked with --worker) under a wall-clock
    timeout enforced by the parent. A probe that does not return in time is
    reported as WEDGED and the parent aborts, freeing the controlling shell.
    (Best-effort only: a wedged AXI read may leave the worker stuck in an
    uninterruptible kernel read — the parent stops waiting on it and returns,
    but the board itself is not un-wedged. This mirrors the repo's existing
    `timeout N ssh ... python3 tl_poke.py <cmd>` staged-helper convention, moved
    on-board: tl_poke.py is the dumb reader, the caller owns the timeout.)

  * AHB_TX HANG. Writing the TX aperture before the link is verified up hangs
    the PS on HREADY from a wedged FC adapter. This smoke test writes NOTHING to
    ahb_tx; any data path must gate on overlay.py:assert_link_safe_for_tx (or
    the fcsm==4 & cal==1 & fc-active check) first. See kr260_onchip_autonomy.py.

Usage (after `make -C fpga deploy TARGET=kr260-pair-onchip`):

    sudo python3 pynq_host/scripts/kr260_onchip_smoke.py
    sudo python3 pynq_host/scripts/kr260_onchip_smoke.py --unlock   # + writability

Exit status: 0 = every check passed; 1 = at least one FAIL; 2 = a probe WEDGED;
3 = a probe hit a bus error / undecoded read (worker died).
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
APB_BASE_0   = 0x84030000   # 32 KB  TideLink APB (Wlink + chiplet ctrl)
STRAP_BASE_0 = 0x84040000   #  4 KB  axi_gpio_strap        (role_strap_i)
DEBUG_BASE_0 = 0x84041000   #  4 KB  axi_gpio_debug_unlock

def apb_base(inst):   return APB_BASE_0   | (inst * INST_STRIDE)
def strap_base(inst): return STRAP_BASE_0 | (inst * INST_STRIDE)
def debug_base(inst): return DEBUG_BASE_0 | (inst * INST_STRIDE)

# --- APB register offsets. Verified against the RTL read mux:
#   STATUS      0x2108  Region 8 slot 2  axi_chiplet_controller.sv:1934-1948
#                       ([19:17] fcsm, [16] cal_done, [7:0] lane_locked)
#   ROLE_CFG    0x2080  Region 4 slot 0  :907 ([0] role_cfg 0=master/1=slave, [1] role_lock)
#   OBS_MASK_HS 0x2194  Region C slot 5  :2018-2031 / mux :2083 ([19] match, [20] gate_open)
#   PAIR_BASE   0x2000  Region 0 slot 0  fifo/tidelink_apb_regs.sv:226,:549 (RW, reset=TIDELINK_PAIR_BASE)
STATUS_OFF      = 0x2108
ROLE_CFG_OFF    = 0x2080
OBS_MASK_HS_OFF = 0x2194
PAIR_BASE_OFF   = 0x2000
GPIO_DATA_OFF   = 0x000

# Baked PAIR_BASE per instance (addrmap.tcl: inst0 -> the OTHER instance's apb
# base + 0x2000). Distinct per instance, each pointing at the peer's config.
PAIR_BASE_EXPECT = {0: 0x8C032000, 1: 0x84032000}

WEDGE_TIMEOUT = 6.0   # seconds a single probe may take before we call it WEDGED


# =============================================================================
# Worker mode: a dumb, single-shot /dev/mem accessor. Runs in a child process
# so the parent can bound it with a wall-clock timeout. Single aligned 32-bit
# ctypes load/store ONLY (the struct-module byte-slice path emits ~5 narrow bus
# stores per word on this platform; see tl_poke.py). Absolute addresses, SoC-agnostic.
# =============================================================================
def _worker_main(argv):
    op = argv[0]
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    maps = {}

    def _mm(addr):
        base = addr & ~(PAGE - 1)
        if base not in maps:
            maps[base] = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                                   mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        return maps[base], addr - base

    def rd(addr):
        m, off = _mm(addr)
        return ctypes.c_uint32.from_buffer(m, off).value

    def wr(addr, val):
        m, off = _mm(addr)
        ctypes.c_uint32.from_buffer(m, off).value = val & 0xFFFFFFFF

    if op == "rdmany":
        for a in argv[1:]:
            sys.stdout.write("0x%08x\n" % rd(int(a, 0)))
        return 0
    if op == "wr":
        wr(int(argv[1], 0), int(argv[2], 0))
        sys.stdout.write("OK\n")
        return 0
    sys.stderr.write("bad worker op %r\n" % op)
    return 3


# =============================================================================
# Parent side: spawn a worker, enforce the timeout by hand (never block on an
# unkillable child), classify the result.
# =============================================================================
def _run_worker(worker_args, timeout):
    """Return (status, text). status in {'ok','wedged','err'}."""
    out = tempfile.TemporaryFile(mode="w+")
    try:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--worker", *worker_args],
            stdout=out, stderr=subprocess.DEVNULL)
    except Exception as e:  # noqa: BLE001
        out.close()
        return "err", "spawn failed: %s" % e
    deadline = time.monotonic() + timeout
    while proc.poll() is None:
        if time.monotonic() > deadline:
            try:
                proc.kill()          # SIGKILL; we do NOT waitpid — a D-state
            except Exception:        # child on a wedged AXI read may never die,
                pass                 # but the parent (and the shell) is freed.
            out.close()
            return "wedged", None
        time.sleep(0.02)
    out.seek(0)
    text = out.read()
    out.close()
    if proc.returncode != 0:
        return "err", text
    return "ok", text


def read_words(addrs, timeout=WEDGE_TIMEOUT):
    """Read a list of absolute addresses in one timed worker. Returns
    (status, [ints]) with status 'ok'/'wedged'/'err'."""
    status, text = _run_worker(["rdmany", *("0x%x" % a for a in addrs)], timeout)
    if status != "ok":
        return status, None
    vals = [int(line, 16) for line in text.split() if line.strip()]
    if len(vals) != len(addrs):
        return "err", None
    return "ok", vals


def write_word(addr, val, timeout=WEDGE_TIMEOUT):
    status, _ = _run_worker(["wr", "0x%x" % addr, "0x%x" % val], timeout)
    return status


class WedgeAbort(Exception):
    pass


class Report:
    def __init__(self):
        self.fails = 0

    def line(self, ok, label, detail):
        tag = "INFO" if ok is None else ("PASS" if ok else "FAIL")
        if ok is False:
            self.fails += 1
        print("[%s] %-26s %s" % (tag, label, detail))


def _guarded_read(r, label, addrs):
    """Timed read; on WEDGED, report and raise WedgeAbort (stop probing a
    wedged board). On worker error, report FAIL and return None."""
    status, vals = read_words(addrs)
    if status == "wedged":
        r.line(False, label,
               "WEDGED — no response in %.0fs (PS<->PL bus hung; likely the "
               "training-entry wedge). ABORTING further probes." % WEDGE_TIMEOUT)
        raise WedgeAbort()
    if status == "err":
        r.line(False, label,
               "worker died (SIGBUS / undecoded read / no data) — treat as a "
               "bus error")
        return None
    return vals


def main():
    global WEDGE_TIMEOUT
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--unlock", action="store_true",
                    help="also exercise a PL register write (debug_unlock GPIO), "
                         "then RESTORE it to 0. WARNING: a transient "
                         "debug_unlock=1 opens mask_hs_gate_open and can "
                         "pre-latch role_lock, voiding a later autonomy proof. "
                         "Reload the PL before kr260_onchip_autonomy.py.")
    ap.add_argument("--wedge-timeout", type=float, default=WEDGE_TIMEOUT,
                    help="seconds a probe may take before it is called WEDGED")
    args = ap.parse_args()

    WEDGE_TIMEOUT = args.wedge_timeout

    if os.geteuid() != 0:
        print("ERROR: need root for /dev/mem (use sudo)", file=sys.stderr)
        return 2

    print("KR260 on-chip PAIR smoke — inst0=die_a (0x8403_0000)  "
          "inst1=die_b (0x8C03_0000)")
    print("Probes touch ONLY apb/strap/debug (never ahb_ptp/phc/ahb_sub/ahb_tx).\n")

    r = Report()
    try:
        # -- Probes 1 & 2: both APB apertures respond. The first read on each
        #    instance is the wedge-risky one, so it is timed-guarded.
        for inst in (0, 1):
            base = apb_base(inst)
            vals = _guarded_read(
                r, "inst%d APB responds" % inst,
                [base + STATUS_OFF, base + ROLE_CFG_OFF,
                 base + OBS_MASK_HS_OFF, base + PAIR_BASE_OFF])
            if vals is None:
                continue
            status_v, role_v, maskhs_v, pairbase_v = vals
            # A dead/undecoded aperture reads all-identical (all 0x0 or all 0xF)
            # on every register; any variation proves it is really answering.
            alive = len(set(vals)) > 1
            r.line(alive, "inst%d APB responds" % inst,
                   "@0x%08X status=0x%08X role=0x%08X mask_hs=0x%08X"
                   % (base, status_v, role_v, maskhs_v))
            # (info) baked PAIR_BASE should point at the peer's config aperture.
            want = PAIR_BASE_EXPECT[inst]
            r.line(pairbase_v == want, "inst%d PAIR_BASE -> peer" % inst,
                   "0x%08X (expect 0x%08X, the other die's apb+0x2000)"
                   % (pairbase_v, want))

        # -- Probes 3 & 4: strap GPIOs read OPPOSITE roles (0 and 1).
        for inst, want in ((0, 0), (1, 1)):
            vals = _guarded_read(r, "inst%d strap" % inst,
                                 [strap_base(inst) + GPIO_DATA_OFF])
            if vals is None:
                continue
            strap = vals[0] & 0x1
            who = "die_a" if inst == 0 else "die_b"
            r.line(strap == want, "inst%d strap = %d (%s)" % (inst, want, who),
                   "strap=0x%X @0x%08X%s" % (strap, strap_base(inst),
                    "" if strap == want else "  <-- WRONG/MISSING INSTANCE"))

        # -- Probe 6: a PL register is writable (opt-in; restores to 0).
        if args.unlock:
            for inst in (0, 1):
                da = debug_base(inst) + GPIO_DATA_OFF
                w1 = write_word(da, 1)
                if w1 == "wedged":
                    r.line(False, "inst%d debug writable" % inst,
                           "WEDGED writing debug_unlock — ABORTING")
                    raise WedgeAbort()
                vals = _guarded_read(r, "inst%d debug rb" % inst, [da])
                rb = None if vals is None else (vals[0] & 0x1)
                # Restore to 0 regardless, so we do not leave the mask gate open.
                write_word(da, 0)
                r.line(rb == 1, "inst%d debug_unlock writable" % inst,
                       "wrote 1 read %s @0x%08X (restored to 0)"
                       % ("0x%X" % rb if rb is not None else "?", da))
        else:
            r.line(None, "PL register writable",
                   "skipped (pass --unlock; note it can pre-latch role_lock)")

    except WedgeAbort:
        print("\nSMOKE WEDGED — a probe hung the PS<->PL bus. The board likely "
              "needs a PL reload / power cycle.")
        return 2

    print()
    if r.fails:
        print("SMOKE FAILED — %d check(s) failed." % r.fails)
        return 1
    print("SMOKE PASSED — both instances respond and hold OPPOSITE role straps.")
    print("NOTE: plumbing only. Nothing here proves link-up, autoneg, eye, or "
          "data — run kr260_onchip_autonomy.py for the autonomy proof.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        sys.exit(_worker_main(sys.argv[2:]))
    sys.exit(main())
