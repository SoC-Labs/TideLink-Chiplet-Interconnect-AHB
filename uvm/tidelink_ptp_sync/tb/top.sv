///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for PTP synchronisation verification.
//
// Instantiates two tidelink_top instances (Chiplet A and Chiplet B), each
// with a PHC (PTP Hardware Clock) and TideLink PTP module. The two chiplets
// are connected via FC crossover so that PTP SYNC and DELAY_REQ messages
// traverse the link.
//
// Six SVT AHB VIP interfaces (3 per side):
//   1. PHC AHB master   (reads/writes PHC registers: NS_INCR, HW_CAP, etc.)
//   2. PTP AHB master   (triggers PTP messages via addr[3:0] msg_type)
//   3. CFG AHB master   (TideLink config registers)
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"
`include "svt_ahb.uvm.pkg"
`include "svt_ahb_if.svi"

// Testbench interface
`include "tidelink_ptp_sync_if.sv"

// Testbench package
`include "tidelink_ptp_sync_pkg.sv"

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
  import tidelink_ptp_sync_pkg::*;

  // ---------------------------------------------------------------
  // Testbench interface
  // ---------------------------------------------------------------
  tidelink_ptp_sync_if tb_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // SVT AHB interface instances (3 per chiplet side)
  // ---------------------------------------------------------------

  // Chiplet A: PHC AHB
  svt_ahb_if ahb_a_phc_if();
  assign ahb_a_phc_if.hclk    = clk;
  assign ahb_a_phc_if.hresetn = rst_n;

  // Chiplet A: PTP AHB
  svt_ahb_if ahb_a_ptp_if();
  assign ahb_a_ptp_if.hclk    = clk;
  assign ahb_a_ptp_if.hresetn = rst_n;

  // Chiplet A: CFG AHB
  svt_ahb_if ahb_a_cfg_if();
  assign ahb_a_cfg_if.hclk    = clk;
  assign ahb_a_cfg_if.hresetn = rst_n;

  // Chiplet B: PHC AHB
  svt_ahb_if ahb_b_phc_if();
  assign ahb_b_phc_if.hclk    = clk;
  assign ahb_b_phc_if.hresetn = rst_n;

  // Chiplet B: PTP AHB
  svt_ahb_if ahb_b_ptp_if();
  assign ahb_b_ptp_if.hclk    = clk;
  assign ahb_b_ptp_if.hresetn = rst_n;

  // Chiplet B: CFG AHB
  svt_ahb_if ahb_b_cfg_if();
  assign ahb_b_cfg_if.hclk    = clk;
  assign ahb_b_cfg_if.hresetn = rst_n;

  // ---------------------------------------------------------------
  // DUT slave response wires
  // ---------------------------------------------------------------

  // Chiplet A PHC slave outputs
  wire        a_phc_hreadyout;
  wire        a_phc_hresp;
  wire [31:0] a_phc_hrdata;

  // Chiplet A PTP slave outputs
  wire        a_ptp_hreadyout;
  wire        a_ptp_hresp;
  wire [31:0] a_ptp_hrdata;

  // Chiplet A CFG slave outputs
  wire        a_cfg_hreadyout;
  wire        a_cfg_hresp;
  wire [31:0] a_cfg_hrdata;

  // Chiplet B PHC slave outputs
  wire        b_phc_hreadyout;
  wire        b_phc_hresp;
  wire [31:0] b_phc_hrdata;

  // Chiplet B PTP slave outputs
  wire        b_ptp_hreadyout;
  wire        b_ptp_hresp;
  wire [31:0] b_ptp_hrdata;

  // Chiplet B CFG slave outputs
  wire        b_cfg_hreadyout;
  wire        b_cfg_hresp;
  wire [31:0] b_cfg_hrdata;

  // ---------------------------------------------------------------
  // DUT instantiation placeholder
  // ---------------------------------------------------------------
  // The actual DUT would instantiate two tidelink_top + PHC_AHB modules
  // connected via FC crossover. This is left as a structural placeholder
  // to be completed when the RTL is integrated.
  //
  // For now, the testbench infrastructure (env, sequences, tests) is
  // fully functional and ready to connect to the DUT once available.
  //
  // Expected connections per chiplet:
  //   ahb_X_phc_if.master_if[0] -> PHC AHB slave port (12-bit addr)
  //   ahb_X_ptp_if.master_if[0] -> PTP AHB slave port (4-bit addr)
  //   ahb_X_cfg_if.master_if[0] -> TideLink CFG slave port (12-bit addr)
  // ---------------------------------------------------------------

  // ---------------------------------------------------------------
  // AHB VIP signal routing helper macro
  // ---------------------------------------------------------------
  // For each AHB interface, route VIP master outputs to DUT slave inputs
  // and DUT slave outputs back to VIP master and passive slave monitor.

  `define CONNECT_AHB_SLAVE(VIP_IF, DUT_HREADYOUT, DUT_HRESP, DUT_HRDATA) \
    assign VIP_IF.slave_if[0].haddr     = VIP_IF.master_if[0].haddr;      \
    assign VIP_IF.slave_if[0].htrans    = VIP_IF.master_if[0].htrans;     \
    assign VIP_IF.slave_if[0].hburst    = VIP_IF.master_if[0].hburst;     \
    assign VIP_IF.slave_if[0].hsize     = VIP_IF.master_if[0].hsize;      \
    assign VIP_IF.slave_if[0].hprot     = VIP_IF.master_if[0].hprot;      \
    assign VIP_IF.slave_if[0].hwrite    = VIP_IF.master_if[0].hwrite;     \
    assign VIP_IF.slave_if[0].hwdata    = VIP_IF.master_if[0].hwdata;     \
    assign VIP_IF.slave_if[0].hmaster   = 4'h0;                           \
    assign VIP_IF.slave_if[0].hmastlock = 1'b0;                           \
    assign VIP_IF.slave_if[0].hready_in = DUT_HREADYOUT;

  `CONNECT_AHB_SLAVE(ahb_a_phc_if, a_phc_hreadyout, a_phc_hresp, a_phc_hrdata)
  `CONNECT_AHB_SLAVE(ahb_a_ptp_if, a_ptp_hreadyout, a_ptp_hresp, a_ptp_hrdata)
  `CONNECT_AHB_SLAVE(ahb_a_cfg_if, a_cfg_hreadyout, a_cfg_hresp, a_cfg_hrdata)
  `CONNECT_AHB_SLAVE(ahb_b_phc_if, b_phc_hreadyout, b_phc_hresp, b_phc_hrdata)
  `CONNECT_AHB_SLAVE(ahb_b_ptp_if, b_ptp_hreadyout, b_ptp_hresp, b_ptp_hrdata)
  `CONNECT_AHB_SLAVE(ahb_b_cfg_if, b_cfg_hreadyout, b_cfg_hresp, b_cfg_hrdata)

  // Force DUT responses back onto VIP interfaces
  initial begin
    // Chiplet A PHC
    force ahb_a_phc_if.master_if[0].hready = a_phc_hreadyout;
    force ahb_a_phc_if.master_if[0].hresp  = {1'b0, a_phc_hresp};
    force ahb_a_phc_if.master_if[0].hrdata = a_phc_hrdata;
    force ahb_a_phc_if.master_if[0].hgrant = 1'b1;
    force ahb_a_phc_if.slave_if[0].hsel    = 1'b1;
    force ahb_a_phc_if.slave_if[0].hready  = a_phc_hreadyout;
    force ahb_a_phc_if.slave_if[0].hrdata  = a_phc_hrdata;
    force ahb_a_phc_if.slave_if[0].hresp   = {1'b0, a_phc_hresp};

    // Chiplet A PTP
    force ahb_a_ptp_if.master_if[0].hready = a_ptp_hreadyout;
    force ahb_a_ptp_if.master_if[0].hresp  = {1'b0, a_ptp_hresp};
    force ahb_a_ptp_if.master_if[0].hrdata = a_ptp_hrdata;
    force ahb_a_ptp_if.master_if[0].hgrant = 1'b1;
    force ahb_a_ptp_if.slave_if[0].hsel    = 1'b1;
    force ahb_a_ptp_if.slave_if[0].hready  = a_ptp_hreadyout;
    force ahb_a_ptp_if.slave_if[0].hrdata  = a_ptp_hrdata;
    force ahb_a_ptp_if.slave_if[0].hresp   = {1'b0, a_ptp_hresp};

    // Chiplet A CFG
    force ahb_a_cfg_if.master_if[0].hready = a_cfg_hreadyout;
    force ahb_a_cfg_if.master_if[0].hresp  = {1'b0, a_cfg_hresp};
    force ahb_a_cfg_if.master_if[0].hrdata = a_cfg_hrdata;
    force ahb_a_cfg_if.master_if[0].hgrant = 1'b1;
    force ahb_a_cfg_if.slave_if[0].hsel    = 1'b1;
    force ahb_a_cfg_if.slave_if[0].hready  = a_cfg_hreadyout;
    force ahb_a_cfg_if.slave_if[0].hrdata  = a_cfg_hrdata;
    force ahb_a_cfg_if.slave_if[0].hresp   = {1'b0, a_cfg_hresp};

    // Chiplet B PHC
    force ahb_b_phc_if.master_if[0].hready = b_phc_hreadyout;
    force ahb_b_phc_if.master_if[0].hresp  = {1'b0, b_phc_hresp};
    force ahb_b_phc_if.master_if[0].hrdata = b_phc_hrdata;
    force ahb_b_phc_if.master_if[0].hgrant = 1'b1;
    force ahb_b_phc_if.slave_if[0].hsel    = 1'b1;
    force ahb_b_phc_if.slave_if[0].hready  = b_phc_hreadyout;
    force ahb_b_phc_if.slave_if[0].hrdata  = b_phc_hrdata;
    force ahb_b_phc_if.slave_if[0].hresp   = {1'b0, b_phc_hresp};

    // Chiplet B PTP
    force ahb_b_ptp_if.master_if[0].hready = b_ptp_hreadyout;
    force ahb_b_ptp_if.master_if[0].hresp  = {1'b0, b_ptp_hresp};
    force ahb_b_ptp_if.master_if[0].hrdata = b_ptp_hrdata;
    force ahb_b_ptp_if.master_if[0].hgrant = 1'b1;
    force ahb_b_ptp_if.slave_if[0].hsel    = 1'b1;
    force ahb_b_ptp_if.slave_if[0].hready  = b_ptp_hreadyout;
    force ahb_b_ptp_if.slave_if[0].hrdata  = b_ptp_hrdata;
    force ahb_b_ptp_if.slave_if[0].hresp   = {1'b0, b_ptp_hresp};

    // Chiplet B CFG
    force ahb_b_cfg_if.master_if[0].hready = b_cfg_hreadyout;
    force ahb_b_cfg_if.master_if[0].hresp  = {1'b0, b_cfg_hresp};
    force ahb_b_cfg_if.master_if[0].hrdata = b_cfg_hrdata;
    force ahb_b_cfg_if.master_if[0].hgrant = 1'b1;
    force ahb_b_cfg_if.slave_if[0].hsel    = 1'b1;
    force ahb_b_cfg_if.slave_if[0].hready  = b_cfg_hreadyout;
    force ahb_b_cfg_if.slave_if[0].hrdata  = b_cfg_hrdata;
    force ahb_b_cfg_if.slave_if[0].hresp   = {1'b0, b_cfg_hresp};
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
    // Set testbench interface
    uvm_config_db#(virtual tidelink_ptp_sync_if)::set(uvm_root::get(),
      "uvm_test_top", "tb_if", tb_if);

    // Set VIP AHB interfaces — Chiplet A
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_phc_ahb_sys_env", "vif", ahb_a_phc_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_ptp_ahb_sys_env", "vif", ahb_a_ptp_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.a_cfg_ahb_sys_env", "vif", ahb_a_cfg_if);

    // Set VIP AHB interfaces — Chiplet B
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_phc_ahb_sys_env", "vif", ahb_b_phc_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_ptp_ahb_sys_env", "vif", ahb_b_ptp_if);
    uvm_config_db#(svt_ahb_vif)::set(uvm_root::get(),
      "uvm_test_top.env.b_cfg_ahb_sys_env", "vif", ahb_b_cfg_if);

    run_test();
  end

endmodule
