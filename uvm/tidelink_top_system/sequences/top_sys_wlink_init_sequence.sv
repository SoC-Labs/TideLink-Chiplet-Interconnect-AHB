///////////////////////////////////////////////////////////////////////////////
// top_sys_wlink_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB-based Wlink chiplet controller initialization sequence.
//
// Writes ROLE_CFG (offset 0x2080) with the per-side role and the lock bit:
//   bit[0] = role (0=master, 1=slave) — OVERRIDES the strap when locked
//   bit[1] = role_lock (W1S) — releases Wlink from POR
//
// IMPORTANT: bit[0] overrides the strap. Writing 0x02 ("accept strap default")
// is misleading — it actually FORCES role=master (0) regardless of strap.
// Each side must write its intended role explicitly. Setting both sides to
// master (the prior bug) leaves the link with no slave to grant credits, so
// the FC adapter stalls when traffic starts.
//
// Set `is_slave = 1` on the slave side before starting the sequence; default
// is_slave = 0 (master).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
`define GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV

class top_sys_wlink_init_sequence extends uvm_sequence #(apb_master_transaction);

  `uvm_object_utils(top_sys_wlink_init_sequence)

  string side_name = "?";
  bit    is_slave  = 0;  // 0=master (default), 1=slave

  function new(string name = "top_sys_wlink_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction wr_txn;
    bit [31:0] role_cfg_value;

    // bit[1]=lock, bit[0]=role override (0=master, 1=slave)
    role_cfg_value = is_slave ? 32'h0000_0003 : 32'h0000_0002;

    `uvm_info("WLINK_INIT", $sformatf(
      "[%s] Locking chiplet controller role (role=%s, ROLE_CFG=0x%08h).",
      side_name, is_slave ? "slave" : "master", role_cfg_value), UVM_LOW)

    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h2080;  // ROLE_CFG
    wr_txn.wdata = role_cfg_value;
    wr_txn.write = 1;
    `uvm_send(wr_txn)

    `uvm_info("WLINK_INIT", $sformatf("[%s] Role locked. Wlink link training in progress.",
      side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
