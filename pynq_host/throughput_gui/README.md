# TideLink throughput GUI (port 8090)

Third member of the web-toolkit family (`eye_toolkit/web` :8088,
`stress_toolkit/web` :8089). FastAPI + SSE + vanilla JS + Plotly
(vendored), per the plan in `docs/THROUGHPUT_GUI_PLAN_2026_06_12.md [removed 2026-07; in git history]`.

**P0 walking skeleton** — one canned `throughput_m2s` run end-to-end:

* **On-board measurement agent** (`agent/tl_perf_agent.py`) — stdlib-only,
  pushed afresh per run over SSH, mmaps `/dev/mem` ONCE and runs the timed
  loops locally (an SSH-per-register "throughput test" measures sshpass,
  not TideLink). Modeled on `pynq_host/scripts/tlchar.py`, including the
  `TIDELINK_TX_BASE` / `TIDELINK_RXFIFO_BASE` env overrides for GP1-split
  images and the authoritative SWI_LANE_STATUS `0x108` decode.
* **Run store** — SQLite index + flat NDJSON/CSV per run under
  `~/tidelink_throughput_runs/` (survives board power-cycles).
* **Fail-closed provenance** — every run records the staged bitstream
  manifests (`make_bitstream_manifest.sh` schema) + `verify_deployed.sh`
  result + PHYID; no valid manifest sha256 ⇒ HTTP 412, no run record.
* **Safety interlocks** (server-enforced):
  1. cross-toolkit single-experiment `flock` (`~/.tidelink-hw.lock`) — 409
  2. fpgahub lease must be **GRANTED, not queued** — 412
  3. criterion-A/B link gate (port of `tt_verify_link_up`) — 412
  4. **delivery proof** — one verified 4-word M→S packet before any
     sustained AHB_TX traffic (port of `link_delivery_proof.sh`)
  5. jam-signature sentinel on every sample (CLASSIC / HELD-REPLAY matrix
     per `unjam_fc_node.sh` + FCSM∉{4,5} excursions) → auto-abort, FAILED
  6. hard wall-clock watchdog

## Dev mode (no boards, no network)

```bash
python3 -m pynq_host.throughput_gui.app --fake --port 8090 \
    --store-dir /tmp/tlruns
# then browse http://localhost:8090/  — click "Start run"
```

`--fake` runs the agents as local subprocesses against an in-process die
model with a shared spool-file "wire", so M→S words genuinely traverse
process boundaries: the delivery proof only passes if the master really
sent, the live chart shows credit-gated throughput (~4 Mbit/s with the
default modeled capacity), and the whole gate/FSM/store/SSE stack is the
production code. A synthetic `v0-fake` artefact version with honest
sha256 manifests is staged automatically (never into the real
`~/tidelink_artefacts`).

Fault-injection knobs (env on the agent, used by the tests):
`TIDELINK_FAKE_JAM_AT_S` (CLASSIC jam after N s),
`TIDELINK_FAKE_LINK_DOWN=1`, `TIDELINK_FAKE_CAP_WPS` (link capacity).

## Deploy on mapstone-dev

```bash
# 1. venv (same pattern as ~/.venvs/tideeye, ~/.venvs/tidestress)
python3 -m venv ~/.venvs/tidethroughput
~/.venvs/tidethroughput/bin/pip install -r \
    ~/SoCLabs/tidelink/pynq_host/throughput_gui/requirements.txt

# 2a. ad-hoc
cd ~/SoCLabs/tidelink
~/.venvs/tidethroughput/bin/uvicorn pynq_host.throughput_gui.app:app \
    --host 127.0.0.1 --port 8090

# 2b. or systemd (user unit)
mkdir -p ~/.config/systemd/user
cp pynq_host/throughput_gui/systemd/tidelink-throughput-web.service \
    ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now tidelink-throughput-web
journalctl --user -u tidelink-throughput-web -f

# 3. from your laptop
ssh -L 8090:localhost:8090 david@mapstone-dev
# browse http://localhost:8090/
```

Configuration (environment, see the unit file):

| Variable | Default | Meaning |
|---|---|---|
| `TIDELINK_THROUGHPUT_STORE` | `~/tidelink_throughput_runs` | run store root |
| `TIDELINK_THROUGHPUT_ARTEFACTS` | `~/tidelink_artefacts` | staged manifests root |
| `TIDELINK_THROUGHPUT_VERSION` | (none) | default `vNN` artefact version |
| `TIDELINK_HW_LOCK` | `~/.tidelink-hw.lock` | cross-toolkit mutex path |
| `TIDELINK_TX_BASE` / `TIDELINK_RXFIFO_BASE` | `0x44000000` / `0x44010000` | GP1-split overrides, forwarded to the board agent |
| `TIDELINK_BOARD_PASS` | `xilinx` | board password |
| `TIDELINK_THROUGHPUT_FAKE` | unset | `1` ⇒ fake backend for the module-level app |

**DO NOT expose publicly.** No auth on the HTTP surface; the loopback
bind + `ssh -L` tunnel IS the authentication (same as the siblings —
the CLI hard-refuses `--host 0.0.0.0`).

## Running a real M→S throughput test

1. Stage + deploy a manifested bitstream pair as usual
   (`deploy_pair.sh`, manifests in `~/tidelink_artefacts/<vNN>/`),
   converge with `bringup_pair_converge.sh`.
2. Set `TIDELINK_THROUGHPUT_VERSION=<vNN>` (or type the version in the
   form), hold the `bridge1` lease (the server acquires one and refuses
   QUEUED), click *Start run*.
3. The server probes both dies (criterion-B), runs the delivery proof,
   then streams windowed samples to the chart over SSE. CSV/NDJSON
   download links appear when the run lands in the store.

If a run FAILS with a jam-signature reason, recover with
`pynq_host/scripts/unjam_fc_node.sh <ip>` on both boards (and/or
`bringup_pair_converge.sh`) — the GUI recovery button is a P1 item.

## Tests

```bash
cd ~/SoCLabs/tidelink
~/.venvs/tidethroughput/bin/python -m pytest \
    -c pynq_host/throughput_gui/tests/pytest.ini \
    pynq_host/throughput_gui/tests -v
```

All tests run offline against the fake backend, including an E2E smoke
that boots the real server subprocess in `--fake` mode and completes a
canned run over HTTP.

## P0 → P1 deferrals

Per the plan §7: sweep axes + between-point gate re-checks; the other
registry tests (`throughput_s2m`, `throughput_bidir`, `doorbell_rtt`,
`credit_recovery`, `soak`); run-list/comparison UI + `/api/compare`;
`POST /api/recover/unjam` wedge-recovery button; perf-counter R5/R6/R7
capture in the observer; deploy-before-run via the shared `deploy.py`;
SSE replay for finished runs (P0 streams live runs only — use
`/api/runs/{id}` + samples downloads afterwards).
