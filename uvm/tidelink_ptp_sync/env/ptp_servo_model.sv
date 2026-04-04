///////////////////////////////////////////////////////////////////////////////
// ptp_servo_model.sv
///////////////////////////////////////////////////////////////////////////////
// PI (Proportional-Integral) servo controller model for PTP clock recovery.
//
// Accepts a measured offset in nanoseconds and produces an NS_INCR_FRAC
// adjustment value. The integral term accumulates over successive calls
// to track steady-state frequency error. Output is clamped to
// +/- max_adjustment.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SERVO_MODEL_SV
`define GUARD_PTP_SERVO_MODEL_SV

class ptp_servo_model extends uvm_object;

  `uvm_object_utils(ptp_servo_model)

  // PI gains
  real Kp;
  real Ki;

  // Integral accumulator
  real integral;

  // Output clamp (in raw adjustment units before NS_INCR_FRAC scaling)
  real max_adjustment;

  function new(string name = "ptp_servo_model");
    super.new(name);
    Kp           = 0.5;
    Ki           = 0.01;
    integral     = 0.0;
    max_adjustment = 1000000.0;
  endfunction

  // ---------------------------------------------------------------
  // Initialise from a ptp_sync_config object
  // ---------------------------------------------------------------
  function void configure(ptp_sync_config cfg);
    Kp             = cfg.Kp;
    Ki             = cfg.Ki;
    max_adjustment = cfg.max_adjustment;
    integral       = 0.0;
  endfunction

  // ---------------------------------------------------------------
  // Reset the integral accumulator (e.g. after a step change)
  // ---------------------------------------------------------------
  function void reset();
    integral = 0.0;
  endfunction

  // ---------------------------------------------------------------
  // Compute NS_INCR_FRAC adjustment from a measured offset
  //
  // offset_ns : signed clock offset in nanoseconds (positive = B ahead)
  // Returns   : signed delta to add to NS_INCR_FRAC on PHC_B
  //
  // The scaling factor 2^32 / 1e9 converts a nanosecond-domain
  // correction into the 32-bit fractional nanosecond increment
  // register space.
  // ---------------------------------------------------------------
  function int compute_adjustment(real offset_ns);
    real error;
    real raw;
    real scaled;

    error = offset_ns;
    integral += error;

    raw = Kp * error + Ki * integral;

    // Clamp
    if (raw > max_adjustment) raw = max_adjustment;
    if (raw < -max_adjustment) raw = -max_adjustment;

    // Convert ns-domain correction to NS_INCR_FRAC delta
    // 2^32 / 1e9 = 4.294967296
    scaled = raw * 4294967296.0 / 1.0e9;

    return int'(scaled);
  endfunction

endclass

`endif // GUARD_PTP_SERVO_MODEL_SV
