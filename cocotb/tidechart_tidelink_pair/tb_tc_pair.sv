// =============================================================================
// tb_tc_pair.sv — TideChart <-> TideLink pair integration smoke (gap F18)
//
// Derived from cocotb/tidelink_top_pair/tb_top.sv (the proven two-die pair
// harness). It keeps that harness's structure, instance names (u_master /
// u_slave), and m_/s_ prefixed signal names VERBATIM so the pair's Python
// bring-up class (PairTB in test_tidelink_pair_doorbell.py) can be imported
// and reused unchanged.
//
// The ONE difference vs tb_top.sv: on BOTH dies the TideChart AXI-Stream ports
// (tc_axis_rx/tx), the link_active line, and the congestion sideband
// (tl_local_link_state_o / tl_link_state_change_o / tl_bcast_ack_i) are no
// longer tied off — they are wired to a `tidechart_shim` instance exactly the
// way nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv wires them in the
// ASIC integration. Each shim runs its TideChart on link port 0; port 1 of the
// (NUM_PORTS=2, well-tested) controller is tied off.
//
// This proves: (a) the combined stack elaborates; (b) the pair link still
// brings up with TideChart attached; (c) TideChart consumes a real TideLink
// event — the election FSM only leaves ST_WAIT_LINKS because tidelink asserts
// link_active.
// =============================================================================
`timescale 1ns/1ps

module tb_tc_pair #(
    parameter int SKID_BITS      = 0,
    parameter int BYPASS_AUTONEG = 1,          // SW role-lock path (do_role_lock)
    parameter SYS_ADDR_W    = 32,
    parameter SYS_DATA_W    = 32,
    parameter RAM_ADDR_W    = 14,
    parameter RAM_DATA_W    = 32,
    parameter APB_ADDR_W    = 12,
    parameter FC_DATA_W     = 48,
    parameter NUM_PHY_LANES = 8,
    parameter [SYS_ADDR_W-1:0] M_PAIR_BASE = 32'h44032000,
    parameter [SYS_ADDR_W-1:0] S_PAIR_BASE = 32'h44032000
);

    // -------------------------------------------------------------------------
    // Clocks / resets  (names must match PairTB: hclk, ref_clk, poresetn, hresetn)
    // -------------------------------------------------------------------------
    logic hclk     = 1'b0;
    logic ref_clk  = 1'b0;
    logic poresetn = 1'b0;
    logic hresetn  = 1'b0;

    logic m_por_gate = 1'b1;
    logic s_por_gate = 1'b1;
    wire  m_poresetn_w = poresetn & m_por_gate;
    wire  m_hresetn_w  = hresetn  & m_por_gate;
    wire  s_poresetn_w = poresetn & s_por_gate;
    wire  s_hresetn_w  = hresetn  & s_por_gate;

    logic m_apb_debug_unlock = 1'b1;
    logic s_apb_debug_unlock = 1'b1;
    logic m_mask_hs_bypass   = 1'b1;
    logic s_mask_hs_bypass   = 1'b1;

    // -------------------------------------------------------------------------
    // Cross-wired GPIO PHY pads via pad_skid (reused from the pair bench)
    // -------------------------------------------------------------------------
    wire                     m_pad_clk_tx, s_pad_clk_tx;
    wire [NUM_PHY_LANES-1:0] m_pad_tx,     s_pad_tx;
    wire                     m_pad_clk_tx_skid, s_pad_clk_tx_skid;
    wire [NUM_PHY_LANES-1:0] m_pad_tx_skid,     s_pad_tx_skid;

    pad_skid #(.SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES)) u_skid_m2s (
        .pad_clk_in (m_pad_clk_tx), .pad_data_in (m_pad_tx),
        .pad_clk_out(m_pad_clk_tx_skid), .pad_data_out(m_pad_tx_skid)
    );
    pad_skid #(.SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES)) u_skid_s2m (
        .pad_clk_in (s_pad_clk_tx), .pad_data_in (s_pad_tx),
        .pad_clk_out(s_pad_clk_tx_skid), .pad_data_out(s_pad_tx_skid)
    );

    // -------------------------------------------------------------------------
    // AHB TX aperture (m/s) — driven at signal level by PairTB helpers
    // -------------------------------------------------------------------------
    logic                    m_ahb_tx_hsel, s_ahb_tx_hsel;
    logic  [RAM_ADDR_W-1:0]  m_ahb_tx_haddr, s_ahb_tx_haddr;
    logic            [1:0]   m_ahb_tx_htrans, s_ahb_tx_htrans;
    logic            [2:0]   m_ahb_tx_hsize, s_ahb_tx_hsize;
    logic                    m_ahb_tx_hwrite, s_ahb_tx_hwrite;
    logic  [SYS_DATA_W-1:0]  m_ahb_tx_hwdata, s_ahb_tx_hwdata;
    logic                    m_ahb_tx_hready_in, s_ahb_tx_hready_in;
    wire   [SYS_DATA_W-1:0]  m_ahb_tx_hrdata, s_ahb_tx_hrdata;
    wire                     m_ahb_tx_hresp, s_ahb_tx_hresp;
    wire                     m_ahb_tx_hready, s_ahb_tx_hready;
    wire m_ahb_tx_hready_loop = m_ahb_tx_hready;
    wire s_ahb_tx_hready_loop = s_ahb_tx_hready;

    // -------------------------------------------------------------------------
    // AHB FIFO read port (m/s)
    // -------------------------------------------------------------------------
    logic                    m_ahb_fifo_hsel, s_ahb_fifo_hsel;
    logic  [RAM_ADDR_W-1:0]  m_ahb_fifo_haddr, s_ahb_fifo_haddr;
    logic            [1:0]   m_ahb_fifo_htrans, s_ahb_fifo_htrans;
    logic            [2:0]   m_ahb_fifo_hsize, s_ahb_fifo_hsize;
    logic                    m_ahb_fifo_hwrite, s_ahb_fifo_hwrite;
    logic  [SYS_DATA_W-1:0]  m_ahb_fifo_hwdata, s_ahb_fifo_hwdata;
    logic                    m_ahb_fifo_hready_in, s_ahb_fifo_hready_in;
    wire   [SYS_DATA_W-1:0]  m_ahb_fifo_hrdata, s_ahb_fifo_hrdata;
    wire                     m_ahb_fifo_hresp, s_ahb_fifo_hresp;
    wire                     m_ahb_fifo_hready, s_ahb_fifo_hready;

    // -------------------------------------------------------------------------
    // TideLink unified APB config port (m/s)
    // -------------------------------------------------------------------------
    logic         m_apb_psel, m_apb_penable, m_apb_pwrite;
    logic [14:0]  m_apb_paddr;
    logic  [3:0]  m_apb_pstrb;
    logic  [2:0]  m_apb_pprot;
    logic [SYS_DATA_W-1:0] m_apb_pwdata;
    wire  [SYS_DATA_W-1:0] m_apb_prdata;
    wire                   m_apb_pready, m_apb_pslverr;
    logic         s_apb_psel, s_apb_penable, s_apb_pwrite;
    logic [14:0]  s_apb_paddr;
    logic  [3:0]  s_apb_pstrb;
    logic  [2:0]  s_apb_pprot;
    logic [SYS_DATA_W-1:0] s_apb_pwdata;
    wire  [SYS_DATA_W-1:0] s_apb_prdata;
    wire                   s_apb_pready, s_apb_pslverr;

    // -------------------------------------------------------------------------
    // IRQ / status
    // -------------------------------------------------------------------------
    wire m_released_credits_irq, m_doorbell_irq, m_packet_committed_irq;
    wire m_ptp_irq, m_perf_irq, m_wlink_irq;
    wire m_role_is_master, m_role_locked, m_link_active, m_d2d_reset_o;
    wire s_released_credits_irq, s_doorbell_irq, s_packet_committed_irq;
    wire s_ptp_irq, s_perf_irq, s_wlink_irq;
    wire s_role_is_master, s_role_locked, s_link_active, s_d2d_reset_o;

    // I2C pull-up bus model
    wire m_i2c_scl_o, m_i2c_scl_t, m_i2c_sda_o, m_i2c_sda_t;
    wire s_i2c_scl_o, s_i2c_scl_t, s_i2c_sda_o, s_i2c_sda_t;
    wire i2c_scl = (m_i2c_scl_t ? 1'b1 : m_i2c_scl_o) & (s_i2c_scl_t ? 1'b1 : s_i2c_scl_o);
    wire i2c_sda = (m_i2c_sda_t ? 1'b1 : m_i2c_sda_o) & (s_i2c_sda_t ? 1'b1 : s_i2c_sda_o);

    // -------------------------------------------------------------------------
    // PHC behavioural models (reused tb_phc_model.sv)
    // -------------------------------------------------------------------------
    logic [47:0] m_phc_init_seconds     = 48'd0;
    logic [29:0] m_phc_init_nanoseconds = 30'd0;
    logic        m_phc_lock_enable      = 1'b1;
    logic [47:0] s_phc_init_seconds     = 48'd0;
    logic [29:0] s_phc_init_nanoseconds = 30'd20_000;
    logic        s_phc_lock_enable      = 1'b1;

    wire        m_phc_hw_capture; wire [29:0] m_phc_nanoseconds; wire [47:0] m_phc_seconds;
    wire        m_phc_pps; wire [47:0] m_phc_hw_cap_seconds; wire [29:0] m_phc_hw_cap_nanoseconds;
    wire [31:0] m_phc_hw_cap_sub_nanoseconds; wire m_phc_hw_set_time;
    wire [47:0] m_phc_hw_set_seconds; wire [29:0] m_phc_hw_set_nanoseconds;
    wire        m_phc_hw_adj_valid; wire [31:0] m_phc_hw_adj_ns_incr_frac; wire m_phc_locked;
    wire        s_phc_hw_capture; wire [29:0] s_phc_nanoseconds; wire [47:0] s_phc_seconds;
    wire        s_phc_pps; wire [47:0] s_phc_hw_cap_seconds; wire [29:0] s_phc_hw_cap_nanoseconds;
    wire [31:0] s_phc_hw_cap_sub_nanoseconds; wire s_phc_hw_set_time;
    wire [47:0] s_phc_hw_set_seconds; wire [29:0] s_phc_hw_set_nanoseconds;
    wire        s_phc_hw_adj_valid; wire [31:0] s_phc_hw_adj_ns_incr_frac; wire s_phc_locked;

    tb_phc_model #(.SYS_DATA_W(SYS_DATA_W), .NOMINAL_NS_INCR(1)) u_m_phc (
        .phc_clk(hclk), .phc_resetn(m_hresetn_w),
        .init_seconds(m_phc_init_seconds), .init_nanoseconds(m_phc_init_nanoseconds),
        .lock_enable_i(m_phc_lock_enable),
        .phc_hw_capture(m_phc_hw_capture), .phc_nanoseconds(m_phc_nanoseconds),
        .phc_seconds(m_phc_seconds), .phc_pps(m_phc_pps),
        .phc_hw_cap_seconds(m_phc_hw_cap_seconds), .phc_hw_cap_nanoseconds(m_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds(m_phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time(m_phc_hw_set_time), .phc_hw_set_seconds(m_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds(m_phc_hw_set_nanoseconds), .phc_hw_adj_valid(m_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac(m_phc_hw_adj_ns_incr_frac), .phc_locked_o(m_phc_locked)
    );
    tb_phc_model #(.SYS_DATA_W(SYS_DATA_W), .NOMINAL_NS_INCR(1)) u_s_phc (
        .phc_clk(hclk), .phc_resetn(s_hresetn_w),
        .init_seconds(s_phc_init_seconds), .init_nanoseconds(s_phc_init_nanoseconds),
        .lock_enable_i(s_phc_lock_enable),
        .phc_hw_capture(s_phc_hw_capture), .phc_nanoseconds(s_phc_nanoseconds),
        .phc_seconds(s_phc_seconds), .phc_pps(s_phc_pps),
        .phc_hw_cap_seconds(s_phc_hw_cap_seconds), .phc_hw_cap_nanoseconds(s_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds(s_phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time(s_phc_hw_set_time), .phc_hw_set_seconds(s_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds(s_phc_hw_set_nanoseconds), .phc_hw_adj_valid(s_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac(s_phc_hw_adj_ns_incr_frac), .phc_locked_o(s_phc_locked)
    );

    // =========================================================================
    // TideChart <-> TideLink boundary nets (per-die, port 0)
    //   Direction naming per TideLink / the chiplet shim:
    //     tc_*_rx_* : TideLink -> TideChart   (tidelink drives)
    //     tc_*_tx_* : TideChart -> TideLink   (tidechart drives)
    // =========================================================================
    // die_a (master)
    wire         m_tc_rx_tvalid;  wire [FC_DATA_W-1:0] m_tc_rx_tdata;  wire m_tc_rx_tready;
    wire         m_tc_tx_tvalid;  wire [FC_DATA_W-1:0] m_tc_tx_tdata;  wire m_tc_tx_tready;
    wire  [4:0]  m_tl_link_state; wire m_tl_link_state_change;         wire m_tl_bcast_ack;
    // die_b (slave)
    wire         s_tc_rx_tvalid;  wire [FC_DATA_W-1:0] s_tc_rx_tdata;  wire s_tc_rx_tready;
    wire         s_tc_tx_tvalid;  wire [FC_DATA_W-1:0] s_tc_tx_tdata;  wire s_tc_tx_tready;
    wire  [4:0]  s_tl_link_state; wire s_tl_link_state_change;         wire s_tl_bcast_ack;

    // =========================================================================
    // DUT: master tidelink_top  (u_master)
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W(SYS_ADDR_W), .SYS_DATA_W(SYS_DATA_W), .RAM_ADDR_W(RAM_ADDR_W),
        .RAM_DATA_W(RAM_DATA_W), .APB_ADDR_W(APB_ADDR_W), .FC_DATA_W(FC_DATA_W),
        .NUM_PHY_LANES(NUM_PHY_LANES), .TIDELINK_PAIR_BASE(M_PAIR_BASE)
    ) u_master (
        .hclk(hclk), .hresetn(m_hresetn_w), .poresetn(m_poresetn_w),
        .ahb_sub_hsel(1'b0), .ahb_sub_haddr(32'h0), .ahb_sub_hburst(3'h0),
        .ahb_sub_hprot(4'h0), .ahb_sub_hsize(3'h0), .ahb_sub_htrans(2'b00),
        .ahb_sub_hwdata(32'h0), .ahb_sub_hwrite(1'b0), .ahb_sub_hready(1'b1),
        .ahb_sub_hrdata(), .ahb_sub_hresp(), .ahb_sub_hreadyout(),
        .ahb_tx_hsel(m_ahb_tx_hsel), .ahb_tx_haddr(m_ahb_tx_haddr), .ahb_tx_htrans(m_ahb_tx_htrans),
        .ahb_tx_hsize(m_ahb_tx_hsize), .ahb_tx_hwrite(m_ahb_tx_hwrite), .ahb_tx_hwdata(m_ahb_tx_hwdata),
        .ahb_tx_hready(m_ahb_tx_hready_loop), .ahb_tx_hrdata(m_ahb_tx_hrdata),
        .ahb_tx_hresp(m_ahb_tx_hresp), .ahb_tx_hreadyout(m_ahb_tx_hready),
        .ahb_fifo_hsel(m_ahb_fifo_hsel), .ahb_fifo_haddr(m_ahb_fifo_haddr), .ahb_fifo_htrans(m_ahb_fifo_htrans),
        .ahb_fifo_hsize(m_ahb_fifo_hsize), .ahb_fifo_hwrite(m_ahb_fifo_hwrite), .ahb_fifo_hwdata(m_ahb_fifo_hwdata),
        .ahb_fifo_hready(m_ahb_fifo_hready), .ahb_fifo_hrdata(m_ahb_fifo_hrdata),
        .ahb_fifo_hresp(m_ahb_fifo_hresp), .ahb_fifo_hreadyout(m_ahb_fifo_hready),
        .ahb_mng_haddr(), .ahb_mng_hburst(), .ahb_mng_hprot(), .ahb_mng_hsize(),
        .ahb_mng_htrans(), .ahb_mng_hwdata(), .ahb_mng_hwrite(),
        .ahb_mng_hready(1'b1), .ahb_mng_hrdata(32'h0), .ahb_mng_hresp(1'b0),
        .apb_psel(m_apb_psel), .apb_paddr(m_apb_paddr), .apb_penable(m_apb_penable),
        .apb_pwrite(m_apb_pwrite), .apb_pstrb(m_apb_pstrb), .apb_pprot(m_apb_pprot),
        .apb_pwdata(m_apb_pwdata), .apb_prdata(m_apb_prdata), .apb_pready(m_apb_pready), .apb_pslverr(m_apb_pslverr),
        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0), .scan_shift(1'b0),
        .scan_in(1'b0), .scan_out(),
        .user_ref_clk(ref_clk),
        .pad_clk_tx(m_pad_clk_tx), .pad_tx(m_pad_tx),
        .pad_clk_rx(s_pad_clk_tx_skid & s_por_gate),
        .pad_rx(s_pad_tx_skid & {NUM_PHY_LANES{s_por_gate}}),
        .idelay_ref_clk(1'b0),
        .phc_clk(hclk), .phc_resetn(m_hresetn_w),
        .phc_nanoseconds(m_phc_nanoseconds), .phc_seconds(m_phc_seconds), .phc_pps(m_phc_pps),
        .phc_hw_cap_seconds(m_phc_hw_cap_seconds), .phc_hw_cap_nanoseconds(m_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds(m_phc_hw_cap_sub_nanoseconds), .phc_locked_i(m_phc_locked),
        .ahb_ptp_hsel(1'b0), .ahb_ptp_haddr(4'h0), .ahb_ptp_htrans(2'b00), .ahb_ptp_hsize(3'h0),
        .ahb_ptp_hwrite(1'b0), .ahb_ptp_hwdata(32'h0), .ahb_ptp_hready(1'b1),
        .ahb_ptp_hrdata(), .ahb_ptp_hresp(), .ahb_ptp_hreadyout(),
        .phc_hw_capture(m_phc_hw_capture), .phc_hw_set_time(m_phc_hw_set_time),
        .phc_hw_set_seconds(m_phc_hw_set_seconds), .phc_hw_set_nanoseconds(m_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid(m_phc_hw_adj_valid), .phc_hw_adj_ns_incr_frac(m_phc_hw_adj_ns_incr_frac),
        .servo_locked(),
        // ---- TideChart AXI-Stream: WIRED to u_tc_master (was tied off) ----
        .tc_axis_tx_tvalid(m_tc_tx_tvalid), .tc_axis_tx_tdata(m_tc_tx_tdata), .tc_axis_tx_tready(m_tc_tx_tready),
        .tc_axis_rx_tvalid(m_tc_rx_tvalid), .tc_axis_rx_tdata(m_tc_rx_tdata), .tc_axis_rx_tready(m_tc_rx_tready),
        .tc_qos_priority(3'h0),
        // ---- Congestion sideband: WIRED to u_tc_master ----
        .tl_local_link_state_o(m_tl_link_state), .tl_link_state_change_o(m_tl_link_state_change),
        .tl_ewma_credit_o(), .tl_bcast_ack_i(m_tl_bcast_ack),
        .link_active(m_link_active), .d2d_reset_o(m_d2d_reset_o),
        .role_strap_i(1'b0), .role_is_master_o(m_role_is_master), .role_locked_o(m_role_locked),
        .apb_debug_unlock_i(m_apb_debug_unlock), .mask_hs_bypass_i(m_mask_hs_bypass),
        .nego_priority_i(16'h8000), .puf_seed(16'hA5A5), .puf_ready(1'b1), .nego_error_irq(),
        .i2c_scl_i(i2c_scl), .i2c_scl_o(m_i2c_scl_o), .i2c_scl_t(m_i2c_scl_t),
        .i2c_sda_i(i2c_sda), .i2c_sda_o(m_i2c_sda_o), .i2c_sda_t(m_i2c_sda_t),
        .s_i2c_axi_awvalid(1'b0), .s_i2c_axi_awid(2'b00), .s_i2c_axi_awaddr(4'h0), .s_i2c_axi_awlen(8'h00),
        .s_i2c_axi_awsize(3'h0), .s_i2c_axi_awburst(2'b00), .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache(4'h0),
        .s_i2c_axi_awprot(3'h0), .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata(32'h0), .s_i2c_axi_wstrb(4'h0), .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(), .s_i2c_axi_bready(1'b1),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid(2'b00), .s_i2c_axi_araddr(4'h0), .s_i2c_axi_arlen(8'h00),
        .s_i2c_axi_arsize(3'h0), .s_i2c_axi_arburst(2'b00), .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache(4'h0),
        .s_i2c_axi_arprot(3'h0), .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(), .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b1),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq(),
        .released_credits_irq(m_released_credits_irq), .doorbell_irq(m_doorbell_irq),
        .packet_committed_irq(m_packet_committed_irq), .ptp_irq(m_ptp_irq),
        .perf_irq(m_perf_irq), .wlink_irq(m_wlink_irq)
    );

    // =========================================================================
    // DUT: slave tidelink_top  (u_slave)
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W(SYS_ADDR_W), .SYS_DATA_W(SYS_DATA_W), .RAM_ADDR_W(RAM_ADDR_W),
        .RAM_DATA_W(RAM_DATA_W), .APB_ADDR_W(APB_ADDR_W), .FC_DATA_W(FC_DATA_W),
        .NUM_PHY_LANES(NUM_PHY_LANES), .TIDELINK_PAIR_BASE(S_PAIR_BASE)
    ) u_slave (
        .hclk(hclk), .hresetn(s_hresetn_w), .poresetn(s_poresetn_w),
        .ahb_sub_hsel(1'b0), .ahb_sub_haddr(32'h0), .ahb_sub_hburst(3'h0),
        .ahb_sub_hprot(4'h0), .ahb_sub_hsize(3'h0), .ahb_sub_htrans(2'b00),
        .ahb_sub_hwdata(32'h0), .ahb_sub_hwrite(1'b0), .ahb_sub_hready(1'b1),
        .ahb_sub_hrdata(), .ahb_sub_hresp(), .ahb_sub_hreadyout(),
        .ahb_tx_hsel(s_ahb_tx_hsel), .ahb_tx_haddr(s_ahb_tx_haddr), .ahb_tx_htrans(s_ahb_tx_htrans),
        .ahb_tx_hsize(s_ahb_tx_hsize), .ahb_tx_hwrite(s_ahb_tx_hwrite), .ahb_tx_hwdata(s_ahb_tx_hwdata),
        .ahb_tx_hready(s_ahb_tx_hready_loop), .ahb_tx_hrdata(s_ahb_tx_hrdata),
        .ahb_tx_hresp(s_ahb_tx_hresp), .ahb_tx_hreadyout(s_ahb_tx_hready),
        .ahb_fifo_hsel(s_ahb_fifo_hsel), .ahb_fifo_haddr(s_ahb_fifo_haddr), .ahb_fifo_htrans(s_ahb_fifo_htrans),
        .ahb_fifo_hsize(s_ahb_fifo_hsize), .ahb_fifo_hwrite(s_ahb_fifo_hwrite), .ahb_fifo_hwdata(s_ahb_fifo_hwdata),
        .ahb_fifo_hready(s_ahb_fifo_hready), .ahb_fifo_hrdata(s_ahb_fifo_hrdata),
        .ahb_fifo_hresp(s_ahb_fifo_hresp), .ahb_fifo_hreadyout(s_ahb_fifo_hready),
        .ahb_mng_haddr(), .ahb_mng_hburst(), .ahb_mng_hprot(), .ahb_mng_hsize(),
        .ahb_mng_htrans(), .ahb_mng_hwdata(), .ahb_mng_hwrite(),
        .ahb_mng_hready(1'b1), .ahb_mng_hrdata(32'h0), .ahb_mng_hresp(1'b0),
        .apb_psel(s_apb_psel), .apb_paddr(s_apb_paddr), .apb_penable(s_apb_penable),
        .apb_pwrite(s_apb_pwrite), .apb_pstrb(s_apb_pstrb), .apb_pprot(s_apb_pprot),
        .apb_pwdata(s_apb_pwdata), .apb_prdata(s_apb_prdata), .apb_pready(s_apb_pready), .apb_pslverr(s_apb_pslverr),
        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0), .scan_shift(1'b0),
        .scan_in(1'b0), .scan_out(),
        .user_ref_clk(ref_clk),
        .pad_clk_tx(s_pad_clk_tx), .pad_tx(s_pad_tx),
        .pad_clk_rx(m_pad_clk_tx_skid & m_por_gate),
        .pad_rx(m_pad_tx_skid & {NUM_PHY_LANES{m_por_gate}}),
        .idelay_ref_clk(1'b0),
        .phc_clk(hclk), .phc_resetn(s_hresetn_w),
        .phc_nanoseconds(s_phc_nanoseconds), .phc_seconds(s_phc_seconds), .phc_pps(s_phc_pps),
        .phc_hw_cap_seconds(s_phc_hw_cap_seconds), .phc_hw_cap_nanoseconds(s_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds(s_phc_hw_cap_sub_nanoseconds), .phc_locked_i(s_phc_locked),
        .ahb_ptp_hsel(1'b0), .ahb_ptp_haddr(4'h0), .ahb_ptp_htrans(2'b00), .ahb_ptp_hsize(3'h0),
        .ahb_ptp_hwrite(1'b0), .ahb_ptp_hwdata(32'h0), .ahb_ptp_hready(1'b1),
        .ahb_ptp_hrdata(), .ahb_ptp_hresp(), .ahb_ptp_hreadyout(),
        .phc_hw_capture(s_phc_hw_capture), .phc_hw_set_time(s_phc_hw_set_time),
        .phc_hw_set_seconds(s_phc_hw_set_seconds), .phc_hw_set_nanoseconds(s_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid(s_phc_hw_adj_valid), .phc_hw_adj_ns_incr_frac(s_phc_hw_adj_ns_incr_frac),
        .servo_locked(),
        // ---- TideChart AXI-Stream: WIRED to u_tc_slave ----
        .tc_axis_tx_tvalid(s_tc_tx_tvalid), .tc_axis_tx_tdata(s_tc_tx_tdata), .tc_axis_tx_tready(s_tc_tx_tready),
        .tc_axis_rx_tvalid(s_tc_rx_tvalid), .tc_axis_rx_tdata(s_tc_rx_tdata), .tc_axis_rx_tready(s_tc_rx_tready),
        .tc_qos_priority(3'h0),
        .tl_local_link_state_o(s_tl_link_state), .tl_link_state_change_o(s_tl_link_state_change),
        .tl_ewma_credit_o(), .tl_bcast_ack_i(s_tl_bcast_ack),
        .link_active(s_link_active), .d2d_reset_o(s_d2d_reset_o),
        .role_strap_i(1'b1), .role_is_master_o(s_role_is_master), .role_locked_o(s_role_locked),
        .apb_debug_unlock_i(s_apb_debug_unlock), .mask_hs_bypass_i(s_mask_hs_bypass),
        .nego_priority_i(16'h7FFF), .puf_seed(16'h5A5A), .puf_ready(1'b1), .nego_error_irq(),
        .i2c_scl_i(i2c_scl), .i2c_scl_o(s_i2c_scl_o), .i2c_scl_t(s_i2c_scl_t),
        .i2c_sda_i(i2c_sda), .i2c_sda_o(s_i2c_sda_o), .i2c_sda_t(s_i2c_sda_t),
        .s_i2c_axi_awvalid(1'b0), .s_i2c_axi_awid(2'b00), .s_i2c_axi_awaddr(4'h0), .s_i2c_axi_awlen(8'h00),
        .s_i2c_axi_awsize(3'h0), .s_i2c_axi_awburst(2'b00), .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache(4'h0),
        .s_i2c_axi_awprot(3'h0), .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata(32'h0), .s_i2c_axi_wstrb(4'h0), .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(), .s_i2c_axi_bready(1'b1),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid(2'b00), .s_i2c_axi_araddr(4'h0), .s_i2c_axi_arlen(8'h00),
        .s_i2c_axi_arsize(3'h0), .s_i2c_axi_arburst(2'b00), .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache(4'h0),
        .s_i2c_axi_arprot(3'h0), .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(), .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b1),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq(),
        .released_credits_irq(s_released_credits_irq), .doorbell_irq(s_doorbell_irq),
        .packet_committed_irq(s_packet_committed_irq), .ptp_irq(s_ptp_irq),
        .perf_irq(s_perf_irq), .wlink_irq(s_wlink_irq)
    );

    // =========================================================================
    // TideChart on die_a (master)  — attached per tidechart_shim pattern.
    //   Link port 0 = this die's tidelink; port 1 tied off (NUM_PORTS=2).
    // =========================================================================
    logic         m_tc_apb_psel, m_tc_apb_penable, m_tc_apb_pwrite;
    logic  [7:0]  m_tc_apb_paddr;
    logic [31:0]  m_tc_apb_pwdata;
    wire  [31:0]  m_tc_apb_prdata;
    wire          m_tc_apb_pready, m_tc_apb_pslverr, m_tc_irq;

    wire [1:0]  m_tc_rx_tready_v;  assign m_tc_rx_tready = m_tc_rx_tready_v[0];
    wire [1:0]  m_tc_tx_tvalid_v;  assign m_tc_tx_tvalid = m_tc_tx_tvalid_v[0];
    wire [95:0] m_tc_tx_tdata_flat; assign m_tc_tx_tdata = m_tc_tx_tdata_flat[FC_DATA_W-1:0];
    wire [1:0]  m_tc_bcast_ack_v;  assign m_tl_bcast_ack = m_tc_bcast_ack_v[0];

    tidechart_shim #(.NUM_PORTS(2), .FC_DATA_W(FC_DATA_W), .APB_ADDR_W(8), .SYS_DATA_W(32)) u_tc_master (
        .clk(hclk), .resetn(m_hresetn_w),
        .tc_axis_rx_tvalid    ({1'b0, m_tc_rx_tvalid}),
        .tc_axis_rx_tdata_flat({48'b0, m_tc_rx_tdata}),
        .tc_axis_rx_tready    (m_tc_rx_tready_v),
        .tc_axis_tx_tvalid    (m_tc_tx_tvalid_v),
        .tc_axis_tx_tdata_flat(m_tc_tx_tdata_flat),
        .tc_axis_tx_tready    ({1'b1, m_tc_tx_tready}),
        .link_active          ({1'b0, m_link_active}),
        .local_link_state_i_flat  ({5'b0, m_tl_link_state}),
        .local_link_state_change_i({1'b0, m_tl_link_state_change}),
        .local_bcast_ack_o        (m_tc_bcast_ack_v),
        .apb_paddr(m_tc_apb_paddr), .apb_psel(m_tc_apb_psel), .apb_penable(m_tc_apb_penable),
        .apb_pwrite(m_tc_apb_pwrite), .apb_pwdata(m_tc_apb_pwdata), .apb_prdata(m_tc_apb_prdata),
        .apb_pready(m_tc_apb_pready), .apb_pslverr(m_tc_apb_pslverr),
        .tidechart_irq(m_tc_irq),
        .tc_to_irqc_tvalid_o(), .tc_to_irqc_tdata_o(), .tc_to_irqc_tready_i(1'b1), .tc_to_irqc_tlast_o(),
        .irqc_to_tc_tvalid_i(1'b0), .irqc_to_tc_tdata_i(32'h0), .irqc_to_tc_tready_o()
    );

    // =========================================================================
    // TideChart on die_b (slave)
    // =========================================================================
    logic         s_tc_apb_psel, s_tc_apb_penable, s_tc_apb_pwrite;
    logic  [7:0]  s_tc_apb_paddr;
    logic [31:0]  s_tc_apb_pwdata;
    wire  [31:0]  s_tc_apb_prdata;
    wire          s_tc_apb_pready, s_tc_apb_pslverr, s_tc_irq;

    wire [1:0]  s_tc_rx_tready_v;  assign s_tc_rx_tready = s_tc_rx_tready_v[0];
    wire [1:0]  s_tc_tx_tvalid_v;  assign s_tc_tx_tvalid = s_tc_tx_tvalid_v[0];
    wire [95:0] s_tc_tx_tdata_flat; assign s_tc_tx_tdata = s_tc_tx_tdata_flat[FC_DATA_W-1:0];
    wire [1:0]  s_tc_bcast_ack_v;  assign s_tl_bcast_ack = s_tc_bcast_ack_v[0];

    tidechart_shim #(.NUM_PORTS(2), .FC_DATA_W(FC_DATA_W), .APB_ADDR_W(8), .SYS_DATA_W(32)) u_tc_slave (
        .clk(hclk), .resetn(s_hresetn_w),
        .tc_axis_rx_tvalid    ({1'b0, s_tc_rx_tvalid}),
        .tc_axis_rx_tdata_flat({48'b0, s_tc_rx_tdata}),
        .tc_axis_rx_tready    (s_tc_rx_tready_v),
        .tc_axis_tx_tvalid    (s_tc_tx_tvalid_v),
        .tc_axis_tx_tdata_flat(s_tc_tx_tdata_flat),
        .tc_axis_tx_tready    ({1'b1, s_tc_tx_tready}),
        .link_active          ({1'b0, s_link_active}),
        .local_link_state_i_flat  ({5'b0, s_tl_link_state}),
        .local_link_state_change_i({1'b0, s_tl_link_state_change}),
        .local_bcast_ack_o        (s_tc_bcast_ack_v),
        .apb_paddr(s_tc_apb_paddr), .apb_psel(s_tc_apb_psel), .apb_penable(s_tc_apb_penable),
        .apb_pwrite(s_tc_apb_pwrite), .apb_pwdata(s_tc_apb_pwdata), .apb_prdata(s_tc_apb_prdata),
        .apb_pready(s_tc_apb_pready), .apb_pslverr(s_tc_apb_pslverr),
        .tidechart_irq(s_tc_irq),
        .tc_to_irqc_tvalid_o(), .tc_to_irqc_tdata_o(), .tc_to_irqc_tready_i(1'b1), .tc_to_irqc_tlast_o(),
        .irqc_to_tc_tvalid_i(1'b0), .irqc_to_tc_tdata_i(32'h0), .irqc_to_tc_tready_o()
    );

    // ----- Waveform dump (gated) ---------------------------------------------
    `ifndef TB_TOP_NO_DUMP
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_tc_pair);
    end
    `endif

endmodule
