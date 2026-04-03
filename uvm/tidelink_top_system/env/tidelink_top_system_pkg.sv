///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for TideLink full
// tidelink_top paired-system verification. Two complete tidelink_top
// modules connected back-to-back via PHY pad crossover.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_PKG_SV
`define GUARD_TIDELINK_TOP_SYSTEM_PKG_SV

package tidelink_top_system_pkg;

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
  parameter REG_CREDIT_COUNT   = 12'h00C;
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
  parameter CTRL_EN    = 0;
  parameter CTRL_FLUSH = 1;

  // Hardware constants
  parameter RAM_ADDR_W  = 14;
  parameter MAX_CREDITS = (1 << (RAM_ADDR_W - 2)); // 4096

  // Side identifiers
  typedef enum bit {SIDE_A = 1'b0, SIDE_B = 1'b1} side_t;

  // ---------------------------------------------------------------
  // APB master agent (reused from unit test)
  // ---------------------------------------------------------------
  `include "apb_master_transaction.sv"
  `include "apb_master_driver.sv"
  `include "apb_master_monitor.sv"
  `include "apb_master_sequencer.sv"
  `include "apb_master_agent.sv"

  // ---------------------------------------------------------------
  // Reused sequences from integration testbench
  // ---------------------------------------------------------------
  `include "integration_cfg_write_sequence.sv"
  `include "integration_cfg_read_sequence.sv"
  `include "integration_tx_write_sequence.sv"
  `include "integration_fifo_read_sequence.sv"

  // ---------------------------------------------------------------
  // Environment components
  // ---------------------------------------------------------------
  `include "tidelink_top_system_coverage.sv"
  `include "tidelink_top_system_scoreboard.sv"
  `include "tidelink_top_system_vseq.sv"
  `include "tidelink_top_system_env.sv"

  // ---------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------
  `include "top_sys_wlink_init_sequence.sv"
  `include "top_sys_init_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "tidelink_top_system_base_test.sv"
  `include "test_top_single_packet.sv"
  `include "test_top_bidirectional.sv"
  `include "test_top_back_to_back.sv"
  `include "test_top_max_packet.sv"
  `include "test_top_credit_exhaustion.sv"
  `include "test_top_ahb_passthrough.sv"
  `include "test_top_reset_recovery.sv"
  `include "test_top_long_running.sv"
  `include "test_top_mixed_traffic.sv"

endpackage

`endif // GUARD_TIDELINK_TOP_SYSTEM_PKG_SV
