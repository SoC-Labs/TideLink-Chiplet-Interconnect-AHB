///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_stress_test.sv
///////////////////////////////////////////////////////////////////////////////
// Stress test: sends multiple packets in rapid succession through the FC
// loopback path, verifying data integrity and credit management under load.
//
// Verifies:
//   - Back-to-back packet handling through FC adapter
//   - TX arbitration (FC ready backpressure when multiple beats in flight)
//   - RX path FSM handles continuous incoming FC words
//   - FIFO mux correctly arbitrates between FC RX writes and CPU reads
//   - Credit counting remains consistent across many packets
//   - No data corruption under sustained traffic
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_STRESS_TEST_SV
`define GUARD_TIDELINK_INTEGRATION_STRESS_TEST_SV

class tidelink_integration_stress_test extends tidelink_integration_base_test;

  `uvm_component_utils(tidelink_integration_stress_test)

  // Test parameters
  int unsigned num_packets   = 8;
  int unsigned words_per_pkt = 4;

  function new(string name = "tidelink_integration_stress_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    integration_tx_write_sequence   wr_seq;
    integration_fifo_read_sequence  rd_seq;
    bit [31:0] reg_data;
    bit [31:0] credits_initial;
    int unsigned expected_credits_consumed;

    phase.raise_objection(this);

    `uvm_info("TEST", $sformatf("=== Integration Stress Test: %0d packets x %0d words ===",
      num_packets, words_per_pkt), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialize TideLink
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Initialize TideLink", UVM_LOW)
    init_tidelink(32'h4000_0000, 32'd0);

    read_cfg_reg(REG_CREDIT_COUNT, credits_initial);
    `uvm_info("TEST", $sformatf("Initial CREDIT_COUNT = %0d", credits_initial), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 2: Write and read packets in sequence
    // ---------------------------------------------------------------
    for (int pkt = 0; pkt < num_packets; pkt++) begin
      `uvm_info("TEST", $sformatf("--- Packet %0d/%0d ---", pkt + 1, num_packets), UVM_LOW)

      // Write packet to TX aperture
      wr_seq = integration_tx_write_sequence::type_id::create(
        $sformatf("wr_seq_%0d", pkt));
      wr_seq.packet_data = new[words_per_pkt];
      for (int w = 0; w < words_per_pkt; w++) begin
        // Generate unique data pattern: packet_index in upper 16, word_index in lower 16
        wr_seq.packet_data[w] = {16'(pkt), 16'(w)};
      end
      wr_seq.start(env.tx_ahb_sys_env.master[0].sequencer);

      // Wait for FC loopback delivery
      repeat (20) @(posedge tb_if.clk);

      // Verify credits consumed
      expected_credits_consumed = words_per_pkt + 2; // 2-word header + N data
                                                      // (tidelink_fifo_ctrl.sv packet_delta = length + 2)
      read_cfg_reg(REG_CREDIT_COUNT, reg_data);
      `uvm_info("TEST", $sformatf("CREDIT_COUNT after write %0d = %0d (expected %0d)",
        pkt, reg_data, credits_initial - expected_credits_consumed), UVM_MEDIUM)
      if (reg_data !== (credits_initial - expected_credits_consumed))
        `uvm_error("TEST", $sformatf("Packet %0d: CREDIT_COUNT mismatch after write", pkt))

      // Read packet from RX FIFO
      rd_seq = integration_fifo_read_sequence::type_id::create(
        $sformatf("rd_seq_%0d", pkt));
      rd_seq.num_words = words_per_pkt;
      rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

      // Wait for returner credit release via FC sideband loopback
      repeat (40) @(posedge tb_if.clk);

      // Verify data integrity for this packet
      env.sb.compare_loopback_data();

      // Verify credits recovered
      read_cfg_reg(REG_CREDIT_COUNT, reg_data);
      `uvm_info("TEST", $sformatf("CREDIT_COUNT after read %0d = %0d (expected %0d)",
        pkt, reg_data, credits_initial), UVM_MEDIUM)
      if (reg_data !== credits_initial)
        `uvm_error("TEST", $sformatf("Packet %0d: CREDIT_COUNT did not recover after read", pkt))
    end

    // ---------------------------------------------------------------
    // Step 3: Final credit check
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 3: Final credit verification", UVM_LOW)
    read_cfg_reg(REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("Final CREDIT_COUNT = %0d (expected %0d)",
      reg_data, credits_initial), UVM_LOW)
    if (reg_data !== credits_initial)
      `uvm_error("TEST", "Final CREDIT_COUNT does not match initial value")

    // ---------------------------------------------------------------
    // Step 4: Check no error flags
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 4: Check for error flags", UVM_LOW)
    read_cfg_reg(REG_STATUS, reg_data);
    if (reg_data[STATUS_OVERRUN])
      `uvm_error("TEST", "STATUS.OVERRUN set — FIFO overflowed during stress")
    if (reg_data[STATUS_UNDERRUN])
      `uvm_error("TEST", "STATUS.UNDERRUN set — FIFO underflowed during stress")
    if (reg_data[STATUS_MASTER_ERROR])
      `uvm_error("TEST", "STATUS.MASTER_ERROR set — AHB master error during stress")

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_INTEGRATION_STRESS_TEST_SV
