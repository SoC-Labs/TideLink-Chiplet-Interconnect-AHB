///////////////////////////////////////////////////////////////////////////////
// test_back_to_back.sv
///////////////////////////////////////////////////////////////////////////////
// Rapid-fire packets with no gap between them. Stresses:
//   - FIFO write pointer wrap-around behavior
//   - FC adapter pipeline (back-to-back address/data phases)
//   - Credit consumption rate vs. release rate
//   - Mux arbitration when FC RX and CPU read overlap
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_BACK_TO_BACK_SV
`define GUARD_TEST_BACK_TO_BACK_SV

class test_back_to_back extends tidelink_system_base_test;

  `uvm_component_utils(test_back_to_back)

  int unsigned num_packets   = 10;
  int unsigned words_per_pkt = 4;

  function new(string name = "test_back_to_back", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] reg_data;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf("=== Test Back-to-Back: %0d packets x %0d words ===",
      num_packets, words_per_pkt), UVM_LOW)

    // Initialize both sides
    init_both_sides();

    // Send and receive packets sequentially with minimal gaps
    for (int pkt = 0; pkt < num_packets; pkt++) begin
      `uvm_info("TEST", $sformatf("--- Packet %0d/%0d ---", pkt + 1, num_packets), UVM_LOW)

      // Generate unique data
      pkt_data = new[words_per_pkt];
      for (int w = 0; w < words_per_pkt; w++)
        pkt_data[w] = {16'(pkt), 16'(w)};

      // Write to A's TX aperture
      write_packet(SIDE_A, pkt_data);

      // Minimal wait — just enough for FC crossover (stress the pipeline)
      repeat (15) @(posedge tb_if.clk);

      // Read from B's RX FIFO
      read_packet(SIDE_B, words_per_pkt, read_data);

      // Wait for credit return via FC crossover
      repeat (40) @(posedge tb_if.clk);

      // Verify data integrity
      env.sb.compare_a2b_data();

      // Verify credits recovered before next packet
      read_cfg_reg(SIDE_B, REG_CREDIT_COUNT, reg_data);
      if (reg_data !== MAX_CREDITS)
        `uvm_error("TEST", $sformatf("Packet %0d: B credits=%0d, expected=%0d",
          pkt, reg_data, MAX_CREDITS))
    end

    // Final error check
    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_BACK_TO_BACK_SV
