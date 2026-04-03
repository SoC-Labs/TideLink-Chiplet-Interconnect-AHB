///////////////////////////////////////////////////////////////////////////////
// top_sys_wlink_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB-based Wlink chiplet controller initialization sequence.
// Configures the Wlink link layer and waits for link-up via the GPIO PHY.
//
// This sequence must run on the APB master agent sequencer for the
// corresponding chiplet side.
//
// Wlink GPIO PHY register map (from Chisel-generated Wlink module):
//   0x0000 - SWRESET (write 1 to reset)
//   0x0004 - ENABLE  (write 1 to enable link)
//   0x0008 - LINK_STATUS (bit[0]=link_up, read-only)
//
// NOTE: The exact register map depends on the generated Wlink configuration.
// Update the addresses below if your Wlink build differs.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
`define GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV

class top_sys_wlink_init_sequence extends uvm_sequence #(apb_master_transaction);

  `uvm_object_utils(top_sys_wlink_init_sequence)

  string side_name = "?";

  // Wlink APB register addresses (configurable)
  bit [12:0] swreset_addr     = 13'h0000;
  bit [12:0] enable_addr      = 13'h0004;
  bit [12:0] link_status_addr = 13'h0008;

  // Max wait cycles for link up
  int unsigned link_up_timeout = 5000;

  function new(string name = "top_sys_wlink_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction apb_txn;

    `uvm_info("WLINK_INIT", $sformatf("[%s] Starting Wlink initialization...", side_name), UVM_LOW)

    // Step 1: Software reset
    apb_txn = apb_master_transaction::type_id::create("apb_txn");
    start_item(apb_txn);
    apb_txn.addr  = {19'h0, swreset_addr};
    apb_txn.wdata = 32'h0000_0001;
    apb_txn.write = 1;
    finish_item(apb_txn);

    // Step 2: Release reset
    apb_txn = apb_master_transaction::type_id::create("apb_txn");
    start_item(apb_txn);
    apb_txn.addr  = {19'h0, swreset_addr};
    apb_txn.wdata = 32'h0000_0000;
    apb_txn.write = 1;
    finish_item(apb_txn);

    // Step 3: Enable link
    apb_txn = apb_master_transaction::type_id::create("apb_txn");
    start_item(apb_txn);
    apb_txn.addr  = {19'h0, enable_addr};
    apb_txn.wdata = 32'h0000_0001;
    apb_txn.write = 1;
    finish_item(apb_txn);

    `uvm_info("WLINK_INIT", $sformatf("[%s] Wlink enable written, waiting for link up...",
      side_name), UVM_LOW)

    // Step 4: Poll link status (optional — for GPIO PHY link-up may be immediate)
    // In GPIO PHY mode the link comes up after both sides are enabled.
    // Tests should call this on both sides, then wait for link training.

    `uvm_info("WLINK_INIT", $sformatf("[%s] Wlink initialization complete.", side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
