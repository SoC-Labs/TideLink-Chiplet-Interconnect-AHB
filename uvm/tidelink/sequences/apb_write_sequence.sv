///////////////////////////////////////////////////////////////////////////////
// apb_write_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB master sequence: single-beat write transfer.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_APB_WRITE_SEQUENCE_SV
`define GUARD_APB_WRITE_SEQUENCE_SV

class apb_write_sequence extends uvm_sequence #(apb_master_transaction);

  rand bit [14:0] addr;
  rand bit [31:0] data;

  constraint c_word_aligned { addr[1:0] == 2'b00; }

  `uvm_object_utils(apb_write_sequence)

  function new(string name = "apb_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction tr;

    `uvm_info("SEQ", $sformatf("APB write: addr=0x%04h data=0x%08h", addr, data), UVM_MEDIUM)

    tr = apb_master_transaction::type_id::create("apb_wr_tr");
    start_item(tr);
    tr.addr  = addr;
    tr.wdata = data;
    tr.write = 1'b1;
    finish_item(tr);
  endtask

endclass

`endif // GUARD_APB_WRITE_SEQUENCE_SV
