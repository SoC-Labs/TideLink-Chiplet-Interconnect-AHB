///////////////////////////////////////////////////////////////////////////////
// ptp_sync_coverage.sv
///////////////////////////////////////////////////////////////////////////////
// Functional coverage collector for PTP synchronisation verification.
//
// Covergroups track:
//   - Initial offset magnitude bins
//   - Frequency error (drift) bins
//   - Settling time bins
//   - Residual error after convergence
//   - Servo adjustment magnitude
//   - Step-change recovery time
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SYNC_COVERAGE_SV
`define GUARD_PTP_SYNC_COVERAGE_SV

class ptp_sync_coverage extends uvm_component;

  `uvm_component_utils(ptp_sync_coverage)

  // Sampled values
  real sample_initial_offset_ns;
  real sample_frequency_error_ppm;
  int unsigned sample_settling_exchanges;
  real sample_residual_ns;
  int  sample_servo_adjustment;
  int unsigned sample_step_recovery_exchanges;

  // ---------------------------------------------------------------
  // Covergroups
  // ---------------------------------------------------------------

  covergroup cg_initial_offset;
    option.per_instance = 1;
    option.name = "cg_initial_offset";

    offset_ns: coverpoint sample_initial_offset_ns {
      bins zero           = {0};
      bins tiny_pos       = {[1:100]};
      bins small_pos      = {[101:1000]};
      bins medium_pos     = {[1001:10000]};
      bins large_pos      = {[10001:$]};
      bins tiny_neg       = {[-100:-1]};
      bins small_neg      = {[-1000:-101]};
      bins medium_neg     = {[-10000:-1001]};
      bins large_neg      = {[$:-10001]};
    }
  endgroup

  covergroup cg_frequency_error;
    option.per_instance = 1;
    option.name = "cg_frequency_error";

    freq_ppm: coverpoint sample_frequency_error_ppm {
      bins zero            = {0};
      bins low_pos         = {[1:10]};
      bins medium_pos      = {[11:100]};
      bins high_pos        = {[101:500]};
      bins low_neg         = {[-10:-1]};
      bins medium_neg      = {[-100:-11]};
      bins high_neg        = {[-500:-101]};
    }
  endgroup

  covergroup cg_settling_time;
    option.per_instance = 1;
    option.name = "cg_settling_time";

    exchanges: coverpoint sample_settling_exchanges {
      bins fast        = {[1:10]};
      bins moderate    = {[11:50]};
      bins slow        = {[51:100]};
      bins very_slow   = {[101:200]};
      bins did_not     = {[201:$]};
    }
  endgroup

  covergroup cg_residual_error;
    option.per_instance = 1;
    option.name = "cg_residual_error";

    residual_ns: coverpoint sample_residual_ns {
      bins sub_ns      = {[0:1]};
      bins few_ns      = {[2:5]};
      bins moderate    = {[6:10]};
      bins large       = {[11:$]};
    }
  endgroup

  covergroup cg_servo_adjustment;
    option.per_instance = 1;
    option.name = "cg_servo_adjustment";

    adjustment: coverpoint sample_servo_adjustment {
      bins zero          = {0};
      bins small_pos     = {[1:1000]};
      bins medium_pos    = {[1001:100000]};
      bins large_pos     = {[100001:$]};
      bins small_neg     = {[-1000:-1]};
      bins medium_neg    = {[-100000:-1001]};
      bins large_neg     = {[$:-100001]};
    }
  endgroup

  covergroup cg_step_recovery;
    option.per_instance = 1;
    option.name = "cg_step_recovery";

    recovery: coverpoint sample_step_recovery_exchanges {
      bins fast        = {[1:20]};
      bins moderate    = {[21:50]};
      bins slow        = {[51:100]};
      bins very_slow   = {[101:$]};
    }
  endgroup

  function new(string name = "ptp_sync_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_initial_offset   = new();
    cg_frequency_error  = new();
    cg_settling_time    = new();
    cg_residual_error   = new();
    cg_servo_adjustment = new();
    cg_step_recovery    = new();

    sample_initial_offset_ns       = 0.0;
    sample_frequency_error_ppm     = 0.0;
    sample_settling_exchanges      = 0;
    sample_residual_ns             = 0.0;
    sample_servo_adjustment        = 0;
    sample_step_recovery_exchanges = 0;
  endfunction

  // ---------------------------------------------------------------
  // Sample methods (called by tests/sequences)
  // ---------------------------------------------------------------
  function void sample_initial_offset(real offset_ns);
    sample_initial_offset_ns = offset_ns;
    cg_initial_offset.sample();
  endfunction

  function void sample_freq_error(real ppm);
    sample_frequency_error_ppm = ppm;
    cg_frequency_error.sample();
  endfunction

  function void sample_settling(int unsigned exchanges);
    sample_settling_exchanges = exchanges;
    cg_settling_time.sample();
  endfunction

  function void sample_residual(real residual_ns);
    sample_residual_ns = (residual_ns < 0.0) ? -residual_ns : residual_ns;
    cg_residual_error.sample();
  endfunction

  function void sample_adjustment(int adjustment);
    sample_servo_adjustment = adjustment;
    cg_servo_adjustment.sample();
  endfunction

  function void sample_recovery(int unsigned exchanges);
    sample_step_recovery_exchanges = exchanges;
    cg_step_recovery.sample();
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    `uvm_info("COV_PTP", $sformatf({
      "\n",
      "---------- PTP Sync Coverage Summary ----------\n",
      "  cg_initial_offset:   %.1f%%\n",
      "  cg_frequency_error:  %.1f%%\n",
      "  cg_settling_time:    %.1f%%\n",
      "  cg_residual_error:   %.1f%%\n",
      "  cg_servo_adjustment: %.1f%%\n",
      "  cg_step_recovery:    %.1f%%\n",
      "------------------------------------------------"},
      cg_initial_offset.get_coverage(),
      cg_frequency_error.get_coverage(),
      cg_settling_time.get_coverage(),
      cg_residual_error.get_coverage(),
      cg_servo_adjustment.get_coverage(),
      cg_step_recovery.get_coverage()), UVM_LOW)
  endfunction

endclass

`endif // GUARD_PTP_SYNC_COVERAGE_SV
