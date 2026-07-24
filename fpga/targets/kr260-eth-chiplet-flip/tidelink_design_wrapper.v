//-----------------------------------------------------------------------------
// nanoSoC eth-chiplet - KR260 (Zynq UltraScale+ / K26 SOM) Board Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Synthesis top read by build_design.tcl. Instantiates the tidelink_design
// block design (PS8 + AXI->AHB backdoor + the packaged nanosoc_eth_chiplet IP)
// and applies the board-level tristates.
//
// Difference from the bare-link KR260 wrapper: the eth-chiplet contains the
// whole SoC + internal TideLink, so this wrapper also folds the CoreSight SWD
// bidirectional line (SWDIO) into an IOBUF on PMOD4. See swd_pmod4.xdc.
//
// As on the bare-link KR260 target there are NO DDR_*/FIXED_IO_* ports — the
// MPSoC PS DDR4 + MIO are bonded to the SOM and configured by the board preset
// inside the BD.
//-----------------------------------------------------------------------------

module tidelink_design_wrapper (
    // GPIO-PHY pads — KR260 Raspberry-Pi 40-pin header J21 (see kr260_eth_chiplet.xdc)
    output wire        pad_clk_tx,
    output wire  [7:0] pad_tx,
    input  wire        pad_clk_rx,
    input  wire  [7:0] pad_rx,

    // CoreSight SWD on PMOD4 (see swd_pmod4.xdc)
    input  wire        SWCLK,          // PMOD4 pin1 / L2
    inout  wire        SWDIO,          // PMOD4 pin2 / T7 (bidirectional)
    input  wire        SWD_NPORESETN,  // PMOD4 pin3 / AF7 (optional)

    // Primary UART console (bring to a spare pad or the PS-side USB-UART; XDC)
    input  wire        uart_rxd,
    output wire        uart_txd,

    // Status LEDs (active-high) — link_active / role_is_master
    output wire        led0,
    output wire        led1
);

    //=========================================================================
    // SWDIO bidirectional buffer.
    //   Drive out when the DAP asserts output-enable (swdio_oe = dap_swdoen,
    //   active-high). Vivado IOBUF T is active-high tristate, so T = ~oe.
    //=========================================================================
    wire swdio_i_int;   // sensed value into the DAP (dap_swditms)
    wire swdio_o_int;   // DAP drive value            (dap_swdo)
    wire swdio_oe_int;  // DAP output enable          (dap_swdoen)

    IOBUF u_swdio_iobuf (
        .IO (SWDIO),
        .I  (swdio_o_int),
        .O  (swdio_i_int),
        .T  (~swdio_oe_int)
    );

    //=========================================================================
    // Block Design Instance
    //=========================================================================
    tidelink_design tidelink_design_i (
        // GPIO-PHY pads
        .pad_clk_tx      (pad_clk_tx),
        .pad_tx          (pad_tx),
        .pad_clk_rx      (pad_clk_rx),
        .pad_rx          (pad_rx),

        // SWD — SWCLK/nPORESETN direct; SWDIO via the IOBUF above
        .swclk           (SWCLK),
        .swd_nporesetn   (SWD_NPORESETN),
        .swdio_i         (swdio_i_int),
        .swdio_o         (swdio_o_int),
        .swdio_oe        (swdio_oe_int),

        // UART console
        .uart_rxd        (uart_rxd),
        .uart_txd        (uart_txd),

        // Status
        .led0            (led0),
        .led1            (led1)
    );

endmodule
