///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_base.sv — Parameterised lane-mask end-to-end test
///////////////////////////////////////////////////////////////////////////////
// Base class for the test_top_lane_mask_* family. Each subclass sets the
// four mask fields (a_tx, a_rx, b_tx, b_rx) and optionally overrides
// run_traffic() / check_active_lanes() for scenario-specific verification.
//
// The canonical sequence is:
//   1. Program lane masks on both sides via APB before link training
//   2. init_wlink() — locks the role and waits for link-up
//   3. init_both_sides() — configures TideLink credit pool
//   4. Verify the derived active_lanes register reflects popcount(mask)-1
//   5. Send a packet A->B (and optionally B->A), check scoreboard
//
// All four masks default to 0xFF (full link); subclasses override only
// the fields that should be reduced.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_BASE_SV
`define GUARD_TEST_TOP_LANE_MASK_BASE_SV

// Not abstract — the default all-FF mask is a valid (no-op) configuration.
// Tests should subclass and override the mask fields rather than running
// this directly; nothing prevents direct instantiation, however.
class test_top_lane_mask_base extends tidelink_top_system_base_test;

  // Per-side per-direction masks. Default to all-lanes-enabled. Subclasses
  // override these in their constructor to set the scenario.
  bit [15:0] a_tx_mask = 16'h00FF;
  bit [15:0] a_rx_mask = 16'h00FF;
  bit [15:0] b_tx_mask = 16'h00FF;
  bit [15:0] b_rx_mask = 16'h00FF;

  function new(string name = "test_top_lane_mask_base", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Programs masks on both sides, then runs the existing init flow.
  virtual task init_system_with_lane_mask();
    top_sys_wlink_lane_mask_sequence a_mask, b_mask;

    `uvm_info("TEST", $sformatf(
      "Programming lane mask: A.tx=0x%04h A.rx=0x%04h B.tx=0x%04h B.rx=0x%04h",
      a_tx_mask, a_rx_mask, b_tx_mask, b_rx_mask), UVM_LOW)

    a_mask = top_sys_wlink_lane_mask_sequence::type_id::create("a_mask");
    a_mask.side_name = "A";
    a_mask.tx_mask   = a_tx_mask;
    a_mask.rx_mask   = a_rx_mask;
    a_mask.start(env.a_apb_agt.sequencer);

    b_mask = top_sys_wlink_lane_mask_sequence::type_id::create("b_mask");
    b_mask.side_name = "B";
    b_mask.tx_mask   = b_tx_mask;
    b_mask.rx_mask   = b_rx_mask;
    b_mask.start(env.b_apb_agt.sequencer);

    // Drop a coverage sample for the lane-mask covergroup. Sample the A side
    // values; mismatch tests can override to sample additional points.
    if (env.cov != null)
      env.cov.sample_lane_mask(a_tx_mask, a_rx_mask);

    init_wlink();
    init_both_sides();
  endtask

  // Confirm derived active_lanes register reads back popcount(mask)-1 on each
  // side. Subclasses can override to skip this check (e.g. mismatch tests).
  virtual task check_active_lanes();
    bit [31:0] a_active, b_active;
    int        a_tx_expected, a_rx_expected, b_tx_expected, b_rx_expected;

    a_tx_expected = $countones(a_tx_mask) - 1;
    a_rx_expected = $countones(a_rx_mask) - 1;
    b_tx_expected = $countones(b_tx_mask) - 1;
    b_rx_expected = $countones(b_rx_mask) - 1;

    read_cfg_reg_raw(SIDE_A, 15'h0210, a_active);
    if ((a_active & 32'h0000_FFFF) != a_tx_expected)
      `uvm_error("TEST", $sformatf("[A] active_tx_lanes expected %0d, got %0d",
                                    a_tx_expected, a_active & 32'h0000_FFFF))
    if (((a_active >> 16) & 32'h0000_FFFF) != a_rx_expected)
      `uvm_error("TEST", $sformatf("[A] active_rx_lanes expected %0d, got %0d",
                                    a_rx_expected, (a_active >> 16) & 32'h0000_FFFF))

    read_cfg_reg_raw(SIDE_B, 15'h0210, b_active);
    if ((b_active & 32'h0000_FFFF) != b_tx_expected)
      `uvm_error("TEST", $sformatf("[B] active_tx_lanes expected %0d, got %0d",
                                    b_tx_expected, b_active & 32'h0000_FFFF))
    if (((b_active >> 16) & 32'h0000_FFFF) != b_rx_expected)
      `uvm_error("TEST", $sformatf("[B] active_rx_lanes expected %0d, got %0d",
                                    b_rx_expected, (b_active >> 16) & 32'h0000_FFFF))
  endtask

  // Default traffic: single 4-word packet A->B, scoreboard compare.
  // Subclasses can override for bidirectional or back-to-back patterns.
  virtual task run_traffic();
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    pkt_data = new[4];
    pkt_data[0] = 32'hDEAD_BEEF;
    pkt_data[1] = 32'hCAFE_BABE;
    pkt_data[2] = 32'h1234_5678;
    pkt_data[3] = 32'h9ABC_DEF0;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
  endtask

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== %s ===", get_type_name()), UVM_LOW)

    init_system_with_lane_mask();
    check_active_lanes();
    run_traffic();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

  // APB read with a raw 15-bit address (bypasses the +0x2000 offset that
  // read_cfg_reg applies for TideLink config regs, since lane control lives
  // in Wlink space at 0x0210 / 0x0214).
  virtual task read_cfg_reg_raw(side_t side, input bit [14:0] addr,
                                 output bit [31:0] data);
    integration_cfg_read_sequence rd_seq;
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = addr;
    if (side == SIDE_A)
      rd_seq.start(env.a_apb_agt.sequencer);
    else
      rd_seq.start(env.b_apb_agt.sequencer);
    data = rd_seq.rdata;
  endtask

  // APB write with a raw 15-bit address (Wlink space).
  virtual task write_cfg_reg_raw(side_t side, input bit [14:0] addr,
                                  input bit [31:0] data);
    integration_cfg_write_sequence wr_seq;
    wr_seq = integration_cfg_write_sequence::type_id::create("wr_seq");
    wr_seq.addr = addr;
    wr_seq.data = data;
    if (side == SIDE_A)
      wr_seq.start(env.a_apb_agt.sequencer);
    else
      wr_seq.start(env.b_apb_agt.sequencer);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_BASE_SV
