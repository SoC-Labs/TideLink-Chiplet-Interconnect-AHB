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
// bidirectional line (SWDIO) into an IOBUF on PMOD2 (3.3V). Pins live in
// kr260_eth_chiplet_tidelink.xdc.
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

    // CoreSight SWD on PMOD2, 3.3V (pins in kr260_eth_chiplet_tidelink.xdc)
    input  wire        SWCLK,          // PMOD2 pin1 / J11
    inout  wire        SWDIO,          // PMOD2 pin2 / J10 (bidirectional)
    input  wire        SWD_NPORESETN,  // PMOD2 pin3 / K13 (optional)

    // LAN8720 RMII PHY on PMOD1 (TX1 overflows to PMOD2 pin4) — see XDC
    input  wire        rmii_ref_clk,   // PHY REF_CLK_OUT, 50 MHz
    output wire  [1:0] rmii_txd,       // txd[1] = PMOD2 pin4 (K12)
    output wire        rmii_tx_en,
    input  wire  [1:0] rmii_rxd,
    input  wire        rmii_crs_dv,
    output wire        mdc_pad_o,      // MDC
    inout  wire        MDIO,           // bidirectional management data

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
    // MDIO bidirectional buffer.
    //   md_padoe_o is ACTIVE-HIGH output enable (OpenCores eth_top: "Signal was
    //   always active high"). Vivado IOBUF T is active-high tristate -> T = ~oe.
    //=========================================================================
    wire md_pad_i_int;    // sensed value into the MAC
    wire md_pad_o_int;    // MAC drive value
    wire md_padoe_o_int;  // MAC output enable (active high)

    IOBUF u_mdio_iobuf (
        .IO (MDIO),
        .I  (md_pad_o_int),
        .O  (md_pad_i_int),
        .T  (~md_padoe_o_int)
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

        // RMII PHY + MDIO (MDIO tristate resolved by the IOBUF above)
        .rmii_ref_clk    (rmii_ref_clk),
        .rmii_txd        (rmii_txd),
        .rmii_tx_en      (rmii_tx_en),
        .rmii_rxd        (rmii_rxd),
        .rmii_crs_dv     (rmii_crs_dv),
        .mdc_pad_o       (mdc_pad_o),
        .md_pad_i        (md_pad_i_int),
        .md_pad_o        (md_pad_o_int),
        .md_padoe_o      (md_padoe_o_int),

        // UART console
        .uart_rxd        (uart_rxd),
        .uart_txd        (uart_txd),

        // Status
        .led0            (led0),
        .led1            (led1)
    );

endmodule
