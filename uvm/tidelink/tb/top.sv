///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink verification.
//
// Instantiates the DUT with:
//   - SVT AHB VIP interface for FIFO AHB slave port (VIP master drives)
//   - SVT AHB VIP interface for returner AHB master port (VIP slave responds)
//   - Custom APB master interface for register access
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

// APB master interface (must be outside module)
`include "apb_master_if.sv"

// Testbench package (must be outside module)
`include "tidelink_pkg.sv"

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
  import tidelink_pkg::*;

  // ---------------------------------------------------------------
  // Interface instances
  // ---------------------------------------------------------------

  // FIFO-side AHB interface (VIP master drives DUT slave)
  svt_ahb_if ahb_fifo_if();
  assign ahb_fifo_if.hclk    = clk;
  assign ahb_fifo_if.hresetn = rst_n;

  // Returner-side AHB interface (DUT master drives VIP slave)
  svt_ahb_if ahb_ret_if();
  assign ahb_ret_if.hclk    = clk;
  assign ahb_ret_if.hresetn = rst_n;

  // APB master interface
  apb_master_if apb_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // DUT instantiation
  // ---------------------------------------------------------------

  // DUT AHB slave (FIFO) outputs
  wire        dut_ahbs_hreadyout;
  wire        dut_ahbs_hresp;
  wire [31:0] dut_ahbs_hrdata;

  // DUT AHB master (returner) outputs
  wire [31:0] dut_ahbm_haddr;
  wire [31:0] dut_ahbm_hwdata;
  wire  [1:0] dut_ahbm_htrans;
  wire  [2:0] dut_ahbm_hsize;
  wire        dut_ahbm_hwrite;

  // DUT interrupt outputs
  wire        dut_released_tokens_irq;
  wire        dut_doorbell_irq;
  wire        dut_packet_committed_irq;

  // Gate-level netlists have no parameters; RTL uses parameterised instantiation
`ifdef GATE_SIM
  tidelink u_dut (
    .hclk               (clk),
    .hresetn             (rst_n),
`else
  tidelink #(
    .SYS_ADDR_W         (32),
    .SYS_DATA_W         (32),
    .RAM_ADDR_W         (14),
    .RAM_DATA_W         (32),
    .APB_ADDR_W         (12),
    .TIDELINK_PAIR_BASE (32'h4000_0000)
  ) u_dut (
    .hclk               (clk),
    .hresetn             (rst_n),
`endif

    // AHB Slave (FIFO) - driven by VIP master
    .ahbs_hsel           (1'b1),
    .ahbs_hready         (ahb_fifo_if.master_if[0].hready),
    .ahbs_htrans         (ahb_fifo_if.master_if[0].htrans),
    .ahbs_hsize          (ahb_fifo_if.master_if[0].hsize),
    .ahbs_hwrite         (ahb_fifo_if.master_if[0].hwrite),
    .ahbs_haddr          (ahb_fifo_if.master_if[0].haddr[13:0]),
    .ahbs_hwdata         (ahb_fifo_if.master_if[0].hwdata[31:0]),
    .ahbs_hreadyout      (dut_ahbs_hreadyout),
    .ahbs_hresp          (dut_ahbs_hresp),
    .ahbs_hrdata         (dut_ahbs_hrdata),

    // AHB Master (returner) - VIP slave responds
    .ahbm_haddr          (dut_ahbm_haddr),
    .ahbm_hwdata         (dut_ahbm_hwdata),
    .ahbm_htrans         (dut_ahbm_htrans),
    .ahbm_hsize          (dut_ahbm_hsize),
    .ahbm_hwrite         (dut_ahbm_hwrite),
    .ahbm_hready         (ahb_ret_if.slave_if[0].hready),
    .ahbm_hresp          (ahb_ret_if.slave_if[0].hresp[0]),
    .ahbm_hrdata         (ahb_ret_if.slave_if[0].hrdata[31:0]),

    // APB Slave (registers) - driven by APB master agent
    .apbs_psel           (apb_if.psel),
    .apbs_penable        (apb_if.penable),
    .apbs_pwrite         (apb_if.pwrite),
    .apbs_paddr          (apb_if.paddr),
    .apbs_pwdata         (apb_if.pwdata),
    .apbs_prdata         (apb_if.prdata),
    .apbs_pready         (apb_if.pready),
    .apbs_pslverr        (apb_if.pslverr),

    // Interrupts
    .released_tokens_irq (dut_released_tokens_irq),
    .doorbell_irq        (dut_doorbell_irq),
    .packet_committed_irq(dut_packet_committed_irq)
  );

  // ---------------------------------------------------------------
  // FIFO AHB: DUT slave outputs -> VIP slave_if[0] (passive monitor)
  // and back to VIP master as hready/hresp/hrdata
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
  assign ahb_fifo_if.slave_if[0].hready_in = dut_ahbs_hreadyout;

  initial begin
    force ahb_fifo_if.master_if[0].hready = dut_ahbs_hreadyout;
    force ahb_fifo_if.master_if[0].hresp  = {1'b0, dut_ahbs_hresp};
    force ahb_fifo_if.master_if[0].hrdata = dut_ahbs_hrdata;
    force ahb_fifo_if.master_if[0].hgrant = 1'b1;

    force ahb_fifo_if.slave_if[0].hsel    = 1'b1;
    force ahb_fifo_if.slave_if[0].hready  = dut_ahbs_hreadyout;
    force ahb_fifo_if.slave_if[0].hrdata  = dut_ahbs_hrdata;
    force ahb_fifo_if.slave_if[0].hresp   = {1'b0, dut_ahbs_hresp};
  end

  // ---------------------------------------------------------------
  // Returner AHB: DUT master outputs -> VIP master_if[0] (passive monitor)
  // VIP slave_if[0] responds to DUT master
  // ---------------------------------------------------------------
  assign ahb_ret_if.slave_if[0].haddr     = dut_ahbm_haddr;
  assign ahb_ret_if.slave_if[0].htrans    = dut_ahbm_htrans;
  assign ahb_ret_if.slave_if[0].hburst    = 3'b000; // SINGLE
  assign ahb_ret_if.slave_if[0].hsize     = dut_ahbm_hsize;
  assign ahb_ret_if.slave_if[0].hprot     = 4'h0;
  assign ahb_ret_if.slave_if[0].hwrite    = dut_ahbm_hwrite;
  assign ahb_ret_if.slave_if[0].hwdata    = dut_ahbm_hwdata;
  assign ahb_ret_if.slave_if[0].hmaster   = 4'h0;
  assign ahb_ret_if.slave_if[0].hmastlock = 1'b0;

  initial begin
    force ahb_ret_if.slave_if[0].hsel      = 1'b1;
    force ahb_ret_if.slave_if[0].hready_in = ahb_ret_if.slave_if[0].hready;
    force ahb_ret_if.master_if[0].haddr    = dut_ahbm_haddr;
    force ahb_ret_if.master_if[0].htrans   = dut_ahbm_htrans;
    force ahb_ret_if.master_if[0].hburst   = 3'b000;
    force ahb_ret_if.master_if[0].hsize    = dut_ahbm_hsize;
    force ahb_ret_if.master_if[0].hprot    = 4'h0;
    force ahb_ret_if.master_if[0].hwrite   = dut_ahbm_hwrite;
    force ahb_ret_if.master_if[0].hwdata   = dut_ahbm_hwdata;
    force ahb_ret_if.master_if[0].hready   = ahb_ret_if.slave_if[0].hready;
    force ahb_ret_if.master_if[0].hresp    = ahb_ret_if.slave_if[0].hresp;
    force ahb_ret_if.master_if[0].hrdata   = ahb_ret_if.slave_if[0].hrdata;
    force ahb_ret_if.master_if[0].hgrant   = 1'b1;
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
      "uvm_test_top.env.fifo_ahb_sys_env", "vif", ahb_fifo_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.ret_ahb_sys_env", "vif", ahb_ret_if);

    // Set APB interface for driver and monitor
    uvm_config_db#(virtual apb_master_if.driver)::set(uvm_root::get(),
      "uvm_test_top.env.apb_agt.driver", "vif", apb_if.driver);
    uvm_config_db#(virtual apb_master_if.monitor)::set(uvm_root::get(),
      "uvm_test_top.env.apb_agt.monitor", "vif", apb_if.monitor);

    // Plain virtual interface for clock/reset access in tests
    uvm_config_db#(virtual apb_master_if)::set(uvm_root::get(),
      "uvm_test_top", "vif", apb_if);

    run_test();
  end

endmodule
