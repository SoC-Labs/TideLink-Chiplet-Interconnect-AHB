# TideLink HW Test Suite — `pynq_host/scripts/hwtest/`

A thorough, safety-aware hardware test suite for the TideLink chiplet
interconnect, runnable against the `bridge1` PYNQ-Z2 master/slave pair.

Organised as one orchestrator (`run_all.sh`) plus 13 per-category scripts.
Every script sources the common library at `lib/lib_hwtest.sh` which
implements the same safety-audited APB transport as the existing bringup
scripts (`bringup_pair_converge.sh`, `wlink_probe.sh`).

## Files

| File | Purpose |
|---|---|
| `run_all.sh` | Orchestrator — runs included categories, aggregates results, emits coverage matrix |
| `lib/lib_hwtest.sh` | Shared helpers (`tt_devmem_read/write`, `tt_verify_link_up`, `tt_gate_ahb_tx`, pass/fail accounting) |
| `01_wlink_layer.sh`     | Wlink layer — PHY-ID, lanes, ECC, lane-mask fault inj., retrain, reliability mini-sweep |
| `02_tidelink_top_regs.sh` | Region 0 top-system register sweep (RW round-trip, RO rejects, FLUSH self-clear) |
| `03_ahb_sub_e2e.sh`     | AHB SUB end-to-end through XHB500+Wlink+FC (safe path; local + peer-visible) |
| `04_ahb_mng_incoming.sh` | Slave-side credit/doorbell accumulator + PAIR_CREDIT_COUNTER under-flow guard |
| `05_ahb_tx_storm.sh`    | AHB TX (the wedge-hazard path) — **GATED** on `tt_gate_ahb_tx()` |
| `06_ahb_fifo.sh`        | FIFO behaviour: CURRENT_CREDITS, FLUSH, RELEASE_THRESHOLD, IRQ accumulators |
| `07_addr_translation.sh` | PAIR_BASE_ADDR round-trip + R4 CAM slot pokes |
| `08_ptp_basic.sh`       | PTP basic (R1 0x034/0x038/0x03C) |
| `09_ptp_hw_sync.sh`     | PTP HW sync (R2 0x040/0x044/0x048) — **GATED** on PHC image |
| `10_servo_mailbox.sh`   | Servo cfg (R2) + timestamp mailbox (R3) |
| `11_perf_counters.sh`   | R5/R6/R7 perf counter readability + delta-under-traffic |
| `12_chiplet_phyalign.sh` | R8 chiplet-extended (SWI_TRAINING_MODE/BIT_SLIP/LANE_STATUS/NEGO_*/PHY_ALIGN_ID) |
| `13_long_soak.sh`       | Multi-minute/hour mixed-ops endurance soak |
| `REG_INVENTORY.md`      | Authoritative register inventory: every reg the suite accesses |

## Usage

### Run the default safe subset (no AHB_TX, no soak)
```sh
# On mapstone-dev, after acquiring bridge1 lease and deploying the unified bins:
./pynq_host/scripts/hwtest/run_all.sh
```

### Run everything including AHB_TX storm (only after a known-good build is verified up)
```sh
HWTEST_INCLUDE=all ./pynq_host/scripts/hwtest/run_all.sh
```

### Run a single category
```sh
./pynq_host/scripts/hwtest/12_chiplet_phyalign.sh
```

### Long soak (overnight)
```sh
SOAK_SECS=28800 HWTEST_INCLUDE=13 ./pynq_host/scripts/hwtest/run_all.sh
```

### Acquire the bridge1 lease for me
```sh
HWTEST_ACQUIRE_LEASE=1 HWTEST_LEASE_TTL=3600 ./pynq_host/scripts/hwtest/run_all.sh
```

## Environment variables

| Var | Default | Used by | Purpose |
|---|---|---|---|
| `MASTER_IP` | `192.168.4.101` | all | bridge1 master board IP |
| `SLAVE_IP` | `192.168.6.101` | all | bridge1 slave board IP |
| `TIDELINK_BOARD_PASS` | `xilinx` | all | sshpass password for the boards |
| `ARTEFACTS` | `/tmp/tidelink_deploy` | (when calling deploy_pair via cat 1e) | bin staging dir |
| `HWTEST_LOGDIR` | `/tmp/tidelink_hwtest_logs` | run_all | per-category log dir |
| `HWTEST_INCLUDE` | `1,2,3,4,6,7,8,10,11,12` | run_all | comma-list of category numbers; or `all` / `safe` |
| `HWTEST_EXCLUDE` | `` | run_all | comma-list to drop after include |
| `HWTEST_BAIL_ON_FAIL` | `0` | run_all | stop at first category failure if 1 |
| `HWTEST_ACQUIRE_LEASE` | `0` | run_all | acquire bridge1 lease automatically if 1 |
| `HWTEST_LEASE_TTL` | `3600` | run_all | lease seconds when acquiring |
| `RUN_RELIABILITY` | `0` | cat 1 | enable reliability mini-sweep (heavy, re-deploys) |
| `MINI_SWEEP_N` | `5` | cat 1 | reliability sweep iterations |
| `RETRAIN_N` | `5` | cat 1 | retrain cycles |
| `AHB_SUB_BASE` | `0x44010000` | cat 3 | local AHB SUB aperture base |
| `AHB_SUB_NWORDS` | `64` | cat 3 | storm depth |
| `N_DBELL` | `8` | cat 4 | doorbell rings |
| `AHB_TX_BASE` | `0x44000000` | cat 5 | AHB_TX aperture base |
| `N_AHB_TX` | `16` | cat 5 | storm depth |
| `AHB_TX_TIMEOUT_S` | `5` | cat 5 | per-write timeout (wedge guard) |
| `PTP_SYNC_INTERVAL` | `0x0000C350` | cat 9 | HW_SYNC_INTERVAL value |
| `PTP_SOAK_SECS` | `60` | cat 9 | PTP soak duration |
| `SOAK_SECS` | `600` | cat 13 | long-soak duration |
| `SAMPLE_GAP_S` | `10` | cat 13 | soak sample period |
| `SOAK_FAIL_ON_DROP` | `1` | cat 13 | fail soak if any drop seen |

## Safety constraints (non-negotiable)

1. **AHB_TX (`0x4400_0000`) wedges the board** if the link isn't fully up.
   Bench-confirmed 2026-04-27 on z2_02 — physical power-cycle required.
   * `tt_gate_ahb_tx()` aborts cat 5 if the link is not 16/16 + cal_done.
   * Cat 5 wraps every AHB_TX write in `timeout AHB_TX_TIMEOUT_S` so a wedge
     does not block the host indefinitely.
2. **`ROLE_CFG.role_lock` (R4 0x080) is W1S, POR-only clear.** The suite
   never writes it — deploy_pair already sets it.
3. **`CTRL_LOCK` (R0 0x01C bit[2]) is write-once.** The suite reads it
   (cat 2b, 7b) but never sets it.
4. **`SWI_PHASE_OFFSET` (R8 0x118) is latched at role_lock.** Cat 12f reads
   it; we never write it.
5. **Lane mask (`0x4403_0214`)** writes in cat 1f restore the original on
   exit via `trap restore_mask EXIT`.

## Runtime estimates

| Category | Approx. time | Notes |
|---|---|---|
| 1 (default `RUN_RELIABILITY=0`) | ~30 s | 1e skipped |
| 1 (`RUN_RELIABILITY=1, MINI_SWEEP_N=5`) | ~5 min | 5 re-deploys |
| 2 | ~20 s | per-board reg sweep |
| 3 | ~1 min | AHB_SUB N-word storm × 2 boards |
| 4 | ~15 s | doorbell + credit observation |
| 5 (default `N_AHB_TX=16`) | ~15 s | AHB_TX storm |
| 6 | ~15 s | FIFO RW |
| 7 | ~30 s | PAIR_BASE + CAM round-trips |
| 8 | ~15 s | PTP basic |
| 9 (default `PTP_SOAK_SECS=60`) | ~1.5 min | gated; skips if no PHC |
| 10 | ~30 s | servo + mailbox |
| 11 | ~30 s | perf snapshot + delta |
| 12 | ~30 s | R8 sweep |
| 13 (default `SOAK_SECS=600`) | 10 min | mixed-ops soak |
| **Default run (1,2,3,4,6,7,8,10,11,12)** | **~4 min** | Safe subset |
| **`all` run** | **~15 min** | Includes 5,9,13 |

## Pre-requisites

1. The bridge1 lease must be **granted** (not queued). Either acquire via
   `HWTEST_ACQUIRE_LEASE=1` or do it yourself first.
2. Staged bins at `/tmp/tidelink_deploy/{tidelink.bin,tidelink-flip.bin}`
   if running cat 1e (`RUN_RELIABILITY=1`).
3. Bitstream loaded on both boards with `role_lock=1` (i.e. `deploy_pair.sh`
   already run). Use `bringup_pair_converge.sh` to bring the link up first.
4. `mapstone-dev` reachable from the runner (used as ssh ProxyJump).
5. `sshpass`, `python3` on the boards (PYNQ image default).

## What this suite does NOT cover

* **Build / synthesis** — see `make` targets and CI build jobs.
* **Simulation** — see `cocotb/` + `uvm/`.
* **PHC integration** (cat 9) is **gated**; the PHC image is in development
  in the sibling worktree `~/SoCLabs/td-phc-dev`.
* **Bit-stress on RF SRAMs** — separate cocotb bench, no HW path yet.
* **Thermal characterisation** — soak (cat 13) catches functional drift but
  doesn't read on-die temp (no sensor exposed).

## Adding a new category

1. Create `NN_descriptive_name.sh`. Source `lib/lib_hwtest.sh`.
2. Use `tt_pass`/`tt_fail`/`tt_skip`/`tt_assert_eq`/etc. for outcomes.
3. End with `tt_summary`. Return its exit code (the `set -u` at top means
   the script exits with `tt_summary`'s rc by default if it's the last call).
4. Register in `run_all.sh`'s `CATEGORIES` array.
5. Document the new category in `REG_INVENTORY.md` and this README.
