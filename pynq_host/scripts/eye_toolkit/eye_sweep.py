#!/usr/bin/env python3
"""eye_sweep.py — TideLink PHY eye visualisation toolkit.

Sweeps the global `swi_phase_offset[3:0]` (PHY_CTRL register bits[20:17])
on one or two PYNQ-Z2 boards, observes per-lane lock status at each
phase, and emits:
  - CSV  : machine-readable raw data for diffing / regression
  - JSON : metadata (board IPs, RTL git rev, timestamp, sweep params)
  - PNG  : matplotlib heatmap visualisation
  - ASCII: terminal-friendly summary printed to stdout

This is the v1 toolkit, addressing Option B from
docs/EYE_VISUALISATION_2026_05_27.md — the GLOBAL clock-data phase sweep.

When Option C (per-lane lane_score buffer exposed via APB) lands, the
toolkit can be extended via `--mode deep` to do the full 128-point
(slip × phase) per-lane 2D eye scan; the v1 1D-per-board sweep is
implemented in `sweep_global_phase()` below as a separate function so
the deep-mode add will not disturb the v1 flow.

Usage:
    # Single board sweep (e.g. master only)
    eye_sweep.py --master 192.168.4.101 --outdir /tmp/eye_runs/

    # Paired sweep (master + slave, plotted side-by-side)
    eye_sweep.py --master 192.168.4.101 --slave 192.168.6.101 \\
                 --outdir /tmp/eye_runs/ --label "tdif-24-baseline"

    # Quick ASCII-only sweep (no matplotlib needed)
    eye_sweep.py --master 192.168.4.101 --ascii-only

    # Compare two prior captures
    eye_sweep.py --diff /tmp/eye_runs/tdif-24-baseline.csv \\
                       /tmp/eye_runs/tdif-25-postfix.csv

CONSTRAINTS:
  - Requires `sshpass` on the host running this script.
  - Requires `python3` on the PYNQ board (xilinx@<IP>).
  - Boards must already have a TideLink bitstream loaded and the link
    in LINK_IDLE (`bringup_pair_converge.sh` succeeded).
  - DOES NOT perturb the link beyond writing PHY_CTRL.swi_phase_offset
    and reading SWI_LANE_STATUS — both safe operations per
    pynq_host/scripts/deploy_pair.sh comments.

Author: SoC Labs 2026-05-27
"""

import argparse
import csv
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime

# ---------------------------------------------------------------------------
# Register layout (per pynq_host/scripts/deploy_pair.sh + memory entries
# reference_tidelink_address_map and project_tidelink_idelay_slaveclk)
# ---------------------------------------------------------------------------
PHY_CTRL_ADDR        = 0x44030000   # Wlink PHY ctrl reg
PHY_CTRL_PHASE_SHIFT = 17           # swi_phase_offset bits[20:17]
PHY_CTRL_PHASE_MASK  = 0xF          # 4-bit field, 0..15
SWI_LANE_STATUS_ADDR = 0x44032108   # Region 8 SWI_LANE_STATUS

# Settling time after writing swi_phase_offset, before reading lock status.
PHASE_SETTLE_S       = 0.5

DEFAULT_PASS = os.environ.get("TIDELINK_BOARD_PASS", "xilinx")

# ---------------------------------------------------------------------------
# Remote register access via sshpass + python3 + /dev/mem mmap
# ---------------------------------------------------------------------------
SSH_COMMON = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=8",
]


def _remote_python(ip: str, py: str, password: str) -> str:
    """Execute a python3 snippet on the PYNQ as `xilinx@<ip>` via sudo.
    Returns stdout (stripped) or raises subprocess.CalledProcessError.
    """
    cmd = [
        "sshpass", "-p", password, "ssh", *SSH_COMMON,
        f"xilinx@{ip}",
        f"echo '{password}' | sudo -S python3 -c {shlex.quote(py)} 2>/dev/null",
    ]
    out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, timeout=15)
    return out.decode().strip().splitlines()[-1] if out else ""


def remote_read(ip: str, addr: int, password: str = DEFAULT_PASS) -> int:
    """32-bit MMIO read at @addr from xilinx@<ip>."""
    py = (
        "import mmap,struct,os\n"
        "P=4096; fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)\n"
        f"a={addr}; b=a&~(P-1); o=a-b\n"
        "m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
        "mmap.PROT_READ|mmap.PROT_WRITE,offset=b)\n"
        "print('0x%08x' % struct.unpack_from('<I',m,o)[0])\n"
    )
    return int(_remote_python(ip, py, password), 16)


def remote_write_field(ip: str, addr: int, shift: int, mask: int,
                       value: int, password: str = DEFAULT_PASS) -> None:
    """Read-modify-write the field at @addr[shift+:width(mask)] := value."""
    py = (
        "import mmap,struct,os\n"
        "P=4096; fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)\n"
        f"a={addr}; b=a&~(P-1); o=a-b\n"
        "m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
        "mmap.PROT_READ|mmap.PROT_WRITE,offset=b)\n"
        "old=struct.unpack_from('<I',m,o)[0]\n"
        f"new=(old & ~({mask}<<{shift})) | (({value} & {mask})<<{shift})\n"
        "struct.pack_into('<I',m,o,new)\n"
        "print('0x%08x' % new)\n"
    )
    _remote_python(ip, py, password)


# ---------------------------------------------------------------------------
# v1 sweep — global swi_phase_offset across 0..15
# ---------------------------------------------------------------------------

def decode_lane_status(raw: int) -> dict:
    """Decode SWI_LANE_STATUS bitfield into a dict."""
    return {
        "raw":          raw,
        "lock_mask":    raw & 0xFF,
        "lock_count":   bin(raw & 0xFF).count("1"),
        "fault_mask":   (raw >> 8) & 0xFF,
        "cal_done":     (raw >> 16) & 1,
        "fcsm_state":   (raw >> 17) & 0xF,
        "cr_pkt_seen":  (raw >> 21) & 1,
    }


def iter_sweep_global_phase(ip: str, password: str = DEFAULT_PASS,
                            settle_s: float = PHASE_SETTLE_S,
                            sleep_fn=time.sleep,
                            read_fn=None,
                            write_fn=None):
    """Generator form of the v1 global phase sweep.

    Yields one decoded row per phase tap, in sweep order, immediately
    after the read for that tap completes. Restores swi_phase_offset
    to its original value on normal completion AND on early generator
    close (e.g. caller .close()s us mid-sweep, or hits an exception).

    The ``sleep_fn`` / ``read_fn`` / ``write_fn`` hooks let callers
    (live web app, tests) inject async-aware or canned implementations
    without forking the loop body.
    """
    if read_fn is None:
        read_fn = lambda a: remote_read(ip, a, password)
    if write_fn is None:
        write_fn = lambda a, sh, msk, v: remote_write_field(
            ip, a, sh, msk, v, password)

    original = read_fn(PHY_CTRL_ADDR)
    original_phase = (original >> PHY_CTRL_PHASE_SHIFT) & PHY_CTRL_PHASE_MASK

    try:
        for phase in range(16):
            write_fn(PHY_CTRL_ADDR, PHY_CTRL_PHASE_SHIFT,
                     PHY_CTRL_PHASE_MASK, phase)
            sleep_fn(settle_s)
            raw_status = read_fn(SWI_LANE_STATUS_ADDR)
            decoded = decode_lane_status(raw_status)
            decoded["phase"] = phase
            yield decoded
    finally:
        write_fn(PHY_CTRL_ADDR, PHY_CTRL_PHASE_SHIFT,
                 PHY_CTRL_PHASE_MASK, original_phase)


def sweep_global_phase(ip: str, password: str = DEFAULT_PASS,
                       settle_s: float = PHASE_SETTLE_S) -> list:
    """Run the v1 global phase sweep. Returns list of dicts, one per
    phase tap, in sweep order.

    Side effect: leaves swi_phase_offset at its original value after
    sweep completes.
    """
    return list(iter_sweep_global_phase(ip, password, settle_s))


# ---------------------------------------------------------------------------
# Output formats
# ---------------------------------------------------------------------------

def write_csv(rows: list, path: str, board_label: str) -> None:
    """Emit raw sweep data as CSV, suitable for diff / regression."""
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["board", "phase", "raw", "lock_mask_hex", "lock_count",
                    "fault_mask_hex", "cal_done", "fcsm_state",
                    "cr_pkt_seen"])
        for r in rows:
            w.writerow([board_label, r["phase"],
                        f"0x{r['raw']:08x}",
                        f"0x{r['lock_mask']:02x}",
                        r["lock_count"],
                        f"0x{r['fault_mask']:02x}",
                        r["cal_done"], r["fcsm_state"], r["cr_pkt_seen"]])


def render_ascii(per_board: dict) -> str:
    """ASCII heatmap: rows = phase tap, cols = board, cell = lane lock
    count. Useful for terminal + log output without matplotlib."""
    boards = list(per_board.keys())
    lines = []
    header = f"{'phase':>5}  " + "  ".join(f"{b:<10}" for b in boards)
    lines.append(header)
    lines.append("-" * len(header))
    for phase in range(16):
        cells = []
        for b in boards:
            row = next((r for r in per_board[b] if r["phase"] == phase), None)
            if row is None:
                cells.append(f"{'?':<10}")
                continue
            n = row["lock_count"]
            bar = "█" * n + "·" * (8 - n)
            cells.append(f"{bar} {n}")
        lines.append(f"{phase:>5}  " + "  ".join(cells))
    # Footer: identify contiguous runs of full-lock per board
    lines.append("")
    for b in boards:
        rows = sorted(per_board[b], key=lambda r: r["phase"])
        runs = []
        cur_start = None
        for r in rows:
            if r["lock_count"] == 8:
                if cur_start is None:
                    cur_start = r["phase"]
                cur_end = r["phase"]
            else:
                if cur_start is not None:
                    runs.append((cur_start, cur_end))
                    cur_start = None
        if cur_start is not None:
            runs.append((cur_start, cur_end))
        run_desc = ", ".join(f"[{s}..{e}] (w={e - s + 1})" for s, e in runs) \
            or "<none>"
        lines.append(f"  {b}: full-lock runs: {run_desc}")
    return "\n".join(lines)


def render_png(per_board: dict, path: str, title: str) -> None:
    """Matplotlib PNG: one heatmap per board, side-by-side.

    Returns silently and skips if matplotlib is not installed (so the
    toolkit still works on minimal Python installs)."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("[eye_sweep] matplotlib not available — skipping PNG",
              file=sys.stderr)
        return

    boards = list(per_board.keys())
    n = len(boards)
    fig, axs = plt.subplots(1, n, figsize=(4 * n + 1, 4), squeeze=False)

    for col, b in enumerate(boards):
        rows = sorted(per_board[b], key=lambda r: r["phase"])
        # Matrix: phase × lane, cell = lock(0/1)
        mat = np.zeros((16, 8), dtype=int)
        for r in rows:
            for lane in range(8):
                mat[r["phase"], lane] = (r["lock_mask"] >> lane) & 1
        ax = axs[0][col]
        im = ax.imshow(mat, aspect="auto", origin="lower",
                       cmap="RdYlGn", vmin=0, vmax=1, interpolation="nearest")
        ax.set_xticks(range(8))
        ax.set_xticklabels([f"L{i}" for i in range(8)])
        ax.set_yticks(range(16))
        ax.set_xlabel("lane")
        ax.set_ylabel("swi_phase_offset")
        ax.set_title(b)

    fig.suptitle(title, fontsize=11)
    plt.tight_layout(rect=[0, 0, 1, 0.97])
    plt.savefig(path, dpi=120)
    plt.close(fig)


# ---------------------------------------------------------------------------
# Compare two prior captures (regression mode)
# ---------------------------------------------------------------------------

def read_csv(path: str) -> dict:
    """Re-read a CSV produced by write_csv. Returns per_board dict."""
    per_board = {}
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            b = row["board"]
            per_board.setdefault(b, []).append({
                "phase":       int(row["phase"]),
                "raw":         int(row["raw"], 16),
                "lock_mask":   int(row["lock_mask_hex"], 16),
                "lock_count":  int(row["lock_count"]),
                "fault_mask":  int(row["fault_mask_hex"], 16),
                "cal_done":    int(row["cal_done"]),
                "fcsm_state":  int(row["fcsm_state"]),
                "cr_pkt_seen": int(row["cr_pkt_seen"]),
            })
    return per_board


def diff_captures(path_a: str, path_b: str) -> str:
    """Compare two CSV captures, highlighting changes in lock_mask per
    (board, phase). Returns human-readable summary."""
    a = read_csv(path_a)
    b = read_csv(path_b)
    out = [f"DIFF: {path_a}  vs  {path_b}", "=" * 70]
    boards = sorted(set(a) | set(b))
    for board in boards:
        if board not in a:
            out.append(f"{board}: only in B")
            continue
        if board not in b:
            out.append(f"{board}: only in A")
            continue
        out.append(f"{board}:")
        # Index by phase
        a_by_phase = {r["phase"]: r for r in a[board]}
        b_by_phase = {r["phase"]: r for r in b[board]}
        any_diff = False
        for ph in sorted(set(a_by_phase) | set(b_by_phase)):
            ra = a_by_phase.get(ph)
            rb = b_by_phase.get(ph)
            if ra and rb and ra["lock_mask"] == rb["lock_mask"]:
                continue
            any_diff = True
            la = f"0x{ra['lock_mask']:02x} ({ra['lock_count']}/8)" \
                if ra else "absent"
            lb = f"0x{rb['lock_mask']:02x} ({rb['lock_count']}/8)" \
                if rb else "absent"
            out.append(f"  phase {ph:2d}: {la}  ->  {lb}")
        if not any_diff:
            out.append("  (no change)")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="TideLink PHY eye-sweep toolkit (v1: global phase)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--master", default=None,
                    help="Master PYNQ IP (die_a). At least one of "
                         "--master/--slave required unless --diff used.")
    ap.add_argument("--slave", default=None,
                    help="Slave PYNQ IP (die_b).")
    ap.add_argument("--outdir", default="/tmp/eye_runs",
                    help="Output dir for CSV/JSON/PNG (default /tmp/eye_runs)")
    ap.add_argument("--label", default=None,
                    help="Run label, used in filenames + plot titles. "
                         "Defaults to current git rev + timestamp.")
    ap.add_argument("--settle", type=float, default=PHASE_SETTLE_S,
                    help=f"Settling time per phase tap "
                         f"(s, default {PHASE_SETTLE_S})")
    ap.add_argument("--password", default=DEFAULT_PASS,
                    help="PYNQ board password (default env "
                         "TIDELINK_BOARD_PASS or 'xilinx')")
    ap.add_argument("--ascii-only", action="store_true",
                    help="Skip PNG rendering (faster, no matplotlib needed)")
    ap.add_argument("--diff", nargs=2, metavar=("CSV_A", "CSV_B"),
                    default=None,
                    help="Compare two prior CSV captures and exit.")

    args = ap.parse_args()

    # Diff mode short-circuits the sweep.
    if args.diff:
        print(diff_captures(args.diff[0], args.diff[1]))
        return 0

    if not args.master and not args.slave:
        ap.error("at least one of --master / --slave required "
                 "(or use --diff to compare prior captures)")

    os.makedirs(args.outdir, exist_ok=True)

    if args.label is None:
        try:
            git_rev = subprocess.check_output(
                ["git", "rev-parse", "--short", "HEAD"],
                stderr=subprocess.DEVNULL,
                cwd=os.path.dirname(os.path.abspath(__file__))
            ).decode().strip()
        except Exception:
            git_rev = "unknown"
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        args.label = f"{git_rev}_{ts}"

    print(f"[eye_sweep] label={args.label}")
    per_board = {}
    metadata = {"label": args.label, "timestamp": datetime.now().isoformat(),
                "boards": {}, "settle_s": args.settle}

    if args.master:
        print(f"[eye_sweep] sweeping master @ {args.master} ...")
        per_board["master"] = sweep_global_phase(
            args.master, args.password, args.settle)
        metadata["boards"]["master"] = args.master
    if args.slave:
        print(f"[eye_sweep] sweeping slave  @ {args.slave} ...")
        per_board["slave"] = sweep_global_phase(
            args.slave, args.password, args.settle)
        metadata["boards"]["slave"] = args.slave

    # Write outputs
    csv_path = os.path.join(args.outdir, f"{args.label}.csv")
    json_path = os.path.join(args.outdir, f"{args.label}.json")
    png_path = os.path.join(args.outdir, f"{args.label}.png")
    for board, rows in per_board.items():
        write_csv(rows, csv_path.replace(".csv", f"_{board}.csv"), board)

    with open(json_path, "w") as f:
        json.dump(metadata, f, indent=2)

    ascii_report = render_ascii(per_board)
    print()
    print(ascii_report)
    print()

    if not args.ascii_only:
        render_png(per_board, png_path,
                   title=f"TideLink eye sweep — {args.label}")
        print(f"[eye_sweep] saved PNG: {png_path}")

    print(f"[eye_sweep] saved CSV(s) under {args.outdir}")
    print(f"[eye_sweep] saved metadata: {json_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
