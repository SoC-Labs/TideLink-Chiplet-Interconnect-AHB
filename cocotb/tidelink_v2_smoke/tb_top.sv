// =============================================================================
// tb_top.sv — tidelink_v2_smoke: single `tidelink_top`, APB-only.
//
// Fast V2 (S3 PHY swap) integration sanity gate: elaborate tidelink_top with
// the V2 swap set (flists/tidelink_fpga_v2.flist — TIDELINK_PHY_V2 defined,
// deps/tidelink-phy serdes/calibrator/checker, eye-regs removed) and prove
// reset + APB liveness. Everything except the unified APB port is tied off:
// no link partner, no AHB traffic, pads strapped to 0.
//
// Wiring mirrors the master instance of cocotb/tidelink_top_pair/tb_top.sv
// (the authoritative tie-off pattern); driver style mirrors
// cocotb/tidelink_fc_adapter.
// =============================================================================
`timescale 1ns/1ps

module tb_top #(
    parameter SYS_ADDR_W    = 32,
    parameter SYS_DATA_W    = 32,
    parameter RAM_ADDR_W    = 14,
    parameter RAM_DATA_W    = 32,
    parameter APB_ADDR_W    = 12,
    parameter FC_DATA_W     = 48,
    parameter NUM_PHY_LANES = 8
);

    // ── Clocks / resets (driven from cocotb) ────────────────────────────────
    logic hclk     = 1'b0;
    logic ref_clk  = 1'b0;
    logic poresetn = 1'b0;
    logic hresetn  = 1'b0;

    // ── APB unified config port (driven from cocotb) ────────────────────────
    logic         apb_psel = 1'b0, apb_penable = 1'b0, apb_pwrite = 1'b0;
    logic [14:0]  apb_paddr = '0;
    logic [3:0]   apb_pstrb = 4'hF;
    logic [2:0]   apb_pprot = 3'h0;
    logic [SYS_DATA_W-1:0] apb_pwdata = '0;
    wire  [SYS_DATA_W-1:0] apb_prdata;
    wire                   apb_pready;
    wire                   apb_pslverr;

    // ── Status outputs (observed by the test) ───────────────────────────────
    wire role_is_master, role_locked, link_active, d2d_reset_o;
    wire released_credits_irq, doorbell_irq, packet_committed_irq;
    wire ptp_irq, perf_irq, wlink_irq;

    // PHY pads — no partner: RX strapped low, TX dangles.
    wire                     pad_clk_tx;
    wire [NUM_PHY_LANES-1:0] pad_tx;

    // I2C — pulled-up single-die bus (loop our own open-drain back).
    wire i2c_scl_o, i2c_scl_t, i2c_sda_o, i2c_sda_t;
    wire i2c_scl = i2c_scl_t ? 1'b1 : i2c_scl_o;
    wire i2c_sda = i2c_sda_t ? 1'b1 : i2c_sda_o;

    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES)
    ) u_dut (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),

        // AHB Sub — tied off
        .ahb_sub_hsel      (1'b0),
        .ahb_sub_haddr     (32'h0),
        .ahb_sub_hburst    (3'h0),
        .ahb_sub_hprot     (4'h0),
        .ahb_sub_hsize     (3'h0),
        .ahb_sub_htrans    (2'b00),
        .ahb_sub_hwdata    (32'h0),
        .ahb_sub_hwrite    (1'b0),
        .ahb_sub_hready    (1'b1),
        .ahb_sub_hrdata    (/* unused */),
        .ahb_sub_hresp     (/* unused */),
        .ahb_sub_hreadyout (/* unused */),

        // AHB TX aperture — tied off
        .ahb_tx_hsel       (1'b0),
        .ahb_tx_haddr      ({RAM_ADDR_W{1'b0}}),
        .ahb_tx_htrans     (2'b00),
        .ahb_tx_hsize      (3'h0),
        .ahb_tx_hwrite     (1'b0),
        .ahb_tx_hwdata     (32'h0),
        .ahb_tx_hready     (1'b1),
        .ahb_tx_hrdata     (/* unused */),
        .ahb_tx_hresp      (/* unused */),
        .ahb_tx_hreadyout  (/* unused */),

        // AHB FIFO read port — tied off
        .ahb_fifo_hsel     (1'b0),
        .ahb_fifo_haddr    ({RAM_ADDR_W{1'b0}}),
        .ahb_fifo_htrans   (2'b00),
        .ahb_fifo_hsize    (3'h0),
        .ahb_fifo_hwrite   (1'b0),
        .ahb_fifo_hwdata   (32'h0),
        .ahb_fifo_hready   (1'b1),
        .ahb_fifo_hrdata   (/* unused */),
        .ahb_fifo_hresp    (/* unused */),
        .ahb_fifo_hreadyout(/* unused */),

        // AHB Manager — tied off
        .ahb_mng_haddr     (/* unused */),
        .ahb_mng_hburst    (/* unused */),
        .ahb_mng_hprot     (/* unused */),
        .ahb_mng_hsize     (/* unused */),
        .ahb_mng_htrans    (/* unused */),
        .ahb_mng_hwdata    (/* unused */),
        .ahb_mng_hwrite    (/* unused */),
        .ahb_mng_hready    (1'b1),
        .ahb_mng_hrdata    (32'h0),
        .ahb_mng_hresp     (1'b0),

        // APB unified config port — the only driven interface
        .apb_psel          (apb_psel),
        .apb_paddr         (apb_paddr),
        .apb_penable       (apb_penable),
        .apb_pwrite        (apb_pwrite),
        .apb_pstrb         (apb_pstrb),
        .apb_pprot         (apb_pprot),
        .apb_pwdata        (apb_pwdata),
        .apb_prdata        (apb_prdata),
        .apb_pready        (apb_pready),
        .apb_pslverr       (apb_pslverr),

        // Scan / DFT — tied off
        .scan_mode         (1'b0),
        .scan_asyncrst_ctrl(1'b0),
        .scan_clk          (1'b0),
        .scan_shift        (1'b0),
        .scan_in           (1'b0),
        .scan_out          (/* unused */),

        .user_ref_clk      (ref_clk),

        // PHY pads — no partner
        .pad_clk_tx        (pad_clk_tx),
        .pad_tx            (pad_tx),
        .pad_clk_rx        (1'b0),
        .pad_rx            ({NUM_PHY_LANES{1'b0}}),

        .idelay_ref_clk    (1'b0),

        // PHC — tied off
        .phc_clk                    (hclk),
        .phc_resetn                 (hresetn),
        .phc_nanoseconds            (30'h0),
        .phc_seconds                (48'h0),
        .phc_pps                    (1'b0),
        .phc_hw_cap_seconds         (48'h0),
        .phc_hw_cap_nanoseconds     (30'h0),
        .phc_hw_cap_sub_nanoseconds (32'h0),
        .phc_locked_i               (1'b1),

        // PTP AHB write port — tied off
        .ahb_ptp_hsel               (1'b0),
        .ahb_ptp_haddr              (4'h0),
        .ahb_ptp_htrans             (2'b00),
        .ahb_ptp_hsize              (3'h0),
        .ahb_ptp_hwrite             (1'b0),
        .ahb_ptp_hwdata             (32'h0),
        .ahb_ptp_hready             (1'b1),
        .ahb_ptp_hrdata             (/* unused */),
        .ahb_ptp_hresp              (/* unused */),
        .ahb_ptp_hreadyout          (/* unused */),
        .phc_hw_capture             (/* unused */),
        .phc_hw_set_time            (/* unused */),
        .phc_hw_set_seconds         (/* unused */),
        .phc_hw_set_nanoseconds     (/* unused */),
        .phc_hw_adj_valid           (/* unused */),
        .phc_hw_adj_ns_incr_frac    (/* unused */),
        .servo_locked               (/* unused */),

        // TideChart axis — tied off with defined zeros
        .tc_axis_tx_tvalid (1'b0),
        .tc_axis_tx_tdata  ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready (/* unused */),
        .tc_axis_rx_tvalid (/* unused */),
        .tc_axis_rx_tdata  (/* unused */),
        .tc_axis_rx_tready (1'b1),
        .tc_qos_priority   (3'h0),

        // Congestion sideband
        .tl_local_link_state_o  (/* unused */),
        .tl_link_state_change_o (/* unused */),
        .tl_ewma_credit_o       (/* unused */),
        .tl_bcast_ack_i         (1'b0),

        .link_active       (link_active),
        .d2d_reset_o       (d2d_reset_o),

        // Role: master strap, APB writes ungated (debug unlock high — same
        // straps the pair tb uses so Region 8 writes land pre-role-lock).
        .role_strap_i      (1'b0),
        .role_is_master_o  (role_is_master),
        .role_locked_o     (role_locked),
        .apb_debug_unlock_i(1'b1),
        .mask_hs_bypass_i  (1'b1),

        .nego_priority_i   (16'h8000),
        .puf_seed          (16'hA5A5),
        .puf_ready         (1'b1),
        .nego_error_irq    (/* unused */),

        // I2C — self-looped pulled-up bus
        .i2c_scl_i         (i2c_scl),
        .i2c_scl_o         (i2c_scl_o),
        .i2c_scl_t         (i2c_scl_t),
        .i2c_sda_i         (i2c_sda),
        .i2c_sda_o         (i2c_sda_o),
        .i2c_sda_t         (i2c_sda_t),

        // I2C sideband AXI — tied off
        .s_i2c_axi_awvalid (1'b0),
        .s_i2c_axi_awid    (2'b00),
        .s_i2c_axi_awaddr  (4'h0),
        .s_i2c_axi_awlen   (8'h00),
        .s_i2c_axi_awsize  (3'h0),
        .s_i2c_axi_awburst (2'b00),
        .s_i2c_axi_awlock  (1'b0),
        .s_i2c_axi_awcache (4'h0),
        .s_i2c_axi_awprot  (3'h0),
        .s_i2c_axi_awready (/* unused */),
        .s_i2c_axi_wvalid  (1'b0),
        .s_i2c_axi_wdata   (32'h0),
        .s_i2c_axi_wstrb   (4'h0),
        .s_i2c_axi_wlast   (1'b0),
        .s_i2c_axi_wready  (/* unused */),
        .s_i2c_axi_bvalid  (/* unused */),
        .s_i2c_axi_bid     (/* unused */),
        .s_i2c_axi_bresp   (/* unused */),
        .s_i2c_axi_bready  (1'b1),
        .s_i2c_axi_arvalid (1'b0),
        .s_i2c_axi_arid    (2'b00),
        .s_i2c_axi_araddr  (4'h0),
        .s_i2c_axi_arlen   (8'h00),
        .s_i2c_axi_arsize  (3'h0),
        .s_i2c_axi_arburst (2'b00),
        .s_i2c_axi_arlock  (1'b0),
        .s_i2c_axi_arcache (4'h0),
        .s_i2c_axi_arprot  (3'h0),
        .s_i2c_axi_arready (/* unused */),
        .s_i2c_axi_rvalid  (/* unused */),
        .s_i2c_axi_rid     (/* unused */),
        .s_i2c_axi_rdata   (/* unused */),
        .s_i2c_axi_rresp   (/* unused */),
        .s_i2c_axi_rlast   (/* unused */),
        .s_i2c_axi_rready  (1'b1),

        .i2c_nbsy_irq      (/* unused */),
        .i2c_nrd_empty_irq (/* unused */),

        .released_credits_irq (released_credits_irq),
        .doorbell_irq         (doorbell_irq),
        .packet_committed_irq (packet_committed_irq),
        .ptp_irq              (ptp_irq),
        .perf_irq             (perf_irq),
        .wlink_irq            (wlink_irq)
    );

endmodule
