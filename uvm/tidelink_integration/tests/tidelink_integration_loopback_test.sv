///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_loopback_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests end-to-end loopback: write packet descriptors to TX aperture,
// verify they arrive in the RX FIFO via FC loopback.
//
// Verifies:
//   - FC adapter correctly packs AHB writes into 48-bit FC words
//   - FC loopback delivers words back to FC adapter RX path
//   - FC adapter RX correctly routes FIFO_DATA packets to FIFO mux
//   - FIFO stores data and makes it readable
//   - Packet data integrity (TX write data == RX read data)
//   - Credit counting (credits consumed on write, released on read)
//   - packet_committed status bit
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_LOOPBACK_TEST_SV
`define GUARD_TIDELINK_INTEGRATION_LOOPBACK_TEST_SV

class tidelink_integration_loopback_test extends tidelink_integration_base_test;

  `uvm_component_utils(tidelink_integration_loopback_test)

  function new(string name = "tidelink_integration_loopback_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    integration_tx_write_sequence   wr_seq;
    integration_fifo_read_sequence  rd_seq;
    bit [31:0] reg_data;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== Integration Loopback Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Initialize TideLink
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Initialize TideLink", UVM_LOW)
    init_tidelink(32'h4000_0000, 32'd0);

    // ---------------------------------------------------------------
    // Step 2: Check initial credit count
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 2: Check initial credit count", UVM_LOW)
    read_cfg_reg(REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("Initial CREDIT_COUNT = %0d", reg_data), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", $sformatf("Expected CREDIT_COUNT=%0d, got %0d",
        MAX_CREDITS, reg_data))

    // ---------------------------------------------------------------
    // Step 3: Write a 4-word packet to TX aperture
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 3: Write 4-word packet to TX aperture", UVM_LOW)
    wr_seq = integration_tx_write_sequence::type_id::create("wr_seq");
    wr_seq.packet_data = new[4];
    wr_seq.packet_data[0] = 32'hDEAD_BEEF;
    wr_seq.packet_data[1] = 32'hCAFE_BABE;
    wr_seq.packet_data[2] = 32'h1234_5678;
    wr_seq.packet_data[3] = 32'h9ABC_DEF0;
    wr_seq.start(env.tx_ahb_sys_env.master[0].sequencer);

    // Wait for FC loopback + FIFO write to complete
    repeat (30) @(posedge tb_if.clk);

    // ---------------------------------------------------------------
    // Step 4: Check status - packet should be committed
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 4: Check packet committed status", UVM_LOW)
    read_cfg_reg(REG_STATUS, reg_data);
    `uvm_info("TEST", $sformatf("STATUS = 0x%08h", reg_data), UVM_LOW)
    if (reg_data[STATUS_PACKET_COMMITTED] !== 1'b1)
      `uvm_error("TEST", "Expected packet_committed bit set in STATUS")

    // Check credit count decreased (6 credits consumed: 2-word header + 4 data,
    // see tidelink_fifo_ctrl.sv packet_delta = length + 2)
    read_cfg_reg(REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("CREDIT_COUNT after write = %0d (expected %0d)",
      reg_data, MAX_CREDITS - 6), UVM_LOW)
    if (reg_data !== (MAX_CREDITS - 6))
      `uvm_error("TEST", "CREDIT_COUNT mismatch after write")

    // ---------------------------------------------------------------
    // Step 5: Read the packet back from RX FIFO
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 5: Read packet from RX FIFO", UVM_LOW)
    rd_seq = integration_fifo_read_sequence::type_id::create("rd_seq");
    rd_seq.num_words = 4;
    rd_seq.start(env.fifo_ahb_sys_env.master[0].sequencer);

    // Wait for returner credit release to complete (goes through FC loopback)
    repeat (40) @(posedge tb_if.clk);

    // ---------------------------------------------------------------
    // Step 6: Verify data integrity via scoreboard
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 6: Verify loopback data integrity", UVM_LOW)
    env.sb.compare_loopback_data();

    // ---------------------------------------------------------------
    // Step 7: Check credit count recovered
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 7: Check credit recovery", UVM_LOW)
    read_cfg_reg(REG_CREDIT_COUNT, reg_data);
    `uvm_info("TEST", $sformatf("CREDIT_COUNT after read = %0d (expected %0d)",
      reg_data, MAX_CREDITS), UVM_LOW)
    if (reg_data !== MAX_CREDITS)
      `uvm_error("TEST", "CREDIT_COUNT did not recover after read")

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_INTEGRATION_LOOPBACK_TEST_SV
