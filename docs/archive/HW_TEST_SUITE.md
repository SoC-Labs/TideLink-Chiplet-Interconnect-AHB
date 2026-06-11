# TideLink HW Test Suite — Design Document

Generated 2026-05-23 on `feat/hw-test-suite` (isolation worktree
`~/SoCLabs/td-hwtest-dev`).

Companion to:
- `pynq_host/scripts/hwtest/README.md` — usage + env vars
- `pynq_host/scripts/hwtest/REG_INVENTORY.md` — register coverage
- `docs/archive/OUTSTANDING_WORK_REPORT.md` §3 — HW stress program scoping
- `docs/PTP_PROTOCOL.md` — PTP single-phase protocol (HW sync side)
- `src/rtl/fifo/tidelink_apb_regs.sv` — authoritative APB reg map

## 1. Design goals

1. **Cover every accessible facet** of the TideLink link + every accessible
   register + every functional path that can be exercised from the PS via APB
   (and, when gated, via AHB_TX).
2. **Safe by construction.** Every write that could wedge the board is
   guarded by a hard gate (`tt_gate_ahb_tx()`) that refuses to proceed unless
   the link is verified 16/16 + cal_done. Wedge-class writes are also wrapped
   in `timeout` so a wedge cannot block the host.
3. **Reuses safety-audited transport.** Every APB read/write goes through the
   exact `/dev/mem` mmap-from-Python pattern used by the existing
   `wlink_probe.sh` and `bringup_pair_converge.sh`. There is **no new
   transport** — we don't load PYNQ overlays, we don't use `mmap` from
   user-space Python on the host, we don't use `pynqmmio` shims.
4. **Pass/fail + measurable metrics.** Every sub-test emits PASS / FAIL /
   SKIP via the shared library; the orchestrator emits a coverage matrix.
5. **Lease-aware.** Can optionally acquire + release the `bridge1` lease
   itself; otherwise expects the caller to have it.
6. **Isolated from main.** Lives under
   `pynq_host/scripts/hwtest/`; no existing script is touched.

## 2. Architecture

```
                            ┌────────────────────┐
                            │     run_all.sh     │  orchestrator
                            │  (cat selection,   │
                            │   lease, matrix)   │
                            └─────────┬──────────┘
                                      │
              ┌──────────┬────────────┼────────────┬──────────┐
              ▼          ▼            ▼            ▼          ▼
            01_…       02_…    …   05_…  …    12_…       13_…
            wlink      top         ahb_tx       phyalign   soak
              │          │            │            │          │
              └──────────┴────────────┴────────────┴──────────┘
                                      │
                               ┌──────▼──────┐
                               │  lib_hwtest │  /dev/mem APB I/O,
                               │     .sh     │  tt_pass/fail,
                               └──────┬──────┘  tt_gate_ahb_tx
                                      │
                              sshpass + ssh to xilinx@{master,slave}
                              python3 -c '<embedded /dev/mem mmap>'
```

The `lib_hwtest.sh` library is the trust boundary: only it knows how to talk
to the boards. Category scripts must not introduce a new transport.

## 3. The 13 categories — rationale, method, pass criteria

### Cat 1 — Wlink layer

**Rationale.** Wlink is the link layer beneath TideLink; if it's not up,
everything downstream is meaningless. Exercises the per-lane PHY/byte-align/FC
plumbing.

**Method.** Six sub-tests:
* 1a `PHY_ALIGN_ID` identity — confirms R8 0x11C reads exactly `0x5041_0100`.
* 1b Lane-status snapshot — informational + assert 8/8 + cal_done=1.
* 1c FC channel header sanity — read 7 FC headers, expect non-FF / non-all-zero.
* 1d ECC counters at idle — R8 0x114; saturation = PHY/byte-align fail.
* 1e Reliability mini-sweep — opt-in; re-deploys both boards N times.
* 1f Lane-mask fault injection — mask one lane at a time on master TX,
  observe slave RX popcount degrade; restore mask on exit.
* 1g Retrain robustness — coordinated `slot0=0x3,0x1` cycle N times.

**Pass criteria.** All sub-tests pass; no spurious lane-drops in 1g; mask in
1f gives popcount ≤ 7 on the slave for every masked lane.

**Safety.** APB-only + lane-mask (restored via EXIT trap). No AHB_TX.

### Cat 2 — TideLink top-system regs (Region 0)

**Rationale.** Region 0 holds the config registers operators most often
poke (`PAIR_BASE_ADDR`, `RELEASE_THRESHOLD`, `CTRL`). Round-trip every RW;
verify every RO rejects writes; FLUSH self-clears.

**Method.** Eight sub-tests per board.

**Pass criteria.** `PAIR_BASE_ADDR` and `RELEASE_THRESHOLD` round-trip 4
trials each; FLUSH self-clears; STATUS sticky errors absent at idle.

**Safety.** APB-only. Restores `PAIR_BASE_ADDR` on exit.

### Cat 3 — AHB SUB end-to-end

**Rationale.** AHB SUB is the SAFE AHB datapath — local AHB writes go
through XHB500+Wlink+FC to the peer's AHB SUB slave and back. HREADY is
always locally returned, so a link-down state never wedges the host.

**Method.** Local AHB_SUB single-word + N-word storm on each board, then
the peer-visibility test (master writes, slave reads same offset).

**Pass criteria.** 100% data integrity local; peer-visibility passes if link
is up.

**Safety.** AHB_SUB is documented safe; no `tt_gate_ahb_tx()` needed.

### Cat 4 — AHB MNG incoming (slave-side accounting)

**Rationale.** Verifies that incoming traffic on the slave (doorbells from
the master, credit returns) is correctly accumulated and that the
counter-underflow guard (Bug #7 fix) works.

**Method.** Baseline-clear accumulators, ring N doorbells from master,
observe slave-side `DOORBELL_RESP_ACC` (Region 1 0x024); test
`PAIR_CREDIT_COUNTER` saturate-at-zero (write 0xFFFFFFFF to consume).

**Pass criteria.** `DOORBELL_RESP_ACC` in `[1, N_DBELL]`; read-clears to
0; PAIR counter saturates at 0.

**Safety.** APB + doorbell (safe path).

### Cat 5 — AHB TX (the wedge hazard)

**Rationale.** AHB TX writes go through the FC adapter; if the link is
down the FC adapter never asserts HREADY back, the AXI-Lite-to-AHB bridge
stalls, SmartConnect blocks, and the PS mmap write hangs in kernel space —
SSH dies, board needs physical power-cycle.

**Method.** **Mandatory gate** `tt_gate_ahb_tx()` — aborts unless 16/16 +
cal_done both sides. Then a bounded N-word storm wrapped in `timeout`. Final
re-verify-up + sticky-error sweep.

**Pass criteria.** No timeout; sticky errors clear post-storm; link still
16/16.

**Safety.** Two-layer: (a) `tt_gate_ahb_tx()` refuses to start without a
verified-up link; (b) every write wrapped in `timeout AHB_TX_TIMEOUT_S` so a
wedge cannot lock the testing host. On the first timeout, the script exits
immediately with rc=4; `run_all.sh` propagates that as a hard stop.

### Cat 6 — AHB FIFO

**Rationale.** Region 0 has the FIFO observability registers
(`CURRENT_CREDITS`, `STATUS`, `RELEASE_ACC`). Verifies idle state +
FLUSH + RELEASE_THRESHOLD round-trip + IRQ-accumulator clear-on-read.

**Method.** Six sub-tests per board.

**Pass criteria.** `CURRENT_CREDITS` near-full at idle; FLUSH clears sticky
errors + RELEASE_ACC; threshold round-trips; IRQ accumulators clear on read.

**Safety.** APB-only. The active overrun/underrun test would require AHB_TX
and is therefore not run here — it's covered by cat 5 as a sticky-error
side-check.

### Cat 7 — Address translation

**Rationale.** The address translator + `PAIR_BASE_ADDR` determines where
TX/credit/doorbell frames land on the peer. Mis-programming breaks every
downstream test. Includes Region 4 CAM-slot pokes (treated as opaque
storage — round-trip or RO behaviour, both acceptable; report which).

**Method.** Multi-value round-trip on `PAIR_BASE_ADDR`; CAM slot RW pokes
on R4 slots 1..7 (slot 0 is `ROLE_CFG`, never touched); restore at end.

**Pass criteria.** Round-trip pass; restore matches original.

### Cat 8 — PTP basic

**Rationale.** Region 1 0x034-0x03C is the pass-through to `tidelink_ptp`.
Verify the APB-side plumbing without initiating a sync.

**Method.** PTP_CTRL round-trip with values chosen to avoid known
arm/send bits; PTP_RX_PAYLOAD + PTP_STATUS RO sanity.

**Pass criteria.** Reads work; PTP_RX_PAYLOAD rejects writes.

### Cat 9 — PTP HW Sync (GATED on PHC image)

**Rationale.** Reference `docs/archive/PTP_HW_TEST_PLAN.md`. PHC integration is in
development in the sibling worktree `~/SoCLabs/td-phc-dev`. We detect PHC
presence by reading `HW_SYNC_STATUS` and skipping if it always reads 0xFF...

**Method.** HW_SYNC_CTRL/INTERVAL round-trip; enable for ~5s and observe
seq_num counter advance; servo telemetry sample; 60s soak.

**Pass criteria.** Seq_num advances under enable; `HW_SYNC_STATUS.active=1`
with sync enabled; no link drops in soak.

**Safety.** APB-only + sideband packets. Link must be 16/16 first.

### Cat 10 — Servo + mailbox

**Rationale.** Servo cfg (R2 0x04C-0x05C) passes through to the servo;
mailbox (R3 0x060-0x07C) is written by FC sideband on PTP transactions
and is RO from APB. Round-trip the servo, read the mailbox.

**Pass criteria.** Servo cfg either round-trips or is RO-stable
(build-dependent); mailbox slots readable.

### Cat 11 — Performance counters

**Rationale.** Regions 5/6/7 hold the `tidelink_perf` counters. Bug #23
(R7 truncation) caveat — if the build doesn't have the cb2cd26 fix, R7
DBG_LINK_STATUS will be wrong; we flag 0xFFFFFFFF as suspect.

**Method.** Snapshot 24 slots; induce light traffic (doorbell ring); 
snapshot again; report which slots advanced.

**Pass criteria.** All 24 readable; at least one slot advances under
traffic; R7 0x0E0 not 0xFFFFFFFF.

### Cat 12 — Chiplet ext (R8 PHY-align + I2C train)

**Rationale.** Region 8 (0x100-0x11C) is the PHY-alignment + I2C-training
register block. The most surface-exposed config block.

**Method.** Seven sub-tests per board: PHY_ALIGN_ID identity, SWI_BIT_SLIP_LO
round-trip, SWI_LANE_STATUS RO, NEGO_TRAIN_CFG round-trip, NEGO_TRAIN_STEP
pulse, SWI_PHASE_OFFSET read-only (do not modify), SWI_TRAINING_MODE
round-trip with W1P-awareness.

**Pass criteria.** All round-trips work; PHY_ALIGN_ID exact; STEP doesn't
latch as 0x1.

### Cat 13 — Long soak

**Rationale.** Endurance test. Spots slow degradation: occasional lane
drops, sticky-error growth, ECC counter creep.

**Method.** N-tick loop sampling every `SAMPLE_GAP_S` seconds, with a
random-selection of 5 safe ops at each tick (version read, doorbell ring if
link up, RELEASE_THRESHOLD round-trip, pair-base read, BIT_SLIP read).
Counts drops + sticky events.

**Pass criteria.** 0 drops, 0 sticky events over `SOAK_SECS` (default
600 s; bump to 28800 for an 8h run).

**Safety.** Safe-ops only.

## 4. Coverage matrix (what's exercised vs not)

| Register / mechanism | Region/Offset | Exercised by | Covered? |
|---|---|---|---|
| PAIR_BASE_ADDR | R0 0x000 | cat 2c, 7a | ✅ RW round-trip + restore |
| RELEASE_THRESHOLD | R0 0x004 | cat 2d, 6c | ✅ multi-value RW |
| PACKET_WORD_LENGTH | R0 0x008 | cat 2e (RO) | ✅ RO confirmed |
| CURRENT_CREDITS | R0 0x00C | cat 4e, 6a | ✅ value sanity + idle-near-full |
| STATUS | R0 0x010 | cat 2g, 6b, 6e | ✅ sticky-error tracking |
| DOORBELL/VERSION | R0 0x014 | cat 2a, 2h | ✅ version ID + doorbell ring |
| RELEASE_ACC | R0 0x018 | cat 6b | ✅ FLUSH clears |
| CTRL (FLUSH/LOCK) | R0 0x01C | cat 2b, 2f, 7b | ✅ FLUSH self-clear; LOCK read |
| RELEASED_CREDITS_ACC | R1 0x020 | cat 6d | ✅ clear-on-read |
| DOORBELL_RESP_ACC | R1 0x024 | cat 4b, 6d | ✅ accumulate + clear |
| PAIR_CREDIT_COUNTER | R1 0x028 | cat 4c | ✅ saturate-at-zero |
| PAIR_CREDIT_CONSUME | R1 0x02C | cat 4c | ✅ underflow saturate (Bug #7) |
| PAIR_CREDIT_COUNTER_EN | R1 0x030 | cat 4d | ✅ enable toggle |
| PTP_CTRL | R1 0x034 | cat 8a | ✅ W1P-aware round-trip |
| PTP_RX_PAYLOAD | R1 0x038 | cat 8b | ✅ RO |
| PTP_STATUS | R1 0x03C | cat 8c | ✅ RO sanity |
| HW_SYNC_CTRL | R2 0x040 | cat 9a, 9d | ⚠️ Gated on PHC |
| HW_SYNC_INTERVAL | R2 0x044 | cat 9b | ⚠️ Gated on PHC |
| HW_SYNC_STATUS | R2 0x048 | cat 9c, 9d | ⚠️ Gated on PHC |
| Servo cfg | R2 0x04C-0x05C | cat 10a | ✅ round-trip or RO-stable |
| Servo status | R3 0x060-0x064 | cat 9e, 10b | ✅ readable |
| Mailbox | R3 0x068-0x07C | cat 10b, 10c | ✅ RO from APB |
| ROLE_CFG | R4 0x080 | (never touched) | ⛔ W1S role_lock — deploy_pair owns it |
| R4 slots 1..7 | R4 0x084-0x09C | cat 7c | ✅ RW round-trip / RO-stable |
| Perf TX | R5 0x0A0-0x0BC | cat 11a-c | ✅ delta under traffic |
| Perf RX | R6 0x0C0-0x0DC | cat 11a-c | ✅ delta under traffic |
| Perf debug | R7 0x0E0-0x0FC | cat 11d | ✅ Bug #23 sentinel |
| SWI_TRAINING_MODE | R8 0x100 | cat 12g | ✅ W1P-aware |
| SWI_BIT_SLIP_LO | R8 0x104 | cat 12b | ✅ RW round-trip |
| SWI_LANE_STATUS | R8 0x108 | cat 1b, 12c, all | ✅ RO + popcount decoded |
| NEGO_TRAIN_CFG | R8 0x10C | cat 12d | ✅ RW round-trip |
| NEGO_TRAIN_STATUS | R8 0x110 | (read by 12d via CFG cycle) | ✅ readable |
| NEGO_TRAIN_STEP | R8 0x114 | cat 12e | ✅ W1P + ECC counters |
| SWI_PHASE_OFFSET | R8 0x118 | cat 12f | ✅ read-only sanity |
| PHY_ALIGN_ID | R8 0x11C | cat 1a, 12a | ✅ exact match |
| Wlink LaneMask | WL 0x0214 | cat 1f | ✅ fault injection |
| Wlink FC headers | WL 0x1000-0x1700 | cat 1c | ✅ readable sanity |
| AHB_SUB | 0x4401_0000+ | cat 3 | ✅ local + peer-visible |
| AHB_TX | 0x4400_0000+ | cat 5 | ✅ GATED storm |
| Lane retrain | R8 slot0 | cat 1g | ✅ N cycles |
| Reliability | full deploy loop | cat 1e | ⚙️ opt-in |
| Long soak | full | cat 13 | ✅ multi-hour |

**Gaps (deferred):**
- **Thermal characterisation** — no on-die temp sensor exposed; would need
  IPMI/PMBus from the chassis.
- **Cocotb/UVM** — not in scope (sim-level).
- **PHC sync timing accuracy** — requires GPS reference; the suite verifies
  protocol mechanics but not the absolute offset bound.
- **Multi-pair stress** — bridge1 is a single pair; multi-board topologies
  not addressable here.

## 5. CI integration

A new `hwtest` stage is added to `.gitlab-ci.yml` (see snippet at end of
file). The job:
1. Runs on a runner that has `mapstone-dev` SSH access.
2. Acquires the `bridge1` lease via `fpgahub` (TTL 1 h).
3. Verifies the deployed bitstream matches a known-good manifest.
4. Runs `HWTEST_INCLUDE=safe ./pynq_host/scripts/hwtest/run_all.sh`.
5. Releases the lease on exit (trap).
6. Uploads `/tmp/tidelink_hwtest_logs` as an artifact.

The job is **manual / scheduled** — not on every push, to avoid lease
contention with bringup development. A nightly schedule + manual-trigger
button is the operating model.

## 6. Pre-conditions before running the full suite

1. The bridge1 lease must be granted (verify with `fpgahub pair lease show
   bridge1`).
2. The unified-main bitstream must be deployed + verified 16/16 via
   `bringup_pair_converge.sh`.
3. Categories 5, 9, 13 are the heavy ones: 5 needs a verified-up link,
   9 needs the PHC image, 13 is long.

## 7. Open items / next steps

* **Wire up cat 1e reliability sweep** — needs `RUN_RELIABILITY=1` +
  `DEPLOY_PAIR` set; currently opt-in.
* **Cat 9 PTP soak duration** — bump to 8 h once the PHC image is stable.
* **Cat 5 N_AHB_TX** — bump from 16 (smoke) to e.g. 1024 (sustained) once
  we trust the link.
* **AHB_SUB peer-visibility** (cat 3d) — depends on address-translator
  configuration; may need a per-build tweak.
* **Latency / throughput characterisation** — `tidelink_perf` already
  counts packets/bytes/retries; cat 11b detects deltas but doesn't compute
  BW. Add a quantitative cat 11e once cat 5 storm is reliable.
