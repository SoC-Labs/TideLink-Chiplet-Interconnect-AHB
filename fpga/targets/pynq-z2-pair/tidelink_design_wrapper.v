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

    // GPIO PHY pads — Raspberry Pi header (see XDC for pin assignments)
    // TX side: driven by TideLink IP (outputs)
    output wire        pad_clk_tx,        // RPi header TX clock
    output wire  [7:0] pad_tx,            // RPi header TX data [7:0]
    // RX side: received by TideLink IP (inputs)
    input  wire        pad_clk_rx,        // RPi header RX clock
    input  wire  [7:0] pad_rx,            // RPi header RX data [7:0]

    // Board LEDs (accent green, active-high)
    output wire        led0,              // LD0 / R14 — link_active
    output wire        led1,              // LD1 / P14 — role_is_master
    output wire        led2,              // LD2 / N16 — wlink_irq
    output wire        led3               // LD3 / M14 — released_credits_irq
);

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

        // =====================================================================
        // Board-level tie-offs — signals not exposed at the top-level port
        // =====================================================================

        // Role strap: driven inside the BD by axi_gpio_strap (paired-only).
        // Not connected at this scope — the BD does not expose role_strap_i
        // as an external port for this target.

        // Broadcast acknowledge: no TideChart agent present at this stage.
        .tl_bcast_ack_i           (1'b0),

        // PHC tie-offs — Q4 TODO: replace with phc_hardware_clock IP instance
        .phc_pps                  (1'b0),
        .phc_locked_i             (1'b0),

        // TideChart AXI-Stream tie-offs — not used at this stage
        .tc_axis_tx_tvalid        (1'b0),
        .tc_axis_tx_tdata         (48'h0),
        // tc_axis_rx_tready: always ready (accept and discard any RX packets)
        .tc_axis_rx_tready        (1'b1),

        // QoS priority: default (best-effort)
        .tc_qos_priority          (3'b0),

        // PUF: puf_ready = 1, seed = 0xA5A5 (both wired in BD via xlconstant)

        // Wlink PLL reference clock: no external TCXO on Pynq-Z2; tie to 0.
        // The Wlink PLL will lock to the HCLK domain internally.
        .user_ref_clk             (1'b0),

        // I2C sideband: open-drain idle state (both lines released high)
        .i2c_scl_i                (1'b1),
        .i2c_sda_i                (1'b1),

        // I2C AXI slave: not connected — tie all inputs low
        .s_i2c_axi_awvalid        (1'b0),
        .s_i2c_axi_awid           (2'b0),
        .s_i2c_axi_awaddr         (4'b0),
        .s_i2c_axi_awlen          (8'b0),
        .s_i2c_axi_awsize         (3'b0),
        .s_i2c_axi_awburst        (2'b0),
        .s_i2c_axi_awlock         (1'b0),
        .s_i2c_axi_awcache        (4'b0),
        .s_i2c_axi_awprot         (3'b0),
        .s_i2c_axi_wvalid         (1'b0),
        .s_i2c_axi_wdata          (32'b0),
        .s_i2c_axi_wstrb          (4'b0),
        .s_i2c_axi_wlast          (1'b0),
        .s_i2c_axi_bready         (1'b0),
        .s_i2c_axi_arvalid        (1'b0),
        .s_i2c_axi_arid           (2'b0),
        .s_i2c_axi_araddr         (4'b0),
        .s_i2c_axi_arlen          (8'b0),
        .s_i2c_axi_arsize         (3'b0),
        .s_i2c_axi_arburst        (2'b0),
        .s_i2c_axi_arlock         (1'b0),
        .s_i2c_axi_arcache        (4'b0),
        .s_i2c_axi_arprot         (3'b0),
        .s_i2c_axi_rready         (1'b0),

        // ahb_mng (incoming manager from remote chiplet): not connected.
        // Drive HRDATA=0, HRESP=OKAY. Vivado INFO (not ERROR) for undriven
        // master outputs — acceptable for single-instance bring-up.
        .ahb_mng_hrdata           (32'b0),
        .ahb_mng_hresp            (1'b0),

        // Scan / DFT: tie all low for normal FPGA operation
        .scan_mode                (1'b0),
        .scan_asyncrst_ctrl       (1'b0),
        .scan_clk                 (1'b0),
        .scan_shift               (1'b0),
        .scan_in                  (1'b0)
    );

endmodule
