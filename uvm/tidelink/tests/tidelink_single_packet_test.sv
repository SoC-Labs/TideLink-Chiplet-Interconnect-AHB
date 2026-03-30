///////////////////////////////////////////////////////////////////////////////
// tidelink_single_packet_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests single packet write and read through the TideLink FIFO.
// Verifies:
//   - Packet data integrity via scoreboard (write matches read on the bus)
//   - Token counting (tokens consumed on write, released on read)
//   - Returner fires token release after read completion
//   - packet_committed_irq assertion
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SINGLE_PACKET_TEST_SV
`define GUARD_TIDELINK_SINGLE_PACKET_TEST_SV

class tidelink_single_packet_test extends tidelink_base_test;

  `uvm_component_utils(tidelink_single_packet_test)

  function new(string name = "tidelink_single_packet_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    tidelink_init_sequence    init_seq;
    ahb_packet_write_sequence wr_pkt_seq;
    ahb_packet_read_sequence  rd_pkt_seq;
    apb_read_sequence         rd_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== Single Packet Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialize TideLink
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Initialize TideLink", UVM_LOW)
    init_seq = tidelink_init_sequence::type_id::create("init_seq");
    init_seq.pair_base_addr = 32'h4000_0000;
    init_seq.rel_threshold  = 32'd0;  // Immediate release
    init_seq.start(env.apb_agt.sequencer);

    // ---------------------------------------------------------------
    // Step 2: Check initial token count
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 2: Check initial token count", UVM_LOW)
    rd_seq = apb_read_sequence::type_id::create("rd_tokens_init");
    rd_seq.addr = REG_TOKEN_COUNT;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("Initial TOKEN_COUNT = %0d", rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== MAX_TOKENS)
      `uvm_error("TEST", $sformatf("Expected TOKEN_COUNT=%0d, got %0d", MAX_TOKENS, rd_seq.rdata))

    // ---------------------------------------------------------------
    // Step 3: Write a 4-word packet
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 3: Write a 4-word packet", UVM_LOW)
    wr_pkt_seq = ahb_packet_write_sequence::type_id::create("wr_pkt_seq");
    wr_pkt_seq.packet_data = new[4];
    wr_pkt_seq.packet_data[0] = 32'hDEAD_BEEF;
    wr_pkt_seq.packet_data[1] = 32'hCAFE_BABE;
    wr_pkt_seq.packet_data[2] = 32'h1234_5678;
    wr_pkt_seq.packet_data[3] = 32'h9ABC_DEF0;
    wr_pkt_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

    // Wait for packet committed
    repeat (10) @(posedge vif.clk);

    // ---------------------------------------------------------------
    // Step 4: Check status - packet should be committed
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 4: Check packet committed status", UVM_LOW)
    rd_seq = apb_read_sequence::type_id::create("rd_status");
    rd_seq.addr = REG_STATUS;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("STATUS = 0x%08h", rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata[STATUS_PACKET_COMMITTED] !== 1'b1)
      `uvm_error("TEST", "Expected packet_committed bit set in STATUS")

    // Check token count decreased (5 tokens consumed: 1 length + 4 data)
    rd_seq = apb_read_sequence::type_id::create("rd_tokens_after_wr");
    rd_seq.addr = REG_TOKEN_COUNT;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("TOKEN_COUNT after write = %0d (expected %0d)",
      rd_seq.rdata, MAX_TOKENS - 5), UVM_LOW)
    if (rd_seq.rdata !== (MAX_TOKENS - 5))
      `uvm_error("TEST", "TOKEN_COUNT mismatch after write")

    // ---------------------------------------------------------------
    // Step 5: Read the packet back
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 5: Read packet back", UVM_LOW)
    rd_pkt_seq = ahb_packet_read_sequence::type_id::create("rd_pkt_seq");
    rd_pkt_seq.num_words = 4;
    rd_pkt_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

    // Wait for returner to complete token release
    repeat (20) @(posedge vif.clk);

    // ---------------------------------------------------------------
    // Step 6: Verify data integrity via scoreboard
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 6: Verify packet data integrity via scoreboard", UVM_LOW)
    env.sb.compare_packet_data();

    // ---------------------------------------------------------------
    // Step 7: Check token count recovered
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 7: Check token count after read", UVM_LOW)
    rd_seq = apb_read_sequence::type_id::create("rd_tokens_final");
    rd_seq.addr = REG_TOKEN_COUNT;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("TOKEN_COUNT after read = %0d (expected %0d)",
      rd_seq.rdata, MAX_TOKENS), UVM_LOW)
    if (rd_seq.rdata !== MAX_TOKENS)
      `uvm_error("TEST", "TOKEN_COUNT did not recover after read")

    repeat (20) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_SINGLE_PACKET_TEST_SV
