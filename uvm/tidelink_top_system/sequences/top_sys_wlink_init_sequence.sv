///////////////////////////////////////////////////////////////////////////////
// top_sys_wlink_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB-based Wlink chiplet controller initialization sequence.
//
// The Wlink GPIO PHY configuration defaults to enabled on reset (swi_enable=1).
// This sequence is a placeholder for any additional Wlink configuration
// that may be needed (e.g., PHY-specific settings, link parameters).
//
// For the default GPIO PHY configuration, the link comes up automatically
// after reset when both sides have their PHY pads cross-connected.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
`define GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV

class top_sys_wlink_init_sequence extends uvm_sequence #(apb_master_transaction);

  `uvm_object_utils(top_sys_wlink_init_sequence)

  string side_name = "?";

  function new(string name = "top_sys_wlink_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction wr_txn;

    `uvm_info("WLINK_INIT", $sformatf("[%s] Locking chiplet controller role (accepting strap default).",
      side_name), UVM_LOW)

    `uvm_create(wr_txn)
    wr_txn.paddr  = 15'h2080;  // ROLE_CFG
    wr_txn.pwdata = 32'h0000_0002;  // role_lock=1, role=0 (accept strap default)
    wr_txn.pwrite = 1;
    `uvm_send(wr_txn)

    `uvm_info("WLINK_INIT", $sformatf("[%s] Role locked. Wlink link training in progress.",
      side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
