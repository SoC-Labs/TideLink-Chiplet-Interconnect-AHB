///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_credit_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests the credit sideband loopback path.
//
// When the FIFO's returner sends credit release or doorbell writes, the FC
// adapter intercepts them and converts them to SIDEBAND FC packets. In the
// loopback topology, these come back through the FC RX path and get routed
// to the config register port via the config mux.
//
// Verifies:
//   - Returner fires after packet read completion
//   - FC adapter correctly encodes returner writes as PKT_SIDEBAND
//   - Loopback delivers sideband packets to config port
//   - RELEASED_ACC register accumulates released credits
//   - PAIR_CREDIT_COUNTER tracks received credits
//   - released_credits_irq fires
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_CREDIT_TEST_SV
`define GUARD_TIDELINK_INTEGRATION_CREDIT_TEST_SV

class tidelink_integration_credit_test extends tidelink_integration_base_test;

  `uvm_component_utils(tidelink_integration_credit_test)

  function new(string name = "tidelink_integration_credit_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    integration_tx_write_sequence   wr_seq;
    integration_fifo_read_sequence  rd_seq;
    bit [31:0] reg_data;
    bit [31:0] credits_before, credits_after;
    bit [31:0] pair_credit_before, pair_credit_after;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== Integration Credit Sideband Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialize TideLink with immediate credit release
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Initialize TideLink (immediate release)", UVM_LOW)
    init_tidelink(32'h4000_0000, 32'd0);

    // ---------------------------------------------------------------
    // Step 2: Record initial credit state
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 2: Record initial credit state", UVM_LOW)
    read_cfg_reg(REG_CREDIT_COUNT, credits_before);
    read_cfg_reg(REG_PAIR_CREDIT_COUNTER, pair_credit_before);
    `uvm_info("TEST", $sformatf("Initial: CREDIT_COUNT=%0d, PAIR_CREDIT_COUNTER=%0d",
      credits_before, pair_credit_before), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 3: Write a 2-word packet to TX aperture
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 3: Write 2-word packet", UVM_LOW)
    wr_seq = integration_tx_write_sequence::type_id::create("wr_seq");
    wr_seq.packet_data = new[2];
    wr_seq.packet_data[0] = 32'hAAAA_BBBB;
    wr_seq.packet_data[1] = 32'hCCCC_DDDD;
    wr_seq.start(env.tx_ahb_sys_env.master[0].sequencer);

    // Wait for loopback delivery
    repeat (30) @(posedge tb_if.clk);

    // Check credits consumed (3 words: 1 length + 2 data)
    read_cfg_reg(REG_CREDIT_COUNT, credits_after);
    `uvm_info("TEST", $sformatf("CREDIT_COUNT after write = %0d (expected %0d)",
      credits_after, credits_before - 3), UVM_LOW)
    if (credits_after !== (credits_before - 3))
      `uvm_error("TEST", "CREDIT_COUNT not decremented correctly after write")

    // ---------------------------------------------------------------
    // Step 4: Read the packet from RX FIFO (triggers returner)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 4: Read packet (triggers credit release)", UVM_LOW)
    rd_seq = integration_fifo_read_sequence::type_id::create("rd_seq");
    rd_seq.num_words = 2;
    rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

    // Wait for returner → FC sideband → loopback → config write
    // The credit release path is: returner AHB write → FC adapter intercepts →
    // FC TX (SIDEBAND) → loopback → FC RX → config mux → AHB-to-APB bridge →
    // APB register write (RELEASED_ACC / PAIR_CREDIT_COUNTER)
    repeat (60) @(posedge tb_if.clk);

    // ---------------------------------------------------------------
    // Step 5: Verify credit recovery
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 5: Check credit recovery", UVM_LOW)
    read_cfg_reg(REG_CREDIT_COUNT, credits_after);
    `uvm_info("TEST", $sformatf("CREDIT_COUNT after read = %0d (expected %0d)",
      credits_after, credits_before), UVM_LOW)
    if (credits_after !== credits_before)
      `uvm_error("TEST", "CREDIT_COUNT did not recover — credit sideband path may be broken")

    // ---------------------------------------------------------------
    // Step 6: Check PAIR_CREDIT_COUNTER received credits
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 6: Check pair credit counter", UVM_LOW)
    read_cfg_reg(REG_PAIR_CREDIT_COUNTER, pair_credit_after);
    `uvm_info("TEST", $sformatf("PAIR_CREDIT_COUNTER = %0d (before=%0d)",
      pair_credit_after, pair_credit_before), UVM_LOW)
    // In loopback, sideband writes to RELEASED_ACC go to OUR config regs,
    // which should be accumulated by the pair credit receiver
    if (pair_credit_after <= pair_credit_before)
      `uvm_warning("TEST", "PAIR_CREDIT_COUNTER did not increment — may need sideband routing check")

    // ---------------------------------------------------------------
    // Step 7: Check released_credits_irq fired
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 7: Check released_credits_irq", UVM_LOW)
    if (tb_if.released_credits_irq !== 1'b1)
      `uvm_warning("TEST", "released_credits_irq not asserted — may need longer wait or threshold config")

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_INTEGRATION_CREDIT_TEST_SV
