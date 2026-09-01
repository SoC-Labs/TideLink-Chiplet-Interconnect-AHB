///////////////////////////////////////////////////////////////////////////////
// tl_top_sb_selftest.sv
///////////////////////////////////////////////////////////////////////////////
// CONTROL TEST for false-green register B2 (and the B1 family in this file).
//
// The tidelink_top_system ENV is quarantined — it does not elaborate (see the
// QUARANTINED banner in ../Makefile). That quarantine is a DUT/TB port-rot
// problem; the scoreboard itself is a pure UVM component with no RTL
// dependency, so it can still be executed. This harness compiles UVM + the
// AMBA VIP transaction types + the scoreboard ALONE, with no design under
// test, and exercises the scoreboard's verdict path directly.
//
// The defect under test:
//   report_phase() calls compare_a2b_data()/compare_b2a_data(), both of which
//   delete() every queue before returning. The unmatched-TX backstop that
//   followed read `a_tx_write_data.size() > 0` — always false at that point.
//   The one check that exists to report lost packets could never fire.
//
// Specimen: leave 6 A->B TX words with 0 FIFO reads standing at end of test,
// and 4 B->A TX words with 1 FIFO read. Both are total/partial loss. The
// scoreboard must report them. Errors from the scoreboard are demoted by a
// report catcher so only this test's own meta-verdict escapes.
//
// Negative control: a matched A->B pair injected and compared mid-test must
// produce no error at all.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TL_TOP_SB_SELFTEST_SV
`define GUARD_TL_TOP_SB_SELFTEST_SV

// Counts and demotes the scoreboard's own verdicts. Records whether an
// "unmatched" message (the B2 backstop) was among them.
class tl_top_sb_catcher extends uvm_report_catcher;

  `uvm_object_utils(tl_top_sb_catcher)

  int unsigned n_errors;
  int unsigned n_unmatched_errors;
  int unsigned n_count_mismatch_errors;
  bit          armed;

  function new(string name = "tl_top_sb_catcher");
    super.new(name);
    n_errors                = 0;
    n_unmatched_errors      = 0;
    n_count_mismatch_errors = 0;
    armed                   = 0;
  endfunction

  function void arm();
    armed = 1;
  endfunction

  function void reset_counts();
    n_errors                = 0;
    n_unmatched_errors      = 0;
    n_count_mismatch_errors = 0;
  endfunction

  virtual function action_e catch();
    string id;
    string msg;
    id  = get_id();
    msg = get_message();
    if (armed && get_severity() == UVM_ERROR &&
        (id == "SB_A2B" || id == "SB_B2A" || id == "SB_REPORT")) begin
      n_errors++;
      // uvm_is_match uses glob syntax: '*' matches any run of characters.
      if (uvm_is_match("*unmatched*", msg))       n_unmatched_errors++;
      if (uvm_is_match("*word-count mismatch*", msg)) n_count_mismatch_errors++;
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction

endclass


class tl_top_sb_selftest extends uvm_test;

  `uvm_component_utils(tl_top_sb_selftest)

  tidelink_top_system_scoreboard sb;
  tl_top_sb_catcher              cat;

  int unsigned checks_run;
  int unsigned checks_ok;

  function new(string name = "tl_top_sb_selftest", uvm_component parent = null);
    super.new(name, parent);
    checks_run = 0;
    checks_ok  = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sb  = tidelink_top_system_scoreboard::type_id::create("sb", this);
    cat = tl_top_sb_catcher::type_id::create("cat");
    uvm_report_cb::add(null, cat);
    cat.arm();
  endfunction

  function void expect_true(string label, bit cond, string detail);
    checks_run++;
    if (cond) begin
      checks_ok++;
      `uvm_info("SB_SELFTEST", $sformatf("OK: %s", label), UVM_LOW)
    end else begin
      `uvm_error("SB_SELFTEST", $sformatf("%s -- %s", label, detail))
    end
  endfunction

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);

    `uvm_info("TEST",
      "=== tidelink_top_system scoreboard self-test (control for B2) ===",
      UVM_LOW)

    // -------------------------------------------------------------
    // NEGATIVE CONTROL first: a matched A->B transfer, compared
    // explicitly, must be silent. Without this, a scoreboard that
    // errors unconditionally would pass this test.
    // -------------------------------------------------------------
    cat.reset_counts();
    for (int i = 0; i < 5; i++) begin
      sb.a_tx_write_data.push_back(32'h1111_0000 + i);
      sb.a_tx_write_addr.push_back(14'(i * 4));
      sb.b_fifo_read_data.push_back(32'h1111_0000 + i);
      sb.b_fifo_read_addr.push_back(14'(i * 4));
    end
    sb.compare_a2b_data();
    expect_true("negative control: matched 5/5 A->B raises no error",
                cat.n_errors == 0,
                $sformatf("FALSE RED: %0d error(s) on a matched transfer",
                          cat.n_errors));

    // -------------------------------------------------------------
    // SPECIMEN: leave loss standing in the queues at end of test.
    // report_phase is the ONLY thing that will look at them, and the
    // backstop there is what B2 says can never fire.
    //   A->B: 6 words written, 0 read back  (total loss)
    //   B->A: 4 words written, 1 read back  (partial loss)
    // -------------------------------------------------------------
    cat.reset_counts();
    for (int i = 0; i < 6; i++) begin
      sb.a_tx_write_data.push_back(32'hA5A5_0000 + i);
      sb.a_tx_write_addr.push_back(14'(i * 4));
    end
    for (int i = 0; i < 4; i++) begin
      sb.b_tx_write_data.push_back(32'hB6B6_0000 + i);
      sb.b_tx_write_addr.push_back(14'(i * 4));
    end
    sb.a_fifo_read_data.push_back(32'hB6B6_0000);
    sb.a_fifo_read_addr.push_back(14'h0);

    `uvm_info("SB_SELFTEST",
      "Injected 6/0 A->B and 4/1 B->A packet loss; leaving it for report_phase",
      UVM_LOW)

    phase.drop_objection(this);
  endtask

  // report_phase is bottom-up: the scoreboard (a child) has already run its
  // own report_phase by the time this executes, so its verdict is in the
  // catcher.
  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);

    expect_true("scoreboard reports the standing A->B / B->A loss at all",
                cat.n_errors > 0,
                "FALSE GREEN: 10 lost words produced ZERO scoreboard errors");

    expect_true("count-mismatch check fires (B1 family)",
                cat.n_count_mismatch_errors >= 2,
                $sformatf({"expected >=2 word-count-mismatch errors (one per ",
                           "direction), saw %0d"}, cat.n_count_mismatch_errors));

    expect_true("unmatched-TX backstop fires (B2)",
                cat.n_unmatched_errors >= 2,
                $sformatf({"FALSE GREEN: the report_phase unmatched-TX backstop ",
                           "raised %0d errors. It reads a queue that ",
                           "compare_*_data() has already delete()d, so it is ",
                           "unreachable."}, cat.n_unmatched_errors));

    // COULD-NOT-EVALUATE guard: 1 check in main_phase + 3 here.
    if (checks_run != 4)
      `uvm_error("SB_SELFTEST", $sformatf(
        "COULD-NOT-EVALUATE: expected 4 checks, ran %0d", checks_run));

    `uvm_info("SB_SELFTEST", $sformatf(
      "Self-test complete: %0d/%0d checks passed", checks_ok, checks_run),
      UVM_LOW)
  endfunction

  function void final_phase(uvm_phase phase);
    uvm_report_server svr;
    super.final_phase(phase);
    svr = uvm_report_server::get_server();
    if (svr.get_severity_count(UVM_FATAL) +
        svr.get_severity_count(UVM_ERROR) > 0)
      `uvm_info("final_phase", "\n========== TEST FAILED ==========\n", UVM_NONE)
    else
      `uvm_info("final_phase", "\n========== TEST PASSED ==========\n", UVM_NONE)
  endfunction

endclass

`endif // GUARD_TL_TOP_SB_SELFTEST_SV
