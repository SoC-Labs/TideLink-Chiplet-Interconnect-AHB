///////////////////////////////////////////////////////////////////////////////
// test_top_autoneg_basic.sv — Auto-negotiation basic role resolution
///////////////////////////////////////////////////////////////////////////////
// Runs auto-negotiation on both sides with different priorities:
//   Side A: priority = 0x0001 (low = wins master)
//   Side B: priority = 0x1000 (high = becomes slave)
// After negotiation, verifies correct role assignment, initializes TideLink,
// and sends a packet A->B.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AUTONEG_BASIC_SV
`define GUARD_TEST_TOP_AUTONEG_BASIC_SV

class test_top_autoneg_basic extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_autoneg_basic)

  function new(string name = "test_top_autoneg_basic", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    top_sys_autoneg_sequence a_autoneg, b_autoneg;
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Basic ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Run auto-negotiation on both sides (fork/join)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Starting auto-negotiation on both sides...", UVM_LOW)

    a_autoneg = top_sys_autoneg_sequence::type_id::create("a_autoneg");
    a_autoneg.side_name    = "A";
    a_autoneg.priority_val = 32'h0000_0001;  // low priority -> wins master
    a_autoneg.force_lock   = 1;

    b_autoneg = top_sys_autoneg_sequence::type_id::create("b_autoneg");
    b_autoneg.side_name    = "B";
    b_autoneg.priority_val = 32'h0000_1000;  // high priority -> becomes slave
    b_autoneg.force_lock   = 1;

    fork
      a_autoneg.start(env.a_apb_agt.sequencer);
      b_autoneg.start(env.b_apb_agt.sequencer);
    join

    // ---------------------------------------------------------------
    // Step 2: Verify negotiation outcome
    // ---------------------------------------------------------------
    if (!a_autoneg.nego_done)
      `uvm_error("TEST", "[A] Negotiation did not complete successfully")

    if (!b_autoneg.nego_done)
      `uvm_error("TEST", "[B] Negotiation did not complete successfully")

    if (!a_autoneg.nego_won)
      `uvm_error("TEST", "[A] Expected to win negotiation (lower priority) but did not")

    if (!b_autoneg.nego_lost)
      `uvm_error("TEST", "[B] Expected to lose negotiation (higher priority) but did not")

    `uvm_info("TEST", $sformatf("Side A: won=%0b lost=%0b | Side B: won=%0b lost=%0b",
      a_autoneg.nego_won, a_autoneg.nego_lost,
      b_autoneg.nego_won, b_autoneg.nego_lost), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 3: Wait for Wlink link training
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Waiting for Wlink link-up after role lock...", UVM_LOW)
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);
    `uvm_info("TEST", "Wlink link-up complete.", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 4: Initialize TideLink (pair base, credits, doorbell)
    // ---------------------------------------------------------------
    init_both_sides();

    // ---------------------------------------------------------------
    // Step 5: Send packet A->B and verify
    // ---------------------------------------------------------------
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

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Basic COMPLETE ===", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_AUTONEG_BASIC_SV
