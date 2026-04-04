///////////////////////////////////////////////////////////////////////////////
// phc_drift_inject_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Inject a frequency drift into a PHC by writing a non-zero NS_INCR_FRAC.
//
// NS_INCR_FRAC adds a fractional nanosecond to each tick:
//   effective_incr = NS_INCR + NS_INCR_FRAC / 2^32
//
// For example, to create +100 ppm drift at NS_INCR=4:
//   drift = 4 * 100e-6 = 0.0004 ns per tick
//   NS_INCR_FRAC = 0.0004 * 2^32 = 1717987 (approx)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PHC_DRIFT_INJECT_SEQUENCE_SV
`define GUARD_PHC_DRIFT_INJECT_SEQUENCE_SV

class phc_drift_inject_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(phc_drift_inject_sequence)

  // NS_INCR_FRAC value to write (signed interpretation allowed)
  bit [31:0] ns_incr_frac = 32'd0;

  // Convenience: specify drift in ppm (will compute ns_incr_frac if non-zero)
  // Uses NS_INCR=4 as baseline. Set to 0.0 to use ns_incr_frac directly.
  real drift_ppm = 0.0;

  // Baseline NS_INCR for ppm-to-frac conversion
  bit [31:0] ns_incr = 32'd4;

  // Side identifier for logging
  string side_name = "?";

  function new(string name = "phc_drift_inject_sequence");
    super.new(name);
  endfunction

  virtual task body();
    ahb_reg_write_sequence wr_seq;
    real frac_real;

    // Convert ppm to NS_INCR_FRAC if drift_ppm is specified
    if (drift_ppm != 0.0) begin
      // drift_ns_per_tick = NS_INCR * drift_ppm * 1e-6
      // NS_INCR_FRAC = drift_ns_per_tick * 2^32
      frac_real = $itor(ns_incr) * drift_ppm * 1.0e-6 * 4294967296.0;
      ns_incr_frac = $rtoi(frac_real);
      `uvm_info("SEQ", $sformatf("[%s] Drift %.1f ppm -> NS_INCR_FRAC=0x%08h (%0d)",
        side_name, drift_ppm, ns_incr_frac, $signed(ns_incr_frac)), UVM_LOW)
    end else begin
      `uvm_info("SEQ", $sformatf("[%s] Injecting NS_INCR_FRAC=0x%08h",
        side_name, ns_incr_frac), UVM_LOW)
    end

    // Write NS_INCR_FRAC
    wr_seq = ahb_reg_write_sequence::type_id::create("wr_frac");
    wr_seq.addr = PHC_REG_NS_INCR_FRAC;
    wr_seq.data = ns_incr_frac;
    wr_seq.start(p_sequencer);

    `uvm_info("SEQ", $sformatf("[%s] Drift injection complete.", side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_PHC_DRIFT_INJECT_SEQUENCE_SV
