///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for TideLink FC Adapter
// verification.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_PKG_SV
`define GUARD_TIDELINK_FC_ADAPTER_PKG_SV

package tidelink_fc_adapter_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---------------------------------------------------------------
  // FC agent
  // ---------------------------------------------------------------
  `include "fc_seq_item.sv"
  `include "fc_driver.sv"
  `include "fc_monitor.sv"
  `include "fc_sequencer.sv"
  `include "fc_agent.sv"

  // ---------------------------------------------------------------
  // AHB TX agents (master side, drive DUT's AHB slave ports)
  // ---------------------------------------------------------------
  `include "ahb_tx_seq_item.sv"
  `include "ahb_tx_driver.sv"
  `include "ahb_tx_sequencer.sv"
  `include "ahb_tx_agent.sv"
  `include "rtn_driver.sv"
  `include "rtn_agent.sv"

  // ---------------------------------------------------------------
  // AHB RX responders (slave side, respond to DUT's AHB master ports)
  // ---------------------------------------------------------------
  `include "ahb_rx_responder.sv"

  // ---------------------------------------------------------------
  // FC TX ready driver
  // ---------------------------------------------------------------
  `include "fc_tx_ready_driver.sv"

  // ---------------------------------------------------------------
  // Environment
  // ---------------------------------------------------------------
  `include "tidelink_fc_adapter_scoreboard.sv"
  `include "tidelink_fc_adapter_env.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "tidelink_fc_adapter_base_test.sv"
  `include "tidelink_fc_adapter_tx_test.sv"
  `include "tidelink_fc_adapter_sideband_test.sv"
  `include "tidelink_fc_adapter_rx_test.sv"
  `include "tidelink_fc_adapter_full_test.sv"

endpackage

`endif // GUARD_TIDELINK_FC_ADAPTER_PKG_SV
