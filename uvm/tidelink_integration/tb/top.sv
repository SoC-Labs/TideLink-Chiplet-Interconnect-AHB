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
  // FC adapter RX — direct write (FIFO) + APB master (Config)
  // ---------------------------------------------------------------
  wire                   fc_rx_fifo_valid;
  wire                   fc_rx_fifo_write;
  wire [RAM_ADDR_W-1:0] fc_rx_fifo_addr;
  wire [SYS_DATA_W-1:0] fc_rx_fifo_wdata;
  wire                   fc_rx_fifo_ready;

  wire [APB_ADDR_W-1:0] fc_cfg_apb_paddr;
  wire                   fc_cfg_apb_psel;
  wire                   fc_cfg_apb_penable;
  wire                   fc_cfg_apb_pwrite;
  wire [SYS_DATA_W-1:0] fc_cfg_apb_pwdata;
  wire [SYS_DATA_W-1:0] fc_cfg_apb_prdata;
  wire                   fc_cfg_apb_pready;

  // ---------------------------------------------------------------
  // DUT output wires
  // ---------------------------------------------------------------

  // TX aperture DUT slave outputs
  wire        dut_tx_hreadyout;
  wire        dut_tx_hresp;
  wire [31:0] dut_tx_hrdata;

  // FIFO read DUT slave outputs (FC RX writes use the dedicated fc_wr port,
  // so the FIFO AHB slave is exclusively the external VIP read path)
  wire        dut_fifo_hreadyout;
  wire        dut_fifo_hresp;
  wire [31:0] dut_fifo_hrdata;

  // Interrupts
  wire        dut_released_credits_irq;
  wire        dut_doorbell_irq;
  wire        dut_packet_committed_irq;

  // ---------------------------------------------------------------
  // Config port mux: 2:1 APB mux for config slave port
  //   Source 0 (priority): FC adapter RX Config (now native APB)
  //   Source 1: External APB master agent
  // FC adapter has priority (credit/doorbell delivery is time-sensitive).
  // External APB is stalled (pready=0) when FC adapter is active.
  // ---------------------------------------------------------------

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

  // Route APB responses back to FC adapter (no pslverr in new APB master surface)
  assign fc_cfg_apb_prdata  = tl_apb_prdata;
  assign fc_cfg_apb_pready  = tl_apb_pready;

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

    // Direct Write — RX FIFO path (drives tidelink_fifo's fc_wr port)
    .fc_rx_fifo_valid  (fc_rx_fifo_valid),
    .fc_rx_fifo_write  (fc_rx_fifo_write),
    .fc_rx_fifo_addr   (fc_rx_fifo_addr),
    .fc_rx_fifo_wdata  (fc_rx_fifo_wdata),
    .fc_rx_fifo_ready  (fc_rx_fifo_ready),

    // APB Master — RX Config path (drives APB mux)
    .fc_rx_cfg_paddr   (fc_cfg_apb_paddr),
    .fc_rx_cfg_pwdata  (fc_cfg_apb_pwdata),
    .fc_rx_cfg_psel    (fc_cfg_apb_psel),
    .fc_rx_cfg_penable (fc_cfg_apb_penable),
    .fc_rx_cfg_pwrite  (fc_cfg_apb_pwrite),
    .fc_rx_cfg_prdata  (fc_cfg_apb_prdata),
    .fc_rx_cfg_pready  (fc_cfg_apb_pready),

    // Servo timestamp injection (not exercised in integration testbench)
    .servo_fc_valid    (1'b0),
    .servo_fc_data     (48'h0),
    .servo_fc_ready    (),

    // TideChart AXI-Stream port (not exercised in integration testbench)
    .tc_axis_tx_tvalid (1'b0),
    .tc_axis_tx_tdata  (48'h0),
    .tc_axis_tx_tready (),
    .tc_axis_rx_tvalid (),
    .tc_axis_rx_tdata  (),
    .tc_axis_rx_tready (1'b1),

    // QoS priority hint (default = original fixed priority)
    .tc_qos_priority   (3'b000),

    // PUF SRAM read interface (not exercised in integration testbench)
    .puf_addr          (),
    .puf_req           (),
    .puf_rdata         (32'h0),
    .puf_ack           (1'b0),

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

    // AHB Slave — FIFO data (external VIP master only; FC RX writes go
    // through the dedicated fc_wr_* port below)
    .ahbs_hsel         (1'b1),
    .ahbs_hready       (dut_fifo_hreadyout),
    .ahbs_htrans       (ahb_fifo_if.master_if[0].htrans),
    .ahbs_hsize        (ahb_fifo_if.master_if[0].hsize),
    .ahbs_hwrite       (ahb_fifo_if.master_if[0].hwrite),
    .ahbs_haddr        (ahb_fifo_if.master_if[0].haddr[RAM_ADDR_W-1:0]),
    .ahbs_hwdata       (ahb_fifo_if.master_if[0].hwdata[31:0]),
    .ahbs_hreadyout    (dut_fifo_hreadyout),
    .ahbs_hresp        (dut_fifo_hresp),
    .ahbs_hrdata       (dut_fifo_hrdata),

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

    // FC direct-write — incoming RX FIFO_DATA from FC adapter
    .fc_wr_valid       (fc_rx_fifo_valid),
    .fc_wr_write       (fc_rx_fifo_write),
    .fc_wr_addr        (fc_rx_fifo_addr),
    .fc_wr_wdata       (fc_rx_fifo_wdata),
    .fc_wr_ready       (fc_rx_fifo_ready),

    // PUF SRAM read interface (not exercised in integration testbench)
    .puf_addr          ('0),
    .puf_req           (1'b0),
    .puf_rdata         (),
    .puf_ack           (),

    // Interrupts
    .released_credits_irq (dut_released_credits_irq),
    .doorbell_irq         (dut_doorbell_irq),
    .packet_committed_irq (dut_packet_committed_irq),

    // PTP register pass-through (unused in integration testbench)
    .ptp_reg_write     (),
    .ptp_reg_addr      (),
    .ptp_reg_wdata     (),
    .ptp_reg_rdata     (32'h0),
    .ptp_reg_region    (),

    // Servo register pass-through (unused in integration testbench)
    .servo_reg_write   (),
    .servo_reg_addr    (),
    .servo_reg_wdata   (),
    .servo_reg_rdata   (32'h0),

    // Mailbox register pass-through (unused in integration testbench)
    .mbox_reg_write    (),
    .mbox_reg_addr     (),
    .mbox_reg_wdata    (),

    // Chiplet controller register pass-through (unused)
    .ctrl_reg_write    (),
    .ctrl_reg_addr     (),
    .ctrl_reg_wdata    (),
    .ctrl_reg_rdata    (32'h0),

    // Performance profiling register pass-through (unused)
    .perf_reg_write    (),
    .perf_reg_addr     (),
    .perf_reg_wdata    (),
    .perf_reg_rdata    (32'h0),
    .perf_reg_region   (),

    // Credit count observation (unused)
    .perf_credit_count ()
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
