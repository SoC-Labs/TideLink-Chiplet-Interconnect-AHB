# PHC Phase-1 — Sim-vs-HW Gap Analysis

**Date:** 2026-05-23
**Branch:** `feat/phc-pair-fpga-models`
**Context:** docs/PHC_PHASE1_HW_REPORT.md §"Build #11 verdict" /
§"Phase-1 PHC status — autonomous loop exhausted".

The PHC slave-RX bug (master HW_SYNC_STATUS=0x4815/0x4831/0x47f5 advancing,
slave HW_SYNC_STATUS=0x0, PTP_CTRL=0x1 confirmed sticky) does not reproduce
in `cocotb/phc_pair/` even after Agent N's TB-helper race fix (c8f418c).
This document is the cause-narrowing audit ordered by the next-tier debug
brief: extend the sim env with the FPGA-specific structural cells the
production bitstream inserts, re-run, and identify what HW still does
that sim does not.

---

## 1. Topology diff — sim vs HW

Both halves of the pair traverse the *same RTL* up to and including the
GPIO PHY. The divergence sits **inside** `axi_chiplet_controller` and is
gated by the `USE_IDELAY` and `USE_CLKBUF` parameters (and, downstream of
that, by the XDC source-synchronous constraint set + Vivado P&R).

Per-signal table (slave's master-→-slave direction; symmetric on the
slave-→-master direction):

| Stage | sim (`cocotb/phc_pair/`, default) | HW (`pynq-z2-pair-all/-flip-all`) |
|---|---|---|
| Master `tidelink_ptp.ptp_sp_tx_*` | identical RTL | identical RTL |
| Master `Wlink.sp2wl` + `ll_tx` | identical RTL | identical RTL |
| Master GPIO PHY TX serdes | identical RTL | identical RTL |
| Master `pad_clk_tx` / `pad_tx[7:0]` driver | wire output of `axi_chiplet_controller` | OBUF in BD, IO-bank pinned via `pynq_z2_tidelink_xil.xdc` |
| Cross-link clock path | continuous SystemVerilog wire (`m_pad_clk_tx → s_pad_clk_tx`) | physical PCB trace, IBUF on slave side (BUFG insertion location is the §9 fix) |
| Cross-link data path | continuous SystemVerilog wires (`m_pad_tx[n] → s_pad_tx[n]`) | physical PCB traces (8 separate routes, IOB-packing pressure inside Vivado) |
| Slave `pad_clk_rx` IBUF→`tidelink_rxclk_buf` | `USE_CLKBUF=0`: `assign clk_o = clk_i` (continuous assign) | `USE_CLKBUF=1`: **explicit `BUFG` primitive** driving the recovered RX clock global network |
| Slave `pad_rx[n]` IBUF→`tidelink_idelay_rx` | `USE_IDELAY=0`: `assign pad_rx_o = pad_rx_i` | `USE_IDELAY=1`: per-lane **`IDELAYE2 (VAR_LOAD)`** + one bank `IDELAYCTRL` running on 200 MHz reference |
| Slave PHY RX deserialiser + bit-slip mux | identical RTL | identical RTL, but capture flops live in fabric, clocked by the BUFG-buffered recovered clock |
| Slave `ll_rx` short-packet decode | identical RTL | identical RTL |
| Slave `sp2wl.rx_fifo` | identical RTL (async FIFO using SystemVerilog handshake) | identical RTL (same async FIFO, but the two domains are *physically* distinct clocks subject to per-build skew) |
| Slave `tidelink_ptp.ptp_sp_rx_*` | identical RTL | identical RTL |
| **Constraints** | none | `set_input_delay`/`set_output_delay`/`set_bus_skew`/`set_clock_groups` (`pynq_z2_tidelink_timing.xdc`), IDELAY ref-clock create_generated_clock (`pynq_z2_tidelink_idelay.xdc`) |
| **P&R** | n/a — pure functional sim | Vivado place + route, fabric routing skew per-build random within constraint headroom |

### Identification of the FPGA-only cells that sim was not modelling

In the **default** `cocotb/phc_pair/tb_top.sv` (pre-this-branch), both
`tidelink_idelay_rx` and `tidelink_rxclk_buf` *were* in the elaborated
hierarchy — but only in their `USE_IDELAY=0` / `USE_CLKBUF=0` passthrough
branches. The actual Xilinx `IDELAYE2`, `IDELAYCTRL` and `BUFG`
primitives never appeared in sim because the generate-if pruned the
branch that references them entirely.

This branch (`feat/phc-pair-fpga-models`) flips those parameters to 1
and pulls in Vivado's unisim library + `glbl.v` so the real primitives
elaborate. See §3 for the empirical result.

---

## 2. What the sim env was extended with

Branch `feat/phc-pair-fpga-models` modifies *only* `cocotb/phc_pair/`:

1. `tb_top.sv` — adds:
   - a free-running 200 MHz `idelay_ref_clk` and an active-high
     `idelay_rst` that releases 200 ns after time zero;
   - those signals are wired to both `u_master.idelay_ref_clk/_rst` and
     `u_slave.idelay_ref_clk/_rst` (the existing port was floating);
   - an `ifdef PHC_PAIR_USE_FPGA_MODELS` `defparam` block that flips
     `USE_IDELAY=1` and `USE_CLKBUF=1` on both `axi_chiplet_controller`
     instances.

2. `Makefile` — adds a `USE_FPGA_MODELS` knob (default 0, preserving
   existing behaviour). When set to 1, the build:
   - defines `PHC_PAIR_USE_FPGA_MODELS` (activates the `defparam`);
   - adds `-y $(XILINX_VIVADO)/data/verilog/src/unisims +libext+.v` so
     the `IDELAYE2`, `IDELAYCTRL` and `BUFG` modules resolve by name;
   - explicitly compiles `glbl.v` and elaborates it as a second top
     (`-top glbl`) so the unisim primitives' `glbl.GSR` XMR resolves.

Run with:

```sh
cd cocotb/phc_pair
make USE_FPGA_MODELS=1                            # test_phc_hw_sync_pair
make USE_FPGA_MODELS=1 MODULE=test_phc_diag       # per-cycle counts
```

Compile evidence that the primitives ARE pulled in:

```
Parsing library directory file '/apps/Xilinx/Vivado/2024.1/data/verilog/src/unisims/BUFG.v'
Parsing library directory file '/apps/Xilinx/Vivado/2024.1/data/verilog/src/unisims/IDELAYCTRL.v'
Parsing library directory file '/apps/Xilinx/Vivado/2024.1/data/verilog/src/unisims/IDELAYE2.v'
recompiling module IDELAYCTRL
recompiling module IDELAYE2
```

And the VCD confirms that the `g_idelay.g_lane[0..7]` generate branches
are elaborated under both `u_master.u_idelay_rx` and `u_slave.u_idelay_rx`
(only the active branch's nets appear; the `g_passthru` branch is gone).

---

## 3. Does the extended env reproduce the HW bug?

**No.**

| Run | Result | Slave `sync_rx_done` pulses | Slave `PTP_CTRL[2]` (rx_valid) | Slave `sp2wl.rx_fifo.winc` |
|---|---|---|---|---|
| `make` (default, USE_IDELAY=0, USE_CLKBUF=0) | PASS | 3 | 1 | 7968 |
| `make USE_FPGA_MODELS=1` (USE_IDELAY=1, USE_CLKBUF=1) | **PASS** | **3** | **1** | **7968** (via diag) |

The slave reliably observes master SYNC short packets in both
configurations. The HW bug (slave HW_SYNC_STATUS stays 0x0 with
PTP_CTRL=0x1) does NOT reproduce in either.

This is consistent with what the cells do as behavioural models:

- `IDELAYE2` with `IDELAY_VALUE=0` and `IDELAY_TYPE="VAR_LOAD"` —
  the unisim model implements the configured tap as a discrete sample
  delay, but with our calibrator default and a 200 MHz REFCLK the
  modelled per-tap resolution (~78 ps) is sub-cycle for the 25 MHz
  pad clock; in functional sim the delay is logically zero on a
  cycle-by-cycle basis.
- `BUFG` — modelled as a pure wire in unisim. No clock-domain semantic.
- `IDELAYCTRL` — provides a `RDY` output (unused here, deliberately).

The cells therefore do **not** introduce any new logical or timing
behaviour in functional VCS simulation. Their HW value comes from
giving the synthesizer + placer + router a deterministic structural
target (a BUFG node, an IODELAY group), so that the *physical* clk-to-
data eye position on the recovered RX clock is no longer build-lottery.

---

## 4. Divergence-point identified

The remaining differences between sim and HW that this experiment did
*not* close, in priority order for next-tier debug:

1. **Vivado P&R skew on the slave's master→slave clock+data fan-out.**
   The `pad_rx[7:0]` IBUFs all need to land in the same I/O column as
   the `pad_clk_rx` IBUF + its BUFG; the routed delay from each IBUF
   to the GPIO PHY's deserialiser capture flops is per-build random
   within the unconstrained slack window. The §9 IDELAYE2 fix gives
   the calibrator a real delay lever, but only *characterises* the
   skew; it cannot move data out of a missed eye if the bitstream
   already routed past the IDELAY tap range. Sim has no P&R, so any
   build-lottery class of bug is invisible.

2. **Real-world reset/sequencing race between `peripheral_aresetn`,
   the recovered-RX-clock-domain (`pad_clk_rx_buf`) and the slave's
   `sp2wl.rx_fifo` write pointer.** In sim both clocks are perfectly
   synchronous (driven by the same simulator quantum). On silicon the
   recovered RX clock is gated by the master's TX activity and only
   exists once the master is sending — the FIFO's CDC may be left in
   an `X` state until the first TX, and recovery from that depends on
   how the BUFG's clock-enable propagates the first edge. Sim's
   `init`-block reset coverage hides this entirely.

3. **`set_bus_skew` / `set_input_delay` constraint margin.** If the
   timing constraint headroom on the master→slave bus is exhausted by
   actual routing (visible in `report_bus_skew` post-impl), specific
   lanes may be marginal — the calibrator can compensate up to a
   threshold and silently fail above it. Sim has no timing model.

4. **Slave-side FIFO reset state at link-active edge.** `sp2wl.rx_fifo`
   uses the recovered RX clock domain for the write side. On HW the
   FIFO write pointer comes out of reset only once `pad_clk_rx` is
   running (i.e. master is TXing); in sim the clock is always running
   from `t=0`, so the FIFO reset edge always aligns with a known
   `pad_clk_rx` cycle. A reset-domain ambiguity in the FIFO that
   happens to manifest as a stuck full / stuck empty pointer on HW
   would be invisible to sim.

5. **APB-burst-induced wedge of the slave PYNQ board** (orthogonal
   to the link bug per se, but documented in `PHC_PHASE1_HW_REPORT.md`
   §"Build #9 retry #2": multiple z2_03 wedges under the test-harness
   SSH+devmem burst load). Sim trivially never hits this.

6. **Master's `tx_link_idle` interaction with `b61c84a`'s force_en.**
   In sim, `tx_link_idle` toggles freely and the FSM advances every
   ~250 ns. On HW the live `tx_link_idle` may have a different duty
   cycle once the calibrator + autoneg + LP-frame insertion overhead
   are accounted for; the master `HW_SYNC_STATUS=0x4815/0x47f5` proves
   the FSM advances, but the per-packet rate on HW may differ from
   sim's ~870/s observed.

The most likely single cause is **(1)** — exactly the failure mode
`tidelink_idelay_rx.sv`'s header explicitly anticipates: "the
calibrator's window is finite: it only locks if the build-time per-lane
clk-to-data routing skew lands inside that window." Even with USE_IDELAY
on, if the *bitstream* routes past the tap range, the calibrator's lock
threshold passes (link looks 16/16) while the *actual* eye sits at the
edge of one lane's UI — under thermal drift / supply ripple that lane
drops and the deserialiser bit-position shifts by one, producing
garbled short-packet payloads that fail the ECC check (silent drop, no
counter). HW evidence consistent with this: master `LinkInterrupts =
0x00020202` shows `ecc_corrected` on master's RX of slave-originated
traffic; slave's `LinkInterrupts = 0x00000000` shows zero RX activity
at all on the slave side — the deserialiser is not even firing a frame
boundary, suggestive of clock-recovery rather than bit-error.

---

## 5. Recommendation for the next-tier debug primitive

Sim has now exonerated the **logical** RX path end-to-end at every
boundary the diag test probes:
`ll_tx.sop → ll_rx.valid&&sop → is_short_pkt → dataIdMatch →
rx_pkt_valid → rx_fifo.winc → ptp_sp_rx_valid → ptp_enable_r &
sync_rx_done` all transit at 7968 packets per 50 000 cycles per
`test_phc_diag` with USE_FPGA_MODELS=1. The bug is therefore *not*
in the RTL functional path. Three options for the next step, ranked
by cost vs. discriminating power:

1. **(Highest signal / lowest risk) Oscilloscope on the slave's
   `pad_clk_rx` + one `pad_rx[n]` pin.** Differential probe at the
   Raspberry Pi header. Confirms whether the recovered RX clock is
   actually toggling on the slave side when master TX is active.
   If clock present but data eye crushed → IDELAY tap is past
   range, escalate to in-PHY clean-clock restructure
   (`tidelink_rxclk_buf` SCOPE NOTE).

2. **(Medium signal / medium cost) ChipScope ILA on slave's `ll_rx`
   boundary** with mark_debug on `valid`, `sop`, `data_id`, `wc`,
   `is_short_pkt`, `is_long_pkt`, `corrupted`. The HW counter
   experiment (`feat/phc-rx-counters`) tried this at the APB-readable
   layer but read back nonsense values on slave — the slave-side
   address decode is suspect. An ILA, which bypasses APB entirely,
   sidesteps the slave's APB-decode issue.

3. **(Low signal / low cost) Re-run with the `force_en` bypass also
   on the slave's `ptp_enable_r`** plus mid-test re-arm of
   `PTP_CTRL=1` every 1 s. If a non-PTP-related register on slave is
   silently clearing under APB-burst pressure, this would expose it.
   Already partly covered by the `4367a71` discriminator log — extend
   to a per-sample re-arm.

The pure-sim env (this branch) provides the long-lived discriminator:
any future RTL hypothesis can be tested in cocotb in ~25 s wall-clock
and ruled in or out before incurring a 40-minute farm rebuild + a
bridge1 lease cycle. The §9 cells are now in the elaborated hierarchy,
so the env also stress-tests the IDELAY/BUFG parameterisation in case
of future RTL changes to those wrappers.

---

## 6. Branch + artifacts

- Branch: `feat/phc-pair-fpga-models` (not merged).
- Files touched: `cocotb/phc_pair/Makefile`, `cocotb/phc_pair/tb_top.sv`,
  and this document.
- No RTL changes outside `cocotb/`.
- No FPGA constraints or BD changes.
- No rebuild required.
- Default (USE_FPGA_MODELS=0) behaviour preserved bit-for-bit — the
  pre-existing `test_phc_hw_sync_pair` and `test_phc_diag` still PASS
  identically on this branch (verified).
