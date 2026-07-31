//-----------------------------------------------------------------------------
// nanoSoC compute-chiplet - KR260 (Zynq UltraScale+ / K26 SOM) Board Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Synthesis top read by build_design.tcl. Instantiates the tidelink_design
// block design (PS8 + AXI->AHB ps_ahb_s backdoor + the packaged
// nanosoc_compute_chiplet IP) and applies the board-level tristates.
//
// Two-link sibling of the eth-chiplet board wrapper. The compute chiplet contains
// the whole SoC + TWO internal TideLinks; only LINK 0 reaches the board here
// (link 1 is tied off inside the BD). This wrapper folds FOUR bidirectional lines
// into IOBUFs on the KR260 3.3V pins:
//   - i2c0_scl / i2c0_sda : LINK 0 TideLink I2C sideband (J21)
//   - swdio               : CoreSight SWDIO (PMOD2)
//   - jtag_tdo            : CoreSight JTAG TDO with output-enable (PMOD2)
// Board port names match kr260_compute_chiplet_tidelink.xdc (constraints agent).
//
// As on the eth-chiplet / bare-link KR260 targets there are NO DDR_*/FIXED_IO_*
// ports — the MPSoC PS DDR4 + MIO are bonded to the SOM and configured by the
// board preset inside the BD.
//-----------------------------------------------------------------------------

module tidelink_design_wrapper (
    // LINK 0 GPIO-PHY pads — KR260 Raspberry-Pi 40-pin header J21 (see XDC)
    output wire        pad_clk_tx_0,
    output wire  [7:0] pad_tx_0,
    input  wire        pad_clk_rx_0,
    input  wire  [7:0] pad_rx_0,

    // LINK 0 TideLink I2C sideband on J21 (bidirectional, open-drain)
    inout  wire        i2c0_scl,
    inout  wire        i2c0_sda,

    // CoreSight SWJ-DP on PMOD2, 3.3V (pins in kr260_compute_chiplet_tidelink.xdc)
    input  wire        swclk,          // SWCLK
    inout  wire        swdio,          // SWDIO (bidirectional)
    input  wire        jtag_tdi,       // JTAG TDI
    inout  wire        jtag_tdo,       // JTAG TDO (output w/ enable -> IOBUF)
    input  wire        jtag_ntrst,     // JTAG nTRST

    // Primary UART console
    input  wire        uart_rxd,
    output wire        uart_txd,

    // Status LEDs (active-high) — link_active_0 / role_is_master_0
    output wire        led0,
    output wire        led1
);

    //=========================================================================
    // LINK 0 I2C bidirectional buffers.
    //   The chiplet's i2c_*_t is a Hi-Z enable (1 = float), i.e. already in Vivado
    //   IOBUF T sense (T=1 -> Hi-Z). So T = i2c_*_t DIRECTLY (no inversion).
    //=========================================================================
    wire i2c_scl_i_int, i2c_scl_o_int, i2c_scl_t_int;
    wire i2c_sda_i_int, i2c_sda_o_int, i2c_sda_t_int;

    IOBUF u_i2c0_scl_iobuf (
        .IO (i2c0_scl),
        .I  (i2c_scl_o_int),
        .O  (i2c_scl_i_int),
        .T  (i2c_scl_t_int)
    );
    IOBUF u_i2c0_sda_iobuf (
        .IO (i2c0_sda),
        .I  (i2c_sda_o_int),
        .O  (i2c_sda_i_int),
        .T  (i2c_sda_t_int)
    );

    //=========================================================================
    // SWDIO bidirectional buffer.
    //   Drive out when the DAP asserts output-enable (swdio_oe = dap_swdoen,
    //   ACTIVE-HIGH). Vivado IOBUF T is active-high tristate, so T = ~oe.
    //=========================================================================
    wire swdio_i_int;   // sensed value into the DAP (dap_swditms)
    wire swdio_o_int;   // DAP drive value            (dap_swdo)
    wire swdio_oe_int;  // DAP output enable          (dap_swdoen, active high)

    IOBUF u_swdio_iobuf (
        .IO (swdio),
        .I  (swdio_o_int),
        .O  (swdio_i_int),
        .T  (~swdio_oe_int)
    );

    //=========================================================================
    // JTAG TDO tristate buffer.
    //   jtag_tdo_t carries dap_ntdoen (ACTIVE-LOW output enable): ntdoen=1 -> Hi-Z,
    //   ntdoen=0 -> drive. That is exactly Vivado IOBUF T sense, so T = jtag_tdo_t
    //   DIRECTLY (no inversion). The IOBUF O (input) side is unused (TDO is output).
    //=========================================================================
    wire jtag_tdo_o_int;   // DAP drive value    (dap_tdo)
    wire jtag_tdo_t_int;   // DAP output enable  (dap_ntdoen, 1 = float)

    IOBUF u_jtag_tdo_iobuf (
        .IO (jtag_tdo),
        .I  (jtag_tdo_o_int),
        .O  (),                 // TDO is output-only; sensed value unused
        .T  (jtag_tdo_t_int)
    );

    //=========================================================================
    // Block Design Instance
    //=========================================================================
    tidelink_design tidelink_design_i (
        // LINK 0 GPIO-PHY pads
        .pad_clk_tx_0    (pad_clk_tx_0),
        .pad_tx_0        (pad_tx_0),
        .pad_clk_rx_0    (pad_clk_rx_0),
        .pad_rx_0        (pad_rx_0),

        // LINK 0 I2C sideband (tristate resolved by the IOBUFs above)
        .i2c0_scl_i      (i2c_scl_i_int),
        .i2c0_scl_o      (i2c_scl_o_int),
        .i2c0_scl_t      (i2c_scl_t_int),
        .i2c0_sda_i      (i2c_sda_i_int),
        .i2c0_sda_o      (i2c_sda_o_int),
        .i2c0_sda_t      (i2c_sda_t_int),

        // SWJ-DP — SWCLK/TDI/nTRST direct; SWDIO + TDO via the IOBUFs above
        .swclk           (swclk),
        .swdio_i         (swdio_i_int),
        .swdio_o         (swdio_o_int),
        .swdio_oe        (swdio_oe_int),
        .jtag_tdi        (jtag_tdi),
        .jtag_tdo_o      (jtag_tdo_o_int),
        .jtag_tdo_t      (jtag_tdo_t_int),
        .jtag_ntrst      (jtag_ntrst),

        // UART console
        .uart_rxd        (uart_rxd),
        .uart_txd        (uart_txd),

        // Status
        .led0            (led0),
        .led1            (led1)
    );

endmodule
