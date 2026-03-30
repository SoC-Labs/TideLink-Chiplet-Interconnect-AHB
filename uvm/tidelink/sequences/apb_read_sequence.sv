///////////////////////////////////////////////////////////////////////////////
// apb_read_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB master sequence: single-beat read transfer.
// After completion, the read data is available in rsp.rdata.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_APB_READ_SEQUENCE_SV
`define GUARD_APB_READ_SEQUENCE_SV

class apb_read_sequence extends uvm_sequence #(apb_master_transaction);

  rand bit [11:0] addr;

  // Read data captured after transfer
  bit [31:0] rdata;

  constraint c_word_aligned { addr[1:0] == 2'b00; }

  `uvm_object_utils(apb_read_sequence)

  function new(string name = "apb_read_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction tr;

    `uvm_info("SEQ", $sformatf("APB read: addr=0x%03h", addr), UVM_MEDIUM)

    tr = apb_master_transaction::type_id::create("apb_rd_tr");
    start_item(tr);
    tr.addr  = addr;
    tr.write = 1'b0;
    finish_item(tr);

    rdata = tr.rdata;
  endtask

endclass

`endif // GUARD_APB_READ_SEQUENCE_SV
