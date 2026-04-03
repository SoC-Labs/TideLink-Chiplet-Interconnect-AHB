///////////////////////////////////////////////////////////////////////////////
// top.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM testbench for TideLink FC Adapter verification.
//
// Instantiates the DUT with:
//   - Custom interface for all AHB and FC ports
//   - UVM config_db setup for all agents
///////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

`include "uvm_pkg.sv"

// Interface (must be outside module)
`include "tidelink_fc_adapter_if.sv"

// Testbench package (must be outside module)
`include "tidelink_fc_adapter_pkg.sv"

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
  import tidelink_fc_adapter_pkg::*;

  // ---------------------------------------------------------------
  // Interface instance
  // ---------------------------------------------------------------
  tidelink_fc_adapter_if dut_if(.clk(clk), .rst_n(rst_n));

  // ---------------------------------------------------------------
  // AHB TX HREADY feedback
  // ---------------------------------------------------------------
  // The DUT's ahb_tx_hready input should reflect hreadyout for
  // back-to-back transfers (AHB-Lite single-master convention).
  // The agent drives hready via the clocking block; we wire
  // hreadyout back to it here so the DUT sees the correct value.
  assign dut_if.ahb_tx_hready = dut_if.ahb_tx_hreadyout;

  // ---------------------------------------------------------------
  // DUT instantiation
  // ---------------------------------------------------------------
  tidelink_fc_adapter #(
    .SYS_ADDR_W (32),
    .SYS_DATA_W (32),
    .RAM_ADDR_W (14),
    .APB_ADDR_W (12),
    .FC_DATA_W  (48)
  ) u_dut (
    .hclk               (clk),
    .hresetn             (rst_n),

    // AHB Slave — TX Aperture
    .ahb_tx_hsel         (dut_if.ahb_tx_hsel),
    .ahb_tx_haddr        (dut_if.ahb_tx_haddr),
    .ahb_tx_htrans       (dut_if.ahb_tx_htrans),
    .ahb_tx_hsize        (dut_if.ahb_tx_hsize),
    .ahb_tx_hwrite       (dut_if.ahb_tx_hwrite),
    .ahb_tx_hwdata       (dut_if.ahb_tx_hwdata),
    .ahb_tx_hready       (dut_if.ahb_tx_hready),
    .ahb_tx_hrdata       (dut_if.ahb_tx_hrdata),
    .ahb_tx_hresp        (dut_if.ahb_tx_hresp),
    .ahb_tx_hreadyout    (dut_if.ahb_tx_hreadyout),

    // AHB Slave — Returner Interception
    .rtn_haddr           (dut_if.rtn_haddr),
    .rtn_hwdata          (dut_if.rtn_hwdata),
    .rtn_htrans          (dut_if.rtn_htrans),
    .rtn_hsize           (dut_if.rtn_hsize),
    .rtn_hwrite          (dut_if.rtn_hwrite),
    .rtn_hready          (dut_if.rtn_hready),
    .rtn_hresp           (dut_if.rtn_hresp),
    .rtn_hrdata          (dut_if.rtn_hrdata),

    // AHB Master — RX FIFO Path
    .fc_rx_fifo_haddr    (dut_if.fc_rx_fifo_haddr),
    .fc_rx_fifo_hwdata   (dut_if.fc_rx_fifo_hwdata),
    .fc_rx_fifo_htrans   (dut_if.fc_rx_fifo_htrans),
    .fc_rx_fifo_hsize    (dut_if.fc_rx_fifo_hsize),
    .fc_rx_fifo_hwrite   (dut_if.fc_rx_fifo_hwrite),
    .fc_rx_fifo_hready   (dut_if.fc_rx_fifo_hready),
    .fc_rx_fifo_hresp    (dut_if.fc_rx_fifo_hresp),
    .fc_rx_fifo_hrdata   (dut_if.fc_rx_fifo_hrdata),

    // AHB Master — RX Config Path
    .fc_rx_cfg_haddr     (dut_if.fc_rx_cfg_haddr),
    .fc_rx_cfg_hwdata    (dut_if.fc_rx_cfg_hwdata),
    .fc_rx_cfg_htrans    (dut_if.fc_rx_cfg_htrans),
    .fc_rx_cfg_hsize     (dut_if.fc_rx_cfg_hsize),
    .fc_rx_cfg_hwrite    (dut_if.fc_rx_cfg_hwrite),
    .fc_rx_cfg_hready    (dut_if.fc_rx_cfg_hready),
    .fc_rx_cfg_hresp     (dut_if.fc_rx_cfg_hresp),
    .fc_rx_cfg_hrdata    (dut_if.fc_rx_cfg_hrdata),

    // FC Node Interface
    .tl_fc_a2l_valid     (dut_if.tl_fc_a2l_valid),
    .tl_fc_a2l_data      (dut_if.tl_fc_a2l_data),
    .tl_fc_a2l_ready     (dut_if.tl_fc_a2l_ready),
    .tl_fc_l2a_valid     (dut_if.tl_fc_l2a_valid),
    .tl_fc_l2a_data      (dut_if.tl_fc_l2a_data),
    .tl_fc_l2a_accept    (dut_if.tl_fc_l2a_accept)
  );

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
    // Set the main DUT interface
    uvm_config_db#(virtual tidelink_fc_adapter_if)::set(
      uvm_root::get(), "*", "dut_vif", dut_if);

    run_test();
  end

endmodule
