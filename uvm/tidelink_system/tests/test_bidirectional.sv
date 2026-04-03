///////////////////////////////////////////////////////////////////////////////
// test_bidirectional.sv
///////////////////////////////////////////////////////////////////////////////
// Simultaneous A->B and B->A packet transfer. Verifies:
//   - No cross-contamination between directions
//   - FC crossover correctly routes A TX to B RX and B TX to A RX
//   - Credit management works independently on each side
//   - Arbitration between TX aperture and returner under load
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_BIDIRECTIONAL_SV
`define GUARD_TEST_BIDIRECTIONAL_SV

class test_bidirectional extends tidelink_system_base_test;

  `uvm_component_utils(test_bidirectional)

  function new(string name = "test_bidirectional", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] a_pkt[], b_pkt[];
    bit [31:0] a_read[], b_read[];
    bit [31:0] reg_data;
    sys_bidirectional_sequence bidir_seq;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Bidirectional Traffic ===", UVM_LOW)

    // Step 1: Initialize both sides
    init_both_sides();

    // Step 2: Prepare distinct packets for each direction
    a_pkt = new[4];
    a_pkt[0] = 32'hAAAA_0001;
    a_pkt[1] = 32'hAAAA_0002;
    a_pkt[2] = 32'hAAAA_0003;
    a_pkt[3] = 32'hAAAA_0004;

    b_pkt = new[4];
    b_pkt[0] = 32'hBBBB_0001;
    b_pkt[1] = 32'hBBBB_0002;
    b_pkt[2] = 32'hBBBB_0003;
    b_pkt[3] = 32'hBBBB_0004;

    // Step 3: Send both directions simultaneously
    `uvm_info("TEST", "Step 3: Bidirectional TX", UVM_LOW)
    bidir_seq = sys_bidirectional_sequence::type_id::create("bidir_seq");
    bidir_seq.a_packet_data = a_pkt;
    bidir_seq.b_packet_data = b_pkt;
    bidir_seq.a_tx_sqr = env.a_tx_ahb_sys_env.master[0].sequencer;
    bidir_seq.b_tx_sqr = env.b_tx_ahb_sys_env.master[0].sequencer;
    bidir_seq.start(null);

    // Wait for FC crossover delivery in both directions
    repeat (50) @(posedge tb_if.clk);

    // Step 4: Read A's packet from B's FIFO (A->B direction)
    `uvm_info("TEST", "Step 4: Read A->B packet from B's FIFO", UVM_LOW)
    read_packet(SIDE_B, 4, b_read);

    // Step 5: Read B's packet from A's FIFO (B->A direction)
    `uvm_info("TEST", "Step 5: Read B->A packet from A's FIFO", UVM_LOW)
    read_packet(SIDE_A, 4, a_read);

    // Wait for credit releases
    repeat (60) @(posedge tb_if.clk);

    // Step 6: Verify data integrity in both directions
    `uvm_info("TEST", "Step 6: Verify data integrity", UVM_LOW)
    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    // Step 7: Verify credits recovered on both sides
    read_cfg_reg(SIDE_A, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("A CREDIT_COUNT = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "A CREDIT_COUNT did not recover")

    read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("B CREDIT_COUNT = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "B CREDIT_COUNT did not recover")

    // Step 8: Check no errors
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_BIDIRECTIONAL_SV
