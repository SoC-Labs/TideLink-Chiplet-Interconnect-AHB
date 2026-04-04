///////////////////////////////////////////////////////////////////////////////
// ahb_reg_write_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: single-beat write to a register via AHB port.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_REG_WRITE_SEQUENCE_SV
`define GUARD_AHB_REG_WRITE_SEQUENCE_SV

class ahb_reg_write_sequence extends svt_ahb_master_transaction_base_sequence;

  bit [11:0] addr;
  bit [31:0] data;

  `uvm_object_utils(ahb_reg_write_sequence)

  function new(string name = "ahb_reg_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;

    `uvm_info("SEQ", $sformatf("REG write: addr=0x%03h data=0x%08h", addr, data), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == local::addr;
      data.size() == 1;
      data[0]    == local::data;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB write transaction")
    `uvm_send(req)
  endtask

endclass

`endif // GUARD_AHB_REG_WRITE_SEQUENCE_SV
