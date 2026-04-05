///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for TideLink PTP chain
// verification. Three-hop chain: A <-> B1/B2 <-> C with cascaded PTP
// synchronisation across dedicated FC nodes.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_PKG_SV
`define GUARD_TIDELINK_PTP_CHAIN_PKG_SV

package tidelink_ptp_chain_pkg;

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
  parameter CTRL_FLUSH = 1;

  // Hardware constants
  parameter RAM_ADDR_W  = 14;
  parameter MAX_CREDITS = (1 << (RAM_ADDR_W - 2)); // 4096

  // ---------------------------------------------------------------
  // PTP register offsets
  // ---------------------------------------------------------------
  parameter REG_PTP_CTRL          = 12'h034;
  parameter REG_PTP_RX_PAYLOAD    = 12'h038;
  parameter REG_PTP_STATUS        = 12'h03C;
  parameter REG_HW_SYNC_CTRL      = 12'h040;
  parameter REG_HW_SYNC_INTERVAL  = 12'h044;
  parameter REG_HW_SYNC_STATUS    = 12'h048;
  parameter REG_SERVO_CTRL        = 12'h04C;
  parameter REG_SERVO_KP          = 12'h050;
  parameter REG_SERVO_KI          = 12'h054;
  parameter REG_SERVO_STEP_THRESH = 12'h058;
  parameter REG_SERVO_STATUS      = 12'h05C;
  parameter REG_SERVO_DELAY       = 12'h060;
  parameter REG_SERVO_NS_FRAC     = 12'h064;

  // ---------------------------------------------------------------
  // Side identifiers
  // ---------------------------------------------------------------
  typedef enum bit [1:0] {SIDE_A=2'b00, SIDE_B1=2'b01, SIDE_B2=2'b10, SIDE_C=2'b11} side_t;

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
  `include "tidelink_ptp_chain_config.sv"
  `include "tidelink_ptp_chain_coverage.sv"
  `include "tidelink_ptp_chain_scoreboard.sv"
  `include "tidelink_ptp_chain_vseq.sv"
  `include "tidelink_ptp_chain_env.sv"

  // ---------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------
  `include "top_sys_wlink_init_sequence.sv"
  `include "top_sys_init_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "tidelink_ptp_chain_base_test.sv"
  `include "test_chain_convergence.sv"
  `include "test_chain_lock_propagation.sv"
  `include "test_chain_step_recovery.sv"
  `include "test_chain_b_unlock_c_holds.sv"
  `include "test_chain_stress.sv"
  `include "test_chain_force_enable.sv"

endpackage

`endif // GUARD_TIDELINK_PTP_CHAIN_PKG_SV
