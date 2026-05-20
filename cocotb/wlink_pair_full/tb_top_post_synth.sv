// =============================================================================
// tb_top_post_synth.sv — Post-synthesis netlist pair simulation.
//
// Agent #4 — Angle 2.
//
// Instantiates two copies of the post-synth Vivado IP wrapper
// `tidelink_design_tidelink_0_0` instead of the RTL `tidelink_top`. This
// catches sim/HW divergences that arise from Vivado synth optimisations
// (resource sharing, retiming, BRAM/SRL init-value handling, latch
// inference, etc.) that are invisible to RTL-only sim.
//
// The post-synth netlist already includes all the BD-side parameter
// overrides (AUTOCAL_ENABLE=1, etc.) so we don't need to set them at the
// tb level. Cocotb drives the same APB bringup sequence as
// test_hw_full_mirror_via_apb.py but against the synthesised chiplet.
//
// Required deps in flist:
//   - post_synth/tidelink_design_tidelink_0_0_funcsim.v  (post-synth netlist)
//   - Xilinx UNISIM library (for FDR/LUT/BUF primitives)
//   - glbl module (in the netlist) — driven by VCS via `-glbl` switch
// =============================================================================
`timescale 1ns/1ps

module tb_top;

    localparam int NUM_PHY_LANES = 8;

    // ----- Clocks & resets ---------------------------------------------------
    logic clk = 1'b0;
    logic poresetn = 1'b0;
    logic hresetn  = 1'b0;
    wire  master_clk = clk;   // cocotb compat
    wire  slave_clk  = clk;
    wire  apb_clk    = clk;

    // Straps + xlconst signals — post-synth IP wrapper takes these as inputs.
    logic m_role_strap = 1'b0;   // master
    logic s_role_strap = 1'b1;   // slave
    logic m_apb_debug_unlock = 1'b0;
    logic s_apb_debug_unlock = 1'b0;
    logic m_mask_hs_bypass = 1'b1;
    logic s_mask_hs_bypass = 1'b1;

    // Per-side APB (post-synth IP wrapper uses paddr[31:0])
    logic        m_apb_psel    = 1'b0;
    logic        m_apb_penable = 1'b0;
    logic        m_apb_pwrite  = 1'b0;
    logic [31:0] m_apb_paddr   = '0;
    logic [31:0] m_apb_pwdata  = '0;
    wire  [31:0] m_apb_prdata;
    wire         m_apb_pready;
    wire         m_apb_pslverr;

    logic        s_apb_psel    = 1'b0;
    logic        s_apb_penable = 1'b0;
    logic        s_apb_pwrite  = 1'b0;
    logic [31:0] s_apb_paddr   = '0;
    logic [31:0] s_apb_pwdata  = '0;
    wire  [31:0] s_apb_prdata;
    wire         s_apb_pready;
    wire         s_apb_pslverr;

    // I2C wired-AND
    wire m_i2c_scl_o, m_i2c_scl_t, m_i2c_sda_o, m_i2c_sda_t;
    wire s_i2c_scl_o, s_i2c_scl_t, s_i2c_sda_o, s_i2c_sda_t;
    wire i2c_scl = (m_i2c_scl_t ? 1'b1 : m_i2c_scl_o) &
                   (s_i2c_scl_t ? 1'b1 : s_i2c_scl_o);
    wire i2c_sda = (m_i2c_sda_t ? 1'b1 : m_i2c_sda_o) &
                   (s_i2c_sda_t ? 1'b1 : s_i2c_sda_o);

    // PHY pads
    wire        m_pad_clk_tx, s_pad_clk_tx;
    wire [NUM_PHY_LANES-1:0] m_pad_tx, s_pad_tx;

    // Observable status outputs
    wire m_role_is_master, s_role_is_master;
    wire m_role_locked,    s_role_locked;
    wire m_link_active,    s_link_active;

    // AHB Manager output bundles (HREADY into manager from "slave")
    wire [31:0] m_mng_haddr,  s_mng_haddr;
    wire [2:0]  m_mng_hburst, s_mng_hburst;
    wire [6:0]  m_mng_hprot,  s_mng_hprot;
    wire [2:0]  m_mng_hsize,  s_mng_hsize;
    wire [1:0]  m_mng_htrans, s_mng_htrans;
    wire [31:0] m_mng_hwdata, s_mng_hwdata;
    wire        m_mng_hwrite, s_mng_hwrite;

    // ----- Chiplet A (master) — POST-SYNTH netlist ---------------------------
    tidelink_design_tidelink_0_0 u_master (
        .hclk              (clk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),
        .phc_clk           (clk),
        .phc_resetn        (hresetn),
        .user_ref_clk      (clk),

        // AHB Sub (tied off)
        .ahb_sub_haddr     (32'h0),
        .ahb_sub_hburst    (3'h0),
        .ahb_sub_hprot     (4'h0),
        .ahb_sub_hsize     (3'h0),
        .ahb_sub_htrans    (2'b00),
        .ahb_sub_hwdata    (32'h0),
        .ahb_sub_hwrite    (1'b0),
        .ahb_sub_hrdata    (),
        .ahb_sub_hresp     (),
        .ahb_sub_hready    (),

        // AHB TX (tied off)
        .ahb_tx_haddr      (14'h0),
        .ahb_tx_hsize      (3'h0),
        .ahb_tx_htrans     (2'b00),
        .ahb_tx_hwdata     (32'h0),
        .ahb_tx_hwrite     (1'b0),
        .ahb_tx_hrdata     (),
        .ahb_tx_hresp      (),
        .ahb_tx_hready     (),

        // AHB FIFO (tied off)
        .ahb_fifo_haddr    (14'h0),
        .ahb_fifo_hsize    (3'h0),
        .ahb_fifo_htrans   (2'b00),
        .ahb_fifo_hwdata   (32'h0),
        .ahb_fifo_hwrite   (1'b0),
        .ahb_fifo_hrdata   (),
        .ahb_fifo_hresp    (),
        .ahb_fifo_hready   (),

        // AHB PTP (tied off)
        .ahb_ptp_haddr     (4'h0),
        .ahb_ptp_hsize     (3'h0),
        .ahb_ptp_htrans    (2'b00),
        .ahb_ptp_hwdata    (32'h0),
        .ahb_ptp_hwrite    (1'b0),
        .ahb_ptp_hrdata    (),
        .ahb_ptp_hresp     (),
        .ahb_ptp_hready    (),

        // AHB Manager (chiplet drives; remote-side perfect slave)
        .ahb_mng_haddr     (m_mng_haddr),
        .ahb_mng_hburst    (m_mng_hburst),
        .ahb_mng_hprot     (m_mng_hprot),
        .ahb_mng_hsize     (m_mng_hsize),
        .ahb_mng_htrans    (m_mng_htrans),
        .ahb_mng_hwdata    (m_mng_hwdata),
        .ahb_mng_hwrite    (m_mng_hwrite),
        .ahb_mng_hready    (1'b1),
        .ahb_mng_hrdata    (32'h0),
        .ahb_mng_hresp     (1'b0),

        // APB external config port
        .apb_psel          (m_apb_psel),
        .apb_paddr         (m_apb_paddr),
        .apb_penable       (m_apb_penable),
        .apb_pwrite        (m_apb_pwrite),
        .apb_pstrb         (4'hF),
        .apb_pprot         (3'h0),
        .apb_pwdata        (m_apb_pwdata),
        .apb_prdata        (m_apb_prdata),
        .apb_pready        (m_apb_pready),
        .apb_pslverr       (m_apb_pslverr),

        // TideChart axis (tied off)
        .tc_axis_tx_tvalid (1'b0),
        .tc_axis_tx_tdata  (48'h0),
        .tc_axis_tx_tready (),
        .tc_axis_rx_tvalid (),
        .tc_axis_rx_tdata  (),
        .tc_axis_rx_tready (1'b1),
        .tc_qos_priority   (3'h0),

        // PHY pads
        .pad_clk_tx        (m_pad_clk_tx),
        .pad_tx            (m_pad_tx),
        .pad_clk_rx        (s_pad_clk_tx),
        .pad_rx            (s_pad_tx),

        // PHC tied off
        .phc_hw_capture    (),
        .phc_nanoseconds   (30'h0),
        .phc_seconds       (48'h0),
        .phc_pps           (1'b0),
        .phc_hw_cap_seconds(48'h0),
        .phc_hw_cap_nanoseconds(30'h0),
        .phc_hw_cap_sub_nanoseconds(32'h0),
        .phc_hw_set_time   (),
        .phc_hw_set_seconds(),
        .phc_hw_set_nanoseconds(),
        .phc_hw_adj_valid  (),
        .phc_hw_adj_ns_incr_frac(),
        .phc_locked_i      (1'b1),

        .servo_locked      (),

        // IRQs + status
        .released_credits_irq (),
        .doorbell_irq         (),
        .packet_committed_irq (),
        .ptp_irq              (),
        .perf_irq             (),
        .wlink_irq            (),
        .nego_error_irq       (),
        .i2c_nbsy_irq         (),
        .i2c_nrd_empty_irq    (),
        .link_active          (m_link_active),
        .d2d_reset_o          (),

        // Congestion sideband
        .tl_local_link_state_o (),
        .tl_link_state_change_o(),
        .tl_ewma_credit_o      (),
        .tl_bcast_ack_i        (1'b0),

        // Role
        .role_strap_i       (m_role_strap),
        .role_is_master_o   (m_role_is_master),
        .role_locked_o      (m_role_locked),
        .apb_debug_unlock_i (m_apb_debug_unlock),
        .mask_hs_bypass_i   (m_mask_hs_bypass),

        // Autoneg
        .nego_priority_i    (16'h0),
        .puf_seed           (16'h0),
        .puf_ready          (1'b0),

        // I2C — open-drain bus
        .i2c_scl_i          (i2c_scl),
        .i2c_scl_o          (m_i2c_scl_o),
        .i2c_scl_t          (m_i2c_scl_t),
        .i2c_sda_i          (i2c_sda),
        .i2c_sda_o          (m_i2c_sda_o),
        .i2c_sda_t          (m_i2c_sda_t),

        // I2C AXI (tied off)
        .s_i2c_axi_awvalid(1'b0), .s_i2c_axi_awid(2'h0), .s_i2c_axi_awaddr(4'h0),
        .s_i2c_axi_awlen(8'h0), .s_i2c_axi_awsize(3'h0), .s_i2c_axi_awburst(2'h0),
        .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache(4'h0), .s_i2c_axi_awprot(3'h0),
        .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata(32'h0), .s_i2c_axi_wstrb(4'h0),
        .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(),
        .s_i2c_axi_bready(1'b0),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid(2'h0), .s_i2c_axi_araddr(4'h0),
        .s_i2c_axi_arlen(8'h0), .s_i2c_axi_arsize(3'h0), .s_i2c_axi_arburst(2'h0),
        .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache(4'h0), .s_i2c_axi_arprot(3'h0),
        .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(),
        .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b0),

        // Scan
        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out()
    );

    // ----- Chiplet B (slave) — POST-SYNTH netlist ----------------------------
    tidelink_design_tidelink_0_0 u_slave (
        .hclk              (clk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),
        .phc_clk           (clk),
        .phc_resetn        (hresetn),
        .user_ref_clk      (clk),

        .ahb_sub_haddr     (32'h0), .ahb_sub_hburst(3'h0), .ahb_sub_hprot(4'h0),
        .ahb_sub_hsize     (3'h0), .ahb_sub_htrans(2'b00),
        .ahb_sub_hwdata    (32'h0), .ahb_sub_hwrite(1'b0),
        .ahb_sub_hrdata    (), .ahb_sub_hresp(), .ahb_sub_hready(),

        .ahb_tx_haddr      (14'h0), .ahb_tx_hsize(3'h0), .ahb_tx_htrans(2'b00),
        .ahb_tx_hwdata     (32'h0), .ahb_tx_hwrite(1'b0),
        .ahb_tx_hrdata     (), .ahb_tx_hresp(), .ahb_tx_hready(),

        .ahb_fifo_haddr    (14'h0), .ahb_fifo_hsize(3'h0), .ahb_fifo_htrans(2'b00),
        .ahb_fifo_hwdata   (32'h0), .ahb_fifo_hwrite(1'b0),
        .ahb_fifo_hrdata   (), .ahb_fifo_hresp(), .ahb_fifo_hready(),

        .ahb_ptp_haddr     (4'h0), .ahb_ptp_hsize(3'h0), .ahb_ptp_htrans(2'b00),
        .ahb_ptp_hwdata    (32'h0), .ahb_ptp_hwrite(1'b0),
        .ahb_ptp_hrdata    (), .ahb_ptp_hresp(), .ahb_ptp_hready(),

        .ahb_mng_haddr     (s_mng_haddr), .ahb_mng_hburst(s_mng_hburst),
        .ahb_mng_hprot     (s_mng_hprot), .ahb_mng_hsize(s_mng_hsize),
        .ahb_mng_htrans    (s_mng_htrans), .ahb_mng_hwdata(s_mng_hwdata),
        .ahb_mng_hwrite    (s_mng_hwrite),
        .ahb_mng_hready    (1'b1), .ahb_mng_hrdata(32'h0), .ahb_mng_hresp(1'b0),

        .apb_psel          (s_apb_psel),
        .apb_paddr         (s_apb_paddr),
        .apb_penable       (s_apb_penable),
        .apb_pwrite        (s_apb_pwrite),
        .apb_pstrb         (4'hF),
        .apb_pprot         (3'h0),
        .apb_pwdata        (s_apb_pwdata),
        .apb_prdata        (s_apb_prdata),
        .apb_pready        (s_apb_pready),
        .apb_pslverr       (s_apb_pslverr),

        .tc_axis_tx_tvalid (1'b0), .tc_axis_tx_tdata(48'h0), .tc_axis_tx_tready(),
        .tc_axis_rx_tvalid (), .tc_axis_rx_tdata(), .tc_axis_rx_tready(1'b1),
        .tc_qos_priority   (3'h0),

        .pad_clk_tx        (s_pad_clk_tx),
        .pad_tx            (s_pad_tx),
        .pad_clk_rx        (m_pad_clk_tx),
        .pad_rx            (m_pad_tx),

        .phc_hw_capture    (), .phc_nanoseconds(30'h0), .phc_seconds(48'h0),
        .phc_pps           (1'b0), .phc_hw_cap_seconds(48'h0),
        .phc_hw_cap_nanoseconds(30'h0), .phc_hw_cap_sub_nanoseconds(32'h0),
        .phc_hw_set_time   (), .phc_hw_set_seconds(), .phc_hw_set_nanoseconds(),
        .phc_hw_adj_valid  (), .phc_hw_adj_ns_incr_frac(), .phc_locked_i(1'b1),

        .servo_locked      (),

        .released_credits_irq(), .doorbell_irq(), .packet_committed_irq(),
        .ptp_irq(), .perf_irq(), .wlink_irq(), .nego_error_irq(),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq(),
        .link_active       (s_link_active), .d2d_reset_o(),

        .tl_local_link_state_o(), .tl_link_state_change_o(), .tl_ewma_credit_o(),
        .tl_bcast_ack_i    (1'b0),

        .role_strap_i      (s_role_strap),
        .role_is_master_o  (s_role_is_master),
        .role_locked_o     (s_role_locked),
        .apb_debug_unlock_i(s_apb_debug_unlock),
        .mask_hs_bypass_i  (s_mask_hs_bypass),

        .nego_priority_i   (16'h0), .puf_seed(16'h0), .puf_ready(1'b0),

        .i2c_scl_i         (i2c_scl), .i2c_scl_o(s_i2c_scl_o), .i2c_scl_t(s_i2c_scl_t),
        .i2c_sda_i         (i2c_sda), .i2c_sda_o(s_i2c_sda_o), .i2c_sda_t(s_i2c_sda_t),

        .s_i2c_axi_awvalid(1'b0), .s_i2c_axi_awid(2'h0), .s_i2c_axi_awaddr(4'h0),
        .s_i2c_axi_awlen(8'h0), .s_i2c_axi_awsize(3'h0), .s_i2c_axi_awburst(2'h0),
        .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache(4'h0), .s_i2c_axi_awprot(3'h0),
        .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata(32'h0), .s_i2c_axi_wstrb(4'h0),
        .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(),
        .s_i2c_axi_bready(1'b0),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid(2'h0), .s_i2c_axi_araddr(4'h0),
        .s_i2c_axi_arlen(8'h0), .s_i2c_axi_arsize(3'h0), .s_i2c_axi_arburst(2'h0),
        .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache(4'h0), .s_i2c_axi_arprot(3'h0),
        .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(),
        .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b0),

        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out()
    );

    // VCD dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
