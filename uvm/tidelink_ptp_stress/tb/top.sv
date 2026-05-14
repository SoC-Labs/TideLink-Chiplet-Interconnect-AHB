///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink PTP stress characterisation.
//
// Two-chiplet (A <-> B) topology with full tidelink_top instances back-to-back
// via PHY pad crossover, plus a dedicated phc_top per side wired into the
// PTP hardware-capture / hardware-set servo interface.
//
//   Chiplet A (master)            Chiplet B (slave)
//   +--------------+  PHY pads   +--------------+
//   | tidelink_top |<----------->| tidelink_top |
//   | + PHC_A      |             | + PHC_B      |
//   +--------------+             +--------------+
//
// Per-side SVT AHB VIP system envs (active masters, passive slaves):
//   ptp  — drives the PTP TX AHB write port (msg_type at addr[3:0])
//   phc  — independent PHC register access (HW_CAP read-back; loopback)
//   sub  — AHB subordinate (background AXI traffic on remote-access port)
//   tx   — TideLink TX aperture (background FIFO data writes)
//   fifo — RX FIFO data read
//   cfg  — TideLink config-register access (also used by ptp_init for PHC/PTP)
//   mng  — AHB manager (incoming from remote — slave VIP responds)
//
// Per-side custom APB master agent:
//   apb  — Wlink + TideLink unified APB config port
//
// TODO(ptp_stress): the env declares per-side `a_ptp_ahb_sys_env` and
// `a_phc_ahb_sys_env` SVT AHB system envs, but the current tidelink_top
// surface routes PTP/PHC register access through the unified `cfg` AHB
// port — the dedicated PTP AHB write port is exercised separately via the
// `ahb_ptp_*` slave port wired below. The phc AHB VIPs are wired as
// stand-alone loopbacks so the VIP elaborates and `make compile` passes;
// sequences that target them will see address-decoder-like default reads.
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

`include "tidelink_ptp_stress_if.sv"
`include "apb_master_if.sv"
`include "tidelink_ptp_stress_pkg.sv"

module test_top;

  // ---------------------------------------------------------------
  // Clock and reset
  // ---------------------------------------------------------------
  parameter CLK_PERIOD     = 10;  // 100 MHz system clock
  parameter REF_CLK_PERIOD = 20;  // 50 MHz Wlink PLL reference

  bit   clk;
  bit   ref_clk;
  logic rst_n;
  logic poresetn;

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  initial begin
    ref_clk = 1'b0;
    forever #(REF_CLK_PERIOD/2) ref_clk = ~ref_clk;
  end

  initial begin
    rst_n    = 1'b0;
    poresetn = 1'b0;
    repeat (10) @(posedge clk);
    poresetn = 1'b1;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------
  // Package imports
  // ---------------------------------------------------------------
  import uvm_pkg::*;
  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;
  import tidelink_ptp_stress_pkg::*;

  // ---------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------
  localparam SYS_ADDR_W = 32;
  localparam SYS_DATA_W = 32;
  localparam RAM_ADDR_W = 14;
  localparam RAM_DATA_W = 32;
  localparam APB_ADDR_W = 12;
  localparam FC_DATA_W  = 48;
  localparam NUM_PHY_LANES = 8;

  // Pair base addresses: A points to B's config space, B points to A's
  localparam [SYS_ADDR_W-1:0] A_PAIR_BASE = 32'h4000_0000;
  localparam [SYS_ADDR_W-1:0] B_PAIR_BASE = 32'h5000_0000;

  // ---------------------------------------------------------------
  // SVT AHB Interface instances — Chiplet A
  // ---------------------------------------------------------------
  `define DECLARE_SIDE_IFS(PREFIX) \
    svt_ahb_if ahb_``PREFIX``_ptp_if();  \
    assign ahb_``PREFIX``_ptp_if.hclk    = clk;  \
    assign ahb_``PREFIX``_ptp_if.hresetn = rst_n; \
    svt_ahb_if ahb_``PREFIX``_phc_if();  \
    assign ahb_``PREFIX``_phc_if.hclk    = clk;  \
    assign ahb_``PREFIX``_phc_if.hresetn = rst_n; \
    svt_ahb_if ahb_``PREFIX``_sub_if();  \
    assign ahb_``PREFIX``_sub_if.hclk    = clk;  \
    assign ahb_``PREFIX``_sub_if.hresetn = rst_n; \
    svt_ahb_if ahb_``PREFIX``_tx_if();   \
    assign ahb_``PREFIX``_tx_if.hclk    = clk;   \
    assign ahb_``PREFIX``_tx_if.hresetn = rst_n;  \
    svt_ahb_if ahb_``PREFIX``_fifo_if(); \
    assign ahb_``PREFIX``_fifo_if.hclk    = clk; \
    assign ahb_``PREFIX``_fifo_if.hresetn = rst_n;\
    svt_ahb_if ahb_``PREFIX``_cfg_if();  \
    assign ahb_``PREFIX``_cfg_if.hclk    = clk;  \
    assign ahb_``PREFIX``_cfg_if.hresetn = rst_n; \
    svt_ahb_if ahb_``PREFIX``_mng_if();  \
    assign ahb_``PREFIX``_mng_if.hclk    = clk;  \
    assign ahb_``PREFIX``_mng_if.hresetn = rst_n; \
    apb_master_if apb_``PREFIX``_if(.clk(clk), .rst_n(rst_n));

  `DECLARE_SIDE_IFS(a)
  `DECLARE_SIDE_IFS(b)

  // System-level interface
  tidelink_ptp_stress_if tb_if(.clk(clk), .rst_n(rst_n));
  assign tb_if.poresetn = poresetn;

  // ---------------------------------------------------------------
  // PHY pad crossover: A TX <-> B RX, B TX <-> A RX (8-lane GPIO)
  // ---------------------------------------------------------------
  wire                       a_pad_clk_tx, b_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   a_pad_tx,     b_pad_tx;

  wire                       a_pad_clk_rx = b_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   a_pad_rx     = b_pad_tx;
  wire                       b_pad_clk_rx = a_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   b_pad_rx     = a_pad_tx;

  // ---------------------------------------------------------------
  // DUT output wires — per side
  // ---------------------------------------------------------------
  `define DECLARE_SIDE_WIRES(PREFIX) \
    wire        PREFIX``_dut_sub_hreadyout, PREFIX``_dut_sub_hresp; \
    wire [31:0] PREFIX``_dut_sub_hrdata; \
    wire        PREFIX``_dut_tx_hreadyout, PREFIX``_dut_tx_hresp; \
    wire [31:0] PREFIX``_dut_tx_hrdata; \
    wire        PREFIX``_dut_fifo_hreadyout, PREFIX``_dut_fifo_hresp; \
    wire [31:0] PREFIX``_dut_fifo_hrdata; \
    wire        PREFIX``_dut_ptp_hreadyout, PREFIX``_dut_ptp_hresp; \
    wire [31:0] PREFIX``_dut_ptp_hrdata; \
    wire [31:0] PREFIX``_dut_mng_haddr; \
    wire  [2:0] PREFIX``_dut_mng_hburst; \
    wire  [6:0] PREFIX``_dut_mng_hprot; \
    wire  [2:0] PREFIX``_dut_mng_hsize; \
    wire  [1:0] PREFIX``_dut_mng_htrans; \
    wire [31:0] PREFIX``_dut_mng_hwdata; \
    wire        PREFIX``_dut_mng_hwrite; \
    wire        PREFIX``_dut_mng_hready; \
    wire [31:0] PREFIX``_mng_hrdata; \
    wire        PREFIX``_mng_hresp; \
    wire        PREFIX``_released_credits_irq, PREFIX``_doorbell_irq; \
    wire        PREFIX``_packet_committed_irq, PREFIX``_wlink_irq, PREFIX``_ptp_irq; \
    wire        PREFIX``_d2d_reset_o, PREFIX``_servo_locked, PREFIX``_link_active; \
    wire        PREFIX``_dut_hw_capture; \
    wire        PREFIX``_hw_set_time, PREFIX``_hw_adj_valid; \
    wire [47:0] PREFIX``_hw_set_seconds; \
    wire [29:0] PREFIX``_hw_set_nanoseconds; \
    wire [31:0] PREFIX``_hw_adj_ns_incr_frac;

  `DECLARE_SIDE_WIRES(a)
  `DECLARE_SIDE_WIRES(b)

  // ---------------------------------------------------------------
  // PHC instance per side — provides time domain to its tidelink_top.
  // PHC's free-running nanoseconds/seconds counters feed phc_nanoseconds /
  // phc_seconds back to the DUT; the DUT's hw_capture pulse triggers PHC
  // hw_cap_*; the DUT's hw_set_* outputs adjust the PHC's count.
  // ---------------------------------------------------------------
  wire        a_phc_pps, b_phc_pps;
  wire [47:0] a_phc_hw_cap_seconds,     b_phc_hw_cap_seconds;
  wire [29:0] a_phc_hw_cap_nanoseconds, b_phc_hw_cap_nanoseconds;
  wire [31:0] a_phc_hw_cap_sub_nanoseconds, b_phc_hw_cap_sub_nanoseconds;
  wire [29:0] a_phc_nanoseconds, b_phc_nanoseconds;
  wire [47:0] a_phc_seconds,     b_phc_seconds;

  // PHC_A
  phc u_phc_a (
    .clk     (clk),
    .resetn  (rst_n),
    .psel    (1'b0), .penable (1'b0), .pwrite  (1'b0),
    .paddr   ({APB_ADDR_W{1'b0}}), .pwdata  (32'h0),
    .prdata  (), .pready  (), .pslverr (),
    .pps_irq (), .alarm_irq (),
    .hw_capture_0_i             (a_dut_hw_capture),
    .hw_cap_seconds_0_o         (a_phc_hw_cap_seconds),
    .hw_cap_nanoseconds_0_o     (a_phc_hw_cap_nanoseconds),
    .hw_cap_sub_nanoseconds_0_o (a_phc_hw_cap_sub_nanoseconds),
    .hw_set_time_0_i            (a_hw_set_time),
    .hw_set_seconds_0_i         (a_hw_set_seconds),
    .hw_set_nanoseconds_0_i     (a_hw_set_nanoseconds),
    .hw_adj_valid_0_i           (a_hw_adj_valid),
    .hw_adj_ns_incr_frac_0_i    (a_hw_adj_ns_incr_frac),
    .hw_capture_1_i             (1'b0),
    .hw_cap_seconds_1_o         (),
    .hw_cap_nanoseconds_1_o     (),
    .hw_cap_sub_nanoseconds_1_o (),
    .hw_set_time_1_i            (1'b0),
    .hw_set_seconds_1_i         (48'h0),
    .hw_set_nanoseconds_1_i     (30'h0),
    .hw_adj_valid_1_i           (1'b0),
    .hw_adj_ns_incr_frac_1_i    (32'h0),
    .servo_locked_i             (a_servo_locked),
    .servo_phase_step_active_i  (1'b0),
    .eth_rx_capture             (1'b0),
    .eth_tx_capture             (1'b0),
    .pps_out                    (a_phc_pps)
  );

  // PHC_B
  phc u_phc_b (
    .clk     (clk),
    .resetn  (rst_n),
    .psel    (1'b0), .penable (1'b0), .pwrite  (1'b0),
    .paddr   ({APB_ADDR_W{1'b0}}), .pwdata  (32'h0),
    .prdata  (), .pready  (), .pslverr (),
    .pps_irq (), .alarm_irq (),
    .hw_capture_0_i             (b_dut_hw_capture),
    .hw_cap_seconds_0_o         (b_phc_hw_cap_seconds),
    .hw_cap_nanoseconds_0_o     (b_phc_hw_cap_nanoseconds),
    .hw_cap_sub_nanoseconds_0_o (b_phc_hw_cap_sub_nanoseconds),
    .hw_set_time_0_i            (b_hw_set_time),
    .hw_set_seconds_0_i         (b_hw_set_seconds),
    .hw_set_nanoseconds_0_i     (b_hw_set_nanoseconds),
    .hw_adj_valid_0_i           (b_hw_adj_valid),
    .hw_adj_ns_incr_frac_0_i    (b_hw_adj_ns_incr_frac),
    .hw_capture_1_i             (1'b0),
    .hw_cap_seconds_1_o         (),
    .hw_cap_nanoseconds_1_o     (),
    .hw_cap_sub_nanoseconds_1_o (),
    .hw_set_time_1_i            (1'b0),
    .hw_set_seconds_1_i         (48'h0),
    .hw_set_nanoseconds_1_i     (30'h0),
    .hw_adj_valid_1_i           (1'b0),
    .hw_adj_ns_incr_frac_1_i    (32'h0),
    .servo_locked_i             (b_servo_locked),
    .servo_phase_step_active_i  (1'b0),
    .eth_rx_capture             (1'b0),
    .eth_tx_capture             (1'b0),
    .pps_out                    (b_phc_pps)
  );

  // PHC nanoseconds/seconds outputs are not exposed as ports — pull them
  // out via hierarchical reference (same approach as ptp_chain tb).
  assign a_phc_nanoseconds = u_phc_a.nanoseconds;
  assign a_phc_seconds     = u_phc_a.seconds;
  assign b_phc_nanoseconds = u_phc_b.nanoseconds;
  assign b_phc_seconds     = u_phc_b.seconds;

  // Force PHC enable + ns_incr=10 (10 ns per cycle @ 100 MHz) after reset
  // so the free-running counters actually count.
  initial begin
    @(posedge rst_n);
    force u_phc_a.ctrl_enable = 1'b1;
    force u_phc_a.ns_incr     = 8'd10;
    force u_phc_b.ctrl_enable = 1'b1;
    force u_phc_b.ns_incr     = 8'd10;
  end

  // ---------------------------------------------------------------
  // I2C open-drain bus wiring (tied per side, then OR'd onto bus)
  // ---------------------------------------------------------------
  wire a_i2c_scl_o, a_i2c_scl_t, a_i2c_sda_o, a_i2c_sda_t;
  wire b_i2c_scl_o, b_i2c_scl_t, b_i2c_sda_o, b_i2c_sda_t;
  wire i2c_scl = (a_i2c_scl_t ? 1'b1 : a_i2c_scl_o) & (b_i2c_scl_t ? 1'b1 : b_i2c_scl_o);
  wire i2c_sda = (a_i2c_sda_t ? 1'b1 : a_i2c_sda_o) & (b_i2c_sda_t ? 1'b1 : b_i2c_sda_o);

  // =================================================================
  // DUT A — tidelink_top (master)
  // =================================================================
  tidelink_top #(
    .SYS_ADDR_W        (SYS_ADDR_W),
    .SYS_DATA_W        (SYS_DATA_W),
    .RAM_ADDR_W        (RAM_ADDR_W),
    .RAM_DATA_W        (RAM_DATA_W),
    .APB_ADDR_W        (APB_ADDR_W),
    .FC_DATA_W         (FC_DATA_W),
    .NUM_PHY_LANES     (NUM_PHY_LANES),
    .TIDELINK_PAIR_BASE(A_PAIR_BASE)
  ) u_tidelink_top_a (
    .hclk              (clk),
    .hresetn           (rst_n),
    .poresetn          (poresetn),
    .phc_clk           (clk),
    .phc_resetn        (rst_n),

    // AHB Sub
    .ahb_sub_hsel      (1'b1),
    .ahb_sub_haddr     (ahb_a_sub_if.master_if[0].haddr),
    .ahb_sub_hburst    (ahb_a_sub_if.master_if[0].hburst),
    .ahb_sub_hprot     (ahb_a_sub_if.master_if[0].hprot[3:0]),
    .ahb_sub_hsize     (ahb_a_sub_if.master_if[0].hsize),
    .ahb_sub_htrans    (ahb_a_sub_if.master_if[0].htrans),
    .ahb_sub_hwdata    (ahb_a_sub_if.master_if[0].hwdata[31:0]),
    .ahb_sub_hwrite    (ahb_a_sub_if.master_if[0].hwrite),
    .ahb_sub_hready    (ahb_a_sub_if.master_if[0].hready),
    .ahb_sub_hrdata    (a_dut_sub_hrdata),
    .ahb_sub_hresp     (a_dut_sub_hresp),
    .ahb_sub_hreadyout (a_dut_sub_hreadyout),

    // AHB TX aperture
    .ahb_tx_hsel       (1'b1),
    .ahb_tx_haddr      (ahb_a_tx_if.master_if[0].haddr[RAM_ADDR_W-1:0]),
    .ahb_tx_htrans     (ahb_a_tx_if.master_if[0].htrans),
    .ahb_tx_hsize      (ahb_a_tx_if.master_if[0].hsize),
    .ahb_tx_hwrite     (ahb_a_tx_if.master_if[0].hwrite),
    .ahb_tx_hwdata     (ahb_a_tx_if.master_if[0].hwdata[31:0]),
    .ahb_tx_hready     (ahb_a_tx_if.master_if[0].hready),
    .ahb_tx_hrdata     (a_dut_tx_hrdata),
    .ahb_tx_hresp      (a_dut_tx_hresp),
    .ahb_tx_hreadyout  (a_dut_tx_hreadyout),

    // AHB FIFO read
    .ahb_fifo_hsel     (1'b1),
    .ahb_fifo_haddr    (ahb_a_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0]),
    .ahb_fifo_htrans   (ahb_a_fifo_if.master_if[0].htrans),
    .ahb_fifo_hsize    (ahb_a_fifo_if.master_if[0].hsize),
    .ahb_fifo_hwrite   (ahb_a_fifo_if.master_if[0].hwrite),
    .ahb_fifo_hwdata   (ahb_a_fifo_if.master_if[0].hwdata[31:0]),
    .ahb_fifo_hready   (ahb_a_fifo_if.master_if[0].hready),
    .ahb_fifo_hrdata   (a_dut_fifo_hrdata),
    .ahb_fifo_hresp    (a_dut_fifo_hresp),
    .ahb_fifo_hreadyout(a_dut_fifo_hreadyout),

    // AHB Manager (incoming from remote)
    .ahb_mng_haddr     (a_dut_mng_haddr),
    .ahb_mng_hburst    (a_dut_mng_hburst),
    .ahb_mng_hprot     (a_dut_mng_hprot),
    .ahb_mng_hsize     (a_dut_mng_hsize),
    .ahb_mng_htrans    (a_dut_mng_htrans),
    .ahb_mng_hwdata    (a_dut_mng_hwdata),
    .ahb_mng_hwrite    (a_dut_mng_hwrite),
    .ahb_mng_hready    (a_dut_mng_hready),
    .ahb_mng_hrdata    (a_mng_hrdata),
    .ahb_mng_hresp     (a_mng_hresp),

    // Unified APB config port
    .apb_psel          (apb_a_if.psel),
    .apb_paddr         (apb_a_if.paddr),
    .apb_penable       (apb_a_if.penable),
    .apb_pwrite        (apb_a_if.pwrite),
    .apb_pstrb         (4'hF),
    .apb_pprot         (3'h0),
    .apb_pwdata        (apb_a_if.pwdata),
    .apb_prdata        (apb_a_if.prdata),
    .apb_pready        (apb_a_if.pready),
    .apb_pslverr       (apb_a_if.pslverr),

    // PTP TX AHB write port — driven by ptp AHB VIP
    .ahb_ptp_hsel      (1'b1),
    .ahb_ptp_haddr     (ahb_a_ptp_if.master_if[0].haddr[3:0]),
    .ahb_ptp_htrans    (ahb_a_ptp_if.master_if[0].htrans),
    .ahb_ptp_hsize     (ahb_a_ptp_if.master_if[0].hsize),
    .ahb_ptp_hwrite    (ahb_a_ptp_if.master_if[0].hwrite),
    .ahb_ptp_hwdata    (ahb_a_ptp_if.master_if[0].hwdata[31:0]),
    .ahb_ptp_hready    (ahb_a_ptp_if.master_if[0].hready),
    .ahb_ptp_hrdata    (a_dut_ptp_hrdata),
    .ahb_ptp_hresp     (a_dut_ptp_hresp),
    .ahb_ptp_hreadyout (a_dut_ptp_hreadyout),

    // Scan / DFT
    .scan_mode         (1'b0),
    .scan_asyncrst_ctrl(1'b0),
    .scan_clk          (1'b0),
    .scan_shift        (1'b0),
    .scan_in           (1'b0),
    .scan_out          (),

    // Wlink PLL reference
    .user_ref_clk      (ref_clk),

    // PHY pads
    .pad_clk_tx        (a_pad_clk_tx),
    .pad_tx            (a_pad_tx),
    .pad_clk_rx        (a_pad_clk_rx),
    .pad_rx            (a_pad_rx),

    // PHC interface
    .phc_hw_capture            (a_dut_hw_capture),
    .phc_nanoseconds           (a_phc_nanoseconds),
    .phc_seconds               (a_phc_seconds),
    .phc_pps                   (a_phc_pps),
    .phc_hw_cap_seconds        (a_phc_hw_cap_seconds),
    .phc_hw_cap_nanoseconds    (a_phc_hw_cap_nanoseconds),
    .phc_hw_cap_sub_nanoseconds(a_phc_hw_cap_sub_nanoseconds),
    .phc_hw_set_time           (a_hw_set_time),
    .phc_hw_set_seconds        (a_hw_set_seconds),
    .phc_hw_set_nanoseconds    (a_hw_set_nanoseconds),
    .phc_hw_adj_valid          (a_hw_adj_valid),
    .phc_hw_adj_ns_incr_frac   (a_hw_adj_ns_incr_frac),

    // PHC lock gate (single-link — tied to 1)
    .phc_locked_i      (1'b1),
    .servo_locked      (a_servo_locked),

    // TideChart axis (tied off)
    .tc_axis_tx_tvalid (1'b0),
    .tc_axis_tx_tdata  ({FC_DATA_W{1'b0}}),
    .tc_axis_rx_tready (1'b1),
    .tc_qos_priority   (3'h0),
    .tl_bcast_ack_i    (1'b0),
    .apb_debug_unlock_i(1'b0),
    .mask_hs_bypass_i  (1'b0),

    // Negotiation / PUF (tied off)
    .nego_priority_i   (16'h0),
    .puf_seed          (16'h0),
    .puf_ready         (1'b0),

    // Interrupts
    .released_credits_irq (a_released_credits_irq),
    .doorbell_irq         (a_doorbell_irq),
    .packet_committed_irq (a_packet_committed_irq),
    .ptp_irq              (a_ptp_irq),
    .wlink_irq            (a_wlink_irq),
    .d2d_reset_o          (a_d2d_reset_o),

    // Role: A = master
    .role_strap_i      (1'b0),
    .role_is_master_o  (),
    .role_locked_o     (),

    // I2C sideband
    .i2c_scl_i         (i2c_scl),
    .i2c_scl_o         (a_i2c_scl_o),
    .i2c_scl_t         (a_i2c_scl_t),
    .i2c_sda_i         (i2c_sda),
    .i2c_sda_o         (a_i2c_sda_o),
    .i2c_sda_t         (a_i2c_sda_t),

    // I2C sideband AXI (tied off)
    .s_i2c_axi_awvalid (1'b0),
    .s_i2c_axi_awid    (2'b00),
    .s_i2c_axi_awaddr  (4'h0),
    .s_i2c_axi_awlen   (8'h00),
    .s_i2c_axi_awsize  (3'h0),
    .s_i2c_axi_awburst (2'b00),
    .s_i2c_axi_awlock  (1'b0),
    .s_i2c_axi_awcache (4'h0),
    .s_i2c_axi_awprot  (3'h0),
    .s_i2c_axi_awready (),
    .s_i2c_axi_wvalid  (1'b0),
    .s_i2c_axi_wdata   (32'h0),
    .s_i2c_axi_wstrb   (4'h0),
    .s_i2c_axi_wlast   (1'b0),
    .s_i2c_axi_wready  (),
    .s_i2c_axi_bvalid  (),
    .s_i2c_axi_bid     (),
    .s_i2c_axi_bresp   (),
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
    .s_i2c_axi_arready (),
    .s_i2c_axi_rvalid  (),
    .s_i2c_axi_rid     (),
    .s_i2c_axi_rdata   (),
    .s_i2c_axi_rresp   (),
    .s_i2c_axi_rlast   (),
    .s_i2c_axi_rready  (1'b1),

    // Link active observation
    .link_active       (a_link_active),

    // I2C interrupts
    .i2c_nbsy_irq      (),
    .i2c_nrd_empty_irq ()
  );

  // =================================================================
  // DUT B — tidelink_top (slave)
  // =================================================================
  tidelink_top #(
    .SYS_ADDR_W        (SYS_ADDR_W),
    .SYS_DATA_W        (SYS_DATA_W),
    .RAM_ADDR_W        (RAM_ADDR_W),
    .RAM_DATA_W        (RAM_DATA_W),
    .APB_ADDR_W        (APB_ADDR_W),
    .FC_DATA_W         (FC_DATA_W),
    .NUM_PHY_LANES     (NUM_PHY_LANES),
    .TIDELINK_PAIR_BASE(B_PAIR_BASE)
  ) u_tidelink_top_b (
    .hclk              (clk),
    .hresetn           (rst_n),
    .poresetn          (poresetn),
    .phc_clk           (clk),
    .phc_resetn        (rst_n),

    .ahb_sub_hsel      (1'b1),
    .ahb_sub_haddr     (ahb_b_sub_if.master_if[0].haddr),
    .ahb_sub_hburst    (ahb_b_sub_if.master_if[0].hburst),
    .ahb_sub_hprot     (ahb_b_sub_if.master_if[0].hprot[3:0]),
    .ahb_sub_hsize     (ahb_b_sub_if.master_if[0].hsize),
    .ahb_sub_htrans    (ahb_b_sub_if.master_if[0].htrans),
    .ahb_sub_hwdata    (ahb_b_sub_if.master_if[0].hwdata[31:0]),
    .ahb_sub_hwrite    (ahb_b_sub_if.master_if[0].hwrite),
    .ahb_sub_hready    (ahb_b_sub_if.master_if[0].hready),
    .ahb_sub_hrdata    (b_dut_sub_hrdata),
    .ahb_sub_hresp     (b_dut_sub_hresp),
    .ahb_sub_hreadyout (b_dut_sub_hreadyout),

    .ahb_tx_hsel       (1'b1),
    .ahb_tx_haddr      (ahb_b_tx_if.master_if[0].haddr[RAM_ADDR_W-1:0]),
    .ahb_tx_htrans     (ahb_b_tx_if.master_if[0].htrans),
    .ahb_tx_hsize      (ahb_b_tx_if.master_if[0].hsize),
    .ahb_tx_hwrite     (ahb_b_tx_if.master_if[0].hwrite),
    .ahb_tx_hwdata     (ahb_b_tx_if.master_if[0].hwdata[31:0]),
    .ahb_tx_hready     (ahb_b_tx_if.master_if[0].hready),
    .ahb_tx_hrdata     (b_dut_tx_hrdata),
    .ahb_tx_hresp      (b_dut_tx_hresp),
    .ahb_tx_hreadyout  (b_dut_tx_hreadyout),

    .ahb_fifo_hsel     (1'b1),
    .ahb_fifo_haddr    (ahb_b_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0]),
    .ahb_fifo_htrans   (ahb_b_fifo_if.master_if[0].htrans),
    .ahb_fifo_hsize    (ahb_b_fifo_if.master_if[0].hsize),
    .ahb_fifo_hwrite   (ahb_b_fifo_if.master_if[0].hwrite),
    .ahb_fifo_hwdata   (ahb_b_fifo_if.master_if[0].hwdata[31:0]),
    .ahb_fifo_hready   (ahb_b_fifo_if.master_if[0].hready),
    .ahb_fifo_hrdata   (b_dut_fifo_hrdata),
    .ahb_fifo_hresp    (b_dut_fifo_hresp),
    .ahb_fifo_hreadyout(b_dut_fifo_hreadyout),

    .ahb_mng_haddr     (b_dut_mng_haddr),
    .ahb_mng_hburst    (b_dut_mng_hburst),
    .ahb_mng_hprot     (b_dut_mng_hprot),
    .ahb_mng_hsize     (b_dut_mng_hsize),
    .ahb_mng_htrans    (b_dut_mng_htrans),
    .ahb_mng_hwdata    (b_dut_mng_hwdata),
    .ahb_mng_hwrite    (b_dut_mng_hwrite),
    .ahb_mng_hready    (b_dut_mng_hready),
    .ahb_mng_hrdata    (b_mng_hrdata),
    .ahb_mng_hresp     (b_mng_hresp),

    .apb_psel          (apb_b_if.psel),
    .apb_paddr         (apb_b_if.paddr),
    .apb_penable       (apb_b_if.penable),
    .apb_pwrite        (apb_b_if.pwrite),
    .apb_pstrb         (4'hF),
    .apb_pprot         (3'h0),
    .apb_pwdata        (apb_b_if.pwdata),
    .apb_prdata        (apb_b_if.prdata),
    .apb_pready        (apb_b_if.pready),
    .apb_pslverr       (apb_b_if.pslverr),

    .ahb_ptp_hsel      (1'b1),
    .ahb_ptp_haddr     (ahb_b_ptp_if.master_if[0].haddr[3:0]),
    .ahb_ptp_htrans    (ahb_b_ptp_if.master_if[0].htrans),
    .ahb_ptp_hsize     (ahb_b_ptp_if.master_if[0].hsize),
    .ahb_ptp_hwrite    (ahb_b_ptp_if.master_if[0].hwrite),
    .ahb_ptp_hwdata    (ahb_b_ptp_if.master_if[0].hwdata[31:0]),
    .ahb_ptp_hready    (ahb_b_ptp_if.master_if[0].hready),
    .ahb_ptp_hrdata    (b_dut_ptp_hrdata),
    .ahb_ptp_hresp     (b_dut_ptp_hresp),
    .ahb_ptp_hreadyout (b_dut_ptp_hreadyout),

    .scan_mode         (1'b0),
    .scan_asyncrst_ctrl(1'b0),
    .scan_clk          (1'b0),
    .scan_shift        (1'b0),
    .scan_in           (1'b0),
    .scan_out          (),

    .user_ref_clk      (ref_clk),

    .pad_clk_tx        (b_pad_clk_tx),
    .pad_tx            (b_pad_tx),
    .pad_clk_rx        (b_pad_clk_rx),
    .pad_rx            (b_pad_rx),

    .phc_hw_capture            (b_dut_hw_capture),
    .phc_nanoseconds           (b_phc_nanoseconds),
    .phc_seconds               (b_phc_seconds),
    .phc_pps                   (b_phc_pps),
    .phc_hw_cap_seconds        (b_phc_hw_cap_seconds),
    .phc_hw_cap_nanoseconds    (b_phc_hw_cap_nanoseconds),
    .phc_hw_cap_sub_nanoseconds(b_phc_hw_cap_sub_nanoseconds),
    .phc_hw_set_time           (b_hw_set_time),
    .phc_hw_set_seconds        (b_hw_set_seconds),
    .phc_hw_set_nanoseconds    (b_hw_set_nanoseconds),
    .phc_hw_adj_valid          (b_hw_adj_valid),
    .phc_hw_adj_ns_incr_frac   (b_hw_adj_ns_incr_frac),

    .phc_locked_i      (1'b1),
    .servo_locked      (b_servo_locked),

    .tc_axis_tx_tvalid (1'b0),
    .tc_axis_tx_tdata  ({FC_DATA_W{1'b0}}),
    .tc_axis_rx_tready (1'b1),
    .tc_qos_priority   (3'h0),
    .tl_bcast_ack_i    (1'b0),
    .apb_debug_unlock_i(1'b0),
    .mask_hs_bypass_i  (1'b0),

    .nego_priority_i   (16'h0),
    .puf_seed          (16'h0),
    .puf_ready         (1'b0),

    .released_credits_irq (b_released_credits_irq),
    .doorbell_irq         (b_doorbell_irq),
    .packet_committed_irq (b_packet_committed_irq),
    .ptp_irq              (b_ptp_irq),
    .wlink_irq            (b_wlink_irq),
    .d2d_reset_o          (b_d2d_reset_o),

    // Role: B = slave
    .role_strap_i      (1'b1),
    .role_is_master_o  (),
    .role_locked_o     (),

    .i2c_scl_i         (i2c_scl),
    .i2c_scl_o         (b_i2c_scl_o),
    .i2c_scl_t         (b_i2c_scl_t),
    .i2c_sda_i         (i2c_sda),
    .i2c_sda_o         (b_i2c_sda_o),
    .i2c_sda_t         (b_i2c_sda_t),

    .s_i2c_axi_awvalid (1'b0),
    .s_i2c_axi_awid    (2'b00),
    .s_i2c_axi_awaddr  (4'h0),
    .s_i2c_axi_awlen   (8'h00),
    .s_i2c_axi_awsize  (3'h0),
    .s_i2c_axi_awburst (2'b00),
    .s_i2c_axi_awlock  (1'b0),
    .s_i2c_axi_awcache (4'h0),
    .s_i2c_axi_awprot  (3'h0),
    .s_i2c_axi_awready (),
    .s_i2c_axi_wvalid  (1'b0),
    .s_i2c_axi_wdata   (32'h0),
    .s_i2c_axi_wstrb   (4'h0),
    .s_i2c_axi_wlast   (1'b0),
    .s_i2c_axi_wready  (),
    .s_i2c_axi_bvalid  (),
    .s_i2c_axi_bid     (),
    .s_i2c_axi_bresp   (),
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
    .s_i2c_axi_arready (),
    .s_i2c_axi_rvalid  (),
    .s_i2c_axi_rid     (),
    .s_i2c_axi_rdata   (),
    .s_i2c_axi_rresp   (),
    .s_i2c_axi_rlast   (),
    .s_i2c_axi_rready  (1'b1),

    .link_active       (b_link_active),

    .i2c_nbsy_irq      (),
    .i2c_nrd_empty_irq ()
  );

  // =================================================================
  // Wire IRQs to tb_if
  // =================================================================
  assign tb_if.a_ptp_irq              = a_ptp_irq;
  assign tb_if.b_ptp_irq              = b_ptp_irq;
  assign tb_if.a_released_credits_irq = a_released_credits_irq;
  assign tb_if.a_doorbell_irq         = a_doorbell_irq;
  assign tb_if.a_packet_committed_irq = a_packet_committed_irq;
  assign tb_if.a_wlink_irq            = a_wlink_irq;
  assign tb_if.b_released_credits_irq = b_released_credits_irq;
  assign tb_if.b_doorbell_irq         = b_doorbell_irq;
  assign tb_if.b_packet_committed_irq = b_packet_committed_irq;
  assign tb_if.b_wlink_irq            = b_wlink_irq;

  // =================================================================
  // VIP AHB interface wiring — helper macros
  // =================================================================
  `define WIRE_AHB_SUB(VIF, DUT_HREADYOUT, DUT_HRESP, DUT_HRDATA) \
    assign VIF.slave_if[0].haddr     = VIF.master_if[0].haddr;     \
    assign VIF.slave_if[0].htrans    = VIF.master_if[0].htrans;    \
    assign VIF.slave_if[0].hburst    = VIF.master_if[0].hburst;    \
    assign VIF.slave_if[0].hsize     = VIF.master_if[0].hsize;     \
    assign VIF.slave_if[0].hprot     = VIF.master_if[0].hprot;     \
    assign VIF.slave_if[0].hwrite    = VIF.master_if[0].hwrite;    \
    assign VIF.slave_if[0].hwdata    = VIF.master_if[0].hwdata;    \
    assign VIF.slave_if[0].hmaster   = 4'h0;                       \
    assign VIF.slave_if[0].hmastlock = 1'b0;                       \
    assign VIF.slave_if[0].hready_in = DUT_HREADYOUT;              \
    initial begin                                                   \
      force VIF.master_if[0].hready = DUT_HREADYOUT;               \
      force VIF.master_if[0].hresp  = {1'b0, DUT_HRESP};          \
      force VIF.master_if[0].hrdata = DUT_HRDATA;                  \
      force VIF.master_if[0].hgrant = 1'b1;                        \
      force VIF.slave_if[0].hsel    = 1'b1;                        \
      force VIF.slave_if[0].hready  = DUT_HREADYOUT;               \
      force VIF.slave_if[0].hrdata  = DUT_HRDATA;                  \
      force VIF.slave_if[0].hresp   = {1'b0, DUT_HRESP};          \
    end

  // Manager wiring: DUT drives request signals; slave VIP drives response.
  `define WIRE_AHB_MNG(VIF, DUT_HADDR, DUT_HBURST, DUT_HPROT, DUT_HSIZE, DUT_HTRANS, DUT_HWDATA, DUT_HWRITE, DUT_HREADY, MNG_HRDATA, MNG_HRESP) \
    assign VIF.slave_if[0].haddr     = DUT_HADDR;                  \
    assign VIF.slave_if[0].htrans    = DUT_HTRANS;                 \
    assign VIF.slave_if[0].hburst    = DUT_HBURST;                 \
    assign VIF.slave_if[0].hsize     = DUT_HSIZE;                  \
    assign VIF.slave_if[0].hprot     = DUT_HPROT;                  \
    assign VIF.slave_if[0].hwrite    = DUT_HWRITE;                 \
    assign VIF.slave_if[0].hwdata    = DUT_HWDATA;                 \
    assign VIF.slave_if[0].hmaster   = 4'h0;                       \
    assign VIF.slave_if[0].hmastlock = 1'b0;                       \
    assign VIF.slave_if[0].hsel      = DUT_HTRANS[1];              \
    assign VIF.slave_if[0].hready_in = VIF.slave_if[0].hready;     \
    assign DUT_HREADY = VIF.slave_if[0].hready;                    \
    assign MNG_HRDATA = VIF.slave_if[0].hrdata[31:0];              \
    assign MNG_HRESP  = VIF.slave_if[0].hresp[0];                  \
    initial begin                                                   \
      force VIF.master_if[0].haddr   = DUT_HADDR;                  \
      force VIF.master_if[0].htrans  = DUT_HTRANS;                 \
      force VIF.master_if[0].hburst  = DUT_HBURST;                 \
      force VIF.master_if[0].hsize   = DUT_HSIZE;                  \
      force VIF.master_if[0].hprot   = DUT_HPROT;                  \
      force VIF.master_if[0].hwrite  = DUT_HWRITE;                 \
      force VIF.master_if[0].hwdata  = DUT_HWDATA;                 \
      force VIF.master_if[0].hready  = VIF.slave_if[0].hready;     \
      force VIF.master_if[0].hresp   = VIF.slave_if[0].hresp;      \
      force VIF.master_if[0].hrdata  = VIF.slave_if[0].hrdata;     \
      force VIF.master_if[0].hgrant  = 1'b1;                       \
    end

  // ---------------------------------------------------------------
  // Loopback wiring for VIPs that don't drive a real DUT slave port.
  // The cfg/phc AHB envs are not wired to any DUT port — sequences
  // targeting them resolve via this self-responding loopback.
  // TODO(ptp_stress): wire cfg/phc to a real APB-bridged AHB port if/when
  // the design exposes one; for now this satisfies VIP elaboration.
  // ---------------------------------------------------------------
  `define WIRE_AHB_LOOPBACK(VIF) \
    assign VIF.slave_if[0].haddr     = VIF.master_if[0].haddr;     \
    assign VIF.slave_if[0].htrans    = VIF.master_if[0].htrans;    \
    assign VIF.slave_if[0].hburst    = VIF.master_if[0].hburst;    \
    assign VIF.slave_if[0].hsize     = VIF.master_if[0].hsize;     \
    assign VIF.slave_if[0].hprot     = VIF.master_if[0].hprot;     \
    assign VIF.slave_if[0].hwrite    = VIF.master_if[0].hwrite;    \
    assign VIF.slave_if[0].hwdata    = VIF.master_if[0].hwdata;    \
    assign VIF.slave_if[0].hmaster   = 4'h0;                       \
    assign VIF.slave_if[0].hmastlock = 1'b0;                       \
    assign VIF.slave_if[0].hready_in = 1'b1;                       \
    initial begin                                                   \
      force VIF.master_if[0].hready = 1'b1;                        \
      force VIF.master_if[0].hresp  = 2'b00;                       \
      force VIF.master_if[0].hrdata = 32'h0;                       \
      force VIF.master_if[0].hgrant = 1'b1;                        \
      force VIF.slave_if[0].hsel    = 1'b1;                        \
      force VIF.slave_if[0].hready  = 1'b1;                        \
      force VIF.slave_if[0].hrdata  = 32'h0;                       \
      force VIF.slave_if[0].hresp   = 2'b00;                       \
    end

  // --- Chiplet A subordinate interfaces wired to DUT A ports ---
  `WIRE_AHB_SUB(ahb_a_sub_if,  a_dut_sub_hreadyout,  a_dut_sub_hresp,  a_dut_sub_hrdata)
  `WIRE_AHB_SUB(ahb_a_tx_if,   a_dut_tx_hreadyout,   a_dut_tx_hresp,   a_dut_tx_hrdata)
  `WIRE_AHB_SUB(ahb_a_fifo_if, a_dut_fifo_hreadyout, a_dut_fifo_hresp, a_dut_fifo_hrdata)
  `WIRE_AHB_SUB(ahb_a_ptp_if,  a_dut_ptp_hreadyout,  a_dut_ptp_hresp,  a_dut_ptp_hrdata)

  // --- Chiplet A loopback VIPs (cfg, phc — not wired to DUT) ---
  `WIRE_AHB_LOOPBACK(ahb_a_cfg_if)
  `WIRE_AHB_LOOPBACK(ahb_a_phc_if)

  // --- Chiplet A manager interface ---
  `WIRE_AHB_MNG(ahb_a_mng_if,
    a_dut_mng_haddr, a_dut_mng_hburst, {25'h0, a_dut_mng_hprot},
    a_dut_mng_hsize, a_dut_mng_htrans, a_dut_mng_hwdata,
    a_dut_mng_hwrite, a_dut_mng_hready, a_mng_hrdata, a_mng_hresp)

  // --- Chiplet B subordinate interfaces wired to DUT B ports ---
  `WIRE_AHB_SUB(ahb_b_sub_if,  b_dut_sub_hreadyout,  b_dut_sub_hresp,  b_dut_sub_hrdata)
  `WIRE_AHB_SUB(ahb_b_tx_if,   b_dut_tx_hreadyout,   b_dut_tx_hresp,   b_dut_tx_hrdata)
  `WIRE_AHB_SUB(ahb_b_fifo_if, b_dut_fifo_hreadyout, b_dut_fifo_hresp, b_dut_fifo_hrdata)
  `WIRE_AHB_SUB(ahb_b_ptp_if,  b_dut_ptp_hreadyout,  b_dut_ptp_hresp,  b_dut_ptp_hrdata)

  // --- Chiplet B loopback VIPs (cfg, phc — not wired to DUT) ---
  `WIRE_AHB_LOOPBACK(ahb_b_cfg_if)
  `WIRE_AHB_LOOPBACK(ahb_b_phc_if)

  // --- Chiplet B manager interface ---
  `WIRE_AHB_MNG(ahb_b_mng_if,
    b_dut_mng_haddr, b_dut_mng_hburst, {25'h0, b_dut_mng_hprot},
    b_dut_mng_hsize, b_dut_mng_htrans, b_dut_mng_hwdata,
    b_dut_mng_hwrite, b_dut_mng_hready, b_mng_hrdata, b_mng_hresp)

  // ---------------------------------------------------------------
  // Waveform dumping
  // ---------------------------------------------------------------
`ifdef WAVES_FSDB
  initial begin
    $fsdbDumpfile("test_top");
    $fsdbDumpvars;
  end
`elsif WAVES_VCD
  initial begin
    $dumpfile("test_top.vcd");
    $dumpvars(0, test_top);
  end
`elsif WAVES
  initial begin
    $vcdpluson;
  end
`endif

  // ---------------------------------------------------------------
  // UVM configuration and test launch
  // ---------------------------------------------------------------
  initial begin
    // Chiplet A AHB VIPs
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_ptp_ahb_sys_env",  "vif", ahb_a_ptp_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_phc_ahb_sys_env",  "vif", ahb_a_phc_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_sub_ahb_sys_env",  "vif", ahb_a_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_tx_ahb_sys_env",   "vif", ahb_a_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_fifo_ahb_sys_env", "vif", ahb_a_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_cfg_ahb_sys_env",  "vif", ahb_a_cfg_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_mng_ahb_sys_env",  "vif", ahb_a_mng_if);

    // Chiplet B AHB VIPs
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_ptp_ahb_sys_env",  "vif", ahb_b_ptp_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_phc_ahb_sys_env",  "vif", ahb_b_phc_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_sub_ahb_sys_env",  "vif", ahb_b_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_tx_ahb_sys_env",   "vif", ahb_b_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_fifo_ahb_sys_env", "vif", ahb_b_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_cfg_ahb_sys_env",  "vif", ahb_b_cfg_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_mng_ahb_sys_env",  "vif", ahb_b_mng_if);

    // APB interfaces — driver and monitor need separate modport VIFs
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.a_apb_agt.driver", "vif", apb_a_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.a_apb_agt.monitor", "vif", apb_a_if);
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.b_apb_agt.driver", "vif", apb_b_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.b_apb_agt.monitor", "vif", apb_b_if);

    // Clock/reset/IRQ interface
    uvm_config_db#(virtual tidelink_ptp_stress_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    run_test();
  end

endmodule
