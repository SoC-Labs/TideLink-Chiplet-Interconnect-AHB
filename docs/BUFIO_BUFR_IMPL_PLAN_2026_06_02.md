# BUFIO+BUFR RX Clock Restructure — Implementation Plan (2026-06-02)

Target: `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-{,flip-}all`

## 1. Goal + success criteria

Replace the single `IBUFG → BUFG` `tidelink_clk_rx_buf` wrapper with a dual-output
`IBUF → BUFIO + BUFG` (BUFR omitted — no division required at /1) wrapper, and
route the BUFIO output to the **six** in-bank-13 RX sample lanes via a
per-lane LOC-pinned IOB flop, while keeping the BUFG output for the **two**
cross-bank (bank-35) lanes and any fabric-side users. Success: (a) scope
shows tighter, less-skewed sampling on bank-13 lanes vs the bank-35 pair;
(b) `report_clocks` lists `clk_rx_bufio` and `clk_rx_bufg`; (c)
`report_clock_utilization` places one BUFIO in clock-region X1Y2 (bank 13);
(d) bank-13 lanes show lower `EYE_CRC_ERR_LO/HI` counts than bank-35 lanes
under identical traffic; (e) WNS/WHS clean on both clocks after `set_max_delay`
between the two domains.

## 2. Architecture diagram

```
Before:
  pad_clk_rx(Y7) ─► IBUFG ─► BUFG ────────► 8 lane samplers (global tree)

After:
  pad_clk_rx(Y7) ─► IBUF ─┬─► BUFIO ─► clk_rx_bufio ─► 6 bank-13 lane samplers
                          │                            (LOC'd to bank-13 IOBs)
                          └─► BUFG  ─► clk_rx_bufg  ─► 2 bank-35 lane samplers
                                                      + fabric / IDELAYCTRL refs
```

BUFR is not needed: we want /1 of the recovered clock; BUFIO already drives
ILOGIC/IOB flops directly without division.

## 3. Bank inventory (verified against current XDC)

Banks per audit: **bank 13** = V10, V8, W10, W8, V6, W6, Y6, Y7, Y8, Y9, U7, U8, V7, W9. **bank 35** = F19, F20, B20, A20, B19, C20.

| Lane | Master pin | Flip pin | Master bank | Flip bank | Capture clock |
|------|-----------|----------|-------------|-----------|---------------|
| pad_clk_rx | **Y7** | **Y9** | 13 | 13 | n/a (BUFIO source) |
| pad_rx[0] | U7  | F19 | 13 | **35** | bufio(master) / bufg(flip) |
| pad_rx[1] | C20 | V10 | **35** | 13 | bufg(master) / bufio(flip) |
| pad_rx[2] | Y8  | V8  | 13 | 13 | bufio / bufio |
| pad_rx[3] | A20 | W10 | **35** | 13 | bufg(master) / bufio(flip) |
| pad_rx[4] | U8  | B20 | 13 | **35** | bufio(master) / bufg(flip) |
| pad_rx[5] | W6  | W8  | 13 | 13 | bufio / bufio |
| pad_rx[6] | Y6  | V6  | 13 | 13 | bufio / bufio |
| pad_rx[7] | V7  | W9  | 13 | 13 | bufio / bufio |

**Result:** master = 6 BUFIO + 2 BUFG; flip = 6 BUFIO + 2 BUFG. The two BUFG
lanes differ by index between the master and flip XDCs — the per-lane LOC
constraints therefore must be **target-directory local**, not shared.

## 4. RTL wrapper changes — `tidelink_clk_rx_buf.v`

Replace the current two-port wrapper with a two-clock-output wrapper. Note
**IBUF** (not IBUFG) is used: UG472 §3 says BUFIO accepts an IBUF/IBUFDS
driver in a clock-capable I/O; IBUFG is only required when feeding a BUFG/MMCM
through the dedicated CCIO route, and an IBUFG output **cannot** drive a BUFIO
without going through a BUFG first.

```verilog
module tidelink_clk_rx_buf (
    input  wire pad_in,        // pad_clk_rx (Y7 master / Y9 flip — bank 13 MRCC/SRCC)
    output wire clk_out_bufio, // regional clock for bank-13 RX lanes
    output wire clk_out_bufg   // global clock for bank-35 RX lanes + fabric
);
    wire w_ibuf;
    IBUF  u_ibuf  (.I(pad_in), .O(w_ibuf));
    BUFIO u_bufio (.I(w_ibuf), .O(clk_out_bufio));
    BUFG  u_bufg  (.I(w_ibuf), .O(clk_out_bufg));
endmodule
```

Caveat: Vivado normally infers an IBUFG on a top-level clock port. The XDC must
not force `IBUF_LOW_PWR` differences between the two consumers; both come off
the same IBUF.

## 5. BD TCL changes — `tidelink_design.tcl`

The packaged IP has a **single** `pad_clk_rx` port, so it cannot natively accept
two distinct RX clocks. Three options evaluated:

1. **Modify the packaged IP** to split `pad_clk_rx` into `pad_clk_rx_bufio` +
   `pad_clk_rx_bufg` and fan-out per-lane internally based on a 8-bit
   `LANE_BANK_MASK` parameter. Highest impact, requires re-package + RTL
   thread through `tidelink_top → axi_chiplet_controller → Wlink → WlinkGPIOPHY
   → WavD2DGpio`. **Recommended path** — the cap-side fan-out already pivots
   on `USE_CAP_CLKBUF` in `WavD2DGpio.v:178-248`, so the surgery is bounded.
2. Drive only the BUFIO into the IP and externally instantiate two
   ILOGIC capture flops for the bank-35 lanes ahead of the IP's pad_rx ports.
   Bypasses IP re-packaging but breaks IDELAYE2 IDATAIN since the bank-35
   IBUF would then feed both ILOGIC and IP — same Route 30-568 class of
   failure that killed the ILA build.
3. Tie the BUFG output to `tidelink_0/pad_clk_rx` (the IP's single port) and
   leave the BUFIO output dangling. This degrades to **today's behaviour**
   for bank-13 lanes — no benefit.

**Plan adopts option 1.** Concrete TCL diff:

- New BD output port on `clk_rx_buf` cell: `clk_out_bufio` + `clk_out_bufg`.
- New IP input port (after re-package): `pad_clk_rx_bufio` + `pad_clk_rx_bufg`.
- Connections:
  ```tcl
  connect_bd_net [get_bd_pins clk_rx_buf/clk_out_bufio] \
                 [get_bd_pins tidelink_0/pad_clk_rx_bufio]
  connect_bd_net [get_bd_pins clk_rx_buf/clk_out_bufg] \
                 [get_bd_pins tidelink_0/pad_clk_rx_bufg]
  ```
- Set `CONFIG.LANE_BANK_MASK {8'b…}` per target (8'b00010110 master,
  8'b00010001 flip — bit-N=1 means lane N is bank 35 → uses BUFG).

## 6. XDC — placement constraints

Force the per-lane RX `link_data_pad_clk` register and the `count` reg into
the IOB of the corresponding `pad_rx[*]` ball for the bank-13 lanes. UG903
syntax (hierarchy paths verified against the routed netlist of Build #11):

```
# Example (master, lane 0 = U7, bank 13):
set_property IOB TRUE [get_cells -hier -filter \
    {NAME =~ "*WavD2DGpio*gpiorx_0*link_data_pad_clk*"}]

# Optional: force the lane's IDELAYE2 into bank 13 site
set_property LOC IDELAY_X0Y22 [get_cells -hier -filter \
    {NAME =~ "*tidelink_idelay_rx*lane[0]*"}]
```

Repeat for all six in-bank-13 lanes per target. The bank-35 lanes get **no
LOC** — let the placer use the global BUFG distribution.

## 7. XDC — timing

New clock declarations (replacing the current `clk_rx_buf/u_bufg/O` ref):

```
create_clock -name clk_rx        -period 40.0 [get_ports pad_clk_rx]
create_generated_clock -name clk_rx_bufio -divide_by 1 \
    -source [get_pins -hier -filter {NAME =~ "*clk_rx_buf*u_ibuf/O"}] \
    [get_pins -hier -filter {NAME =~ "*clk_rx_buf*u_bufio/O"}]
create_generated_clock -name clk_rx_bufg  -divide_by 1 \
    -source [get_pins -hier -filter {NAME =~ "*clk_rx_buf*u_ibuf/O"}] \
    [get_pins -hier -filter {NAME =~ "*clk_rx_buf*u_bufg/O"}]
```

Inter-clock skew management:

```
set_max_delay  2.0 -from [get_clocks clk_rx_bufio] -to [get_clocks clk_rx_bufg]
set_max_delay  2.0 -from [get_clocks clk_rx_bufg]  -to [get_clocks clk_rx_bufio]
set_false_path -from [get_clocks clk_rx_bufio] -to [get_clocks hclk]
set_false_path -from [get_clocks clk_rx_bufg]  -to [get_clocks hclk]
```

IDELAYCTRL `refclk` (200 MHz) is unchanged — both BUFIO and BUFG fed lanes
share the same IDELAYCTRL.

## 8. Validation plan

1. `report_clocks` lists `clk_rx_bufio` and `clk_rx_bufg`.
2. `report_clock_utilization -file …` — BUFIO count = 1, located in clock-region
   X1Y2 (bank 13).
3. `report_timing_summary` — WNS > 0 on both clocks; no unconstrained paths
   on the inter-bank crossings.
4. `report_high_fanout_nets -clock_regions` — bank-35 BUFG net spans 1 region,
   BUFIO net stays in bank-13's column.
5. HW: scope re-measure pad_rx[*] eyes vs Build #12 baseline; compare
   `EYE_CRC_ERR_LO/HI` register counts at the APB level — bank-13 lanes should
   be ≥ 10× lower than bank-35 lanes under 1 minute of full-rate traffic.

## 9. Risk + rollback

**Risks:**
- IP re-package (option 1) is the riskiest piece — touches the same
  `USE_CAP_CLKBUF` generate that landed in Build #12 R3. Failure mode is the
  same as the prior `BD 41-1276` ignored-override class.
- Bank-13 routing congestion: the 200 MHz IDELAYCTRL ref + the new BUFIO + the
  existing IDELAYE2 cells all live in bank 13. May force a few flops out of
  IOB → `IOB TRUE` constraint warnings.
- BUFIO can only drive ILOGIC/IOB and not BUFG inputs — must not accidentally
  cascade.

**Rollback:** revert the wrapper to `IBUFG → BUFG`, drop the second BD port,
delete the LOC + create_generated_clock + set_max_delay lines. One git revert
per target.

**Branch strategy:** new branch `feat/bufio-bufr-rx` off the SI-hardening
branch once Build #12 (R1+R2+R3) is **HW-validated** with the scope. Do not
land before that gate — restructure rests on the cap-reduction working.

## 10. Step-by-step task list

| # | Task | Effort |
|---|------|--------|
| 1 | Re-verify bank assignments for both master/flip targets, including the 4 sibling `-mmcmbypass-*` targets | 15 min |
| 2 | Rewrite `tidelink_clk_rx_buf.v` with dual outputs; mirror to flip-target dir | 30 min |
| 3 | Add `pad_clk_rx_bufio/_bufg` ports to `tidelink_vivado_wrapper.v` + thread `LANE_BANK_MASK` through `WavD2DGpio.v` generate; re-package IP | 2-3 hrs |
| 4 | Update BD TCL: rewire wrapper + pass `LANE_BANK_MASK` per target | 30 min |
| 5 | Add `IOB TRUE` + `LOC IDELAY_*` for bank-13 lanes in `pynq_z2_tidelink.xdc` (both targets) | 1 hr |
| 6 | Add `create_generated_clock` + `set_max_delay` to `pynq_z2_tidelink_timing.xdc` | 30 min |
| 7 | First build attempt (single target, master) | 50 min |
| 8 | Debug placement / clock-region errors | 2-8 hrs |
| 9 | Second build with flip target; both bitstreams ready | 50 min |
| 10 | HW deploy via fpgahub: scope + EYE_CRC_ERR compare | 1 hr |

**Estimated total:** 1-2 working days (active effort 5-8 hrs + 1 build cycle
debug margin). Most uncertainty is in step 8 (clock-region placement) — if
the IDELAYE2 LOC clashes with the bank-13 BUFIO route, fall back to letting
the placer choose IDELAY sites and only constrain the capture flops.
