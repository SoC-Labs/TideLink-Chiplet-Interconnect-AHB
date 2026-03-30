///////////////////////////////////////////////////////////////////////////////
// tidelink_stall_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests TideLink with different gapping and stalling scenarios:
//
//   1. Gapped writes: random idle cycles between AHB write beats
//   2. Gapped reads:  random idle cycles between AHB read beats
//   3. Returner backpressure: VIP slave inserts wait states on the AHB
//      master port, stalling the returner mid-transfer
//   4. Combined: gapped packets with returner stalling, multiple packets
//
// Data integrity is verified in the back-to-back tests (single_packet,
// random). This test focuses on:
//   - Token count recovery after gapped write/read cycles
//   - Correct returner behaviour under stalled bus conditions
//   - No error flags (overrun/underrun) despite timing gaps
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_STALL_TEST_SV
`define GUARD_TIDELINK_STALL_TEST_SV

class tidelink_stall_test extends tidelink_base_test;

  `uvm_component_utils(tidelink_stall_test)

  function new(string name = "tidelink_stall_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    tidelink_init_sequence            init_seq;
    ahb_gapped_packet_write_sequence  gapped_wr_seq;
    ahb_gapped_packet_read_sequence   gapped_rd_seq;
    ahb_packet_write_sequence         wr_seq;
    ahb_packet_read_sequence          rd_seq;
    apb_read_sequence                 apb_rd_seq;
    bit [31:0] token_count_before;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== Stall & Gap Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Initialize TideLink (immediate token release)
    // ---------------------------------------------------------------
    init_seq = tidelink_init_sequence::type_id::create("init_seq");
    init_seq.pair_base_addr = 32'h4000_0000;
    init_seq.rel_threshold  = 32'd0;
    init_seq.start(env.apb_agt.sequencer);

    // ---------------------------------------------------------------
    // Test 1: Back-to-back write, gapped read
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 1: Back-to-back write, gapped read", UVM_LOW)
    begin
      wr_seq = ahb_packet_write_sequence::type_id::create("wr_b2b");
      wr_seq.packet_data = new[4];
      wr_seq.packet_data = '{32'hAAAA_BBBB, 32'hCCCC_DDDD, 32'hEEEE_FFFF, 32'h1111_2222};
      wr_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (5) @(posedge vif.clk);

      // Check tokens consumed
      apb_rd_seq = apb_read_sequence::type_id::create("rd_tk_1a");
      apb_rd_seq.addr = REG_TOKEN_COUNT;
      apb_rd_seq.start(env.apb_agt.sequencer);
      `uvm_info("TEST", $sformatf("TOKEN_COUNT after write = %0d (expected %0d)",
        apb_rd_seq.rdata, MAX_TOKENS - 5), UVM_LOW)
      if (apb_rd_seq.rdata !== (MAX_TOKENS - 5))
        `uvm_error("TEST", "Test 1: TOKEN_COUNT mismatch after write")

      gapped_rd_seq = ahb_gapped_packet_read_sequence::type_id::create("rd_gapped_1");
      gapped_rd_seq.num_words = 4;
      gapped_rd_seq.min_gap   = 1;
      gapped_rd_seq.max_gap   = 3;
      gapped_rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (30) @(posedge vif.clk);

      // Verify token recovery
      apb_rd_seq = apb_read_sequence::type_id::create("rd_tk_1b");
      apb_rd_seq.addr = REG_TOKEN_COUNT;
      apb_rd_seq.start(env.apb_agt.sequencer);
      `uvm_info("TEST", $sformatf("TOKEN_COUNT after gapped read = %0d (expected %0d)",
        apb_rd_seq.rdata, MAX_TOKENS), UVM_LOW)
      if (apb_rd_seq.rdata !== MAX_TOKENS)
        `uvm_error("TEST", "Test 1: tokens not recovered after gapped read")
    end

    // ---------------------------------------------------------------
    // Test 2: Gapped write, back-to-back read
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 2: Gapped write, back-to-back read", UVM_LOW)
    begin
      gapped_wr_seq = ahb_gapped_packet_write_sequence::type_id::create("wr_gapped_1");
      gapped_wr_seq.packet_data = new[6];
      gapped_wr_seq.packet_data = '{32'hDEAD_BEEF, 32'hFACE_CAFE, 32'hBAAD_F00D,
                                     32'hC0DE_D00D, 32'h1234_ABCD, 32'hFEED_FACE};
      gapped_wr_seq.min_gap = 2;
      gapped_wr_seq.max_gap = 5;
      gapped_wr_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (5) @(posedge vif.clk);

      // Check tokens consumed (7 tokens: 1 length + 6 data)
      apb_rd_seq = apb_read_sequence::type_id::create("rd_tk_2a");
      apb_rd_seq.addr = REG_TOKEN_COUNT;
      apb_rd_seq.start(env.apb_agt.sequencer);
      `uvm_info("TEST", $sformatf("TOKEN_COUNT after gapped write = %0d (expected %0d)",
        apb_rd_seq.rdata, MAX_TOKENS - 7), UVM_LOW)
      if (apb_rd_seq.rdata !== (MAX_TOKENS - 7))
        `uvm_error("TEST", "Test 2: TOKEN_COUNT mismatch after gapped write")

      rd_seq = ahb_packet_read_sequence::type_id::create("rd_b2b_1");
      rd_seq.num_words = 6;
      rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (30) @(posedge vif.clk);

      apb_rd_seq = apb_read_sequence::type_id::create("rd_tk_2b");
      apb_rd_seq.addr = REG_TOKEN_COUNT;
      apb_rd_seq.start(env.apb_agt.sequencer);
      `uvm_info("TEST", $sformatf("TOKEN_COUNT after b2b read = %0d (expected %0d)",
        apb_rd_seq.rdata, MAX_TOKENS), UVM_LOW)
      if (apb_rd_seq.rdata !== MAX_TOKENS)
        `uvm_error("TEST", "Test 2: tokens not recovered after back-to-back read")
    end

    // ---------------------------------------------------------------
    // Test 3: Gapped write AND gapped read
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 3: Gapped write AND gapped read", UVM_LOW)
    begin
      gapped_wr_seq = ahb_gapped_packet_write_sequence::type_id::create("wr_gapped_2");
      gapped_wr_seq.packet_data = new[8];
      for (int i = 0; i < 8; i++)
        gapped_wr_seq.packet_data[i] = $urandom();
      gapped_wr_seq.min_gap = 1;
      gapped_wr_seq.max_gap = 6;
      gapped_wr_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (5) @(posedge vif.clk);

      gapped_rd_seq = ahb_gapped_packet_read_sequence::type_id::create("rd_gapped_2");
      gapped_rd_seq.num_words = 8;
      gapped_rd_seq.min_gap   = 1;
      gapped_rd_seq.max_gap   = 6;
      gapped_rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (30) @(posedge vif.clk);

      apb_rd_seq = apb_read_sequence::type_id::create("rd_tk_3");
      apb_rd_seq.addr = REG_TOKEN_COUNT;
      apb_rd_seq.start(env.apb_agt.sequencer);
      `uvm_info("TEST", $sformatf("TOKEN_COUNT after dual-gapped = %0d (expected %0d)",
        apb_rd_seq.rdata, MAX_TOKENS), UVM_LOW)
      if (apb_rd_seq.rdata !== MAX_TOKENS)
        `uvm_error("TEST", "Test 3: tokens not recovered after dual-gapped packet")
    end

    // ---------------------------------------------------------------
    // Test 4: Multiple random-gapped packets (exercises returner stalling)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 4: Multiple random-gapped packets with returner stall", UVM_LOW)
    for (int pkt = 0; pkt < 5; pkt++) begin
      int unsigned pkt_len;
      `uvm_info("TEST", $sformatf("--- Stall packet %0d ---", pkt), UVM_LOW)

      pkt_len = 2 + ($urandom() % 15);

      gapped_wr_seq = ahb_gapped_packet_write_sequence::type_id::create(
        $sformatf("wr_stall_%0d", pkt));
      gapped_wr_seq.packet_data = new[pkt_len];
      for (int i = 0; i < pkt_len; i++)
        gapped_wr_seq.packet_data[i] = $urandom();
      if (!gapped_wr_seq.randomize() with {
        min_gap inside {[1:2]};
        max_gap inside {[1:5]};
      })
        `uvm_fatal("TEST", "Failed to randomize gapped write sequence")
      gapped_wr_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (5) @(posedge vif.clk);

      gapped_rd_seq = ahb_gapped_packet_read_sequence::type_id::create(
        $sformatf("rd_stall_%0d", pkt));
      gapped_rd_seq.num_words = pkt_len;
      if (!gapped_rd_seq.randomize() with {
        min_gap inside {[1:2]};
        max_gap inside {[1:5]};
      })
        `uvm_fatal("TEST", "Failed to randomize gapped read sequence")
      gapped_rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);
      repeat (30) @(posedge vif.clk);

      // Verify token recovery per-packet
      apb_rd_seq = apb_read_sequence::type_id::create($sformatf("rd_tk_4_%0d", pkt));
      apb_rd_seq.addr = REG_TOKEN_COUNT;
      apb_rd_seq.start(env.apb_agt.sequencer);
      `uvm_info("TEST", $sformatf("TOKEN_COUNT = %0d (expected %0d)",
        apb_rd_seq.rdata, MAX_TOKENS), UVM_LOW)
      if (apb_rd_seq.rdata !== MAX_TOKENS)
        `uvm_error("TEST", $sformatf("Test 4 packet %0d: tokens not recovered", pkt))
    end

    // ---------------------------------------------------------------
    // Final checks: no error flags should be set
    // ---------------------------------------------------------------
    apb_rd_seq = apb_read_sequence::type_id::create("rd_status_final");
    apb_rd_seq.addr = REG_STATUS;
    apb_rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("Final STATUS = 0x%08h", apb_rd_seq.rdata), UVM_LOW)
    if (apb_rd_seq.rdata[STATUS_OVERRUN])
      `uvm_error("TEST", "Overrun flag set — should not happen")
    if (apb_rd_seq.rdata[STATUS_UNDERRUN])
      `uvm_error("TEST", "Underrun flag set — should not happen")

    repeat (50) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_STALL_TEST_SV
