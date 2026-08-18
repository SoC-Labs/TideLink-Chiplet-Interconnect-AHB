//=============================================================================
// tb_inert.sv — harness for the tidelink_link_rate_regs_inert gate
//
// ONE tidelink_top, elaborated with ITS OWN DEFAULT PARAMETERS — which means
// LINK_RATE_REGS_PRESENT = 1'b0, the shipping configuration. There is no link
// partner, no PHY traffic and no bring-up here, on purpose: the property under
// test is that the OFF arm of `g_link_rate_absent` reproduces the pre-feature
// behaviour of tidelink_top's APB quadrant 11 and of its link-clock ratio
// source. Neither needs a trained link, and a bench that needed one would take
// minutes and hide the property behind everything else that can go wrong.
//
// WHY A DEDICATED HARNESS RATHER THAN tidelink_top_pair
//   tidelink_top_pair's tb_top.sv drives link_clk_div_ratio_i from a plusarg
//   and runs the whole bring-up chain. Re-running that suite is evidence the
//   DIVIDER works; it is not evidence the OFF arm is inert, because a suite
//   that never touches quadrant 11 gives exactly the same result whether the
//   OFF arm drives 1'b1 or 1'b0 onto rate_pready. That indiscriminacy is the
//   defect this bench exists to close.
//
// EVERY tidelink_top input is driven. 88 of them are tied to 0 by the block
// below; the 11 the bench actually uses (clocks, resets, the APB request
// channel, link_clk_div_ratio_i) are driven from cocotb. Nothing is left
// floating, so no result here can be an artefact of a 'z input.
//
// MAINTENANCE. This port list was generated from the module header of
// src/rtl/tidelink_top.sv and mirrors it as of 2026-08-18. If a port is ADDED
// to tidelink_top, named-port instantiation leaves it unconnected here rather
// than erroring — so re-generate this list when the header changes. That gap
// cannot manufacture a false PASS, because the property under test reads only
// apb_*, link_clk_div_ratio_i, scan_mode, the two clocks and the two resets,
// all of which are connected explicitly above; a new floating input can make a
// test fail, never make a broken OFF arm look correct.
//
// The obs_* nets are hierarchical TAPS, not extra logic: they let cocotb watch
// the divider's real output clock and its effective ratio without depending on
// how VCS names generate scopes. obs_present taps the PARAMETER itself, so the
// bench can refuse to run — loudly — if someone flips the default to 1 and
// this gate silently starts measuring the ON build instead.
//=============================================================================
`timescale 1ns/1ps

module tb_inert;

    // Mirror of the tidelink_top defaults these port widths depend on.
    localparam SYS_ADDR_W    = 32;
    localparam SYS_DATA_W    = 32;
    localparam RAM_ADDR_W    = 14;
    localparam FC_DATA_W     = 48;
    localparam NUM_PHY_LANES = 8;

    // ---- tidelink_top port nets (generated from the module header) ----------
    logic hclk;
    logic hresetn;
    logic poresetn;
    logic phc_clk;
    logic phc_resetn;
    logic ahb_sub_hsel;
    logic [SYS_ADDR_W-1:0] ahb_sub_haddr;
    logic [2:0] ahb_sub_hburst;
    logic [3:0] ahb_sub_hprot;
    logic [2:0] ahb_sub_hsize;
    logic [1:0] ahb_sub_htrans;
    logic [SYS_DATA_W-1:0] ahb_sub_hwdata;
    logic ahb_sub_hwrite;
    logic ahb_sub_hready;
    wire  [SYS_DATA_W-1:0] ahb_sub_hrdata;
    wire  ahb_sub_hresp;
    wire  ahb_sub_hreadyout;
    logic ahb_tx_hsel;
    logic [RAM_ADDR_W-1:0] ahb_tx_haddr;
    logic [1:0] ahb_tx_htrans;
    logic [2:0] ahb_tx_hsize;
    logic ahb_tx_hwrite;
    logic [SYS_DATA_W-1:0] ahb_tx_hwdata;
    logic ahb_tx_hready;
    wire  [SYS_DATA_W-1:0] ahb_tx_hrdata;
    wire  ahb_tx_hresp;
    wire  ahb_tx_hreadyout;
    logic ahb_fifo_hsel;
    logic [RAM_ADDR_W-1:0] ahb_fifo_haddr;
    logic [1:0] ahb_fifo_htrans;
    logic [2:0] ahb_fifo_hsize;
    logic ahb_fifo_hwrite;
    logic [SYS_DATA_W-1:0] ahb_fifo_hwdata;
    logic ahb_fifo_hready;
    wire  [SYS_DATA_W-1:0] ahb_fifo_hrdata;
    wire  ahb_fifo_hresp;
    wire  ahb_fifo_hreadyout;
    wire  [SYS_ADDR_W-1:0] ahb_mng_haddr;
    wire  [2:0] ahb_mng_hburst;
    wire  [6:0] ahb_mng_hprot;
    wire  [2:0] ahb_mng_hsize;
    wire  [1:0] ahb_mng_htrans;
    wire  [SYS_DATA_W-1:0] ahb_mng_hwdata;
    wire  ahb_mng_hwrite;
    logic ahb_mng_hready;
    logic [SYS_DATA_W-1:0] ahb_mng_hrdata;
    logic ahb_mng_hresp;
    logic [14:0] apb_paddr;
    logic apb_penable;
    logic apb_pwrite;
    logic [3:0] apb_pstrb;
    logic [2:0] apb_pprot;
    logic [SYS_DATA_W-1:0] apb_pwdata;
    logic apb_psel;
    wire  [SYS_DATA_W-1:0] apb_prdata;
    wire  apb_pready;
    wire  apb_pslverr;
    logic scan_mode;
    logic scan_asyncrst_ctrl;
    logic scan_clk;
    logic scan_shift;
    logic scan_in;
    wire  scan_out;
    logic user_ref_clk;
    logic [2:0] link_clk_div_ratio_i;
    wire  pad_clk_tx;
    wire  [NUM_PHY_LANES-1:0] pad_tx;
    logic pad_clk_rx;
    logic [NUM_PHY_LANES-1:0] pad_rx;
    logic idelay_ref_clk;
    logic ahb_ptp_hsel;
    logic [3:0] ahb_ptp_haddr;
    logic [1:0] ahb_ptp_htrans;
    logic [2:0] ahb_ptp_hsize;
    logic ahb_ptp_hwrite;
    logic [SYS_DATA_W-1:0] ahb_ptp_hwdata;
    logic ahb_ptp_hready;
    wire  [SYS_DATA_W-1:0] ahb_ptp_hrdata;
    wire  ahb_ptp_hresp;
    wire  ahb_ptp_hreadyout;
    wire  phc_hw_capture;
    logic [29:0] phc_nanoseconds;
    logic [47:0] phc_seconds;
    logic phc_pps;
    logic [47:0] phc_hw_cap_seconds;
    logic [29:0] phc_hw_cap_nanoseconds;
    logic [SYS_DATA_W-1:0] phc_hw_cap_sub_nanoseconds;
    wire  phc_hw_set_time;
    wire  [47:0] phc_hw_set_seconds;
    wire  [29:0] phc_hw_set_nanoseconds;
    wire  phc_hw_adj_valid;
    wire  [SYS_DATA_W-1:0] phc_hw_adj_ns_incr_frac;
    logic phc_locked_i;
    wire  servo_locked;
    wire  released_credits_irq;
    wire  doorbell_irq;
    wire  packet_committed_irq;
    wire  ptp_irq;
    wire  perf_irq;
    wire  wlink_irq;
    logic tc_axis_tx_tvalid;
    logic [FC_DATA_W-1:0] tc_axis_tx_tdata;
    wire  tc_axis_tx_tready;
    wire  tc_axis_rx_tvalid;
    wire  [FC_DATA_W-1:0] tc_axis_rx_tdata;
    logic tc_axis_rx_tready;
    logic [2:0] tc_qos_priority;
    wire  [4:0] tl_local_link_state_o;
    wire  tl_link_state_change_o;
    wire  [12:0] tl_ewma_credit_o;
    logic tl_bcast_ack_i;
    wire  link_active;
    wire  tl_data_mode_o;
    wire  d2d_reset_o;
    logic role_strap_i;
    wire  role_is_master_o;
    wire  role_locked_o;
    logic apb_debug_unlock_i;
    logic mask_hs_bypass_i;
    logic [15:0] nego_priority_i;
    logic [15:0] puf_seed;
    logic puf_ready;
    wire  nego_error_irq;
    wire  train_fail_irq;
    logic i2c_scl_i;
    wire  i2c_scl_o;
    wire  i2c_scl_t;
    logic i2c_sda_i;
    wire  i2c_sda_o;
    wire  i2c_sda_t;
    logic s_i2c_axi_awvalid;
    logic [1:0] s_i2c_axi_awid;
    logic [3:0] s_i2c_axi_awaddr;
    logic [7:0] s_i2c_axi_awlen;
    logic [2:0] s_i2c_axi_awsize;
    logic [1:0] s_i2c_axi_awburst;
    logic s_i2c_axi_awlock;
    logic [3:0] s_i2c_axi_awcache;
    logic [2:0] s_i2c_axi_awprot;
    wire  s_i2c_axi_awready;
    logic s_i2c_axi_wvalid;
    logic [SYS_DATA_W-1:0] s_i2c_axi_wdata;
    logic [3:0] s_i2c_axi_wstrb;
    logic s_i2c_axi_wlast;
    wire  s_i2c_axi_wready;
    wire  s_i2c_axi_bvalid;
    wire  [1:0] s_i2c_axi_bid;
    wire  [1:0] s_i2c_axi_bresp;
    logic s_i2c_axi_bready;
    logic s_i2c_axi_arvalid;
    logic [1:0] s_i2c_axi_arid;
    logic [3:0] s_i2c_axi_araddr;
    logic [7:0] s_i2c_axi_arlen;
    logic [2:0] s_i2c_axi_arsize;
    logic [1:0] s_i2c_axi_arburst;
    logic s_i2c_axi_arlock;
    logic [3:0] s_i2c_axi_arcache;
    logic [2:0] s_i2c_axi_arprot;
    wire  s_i2c_axi_arready;
    wire  s_i2c_axi_rvalid;
    wire  [1:0] s_i2c_axi_rid;
    wire  [SYS_DATA_W-1:0] s_i2c_axi_rdata;
    wire  [1:0] s_i2c_axi_rresp;
    wire  s_i2c_axi_rlast;
    logic s_i2c_axi_rready;
    wire  i2c_nbsy_irq;
    wire  i2c_nrd_empty_irq;

    // ---- DUT: default parameters, i.e. LINK_RATE_REGS_PRESENT = 1'b0 --------
    tidelink_top u_dut (
        .hclk (hclk),
        .hresetn (hresetn),
        .poresetn (poresetn),
        .phc_clk (phc_clk),
        .phc_resetn (phc_resetn),
        .ahb_sub_hsel (ahb_sub_hsel),
        .ahb_sub_haddr (ahb_sub_haddr),
        .ahb_sub_hburst (ahb_sub_hburst),
        .ahb_sub_hprot (ahb_sub_hprot),
        .ahb_sub_hsize (ahb_sub_hsize),
        .ahb_sub_htrans (ahb_sub_htrans),
        .ahb_sub_hwdata (ahb_sub_hwdata),
        .ahb_sub_hwrite (ahb_sub_hwrite),
        .ahb_sub_hready (ahb_sub_hready),
        .ahb_sub_hrdata (ahb_sub_hrdata),
        .ahb_sub_hresp (ahb_sub_hresp),
        .ahb_sub_hreadyout (ahb_sub_hreadyout),
        .ahb_tx_hsel (ahb_tx_hsel),
        .ahb_tx_haddr (ahb_tx_haddr),
        .ahb_tx_htrans (ahb_tx_htrans),
        .ahb_tx_hsize (ahb_tx_hsize),
        .ahb_tx_hwrite (ahb_tx_hwrite),
        .ahb_tx_hwdata (ahb_tx_hwdata),
        .ahb_tx_hready (ahb_tx_hready),
        .ahb_tx_hrdata (ahb_tx_hrdata),
        .ahb_tx_hresp (ahb_tx_hresp),
        .ahb_tx_hreadyout (ahb_tx_hreadyout),
        .ahb_fifo_hsel (ahb_fifo_hsel),
        .ahb_fifo_haddr (ahb_fifo_haddr),
        .ahb_fifo_htrans (ahb_fifo_htrans),
        .ahb_fifo_hsize (ahb_fifo_hsize),
        .ahb_fifo_hwrite (ahb_fifo_hwrite),
        .ahb_fifo_hwdata (ahb_fifo_hwdata),
        .ahb_fifo_hready (ahb_fifo_hready),
        .ahb_fifo_hrdata (ahb_fifo_hrdata),
        .ahb_fifo_hresp (ahb_fifo_hresp),
        .ahb_fifo_hreadyout (ahb_fifo_hreadyout),
        .ahb_mng_haddr (ahb_mng_haddr),
        .ahb_mng_hburst (ahb_mng_hburst),
        .ahb_mng_hprot (ahb_mng_hprot),
        .ahb_mng_hsize (ahb_mng_hsize),
        .ahb_mng_htrans (ahb_mng_htrans),
        .ahb_mng_hwdata (ahb_mng_hwdata),
        .ahb_mng_hwrite (ahb_mng_hwrite),
        .ahb_mng_hready (ahb_mng_hready),
        .ahb_mng_hrdata (ahb_mng_hrdata),
        .ahb_mng_hresp (ahb_mng_hresp),
        .apb_paddr (apb_paddr),
        .apb_penable (apb_penable),
        .apb_pwrite (apb_pwrite),
        .apb_pstrb (apb_pstrb),
        .apb_pprot (apb_pprot),
        .apb_pwdata (apb_pwdata),
        .apb_psel (apb_psel),
        .apb_prdata (apb_prdata),
        .apb_pready (apb_pready),
        .apb_pslverr (apb_pslverr),
        .scan_mode (scan_mode),
        .scan_asyncrst_ctrl (scan_asyncrst_ctrl),
        .scan_clk (scan_clk),
        .scan_shift (scan_shift),
        .scan_in (scan_in),
        .scan_out (scan_out),
        .user_ref_clk (user_ref_clk),
        .link_clk_div_ratio_i (link_clk_div_ratio_i),
        .pad_clk_tx (pad_clk_tx),
        .pad_tx (pad_tx),
        .pad_clk_rx (pad_clk_rx),
        .pad_rx (pad_rx),
        .idelay_ref_clk (idelay_ref_clk),
        .ahb_ptp_hsel (ahb_ptp_hsel),
        .ahb_ptp_haddr (ahb_ptp_haddr),
        .ahb_ptp_htrans (ahb_ptp_htrans),
        .ahb_ptp_hsize (ahb_ptp_hsize),
        .ahb_ptp_hwrite (ahb_ptp_hwrite),
        .ahb_ptp_hwdata (ahb_ptp_hwdata),
        .ahb_ptp_hready (ahb_ptp_hready),
        .ahb_ptp_hrdata (ahb_ptp_hrdata),
        .ahb_ptp_hresp (ahb_ptp_hresp),
        .ahb_ptp_hreadyout (ahb_ptp_hreadyout),
        .phc_hw_capture (phc_hw_capture),
        .phc_nanoseconds (phc_nanoseconds),
        .phc_seconds (phc_seconds),
        .phc_pps (phc_pps),
        .phc_hw_cap_seconds (phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds (phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time (phc_hw_set_time),
        .phc_hw_set_seconds (phc_hw_set_seconds),
        .phc_hw_set_nanoseconds (phc_hw_set_nanoseconds),
        .phc_hw_adj_valid (phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac (phc_hw_adj_ns_incr_frac),
        .phc_locked_i (phc_locked_i),
        .servo_locked (servo_locked),
        .released_credits_irq (released_credits_irq),
        .doorbell_irq (doorbell_irq),
        .packet_committed_irq (packet_committed_irq),
        .ptp_irq (ptp_irq),
        .perf_irq (perf_irq),
        .wlink_irq (wlink_irq),
        .tc_axis_tx_tvalid (tc_axis_tx_tvalid),
        .tc_axis_tx_tdata (tc_axis_tx_tdata),
        .tc_axis_tx_tready (tc_axis_tx_tready),
        .tc_axis_rx_tvalid (tc_axis_rx_tvalid),
        .tc_axis_rx_tdata (tc_axis_rx_tdata),
        .tc_axis_rx_tready (tc_axis_rx_tready),
        .tc_qos_priority (tc_qos_priority),
        .tl_local_link_state_o (tl_local_link_state_o),
        .tl_link_state_change_o (tl_link_state_change_o),
        .tl_ewma_credit_o (tl_ewma_credit_o),
        .tl_bcast_ack_i (tl_bcast_ack_i),
        .link_active (link_active),
        .tl_data_mode_o (tl_data_mode_o),
        .d2d_reset_o (d2d_reset_o),
        .role_strap_i (role_strap_i),
        .role_is_master_o (role_is_master_o),
        .role_locked_o (role_locked_o),
        .apb_debug_unlock_i (apb_debug_unlock_i),
        .mask_hs_bypass_i (mask_hs_bypass_i),
        .nego_priority_i (nego_priority_i),
        .puf_seed (puf_seed),
        .puf_ready (puf_ready),
        .nego_error_irq (nego_error_irq),
        .train_fail_irq (train_fail_irq),
        .i2c_scl_i (i2c_scl_i),
        .i2c_scl_o (i2c_scl_o),
        .i2c_scl_t (i2c_scl_t),
        .i2c_sda_i (i2c_sda_i),
        .i2c_sda_o (i2c_sda_o),
        .i2c_sda_t (i2c_sda_t),
        .s_i2c_axi_awvalid (s_i2c_axi_awvalid),
        .s_i2c_axi_awid (s_i2c_axi_awid),
        .s_i2c_axi_awaddr (s_i2c_axi_awaddr),
        .s_i2c_axi_awlen (s_i2c_axi_awlen),
        .s_i2c_axi_awsize (s_i2c_axi_awsize),
        .s_i2c_axi_awburst (s_i2c_axi_awburst),
        .s_i2c_axi_awlock (s_i2c_axi_awlock),
        .s_i2c_axi_awcache (s_i2c_axi_awcache),
        .s_i2c_axi_awprot (s_i2c_axi_awprot),
        .s_i2c_axi_awready (s_i2c_axi_awready),
        .s_i2c_axi_wvalid (s_i2c_axi_wvalid),
        .s_i2c_axi_wdata (s_i2c_axi_wdata),
        .s_i2c_axi_wstrb (s_i2c_axi_wstrb),
        .s_i2c_axi_wlast (s_i2c_axi_wlast),
        .s_i2c_axi_wready (s_i2c_axi_wready),
        .s_i2c_axi_bvalid (s_i2c_axi_bvalid),
        .s_i2c_axi_bid (s_i2c_axi_bid),
        .s_i2c_axi_bresp (s_i2c_axi_bresp),
        .s_i2c_axi_bready (s_i2c_axi_bready),
        .s_i2c_axi_arvalid (s_i2c_axi_arvalid),
        .s_i2c_axi_arid (s_i2c_axi_arid),
        .s_i2c_axi_araddr (s_i2c_axi_araddr),
        .s_i2c_axi_arlen (s_i2c_axi_arlen),
        .s_i2c_axi_arsize (s_i2c_axi_arsize),
        .s_i2c_axi_arburst (s_i2c_axi_arburst),
        .s_i2c_axi_arlock (s_i2c_axi_arlock),
        .s_i2c_axi_arcache (s_i2c_axi_arcache),
        .s_i2c_axi_arprot (s_i2c_axi_arprot),
        .s_i2c_axi_arready (s_i2c_axi_arready),
        .s_i2c_axi_rvalid (s_i2c_axi_rvalid),
        .s_i2c_axi_rid (s_i2c_axi_rid),
        .s_i2c_axi_rdata (s_i2c_axi_rdata),
        .s_i2c_axi_rresp (s_i2c_axi_rresp),
        .s_i2c_axi_rlast (s_i2c_axi_rlast),
        .s_i2c_axi_rready (s_i2c_axi_rready),
        .i2c_nbsy_irq (i2c_nbsy_irq),
        .i2c_nrd_empty_irq (i2c_nrd_empty_irq)
    );

    // ---- Observation taps ---------------------------------------------------
    // The divided PHY reference clock, as the PHY sees it.
    wire        obs_link_hsclk = u_dut.link_hsclk_w;
    // The ratio the divider is actually running (its own ratio_o readback).
    wire  [2:0] obs_ratio_eff  = u_dut.u_link_clk_div.ratio_o;
    // The net whose driver IS the OFF arm's ratio alias.
    wire  [2:0] obs_ratio_sel  = u_dut.link_ratio_sel_w;
    // Elaborated value of the parameter under test. If this is not 0 the gate
    // is measuring something other than the OFF arm and must not report PASS.
    wire        obs_present    = u_dut.LINK_RATE_REGS_PRESENT;

    // ---- Tie-off ------------------------------------------------------------
    // Everything the bench does not drive sits at 0 from time 0. cocotb drives
    // the rest; it waits 1 ns before its first assignment so this wins the
    // time-0 race either way.
    initial begin
        phc_clk <= '0;
        phc_resetn <= '0;
        ahb_sub_hsel <= '0;
        ahb_sub_haddr <= '0;
        ahb_sub_hburst <= '0;
        ahb_sub_hprot <= '0;
        ahb_sub_hsize <= '0;
        ahb_sub_htrans <= '0;
        ahb_sub_hwdata <= '0;
        ahb_sub_hwrite <= '0;
        ahb_sub_hready <= '0;
        ahb_tx_hsel <= '0;
        ahb_tx_haddr <= '0;
        ahb_tx_htrans <= '0;
        ahb_tx_hsize <= '0;
        ahb_tx_hwrite <= '0;
        ahb_tx_hwdata <= '0;
        ahb_tx_hready <= '0;
        ahb_fifo_hsel <= '0;
        ahb_fifo_haddr <= '0;
        ahb_fifo_htrans <= '0;
        ahb_fifo_hsize <= '0;
        ahb_fifo_hwrite <= '0;
        ahb_fifo_hwdata <= '0;
        ahb_fifo_hready <= '0;
        ahb_mng_hready <= '0;
        ahb_mng_hrdata <= '0;
        ahb_mng_hresp <= '0;
        apb_pprot <= '0;
        scan_mode <= '0;
        scan_asyncrst_ctrl <= '0;
        scan_clk <= '0;
        scan_shift <= '0;
        scan_in <= '0;
        pad_clk_rx <= '0;
        pad_rx <= '0;
        idelay_ref_clk <= '0;
        ahb_ptp_hsel <= '0;
        ahb_ptp_haddr <= '0;
        ahb_ptp_htrans <= '0;
        ahb_ptp_hsize <= '0;
        ahb_ptp_hwrite <= '0;
        ahb_ptp_hwdata <= '0;
        ahb_ptp_hready <= '0;
        phc_nanoseconds <= '0;
        phc_seconds <= '0;
        phc_pps <= '0;
        phc_hw_cap_seconds <= '0;
        phc_hw_cap_nanoseconds <= '0;
        phc_hw_cap_sub_nanoseconds <= '0;
        phc_locked_i <= '0;
        tc_axis_tx_tvalid <= '0;
        tc_axis_tx_tdata <= '0;
        tc_axis_rx_tready <= '0;
        tc_qos_priority <= '0;
        tl_bcast_ack_i <= '0;
        role_strap_i <= '0;
        apb_debug_unlock_i <= '0;
        mask_hs_bypass_i <= '0;
        nego_priority_i <= '0;
        puf_seed <= '0;
        puf_ready <= '0;
        i2c_scl_i <= '0;
        i2c_sda_i <= '0;
        s_i2c_axi_awvalid <= '0;
        s_i2c_axi_awid <= '0;
        s_i2c_axi_awaddr <= '0;
        s_i2c_axi_awlen <= '0;
        s_i2c_axi_awsize <= '0;
        s_i2c_axi_awburst <= '0;
        s_i2c_axi_awlock <= '0;
        s_i2c_axi_awcache <= '0;
        s_i2c_axi_awprot <= '0;
        s_i2c_axi_wvalid <= '0;
        s_i2c_axi_wdata <= '0;
        s_i2c_axi_wstrb <= '0;
        s_i2c_axi_wlast <= '0;
        s_i2c_axi_bready <= '0;
        s_i2c_axi_arvalid <= '0;
        s_i2c_axi_arid <= '0;
        s_i2c_axi_araddr <= '0;
        s_i2c_axi_arlen <= '0;
        s_i2c_axi_arsize <= '0;
        s_i2c_axi_arburst <= '0;
        s_i2c_axi_arlock <= '0;
        s_i2c_axi_arcache <= '0;
        s_i2c_axi_arprot <= '0;
        s_i2c_axi_rready <= '0;
    end

    // Quiet, deterministic APB idle state before cocotb takes over.
    initial begin
        hclk                 <= 1'b0;
        user_ref_clk         <= 1'b0;
        hresetn              <= 1'b0;
        poresetn             <= 1'b0;
        link_clk_div_ratio_i <= 3'd0;
        apb_paddr            <= 15'd0;
        apb_penable          <= 1'b0;
        apb_pwrite           <= 1'b0;
        apb_pstrb            <= 4'hF;
        apb_pwdata           <= 32'd0;
        apb_psel             <= 1'b0;
    end

`ifndef TB_INERT_NO_DUMP
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_inert);
    end
`endif

endmodule
