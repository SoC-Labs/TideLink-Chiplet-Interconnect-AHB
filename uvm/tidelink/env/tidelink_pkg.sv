///////////////////////////////////////////////////////////////////////////////
// tidelink_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for TideLink verification.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PKG_SV
`define GUARD_TIDELINK_PKG_SV

package tidelink_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;

  // ---------------------------------------------------------------
  // TideLink register map constants
  // ---------------------------------------------------------------
  // Region 0: Configuration and Status
  parameter REG_PAIR_BASE      = 12'h000;
  parameter REG_REL_THRESHOLD  = 12'h004;
  parameter REG_PKT_WORD_LEN   = 12'h008;
  parameter REG_CREDIT_COUNT    = 12'h00C;
  parameter REG_STATUS         = 12'h010;
  parameter REG_DOORBELL       = 12'h014;
  parameter REG_REL_ACC        = 12'h018;
  parameter REG_CTRL           = 12'h01C;

  // Region 1: Incoming Credit Receivers
  parameter REG_RELEASED_ACC       = 12'h020;
  parameter REG_DOORBELL_RESP_ACC  = 12'h024;
  parameter REG_PAIR_CREDIT_COUNTER = 12'h028;
  parameter REG_PAIR_CREDIT_CONSUME = 12'h02C;
  parameter REG_PAIR_CREDIT_ENABLE  = 12'h030;

  // Status register bit positions
  parameter STATUS_RETURNER_BUSY    = 0;
  parameter STATUS_OVERRUN          = 1;
  parameter STATUS_UNDERRUN         = 2;
  parameter STATUS_MASTER_ERROR     = 3;
  parameter STATUS_PACKET_COMMITTED = 4;

  // CTRL register bit positions
  // CTRL_EN removed: FIFO is now always enabled, EN bit no longer exists in HW
  parameter CTRL_FLUSH = 1;

  // Hardware constants
  parameter RAM_ADDR_W  = 14;
  parameter MAX_CREDITS  = (1 << (RAM_ADDR_W - 2)); // 4096

  // ---------------------------------------------------------------
  // APB master agent
  // ---------------------------------------------------------------
  `include "apb_master_transaction.sv"
  `include "apb_master_driver.sv"
  `include "apb_master_monitor.sv"
  `include "apb_master_sequencer.sv"
  `include "apb_master_agent.sv"

  // ---------------------------------------------------------------
  // Environment
  // ---------------------------------------------------------------
  `include "tidelink_config.sv"
  `include "tidelink_scoreboard.sv"
  `include "tidelink_env.sv"

  // ---------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------
  `include "apb_write_sequence.sv"
  `include "apb_read_sequence.sv"
  `include "tidelink_init_sequence.sv"
  `include "ahb_packet_write_sequence.sv"
  `include "ahb_packet_read_sequence.sv"
  `include "ahb_random_packet_sequence.sv"
  `include "ahb_gapped_packet_write_sequence.sv"
  `include "ahb_gapped_packet_read_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "tidelink_base_test.sv"
  `include "tidelink_register_test.sv"
  `include "tidelink_single_packet_test.sv"
  `include "tidelink_random_test.sv"
  `include "tidelink_stall_test.sv"
  `include "tidelink_scoreboard_loss_selftest.sv"

endpackage

`endif // GUARD_TIDELINK_PKG_SV
