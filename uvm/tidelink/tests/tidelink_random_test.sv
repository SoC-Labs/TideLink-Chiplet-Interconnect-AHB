///////////////////////////////////////////////////////////////////////////////
// tidelink_random_test.sv
///////////////////////////////////////////////////////////////////////////////
// Constrained-random test: multiple packets with random sizes and data.
// Data integrity is verified by the scoreboard (comparing AHB bus-level
// write and read data captured by the VIP monitors).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_RANDOM_TEST_SV
`define GUARD_TIDELINK_RANDOM_TEST_SV

class tidelink_random_test extends tidelink_base_test;

  `uvm_component_utils(tidelink_random_test)

  int unsigned num_packets = 10;

  function new(string name = "tidelink_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    tidelink_init_sequence        init_seq;
    ahb_random_packet_sequence    wr_pkt_seq;
    ahb_packet_read_sequence      rd_pkt_seq;
    apb_read_sequence             rd_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", $sformatf("=== Random Packet Test: %0d packets ===", num_packets), UVM_LOW)

    // ---------------------------------------------------------------
    // Initialize TideLink
    // ---------------------------------------------------------------
    init_seq = tidelink_init_sequence::type_id::create("init_seq");
    init_seq.pair_base_addr = 32'h4000_0000;
    init_seq.rel_threshold  = 32'd0;  // Immediate release
    init_seq.start(env.apb_agt.sequencer);

    // ---------------------------------------------------------------
    // Send random packets one at a time (single packet in-flight)
    // ---------------------------------------------------------------
    for (int pkt = 0; pkt < num_packets; pkt++) begin
      `uvm_info("TEST", $sformatf("--- Packet %0d ---", pkt), UVM_LOW)

      // Write random packet
      wr_pkt_seq = ahb_random_packet_sequence::type_id::create($sformatf("wr_pkt_%0d", pkt));
      if (!wr_pkt_seq.randomize())
        `uvm_fatal("TEST", "Failed to randomize packet write sequence")
      wr_pkt_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

      // Wait for commit
      repeat (5) @(posedge vif.clk);

      // Read packet back
      rd_pkt_seq = ahb_packet_read_sequence::type_id::create($sformatf("rd_pkt_%0d", pkt));
      rd_pkt_seq.num_words = wr_pkt_seq.num_words;
      rd_pkt_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

      // Wait for returner to release tokens
      repeat (20) @(posedge vif.clk);

      // Verify data integrity via scoreboard
      env.sb.compare_packet_data();
    end

    // Final status check
    rd_seq = apb_read_sequence::type_id::create("rd_status_final");
    rd_seq.addr = REG_STATUS;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("Final STATUS = 0x%08h", rd_seq.rdata), UVM_LOW)

    rd_seq = apb_read_sequence::type_id::create("rd_tokens_final");
    rd_seq.addr = REG_TOKEN_COUNT;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("Final TOKEN_COUNT = %0d (expected %0d)",
      rd_seq.rdata, MAX_TOKENS), UVM_LOW)
    if (rd_seq.rdata !== MAX_TOKENS)
      `uvm_error("TEST", "Final TOKEN_COUNT mismatch — tokens not fully recovered")

    repeat (50) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_RANDOM_TEST_SV
