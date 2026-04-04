///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink full-system verification.
//
// Instantiates TWO complete tidelink_top modules connected back-to-back
// via PHY pad crossover, exercising the full chiplet communication stack:
//
//   Chiplet A (tidelink_top)           Chiplet B (tidelink_top)
//   +---------------------------+      +---------------------------+
//   | tidelink_fifo_ahb         |      | tidelink_fifo_ahb         |
//   | tidelink_fc_adapter       |      | tidelink_fc_adapter       |
//   | tidelink_addr_translator  |      | tidelink_addr_translator  |
//   | XHB500 AHB<->AXI bridges  |      | XHB500 AHB<->AXI bridges  |
//   | Wlink chiplet controller  |      | Wlink chiplet controller  |
//   +-------+----------+-------+      +-------+----------+-------+
//           |          |                       |          |
//      PHY TX|          |PHY RX           PHY TX|          |PHY RX
//           |          |                       |          |
//           +----------+-----------------------+----------+
//                      |    PHY Pad Crossover   |
//                      +------------------------+
//     A pad_tx -> B pad_rx,  B pad_tx -> A pad_rx
//
// Per-side SVT AHB VIP interfaces:
//   1. ahb_sub  — AHB master VIP → regular AHB access (via XHB500+Wlink)
//   2. ahb_tx   — AHB master VIP → TideLink TX aperture (via FC node)
//   3. ahb_fifo — AHB master VIP → RX FIFO data read
//   4. ahb_cfg  — AHB master VIP → TideLink config registers
//   5. ahb_adr  — AHB master VIP → address translator configuration
//   6. ahb_mng  — AHB slave VIP  ← incoming remote AHB (via XHB500+Wlink)
//
// Per-side APB agent:
//   7. apb_ctrl — APB master agent → Wlink controller configuration
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

// System-specific interface
`include "tidelink_top_system_if.sv"

// APB master interface (must be compiled outside the package)
`include "apb_master_if.sv"

// Testbench package
`include "tidelink_top_system_pkg.sv"

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
  import tidelink_top_system_pkg::*;

  // ---------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------
  localparam SYS_ADDR_W = 32;
  localparam SYS_DATA_W = 32;
  localparam RAM_ADDR_W = 14;
  localparam RAM_DATA_W = 32;
  localparam APB_ADDR_W = 12;
  localparam FC_DATA_W  = 48;

  // Pair base addresses: A points to B's config space, B points to A's
  localparam [SYS_ADDR_W-1:0] A_PAIR_BASE = 32'h4000_0000;
  localparam [SYS_ADDR_W-1:0] B_PAIR_BASE = 32'h5000_0000;

  // ---------------------------------------------------------------
  // APB master interface (simple wires, driven by apb_master_agent)
  // ---------------------------------------------------------------
  // Chiplet A APB
  wire        a_apb_psel;
  wire [12:0] a_apb_paddr;
  wire        a_apb_penable;
  wire        a_apb_pwrite;
  wire  [3:0] a_apb_pstrb;
  wire  [2:0] a_apb_pprot;
  wire [31:0] a_apb_pwdata;
  wire [31:0] a_apb_prdata;
  wire        a_apb_pready;
  wire        a_apb_pslverr;

  // Chiplet B APB
  wire        b_apb_psel;
  wire [12:0] b_apb_paddr;
  wire        b_apb_penable;
  wire        b_apb_pwrite;
  wire  [3:0] b_apb_pstrb;
  wire  [2:0] b_apb_pprot;
  wire [31:0] b_apb_pwdata;
  wire [31:0] b_apb_prdata;
  wire        b_apb_pready;
  wire        b_apb_pslverr;

  // ---------------------------------------------------------------
  // SVT AHB Interface instances — Chiplet A
  // ---------------------------------------------------------------

  // AHB Sub (regular access to remote)
  svt_ahb_if ahb_a_sub_if();
  assign ahb_a_sub_if.hclk    = clk;
  assign ahb_a_sub_if.hresetn = rst_n;

  // AHB TX aperture
  svt_ahb_if ahb_a_tx_if();
  assign ahb_a_tx_if.hclk    = clk;
  assign ahb_a_tx_if.hresetn = rst_n;

  // AHB FIFO read
  svt_ahb_if ahb_a_fifo_if();
  assign ahb_a_fifo_if.hclk    = clk;
  assign ahb_a_fifo_if.hresetn = rst_n;

  // AHB Config
  svt_ahb_if ahb_a_cfg_if();
  assign ahb_a_cfg_if.hclk    = clk;
  assign ahb_a_cfg_if.hresetn = rst_n;

  // AHB Address translator config
  svt_ahb_if ahb_a_adr_if();
  assign ahb_a_adr_if.hclk    = clk;
  assign ahb_a_adr_if.hresetn = rst_n;

  // AHB Manager (incoming from remote — slave VIP responds)
  svt_ahb_if ahb_a_mng_if();
  assign ahb_a_mng_if.hclk    = clk;
  assign ahb_a_mng_if.hresetn = rst_n;

  // APB master interface A
  apb_master_if apb_a_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // SVT AHB Interface instances — Chiplet B
  // ---------------------------------------------------------------

  svt_ahb_if ahb_b_sub_if();
  assign ahb_b_sub_if.hclk    = clk;
  assign ahb_b_sub_if.hresetn = rst_n;

  svt_ahb_if ahb_b_tx_if();
  assign ahb_b_tx_if.hclk    = clk;
  assign ahb_b_tx_if.hresetn = rst_n;

  svt_ahb_if ahb_b_fifo_if();
  assign ahb_b_fifo_if.hclk    = clk;
  assign ahb_b_fifo_if.hresetn = rst_n;

  svt_ahb_if ahb_b_cfg_if();
  assign ahb_b_cfg_if.hclk    = clk;
  assign ahb_b_cfg_if.hresetn = rst_n;

  svt_ahb_if ahb_b_adr_if();
  assign ahb_b_adr_if.hclk    = clk;
  assign ahb_b_adr_if.hresetn = rst_n;

  svt_ahb_if ahb_b_mng_if();
  assign ahb_b_mng_if.hclk    = clk;
  assign ahb_b_mng_if.hresetn = rst_n;

  apb_master_if apb_b_if(.clk(clk), .rst_n(rst_n));

  // System-level interface
  tidelink_top_system_if tb_if(.clk(clk), .rst_n(rst_n));
  assign tb_if.poresetn = poresetn;

  // ---------------------------------------------------------------
  // PHY pad crossover: A TX -> B RX, B TX -> A RX (8-lane GPIO)
  // ---------------------------------------------------------------
  localparam NUM_PHY_LANES = 8;

  wire                       a_pad_clk_tx, b_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   a_pad_tx, b_pad_tx;

  // A TX pads -> B RX pads, B TX pads -> A RX pads
  wire                       a_pad_clk_rx = b_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   a_pad_rx     = b_pad_tx;
  wire                       b_pad_clk_rx = a_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   b_pad_rx     = a_pad_tx;

  // ---------------------------------------------------------------
  // General bus crossover: A out -> B in, B out -> A in
  // ---------------------------------------------------------------
  wire [31:0] a_gb_out, b_gb_out;
  wire [31:0] a_gb_in = b_gb_out;
  wire [31:0] b_gb_in = a_gb_out;

  // ---------------------------------------------------------------
  // DUT output wires — Chiplet A
  // ---------------------------------------------------------------
  wire        a_dut_sub_hreadyout, a_dut_sub_hresp;
  wire [31:0] a_dut_sub_hrdata;
  wire        a_dut_tx_hreadyout, a_dut_tx_hresp;
  wire [31:0] a_dut_tx_hrdata;
  wire        a_dut_fifo_hreadyout, a_dut_fifo_hresp;
  wire [31:0] a_dut_fifo_hrdata;
  wire        a_dut_cfg_hreadyout, a_dut_cfg_hresp;
  wire [31:0] a_dut_cfg_hrdata;
  wire        a_dut_adr_hreadyout, a_dut_adr_hresp;
  wire [31:0] a_dut_adr_hrdata;

  // A manager outputs (DUT drives these)
  wire [31:0] a_dut_mng_haddr;
  wire  [2:0] a_dut_mng_hburst;
  wire  [3:0] a_dut_mng_hprot;
  wire  [2:0] a_dut_mng_hsize;
  wire  [1:0] a_dut_mng_htrans;
  wire [31:0] a_dut_mng_hwdata;
  wire        a_dut_mng_hwrite;
  wire        a_dut_mng_hready;

  // A manager inputs (from slave VIP)
  wire [31:0] a_mng_hrdata;
  wire        a_mng_hresp;

  // A interrupts
  wire a_released_credits_irq, a_doorbell_irq, a_packet_committed_irq, a_wlink_irq;
  wire a_d2d_reset_o;

  // ---------------------------------------------------------------
  // DUT output wires — Chiplet B
  // ---------------------------------------------------------------
  wire        b_dut_sub_hreadyout, b_dut_sub_hresp;
  wire [31:0] b_dut_sub_hrdata;
  wire        b_dut_tx_hreadyout, b_dut_tx_hresp;
  wire [31:0] b_dut_tx_hrdata;
  wire        b_dut_fifo_hreadyout, b_dut_fifo_hresp;
  wire [31:0] b_dut_fifo_hrdata;
  wire        b_dut_cfg_hreadyout, b_dut_cfg_hresp;
  wire [31:0] b_dut_cfg_hrdata;
  wire        b_dut_adr_hreadyout, b_dut_adr_hresp;
  wire [31:0] b_dut_adr_hrdata;

  wire [31:0] b_dut_mng_haddr;
  wire  [2:0] b_dut_mng_hburst;
  wire  [3:0] b_dut_mng_hprot;
  wire  [2:0] b_dut_mng_hsize;
  wire  [1:0] b_dut_mng_htrans;
  wire [31:0] b_dut_mng_hwdata;
  wire        b_dut_mng_hwrite;
  wire        b_dut_mng_hready;

  wire [31:0] b_mng_hrdata;
  wire        b_mng_hresp;

  wire b_released_credits_irq, b_doorbell_irq, b_packet_committed_irq, b_wlink_irq;
  wire b_d2d_reset_o;

  // =================================================================
  // DUT A — tidelink_top
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

    // AHB Sub (regular access)
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

    // AHB Config
    .ahb_cfg_hsel      (1'b1),
    .ahb_cfg_haddr     (ahb_a_cfg_if.master_if[0].haddr[APB_ADDR_W-1:0]),
    .ahb_cfg_htrans    (ahb_a_cfg_if.master_if[0].htrans),
    .ahb_cfg_hsize     (ahb_a_cfg_if.master_if[0].hsize),
    .ahb_cfg_hwrite    (ahb_a_cfg_if.master_if[0].hwrite),
    .ahb_cfg_hwdata    (ahb_a_cfg_if.master_if[0].hwdata[31:0]),
    .ahb_cfg_hready    (ahb_a_cfg_if.master_if[0].hready),
    .ahb_cfg_hrdata    (a_dut_cfg_hrdata),
    .ahb_cfg_hresp     (a_dut_cfg_hresp),
    .ahb_cfg_hreadyout (a_dut_cfg_hreadyout),

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

    // AHB Address translator config
    .ahb_adr_hsel      (1'b1),
    .ahb_adr_haddr     (ahb_a_adr_if.master_if[0].haddr),
    .ahb_adr_hburst    (ahb_a_adr_if.master_if[0].hburst),
    .ahb_adr_hprot     (ahb_a_adr_if.master_if[0].hprot[3:0]),
    .ahb_adr_hsize     (ahb_a_adr_if.master_if[0].hsize),
    .ahb_adr_htrans    (ahb_a_adr_if.master_if[0].htrans),
    .ahb_adr_hwdata    (ahb_a_adr_if.master_if[0].hwdata[31:0]),
    .ahb_adr_hwrite    (ahb_a_adr_if.master_if[0].hwrite),
    .ahb_adr_hready    (ahb_a_adr_if.master_if[0].hready),
    .ahb_adr_hrdata    (a_dut_adr_hrdata),
    .ahb_adr_hresp     (a_dut_adr_hresp),
    .ahb_adr_hreadyout (a_dut_adr_hreadyout),

    // APB Wlink controller config
    .apb_ctrl_psel     (apb_a_if.psel),
    .apb_ctrl_paddr    ({1'b0, apb_a_if.paddr}),
    .apb_ctrl_penable  (apb_a_if.penable),
    .apb_ctrl_pwrite   (apb_a_if.pwrite),
    .apb_ctrl_pstrb    (4'hF),
    .apb_ctrl_pprot    (3'h0),
    .apb_ctrl_pwdata   (apb_a_if.pwdata),
    .apb_ctrl_prdata   (apb_a_if.prdata),
    .apb_ctrl_pready   (apb_a_if.pready),
    .apb_ctrl_pslverr  (apb_a_if.pslverr),

    // Scan / DFT (tied off)
    .scan_mode         (1'b0),
    .scan_asyncrst_ctrl(1'b0),
    .scan_clk          (1'b0),
    .scan_shift        (1'b0),
    .scan_in           (1'b0),
    .scan_out          (),

    // Wlink PLL reference
    .user_ref_clk      (ref_clk),

    // General bus crossover
    .gb_in             (a_gb_in),
    .gb_out            (a_gb_out),

    // PHY pads
    .pad_clk_tx        (a_pad_clk_tx),
    .pad_tx            (a_pad_tx),
    .pad_clk_rx        (a_pad_clk_rx),
    .pad_rx            (a_pad_rx),

    // Interrupts
    .released_credits_irq (a_released_credits_irq),
    .doorbell_irq         (a_doorbell_irq),
    .packet_committed_irq (a_packet_committed_irq),
    .wlink_irq            (a_wlink_irq),
    .d2d_reset_o          (a_d2d_reset_o)
  );

  // =================================================================
  // DUT B — tidelink_top
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

    // AHB Sub
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

    // AHB TX aperture
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

    // AHB FIFO read
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

    // AHB Config
    .ahb_cfg_hsel      (1'b1),
    .ahb_cfg_haddr     (ahb_b_cfg_if.master_if[0].haddr[APB_ADDR_W-1:0]),
    .ahb_cfg_htrans    (ahb_b_cfg_if.master_if[0].htrans),
    .ahb_cfg_hsize     (ahb_b_cfg_if.master_if[0].hsize),
    .ahb_cfg_hwrite    (ahb_b_cfg_if.master_if[0].hwrite),
    .ahb_cfg_hwdata    (ahb_b_cfg_if.master_if[0].hwdata[31:0]),
    .ahb_cfg_hready    (ahb_b_cfg_if.master_if[0].hready),
    .ahb_cfg_hrdata    (b_dut_cfg_hrdata),
    .ahb_cfg_hresp     (b_dut_cfg_hresp),
    .ahb_cfg_hreadyout (b_dut_cfg_hreadyout),

    // AHB Manager
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

    // AHB Address translator config
    .ahb_adr_hsel      (1'b1),
    .ahb_adr_haddr     (ahb_b_adr_if.master_if[0].haddr),
    .ahb_adr_hburst    (ahb_b_adr_if.master_if[0].hburst),
    .ahb_adr_hprot     (ahb_b_adr_if.master_if[0].hprot[3:0]),
    .ahb_adr_hsize     (ahb_b_adr_if.master_if[0].hsize),
    .ahb_adr_htrans    (ahb_b_adr_if.master_if[0].htrans),
    .ahb_adr_hwdata    (ahb_b_adr_if.master_if[0].hwdata[31:0]),
    .ahb_adr_hwrite    (ahb_b_adr_if.master_if[0].hwrite),
    .ahb_adr_hready    (ahb_b_adr_if.master_if[0].hready),
    .ahb_adr_hrdata    (b_dut_adr_hrdata),
    .ahb_adr_hresp     (b_dut_adr_hresp),
    .ahb_adr_hreadyout (b_dut_adr_hreadyout),

    // APB Wlink controller config
    .apb_ctrl_psel     (apb_b_if.psel),
    .apb_ctrl_paddr    ({1'b0, apb_b_if.paddr}),
    .apb_ctrl_penable  (apb_b_if.penable),
    .apb_ctrl_pwrite   (apb_b_if.pwrite),
    .apb_ctrl_pstrb    (4'hF),
    .apb_ctrl_pprot    (3'h0),
    .apb_ctrl_pwdata   (apb_b_if.pwdata),
    .apb_ctrl_prdata   (apb_b_if.prdata),
    .apb_ctrl_pready   (apb_b_if.pready),
    .apb_ctrl_pslverr  (apb_b_if.pslverr),

    // Scan / DFT
    .scan_mode         (1'b0),
    .scan_asyncrst_ctrl(1'b0),
    .scan_clk          (1'b0),
    .scan_shift        (1'b0),
    .scan_in           (1'b0),
    .scan_out          (),

    .user_ref_clk      (ref_clk),

    .gb_in             (b_gb_in),
    .gb_out            (b_gb_out),

    .pad_clk_tx        (b_pad_clk_tx),
    .pad_tx            (b_pad_tx),
    .pad_clk_rx        (b_pad_clk_rx),
    .pad_rx            (b_pad_rx),

    .released_credits_irq (b_released_credits_irq),
    .doorbell_irq         (b_doorbell_irq),
    .packet_committed_irq (b_packet_committed_irq),
    .wlink_irq            (b_wlink_irq),
    .d2d_reset_o          (b_d2d_reset_o)
  );

  // =================================================================
  // Wire IRQs to tb_if
  // =================================================================
  assign tb_if.a_released_credits_irq = a_released_credits_irq;
  assign tb_if.a_doorbell_irq         = a_doorbell_irq;
  assign tb_if.a_packet_committed_irq = a_packet_committed_irq;
  assign tb_if.a_wlink_irq            = a_wlink_irq;
  assign tb_if.b_released_credits_irq = b_released_credits_irq;
  assign tb_if.b_doorbell_irq         = b_doorbell_irq;
  assign tb_if.b_packet_committed_irq = b_packet_committed_irq;
  assign tb_if.b_wlink_irq            = b_wlink_irq;

  // =================================================================
  // VIP AHB interface wiring — helper macro
  // =================================================================
  // For subordinate ports: VIP master drives, DUT responds
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

  // For manager ports: DUT drives, VIP slave responds
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

  // --- Chiplet A subordinate interfaces ---
  `WIRE_AHB_SUB(ahb_a_sub_if,  a_dut_sub_hreadyout,  a_dut_sub_hresp,  a_dut_sub_hrdata)
  `WIRE_AHB_SUB(ahb_a_tx_if,   a_dut_tx_hreadyout,   a_dut_tx_hresp,   a_dut_tx_hrdata)
  `WIRE_AHB_SUB(ahb_a_fifo_if, a_dut_fifo_hreadyout, a_dut_fifo_hresp, a_dut_fifo_hrdata)
  `WIRE_AHB_SUB(ahb_a_cfg_if,  a_dut_cfg_hreadyout,  a_dut_cfg_hresp,  a_dut_cfg_hrdata)
  `WIRE_AHB_SUB(ahb_a_adr_if,  a_dut_adr_hreadyout,  a_dut_adr_hresp,  a_dut_adr_hrdata)

  // --- Chiplet A manager interface ---
  `WIRE_AHB_MNG(ahb_a_mng_if,
    a_dut_mng_haddr, a_dut_mng_hburst, {28'h0, a_dut_mng_hprot},
    a_dut_mng_hsize, a_dut_mng_htrans, a_dut_mng_hwdata,
    a_dut_mng_hwrite, a_dut_mng_hready, a_mng_hrdata, a_mng_hresp)

  // --- Chiplet B subordinate interfaces ---
  `WIRE_AHB_SUB(ahb_b_sub_if,  b_dut_sub_hreadyout,  b_dut_sub_hresp,  b_dut_sub_hrdata)
  `WIRE_AHB_SUB(ahb_b_tx_if,   b_dut_tx_hreadyout,   b_dut_tx_hresp,   b_dut_tx_hrdata)
  `WIRE_AHB_SUB(ahb_b_fifo_if, b_dut_fifo_hreadyout, b_dut_fifo_hresp, b_dut_fifo_hrdata)
  `WIRE_AHB_SUB(ahb_b_cfg_if,  b_dut_cfg_hreadyout,  b_dut_cfg_hresp,  b_dut_cfg_hrdata)
  `WIRE_AHB_SUB(ahb_b_adr_if,  b_dut_adr_hreadyout,  b_dut_adr_hresp,  b_dut_adr_hrdata)

  // --- Chiplet B manager interface ---
  `WIRE_AHB_MNG(ahb_b_mng_if,
    b_dut_mng_haddr, b_dut_mng_hburst, {28'h0, b_dut_mng_hprot},
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
      "uvm_test_top.env.a_sub_ahb_sys_env",  "vif", ahb_a_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_tx_ahb_sys_env",   "vif", ahb_a_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_fifo_ahb_sys_env", "vif", ahb_a_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_cfg_ahb_sys_env",  "vif", ahb_a_cfg_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_adr_ahb_sys_env",  "vif", ahb_a_adr_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_mng_ahb_sys_env",  "vif", ahb_a_mng_if);

    // Chiplet B AHB VIPs
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_sub_ahb_sys_env",  "vif", ahb_b_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_tx_ahb_sys_env",   "vif", ahb_b_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_fifo_ahb_sys_env", "vif", ahb_b_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_cfg_ahb_sys_env",  "vif", ahb_b_cfg_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_adr_ahb_sys_env",  "vif", ahb_b_adr_if);
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
    uvm_config_db#(virtual tidelink_top_system_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    run_test();
  end

endmodule
