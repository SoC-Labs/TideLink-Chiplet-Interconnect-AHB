///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink paired-system verification.
//
// Instantiates TWO FC adapter + FIFO subsystems connected back-to-back
// via FC crossover, simulating two chiplets communicating:
//
//   Chiplet A                              Chiplet B
//   +-----------------------+              +-----------------------+
//   | tidelink_fc_adapter   |              | tidelink_fc_adapter   |
//   |  + tidelink_fifo      |              |  + tidelink_fifo      |
//   |  + AHB-to-APB bridge  |              |  + AHB-to-APB bridge  |
//   |  + FIFO/config muxes  |              |  + FIFO/config muxes  |
//   +------+------+---------+              +------+------+---------+
//          |      |                               |      |
//     FC TX|      |FC RX                     FC TX|      |FC RX
//          |      |                               |      |
//          +------+-------------------------------+------+
//                 |          FC Crossover          |
//                 +-------------------------------+
//   A's FC TX -> B's FC RX (a2l -> l2a)
//   B's FC TX -> A's FC RX (a2l -> l2a)
//
// Per-side interfaces:
//   1. SVT AHB VIP: TX aperture AHB master (drives writes into FC adapter TX)
//   2. SVT AHB VIP: FIFO read AHB master (reads received packets from RX FIFO)
//   3. Custom APB master agent: config register access (unified APB port,
//      TideLink regs at 0x2000 offset)
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

// APB master agent interface (for config register access)
`include "apb_master_if.sv"

// System-specific interface
`include "tidelink_system_if.sv"

// Testbench package
`include "tidelink_system_pkg.sv"

module test_top;

  // ---------------------------------------------------------------
  // Clock and reset
  // ---------------------------------------------------------------
  parameter CLK_PERIOD = 10; // 100 MHz

  bit clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------
  // Package imports
  // ---------------------------------------------------------------
  import uvm_pkg::*;
  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;
  import tidelink_system_pkg::*;

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
  // Interface instances — Chiplet A
  // ---------------------------------------------------------------
  svt_ahb_if ahb_a_tx_if();
  assign ahb_a_tx_if.hclk    = clk;
  assign ahb_a_tx_if.hresetn = rst_n;

  svt_ahb_if ahb_a_fifo_if();
  assign ahb_a_fifo_if.hclk    = clk;
  assign ahb_a_fifo_if.hresetn = rst_n;

  // Config APB interface A
  apb_master_if apb_a_cfg_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // Interface instances — Chiplet B
  // ---------------------------------------------------------------
  svt_ahb_if ahb_b_tx_if();
  assign ahb_b_tx_if.hclk    = clk;
  assign ahb_b_tx_if.hresetn = rst_n;

  svt_ahb_if ahb_b_fifo_if();
  assign ahb_b_fifo_if.hclk    = clk;
  assign ahb_b_fifo_if.hresetn = rst_n;

  // Config APB interface B
  apb_master_if apb_b_cfg_if(.clk(clk), .rst_n(rst_n));

  // System-level interface for clock/reset/IRQ access
  tidelink_system_if tb_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // FC crossover wiring: A's TX -> B's RX, B's TX -> A's RX
  // ---------------------------------------------------------------
  wire                   a_fc_a2l_valid;
  wire [FC_DATA_W-1:0]  a_fc_a2l_data;
  wire                   a_fc_a2l_ready;
  wire                   a_fc_l2a_valid;
  wire [FC_DATA_W-1:0]  a_fc_l2a_data;
  wire                   a_fc_l2a_accept;

  wire                   b_fc_a2l_valid;
  wire [FC_DATA_W-1:0]  b_fc_a2l_data;
  wire                   b_fc_a2l_ready;
  wire                   b_fc_l2a_valid;
  wire [FC_DATA_W-1:0]  b_fc_l2a_data;
  wire                   b_fc_l2a_accept;

  // FC Crossover: A TX -> B RX, B TX -> A RX
  assign b_fc_l2a_valid  = a_fc_a2l_valid;
  assign b_fc_l2a_data   = a_fc_a2l_data;
  assign a_fc_a2l_ready  = b_fc_l2a_accept;

  assign a_fc_l2a_valid  = b_fc_a2l_valid;
  assign a_fc_l2a_data   = b_fc_a2l_data;
  assign b_fc_a2l_ready  = a_fc_l2a_accept;

  // =================================================================
  // CHIPLET A — FC adapter + FIFO + mux logic
  // =================================================================

  // Returner AHB master wiring
  wire [SYS_ADDR_W-1:0] a_rtn_haddr;
  wire [SYS_DATA_W-1:0] a_rtn_hwdata;
  wire            [1:0]  a_rtn_htrans;
  wire            [2:0]  a_rtn_hsize;
  wire                   a_rtn_hwrite;
  wire                   a_rtn_hready;
  wire                   a_rtn_hresp;
  wire [SYS_DATA_W-1:0] a_rtn_hrdata;

  // FC adapter RX — split AHB master wiring
  wire [RAM_ADDR_W-1:0] a_fc_rx_fifo_haddr;
  wire [SYS_DATA_W-1:0] a_fc_rx_fifo_hwdata;
  wire            [1:0]  a_fc_rx_fifo_htrans;
  wire            [2:0]  a_fc_rx_fifo_hsize;
  wire                   a_fc_rx_fifo_hwrite;
  wire                   a_fc_rx_fifo_hready;
  wire                   a_fc_rx_fifo_hresp;
  wire [SYS_DATA_W-1:0] a_fc_rx_fifo_hrdata;

  wire [APB_ADDR_W-1:0] a_fc_rx_cfg_haddr;
  wire [SYS_DATA_W-1:0] a_fc_rx_cfg_hwdata;
  wire            [1:0]  a_fc_rx_cfg_htrans;
  wire            [2:0]  a_fc_rx_cfg_hsize;
  wire                   a_fc_rx_cfg_hwrite;
  wire                   a_fc_rx_cfg_hready;
  wire                   a_fc_rx_cfg_hresp;
  wire [SYS_DATA_W-1:0] a_fc_rx_cfg_hrdata;

  // DUT output wires for Chiplet A
  wire        a_dut_tx_hreadyout;
  wire        a_dut_tx_hresp;
  wire [31:0] a_dut_tx_hrdata;
  wire        a_dut_fifo_hreadyout;
  wire        a_dut_fifo_hresp;
  wire [31:0] a_dut_fifo_hrdata;
  wire        a_released_credits_irq;
  wire        a_doorbell_irq;
  wire        a_packet_committed_irq;

  // FIFO port mux A
  wire                   a_fifo_mux_hsel;
  wire [RAM_ADDR_W-1:0] a_fifo_mux_haddr;
  wire            [1:0]  a_fifo_mux_htrans;
  wire            [2:0]  a_fifo_mux_hsize;
  wire                   a_fifo_mux_hwrite;
  wire [SYS_DATA_W-1:0] a_fifo_mux_hwdata;
  wire                   a_fifo_mux_hready;
  wire [SYS_DATA_W-1:0] a_fifo_mux_hrdata;
  wire                   a_fifo_mux_hresp;
  wire                   a_fifo_mux_hreadyout;

  wire a_fc_rx_fifo_active = a_fc_rx_fifo_htrans[1];

  assign a_fifo_mux_hsel   = a_fc_rx_fifo_active ? 1'b1              : 1'b1;
  assign a_fifo_mux_haddr  = a_fc_rx_fifo_active ? a_fc_rx_fifo_haddr  : ahb_a_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0];
  assign a_fifo_mux_htrans = a_fc_rx_fifo_active ? a_fc_rx_fifo_htrans : ahb_a_fifo_if.master_if[0].htrans;
  assign a_fifo_mux_hsize  = a_fc_rx_fifo_active ? a_fc_rx_fifo_hsize  : ahb_a_fifo_if.master_if[0].hsize;
  assign a_fifo_mux_hwrite = a_fc_rx_fifo_active ? a_fc_rx_fifo_hwrite : ahb_a_fifo_if.master_if[0].hwrite;
  assign a_fifo_mux_hwdata = a_fc_rx_fifo_active ? a_fc_rx_fifo_hwdata : ahb_a_fifo_if.master_if[0].hwdata[31:0];
  assign a_fifo_mux_hready = a_fifo_mux_hreadyout;

  assign a_fc_rx_fifo_hready  = a_fc_rx_fifo_active ? a_fifo_mux_hreadyout : 1'b1;
  assign a_fc_rx_fifo_hresp   = a_fifo_mux_hresp;
  assign a_fc_rx_fifo_hrdata  = a_fifo_mux_hrdata;
  assign a_dut_fifo_hreadyout = a_fc_rx_fifo_active ? 1'b0 : a_fifo_mux_hreadyout;
  assign a_dut_fifo_hresp     = a_fifo_mux_hresp;
  assign a_dut_fifo_hrdata    = a_fifo_mux_hrdata;

  // ---------------------------------------------------------------
  // FC adapter RX config A: AHB-to-APB bridge
  // Converts FC adapter's AHB config master to APB for the config mux
  // ---------------------------------------------------------------
  wire [APB_ADDR_W-1:0] a_fc_cfg_apb_paddr;
  wire                   a_fc_cfg_apb_psel;
  wire                   a_fc_cfg_apb_penable;
  wire                   a_fc_cfg_apb_pwrite;
  wire [SYS_DATA_W-1:0] a_fc_cfg_apb_pwdata;
  wire [SYS_DATA_W-1:0] a_fc_cfg_apb_prdata;
  wire                   a_fc_cfg_apb_pready;
  wire                   a_fc_cfg_apb_pslverr;

  wire                   a_fc_cfg_ahb_hreadyout;
  wire                   a_fc_cfg_ahb_hresp;
  wire [SYS_DATA_W-1:0] a_fc_cfg_ahb_hrdata;

  assign a_fc_rx_cfg_hready = a_fc_cfg_ahb_hreadyout;
  assign a_fc_rx_cfg_hresp  = a_fc_cfg_ahb_hresp;
  assign a_fc_rx_cfg_hrdata = a_fc_cfg_ahb_hrdata;

  cmsdk_ahb_to_apb #(
    .ADDRWIDTH      (APB_ADDR_W),
    .REGISTER_RDATA (1),
    .REGISTER_WDATA (0)
  ) u_a_fc_cfg_ahb_to_apb (
    .HCLK      (clk),
    .HRESETn   (rst_n),
    .PCLKEN    (1'b1),

    .HSEL      (a_fc_rx_cfg_htrans[1]),
    .HADDR     (a_fc_rx_cfg_haddr),
    .HTRANS    (a_fc_rx_cfg_htrans),
    .HSIZE     (a_fc_rx_cfg_hsize),
    .HPROT     (4'b0011),
    .HWRITE    (a_fc_rx_cfg_hwrite),
    .HREADY    (a_fc_cfg_ahb_hreadyout),
    .HWDATA    (a_fc_rx_cfg_hwdata),

    .HREADYOUT (a_fc_cfg_ahb_hreadyout),
    .HRDATA    (a_fc_cfg_ahb_hrdata),
    .HRESP     (a_fc_cfg_ahb_hresp),

    .PADDR     (a_fc_cfg_apb_paddr),
    .PSEL      (a_fc_cfg_apb_psel),
    .PENABLE   (a_fc_cfg_apb_penable),
    .PWRITE    (a_fc_cfg_apb_pwrite),
    .PSTRB     (),
    .PPROT     (),
    .PWDATA    (a_fc_cfg_apb_pwdata),
    .APBACTIVE (),

    .PRDATA    (a_fc_cfg_apb_prdata),
    .PREADY    (a_fc_cfg_apb_pready),
    .PSLVERR   (a_fc_cfg_apb_pslverr)
  );

  // ---------------------------------------------------------------
  // Config port mux A: 2:1 APB mux for config slave port
  //   Source 0 (priority): FC adapter RX Config (bridged from AHB above)
  //   Source 1: External APB master agent (CPU reads/writes config registers)
  // FC adapter has priority (credit/doorbell delivery is time-sensitive).
  // External APB is stalled (pready=0) when FC adapter is active.
  // ---------------------------------------------------------------
  wire a_fc_cfg_apb_active = a_fc_cfg_apb_psel;

  // APB signals to tidelink_fifo APB slave A
  wire [APB_ADDR_W-1:0] a_tl_apb_paddr;
  wire                   a_tl_apb_psel;
  wire                   a_tl_apb_penable;
  wire                   a_tl_apb_pwrite;
  wire [SYS_DATA_W-1:0] a_tl_apb_pwdata;
  wire [SYS_DATA_W-1:0] a_tl_apb_prdata;
  wire                   a_tl_apb_pready;
  wire                   a_tl_apb_pslverr;

  assign a_tl_apb_paddr   = a_fc_cfg_apb_active ? a_fc_cfg_apb_paddr   : apb_a_cfg_if.paddr[APB_ADDR_W-1:0];
  assign a_tl_apb_psel    = a_fc_cfg_apb_active ? a_fc_cfg_apb_psel    : apb_a_cfg_if.psel;
  assign a_tl_apb_penable = a_fc_cfg_apb_active ? a_fc_cfg_apb_penable : apb_a_cfg_if.penable;
  assign a_tl_apb_pwrite  = a_fc_cfg_apb_active ? a_fc_cfg_apb_pwrite  : apb_a_cfg_if.pwrite;
  assign a_tl_apb_pwdata  = a_fc_cfg_apb_active ? a_fc_cfg_apb_pwdata  : apb_a_cfg_if.pwdata;

  // Route APB responses back to both sources
  assign a_fc_cfg_apb_prdata  = a_tl_apb_prdata;
  assign a_fc_cfg_apb_pready  = a_tl_apb_pready;
  assign a_fc_cfg_apb_pslverr = a_tl_apb_pslverr;

  // External APB: stall when FC adapter is active, otherwise pass through
  assign apb_a_cfg_if.prdata  = a_fc_cfg_apb_active ? '0   : a_tl_apb_prdata;
  assign apb_a_cfg_if.pready  = a_fc_cfg_apb_active ? 1'b0 : a_tl_apb_pready;
  assign apb_a_cfg_if.pslverr = a_fc_cfg_apb_active ? 1'b0 : a_tl_apb_pslverr;

  // FC Adapter A
  tidelink_fc_adapter #(
    .SYS_ADDR_W (SYS_ADDR_W),
    .SYS_DATA_W (SYS_DATA_W),
    .RAM_ADDR_W (RAM_ADDR_W),
    .APB_ADDR_W (APB_ADDR_W),
    .FC_DATA_W  (FC_DATA_W)
  ) u_fc_adapter_a (
    .hclk              (clk),
    .hresetn           (rst_n),
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
    .rtn_haddr         (a_rtn_haddr),
    .rtn_hwdata        (a_rtn_hwdata),
    .rtn_htrans        (a_rtn_htrans),
    .rtn_hsize         (a_rtn_hsize),
    .rtn_hwrite        (a_rtn_hwrite),
    .rtn_hready        (a_rtn_hready),
    .rtn_hresp         (a_rtn_hresp),
    .rtn_hrdata        (a_rtn_hrdata),
    .fc_rx_fifo_haddr  (a_fc_rx_fifo_haddr),
    .fc_rx_fifo_hwdata (a_fc_rx_fifo_hwdata),
    .fc_rx_fifo_htrans (a_fc_rx_fifo_htrans),
    .fc_rx_fifo_hsize  (a_fc_rx_fifo_hsize),
    .fc_rx_fifo_hwrite (a_fc_rx_fifo_hwrite),
    .fc_rx_fifo_hready (a_fc_rx_fifo_hready),
    .fc_rx_fifo_hresp  (a_fc_rx_fifo_hresp),
    .fc_rx_fifo_hrdata (a_fc_rx_fifo_hrdata),
    .fc_rx_cfg_haddr   (a_fc_rx_cfg_haddr),
    .fc_rx_cfg_hwdata  (a_fc_rx_cfg_hwdata),
    .fc_rx_cfg_htrans  (a_fc_rx_cfg_htrans),
    .fc_rx_cfg_hsize   (a_fc_rx_cfg_hsize),
    .fc_rx_cfg_hwrite  (a_fc_rx_cfg_hwrite),
    .fc_rx_cfg_hready  (a_fc_rx_cfg_hready),
    .fc_rx_cfg_hresp   (a_fc_rx_cfg_hresp),
    .fc_rx_cfg_hrdata  (a_fc_rx_cfg_hrdata),
    .tl_fc_a2l_valid   (a_fc_a2l_valid),
    .tl_fc_a2l_data    (a_fc_a2l_data),
    .tl_fc_a2l_ready   (a_fc_a2l_ready),
    .tl_fc_l2a_valid   (a_fc_l2a_valid),
    .tl_fc_l2a_data    (a_fc_l2a_data),
    .tl_fc_l2a_accept  (a_fc_l2a_accept)
  );

  // FIFO A (APB config interface, not AHB)
  tidelink_fifo #(
    .SYS_ADDR_W        (SYS_ADDR_W),
    .SYS_DATA_W        (SYS_DATA_W),
    .RAM_ADDR_W        (RAM_ADDR_W),
    .RAM_DATA_W        (RAM_DATA_W),
    .APB_ADDR_W        (APB_ADDR_W),
    .TIDELINK_PAIR_BASE(A_PAIR_BASE)
  ) u_tidelink_fifo_a (
    .hclk              (clk),
    .hresetn           (rst_n),

    // AHB Slave — FIFO data (muxed: FC RX writes + VIP reads)
    .ahbs_hsel         (a_fifo_mux_hsel),
    .ahbs_hready       (a_fifo_mux_hready),
    .ahbs_htrans       (a_fifo_mux_htrans),
    .ahbs_hsize        (a_fifo_mux_hsize),
    .ahbs_hwrite       (a_fifo_mux_hwrite),
    .ahbs_haddr        (a_fifo_mux_haddr),
    .ahbs_hwdata       (a_fifo_mux_hwdata),
    .ahbs_hreadyout    (a_fifo_mux_hreadyout),
    .ahbs_hresp        (a_fifo_mux_hresp),
    .ahbs_hrdata       (a_fifo_mux_hrdata),

    // APB Slave — Config registers (muxed: FC RX sideband + APB agent)
    .apbs_psel         (a_tl_apb_psel),
    .apbs_penable      (a_tl_apb_penable),
    .apbs_pwrite       (a_tl_apb_pwrite),
    .apbs_paddr        (a_tl_apb_paddr),
    .apbs_pwdata       (a_tl_apb_pwdata),
    .apbs_prdata       (a_tl_apb_prdata),
    .apbs_pready       (a_tl_apb_pready),
    .apbs_pslverr      (a_tl_apb_pslverr),

    // AHB Master — Returner (routed to FC adapter for sideband transport)
    .ahbm_haddr        (a_rtn_haddr),
    .ahbm_hwdata       (a_rtn_hwdata),
    .ahbm_htrans       (a_rtn_htrans),
    .ahbm_hsize        (a_rtn_hsize),
    .ahbm_hwrite       (a_rtn_hwrite),
    .ahbm_hready       (a_rtn_hready),
    .ahbm_hresp        (a_rtn_hresp),
    .ahbm_hrdata       (a_rtn_hrdata),

    // Interrupts
    .released_credits_irq (a_released_credits_irq),
    .doorbell_irq         (a_doorbell_irq),
    .packet_committed_irq (a_packet_committed_irq),

    // PTP register pass-through (unused in system testbench)
    .ptp_reg_write     (),
    .ptp_reg_addr      (),
    .ptp_reg_wdata     (),
    .ptp_reg_rdata     (32'h0),
    .ptp_reg_region    ()
  );

  // =================================================================
  // CHIPLET B — FC adapter + FIFO + mux logic
  // =================================================================

  // Returner AHB master wiring
  wire [SYS_ADDR_W-1:0] b_rtn_haddr;
  wire [SYS_DATA_W-1:0] b_rtn_hwdata;
  wire            [1:0]  b_rtn_htrans;
  wire            [2:0]  b_rtn_hsize;
  wire                   b_rtn_hwrite;
  wire                   b_rtn_hready;
  wire                   b_rtn_hresp;
  wire [SYS_DATA_W-1:0] b_rtn_hrdata;

  // FC adapter RX — split AHB master wiring
  wire [RAM_ADDR_W-1:0] b_fc_rx_fifo_haddr;
  wire [SYS_DATA_W-1:0] b_fc_rx_fifo_hwdata;
  wire            [1:0]  b_fc_rx_fifo_htrans;
  wire            [2:0]  b_fc_rx_fifo_hsize;
  wire                   b_fc_rx_fifo_hwrite;
  wire                   b_fc_rx_fifo_hready;
  wire                   b_fc_rx_fifo_hresp;
  wire [SYS_DATA_W-1:0] b_fc_rx_fifo_hrdata;

  wire [APB_ADDR_W-1:0] b_fc_rx_cfg_haddr;
  wire [SYS_DATA_W-1:0] b_fc_rx_cfg_hwdata;
  wire            [1:0]  b_fc_rx_cfg_htrans;
  wire            [2:0]  b_fc_rx_cfg_hsize;
  wire                   b_fc_rx_cfg_hwrite;
  wire                   b_fc_rx_cfg_hready;
  wire                   b_fc_rx_cfg_hresp;
  wire [SYS_DATA_W-1:0] b_fc_rx_cfg_hrdata;

  // DUT output wires for Chiplet B
  wire        b_dut_tx_hreadyout;
  wire        b_dut_tx_hresp;
  wire [31:0] b_dut_tx_hrdata;
  wire        b_dut_fifo_hreadyout;
  wire        b_dut_fifo_hresp;
  wire [31:0] b_dut_fifo_hrdata;
  wire        b_released_credits_irq;
  wire        b_doorbell_irq;
  wire        b_packet_committed_irq;

  // FIFO port mux B
  wire                   b_fifo_mux_hsel;
  wire [RAM_ADDR_W-1:0] b_fifo_mux_haddr;
  wire            [1:0]  b_fifo_mux_htrans;
  wire            [2:0]  b_fifo_mux_hsize;
  wire                   b_fifo_mux_hwrite;
  wire [SYS_DATA_W-1:0] b_fifo_mux_hwdata;
  wire                   b_fifo_mux_hready;
  wire [SYS_DATA_W-1:0] b_fifo_mux_hrdata;
  wire                   b_fifo_mux_hresp;
  wire                   b_fifo_mux_hreadyout;

  wire b_fc_rx_fifo_active = b_fc_rx_fifo_htrans[1];

  assign b_fifo_mux_hsel   = b_fc_rx_fifo_active ? 1'b1              : 1'b1;
  assign b_fifo_mux_haddr  = b_fc_rx_fifo_active ? b_fc_rx_fifo_haddr  : ahb_b_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0];
  assign b_fifo_mux_htrans = b_fc_rx_fifo_active ? b_fc_rx_fifo_htrans : ahb_b_fifo_if.master_if[0].htrans;
  assign b_fifo_mux_hsize  = b_fc_rx_fifo_active ? b_fc_rx_fifo_hsize  : ahb_b_fifo_if.master_if[0].hsize;
  assign b_fifo_mux_hwrite = b_fc_rx_fifo_active ? b_fc_rx_fifo_hwrite : ahb_b_fifo_if.master_if[0].hwrite;
  assign b_fifo_mux_hwdata = b_fc_rx_fifo_active ? b_fc_rx_fifo_hwdata : ahb_b_fifo_if.master_if[0].hwdata[31:0];
  assign b_fifo_mux_hready = b_fifo_mux_hreadyout;

  assign b_fc_rx_fifo_hready  = b_fc_rx_fifo_active ? b_fifo_mux_hreadyout : 1'b1;
  assign b_fc_rx_fifo_hresp   = b_fifo_mux_hresp;
  assign b_fc_rx_fifo_hrdata  = b_fifo_mux_hrdata;
  assign b_dut_fifo_hreadyout = b_fc_rx_fifo_active ? 1'b0 : b_fifo_mux_hreadyout;
  assign b_dut_fifo_hresp     = b_fifo_mux_hresp;
  assign b_dut_fifo_hrdata    = b_fifo_mux_hrdata;

  // ---------------------------------------------------------------
  // FC adapter RX config B: AHB-to-APB bridge
  // ---------------------------------------------------------------
  wire [APB_ADDR_W-1:0] b_fc_cfg_apb_paddr;
  wire                   b_fc_cfg_apb_psel;
  wire                   b_fc_cfg_apb_penable;
  wire                   b_fc_cfg_apb_pwrite;
  wire [SYS_DATA_W-1:0] b_fc_cfg_apb_pwdata;
  wire [SYS_DATA_W-1:0] b_fc_cfg_apb_prdata;
  wire                   b_fc_cfg_apb_pready;
  wire                   b_fc_cfg_apb_pslverr;

  wire                   b_fc_cfg_ahb_hreadyout;
  wire                   b_fc_cfg_ahb_hresp;
  wire [SYS_DATA_W-1:0] b_fc_cfg_ahb_hrdata;

  assign b_fc_rx_cfg_hready = b_fc_cfg_ahb_hreadyout;
  assign b_fc_rx_cfg_hresp  = b_fc_cfg_ahb_hresp;
  assign b_fc_rx_cfg_hrdata = b_fc_cfg_ahb_hrdata;

  cmsdk_ahb_to_apb #(
    .ADDRWIDTH      (APB_ADDR_W),
    .REGISTER_RDATA (1),
    .REGISTER_WDATA (0)
  ) u_b_fc_cfg_ahb_to_apb (
    .HCLK      (clk),
    .HRESETn   (rst_n),
    .PCLKEN    (1'b1),

    .HSEL      (b_fc_rx_cfg_htrans[1]),
    .HADDR     (b_fc_rx_cfg_haddr),
    .HTRANS    (b_fc_rx_cfg_htrans),
    .HSIZE     (b_fc_rx_cfg_hsize),
    .HPROT     (4'b0011),
    .HWRITE    (b_fc_rx_cfg_hwrite),
    .HREADY    (b_fc_cfg_ahb_hreadyout),
    .HWDATA    (b_fc_rx_cfg_hwdata),

    .HREADYOUT (b_fc_cfg_ahb_hreadyout),
    .HRDATA    (b_fc_cfg_ahb_hrdata),
    .HRESP     (b_fc_cfg_ahb_hresp),

    .PADDR     (b_fc_cfg_apb_paddr),
    .PSEL      (b_fc_cfg_apb_psel),
    .PENABLE   (b_fc_cfg_apb_penable),
    .PWRITE    (b_fc_cfg_apb_pwrite),
    .PSTRB     (),
    .PPROT     (),
    .PWDATA    (b_fc_cfg_apb_pwdata),
    .APBACTIVE (),

    .PRDATA    (b_fc_cfg_apb_prdata),
    .PREADY    (b_fc_cfg_apb_pready),
    .PSLVERR   (b_fc_cfg_apb_pslverr)
  );

  // ---------------------------------------------------------------
  // Config port mux B: 2:1 APB mux for config slave port
  // ---------------------------------------------------------------
  wire b_fc_cfg_apb_active = b_fc_cfg_apb_psel;

  // APB signals to tidelink_fifo APB slave B
  wire [APB_ADDR_W-1:0] b_tl_apb_paddr;
  wire                   b_tl_apb_psel;
  wire                   b_tl_apb_penable;
  wire                   b_tl_apb_pwrite;
  wire [SYS_DATA_W-1:0] b_tl_apb_pwdata;
  wire [SYS_DATA_W-1:0] b_tl_apb_prdata;
  wire                   b_tl_apb_pready;
  wire                   b_tl_apb_pslverr;

  assign b_tl_apb_paddr   = b_fc_cfg_apb_active ? b_fc_cfg_apb_paddr   : apb_b_cfg_if.paddr[APB_ADDR_W-1:0];
  assign b_tl_apb_psel    = b_fc_cfg_apb_active ? b_fc_cfg_apb_psel    : apb_b_cfg_if.psel;
  assign b_tl_apb_penable = b_fc_cfg_apb_active ? b_fc_cfg_apb_penable : apb_b_cfg_if.penable;
  assign b_tl_apb_pwrite  = b_fc_cfg_apb_active ? b_fc_cfg_apb_pwrite  : apb_b_cfg_if.pwrite;
  assign b_tl_apb_pwdata  = b_fc_cfg_apb_active ? b_fc_cfg_apb_pwdata  : apb_b_cfg_if.pwdata;

  // Route APB responses back to both sources
  assign b_fc_cfg_apb_prdata  = b_tl_apb_prdata;
  assign b_fc_cfg_apb_pready  = b_tl_apb_pready;
  assign b_fc_cfg_apb_pslverr = b_tl_apb_pslverr;

  // External APB: stall when FC adapter is active, otherwise pass through
  assign apb_b_cfg_if.prdata  = b_fc_cfg_apb_active ? '0   : b_tl_apb_prdata;
  assign apb_b_cfg_if.pready  = b_fc_cfg_apb_active ? 1'b0 : b_tl_apb_pready;
  assign apb_b_cfg_if.pslverr = b_fc_cfg_apb_active ? 1'b0 : b_tl_apb_pslverr;

  // FC Adapter B
  tidelink_fc_adapter #(
    .SYS_ADDR_W (SYS_ADDR_W),
    .SYS_DATA_W (SYS_DATA_W),
    .RAM_ADDR_W (RAM_ADDR_W),
    .APB_ADDR_W (APB_ADDR_W),
    .FC_DATA_W  (FC_DATA_W)
  ) u_fc_adapter_b (
    .hclk              (clk),
    .hresetn           (rst_n),
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
    .rtn_haddr         (b_rtn_haddr),
    .rtn_hwdata        (b_rtn_hwdata),
    .rtn_htrans        (b_rtn_htrans),
    .rtn_hsize         (b_rtn_hsize),
    .rtn_hwrite        (b_rtn_hwrite),
    .rtn_hready        (b_rtn_hready),
    .rtn_hresp         (b_rtn_hresp),
    .rtn_hrdata        (b_rtn_hrdata),
    .fc_rx_fifo_haddr  (b_fc_rx_fifo_haddr),
    .fc_rx_fifo_hwdata (b_fc_rx_fifo_hwdata),
    .fc_rx_fifo_htrans (b_fc_rx_fifo_htrans),
    .fc_rx_fifo_hsize  (b_fc_rx_fifo_hsize),
    .fc_rx_fifo_hwrite (b_fc_rx_fifo_hwrite),
    .fc_rx_fifo_hready (b_fc_rx_fifo_hready),
    .fc_rx_fifo_hresp  (b_fc_rx_fifo_hresp),
    .fc_rx_fifo_hrdata (b_fc_rx_fifo_hrdata),
    .fc_rx_cfg_haddr   (b_fc_rx_cfg_haddr),
    .fc_rx_cfg_hwdata  (b_fc_rx_cfg_hwdata),
    .fc_rx_cfg_htrans  (b_fc_rx_cfg_htrans),
    .fc_rx_cfg_hsize   (b_fc_rx_cfg_hsize),
    .fc_rx_cfg_hwrite  (b_fc_rx_cfg_hwrite),
    .fc_rx_cfg_hready  (b_fc_rx_cfg_hready),
    .fc_rx_cfg_hresp   (b_fc_rx_cfg_hresp),
    .fc_rx_cfg_hrdata  (b_fc_rx_cfg_hrdata),
    .tl_fc_a2l_valid   (b_fc_a2l_valid),
    .tl_fc_a2l_data    (b_fc_a2l_data),
    .tl_fc_a2l_ready   (b_fc_a2l_ready),
    .tl_fc_l2a_valid   (b_fc_l2a_valid),
    .tl_fc_l2a_data    (b_fc_l2a_data),
    .tl_fc_l2a_accept  (b_fc_l2a_accept)
  );

  // FIFO B (APB config interface, not AHB)
  tidelink_fifo #(
    .SYS_ADDR_W        (SYS_ADDR_W),
    .SYS_DATA_W        (SYS_DATA_W),
    .RAM_ADDR_W        (RAM_ADDR_W),
    .RAM_DATA_W        (RAM_DATA_W),
    .APB_ADDR_W        (APB_ADDR_W),
    .TIDELINK_PAIR_BASE(B_PAIR_BASE)
  ) u_tidelink_fifo_b (
    .hclk              (clk),
    .hresetn           (rst_n),

    // AHB Slave — FIFO data (muxed)
    .ahbs_hsel         (b_fifo_mux_hsel),
    .ahbs_hready       (b_fifo_mux_hready),
    .ahbs_htrans       (b_fifo_mux_htrans),
    .ahbs_hsize        (b_fifo_mux_hsize),
    .ahbs_hwrite       (b_fifo_mux_hwrite),
    .ahbs_haddr        (b_fifo_mux_haddr),
    .ahbs_hwdata       (b_fifo_mux_hwdata),
    .ahbs_hreadyout    (b_fifo_mux_hreadyout),
    .ahbs_hresp        (b_fifo_mux_hresp),
    .ahbs_hrdata       (b_fifo_mux_hrdata),

    // APB Slave — Config registers (muxed)
    .apbs_psel         (b_tl_apb_psel),
    .apbs_penable      (b_tl_apb_penable),
    .apbs_pwrite       (b_tl_apb_pwrite),
    .apbs_paddr        (b_tl_apb_paddr),
    .apbs_pwdata       (b_tl_apb_pwdata),
    .apbs_prdata       (b_tl_apb_prdata),
    .apbs_pready       (b_tl_apb_pready),
    .apbs_pslverr      (b_tl_apb_pslverr),

    // AHB Master — Returner
    .ahbm_haddr        (b_rtn_haddr),
    .ahbm_hwdata       (b_rtn_hwdata),
    .ahbm_htrans       (b_rtn_htrans),
    .ahbm_hsize        (b_rtn_hsize),
    .ahbm_hwrite       (b_rtn_hwrite),
    .ahbm_hready       (b_rtn_hready),
    .ahbm_hresp        (b_rtn_hresp),
    .ahbm_hrdata       (b_rtn_hrdata),

    // Interrupts
    .released_credits_irq (b_released_credits_irq),
    .doorbell_irq         (b_doorbell_irq),
    .packet_committed_irq (b_packet_committed_irq),

    // PTP register pass-through (unused)
    .ptp_reg_write     (),
    .ptp_reg_addr      (),
    .ptp_reg_wdata     (),
    .ptp_reg_rdata     (32'h0),
    .ptp_reg_region    ()
  );

  // =================================================================
  // Wire IRQs to tb_if
  // =================================================================
  assign tb_if.a_released_credits_irq = a_released_credits_irq;
  assign tb_if.a_doorbell_irq         = a_doorbell_irq;
  assign tb_if.a_packet_committed_irq = a_packet_committed_irq;
  assign tb_if.b_released_credits_irq = b_released_credits_irq;
  assign tb_if.b_doorbell_irq         = b_doorbell_irq;
  assign tb_if.b_packet_committed_irq = b_packet_committed_irq;

  // =================================================================
  // VIP AHB interface wiring — Chiplet A
  // =================================================================

  // --- TX A ---
  assign ahb_a_tx_if.slave_if[0].haddr     = ahb_a_tx_if.master_if[0].haddr;
  assign ahb_a_tx_if.slave_if[0].htrans    = ahb_a_tx_if.master_if[0].htrans;
  assign ahb_a_tx_if.slave_if[0].hburst    = ahb_a_tx_if.master_if[0].hburst;
  assign ahb_a_tx_if.slave_if[0].hsize     = ahb_a_tx_if.master_if[0].hsize;
  assign ahb_a_tx_if.slave_if[0].hprot     = ahb_a_tx_if.master_if[0].hprot;
  assign ahb_a_tx_if.slave_if[0].hwrite    = ahb_a_tx_if.master_if[0].hwrite;
  assign ahb_a_tx_if.slave_if[0].hwdata    = ahb_a_tx_if.master_if[0].hwdata;
  assign ahb_a_tx_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_a_tx_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_a_tx_if.slave_if[0].hready_in = a_dut_tx_hreadyout;

  initial begin
    force ahb_a_tx_if.master_if[0].hready = a_dut_tx_hreadyout;
    force ahb_a_tx_if.master_if[0].hresp  = {1'b0, a_dut_tx_hresp};
    force ahb_a_tx_if.master_if[0].hrdata = a_dut_tx_hrdata;
    force ahb_a_tx_if.master_if[0].hgrant = 1'b1;
    force ahb_a_tx_if.slave_if[0].hsel    = 1'b1;
    force ahb_a_tx_if.slave_if[0].hready  = a_dut_tx_hreadyout;
    force ahb_a_tx_if.slave_if[0].hrdata  = a_dut_tx_hrdata;
    force ahb_a_tx_if.slave_if[0].hresp   = {1'b0, a_dut_tx_hresp};
  end

  // --- FIFO A ---
  assign ahb_a_fifo_if.slave_if[0].haddr     = ahb_a_fifo_if.master_if[0].haddr;
  assign ahb_a_fifo_if.slave_if[0].htrans    = ahb_a_fifo_if.master_if[0].htrans;
  assign ahb_a_fifo_if.slave_if[0].hburst    = ahb_a_fifo_if.master_if[0].hburst;
  assign ahb_a_fifo_if.slave_if[0].hsize     = ahb_a_fifo_if.master_if[0].hsize;
  assign ahb_a_fifo_if.slave_if[0].hprot     = ahb_a_fifo_if.master_if[0].hprot;
  assign ahb_a_fifo_if.slave_if[0].hwrite    = ahb_a_fifo_if.master_if[0].hwrite;
  assign ahb_a_fifo_if.slave_if[0].hwdata    = ahb_a_fifo_if.master_if[0].hwdata;
  assign ahb_a_fifo_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_a_fifo_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_a_fifo_if.slave_if[0].hready_in = a_dut_fifo_hreadyout;

  initial begin
    force ahb_a_fifo_if.master_if[0].hready = a_dut_fifo_hreadyout;
    force ahb_a_fifo_if.master_if[0].hresp  = {1'b0, a_dut_fifo_hresp};
    force ahb_a_fifo_if.master_if[0].hrdata = a_dut_fifo_hrdata;
    force ahb_a_fifo_if.master_if[0].hgrant = 1'b1;
    force ahb_a_fifo_if.slave_if[0].hsel    = 1'b1;
    force ahb_a_fifo_if.slave_if[0].hready  = a_dut_fifo_hreadyout;
    force ahb_a_fifo_if.slave_if[0].hrdata  = a_dut_fifo_hrdata;
    force ahb_a_fifo_if.slave_if[0].hresp   = {1'b0, a_dut_fifo_hresp};
  end

  // =================================================================
  // VIP AHB interface wiring — Chiplet B
  // =================================================================

  // --- TX B ---
  assign ahb_b_tx_if.slave_if[0].haddr     = ahb_b_tx_if.master_if[0].haddr;
  assign ahb_b_tx_if.slave_if[0].htrans    = ahb_b_tx_if.master_if[0].htrans;
  assign ahb_b_tx_if.slave_if[0].hburst    = ahb_b_tx_if.master_if[0].hburst;
  assign ahb_b_tx_if.slave_if[0].hsize     = ahb_b_tx_if.master_if[0].hsize;
  assign ahb_b_tx_if.slave_if[0].hprot     = ahb_b_tx_if.master_if[0].hprot;
  assign ahb_b_tx_if.slave_if[0].hwrite    = ahb_b_tx_if.master_if[0].hwrite;
  assign ahb_b_tx_if.slave_if[0].hwdata    = ahb_b_tx_if.master_if[0].hwdata;
  assign ahb_b_tx_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_b_tx_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_b_tx_if.slave_if[0].hready_in = b_dut_tx_hreadyout;

  initial begin
    force ahb_b_tx_if.master_if[0].hready = b_dut_tx_hreadyout;
    force ahb_b_tx_if.master_if[0].hresp  = {1'b0, b_dut_tx_hresp};
    force ahb_b_tx_if.master_if[0].hrdata = b_dut_tx_hrdata;
    force ahb_b_tx_if.master_if[0].hgrant = 1'b1;
    force ahb_b_tx_if.slave_if[0].hsel    = 1'b1;
    force ahb_b_tx_if.slave_if[0].hready  = b_dut_tx_hreadyout;
    force ahb_b_tx_if.slave_if[0].hrdata  = b_dut_tx_hrdata;
    force ahb_b_tx_if.slave_if[0].hresp   = {1'b0, b_dut_tx_hresp};
  end

  // --- FIFO B ---
  assign ahb_b_fifo_if.slave_if[0].haddr     = ahb_b_fifo_if.master_if[0].haddr;
  assign ahb_b_fifo_if.slave_if[0].htrans    = ahb_b_fifo_if.master_if[0].htrans;
  assign ahb_b_fifo_if.slave_if[0].hburst    = ahb_b_fifo_if.master_if[0].hburst;
  assign ahb_b_fifo_if.slave_if[0].hsize     = ahb_b_fifo_if.master_if[0].hsize;
  assign ahb_b_fifo_if.slave_if[0].hprot     = ahb_b_fifo_if.master_if[0].hprot;
  assign ahb_b_fifo_if.slave_if[0].hwrite    = ahb_b_fifo_if.master_if[0].hwrite;
  assign ahb_b_fifo_if.slave_if[0].hwdata    = ahb_b_fifo_if.master_if[0].hwdata;
  assign ahb_b_fifo_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_b_fifo_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_b_fifo_if.slave_if[0].hready_in = b_dut_fifo_hreadyout;

  initial begin
    force ahb_b_fifo_if.master_if[0].hready = b_dut_fifo_hreadyout;
    force ahb_b_fifo_if.master_if[0].hresp  = {1'b0, b_dut_fifo_hresp};
    force ahb_b_fifo_if.master_if[0].hrdata = b_dut_fifo_hrdata;
    force ahb_b_fifo_if.master_if[0].hgrant = 1'b1;
    force ahb_b_fifo_if.slave_if[0].hsel    = 1'b1;
    force ahb_b_fifo_if.slave_if[0].hready  = b_dut_fifo_hreadyout;
    force ahb_b_fifo_if.slave_if[0].hrdata  = b_dut_fifo_hrdata;
    force ahb_b_fifo_if.slave_if[0].hresp   = {1'b0, b_dut_fifo_hresp};
  end

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
    // Set VIP AHB interfaces — Chiplet A
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_tx_ahb_sys_env", "vif", ahb_a_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_fifo_ahb_sys_env", "vif", ahb_a_fifo_if);

    // Set VIP AHB interfaces — Chiplet B
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_tx_ahb_sys_env", "vif", ahb_b_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_fifo_ahb_sys_env", "vif", ahb_b_fifo_if);

    // Set APB config agent interfaces — Chiplet A
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.a_cfg_apb_agent.driver", "vif", apb_a_cfg_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.a_cfg_apb_agent.monitor", "vif", apb_a_cfg_if);

    // Set APB config agent interfaces — Chiplet B
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.b_cfg_apb_agent.driver", "vif", apb_b_cfg_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.b_cfg_apb_agent.monitor", "vif", apb_b_cfg_if);

    // Clock/reset/IRQ interface
    uvm_config_db#(virtual tidelink_system_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    run_test();
  end

endmodule
