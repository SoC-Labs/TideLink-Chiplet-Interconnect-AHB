///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface wrapping all DUT ports of tidelink_fc_adapter.
// Provides clocking blocks for each agent role:
//   - AHB master agents (drive TX aperture and returner slave ports)
//   - AHB slave agents (respond to RX FIFO and RX config master ports)
//   - FC TX monitor (observes a2l valid/data/ready)
//   - FC RX driver (drives l2a valid/data, monitors accept)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_IF_SV
`define GUARD_TIDELINK_FC_ADAPTER_IF_SV

interface tidelink_fc_adapter_if (
  input wire clk,
  input wire rst_n
);

  // ---------------------------------------------------------------
  // AHB Slave — TX Aperture (driven by AHB master agent)
  // ---------------------------------------------------------------
  logic              ahb_tx_hsel;
  logic [13:0]       ahb_tx_haddr;
  logic  [1:0]       ahb_tx_htrans;
  logic  [2:0]       ahb_tx_hsize;
  logic              ahb_tx_hwrite;
  logic [31:0]       ahb_tx_hwdata;
  logic              ahb_tx_hready;      // input to DUT (driven by agent)
  logic [31:0]       ahb_tx_hrdata;      // output from DUT
  logic              ahb_tx_hresp;       // output from DUT
  logic              ahb_tx_hreadyout;   // output from DUT

  // ---------------------------------------------------------------
  // AHB Slave — Returner Interception (driven by AHB master agent)
  // ---------------------------------------------------------------
  logic [31:0]       rtn_haddr;
  logic [31:0]       rtn_hwdata;
  logic  [1:0]       rtn_htrans;
  logic  [2:0]       rtn_hsize;
  logic              rtn_hwrite;
  logic              rtn_hready;         // output from DUT
  logic              rtn_hresp;          // output from DUT
  logic [31:0]       rtn_hrdata;         // output from DUT

  // ---------------------------------------------------------------
  // Direct Write — RX FIFO Path (DUT drives valid/write/addr/wdata,
  //                              responder drives ready)
  // ---------------------------------------------------------------
  logic              fc_rx_fifo_valid;   // output from DUT
  logic              fc_rx_fifo_write;   // output from DUT
  logic [13:0]       fc_rx_fifo_addr;    // output from DUT
  logic [31:0]       fc_rx_fifo_wdata;   // output from DUT
  logic              fc_rx_fifo_ready;   // input to DUT (driven by responder)

  // ---------------------------------------------------------------
  // APB Master — RX Config Path (DUT drives PSEL/PENABLE/PWRITE/...,
  //                              responder drives PREADY/PRDATA)
  // ---------------------------------------------------------------
  logic [11:0]       fc_rx_cfg_paddr;    // output from DUT
  logic [31:0]       fc_rx_cfg_pwdata;   // output from DUT
  logic              fc_rx_cfg_psel;     // output from DUT
  logic              fc_rx_cfg_penable;  // output from DUT
  logic              fc_rx_cfg_pwrite;   // output from DUT
  logic [31:0]       fc_rx_cfg_prdata;   // input to DUT (driven by responder)
  logic              fc_rx_cfg_pready;   // input to DUT (driven by responder)

  // ---------------------------------------------------------------
  // FC Node Interface — TX (DUT drives a2l, agent drives ready)
  // ---------------------------------------------------------------
  logic              tl_fc_a2l_valid;    // output from DUT
  logic [47:0]       tl_fc_a2l_data;     // output from DUT
  logic              tl_fc_a2l_ready;    // input to DUT (driven by agent)

  // ---------------------------------------------------------------
  // FC Node Interface — RX (agent drives l2a, DUT drives accept)
  // ---------------------------------------------------------------
  logic              tl_fc_l2a_valid;    // input to DUT (driven by agent)
  logic [47:0]       tl_fc_l2a_data;     // input to DUT (driven by agent)
  logic              tl_fc_l2a_accept;   // output from DUT

  // ---------------------------------------------------------------
  // Clocking block: AHB master driving TX aperture
  // ---------------------------------------------------------------
  clocking ahb_tx_drv_cb @(posedge clk);
    default input #1 output #1;
    output ahb_tx_hsel, ahb_tx_haddr, ahb_tx_htrans, ahb_tx_hsize;
    output ahb_tx_hwrite, ahb_tx_hwdata, ahb_tx_hready;
    input  ahb_tx_hrdata, ahb_tx_hresp, ahb_tx_hreadyout;
  endclocking

  // ---------------------------------------------------------------
  // Clocking block: AHB master driving returner interception
  // ---------------------------------------------------------------
  clocking rtn_drv_cb @(posedge clk);
    default input #1 output #1;
    output rtn_haddr, rtn_hwdata, rtn_htrans, rtn_hsize, rtn_hwrite;
    input  rtn_hready, rtn_hresp, rtn_hrdata;
  endclocking

  // ---------------------------------------------------------------
  // Clocking block: direct-write responder for RX FIFO path
  // ---------------------------------------------------------------
  clocking rx_fifo_slv_cb @(posedge clk);
    default input #1 output #1;
    input  fc_rx_fifo_valid, fc_rx_fifo_write, fc_rx_fifo_addr, fc_rx_fifo_wdata;
    output fc_rx_fifo_ready;
  endclocking

  // ---------------------------------------------------------------
  // Clocking block: APB responder for RX Config path
  // ---------------------------------------------------------------
  clocking rx_cfg_slv_cb @(posedge clk);
    default input #1 output #1;
    input  fc_rx_cfg_paddr, fc_rx_cfg_pwdata, fc_rx_cfg_psel;
    input  fc_rx_cfg_penable, fc_rx_cfg_pwrite;
    output fc_rx_cfg_prdata, fc_rx_cfg_pready;
  endclocking

  // ---------------------------------------------------------------
  // Clocking block: FC TX monitor (observes a2l, drives ready)
  // ---------------------------------------------------------------
  clocking fc_tx_cb @(posedge clk);
    default input #1 output #1;
    input  tl_fc_a2l_valid, tl_fc_a2l_data;
    output tl_fc_a2l_ready;
  endclocking

  // ---------------------------------------------------------------
  // Clocking block: FC RX driver (drives l2a, observes accept)
  // ---------------------------------------------------------------
  clocking fc_rx_cb @(posedge clk);
    default input #1 output #1;
    output tl_fc_l2a_valid, tl_fc_l2a_data;
    input  tl_fc_l2a_accept;
  endclocking

  // ---------------------------------------------------------------
  // Clocking block: passive monitor
  // ---------------------------------------------------------------
  clocking mon_cb @(posedge clk);
    default input #1;
    input ahb_tx_hsel, ahb_tx_haddr, ahb_tx_htrans, ahb_tx_hsize;
    input ahb_tx_hwrite, ahb_tx_hwdata, ahb_tx_hready;
    input ahb_tx_hrdata, ahb_tx_hresp, ahb_tx_hreadyout;
    input rtn_haddr, rtn_hwdata, rtn_htrans, rtn_hsize, rtn_hwrite;
    input rtn_hready, rtn_hresp, rtn_hrdata;
    input fc_rx_fifo_valid, fc_rx_fifo_write, fc_rx_fifo_addr;
    input fc_rx_fifo_wdata, fc_rx_fifo_ready;
    input fc_rx_cfg_paddr, fc_rx_cfg_pwdata, fc_rx_cfg_psel;
    input fc_rx_cfg_penable, fc_rx_cfg_pwrite, fc_rx_cfg_pready;
    input tl_fc_a2l_valid, tl_fc_a2l_data, tl_fc_a2l_ready;
    input tl_fc_l2a_valid, tl_fc_l2a_data, tl_fc_l2a_accept;
  endclocking

  // ---------------------------------------------------------------
  // Modports
  // ---------------------------------------------------------------
  modport ahb_tx_master  (clocking ahb_tx_drv_cb, input clk, input rst_n);
  modport rtn_master     (clocking rtn_drv_cb, input clk, input rst_n);
  modport rx_fifo_slave  (clocking rx_fifo_slv_cb, input clk, input rst_n);
  modport rx_cfg_slave   (clocking rx_cfg_slv_cb, input clk, input rst_n);
  modport fc_tx_monitor  (clocking fc_tx_cb, input clk, input rst_n);
  modport fc_rx_driver   (clocking fc_rx_cb, input clk, input rst_n);
  modport monitor        (clocking mon_cb, input clk, input rst_n);

endinterface

`endif // GUARD_TIDELINK_FC_ADAPTER_IF_SV
