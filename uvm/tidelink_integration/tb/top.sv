///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink integration verification.
//
// Instantiates a self-contained loopback topology:
//   - tidelink_fc_adapter: TX aperture + returner interception + RX routing
//   - tidelink_fifo: RX FIFO with AHB data + APB config slave ports
//   - cmsdk_ahb_to_apb bridge: converts FC adapter RX config (AHB) to APB
//   - APB config mux: arbitrates FC adapter APB vs external APB master
//   - FIFO data port mux: arbitrates FC adapter RX vs external AHB reads
//   - FC TX→RX loopback: a2l wired directly to l2a
//
// Data path: TX aperture write → FC TX → loopback → FC RX → mux → FIFO
// Sideband path: returner write → FC TX → loopback → FC RX → mux → config
//
// Interfaces:
//   1. SVT AHB VIP: TX aperture AHB master (drives writes into FC adapter)
//   2. SVT AHB VIP: FIFO read AHB master (reads received packets from FIFO)
//   3. Custom APB master agent: config register access (unified APB port,
//      TideLink regs at 0x2000 offset)
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

// APB master agent interface (for config register access)
`include "apb_master_if.sv"

// Integration-specific interface
`include "tidelink_integration_if.sv"

// Testbench package
`include "tidelink_integration_pkg.sv"

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
  import tidelink_integration_pkg::*;

  // ---------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------
  localparam SYS_ADDR_W = 32;
  localparam SYS_DATA_W = 32;
  localparam RAM_ADDR_W = 14;
  localparam RAM_DATA_W = 32;
  localparam APB_ADDR_W = 12;
  localparam FC_DATA_W  = 48;
  localparam [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = 32'h4000_0000;

  // ---------------------------------------------------------------
  // Interface instances
  // ---------------------------------------------------------------

  // TX aperture AHB interface (VIP master drives FC adapter TX slave)
  svt_ahb_if ahb_tx_if();
  assign ahb_tx_if.hclk    = clk;
  assign ahb_tx_if.hresetn = rst_n;

  // FIFO read AHB interface (VIP master reads RX FIFO data)
  svt_ahb_if ahb_fifo_if();
  assign ahb_fifo_if.hclk    = clk;
  assign ahb_fifo_if.hresetn = rst_n;

  // Config APB interface (custom APB master agent reads/writes config registers)
  apb_master_if apb_cfg_if(.clk(clk), .rst_n(rst_n));

  // Simple clock/reset/IRQ interface for tests
  tidelink_integration_if tb_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // FC loopback wiring
  // ---------------------------------------------------------------
  wire                   tl_fc_a2l_valid;
  wire [FC_DATA_W-1:0]  tl_fc_a2l_data;
  wire                   tl_fc_a2l_ready;
  wire                   tl_fc_l2a_valid;
  wire [FC_DATA_W-1:0]  tl_fc_l2a_data;
  wire                   tl_fc_l2a_accept;

  // FC TX→RX loopback: wire a2l directly to l2a
  assign tl_fc_l2a_valid = tl_fc_a2l_valid;
  assign tl_fc_l2a_data  = tl_fc_a2l_data;
  assign tl_fc_a2l_ready = tl_fc_l2a_accept;

  // ---------------------------------------------------------------
  // Returner AHB master wiring (FIFO returner → FC adapter interception)
  // ---------------------------------------------------------------
  wire [SYS_ADDR_W-1:0] rtn_haddr;
  wire [SYS_DATA_W-1:0] rtn_hwdata;
  wire            [1:0]  rtn_htrans;
  wire            [2:0]  rtn_hsize;
  wire                   rtn_hwrite;
  wire                   rtn_hready;
  wire                   rtn_hresp;
  wire [SYS_DATA_W-1:0] rtn_hrdata;

  // ---------------------------------------------------------------
  // FC adapter RX — split AHB master wiring
  // ---------------------------------------------------------------
  wire [RAM_ADDR_W-1:0] fc_rx_fifo_haddr;
  wire [SYS_DATA_W-1:0] fc_rx_fifo_hwdata;
  wire            [1:0]  fc_rx_fifo_htrans;
  wire            [2:0]  fc_rx_fifo_hsize;
  wire                   fc_rx_fifo_hwrite;
  wire                   fc_rx_fifo_hready;
  wire                   fc_rx_fifo_hresp;
  wire [SYS_DATA_W-1:0] fc_rx_fifo_hrdata;

  wire [APB_ADDR_W-1:0] fc_rx_cfg_haddr;
  wire [SYS_DATA_W-1:0] fc_rx_cfg_hwdata;
  wire            [1:0]  fc_rx_cfg_htrans;
  wire            [2:0]  fc_rx_cfg_hsize;
  wire                   fc_rx_cfg_hwrite;
  wire                   fc_rx_cfg_hready;
  wire                   fc_rx_cfg_hresp;
  wire [SYS_DATA_W-1:0] fc_rx_cfg_hrdata;

  // ---------------------------------------------------------------
  // DUT output wires
  // ---------------------------------------------------------------

  // TX aperture DUT slave outputs
  wire        dut_tx_hreadyout;
  wire        dut_tx_hresp;
  wire [31:0] dut_tx_hrdata;

  // FIFO read DUT slave outputs (muxed)
  wire        dut_fifo_hreadyout;
  wire        dut_fifo_hresp;
  wire [31:0] dut_fifo_hrdata;

  // Interrupts
  wire        dut_released_credits_irq;
  wire        dut_doorbell_irq;
  wire        dut_packet_committed_irq;

  // ---------------------------------------------------------------
  // FIFO port mux: 2:1 AHB mux for FIFO slave port
  //   Source 0: FC adapter RX FIFO master (writes incoming packets)
  //   Source 1: External ahb_fifo VIP (CPU reads received packets)
  // FC adapter has priority (incoming data must not be dropped).
  // ---------------------------------------------------------------
  wire                   fifo_mux_hsel;
  wire [RAM_ADDR_W-1:0] fifo_mux_haddr;
  wire            [1:0]  fifo_mux_htrans;
  wire            [2:0]  fifo_mux_hsize;
  wire                   fifo_mux_hwrite;
  wire [SYS_DATA_W-1:0] fifo_mux_hwdata;
  wire                   fifo_mux_hready;
  wire [SYS_DATA_W-1:0] fifo_mux_hrdata;
  wire                   fifo_mux_hresp;
  wire                   fifo_mux_hreadyout;

  wire fc_rx_fifo_active = fc_rx_fifo_htrans[1];

  assign fifo_mux_hsel   = fc_rx_fifo_active ? 1'b1              : 1'b1;
  assign fifo_mux_haddr  = fc_rx_fifo_active ? fc_rx_fifo_haddr  : ahb_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0];
  assign fifo_mux_htrans = fc_rx_fifo_active ? fc_rx_fifo_htrans : ahb_fifo_if.master_if[0].htrans;
  assign fifo_mux_hsize  = fc_rx_fifo_active ? fc_rx_fifo_hsize  : ahb_fifo_if.master_if[0].hsize;
  assign fifo_mux_hwrite = fc_rx_fifo_active ? fc_rx_fifo_hwrite : ahb_fifo_if.master_if[0].hwrite;
  assign fifo_mux_hwdata = fc_rx_fifo_active ? fc_rx_fifo_hwdata : ahb_fifo_if.master_if[0].hwdata[31:0];
  assign fifo_mux_hready = fifo_mux_hreadyout;

  assign fc_rx_fifo_hready  = fc_rx_fifo_active ? fifo_mux_hreadyout : 1'b1;
  assign fc_rx_fifo_hresp   = fifo_mux_hresp;
  assign fc_rx_fifo_hrdata  = fifo_mux_hrdata;
  assign dut_fifo_hreadyout = fc_rx_fifo_active ? 1'b0 : fifo_mux_hreadyout;
  assign dut_fifo_hresp     = fifo_mux_hresp;
  assign dut_fifo_hrdata    = fifo_mux_hrdata;

  // ---------------------------------------------------------------
  // FC adapter RX config: AHB-to-APB bridge
  // Converts FC adapter's AHB config master to APB for the config mux
  // ---------------------------------------------------------------
  wire [APB_ADDR_W-1:0] fc_cfg_apb_paddr;
  wire                   fc_cfg_apb_psel;
  wire                   fc_cfg_apb_penable;
  wire                   fc_cfg_apb_pwrite;
  wire [SYS_DATA_W-1:0] fc_cfg_apb_pwdata;
  wire [SYS_DATA_W-1:0] fc_cfg_apb_prdata;
  wire                   fc_cfg_apb_pready;
  wire                   fc_cfg_apb_pslverr;

  wire                   fc_cfg_ahb_hreadyout;
  wire                   fc_cfg_ahb_hresp;
  wire [SYS_DATA_W-1:0] fc_cfg_ahb_hrdata;

  assign fc_rx_cfg_hready = fc_cfg_ahb_hreadyout;
  assign fc_rx_cfg_hresp  = fc_cfg_ahb_hresp;
  assign fc_rx_cfg_hrdata = fc_cfg_ahb_hrdata;

  cmsdk_ahb_to_apb #(
    .ADDRWIDTH      (APB_ADDR_W),
    .REGISTER_RDATA (1),
    .REGISTER_WDATA (0)
  ) u_fc_cfg_ahb_to_apb (
    .HCLK      (clk),
    .HRESETn   (rst_n),
    .PCLKEN    (1'b1),

    .HSEL      (fc_rx_cfg_htrans[1]),
    .HADDR     (fc_rx_cfg_haddr),
    .HTRANS    (fc_rx_cfg_htrans),
    .HSIZE     (fc_rx_cfg_hsize),
    .HPROT     (4'b0011),
    .HWRITE    (fc_rx_cfg_hwrite),
    .HREADY    (fc_cfg_ahb_hreadyout),
    .HWDATA    (fc_rx_cfg_hwdata),

    .HREADYOUT (fc_cfg_ahb_hreadyout),
    .HRDATA    (fc_cfg_ahb_hrdata),
    .HRESP     (fc_cfg_ahb_hresp),

    .PADDR     (fc_cfg_apb_paddr),
    .PSEL      (fc_cfg_apb_psel),
    .PENABLE   (fc_cfg_apb_penable),
    .PWRITE    (fc_cfg_apb_pwrite),
    .PSTRB     (),
    .PPROT     (),
    .PWDATA    (fc_cfg_apb_pwdata),
    .APBACTIVE (),

    .PRDATA    (fc_cfg_apb_prdata),
    .PREADY    (fc_cfg_apb_pready),
    .PSLVERR   (fc_cfg_apb_pslverr)
  );

  // ---------------------------------------------------------------
  // Config port mux: 2:1 APB mux for config slave port
  //   Source 0 (priority): FC adapter RX Config (bridged from AHB above)
  //   Source 1: External APB master agent (CPU reads/writes config registers)
  // FC adapter has priority (credit/doorbell delivery is time-sensitive).
  // External APB is stalled (pready=0) when FC adapter is active.
  // ---------------------------------------------------------------
  wire fc_cfg_apb_active = fc_cfg_apb_psel;

  // APB signals to tidelink_fifo APB slave
  wire [APB_ADDR_W-1:0] tl_apb_paddr;
  wire                   tl_apb_psel;
  wire                   tl_apb_penable;
  wire                   tl_apb_pwrite;
  wire [SYS_DATA_W-1:0] tl_apb_pwdata;
  wire [SYS_DATA_W-1:0] tl_apb_prdata;
  wire                   tl_apb_pready;
  wire                   tl_apb_pslverr;

  assign tl_apb_paddr   = fc_cfg_apb_active ? fc_cfg_apb_paddr   : apb_cfg_if.paddr[APB_ADDR_W-1:0];
  assign tl_apb_psel    = fc_cfg_apb_active ? fc_cfg_apb_psel    : apb_cfg_if.psel;
  assign tl_apb_penable = fc_cfg_apb_active ? fc_cfg_apb_penable : apb_cfg_if.penable;
  assign tl_apb_pwrite  = fc_cfg_apb_active ? fc_cfg_apb_pwrite  : apb_cfg_if.pwrite;
  assign tl_apb_pwdata  = fc_cfg_apb_active ? fc_cfg_apb_pwdata  : apb_cfg_if.pwdata;

  // Route APB responses back to both sources
  assign fc_cfg_apb_prdata  = tl_apb_prdata;
  assign fc_cfg_apb_pready  = tl_apb_pready;
  assign fc_cfg_apb_pslverr = tl_apb_pslverr;

  // External APB: stall when FC adapter is active, otherwise pass through
  assign apb_cfg_if.prdata  = fc_cfg_apb_active ? '0   : tl_apb_prdata;
  assign apb_cfg_if.pready  = fc_cfg_apb_active ? 1'b0 : tl_apb_pready;
  assign apb_cfg_if.pslverr = fc_cfg_apb_active ? 1'b0 : tl_apb_pslverr;

  // ---------------------------------------------------------------
  // DUT: TideLink FC Adapter
  // ---------------------------------------------------------------
  tidelink_fc_adapter #(
    .SYS_ADDR_W (SYS_ADDR_W),
    .SYS_DATA_W (SYS_DATA_W),
    .RAM_ADDR_W (RAM_ADDR_W),
    .APB_ADDR_W (APB_ADDR_W),
    .FC_DATA_W  (FC_DATA_W)
  ) u_fc_adapter (
    .hclk              (clk),
    .hresetn           (rst_n),

    // AHB Slave — TX aperture (VIP master drives)
    .ahb_tx_hsel       (1'b1),
    .ahb_tx_haddr      (ahb_tx_if.master_if[0].haddr[RAM_ADDR_W-1:0]),
    .ahb_tx_htrans     (ahb_tx_if.master_if[0].htrans),
    .ahb_tx_hsize      (ahb_tx_if.master_if[0].hsize),
    .ahb_tx_hwrite     (ahb_tx_if.master_if[0].hwrite),
    .ahb_tx_hwdata     (ahb_tx_if.master_if[0].hwdata[31:0]),
    .ahb_tx_hready     (ahb_tx_if.master_if[0].hready),
    .ahb_tx_hrdata     (dut_tx_hrdata),
    .ahb_tx_hresp      (dut_tx_hresp),
    .ahb_tx_hreadyout  (dut_tx_hreadyout),

    // AHB Slave — Returner interception (from FIFO's returner master)
    .rtn_haddr         (rtn_haddr),
    .rtn_hwdata        (rtn_hwdata),
    .rtn_htrans        (rtn_htrans),
    .rtn_hsize         (rtn_hsize),
    .rtn_hwrite        (rtn_hwrite),
    .rtn_hready        (rtn_hready),
    .rtn_hresp         (rtn_hresp),
    .rtn_hrdata        (rtn_hrdata),

    // AHB Master — RX FIFO path (writes to FIFO via mux)
    .fc_rx_fifo_haddr  (fc_rx_fifo_haddr),
    .fc_rx_fifo_hwdata (fc_rx_fifo_hwdata),
    .fc_rx_fifo_htrans (fc_rx_fifo_htrans),
    .fc_rx_fifo_hsize  (fc_rx_fifo_hsize),
    .fc_rx_fifo_hwrite (fc_rx_fifo_hwrite),
    .fc_rx_fifo_hready (fc_rx_fifo_hready),
    .fc_rx_fifo_hresp  (fc_rx_fifo_hresp),
    .fc_rx_fifo_hrdata (fc_rx_fifo_hrdata),

    // AHB Master — RX Config path (writes to config via mux)
    .fc_rx_cfg_haddr   (fc_rx_cfg_haddr),
    .fc_rx_cfg_hwdata  (fc_rx_cfg_hwdata),
    .fc_rx_cfg_htrans  (fc_rx_cfg_htrans),
    .fc_rx_cfg_hsize   (fc_rx_cfg_hsize),
    .fc_rx_cfg_hwrite  (fc_rx_cfg_hwrite),
    .fc_rx_cfg_hready  (fc_rx_cfg_hready),
    .fc_rx_cfg_hresp   (fc_rx_cfg_hresp),
    .fc_rx_cfg_hrdata  (fc_rx_cfg_hrdata),

    // FC node interface (looped back)
    .tl_fc_a2l_valid   (tl_fc_a2l_valid),
    .tl_fc_a2l_data    (tl_fc_a2l_data),
    .tl_fc_a2l_ready   (tl_fc_a2l_ready),
    .tl_fc_l2a_valid   (tl_fc_l2a_valid),
    .tl_fc_l2a_data    (tl_fc_l2a_data),
    .tl_fc_l2a_accept  (tl_fc_l2a_accept)
  );

  // ---------------------------------------------------------------
  // DUT: TideLink FIFO (with APB config interface)
  // ---------------------------------------------------------------
  tidelink_fifo #(
    .SYS_ADDR_W        (SYS_ADDR_W),
    .SYS_DATA_W        (SYS_DATA_W),
    .RAM_ADDR_W        (RAM_ADDR_W),
    .RAM_DATA_W        (RAM_DATA_W),
    .APB_ADDR_W        (APB_ADDR_W),
    .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
  ) u_tidelink_fifo (
    .hclk              (clk),
    .hresetn           (rst_n),

    // AHB Slave — FIFO data (muxed: FC RX writes + VIP reads)
    .ahbs_hsel         (fifo_mux_hsel),
    .ahbs_hready       (fifo_mux_hready),
    .ahbs_htrans       (fifo_mux_htrans),
    .ahbs_hsize        (fifo_mux_hsize),
    .ahbs_hwrite       (fifo_mux_hwrite),
    .ahbs_haddr        (fifo_mux_haddr),
    .ahbs_hwdata       (fifo_mux_hwdata),
    .ahbs_hreadyout    (fifo_mux_hreadyout),
    .ahbs_hresp        (fifo_mux_hresp),
    .ahbs_hrdata       (fifo_mux_hrdata),

    // APB Slave — Config registers (muxed: FC RX sideband + APB agent)
    .apbs_psel         (tl_apb_psel),
    .apbs_penable      (tl_apb_penable),
    .apbs_pwrite       (tl_apb_pwrite),
    .apbs_paddr        (tl_apb_paddr),
    .apbs_pwdata       (tl_apb_pwdata),
    .apbs_prdata       (tl_apb_prdata),
    .apbs_pready       (tl_apb_pready),
    .apbs_pslverr      (tl_apb_pslverr),

    // AHB Master — Returner (routed to FC adapter for sideband transport)
    .ahbm_haddr        (rtn_haddr),
    .ahbm_hwdata       (rtn_hwdata),
    .ahbm_htrans       (rtn_htrans),
    .ahbm_hsize        (rtn_hsize),
    .ahbm_hwrite       (rtn_hwrite),
    .ahbm_hready       (rtn_hready),
    .ahbm_hresp        (rtn_hresp),
    .ahbm_hrdata       (rtn_hrdata),

    // Interrupts
    .released_credits_irq (dut_released_credits_irq),
    .doorbell_irq         (dut_doorbell_irq),
    .packet_committed_irq (dut_packet_committed_irq),

    // PTP register pass-through (unused in integration testbench)
    .ptp_reg_write     (),
    .ptp_reg_addr      (),
    .ptp_reg_wdata     (),
    .ptp_reg_rdata     (32'h0),
    .ptp_reg_region    ()
  );

  // Wire IRQs to tb_if
  assign tb_if.released_credits_irq = dut_released_credits_irq;
  assign tb_if.doorbell_irq         = dut_doorbell_irq;
  assign tb_if.packet_committed_irq = dut_packet_committed_irq;

  // ---------------------------------------------------------------
  // TX AHB: VIP master drives FC adapter TX slave
  // ---------------------------------------------------------------
  assign ahb_tx_if.slave_if[0].haddr     = ahb_tx_if.master_if[0].haddr;
  assign ahb_tx_if.slave_if[0].htrans    = ahb_tx_if.master_if[0].htrans;
  assign ahb_tx_if.slave_if[0].hburst    = ahb_tx_if.master_if[0].hburst;
  assign ahb_tx_if.slave_if[0].hsize     = ahb_tx_if.master_if[0].hsize;
  assign ahb_tx_if.slave_if[0].hprot     = ahb_tx_if.master_if[0].hprot;
  assign ahb_tx_if.slave_if[0].hwrite    = ahb_tx_if.master_if[0].hwrite;
  assign ahb_tx_if.slave_if[0].hwdata    = ahb_tx_if.master_if[0].hwdata;
  assign ahb_tx_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_tx_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_tx_if.slave_if[0].hready_in = dut_tx_hreadyout;

  initial begin
    force ahb_tx_if.master_if[0].hready = dut_tx_hreadyout;
    force ahb_tx_if.master_if[0].hresp  = {1'b0, dut_tx_hresp};
    force ahb_tx_if.master_if[0].hrdata = dut_tx_hrdata;
    force ahb_tx_if.master_if[0].hgrant = 1'b1;

    force ahb_tx_if.slave_if[0].hsel    = 1'b1;
    force ahb_tx_if.slave_if[0].hready  = dut_tx_hreadyout;
    force ahb_tx_if.slave_if[0].hrdata  = dut_tx_hrdata;
    force ahb_tx_if.slave_if[0].hresp   = {1'b0, dut_tx_hresp};
  end

  // ---------------------------------------------------------------
  // FIFO read AHB: VIP master reads from RX FIFO (through mux)
  // ---------------------------------------------------------------
  assign ahb_fifo_if.slave_if[0].haddr     = ahb_fifo_if.master_if[0].haddr;
  assign ahb_fifo_if.slave_if[0].htrans    = ahb_fifo_if.master_if[0].htrans;
  assign ahb_fifo_if.slave_if[0].hburst    = ahb_fifo_if.master_if[0].hburst;
  assign ahb_fifo_if.slave_if[0].hsize     = ahb_fifo_if.master_if[0].hsize;
  assign ahb_fifo_if.slave_if[0].hprot     = ahb_fifo_if.master_if[0].hprot;
  assign ahb_fifo_if.slave_if[0].hwrite    = ahb_fifo_if.master_if[0].hwrite;
  assign ahb_fifo_if.slave_if[0].hwdata    = ahb_fifo_if.master_if[0].hwdata;
  assign ahb_fifo_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_fifo_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_fifo_if.slave_if[0].hready_in = dut_fifo_hreadyout;

  initial begin
    force ahb_fifo_if.master_if[0].hready = dut_fifo_hreadyout;
    force ahb_fifo_if.master_if[0].hresp  = {1'b0, dut_fifo_hresp};
    force ahb_fifo_if.master_if[0].hrdata = dut_fifo_hrdata;
    force ahb_fifo_if.master_if[0].hgrant = 1'b1;

    force ahb_fifo_if.slave_if[0].hsel    = 1'b1;
    force ahb_fifo_if.slave_if[0].hready  = dut_fifo_hreadyout;
    force ahb_fifo_if.slave_if[0].hrdata  = dut_fifo_hrdata;
    force ahb_fifo_if.slave_if[0].hresp   = {1'b0, dut_fifo_hresp};
  end

  // ---------------------------------------------------------------
  // Config APB: custom APB master agent reads/writes config regs
  // (APB interface signals are directly driven by the APB agent via
  //  apb_cfg_if, and muxed with FC adapter APB in the config mux above)
  // ---------------------------------------------------------------

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
    // Set VIP AHB interfaces
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.tx_ahb_sys_env", "vif", ahb_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.fifo_ahb_sys_env", "vif", ahb_fifo_if);

    // Set APB config agent interfaces
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.cfg_apb_agent.driver", "vif", apb_cfg_if);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.cfg_apb_agent.monitor", "vif", apb_cfg_if);

    // Clock/reset/IRQ interface
    uvm_config_db#(virtual tidelink_integration_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    run_test();
  end

endmodule
