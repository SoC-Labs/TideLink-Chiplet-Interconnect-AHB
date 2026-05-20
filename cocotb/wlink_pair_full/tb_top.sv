// =============================================================================
// tb_top.sv — Two-instance tidelink_top pair simulation (FULL BD-wrapped DUT)
//
// Agent #4 — Angle 1 reproducer attempt.
//
// Unlike cocotb/wlink_pair/tb_top.sv (which instantiates axi_chiplet_controller
// directly), this tb instantiates the *full* tidelink_top wrapper that the
// Vivado BD synthesises into. That brings in:
//
//   - tidelink_fifo with tidelink_apb_regs (APB → ctrl_reg conversion)
//   - The FC-vs-external APB 2:1 mux (priority on FC adapter)
//   - The unified APB decode tree (apb_sel_wlink / apb_sel_tidelink)
//   - The chiplet's apb_paddr[14:0] 15-bit width truncation
//
// All of these sit between the bench PYNQ AXI→APB bridge and the chiplet's
// ctrl_reg port on real HW. The cocotb wlink_pair tb_top bypasses them all by
// driving ctrl_reg_write/addr/wdata directly. If any of those layers introduces
// a sim/HW divergence (e.g. an FC RX packet arriving mid-bringup steals the
// APB and stalls SW writes), this tb will catch it where wlink_pair cannot.
//
// Cocotb drives the chiplet via the same APB transactions the PYNQ would
// issue. No ctrl_reg port poking.
// =============================================================================
`timescale 1ns/1ps

module tb_top;

    localparam int SYS_ADDR_W    = 32;
    localparam int SYS_DATA_W    = 32;
    localparam int RAM_ADDR_W    = 14;
    localparam int APB_ADDR_W    = 12;
    localparam int FC_DATA_W     = 48;
    localparam int NUM_PHY_LANES = 8;

    // Pair base addresses (TIDELINK_PAIR_BASE param). For autoneg-only tests
    // these can match the local address — FC sideband isn't exercised here.
    localparam [SYS_ADDR_W-1:0] M_PAIR_BASE = 32'h4403_2000;
    localparam [SYS_ADDR_W-1:0] S_PAIR_BASE = 32'h4403_2000;

    // ----- Clocks & resets ---------------------------------------------------
    logic clk = 1'b0;
    logic poresetn = 1'b0;
    logic hresetn  = 1'b0;
    // master/slave clock aliases for cocotb (single-clock tb, shared 50 MHz)
    wire  master_clk = clk;
    wire  slave_clk  = clk;
    wire  apb_clk    = clk;

    // Strap GPIO + debug_unlock + mask_hs_bypass (all xlconst on real BD)
    logic m_role_strap = 1'b0;   // master
    logic s_role_strap = 1'b1;   // slave
    logic m_apb_debug_unlock = 1'b0;
    logic s_apb_debug_unlock = 1'b0;
    logic m_mask_hs_bypass = 1'b1;
    logic s_mask_hs_bypass = 1'b1;

    // ----- Per-side APB (cocotb drives, mirrors BD's axi_apb output) --------
    logic        m_apb_psel   = 1'b0;
    logic        m_apb_penable= 1'b0;
    logic        m_apb_pwrite = 1'b0;
    logic [14:0] m_apb_paddr  = '0;
    logic [SYS_DATA_W-1:0] m_apb_pwdata = '0;
    wire  [SYS_DATA_W-1:0] m_apb_prdata;
    wire                   m_apb_pready;
    wire                   m_apb_pslverr;

    logic        s_apb_psel   = 1'b0;
    logic        s_apb_penable= 1'b0;
    logic        s_apb_pwrite = 1'b0;
    logic [14:0] s_apb_paddr  = '0;
    logic [SYS_DATA_W-1:0] s_apb_pwdata = '0;
    wire  [SYS_DATA_W-1:0] s_apb_prdata;
    wire                   s_apb_pready;
    wire                   s_apb_pslverr;

    // ----- I2C wired-AND open-drain bus (shared between master + slave) -----
    wire m_i2c_scl_o, m_i2c_scl_t, m_i2c_sda_o, m_i2c_sda_t;
    wire s_i2c_scl_o, s_i2c_scl_t, s_i2c_sda_o, s_i2c_sda_t;
    wire i2c_scl = (m_i2c_scl_t ? 1'b1 : m_i2c_scl_o) &
                   (s_i2c_scl_t ? 1'b1 : s_i2c_scl_o);
    wire i2c_sda = (m_i2c_sda_t ? 1'b1 : m_i2c_sda_o) &
                   (s_i2c_sda_t ? 1'b1 : s_i2c_sda_o);

    // ----- Cross-wired PHY pads (no skid for this tb) ------------------------
    wire        m_pad_clk_tx, s_pad_clk_tx;
    wire [NUM_PHY_LANES-1:0] m_pad_tx, s_pad_tx;

    // ----- Observable status (top-level outputs) -----------------------------
    wire m_role_is_master, s_role_is_master;
    wire m_role_locked,    s_role_locked;
    wire m_link_active,    s_link_active;
    wire m_d2d_reset_o,    s_d2d_reset_o;

    // IRQs (left dangling per side)
    wire m_released_credits_irq, m_doorbell_irq, m_packet_committed_irq;
    wire m_ptp_irq, m_perf_irq, m_wlink_irq, m_nego_error_irq;
    wire s_released_credits_irq, s_doorbell_irq, s_packet_committed_irq;
    wire s_ptp_irq, s_perf_irq, s_wlink_irq, s_nego_error_irq;

    // ----- AHB Manager outputs (tie back via slave-VIP stub) -----------------
    // The chiplet manager port drives address phases when the remote peer
    // sends payloads. We model a perfect-slave by returning hrdata=0 and
    // hready=1 always.
    wire [SYS_ADDR_W-1:0] m_mng_haddr,  s_mng_haddr;
    wire           [2:0]  m_mng_hburst, s_mng_hburst;
    wire           [6:0]  m_mng_hprot,  s_mng_hprot;
    wire           [2:0]  m_mng_hsize,  s_mng_hsize;
    wire           [1:0]  m_mng_htrans, s_mng_htrans;
    wire [SYS_DATA_W-1:0] m_mng_hwdata, s_mng_hwdata;
    wire                  m_mng_hwrite, s_mng_hwrite;
    wire                  m_mng_hready_o, s_mng_hready_o;

    // ----- Chiplet A (master) ------------------------------------------------
    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (SYS_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE(M_PAIR_BASE)
    ) u_master (
        .hclk              (clk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),
        .phc_clk           (clk),
        .phc_resetn        (hresetn),
        .user_ref_clk      (clk),

        // AHB Sub (tied off — never exercised here, mirrors BD's loopback)
        .ahb_sub_hsel      (1'b1),
        .ahb_sub_haddr     ('0),
        .ahb_sub_hburst    ('0),
        .ahb_sub_hprot     ('0),
        .ahb_sub_hsize     ('0),
        .ahb_sub_htrans    (2'b00),
        .ahb_sub_hwdata    ('0),
        .ahb_sub_hwrite    (1'b0),
        .ahb_sub_hready    (1'b1),
        .ahb_sub_hrdata    (),
        .ahb_sub_hresp     (),
        .ahb_sub_hreadyout (),

        // AHB TX aperture (tied off)
        .ahb_tx_hsel       (1'b1),
        .ahb_tx_haddr      ('0),
        .ahb_tx_htrans     (2'b00),
        .ahb_tx_hsize      ('0),
        .ahb_tx_hwrite     (1'b0),
        .ahb_tx_hwdata     ('0),
        .ahb_tx_hready     (1'b1),
        .ahb_tx_hrdata     (),
        .ahb_tx_hresp      (),
        .ahb_tx_hreadyout  (),

        // AHB FIFO read (tied off)
        .ahb_fifo_hsel     (1'b1),
        .ahb_fifo_haddr    ('0),
        .ahb_fifo_htrans   (2'b00),
        .ahb_fifo_hsize    ('0),
        .ahb_fifo_hwrite   (1'b0),
        .ahb_fifo_hwdata   ('0),
        .ahb_fifo_hready   (1'b1),
        .ahb_fifo_hrdata   (),
        .ahb_fifo_hresp    (),
        .ahb_fifo_hreadyout(),

        // AHB Manager (incoming from remote — model a perfect ready-slave)
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

        // Unified APB config port
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

        // Scan / DFT
        .scan_mode         (1'b0),
        .scan_asyncrst_ctrl(1'b0),
        .scan_clk          (1'b0),
        .scan_shift        (1'b0),
        .scan_in           (1'b0),
        .scan_out          (),

        // PHY pads (cross-wired)
        .pad_clk_tx        (m_pad_clk_tx),
        .pad_tx            (m_pad_tx),
        .pad_clk_rx        (s_pad_clk_tx),
        .pad_rx            (s_pad_tx),

        // PTP / PHC tied off
        .phc_locked_i             (1'b1),
        .phc_nanoseconds          (30'h0),
        .phc_seconds              (48'h0),
        .phc_pps                  (1'b0),
        .phc_hw_cap_seconds       (48'h0),
        .phc_hw_cap_nanoseconds   (30'h0),
        .phc_hw_cap_sub_nanoseconds(32'h0),
        .phc_hw_capture           (),
        .phc_hw_set_time          (),
        .phc_hw_set_seconds       (),
        .phc_hw_set_nanoseconds   (),
        .phc_hw_adj_valid         (),
        .phc_hw_adj_ns_incr_frac  (),

        // PTP AHB write port (tied off)
        .ahb_ptp_hsel             (1'b0),
        .ahb_ptp_haddr            (4'h0),
        .ahb_ptp_htrans           (2'b00),
        .ahb_ptp_hsize            ('0),
        .ahb_ptp_hwrite           (1'b0),
        .ahb_ptp_hwdata           ('0),
        .ahb_ptp_hready           (1'b1),
        .ahb_ptp_hrdata           (),
        .ahb_ptp_hresp            (),
        .ahb_ptp_hreadyout        (),

        // Servo status (dangling)
        .servo_locked             (),

        // TideChart axis (tied off)
        .tc_axis_tx_tvalid        (1'b0),
        .tc_axis_tx_tdata         ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready        (),
        .tc_axis_rx_tvalid        (),
        .tc_axis_rx_tdata         (),
        .tc_axis_rx_tready        (1'b1),
        .tc_qos_priority          (3'h0),

        // TideChart congestion sideband
        .tl_local_link_state_o    (),
        .tl_link_state_change_o   (),
        .tl_ewma_credit_o         (),
        .tl_bcast_ack_i           (1'b0),

        // Straps + autoneg config
        .apb_debug_unlock_i       (m_apb_debug_unlock),
        .mask_hs_bypass_i         (m_mask_hs_bypass),
        .nego_priority_i          (16'h0),
        .puf_seed                 (16'h0),
        .puf_ready                (1'b0),
        .nego_error_irq           (m_nego_error_irq),

        // IRQs + link status
        .released_credits_irq     (m_released_credits_irq),
        .doorbell_irq             (m_doorbell_irq),
        .packet_committed_irq     (m_packet_committed_irq),
        .ptp_irq                  (m_ptp_irq),
        .perf_irq                 (m_perf_irq),
        .wlink_irq                (m_wlink_irq),
        .link_active              (m_link_active),
        .d2d_reset_o              (m_d2d_reset_o),

        // Role selection
        .role_strap_i             (m_role_strap),
        .role_is_master_o         (m_role_is_master),
        .role_locked_o            (m_role_locked),

        // I2C sideband — shared open-drain bus
        .i2c_scl_i                (i2c_scl),
        .i2c_scl_o                (m_i2c_scl_o),
        .i2c_scl_t                (m_i2c_scl_t),
        .i2c_sda_i                (i2c_sda),
        .i2c_sda_o                (m_i2c_sda_o),
        .i2c_sda_t                (m_i2c_sda_t),

        // I2C AXI slave (tied off — not used)
        .s_i2c_axi_awvalid        (1'b0), .s_i2c_axi_awid('0), .s_i2c_axi_awaddr('0),
        .s_i2c_axi_awlen('0), .s_i2c_axi_awsize('0), .s_i2c_axi_awburst('0),
        .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache('0), .s_i2c_axi_awprot('0),
        .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata('0), .s_i2c_axi_wstrb('0),
        .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(),
        .s_i2c_axi_bready(1'b0),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid('0), .s_i2c_axi_araddr('0),
        .s_i2c_axi_arlen('0), .s_i2c_axi_arsize('0), .s_i2c_axi_arburst('0),
        .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache('0), .s_i2c_axi_arprot('0),
        .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(),
        .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b0),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq()
    );

    // ----- Chiplet B (slave) -------------------------------------------------
    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (SYS_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE(S_PAIR_BASE)
    ) u_slave (
        .hclk              (clk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),
        .phc_clk           (clk),
        .phc_resetn        (hresetn),
        .user_ref_clk      (clk),

        .ahb_sub_hsel      (1'b1),
        .ahb_sub_haddr     ('0), .ahb_sub_hburst('0), .ahb_sub_hprot('0),
        .ahb_sub_hsize     ('0), .ahb_sub_htrans(2'b00),
        .ahb_sub_hwdata    ('0), .ahb_sub_hwrite(1'b0), .ahb_sub_hready(1'b1),
        .ahb_sub_hrdata    (), .ahb_sub_hresp(), .ahb_sub_hreadyout(),

        .ahb_tx_hsel       (1'b1),
        .ahb_tx_haddr      ('0), .ahb_tx_htrans(2'b00), .ahb_tx_hsize('0),
        .ahb_tx_hwrite     (1'b0), .ahb_tx_hwdata('0), .ahb_tx_hready(1'b1),
        .ahb_tx_hrdata     (), .ahb_tx_hresp(), .ahb_tx_hreadyout(),

        .ahb_fifo_hsel     (1'b1),
        .ahb_fifo_haddr    ('0), .ahb_fifo_htrans(2'b00), .ahb_fifo_hsize('0),
        .ahb_fifo_hwrite   (1'b0), .ahb_fifo_hwdata('0), .ahb_fifo_hready(1'b1),
        .ahb_fifo_hrdata   (), .ahb_fifo_hresp(), .ahb_fifo_hreadyout(),

        .ahb_mng_haddr     (s_mng_haddr),
        .ahb_mng_hburst    (s_mng_hburst),
        .ahb_mng_hprot     (s_mng_hprot),
        .ahb_mng_hsize     (s_mng_hsize),
        .ahb_mng_htrans    (s_mng_htrans),
        .ahb_mng_hwdata    (s_mng_hwdata),
        .ahb_mng_hwrite    (s_mng_hwrite),
        .ahb_mng_hready    (1'b1),
        .ahb_mng_hrdata    (32'h0),
        .ahb_mng_hresp     (1'b0),

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

        .scan_mode         (1'b0), .scan_asyncrst_ctrl(1'b0),
        .scan_clk          (1'b0), .scan_shift(1'b0), .scan_in(1'b0), .scan_out(),

        .pad_clk_tx        (s_pad_clk_tx), .pad_tx(s_pad_tx),
        .pad_clk_rx        (m_pad_clk_tx), .pad_rx(m_pad_tx),

        .phc_locked_i             (1'b1),
        .phc_nanoseconds          (30'h0), .phc_seconds(48'h0), .phc_pps(1'b0),
        .phc_hw_cap_seconds       (48'h0),
        .phc_hw_cap_nanoseconds   (30'h0),
        .phc_hw_cap_sub_nanoseconds(32'h0),
        .phc_hw_capture           (),
        .phc_hw_set_time          (),
        .phc_hw_set_seconds       (),
        .phc_hw_set_nanoseconds   (),
        .phc_hw_adj_valid         (),
        .phc_hw_adj_ns_incr_frac  (),

        .ahb_ptp_hsel             (1'b0),
        .ahb_ptp_haddr            (4'h0), .ahb_ptp_htrans(2'b00),
        .ahb_ptp_hsize('0), .ahb_ptp_hwrite(1'b0),
        .ahb_ptp_hwdata           ('0), .ahb_ptp_hready(1'b1),
        .ahb_ptp_hrdata(), .ahb_ptp_hresp(), .ahb_ptp_hreadyout(),

        .servo_locked             (),

        .tc_axis_tx_tvalid        (1'b0),
        .tc_axis_tx_tdata         ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready        (),
        .tc_axis_rx_tvalid        (),
        .tc_axis_rx_tdata         (),
        .tc_axis_rx_tready        (1'b1),
        .tc_qos_priority          (3'h0),

        .tl_local_link_state_o    (),
        .tl_link_state_change_o   (),
        .tl_ewma_credit_o         (),
        .tl_bcast_ack_i           (1'b0),

        .apb_debug_unlock_i       (s_apb_debug_unlock),
        .mask_hs_bypass_i         (s_mask_hs_bypass),
        .nego_priority_i          (16'h0),
        .puf_seed                 (16'h0),
        .puf_ready                (1'b0),
        .nego_error_irq           (s_nego_error_irq),

        .released_credits_irq     (s_released_credits_irq),
        .doorbell_irq             (s_doorbell_irq),
        .packet_committed_irq     (s_packet_committed_irq),
        .ptp_irq                  (s_ptp_irq),
        .perf_irq                 (s_perf_irq),
        .wlink_irq                (s_wlink_irq),
        .link_active              (s_link_active),
        .d2d_reset_o              (s_d2d_reset_o),

        .role_strap_i             (s_role_strap),
        .role_is_master_o         (s_role_is_master),
        .role_locked_o            (s_role_locked),

        .i2c_scl_i                (i2c_scl),
        .i2c_scl_o                (s_i2c_scl_o),
        .i2c_scl_t                (s_i2c_scl_t),
        .i2c_sda_i                (i2c_sda),
        .i2c_sda_o                (s_i2c_sda_o),
        .i2c_sda_t                (s_i2c_sda_t),

        .s_i2c_axi_awvalid        (1'b0), .s_i2c_axi_awid('0), .s_i2c_axi_awaddr('0),
        .s_i2c_axi_awlen('0), .s_i2c_axi_awsize('0), .s_i2c_axi_awburst('0),
        .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache('0), .s_i2c_axi_awprot('0),
        .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata('0), .s_i2c_axi_wstrb('0),
        .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(),
        .s_i2c_axi_bready(1'b0),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid('0), .s_i2c_axi_araddr('0),
        .s_i2c_axi_arlen('0), .s_i2c_axi_arsize('0), .s_i2c_axi_arburst('0),
        .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache('0), .s_i2c_axi_arprot('0),
        .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(),
        .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b0),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq()
    );

    // VCD dump for debugging
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
