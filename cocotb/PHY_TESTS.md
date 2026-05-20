# §9 PHY component unit tests — coverage map

Standalone cocotb unit tests for the §9 (clock + T3a + calibrator)
RTL changes added on `feat/td-combined`. Each directory is a tight
single-DUT (or, where load-bearing, deliberately-small multi-DUT)
testbench with `vcs` as the simulator. Companion to the existing
`cocotb/phy_align/` and `cocotb/wlink_pair/` integration suites.

## RTL → test mapping

| RTL component                            | Test directory                            | What is covered                                                                                                              |
|---|---|---|
| `fpga/rtl/tidelink_rxclk_buf.sv`         | `cocotb/tidelink_rxclk_buf/`              | Boundary BUFG buffer USE_CLKBUF=0 g_passthru and USE_CLKBUF=1+TIDELINK_RXCLK_NO_PRIMITIVE opt-OUT — bit-exact passthrough on both elaboratable corners. |
| `WavD2DGpioRx.v` USE_CLKBUF generate     | `cocotb/wavd2d_gpiorx_clkbuf/`            | USE_CLKBUF=0 g_passthru arm = the legacy WavClockMux-alias path (pre-restructure bit-exact). Deserialised io_link_data is well-formed (hi==lo, non-degenerate) from a periodic byte stream. |
| `WavD2DGpioRx.v` T3a comma-hunt          | `cocotb/wavd2d_gpiorx_t3a/`               | USE_T3A=1 slip-on-match: 8 lanes × 4 skews per lane (32 sub-checks), io_link_data INVARIANT under POR-deassertion skew = lottery defeated. (existing — covers all 8 lane-byte rotations.) |
| `WavD2DGpioRx.v` T3a — MAX_HUNT timeout  | `cocotb/wavd2d_gpiorx_t3a_timeout/`       | USE_T3A=1 silent-peer fallback: io_pad held 0 → S_HUNT exits to S_LOCKED via MAX_HUNT, do_slip stays 0, io_link_data steady 0. Staggered bring-up cannot livelock. |
| `WavD2DGpioRx.v` T3a — USE_T3A=0 off     | `cocotb/wavd2d_gpiorx_t3a_off/`           | USE_T3A=0 strict bit-exact: g_t3a_passthru arm elaborated, count resets to 0xF and free-runs +1 mod 16, async-resets on POR. ASIC/UVM/sim default preserved. |
| `tidelink_phy_align_calibrator.sv` T3/T3.2 | `cocotb/tidelink_phy_align_calibrator/` (this set) | T3 continuous re-sweep on faulted sweep; T3.2 S_HOLD on sweep_success keeps training_mode HIGH HOLD_CYCLES and is insensitive to lane_locked drop; resweep_ctr semantics; best-of-sweep silicon default walks full 128-point space. |
| `tidelink_phy_align_calibrator.sv` §9.9 best-of-sweep | `cocotb/phy_align_calibrator/` (Agent A) + the `_placeholder` test in our dir | Widest-eye selection — two-DUT compare (best-of-sweep vs first-match). |
| Calibrator + lane_checker pair integration | `cocotb/phy_align/test_pair_align.py`     | End-to-end pair-level test (master+slave) — confirms calibration converges with FCSM reaching state=4. Re-confirmed PASS post §9 RTL.  |

## Run order

```sh
cd /home/dam1n19/td_idelay_wt && source set_env.sh

# Fast unit tests (≲ 2 s each):
make -C cocotb/tidelink_rxclk_buf
make -C cocotb/wavd2d_gpiorx_clkbuf
make -C cocotb/wavd2d_gpiorx_t3a_off
make -C cocotb/wavd2d_gpiorx_t3a_timeout
make -C cocotb/tidelink_phy_align_calibrator                # single-DUT (T3/T3.2)
make -C cocotb/tidelink_phy_align_calibrator TB_VARIANT=compare   # two-DUT best-of-sweep
make -C cocotb/wavd2d_gpiorx_t3a                            # 8 lanes × 4 skews, ~3 s

# Integration smoke (≲ 10 s):
make -C cocotb/phy_align                                    # test_pair_align
```

Each test directory's Makefile has a header comment with the specific
`make` invocation and required env (`set_env.sh` first; the rxclk_buf
and calibrator-only sims do not need `CMSDK_FPGA_SRAM_V` because they
do not pull in the AHB/CMSDK side of the testbench).

## Intentional gaps (not tested by this set)

* **USE_CLKBUF=1 WITHOUT TIDELINK_RXCLK_NO_PRIMITIVE** — would elaborate
  a real Xilinx BUFG; VCS cannot do that without unisim. Covered by
  the FPGA build flow (Vivado synth + routed netlist).
* **WavD2DGpioRx USE_CLKBUF=1** branch (g_clkbuf BUFG arm) — same
  reason. The opt-OUT escape hatch (`TIDELINK_RXCLK_NO_PRIMITIVE`)
  inside that branch IS available in sim but its `else just reuses
  the same WavClockMux outputs as USE_CLKBUF=0, giving no functional
  coverage delta over `cocotb/wavd2d_gpiorx_clkbuf/`.
* **8-lane T3a array hierarchical probe** — cocotb 2.0 + VCS 2022.06
  doesn't reliably resolve flattened generate-for `g_lane[N].u_dut`
  child names via `_discover_all`. The
  `cocotb/wavd2d_gpiorx_t3a_timeout/` test sidesteps this with a
  single-instance TB; per-lane introspection on the 8-lane array uses
  output bus slicing (working) rather than hierarchical descent.
* **Best-of-sweep selection refinement tests** — the placeholder test
  `test_best_of_sweep_placeholder.py` pins the silicon-default
  full-128-point sweep length contract; richer refinements (tie-break
  rules, marginal-eye-over-first-match) are covered by Agent A's
  `cocotb/phy_align_calibrator/test_best_of_sweep_compare.py`.
* **APB override and SW debug paths in the calibrator** — covered
  indirectly by the pair-level integration tests; no dedicated unit
  test here.
