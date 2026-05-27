// =============================================================================
// tb_top.sv — paired tidelink_top with master's `ahb_sub` exposed for
//             cocotb-driven AHB peer-aperture reads. Used by
//             test_eye_peer_aperture_drain (proposal §9 test #7).
// =============================================================================
//
// This is a thinned-down clone of cocotb/tidelink_top_pair/tb_top.sv whose
// ONLY behavioural difference is that master's ahb_sub port is wired out
// to the cocotb testbench instead of tied off. That lets the cocotb test
// issue AHB reads at peer-aperture addresses (0x4003_2140..0x4003_217F →
// reaches the slave's local Region 10 via the peer aperture).
//
// The proposal §7 worked example:
//     LOCAL_BASE = 0x44032140    (slave's local view of its own Region 10)
//     PEER_BASE  = 0x40032140    (master's view of slave's Region 10)
//
// Test plan:
//   1. Bring up the pair (role_lock + autocal) just as
//      tidelink_top_pair/test_tidelink_pair_doorbell does.
//   2. Locally programme + trigger an eye sweep on the SLAVE (s_apb_*).
//   3. From the MASTER side, issue AHB-Sub reads at 0x40032140 + offset
//      and assert the data matches what was just captured locally.
//
// We tie off all the ports that aren't relevant to the peer-aperture
// drain (PTP/PHC/I2C/AHB-Mng/scan) the same way the parent pair tb does.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`timescale 1ns/1ps

module tb_top #(
    parameter int SKID_BITS = `ifdef TB_TOP_SKID_BITS `TB_TOP_SKID_BITS `else 0 `endif,
    parameter SYS_ADDR_W    = 32,
    parameter SYS_DATA_W    = 32,
    parameter RAM_ADDR_W    = 14,
    parameter RAM_DATA_W    = 32,
    parameter APB_ADDR_W    = 12,
    parameter FC_DATA_W     = 48,
    parameter NUM_PHY_LANES = 8,
    parameter [SYS_ADDR_W-1:0] M_PAIR_BASE = 32'h4403_2000,
    parameter [SYS_ADDR_W-1:0] S_PAIR_BASE = 32'h4403_2000
);

    // -------------------------------------------------------------------------
    // Clocks and resets
    // -------------------------------------------------------------------------
    logic hclk     = 1'b0;
    logic ref_clk  = 1'b0;
    logic poresetn = 1'b0;
    logic hresetn  = 1'b0;
    logic m_apb_debug_unlock = 1'b1;
    logic s_apb_debug_unlock = 1'b1;
    logic m_mask_hs_bypass = 1'b1;
    logic s_mask_hs_bypass = 1'b1;

    // -------------------------------------------------------------------------
    // Cross-wired GPIO PHY pads
    // -------------------------------------------------------------------------
    wire                          m_pad_clk_tx, s_pad_clk_tx;
    wire [NUM_PHY_LANES-1:0]      m_pad_tx,     s_pad_tx;
    wire                          m_pad_clk_tx_skid, s_pad_clk_tx_skid;
    wire [NUM_PHY_LANES-1:0]      m_pad_tx_skid,     s_pad_tx_skid;

    pad_skid #(.SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES)) u_skid_m2s (
        .pad_clk_in  (m_pad_clk_tx), .pad_data_in (m_pad_tx),
        .pad_clk_out (m_pad_clk_tx_skid), .pad_data_out (m_pad_tx_skid)
    );
    pad_skid #(.SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES)) u_skid_s2m (
        .pad_clk_in  (s_pad_clk_tx), .pad_data_in (s_pad_tx),
        .pad_clk_out (s_pad_clk_tx_skid), .pad_data_out (s_pad_tx_skid)
    );

    // -------------------------------------------------------------------------
    // Master AHB-Sub — EXPOSED to cocotb (the focus of this testbench).
    // The cocotb test issues read transactions at 0x4003_2140+offset which
    // ride the peer aperture into slave's local Region 10.
    // -------------------------------------------------------------------------
    logic                          m_ahb_sub_hsel;
    logic   [SYS_ADDR_W-1:0]       m_ahb_sub_haddr;
    logic                    [2:0] m_ahb_sub_hburst;
    logic                    [3:0] m_ahb_sub_hprot;
    logic                    [2:0] m_ahb_sub_hsize;
    logic                    [1:0] m_ahb_sub_htrans;
    logic   [SYS_DATA_W-1:0]       m_ahb_sub_hwdata;
    logic                          m_ahb_sub_hwrite;
    logic                          m_ahb_sub_hready;
    wire    [SYS_DATA_W-1:0]       m_ahb_sub_hrdata;
    wire                           m_ahb_sub_hresp;
    wire                           m_ahb_sub_hreadyout;

    // Per-side TX aperture + FIFO read — tied off here (this test does
    // not exercise FC packets, only the peer aperture).
    // -------------------------------------------------------------------------
    // APB unified config port (manually driven from cocotb).
    // -------------------------------------------------------------------------
    logic         m_apb_psel,  m_apb_penable, m_apb_pwrite;
    logic [14:0]  m_apb_paddr;
    logic         [3:0]  m_apb_pstrb;
    logic         [2:0]  m_apb_pprot;
    logic [SYS_DATA_W-1:0] m_apb_pwdata;
    wire  [SYS_DATA_W-1:0] m_apb_prdata;
    wire                   m_apb_pready;
    wire                   m_apb_pslverr;
    logic         s_apb_psel,  s_apb_penable, s_apb_pwrite;
    logic [14:0]  s_apb_paddr;
    logic         [3:0]  s_apb_pstrb;
    logic         [2:0]  s_apb_pprot;
    logic [SYS_DATA_W-1:0] s_apb_pwdata;
    wire  [SYS_DATA_W-1:0] s_apb_prdata;
    wire                   s_apb_pready;
    wire                   s_apb_pslverr;

    // -------------------------------------------------------------------------
    // I2C — pull-up bus model.
    // -------------------------------------------------------------------------
    wire m_i2c_scl_o, m_i2c_scl_t, m_i2c_sda_o, m_i2c_sda_t;
    wire s_i2c_scl_o, s_i2c_scl_t, s_i2c_sda_o, s_i2c_sda_t;
    wire i2c_scl = (m_i2c_scl_t ? 1'b1 : m_i2c_scl_o) & (s_i2c_scl_t ? 1'b1 : s_i2c_scl_o);
    wire i2c_sda = (m_i2c_sda_t ? 1'b1 : m_i2c_sda_o) & (s_i2c_sda_t ? 1'b1 : s_i2c_sda_o);

    wire m_role_is_master, m_role_locked, m_link_active, m_d2d_reset_o;
    wire s_role_is_master, s_role_locked, s_link_active, s_d2d_reset_o;

    // -------------------------------------------------------------------------
    // Generic AHB tie-off macro (TX aperture / FIFO / PTP / Mng — all the
    // ports we don't drive on either side).
    // -------------------------------------------------------------------------

    // =========================================================================
    // DUT: master `tidelink_top`
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE(M_PAIR_BASE)
    ) u_master (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),

        // AHB Sub — EXPOSED (drive from cocotb for peer aperture access)
        .ahb_sub_hsel      (m_ahb_sub_hsel),
        .ahb_sub_haddr     (m_ahb_sub_haddr),
        .ahb_sub_hburst    (m_ahb_sub_hburst),
        .ahb_sub_hprot     (m_ahb_sub_hprot),
        .ahb_sub_hsize     (m_ahb_sub_hsize),
        .ahb_sub_htrans    (m_ahb_sub_htrans),
        .ahb_sub_hwdata    (m_ahb_sub_hwdata),
        .ahb_sub_hwrite    (m_ahb_sub_hwrite),
        .ahb_sub_hready    (m_ahb_sub_hready),
        .ahb_sub_hrdata    (m_ahb_sub_hrdata),
        .ahb_sub_hresp     (m_ahb_sub_hresp),
        .ahb_sub_hreadyout (m_ahb_sub_hreadyout),

        // Everything else tied off (this test only needs APB + ahb_sub)
        .ahb_tx_hsel       (1'b0), .ahb_tx_haddr      (14'h0),
        .ahb_tx_htrans     (2'b00), .ahb_tx_hsize     (3'h0),
        .ahb_tx_hwrite     (1'b0), .ahb_tx_hwdata    (32'h0),
        .ahb_tx_hready     (1'b1), .ahb_tx_hrdata    (/*unused*/),
        .ahb_tx_hresp      (/*unused*/), .ahb_tx_hreadyout (/*unused*/),

        .ahb_fifo_hsel     (1'b0), .ahb_fifo_haddr    (14'h0),
        .ahb_fifo_htrans   (2'b00), .ahb_fifo_hsize   (3'h0),
        .ahb_fifo_hwrite   (1'b0), .ahb_fifo_hwdata   (32'h0),
        .ahb_fifo_hready   (1'b1), .ahb_fifo_hrdata   (/*unused*/),
        .ahb_fifo_hresp    (/*unused*/), .ahb_fifo_hreadyout(/*unused*/),

        .ahb_mng_haddr     (/*unused*/), .ahb_mng_hburst (/*unused*/),
        .ahb_mng_hprot     (/*unused*/), .ahb_mng_hsize  (/*unused*/),
        .ahb_mng_htrans    (/*unused*/), .ahb_mng_hwdata (/*unused*/),
        .ahb_mng_hwrite    (/*unused*/), .ahb_mng_hready (1'b1),
        .ahb_mng_hrdata    (32'h0),      .ahb_mng_hresp  (1'b0),

        .apb_psel          (m_apb_psel),  .apb_paddr  (m_apb_paddr),
        .apb_penable       (m_apb_penable),.apb_pwrite (m_apb_pwrite),
        .apb_pstrb         (m_apb_pstrb), .apb_pprot  (m_apb_pprot),
        .apb_pwdata        (m_apb_pwdata),.apb_prdata (m_apb_prdata),
        .apb_pready        (m_apb_pready),.apb_pslverr(m_apb_pslverr),

        .scan_mode (1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out(/*unused*/),

        .user_ref_clk      (ref_clk),
        .pad_clk_tx        (m_pad_clk_tx),
        .pad_tx            (m_pad_tx),
        .pad_clk_rx        (s_pad_clk_tx_skid),
        .pad_rx            (s_pad_tx_skid),
        .idelay_ref_clk    (1'b0),

        .phc_clk           (hclk), .phc_resetn (hresetn),
        .phc_nanoseconds   (30'h0), .phc_seconds(48'h0),
        .phc_pps           (1'b0),
        .phc_hw_cap_seconds(48'h0), .phc_hw_cap_nanoseconds(30'h0),
        .phc_hw_cap_sub_nanoseconds(32'h0), .phc_locked_i(1'b1),

        .ahb_ptp_hsel  (1'b0), .ahb_ptp_haddr (4'h0),
        .ahb_ptp_htrans(2'b00),.ahb_ptp_hsize (3'h0),
        .ahb_ptp_hwrite(1'b0), .ahb_ptp_hwdata(32'h0),
        .ahb_ptp_hready(1'b1),
        .ahb_ptp_hrdata(/*unused*/),    .ahb_ptp_hresp(/*unused*/),
        .ahb_ptp_hreadyout(/*unused*/),
        .phc_hw_capture(/*unused*/),    .phc_hw_set_time(/*unused*/),
        .phc_hw_set_seconds(/*unused*/),.phc_hw_set_nanoseconds(/*unused*/),
        .phc_hw_adj_valid(/*unused*/),  .phc_hw_adj_ns_incr_frac(/*unused*/),
        .servo_locked    (/*unused*/),

        .tc_axis_tx_tvalid (1'b0), .tc_axis_tx_tdata({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready (/*unused*/),
        .tc_axis_rx_tvalid (/*unused*/), .tc_axis_rx_tdata (/*unused*/),
        .tc_axis_rx_tready (1'b1), .tc_qos_priority(3'h0),

        .tl_local_link_state_o (/*unused*/),
        .tl_link_state_change_o(/*unused*/),
        .tl_ewma_credit_o      (/*unused*/),
        .tl_bcast_ack_i        (1'b0),

        .link_active       (m_link_active),
        .d2d_reset_o       (m_d2d_reset_o),

        .role_strap_i      (1'b0),
        .role_is_master_o  (m_role_is_master),
        .role_locked_o     (m_role_locked),
        .apb_debug_unlock_i(m_apb_debug_unlock),
        .mask_hs_bypass_i  (m_mask_hs_bypass),
        .nego_priority_i   (16'h8000),
        .puf_seed          (16'hA5A5), .puf_ready (1'b1),
        .nego_error_irq    (/*unused*/),

        .i2c_scl_i (i2c_scl), .i2c_scl_o (m_i2c_scl_o),
        .i2c_scl_t (m_i2c_scl_t),
        .i2c_sda_i (i2c_sda), .i2c_sda_o (m_i2c_sda_o),
        .i2c_sda_t (m_i2c_sda_t),

        .s_i2c_axi_awvalid (1'b0), .s_i2c_axi_awid(2'b00),
        .s_i2c_axi_awaddr  (4'h0), .s_i2c_axi_awlen(8'h00),
        .s_i2c_axi_awsize  (3'h0), .s_i2c_axi_awburst(2'b00),
        .s_i2c_axi_awlock  (1'b0), .s_i2c_axi_awcache(4'h0),
        .s_i2c_axi_awprot  (3'h0), .s_i2c_axi_awready(/*unused*/),
        .s_i2c_axi_wvalid  (1'b0), .s_i2c_axi_wdata(32'h0),
        .s_i2c_axi_wstrb   (4'h0), .s_i2c_axi_wlast(1'b0),
        .s_i2c_axi_wready  (/*unused*/),
        .s_i2c_axi_bvalid  (/*unused*/), .s_i2c_axi_bid(/*unused*/),
        .s_i2c_axi_bresp   (/*unused*/), .s_i2c_axi_bready(1'b1),
        .s_i2c_axi_arvalid (1'b0), .s_i2c_axi_arid(2'b00),
        .s_i2c_axi_araddr  (4'h0), .s_i2c_axi_arlen(8'h00),
        .s_i2c_axi_arsize  (3'h0), .s_i2c_axi_arburst(2'b00),
        .s_i2c_axi_arlock  (1'b0), .s_i2c_axi_arcache(4'h0),
        .s_i2c_axi_arprot  (3'h0), .s_i2c_axi_arready(/*unused*/),
        .s_i2c_axi_rvalid  (/*unused*/), .s_i2c_axi_rid(/*unused*/),
        .s_i2c_axi_rdata   (/*unused*/), .s_i2c_axi_rresp(/*unused*/),
        .s_i2c_axi_rlast   (/*unused*/), .s_i2c_axi_rready(1'b1),

        .i2c_nbsy_irq      (/*unused*/), .i2c_nrd_empty_irq(/*unused*/),

        .released_credits_irq (/*unused*/),
        .doorbell_irq         (/*unused*/),
        .packet_committed_irq (/*unused*/),
        .ptp_irq              (/*unused*/),
        .perf_irq             (/*unused*/),
        .wlink_irq            (/*unused*/)
    );

    // =========================================================================
    // DUT: slave `tidelink_top`
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE(S_PAIR_BASE)
    ) u_slave (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),

        .ahb_sub_hsel      (1'b0), .ahb_sub_haddr (32'h0),
        .ahb_sub_hburst    (3'h0), .ahb_sub_hprot (4'h0),
        .ahb_sub_hsize     (3'h0), .ahb_sub_htrans(2'b00),
        .ahb_sub_hwdata    (32'h0),.ahb_sub_hwrite(1'b0),
        .ahb_sub_hready    (1'b1),
        .ahb_sub_hrdata    (/*unused*/),
        .ahb_sub_hresp     (/*unused*/),
        .ahb_sub_hreadyout (/*unused*/),

        .ahb_tx_hsel       (1'b0), .ahb_tx_haddr  (14'h0),
        .ahb_tx_htrans     (2'b00),.ahb_tx_hsize  (3'h0),
        .ahb_tx_hwrite     (1'b0), .ahb_tx_hwdata (32'h0),
        .ahb_tx_hready     (1'b1), .ahb_tx_hrdata (/*unused*/),
        .ahb_tx_hresp      (/*unused*/), .ahb_tx_hreadyout(/*unused*/),

        .ahb_fifo_hsel     (1'b0), .ahb_fifo_haddr (14'h0),
        .ahb_fifo_htrans   (2'b00),.ahb_fifo_hsize (3'h0),
        .ahb_fifo_hwrite   (1'b0), .ahb_fifo_hwdata(32'h0),
        .ahb_fifo_hready   (1'b1), .ahb_fifo_hrdata(/*unused*/),
        .ahb_fifo_hresp    (/*unused*/),.ahb_fifo_hreadyout(/*unused*/),

        .ahb_mng_haddr (/*unused*/), .ahb_mng_hburst(/*unused*/),
        .ahb_mng_hprot (/*unused*/), .ahb_mng_hsize (/*unused*/),
        .ahb_mng_htrans(/*unused*/), .ahb_mng_hwdata(/*unused*/),
        .ahb_mng_hwrite(/*unused*/), .ahb_mng_hready(1'b1),
        .ahb_mng_hrdata(32'h0),      .ahb_mng_hresp (1'b0),

        .apb_psel    (s_apb_psel),  .apb_paddr   (s_apb_paddr),
        .apb_penable (s_apb_penable),.apb_pwrite (s_apb_pwrite),
        .apb_pstrb   (s_apb_pstrb), .apb_pprot   (s_apb_pprot),
        .apb_pwdata  (s_apb_pwdata),.apb_prdata  (s_apb_prdata),
        .apb_pready  (s_apb_pready),.apb_pslverr (s_apb_pslverr),

        .scan_mode (1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out(/*unused*/),

        .user_ref_clk      (ref_clk),
        .pad_clk_tx        (s_pad_clk_tx),
        .pad_tx            (s_pad_tx),
        .pad_clk_rx        (m_pad_clk_tx_skid),
        .pad_rx            (m_pad_tx_skid),
        .idelay_ref_clk    (1'b0),

        .phc_clk(hclk), .phc_resetn(hresetn),
        .phc_nanoseconds(30'h0), .phc_seconds(48'h0), .phc_pps(1'b0),
        .phc_hw_cap_seconds(48'h0), .phc_hw_cap_nanoseconds(30'h0),
        .phc_hw_cap_sub_nanoseconds(32'h0), .phc_locked_i(1'b1),

        .ahb_ptp_hsel(1'b0), .ahb_ptp_haddr(4'h0),
        .ahb_ptp_htrans(2'b00),.ahb_ptp_hsize(3'h0),
        .ahb_ptp_hwrite(1'b0), .ahb_ptp_hwdata(32'h0),
        .ahb_ptp_hready(1'b1),
        .ahb_ptp_hrdata(/*unused*/), .ahb_ptp_hresp(/*unused*/),
        .ahb_ptp_hreadyout(/*unused*/),
        .phc_hw_capture(/*unused*/),    .phc_hw_set_time(/*unused*/),
        .phc_hw_set_seconds(/*unused*/),.phc_hw_set_nanoseconds(/*unused*/),
        .phc_hw_adj_valid(/*unused*/),  .phc_hw_adj_ns_incr_frac(/*unused*/),
        .servo_locked   (/*unused*/),

        .tc_axis_tx_tvalid(1'b0), .tc_axis_tx_tdata({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready(/*unused*/),
        .tc_axis_rx_tvalid(/*unused*/), .tc_axis_rx_tdata(/*unused*/),
        .tc_axis_rx_tready(1'b1), .tc_qos_priority(3'h0),

        .tl_local_link_state_o (/*unused*/),
        .tl_link_state_change_o(/*unused*/),
        .tl_ewma_credit_o      (/*unused*/),
        .tl_bcast_ack_i        (1'b0),

        .link_active(s_link_active), .d2d_reset_o(s_d2d_reset_o),

        .role_strap_i      (1'b1),    // slave role
        .role_is_master_o  (s_role_is_master),
        .role_locked_o     (s_role_locked),
        .apb_debug_unlock_i(s_apb_debug_unlock),
        .mask_hs_bypass_i  (s_mask_hs_bypass),
        .nego_priority_i   (16'h0001),
        .puf_seed          (16'h5A5A), .puf_ready(1'b1),
        .nego_error_irq    (/*unused*/),

        .i2c_scl_i (i2c_scl), .i2c_scl_o (s_i2c_scl_o),
        .i2c_scl_t (s_i2c_scl_t),
        .i2c_sda_i (i2c_sda), .i2c_sda_o (s_i2c_sda_o),
        .i2c_sda_t (s_i2c_sda_t),

        .s_i2c_axi_awvalid (1'b0), .s_i2c_axi_awid(2'b00),
        .s_i2c_axi_awaddr  (4'h0), .s_i2c_axi_awlen(8'h00),
        .s_i2c_axi_awsize  (3'h0), .s_i2c_axi_awburst(2'b00),
        .s_i2c_axi_awlock  (1'b0), .s_i2c_axi_awcache(4'h0),
        .s_i2c_axi_awprot  (3'h0), .s_i2c_axi_awready(/*unused*/),
        .s_i2c_axi_wvalid  (1'b0), .s_i2c_axi_wdata(32'h0),
        .s_i2c_axi_wstrb   (4'h0), .s_i2c_axi_wlast(1'b0),
        .s_i2c_axi_wready  (/*unused*/),
        .s_i2c_axi_bvalid  (/*unused*/), .s_i2c_axi_bid(/*unused*/),
        .s_i2c_axi_bresp   (/*unused*/), .s_i2c_axi_bready(1'b1),
        .s_i2c_axi_arvalid (1'b0), .s_i2c_axi_arid(2'b00),
        .s_i2c_axi_araddr  (4'h0), .s_i2c_axi_arlen(8'h00),
        .s_i2c_axi_arsize  (3'h0), .s_i2c_axi_arburst(2'b00),
        .s_i2c_axi_arlock  (1'b0), .s_i2c_axi_arcache(4'h0),
        .s_i2c_axi_arprot  (3'h0), .s_i2c_axi_arready(/*unused*/),
        .s_i2c_axi_rvalid  (/*unused*/), .s_i2c_axi_rid(/*unused*/),
        .s_i2c_axi_rdata   (/*unused*/), .s_i2c_axi_rresp(/*unused*/),
        .s_i2c_axi_rlast   (/*unused*/), .s_i2c_axi_rready(1'b1),

        .i2c_nbsy_irq    (/*unused*/), .i2c_nrd_empty_irq(/*unused*/),

        .released_credits_irq (/*unused*/),
        .doorbell_irq         (/*unused*/),
        .packet_committed_irq (/*unused*/),
        .ptp_irq              (/*unused*/),
        .perf_irq             (/*unused*/),
        .wlink_irq            (/*unused*/)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
