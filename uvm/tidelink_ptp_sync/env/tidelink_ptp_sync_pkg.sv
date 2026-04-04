///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_sync_pkg.sv
///////////////////////////////////////////////////////////////////////////////
// Package containing all UVM testbench components for PTP synchronisation
// verification. Tests that two chiplets with independent PHCs can synchronise
// via TideLink PTP exchanges, and recover when intentionally desynchronised.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_SYNC_PKG_SV
`define GUARD_TIDELINK_PTP_SYNC_PKG_SV

package tidelink_ptp_sync_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import svt_uvm_pkg::*;
  import svt_ahb_uvm_pkg::*;

  // ---------------------------------------------------------------
  // PHC register map constants (12-bit AHB address space)
  // ---------------------------------------------------------------
  parameter PHC_REG_CTRL              = 12'h000;  // bit[1]=SET_TIME
  parameter PHC_REG_NS_INCR           = 12'h008;
  parameter PHC_REG_NS_INCR_FRAC      = 12'h00C;
  parameter PHC_REG_SET_SECONDS_LO    = 12'h010;
  parameter PHC_REG_SET_NANOSECONDS   = 12'h018;
  parameter PHC_REG_HW_CAP_SECONDS_LO = 12'h040;
  parameter PHC_REG_HW_CAP_NANOSECONDS = 12'h048;

  // PHC CTRL bit positions
  parameter PHC_CTRL_SET_TIME = 1;

  // ---------------------------------------------------------------
  // PTP register map constants (4-bit AHB address via addr[3:0])
  // ---------------------------------------------------------------
  parameter PTP_REG_CTRL        = 12'h034;  // bit[0]=enable, bit[1]=clear
  parameter PTP_REG_RX_PAYLOAD  = 12'h038;

  // PTP CTRL bit positions
  parameter PTP_CTRL_ENABLE = 0;
  parameter PTP_CTRL_CLEAR  = 1;

  // ---------------------------------------------------------------
  // PTP message types (used as addr[3:0] for PTP AHB slave)
  // ---------------------------------------------------------------
  parameter PTP_MSG_SYNC       = 4'h0;
  parameter PTP_MSG_DELAY_REQ  = 4'h1;
  parameter PTP_MSG_DELAY_RESP = 4'h3;

  // ---------------------------------------------------------------
  // TideLink config register map constants (shared with other TBs)
  // ---------------------------------------------------------------
  parameter REG_PAIR_BASE           = 12'h000;
  parameter REG_REL_THRESHOLD       = 12'h004;
  parameter REG_PAIR_CREDIT_ENABLE  = 12'h030;

  // Side identifiers
  typedef enum bit {SIDE_A = 1'b0, SIDE_B = 1'b1} side_t;

  // ---------------------------------------------------------------
  // Environment components
  // ---------------------------------------------------------------
  `include "ptp_sync_config.sv"
  `include "ptp_servo_model.sv"
  `include "ptp_sync_coverage.sv"
  `include "ptp_sync_scoreboard.sv"
  `include "ptp_sync_vseq.sv"
  `include "tidelink_ptp_sync_env.sv"

  // ---------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------
  `include "ahb_reg_write_sequence.sv"
  `include "ahb_reg_read_sequence.sv"
  `include "phc_init_sequence.sv"
  `include "ptp_exchange_sequence.sv"
  `include "ptp_servo_sequence.sv"
  `include "phc_offset_inject_sequence.sv"
  `include "phc_drift_inject_sequence.sv"

  // ---------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------
  `include "ptp_sync_base_test.sv"
  `include "test_initial_offset.sv"
  `include "test_frequency_drift.sv"
  `include "test_step_change.sv"
  `include "test_long_term_stability.sv"

endpackage

`endif // GUARD_TIDELINK_PTP_SYNC_PKG_SV
