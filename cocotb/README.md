# TideLink — cocotb test index

cocotb-based simulation suite for the TideLink chiplet-interconnect
subsystem. Each subdirectory is a self-contained test environment with
its own `Makefile`, `tb_top.sv` (or `tb_top` from a flist), and one or
more `test_*.py` files. The top-level `cocotb/Makefile` defines the
`ENVS` list that `make regression` walks.

## Quick-start

```sh
# Single env
cd cocotb/tidelink_fifo
make

# All envs (CI's cocotb-regression job)
cd cocotb
make regression
```

The CI invocation is `make -C cocotb regression`. Each env emits a
`run.log` + `.result` + `results.xml` under itself; coverage gets
collected into `cocotb/<env>/coverage.vdb` and aggregated into
`coverage_report/`.

## Environments

### Module / unit tests

| Env | Module under test | What it exercises |
|---|---|---|
| [`tidelink_fifo`](tidelink_fifo/) | `tidelink_fifo_mem` | FIFO mem + ctrl + APB regs together as the FIFO subsystem |
| [`tidelink_returner`](tidelink_returner/) | `tidelink_returner` | Credit-return AHB-master state machine |
| [`tidelink_apb_regs`](tidelink_apb_regs/) | `tidelink_apb_regs` | APB register file |
| [`tidelink_fc_adapter`](tidelink_fc_adapter/) | `tidelink_fc_adapter` | FC TX / RX + sideband adapter (single-stream tests; `full_test` excluded from CI pending scoreboard-race fix) |
| [`tidelink_ptp`](tidelink_ptp/) | `tidelink_ptp` | Single-phase PTP state machine |
| [`tidelink_ptp_servo`](tidelink_ptp_servo/) | `tidelink_ptp_servo` | PTP servo block |
| [`tidelink_phc_cdc`](tidelink_phc_cdc/) | `tidelink_phc_cdc` | PHC ↔ AHB handshake CDC |
| [`tidelink_addr_translator`](tidelink_addr_translator/) | `tidelink_addr_translator` | CAM-based address translation |
| [`tidelink_autoneg`](tidelink_autoneg/) | `tidelink_autoneg` (in chiplet controller) | Autoneg FSM, role lock, I²C arbitration |
| [`tidelink_mul_iter`](tidelink_mul_iter/) | `tidelink_mul_iter` | 32×32 iterative signed-×-unsigned multiplier (used by PTP servo) |
| [`tidelink_perf`](tidelink_perf/) | `tidelink_perf` | Perf counter block |
| [`tidelink_perf_congestion`](tidelink_perf_congestion/) | `tidelink_perf` congestion estimator | Phase-1 congestion-estimator characterisation |
| [`tidelink_idelay_rx`](tidelink_idelay_rx/) | `tidelink_idelay_rx` | Per-lane IDELAYE2 wrapper passthrough check |
| [`tidelink_rxclk_buf`](tidelink_rxclk_buf/) | `tidelink_rxclk_buf` | Recovered-RX-clock BUFG wrapper |
| [`tidelink_clkfreq_check`](tidelink_clkfreq_check/) | clock-freq-check helper | Sanity check on the FPGA clk_wiz output |
| [`wav_d2d_gpio_tx`](wav_d2d_gpio_tx/) | `WavD2DGpioTx` | Training-pattern mux passthrough |
| [`wavd2d_gpiorx_clkbuf`](wavd2d_gpiorx_clkbuf/) | `WavD2DGpioRx` | §9 in-PHY BUFG restructure (USE_CLKBUF=0 bit-exact) |
| [`wavd2d_gpiorx_t3a`](wavd2d_gpiorx_t3a/) | `WavD2DGpioRx` | §9 T3a self-aligning RX comma-hunt |
| [`wavd2d_gpiorx_t3a_off`](wavd2d_gpiorx_t3a_off/) | `WavD2DGpioRx` | §9 T3a USE_T3A=0 legacy-passthrough pin |
| [`wavd2d_gpiorx_t3a_timeout`](wavd2d_gpiorx_t3a_timeout/) | `WavD2DGpioRx` | §9 T3a silent-peer MAX_HUNT timeout fallback |

### Integration / system tests

| Env | What it exercises |
|---|---|
| [`tidelink`](tidelink/) | `tidelink` top-level (the legacy `src/rtl/tidelink.sv` wrapper — TOP=`tidelink_fifo` per `lint/Makefile`'s `TOP_tidelink`) |
| [`tidelink_ahb`](tidelink_ahb/) | `tidelink_ahb` wrapper + AHB-to-APB bridge (cocotb + HAL lint clean 2026-05-29) |
| [`tidelink_top`](tidelink_top/) | `tidelink_top` full integration (chiplet controller + FIFO + FC adapter + PTP + addr trans) |
| [`tidelink_system`](tidelink_system/) | Full-system integration test |
| [`tidelink_py_pair`](tidelink_py_pair/) | Python-driven paired-board sim |

### Lint flow (not a cocotb test env)

| Dir | Purpose |
|---|---|
| [`lint/`](lint/) | Verilator strict-lint wrapper (separate from `cocotb/Makefile regression`) |

### Debug envs (`debug/`, NOT in regression)

[`debug/`](debug/) holds bug-bisect probes, force-injection harnesses,
silicon-fingerprint reproducers, and integration sims that are too slow
or too scenario-specific for the per-commit CI loop. They are kept under
source control because they remain useful when a related class of bug
re-appears, but they are deliberately excluded from `make regression` so
the CI pipeline stays green and fast.

| Env | Why debug-only |
|---|---|
| [`debug/calibrator_force_bisect/`](debug/calibrator_force_bisect/) | Hierarchical-force bisect harness used to isolate the AUTOCAL=1 M→S corruption (`f900e07`) |
| [`debug/tidelink_chiplet_pair_autocal/`](debug/tidelink_chiplet_pair_autocal/) | Two-chiplet AUTOCAL_ENABLE=1 sim used during the same calibrator investigation |
| [`debug/tidelink_phy_align_calibrator/`](debug/tidelink_phy_align_calibrator/) | Calibrator FSM unit harness; default `MODULE` (`test_calibrator_t3`) currently fails an S_SWEEP-cycles assertion against the post-merge RTL — pending a re-pin |
| [`debug/phy_align/`](debug/phy_align/) | §9 PHY-align story — mix of contract pins (`test_calibrator_skew_window`) and asymmetric/staggered fault-injection probes |
| [`debug/wlink_pair/`](debug/wlink_pair/) | Two-Wlink pair-bringup sim with the L4/L6/FCSM/FPGA-repro test family from the 2026-05-2x interface-FCSM debug session |
| [`debug/wlink_tx_pstate_ctrl/`](debug/wlink_tx_pstate_ctrl/) | WlinkTxPstateCtrl FSM deadlock hypothesis probe (debug session 289bb42) |
| [`debug/wav_d2d_gpio_tx_prbs/`](debug/wav_d2d_gpio_tx_prbs/) | `feat/calibrator-prbs` PRBS-7 training stream investigation (now superseded by the constant-pattern checker in `deps/tidelink-gpio-phy`) |
| [`debug/bank_asymmetry/`](debug/bank_asymmetry/) | Synthetic per-bank RX asymmetry reproducer for the ~14/16 lane-lock plateau |
| [`debug/sim_robust/`](debug/sim_robust/) | Adversarial Cat-3/Cat-6 silicon-fingerprint reproducer set (Bug #1/#3/#7). Driven by the top-level `make sim_robust` target. |
| [`debug/phc_pair/`](debug/phc_pair/) | Two-Wlink + tidelink_ptp pair sim built to reproduce the PHC Phase-1 slave-RX gap |
| [`debug/tidelink_peer_aperture/`](debug/tidelink_peer_aperture/) | Cross-link extraction sim for the v2 Eye Visibility proposal (speculative RTL path) |
| [`debug/i2c_clkstretch/`](debug/i2c_clkstretch/) | SHORTCOMINGS-14a I²C clock-stretching reproducer + fix proof |
| [`debug/i2c_mask_selflock/`](debug/i2c_mask_selflock/) | Fix B autonomous SLAVE self-lock via the real `0x21C` lane-mask-handshake (shares the `wlink_pair` testbench) |

## Verification plan + coverage

The authoritative scope + acceptance criteria for each env lives in
[`VERIFICATION_PLAN.md`](VERIFICATION_PLAN.md). Coverage aggregation is
under `coverage_report/` (generated by the CI `coverage-merge` job; do
not edit by hand).

## Known-excluded-from-CI

(None as of 2026-05-29.)

Resolved 2026-05-29:
- `tidelink_ahb` HAL lint is now clean — legacy `src/rtl/tidelink.sv`
  was modernised to wrap the current `tidelink_fifo` with tie-offs for
  the new pass-through ports, and was added to
  `flists/tidelink_ahb.flist` so HAL can resolve `u_tidelink`.
- `tidelink_fc_adapter` → `tidelink_fc_adapter_full_test` (UVM) was
  previously flaky (~31 scoreboard mismatches under interleaved
  TX+RX+sideband stress) and excluded from CI.  Root cause: DUT
  corner case where, when the AHB master pipelines a new address
  phase in the same cycle the skid accepts the previous item, the
  latch is overwritten while `*_pending_r` stays asserted — and on
  the following cycle the skid samples a SECOND time with the new
  address paired with stale `hwdata` (master's clocking-block
  `output #1` NBA fires at +1ns, after the skid sample).  Fixed in
  the UVM testbench (`uvm/tidelink_fc_adapter/env/{rtn,ahb_tx}_driver.sv`)
  by waiting for pre-edge `hready=1` plus one settle cycle before
  re-arming the address phase, guaranteeing the FSM has cleanly
  transitioned through `pending=1 -> 0` before the next handshake.
  50/50 random seeds pass.

Tracked in `docs/archive/REPO_SIMPLIFICATION_IMPACT.md` (tier-2 §1-A).
