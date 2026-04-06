///////////////////////////////////////////////////////////////////////////////
// sys_credit_check_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Read and verify credit-related registers on one side via APB config port.
// Returns the values for the test to inspect.
//
// TideLink config registers are at 0x2000 offset in the unified APB space.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_SYS_CREDIT_CHECK_SEQUENCE_SV
`define GUARD_SYS_CREDIT_CHECK_SEQUENCE_SV

class sys_credit_check_sequence extends uvm_sequence #(apb_master_transaction);

  // Output fields (populated after body completes)
  bit [31:0] credit_count;
  bit [31:0] pair_credit_counter;
  bit [31:0] status_reg;
  bit [31:0] rel_acc;

  // Side identifier for logging
  string side_name = "?";

  `uvm_object_utils(sys_credit_check_sequence)

  function new(string name = "sys_credit_check_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integration_cfg_read_sequence rd_seq;

    `uvm_info("SEQ", $sformatf("[%s] Reading credit registers", side_name), UVM_MEDIUM)

    // Read CREDIT_COUNT (0x2000 + REG_CREDIT_COUNT)
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_credit_count");
    rd_seq.addr = 15'h2000 + REG_CREDIT_COUNT;
    rd_seq.start(get_sequencer());
    credit_count = rd_seq.rdata;

    // Read PAIR_CREDIT_COUNTER (0x2000 + REG_PAIR_CREDIT_COUNTER)
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_pair_credit");
    rd_seq.addr = 15'h2000 + REG_PAIR_CREDIT_COUNTER;
    rd_seq.start(get_sequencer());
    pair_credit_counter = rd_seq.rdata;

    // Read STATUS (0x2000 + REG_STATUS)
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_status");
    rd_seq.addr = 15'h2000 + REG_STATUS;
    rd_seq.start(get_sequencer());
    status_reg = rd_seq.rdata;

    // Read REL_ACC (0x2000 + REG_REL_ACC)
    rd_seq = integration_cfg_read_sequence::type_id::create("rd_rel_acc");
    rd_seq.addr = 15'h2000 + REG_REL_ACC;
    rd_seq.start(get_sequencer());
    rel_acc = rd_seq.rdata;

    `uvm_info("SEQ", $sformatf(
      "[%s] Credits: count=%0d pair_counter=%0d status=0x%08h rel_acc=%0d",
      side_name, credit_count, pair_credit_counter, status_reg, rel_acc), UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_SYS_CREDIT_CHECK_SEQUENCE_SV
