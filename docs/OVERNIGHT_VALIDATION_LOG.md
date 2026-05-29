# Overnight HW Validation Loop — `feat/td-gpio-phy-integration`

**Started:** 2026-05-28 (evening session)
**Target:** PTP + AHB doorbell working in BOTH directions on pynq-z2 pair
**Authorization:** User granted permission to run builds, deploy via fpgahub, push RTL fixes, iterate autonomously until working

## Pin matrix at loop start

| Repo | Branch | HEAD |
|---|---|---|
| Parent | `feat/td-gpio-phy-integration` | `cbcba54` |
| `deps/tidelink-gpio-phy` | `main` | `d23a8cd` |
| `deps/axi-chiplet-controller` | `feat/td-gpio-phy-integration` | `c0a69ff` |

All three branches pushed to origin (verified via `git ls-remote`).

## Loop state machine

```
BUILD → LEASE → DEPLOY → BRINGUP → VALIDATE
                                       │
                                  pass: EXIT
                                  fail: DIAGNOSE → FIX → BUILD
```

Hard limit: bail out after iteration 8 (≈8 × 60min build = 8 hours) — user needs the report by morning.

## Iteration log

### Iteration 1 — kick-off

- **Phase:** BUILD
- **Build command:** `make -C fpga build_pair_farmed FARM_HOST=srv04936`
- **Build SHA:** `cbcba54`
- **Submodule pins:** `tidelink-gpio-phy@d23a8cd`, `axi-chiplet-controller@c0a69ff`
- **Expected duration:** ~50 min (master local + slave on srv04936, concurrent)
- **Output:** `/tmp/td_overnight_build_1.log`
- **Status:** *kicking off…*

#### Iteration 1 progress log

- **23:11:09** make build_pair_farmed started
- **23:11:53** package_ip OK
- **23:12:25** package_phc_ip OK
- **23:12:25** launched master `pynq-z2-pair-all@local` + slave `pynq-z2-pair-flip-all@srv04936` (concurrent)
- Vivado PID local: 383445 (running)
- Logs:
  - `/tmp/td_overnight_build_1.log` (driver)
  - `imp/fpga/run/farm/pynq-z2-pair-all@local.20260528-231109.log` (master)
  - `imp/fpga/run/farm/pynq-z2-pair-flip-all@srv04936.20260528-231109.log` (slave)
- Expected wall: ~50 min (pair-all + farmed slave, concurrent)
- Expected complete: ~24:00 BST

#### Parallel agents dispatched (23:11)

- **Agent B** — fix the 4 failing tidelink-gpio-phy cocotb tests (silent-pass make wrapper + hierarchical-force tests)
- **Agent C** — independent ASIC-readiness test gap assessment (write `docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md`)
- **Agent D** — Fusion Compiler GDSII iteration on TSMC65 (worktree `td-gpio-phy-fc2`, branch `feat/td-gpio-phy-fc2-build`)

#### Iteration 1 build complete + hardware blocker

- **00:17 BST** make build_pair_farmed PASS in 64m53s; both bitstreams produced (master `imp/fpga/output/pynq-z2-pair-all/tidelink.bit`, slave `imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit`); md5 master `ddf1bb6b...`, slave `b8303b92...`
- **00:22 BST** Bins converted to .bin + .hwh staged to `mapstone-dev:/tmp/tidelink_deploy/{tidelink.bin,tidelink-flip.bin}` with manifest sha256 / commit `925e6470` / label `feat/td-gpio-phy-integration`
- **00:25 BST** fpgahub pair lease acquire bridge1 + fpgahub pair up bridge1 — both members `held + attached` per fpgahub
- **00:26 BST** First convergence attempt fails: `board 192.168.4.101 unreachable over SSH (check lease GRANTED + board up)`
- **00:30 BST** Slave (`pynq-z2-03` at .6.101) SSH-reachable; master (`pynq-z2-02` at .4.101 / .3.101) all timeouts
- **00:33 BST** `fpgahub down/up pynq_z2_02_pl` returns `no devices to server for pynq_z2_02_pl` — the board's USB-IP devices are not visible to the fpgahub daemon
- **00:35 BST** **HARDWARE BLOCKER**: master board pynq_z2_02 is physically offline (powered off / USB disconnected / hub failure). bridge1 is the only configured pair. Bidirectional validation cannot proceed without master.

#### Decision

- Release the lease (no point holding hardware I can't use)
- Continue autonomous work on what IS actionable: FC2 GDSII (still running, ETA 01:10), FC2 RTL fix backport, morning summary preparation
- Surface the blocker as the top item in the morning report so the user can power-cycle / re-cable z2_02 and re-run from the staged bitstreams


#### FC2 Pipeline status (01:17 - 01:18)

- **01:17 BST** Wake-up check: FC2 `2_synthesis.log` last modified 00:36; no `fc_shell` / `fusion_compiler` processes running; no `.synth.done` sentinel. **Pipeline silently stalled / killed**.
- **Diagnostic**: 716GB disk free, 191GB mem available, no OOM in dmesg, no FC_STAGE_FAIL marker. Stall cause unknown.
- **01:18 BST** Restarted `make -C syn/asic/fusion-compiler fc MODULE=tidelink_top_full` in background (PID 651008 / fc_shell 651013). Output to `/tmp/td_fc2_restart_1.log`. Logs to `syn/asic/fusion-compiler/logs/`.
- **New ETA**: fc_synth ~60min (~02:18), chained cts→route→pg→signoff→drc→abstract ~60min more → GDSII landing ~03:18 BST.


#### FC2 progress at 03:01 BST

- **02:25 BST** `fc_synth` COMPLETE. `.synth.done` sentinel written. FC_STAGE_OK: synth. Elapsed 1.12 h, peak mem 2.1 GB. Outputs: `tidelink_top.synth.svf`.
- **02:25 BST** `fc_clock` (CTS) auto-started. fc_shell PID 690878 executing `3_clock.tcl`. Log at 2.4 MB (live).
- **03:01 BST** CTS 36 min in (vs ~26 min budget — slight overrun, acceptable). Output `tidelink_top.cts.svf` already written (preliminary).
- **Revised GDSII ETA**: ~03:48 BST (cts ~10 more min, route ~23, pg ~3, signoff ~1, drc ~5, gdsii ~30s)
