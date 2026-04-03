///////////////////////////////////////////////////////////////////////////////
// test_top_back_to_back.sv — Rapid-fire packets through Wlink
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_BACK_TO_BACK_SV
`define GUARD_TEST_TOP_BACK_TO_BACK_SV

class test_top_back_to_back extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_back_to_back)

  function new(string name = "test_top_back_to_back", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    int num_packets = 10;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Back-to-Back ===", UVM_LOW)

    init_system();

    // Write multiple packets from A
    for (int p = 0; p < num_packets; p++) begin
      pkt_data = new[4];
      for (int w = 0; w < 4; w++)
        pkt_data[w] = (p << 16) | (w + 1);
      write_packet(SIDE_A, pkt_data);
    end

    // Wait for all packets to traverse Wlink
    repeat (500) @(posedge tb_if.clk);

    // Read all packets from B
    for (int p = 0; p < num_packets; p++) begin
      read_packet(SIDE_B, 4, read_data);
    end

    repeat (300) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
