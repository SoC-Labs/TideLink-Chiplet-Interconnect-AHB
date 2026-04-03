///////////////////////////////////////////////////////////////////////////////
// fc_seq_item.sv
///////////////////////////////////////////////////////////////////////////////
// UVM sequence item for the 48-bit FC node interface.
// Represents a single FC transfer (TX or RX direction).
//
// FC data layout (48 bits):
//   [47:46] pkt_type    -- 00=FIFO_DATA, 01=SIDEBAND
//   [45:32] addr_offset -- 14-bit byte address
//   [31:0]  payload     -- 32-bit data word
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_FC_SEQ_ITEM_SV
`define GUARD_FC_SEQ_ITEM_SV

class fc_seq_item extends uvm_sequence_item;

  // FC packet type encoding
  typedef enum bit [1:0] {
    PKT_FIFO_DATA = 2'b00,
    PKT_SIDEBAND  = 2'b01
  } fc_pkt_type_e;

  // ---------------------------------------------------------------
  // Fields
  // ---------------------------------------------------------------
  rand fc_pkt_type_e  pkt_type;
  rand bit [13:0]     addr_offset;
  rand bit [31:0]     payload;

  // Delay before driving this item (in clock cycles)
  rand int unsigned   delay;

  // ---------------------------------------------------------------
  // Constraints
  // ---------------------------------------------------------------
  constraint c_delay_default { delay inside {[0:5]}; }
  constraint c_addr_word_aligned { addr_offset[1:0] == 2'b00; }

  // ---------------------------------------------------------------
  // Utility
  // ---------------------------------------------------------------
  `uvm_object_utils_begin(fc_seq_item)
    `uvm_field_enum(fc_pkt_type_e, pkt_type, UVM_ALL_ON)
    `uvm_field_int(addr_offset, UVM_ALL_ON)
    `uvm_field_int(payload, UVM_ALL_ON)
    `uvm_field_int(delay, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "fc_seq_item");
    super.new(name);
  endfunction

  // Pack into 48-bit FC word
  function bit [47:0] pack_fc_word();
    return {pkt_type, addr_offset, payload};
  endfunction

  // Unpack from 48-bit FC word
  function void unpack_fc_word(bit [47:0] fc_word);
    pkt_type    = fc_pkt_type_e'(fc_word[47:46]);
    addr_offset = fc_word[45:32];
    payload     = fc_word[31:0];
  endfunction

endclass

`endif // GUARD_FC_SEQ_ITEM_SV
