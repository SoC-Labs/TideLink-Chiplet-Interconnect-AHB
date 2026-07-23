//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge - KR260 (Zynq UltraScale+ / K26 SOM) Board Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Synthesis top read by build_design.tcl. Instantiates the tidelink_design
// block design and applies the board-level I2C open-drain tristate.
//
// Unlike the Z2 PS7 wrapper, there are NO DDR_* / FIXED_IO_* ports: on the
// MPSoC the PS DDR4 + MIO are bonded to the K26 SOM and are configured by the
// board preset inside the BD — they are not brought out as PL top-level ports.
//
// PHY pads: pad_clk_tx / pad_tx[7:0] drive the KR260 Raspberry-Pi header
// (outputs); pad_clk_rx / pad_rx[7:0] are inputs. See kr260_tidelink.xdc.
//-----------------------------------------------------------------------------

module tidelink_design_wrapper (
    // GPIO PHY pads — KR260 Raspberry Pi 40-pin header (see XDC for pins)
    // TX side: driven by TideLink IP (outputs)
    output wire        pad_clk_tx,        // RPi header TX clock (HDGC)
    output wire  [7:0] pad_tx,            // RPi header TX data [7:0]
    // RX side: received by TideLink IP (inputs)
    input  wire        pad_clk_rx,        // RPi header RX clock (HDGC)
    input  wire  [7:0] pad_rx,            // RPi header RX data [7:0]

    // Status LEDs on spare RPi-header pins (active-high). See XDC.
    output wire        led0,              // link_active
    output wire        led1,              // role_is_master
    output wire        led2,              // wlink_irq
    output wire        led3,              // released_credits_irq

    // Inter-board I2C sideband (autoneg role-lock). On the KR260 these pin to
    // the RPi header's I2C1 pins (BCM2/BCM3), which carry the ribbon between the
    // two boards symmetrically (SDA<->SDA, SCL<->SCL). Open-drain via assigns.
    inout  wire        i2c_scl_io,
    inout  wire        i2c_sda_io
);

    //=========================================================================
    // I2C open-drain tristate (Vivado convention: _t=1 => Hi-Z).
    // Mirrors the proven Z2/mps3 wrapper pattern.
    //=========================================================================
    wire i2c_scl_i_int, i2c_scl_o_int, i2c_scl_t_int;
    wire i2c_sda_i_int, i2c_sda_o_int, i2c_sda_t_int;
    assign i2c_scl_io    = i2c_scl_t_int ? 1'bz : i2c_scl_o_int;
    assign i2c_scl_i_int = i2c_scl_io;
    assign i2c_sda_io    = i2c_sda_t_int ? 1'bz : i2c_sda_o_int;
    assign i2c_sda_i_int = i2c_sda_io;

    //=========================================================================
    // Block Design Instance
    //=========================================================================
    tidelink_design tidelink_design_i (
        // GPIO PHY pads
        .pad_clk_tx               (pad_clk_tx),
        .pad_tx                   (pad_tx),
        .pad_clk_rx               (pad_clk_rx),
        .pad_rx                   (pad_rx),

        // LEDs
        .led0                     (led0),
        .led1                     (led1),
        .led2                     (led2),
        .led3                     (led3),

        // Inter-board I2C sideband — external BD ports IOBUF'd above.
        .i2c_scl_i                (i2c_scl_i_int),
        .i2c_scl_o                (i2c_scl_o_int),
        .i2c_scl_t                (i2c_scl_t_int),
        .i2c_sda_i                (i2c_sda_i_int),
        .i2c_sda_o                (i2c_sda_o_int),
        .i2c_sda_t                (i2c_sda_t_int)

        // All other tie-offs (tl_bcast_ack_i, tc_axis_*, tc_qos_priority,
        // scan/DFT, ahb_mng_*, s_i2c_axi_*, and the PHC inputs when PTP is off)
        // are driven INSIDE the block design via xlconstant cells.
    );

endmodule
