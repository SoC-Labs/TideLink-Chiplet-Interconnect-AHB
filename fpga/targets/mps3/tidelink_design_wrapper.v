//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge — ARM MPS3 Board-Level Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Top-level board wrapper for the ARM MPS3 (xcku115-flvb1760-1-c) TideLink
// bring-up target.  Instantiates the Vivado block design and handles:
//
//   - 18 GPIO PHY pad connections (pad_clk_tx, pad_tx[7:0], pad_clk_rx,
//     pad_rx[7:0]) to the MPS3 FPGA-IO expansion connector pins.
//   - I2C sideband tristate (IOBUF in RTL; open-drain convention).
//   - MPS3 USER_nLED[7:0] driven from TideLink IRQ and status outputs
//     (active-low; wrapper inverts the active-high IP outputs).
//   - Active-low USER_nPB[0] (PB1) to the BD nrst port.
//   - Parasitic SH0 I/O pins declared as unused Hi-Z inputs (MPS3 TRM §A.2).
//   - Scan and DFT ports tied to 0 (FPGA bring-up, no scan insertion).
//
// No PS/PS7, DDR, or Fixed-IO — MPS3 is bare-PL.
//
// FPGA part: xcku115-flvb1760-1-c (confirmed by eth-subsystem-ahb MPS3
// bring-up in this SoCLabs tree; the Makefile placeholder xcku115-flva1517-2-e
// should be updated to match — see README.md TODO).
//
// PHY connector mapping:
//   TODO: 18 PHY pins must be confirmed against the MPS3 FPGA-IO connector
//   pinout from the board TRM (100765_0000_04_en) and the actual expansion
//   board carrying the TideLink PHY.  Current assignments in the XDC are
//   PLACEHOLDER — do not use for board bring-up without verification.
//   See mps3_tidelink.xdc for the full pin list.
//
// I/O standard:
//   PHY pads: LVCMOS33  (Shield connector with 3V3 IOREF jumper set)
//   Board signals (LEDs, pushbutton, OSCCLK): LVCMOS18
//   Set IOREF link jumpers on the MPS3 accordingly (TRM §2.16).
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tidelink_design_wrapper (
    // =========================================================================
    // Board clock and reset
    // =========================================================================

    // 24 MHz fixed board oscillator (OSCCLK[0] = AL15, LVCMOS18)
    // Feeds Clocking Wizard to derive 50 MHz hclk for TideLink.
    input  wire        OSCCLK,

    // PB1 — system reset, active-low (USER_nPB[0] = AT30, LVCMOS18)
    // Board pushbutton; passed directly as active-low nrst to the BD.
    input  wire        USER_nPB,

    // =========================================================================
    // TideLink GPIO PHY pads — FPGA-IO expansion connector
    //
    // 18 signals total:
    //   pad_clk_tx (1) — TX clock output
    //   pad_tx[7:0](8) — TX data output  (8 lanes)
    //   pad_clk_rx (1) — RX clock input
    //   pad_rx[7:0](8) — RX data input   (8 lanes)
    //
    // All assigned to the MPS3 FPGA-IO connector (TODO: confirm pinout).
    // I/O standard: LVCMOS33 (Shield connector, 3V3 IOREF).
    // =========================================================================

    // TX path — output from TideLink to external PHY
    output wire        pad_clk_tx,   // TODO: assign to FPGA-IO pin
    output wire  [7:0] pad_tx,       // TODO: assign to FPGA-IO pins [8 pins]

    // RX path — input from external PHY to TideLink
    input  wire        pad_clk_rx,   // TODO: assign to FPGA-IO pin
    input  wire  [7:0] pad_rx,       // TODO: assign to FPGA-IO pins [8 pins]

    // =========================================================================
    // I2C sideband — open-drain bidirectional
    // Board wrapper implements IOBUF (tristate) here in RTL.
    // TODO: Assign to a suitable MPS3 I/O pin pair if needed for bring-up.
    // For first bring-up, these can be left unconnected (BD ties off).
    // =========================================================================
    inout  wire        i2c_scl,      // TODO: assign pin or leave unconnected
    inout  wire        i2c_sda,      // TODO: assign pin or leave unconnected

    // =========================================================================
    // User LEDs (USER_nLED[7:0], active-low, LVCMOS18)
    //
    // The MPS3 has 10 user LEDs (USER_nLED[9:0]).
    // We use 8 for TideLink status / IRQ visibility.
    //   LED[0] = link_active        (TideLink link up and passing traffic)
    //   LED[1] = d2d_reset_o        (D2D reset asserted; blinking = not stable)
    //   LED[2] = released_credits_irq
    //   LED[3] = doorbell_irq
    //   LED[4] = packet_committed_irq
    //   LED[5] = ptp_irq
    //   LED[6] = wlink_irq
    //   LED[7] = nego_error_irq     (negotiation error — should stay off)
    //
    // Active-low convention: wrapper inverts all active-high IP outputs.
    // =========================================================================
    output wire  [7:0] USER_nLED,

    // =========================================================================
    // Parasitic I/O — MPS3 TRM §A.2
    //
    // SH0_IO[16] (AV16) and SH0_IO[17] (AT14) are wired through 4K7 resistors
    // to SH0_IO[14] and SH0_IO[15] respectively on the board connector.  If
    // any PHY pads reuse SH0_IO[14:15], these parasitic pins must be declared
    // as Hi-Z inputs (PULLTYPE NONE in XDC) to avoid bus contention.
    //
    // TODO: Audit which SH0 pins the PHY connector uses and add corresponding
    // parasitic pin declarations to both this wrapper and the XDC.
    // =========================================================================
    input  wire        SH_nRST_n    // TODO: drive HIGH if shield bus switches needed
);

    // =========================================================================
    // Internal wires from the block design
    // =========================================================================

    // IRQ / status (active-high from IP)
    wire released_credits_irq_int;
    wire doorbell_irq_int;
    wire packet_committed_irq_int;
    wire ptp_irq_int;
    wire perf_irq_int;
    wire wlink_irq_int;
    wire nego_error_irq_int;
    wire i2c_nbsy_irq_int;
    wire i2c_nrd_empty_irq_int;
    wire link_active_int;
    wire d2d_reset_o_int;

    // I2C tristate signals from BD
    wire i2c_scl_i_int;
    wire i2c_scl_o_int;
    wire i2c_scl_t_int;
    wire i2c_sda_i_int;
    wire i2c_sda_o_int;
    wire i2c_sda_t_int;

    // =========================================================================
    // I2C open-drain tristate (Vivado convention: _t=1 => Hi-Z)
    // =========================================================================
    assign i2c_scl   = i2c_scl_t_int ? 1'bz : i2c_scl_o_int;
    assign i2c_scl_i_int = i2c_scl;

    assign i2c_sda   = i2c_sda_t_int ? 1'bz : i2c_sda_o_int;
    assign i2c_sda_i_int = i2c_sda;

    // =========================================================================
    // Shield bus switch — drive HIGH to enable SN74TVC16222 pass transistors
    // on the MPS3 Shield/PMOD path.  Without this, all shield signals are
    // isolated from the FPGA.  The XDC drives SH_nRST to AU14 LVCMOS33.
    // NOTE: This wrapper port is output-only; declare as output in the real
    // implementation.  Declared as input here as a placeholder to avoid
    // synthesis errors before the XDC TODO pins are resolved.
    // TODO: Change to output wire and assign 1'b1 once pin is confirmed.
    // =========================================================================
    // assign SH_nRST_n = 1'b1; // Enable shield bus switches

    // =========================================================================
    // Block design instance
    // =========================================================================
    tidelink_design tidelink_design_i (
        // Board clock + reset
        .OSCCLK                 (OSCCLK),
        .nrst                   (USER_nPB),      // PB1 active-low -> BD nrst (active-low)

        // GPIO PHY pads — routed to FPGA-IO connector via XDC
        .pad_clk_tx             (pad_clk_tx),
        .pad_tx                 (pad_tx),
        .pad_clk_rx             (pad_clk_rx),
        .pad_rx                 (pad_rx),

        // I2C sideband tristate signals
        .i2c_scl_i              (i2c_scl_i_int),
        .i2c_scl_o              (i2c_scl_o_int),
        .i2c_scl_t              (i2c_scl_t_int),
        .i2c_sda_i              (i2c_sda_i_int),
        .i2c_sda_o              (i2c_sda_o_int),
        .i2c_sda_t              (i2c_sda_t_int),

        // IRQ / status outputs
        .released_credits_irq   (released_credits_irq_int),
        .doorbell_irq            (doorbell_irq_int),
        .packet_committed_irq   (packet_committed_irq_int),
        .ptp_irq                 (ptp_irq_int),
        .perf_irq                (perf_irq_int),
        .wlink_irq               (wlink_irq_int),
        .nego_error_irq          (nego_error_irq_int),
        .i2c_nbsy_irq            (i2c_nbsy_irq_int),
        .i2c_nrd_empty_irq       (i2c_nrd_empty_irq_int),
        .link_active             (link_active_int),
        .d2d_reset_o             (d2d_reset_o_int)
    );

    // =========================================================================
    // LED outputs — invert active-high IP signals to drive active-low MPS3 LEDs
    //
    // LED assignment (rationale: show link health at a glance):
    //   [0] link_active           — solid when D2D link is up
    //   [1] d2d_reset_o           — flickers during D2D reset / bring-up
    //   [2] released_credits_irq  — credit return traffic
    //   [3] doorbell_irq          — doorbell received (remote chiplet activity)
    //   [4] packet_committed_irq  — RX packet committed
    //   [5] ptp_irq               — PTP event
    //   [6] wlink_irq             — Wlink controller event
    //   [7] nego_error_irq        — negotiation error (should stay off)
    // =========================================================================
    assign USER_nLED[0] = ~link_active_int;
    assign USER_nLED[1] = ~d2d_reset_o_int;
    assign USER_nLED[2] = ~released_credits_irq_int;
    assign USER_nLED[3] = ~doorbell_irq_int;
    assign USER_nLED[4] = ~packet_committed_irq_int;
    assign USER_nLED[5] = ~ptp_irq_int;
    assign USER_nLED[6] = ~wlink_irq_int;
    assign USER_nLED[7] = ~nego_error_irq_int;

endmodule
