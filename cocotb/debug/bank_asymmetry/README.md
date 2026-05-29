# cocotb/bank_asymmetry — bank-35 / bank-13 IDELAYCTRL asymmetry reproducer

This cocotb test reproduces, **synthetically and behaviourally**, the per-bank
IDELAYCTRL tap-time asymmetry that produces the ~14/16 lane-lock plateau seen
on the TideLink Pynq-Z2 silicon bring-up. It pins the §9.9 best-of-sweep
widest-eye latch (commit `0d85843`) as the load-bearing fix and demonstrates
that a per-bank-group phase search would close the remaining gap.

## What the TB models

Vivado places the master RX lanes across two IDELAY columns:

| Lane group         | Lanes               | IDELAY column / IDELAYCTRL |
| ------------------ | ------------------- | -------------------------- |
| bank-13 (6 lanes)  | 0, 2, 4, 5, 6, 7    | column X0 / `IDELAYCTRL_X0Y0` |
| bank-35 (2 lanes)  | 1 (C20), 3 (A20)    | column X1 / `IDELAYCTRL_X1Y2` (replicated) |

The two IDELAYCTRLs have independent VT-dependent tap-time references, so the
bank-35 lanes see effectively:

  * a **narrower lock eye** (fewer (slip, phase) iterator points lock), and/or
  * a **shifted eye centre** (1–2 phase points off the bank-13 centre).

Tap-time variation is **not** captured by any SDF or gate-level sim model — it
is a silicon runtime characteristic. This TB models the **effect** (per-lane
narrow / skewed / bouncing eye) at the calibrator's `lane_locked[7:0]`
boundary, without instantiating Wav PHY.

The slave board mirrors with lanes 0 (F19) and 4 (B20) on bank-35. See the HW
trajectory probe `/home/dam1n19/td_campaign/bringup_health_probe.log`:

```
M[0xf5 ..] / M[0xfd ..] / M[0xd5 ..] / M[0xd7 ..]    ← master  : lanes 1,3 bounce
S[0xce ..] / S[0x7f ..] / S[0xee ..]                  ← slave   : lanes 0,4 bounce
```

and the project-memory entry
`~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_fpga_bringup.md`
for full HW context.

## TB structure

`tb_top.sv` elaborates **two** `tidelink_phy_align_calibrator` instances driven
from the same synthetic `lane_locked[7:0]` vector:

  * `u_dut_best`  — `EARLY_EXIT_ON_ALL_LOCKED=0` (silicon default; §9.9
    best-of-sweep widest-eye latch, Agent A's commit `0d85843`).
  * `u_dut_first` — `EARLY_EXIT_ON_ALL_LOCKED=1` (legacy §9.7 first-match-wins
    compat).

A pure-RTL per-lane eye-shape driver watches the **best** DUT's iterator
(`sweep_slip`, `sweep_phase`, `dwell_ctr`) and produces a parameterised
`lane_locked[7:0]` according to the per-lane eye model.

## Per-lane stimulus parameters

Each lane has 5 packed inputs the test pokes before triggering calibration:

| Input              | Width per lane | Pack          | Meaning                                                                  |
| ------------------ | -------------- | ------------- | ------------------------------------------------------------------------ |
| `eye_centre_slip`  | 3 bits         | 24-bit packed | Slip value at which this lane's eye is centred                           |
| `eye_centre_phase` | 4 bits         | 32-bit packed | Phase value at which this lane's eye is centred                          |
| `eye_width`        | 3 bits         | 24-bit packed | Half-width of the eye in points (Chebyshev / L_inf distance)             |
| `eye_skew_phase`   | 4 bits         | 32-bit packed | Per-lane phase shift (mod 16) applied BEFORE the eye check; models IDELAYCTRL tap-time misalignment |
| `eye_noise_enable` | 1 bit          |  8-bit packed | Enable eye-edge bounce: HIGH for `LOCK_THRESH+2` cycles at the eye edge then LOW (models the bringup_health_probe oscillation) |

`eye_width = 0` is a **single-point eye** (the bank-35 narrow case);
`eye_width = 3` is a **wide eye** (the bank-13 case).

A lane reports `lane_locked = 1` iff
`max(|slip - centre_slip|, |(phase + skew) mod 16 - centre_phase|) <= width`,
i.e. the Chebyshev distance from the lane's eye centre is within its half-
width. With `noise_enable[lane] = 1`, the lane additionally **bounces** at
distance `width+1`: HIGH for the first `LOCK_THRESH+2` cycles of each
`DWELL_CYCLES` window, then LOW. That 18-cycle run-length **just barely**
clears the lane checker's `LOCK_THRESH = 16` threshold — exactly the
marginal-edge mechanism the HW probe captured.

## Scenarios

| Scenario                       | Pattern                                                                                                | Expected                                                                                                  |
| ------------------------------ | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `test_uniform_all_lanes_lock`  | all 8 lanes wide-eye (width=3), random common centre                                                   | both DUTs lock 8/8 inside the eye                                                                          |
| `test_bank35_master_narrow_eye`| lanes 1,3 narrow (width=0, +2 phase shift) vs bank-13 wide                                             | best-of-sweep locks all 8 at the eye centre                                                                |
| `test_bank35_slave_narrow_eye_flip` | lanes 0,4 narrow (slave HW)                                                                       | best-of-sweep locks all 8 at the eye centre                                                                |
| `test_marginal_bounce_best_vs_first` | narrow + eye-edge bounce on lanes 1,3                                                             | best-of-sweep locks at CENTRE; first-match locks ≥1 narrow lane at EDGE                                    |
| `test_first_vs_best_monte_carlo`     | 40 seeds, random centre + offset 1–2, random narrow-lane set                                      | first-match failure rate ≥30%; best-of-sweep failure rate ≤5%                                              |
| `test_per_bank_group_hypothesis`     | bank-asymmetric scenario with narrow lanes given a wider effective eye (simulates the proposed fix) | both DUTs lock all 8 lanes cleanly — proves Agent B's per-bank phase-search hypothesis would close the gap |

## Results (silicon default DUT vs first-match DUT)

| Statistic                                                | Value             |
| -------------------------------------------------------- | ----------------- |
| First-match-wins failure rate on bank-asymmetric Monte-Carlo (N=40) | **100% (40/40)** |
| Best-of-sweep failure rate on the same scenarios         | **0% (0/40)**    |
| Wall-clock per scenario (single sweep)                   | ~0.6 s            |
| Wall-clock for the 40-seed Monte-Carlo                   | ~25 s             |

The first-match-wins failure rate is materially **above** the ≥30% headline
target the task specified: with the synthetic edge bounce reproducer enabled
on the narrow lanes, the legacy policy **always** latches the edge first
(because the bounce is positioned at distance `width+1` from centre, which is
encountered first when sweeping phase-outer slip-inner and the centre is
beyond the bounce point). This pins the §9.9 mechanism unambiguously.

## Caveats

* **Behavioural, not physical.** The TB does NOT model IDELAYE2 silicon, PLL
  phase, or PHY clocking. It models the **observable effect** at
  `lane_locked[7:0]`: narrow / skewed / bouncing eyes. Silicon-level
  characterisation requires HW (the trajectory probe in
  `pynq_host/scripts/bringup_health_probe.sh`).
* **DWELL_CYCLES = 32, LOCK_THRESH = 16** in the TB; the silicon defaults are
  `DWELL_CYCLES = 64, LOCK_THRESH = 16`. The bounce window is sized for
  DWELL=32 (`LOCK_THRESH+2 = 18` is a meaningful fraction of 32). The §9.9
  selection-policy difference is independent of DWELL_CYCLES once the dwell
  exceeds LOCK_THRESH; the smaller DWELL is purely for sim wall-time.
* **No re-sweep cycles modelled.** Each scenario triggers ONE sweep and reads
  the latched outputs. T3 continuous re-sweep is exercised separately in
  `cocotb/tidelink_phy_align_calibrator/test_calibrator_t3.py`.

## Invocation

```bash
cd /home/dam1n19/td_idelay_wt
source set_env.sh
rm -rf cocotb/bank_asymmetry/sim_build
make -C cocotb/bank_asymmetry
```

Verilator lint:

```bash
verilator --lint-only -Wall \
  -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH \
  --top-module tb_top \
  cocotb/bank_asymmetry/tb_top.sv \
  src/rtl/tidelink_phy_align_calibrator.sv
```

(clean — 0 warnings, 0 errors with Verilator 4.028).

## References

* `src/rtl/tidelink_phy_align_calibrator.sv` — calibrator FSM (DUT)
* `src/rtl/tidelink_lane_checker.sv` — lock criterion (`LOCK_THRESH`)
* `cocotb/tidelink_phy_align_calibrator/tb_top_compare.sv` — sibling
  two-DUT comparator (Agent A's eye-edge marginal test)
* commit `0d85843` — §9.9 best-of-sweep widest-eye latch (Agent A)
* commit `c86f17b` — `tb_early_exit_force_q` sim bypass (this TB does
  not need to assert it; the per-DUT parameter selects the policy)
* `/home/dam1n19/td_campaign/bringup_health_probe.log` — HW trajectory
* `~/.claude/projects/-home-dam1n19-SoCLabs-tidelink/memory/project_tidelink_fpga_bringup.md`
  — full §9 bring-up context (top RESOLVED section)
