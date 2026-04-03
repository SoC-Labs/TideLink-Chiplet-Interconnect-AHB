///////////////////////////////////////////////////////////////////////////////
// test_top_bidirectional.sv — Simultaneous A->B and B->A through Wlink
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_BIDIRECTIONAL_SV
`define GUARD_TEST_TOP_BIDIRECTIONAL_SV

class test_top_bidirectional extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_bidirectional)

  function new(string name = "test_top_bidirectional", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] a_pkt[], b_pkt[];
    bit [31:0] a_read[], b_read[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Bidirectional ===", UVM_LOW)

    init_system();

    // Create distinct packets for each direction
    a_pkt = new[4];
    a_pkt[0] = 32'hAAAA_1111;
    a_pkt[1] = 32'hAAAA_2222;
    a_pkt[2] = 32'hAAAA_3333;
    a_pkt[3] = 32'hAAAA_4444;

    b_pkt = new[4];
    b_pkt[0] = 32'hBBBB_1111;
    b_pkt[1] = 32'hBBBB_2222;
    b_pkt[2] = 32'hBBBB_3333;
    b_pkt[3] = 32'hBBBB_4444;

    // Send simultaneously in both directions
    fork
      write_packet(SIDE_A, a_pkt);
      write_packet(SIDE_B, b_pkt);
    join

    // Wait for both packets to traverse Wlink
    repeat (300) @(posedge tb_if.clk);

    // Read both FIFOs
    fork
      read_packet(SIDE_B, 4, b_read);  // A->B data arrives at B
      read_packet(SIDE_A, 4, a_read);  // B->A data arrives at A
    join

    repeat (200) @(posedge tb_if.clk);

    // Verify both paths
    env.sb.compare_a2b_data();
    env.sb.compare_b2a_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
