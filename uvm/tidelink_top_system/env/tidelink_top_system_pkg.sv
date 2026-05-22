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
  // CTRL_EN removed: FIFO is now always enabled, EN bit no longer exists in HW
  parameter CTRL_FLUSH = 1;

  // Region 4: Auto-negotiation registers
  parameter REG_NEGO_CFG      = 12'h090;
  parameter REG_NEGO_STATUS   = 12'h094;
  parameter REG_NEGO_PRIORITY = 12'h098;
  parameter REG_NEGO_TIMEOUT  = 12'h09C;
  parameter REG_I2C_PRESCALE  = 12'h08C;  // ctrl_reg_addr 3 (was 0x0A0 — pre-existing bug, that lives in perf region)

  // NEGO_STATUS bit positions. State field widened from 3 to 4 bits in
  // Phase 2 to host the new ST_NEGO_MASK_RES_TX state, so all the higher
  // bits shift up by 1.
  parameter NEGO_STATUS_DONE     = 4;
  parameter NEGO_STATUS_ERROR    = 5;
  parameter NEGO_STATUS_WON      = 6;
  parameter NEGO_STATUS_LOST     = 7;
  parameter NEGO_STATUS_SDA_SEEN = 8;
  parameter NEGO_STATUS_MASK_MM  = 9;

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
  `include "top_sys_wlink_lane_mask_sequence.sv"
  `include "top_sys_autoneg_sequence.sv"
  `include "top_sys_init_sequence.sv"
  `include "top_sys_ahb_sub_sequence.sv"

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
  `include "test_top_coordinated_reset.sv"
  `include "test_top_addr_translate.sv"
  `include "test_top_autoneg_basic.sv"
  `include "test_top_autoneg_bypass.sv"
  `include "test_top_autoneg_timeout.sv"
  // Lane mask family — base test plus 6 mask scenarios + 1 mid-stream + 1 err-inj.
  // The base class is virtual and not directly runnable; the canonical drop-high
  // test uses test_top_lane_mask, with the rest being thin parameter wrappers.
  `include "test_top_lane_mask_base.sv"
  `include "test_top_lane_mask.sv"
  `include "test_top_lane_mask_drop_middle.sv"
  `include "test_top_lane_mask_single_lane.sv"
  `include "test_top_lane_mask_two_drops.sv"
  `include "test_top_lane_mask_asymmetric.sv"
  `include "test_top_lane_mask_midstream.sv"
  `include "test_top_lane_mask_with_err_inj.sv"
  // Phase 4 — PHY gating + damaged-lane recovery
  `include "test_top_lane_mask_phy_gating.sv"
  `include "test_top_lane_mask_damaged_lane.sv"
  `include "test_top_lane_mask_damaged_lane_unmasked.sv"
  // Phase 5 — diagnostic sweep over mismatched mask pairs (writes CSV report)
  `include "test_top_lane_mask_mismatch_sweep.sv"
  // Phase 7 — random-mask soak (also drops cg_lane_mask coverage samples)
  `include "test_top_lane_mask_random_soak.sv"
  // Peer-mask handshake (gate-on-mismatch hardware enforcement)
  `include "test_top_peer_mask_match.sv"
  `include "test_top_peer_mask_mismatch_refused.sv"
  `include "test_top_peer_mask_auto.sv"
  `include "test_top_peer_mask_auto_mismatch.sv"

  // BRINGUP_REPORT.md §9 — per-lane bit-slip alignment tests.
  `include "test_top_align_base.sv"
  `include "test_align_uniform_skew.sv"
  `include "test_align_asymmetric_skew.sv"
  `include "test_align_one_dead_lane.sv"
  `include "test_align_recalibration_after_link_drop.sv"

  // Phase 3 — I²C-coordinated training-mode entry/exit (Agent #4).
  `include "test_top_train_base.sv"
  `include "test_train_i2c_handshake.sv"
  `include "test_train_lane_fault.sv"
  `include "test_train_no_peer_response.sv"
  `include "test_train_async_re_train.sv"
  `include "test_train_with_apb_override.sv"

endpackage

`endif // GUARD_TIDELINK_TOP_SYSTEM_PKG_SV
