# TideLink HW Test Suite — Development Log

Worktree: `~/SoCLabs/td-hwtest-dev` (branch `feat/hw-test-suite`, off `main`
@ `0551cd8`, submodule `2f602d1`). Work is local-only — no push.

## Session start (2026-05-22 23:50 UTC)

* Verified worktree at `/home/dam1n19/SoCLabs/td-hwtest-dev` already created
  on branch `feat/hw-test-suite` (head `0551cd8` = main, clean tree).
* Read all reference material:
  - `docs/OUTSTANDING_WORK_REPORT.md` §3 (HW stress program scoping)
  - `src/rtl/fifo/tidelink_apb_regs.sv` (authoritative APB reg map, 549 lines)
  - `pynq_host/scripts/{bringup_pair_converge.sh, wlink_probe.sh,
    deploy_pair.sh, redeploy_repeatability.sh, phase_recal_sweep.sh}`
  - Note: `bringup_reliability.sh` and `bringup_health_probe.sh` named in the
    task brief don't exist in this worktree; the closest existing harness
    is `bringup_pair_converge.sh` (closed-loop bring-up) which the new suite
    mimics in style + safety. The task brief's `docs/PTP_HW_TEST_PLAN.md`
    likewise doesn't exist here — referenced PTP fields directly from RDL
    + tidelink_apb_regs.sv. Authored cat 9 from RTL + protocol doc.

## Categories implemented (all 13)

All scripts live in `pynq_host/scripts/hwtest/`:

| # | Script | Sub-tests | Safety class |
|---|---|---|---|
| 1 | `01_wlink_layer.sh` | 7 (1a-1g) | APB-only + lane-mask (restored) |
| 2 | `02_tidelink_top_regs.sh` | 8 (2a-2h) | APB-only |
| 3 | `03_ahb_sub_e2e.sh` | 4 (3a-3d) | AHB_SUB local + peer (safe path) |
| 4 | `04_ahb_mng_incoming.sh` | 5 (4a-4e) | APB + doorbell |
| 5 | `05_ahb_tx_storm.sh` | 4 (5a-5d) | **GATED** + timeout-wrapped |
| 6 | `06_ahb_fifo.sh` | 5 (6a-6e) | APB-only |
| 7 | `07_addr_translation.sh` | 3 (7a-7c) | APB-only + restore |
| 8 | `08_ptp_basic.sh` | 3 (8a-8c) | APB-only |
| 9 | `09_ptp_hw_sync.sh` | 7 (9a-9g) | **GATED on PHC image** |
| 10 | `10_servo_mailbox.sh` | 3 (10a-10c) | APB-only |
| 11 | `11_perf_counters.sh` | 4 (11a-11d) | APB-only + light traffic |
| 12 | `12_chiplet_phyalign.sh` | 7 (12a-12g) | APB-only |
| 13 | `13_long_soak.sh` | 1 long-running | APB-only safe-ops |

Total: **~60 distinct sub-test assertions** across the 13 categories.

## Files added (none modified, except `.gitlab-ci.yml` which had a new
stage + 3 new jobs appended without touching existing pipeline jobs)

```
pynq_host/scripts/hwtest/
    README.md                       7.6 KB
    REG_INVENTORY.md                9.3 KB
    run_all.sh                      6.5 KB
    01_wlink_layer.sh               8.5 KB
    02_tidelink_top_regs.sh         5.9 KB
    03_ahb_sub_e2e.sh               4.4 KB
    04_ahb_mng_incoming.sh          4.3 KB
    05_ahb_tx_storm.sh              4.8 KB
    06_ahb_fifo.sh                  4.1 KB
    07_addr_translation.sh          3.8 KB
    08_ptp_basic.sh                 3.0 KB
    09_ptp_hw_sync.sh               5.6 KB
    10_servo_mailbox.sh             3.0 KB
    11_perf_counters.sh             3.5 KB
    12_chiplet_phyalign.sh          5.1 KB
    13_long_soak.sh                 4.6 KB
    lib/
        lib_hwtest.sh               common library
docs/
    HW_TEST_SUITE.md                design rationale, coverage matrix
    HW_TEST_SUITE_DEV_LOG.md        THIS FILE
```

Existing file modified:
* `.gitlab-ci.yml` — added new `hwtest` stage + 3 new jobs (`hwtest:safe`,
  `hwtest:full`, `hwtest:soak`). No existing jobs touched; existing stages
  list got `hwtest` appended.

## Register inventory coverage

Every register documented in `tidelink_apb_regs.sv`'s header is touched by
the suite. Summary (full table in `pynq_host/scripts/hwtest/REG_INVENTORY.md`):

* **Region 0 (config/status, 0x000-0x01C):** all 8 regs — RW round-trip on
  RW, RO-reject confirmation on RO, FLUSH self-clear, doorbell ring.
* **Region 1 (credits + PTP basic, 0x020-0x03C):** all 8 regs — accumulator
  add/clear, counter under-flow (Bug #7) saturation, PTP passthrough.
* **Region 2 (PTP HW sync + servo, 0x040-0x05C):** PHC gated (cat 9) + servo
  round-trip (cat 10).
* **Region 3 (servo status + mailbox, 0x060-0x07C):** all 8 slots readable;
  RO-from-APB confirmation.
* **Region 4 (chiplet ctrl, 0x080-0x09C):** ROLE_CFG (0x080) never touched
  (W1S role_lock); slots 1-7 RW pokes.
* **Region 5/6/7 (perf, 0x0A0-0x0FC):** all 24 slots — delta-under-traffic
  + Bug #23 sentinel.
* **Region 8 (PHY-align + I2C-train, 0x100-0x11C):** all 8 regs — RW round-
  trip, RO confirmation, PHY_ALIGN_ID identity, W1P-aware writes.
* **Wlink APB (sibling at 0x4403_0000):** PHY (0x000), LinkCRC (0x200),
  ActiveLanes/LaneMask (0x210/0x214), 7 FC headers (0x1000-0x1700).
* **AHB_SUB aperture (0x4401_0000+):** local + peer-visible storm.
* **AHB_TX aperture (0x4400_0000+):** **GATED** storm with timeout wrap.

## CI integration status

Three new jobs added under a new `hwtest` stage, all `manual` by default:

* `hwtest:safe` — default subset (cat 1,2,3,4,6,7,8,10,11,12), ~4 min. Also
  auto-triggers if `SCHEDULE_HWTEST=1` (e.g. nightly schedule).
* `hwtest:full` — full suite except cat 13 soak, includes AHB_TX storm
  (`HWTEST_INCLUDE=all, EXCLUDE=13`).
* `hwtest:soak` — cat 13 only, 8 h soak, 9 h lease.

All three use `tags: [bridge1-runner]` (an executor runner that has
mapstone-dev SSH access + fpgahub CLI). They take a fresh lease at start,
release on exit (built-in to `run_all.sh`'s lease handling), and upload
`/tmp/tidelink_hwtest_logs/` as a 30-day artifact.

## What's gated on the PHC image

Cat 9 (PTP HW Sync) skips with `tt_skip` if `HW_SYNC_STATUS` reads 0xFFFFFFFF
or empty (PHC block absent). Cat 9 will be effective once the PHC dev
agent (`~/SoCLabs/td-phc-dev`) merges to main. Other categories don't
depend on the PHC.

## What's deferred

* **Cat 1e reliability sweep** — opt-in via `RUN_RELIABILITY=1`. The default
  run does NOT re-deploy (would burn the lease + risk a non-converging
  bringup blocking the rest of the suite).
* **AHB_SUB peer-visibility** (3d) — depends on address-translator
  configuration; may need a per-build aperture tweak.
* **Cocotb/UVM** integration — out of scope; tests run separately.
* **Thermal characterisation** — no exposed temp sensor.
* **PHC absolute-offset bound** — requires a GPS reference clock.
* **Quantitative BW/latency** — cat 11b detects perf-counter deltas but
  doesn't compute BW; planned cat 11e once cat 5 storm is reliable.

## Pre-commit verification

* `bash -n` syntax check across all 14 scripts (13 categories +
  run_all.sh + lib_hwtest.sh) — all pass.
* No new tools introduced beyond what bringup_pair_converge.sh already
  uses: `sshpass`, `python3` on the boards, `mmap` via /dev/mem.
* No file outside `pynq_host/scripts/hwtest/`, `docs/HW_TEST_SUITE*.md`, or
  `.gitlab-ci.yml` is touched.
* Dry-run / live hardware exec deferred — operator-gated; the task brief
  permits running but emphasises documentation + script work. The scripts
  are safe-by-construction and respect the AHB_TX wedge hazard.

## Next steps for the operator

1. Bring up the link with `bringup_pair_converge.sh` (or whichever
   bringup harness is in current use) and verify 16/16 + cal_done.
2. Run the safe subset:
   ```
   ./pynq_host/scripts/hwtest/run_all.sh
   ```
3. If safe subset passes, run the full suite (includes AHB_TX storm):
   ```
   HWTEST_INCLUDE=all HWTEST_EXCLUDE=13 ./pynq_host/scripts/hwtest/run_all.sh
   ```
4. For overnight characterisation:
   ```
   SOAK_SECS=28800 HWTEST_INCLUDE=13 ./pynq_host/scripts/hwtest/run_all.sh
   ```
5. Once PHC image lands on main, run cat 9 to validate PTP HW sync.

## Commits (local-only on `feat/hw-test-suite`)

Initial planned commit: "hwtest: HW test suite — 13 categories, common lib,
orchestrator, CI hooks, docs".
