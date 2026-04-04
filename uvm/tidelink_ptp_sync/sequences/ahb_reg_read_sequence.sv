///////////////////////////////////////////////////////////////////////////////
// ahb_reg_read_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: single-beat read from a register via AHB port.
// After completion, read data is available in rdata.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_REG_READ_SEQUENCE_SV
`define GUARD_AHB_REG_READ_SEQUENCE_SV

class ahb_reg_read_sequence extends svt_ahb_master_transaction_base_sequence;

  bit [11:0] addr;

  // Read data captured after transfer
  bit [31:0] rdata;

  `uvm_object_utils(ahb_reg_read_sequence)

  function new(string name = "ahb_reg_read_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;

    `uvm_info("SEQ", $sformatf("REG read: addr=0x%03h", addr), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == local::addr;
      data.size() == 1;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB read transaction")
    `uvm_send(req)

    if (req.data.size() > 0)
      rdata = req.data[0];
  endtask

endclass

`endif // GUARD_AHB_REG_READ_SEQUENCE_SV
