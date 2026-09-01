///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for TideLink integration
// verification.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_PKG_SV
`define GUARD_TIDELINK_INTEGRATION_PKG_SV

package tidelink_integration_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;

  // ---------------------------------------------------------------
  // APB master agent (reused from unit-level testbench)
  // ---------------------------------------------------------------
  `include "apb_master_transaction.sv"
  `include "apb_master_driver.sv"
  `include "apb_master_monitor.sv"
  `include "apb_master_sequencer.sv"
  `include "apb_master_agent.sv"

  // ---------------------------------------------------------------
  // TideLink register map constants (shared with unit-level TB)
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
  // Environment
  // ---------------------------------------------------------------
  `include "tidelink_integration_config.sv"
  `include "tidelink_integration_scoreboard.sv"
  `include "tidelink_integration_env.sv"

  // ---------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------
  // Config sequences (APB-based, with 0x2000 offset for TideLink regs)
  `include "integration_cfg_write_sequence.sv"
  `include "integration_cfg_read_sequence.sv"
  `include "integration_init_sequence.sv"
  // Data path sequences (AHB-based, unchanged)
  `include "integration_tx_write_sequence.sv"
  `include "integration_fifo_read_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "tidelink_integration_base_test.sv"
  `include "tidelink_integration_loopback_test.sv"
  `include "tidelink_integration_credit_test.sv"
  `include "tidelink_integration_stress_test.sv"
  `include "tidelink_integration_scoreboard_loss_selftest.sv"

endpackage

`endif // GUARD_TIDELINK_INTEGRATION_PKG_SV
