///////////////////////////////////////////////////////////////////////////////
// ahb_tx_seq_item.sv
///////////////////////////////////////////////////////////////////////////////
// UVM sequence item for AHB master write transactions.
// Used by both TX aperture and returner agents.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_TX_SEQ_ITEM_SV
`define GUARD_AHB_TX_SEQ_ITEM_SV

class ahb_tx_seq_item extends uvm_sequence_item;

  rand bit [31:0] addr;
  rand bit [31:0] data;
  rand bit  [2:0] hsize;
  rand int unsigned delay;

  constraint c_word_size  { hsize == 3'b010; }
  constraint c_word_align { addr[1:0] == 2'b00; }
  constraint c_delay      { delay inside {[0:3]}; }

  `uvm_object_utils_begin(ahb_tx_seq_item)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_int(data, UVM_ALL_ON)
    `uvm_field_int(hsize, UVM_ALL_ON)
    `uvm_field_int(delay, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "ahb_tx_seq_item");
    super.new(name);
  endfunction

endclass

`endif // GUARD_AHB_TX_SEQ_ITEM_SV
