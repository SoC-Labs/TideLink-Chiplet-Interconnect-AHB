///////////////////////////////////////////////////////////////////////////////
// top_sys_ahb_sub_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB write/read sequence for the regular AHB subordinate (ahb_sub) port.
// Used to exercise the XHB500 + Wlink AHB passthrough path.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_AHB_SUB_SEQUENCE_SV
`define GUARD_TOP_SYS_AHB_SUB_SEQUENCE_SV

class top_sys_ahb_sub_write_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(top_sys_ahb_sub_write_sequence)

  bit [31:0] addr = 32'h0000_1000;
  bit [31:0] data = 32'hCAFE_F00D;

  function new(string name = "top_sys_ahb_sub_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;
    svt_ahb_master_configuration cfg;

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("AHB_SUB", "Failed to cast SVT configuration")

    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == local::addr;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == local::data;
    });
    `uvm_send(txn)
  endtask

endclass

class top_sys_ahb_sub_read_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(top_sys_ahb_sub_read_sequence)

  bit [31:0] addr = 32'h0000_2000;
  bit [31:0] rdata;

  function new(string name = "top_sys_ahb_sub_read_sequence");
    super.new(name);
  endfunction

  virtual task body();
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;
    svt_ahb_master_configuration cfg;

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("AHB_SUB", "Failed to cast SVT configuration")

    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      addr       == local::addr;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
    });
    `uvm_send(txn)
    if (txn.data.size() > 0)
      rdata = txn.data[0];
  endtask

endclass

`endif // GUARD_TOP_SYS_AHB_SUB_SEQUENCE_SV
