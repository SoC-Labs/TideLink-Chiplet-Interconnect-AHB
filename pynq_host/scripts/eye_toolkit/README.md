# TideLink PHY live-lane-phase Toolkit

A reusable Python toolkit for visualising the per-phase lane lock
behaviour of the TideLink Wlink PHY on real hardware. Designed to be
invoked against successive RTL builds (especially calibrator-related
changes) to objectively measure whether per-lane phase margin has
improved.

> **Naming note.** The directory and Python module names
> (`eye_toolkit/`, `eye_sweep.py`) are retained for historical
> reasons and to avoid breaking import paths / systemd units.
> User-visible labels have been updated to **live-lane-phase**,
> which more accurately describes what is rendered: a per-lane
> `swi_phase_offset` 0..15 vs lane-locked heatmap, not a
> conventional time-domain eye diagram.

## What it measures (v1)

`swi_phase_offset[3:0]` (a single 4-bit knob in `PHY_CTRL` register at
`0x4403_0000`, bits[20:17]) is the global clock-data sampling-phase
override applied to all lanes uniformly. The toolkit sweeps it 0..15,
reads back `SWI_LANE_STATUS[7:0]` (per-lane lock bitmap) at each step,
and renders the result as ASCII + CSV + PNG.

This v1 sweep is **GLOBAL** — it answers "for what range of clock-
phase offsets do all 8 lanes lock?". A wider passing range = wider
margin. A narrow or 1-point passing range = eye-edge symptom.

It does NOT yet measure the **per-lane IDELAYE2 tap sweep** that the
calibrator does internally. When the `lane_score` APB-expose RTL change
lands (see `docs/OPTION_C_LANE_SCORE_APB_EXPOSE.md`), this toolkit will
be extended with a `--mode deep` flag that pulls the full per-lane
128-point (slip × phase) score grid.

## When to use

- After any RTL change to `tidelink_phy_align_calibrator.sv` — to
  measure margin improvement / regression.
- Before/after deploying a candidate calibrator-bugfix bitstream — to
  prove the change works on silicon, not just in sim.
- As a regression gate in CI when the calibrator agent lands a fix.

## Prerequisites

- Run from a host with `ssh` to the PYNQ board(s) — typically
  `mapstone-dev` (which has direct routes to the per-board /24
  networks). Running from your laptop usually does NOT work because
  PYNQ /24 networks are not routable from the wider lab network.
- `sshpass` installed (used by the existing pynq_host scripts).
- `python3` on the PYNQ board (Xilinx Linux ships with it).
- `python3-matplotlib` on the host running the toolkit (for PNG
  rendering). If not present, `--ascii-only` falls back to terminal
  output without complaint.
- TideLink bitstream already deployed and `bringup_pair_converge.sh`
  succeeded (link in LINK_IDLE with 16/16 lanes locked at the
  calibrator's chosen phase). The toolkit perturbs `swi_phase_offset`
  only — it does NOT re-bring-up the link.
- A `bridge1` pair lease should already be held by the user invoking
  this; the toolkit does NOT manage leases.

## Common invocations

```bash
# Single-board sweep (master only)
ssh mapstone-dev "python3 /home/david/SoCLabs/tidelink/pynq_host/scripts/eye_toolkit/eye_sweep.py \\
    --master 192.168.4.101 \\
    --outdir /tmp/eye_runs/ \\
    --label tdif-24-baseline"

# Paired sweep — both dies side-by-side
ssh mapstone-dev "python3 /home/david/SoCLabs/tidelink/pynq_host/scripts/eye_toolkit/eye_sweep.py \\
    --master 192.168.4.101 --slave 192.168.6.101 \\
    --outdir /tmp/eye_runs/ \\
    --label tdif-24-baseline"

# Compare two prior captures (regression mode, no HW needed)
python3 eye_sweep.py --diff /tmp/eye_runs/tdif-24-baseline_master.csv \\
                            /tmp/eye_runs/tdif-25-postfix_master.csv

# Faster sweep without matplotlib (CI-friendly)
python3 eye_sweep.py --master 192.168.4.101 --ascii-only \\
    --settle 0.1 --label ci-quick-check
```

## Outputs

For label `<L>` and boards `master`+`slave`:

```
<outdir>/<L>_master.csv     — raw sweep data (board, phase, lock_mask, etc.)
<outdir>/<L>_slave.csv      — same for slave (if --slave given)
<outdir>/<L>.json           — run metadata (timestamp, board IPs, git rev)
<outdir>/<L>.png            — matplotlib heatmap (16 phase × 8 lanes × N boards)
```

Plus ASCII summary printed to stdout, e.g.:

```
phase  master      slave
-----------------------------------
    0  ████████ 8  ████████ 8
    1  ········ 0  ········ 0
    2  ········ 0  ········ 0
    ...
    8  ████████ 8  ████████ 8
    ...

  master: full-lock runs: [0..0] (w=1), [8..8] (w=1)
  slave:  full-lock runs: [0..0] (w=1), [8..8] (w=1)
```

Eye-width is the `(w=N)` value — wider is better. With Agent O's
proposed MIN_LOCK_DWELLS=4 fix, we expect ≥ 4-wide contiguous runs
post-fix.

## Interpreting results

- **Full-lock runs of width ≥ 4 contiguous phases**: link has eye
  margin, calibrator can centre. Expected post-fix.
- **1-2-wide passing runs**: eye-edge regime (current pre-fix state).
  Real-data ISI will likely fail CRC even though training pattern
  locks.
- **No passing runs at all** (`lock=0` for all 16 phases): link is
  dead. Verify deploy_pair.sh and converge succeeded first.
- **Master and slave have very different patterns**: the asymmetry the
  calibrator agent is investigating. Expected to remain visible in
  v1 1D sweep only if calibrator-internal per-lane behaviour leaks
  through the global phase knob.

## Regression workflow

```bash
# 1. Deploy candidate bitstream + converge
ssh mapstone-dev "bash /home/david/SoCLabs/tidelink/pynq_host/scripts/bringup_pair_converge.sh \\
    192.168.4.101 192.168.6.101"

# 2. Capture baseline (pre-fix bitstream already on hand)
ssh mapstone-dev "python3 .../eye_toolkit/eye_sweep.py \\
    --master 192.168.4.101 --slave 192.168.6.101 \\
    --label pre-fix-2026-05-27"

# 3. Deploy fix bitstream + converge again
...

# 4. Capture post-fix
ssh mapstone-dev "python3 .../eye_toolkit/eye_sweep.py \\
    --master 192.168.4.101 --slave 192.168.6.101 \\
    --label post-fix-2026-05-27"

# 5. Diff
python3 eye_sweep.py --diff /tmp/eye_runs/pre-fix-2026-05-27_master.csv \\
                            /tmp/eye_runs/post-fix-2026-05-27_master.csv
```

## Deep mode (v2)

Deep mode captures the full per-lane 2D eye exposed by the v2 Region
10 RTL (`docs/EYE_VISIBILITY_RTL_PROPOSAL.md`). Each lane is swept
across all 128 `(slip × phase)` points and the 6-bit lane-score grid
is read back via APB — giving an actual 2D heatmap per lane, vs the
v1 global 16-point clock-data phase sweep.

```bash
# Bilateral capture from a single PYNQ host using the peer aperture
ssh mapstone-dev "python3 .../eye_toolkit/eye_sweep.py \
    --mode deep \
    --master 192.168.4.101 \
    --peer-aperture \
    --label tdif-26-deep-eye"

# Single-die deep eye on one PYNQ (use 100 ms dwell)
ssh mapstone-dev "python3 .../eye_toolkit/eye_sweep.py \
    --mode deep --master 192.168.4.101 \
    --dwell-us 100000 --label deep-master-only"

# One-shot bilateral via the worked-example script
ssh mapstone-dev "python3 .../eye_toolkit/eye_dump_bilateral.py \
    --master 192.168.4.101 --label bilateral-deep"

# Single lane (faster, useful for debugging one bad lane)
... eye_sweep.py --mode deep --master 192.168.4.101 --lane 3 ...

# AUTO_INCREMENT_LANE — one ENTER, 8 lane sweeps back-to-back
... eye_sweep.py --mode deep --master 192.168.4.101 --auto-increment ...
```

Deep mode requires the **Region 10 eye-visibility RTL** to be present
on the bitstream (see `docs/EYE_VISIBILITY_RTL_PROPOSAL.md`). On a
bitstream without Region 10, `SWI_EYE_STATUS` will read back as `0x0`
and the polling loop will time out after `2 × dwell_us`.

The `--peer-aperture` flag re-bases Region 10 accesses from the local
`0x44032140` to the peer aperture at `0x40032140` — die_a's host
drains die_b's eye over the existing TideLink peer pipe. WARNING: do
not confuse `0x40000000` (peer aperture) with `0x44010000` (local RX
FIFO) — they are different fabrics; the test
`test_peer_aperture_uses_0x40032140` exists to guard this.

Outputs for deep mode:

```
<outdir>/<L>.json           — run metadata (label, dwell, lanes, peer flag)
<outdir>/<L>_deep.json      — {board: {lane: [128 scores]}} as JSON
<outdir>/<L>_deep.png       — 4×2 lane heatmap per board (matplotlib)
```

## Future extensions

- **`--soak-bits N`** — after each phase write, ring the doorbell N
  times and count `DOORBELL_RESP_ACC` increments, giving "real-data"
  bit-equivalent passing rate per phase (not just training-pattern
  lock).
- **`--idelay-sweep`** — sweep per-lane IDELAYE2 tap directly via the
  calibrator's debug override (if RTL exposes it).
- **`--compare-rtls dir`** — multi-run diff: scan all CSVs in a dir,
  produce a regression grid showing eye-width-per-build over time.

## Live mode (browser UI — "live-lane-phase")

A FastAPI + Plotly toolkit that wraps the v1 sweep behind a single
page. Acquires `bridge1`, deploys, converges, sweeps both boards in
parallel, and streams per-phase rows to the browser via SSE.

See [`web/README.md`](web/README.md) for run instructions, API
surface, and the SSH-tunnel exposure model.

Quick start:

```bash
cd ~/SoCLabs/tidelink/pynq_host
make install-web && systemctl --user enable --now tideeye-web
ssh -L 8088:localhost:8088 mapstone-dev   # from your laptop
open http://localhost:8088/
```

## Files

- `eye_sweep.py` — the CLI toolkit + library (also drives `web/`).
- `eye_dump_bilateral.py` — worked example: capture both dies via the
  peer aperture from one PYNQ host.
- `tests/test_deep_mode.py` — mocked-IO unit tests for deep mode.
- `web/` — the FastAPI live-lane-phase browser front-end.
- `README.md` — this file.

## Related

- `docs/EYE_VISIBILITY_RTL_PROPOSAL.md` — **v2 design doc, source of
  truth for the Region 10 register map and the deep-mode protocol.**
- `docs/EYE_VISUALISATION_2026_05_27.md` — first eye captured this
  way + analysis.
- `docs/OPTION_C_LANE_SCORE_APB_EXPOSE.md` — earlier draft, subsumed
  by v2 above.
- `docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md` — bug context + sim
  evidence the toolkit complements with HW evidence.
