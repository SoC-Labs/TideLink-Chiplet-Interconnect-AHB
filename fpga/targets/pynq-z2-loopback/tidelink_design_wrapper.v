//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge - Pynq-Z2 Single-Instance Board-Level Wrapper (Wave B1)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Top-level Verilog wrapper that the Vivado build_design.tcl reads as the
// synthesis top. Instantiates the tidelink_design block design and applies
// all board-level tie-offs that are inappropriate for the IP Integrator BD:
//
//   - role_strap_i is driven inside the BD by axi_gpio_strap (NOT tied here)
//   - tl_bcast_ack_i = 1'b0     (no TideChart broadcast acknowledgement)
//   - phc_pps = 1'b0             (PHC tie-off — Q4)
//   - phc_locked_i = 1'b0       (PHC tie-off — Q4)
//   - tc_axis_tx_tvalid = 1'b0  (TideChart TX not used at this stage)
//   - tc_axis_tx_tdata  = 48'h0 (TideChart TX not used at this stage)
//   - tc_axis_rx_tready = 1'b1  (TideChart RX: always accept)
//   - user_ref_clk = 1'b0       (Wlink PLL ref — no external TCXO on Pynq-Z2)
//   - I2C sideband: scl_i/sda_i pulled high (open-drain idle state)
//   - I2C AXI slave: all inputs tied 0 (not connected)
//   - Scan/DFT: all tied 0
//   - tc_qos_priority = 3'b0    (default QoS)
//
// PHY pads: pad_clk_tx and pad_tx[7:0] are driven directly from the block
// design (no IOBUF needed — TideLink GPIO pads are unidirectional outputs
// on the TX side and unidirectional inputs on the RX side).
//
// Note on ahb_mng: the manager port (incoming from remote chiplet) is left
// unconnected in this single-instance target. The BD does not instantiate
// an AHB bridge for the manager path. Outputs from the IP that are connected
// to this manager path will be left floating (Vivado issues an INFO, not
// ERROR, for unused master outputs). A future revision will add a BlockRAM
// slave on the manager path once the paired target validates the manager flow.
//-----------------------------------------------------------------------------

module tidelink_design_wrapper (
    // DDR3 Interface (to Zynq PS)
    inout  wire [14:0] DDR_addr,
    inout  wire  [2:0] DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire  [3:0] DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire  [3:0] DDR_dqs_n,
    inout  wire  [3:0] DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,

    // Fixed IO (Zynq PS)
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,

    // GPIO PHY pads are NOT exposed in the loopback build — TX is wired
    // back to RX inside this wrapper before reaching FPGA pins. This
    // bypasses the cable AND the fabric-routed pad_clk_rx clock issues,
    // letting us prove whether Wlink/TideLink are functional in
    // principle on a single board with no peer.

    // Board LEDs (accent green, active-high)
    output wire        led0,              // LD0 / R14 — link_active
    output wire        led1,              // LD1 / P14 — role_is_master
    output wire        led2,              // LD2 / N16 — wlink_irq
    output wire        led3               // LD3 / M14 — released_credits_irq
);

    //=========================================================================
    // Internal TX→RX loopback wires
    //
    // The BD still presents pad_clk_tx / pad_tx[*] as outputs and
    // pad_clk_rx / pad_rx[*] as inputs. We connect them to internal
    // wires only — never to FPGA pads — so the BD's own ahb_tx packets
    // travel through Wlink TX → these wires → Wlink RX → tidelink_fc
    // RX FIFO, all on this single board.
    //=========================================================================
    wire        loopback_clk;
    wire [7:0]  loopback_data;

    //=========================================================================
    // Block Design Instance
    //=========================================================================
    tidelink_design tidelink_design_i (
        // DDR
        .DDR_addr                 (DDR_addr),
        .DDR_ba                   (DDR_ba),
        .DDR_cas_n                (DDR_cas_n),
        .DDR_ck_n                 (DDR_ck_n),
        .DDR_ck_p                 (DDR_ck_p),
        .DDR_cke                  (DDR_cke),
        .DDR_cs_n                 (DDR_cs_n),
        .DDR_dm                   (DDR_dm),
        .DDR_dq                   (DDR_dq),
        .DDR_dqs_n                (DDR_dqs_n),
        .DDR_dqs_p                (DDR_dqs_p),
        .DDR_odt                  (DDR_odt),
        .DDR_ras_n                (DDR_ras_n),
        .DDR_reset_n              (DDR_reset_n),
        .DDR_we_n                 (DDR_we_n),

        // Fixed IO
        .FIXED_IO_ddr_vrn         (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp         (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio             (FIXED_IO_mio),
        .FIXED_IO_ps_clk          (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb         (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb        (FIXED_IO_ps_srstb),

        // GPIO PHY pads — wired to internal loopback nets only
        .pad_clk_tx               (loopback_clk),
        .pad_tx                   (loopback_data),
        .pad_clk_rx               (loopback_clk),
        .pad_rx                   (loopback_data),

        // LEDs
        .led0                     (led0),
        .led1                     (led1),
        .led2                     (led2),
        .led3                     (led3)

        // All other tie-offs (tl_bcast_ack_i, phc_pps, phc_locked_i,
        // tc_axis_*, tc_qos_priority, user_ref_clk, scan_*, i2c_*, ahb_mng_*,
        // s_i2c_axi_*) are driven INSIDE the block design via xlconstant
        // cells in tidelink_design.tcl. They are not exposed as BD external
        // ports, so they do not appear in this instantiation.
    );

endmodule
