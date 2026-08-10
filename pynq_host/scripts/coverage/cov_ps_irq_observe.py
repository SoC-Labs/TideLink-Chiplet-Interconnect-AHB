#!/usr/bin/env python3
# =============================================================================
# cov_ps_irq_observe.py — BOARD-SIDE (runs ON the KR260 PS Linux): the FIRST
#     instrument that checks whether a chiplet interrupt line actually REACHES the
#     PS. Snapshots /proc/interrupts + UIO (+ GIC debugfs if available), applies a
#     stimulus, and asserts the corresponding pl_ps_irq0/GIC count INCREMENTS.
#
# WHY THIS EXISTS (the gap it closes):
#   Per the V-plan: "No interrupt has EVER been observed asserting on hardware —
#   not a line, not an ISR, not even a confirmed source-latch high." Every current
#   HW "IRQ" check is a register poll used as a proxy. NO existing script watches
#   the PS interrupt controller. This is that instrument: a before/after delta on
#   the GIC counters is the first proof a fabric line (pl_ps_irq0) reaches the PS.
#
# THE PS PATH (from the FPGA block design):
#   The eth-chiplet boundary IRQ outputs { eth_irq, phc_pps_irq, phc_alarm_irq,
#   tidechart_irq_o } are CONCATENATED -> pl_ps_irq0 -> PS GIC (an SPI line). They
#   show up in /proc/interrupts under the PL/fabric controller. tidechart_irq_o is
#   eth-chiplet IRQ[14]. NOTE: the cross-die MAILBOX doorbell is a DIFFERENT path —
#   it feeds the internal M0 NVIC (d2d_irq -> CPU1 IRQ0), NOT pl_ps_irq0 — so it is
#   NOT expected to move a PS GIC counter without firmware (that is test #3). Use
#   --stimulus tidechart here for the PS-reachable source.
#
# MODES:
#   --phase auto     (default) baseline -> local stimulus -> re-snapshot -> diff.
#   --phase baseline  write a snapshot to --state and exit (apply an EXTERNAL
#                     stimulus yourself: bench source, or die_a mailbox fire).
#   --phase compare   read --state, take a fresh snapshot, diff (pairs with baseline).
#
# STIMULUS (--stimulus, auto phase only):
#   none               observe only (for externally-applied stimulus).
#   tidechart (default) pulse TideChart election_start + congestion broadcast via
#                       the in-window APB (0x4_2E04_xxxx). LOCAL config-plane writes
#                       only -> wedge-safe. tidechart_irq_o is the pl_ps_irq0 source.
#
# SAFETY: reads /proc & sysfs (unprivileged). The tidechart stimulus writes only the
# in-window TideChart APB (0x4_2E04_0008/0x74) — combinational/config plane, cannot
# wedge the AXI data path. NEVER touches the peer aperture or bare-link map. Root is
# required only for a /dev/mem stimulus (not for --stimulus none / baseline / compare).
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
import argparse
import json
import mmap
import os
import re
import struct
import sys
import time

WINDOW_BASE = 0x400000000
TC_SOC_BASE = 0x2E040000                 # TideChart APB -> PS 0x4_2E040000
TC_CTRL     = 0x08                       # [0] election_start
TC_CONG_CTRL = 0x74                      # [0] bcast_enable [1] bcast_trigger(W1P)

# Narrow markers of a PL->PS FABRIC line on Zynq UltraScale+ (KR260). Deliberately
# NARROW: a loose "eth"/"gpio" match would flag the PS's own GEM (ethN) or PS GPIO —
# which tick on their own and would false-PASS. We key on fabric/UIO device names
# AND on the GIC SPI hwirqs that IRQ_F2P (pl_ps_irq0/1) actually land on.
_PL_NAME_HINTS = ("fabric", "amba_pl", "pl_ps", "uio", "tidechart", "chiplet",
                  "eth_ss", "eth-chiplet")
_PL_SPI_RANGES = ((121, 128),   # bank 0: pl_ps_irq0[7:0] -> GIC SPI 121..128
                  (136, 143))   # bank 1: pl_ps_irq0[15:8] -> GIC SPI 136..143


# --- /dev/mem (only used by the tidechart stimulus) --------------------------
def _mm(phys):
    page = phys & ~0xFFF
    off = phys - page
    f = open("/dev/mem", "r+b", buffering=0)
    m = mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED,
                  mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
    return f, m, off


def wr(phys, val):
    f, m, off = _mm(phys)
    m[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)
    m.close(); f.close()


# --- snapshots ---------------------------------------------------------------
def snap_interrupts():
    """Parse /proc/interrupts -> {label: {'total': int, 'desc': str}}. Robust to a
    variable CPU-column count and non-numeric IRQ ids (IPI/ERR/etc.)."""
    out = {}
    try:
        with open("/proc/interrupts") as f:
            lines = f.readlines()
    except OSError as e:
        print("  WARN: cannot read /proc/interrupts: %s" % e)
        return out
    for ln in lines[1:]:                 # first line is the CPU header
        parts = ln.split()
        if not parts:
            continue
        label = parts[0].rstrip(":")
        counts, desc = [], []
        for tok in parts[1:]:
            if not desc and re.fullmatch(r"\d+", tok):
                counts.append(int(tok))
            else:
                desc.append(tok)
        out[label] = {"total": sum(counts), "desc": " ".join(desc)}
    return out


def snap_uio():
    """List UIO devices (name + associated /proc line if the name matches)."""
    devs = []
    base = "/sys/class/uio"
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return devs
    for d in names:
        try:
            with open(os.path.join(base, d, "name")) as f:
                nm = f.read().strip()
        except OSError:
            nm = "?"
        devs.append((d, nm))
    return devs


def snap_gic_debug():
    """Best-effort GIC/irqdomain view from debugfs (root + debugfs mounted)."""
    p = "/sys/kernel/debug/irq/domains/default"
    if os.path.exists(p):
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            return None
    return None


def snapshot():
    return {"t": time.time(),
            "interrupts": snap_interrupts(),
            "uio": snap_uio(),
            "gic": snap_gic_debug()}


def print_snapshot(s, tag):
    print("  [%s] %d IRQ lines; UIO: %s"
          % (tag, len(s["interrupts"]),
             ", ".join("%s=%s" % (d, n) for d, n in s["uio"]) or "(none)"))


# --- diff --------------------------------------------------------------------
def diff(before, after):
    """Return sorted [(label, delta, desc)] for every line whose count increased,
    plus any newly-appeared line (delta = its full count)."""
    b, a = before["interrupts"], after["interrupts"]
    moved = []
    for label, av in a.items():
        bv = b.get(label, {"total": 0})
        d = av["total"] - bv["total"]
        if d > 0:
            moved.append((label, d, av["desc"]))
    moved.sort(key=lambda x: -x[1])
    return moved


def _is_pl(desc, label):
    """True iff this line looks like a PL->PS fabric/UIO source (not a PS peripheral).
    Matches a fabric/UIO device name OR a GIC SPI hwirq in the IRQ_F2P range."""
    s = (desc + " " + label).lower()
    if any(h in s for h in _PL_NAME_HINTS):
        return True
    for tok in re.findall(r"\d+", desc):        # e.g. "GICv2 121 Level fabric"
        n = int(tok)
        if any(lo <= n <= hi for lo, hi in _PL_SPI_RANGES):
            return True
    return False


def report(moved):
    if not moved:
        print("  NO interrupt line incremented.")
        return False
    print("  Lines that INCREMENTED:")
    for label, d, desc in moved:
        star = " <== candidate pl_ps_irq0 / fabric line" if _is_pl(desc, label) else ""
        print("    IRQ %-6s +%-6d  %s%s" % (label, d, desc, star))
    return True


# --- stimulus ----------------------------------------------------------------
def stim_tidechart():
    """Pulse TideChart so tidechart_irq_o (pl_ps_irq0 source) has a chance to
    assert. LOCAL in-window APB writes only (0x4_2E04_xxxx) -> wedge-safe."""
    if os.geteuid() != 0:
        sys.exit("ERROR: --stimulus tidechart needs root for /dev/mem (sudo).")
    base = WINDOW_BASE + TC_SOC_BASE
    print("  stimulus: TideChart election_start + congestion broadcast (0x4_2E04_xxxx)")
    wr(base + TC_CTRL, 0x1)              # election_start edge
    time.sleep(0.05)
    wr(base + TC_CONG_CTRL, 0x1)         # bcast_enable
    wr(base + TC_CONG_CTRL, 0x3)         # bcast_trigger (W1P)
    time.sleep(0.05)


STIMULI = {"none": lambda: print("  stimulus: none (observe only)"),
           "tidechart": stim_tidechart}


# --- phases ------------------------------------------------------------------
def phase_auto(stimulus, hold, verbose):
    print("=== PS IRQ observe (auto): baseline -> stimulus '%s' -> compare ===" % stimulus)
    before = snapshot()
    print_snapshot(before, "baseline")
    if verbose:
        _dump_all(before)
    STIMULI[stimulus]()
    time.sleep(hold)
    after = snapshot()
    print_snapshot(after, "after")
    moved = diff(before, after)
    any_moved = report(moved)
    pl_moved = any(_is_pl(d, l) for l, _, d in moved)
    if pl_moved:
        print("RESULT: PASS — a fabric/PL interrupt line reached the PS GIC (FIRST "
              "hardware evidence a chiplet IRQ crosses to the PS).")
        return 0
    if any_moved:
        print("RESULT: WARN — some IRQ lines moved but none look like pl_ps_irq0 "
              "(likely unrelated PS activity). Inspect the labels above.")
        return 1
    print("RESULT: INCONCLUSIVE — no line moved. This is the EXPECTED current state "
          "(no IRQ has ever been observed on this HW). Either the source did not "
          "assert (tidechart_irq_o gated / TideChart RTL gap) or the concat->GIC "
          "wiring is not live. Try --stimulus none with an external source, or scope "
          "tidechart_irq_o at the boundary.")
    return 2


def phase_baseline(state_path, verbose):
    print("=== PS IRQ observe (baseline): snapshot -> %s ===" % state_path)
    s = snapshot()
    print_snapshot(s, "baseline")
    if verbose:
        _dump_all(s)
    with open(state_path, "w") as f:
        json.dump(s, f)
    print("  wrote %s. Now apply your EXTERNAL stimulus (bench source, or run "
          "cov_mbox_irq_source.py from the host), then: --phase compare --state %s"
          % (state_path, state_path))
    return 0


def phase_compare(state_path, verbose):
    print("=== PS IRQ observe (compare): fresh snapshot vs %s ===" % state_path)
    try:
        with open(state_path) as f:
            before = json.load(f)
    except OSError as e:
        sys.exit("ERROR: cannot read baseline %s: %s (run --phase baseline first)"
                 % (state_path, e))
    after = snapshot()
    print_snapshot(before, "baseline")
    print_snapshot(after, "after")
    moved = diff(before, after)
    any_moved = report(moved)
    pl_moved = any(_is_pl(d, l) for l, _, d in moved)
    if pl_moved:
        print("RESULT: PASS — a fabric/PL line incremented across the external "
              "stimulus (an interrupt reached the PS).")
        return 0
    print("RESULT: %s — see deltas above." % ("WARN" if any_moved else "INCONCLUSIVE"))
    return 1 if any_moved else 2


def _dump_all(s):
    for label, v in sorted(s["interrupts"].items()):
        print("      IRQ %-6s %-10d %s" % (label, v["total"], v["desc"]))


def main():
    ap = argparse.ArgumentParser(
        description="Observe whether a chiplet interrupt line reaches the PS GIC "
                    "(runs ON the KR260 PS). First-ever PS-line detection instrument.")
    ap.add_argument("--phase", default="auto", choices=("auto", "baseline", "compare"))
    ap.add_argument("--stimulus", default="tidechart", choices=tuple(STIMULI),
                    help="auto phase: local source to pulse. tidechart drives the "
                         "pl_ps_irq0 source; none = observe only. Default tidechart.")
    ap.add_argument("--hold", type=float, default=0.5,
                    help="seconds to wait after the stimulus before re-snapshotting.")
    ap.add_argument("--state", default="/tmp/cov_ps_irq_baseline.json",
                    help="baseline/compare: snapshot JSON path.")
    ap.add_argument("--verbose", action="store_true", help="dump every IRQ line.")
    args = ap.parse_args()
    if args.phase == "auto":
        return phase_auto(args.stimulus, args.hold, args.verbose)
    if args.phase == "baseline":
        return phase_baseline(args.state, args.verbose)
    return phase_compare(args.state, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
