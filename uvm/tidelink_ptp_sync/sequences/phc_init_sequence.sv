///////////////////////////////////////////////////////////////////////////////
// phc_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Initialise both PHCs:
//   1. Write NS_INCR = 4 (4 ns per tick at 250 MHz PHC clock, or
//      matching the nominal increment for the testbench clock)
//   2. Enable PTP on both sides
//   3. Optionally set a different NS_INCR_FRAC on side B to model
//      a frequency offset between the two oscillators
//
// This sequence is run on side A's PHC sequencer; it expects the
// caller to also invoke it (or a separate instance) on side B's
// PHC sequencer via the virtual sequencer handles.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PHC_INIT_SEQUENCE_SV
`define GUARD_PHC_INIT_SEQUENCE_SV

class phc_init_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(phc_init_sequence)

  // Nominal nanosecond increment per tick (default 4 ns)
  bit [31:0] ns_incr = 32'd4;

  // Fractional nanosecond increment (0 = no sub-ns correction)
  bit [31:0] ns_incr_frac = 32'd0;

  // Side identifier for logging
  string side_name = "?";

  function new(string name = "phc_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    ahb_reg_write_sequence wr_seq;

    `uvm_info("SEQ", $sformatf("[%s] PHC init: NS_INCR=%0d NS_INCR_FRAC=0x%08h",
      side_name, ns_incr, ns_incr_frac), UVM_LOW)

    // Write NS_INCR
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_ns_incr");
    wr_seq.addr = PHC_REG_NS_INCR;
    wr_seq.data = ns_incr;
    wr_seq.start(p_sequencer);

    // Write NS_INCR_FRAC
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_ns_incr_frac");
    wr_seq.addr = PHC_REG_NS_INCR_FRAC;
    wr_seq.data = ns_incr_frac;
    wr_seq.start(p_sequencer);

    // Select TideLink as hardware servo source (SRC_SEL=0)
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_servo_ctrl");
    wr_seq.addr = PHC_REG_SERVO_CTRL;
    wr_seq.data = 32'h0000_0000;
    wr_seq.start(p_sequencer);

    `uvm_info("SEQ", $sformatf("[%s] PHC init complete.", side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_PHC_INIT_SEQUENCE_SV
