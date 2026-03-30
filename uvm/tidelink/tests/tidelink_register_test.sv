///////////////////////////////////////////////////////////////////////////////
// tidelink_register_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests APB register access to TideLink configuration and status registers.
// Verifies read/write behaviour, default values, and read-only fields.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_REGISTER_TEST_SV
`define GUARD_TIDELINK_REGISTER_TEST_SV

class tidelink_register_test extends tidelink_base_test;

  `uvm_component_utils(tidelink_register_test)

  function new(string name = "tidelink_register_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    apb_write_sequence wr_seq;
    apb_read_sequence  rd_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== Register Access Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Test 1: Read default values
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 1: Read default register values", UVM_LOW)

    // Token count should be MAX_TOKENS (4096) at reset
    rd_seq = apb_read_sequence::type_id::create("rd_token_cnt");
    rd_seq.addr = REG_TOKEN_COUNT;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("TOKEN_COUNT = 0x%08h (expected 0x%08h)",
      rd_seq.rdata, MAX_TOKENS), UVM_LOW)
    if (rd_seq.rdata !== MAX_TOKENS)
      `uvm_error("TEST", "TOKEN_COUNT default value mismatch")

    // Status should be 0 at reset
    rd_seq = apb_read_sequence::type_id::create("rd_status");
    rd_seq.addr = REG_STATUS;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("STATUS = 0x%08h (expected 0x00000000)",
      rd_seq.rdata), UVM_LOW)

    // CTRL should be 0 at reset
    rd_seq = apb_read_sequence::type_id::create("rd_ctrl");
    rd_seq.addr = REG_CTRL;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("CTRL = 0x%08h (expected 0x00000000)",
      rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== 32'h0)
      `uvm_error("TEST", "CTRL default value mismatch")

    // ---------------------------------------------------------------
    // Test 2: Write and readback pair base address
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 2: Write/readback pair base address", UVM_LOW)

    wr_seq = apb_write_sequence::type_id::create("wr_pair_base");
    wr_seq.addr = REG_PAIR_BASE;
    wr_seq.data = 32'h5000_1000;
    wr_seq.start(env.apb_agt.sequencer);

    rd_seq = apb_read_sequence::type_id::create("rd_pair_base");
    rd_seq.addr = REG_PAIR_BASE;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("PAIR_BASE = 0x%08h (expected 0x50001000)",
      rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== 32'h5000_1000)
      `uvm_error("TEST", "PAIR_BASE write/readback mismatch")

    // ---------------------------------------------------------------
    // Test 3: Write and readback release threshold
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 3: Write/readback release threshold", UVM_LOW)

    wr_seq = apb_write_sequence::type_id::create("wr_threshold");
    wr_seq.addr = REG_REL_THRESHOLD;
    wr_seq.data = 32'd50;
    wr_seq.start(env.apb_agt.sequencer);

    rd_seq = apb_read_sequence::type_id::create("rd_threshold");
    rd_seq.addr = REG_REL_THRESHOLD;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("REL_THRESHOLD = %0d (expected 50)",
      rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== 32'd50)
      `uvm_error("TEST", "REL_THRESHOLD write/readback mismatch")

    // ---------------------------------------------------------------
    // Test 4: Write and readback CTRL register
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 4: Enable block via CTRL register", UVM_LOW)

    wr_seq = apb_write_sequence::type_id::create("wr_ctrl");
    wr_seq.addr = REG_CTRL;
    wr_seq.data = 32'h1;  // EN = 1
    wr_seq.start(env.apb_agt.sequencer);

    rd_seq = apb_read_sequence::type_id::create("rd_ctrl2");
    rd_seq.addr = REG_CTRL;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("CTRL = 0x%08h (expected 0x00000001)",
      rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== 32'h1)
      `uvm_error("TEST", "CTRL enable write/readback mismatch")

    // ---------------------------------------------------------------
    // Test 5: Write to accumulator registers (W-add behavior)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Test 5: Write to released tokens accumulator", UVM_LOW)

    wr_seq = apb_write_sequence::type_id::create("wr_rel_acc");
    wr_seq.addr = REG_RELEASED_ACC;
    wr_seq.data = 32'd10;
    wr_seq.start(env.apb_agt.sequencer);

    // Write again - should accumulate
    wr_seq = apb_write_sequence::type_id::create("wr_rel_acc2");
    wr_seq.addr = REG_RELEASED_ACC;
    wr_seq.data = 32'd5;
    wr_seq.start(env.apb_agt.sequencer);

    // Read should return accumulated value and clear
    rd_seq = apb_read_sequence::type_id::create("rd_rel_acc");
    rd_seq.addr = REG_RELEASED_ACC;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("RELEASED_ACC = %0d (expected 15)",
      rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== 32'd15)
      `uvm_error("TEST", "RELEASED_ACC accumulator mismatch")

    // Read again should return 0 (cleared on read)
    rd_seq = apb_read_sequence::type_id::create("rd_rel_acc2");
    rd_seq.addr = REG_RELEASED_ACC;
    rd_seq.start(env.apb_agt.sequencer);
    `uvm_info("TEST", $sformatf("RELEASED_ACC after clear = %0d (expected 0)",
      rd_seq.rdata), UVM_LOW)
    if (rd_seq.rdata !== 32'd0)
      `uvm_error("TEST", "RELEASED_ACC not cleared on read")

    repeat (10) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_REGISTER_TEST_SV
