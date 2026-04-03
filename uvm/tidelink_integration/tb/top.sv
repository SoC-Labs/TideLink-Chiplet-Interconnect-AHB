///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink integration verification.
//
// Instantiates a self-contained loopback topology:
//   - tidelink_fc_adapter: TX aperture + returner interception + RX routing
//   - tidelink_fifo_ahb: RX FIFO with AHB + APB (config) slave ports
//   - FIFO/config port mux logic (copied from tidelink_top.sv)
//   - FC TX→RX loopback: a2l wired directly to l2a
//
// Data path: TX aperture write → FC TX → loopback → FC RX → mux → FIFO
// Sideband path: returner write → FC TX → loopback → FC RX → mux → config
//
// Three SVT AHB VIP interfaces:
//   1. TX aperture AHB master (drives writes into FC adapter TX path)
//   2. FIFO read AHB master (reads received packets from RX FIFO)
//   3. Config AHB master (reads/writes config/status registers)
//
// One custom APB master agent (reused from unit-level testbench) is NOT
// needed here — config access goes through the AHB config VIP instead,
// which hits the AHB-to-APB bridge inside tidelink_fifo_ahb.
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

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

  // Config AHB interface (VIP master reads/writes config registers)
  svt_ahb_if ahb_cfg_if();
  assign ahb_cfg_if.hclk    = clk;
  assign ahb_cfg_if.hresetn = rst_n;

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

  // Config DUT slave outputs (muxed)
  wire        dut_cfg_hreadyout;
  wire        dut_cfg_hresp;
  wire [31:0] dut_cfg_hrdata;

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
  // Config port mux: 2:1 AHB mux for config/APB slave port
  //   Source 0: FC adapter RX Config master (writes credit/doorbell sideband)
  //   Source 1: External ahb_cfg VIP (CPU reads/writes config registers)
  // FC adapter has priority.
  // ---------------------------------------------------------------
  wire                   cfg_mux_hsel;
  wire [APB_ADDR_W-1:0] cfg_mux_haddr;
  wire            [1:0]  cfg_mux_htrans;
  wire            [2:0]  cfg_mux_hsize;
  wire                   cfg_mux_hwrite;
  wire [SYS_DATA_W-1:0] cfg_mux_hwdata;
  wire                   cfg_mux_hready;
  wire [SYS_DATA_W-1:0] cfg_mux_hrdata;
  wire                   cfg_mux_hresp;
  wire                   cfg_mux_hreadyout;

  wire fc_rx_cfg_active = fc_rx_cfg_htrans[1];

  assign cfg_mux_hsel   = fc_rx_cfg_active ? 1'b1             : 1'b1;
  assign cfg_mux_haddr  = fc_rx_cfg_active ? fc_rx_cfg_haddr  : ahb_cfg_if.master_if[0].haddr[APB_ADDR_W-1:0];
  assign cfg_mux_htrans = fc_rx_cfg_active ? fc_rx_cfg_htrans : ahb_cfg_if.master_if[0].htrans;
  assign cfg_mux_hsize  = fc_rx_cfg_active ? fc_rx_cfg_hsize  : ahb_cfg_if.master_if[0].hsize;
  assign cfg_mux_hwrite = fc_rx_cfg_active ? fc_rx_cfg_hwrite : ahb_cfg_if.master_if[0].hwrite;
  assign cfg_mux_hwdata = fc_rx_cfg_active ? fc_rx_cfg_hwdata : ahb_cfg_if.master_if[0].hwdata[31:0];
  assign cfg_mux_hready = cfg_mux_hreadyout;

  assign fc_rx_cfg_hready  = fc_rx_cfg_active ? cfg_mux_hreadyout : 1'b1;
  assign fc_rx_cfg_hresp   = cfg_mux_hresp;
  assign fc_rx_cfg_hrdata  = cfg_mux_hrdata;
  assign dut_cfg_hreadyout = fc_rx_cfg_active ? 1'b0 : cfg_mux_hreadyout;
  assign dut_cfg_hresp     = cfg_mux_hresp;
  assign dut_cfg_hrdata    = cfg_mux_hrdata;

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
  // DUT: TideLink FIFO AHB wrapper
  // ---------------------------------------------------------------
  tidelink_fifo_ahb #(
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

    // AHB Slave — Config registers (muxed: FC RX sideband + VIP access)
    .ahbc_hsel         (cfg_mux_hsel),
    .ahbc_hready       (cfg_mux_hready),
    .ahbc_htrans       (cfg_mux_htrans),
    .ahbc_hsize        (cfg_mux_hsize),
    .ahbc_hwrite       (cfg_mux_hwrite),
    .ahbc_haddr        (cfg_mux_haddr),
    .ahbc_hwdata       (cfg_mux_hwdata),
    .ahbc_hreadyout    (cfg_mux_hreadyout),
    .ahbc_hresp        (cfg_mux_hresp),
    .ahbc_hrdata       (cfg_mux_hrdata),

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
    .packet_committed_irq (dut_packet_committed_irq)
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
  // Config AHB: VIP master reads/writes config regs (through mux)
  // ---------------------------------------------------------------
  assign ahb_cfg_if.slave_if[0].haddr     = ahb_cfg_if.master_if[0].haddr;
  assign ahb_cfg_if.slave_if[0].htrans    = ahb_cfg_if.master_if[0].htrans;
  assign ahb_cfg_if.slave_if[0].hburst    = ahb_cfg_if.master_if[0].hburst;
  assign ahb_cfg_if.slave_if[0].hsize     = ahb_cfg_if.master_if[0].hsize;
  assign ahb_cfg_if.slave_if[0].hprot     = ahb_cfg_if.master_if[0].hprot;
  assign ahb_cfg_if.slave_if[0].hwrite    = ahb_cfg_if.master_if[0].hwrite;
  assign ahb_cfg_if.slave_if[0].hwdata    = ahb_cfg_if.master_if[0].hwdata;
  assign ahb_cfg_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_cfg_if.slave_if[0].hmastlock = 1'b0;
  assign ahb_cfg_if.slave_if[0].hready_in = dut_cfg_hreadyout;

  initial begin
    force ahb_cfg_if.master_if[0].hready = dut_cfg_hreadyout;
    force ahb_cfg_if.master_if[0].hresp  = {1'b0, dut_cfg_hresp};
    force ahb_cfg_if.master_if[0].hrdata = dut_cfg_hrdata;
    force ahb_cfg_if.master_if[0].hgrant = 1'b1;

    force ahb_cfg_if.slave_if[0].hsel    = 1'b1;
    force ahb_cfg_if.slave_if[0].hready  = dut_cfg_hreadyout;
    force ahb_cfg_if.slave_if[0].hrdata  = dut_cfg_hrdata;
    force ahb_cfg_if.slave_if[0].hresp   = {1'b0, dut_cfg_hresp};
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
    // Set VIP AHB interfaces
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.tx_ahb_sys_env", "vif", ahb_tx_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.fifo_ahb_sys_env", "vif", ahb_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.cfg_ahb_sys_env", "vif", ahb_cfg_if);

    // Clock/reset/IRQ interface
    uvm_config_db#(virtual tidelink_integration_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    run_test();
  end

endmodule
