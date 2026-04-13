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
//   | tidelink_fifo             |      | tidelink_fifo             |
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
//   1. ahb_sub  — AHB master VIP -> regular AHB access (via XHB500+Wlink)
//   2. ahb_tx   — AHB master VIP -> TideLink TX aperture (via FC node)
//   3. ahb_fifo — AHB master VIP -> RX FIFO data read
//   4. ahb_mng  — AHB slave VIP  <- incoming remote AHB (via XHB500+Wlink)
//
// Per-side APB agent:
//   5. apb_agt — APB master agent -> unified config port (Wlink + TideLink + Addr Translator)
//      Address map: 0x0000-0x1FFF = Wlink, 0x2000-0x3FFF = TideLink config + PTP,
//                   0x4000-0x5FFF = Address translator
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
  // APB master interfaces (driven by apb_master_agent, unified config port)
  // Address map: 0x0000-0x1FFF = Wlink, 0x2000-0x203F = TideLink + PTP
  // ---------------------------------------------------------------

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
  // DUT output wires — Chiplet A
  // ---------------------------------------------------------------
  wire        a_dut_sub_hreadyout, a_dut_sub_hresp;
  wire [31:0] a_dut_sub_hrdata;
  wire        a_dut_tx_hreadyout, a_dut_tx_hresp;
  wire [31:0] a_dut_tx_hrdata;
  wire        a_dut_fifo_hreadyout, a_dut_fifo_hresp;
  wire [31:0] a_dut_fifo_hrdata;
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

  // ---------------------------------------------------------------
  // I2C open-drain bus wiring
  // ---------------------------------------------------------------
  wire a_i2c_scl_o, a_i2c_scl_t, a_i2c_sda_o, a_i2c_sda_t;
  wire b_i2c_scl_o, b_i2c_scl_t, b_i2c_sda_o, b_i2c_sda_t;
  wire i2c_scl = (a_i2c_scl_t ? 1'b1 : a_i2c_scl_o) & (b_i2c_scl_t ? 1'b1 : b_i2c_scl_o);
  wire i2c_sda = (a_i2c_sda_t ? 1'b1 : a_i2c_sda_o) & (b_i2c_sda_t ? 1'b1 : b_i2c_sda_o);

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

    // Unified APB config port (Wlink 0x0000-0x1FFF, TideLink 0x2000-0x203F)
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

    // Scan / DFT (tied off)
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

    // External PHC lock gate (not used in this testbench)
    .phc_locked_i         (1'b1),

    // Interrupts
    .released_credits_irq (a_released_credits_irq),
    .doorbell_irq         (a_doorbell_irq),
    .packet_committed_irq (a_packet_committed_irq),
    .wlink_irq            (a_wlink_irq),
    .d2d_reset_o          (a_d2d_reset_o),

    // Role selection (A = master)
    .role_strap_i         (1'b0),
    .role_is_master_o     (),
    .role_locked_o        (),

    // I2C sideband
    .i2c_scl_i            (i2c_scl),
    .i2c_scl_o            (a_i2c_scl_o),
    .i2c_scl_t            (a_i2c_scl_t),
    .i2c_sda_i            (i2c_sda),
    .i2c_sda_o            (a_i2c_sda_o),
    .i2c_sda_t            (a_i2c_sda_t),

    // I2C sideband AXI (tied off)
    .s_i2c_axi_awvalid    (1'b0),
    .s_i2c_axi_awid       (2'b00),
    .s_i2c_axi_awaddr     (4'h0),
    .s_i2c_axi_awlen      (8'h00),
    .s_i2c_axi_awsize     (3'h0),
    .s_i2c_axi_awburst    (2'b00),
    .s_i2c_axi_awlock     (1'b0),
    .s_i2c_axi_awcache    (4'h0),
    .s_i2c_axi_awprot     (3'h0),
    .s_i2c_axi_awready    (),
    .s_i2c_axi_wvalid     (1'b0),
    .s_i2c_axi_wdata      (32'h0),
    .s_i2c_axi_wstrb      (4'h0),
    .s_i2c_axi_wlast      (1'b0),
    .s_i2c_axi_wready     (),
    .s_i2c_axi_bvalid     (),
    .s_i2c_axi_bid        (),
    .s_i2c_axi_bresp      (),
    .s_i2c_axi_bready     (1'b1),
    .s_i2c_axi_arvalid    (1'b0),
    .s_i2c_axi_arid       (2'b00),
    .s_i2c_axi_araddr     (4'h0),
    .s_i2c_axi_arlen      (8'h00),
    .s_i2c_axi_arsize     (3'h0),
    .s_i2c_axi_arburst    (2'b00),
    .s_i2c_axi_arlock     (1'b0),
    .s_i2c_axi_arcache    (4'h0),
    .s_i2c_axi_arprot     (3'h0),
    .s_i2c_axi_arready    (),
    .s_i2c_axi_rvalid     (),
    .s_i2c_axi_rid        (),
    .s_i2c_axi_rdata      (),
    .s_i2c_axi_rresp      (),
    .s_i2c_axi_rlast      (),
    .s_i2c_axi_rready     (1'b1),

    // I2C interrupts
    .i2c_nbsy_irq         (),
    .i2c_nrd_empty_irq    ()
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

    // Unified APB config port (Wlink 0x0000-0x1FFF, TideLink 0x2000-0x203F)
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

    // Scan / DFT
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

    // External PHC lock gate (not used in this testbench)
    .phc_locked_i         (1'b1),

    .released_credits_irq (b_released_credits_irq),
    .doorbell_irq         (b_doorbell_irq),
    .packet_committed_irq (b_packet_committed_irq),
    .wlink_irq            (b_wlink_irq),
    .d2d_reset_o          (b_d2d_reset_o),

    // Role selection (B = slave)
    .role_strap_i         (1'b1),
    .role_is_master_o     (),
    .role_locked_o        (),

    // I2C sideband
    .i2c_scl_i            (i2c_scl),
    .i2c_scl_o            (b_i2c_scl_o),
    .i2c_scl_t            (b_i2c_scl_t),
    .i2c_sda_i            (i2c_sda),
    .i2c_sda_o            (b_i2c_sda_o),
    .i2c_sda_t            (b_i2c_sda_t),

    // I2C sideband AXI (tied off)
    .s_i2c_axi_awvalid    (1'b0),
    .s_i2c_axi_awid       (2'b00),
    .s_i2c_axi_awaddr     (4'h0),
    .s_i2c_axi_awlen      (8'h00),
    .s_i2c_axi_awsize     (3'h0),
    .s_i2c_axi_awburst    (2'b00),
    .s_i2c_axi_awlock     (1'b0),
    .s_i2c_axi_awcache    (4'h0),
    .s_i2c_axi_awprot     (3'h0),
    .s_i2c_axi_awready    (),
    .s_i2c_axi_wvalid     (1'b0),
    .s_i2c_axi_wdata      (32'h0),
    .s_i2c_axi_wstrb      (4'h0),
    .s_i2c_axi_wlast      (1'b0),
    .s_i2c_axi_wready     (),
    .s_i2c_axi_bvalid     (),
    .s_i2c_axi_bid        (),
    .s_i2c_axi_bresp      (),
    .s_i2c_axi_bready     (1'b1),
    .s_i2c_axi_arvalid    (1'b0),
    .s_i2c_axi_arid       (2'b00),
    .s_i2c_axi_araddr     (4'h0),
    .s_i2c_axi_arlen      (8'h00),
    .s_i2c_axi_arsize     (3'h0),
    .s_i2c_axi_arburst    (2'b00),
    .s_i2c_axi_arlock     (1'b0),
    .s_i2c_axi_arcache    (4'h0),
    .s_i2c_axi_arprot     (3'h0),
    .s_i2c_axi_arready    (),
    .s_i2c_axi_rvalid     (),
    .s_i2c_axi_rid        (),
    .s_i2c_axi_rdata      (),
    .s_i2c_axi_rresp      (),
    .s_i2c_axi_rlast      (),
    .s_i2c_axi_rready     (1'b1),

    // I2C interrupts
    .i2c_nbsy_irq         (),
    .i2c_nrd_empty_irq    ()
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

  // --- Chiplet A manager interface ---
  `WIRE_AHB_MNG(ahb_a_mng_if,
    a_dut_mng_haddr, a_dut_mng_hburst, {28'h0, a_dut_mng_hprot},
    a_dut_mng_hsize, a_dut_mng_htrans, a_dut_mng_hwdata,
    a_dut_mng_hwrite, a_dut_mng_hready, a_mng_hrdata, a_mng_hresp)

  // --- Chiplet B subordinate interfaces ---
  `WIRE_AHB_SUB(ahb_b_sub_if,  b_dut_sub_hreadyout,  b_dut_sub_hresp,  b_dut_sub_hrdata)
  `WIRE_AHB_SUB(ahb_b_tx_if,   b_dut_tx_hreadyout,   b_dut_tx_hresp,   b_dut_tx_hrdata)
  `WIRE_AHB_SUB(ahb_b_fifo_if, b_dut_fifo_hreadyout, b_dut_fifo_hresp, b_dut_fifo_hrdata)

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
      "uvm_test_top.env.a_mng_ahb_sys_env",  "vif", ahb_a_mng_if);

    // Chiplet B AHB VIPs
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_sub_ahb_sys_env",  "vif", ahb_b_sub_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_tx_ahb_sys_env",   "vif", ahb_b_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_fifo_ahb_sys_env", "vif", ahb_b_fifo_if);
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

  // =================================================================
  // Reset control (driven by tests via tb_if)
  // Force/release must be in module context, not inside a package.
  // =================================================================
  always @(*) begin
    if (tb_if.force_reset)
      force rst_n = 1'b0;
    else
      release rst_n;
  end

endmodule
