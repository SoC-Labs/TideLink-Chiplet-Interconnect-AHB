///////////////////////////////////////////////////////////////////////////////
// integration_cfg_read_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB master sequence: single-beat read from config register via unified APB
// port. After completion, read data is available in rdata.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_INTEGRATION_CFG_READ_SEQUENCE_SV
`define GUARD_INTEGRATION_CFG_READ_SEQUENCE_SV

class integration_cfg_read_sequence extends uvm_sequence #(apb_master_transaction);

  bit [14:0] addr;

  // Read data captured after transfer
  bit [31:0] rdata;

  `uvm_object_utils(integration_cfg_read_sequence)

  function new(string name = "integration_cfg_read_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction tr;

    `uvm_info("SEQ", $sformatf("CFG read: addr=0x%04h", addr), UVM_MEDIUM)

    tr = apb_master_transaction::type_id::create("apb_cfg_rd_tr");
    start_item(tr);
    tr.addr  = addr;
    tr.write = 1'b0;
    finish_item(tr);

    rdata = tr.rdata;
  endtask

endclass

`endif // GUARD_INTEGRATION_CFG_READ_SEQUENCE_SV
