///////////////////////////////////////////////////////////////////////////////
// integration_cfg_write_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB master sequence: single-beat write to config register via unified APB
// port. TideLink registers are at offset 0x2000 in the unified address space.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_INTEGRATION_CFG_WRITE_SEQUENCE_SV
`define GUARD_INTEGRATION_CFG_WRITE_SEQUENCE_SV

class integration_cfg_write_sequence extends uvm_sequence #(apb_master_transaction);

  bit [14:0] addr;
  bit [31:0] data;

  `uvm_object_utils(integration_cfg_write_sequence)

  function new(string name = "integration_cfg_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction tr;

    `uvm_info("SEQ", $sformatf("CFG write: addr=0x%04h data=0x%08h", addr, data), UVM_MEDIUM)

    tr = apb_master_transaction::type_id::create("apb_cfg_wr_tr");
    start_item(tr);
    tr.addr  = addr;
    tr.wdata = data;
    tr.write = 1'b1;
    finish_item(tr);
  endtask

endclass

`endif // GUARD_INTEGRATION_CFG_WRITE_SEQUENCE_SV
