# HANDOVER — TideLink Live Link-Monitor GUI on the PYNQ-Z2 pair

**Date:** 2026-07-24 · **Base:** `main @ ded7d15` · **Author:** analysis session (Fable), for an implementing agent
**Read this whole document before writing any code. The hazards section is not optional.**

---

## 1. Mission

Build a **live link-visibility GUI** for the TideLink chiplet interconnect running on the
**two-board PYNQ-Z2 pair** (z2_02 = die_a "master" ↔ **z2_01** = die_b "slave", GPIO ribbon —
**verified 2026-07-24 on live hardware; NOT z2_03**, see §11).
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

**Second mission (added 2026-07-24): versioned throughput benchmarking.** New RTL versions
with throughput improvements will be built as tagged bitstreams. The GUI must run the same
fixed workload suite against each deployed version, record every metric against the version
tag, and render **version-over-version comparison graphs** that quantify the improvement —
with repeats, so build/bring-up variance doesn't masquerade as a gain. See §10.

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

Board IPs / identity: die_a = z2_02 = `192.168.4.101`; **die_b = z2_01 = `192.168.2.101`**
(verified live 2026-07-24). ⚠ `app.py`'s defaults (`192.168.6.101` = z2_03) and the
`bridge1` pair concept are **stale** — fix the defaults as part of Phase A. Board access is
arbitrated by **fpgahub** — see §7 and §11 for the current per-board lease CLI.

---

## 3. Z2 address map (absolute, Zynq-7000)

TideLink APB block base **`0x4403_2000`** on *both* boards (each board sees only its own die).
Register offsets below are `0x4403_2000 + off`. The agent already encodes these
(`tl_perf_agent.py` top: `PAIR_BASE = 0x44032000`).

- **AHB TX aperture: `0x8400_0000`** and **local RX FIFO (pop-on-read!): `0x8401_0000`** —
  **measured from the `.hwh` of BOTH the golden and v0 images (GP1-split, M_AXI_GP1); the
  scripts' `0x4400_0000` defaults are WRONG for these images** (a write there dies on a bus
  error). Always export `TIDELINK_TX_BASE=0x84000000 TIDELINK_RXFIFO_BASE=0x84010000`, and
  derive from the deployed image's `.hwh` when images change. APB stays `0x4403_xxxx`.

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

**The perf counters DO NOT work on the golden images — measured 2026-07-24, no longer an
assumption:** on both dies of the freshly redeployed golden, `PERF_ID` (0x0FC) reads
`0x00000000` (expected `0x5046_0100`) and a PERF_CTRL write does not stick — the region-decode
bug scrambles both the write AND read paths. Phase A therefore derives rates in software (the
app already does this for runs); every hardware gauge in Phase B needs the rebuilt image.

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

1. **Probe DONE (2026-07-24): does not stick, PERF_ID=0 on both dies** → the rebuild is
   mandatory. (Probe method for re-use on any new image: write `0x0A0 = 0x1`, read back;
   PERF_ID at `0x0FC` must read `0x5046_0100` AND the CTRL bit must stick AND
   SAMPLE_COUNT `0x0E8` must advance.)
2. **Rebuild both Z2 images from main:** targets `pynq-z2-pair-all` + `pynq-z2-pair-flip-all`,
   farm build (`make -C fpga farm_build FARM_JOBS="<target>@farm-host-a"`), `TIDELINK_PHY_V2=1`
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

- `docs/THROUGHPUT_GUI_PLAN_2026_06_12.md [removed 2026-07; in git history]` — the app's architecture plan (SSE degrade to
  1 Hz polling, run store, gates).
- `pynq_host/throughput_gui/README.md` — dev mode, deploy on mapstone-dev, venv pattern.
- `docs/REGISTER_MAP.md` — authoritative register map (esp. lines 60–376, 441–471).
- `docs/HANDOVER_2026_07_10.md` — hazard registers, unjam matrix, operational history.
- `docs/ARCH_ANALYSIS_2026_06_12.md [removed 2026-07; in git history]` — the framing-overhead analysis the GUI visualizes.
- `pynq_host/scripts/tl39.py` — reference decodes + the SoC guard pattern.
- Analysis behind this handover (overhead waterfall, PHY report, demo design):
  session artifact "TideLink Link Efficiency — Analysis & Demo Plan", 2026-07-24.

## 10. Versioned throughput benchmarking (the comparison mission)

### 10a. The confound you MUST design around (or the campaign lies)

On the Z2 pair the end-to-end rate is **PS→PL-bus-bound** (~96 PL cycles/store; the link is
~83% idle). Consequences for benchmarking RTL versions:

- **Wire-efficiency improvements (FC batching, addr suppression, framing changes) will NOT
  move delivered words/s** with the PS software generator — the bottleneck is elsewhere. If
  the campaign's only metric is words/s, those versions will falsely read as "no improvement".
  The metric that moves is **link-busy cycles per delivered word** (ΔLINK_BUSY/ΔRX_WORD_COUNT,
  Phase-B counters) — it drops in direct proportion to wire efficiency.
- **Pipelining/backpressure improvements (deeper TX skid, burst acceptance, PL-side or DMA
  generator) DO move delivered words/s** — that's the metric for them.
- The 2026-07-17 rate-ladder lesson is binding: hclk and link UI are chained on these images,
  so any comparison across versions built at different clocks is **structurally confounded**.
  All versions in one campaign must be built at the **same clk_wiz settings**, and every run
  records a **bus-reference control** (timed non-link PS access, the `--busref` pattern) so a
  PS/bus-rate shift between deploys is detected instead of absorbed into the results.

Every version therefore gets a small **metric matrix**, not one number:
`delivered_words_per_s`, `link_busy_per_word`, `tx_stall_frac`, `rx_stall_frac`,
`credit_starve_cycles`, `crc_errors` (must be 0), `overrun_sticky` (must be clean),
`busref_us` (control). Words/s answers "is the system faster"; link_busy_per_word answers
"is the link protocol leaner"; the controls answer "was the comparison fair".

### 10b. Version registry

Extend the store with a `versions` table keyed by **human tag** (e.g. `tl-tp-v0-baseline`,
`tl-tp-v1-skid8`): tag → git commit → build target(s) → bitstream manifest sha256s (both
boards) → build date → notes. The existing fail-closed provenance (manifest + PHYID recorded
per run, HTTP 412 without) already binds runs to bitstreams — the registry just names them.
A run's version is **resolved from the deployed manifest sha256, never typed by the operator**
(an operator label that disagrees with the manifest is a hard error, not a warning).
`tl-tp-v0-baseline` = the current golden pair, benchmarked first — it is the denominator for
every improvement claim.

### 10c. Fixed workload suite (identical for every version)

| id | workload | primary metric |
|---|---|---|
| W1 | credit-gated stream M→S, N=2, 60 s | delivered words/s (small-packet) |
| W2 | credit-gated stream M→S, N=1024, 60 s | delivered words/s (streaming) + link_busy_per_word |
| W3 | drain-limited (receiver-paced), 60 s | credit-loop metrics, REL_THRESHOLD=0 |
| W4 | bidirectional simultaneous, 60 s | aggregate words/s + starve cycles |
| W5 | busref control (no link traffic) | busref_us — comparison-validity gate |

Suite parameters live in one versioned config so "the same suite" is machine-checkable.
Byte-exactness is verified on every workload (existing delivery-proof + drain verification) —
**a throughput number from a run that wasn't byte-exact is discarded, not annotated**.

### 10d. Repeats and honesty

Bring-up lottery and build variance are real on this rig. Per version: ≥3 suite repetitions,
each from a fresh power-cycle → deploy → bring-up (the §5.3 discipline). Graphs show
median with min–max whiskers, never a single run. A version whose runs disagree wildly is
reported as "unstable", which is itself a finding — do not cherry-pick the good run.

### 10e. Campaign orchestration

A campaign = ordered list of version tags × the suite × repeat count. The orchestrator walks
it: acquire lease → power-cycle → deploy version to BOTH boards → bring up → criterion-A/B +
delivery proof → run suite (monitor loop recording throughout) → store. Deploy/bring-up
failures mark the version attempt FAILED and continue the campaign; they never silently
reduce the repeat count. Campaigns are resumable (the registry knows which cells are filled).
Manual single-version mode must also exist (deploy is slow; the operator may drive it).

### 10f. Comparison graphs (the deliverable)

- **Version-over-version**: grouped bars (or a line when versions form a sequence) of each
  metric vs version tag, baseline highlighted, median + whiskers, one panel per metric — no
  dual axes, no mixed units on one panel.
- **Improvement view**: % change vs `v0-baseline` per metric, with the busref control shown
  alongside so a bus shift is visible next to any claimed gain.
- **Time-series drill-down**: click any bar → that run's live monitor traces (words/s,
  credit level, stalls over the 60 s window) from the stored NDJSON.
- Export: CSV per campaign (the store already writes NDJSON/CSV per run — aggregate, don't
  reinvent).

## 11. Rig state + operational deltas (session log, 2026-07-24)

Everything in this section was **measured/performed live on 2026-07-24**; trust it over any
older doc or memory it contradicts.

- **Cabling (verified by live link + deploy records): die_a = z2_02 (`192.168.4.101`) ↔
  die_b = z2_01 (`192.168.2.101`).** z2_03 is a spare, NOT on the ribbon. Update `app.py`
  defaults and any `.6.101` literals.
- **fpgahub lease CLI changed** (older docs/memories reference a `pair lease acquire bridge1`
  that no longer exists): per-board groups now —
  `fpgahub board lease acquire pynq_z2_02 --ttl <s>` (and `pynq_z2_01`); the token is printed
  ONCE by acquire; `board lease heartbeat|release <board> --token <tok>`. `lease.py` must be
  ported to this model. Hub power-cycle entries: `pynq_z2_02_ps` (rshtech port 3),
  `pynq_z2_01_pl` (rshtech port 2), `pynq_z2_03_ps` (z2_fanout port 1).
- **The boards DO hard-hang when idle** — z2_02 was found dead (hub port on, no route) after
  a week idle and needed a hub power-cycle. Budget for this in campaign orchestration
  (power-cycle → deploy → bring-up is the normal per-repeat path anyway).
- **The GOLDEN pair binaries are preserved** at mapstone-dev
  `~/tidelink_artefacts/golden-z2-20260717/` (`tidelink.bin` die_a sha256 `6d3cadd9…`,
  `tidelink-flip.bin` die_b sha256 `c1dbd91a…`, + `.hwh` + `SHA256SUMS` + README). They were
  recovered from the boards' `/lib/firmware` (md5 `4b5889a9…`/`e384eec6…` — matches the
  07-17 golden record). ⚠ They are NOT the same build as `/tmp/tidelink_deploy` (07-15,
  different hashes) — always deploy golden from the preserved dir with `--expect-sha256`.
- **Rig left in a healthy state:** golden redeployed to both dies with the sha256 guard,
  link trained autonomously (cal=1, fcsm=4, cr_seen=1 both dies; credits 4096; no
  overrun/underrun), leases released.
- **Baseline build:** git tag `tl-tp-v0-baseline` = `ded7d15` (local tag). Built from a
  CLEAN worktree `~/SoCLabs/tidelink-build-v0` — the main checkout carries uncommitted GUI
  + RTL WIP and must never be the source of a benchmark bitstream. (Soton GitLab was down;
  worktree submodules were cloned from the local checkouts with
  `git -c protocol.file.allow=always` and URL overrides.) Farm gate requires
  `source set_env.sh` + `export TIDELINK_PHY_V2=1` or it refuses (silent-V1 guard).
- **Phase A note:** the golden images predate SYNC/epoch-era regs in part; the monitor must
  tolerate individual whitelist regs reading 0 on older images (decode by PHY/OBS ID
  markers where available, e.g. `0x19C[31:24]==0xFC`).

### 11b. v0 deploy + acceptance session (later on 2026-07-24)

- **v0 was deployed to both dies (sha256-manifest-verified) and its PERF acceptance PASSED:**
  PERF_ID `0x5046_0100`, PERF_CTRL sticks, SAMPLE_COUNT free-runs at ~4.7 MHz on both dies.
  **Phase B's hardware gauges are proven live on the v0 image.**
- 🔴 **OPEN BLOCKER — data delivery fails under plain `deploy_pair.sh` bring-up on BOTH
  images.** `link_delivery_proof.sh` (correct GP1 apertures, clean POR, link fcsm=4/cal=1,
  gate_open=1 both dies) fails **both directions on v0 AND on the restored golden** — so this
  is NOT a v0 RTL regression; the July 24/24 delivery and the GUI's criterion-B all ran under
  the throughput_gui orchestrator / tlchar-era bring-up, which evidently performs a step the
  plain deploy does not (data-mode/zero-poke class). **First campaign task: replay the
  orchestrator bring-up on golden until delivery passes, diff the register writes vs plain
  deploy, and encode the missing step into the campaign's deploy phase.** Clues recorded:
  Wlink FE `fe_rx_ptr` advances (link-layer packets DO land), while on v0
  `EPOCH_140=0` / `SLICEMAP=0xFFFFFFFF` (POR) / zero SYNCs inserted or detected.

### 11c. The write-set diff is DONE (code analysis, later 07-24) — candidate pokes ranked

`deploy_pair.sh`'s entire post-load write-set is **{strap GPIO `0x4404_0000`}** (Phase 3-5
autonomy stripped everything else; its own comments say to restore the `0x208` triplet "if
wedged"). The working July flows additionally performed, in rank order of matching our
symptom (`EPOCH=0`, `SLICEMAP=POR`, zero SYNCs, FE ptr advances, no RX commit):

1. **v39 deskew-anchor recipe** — `hold`/`lockthresh`/**`wpauto` (`0x4403_2104`,
   "proven to fix the credit/send-gate", tl39.py:12)**/`arm`/**staggered freeze (die_b then
   die_a)** → gate on `EPOCH 0x2140` anchored. Script: `v39_data_test.sh`.
2. **SYNC beacon: R8 `0x4403_2100 = 0x1C`** (`sync_insert_en`+`sync_force_always`) — "the
   documented bring-up write" (docs/CRC_ROOTCAUSE.md:128); beacon is POR-OFF and without it
   RX has no re-anchor delimiter (docs/ERROR_INJECTION_FINDINGS.md:584).
3. **Pair-credit SEED both directions** — `0x4403_2020 = delta` (bumps `0x028`); "mandatory
   bring-up step, not an optimisation" (tl_perf_agent.py:1063, char_session.sh:9).
4. **`to_data_mode()` LL-swreset triplet** — R8=0 then `0x4403_0208 = 0x27f08→0x27f00→
   0x27f07`; "the load-bearing step" (docs/reference/TIDELINK_BRINGUP_USER_GUIDE.md:298,
   which also warns `role_locked=1` is "necessary but NOT sufficient for traffic").
5. `REL_THRESHOLD 0x2004 = 0` (throughput/credit-return knob, not a delivery enabler).

### 11d. LADDER EXECUTED ON GOLDEN — all four hypotheses REFUTED (07-24, board-measured)

Ran the ladder on golden from a clean POR. **None of the four candidate pokes restores
delivery.** What was actually measured (this supersedes the ranking in §11c):

| stage | applied | result |
|---|---|---|
| 0 baseline | plain deploy | **`EPOCH anchored=1` on BOTH dies** (contradicts the earlier v0 read of 0 — the anchor is NOT the blocker), fcsm=4/cal=1/cr_seen=1. Send **returns OK**, nothing commits |
| 1 | v39 recipe (hold/lockthresh/**wpauto**/arm/staggered freeze) | wpauto+freeze applied cleanly (`slot0=2`); **delivery still FAIL** |
| 2 | pair-credit **seed** (`0x2020=4096` ⇒ `0x028` 0→4096, both dies) | **delivery still FAIL** — and the send now AHB-ERRORs (see below) |
| 3 | **`to_data_mode`** (R8→0, `0x208` triplet) | `WL208` was **already `0x00027f07` BEFORE the triplet** (LL already enabled ⇒ this step was already satisfied by POR/autoneg); **delivery still FAIL** |

🔑 **The sharper finding (redirects the whole investigation): the TX path stalls in the FC
adapter, and the RX never commits — this is not a missing-poke problem.** After stage 1 the
AHB_TX write stopped returning and the board's kernel log shows
`Unhandled fault: external abort on non-linefetch … at <TX aperture>` — that is the
fc_adapter's deliberate `TX_STALL_TIMEOUT` (2^16 hclk ≈ 14 ms) backstop firing and answering
the beat with an **AHB ERROR**, i.e. **`tl_fc_a2l_ready` never asserts — the Wlink FC node
never accepts the app word** (while `fe_full=0`, `fcsm=4`, `cr_seen=1`, `a2l_valid=1`).
So the data path is blocked at the **FC-node accept / CR-credit handshake**, one layer below
everything the ladder was poking.

**Next investigation (not a bring-up recipe — an FC-node question):**
1. `unjam_fc_node.sh` — purpose-built for a wedged FC node; run its CLASSIC/HELD-REPLAY
   matrix and the `0x208` cycle against this exact state.
2. Read the FC node's own credit/enable state (Wlink region `0x4403_0xxx`, `fe_tx_credit_max`
   — cf. [[project_a2b_rootcause_fe_tx_credit_max_2026_07_09]]: "`fe_tx_credit_max` re-zeroed
   by a post-CR `swi_enable` dip" is the known mechanism for exactly this signature).
3. Compare against the KR260 on-chip pair, where the same RTL lineage DOES deliver — diff the
   FC-node config words, not the PHY/deskew ones.

⚠ **Session hygiene note:** stage 1's freeze took the TX from "returns, nothing lands" to
"AHB-ERRORs"; a power-cycle + golden redeploy restored the stage-0 baseline exactly
(verified). Always restore before handing the rig on.

**Ready-to-run staged repro:** `pynq_host/scripts/tl_z2_data_bringup_repro.sh` (mapstone-dev
side; preconditions in its header: leases GRANTED, POR + deploy both, `~/tl39.sh` pointing at
die_b=**.2.101**, `/tmp/ldp_v0.sh` staged). It applies stages 1→1b→2→3 with a delivery proof
after each and stops at the first PASS — that stage is the missing step to encode into the
campaign's deploy phase (and into the GUI orchestrator's bring-up).
- **Role readback polarity differs between images from clean POR** (golden: die_a `cfg=1`;
  v0: die_a `cfg=0`; complementary on both) — a real post-golden RTL delta; account for it
  in `regmap.py` role decode rather than assuming golden semantics.
- ⚠ **Never deploy without a power-cycle:** role-lock state lives in a POR-only reset domain
  that SURVIVES PL reconfiguration — a warm redeploy of the golden came up with roles
  INVERTED vs its own fresh-POR behavior. Mechanism now observed directly; the
  power-cycle → deploy-both → bring-up → test order is mandatory per repeat.
- The farm gate's silicon-tier advisory (`test_03_packet_slave_to_master` undelivered) should
  be treated as a live lead until the bring-up question is closed — consider
  `FARM_GATE_STRESS=1` for campaign builds once golden-recipe delivery is re-established.
- **Rig state at hand-off: golden on both dies from clean POR, link trained (fcsm=4/cal=1,
  no overrun), leases released.** v0 artifacts remain staged at
  `~/tidelink_artefacts/tl-tp-v0-baseline/` — redeploy + delivery re-test once the bring-up
  step is found.

## 12. Definition of done

1. `--fake` demo: monitor page live with two fake dies, run controls working, all tests green.
2. Real-hardware Phase A: monitor running against the golden Z2 pair under lease, showing
   fcsm=4/cal=1 both dies, credit gauges moving during a gated soak, zero non-whitelisted
   reads (agent asserts), zero sticky overruns caused by the GUI.
3. Phase B (if image rebuilt): utilization/stall/starve gauges live, the ~17%-utilization
   finding reproduced on screen, byte-exact delivery re-proven after deploy.
4. Benchmarking: version registry resolving tags from deployed manifests; the W1–W5 suite
   runnable end-to-end in `--fake` (two synthetic "versions" with different modeled capacity
   produce a correct comparison graph); on hardware, `tl-tp-v0-baseline` benchmarked with ≥3
   repeats and its medians matching the §6 sanity anchors; comparison + improvement graphs
   rendering with median/whiskers and the busref control alongside.
5. Nothing in the existing throughput/eye/stress toolkits regressed; existing pytest suite green.
