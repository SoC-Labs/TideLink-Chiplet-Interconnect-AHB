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

  // SoC Labs (2026-05-08): force experiment removed — XMRE error.
  // Test by directly editing reset value of swi_phase_offset in WavD2DGpio.v
  // OR by APB-writing it post-lock + post-swreset.

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
  // Each lane's pass-through can be intercepted via tb_if.{a2b,b2a}_lane_perturb_*
  // (default = pass-through). Used by Phase 4 lane-mask sim plan tests to
  // simulate a damaged ribbon pin: the perturb forces a stuck/garbage value
  // on the wire and the test asserts that with the corresponding mask bit
  // cleared, packet integrity holds.
  localparam NUM_PHY_LANES = 8;

  wire                       a_pad_clk_tx, b_pad_clk_tx;
  wire [NUM_PHY_LANES-1:0]   a_pad_tx, b_pad_tx;

  // Per-lane perturb mux on A->B path
  wire [NUM_PHY_LANES-1:0]   a2b_pad;
  genvar pi;
  generate
    for (pi = 0; pi < NUM_PHY_LANES; pi = pi + 1) begin : g_a2b_perturb
      assign a2b_pad[pi] = tb_if.a2b_lane_perturb_en[pi]
                         ? tb_if.a2b_lane_perturb_val[pi]
                         : a_pad_tx[pi];
    end
  endgenerate

  // Per-lane perturb mux on B->A path
  wire [NUM_PHY_LANES-1:0]   b2a_pad;
  generate
    for (pi = 0; pi < NUM_PHY_LANES; pi = pi + 1) begin : g_b2a_perturb
      assign b2a_pad[pi] = tb_if.b2a_lane_perturb_en[pi]
                         ? tb_if.b2a_lane_perturb_val[pi]
                         : b_pad_tx[pi];
    end
  endgenerate

  // ---------------------------------------------------------------
  // BRINGUP_REPORT.md §9 — per-lane bit-slip skid block (asymmetric skew).
  //
  // After the perturb mux but before the cross-wired RX feed, insert a
  // pad_skid_lanes module on each direction. The skid amounts are driven
  // from tb_if.{a2b,b2a}_skid_bits_per_lane (default all-zero =
  // passthrough). Tests opt in by setting these before init_system().
  // ---------------------------------------------------------------
  wire                       a2b_pad_clk_skid;
  wire [NUM_PHY_LANES-1:0]   a2b_pad_skid;
  wire                       b2a_pad_clk_skid;
  wire [NUM_PHY_LANES-1:0]   b2a_pad_skid;

  pad_skid_lanes #(.LANES(NUM_PHY_LANES)) u_skid_a2b (
    .pad_clk_in        (a_pad_clk_tx),
    .pad_data_in       (a2b_pad),
    .skid_bits_per_lane(tb_if.a2b_skid_bits_per_lane),
    .pad_clk_out       (a2b_pad_clk_skid),
    .pad_data_out      (a2b_pad_skid)
  );

  pad_skid_lanes #(.LANES(NUM_PHY_LANES)) u_skid_b2a (
    .pad_clk_in        (b_pad_clk_tx),
    .pad_data_in       (b2a_pad),
    .skid_bits_per_lane(tb_if.b2a_skid_bits_per_lane),
    .pad_clk_out       (b2a_pad_clk_skid),
    .pad_data_out      (b2a_pad_skid)
  );

  // A TX pads -> B RX pads, B TX pads -> A RX pads (perturb + skid hooks)
  wire                       a_pad_clk_rx = b2a_pad_clk_skid;
  wire [NUM_PHY_LANES-1:0]   a_pad_rx     = b2a_pad_skid;
  wire                       b_pad_clk_rx = a2b_pad_clk_skid;
  wire [NUM_PHY_LANES-1:0]   b_pad_rx     = a2b_pad_skid;

  // Mirror pad values into tb_if so UVM tests can assert on them without
  // reaching across module boundaries from inside a uvm_pkg context.
  assign tb_if.a_pad_tx_obs = a_pad_tx;
  assign tb_if.b_pad_tx_obs = b_pad_tx;

  // ---------------------------------------------------------------
  // §9 per-lane training-pattern lane-lock checkers — one per side.
  // Driven by the deserialised lane data at each side's WavD2DGpio.
  // ---------------------------------------------------------------
  wire [127:0] a_rx_lane_data = u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.io_link_rx_rx_link_data;
  wire         a_rx_link_clk  = u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.io_link_rx_rx_link_clk;
  wire [127:0] b_rx_lane_data = u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.io_link_rx_rx_link_data;
  wire         b_rx_link_clk  = u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.io_link_rx_rx_link_clk;

  wire a_checker_rst = ~poresetn;
  wire b_checker_rst = ~poresetn;

  wire [7:0] a_lane_locked_w;
  wire [7:0] b_lane_locked_w;

  tidelink_lane_checker u_a_checker (
    .clk        (a_rx_link_clk),
    .rst        (a_checker_rst),
    .lane_data  (a_rx_lane_data),
    .lane_locked(a_lane_locked_w)
  );

  tidelink_lane_checker u_b_checker (
    .clk        (b_rx_link_clk),
    .rst        (b_checker_rst),
    .lane_data  (b_rx_lane_data),
    .lane_locked(b_lane_locked_w)
  );

  assign tb_if.a_lane_locked = a_lane_locked_w;
  assign tb_if.b_lane_locked = b_lane_locked_w;

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

    // PHC clock + reset (tied off — PHC not exercised in this tb)
    .phc_clk              (clk),
    .phc_resetn           (rst_n),
    .phc_nanoseconds      (30'h0),
    .phc_seconds          (48'h0),
    .phc_pps              (1'b0),
    .phc_hw_cap_seconds   (48'h0),
    .phc_hw_cap_nanoseconds(30'h0),
    .phc_hw_cap_sub_nanoseconds(32'h0),

    // PTP AHB write port (tied off — PTP not exercised)
    .ahb_ptp_hsel         (1'b0),
    .ahb_ptp_haddr        (4'h0),
    .ahb_ptp_htrans       (2'b00),
    .ahb_ptp_hsize        (3'h0),
    .ahb_ptp_hwrite       (1'b0),
    .ahb_ptp_hwdata       (32'h0),
    .ahb_ptp_hready       (1'b1),

    // TideChart axis (tied off — TideChart not exercised, drive defined zeros
    // so the FC arbiter doesn't see X on tc_qos_priority / tx_tvalid which
    // propagates to sideband_grant and onto Wlink TX data path).
    .tc_axis_tx_tvalid    (1'b0),
    .tc_axis_tx_tdata     ({FC_DATA_W{1'b0}}),
    .tc_axis_rx_tready    (1'b1),
    .tc_qos_priority      (3'h0),
    .tl_bcast_ack_i       (1'b0),
    .apb_debug_unlock_i   (tb_if.a_apb_debug_unlock),
    .mask_hs_bypass_i     (tb_if.a_mask_hs_bypass),

    // Negotiation / PUF (tied off — autoneg not exercised in this tb)
    .nego_priority_i      (16'h0),
    .puf_seed             (16'h0),
    .puf_ready            (1'b0),

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

    // PHC clock + reset (tied off — PHC not exercised in this tb)
    .phc_clk              (clk),
    .phc_resetn           (rst_n),
    .phc_nanoseconds      (30'h0),
    .phc_seconds          (48'h0),
    .phc_pps              (1'b0),
    .phc_hw_cap_seconds   (48'h0),
    .phc_hw_cap_nanoseconds(30'h0),
    .phc_hw_cap_sub_nanoseconds(32'h0),

    // PTP AHB write port (tied off)
    .ahb_ptp_hsel         (1'b0),
    .ahb_ptp_haddr        (4'h0),
    .ahb_ptp_htrans       (2'b00),
    .ahb_ptp_hsize        (3'h0),
    .ahb_ptp_hwrite       (1'b0),
    .ahb_ptp_hwdata       (32'h0),
    .ahb_ptp_hready       (1'b1),

    // TideChart axis (tied off — drive defined zeros so the FC arbiter
    // doesn't see X on tc_qos_priority / tx_tvalid which would propagate
    // through sideband_grant onto the Wlink TX data path).
    .tc_axis_tx_tvalid    (1'b0),
    .tc_axis_tx_tdata     ({FC_DATA_W{1'b0}}),
    .tc_axis_rx_tready    (1'b1),
    .tc_qos_priority      (3'h0),
    .tl_bcast_ack_i       (1'b0),
    .apb_debug_unlock_i   (tb_if.b_apb_debug_unlock),
    .mask_hs_bypass_i     (tb_if.b_mask_hs_bypass),

    // Negotiation / PUF (tied off)
    .nego_priority_i      (16'h0),
    .puf_seed             (16'h0),
    .puf_ready            (1'b0),

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

  // For manager ports: DUT drives request signals out (haddr, hwdata, …)
  // and the VIP slave drives the response back in (hrdata, hresp, hready).
  //
  // HREADY direction fix: the previous macro fed DUT_HREADY into the slave
  // VIP (hready_in) as if the DUT generated it — but AHB hready flows
  // slave→manager, so DUT_HREADY is a DUT INPUT. We now drive it from the
  // slave VIP's hready output, and tie slave_if[0].hready_in to the same
  // value (single-slave bus, no upstream hready mux).
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
  // ---------------------------------------------------------------
  // SoC Labs (debug A→B data flow): probes on TX/RX FC paths and B
  // FIFO write enables to find where data gets lost.
  // ---------------------------------------------------------------
  // A: FC adapter TX side
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_fc_adapter.tl_fc_a2l_valid &&
        u_tidelink_top_a.u_fc_adapter.tl_fc_a2l_ready) begin
      $display("[PROBE_ATX] T=%0t  A.fc_a2l: data=0x%012h type=%0d addr=0x%04h payload=0x%08h",
               $time,
               u_tidelink_top_a.u_fc_adapter.tl_fc_a2l_data,
               u_tidelink_top_a.u_fc_adapter.tl_fc_a2l_data[47:46],
               u_tidelink_top_a.u_fc_adapter.tl_fc_a2l_data[45:32],
               u_tidelink_top_a.u_fc_adapter.tl_fc_a2l_data[31:0]);
    end
  end
  // A: Wlink TideLink TL TX OUT (post-FCSM, into data link layer)
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_advance) begin
      $display("[PROBE_ATX_TL] T=%0t  A.tx_out sop=%0d data_id=0x%02h wc=%0d data=0x%014h",
               $time,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_sop,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_data_id,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_word_count,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_data);
    end
  end
  // B: Wlink TideLink TL RX IN (pre-FCSM, from data link layer)
  always @(posedge clk) begin
    if (u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_valid) begin
      $display("[PROBE_BRX_TL] T=%0t  B.rx_in sop=%0d data_id=0x%02h wc=%0d data=0x%014h",
               $time,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_sop,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_data_id,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_word_count,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_data);
    end
  end
  // B: Wlink TideLink TL TX OUT (B's own outgoing, mostly should be cr_pkts)
  always @(posedge clk) begin
    if (u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_advance) begin
      $display("[PROBE_BTX_TL] T=%0t  B.tx_out sop=%0d data_id=0x%02h wc=%0d data=0x%014h",
               $time,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_sop,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_data_id,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_word_count,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_tx_out_data);
    end
  end
  // A: Wlink TideLink TL RX IN (A's own incoming, B->A path)
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_valid) begin
      $display("[PROBE_ARX_TL] T=%0t  A.rx_in sop=%0d data_id=0x%02h wc=%0d data=0x%014h",
               $time,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_sop,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_data_id,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_word_count,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_data);
    end
  end
  // A: TX aperture AHB writes (slave side)
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_fc_adapter.ahb_tx_hsel &&
        u_tidelink_top_a.u_fc_adapter.ahb_tx_htrans[1] &&
        u_tidelink_top_a.u_fc_adapter.ahb_tx_hwrite &&
        u_tidelink_top_a.u_fc_adapter.ahb_tx_hready) begin
      $display("[PROBE_ATX_AHB] T=%0t  A.tx_aperture addr=0x%04h hready=%0d",
               $time, u_tidelink_top_a.u_fc_adapter.ahb_tx_haddr,
               u_tidelink_top_a.u_fc_adapter.ahb_tx_hready);
    end
  end
  // A: TX aperture data phase
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_fc_adapter.tx_data_phase_r) begin
      $display("[PROBE_ATX_DATA] T=%0t  A.tx_data_phase tx_addr_r=0x%04h hwdata=0x%08h skid_can_accept=%0d sb_grant=%0d tx_fc_valid=%0d",
               $time, u_tidelink_top_a.u_fc_adapter.tx_addr_r,
               u_tidelink_top_a.u_fc_adapter.ahb_tx_hwdata,
               u_tidelink_top_a.u_fc_adapter.skid_can_accept,
               u_tidelink_top_a.u_fc_adapter.sideband_grant,
               u_tidelink_top_a.u_fc_adapter.tx_fc_valid);
    end
  end
  // B: FC adapter RX side
  always @(posedge clk) begin
    if (u_tidelink_top_b.u_fc_adapter.tl_fc_l2a_valid &&
        u_tidelink_top_b.u_fc_adapter.tl_fc_l2a_accept) begin
      $display("[PROBE_BRX] T=%0t  B.fc_l2a: data=0x%012h type=%0d addr=0x%04h payload=0x%08h",
               $time,
               u_tidelink_top_b.u_fc_adapter.tl_fc_l2a_data,
               u_tidelink_top_b.u_fc_adapter.tl_fc_l2a_data[47:46],
               u_tidelink_top_b.u_fc_adapter.tl_fc_l2a_data[45:32],
               u_tidelink_top_b.u_fc_adapter.tl_fc_l2a_data[31:0]);
    end
  end
  // B: FIFO direct write fired
  always @(posedge clk) begin
    if (u_tidelink_top_b.u_fc_adapter.fc_rx_fifo_valid &&
        u_tidelink_top_b.u_fc_adapter.fc_rx_fifo_ready) begin
      $display("[PROBE_BFIFO_WR] T=%0t  B.fc_wr addr=0x%04h wdata=0x%08h",
               $time,
               u_tidelink_top_b.u_fc_adapter.fc_rx_fifo_addr,
               u_tidelink_top_b.u_fc_adapter.fc_rx_fifo_wdata);
    end
  end
  // A: returner state and pending
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_tidelink_fifo.u_returner.state_r != 2'b00) begin
      $display("[PROBE_ARTN] T=%0t  A.returner state=%0d busy=%0d pend0=%0d pend1=%0d pend2=%0d addr=0x%08h data=0x%08h hready=%0d",
               $time,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.state_r,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.busy,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.pending_0,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.pending_1,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.pending_2,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.haddr,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.hwdata,
               u_tidelink_top_a.u_tidelink_fifo.u_returner.hready);
    end
  end
  // ---------------------------------------------------------------
  // SoC Labs (2026-05-08): TideLink FCSM diagnostic — periodically print
  // FCSM state + cr/crack_pkt_seen on both sides so we can pinpoint the
  // SHORTCOMINGS 14b bug (cr_pkt_seen_rx never asserts -> SEND_CREDITS1
  // stuck) inside UVM test_top_autoneg_basic.
  // ---------------------------------------------------------------
  // Snapshot A's FCSM state during the 195-200us SB_A2B window
  initial begin
    #195_000;
    $display("[SOCLABS_DIAG_PRE195] T=%0t  A.tlfcsm: state=%0d cr_seen_rx=%0d crack_seen_rx=%0d",
             $time,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
    $display("[SOCLABS_DIAG_PRE195] T=%0t  B.tlfcsm: state=%0d cr_seen_rx=%0d crack_seen_rx=%0d",
             $time,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
  end

  // FCSM state-change tracker on both sides
  logic [2:0] a_tlfcsm_state_prev;
  logic [2:0] b_tlfcsm_state_prev;
  always @(posedge clk) begin
    if (!rst_n) begin
      a_tlfcsm_state_prev <= 3'h0;
      b_tlfcsm_state_prev <= 3'h0;
    end else begin
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state !== a_tlfcsm_state_prev) begin
        $display("[PROBE_AFCSM] T=%0t  A.tlfcsm: %0d -> %0d cr_seen_rx=%0d crack_seen_rx=%0d",
                 $time,
                 a_tlfcsm_state_prev,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
        a_tlfcsm_state_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state;
      end
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state !== b_tlfcsm_state_prev) begin
        $display("[PROBE_BFCSM] T=%0t  B.tlfcsm: %0d -> %0d cr_seen_rx=%0d crack_seen_rx=%0d",
                 $time,
                 b_tlfcsm_state_prev,
                 u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
                 u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
                 u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
        b_tlfcsm_state_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state;
      end
    end
  end

  // ---------------------------------------------------------------
  // 5-level RX-path tracing: trace upstream of tl2wl rx_in_valid on A & B
  //   L1: tl2wl_auto_wlink_tidelinktl_rx_in_valid (FCSM TL channel input)
  //   L2: rxrouter_auto_out_7_valid                 (router output for TL)
  //   L3: rxrouter_auto_in_valid (== llrx_auto_out_valid)
  //   L4: WlinkRxLinkLayer.state[1:0] (LL_RX FSM)
  //   L5: llrx_io_link_data (deserialiser output, 128-bit)
  // ---------------------------------------------------------------

  // Counters / sticky-seen flags so we can summarise after the run
  integer a_l1_cnt; integer a_l2_cnt; integer a_l3_cnt;
  integer b_l1_cnt; integer b_l2_cnt; integer b_l3_cnt;
  reg     a_llrx_left_idle; reg b_llrx_left_idle;
  reg     a_link_data_nz_seen; reg b_link_data_nz_seen;
  reg [1:0] a_llrx_state_prev, b_llrx_state_prev;

  // Limit print rate
  integer a_l1_prints, a_l2_prints, a_l3_prints;
  integer b_l1_prints, b_l2_prints, b_l3_prints;
  integer a_data_prints, b_data_prints;

  initial begin
    a_l1_cnt = 0; a_l2_cnt = 0; a_l3_cnt = 0;
    b_l1_cnt = 0; b_l2_cnt = 0; b_l3_cnt = 0;
    a_llrx_left_idle = 1'b0; b_llrx_left_idle = 1'b0;
    a_link_data_nz_seen = 1'b0; b_link_data_nz_seen = 1'b0;
    a_llrx_state_prev = 2'h0; b_llrx_state_prev = 2'h0;
    a_l1_prints = 0; a_l2_prints = 0; a_l3_prints = 0;
    b_l1_prints = 0; b_l2_prints = 0; b_l3_prints = 0;
    a_data_prints = 0; b_data_prints = 0;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      // === A side ===
      // L1
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_valid) begin
        a_l1_cnt <= a_l1_cnt + 1;
        if (a_l1_prints < 5) begin
          $display("[PROBE_ARX_L1] T=%0t  A.tl2wl_rx_in_valid=1 (count=%0d)",
                   $time, a_l1_cnt);
          a_l1_prints <= a_l1_prints + 1;
        end
      end
      // L2
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.rxrouter_auto_out_7_valid) begin
        a_l2_cnt <= a_l2_cnt + 1;
        if (a_l2_prints < 5) begin
          $display("[PROBE_ARX_L2] T=%0t  A.rxrouter_auto_out_7_valid=1 (count=%0d)",
                   $time, a_l2_cnt);
          a_l2_prints <= a_l2_prints + 1;
        end
      end
      // L3
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.rxrouter_auto_in_valid) begin
        a_l3_cnt <= a_l3_cnt + 1;
        if (a_l3_prints < 5) begin
          $display("[PROBE_ARX_L3] T=%0t  A.rxrouter_auto_in_valid=1 (llrx_auto_out_valid) (count=%0d) data_id=0x%02h sop=%0d",
                   $time, a_l3_cnt,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_auto_out_data_id,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_auto_out_sop);
          a_l3_prints <= a_l3_prints + 1;
        end
      end
      // L4 — LL_RX state changes
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.state !== a_llrx_state_prev) begin
        $display("[PROBE_ARX_L4] T=%0t  A.llrx.state %0d -> %0d  link_data=0x%032h",
                 $time, a_llrx_state_prev,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.state,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data);
        a_llrx_state_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.state;
        if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.state != 2'h0) a_llrx_left_idle <= 1'b1;
      end
      // L5 — link_data non-zero (deserialiser activity)
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data != 128'h0) begin
        if (!a_link_data_nz_seen) begin
          $display("[PROBE_ARX_L5_FIRST] T=%0t  A.llrx_io_link_data first non-zero = 0x%032h  enable=%0d active_lanes=0x%02h lane_mask=0x%02h",
                   $time,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_enable,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_active_lanes,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_lane_mask);
          a_link_data_nz_seen <= 1'b1;
        end
        if (a_data_prints < 8) begin
          $display("[PROBE_ARX_L5] T=%0t  A.llrx_io_link_data=0x%032h",
                   $time, u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data);
          a_data_prints <= a_data_prints + 1;
        end
      end

      // === B side ===
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl_auto_wlink_tidelinktl_rx_in_valid) begin
        b_l1_cnt <= b_l1_cnt + 1;
        if (b_l1_prints < 5) begin
          $display("[PROBE_BRX_L1] T=%0t  B.tl2wl_rx_in_valid=1 (count=%0d)",
                   $time, b_l1_cnt);
          b_l1_prints <= b_l1_prints + 1;
        end
      end
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.rxrouter_auto_out_7_valid) begin
        b_l2_cnt <= b_l2_cnt + 1;
        if (b_l2_prints < 5) begin
          $display("[PROBE_BRX_L2] T=%0t  B.rxrouter_auto_out_7_valid=1 (count=%0d)",
                   $time, b_l2_cnt);
          b_l2_prints <= b_l2_prints + 1;
        end
      end
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.rxrouter_auto_in_valid) begin
        b_l3_cnt <= b_l3_cnt + 1;
        if (b_l3_prints < 5) begin
          $display("[PROBE_BRX_L3] T=%0t  B.rxrouter_auto_in_valid=1 (count=%0d) data_id=0x%02h sop=%0d",
                   $time, b_l3_cnt,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_auto_out_data_id,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_auto_out_sop);
          b_l3_prints <= b_l3_prints + 1;
        end
      end
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.state !== b_llrx_state_prev) begin
        $display("[PROBE_BRX_L4] T=%0t  B.llrx.state %0d -> %0d  link_data=0x%032h",
                 $time, b_llrx_state_prev,
                 u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.state,
                 u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data);
        b_llrx_state_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.state;
        if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.state != 2'h0) b_llrx_left_idle <= 1'b1;
      end
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data != 128'h0) begin
        if (!b_link_data_nz_seen) begin
          $display("[PROBE_BRX_L5_FIRST] T=%0t  B.llrx_io_link_data first non-zero = 0x%032h  enable=%0d active_lanes=0x%02h lane_mask=0x%02h",
                   $time,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_enable,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_active_lanes,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_lane_mask);
          b_link_data_nz_seen <= 1'b1;
        end
        if (b_data_prints < 8) begin
          $display("[PROBE_BRX_L5] T=%0t  B.llrx_io_link_data=0x%032h",
                   $time, u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data);
          b_data_prints <= b_data_prints + 1;
        end
      end
    end
  end

  // Track link_data changes — count distinct values per side
  reg [127:0] a_link_data_prev, b_link_data_prev;
  integer a_link_data_changes, b_link_data_changes;
  integer a_valid_count, b_valid_count;
  integer a_short_count, b_short_count;
  integer a_long_count, b_long_count;
  integer a_corrupt_count, b_corrupt_count;
  integer a_change_prints, b_change_prints;
  initial begin
    a_link_data_prev = 128'h0; b_link_data_prev = 128'h0;
    a_link_data_changes = 0; b_link_data_changes = 0;
    a_valid_count = 0; b_valid_count = 0;
    a_short_count = 0; b_short_count = 0;
    a_long_count = 0; b_long_count = 0;
    a_corrupt_count = 0; b_corrupt_count = 0;
    a_change_prints = 0; b_change_prints = 0;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      // A: link_data change detection (sampling on clk; aliased view of rx_link_clk domain)
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data !== a_link_data_prev) begin
        a_link_data_changes <= a_link_data_changes + 1;
        if (a_change_prints < 12) begin
          $display("[PROBE_ARX_LDCHG] T=%0t  A.link_data: 0x%032h -> 0x%032h",
                   $time, a_link_data_prev,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data);
          a_change_prints <= a_change_prints + 1;
        end
        a_link_data_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data;
      end
      // A: LL_RX internals
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.valid) a_valid_count <= a_valid_count + 1;
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.is_short_pkt) a_short_count <= a_short_count + 1;
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.is_long_pkt)  a_long_count  <= a_long_count + 1;
      if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.ecc_check_corrupted) a_corrupt_count <= a_corrupt_count + 1;

      // B: link_data change detection
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data !== b_link_data_prev) begin
        b_link_data_changes <= b_link_data_changes + 1;
        if (b_change_prints < 12) begin
          $display("[PROBE_BRX_LDCHG] T=%0t  B.link_data: 0x%032h -> 0x%032h",
                   $time, b_link_data_prev,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data);
          b_change_prints <= b_change_prints + 1;
        end
        b_link_data_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_link_data;
      end
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.valid) b_valid_count <= b_valid_count + 1;
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.is_short_pkt) b_short_count <= b_short_count + 1;
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.is_long_pkt)  b_long_count  <= b_long_count + 1;
      if (u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx.ecc_check_corrupted) b_corrupt_count <= b_corrupt_count + 1;
    end
  end

  // ---------------------------------------------------------------
  // PROBE_TXRX_DIFF: Cycle-by-cycle compare of B.phy_link_tx_tx_link_data
  // (B's LL_TX framer output, going into the GPIO PHY) vs
  // A.llrx_io_link_data (deserialiser output on A's RX path).
  //
  // Goal: determine whether the bug is in B's LL_TX framer or in
  // the loopback/deserialiser path. Prints whenever either signal
  // changes, with a print cap to keep log volume bounded. Also
  // captures the first non-zero transition timestamps for both.
  // ---------------------------------------------------------------
  reg [127:0] btx_link_data_prev;
  reg [127:0] arx_link_data_prev;
  reg         btx_first_seen;
  reg         arx_first_seen;
  integer     btx_first_t;
  integer     arx_first_t;
  integer     diff_prints;
  integer     diff_cycle_cnt;
  integer     diff_match_cnt;
  integer     diff_mismatch_cnt;
  integer     diff_first_mismatch_t;
  reg [127:0] diff_first_mismatch_btx;
  reg [127:0] diff_first_mismatch_arx;

  initial begin
    btx_link_data_prev = 128'h0;
    arx_link_data_prev = 128'h0;
    btx_first_seen     = 1'b0;
    arx_first_seen     = 1'b0;
    btx_first_t        = 0;
    arx_first_t        = 0;
    diff_prints        = 0;
    diff_cycle_cnt     = 0;
    diff_match_cnt     = 0;
    diff_mismatch_cnt  = 0;
    diff_first_mismatch_t   = 0;
    diff_first_mismatch_btx = 128'h0;
    diff_first_mismatch_arx = 128'h0;
  end

  // Sample on the free-running test clk (same as other PROBE_*_LDCHG
  // blocks). This aliases the link_clk domains but is sufficient to
  // expose any persistent value mismatch since link_data is held on
  // each lltx/llrx cycle.
  always @(posedge clk) begin
    if (rst_n) begin
      // First non-zero TX (B) sighting
      if (!btx_first_seen &&
          (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data != 128'h0)) begin
        btx_first_seen <= 1'b1;
        btx_first_t    <= $time;
        $display("[PROBE_TXRX_DIFF_BTX_FIRST] T=%0t  B.phy_link_tx_tx_link_data first non-zero = 0x%032h",
                 $time,
                 u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data);
      end
      // First non-zero RX (A) sighting (already captured elsewhere but
      // recorded here too for direct comparison in the same block)
      if (!arx_first_seen &&
          (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data != 128'h0)) begin
        arx_first_seen <= 1'b1;
        arx_first_t    <= $time;
        $display("[PROBE_TXRX_DIFF_ARX_FIRST] T=%0t  A.llrx_io_link_data first non-zero = 0x%032h",
                 $time,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data);
      end

      // Cycle-by-cycle pair logging — print whenever EITHER side's
      // link_data changes value, capped to 200 lines so we cover the
      // first ~5us of corruption without flooding.
      if (((u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data !== btx_link_data_prev) ||
           (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data       !== arx_link_data_prev)) &&
          (btx_first_seen || arx_first_seen)) begin
        diff_cycle_cnt <= diff_cycle_cnt + 1;
        if (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data ===
            u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data) begin
          diff_match_cnt <= diff_match_cnt + 1;
        end else begin
          diff_mismatch_cnt <= diff_mismatch_cnt + 1;
          if (diff_mismatch_cnt == 0) begin
            diff_first_mismatch_t   <= $time;
            diff_first_mismatch_btx <= u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data;
            diff_first_mismatch_arx <= u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data;
          end
        end
        if (diff_prints < 200) begin
          $display("[PROBE_TXRX_DIFF] T=%0t  B.tx=0x%032h  A.rx=0x%032h  %s",
                   $time,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data,
                   (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data ===
                    u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data) ? "MATCH" : "DIFF");
          diff_prints <= diff_prints + 1;
        end
        btx_link_data_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.phy_link_tx_tx_link_data;
        arx_link_data_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data;
      end
    end
  end

  final begin
    $display("[PROBE_TXRX_DIFF_SUMMARY] btx_first_t=%0t arx_first_t=%0t cycles=%0d match=%0d mismatch=%0d",
             btx_first_t, arx_first_t, diff_cycle_cnt, diff_match_cnt, diff_mismatch_cnt);
    if (diff_mismatch_cnt > 0) begin
      $display("[PROBE_TXRX_DIFF_FIRST_MISMATCH] T=%0t  B.tx=0x%032h  A.rx=0x%032h",
               diff_first_mismatch_t, diff_first_mismatch_btx, diff_first_mismatch_arx);
    end
  end

  // Final summary at end of sim
  final begin
    $display("[PROBE_RXSUMMARY] A: L1_cnt=%0d L2_cnt=%0d L3_cnt=%0d llrx_left_idle=%0d link_data_nz_seen=%0d",
             a_l1_cnt, a_l2_cnt, a_l3_cnt, a_llrx_left_idle, a_link_data_nz_seen);
    $display("[PROBE_RXSUMMARY] B: L1_cnt=%0d L2_cnt=%0d L3_cnt=%0d llrx_left_idle=%0d link_data_nz_seen=%0d",
             b_l1_cnt, b_l2_cnt, b_l3_cnt, b_llrx_left_idle, b_link_data_nz_seen);
    $display("[PROBE_RXSUMMARY] A: link_data_changes=%0d valid_cnt=%0d short_cnt=%0d long_cnt=%0d corrupt_cnt=%0d",
             a_link_data_changes, a_valid_count, a_short_count, a_long_count, a_corrupt_count);
    $display("[PROBE_RXSUMMARY] B: link_data_changes=%0d valid_cnt=%0d short_cnt=%0d long_cnt=%0d corrupt_cnt=%0d",
             b_link_data_changes, b_valid_count, b_short_count, b_long_count, b_corrupt_count);
    $display("[PROBE_RXSUMMARY] A.llrx_io_enable=%0d active_lanes=0x%02h lane_mask=0x%02h",
             u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_enable,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_active_lanes,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_lane_mask);
    $display("[PROBE_RXSUMMARY] B.llrx_io_enable=%0d active_lanes=0x%02h lane_mask=0x%02h",
             u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_enable,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_active_lanes,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_lane_mask);
    // TX-side mask configuration (driving the wire that A receives)
    $display("[PROBE_RXSUMMARY] A.lltx_active_lanes=0x%02h tx_lane_mask=0x%02h short_pkt_max=0x%02h",
             u_tidelink_top_a.u_chiplet_controller.u_wlink.lltx_io_active_lanes,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.lltx_io_lane_mask,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_swi_short_packet_max);
    $display("[PROBE_RXSUMMARY] B.lltx_active_lanes=0x%02h tx_lane_mask=0x%02h short_pkt_max=0x%02h",
             u_tidelink_top_b.u_chiplet_controller.u_wlink.lltx_io_active_lanes,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.lltx_io_lane_mask,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.llrx_io_swi_short_packet_max);
  end

  initial begin
    #150_000;  // 150 ns — earliest sample (autoneg likely still in progress)
    $display("[SOCLABS_DIAG_T0] T=%0t", $time);
    #150_000_000;  // 150 us — past autoneg, before SB_A2B traffic
    $display("[SOCLABS_DIAG] T=%0t  A.tlfcsm: state=%0d cr_seen_rx=%0d crack_seen_rx=%0d",
             $time,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
    $display("[SOCLABS_DIAG] T=%0t  B.tlfcsm: state=%0d cr_seen_rx=%0d crack_seen_rx=%0d",
             $time,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
    #150_000_000;  // 300 us — during/after SB_A2B traffic
    $display("[SOCLABS_DIAG] T=%0t  A.tlfcsm: state=%0d cr_seen_rx=%0d crack_seen_rx=%0d",
             $time,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
    $display("[SOCLABS_DIAG] T=%0t  B.tlfcsm: state=%0d cr_seen_rx=%0d crack_seen_rx=%0d",
             $time,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.state,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.cr_pkt_seen_rx,
             u_tidelink_top_b.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.crack_pkt_seen_rx);
  end

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
  // [PROBE_AECC] Dump ph_in / rx_ecc / calc_ecc / link_data on every
  // ECC-corruption event observed by A's WlinkRxLinkLayer.  Limit the
  // print volume so the log stays readable — first 40 events only.
  // =================================================================
  integer a_ecc_dump_count;
  initial a_ecc_dump_count = 0;
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.ecc_check_corrupted) begin
      if (a_ecc_dump_count < 40) begin
        $display("[PROBE_AECC] T=%0t  ph_in=0x%06h  rx_ecc=0x%02h  calc_ecc=0x%02h  link_data=0x%032h",
                 $time,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.ecc_check_ph_in,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.ecc_check_rx_ecc,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx.ecc_check_calc_ecc,
                 u_tidelink_top_a.u_chiplet_controller.u_wlink.llrx_io_link_data);
        a_ecc_dump_count <= a_ecc_dump_count + 1;
      end
    end
  end

  // =================================================================
  // [PROBE_GPIO_RST] Print A.gpiorx_0 io_por_reset every time it changes
  // and toggle-sample A.gpiorx_0 io_pad_clk to see if it's actually
  // toggling. A's rx_count being stuck at 15 means either reset is
  // held active or pad_clk isn't toggling.
  // =================================================================
  reg a_gpiorx0_por_prev, b_gpiorx0_por_prev;
  reg a_gpiotx0_por_prev, b_gpiotx0_por_prev;
  reg a_gpiorx0_padclk_prev;
  integer a_gpiorx0_padclk_toggles;
  initial begin
    a_gpiorx0_por_prev = 1'b1;
    b_gpiorx0_por_prev = 1'b1;
    a_gpiotx0_por_prev = 1'b1;
    b_gpiotx0_por_prev = 1'b1;
    a_gpiorx0_padclk_prev = 1'b0;
    a_gpiorx0_padclk_toggles = 0;
  end
  always @(posedge clk) begin
    if (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset !== a_gpiorx0_por_prev) begin
      $display("[PROBE_GPIO_RST] T=%0t  A.gpiorx_0.io_por_reset: %b -> %b",
               $time, a_gpiorx0_por_prev,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset);
      a_gpiorx0_por_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset;
    end
    if (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset !== b_gpiorx0_por_prev) begin
      $display("[PROBE_GPIO_RST] T=%0t  B.gpiorx_0.io_por_reset: %b -> %b",
               $time, b_gpiorx0_por_prev,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset);
      b_gpiorx0_por_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset;
    end
    if (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.io_reset !== a_gpiotx0_por_prev) begin
      $display("[PROBE_GPIO_RST] T=%0t  A.gpiotx_0.io_reset: %b -> %b",
               $time, a_gpiotx0_por_prev,
               u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.io_reset);
      a_gpiotx0_por_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.io_reset;
    end
    if (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.io_reset !== b_gpiotx0_por_prev) begin
      $display("[PROBE_GPIO_RST] T=%0t  B.gpiotx_0.io_reset: %b -> %b",
               $time, b_gpiotx0_por_prev,
               u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.io_reset);
      b_gpiotx0_por_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.io_reset;
    end
    if (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_pad_clk !== a_gpiorx0_padclk_prev) begin
      a_gpiorx0_padclk_toggles <= a_gpiorx0_padclk_toggles + 1;
      a_gpiorx0_padclk_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_pad_clk;
    end
  end
  final begin
    $display("[PROBE_GPIO_RST_SUMMARY] A.gpiorx_0.io_pad_clk total toggles=%0d  final_por=%b  final_padclk=%b",
             a_gpiorx0_padclk_toggles,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_por_reset,
             u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_pad_clk);
  end

  // =================================================================
  // [PROBE_GPIO_COUNT] Compare WavD2DGpio counter alignment between
  // B's serialiser (gpiotx_0) and A's deserialiser (gpiorx_0). The
  // 5-bit-shift relationship observed in PROBE_TXRX_DIFF could be a
  // reset-time counter offset between TX and RX. If so, A.rx.count
  // vs B.tx.count will show a fixed delta.
  //
  // Both counters increment by 1 each pad_clk cycle; in this dual-DUT
  // simulation pad_clk_rx is wired from B.tx out to A.rx in. So at the
  // pad_clk edge they should track with a known phase relationship.
  //
  // Print first 40 changes plus a final summary of (a_count - b_count)
  // mod 16 to see if the offset is constant.
  // =================================================================
  integer gpio_cnt_prints;
  integer gpio_cnt_changes;
  reg [3:0] a_rx_cnt_prev;
  reg [3:0] b_tx_cnt_prev;
  integer gpio_cnt_offset_hist[0:15];
  integer i_gpio_init;
  initial begin
    gpio_cnt_prints  = 0;
    gpio_cnt_changes = 0;
    a_rx_cnt_prev    = 4'hf;
    b_tx_cnt_prev    = 4'hf;
    for (i_gpio_init = 0; i_gpio_init < 16; i_gpio_init = i_gpio_init + 1)
      gpio_cnt_offset_hist[i_gpio_init] = 0;
  end
  always @(posedge u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_pad_clk) begin
    if (rst_n) begin
      // Sample current counters via hierarchical refs (on A's RX pad clk)
      if ((u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count !== a_rx_cnt_prev) ||
          (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count !== b_tx_cnt_prev)) begin
        gpio_cnt_changes <= gpio_cnt_changes + 1;
        // Histogram the (a_rx - b_tx) mod 16 offset
        gpio_cnt_offset_hist[
          (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count -
           u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count) & 4'hf
        ] <= gpio_cnt_offset_hist[
          (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count -
           u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count) & 4'hf
        ] + 1;
        // Skip prints during initial reset hold (POR releases ~44us)
        if (gpio_cnt_prints < 80 && $time > 50_000_000) begin
          $display("[PROBE_GPIO_COUNT] T=%0t  A.rx_count=%0d  B.tx_count=%0d  (a-b)mod16=%0d",
                   $time,
                   u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count,
                   u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count,
                   (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count -
                    u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count) & 4'hf);
          gpio_cnt_prints <= gpio_cnt_prints + 1;
        end
        a_rx_cnt_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count;
        b_tx_cnt_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count;
      end
    end
  end
  final begin
    integer i_hist;
    $display("[PROBE_GPIO_COUNT_SUMMARY] total_changes=%0d", gpio_cnt_changes);
    for (i_hist = 0; i_hist < 16; i_hist = i_hist + 1) begin
      if (gpio_cnt_offset_hist[i_hist] != 0)
        $display("[PROBE_GPIO_COUNT_SUMMARY]   offset=%0d  count=%0d", i_hist, gpio_cnt_offset_hist[i_hist]);
    end
  end

  // Same probe for B.gpiorx_0 vs A.gpiotx_0 — to see the reverse direction
  reg [3:0] b_rx_cnt_prev;
  reg [3:0] a_tx_cnt_prev;
  integer gpio_cnt_offset_hist_b[0:15];
  integer gpio_cnt_changes_b;
  integer i_gpio_init_b;
  initial begin
    b_rx_cnt_prev = 4'hf;
    a_tx_cnt_prev = 4'hf;
    gpio_cnt_changes_b = 0;
    for (i_gpio_init_b = 0; i_gpio_init_b < 16; i_gpio_init_b = i_gpio_init_b + 1)
      gpio_cnt_offset_hist_b[i_gpio_init_b] = 0;
  end
  always @(posedge u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.io_pad_clk) begin
    if (rst_n) begin
      if ((u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count !== b_rx_cnt_prev) ||
          (u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count !== a_tx_cnt_prev)) begin
        gpio_cnt_changes_b <= gpio_cnt_changes_b + 1;
        gpio_cnt_offset_hist_b[
          (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count -
           u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count) & 4'hf
        ] <= gpio_cnt_offset_hist_b[
          (u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count -
           u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count) & 4'hf
        ] + 1;
        b_rx_cnt_prev <= u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.gpiorx_0.count;
        a_tx_cnt_prev <= u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.gpiotx_0.count;
      end
    end
  end
  final begin
    integer i_hist_b;
    $display("[PROBE_GPIO_COUNT_B_SUMMARY] total_changes=%0d (B.rx vs A.tx)", gpio_cnt_changes_b);
    for (i_hist_b = 0; i_hist_b < 16; i_hist_b = i_hist_b + 1) begin
      if (gpio_cnt_offset_hist_b[i_hist_b] != 0)
        $display("[PROBE_GPIO_COUNT_B_SUMMARY]   offset=%0d  count=%0d", i_hist_b, gpio_cnt_offset_hist_b[i_hist_b]);
    end
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

  // Power-on reset force/release. Used by tests that need to re-trigger
  // POR-domain logic (e.g. the tidelink_autoneg FSM, which sits on
  // poresetn and goes to ST_BYPASS on the first cycle if nego_en isn't
  // already 1 — re-arming requires a poreset pulse).
  always @(*) begin
    if (tb_if.force_poreset)
      force poresetn = 1'b0;
    else
      release poresetn;
  end

  // -----------------------------------------------------------------
  // BRINGUP_REPORT.md §9 — soft-strap drive for swi_bit_slip /
  // swi_training_mode on each WavD2DGpio. Tests assert the _en signal
  // and the corresponding value via tb_if; this always-block forces it
  // into the gpio module. Force/release in module context is robust
  // across VCS register-default optimisation (uvm_hdl_force can fail to
  // locate constant-default regs even with -debug_access+all).
  // -----------------------------------------------------------------
  always @(*) begin
    if (tb_if.a_align_bit_slip_en)
      force u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.swi_bit_slip = tb_if.a_align_bit_slip;
    else
      release u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.swi_bit_slip;
  end
  always @(*) begin
    if (tb_if.b_align_bit_slip_en)
      force u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.swi_bit_slip = tb_if.b_align_bit_slip;
    else
      release u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.swi_bit_slip;
  end
  always @(*) begin
    if (tb_if.a_align_training_mode_en)
      force u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.swi_training_mode = tb_if.a_align_training_mode;
    else
      release u_tidelink_top_a.u_chiplet_controller.u_wlink.phy.gpio.swi_training_mode;
  end
  always @(*) begin
    if (tb_if.b_align_training_mode_en)
      force u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.swi_training_mode = tb_if.b_align_training_mode;
    else
      release u_tidelink_top_b.u_chiplet_controller.u_wlink.phy.gpio.swi_training_mode;
  end

  // =================================================================
  // Phase 3 — I²C-train scenario injection hooks (Agent #4, RETARGETED
  // by the §9 integration: forces the REAL trunk calibrator/lane-checker
  // nets, not #4's deleted placeholder regs).
  //   swi_lane_locked_in       → lane_locked_w          (tidelink_lane_checker)
  //   swi_lane_fault_in        → cal_lane_fault_w       (tidelink_phy_align_calibrator)
  //   swi_calibration_done_in  → cal_calibration_done_w (tidelink_phy_align_calibrator)
  // Default (force_en=0) is a release; tests set the values then assert
  // force_en to lock them. Hierarchical references live in module scope
  // (not package scope) so they don't trip SV-LCM-HRP.
  // =================================================================
  always @(*) begin
    if (tb_if.a_train_force_en) begin
      force u_tidelink_top_a.u_chiplet_controller.lane_locked_w          = tb_if.a_train_lane_locked;
      force u_tidelink_top_a.u_chiplet_controller.cal_lane_fault_w       = tb_if.a_train_lane_fault;
      force u_tidelink_top_a.u_chiplet_controller.cal_calibration_done_w = tb_if.a_train_cal_done;
    end else begin
      release u_tidelink_top_a.u_chiplet_controller.lane_locked_w;
      release u_tidelink_top_a.u_chiplet_controller.cal_lane_fault_w;
      release u_tidelink_top_a.u_chiplet_controller.cal_calibration_done_w;
    end
  end

  always @(*) begin
    if (tb_if.b_train_force_en) begin
      force u_tidelink_top_b.u_chiplet_controller.lane_locked_w          = tb_if.b_train_lane_locked;
      force u_tidelink_top_b.u_chiplet_controller.cal_lane_fault_w       = tb_if.b_train_lane_fault;
      force u_tidelink_top_b.u_chiplet_controller.cal_calibration_done_w = tb_if.b_train_cal_done;
    end else begin
      release u_tidelink_top_b.u_chiplet_controller.lane_locked_w;
      release u_tidelink_top_b.u_chiplet_controller.cal_lane_fault_w;
      release u_tidelink_top_b.u_chiplet_controller.cal_calibration_done_w;
    end
  end

  // Slave I²C-slave-core disable for test_train_no_peer_response.
  always @(*) begin
    if (tb_if.b_i2c_slv_disable)
      force u_tidelink_top_b.u_chiplet_controller.i2c_slv_reset = 1'b1;
    else
      release u_tidelink_top_b.u_chiplet_controller.i2c_slv_reset;
  end

  // Mirror master-side training-status wires into tb_if (module-scope refs
  // — not allowed from package context).
  assign tb_if.a_train_state_obs             = u_tidelink_top_a.u_chiplet_controller.train_state_w;
  assign tb_if.a_train_ok_obs                = u_tidelink_top_a.u_chiplet_controller.train_ok_w;
  assign tb_if.a_train_fail_obs              = u_tidelink_top_a.u_chiplet_controller.train_fail_w;
  assign tb_if.a_train_in_progress_obs       = u_tidelink_top_a.u_chiplet_controller.train_in_progress_w;
  assign tb_if.a_train_peer_nack_obs         = u_tidelink_top_a.u_chiplet_controller.train_peer_nack_w;
  assign tb_if.a_train_peer_lane_locked_obs  = u_tidelink_top_a.u_chiplet_controller.train_peer_lane_locked_w;
  assign tb_if.a_train_peer_lane_fault_obs   = u_tidelink_top_a.u_chiplet_controller.train_peer_lane_fault_w;
  assign tb_if.a_train_local_lane_fault_obs  = u_tidelink_top_a.u_chiplet_controller.train_local_lane_fault_w;
  assign tb_if.a_nego_train_cfg_obs          = u_tidelink_top_a.u_chiplet_controller.nego_train_cfg_r;

endmodule
