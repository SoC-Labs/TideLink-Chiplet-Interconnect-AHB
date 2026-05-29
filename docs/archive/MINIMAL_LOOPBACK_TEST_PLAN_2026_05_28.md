# Minimal Loopback / Echo Test Plan for PYNQ-Z2 Ribbon Cable Validation

**Date:** 2026-05-28
**Branch:** `feat/minimal-loopback-plan`
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter/`
**Goal:** Decide whether the residual TideLink bring-up issues live in our RTL stack (calibrator + Wlink + chiplet-controller) or in the **physical interconnect** (J13 ribbon, J13 pad SI, board-pair voltage / ground reference, clock-forwarding integrity).

---

## 1. Reference-design search (Option A) — verdict: **no reusable IP found**

I ran four targeted web searches and visited the most plausible hits.

| Query | Useful hit? | Verdict |
|---|---|---|
| `PYNQ-Z2 ribbon cable Pmod GPIO loopback test bitstream chip-to-chip board reference design` | Digilent / PYNQ Pmod docs, [PYNQ Verification](https://pynq.readthedocs.io/en/v2.1/verification.html), [Pmod cable loopback note](https://pynq.readthedocs.io/en/v2.1/pynq_libraries/pmod.html) | The Pmod "loopback" referenced is the **`cable='loopback'`** Python argument to `pynq.lib.pmod`, i.e. internal pin swap when a twisted cable is used. Not a bitstream/RTL design. |
| `Digilent Vivado PYNQ Pmod loopback LFSR forwarded clock signal integrity test` | [Digilent PYNQ-Z1 reference manual](https://digilent.com/reference/programmable-logic/pynq-z1/reference-manual), [Digilent GitHub](https://github.com/digilent) | All Digilent reference designs that I could locate target peripheral interfacing (PmodAD/DA, OLEDrgb, ACL, CAN, …). **No board-to-board ribbon-cable BERT / eye-test demo** in the Digilent or Xilinx universe. |
| `Xilinx 7-series source-synchronous SDR LVCMOS PRBS BERT eye diagnostic GPIO link test github` | [Kria BIST GPIO module](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/bist/docs/modules/gpio.html), [XAPP1240 K7 clock-data recovery](https://static.eetrend.com/files/2022-11/wen_zhang_/100565478-277755-xapp1240-k7-us-clk-data-recovery.pdf), AVED multi-GT PRBS | Kria BIST GPIO is a single-board self-loopback that toggles a pad and reads it back — does NOT exercise a forwarded clock between two boards. XAPP1240 covers MGT serial CDR, not source-sync LVCMOS GPIO. AVED PRBS is GTYp / SerDes only. |
| `FPGA chip-to-chip GPIO forwarded clock PRBS checker SystemVerilog open source project` | [aolofsson/oh](https://github.com/aolofsson/oh) (high-speed-link IP), [opencores PRBS gen/checker](https://github.com/klyone/opencores-ip) | `aolofsson/oh` ships generic LFSR + io_send/io_recv blocks, but **no PYNQ-targeted top + XDC**. The opencores PRBS bits are unwrapped scraped sources, not a buildable Vivado project. |

**Conclusion:** No drop-in design exists at the granularity we want (PYNQ-Z2 pair, same bitstream both sides, J13 ribbon, our exact pin map). Cost to *adapt* `aolofsson/oh` or the opencores LFSR is similar to writing it from scratch (~150 lines), and avoids the licence / vendor-clean-room friction of pulling third-party RTL into a TideLink subtree.

**Recommendation: go with Option B (minimal in-house design).**

---

## 2. Option B — minimal in-house design

### 2.1 Architecture

```
        ┌─────────────────────────────  PYNQ-Z2 (same bitstream both sides)  ──────────────────────────┐
        │                                                                                              │
PS7 ───┤ FCLK_CLK0 ──► clk_wiz ──► hclk (50 MHz)  ──► loopback_top                                    │
        │                                          │                                                   │
        │                                          │   role_strap_i (Y16 pmod_b_trig with PULLDOWN)    │
        │                                          │     0 = SLAVE (RX-only, drives pad_tx=Hi-Z…OK)    │
        │                                          │     1 = MASTER (drives pad_clk_tx + pad_tx)       │
        │                                          │                                                   │
        │   TX (master role)                       │                                                   │
        │     hclk ─► ODDR(.D1(1'b1),.D2(1'b0))  ──► pad_clk_tx (Y9)                                   │
        │     8x LFSR-7 (per-lane seed)          ──► pad_tx[7:0]                                       │
        │                                                                                              │
        │   RX (slave role)                                                                            │
        │     pad_clk_rx (Y7, MRCC) ─► BUFG ──► rxclk domain                                           │
        │     pad_rx[7:0]           ──FF── @rxclk ──► compare against same-seeded LFSR-7 predictor    │
        │     per-lane lock counter (16 consecutive matches → lane_lock)                              │
        │     per-lane error counter (saturating 32-bit)                                              │
        │                                                                                              │
        │   LEDs                                                                                       │
        │     led0 = &lane_lock        (all 8 lanes locked)                                            │
        │     led1 = (sum(err)==0)     (no errors ever)                                                │
        │     led2 = (sum(err) > 1024) (heavy errors)                                                  │
        │     led3 = hclk/2^24         (heartbeat — proves bitstream is alive)                         │
        └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Key design choices:

| Decision | Rationale |
|---|---|
| 50 MHz `hclk` (from PS FCLK/clk_wiz, same as TideLink) | Same edge-rate as the real link → same SI envelope |
| Source-synchronous via `ODDR(D1=1,D2=0)` for `pad_clk_tx` | Tight, ~symmetric edges; identical pattern to TideLink's existing tx_clkbuf path |
| TX data registered in `hclk` domain, `OBUF` only on output (no ODDR on data) | SDR @ 50 MHz; matches TideLink lane behaviour |
| RX samples on rising edge of recovered `pad_clk_rx` via dedicated BUFG | Mirrors the way TideLink intends the data eye to align |
| Per-lane LFSR-7 (`x^7 + x^6 + 1`) | Cheap, 8 FF/lane, no shared seed CDC; 127-bit pattern long enough to expose ISI; per-lane seeds make a stuck-at-X lane unambiguous |
| Strap on Y16 (existing `pmod_b_trig`) | Reuses the cross-board jumper wire we already plumb. Pull-down keeps slave default; master jumpers Y16 high. **Optionally**, use a runtime AXI-GPIO strap like our existing pair-all flow — see §2.5. |
| Same bitstream both sides | Two XDC variants (`pair-all` mirror and `pair-flip-all` mirror) — pin map flips, RTL doesn't |
| **No** AXI / MMIO required to run | LEDs + cross-strap are sufficient to declare GO/NO-GO; UART/MMIO optional for error-count read-out |

### 2.2 Verilog source (single file, ~180 lines including comments)

```systemverilog
//-----------------------------------------------------------------------------
// minimal_loopback_top.v
//   PYNQ-Z2 ribbon-cable / clock-forwarding signal-integrity test bitstream.
//   Strips away TideLink calibrator + Wlink + chiplet-controller. Same
//   bitstream programs master and slave; strap pin selects role.
//
//   * MASTER drives pad_clk_tx (ODDR 1/0) and pad_tx[7:0] (per-lane LFSR-7).
//   * SLAVE samples pad_rx[7:0] on rising edge of pad_clk_rx (BUFG'd).
//     A same-seeded LFSR-7 predictor runs locally; comparison drives the
//     per-lane error counter and lane_lock flag.
//
//   LEDs (active-high, accent-green):
//     led0 = &lane_lock              -- all 8 lanes locked
//     led1 = (|err_any) == 1'b0      -- no errors yet
//     led2 = err_sum > 32'd1024      -- "lots of errors"
//     led3 = heartbeat (hclk / 2^24) -- proves bitstream is alive
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module minimal_loopback_top (
    // PS7 clock + reset (from clk_wiz / proc_sys_reset in the BD)
    input  wire        hclk,        // 50 MHz
    input  wire        hresetn,     // active-low, sync to hclk

    // PHY pads (mapped by the XDC; flip XDC swaps TX/RX assignments)
    output wire        pad_clk_tx,
    output wire [7:0]  pad_tx,
    input  wire        pad_clk_rx,
    input  wire [7:0]  pad_rx,

    // Strap (Y16 PMOD-B, PULLDOWN per XDC: 0 = slave, 1 = master)
    input  wire        role_strap_i,

    // LEDs
    output wire        led0,
    output wire        led1,
    output wire        led2,
    output wire        led3
);

    // -------- Role latch (combinational read of pull-down/up'd Y16) --------
    wire is_master = role_strap_i;

    // -------- Per-lane LFSR-7 seeds (avoid all-zero, distinct per lane) ----
    // Seeds chosen so adjacent lanes diverge after one shift — makes a
    // stuck-at-neighbour cross-talk failure visible.
    localparam [6:0] SEED [0:7] = '{7'h7F, 7'h2A, 7'h55, 7'h0F,
                                    7'h33, 7'h6C, 7'h17, 7'h41};

    // ==================================================================
    // MASTER TX PATH (in hclk domain)
    // ==================================================================
    reg  [6:0] tx_lfsr [0:7];
    reg  [7:0] tx_data_q;
    integer    i;
    always @(posedge hclk) begin
        if (!hresetn) begin
            for (i = 0; i < 8; i = i + 1) tx_lfsr[i] <= SEED[i];
            tx_data_q <= 8'h00;
        end else if (is_master) begin
            for (i = 0; i < 8; i = i + 1) begin
                // x^7 + x^6 + 1 (Fibonacci, period 127)
                tx_lfsr[i] <= {tx_lfsr[i][5:0],
                               tx_lfsr[i][6] ^ tx_lfsr[i][5]};
                tx_data_q[i] <= tx_lfsr[i][6];
            end
        end
    end

    // Drive pad_tx via plain OBUF; ODDR-on-data not needed for 50 MHz SDR.
    // When is_master=0 we still register zeros (slave's pad_tx is unused
    // because the FLIP XDC re-assigns the pins to RX-direction).
    assign pad_tx = tx_data_q;

    // Forwarded clock via ODDR (D1=1 on rising edge of hclk, D2=0 on falling)
    wire pad_clk_tx_int;
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
    ) u_clk_oddr (
        .Q  (pad_clk_tx_int),
        .C  (hclk),
        .CE (1'b1),
        .D1 (is_master),   // gate the clock when slave — keeps line quiet
        .D2 (1'b0),
        .R  (~hresetn), .S(1'b0)
    );
    assign pad_clk_tx = pad_clk_tx_int;

    // ==================================================================
    // SLAVE RX PATH (in rxclk domain — recovered pad_clk_rx via BUFG)
    // ==================================================================
    wire rxclk;
    BUFG u_rxclk_bufg (.I(pad_clk_rx), .O(rxclk));

    // hresetn deasserted by the BD's proc_sys_reset; bring it into the
    // rxclk domain with a 2-FF synchroniser. Lock counters live in rxclk.
    reg [1:0] rxrst_sync;
    always @(posedge rxclk) rxrst_sync <= {rxrst_sync[0], hresetn};
    wire rxrstn = rxrst_sync[1];

    reg  [6:0] rx_lfsr   [0:7];
    reg  [7:0] rx_sample_q;
    reg  [4:0] lock_cnt  [0:7];    // 5-bit -> 16 = locked
    reg        lane_lock [0:7];
    reg [31:0] err_cnt   [0:7];    // saturating
    integer    j;

    always @(posedge rxclk) begin
        if (!rxrstn) begin
            for (j = 0; j < 8; j = j + 1) begin
                rx_lfsr  [j] <= SEED[j];
                lock_cnt [j] <= 5'd0;
                lane_lock[j] <= 1'b0;
                err_cnt  [j] <= 32'd0;
            end
            rx_sample_q <= 8'h00;
        end else begin
            rx_sample_q <= pad_rx;
            for (j = 0; j < 8; j = j + 1) begin
                // expected = top bit of local lfsr, BEFORE shifting
                if (rx_sample_q[j] == rx_lfsr[j][6]) begin
                    if (!lane_lock[j])
                        lock_cnt[j] <= lock_cnt[j] + 5'd1;
                    if (lock_cnt[j] == 5'd15) lane_lock[j] <= 1'b1;
                end else begin
                    lock_cnt [j] <= 5'd0;
                    lane_lock[j] <= 1'b0;
                    if (err_cnt[j] != 32'hFFFF_FFFF)
                        err_cnt[j] <= err_cnt[j] + 32'd1;
                end
                // advance predictor LFSR every rx beat
                rx_lfsr[j] <= {rx_lfsr[j][5:0],
                               rx_lfsr[j][6] ^ rx_lfsr[j][5]};
            end
        end
    end

    // ==================================================================
    // LED aggregation (cross from rxclk back to hclk with a 2-FF sync)
    // ==================================================================
    wire all_lock_rx = lane_lock[0] & lane_lock[1] & lane_lock[2] & lane_lock[3]
                     & lane_lock[4] & lane_lock[5] & lane_lock[6] & lane_lock[7];

    wire any_err_rx = |{err_cnt[0][31:0], err_cnt[1][31:0], err_cnt[2][31:0],
                        err_cnt[3][31:0], err_cnt[4][31:0], err_cnt[5][31:0],
                        err_cnt[6][31:0], err_cnt[7][31:0]};

    // sum-of-errors threshold check stays in rxclk to avoid a 256-bit CDC.
    // Approximate "lots" with "any lane > 128" — same outcome, 1 OR-tree.
    wire heavy_err_rx = |{err_cnt[0][31:7], err_cnt[1][31:7], err_cnt[2][31:7],
                          err_cnt[3][31:7], err_cnt[4][31:7], err_cnt[5][31:7],
                          err_cnt[6][31:7], err_cnt[7][31:7]};

    reg [2:0] led_sync_a, led_sync_b;
    always @(posedge hclk) begin
        led_sync_a <= {heavy_err_rx, any_err_rx, all_lock_rx};
        led_sync_b <= led_sync_a;
    end
    assign led0 =  led_sync_b[0];   // all locked
    assign led1 = ~led_sync_b[1];   // no errors
    assign led2 =  led_sync_b[2];   // heavy errors

    // Heartbeat (proves the bitstream is loaded and clk is alive)
    reg [23:0] hb;
    always @(posedge hclk) hb <= hb + 24'd1;
    assign led3 = hb[23];

endmodule
```

**Line count (excluding boilerplate header):** ~165 lines. Within the 200-line budget.

### 2.3 XDC variants

Both mirror the existing TideLink files. Only `pad_*` differ; LEDs / strap / config are identical.

**`pynq-z2-loopback-min-pair-all/pynq_z2_loopback.xdc`** (master / "die_a" / straight side):
```tcl
# Pad map: identical to pynq-z2-pair-all
set_property -dict {PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports pad_clk_tx]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[0]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[1]}]
set_property -dict {PACKAGE_PIN V8  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[2]}]
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[3]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[4]}]
set_property -dict {PACKAGE_PIN W8  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[5]}]
set_property -dict {PACKAGE_PIN V6  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[6]}]
set_property -dict {PACKAGE_PIN W9  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[7]}]

set_property -dict {PACKAGE_PIN Y7  IOSTANDARD LVCMOS33} [get_ports pad_clk_rx]
set_property -dict {PACKAGE_PIN U7  IOSTANDARD LVCMOS33} [get_ports {pad_rx[0]}]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33} [get_ports {pad_rx[1]}]
set_property -dict {PACKAGE_PIN Y8  IOSTANDARD LVCMOS33} [get_ports {pad_rx[2]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {pad_rx[3]}]
set_property -dict {PACKAGE_PIN U8  IOSTANDARD LVCMOS33} [get_ports {pad_rx[4]}]
set_property -dict {PACKAGE_PIN W6  IOSTANDARD LVCMOS33} [get_ports {pad_rx[5]}]
set_property -dict {PACKAGE_PIN Y6  IOSTANDARD LVCMOS33} [get_ports {pad_rx[6]}]
set_property -dict {PACKAGE_PIN V7  IOSTANDARD LVCMOS33} [get_ports {pad_rx[7]}]

# Strap (master/slave) — pulled DOWN, so slave by default.
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports role_strap_i]

set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led3]

create_clock -period 20.000 -name pad_clk_rx [get_ports pad_clk_rx]

set_property CFGBVS VCCO          [current_design]
set_property CONFIG_VOLTAGE 3.3   [current_design]
```

**`pynq-z2-loopback-min-pair-flip-all/pynq_z2_loopback.xdc`** (slave / "die_b" / flip side) — same body, but TX and RX `PACKAGE_PIN` blocks **swap** (Y7+U7..V7 become TX; Y9+F19..W9 become RX). This is byte-for-byte the mirror of `pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc` with `pad_clk_tx`/`pad_clk_rx`/`pad_tx`/`pad_rx` retaining the same RTL names — only the XDC pin assignments flip.

### 2.4 `vivado_create_project.tcl` (build flow)

Reuse the existing `fpga/Makefile` mechanism. Two new TARGETs:

```tcl
# fpga/targets/pynq-z2-loopback-min-pair-all/loopback_design.tcl
proc create_root_design {parentCell} {
    current_bd_instance $parentCell

    # Zynq PS7 — minimal config, just need FCLK_CLK0 + FCLK_RESET0_N
    set ps7 [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0]
    set_property -dict [list \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
        CONFIG.PCW_USE_M_AXI_GP0            {0} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT     {0} \
    ] $ps7

    # Clocking wizard 100 -> 50 MHz
    set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ               {100.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
        CONFIG.NUM_OUT_CLKS               {1} \
        CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
        CONFIG.RESET_PORT                 {resetn} \
    ] $clk_wiz

    set psr [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset:5.0 psr_0]

    # External ports
    create_bd_port -dir O          pad_clk_tx
    create_bd_port -dir O -from 7 -to 0 pad_tx
    create_bd_port -dir I          pad_clk_rx
    create_bd_port -dir I -from 7 -to 0 pad_rx
    create_bd_port -dir I          role_strap_i
    create_bd_port -dir O          led0
    create_bd_port -dir O          led1
    create_bd_port -dir O          led2
    create_bd_port -dir O          led3

    # PS7 plumbing
    connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0]      [get_bd_pins clk_wiz_0/clk_in1]
    connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N]  [get_bd_pins clk_wiz_0/resetn] \
                                                       [get_bd_pins psr_0/ext_reset_in]
    connect_bd_net [get_bd_pins clk_wiz_0/locked]     [get_bd_pins psr_0/dcm_locked]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]   [get_bd_pins psr_0/slowest_sync_clk]

    # Instantiate the loopback RTL (added via filelist.tcl)
    set lt [create_bd_cell -type module -reference minimal_loopback_top loopback_top_0]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1]      [get_bd_pins loopback_top_0/hclk]
    connect_bd_net [get_bd_pins psr_0/peripheral_aresetn] [get_bd_pins loopback_top_0/hresetn]
    connect_bd_net [get_bd_ports pad_clk_rx]              [get_bd_pins loopback_top_0/pad_clk_rx]
    connect_bd_net [get_bd_ports pad_rx]                  [get_bd_pins loopback_top_0/pad_rx]
    connect_bd_net [get_bd_ports role_strap_i]            [get_bd_pins loopback_top_0/role_strap_i]
    connect_bd_net [get_bd_pins loopback_top_0/pad_clk_tx][get_bd_ports pad_clk_tx]
    connect_bd_net [get_bd_pins loopback_top_0/pad_tx]    [get_bd_ports pad_tx]
    connect_bd_net [get_bd_pins loopback_top_0/led0]      [get_bd_ports led0]
    connect_bd_net [get_bd_pins loopback_top_0/led1]      [get_bd_ports led1]
    connect_bd_net [get_bd_pins loopback_top_0/led2]      [get_bd_ports led2]
    connect_bd_net [get_bd_pins loopback_top_0/led3]      [get_bd_ports led3]

    # Tie off DDR/FixedIO (Zynq PS pass-through)
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
    create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO
    connect_bd_intf_net [get_bd_intf_ports DDR]      [get_bd_intf_pins ps7_0/DDR]
    connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins ps7_0/FIXED_IO]

    validate_bd_design
    save_bd_design
}
```

Hook into `fpga/Makefile`:
```make
VALID_TARGETS += pynq-z2-loopback-min-pair-all pynq-z2-loopback-min-pair-flip-all
```

### 2.5 Optional: AXI-GPIO runtime strap

If we want the strap to be writable from PYNQ python at runtime (mirroring our existing `axi_gpio_strap` at `0x4404_0000`), add a single `axi_gpio` slave at `0x4404_0000` and OR its bit-0 with the physical Y16 strap inside the RTL. ~30 lines extra and avoids re-cabling the boards. **Recommend doing this**, since fpgahub already injects `$FPGAHUB_LOCAL_ROLE` and we get the same deploy ergonomics as TideLink.

---

## 3. GO / NO-GO interpretation

| Observation | Meaning |
|---|---|
| Both boards: `led3` heartbeat blinking | Bitstream loaded, hclk alive — known-good baseline |
| Both boards: `led0` ON, `led1` ON | **Ribbon + clock-forwarding are SIGNAL-INTEGRITY-CLEAN.** Our residual bring-up issues live in TideLink RTL (calibrator / Wlink / FCSM / chiplet-controller). |
| Master: `led0` OFF on slave, `led2` ON on slave | **Physical link is bit-flipping.** Could be: (a) ribbon-cable bad / partly broken (try a known-good one), (b) Y9→Y7 clock-forwarding skew is excessive at 50 MHz, (c) board ground reference is floating. Drop to 25 MHz with `CLKOUT1_REQUESTED_OUT_FREQ {25.000}` rebuild — if it locks at 25 MHz but not 50, it's edge-rate / SI. |
| One lane stuck (`led0` off, only certain `err_cnt[i]` growing) | Per-lane fault — typically one bad ribbon conductor or one bad J13 pad. Bisect by lane index. (We already did this for the F20/B19 case → W9/V7 remap.) |
| `led3` not blinking on slave | Slave is not getting hclk OR strap is mis-tied (Y16 floating high?). Verify clk_wiz `locked` and the PS DDR config. |

---

## 4. Effort estimate

| Step | Effort | Notes |
|---|---|---|
| 1. Create RTL + 2 XDCs + BD tcl on `feat/minimal-loopback-rtl` | **2-3 h** | Mostly mechanical from this plan; one new src file + two new target dirs |
| 2. Local Vivado smoke (`make TARGET=pynq-z2-loopback-min-pair-all build_design`) | **0.5 h** to launch + **~15-20 min** Vivado wall-clock (no TideLink IP packaging, no PHC IP) | Expect 1-2 fix-up iterations on XDC syntax / port names — XDC verifier already exists at `fpga/scripts/verify_xdc.tcl` |
| 3. fpgahub action plumbing (deploy + read LEDs over JTAG/UART) | **1-2 h** | Mirror an existing simple TideLink action; no MMIO needed if we read LEDs visually. Optionally read err_cnt via AXI-GPIO if §2.5 is taken |
| 4. First HW deploy + interpret | **0.5 h** | Same fpgahub `granted` lease pattern as the pair-all flow |
| **Total to first HW result** | **4-6 hours of human-driven work** | + ~30 minutes total Vivado build wall-clock |

**Comparison to a TideLink build:** TideLink builds run 35-50 min and the design has ~1,500 cells + Wlink/PHC/chiplet-controller. This loopback bitstream is **<100 cells in the user fabric**, so synth+impl runs ~15-20 min as forecast. Likely first deploy is **same-day** if started in the morning.

---

## 5. Why this isolates the question we care about

The current symptom on `feat/calibrator-bug-fix` is: AUTOCAL=1 master→slave is asymmetric in sim (`pynq-z2-pair-flip-ila`), 16/16 locks **only with `AUTOCAL_ENABLE(1'b0)`** in hardware on this calibrator branch. We've assumed this is the calibrator phase-pickup, but we have **never** independently verified that the J13 ribbon at 50 MHz is delivering a clean 8-bit-wide 50 MHz parallel bus in the **absence** of the calibrator + Wlink + FCSM machinery. If this minimal loopback shows `led0 + led1` both ON on both boards across a 60-second window, **the physical interconnect is exonerated** and we can be confident the bug is in the RTL stack. If the minimal loopback also fails, we have a much simpler stimulus to debug — and we know the calibrator can't possibly be the culprit (because it doesn't exist in this image).

---

## 6. Out of scope

- No AXI / PYNQ MMIO read-back of `err_cnt[*]` (visual LED reading is enough for a GO/NO-GO). Add §2.5 if we want numerical eye-margin curves later.
- No per-bit eye scan (would need `IDELAYE2` + sweep; we already have that in `tidelink_phy_align_calibrator.sv`).
- No `pmod_b_trig` PHC capture — this is a pure SI test, not a PTP test.

## 7. Sources consulted

- [pynq.lib.pmod (cable loopback)](https://pynq.readthedocs.io/en/v2.1/pynq_libraries/pmod.html)
- [PYNQ Verification page](https://pynq.readthedocs.io/en/v2.1/verification.html)
- [Digilent PYNQ-Z1 reference manual](https://digilent.com/reference/programmable-logic/pynq-z1/reference-manual)
- [Digilent GitHub](https://github.com/digilent)
- [Kria KV260 BIST GPIO Test Module](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/bist/docs/modules/gpio.html)
- [Xilinx XAPP1240 K7 clock-data recovery](https://static.eetrend.com/files/2022-11/wen_zhang_/100565478-277755-xapp1240-k7-us-clk-data-recovery.pdf)
- [Andreas Olofsson's "oh" Verilog library](https://github.com/aolofsson/oh)
- [klyone/opencores-ip (PRBS gen+checker)](https://github.com/klyone/opencores-ip)
- Local XDC reference: `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc`, `fpga/targets/pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc`

