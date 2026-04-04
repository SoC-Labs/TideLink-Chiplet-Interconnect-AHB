///////////////////////////////////////////////////////////////////////////////
// phc_offset_inject_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Inject a time offset into a PHC by writing SET_SECONDS_LO,
// SET_NANOSECONDS, then asserting SET_TIME in CTRL.
//
// This forces the target PHC to jump to the specified time,
// creating an instantaneous offset relative to its current value.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PHC_OFFSET_INJECT_SEQUENCE_SV
`define GUARD_PHC_OFFSET_INJECT_SEQUENCE_SV

class phc_offset_inject_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(phc_offset_inject_sequence)

  // Time to set (absolute)
  bit [31:0] seconds_lo   = 32'd0;
  bit [31:0] nanoseconds  = 32'd0;

  // Side identifier for logging
  string side_name = "?";

  function new(string name = "phc_offset_inject_sequence");
    super.new(name);
  endfunction

  virtual task body();
    ahb_reg_write_sequence wr_seq;

    `uvm_info("SEQ", $sformatf("[%s] Injecting PHC offset: sec=%0d nsec=%0d",
      side_name, seconds_lo, nanoseconds), UVM_LOW)

    // Write SET_SECONDS_LO
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_sec_lo");
    wr_seq.addr = PHC_REG_SET_SECONDS_LO;
    wr_seq.data = seconds_lo;
    wr_seq.start(p_sequencer);

    // Write SET_NANOSECONDS
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_nsec");
    wr_seq.addr = PHC_REG_SET_NANOSECONDS;
    wr_seq.data = nanoseconds;
    wr_seq.start(p_sequencer);

    // Assert SET_TIME in CTRL register (bit 1)
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_ctrl");
    wr_seq.addr = PHC_REG_CTRL;
    wr_seq.data = (32'h1 << PHC_CTRL_SET_TIME);
    wr_seq.start(p_sequencer);

    `uvm_info("SEQ", $sformatf("[%s] PHC offset injection complete.", side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_PHC_OFFSET_INJECT_SEQUENCE_SV
