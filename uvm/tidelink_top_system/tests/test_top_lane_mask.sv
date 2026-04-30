///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask.sv — End-to-end traffic with a non-default lane mask
///////////////////////////////////////////////////////////////////////////////
// Programs identical lane masks on both A and B sides before bringing up
// Wlink, then runs a single packet A->B through the full stack and checks
// that the scoreboard sees matching data. Validates that the lane-mask
// striping logic preserves byte ordering when one or more physical lanes
// are dropped from the active set.
//
// The masked configuration here drops physical lane 7 (the highest lane on
// the 8-lane build), reducing the link width from 8 lanes to 7. This is
// the canonical "burnt ribbon pin" recovery scenario.
//
// Future extension: parametrise the mask via a class member (or +UVM_TESTNAME
// argument) and instantiate per-mask sub-tests. Initial scope is one mask.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_SV
`define GUARD_TEST_TOP_LANE_MASK_SV

class test_top_lane_mask extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_lane_mask)

  // 8-lane build, drop the top lane: 7 lanes active, contiguous
  bit [15:0] tx_mask = 16'h007F;
  bit [15:0] rx_mask = 16'h007F;

  function new(string name = "test_top_lane_mask", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Override the base init to insert lane-mask programming before role-lock.
  // Both ends must agree on the mask before training, so we program A and B
  // first, then call init_wlink() (which locks the role and waits for link
  // training) and init_both_sides() (which configures TideLink credits).
  virtual task init_system_with_lane_mask();
    top_sys_wlink_lane_mask_sequence a_mask, b_mask;

    `uvm_info("TEST", $sformatf(
      "Programming lane mask before link enable: tx=0x%04h rx=0x%04h",
      tx_mask, rx_mask), UVM_LOW)

    a_mask = top_sys_wlink_lane_mask_sequence::type_id::create("a_mask");
    a_mask.side_name = "A";
    a_mask.tx_mask = tx_mask;
    a_mask.rx_mask = rx_mask;
    a_mask.start(env.a_apb_agt.sequencer);

    b_mask = top_sys_wlink_lane_mask_sequence::type_id::create("b_mask");
    b_mask.side_name = "B";
    b_mask.tx_mask = tx_mask;
    b_mask.rx_mask = rx_mask;
    b_mask.start(env.b_apb_agt.sequencer);

    // Now bring up the link with the masks already programmed.
    init_wlink();
    init_both_sides();
  endtask

  virtual task main_phase(uvm_phase phase);
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];
    bit [31:0] active;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Lane Mask (drop highest lane) ===", UVM_LOW)

    init_system_with_lane_mask();

    // Spot-check the derived active_lanes register reads back popcount(mask)-1.
    // Field layout: bits[15:0]=tx, bits[31:16]=rx; both should be 6 (= 7-1).
    read_cfg_reg_raw(SIDE_A, 15'h0210, active);
    if ((active & 32'h0000_FFFF) != 32'h0000_0006)
      `uvm_error("TEST", $sformatf("[A] active_tx_lanes expected 6, got %0d",
                                    active & 32'h0000_FFFF))
    if ((active >> 16) != 32'h0000_0006)
      `uvm_error("TEST", $sformatf("[A] active_rx_lanes expected 6, got %0d",
                                    active >> 16))

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

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

  // Helper: APB read using a raw 15-bit address (bypasses the +0x2000 shift
  // applied by read_cfg_reg, since lane control regs live in Wlink space at
  // 0x0210 / 0x0214).
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

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_SV
