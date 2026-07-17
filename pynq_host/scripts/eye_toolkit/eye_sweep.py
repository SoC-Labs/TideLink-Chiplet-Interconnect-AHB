#!/usr/bin/env python3
"""eye_sweep.py — TideLink PHY live-lane-phase visualisation toolkit.

Despite the legacy "eye" name in this file and its parent directory,
what this tool actually emits is a per-lane heatmap of `lane_locked`
across the 16 possible global `swi_phase_offset` values. It is NOT a
conventional time-domain eye diagram. The file/module names are kept
for backwards compatibility with import paths and shipped systemd
units; user-visible labels in the web UI use "live-lane-phase".

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

# ---------------------------------------------------------------------------
# Region 10 (v2 deep-mode eye visibility) — per
# docs/EYE_VISIBILITY_RTL_PROPOSAL.md §5.
# ---------------------------------------------------------------------------
SWI_EYE_CTRL         = 0x44032140
SWI_EYE_LANE_SEL     = 0x44032144
SWI_EYE_DWELL_US     = 0x44032148
SWI_EYE_STATUS       = 0x4403214C
SWI_FORCE_PHASE_EN   = 0x44032150
SWI_FORCE_PHASE_VAL  = 0x44032154
SWI_FORCE_SLIP_VAL   = 0x44032158
EYE_CRC_ERR_LANE_LO  = 0x4403215C
EYE_CRC_ERR_LANE_HI  = 0x44032160
EYE_SCORE_IDX        = 0x44032164
EYE_SCORE_DATA       = 0x44032168
EYE_BURST_DATA       = 0x4403216C
EYE_LAST_LATCHED     = 0x44032170
PHY_EYE_ID           = 0x44032174

# Peer aperture: die_a addresses die_b's Region 10 at 0x40000000 + offset.
# WARNING: 0x40000000 is the peer aperture base. 0x44010000 is the LOCAL
# RX FIFO — do NOT confuse them. The test_peer_aperture_uses_0x40032140
# guard exists explicitly to catch any drift of this constant.
PEER_APERTURE_BASE   = 0x40000000
PEER_EYE_REGION10    = PEER_APERTURE_BASE + (SWI_EYE_CTRL & 0xFFFFF)  # 0x40032140

# SWI_EYE_CTRL bit map (W1P unless noted)
EYE_CTRL_ENTER             = 1 << 0
EYE_CTRL_RESET             = 1 << 1
EYE_CTRL_MODE_SHIFT        = 4
EYE_CTRL_MODE_MASK         = 0x3 << EYE_CTRL_MODE_SHIFT
EYE_CTRL_MODE_OFF          = 0 << EYE_CTRL_MODE_SHIFT
EYE_CTRL_MODE_SINGLE       = 1 << EYE_CTRL_MODE_SHIFT
EYE_CTRL_REMOTE_TRIGGER_EN = 1 << 7  # reserved (Mechanism β), RAZ/WI in v2
EYE_CTRL_FORCE_FULL_SWEEP  = 1 << 8
EYE_CTRL_AUTO_INCREMENT    = 1 << 9
EYE_CTRL_CAPTURE_ARM       = 1 << 16  # legacy alias of ENTER

# SWI_EYE_STATUS[2:0] state encoding
EYE_STATE_IDLE       = 0
EYE_STATE_SWEEPING   = 1
EYE_STATE_DONE       = 2
EYE_STATE_TIMED_OUT  = 3
EYE_STATE_DRAINING   = 4

# Deep-mode capture geometry: 128 points (slip[2:0] × phase[3:0]) per lane,
# drained as 26 reads of EYE_BURST_DATA (each = 5 × 6-bit scores → 130
# slots, last two discarded).
EYE_POINTS_PER_LANE  = 128
EYE_BURST_READS      = 26
EYE_SCORES_PER_WORD  = 5
EYE_SCORE_BITS       = 6
EYE_SCORE_MASK       = (1 << EYE_SCORE_BITS) - 1

DEFAULT_DWELL_US     = 100_000  # 100 ms — proposal §11(a) recommended

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


def remote_write(ip: str, addr: int, value: int,
                 password: str = DEFAULT_PASS) -> None:
    """32-bit MMIO write of @value to @addr on xilinx@<ip>."""
    py = (
        "import mmap,struct,os\n"
        "P=4096; fd=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)\n"
        f"a={addr}; b=a&~(P-1); o=a-b\n"
        "m=mmap.mmap(fd,P,mmap.MAP_SHARED,"
        "mmap.PROT_READ|mmap.PROT_WRITE,offset=b)\n"
        f"struct.pack_into('<I',m,o,{value & 0xFFFFFFFF})\n"
        f"print('0x%08x' % {value & 0xFFFFFFFF})\n"
    )
    _remote_python(ip, py, password)


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
# v2 deep mode — per-lane 128-point eye capture via Region 10
# ---------------------------------------------------------------------------

class RemoteIO:
    """Minimal read/write seam for deep-mode capture.

    Tests mock this; live HW wraps remote_read / remote_write keyed on a
    PYNQ IP. Subclassing is preferred over passing two callables because
    the deep-mode loop needs both read and write against the same target
    (local or peer aperture) consistently.
    """
    def read(self, addr: int) -> int:
        raise NotImplementedError

    def write(self, addr: int, value: int) -> None:
        raise NotImplementedError


class SSHRemoteIO(RemoteIO):
    def __init__(self, ip: str, password: str = DEFAULT_PASS):
        self.ip = ip
        self.password = password

    def read(self, addr: int) -> int:
        return remote_read(self.ip, addr, self.password)

    def write(self, addr: int, value: int) -> None:
        remote_write(self.ip, addr, value, self.password)


def decode_burst_word(word: int) -> list:
    """Unpack a 32-bit EYE_BURST_DATA word into 5 × 6-bit scores
    (bits [29:0]; bits [31:30] are reserved)."""
    return [(word >> (i * EYE_SCORE_BITS)) & EYE_SCORE_MASK
            for i in range(EYE_SCORES_PER_WORD)]


def decode_eye_status(raw: int) -> dict:
    return {
        "raw":                raw,
        "state":              raw & 0x7,
        "last_swept_lane_id": (raw >> 4) & 0x7,
        "capture_valid":      (raw >> 7) & 0x1,
        "cal_state_mirror":   (raw >> 8) & 0xF,
        "sweep_phase":        (raw >> 12) & 0xF,
        "dwell_remaining_ms": (raw >> 16) & 0xFFFF,
    }


def _drain_lane_buffer(io: RemoteIO) -> list:
    """Drain a single lane's score buffer (128 scores) via EYE_BURST_DATA.

    Writes EYE_SCORE_IDX with the auto-increment bit set (so each read
    advances by EYE_SCORES_PER_WORD), then performs EYE_BURST_READS
    sequential reads. Trims the over-reads back to EYE_POINTS_PER_LANE.
    """
    io.write(EYE_SCORE_IDX, (1 << 16))  # idx=0, auto-increment-on-read
    scores = []
    for _ in range(EYE_BURST_READS):
        scores.extend(decode_burst_word(io.read(EYE_BURST_DATA)))
    return scores[:EYE_POINTS_PER_LANE]


def _poll_status_until_done(io: RemoteIO, timeout_s: float,
                            sleep_fn=time.sleep,
                            poll_interval_s: float = 0.005):
    """Block until SWI_EYE_STATUS state reaches DONE (or TIMED_OUT).

    Returns the final decoded status dict. Raises TimeoutError after
    `timeout_s` of wall-clock elapsed."""
    t0 = time.monotonic()
    while True:
        st = decode_eye_status(io.read(SWI_EYE_STATUS))
        if st["state"] in (EYE_STATE_DONE, EYE_STATE_TIMED_OUT):
            return st
        if time.monotonic() - t0 > timeout_s:
            raise TimeoutError(
                f"SWI_EYE_STATUS did not reach DONE within {timeout_s:.1f}s "
                f"(last state={st['state']}, raw=0x{st['raw']:08x})")
        sleep_fn(poll_interval_s)


def sweep_deep_per_lane(io: RemoteIO, dwell_us: int = DEFAULT_DWELL_US,
                        lanes=range(8), mode: str = 'single',
                        sleep_fn=time.sleep):
    """Drive the v2 Region 10 deep-mode eye capture, yielding one event
    per completed lane.

    Yields dicts of shape::

        {"lane": int, "scores": [128 ints], "status": <decode_eye_status>}

    `mode='single'` programs SWI_EYE_LANE_SEL per lane and issues ENTER
    each time (proposal §11(a) flow). `mode='auto_increment'` sets
    AUTO_INCREMENT_LANE on the first ENTER and lets the calibrator
    advance LANE_SEL itself — host issues one ENTER and waits for 8
    DONE pulses, draining after each.

    `dwell_us` is the per-sweep dwell. Timeout is 2× dwell, with a 1 s
    floor for very short test dwells.
    """
    lane_list = list(lanes)
    if not lane_list:
        return
    if mode not in ('single', 'auto_increment'):
        raise ValueError(f"unknown mode {mode!r}")

    timeout_s = max(1.0, 2.0 * dwell_us / 1_000_000.0)

    if mode == 'auto_increment':
        io.write(SWI_EYE_LANE_SEL, lane_list[0])
        io.write(SWI_EYE_DWELL_US, dwell_us)
        io.write(SWI_EYE_CTRL,
                 EYE_CTRL_ENTER | EYE_CTRL_MODE_SINGLE
                 | EYE_CTRL_FORCE_FULL_SWEEP | EYE_CTRL_AUTO_INCREMENT)
        for lane in lane_list:
            status = _poll_status_until_done(io, timeout_s, sleep_fn)
            scores = _drain_lane_buffer(io)
            yield {"lane": lane, "scores": scores, "status": status}
        return

    for lane in lane_list:
        io.write(SWI_EYE_LANE_SEL, lane)
        io.write(SWI_EYE_DWELL_US, dwell_us)
        io.write(SWI_EYE_CTRL,
                 EYE_CTRL_ENTER | EYE_CTRL_MODE_SINGLE
                 | EYE_CTRL_FORCE_FULL_SWEEP)
        status = _poll_status_until_done(io, timeout_s, sleep_fn)
        scores = _drain_lane_buffer(io)
        yield {"lane": lane, "scores": scores, "status": status}


def collect_deep(io: RemoteIO, **kw) -> dict:
    """Materialise sweep_deep_per_lane() into a {lane: [128 scores]} dict."""
    return {ev["lane"]: ev["scores"] for ev in sweep_deep_per_lane(io, **kw)}


def render_deep_png(per_board: dict, path: str,
                    title: str = "TideLink deep-mode eye") -> None:
    """Render a per-board 8-lane 2D heatmap.

    `per_board` shape: ``{board_label: {lane: [128 scores]}}``. Each
    lane's 128 scores are reshaped to 8 × 16 (slip × phase) and drawn
    as a heatmap; lanes are tiled 4×2 per board, boards stacked
    vertically (so a paired capture is a 4-wide, 4-tall figure).
    """
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("[eye_sweep] matplotlib not available — skipping deep PNG",
              file=sys.stderr)
        return

    boards = list(per_board.keys())
    nb = len(boards)
    fig, axs = plt.subplots(2 * nb, 4, figsize=(16, 5 * nb), squeeze=False)
    for bi, b in enumerate(boards):
        lanes = per_board[b]
        for lane in range(8):
            scores = lanes.get(lane, [0] * EYE_POINTS_PER_LANE)
            arr = np.array(scores[:EYE_POINTS_PER_LANE], dtype=int)
            if arr.size < EYE_POINTS_PER_LANE:
                arr = np.pad(arr, (0, EYE_POINTS_PER_LANE - arr.size))
            mat = arr.reshape(8, 16)  # slip rows × phase cols
            r, c = divmod(lane, 4)
            ax = axs[2 * bi + r][c]
            im = ax.imshow(mat, aspect="auto", origin="lower",
                           cmap="RdYlGn", vmin=0,
                           vmax=EYE_SCORE_MASK,
                           interpolation="nearest")
            ax.set_xlabel("phase")
            ax.set_ylabel("slip")
            ax.set_title(f"{b} L{lane}")
        fig.colorbar(im, ax=axs[2 * bi:2 * bi + 2, :].ravel().tolist(),
                     shrink=0.6, label="score")

    fig.suptitle(title, fontsize=12)
    plt.savefig(path, dpi=120, bbox_inches="tight")
    plt.close(fig)


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
    # --- ZynqMP (KR260) SAFETY GUARD -----------------------------------------
    # Every remote accessor below sshes to the board and mmaps RAW Pynq-Z2
    # control literals (0x4403_xxxx / 0x4404_xxxx / 0x4405_xxxx) over /dev/mem.
    # On a ZynqMP (KR260) those addresses are UNDECODED with NO bus timeout =>
    # a hard PS hang. Pynq-Z2 ONLY. Refuse before any board access (this also
    # blocks the offline --diff path — harmless). On a KR260 use tl_poke.py
    # (0x8403_xxxx) or tl39.py.
    _tl_guard_soc = (os.environ.get("TIDELINK_SOC") or "").strip().lower()
    if _tl_guard_soc not in ("", "z2", "pynq-z2", "pynq_z2", "zynq7", "zynq"):
        sys.stderr.write(
            "\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — sshes to a board and "
            "mmaps RAW Z2 literals (0x4403_xxxx)\n  UNDECODED on a ZynqMP "
            "(KR260) => hard PS hang. Pynq-Z2 ONLY.\n  On a KR260 use "
            "tl_poke.py (0x8403_xxxx) or tl39.py.\n"
            % (os.path.basename(__file__), os.environ.get("TIDELINK_SOC")))
        raise SystemExit(3)
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
    ap.add_argument("--mode", choices=("global", "deep"), default="global",
                    help="Sweep mode: 'global' (v1, 16-tap clock-data "
                         "phase) or 'deep' (v2, per-lane 128-point eye "
                         "via Region 10). Default: global.")
    ap.add_argument("--lane", type=int, default=None,
                    help="Deep mode only: restrict capture to a single "
                         "lane (0..7). Default: iterate all 8 lanes.")
    ap.add_argument("--dwell-us", type=int, default=DEFAULT_DWELL_US,
                    help=f"Deep mode only: per-sweep dwell timer in µs "
                         f"(default {DEFAULT_DWELL_US} = 100 ms).")
    ap.add_argument("--peer-aperture", action="store_true",
                    help="Deep mode only: drain the slave eye through "
                         "die_a's peer aperture at 0x40032140 instead "
                         "of a second SSH connection. Requires --master.")
    ap.add_argument("--auto-increment", action="store_true",
                    help="Deep mode only: set SWI_EYE_CTRL.AUTO_INCREMENT_"
                         "LANE so one ENTER triggers all 8 lane sweeps.")

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

    print(f"[eye_sweep] label={args.label} mode={args.mode}")

    if args.mode == "deep":
        return _run_deep_mode(args)

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


def _run_deep_mode(args) -> int:
    """Drive deep-mode capture against one or two boards.

    With `--peer-aperture`, a single SSH connection to die_a drains both
    dies (die_b via the peer aperture at 0x40032140). Otherwise each
    board gets its own SSH connection.
    """
    if not args.master:
        print("[eye_sweep] deep mode requires --master", file=sys.stderr)
        return 2
    if args.peer_aperture and args.slave:
        print("[eye_sweep] --peer-aperture is incompatible with --slave "
              "(peer aperture replaces the second SSH)", file=sys.stderr)
        return 2

    lanes = (args.lane,) if args.lane is not None else range(8)
    mode = "auto_increment" if args.auto_increment else "single"

    per_board = {}
    metadata = {
        "label": args.label, "mode": "deep", "dwell_us": args.dwell_us,
        "timestamp": datetime.now().isoformat(),
        "boards": {}, "peer_aperture": bool(args.peer_aperture),
        "auto_increment": bool(args.auto_increment),
        "lanes": list(lanes),
    }

    print(f"[eye_sweep] deep mode @ {args.master} (dwell={args.dwell_us} µs, "
          f"mode={mode}, peer_aperture={args.peer_aperture})")
    master_io = SSHRemoteIO(args.master, args.password)
    per_board["master"] = {}
    for ev in sweep_deep_per_lane(master_io, dwell_us=args.dwell_us,
                                  lanes=lanes, mode=mode):
        per_board["master"][ev["lane"]] = ev["scores"]
        print(f"  master L{ev['lane']}: state={ev['status']['state']} "
              f"({len(ev['scores'])} scores)")
    metadata["boards"]["master"] = args.master

    if args.peer_aperture:
        peer_io = _PeerApertureIO(args.master, args.password)
        print(f"[eye_sweep] deep mode @ peer aperture (0x{PEER_EYE_REGION10:08x})")
        per_board["slave"] = {}
        for ev in sweep_deep_per_lane(peer_io, dwell_us=args.dwell_us,
                                      lanes=lanes, mode=mode):
            per_board["slave"][ev["lane"]] = ev["scores"]
            print(f"  slave  L{ev['lane']}: state={ev['status']['state']} "
                  f"({len(ev['scores'])} scores)")
        metadata["boards"]["slave"] = f"peer:{args.master}"
    elif args.slave:
        slave_io = SSHRemoteIO(args.slave, args.password)
        print(f"[eye_sweep] deep mode @ {args.slave}")
        per_board["slave"] = {}
        for ev in sweep_deep_per_lane(slave_io, dwell_us=args.dwell_us,
                                      lanes=lanes, mode=mode):
            per_board["slave"][ev["lane"]] = ev["scores"]
            print(f"  slave  L{ev['lane']}: state={ev['status']['state']} "
                  f"({len(ev['scores'])} scores)")
        metadata["boards"]["slave"] = args.slave

    json_path = os.path.join(args.outdir, f"{args.label}.json")
    scores_path = os.path.join(args.outdir, f"{args.label}_deep.json")
    png_path = os.path.join(args.outdir, f"{args.label}_deep.png")

    with open(json_path, "w") as f:
        json.dump(metadata, f, indent=2)
    with open(scores_path, "w") as f:
        # JSON keys must be strings — convert lane indices.
        json.dump({b: {str(k): v for k, v in lanes_d.items()}
                   for b, lanes_d in per_board.items()}, f, indent=2)
    print(f"[eye_sweep] saved metadata: {json_path}")
    print(f"[eye_sweep] saved scores  : {scores_path}")

    if not args.ascii_only:
        render_deep_png(per_board, png_path,
                        title=f"TideLink deep eye — {args.label}")
        print(f"[eye_sweep] saved PNG: {png_path}")

    return 0


class _PeerApertureIO(RemoteIO):
    """RemoteIO variant that rebases Region 10 accesses to the peer
    aperture at 0x40032140. All other addresses pass through unchanged.

    Used when one SSH connection on die_a drains die_b's eye via the
    TideLink peer pipe.
    """
    def __init__(self, ip: str, password: str = DEFAULT_PASS):
        self.ip = ip
        self.password = password

    @staticmethod
    def _rebase(addr: int) -> int:
        # Region 10 occupies 0x44032140..0x4403217F (64 bytes).
        if SWI_EYE_CTRL <= addr <= (SWI_EYE_CTRL + 0x3F):
            return PEER_APERTURE_BASE + (addr & 0xFFFFF)
        return addr

    def read(self, addr: int) -> int:
        return remote_read(self.ip, self._rebase(addr), self.password)

    def write(self, addr: int, value: int) -> None:
        remote_write(self.ip, self._rebase(addr), value, self.password)


if __name__ == "__main__":
    sys.exit(main())
