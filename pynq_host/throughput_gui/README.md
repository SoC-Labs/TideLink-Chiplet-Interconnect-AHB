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

## Running against the real Z2 pair

The pair is **z2_02 (die_a, `192.168.4.101`) ↔ z2_01 (die_b,
`192.168.2.101`)**. z2_03 (`.6.101`) is a spare and is NOT on the ribbon,
despite older defaults and docs pointing at it.

### Launch

```bash
TIDELINK_FPGAHUB_HOST=<lab-host> \
TIDELINK_BOARD_SSH_JUMP=<lab-host> \
TIDELINK_TX_BASE=0x84000000 TIDELINK_RXFIFO_BASE=0x84010000 \
  python3 -m pynq_host.throughput_gui.app --port 8090 \
    --artefact-dir ~/tidelink_artefacts --artefact-version <vNN>
```

* `TIDELINK_FPGAHUB_HOST` drives fpgahub leases over ssh, so no Bearer
  token is stored on disk. Omit it to use the local REST client.
* `TIDELINK_BOARD_SSH_JUMP` reaches boards through the lab host. The
  shell tooling (`verify_deployed.sh`, `deploy_pair.sh`, …) doesn't read
  it, so from a dev box also add a `ProxyCommand` stanza for the board
  IPs to `~/.ssh/config` — with `ControlMaster=no` on the hop, because
  multiplexing many board sessions over one connection exhausts sshd's
  `MaxSessions` and fails as `Session open refused by peer`.
* **The apertures are mandatory.** Both the golden and v0 Z2 images are
  GP1-split (`ahb_tx 0x8400_0000`, `rx-fifo 0x8401_0000`, confirmed from
  each image's `.hwh`). The `0x4400_0000` defaults are unmapped in these
  images and a write there **SIGBUSes the agent**.
* Leases are **board-group** scoped (`pynq_z2_02` = `_ps` + `_pl`); the
  historical single `bridge1` scope no longer exists on the daemon. A
  pair is two independent leases, acquired all-or-nothing.

### What works today

*Link Monitor* runs against the golden pair as-is: both dies stream
decoded state, criterion-B, credit gauges, sticky faults, CRC.

*Runs* are admitted only behind provenance → `verify_deployed.sh` →
criterion-A/B link gate → delivery proof. Everything up to the proof
passes on the golden pair; **the proof itself currently fails** —
the packet reaches the Wlink FE but never commits to the peer RX FIFO.
That is a bring-up gap, not a GUI or image regression: `deploy_pair.sh`'s
whole post-load write-set is the strap GPIO, while the flows that did
deliver additionally applied a deskew-anchor recipe, the SYNC beacon, the
pair-credit seed (now `tl_perf_agent.py --cmd seed`) and the
`to_data_mode` LL-swreset triplet. `pynq_host/scripts/tl_z2_data_bringup_repro.sh`
bisects those stages; whichever one first makes the proof pass is the
step to encode into the orchestrator's bring-up.

> ⚠ Use the **corrected** swreset triplet `0x27f09 → 0x27f01 → 0x27f07`
> (bit0 `swi_enable` held HIGH). The `…08/…00/…07` form still used by
> several older scripts holds the FCSM in state 0 and clears
> `fe_rx_ptr`/`fe_tx_credit_max`, desyncing the credit ring.

### Golden-image provenance

The recovered golden bitstreams have no recorded source commit. Their
manifests say `"source_commit": "unknown"` on purpose — a fabricated
commit would silently corrupt any comparison keyed on it, so golden runs
must not be used as version-comparison datapoints. Use a manifested build
(e.g. `tl-tp-v0-baseline`) for those.

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
