# Agent M — HW-like clock-drift cocotb sim variant

**Date:** 2026-05-27
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-sim-clkdrift`
**Branch:** `feat/sim-clock-drift`
**New sim directory:** `cocotb/tidelink_top_pair_drift/`

## Objective

The original `cocotb/tidelink_top_pair/` testbench drives master and slave
with a single shared `hclk` and `ref_clk` — emulating the single-MMCM
bridge1 FPGA target. The HW deploy targets that exhibit the M->S
asymmetric corruption ('CALIBRATOR_BUG_HANDOFF_2026_05_26.md') instead
use TWO independent PYNQ-Z2 boards, each with its OWN MMCM. The boards
drift relative to each other at typical XTAL tolerance (~50-250 PPM)
and the inter-board phase relationship at POR is arbitrary.

Agent F's bias-fix ('S_PROBE at (0,0)') passes the doorbell test only
because the cocotb-side shared-clock environment makes (slip=0,
phase=0) the deterministic eye centre for every lane on every run.
This variant emulates the inter-MMCM drift + phase-offset asymmetry
and re-runs the test under both (A) bias-fix applied and (B) bias-fix
reverted to see whether the fix is robust against HW-realistic drift.

## Implementation

### `tb_top.sv`

- Replaced shared `hclk` / `ref_clk` with per-side `hclk_m`/`hclk_s`
  and `ref_clk_m`/`ref_clk_s` ports (logic-driven from cocotb).
- Each chiplet's `.hclk(...)`, `.user_ref_clk(...)`, and `.phc_clk(...)`
  are wired to its OWN per-side clock.
- Kept a `wire hclk = hclk_m;` back-compat alias for any legacy probe
  that resolved on `tb_top.hclk`.

### `test_tidelink_pair_doorbell.py`

- New `CLK_PERIOD_PS_M = 20000` (20.000 ns = 50.0000 MHz exactly).
- New `CLK_PERIOD_PS_S = 20010` (20.010 ns = ~49.975 MHz, +500 PPM).
- New `REF_CLK_PERIOD_PS_M = 8000` / `REF_CLK_PERIOD_PS_S = 8004` ps
  (Wlink PLL ref, scaled to keep ~+500 PPM relationship).
- New `PHASE_OFFSET_PS = 7000` (7.000 ns) — slave's hclk + ref_clk
  start 7 ns delayed (about 1/3 of a master period) so the
  cross-domain pads see a non-zero phase at POR.
- Periods are integer ps because cocotb 2.x's `Clock()` requires the
  period to be a multiple of 2 ps (so the half-period rounds cleanly).
  This sets our PPM resolution to ~100 PPM; 500 PPM is chosen to give
  a margin above realistic XTAL tolerance while keeping convergence
  fast in sim.
- `PairTB.__init__` starts the master clocks at t=0 immediately and
  schedules a coroutine `_delayed_clock` that `Timer`-waits 7 ns then
  starts each slave clock. APBMaster is bound to the *local* clock
  per side (`m_apb` -> hclk_m, `s_apb` -> hclk_s) so APB phases align
  with the local domain.
- Renamed bare `dut.hclk` references throughout the test file to
  `dut.hclk_m` (master domain — the reset sequence stays in the master
  domain to be consistent with the original behaviour).

### `Makefile`

- Identical to the original, headers updated for clarity.

## Rationale

- **500 PPM drift:** datasheet XTAL tolerance is ~50-100 PPM per side,
  so worst-case inter-board offset is 100-200 PPM. We use 500 PPM
  because cocotb 2.x rounds to 2-ps period granularity (~100 PPM
  resolution) and we want margin above realistic XTAL tolerance to
  give the env room to provoke drift-sensitive behaviour. The slave's
  clock period is 20010 ps vs the master's 20000 ps — a 10-ps offset
  on a 20-ns base.
- **7 ns phase offset:** about 1/3 of the master period; guarantees
  the slave's pad-RX is sampling on a non-trivial phase of the
  master's TX clock at t=0. On the original shared-clock sim, the
  (0,0) sample point IS the eye centre; with 7 ns slip and ongoing
  drift, (0,0) may no longer be the canonical eye centre — provoking
  the per-lane (slip, phase) latch to land somewhere else.

## Scenarios run

### Scenario A — current `feat/calibrator-bug-fix` RTL (bias fix applied)

Calibrator RTL = HEAD (`f900e07` — S_PROBE bias to (slip=0, phase=0)
landed by Agent F).

Test: `cocotb/tidelink_top_pair_drift/test_tidelink_pair_doorbell.py`

| Test                                            | Scenario A (bias-fix HEAD) |
|---|---|
| `test_01_role_lock_and_cal_done`                | _RESULT_PENDING_           |
| `test_02_training_held_pre_release`             | _RESULT_PENDING_           |
| `test_03_to_data_mode_cr_crack_latch`           | _RESULT_PENDING_           |
| `test_04_pair_credit_counter_nonzero`           | _RESULT_PENDING_           |
| `test_05_doorbell_master_to_slave`              | _RESULT_PENDING_           |
| `test_06_doorbell_slave_to_master`              | _RESULT_PENDING_           |

Per-lane latched (slip, phase) under Scenario A: _RESULT_PENDING_

### Scenario B — bias fix REVERTED

Calibrator RTL reverted to `0208493` (the commit immediately before
the Agent-F bias-fix) for this run only; restored to HEAD afterwards.

| Test                                            | Scenario B (bias-fix reverted) |
|---|---|
| `test_01_role_lock_and_cal_done`                | _RESULT_PENDING_           |
| `test_02_training_held_pre_release`             | _RESULT_PENDING_           |
| `test_03_to_data_mode_cr_crack_latch`           | _RESULT_PENDING_           |
| `test_04_pair_credit_counter_nonzero`           | _RESULT_PENDING_           |
| `test_05_doorbell_master_to_slave`              | _RESULT_PENDING_           |
| `test_06_doorbell_slave_to_master`              | _RESULT_PENDING_           |

Per-lane latched (slip, phase) under Scenario B: _RESULT_PENDING_

## Conclusion

_TO BE FILLED IN AFTER RUNS COMPLETE._

## Hard constraints honoured

- `/research/AAA/ip_library/**` — not touched.
- `deps/axi-chiplet-controller/**` — not touched.
- `cocotb/tidelink_top_pair/` — not touched.
- Calibrator RTL reverted only temporarily for Scenario B; restored
  after the run.
- New code lives in `cocotb/tidelink_top_pair_drift/` + this doc.

## Reproducer

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-sim-clkdrift
source set_env.sh
cd cocotb/tidelink_top_pair_drift
rm -rf sim_build results.xml
make MODULE=test_tidelink_pair_doorbell
```

For Scenario B:

```bash
cd /home/dam1n19/SoCLabs/td-bisect/td-sim-clkdrift
git show 0208493:src/rtl/tidelink_phy_align_calibrator.sv \
    > src/rtl/tidelink_phy_align_calibrator.sv
cd cocotb/tidelink_top_pair_drift
rm -rf sim_build results.xml
make MODULE=test_tidelink_pair_doorbell
cd ../..
git checkout HEAD -- src/rtl/tidelink_phy_align_calibrator.sv
```
