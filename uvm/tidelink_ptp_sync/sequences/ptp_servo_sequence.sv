///////////////////////////////////////////////////////////////////////////////
// ptp_servo_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Run N PTP exchanges with PI servo adjustment after each:
//   1. Perform a PTP exchange to get t1/t2/t3/t4
//   2. Compute clock offset
//   3. Call servo model to get NS_INCR_FRAC adjustment
//   4. Write new NS_INCR_FRAC to PHC_B
//   5. Report exchange result to scoreboard
//
// The sequence runs on a virtual sequencer and uses the sequencer handles
// from the parent env.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SERVO_SEQUENCE_SV
`define GUARD_PTP_SERVO_SEQUENCE_SV

class ptp_servo_sequence extends uvm_sequence;

  `uvm_object_utils(ptp_servo_sequence)

  // Configuration
  ptp_sync_config cfg;

  // Servo model
  ptp_servo_model servo;

  // Scoreboard handle (set by caller)
  ptp_sync_scoreboard sb;

  // Coverage handle (set by caller)
  ptp_sync_coverage cov;

  // Sequencer handles (set by caller from virtual sequencer)
  svt_ahb_master_transaction_sequencer a_phc_sqr;
  svt_ahb_master_transaction_sequencer a_ptp_sqr;
  svt_ahb_master_transaction_sequencer b_phc_sqr;
  svt_ahb_master_transaction_sequencer b_ptp_sqr;

  // Virtual interface for clock access (wait between exchanges)
  virtual tidelink_ptp_sync_if tb_if;

  // Current NS_INCR_FRAC value on PHC_B
  bit [31:0] current_ns_incr_frac_b;

  function new(string name = "ptp_servo_sequence");
    super.new(name);
    current_ns_incr_frac_b = 32'd0;
  endfunction

  virtual task body();
    ptp_exchange_sequence exch_seq;
    ahb_reg_write_sequence wr_seq;
    int adjustment;
    int unsigned i;

    if (cfg == null)
      `uvm_fatal("NOCFG", "ptp_sync_config not set on ptp_servo_sequence")
    if (servo == null)
      `uvm_fatal("NOSERVO", "ptp_servo_model not set on ptp_servo_sequence")

    `uvm_info("SERVO_SEQ", $sformatf(
      "Starting servo loop: %0d exchanges, interval=%0d cycles, Kp=%.3f Ki=%.4f",
      cfg.num_exchanges, cfg.exchange_interval_cycles, cfg.Kp, cfg.Ki), UVM_LOW)

    for (i = 0; i < cfg.num_exchanges; i++) begin

      // ---------------------------------------------------------------
      // Step 1: Perform PTP exchange
      // ---------------------------------------------------------------
      exch_seq = ptp_exchange_sequence::type_id::create($sformatf("exch_%0d", i));
      exch_seq.a_phc_sqr = a_phc_sqr;
      exch_seq.a_ptp_sqr = a_ptp_sqr;
      exch_seq.b_phc_sqr = b_phc_sqr;
      exch_seq.b_ptp_sqr = b_ptp_sqr;
      exch_seq.start(null);

      // ---------------------------------------------------------------
      // Step 2: Compute servo adjustment
      // ---------------------------------------------------------------
      adjustment = servo.compute_adjustment(exch_seq.offset_ns);

      // ---------------------------------------------------------------
      // Step 3: Apply adjustment to PHC_B NS_INCR_FRAC
      // ---------------------------------------------------------------
      current_ns_incr_frac_b = current_ns_incr_frac_b + adjustment;

      wr_seq = ahb_reg_write_sequence::type_id::create("wr_frac_b");
      wr_seq.addr = PHC_REG_NS_INCR_FRAC;
      wr_seq.data = current_ns_incr_frac_b;
      wr_seq.start(b_phc_sqr);

      // ---------------------------------------------------------------
      // Step 4: Report to scoreboard and coverage
      // ---------------------------------------------------------------
      if (sb != null)
        sb.record_exchange(i, exch_seq.offset_ns, exch_seq.delay_ns,
                           current_ns_incr_frac_b);

      if (cov != null) begin
        cov.sample_adjustment(adjustment);
        cov.sample_residual(exch_seq.offset_ns);
      end

      `uvm_info("SERVO_SEQ", $sformatf(
        "[%0d/%0d] offset=%.3f ns, adj=%0d, frac_b=0x%08h",
        i, cfg.num_exchanges, exch_seq.offset_ns, adjustment,
        current_ns_incr_frac_b), UVM_MEDIUM)

      // ---------------------------------------------------------------
      // Step 5: Wait for next exchange interval
      // ---------------------------------------------------------------
      if (tb_if != null)
        repeat (cfg.exchange_interval_cycles) @(posedge tb_if.clk);

    end

    `uvm_info("SERVO_SEQ", "Servo loop complete.", UVM_LOW)
  endtask

endclass

`endif // GUARD_PTP_SERVO_SEQUENCE_SV
