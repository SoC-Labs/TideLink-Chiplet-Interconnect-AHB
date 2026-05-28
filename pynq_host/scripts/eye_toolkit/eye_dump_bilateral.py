#!/usr/bin/env python3
"""eye_dump_bilateral.py — capture+drain BOTH dies' eyes from one PYNQ.

Implements the §7 worked example of docs/EYE_VISIBILITY_RTL_PROPOSAL.md.
A single SSH connection to die_a writes Region 10 locally
(0x44032140..) for die_a's own calibrator, and writes the same offsets
through the TideLink peer aperture (0x40032140..) to reach die_b's
Region 10 across the link.

Use this when:
  - The chiplet pair is up enough that the peer aperture is reachable
    from die_a (Regions 0..9 already work; Region 10 ACL extension is
    documented in proposal §7).
  - You only have host access to die_a (e.g. die_b's PS has no IP).

If the link is DOWN, use eye_sweep.py --mode deep separately on each
PYNQ instead — Mechanism α tolerates link-down because each calibrator
runs locally.
"""

import argparse
import json
import os
import sys
from datetime import datetime

from eye_sweep import (
    DEFAULT_DWELL_US,
    DEFAULT_PASS,
    PEER_EYE_REGION10,
    SSHRemoteIO,
    _PeerApertureIO,
    render_deep_png,
    sweep_deep_per_lane,
)


def capture_bilateral(ip: str, password: str = DEFAULT_PASS,
                      dwell_us: int = DEFAULT_DWELL_US,
                      lanes=range(8), mode: str = 'single') -> dict:
    """Drive a paired-die deep capture from one PYNQ.

    Returns ``{"master": {lane: [128 scores]}, "slave": {...}}``. The
    "slave" half is drained through die_a's peer aperture — no second
    SSH connection is opened.
    """
    local_io = SSHRemoteIO(ip, password)
    peer_io = _PeerApertureIO(ip, password)
    out = {"master": {}, "slave": {}}
    for ev in sweep_deep_per_lane(local_io, dwell_us=dwell_us,
                                  lanes=lanes, mode=mode):
        out["master"][ev["lane"]] = ev["scores"]
    for ev in sweep_deep_per_lane(peer_io, dwell_us=dwell_us,
                                  lanes=lanes, mode=mode):
        out["slave"][ev["lane"]] = ev["scores"]
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Bilateral deep-eye capture from one PYNQ host "
                    "via the TideLink peer aperture.")
    ap.add_argument("--master", required=True,
                    help="die_a PYNQ IP (peer aperture target = die_b).")
    ap.add_argument("--password", default=DEFAULT_PASS)
    ap.add_argument("--dwell-us", type=int, default=DEFAULT_DWELL_US)
    ap.add_argument("--lane", type=int, default=None,
                    help="Restrict to one lane (0..7). Default: all 8.")
    ap.add_argument("--auto-increment", action="store_true")
    ap.add_argument("--outdir", default="/tmp/eye_runs")
    ap.add_argument("--label", default=None)
    ap.add_argument("--ascii-only", action="store_true")
    args = ap.parse_args()

    lanes = (args.lane,) if args.lane is not None else range(8)
    mode = "auto_increment" if args.auto_increment else "single"

    if args.label is None:
        args.label = f"bilateral_{datetime.now():%Y%m%d_%H%M%S}"
    os.makedirs(args.outdir, exist_ok=True)

    print(f"[eye_dump_bilateral] {args.master} -> local + peer "
          f"(0x{PEER_EYE_REGION10:08x}); dwell={args.dwell_us}µs mode={mode}")

    per_board = capture_bilateral(args.master, args.password,
                                  args.dwell_us, lanes, mode)

    scores_path = os.path.join(args.outdir, f"{args.label}_deep.json")
    png_path = os.path.join(args.outdir, f"{args.label}_deep.png")
    with open(scores_path, "w") as f:
        json.dump({b: {str(k): v for k, v in d.items()}
                   for b, d in per_board.items()}, f, indent=2)
    print(f"[eye_dump_bilateral] saved scores: {scores_path}")

    if not args.ascii_only:
        render_deep_png(per_board, png_path,
                        title=f"TideLink bilateral deep eye — {args.label}")
        print(f"[eye_dump_bilateral] saved PNG: {png_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
