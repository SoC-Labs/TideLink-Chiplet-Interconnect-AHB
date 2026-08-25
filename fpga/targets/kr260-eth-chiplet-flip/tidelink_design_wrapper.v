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
    output wire        led1,

    // HOSTIO4 EXTIO host port, 7 bidirectional pads (M3).
    //
    // NAMED BY FUNCTION, NOT AS A BUS, ON PURPOSE. The P1 mux is handshake-first
    // (P1[0]=ioreq1, P1[1]=ioreq2, P1[2]=ioack, P1[3..6]=iodata[0..3]) while the
    // older nanosoc-simple-chiplet PYNQ-Z2 pinout is data-first. Wiring one order
    // onto the other silently puts ioack -- an INPUT here -- on a pin the host
    // drives. You cannot mis-transpose a port called hostio4_ioack; you can very
    // easily mis-transpose HOSTIO4_P1[2]. The index<->function binding therefore
    // lives in exactly one reviewable place: the IOBUF block below.
    inout  wire        hostio4_ioreq1,      // P1[0] SoC drives (OE const 1)
    inout  wire        hostio4_ioreq2,      // P1[1] SoC drives (OE const 1)
    inout  wire        hostio4_ioack,       // P1[2] host drives (OE const 0)
    inout  wire  [3:0] hostio4_iodata4      // P1[6:3] bidirectional, common nibble OE
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
    // HOSTIO4 P1[6:0] bidirectional buffers.
    //
    //   hostio4_p1_oe is P1_OUTEN from nanosoc_ss_hostio4 — ACTIVE-HIGH output
    //   enable, exactly like md_padoe_o / swdio_oe. Vivado IOBUF T is
    //   active-high tristate -> T = ~oe.
    //
    //   All 7 get an IOBUF even though, with the SoC's hardwired EXTIO mode
    //   (FT1248MODE = 1'b0, nanosoc_multicore_soc.sv:1594), three of them have a
    //   CONSTANT enable:
    //       P1[0] ioreq1  oe = 1'b1  -> synthesises to a plain OBUF
    //       P1[1] ioreq2  oe = 1'b1  -> synthesises to a plain OBUF
    //       P1[2] ioack   oe = 1'b0  -> synthesises to a plain IBUF
    //       P1[6:3] iodata  oe = {4{|fsm_state[4:2]}} -> real tristates
    //   Vivado constant-folds the T input, so the uniform loop costs no extra
    //   logic. It is written this way so the FPGA boundary matches the ASIC's
    //   (all 7 are PDDW16DGZ_G bidirectional pads) and so a future mux change
    //   needs no board-wrapper rework.
    //=========================================================================
    wire [6:0] hostio4_p1_i_int;   // sensed value into the SoC
    wire [6:0] hostio4_p1_o_int;   // SoC drive value
    wire [6:0] hostio4_p1_oe_int;  // SoC output enable (active high)

    genvar gi;
    // One IOBUF per pad, written out rather than looped: this block IS the
    // index<->function binding, so it must be readable line by line. T is
    // ACTIVE-HIGH TRISTATE and P1_OUTEN is ACTIVE-HIGH ENABLE, hence ~oe --
    // the same inversion this file already applies to SWDIO and MDIO. Dropping
    // a ~ here inverts every turnaround and presents as a dead host.
    IOBUF u_hostio4_ioreq1 (.IO(hostio4_ioreq1),    .I(hostio4_p1_o_int[0]), .O(hostio4_p1_i_int[0]), .T(~hostio4_p1_oe_int[0]));
    IOBUF u_hostio4_ioreq2 (.IO(hostio4_ioreq2),    .I(hostio4_p1_o_int[1]), .O(hostio4_p1_i_int[1]), .T(~hostio4_p1_oe_int[1]));
    IOBUF u_hostio4_ioack  (.IO(hostio4_ioack),     .I(hostio4_p1_o_int[2]), .O(hostio4_p1_i_int[2]), .T(~hostio4_p1_oe_int[2]));
    IOBUF u_hostio4_data0  (.IO(hostio4_iodata4[0]),.I(hostio4_p1_o_int[3]), .O(hostio4_p1_i_int[3]), .T(~hostio4_p1_oe_int[3]));
    IOBUF u_hostio4_data1  (.IO(hostio4_iodata4[1]),.I(hostio4_p1_o_int[4]), .O(hostio4_p1_i_int[4]), .T(~hostio4_p1_oe_int[4]));
    IOBUF u_hostio4_data2  (.IO(hostio4_iodata4[2]),.I(hostio4_p1_o_int[5]), .O(hostio4_p1_i_int[5]), .T(~hostio4_p1_oe_int[5]));
    IOBUF u_hostio4_data3  (.IO(hostio4_iodata4[3]),.I(hostio4_p1_o_int[6]), .O(hostio4_p1_i_int[6]), .T(~hostio4_p1_oe_int[6]));

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
        .led1            (led1),

        // HOSTIO4 EXTIO host port (tristates resolved by the IOBUFs above)
        .hostio4_p1_i    (hostio4_p1_i_int),
        .hostio4_p1_o    (hostio4_p1_o_int),
        .hostio4_p1_oe   (hostio4_p1_oe_int)
    );

endmodule
