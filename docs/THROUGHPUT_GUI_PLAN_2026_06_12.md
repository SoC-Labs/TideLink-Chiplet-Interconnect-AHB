# TideLink Throughput-Test GUI — Design & Implementation Plan

**Date:** 2026-06-12
**Status:** PLAN ONLY — nothing implemented yet
**Companion doc:** the throughput/latency *test plan* (being written in parallel).
This document deliberately treats a test as an opaque contract —
`{name, params, target boards} → {status stream, CSV/JSON results}` — so the
two documents can land independently.

---

## 0. Executive summary

Build a third member of the existing web-toolkit family
(`eye_toolkit/web` :8088, `stress_toolkit/web` :8089) at
`pynq_host/throughput_gui/` (port **8090**), reusing the proven
FastAPI + SSE + vanilla-JS + Plotly stack and the existing `lease.py` /
`deploy.py` / link-gate machinery **verbatim**. The two genuinely new pieces
are:

1. **An on-board measurement agent** (`tl_perf_agent.py`) — a single-file
   Python script streamed to each PYNQ over SSH per-run, which mmaps
   `/dev/mem` once and runs the timed inner loops *locally* (the existing
   `mmio_remote.py` spawns one SSH process per register access — fine for
   control, useless for measuring throughput).
2. **A persistent run store with bitstream provenance** (SQLite index +
   flat NDJSON/CSV per run on mapstone-dev), so SRAM-sweep /
   FIFO-size-family graphs are comparable and trustworthy across builds.

---

## 1. Prior art in this ecosystem (reuse audit)

A read-only scan found substantial existing tooling. **Reuse beats
greenfield**, and most of the hard problems are already solved once:

| Existing asset | Path | Reuse verdict |
|---|---|---|
| `eye_toolkit/web` — FastAPI app, SSE run events, Plotly (CDN), systemd unit `tideeye-web.service`, :8088 | `pynq_host/scripts/eye_toolkit/web/` | **Pattern template.** This is the `eye-toolkit-web` lease referenced by `deps/tidelink-gpio-phy/docs/INTEGRATION_GUIDE.md §6.2` (HEAD `b9d1afc`). |
| `stress_toolkit/web` — sibling app, :8089, `RunState` FSM (LEASE_ACQUIRING → DEPLOYING → CONVERGING → RUNNING → DONE/ABORTED/FAILED), abort, PHY sentinel, FakeMmio pytest harness | `pynq_host/scripts/stress_toolkit/web/` | **Primary template.** Its `PacketStress` mode is already a crude throughput test; the new GUI supersedes it for perf work. |
| `lease.py` — fpgahub REST client (link-scope `bridge1` lease, unix-socket auth + Bearer fallback, GRANTED-vs-QUEUED distinction) | `eye_toolkit/web/lease.py` (re-exported by stress_toolkit) | **Import as-is** (same re-export trick stress_toolkit uses). |
| `deploy.py` — wraps `deploy_pair.sh` / converge | `eye_toolkit/web/deploy.py` | **Import as-is** for optional deploy-before-run. |
| `mmio_remote.py` — async SSH `/dev/mem` accessor (`read`/`write`/`read_many`) | `stress_toolkit/web/mmio_remote.py` | **Import for control-plane** pokes (gates, recovery, snapshots). NOT for timed loops. |
| Criterion-A/B link-up gate `tt_verify_link_up` / `tt_gate_ahb_tx` | `pynq_host/scripts/hwtest/lib/lib_hwtest.sh:157-196` | **Port to Python** (one function, ~30 lines) — this is the canonical safety gate. |
| Wedge recovery | `pynq_host/scripts/unjam_fc_node.sh`, `bringup_pair_converge.sh` | **Shell out from orchestrator**, surfaced as a GUI button. |
| Bitstream provenance manifests | `pynq_host/scripts/make_bitstream_manifest.sh`, staged as `~/tidelink_artefacts/vNN/*.manifest.json` on mapstone-dev (`docs/BOARD_DEPLOY_RUNBOOK.md §2-3`); `verify_deployed.sh` | **Read at run start**, embed in every run record. |
| Perf counters R5/R6/R7 (TX/RX/debug, 8×32-bit each @ `0x440320A0/C0/E0`) | `pynq_host/scripts/hwtest/11_perf_counters.sh`, `REG_INVENTORY.md` | **Data source** for credit/link-health time series. |
| `/dev/mem` mmap helper staged as a real file over SSH (quoting-robust pattern) | `unjam_fc_node.sh` (mktemp + heredoc + scp/stdin) | **Same staging pattern** for the board agent. |

What does **not** exist anywhere yet (the actual work):
on-board timed measurement loops; a run store (stress_toolkit keeps runs in
memory only — SSE or it never happened); provenance recorded per run;
run-list / comparison UI; sweep parameterization.

---

## 2. Where each piece runs

```
 dev box (browser ONLY)
   │  ssh -L 8090:localhost:8090 david@mapstone-dev      ← user's tunnel
   ▼
 mapstone-dev (10.22.27.178)          ── ORCHESTRATOR + WEB SERVER + RUN STORE
   │  • only host routed to both board /24s (dev box CANNOT reach boards;
   │    runbook §1) — anything that must talk to both boards lives here
   │  • already hosts the sibling GUIs (:8088/:8089) + systemd units,
   │    the artefact store ~/tidelink_artefacts/ (manifests = provenance),
   │    fpgahubd, and the repo checkout /home/david/SoCLabs/tidelink
   │  • run store on its disk → results survive board power-cycles
   │
   ├─ sshpass ssh xilinx@192.168.4.101 (z2_02 master)  ── BOARD AGENT
   └─ sshpass ssh xilinx@192.168.6.101 (z2_03 slave)   ── BOARD AGENT
        tl_perf_agent.py: mmap /dev/mem ONCE, timed loops with
        time.monotonic_ns(), NDJSON samples on stdout → SSH pipe
```

**Why measurement must be on-board:** one SSH-spawned register access costs
~100–300 ms (process spawn + auth + sudo) → ≤10 ops/s, i.e. an off-board
"throughput test" measures sshpass, not TideLink. A local mmap loop on the
Zynq PS does 10⁵–10⁶ accesses/s — 4–5 orders of magnitude of headroom over
the ~6.25–25 MHz link. Timestamps come from one board's own
`time.monotonic_ns()`, so rate math never crosses a clock boundary.

**Agent-per-run, not resident daemon.** The agent is pushed afresh for every
run (cat-over-ssh to `/tmp/tl_perf_agent.py`, then
`sudo python3 /tmp/tl_perf_agent.py --cfg-json '…'` on the same persistent
SSH channel; results stream back as NDJSON lines on stdout). Rationale:
boards are reflashed/rebooted constantly during bring-up — a resident daemon
adds version-skew, install state, and an extra listening port on the board
networks for zero benefit. The persistent-SSH-pipe pattern is already proven
by `unjam_fc_node.sh` and the converge tooling.

**Cross-board coordination** (bidirectional tests): orchestrator opens both
agent pipes, waits for each agent's `{"ev":"ready"}` line, then writes a
single `GO <epoch_deadline>` line to both stdins. Skew of a few ms is
irrelevant for sustained-throughput windows ≥1 s; per-direction rates are
still computed purely from local timestamps. One-way latency is explicitly
out of scope (would require PTP-disciplined clocks — note for the test-plan
doc); **doorbell round-trip latency is measured entirely on one board** and
needs no clock sync.

**User access:** `ssh -L 8090:localhost:8090 david@mapstone-dev`, then
browse `http://localhost:8090/`. Server binds `127.0.0.1` only → no firewall
work, same as the siblings.

---

## 3. Stack choice

| Layer | Choice | Justification |
|---|---|---|
| Web framework | **FastAPI + uvicorn + sse-starlette** | Already running on mapstone-dev for both sibling GUIs (`stress_toolkit/web/requirements.txt`; venv pattern `~/.venvs/tidestress` documented in its README). Zero new operational surface; SSE for live streaming is already wired and tested (`test_app_sse.py`). |
| Frontend | **Vanilla JS + Plotly (single `<script>` tag)** | Exactly what the siblings ship (`static/index.html` loads `plotly-2.35.0.min.js` from CDN). No node/npm/bundler anywhere. *Improvement:* vendor `plotly.min.js` (~3.6 MB) into `static/vendor/` so the GUI works when the browser host has no internet. |
| Run store | **SQLite (stdlib `sqlite3`) index + flat NDJSON/CSV per run** | SQLite gives queryable run listing/compare with zero pip deps; flat files keep raw samples greppable/scp-able and immune to schema migrations. No server DB. |
| Board side | **Python 3 stdlib only** (`mmap`, `struct`, `time`, `json`) | PYNQ image ships python3; nothing may be pip-installed there. |
| Zero-dependency floor | stdlib `http.server` + long-poll JSON + vendored Plotly | Documented fallback if pip/venv on mapstone-dev ever becomes unavailable. The API below is deliberately implementable either way (SSE degrades to 1 Hz polling of `/api/runs/{id}/state` — the endpoint exists regardless). |

Explicitly rejected: React/Vue/npm toolchains (build chain on shared lab
hosts), Grafana/InfluxDB (operational weight, run provenance awkward),
Jupyter (no run orchestration/safety story).

---

## 4. API + data model

### 4.1 Test contract (generic — companion test-plan doc plugs in here)

A **test definition** is registered server-side as:

```json
{
  "name": "throughput_m2s",
  "title": "M→S sustained throughput",
  "category": "throughput | latency | credit | soak",
  "param_schema": {
    "burst_words":    {"type": "int",   "default": 16,  "min": 1, "max": 256},
    "rate_pps":       {"type": "float", "default": 0, "doc": "0 = unthrottled"},
    "duration_s":     {"type": "float", "default": 10},
    "payload_pattern":{"type": "enum",  "values": ["counter","prbs","da7a"]}
  },
  "sweep_axes": ["burst_words", "rate_pps"],
  "targets": "master | slave | both",
  "hazard": "ahb_tx"
}
```

The GUI renders parameter forms from `param_schema` (data-driven — new tests
from the test-plan doc require **no frontend changes**), and any axis in
`sweep_axes` may be given a list/range instead of a scalar to define a sweep.
`hazard: "ahb_tx"` is what arms the criterion-B gate (§6). Initial registry:
`throughput_m2s`, `throughput_s2m`, `throughput_bidir`, `doorbell_rtt`,
`credit_recovery`, `soak`.

### 4.2 REST endpoints

```
GET  /healthz
GET  /api/tests                          test registry (drives the UI forms)
GET  /api/link/status                    live criterion-A/B snapshot (both boards)
GET  /api/lease                          fpgahub lease state (granted/queued/free)
POST /api/lease/acquire | /release

POST /api/runs                           start: {test, params|sweep, boards,
                                         artefact_version} → 201 {run_id}
                                         409 if experiment mutex held
                                         412 if gate/lease/provenance check fails
GET  /api/runs?test=&label=&sha=&since=  run index (filterable)
GET  /api/runs/{id}                      full record + summary
GET  /api/runs/{id}/events               SSE: state changes + live samples
GET  /api/runs/{id}/state                polling fallback (zero-dep floor)
GET  /api/runs/{id}/samples.csv|.ndjson  raw data download
POST /api/runs/{id}/abort

GET  /api/compare?ids=r1,r2,r3&x=burst_words&y=throughput_mbps
                                         server-side join for overlay charts
POST /api/recover/unjam                  wedge recovery (unjam both + converge),
                                         refused while a run is RUNNING
```

SSE event kinds: `state` (RunState FSM, reused from stress_toolkit),
`sample` (per-window measurement), `sentinel` (FCSM/PHY health), `log`,
`done` (summary attached).

### 4.3 Run record schema (`run.json`)

```json
{
  "run_id": "2026-06-12T14-03-22Z-a1b2c3",
  "test": "throughput_m2s",
  "params": {"burst_words": 16, "rate_pps": 0, "duration_s": 10},
  "sweep_point": {"burst_words": 16},
  "boards": {"master": "192.168.4.101", "slave": "192.168.6.101",
             "pair": "bridge1"},
  "lease": {"holder": "david", "token_id": "…", "scope": "link"},
  "provenance": {
    "artefact_version": "v37",
    "master":  {"sha256": "…64hex…", "label": "v37-word-pin-fix",
                "source_commit": "c57f17e", "target": "pynq-z2-pair-all",
                "build_date": "…", "expected_lock_min": 8},
    "slave":   {"sha256": "…", "label": "…", "target": "pynq-z2-pair-flip-all"},
    "verified_on_board": true,
    "phy_id_master": "0x…", "phy_id_slave": "0x…",
    "fifo_label": "rf_01k"
  },
  "timestamps": {"created": "…", "started": "…", "finished": "…"},
  "state": "DONE",
  "gate_snapshot": {"criterion": "B", "m_fcsm": 4, "s_fcsm": 4,
                    "m_cal_done": 1, "s_cal_done": 1},
  "summary": {"throughput_mbps_mean": 3.1, "throughput_mbps_p5": 2.8,
              "packets": 12000, "errors": 0,
              "rtt_ns": {"p50": 0, "p99": 0, "max": 0},
              "fcsm_excursions": 0},
  "artifacts": ["samples_master.ndjson", "samples_slave.ndjson",
                "summary.json", "agent_master.log", "agent_slave.log"]
}
```

**Provenance is mandatory and fail-closed:** at run start the orchestrator
(a) reads `~/tidelink_artefacts/<ver>/tidelink.bin.manifest.json` and
`tidelink-flip.bin.manifest.json` (schema from
`make_bitstream_manifest.sh` — sha256/label/source_commit/target), (b) runs
the `verify_deployed.sh` check that the image *on each board* matches that
manifest, and (c) reads `PHYID @ 0x4403211C` from both dies as a runtime
cross-check. If any of these fail → HTTP 412, no run record created. The
`fifo_label` field (e.g. the precompiled-SRAM macro variant) is parsed from
the manifest label by convention `vNN-<desc>[-fifoLABEL]` — this is the key
the SRAM-sweep family graphs group on, so it must come from the manifest,
never from a free-text GUI field.

### 4.4 Sample schema (NDJSON, one line per measurement window)

```json
{"t_ns": 1234567890, "win_s": 0.5, "board": "master", "dir": "m2s",
 "words_tx": 80000, "words_rx": 0, "pkts": 5000, "throughput_mbps": 5.12,
 "rtt_ns": null,
 "fcsm": 5, "cal_done": 1, "credit_obs": 31,
 "perf_r5": [0,0,0,0,0,0,0,0], "perf_r6": [...], "perf_r7": [...],
 "err": {"timeouts": 0, "mismatch": 0}}
```

The agent runs two loops in one process: the **timed data loop** (tight,
no instrumentation inside the window) and a **low-rate observer** (~10–20 Hz
read of `OBS 0x44032108` + perf regions R5/R6/R7) whose samples interleave
into the same stream — that is the credit/link-health time series of §5,
captured with zero SSH overhead.

### 4.5 Run store layout (mapstone-dev)

```
~/tidelink_throughput_runs/
├── runs.sqlite3                 # index: run_id, test, params-json, label,
│                                #  sha256s, fifo_label, state, summary-json
└── <run_id>/
    ├── run.json
    ├── samples_master.ndjson
    ├── samples_slave.ndjson
    ├── summary.json
    └── agent_{master,slave}.log
```

A sweep is N run records sharing a `sweep_id` — keeps each point
independently abortable/comparable and the schema flat.

---

## 5. Graphs (all Plotly, all fed from the run store)

1. **Throughput vs burst size** — line+markers, one trace per direction
   (M→S / S→M / bidir-aggregate), error bars = p5/p95 across windows.
   X = `burst_words`, Y = `throughput_mbps`. Built from a sweep's runs.
2. **Throughput vs FIFO size (SRAM sweep)** — the campaign chart. One trace
   per `fifo_label` family, X = burst size (or offered rate), Y = sustained
   throughput; hover shows full provenance (label, sha8, commit). Only runs
   with `verified_on_board: true` are eligible — enforced server-side in
   `/api/compare`.
3. **Latency CDF + histogram** — doorbell RTT raw samples; CDF with
   p50/p99/max markers; histogram beneath. Overlayable across runs.
4. **Credit-level time series** — observer-loop `credit_obs` + R5/R6 deltas
   vs time during a run; this is the credit-recovery test's primary plot.
5. **Link-health overlay** — FCSM state rendered as a background band
   (4=LINK_IDLE green / 5=LINK_DATA blue / other=red) under any time-series
   chart, plus error-counter step lines. Makes "throughput dip = FCSM
   excursion" visually obvious.
6. **Comparison view** — pick N runs from the index (filter by test/label/
   sha), overlay on a shared axis chosen via `/api/compare` x/y params;
   table of summary stats side-by-side with provenance columns.

Live view during a run = chart 4/5 streaming over SSE (same incremental
`Plotly.extendTraces` pattern `stress_toolkit/static/app.js` already uses).

---

## 6. Safety interlocks (orchestrator-enforced, not advisory)

Experiments are stateful and hazardous; every interlock below is checked
server-side in `POST /api/runs` and re-checked where noted. UI greys out the
start button with the failing reason displayed.

1. **Lease gate** — fpgahub lease for `bridge1` must be **GRANTED, not
   queued** (`lease.py` already distinguishes; a queued lease deploys over
   someone else's session — known foot-gun). No lease → 412. The orchestrator
   can acquire one, but never auto-steals; queue position is displayed.
2. **Criterion-B link-up gate** — Python port of `tt_verify_link_up`
   (`hwtest/lib/lib_hwtest.sh:157`): criterion A (8/8 lanes + cal_done both
   dies, training mode) **or** criterion B (cal_done both + FCSM ∈ {4,5}
   both; post-M12 lane_locked=0 is expected in data mode). Any test with
   `hazard: "ahb_tx"` refuses to start without it (wedge hazard —
   `tt_gate_ahb_tx` exits 3 for the same reason), and the gate is
   **re-evaluated between sweep points**.
3. **Single-experiment mutex** — one global `Run` slot in the orchestrator
   (409 otherwise), **plus** a cross-toolkit advisory `flock` on
   `/run/lock/tidelink-hw.lock` (or `~/.tidelink-hw.lock`) so the eye
   (:8088) / stress (:8089) GUIs and CLI scripts can honour the same mutex —
   the orchestrator both takes it and refuses to start if another process
   holds it.
4. **Sentinel during runs** — observer-loop FCSM/PHY watch (reuse of
   stress_toolkit's `FcsmMonitor`/`PhyHealth` semantics): if FCSM leaves
   {4,5}, or the known jam signature appears (FCSM=5 with
   `a2l_replay_link_valid` `0x108[30]`=1 and `fe_rx_is_full` `0x108[31]`=0 —
   the `unjam_fc_node.sh` header signature), the run is auto-aborted, marked
   `FAILED(reason=link_excursion)`, and the recovery button is highlighted.
   Every run also carries a hard wall-clock watchdog (soak excepted, which
   uses a per-window heartbeat instead).
5. **Wedge-recovery button** — `POST /api/recover/unjam` runs
   `unjam_fc_node.sh` on **both** boards then `bringup_pair_converge.sh`,
   streaming output to the UI; refused while a run is RUNNING (abort first).
   This is a first-class UI element, not a hidden admin path — wedges are
   routine during bring-up.
6. **Provenance gate** — staged-manifest + `verify_deployed` + PHYID checks
   (§4.3) fail-closed. A mismatched/unmanifested bitstream cannot produce a
   run record, so it can never pollute the SRAM-sweep graphs.
7. **No speculative TX** — agents never touch `AHB_TX 0x44000000` outside an
   admitted run (inherited rule from stress_toolkit's safety section);
   doorbell/observer paths are wedge-safe by construction.

---

## 7. Implementation plan

### File layout

```
pynq_host/throughput_gui/
├── README.md                      # run instructions + tunnel command
├── requirements.txt               # == stress_toolkit's (fastapi/uvicorn/
│                                  #   sse-starlette/httpx/pydantic/pytest)
├── app.py                         # FastAPI entry (:8090), endpoints §4.2
├── orchestrator.py                # Run FSM (adapted from stress runner.py),
│                                  #   mutex, watchdog, sweep loop
├── gates.py                       # criterion-A/B port, provenance gate,
│                                  #   cross-toolkit flock
├── lease.py / deploy.py           # re-exports of eye_toolkit/web versions
│                                  #   (same pattern stress_toolkit uses)
├── agent/
│   └── tl_perf_agent.py           # ON-BOARD: stdlib-only, mmap-once,
│                                  #   timed loops + observer, NDJSON out
├── agent_channel.py               # push agent + persistent-SSH pipe mgmt,
│                                  #   GO-barrier, line decoder
├── tests_registry.py              # §4.1 definitions (test-plan doc lands here)
├── store.py                       # SQLite index + run-dir reader/writer
├── recovery.py                    # unjam/converge subprocess wrapper
├── static/
│   ├── index.html, app.js, style.css
│   └── vendor/plotly.min.js       # vendored, no CDN dependency
├── systemd/tidelink-throughput-web.service   # 127.0.0.1:8090
└── tests/                         # pytest: FakeMmio + FakeAgentChannel
    ├── test_gates.py, test_store.py, test_orchestrator.py,
    └── test_agent_protocol.py     # agent run locally against /dev/zero-mmap
```

(Optional later refactor: extract `lease/deploy/mmio_remote` into
`pynq_host/webcommon/` — **not** part of this plan; re-export keeps the
existing toolkits untouched.)

### Phases

**P0 — walking skeleton (1.5–2 days)**
One canned `throughput_m2s` run end-to-end: agent push + GO + NDJSON stream,
criterion-B + lease + mutex gates, SSE live throughput chart, CSV download,
run dir written with provenance block. No sweep UI, no compare. *Exit
criterion:* one button-click run on bridge1 produces a chart and a
`run.json` whose sha256s match the staged v-current manifests.

**P1 — sweeps, store, compare (2.5–3 days)**
Sweep axes (burst × rate × direction) with between-point gate re-checks;
`doorbell_rtt` (latency CDF/histogram), `credit_recovery` (credit
time-series + link-health band), `soak` (heartbeat watchdog); SQLite index +
run list page + comparison overlay (`/api/compare`); wedge-recovery button +
jam-signature auto-abort; systemd unit. *Exit:* charts §5.1/3/4/5/6 all
renderable from stored runs.

**P2 — SRAM-sweep campaign support (1.5–2 days)**
FIFO-size family view (§5.2) grouped on manifest `fifo_label`; campaign
checklist UI: pick a list of staged artefact versions → for each, GUI offers
*deploy (via existing `deploy.py`/`deploy_pair.sh`) → converge → run sweep →
record*, pausing for confirmation at each deploy. **Recommendation: builds
stay manual/CLI.** Triggering Vivado farm builds from the GUI is explicitly
out of scope — builds take ~22–50 min, involve srv04936 coordination, and
are policy-gated on sim passes (`feedback_sim_gate_before_hw_deploy`); the
GUI only *consumes* labeled, manifested bitstreams from
`~/tidelink_artefacts/`. Deploy-from-GUI of an already-staged image is in
scope (it's just `deploy_pair.sh`).

**Total: ~6–7 focused days.**

### Agent-autonomous vs needs-the-user

| Autonomous (agent can do offline) | Needs the user |
|---|---|
| All code in the layout above + pytest suites (FakeMmio / FakeAgentChannel / tmpdir store — same offline-test pattern the siblings use) | Confirm port **8090** (and that nothing else on mapstone-dev claims it) |
| Agent protocol validated locally (mmap an anonymous file instead of `/dev/mem`) | Create venv + `pip install -r requirements.txt` on mapstone-dev, install/start the systemd unit (or run uvicorn ad-hoc) |
| Plotly vendoring, static UI | First live HW validation session under a granted `bridge1` lease (standing deploy permission exists, but link state must be triaged by a human if v37-class word-phase issues recur) |
| Porting criterion-B + provenance gates with unit tests | Decide retention policy for `~/tidelink_throughput_runs/` disk growth |
| | Firewall: none needed (127.0.0.1 bind + ssh -L), but confirm no lab policy against new loopback listeners |

### Risks / open questions

- **Link rate vs PS overhead:** at the current 6.25 MHz link the PS-side
  mmap loop is not the bottleneck, but the agent should still self-report
  its achieved *offered* rate per window so saturation analysis can separate
  "link limited" from "driver limited".
- **Sudo password on agent stdin:** reuse the `echo $PASS | sudo -S` pattern
  from `mmio_remote.py`; the GO-barrier protocol must tolerate the sudo
  prompt consuming the first stdin line (stage with `sudo python3` wrapper
  invoked once, GO sent after `ready`).
- **Register-level test bodies** (exact AHB_TX burst formats, doorbell
  registers, credit observation fields) are owned by the companion test-plan
  doc; this GUI consumes them through the §4.1 contract. `tl37.py` and
  `hwtest/lib` are the reference implementations to port from.
- The stress_toolkit `PacketStress` mode overlaps P0's canned test; once P1
  lands, deprecate it with a pointer here to avoid two half-truth
  throughput numbers.
