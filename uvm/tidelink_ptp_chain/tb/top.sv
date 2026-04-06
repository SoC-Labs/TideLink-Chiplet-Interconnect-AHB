///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink PTP chaining verification.
//
// Instantiates a 3-chiplet chain with 4 tidelink_top instances and 3 PHCs:
//
//   Chiplet A (GM)        Chiplet B (Sub→GM)       Chiplet C (Sub)
//   +--------------+      +--------------+         +--------------+
//   | tidelink_top | PHY  | tidelink_top | (link1) | tidelink_top |
//   | + PHC_A      |<---->| + PHC_B      |         | + PHC_C      |
//   |              |      | (shared)     |         |              |
//   |              |      | tidelink_top | PHY     |              |
//   |              |      |              |<------->|              |
//   +--------------+      +--------------+ (link2) +--------------+
//
// PHC_A: free-running Grandmaster reference
// PHC_B: disciplined by link1 servo, timestamps used by link2 GM
// PHC_C: disciplined by link2 servo
//
// B_link1 servo_locked → B_link2 phc_locked_i (lock gate)
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

`include "tidelink_ptp_chain_if.sv"
`include "apb_master_if.sv"
`include "tidelink_ptp_chain_pkg.sv"

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
  import tidelink_ptp_chain_pkg::*;

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

  // Pair base addresses
  localparam [SYS_ADDR_W-1:0] A_PAIR_BASE    = 32'h4000_0000;
  localparam [SYS_ADDR_W-1:0] B1_PAIR_BASE   = 32'h5000_0000;
  localparam [SYS_ADDR_W-1:0] B2_PAIR_BASE   = 32'h6000_0000;
  localparam [SYS_ADDR_W-1:0] C_PAIR_BASE    = 32'h7000_0000;

  // ---------------------------------------------------------------
  // SVT AHB Interface instances — 4 DUT sides
  // ---------------------------------------------------------------
  // Macro to declare all AHB + APB interfaces for one side
  `define DECLARE_SIDE_IFS(PREFIX) \
    svt_ahb_if ahb_``PREFIX``_sub_if();  \
    assign ahb_``PREFIX``_sub_if.hclk    = clk;  \
    assign ahb_``PREFIX``_sub_if.hresetn = rst_n; \
    svt_ahb_if ahb_``PREFIX``_tx_if();   \
    assign ahb_``PREFIX``_tx_if.hclk    = clk;   \
    assign ahb_``PREFIX``_tx_if.hresetn = rst_n;  \
    svt_ahb_if ahb_``PREFIX``_fifo_if(); \
    assign ahb_``PREFIX``_fifo_if.hclk    = clk; \
    assign ahb_``PREFIX``_fifo_if.hresetn = rst_n;\
    svt_ahb_if ahb_``PREFIX``_adr_if();  \
    assign ahb_``PREFIX``_adr_if.hclk    = clk;  \
    assign ahb_``PREFIX``_adr_if.hresetn = rst_n; \
    svt_ahb_if ahb_``PREFIX``_mng_if();  \
    assign ahb_``PREFIX``_mng_if.hclk    = clk;  \
    assign ahb_``PREFIX``_mng_if.hresetn = rst_n; \
    apb_master_if apb_``PREFIX``_if(.clk(clk), .rst_n(rst_n));

  `DECLARE_SIDE_IFS(a)
  `DECLARE_SIDE_IFS(b1)
  `DECLARE_SIDE_IFS(b2)
  `DECLARE_SIDE_IFS(c)

  // System-level interface
  tidelink_ptp_chain_if tb_if(.clk(clk), .rst_n(rst_n));
  assign tb_if.poresetn = poresetn;

  // ---------------------------------------------------------------
  // PHY pad crossover: A <-> B_link1, B_link2 <-> C
  // ---------------------------------------------------------------
  wire                     a_pad_clk_tx,  b1_pad_clk_tx, b2_pad_clk_tx, c_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0] a_pad_tx,      b1_pad_tx,     b2_pad_tx,     c_pad_tx;

  // Link 1: A TX -> B1 RX, B1 TX -> A RX
  wire                     a_pad_clk_rx  = b1_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0] a_pad_rx      = b1_pad_tx;
  wire                     b1_pad_clk_rx = a_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0] b1_pad_rx     = a_pad_tx;

  // Link 2: B2 TX -> C RX, C TX -> B2 RX
  wire                     b2_pad_clk_rx = c_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0] b2_pad_rx     = c_pad_tx;
  wire                     c_pad_clk_rx  = b2_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0] c_pad_rx      = b2_pad_tx;

  // General bus crossover
  wire [31:0] a_gb_out, b1_gb_out, b2_gb_out, c_gb_out;
  wire [31:0] a_gb_in  = b1_gb_out;
  wire [31:0] b1_gb_in = a_gb_out;
  wire [31:0] b2_gb_in = c_gb_out;
  wire [31:0] c_gb_in  = b2_gb_out;

  // ---------------------------------------------------------------
  // DUT output wires — macro to declare per-side wires
  // ---------------------------------------------------------------
  `define DECLARE_SIDE_WIRES(PREFIX) \
    wire        PREFIX``_dut_sub_hreadyout, PREFIX``_dut_sub_hresp; \
    wire [31:0] PREFIX``_dut_sub_hrdata;    \
    wire        PREFIX``_dut_tx_hreadyout, PREFIX``_dut_tx_hresp;  \
    wire [31:0] PREFIX``_dut_tx_hrdata;     \
    wire        PREFIX``_dut_fifo_hreadyout, PREFIX``_dut_fifo_hresp; \
    wire [31:0] PREFIX``_dut_fifo_hrdata;   \
    wire        PREFIX``_dut_adr_hreadyout, PREFIX``_dut_adr_hresp; \
    wire [31:0] PREFIX``_dut_adr_hrdata;    \
    wire [31:0] PREFIX``_dut_mng_haddr;     \
    wire  [2:0] PREFIX``_dut_mng_hburst;    \
    wire  [3:0] PREFIX``_dut_mng_hprot;     \
    wire  [2:0] PREFIX``_dut_mng_hsize;     \
    wire  [1:0] PREFIX``_dut_mng_htrans;    \
    wire [31:0] PREFIX``_dut_mng_hwdata;    \
    wire        PREFIX``_dut_mng_hwrite;    \
    wire        PREFIX``_dut_mng_hready;    \
    wire [31:0] PREFIX``_mng_hrdata;        \
    wire        PREFIX``_mng_hresp;         \
    wire PREFIX``_released_credits_irq, PREFIX``_doorbell_irq; \
    wire PREFIX``_packet_committed_irq, PREFIX``_wlink_irq, PREFIX``_ptp_irq; \
    wire PREFIX``_d2d_reset_o;              \
    wire PREFIX``_servo_locked;

  `DECLARE_SIDE_WIRES(a)
  `DECLARE_SIDE_WIRES(b1)
  `DECLARE_SIDE_WIRES(b2)
  `DECLARE_SIDE_WIRES(c)

  // ---------------------------------------------------------------
  // PHC wires — shared PHC_B between B_link1 and B_link2
  // ---------------------------------------------------------------
  // PHC_A outputs → DUT A
  wire        a_phc_hw_capture;
  wire [47:0] a_phc_hw_cap_seconds;
  wire [29:0] a_phc_hw_cap_nanoseconds;
  wire [31:0] a_phc_hw_cap_sub_nanoseconds;
  wire [29:0] a_phc_nanoseconds;
  wire [47:0] a_phc_seconds;
  wire        a_phc_pps;

  // PHC_B outputs → DUT B_link1 and B_link2
  wire        b_phc_hw_capture;  // OR of b1 and b2 captures
  wire [47:0] b_phc_hw_cap_seconds;
  wire [29:0] b_phc_hw_cap_nanoseconds;
  wire [31:0] b_phc_hw_cap_sub_nanoseconds;
  wire [29:0] b_phc_nanoseconds;
  wire [47:0] b_phc_seconds;
  wire        b_phc_pps;

  // PHC_C outputs → DUT C
  wire        c_phc_hw_capture;
  wire [47:0] c_phc_hw_cap_seconds;
  wire [29:0] c_phc_hw_cap_nanoseconds;
  wire [31:0] c_phc_hw_cap_sub_nanoseconds;
  wire [29:0] c_phc_nanoseconds;
  wire [47:0] c_phc_seconds;
  wire        c_phc_pps;

  // DUT hw_capture outputs (to PHC)
  wire a_dut_hw_capture, b1_dut_hw_capture, b2_dut_hw_capture, c_dut_hw_capture;

  // DUT servo outputs (to PHC)
  wire        a_hw_set_time;
  wire [47:0] a_hw_set_seconds;
  wire [29:0] a_hw_set_nanoseconds;
  wire        a_hw_adj_valid;
  wire [31:0] a_hw_adj_ns_incr_frac;

  wire        b1_hw_set_time;
  wire [47:0] b1_hw_set_seconds;
  wire [29:0] b1_hw_set_nanoseconds;
  wire        b1_hw_adj_valid;
  wire [31:0] b1_hw_adj_ns_incr_frac;

  // B_link2 servo outputs (GM mode — not normally adjusting PHC, but wired for completeness)
  wire        b2_hw_set_time;
  wire [47:0] b2_hw_set_seconds;
  wire [29:0] b2_hw_set_nanoseconds;
  wire        b2_hw_adj_valid;
  wire [31:0] b2_hw_adj_ns_incr_frac;

  wire        c_hw_set_time;
  wire [47:0] c_hw_set_seconds;
  wire [29:0] c_hw_set_nanoseconds;
  wire        c_hw_adj_valid;
  wire [31:0] c_hw_adj_ns_incr_frac;

  // PHC_B hw_capture: OR of link1 and link2 (interleaved, not concurrent)
  assign b_phc_hw_capture = b1_dut_hw_capture | b2_dut_hw_capture;

  // =================================================================
  // PHC Instances (real RTL from ptp-hardware-clock-ahb)
  // =================================================================

  // PHC_A: free-running Grandmaster reference
  phc u_phc_a (
    .clk     (clk),
    .resetn  (rst_n),
    // APB slave (unused — tie off)
    .psel    (1'b0), .penable (1'b0), .pwrite  (1'b0),
    .paddr   ({APB_ADDR_W{1'b0}}), .pwdata  (32'h0),
    .prdata  (), .pready  (), .pslverr (),
    .pps_irq (), .alarm_irq (),
    // HW servo source 0 (from tidelink_top A)
    .hw_capture_0_i          (a_dut_hw_capture),
    .hw_cap_seconds_0_o      (a_phc_hw_cap_seconds),
    .hw_cap_nanoseconds_0_o  (a_phc_hw_cap_nanoseconds),
    .hw_cap_sub_nanoseconds_0_o (a_phc_hw_cap_sub_nanoseconds),
    .hw_set_time_0_i         (a_hw_set_time),
    .hw_set_seconds_0_i      (a_hw_set_seconds),
    .hw_set_nanoseconds_0_i  (a_hw_set_nanoseconds),
    .hw_adj_valid_0_i        (a_hw_adj_valid),
    .hw_adj_ns_incr_frac_0_i (a_hw_adj_ns_incr_frac),
    // HW servo source 1 (unused)
    .hw_capture_1_i          (1'b0),
    .hw_cap_seconds_1_o      (),
    .hw_cap_nanoseconds_1_o  (),
    .hw_cap_sub_nanoseconds_1_o (),
    .hw_set_time_1_i         (1'b0),
    .hw_set_seconds_1_i      (48'h0),
    .hw_set_nanoseconds_1_i  (30'h0),
    .hw_adj_valid_1_i        (1'b0),
    .hw_adj_ns_incr_frac_1_i (32'h0),
    // Status
    .servo_locked_i              (a_servo_locked),
    .servo_phase_step_active_i   (1'b0),
    .eth_rx_capture              (1'b0),
    .eth_tx_capture              (1'b0),
    .pps_out                     (a_phc_pps)
  );

  // PHC_B: shared between B_link1 (Sub) and B_link2 (GM)
  // Source 0: B_link1 servo (Sub — adjusts PHC)
  // Source 1: B_link2 servo (GM — captures t1/t4 but doesn't normally adjust)
  phc u_phc_b (
    .clk     (clk),
    .resetn  (rst_n),
    .psel    (1'b0), .penable (1'b0), .pwrite  (1'b0),
    .paddr   ({APB_ADDR_W{1'b0}}), .pwdata  (32'h0),
    .prdata  (), .pready  (), .pslverr (),
    .pps_irq (), .alarm_irq (),
    // HW servo source 0 (from B_link1 — Subordinate)
    .hw_capture_0_i          (b_phc_hw_capture),
    .hw_cap_seconds_0_o      (b_phc_hw_cap_seconds),
    .hw_cap_nanoseconds_0_o  (b_phc_hw_cap_nanoseconds),
    .hw_cap_sub_nanoseconds_0_o (b_phc_hw_cap_sub_nanoseconds),
    .hw_set_time_0_i         (b1_hw_set_time),
    .hw_set_seconds_0_i      (b1_hw_set_seconds),
    .hw_set_nanoseconds_0_i  (b1_hw_set_nanoseconds),
    .hw_adj_valid_0_i        (b1_hw_adj_valid),
    .hw_adj_ns_incr_frac_0_i (b1_hw_adj_ns_incr_frac),
    // HW servo source 1 (unused — B_link2 GM captures but doesn't adjust)
    .hw_capture_1_i          (1'b0),
    .hw_cap_seconds_1_o      (),
    .hw_cap_nanoseconds_1_o  (),
    .hw_cap_sub_nanoseconds_1_o (),
    .hw_set_time_1_i         (1'b0),
    .hw_set_seconds_1_i      (48'h0),
    .hw_set_nanoseconds_1_i  (30'h0),
    .hw_adj_valid_1_i        (1'b0),
    .hw_adj_ns_incr_frac_1_i (32'h0),
    .servo_locked_i              (b1_servo_locked),
    .servo_phase_step_active_i   (1'b0),
    .eth_rx_capture              (1'b0),
    .eth_tx_capture              (1'b0),
    .pps_out                     (b_phc_pps)
  );

  // PHC_C: disciplined by link2 servo
  phc u_phc_c (
    .clk     (clk),
    .resetn  (rst_n),
    .psel    (1'b0), .penable (1'b0), .pwrite  (1'b0),
    .paddr   ({APB_ADDR_W{1'b0}}), .pwdata  (32'h0),
    .prdata  (), .pready  (), .pslverr (),
    .pps_irq (), .alarm_irq (),
    .hw_capture_0_i          (c_dut_hw_capture),
    .hw_cap_seconds_0_o      (c_phc_hw_cap_seconds),
    .hw_cap_nanoseconds_0_o  (c_phc_hw_cap_nanoseconds),
    .hw_cap_sub_nanoseconds_0_o (c_phc_hw_cap_sub_nanoseconds),
    .hw_set_time_0_i         (c_hw_set_time),
    .hw_set_seconds_0_i      (c_hw_set_seconds),
    .hw_set_nanoseconds_0_i  (c_hw_set_nanoseconds),
    .hw_adj_valid_0_i        (c_hw_adj_valid),
    .hw_adj_ns_incr_frac_0_i (c_hw_adj_ns_incr_frac),
    .hw_capture_1_i          (1'b0),
    .hw_cap_seconds_1_o      (),
    .hw_cap_nanoseconds_1_o  (),
    .hw_cap_sub_nanoseconds_1_o (),
    .hw_set_time_1_i         (1'b0),
    .hw_set_seconds_1_i      (48'h0),
    .hw_set_nanoseconds_1_i  (30'h0),
    .hw_adj_valid_1_i        (1'b0),
    .hw_adj_ns_incr_frac_1_i (32'h0),
    .servo_locked_i              (c_servo_locked),
    .servo_phase_step_active_i   (1'b0),
    .eth_rx_capture              (1'b0),
    .eth_tx_capture              (1'b0),
    .pps_out                     (c_phc_pps)
  );

  // PHC nanoseconds/seconds outputs (directly from clock core)
  // These are exposed via the PHC's internal counter; for testbench purposes
  // we read them from the APB registers. The tidelink_top PHC CDC bridge
  // handles the synchronisation. Since we use hclk=phc_clk (same clock),
  // CDC adds benign latency only.

  // =================================================================
  // Macro to instantiate tidelink_top with all port connections
  // =================================================================
  `define INSTANTIATE_TIDELINK_TOP(INST_NAME, PREFIX, PAIR_BASE, LOCK_GATE_EN, PHC_LOCKED_I, PAD_CLK_TX, PAD_TX, PAD_CLK_RX, PAD_RX, GB_IN, GB_OUT, PHC_HW_CAP_SEC, PHC_HW_CAP_NS, PHC_HW_CAP_SUBNS, PHC_NS, PHC_SEC, PHC_PPS, DUT_HW_CAPTURE, HW_SET_TIME, HW_SET_SEC, HW_SET_NS, HW_ADJ_VALID, HW_ADJ_FRAC, SERVO_LOCKED) \
  tidelink_top #( \
    .SYS_ADDR_W        (SYS_ADDR_W), \
    .SYS_DATA_W        (SYS_DATA_W), \
    .RAM_ADDR_W        (RAM_ADDR_W), \
    .RAM_DATA_W        (RAM_DATA_W), \
    .APB_ADDR_W        (APB_ADDR_W), \
    .FC_DATA_W         (FC_DATA_W),  \
    .NUM_PHY_LANES     (NUM_PHY_LANES), \
    .TIDELINK_PAIR_BASE(PAIR_BASE),  \
    .PHC_LOCK_GATE_EN  (LOCK_GATE_EN) \
  ) INST_NAME ( \
    .hclk              (clk), \
    .hresetn           (rst_n), \
    .poresetn          (poresetn), \
    .phc_clk           (clk), \
    .phc_resetn        (rst_n), \
    /* AHB Sub */ \
    .ahb_sub_hsel      (1'b1), \
    .ahb_sub_haddr     (ahb_``PREFIX``_sub_if.master_if[0].haddr), \
    .ahb_sub_hburst    (ahb_``PREFIX``_sub_if.master_if[0].hburst), \
    .ahb_sub_hprot     (ahb_``PREFIX``_sub_if.master_if[0].hprot[3:0]), \
    .ahb_sub_hsize     (ahb_``PREFIX``_sub_if.master_if[0].hsize), \
    .ahb_sub_htrans    (ahb_``PREFIX``_sub_if.master_if[0].htrans), \
    .ahb_sub_hwdata    (ahb_``PREFIX``_sub_if.master_if[0].hwdata[31:0]), \
    .ahb_sub_hwrite    (ahb_``PREFIX``_sub_if.master_if[0].hwrite), \
    .ahb_sub_hready    (ahb_``PREFIX``_sub_if.master_if[0].hready), \
    .ahb_sub_hrdata    (PREFIX``_dut_sub_hrdata), \
    .ahb_sub_hresp     (PREFIX``_dut_sub_hresp), \
    .ahb_sub_hreadyout (PREFIX``_dut_sub_hreadyout), \
    /* AHB TX aperture */ \
    .ahb_tx_hsel       (1'b1), \
    .ahb_tx_haddr      (ahb_``PREFIX``_tx_if.master_if[0].haddr[RAM_ADDR_W-1:0]), \
    .ahb_tx_htrans     (ahb_``PREFIX``_tx_if.master_if[0].htrans), \
    .ahb_tx_hsize      (ahb_``PREFIX``_tx_if.master_if[0].hsize), \
    .ahb_tx_hwrite     (ahb_``PREFIX``_tx_if.master_if[0].hwrite), \
    .ahb_tx_hwdata     (ahb_``PREFIX``_tx_if.master_if[0].hwdata[31:0]), \
    .ahb_tx_hready     (ahb_``PREFIX``_tx_if.master_if[0].hready), \
    .ahb_tx_hrdata     (PREFIX``_dut_tx_hrdata), \
    .ahb_tx_hresp      (PREFIX``_dut_tx_hresp), \
    .ahb_tx_hreadyout  (PREFIX``_dut_tx_hreadyout), \
    /* AHB FIFO read */ \
    .ahb_fifo_hsel     (1'b1), \
    .ahb_fifo_haddr    (ahb_``PREFIX``_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0]), \
    .ahb_fifo_htrans   (ahb_``PREFIX``_fifo_if.master_if[0].htrans), \
    .ahb_fifo_hsize    (ahb_``PREFIX``_fifo_if.master_if[0].hsize), \
    .ahb_fifo_hwrite   (ahb_``PREFIX``_fifo_if.master_if[0].hwrite), \
    .ahb_fifo_hwdata   (ahb_``PREFIX``_fifo_if.master_if[0].hwdata[31:0]), \
    .ahb_fifo_hready   (ahb_``PREFIX``_fifo_if.master_if[0].hready), \
    .ahb_fifo_hrdata   (PREFIX``_dut_fifo_hrdata), \
    .ahb_fifo_hresp    (PREFIX``_dut_fifo_hresp), \
    .ahb_fifo_hreadyout(PREFIX``_dut_fifo_hreadyout), \
    /* AHB Addr translator config */ \
    .ahb_adr_hsel      (1'b1), \
    .ahb_adr_haddr     (ahb_``PREFIX``_adr_if.master_if[0].haddr), \
    .ahb_adr_hburst    (ahb_``PREFIX``_adr_if.master_if[0].hburst), \
    .ahb_adr_hprot     (ahb_``PREFIX``_adr_if.master_if[0].hprot[3:0]), \
    .ahb_adr_hsize     (ahb_``PREFIX``_adr_if.master_if[0].hsize), \
    .ahb_adr_htrans    (ahb_``PREFIX``_adr_if.master_if[0].htrans), \
    .ahb_adr_hwdata    (ahb_``PREFIX``_adr_if.master_if[0].hwdata[31:0]), \
    .ahb_adr_hwrite    (ahb_``PREFIX``_adr_if.master_if[0].hwrite), \
    .ahb_adr_hready    (ahb_``PREFIX``_adr_if.master_if[0].hready), \
    .ahb_adr_hrdata    (PREFIX``_dut_adr_hrdata), \
    .ahb_adr_hresp     (PREFIX``_dut_adr_hresp), \
    .ahb_adr_hreadyout (PREFIX``_dut_adr_hreadyout), \
    /* AHB Manager */ \
    .ahb_mng_haddr     (PREFIX``_dut_mng_haddr), \
    .ahb_mng_hburst    (PREFIX``_dut_mng_hburst), \
    .ahb_mng_hprot     (PREFIX``_dut_mng_hprot), \
    .ahb_mng_hsize     (PREFIX``_dut_mng_hsize), \
    .ahb_mng_htrans    (PREFIX``_dut_mng_htrans), \
    .ahb_mng_hwdata    (PREFIX``_dut_mng_hwdata), \
    .ahb_mng_hwrite    (PREFIX``_dut_mng_hwrite), \
    .ahb_mng_hready    (PREFIX``_dut_mng_hready), \
    .ahb_mng_hrdata    (PREFIX``_mng_hrdata), \
    .ahb_mng_hresp     (PREFIX``_mng_hresp), \
    /* Unified APB config */ \
    .apb_psel          (apb_``PREFIX``_if.psel), \
    .apb_paddr         (apb_``PREFIX``_if.paddr), \
    .apb_penable       (apb_``PREFIX``_if.penable), \
    .apb_pwrite        (apb_``PREFIX``_if.pwrite), \
    .apb_pstrb         (4'hF), \
    .apb_pprot         (3'h0), \
    .apb_pwdata        (apb_``PREFIX``_if.pwdata), \
    .apb_prdata        (apb_``PREFIX``_if.prdata), \
    .apb_pready        (apb_``PREFIX``_if.pready), \
    .apb_pslverr       (apb_``PREFIX``_if.pslverr), \
    /* AHB PTP TX write port (tie off — servo handles PTP autonomously) */ \
    .ahb_ptp_hsel      (1'b0), \
    .ahb_ptp_haddr     (4'h0), \
    .ahb_ptp_htrans    (2'b00), \
    .ahb_ptp_hsize     (3'h2), \
    .ahb_ptp_hwrite    (1'b0), \
    .ahb_ptp_hwdata    (32'h0), \
    .ahb_ptp_hready    (1'b1), \
    .ahb_ptp_hrdata    (), \
    .ahb_ptp_hresp     (), \
    .ahb_ptp_hreadyout (), \
    /* Scan/DFT */ \
    .scan_mode         (1'b0), \
    .scan_asyncrst_ctrl(1'b0), \
    .scan_clk          (1'b0), \
    .scan_shift        (1'b0), \
    .scan_in           (1'b0), \
    .scan_out          (), \
    /* Wlink PLL reference */ \
    .user_ref_clk      (ref_clk), \
    /* General bus */ \
    .gb_in             (GB_IN), \
    .gb_out            (GB_OUT), \
    /* PHY pads */ \
    .pad_clk_tx        (PAD_CLK_TX), \
    .pad_tx            (PAD_TX), \
    .pad_clk_rx        (PAD_CLK_RX), \
    .pad_rx            (PAD_RX), \
    /* PHC interface */ \
    .phc_hw_capture    (DUT_HW_CAPTURE), \
    .phc_nanoseconds   (PHC_NS), \
    .phc_seconds       (PHC_SEC), \
    .phc_pps           (PHC_PPS), \
    .phc_hw_cap_seconds       (PHC_HW_CAP_SEC), \
    .phc_hw_cap_nanoseconds   (PHC_HW_CAP_NS), \
    .phc_hw_cap_sub_nanoseconds (PHC_HW_CAP_SUBNS), \
    .phc_hw_set_time           (HW_SET_TIME), \
    .phc_hw_set_seconds        (HW_SET_SEC), \
    .phc_hw_set_nanoseconds    (HW_SET_NS), \
    .phc_hw_adj_valid          (HW_ADJ_VALID), \
    .phc_hw_adj_ns_incr_frac   (HW_ADJ_FRAC), \
    /* PHC lock gate */ \
    .phc_locked_i      (PHC_LOCKED_I), \
    .servo_locked      (SERVO_LOCKED), \
    /* Interrupts */ \
    .released_credits_irq (PREFIX``_released_credits_irq), \
    .doorbell_irq         (PREFIX``_doorbell_irq), \
    .packet_committed_irq (PREFIX``_packet_committed_irq), \
    .ptp_irq              (PREFIX``_ptp_irq), \
    .wlink_irq            (PREFIX``_wlink_irq), \
    .d2d_reset_o          (PREFIX``_d2d_reset_o) \
  );

  // =================================================================
  // DUT A — Chiplet A (Grandmaster)
  // =================================================================
  `INSTANTIATE_TIDELINK_TOP(u_chiplet_a, a, A_PAIR_BASE, 0, 1'b1,
    a_pad_clk_tx, a_pad_tx, a_pad_clk_rx, a_pad_rx, a_gb_in, a_gb_out,
    a_phc_hw_cap_seconds, a_phc_hw_cap_nanoseconds, a_phc_hw_cap_sub_nanoseconds,
    a_phc_nanoseconds, a_phc_seconds, a_phc_pps,
    a_dut_hw_capture, a_hw_set_time, a_hw_set_seconds, a_hw_set_nanoseconds,
    a_hw_adj_valid, a_hw_adj_ns_incr_frac, a_servo_locked)

  // =================================================================
  // DUT B_link1 — Chiplet B, link to A (Subordinate)
  // =================================================================
  `INSTANTIATE_TIDELINK_TOP(u_chiplet_b_link1, b1, B1_PAIR_BASE, 0, 1'b1,
    b1_pad_clk_tx, b1_pad_tx, b1_pad_clk_rx, b1_pad_rx, b1_gb_in, b1_gb_out,
    b_phc_hw_cap_seconds, b_phc_hw_cap_nanoseconds, b_phc_hw_cap_sub_nanoseconds,
    b_phc_nanoseconds, b_phc_seconds, b_phc_pps,
    b1_dut_hw_capture, b1_hw_set_time, b1_hw_set_seconds, b1_hw_set_nanoseconds,
    b1_hw_adj_valid, b1_hw_adj_ns_incr_frac, b1_servo_locked)

  // =================================================================
  // DUT B_link2 — Chiplet B, link to C (Grandmaster, gated by B_link1 lock)
  // =================================================================
  `INSTANTIATE_TIDELINK_TOP(u_chiplet_b_link2, b2, B2_PAIR_BASE, 1, b1_servo_locked,
    b2_pad_clk_tx, b2_pad_tx, b2_pad_clk_rx, b2_pad_rx, b2_gb_in, b2_gb_out,
    b_phc_hw_cap_seconds, b_phc_hw_cap_nanoseconds, b_phc_hw_cap_sub_nanoseconds,
    b_phc_nanoseconds, b_phc_seconds, b_phc_pps,
    b2_dut_hw_capture, b2_hw_set_time, b2_hw_set_seconds, b2_hw_set_nanoseconds,
    b2_hw_adj_valid, b2_hw_adj_ns_incr_frac, b2_servo_locked)

  // =================================================================
  // DUT C — Chiplet C (Subordinate)
  // =================================================================
  `INSTANTIATE_TIDELINK_TOP(u_chiplet_c, c, C_PAIR_BASE, 0, 1'b1,
    c_pad_clk_tx, c_pad_tx, c_pad_clk_rx, c_pad_rx, c_gb_in, c_gb_out,
    c_phc_hw_cap_seconds, c_phc_hw_cap_nanoseconds, c_phc_hw_cap_sub_nanoseconds,
    c_phc_nanoseconds, c_phc_seconds, c_phc_pps,
    c_dut_hw_capture, c_hw_set_time, c_hw_set_seconds, c_hw_set_nanoseconds,
    c_hw_adj_valid, c_hw_adj_ns_incr_frac, c_servo_locked)

  // =================================================================
  // Wire status to tb_if
  // =================================================================
  assign tb_if.a_servo_locked  = a_servo_locked;
  assign tb_if.b1_servo_locked = b1_servo_locked;
  assign tb_if.b2_servo_locked = b2_servo_locked;
  assign tb_if.c_servo_locked  = c_servo_locked;
  assign tb_if.a_ptp_irq       = a_ptp_irq;
  assign tb_if.b1_ptp_irq      = b1_ptp_irq;
  assign tb_if.b2_ptp_irq      = b2_ptp_irq;
  assign tb_if.c_ptp_irq       = c_ptp_irq;
  assign tb_if.a_packet_committed_irq  = a_packet_committed_irq;
  assign tb_if.b1_packet_committed_irq = b1_packet_committed_irq;
  assign tb_if.b2_packet_committed_irq = b2_packet_committed_irq;
  assign tb_if.c_packet_committed_irq  = c_packet_committed_irq;
  assign tb_if.a_wlink_irq  = a_wlink_irq;
  assign tb_if.b1_wlink_irq = b1_wlink_irq;
  assign tb_if.b2_wlink_irq = b2_wlink_irq;
  assign tb_if.c_wlink_irq  = c_wlink_irq;

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
    assign VIF.slave_if[0].hready_in = DUT_HREADY;                 \
    assign MNG_HRDATA = VIF.slave_if[0].hrdata[31:0];              \
    assign MNG_HRESP  = VIF.slave_if[0].hresp[0];                 \
    initial begin                                                   \
      force VIF.master_if[0].haddr   = DUT_HADDR;                  \
      force VIF.master_if[0].htrans  = DUT_HTRANS;                 \
      force VIF.master_if[0].hburst  = DUT_HBURST;                 \
      force VIF.master_if[0].hsize   = DUT_HSIZE;                  \
      force VIF.master_if[0].hprot   = DUT_HPROT;                  \
      force VIF.master_if[0].hwrite  = DUT_HWRITE;                 \
      force VIF.master_if[0].hwdata  = DUT_HWDATA;                 \
      force VIF.master_if[0].hready  = DUT_HREADY;                 \
      force VIF.master_if[0].hresp   = VIF.slave_if[0].hresp;      \
      force VIF.master_if[0].hrdata  = VIF.slave_if[0].hrdata;     \
      force VIF.master_if[0].hgrant  = 1'b1;                       \
    end

  // --- Wire all 4 sides ---
  `define WIRE_SIDE_SUBS(PREFIX) \
    `WIRE_AHB_SUB(ahb_``PREFIX``_sub_if,  PREFIX``_dut_sub_hreadyout,  PREFIX``_dut_sub_hresp,  PREFIX``_dut_sub_hrdata)  \
    `WIRE_AHB_SUB(ahb_``PREFIX``_tx_if,   PREFIX``_dut_tx_hreadyout,   PREFIX``_dut_tx_hresp,   PREFIX``_dut_tx_hrdata)   \
    `WIRE_AHB_SUB(ahb_``PREFIX``_fifo_if, PREFIX``_dut_fifo_hreadyout, PREFIX``_dut_fifo_hresp, PREFIX``_dut_fifo_hrdata) \
    `WIRE_AHB_SUB(ahb_``PREFIX``_adr_if,  PREFIX``_dut_adr_hreadyout,  PREFIX``_dut_adr_hresp,  PREFIX``_dut_adr_hrdata)

  `define WIRE_SIDE_MNG(PREFIX) \
    `WIRE_AHB_MNG(ahb_``PREFIX``_mng_if, \
      PREFIX``_dut_mng_haddr, PREFIX``_dut_mng_hburst, {28'h0, PREFIX``_dut_mng_hprot}, \
      PREFIX``_dut_mng_hsize, PREFIX``_dut_mng_htrans, PREFIX``_dut_mng_hwdata, \
      PREFIX``_dut_mng_hwrite, PREFIX``_dut_mng_hready, PREFIX``_mng_hrdata, PREFIX``_mng_hresp)

  `WIRE_SIDE_SUBS(a)
  `WIRE_SIDE_MNG(a)
  `WIRE_SIDE_SUBS(b1)
  `WIRE_SIDE_MNG(b1)
  `WIRE_SIDE_SUBS(b2)
  `WIRE_SIDE_MNG(b2)
  `WIRE_SIDE_SUBS(c)
  `WIRE_SIDE_MNG(c)

  // ---------------------------------------------------------------
  // PHC initialization — force enable and ns_incr for 100 MHz clock
  // Without this, PHC clock cores won't count and HW sync won't fire.
  // ns_incr=10 for 100 MHz (10 ns per cycle).
  // ---------------------------------------------------------------
  initial begin
    // Wait for reset deassertion
    @(posedge rst_n);
    // Force PHC enable and ns_incr on all three PHCs
    // ns_incr=10 for 100 MHz (10 ns per cycle)
    force u_phc_a.ctrl_enable = 1'b1;
    force u_phc_a.ns_incr     = 8'd10;
    force u_phc_b.ctrl_enable = 1'b1;
    force u_phc_b.ns_incr     = 8'd10;
    force u_phc_c.ctrl_enable = 1'b1;
    force u_phc_c.ns_incr     = 8'd10;
  end

  // Connect PHC free-running time outputs to tidelink_top inputs.
  // The PHC module doesn't expose nanoseconds/seconds as ports, so we
  // use hierarchical references to the internal clock core signals.
  assign a_phc_nanoseconds = u_phc_a.nanoseconds;
  assign a_phc_seconds     = u_phc_a.seconds;
  assign b_phc_nanoseconds = u_phc_b.nanoseconds;
  assign b_phc_seconds     = u_phc_b.seconds;
  assign c_phc_nanoseconds = u_phc_c.nanoseconds;
  assign c_phc_seconds     = u_phc_c.seconds;

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
    // Macro to set VIFs for one side
    `define SET_SIDE_VIFS(PREFIX) \
      uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_sub_ahb_sys_env"}, "vif", ahb_``PREFIX``_sub_if); \
      uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_tx_ahb_sys_env"}, "vif", ahb_``PREFIX``_tx_if); \
      uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_fifo_ahb_sys_env"}, "vif", ahb_``PREFIX``_fifo_if); \
      uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_adr_ahb_sys_env"}, "vif", ahb_``PREFIX``_adr_if); \
      uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_mng_ahb_sys_env"}, "vif", ahb_``PREFIX``_mng_if); \
      uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_apb_agt.driver"}, "vif", apb_``PREFIX``_if); \
      uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(), \
        {"uvm_test_top.env.", `"PREFIX`", "_apb_agt.monitor"}, "vif", apb_``PREFIX``_if);

    // Chiplet A
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_sub_ahb_sys_env",  "vif", ahb_a_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_tx_ahb_sys_env",   "vif", ahb_a_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_fifo_ahb_sys_env", "vif", ahb_a_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_adr_ahb_sys_env",  "vif", ahb_a_adr_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_mng_ahb_sys_env",  "vif", ahb_a_mng_if);

    // B_link1
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b1_sub_ahb_sys_env",  "vif", ahb_b1_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b1_tx_ahb_sys_env",   "vif", ahb_b1_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b1_fifo_ahb_sys_env", "vif", ahb_b1_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b1_adr_ahb_sys_env",  "vif", ahb_b1_adr_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b1_mng_ahb_sys_env",  "vif", ahb_b1_mng_if);

    // B_link2
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b2_sub_ahb_sys_env",  "vif", ahb_b2_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b2_tx_ahb_sys_env",   "vif", ahb_b2_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b2_fifo_ahb_sys_env", "vif", ahb_b2_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b2_adr_ahb_sys_env",  "vif", ahb_b2_adr_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b2_mng_ahb_sys_env",  "vif", ahb_b2_mng_if);

    // Chiplet C
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.c_sub_ahb_sys_env",  "vif", ahb_c_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.c_tx_ahb_sys_env",   "vif", ahb_c_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.c_fifo_ahb_sys_env", "vif", ahb_c_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.c_adr_ahb_sys_env",  "vif", ahb_c_adr_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.c_mng_ahb_sys_env",  "vif", ahb_c_mng_if);

    // APB interfaces
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.a_apb_agt.driver", "vif", apb_a_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.a_apb_agt.monitor", "vif", apb_a_if);
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.b1_apb_agt.driver", "vif", apb_b1_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.b1_apb_agt.monitor", "vif", apb_b1_if);
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.b2_apb_agt.driver", "vif", apb_b2_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.b2_apb_agt.monitor", "vif", apb_b2_if);
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.c_apb_agt.driver", "vif", apb_c_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.c_apb_agt.monitor", "vif", apb_c_if);

    // Clock/reset/status interface
    uvm_config_db#(virtual tidelink_ptp_chain_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    run_test();
  end

  // =================================================================
  // Force control (driven by tests via tb_if)
  // Force/release must be in module context, not inside a package.
  // =================================================================
  always @(*) begin
    if (tb_if.force_b1_servo_locked)
      force b1_servo_locked = tb_if.force_b1_servo_locked_val;
    else
      release b1_servo_locked;
  end

endmodule
