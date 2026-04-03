///////////////////////////////////////////////////////////////////////////////
// tidelink_system_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for TideLink paired-system
// verification. Tests two FC adapter + FIFO subsystems connected back-to-back
// via FC crossover.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SYSTEM_PKG_SV
`define GUARD_TIDELINK_SYSTEM_PKG_SV

package tidelink_system_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;

  // ---------------------------------------------------------------
  // TideLink register map constants (shared with integration TB)
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

  // Side identifiers for parameterized sequences
  typedef enum bit {SIDE_A = 1'b0, SIDE_B = 1'b1} side_t;

  // ---------------------------------------------------------------
  // Reused sequences from integration testbench
  // ---------------------------------------------------------------
  `include "integration_cfg_write_sequence.sv"
  `include "integration_cfg_read_sequence.sv"
  `include "integration_init_sequence.sv"
  `include "integration_tx_write_sequence.sv"
  `include "integration_fifo_read_sequence.sv"

  // ---------------------------------------------------------------
  // Environment
  // ---------------------------------------------------------------
  `include "tidelink_system_coverage.sv"
  `include "tidelink_system_scoreboard.sv"
  `include "tidelink_system_vseq.sv"
  `include "tidelink_system_env.sv"

  // ---------------------------------------------------------------
  // System-level sequences
  // ---------------------------------------------------------------
  `include "sys_packet_sequence.sv"
  `include "sys_read_packet_sequence.sv"
  `include "sys_init_sequence.sv"
  `include "sys_credit_check_sequence.sv"
  `include "sys_bidirectional_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "tidelink_system_base_test.sv"
  `include "test_single_packet.sv"
  `include "test_bidirectional.sv"
  `include "test_back_to_back.sv"
  `include "test_max_packet.sv"
  `include "test_credit_exhaustion.sv"
  `include "test_credit_threshold.sv"
  `include "test_sideband_stress.sv"
  `include "test_interleaved_types.sv"
  `include "test_error_injection.sv"
  `include "test_reset_recovery.sv"
  `include "test_long_running.sv"

endpackage

`endif // GUARD_TIDELINK_SYSTEM_PKG_SV
