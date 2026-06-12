# TideLink Hardware Characterization Test Plan — 2026-06-12

**Status:** PLAN (not yet executed). Branch context: `feat/phy-v2-integration`.
**Scope:** throughput / latency / backpressure / robustness characterization of the
TideLink chiplet link on the bridge1 rig (z2_02 ↔ z2_03), plus the **SRAM-size
sweep** experiment that maps FIFO depth → sustained throughput.

**Companion docs:** `docs/BOARD_DEPLOY_RUNBOOK.md` (deploy mechanics + failure
modes — read it first, every §7 failure mode was hit for real),
`docs/REGISTER_MAP.md`, `pynq_host/scripts/hwtest/` (baseline functional suite).

---

## 0. Platform state and what is runnable TODAY

| System | State (2026-06-12) | Characterizable? |
|---|---|---|
| **V1 (v33 image, commit e2fefd4 era)** | Bilateral LINK_IDLE + M→S data byte-perfect, reproduced 3×. S→M app-path historically buggy → needs a smoke re-check. | **YES — this is the system under test today.** |
| **V2 (new PHY, v37)** | One known defect from working: cross-lane word-EPOCH deskew missing in `deps/tidelink-phy` (see `docs/V37_FINAL_DIAGNOSIS_2026_06_12.md`). No data path yet. | NO data tests. Only T7 (bring-up time) is meaningful on V2 today. |

Two practical image variants are referenced below:

- **`v1-base`** = the proven v33 pair images (already in `~/tidelink_artefacts/` on
  mapstone-dev). Runs T1, T4, T5, T7, T8 immediately.
- **`v1-char`** = a fresh V1-lineage build from a branch that adds the post-v33
  safety/measurement fixes that the characterization needs:
  - fc_adapter `TX_STALL_TIMEOUT_LOG2=16` bounded-ERROR conversion (`4c0a51a`,
    landed on this branch — **verify it is present in whatever V1 tree is built**;
    v33 itself pre-dates it). Required for T6 (wedge boundary) and strongly
    recommended for T2/T3.
  - `tidelink_perf.sv` Regions 5–7 (verify `PERF_ID @ 0x440320FC == 0x5046_0100`
    on the deployed image before trusting any counter — hwtest 11a does this).
  - This is also the image lineage the SRAM sweep (§5) builds from.

**Gate for everything:** integrated paired-die cocotb sim MUST pass before any
farm build kicks (standing policy — a sim-discoverable bug once burned 75 min
of farm+deploy time).

---

## 1. Ground rules — hazards and gates every test MUST respect

These are bench-confirmed failure modes, not theory.

1. **AHB_TX on a stalled link wedges the board.** A premature write to the
   AHB_TX aperture (`0x4400_0000`) with the link down historically required a
   *physical power cycle* (bench-confirmed 2026-04-27, z2_02). The
   `TX_STALL_TIMEOUT` fix converts this into a bounded AHB ERROR (~65 536 hclk
   cycles: 1.3 ms @ 50 MHz, 10.5 ms @ 6.25 MHz) — but **still gate every AHB_TX
   sequence** with the link check, and wrap every potentially-stalling write in
   `timeout(1)` host-side (the hwtest `ahb_tx_write_timed` pattern,
   `05_ahb_tx_storm.sh`).
2. **Criterion-B link-up gate** (post-M12, data mode): `cal_done=1` on BOTH
   sides AND FCSM ∈ {4 (LINK_IDLE), 5 (LINK_DATA)} on both sides, decoded from
   `SWI_LANE_STATUS @ 0x4403_2108` ([16]=cal_done, [20:17]=fcsm).
   **`lane_locked[7:0]=0` after training drops is EXPECTED** — do not gate on
   lane lock in data mode. Use `tt_verify_link_up` from
   `pynq_host/scripts/hwtest/lib/lib_hwtest.sh` (already implements A/B).
3. **Doorbell replay amplification (residual #7).** One write to your OWN
   `0x4403_2014` sends one doorbell (carrying your credit count) to the peer,
   where it saturating-ADDs into the peer's `DOORBELL_RESPONSE_ACC @
   0x4403_2024` (read-to-clear). Wlink replay is non-idempotent at RX: a single
   ring deposits **3–5 duplicate copies**. Consequences for test design:
   - NEVER use RESP_ACC *magnitude* as a count oracle. Use it as an
     **arrival edge detector**: read-to-clear, ring, poll-until-nonzero.
   - Rate sweeps must quiesce (read-clear + settle) between ramp steps and
     report the measured amplification factor as a *result*, not noise.
4. **AHB ERROR responses reach the ARM as bus aborts.** When
   `TX_STALL_TIMEOUT` fires, the fc_adapter returns AHB ERROR → propagates as
   AXI SLVERR to the Zynq PS → a python `/dev/mem` mmap access can take
   **SIGBUS**. T6 must run its poking loop in a child process (or trap SIGBUS)
   so one ERROR doesn't kill the measurement harness. Check the sticky
   `STATUS.MASTER_ERROR` (`0x4403_2010` bit[3]) after each step.
5. **Access path:** boards reachable ONLY via `ssh david@mapstone-dev` →
   `sshpass -p xilinx ssh xilinx@192.168.4.101` (z2_02/master) /
   `192.168.6.101` (z2_03/slave). No `devmem` binary on the boards — all
   register access is python3 `/dev/mem` mmap (see `tl37.py` `rd`/`wr` and the
   `lib_hwtest.sh` embedded-python helpers). **fpgahub lease must be GRANTED,
   not queued**, before any deploy.
6. **hclk is build-dependent.** Current branch targets run hclk/AHB/APB at
   **6.25 MHz** (`CLKOUT1_REQUESTED_OUT_FREQ {6.250}` in
   `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`); v33-era images ran
   50 MHz. Every conversion from perf-counter cycles to seconds MUST use the
   f_hclk recorded for the *deployed* image (put it in the manifest label).
7. **Don't run measurement loops over ssh.** ssh round-trips are 10–100 ms
   with jitter; all timed loops run ON the PYNQ ARM (see §3.3).

---

## 2. Measurement infrastructure available in hardware TODAY

### 2.1 Perf counter block (`src/rtl/tidelink_perf.sv`, APB Regions 5–7)

All addresses absolute (APB base `0x4403_2000`). All counters saturate (no
wrap). Verified register-by-register by `hwtest/11_perf_counters.sh`.

| Addr | Name | Semantics |
|---|---|---|
| 0x440320A0 | PERF_CTRL | [0] enable, [1] **freeze** (atomic snapshot), [2] W1P clear counters, [3] W1P clear ts-valids, [4] irq_en |
| 0x440320B0/B4 | TX_START_NS/SEC | PHC timestamp of first FC data word after `tx_pkt_start` |
| 0x440320B8/BC | RX_FIRST_NS/SEC | PHC timestamp of first RX data word |
| 0x440320C0/C4 | RX_DONE_NS/SEC | PHC timestamp of packet-committed edge |
| 0x440320C8 | TX_PKT_COUNT | packets started (one per AHB_TX aperture addr-0 write) |
| 0x440320CC | RX_PKT_COUNT | packets committed into RX FIFO |
| 0x440320D0 | TX_WORD_COUNT | FC TX data-word handshakes |
| 0x440320D4 | RX_WORD_COUNT | FC RX data-word handshakes |
| 0x440320D8 | TX_STALL_COUNT | cycles `fc_tx_valid && !fc_tx_ready` |
| 0x440320DC | RX_STALL_COUNT | cycles `fc_rx_valid && !fc_rx_accept` |
| 0x440320E0 | LINK_BUSY_COUNT | cycles TX router not idle |
| 0x440320E4 | **CREDIT_STARVE_COUNT** | cycles `credit_count==0` (peer FIFO full) — the key starvation metric |
| 0x440320E8 | **SAMPLE_COUNT** | +1 every enabled cycle — the **hardware timebase** for all rates |
| 0x440320F0/F4 | TX/RX_INFLIGHT | 16-bit live in-flight word trackers |
| 0x440320F8 | PERF_CONG_STATE | EWMA congestion estimator ([12:0] ewma, [17:16] level, [20] starve-sticky) |
| 0x440320FC | PERF_ID | `0x5046_0100` — presence gate |

**Atomic snapshot recipe (use everywhere):** set PERF_CTRL[1] (freeze) → read
all counters → clear PERF_CTRL[1]. This removes ssh/mmap read-skew from every
multi-counter ratio. Rates: `rate = Δcount / ΔSAMPLE_COUNT × f_hclk`.

### 2.2 Credit/flow-control observability (Region 0)

| Addr | Name | Semantics |
|---|---|---|
| 0x44032004 | RELEASE_THRESHOLD | RW, default 20 words; batch size for credit release (0 = release per read) |
| 0x44032008 | PACKET_WORD_LENGTH | RO, current packet length from FIFO ctrl |
| 0x4403200C | CREDIT_COUNT | RO, **local RX-FIFO free credits**; resets to MAX_CREDITS = `1<<(RAM_ADDR_W-2)` (4096 @ AW=14) |
| 0x44032010 | STATUS | sticky: [1] OVERRUN, [2] UNDERRUN, [3] MASTER_ERROR, [4] PACKET_COMMITTED |
| 0x44032014 | DOORBELL (W) / ID `0x544C_0100` (R) | write = ring peer (carries own credit count) |
| 0x44032018 | RELEASE_ACC | RO debug: credits freed but below threshold (not yet released) |
| 0x44032020 | RELEASED_CREDITS_ACC | W-add/R-clear: credit-release notifications from peer |
| 0x44032024 | DOORBELL_RESPONSE_ACC | W-add/R-clear: doorbell arrivals from peer (×3–5 amplified) |
| 0x44032028 | PAIR_CREDIT_COUNTER | RO, running estimate of **peer's** available credits — the sender-side starvation view |
| 0x44032108 | SWI_LANE_STATUS | [7:0] lock, [16] cal_done, [20:17] FCSM, [30] a2l_fc_replay_link_valid, [31] fe_rx_is_full |
| 0x44032114 | SYNC/ECC | [31:16] sync_detected_cnt, [15:0] ecc_corrupted_cnt |

Data apertures: **AHB_TX `0x4400_0000`** (16 KB; write at aperture base
starts a packet — `tx_pkt_start`), **local RX FIFO `0x4401_0000`** (16 KB;
reads drain and free credits), peer APB aperture via `0x4000_0000` (ahb_sub).
**Address-map trap (cost ~12 h once):** `0x4401_0000` is the LOCAL RX FIFO,
not the peer.

### 2.3 What does NOT exist (must be host-side)

No HW interval timers besides SAMPLE_COUNT; no latency histograms; no
automated throughput tool. One-way latency via the PHC timestamp registers
requires synchronized PHCs on both dies (PTP Phase-1) — treat one-way numbers
as **V2/PTP-gated**; everything in this plan uses RTT or single-die deltas.

---

## 3. Metrics collection mechanics

### 3.1 Principle: measure on-board, orchestrate from outside

Every timed loop runs as a python3 script **on the PYNQ ARM** (`/dev/mem`
mmap, `time.monotonic_ns()` around mmap ops — sub-µs resolution, a single
32-bit mmap read costs ~1–3 µs). Orchestration (deploy, parameter setting,
start/stop, collection) runs from mapstone-dev over ssh. Results are written
as CSV to `/home/xilinx/char_results/` on each board and pulled afterwards
with the tar-over-ssh pipe (plain scp/rsync between the dev hosts is broken —
runbook §3).

### 3.2 New tooling to write (Phase 0 deliverable)

- `pynq_host/scripts/char/tlchar.py` — on-board library: `rd/wr` (lift from
  `tl37.py`), `perf_snapshot()` (freeze→read-all→unfreeze→dict),
  `send_packet(n_words)` (AHB_TX burst: header write at aperture base then
  payload words, the v33-proven pattern — hdr `0x0024_0000`-style with length
  field, payload `0xDA7Axxxx`), `drain_rx(n_words)`, `ring_doorbell()`,
  `wait_resp_acc(timeout)`, CSV writer. SIGBUS-safe write variant (fork or
  ctypes sigaction) for T6.
- `pynq_host/scripts/char/responder.py` — doorbell ping-pong responder daemon
  (poll own RESP_ACC, ring back immediately) + paced RX-FIFO drainer
  (`--drain-rate words/s`) for T5/T6.
- `pynq_host/scripts/char/run_char.sh` — mapstone-dev orchestrator: criterion-B
  gate (reuse `lib_hwtest.sh`), push scripts, run a named test with params,
  pull CSVs into `~/tidelink_artefacts/char/<image-label>/`.

### 3.3 Per-run metadata (every CSV header)

image label + sha256 (from `tidelink.bin.manifest.json`), commit, RAM_ADDR_W,
f_hclk, link rate, release_threshold, criterion-B snapshot before/after,
sticky STATUS bits after, PERF_ID readback.

---

## 4. TEST CATALOG

Conventions: M = z2_02 (master, 192.168.4.101), S = z2_03 (slave,
192.168.6.101). "Gate" = criterion-B on both sides + sticky-error check + perf
block presence. All tests clear counters (PERF_CTRL[2]) and STATUS stickies
first, snapshot via freeze after.

### T1 — M→S streaming throughput vs burst size  *(runnable today, v1-base)*

- **Measures:** sustained app-level words/s M→S as a function of packet
  payload size, against the credit ceiling.
- **Method:** for each burst size B ∈ {1, 4, 16, 64, 256, 1024, 3072} payload
  words (cap at MAX_CREDITS−2; credit cost per packet = B+2 header words):
  1. Gate. Clear counters both sides. S runs `responder.py --drain-rate max`
     (tight RX-FIFO read loop at `0x4401_0000`).
  2. M runs `tlchar.py stream --burst B --duration 10` : back-to-back
     `send_packet(B)` with a `timeout`-wrapped write loop; before each packet,
     spin until `PAIR_CREDIT_COUNTER (0x44032028) ≥ B+2` (sender-side credit
     gate — never push into a full peer).
  3. Freeze-snapshot both sides: throughput = ΔTX_WORD_COUNT /
     ΔSAMPLE_COUNT × f_hclk (M), cross-checked vs ΔRX_WORD_COUNT (S) and
     vs host wall-clock words/s. Record TX_STALL_COUNT, CREDIT_STARVE_COUNT,
     LINK_BUSY_COUNT duty cycles.
- **Expected:** rises with B (header amortization: efficiency ≈ B/(B+2) ×
  link ceiling), flattens at the link ceiling; raw 128-bit phy word rate ≈
  link_clk → ~4× 32-bit words per phy word minus LL framing. Small B
  dominated by per-packet cost; CREDIT_STARVE ≈ 0 at 16 KB FIFO.
- **Hazards:** AHB_TX wedge class (gate + timeout wrapper + credit gate);
  verify S `STATUS.OVERRUN=0` after; data integrity spot-check (S verifies
  payload pattern on a sampled subset, the v33 byte-perfect check).

### T2 — S→M streaming throughput vs burst size  *(today AFTER an S→M smoke; prefer v1-char)*

- Identical method with roles swapped (S writes its AHB_TX aperture, M
  drains).
- **Pre-gate:** one S→M single-packet smoke (the historical S→M app-path bug
  was sender-side submission, sim-reproduced and fixed; v33 silicon evidence
  is M→S only). If smoke fails, T2/T3 move behind a V1 fix build.
- **Expected:** symmetric with T1; any M↔S asymmetry is itself a finding
  (z2_02 is the historically skewed RX side).

### T3 — Bidirectional simultaneous throughput  *(after T1+T2 pass)*

- **Measures:** aggregate + per-direction throughput under full duplex;
  fairness; credit-path interference (credit-release packets share the link
  with opposing data).
- **Method:** start T1 and T2 loops simultaneously (synchronize start via a
  3-2-1 file-touch barrier over ssh, ±50 ms is fine for 10 s runs), B swept
  jointly {16, 256, 1024}. Snapshot all four counter sets.
- **Expected:** per-direction ≤ unidirectional ceiling; watch
  RX_STALL_COUNT and CONG_STATE level/trend both sides. Degradation >10–20 %
  vs unidirectional indicates credit-return packets competing with data.
- **Hazards:** both AHB_TX paths live at once — both senders need the
  credit gate; this is the closest legal approach to the historic Bug-A
  fe_rx_is_full chicken-and-egg wedge, so monitor `0x44032108[31]`
  (fe_rx_is_full) and `[30]` (replay_link_valid) each second; abort the run
  (stop senders, NOT a recal) if fe_rx_is_full sticks at 1. `unjam_fc_node.sh`
  is the recovery tool.

### T4 — Doorbell round-trip latency  *(runnable today, v1-base)*

- **Measures:** software-visible control-plane RTT: ring → peer arrival →
  ring-back → own RESP_ACC; plus the replay amplification factor.
- **Method (single):** S runs `responder.py` (poll own `0x44032024`
  read-to-clear at max rate; on nonzero, write own `0x44032014`). M:
  read-clear own RESP_ACC, `t0=monotonic_ns()`, write own `0x44032014`, poll
  own RESP_ACC until nonzero, `t1`. RTT = t1−t0 (minus measured poll
  granularity, ~2–5 µs). N=1000 pings, ≥10 ms quiesce gap, record full
  distribution + the summed ACC values (→ amplification factor per leg).
- **Method (rate sweep):** repeat at ping intervals {100 ms, 30 ms, 10 ms,
  3 ms, 1 ms}; stop descending when RESP_ACC stops returning to zero between
  pings (replay-amplified pile-up) — that interval is the doorbell saturation
  point. Report it; do NOT push past it (3–5× amplification means the link
  carries 3–5× your offered doorbell load).
- **Expected:** RTT O(10–100 µs) dominated by the two poll loops + link
  serialization at 6.25/25 MHz; amplification 3–5× confirming residual #7.
- **Hazards:** replay amplification (above); doorbell path is safe (no
  AHB_TX), making this the best *first* characterization on any new image.

### T5 — Credit-return latency  *(runnable today, v1-base)*

- **Measures:** time from RX-FIFO drain on the receiver to credit visibility
  at the sender (`PAIR_CREDIT_COUNTER` recovery), vs drain rate and
  RELEASE_THRESHOLD.
- **Method:** for threshold ∈ {0, 1, 20 (default), 64, 256} (write S
  `0x44032004`; ensure CTRL.LOCK bit[2] not set) × drain rate ∈ {max, 100 k,
  10 k, 1 k words/s}:
  1. M fills S's FIFO to ~75 % (credit-gated sends, then stop).
  2. M starts a 10 kHz sampler of own `PAIR_CREDIT_COUNTER` +
     `RELEASED_CREDITS_ACC` (read-clear) → timestamped CSV.
  3. S drains at the set rate (paced reads of `0x4401_0000`).
  4. Latency = time from S's k-th drained word (S-side timestamped) to M
     seeing the corresponding credit step; with unsynchronized clocks, report
     the **step lag distribution** = M-side inter-step delay minus expected
     batch period, plus the threshold-batching staircase shape.
- **Expected:** staircase steps of `release_threshold` words; latency floor =
  link RTT + FC packet time; threshold=0 gives per-read releases (highest
  credit-path load — watch LINK_BUSY on the S→M direction).
- **Hazards:** none beyond standard gates (drain reads are safe); restore
  threshold to 20 after.

### T6 — Backpressure-to-wedge boundary  *(REQUIRES v1-char: TX_STALL_TIMEOUT in image)*

- **Measures:** behaviour at and past credit exhaustion: where writes start
  stalling, stall duration, where AHB ERROR begins, and that the link
  *recovers* (the v33-era wedge converted to bounded error).
- **Method:**
  1. Gate. S drainer OFF. M streams credit-gated until
     `PAIR_CREDIT_COUNTER < B+2` (legal fill — measure achievable fill level
     vs CREDIT_COUNT on S).
  2. Cross the line deliberately: ONE un-gated `send_packet` in a SIGBUS-safe
     child process under `timeout 5`. Time the blocking write. Expect: write
     stalls ≈ 2^16 hclk (10.5 ms @ 6.25 MHz, 1.3 ms @ 50 MHz) then AHB ERROR
     → SIGBUS in child; parent records duration + `STATUS.MASTER_ERROR`
     (bit[3]) + TX_STALL_COUNT delta.
  3. Recovery: S drains fully; M re-runs T1@B=16 for 2 s; criterion-B
     re-check; sticky STATUS clear-and-verify. PASS = no recal needed, no
     power cycle.
  4. Boundary mapping: repeat step 2 at fill levels {90 %, 95 %, 99 %, 100 %}
     × burst {1, 16, 64} → matrix of (stall-only | ERROR) outcomes.
- **Expected:** ERRORs only when peer credits < packet need for longer than
  the timeout; recovery clean every time. Any non-recoverable outcome is a
  release-blocking bug.
- **Hazards:** THE wedge path. Mandatory: v1-char image (verified
  `TX_STALL_TIMEOUT` present), SIGBUS isolation, `timeout` wrapper, PS-side
  watchdog awareness (Bug-A L11 history), JTAG `rst -system` rescue path
  known (runbook §7.6), and schedule at end of a session (a wedge costs the
  rig). Never run on v1-base.

### T7 — Link bring-up time distribution  *(runnable today; ALSO the only V2-meaningful test)*

- **Measures:** deploy→criterion-B latency distribution and success rate over
  N trials.
- **Method:** N=30 cycles driven from mapstone-dev: `deploy_pair.sh` (or
  swreset-based retrain for the no-reflash variant) → poll both
  `SWI_LANE_STATUS` at 10 Hz → t_linkup = first criterion-B-true sample;
  record per-stage times (cal_done each side, FCSM=4 each side), retries
  (reuse `bringup_pair_converge.sh` convergence loop + its provenance
  banner), failures with full `tl37.py probe()` decode.
- **Expected (V1):** the v18-era baseline was 8/10 bilateral; M11/M12 fixes
  should beat that — target ≥ 28/30 with median t_linkup seconds-scale.
  **V2:** run the same harness to quantify training-lock (`lk=ff`) statistics
  under the wp5+thresh5+hold recipe even though data mode is blocked — this
  baselines the deskew fix.
- **Hazards:** fpgahub lease GRANTED (not queued) for the whole loop; do not
  interleave with anyone's ILA session; deploys are slow (~2–3 min/cycle) —
  this test owns the rig for ~1.5 h.

### T8 — Soak / error rate  *(runnable today, v1-base; extend 13_long_soak.sh)*

- **Measures:** long-horizon stability: ECC corruption rate, sync-loss,
  replay activity, counter monotonicity, credit-leak detection.
- **Method:** 8–24 h. Background load = T1@B=64 at 25 % duty (1 s on / 3 s
  off) + T4 ping every 10 s. Every 60 s, freeze-snapshot both sides + read
  `0x44032114` (sync/ecc counters), STATUS stickies, fe_rx_is_full,
  CREDIT_COUNT-at-idle (**credit-leak check: idle CREDIT_COUNT must return
  to exactly MAX_CREDITS — any monotonic sag is a leaked credit**), → CSV.
- **Expected:** ecc_corrupted_cnt static or ppm-rate; zero stickies; zero
  credit leak; no FCSM excursions out of {4,5}.
- **Hazards:** ssh session resilience (run under nohup on-board, orchestrator
  reattaches); lease duration; thermal drift across the ribbon overnight is a
  *finding*, not a failure.

**Runnable-today summary:** T1, T4, T5, T7, T8 on v1-base now. T2/T3 after a
one-packet S→M smoke (same day). T6 only on v1-char. Nothing except T7 on V2
until the deps/tidelink-phy epoch-deskew fix lands.

---

## 5. SRAM-SIZE SWEEP EXPERIMENT

**Question:** how small can the RX FIFO (and its credit pool) get before
sustained throughput collapses — i.e. where does the FIFO stop covering the
credit-return latency (bandwidth-delay product knee)? This directly sizes the
ASIC `rf_16k` macro choice for v2 silicon.

### 5.1 The parameter chain (verified in-tree, this branch)

Single knob, fully derived — **credits shrink automatically with the RAM**:

```
fpga/vivado_ip/tidelink_vivado_wrapper.v:45      parameter RAM_ADDR_W = 14   (exposed as IP CONFIG)
  └─ src/rtl/tidelink_top.sv:43                  parameter RAM_ADDR_W = 14
      └─ tidelink_fifo.sv:18 → tidelink_fifo_mem.sv:17
          ├─ tidelink_fifo_ctrl.sv:15            RAM_ADDR_W
          │     line 74:  localparam MAX_CREDITS = (1 << (RAM_ADDR_W - 2));   ← 4096 @ AW=14
          │     credit_count_r reset/flush value = MAX_CREDITS               ← auto-scales
          ├─ tidelink_sram.sv  (.AW(RAM_ADDR_W))                              ← the memory itself
          └─ tidelink_apb_regs.sv (.RAM_ADDR_W)   CREDIT_COUNT readback width ← auto-scales
```

- **FPGA memory implementation:** `src/rtl/fifo/fpga/tidelink_sram.sv` wraps
  `cmsdk_fpga_sram` (Arm CMSDK behavioural SRAM → Vivado infers BRAM), sized
  purely by `AW`. ASIC variant (`src/rtl/fifo/asic/`) instantiates the TSMC
  `rf_16k` macro — the sweep is FPGA-only; its *result* informs which ASIC
  macro to compile.
- **Credits derive from RAM_ADDR_W** (`MAX_CREDITS = 1<<(AW−2)`): nothing else
  to change in lockstep. Independent parameters that interact but need no RTL
  change: `RELEASE_THRESHOLD` (APB `0x44032004`, default 20 — SW-set per run)
  and packet header overhead (+2 words/packet).
- **Where to override per build:** the BD instantiation in each target's
  `tidelink_design.tcl` (e.g. `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`
  ~line 292) currently sets only `CONFIG.USE_IDELAY`; add
  `CONFIG.RAM_ADDR_W {<AW>}`. Cleanest mechanization: read an env var in the
  tcl (`TL_RAM_ADDR_W`, default 14) in BOTH `pynq-z2-pair-all` and
  `pynq-z2-pair-flip-all` targets, so one exported variable builds a matched
  pair. Note `package_ip` runs `check-wrapper-params` (`fpga/Makefile:184,190`)
  — packaging is unchanged (wrapper default stays 14), only the BD CONFIG
  varies, so the check stays green and ONE `package_ip` serves all sweep
  points.
- **Memory-map caveat:** `package_tidelink_ip.tcl:140-144` hard-codes the
  `ahb_tx`/`ahb_fifo` apertures at 16384 B. Leave them — at AW<14 the upper
  aperture aliases the physical RAM (address bits above AW−1 ignored). Test
  scripts must confine themselves to the first `1<<AW` bytes. Do NOT shrink
  the BD address segments (keeps the SW map identical across the sweep).
- **Manifest note:** `make_bitstream_manifest.sh` requires `--lock-min`
  (`expected_lock_min`, consumed by the `deploy_pair.sh` provenance guard).
  Use `--lock-min 8` (per-side criterion) and encode the sweep point in the
  label: `--label "swp-aw12-v1char-<commit>"`. The deploy guard is what saved
  us from the stale-bitstream incident (Bug #32) — with five near-identical
  images in flight, **never** deploy `--no-verify` during the sweep.
- Both per-die SRAMs (AHB_TX staging and RX FIFO, "same SRAM depth" per the
  packaging script) scale together; max single packet also shrinks — keep
  burst ≤ MAX_CREDITS−2 at each point.

### 5.2 Sweep points

| Point | RAM_ADDR_W | FIFO size | MAX_CREDITS (words) | Notes |
|---|---|---|---|---|
| P16K | 14 | 16 KB | 4096 | baseline = v1-char itself |
| P8K | 13 | 8 KB | 2048 | |
| P4K | 12 | 4 KB | 1024 | |
| P2K | 11 | 2 KB | 512 | expect first throughput sag at large B |
| P1K | 10 | 1 KB | 256 | knee expected here for mid B |
| P512 | 9 | 512 B | 128 | optional extension — only if P1K hasn't collapsed; guarantees the knee is bracketed |

Constraint check per point: default RELEASE_THRESHOLD=20 < MAX_CREDITS even
at P512; max burst at P512 = 126 payload words (drop larger B cells from the
matrix accordingly).

### 5.3 Build & deploy matrix

- **Build:** `cd fpga && TL_RAM_ADDR_W=<AW> make build_pair_concurrent`
  (`fpga/Makefile:281` — builds `pynq-z2-pair-all` + `pynq-z2-pair-flip-all`
  in parallel locally, **~22 min/pair-point** per the runbook). 5 points ≈
  2 h serial; halve by alternating `build_pair_farmed FARM_HOST=srv04936`
  (purge the srv04936 stale cache first — Bug N6 history). Sim-gate once
  (RTL is identical across points; optionally one cocotb run at AW=10 to
  prove the small-FIFO RTL corner).
- **Per point:** bit2bin both halves, manifest with sweep label, tar-pipe
  stage to `~/tidelink_artefacts/swp-awNN/` on mapstone-dev (runbook §3 — all
  four artefacts, `.hwh` files are NOT optional), `deploy_pair.sh --manifest`.
- **Build-sanity gate per point (cheap, decisive):** after deploy + link-up,
  read idle `CREDIT_COUNT @ 0x4403200C` on both boards — it MUST equal
  `1<<(AW−2)`. This proves the right image is loaded AND the credit pool
  scaled (catches a silently-ignored CONFIG override — the DEPTH_LOG(3)
  silent-revert class of bug).

### 5.4 Per-point test run (~35 min/point)

1. T7-lite: 3 bring-up cycles (link insensitivity to FIFO size expected —
   verify, don't assume).
2. **T1 + T2 full burst sweep** (the core data): B ∈ {1, 4, 16, 64, 256,
   1024, min(3072, MAX_CREDITS−2)} × thresholds {20, MAX_CREDITS/8}.
3. T5 at drain-rate=max and one paced rate (credit-return latency should be
   FIFO-size-invariant — its *coverage* by the FIFO is what changes).
4. T3 at B=64 (bidirectional stress at reduced cushion).
5. T6 boundary probe at 99 %/100 % fill (v1-char safety net) — does the
   smaller FIFO change stall-onset behaviour?
6. 10-min mini-soak with T1@B=64 25 % duty; CREDIT_STARVE duty cycle is the
   headline number.

### 5.5 Analysis — what the sweep yields

The model under test: sustained throughput saturates while
`MAX_CREDITS ≥ W_link × L_credit_return + B_packet` (FIFO covers the
bandwidth-delay product + one burst); below that, the sender idles in
credit-starve for a fraction of each release cycle and throughput degrades
toward `MAX_CREDITS / (MAX_CREDITS/W + L_cr)`. T5 measures `L_cr` directly;
the sweep should land the knee where the model predicts — disagreement
localizes hidden latency (e.g. release batching, doorbell/credit path
contention).

**Graphs to produce** (matplotlib from the pulled CSVs; one notebook in
`pynq_host/scripts/char/`):

1. **Throughput vs FIFO size, family of curves by burst size** (the headline
   knee plot; both directions; log-x FIFO size).
2. Throughput vs burst size, family by FIFO size (same data transposed —
   shows header-amortization vs credit ceiling separation).
3. **Latency CDFs:** doorbell RTT (T4) per image; T6 stall-duration
   distribution; T5 credit-step lag.
4. **Credit-starvation duty cycle** (`ΔCREDIT_STARVE/ΔSAMPLE`) vs drain rate
   and vs FIFO size — should transition 0→significant exactly at the knee.
5. T7 bring-up time histogram/ECDF per image (regression detector across
   the sweep).
6. Soak strip-chart: ecc/sync counters, idle-credit residue, stickies vs time.

---

## 6. Phased execution order

| Phase | Work | Needs rig? | Est. |
|---|---|---|---|
| **0. Tooling** | `tlchar.py`, `responder.py`, `run_char.sh`, CSV/plot scaffold; dry-run rd/wr paths against the currently-deployed image | light | 1 day |
| **1. Baseline on v1-base (today's silicon)** | T4 (first — safest), T7 (N=30), T1 burst sweep, T5; S→M smoke → T2, T3 if green; kick T8 overnight | yes | 1 day + overnight |
| **2. v1-char image** | Branch from V1 lineage + verify TX_STALL_TIMEOUT + perf block; sim-gate; `build_pair_concurrent`; re-run T1/T4 (no-regression vs Phase 1), then T6 wedge-boundary at end of session | build 22 min + rig ½ day | 1 day |
| **3. SRAM sweep** | §5: 5 (+1 optional) build points, pipelined build-while-testing (build P(n+1) during P(n)'s 35-min test run); P16K data = Phase 2 rerun | yes, ~½ day rig/3 points | 2 days |
| **4. Analysis** | Graphs §5.5, knee-vs-model writeup, ASIC FIFO-size recommendation, doc `HW_CHARACTERIZATION_RESULTS_*.md` | no | ½ day |
| **5. V2 follow-up (blocked)** | After the epoch-deskew fix: T7 on V2, then the full catalog re-run on V2 images — the catalog and sweep harness are image-agnostic by design | — | repeat ~Phases 1+3 |

Total to first complete dataset: **~5.5 working days**, of which ~2.5 need the
bridge1 lease. Standing rules throughout: fpgahub lease GRANTED before any
deploy; sim-gate before any farm build; manifest-verified deploys only.

---

## 7. Register quick-reference (absolute addresses)

```
0x44000000  AHB_TX aperture (write @ base = tx_pkt_start)   [WEDGE-CLASS: gate it]
0x44010000  LOCAL RX FIFO aperture (reads drain + free credits)
0x40000000  peer aperture (ahb_sub)
0x44032004  RELEASE_THRESHOLD (RW, default 20)
0x4403200C  CREDIT_COUNT       (RO, idle == 1<<(RAM_ADDR_W-2))
0x44032010  STATUS             (sticky [1]OVR [2]UND [3]MERR [4]PKT_COMMITTED)
0x44032014  DOORBELL (W) / ID 0x544C0100 (R)
0x44032018  RELEASE_ACC        (RO debug, sub-threshold freed credits)
0x44032020  RELEASED_CREDITS_ACC (R-clear)
0x44032024  DOORBELL_RESPONSE_ACC (R-clear, replay-amplified 3-5x)
0x44032028  PAIR_CREDIT_COUNTER (RO, peer credits — sender-side gate)
0x44032100  SWI_TRAINING_MODE
0x44032108  SWI_LANE_STATUS ([7:0]lk [16]cal [20:17]fcsm [30]replay_v [31]fe_full)
0x44032114  SYNC/ECC counters ([31:16] sync_det, [15:0] ecc_corrupt)
0x440320A0  PERF_CTRL ([0]en [1]freeze [2]W1P clear)
0x440320C8..DC  TX/RX PKT/WORD/STALL counters
0x440320E4  CREDIT_STARVE_COUNT      0x440320E8  SAMPLE_COUNT (timebase)
0x440320F8  PERF_CONG_STATE          0x440320FC  PERF_ID (0x50460100 gate)
```

*Plan author: characterization working doc, 2026-06-12. Not yet reviewed
against a live rig session — Phase 0 dry-run will shake out any register
semantics this doc got subtly wrong (update in place).*
