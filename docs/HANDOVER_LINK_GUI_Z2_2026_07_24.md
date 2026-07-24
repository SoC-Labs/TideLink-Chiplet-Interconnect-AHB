# HANDOVER — TideLink Live Link-Monitor GUI on the PYNQ-Z2 pair

**Date:** 2026-07-24 · **Base:** `main @ ded7d15` · **Author:** analysis session (Fable), for an implementing agent
**Read this whole document before writing any code. The hazards section is not optional.**

---

## 1. Mission

Build a **live link-visibility GUI** for the TideLink chiplet interconnect running on the
**two-board PYNQ-Z2 pair** (z2_02 = die_a "master" ↔ z2_03 = die_b "slave", GPIO ribbon).
It must show, continuously and per-die:

- link state (fcsm, cal_done, lane_locked, role/mask handshake),
- delivered throughput (words/s, byte-exactness proof),
- **where the time goes** (link busy vs stalled vs idle-waiting-on-PS),
- credit-loop health (rx room, pair credit, starvation, sticky overrun/underrun),
- CRC error count,

with **load-generator controls** (packet length N, REL_THRESHOLD, run/stop soak) so the
efficiency story can be demonstrated interactively: dragging N moves header efficiency along
N/(N+2); restoring REL_THRESHOLD to its POR of 20 visibly starves the credit loop; the
reliability counters stay on screen the whole time.

**This is an extension of an existing app, not a new stack.** Do not start a new web service.

---

## 2. Architecture (decided — do not relitigate)

Extend **`pynq_host/throughput_gui/`** (FastAPI + SSE + vanilla JS + vendored Plotly,
port **8090**, loopback-bound on mapstone-dev, reached via `ssh -L 8090:localhost:8090`).
It already has everything hard:

| Piece | File | Reuse |
|---|---|---|
| Web app, SSE endpoints, run store | `app.py`, `store.py` | add a **Link Monitor** view + `/api/monitor` SSE |
| On-board mmap agent (stdlib-only, pushed over SSH) | `agent/tl_perf_agent.py` | add a `--cmd monitor` polling loop |
| SSH channel (sshpass → `xilinx@<board>`, persistent pipe) | `agent_channel.py` | as-is, one channel **per board** |
| Register decode (SWI_LANE_STATUS, OBS_FC_CREDIT, jam matrix) | `regmap.py` | as-is + extend |
| Safety interlocks (flock, fpgahub lease, criterion-A/B gate, delivery proof, jam sentinel, watchdog) | `orchestrator.py`, `gates.py`, `lease.py` | **keep all of them** |
| Dev mode (in-process die model + spool-file wire, no boards) | `--fake` in agent + app | **develop against this first** |
| Sibling proofs of the pattern | `scripts/eye_toolkit/web` (:8088), `scripts/stress_toolkit/web` (:8089) | reference only |

**Z2 topology (differs from the KR260 on-chip demo):** two boards, each with its own PS.
The server runs **two agents concurrently** (one per board, same GO-barrier pattern the
stream/drain roles already use). Boards are **not** NTP-synced (clocks ~34 h apart) — never
compare wall-clock across boards; each agent timestamps its own windows with
`time.monotonic()` and the server aligns on receipt order only.

Board IPs / identity: defaults in `app.py` (`192.168.4.101` / `192.168.6.101`, board
`bridge1`); board access is arbitrated by **fpgahub** — see §7.

---

## 3. Z2 address map (absolute, Zynq-7000)

TideLink APB block base **`0x4403_2000`** on *both* boards (each board sees only its own die).
Register offsets below are `0x4403_2000 + off`. The agent already encodes these
(`tl_perf_agent.py` top: `PAIR_BASE = 0x44032000`).

- **AHB TX aperture:** default `0x4400_0000`, but **image-dependent** — GP1-split images
  override via `TIDELINK_TX_BASE` env (older maps used `0x4000_0000`). Take it from the
  deployed image's manifest / existing agent env plumbing. Never hardcode a new literal.
- **Local RX FIFO (pop-on-read!):** `0x4401_0000` (`TIDELINK_RXFIFO_BASE`).

### 3a. Poll-safe whitelist (the ONLY offsets the monitor loop may read)

| off | name | use |
|---|---|---|
| `0x008` | PACKET_WORD_LENGTH (RO) | current pkt len |
| `0x00C` | CREDIT_COUNT (RO) | local RX room ("rxcred") — this is credits free, NOT occupancy |
| `0x010` | STATUS (RO) | [1] sticky overrun, [2] underrun, [4] committed — reliability tripwire |
| `0x018` | RELEASE_ACC (RO) | sub-threshold freed credits |
| `0x028` | PAIR_CREDIT_COUNTER (RO) | credits toward peer (release-observability accumulator) |
| `0x108` | SWI_LANE_STATUS | **headline reg**: [7:0] lane_locked, [16] cal_done, **[19:17] fcsm (3 bits!)**, [23] cr_seen, [31] fe_rx_full — decode already in `regmap.py` |
| `0x114` | SYNC_DET count | RX sync health |
| `0x120` / `0x124` | TX/RX SYNC obs (V2) | sync insert/detect counters |
| `0x140` | SWI_EPOCH_STATUS | [0] epoch_anchored, [6:1] span |
| `0x194` | OBS_MASK_HS | [19] mask_hs_match, [20] gate_open — autonomy genuineness |
| `0x198` | OBS_CAL | cal FSM state, live training_mode |
| `0x19C` | OBS_FC_CREDIT | fe_rx credit/ptr/full + 0xFC marker — catches garbled credit |
| `0x0A0–0x0FC` | perf block (Phase B only, see §5) | PERF_CTRL / counters / PERF_ID |

Wlink FC-node CRC error count: node base + `0x20` (Wlink region is `0x4403_0000 + 0x1720`
for the FC node used in the throughput docs — confirm the node offset against
`docs/REGISTER_MAP.md:471` before wiring the gauge).

### 3b. NEVER READ (side effects or PS hang)

- **`0x1AC`, `0x1B0`, `0x1B4` (abs `0x4403_21AC/B0/B4`) — HARD-STALL the PS on read.**
  Board-proven, uninterruptible AXI hang, power-cycle to recover. Treat `0x1A0–0x1B8` as
  quarantined. (`docs/HANDOVER_2026_07_10.md:14`)
- `0x020`, `0x024` — **read-clears** the released/doorbell credit accumulators (would corrupt
  the credit bookkeeping the link relies on). The drain path owns these, never the monitor.
- `0x038` (PTP payload), eye/CRC lane regs `0x15C/0x160/0x168` — read-clear / auto-increment.
- The RX FIFO aperture `0x4401_0000` — pop-on-read. Monitor never touches it; only the
  drain role does.
- Any offset not on the whitelist: undecoded APB addresses can hang the PS. **The agent's
  monitor loop must be whitelist-driven (a frozen tuple of offsets), not "read a range".**

### 3c. Access discipline (existing, keep)

Reads/writes go through mmap-once `/dev/mem` + `ctypes.c_uint32.from_buffer(...)` for exactly
one aligned 32-bit beat. **`struct.pack_into/unpack_into` on the mmap is BANNED** — it emits
~5 narrow AHB beats per word on this PS and corrupts pop-on-read/TX apertures (this bug burned
three RTL "fixes" before it was caught). `tl_perf_agent.py` already does this correctly —
copy its accessor, don't write a new one.

---

## 4. Phase A — Link Monitor on the CURRENT golden images (no rebuild, no deploy)

The Z2 boards were restored to their golden images 2026-07-17 and hold a proven-good
byte-exact link (24/24 continual-data, both directions). Phase A must work on those images.

**Do not assume the perf counters work on the golden images** — the PERF_CTRL decode fix
(`e6f0254`/`1403248`, 2026-07-17 16:34) postdates them, so counters almost certainly read 0.
Phase A therefore derives rates in software (the app already does this for runs).

Tasks:

1. **Agent:** add `--cmd monitor` to `tl_perf_agent.py`: loop reading the §3a whitelist at a
   configurable period (default 200 ms), emit one NDJSON line per sample
   (`{"ev":"mon", "t":monotonic, "r":{"108":..., "00c":..., ...}}`). Stdlib only,
   Python-3.6-tolerant, works under `--fake` (extend `_FakeMem` with the missing regs).
2. **Server:** `/api/monitor/start|stop`, one agent channel per board, `/api/monitor/events`
   SSE multiplexing both dies. Monitor is **read-only** and may run without a lease *only in
   `--fake`*; against real boards it sits behind the same fpgahub-lease + flock gates as runs
   (a poll loop is still board occupancy).
3. **UI:** a Link Monitor page: per-die state chips (fcsm/cal/lanes/mask_hs/gate), credit
   gauges (CREDIT_COUNT vs 4096 max, PAIR_CREDIT delta/s), sticky overrun/underrun banner,
   CRC count, and a delivered-words/s sparkline fed by the existing run events when a run is
   active. Decode via `regmap.py` only — no fresh bit-slicing in JS.
4. **Load-generator controls:** wrap the existing orchestrator run types; expose packet
   length N and REL_THRESHOLD (`off 0x004`, POR **20**; write 0 for release-per-drain) as run
   parameters with a live header-efficiency readout `N/(N+2)`. TX stays credit-gated and
   behind the delivery-proof gate — **no speculative TX, ever** (the agent docstring rule).
5. **Tests:** pytest against `--fake` (two agent subprocesses, spool-file wire): monitor
   stream shape, whitelist enforcement (attempting a non-whitelisted offset must raise), SSE
   fan-out, and a full fake soak with the monitor running.

Acceptance: `python3 -m pynq_host.throughput_gui.app --fake --port 8090` shows both fake dies
live on the monitor page; all existing tests still pass; the new monitor never issues a read
outside the whitelist (assert in the agent, test in CI).

## 5. Phase B — hardware utilization gauges (requires a rebuilt image)

Gives the headline gauges software can't derive: **link utilization = ΔLINK_BUSY/ΔSAMPLE**,
TX/RX stall fractions, CREDIT_STARVE cycles.

1. **Probe first (cheap, on golden):** write `0x0A0 = 0x1`, read back. Sticks → counters
   live, skip the rebuild. Reads 0 → image predates the fix (expected). PERF_ID at `0x0FC`
   (`0x5046_0100`) only proves the block exists, **not** that CTRL is writable.
2. **Rebuild both Z2 images from main:** targets `pynq-z2-pair-all` + `pynq-z2-pair-flip-all`,
   farm build (`make -C fpga farm_build FARM_JOBS="<target>@srv04936"`), `TIDELINK_PHY_V2=1`
   exported. ⚠ `-verilog_define` never reaches packaged-IP OOC synth — verify the fix is in
   the bitstream **structurally** (probe test in step 1 after deploy), never by build-log or
   md5 diff.
3. **Deploy discipline (non-negotiable, memory-proven):** fpgahub lease GRANTED first;
   `make sim_gate` green on the exact commit before any deploy; **power-cycle → deploy BOTH
   boards → bring up → test** (never reload the PL under a live link); confirm the rig is
   bootpy-clean (`bootpy.service` used to reload `base.bit` ~85 s after boot and looked like
   "died at deploy"). Re-establish the byte-exact baseline (existing delivery-proof gate)
   before trusting anything new.
4. **Perf sampling protocol** (window sampling, in the agent): `0x0A0=0x5` (enable+clear) →
   run window (e.g. 1 s) → `0x0A0=0x3` (freeze) → read `0x0C8–0x0F4` → repeat. Freeze gives a
   coherent snapshot; never read counters unfrozen and call them a window.
5. **UI:** utilization %, stall %, starve cycles, and the "where each word's time goes"
   stacked bar (link busy / TX stall / remainder = PS round trip). Expect ≈17% utilization
   at the golden rate with the PS generator — that *is* the finding, show it proudly.

## 6. Numbers the GUI should reproduce (sanity anchors)

- Golden 2.343 MHz: ~48.8k words/s ≈ 195 kB/s; 25 MHz rung: ~517k words/s ≈ 2.07 MB/s.
- Per-word cost ≈ 96 PL cycles (PS→PL store round trip); link needs ~16 → ~83% idle.
- Wire payload efficiency 25% (32 useful bits / 128-bit beat); header efficiency N/(N+2).
- Credit release per drained minimal packet: +4 (len 2 + 2-word header). MAX_CREDITS 4096.

If the GUI shows numbers wildly off these on the golden image, suspect the instrument first
(rule: **verify the instrument before theorizing about the DUT** — this project has burned
five debugging sagas on instrument bugs, including the "delivery lottery" that was a
fixed-offset FIFO read).

## 7. Operational rules (all board interaction)

1. fpgahub lease must be **GRANTED (not queued)** before touching a board; keep the
   cross-toolkit `flock` (`~/.tidelink-hw.lock`). `lease.py` implements this.
2. Remote power-cycle exists via fpgahub — never plan around a bench visit.
3. Never `reboot` boards ad hoc; power-cycle through fpgahub. (On KR260 `reboot` wedges the
   board — irrelevant here but do not copy patterns that assume it.)
4. TX only through the credit-gated, delivery-proof-gated paths that exist. The RX FIFO write
   side has **no hardware backpressure** (`tidelink_fifo_mem.sv:92` — zero-credit writes are
   silently dropped, sticky overrun only). The end-to-end credit protocol is the only
   protection; the monitor's job is to make its health visible, not to bypass it.
5. Boards run plain PYNQ images — agent code is stdlib-only, nothing pip-installed on boards.

## 8. What NOT to do

- No ILA. Z2 ILA targets exist (`pynq-z2-pair-ila`) but the flow is rotted (Vivado 2025.2
  removed runtime depth/capture controls; `mark_debug` stripped on no-ILA builds) and was
  deliberately superseded by the APB observability path you're using.
- No new web service / framework; no ports other than 8090; no binding beyond loopback.
- No RTL changes in this task. (Wanted later, tracked separately: APB-visible
  `tx_dropped_cnt`, AHB hreadyout-low stall counter, overrun counter.)
- No reads outside the whitelist, no "scan the register space", no reading `0x020/0x024`
  from the monitor, ever.
- Do not write "measured" numbers into docs/commits that came from an unverified
  instrument (see §6 rule).

## 9. Key references (read before coding)

- `docs/THROUGHPUT_GUI_PLAN_2026_06_12.md` — the app's architecture plan (SSE degrade to
  1 Hz polling, run store, gates).
- `pynq_host/throughput_gui/README.md` — dev mode, deploy on mapstone-dev, venv pattern.
- `docs/REGISTER_MAP.md` — authoritative register map (esp. lines 60–376, 441–471).
- `docs/HANDOVER_2026_07_10.md` — hazard registers, unjam matrix, operational history.
- `docs/ARCH_ANALYSIS_2026_06_12.md` — the framing-overhead analysis the GUI visualizes.
- `pynq_host/scripts/tl39.py` — reference decodes + the SoC guard pattern.
- Analysis behind this handover (overhead waterfall, PHY report, demo design):
  session artifact "TideLink Link Efficiency — Analysis & Demo Plan", 2026-07-24.

## 10. Definition of done

1. `--fake` demo: monitor page live with two fake dies, run controls working, all tests green.
2. Real-hardware Phase A: monitor running against the golden Z2 pair under lease, showing
   fcsm=4/cal=1 both dies, credit gauges moving during a gated soak, zero non-whitelisted
   reads (agent asserts), zero sticky overruns caused by the GUI.
3. Phase B (if image rebuilt): utilization/stall/starve gauges live, the ~17%-utilization
   finding reproduced on screen, byte-exact delivery re-proven after deploy.
4. Nothing in the existing throughput/eye/stress toolkits regressed; existing pytest suite green.
