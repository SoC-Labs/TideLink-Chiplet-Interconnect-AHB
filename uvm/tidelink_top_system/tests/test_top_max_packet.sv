///////////////////////////////////////////////////////////////////////////////
// test_top_max_packet.sv — Maximum-size packet through Wlink
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_MAX_PACKET_SV
`define GUARD_TEST_TOP_MAX_PACKET_SV

class test_top_max_packet extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_max_packet)

  function new(string name = "test_top_max_packet", uvm_component parent = null);
    super.new(name, parent);
    test_timeout_cycles = 10_000_000;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    int num_words = 64;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Top Max Packet (%0d words) ===", num_words), UVM_LOW)

    init_system();

    pkt_data = new[num_words];
    for (int i = 0; i < num_words; i++)
      pkt_data[i] = 32'hA000_0000 | i;

    write_packet(SIDE_A, pkt_data);

    // Large packet: scale wait by word count
    repeat (phy_transit_wait * ((num_words / 4) + 1)) @(posedge tb_if.clk);

    read_packet(SIDE_B, num_words, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    phase.drop_objection(this);
  endtask

endclass

`endif
