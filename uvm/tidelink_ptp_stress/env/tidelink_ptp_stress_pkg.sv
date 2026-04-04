///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_stress_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for PTP delay-variance
// characterisation under different interconnect load conditions.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_STRESS_PKG_SV
`define GUARD_TIDELINK_PTP_STRESS_PKG_SV

package tidelink_ptp_stress_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;

  // ---------------------------------------------------------------
  // TideLink register map constants (shared with tidelink_top_system)
  // ---------------------------------------------------------------
  parameter REG_PAIR_BASE      = 12'h000;
  parameter REG_REL_THRESHOLD  = 12'h004;
  parameter REG_PKT_WORD_LEN   = 12'h008;
  parameter REG_CREDIT_COUNT   = 12'h00C;
  parameter REG_STATUS         = 12'h010;
  parameter REG_DOORBELL       = 12'h014;
  parameter REG_REL_ACC        = 12'h018;
  parameter REG_CTRL           = 12'h01C;

  parameter REG_RELEASED_ACC        = 12'h020;
  parameter REG_DOORBELL_RESP_ACC   = 12'h024;
  parameter REG_PAIR_CREDIT_COUNTER = 12'h028;
  parameter REG_PAIR_CREDIT_CONSUME = 12'h02C;
  parameter REG_PAIR_CREDIT_ENABLE  = 12'h030;

  // PTP register offsets
  parameter REG_PTP_CTRL       = 12'h034;
  parameter REG_PTP_RX_PAYLOAD = 12'h038;
  parameter REG_PTP_STATUS     = 12'h03C;

  // PHC register offsets
  parameter REG_PHC_CTRL               = 12'h040;
  parameter REG_PHC_NS_INCR            = 12'h044;
  parameter REG_PHC_HW_CAP_SECONDS_LO  = 12'h050;
  parameter REG_PHC_HW_CAP_SECONDS_HI  = 12'h054;
  parameter REG_PHC_HW_CAP_NANOSECONDS = 12'h058;

  // Status register bit positions
  parameter STATUS_RETURNER_BUSY    = 0;
  parameter STATUS_OVERRUN          = 1;
  parameter STATUS_UNDERRUN         = 2;
  parameter STATUS_MASTER_ERROR     = 3;
  parameter STATUS_PACKET_COMMITTED = 4;

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
  `include "ptp_config.sv"
  `include "ptp_scoreboard.sv"
  `include "ptp_coverage.sv"
  `include "tidelink_ptp_stress_env.sv"

  // ---------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------
  `include "top_sys_wlink_init_sequence.sv"
  `include "top_sys_init_sequence.sv"
  `include "top_sys_ahb_sub_sequence.sv"
  `include "ptp_init_sequence.sv"
  `include "ptp_sync_sequence.sv"
  `include "mixed_load_virtual_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "ptp_stress_base_test.sv"
  `include "ptp_idle_baseline_test.sv"
  `include "ptp_all_saturated_test.sv"

endpackage

`endif // GUARD_TIDELINK_PTP_STRESS_PKG_SV
