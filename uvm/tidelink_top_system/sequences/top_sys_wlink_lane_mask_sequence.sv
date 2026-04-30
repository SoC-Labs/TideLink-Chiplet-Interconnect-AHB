///////////////////////////////////////////////////////////////////////////////
// top_sys_wlink_lane_mask_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Programs the Wlink per-lane mask register at offset 0x214 on a single side.
// Both ends of the link must be programmed with identical masks before the
// link is enabled (i.e. before role_lock is asserted in the wlink_init
// sequence). The hardware does not enforce this; mismatch produces silent
// striping corruption.
//
// Field layout (see src/rdl/wlink_regs.rdl link_lane_mask_reg):
//   bits [15:0]  tx_lane_mask  bit[k]=1 enables physical TX lane k
//   bits [31:16] rx_lane_mask  bit[k]=1 enables physical RX lane k
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_WLINK_LANE_MASK_SEQUENCE_SV
`define GUARD_TOP_SYS_WLINK_LANE_MASK_SEQUENCE_SV

class top_sys_wlink_lane_mask_sequence extends uvm_sequence #(apb_master_transaction);

  `uvm_object_utils(top_sys_wlink_lane_mask_sequence)

  string         side_name = "?";
  bit [15:0]     tx_mask   = 16'h00FF;  // default: 8-lane build, all lanes enabled
  bit [15:0]     rx_mask   = 16'h00FF;

  function new(string name = "top_sys_wlink_lane_mask_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction wr_txn;

    `uvm_info("LANE_MASK", $sformatf(
      "[%s] Programming Wlink lane_mask: tx=0x%04h rx=0x%04h (active_tx=%0d active_rx=%0d)",
      side_name, tx_mask, rx_mask, $countones(tx_mask), $countones(rx_mask)), UVM_LOW)

    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h0214;  // link_lane_mask register (Wlink region 0x0000-0x1FFF)
    wr_txn.wdata = {rx_mask, tx_mask};
    wr_txn.write = 1;
    `uvm_send(wr_txn)
  endtask

endclass

`endif // GUARD_TOP_SYS_WLINK_LANE_MASK_SEQUENCE_SV
