///////////////////////////////////////////////////////////////////////////////
// tidelink_scoreboard_loss_selftest.sv
///////////////////////////////////////////////////////////////////////////////
// CONTROL TEST for the packet-loss false-green defect (false-green register B1).
//
// Before 2026-08-26, `tidelink_scoreboard::compare_packet_data()` reported a
// write/read COUNT mismatch as a `uvm_warning` and then compared only
// `min(write.size(), read.size())` words. With an empty read queue that loop
// executes ZERO times, so TOTAL PACKET LOSS produced no `uvm_error` at all and
// the CI verdict (`grep -q 'failures="0"'`) stayed green. The queues are
// `delete()`d at the end of the same function, so the `report_phase` summary
// could never act as a backstop either.
//
// This test drives the scoreboard directly with invented specimens and asserts
// the scoreboard's OWN verdict. It is deliberately written so that it FAILS
// against the pre-fix scoreboard: run it on the old code and the three
// loss/duplication specimens raise zero errors, which this test reports as a
// SELFTEST error.
//
// It also carries a negative control (matched queues) so that a scoreboard
// hard-wired to error on everything would not pass either.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SCOREBOARD_LOSS_SELFTEST_SV
`define GUARD_TIDELINK_SCOREBOARD_LOSS_SELFTEST_SV

// ---------------------------------------------------------------
// Counts and demotes the scoreboard's own SB_PKT errors so that a
// DELIBERATELY injected specimen does not fail this test. Anything
// the catcher does not recognise is re-thrown untouched.
// ---------------------------------------------------------------
class sb_pkt_error_counter extends uvm_report_catcher;

  `uvm_object_utils(sb_pkt_error_counter)

  int unsigned n_errors;
  bit          armed;

  function new(string name = "sb_pkt_error_counter");
    super.new(name);
    n_errors = 0;
    armed    = 0;
  endfunction

  function void arm();
    n_errors = 0;
    armed    = 1;
  endfunction

  function void disarm();
    armed = 0;
  endfunction

  virtual function action_e catch();
    if (armed && get_severity() == UVM_ERROR && get_id() == "SB_PKT") begin
      n_errors++;
      set_severity(UVM_INFO);
      set_action(UVM_NO_ACTION);
      return CAUGHT;
    end
    return THROW;
  endfunction

endclass


class tidelink_scoreboard_loss_selftest extends tidelink_base_test;

  `uvm_component_utils(tidelink_scoreboard_loss_selftest)

  sb_pkt_error_counter sb_catcher;

  int unsigned specimens_run;
  int unsigned specimens_detected;

  function new(string name = "tidelink_scoreboard_loss_selftest",
               uvm_component parent = null);
    super.new(name, parent);
    specimens_run      = 0;
    specimens_detected = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sb_catcher = sb_pkt_error_counter::type_id::create("sb_catcher");
    uvm_report_cb::add(null, sb_catcher);
  endfunction

  // ---------------------------------------------------------------
  // Drive one specimen through the scoreboard and demand a verdict.
  //   expect_error = 1 -> the scoreboard MUST raise >= 1 SB_PKT error
  //   expect_error = 0 -> the scoreboard MUST raise exactly 0
  // ---------------------------------------------------------------
  virtual function void run_specimen(string        label,
                                     bit [31:0]    wr_words[$],
                                     bit [31:0]    rd_words[$],
                                     bit           expect_error);
    int unsigned seen;
    int unsigned save_match;
    int unsigned save_mismatch;
    int unsigned save_count_mismatch;

    // Snapshot the scoreboard's counters. These specimens are INVENTED, so the
    // scoreboard must be left exactly as it was found — otherwise the counter
    // backstop in report_phase would fail this test on our own stimulus.
    save_match          = env.sb.packet_match_count;
    save_mismatch       = env.sb.packet_mismatch_count;
    save_count_mismatch = env.sb.packet_count_mismatches;

    env.sb.write_packet_data.delete();
    env.sb.read_packet_data.delete();
    foreach (wr_words[i]) env.sb.write_packet_data.push_back(wr_words[i]);
    foreach (rd_words[i]) env.sb.read_packet_data.push_back(rd_words[i]);

    sb_catcher.arm();
    env.sb.compare_packet_data();
    sb_catcher.disarm();
    seen = sb_catcher.n_errors;

    specimens_run++;

    if (expect_error) begin
      if (seen == 0) begin
        `uvm_error("SB_SELFTEST", $sformatf(
          {"FALSE GREEN: specimen '%s' (%0d words written, %0d words read) ",
           "produced ZERO scoreboard errors. compare_packet_data() cannot ",
           "report packet loss."},
          label, wr_words.size(), rd_words.size()))
      end else begin
        specimens_detected++;
        `uvm_info("SB_SELFTEST", $sformatf(
          "OK: specimen '%s' correctly raised %0d scoreboard error(s)",
          label, seen), UVM_LOW)
      end
    end else begin
      if (seen != 0) begin
        `uvm_error("SB_SELFTEST", $sformatf(
          {"FALSE RED: specimen '%s' is a MATCHED transfer but the scoreboard ",
           "raised %0d error(s). The loss check is over-firing."},
          label, seen))
      end else begin
        specimens_detected++;
        `uvm_info("SB_SELFTEST", $sformatf(
          "OK: specimen '%s' (matched transfer) raised no error", label), UVM_LOW)
      end
    end

    // compare_packet_data() deletes the queues itself; make that explicit so
    // the scoreboard's report_phase re-comparison sees a clean slate.
    env.sb.write_packet_data.delete();
    env.sb.read_packet_data.delete();

    // Restore the counters clobbered by the invented specimen.
    env.sb.packet_match_count       = save_match;
    env.sb.packet_mismatch_count    = save_mismatch;
    env.sb.packet_count_mismatches  = save_count_mismatch;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] wr[$];
    bit [31:0] rd[$];

    phase.raise_objection(this);

    `uvm_info("TEST", "=== Scoreboard packet-loss self-test (control for B1) ===",
              UVM_LOW)

    // -------------------------------------------------------------
    // Specimen 1: TOTAL packet loss. 8 words written, none read back.
    // This is the exact shape that used to pass: min_size == 0.
    // -------------------------------------------------------------
    wr.delete(); rd.delete();
    for (int i = 0; i < 8; i++) wr.push_back(32'hA5A5_0000 + i);
    run_specimen("total loss: 8 written / 0 read", wr, rd, 1'b1);

    // -------------------------------------------------------------
    // Specimen 2: PARTIAL loss. The surviving prefix matches byte-exactly,
    // so the per-word loop finds nothing wrong.
    // -------------------------------------------------------------
    wr.delete(); rd.delete();
    for (int i = 0; i < 8; i++) wr.push_back(32'hDEAD_0000 + i);
    for (int i = 0; i < 5; i++) rd.push_back(32'hDEAD_0000 + i);
    run_specimen("partial loss: 8 written / 5 read", wr, rd, 1'b1);

    // -------------------------------------------------------------
    // Specimen 3: DUPLICATION, the other polarity of a count mismatch.
    // -------------------------------------------------------------
    wr.delete(); rd.delete();
    for (int i = 0; i < 4; i++) wr.push_back(32'hCAFE_0000 + i);
    for (int i = 0; i < 4; i++) rd.push_back(32'hCAFE_0000 + i);
    for (int i = 0; i < 2; i++) rd.push_back(32'hCAFE_0000 + i);
    run_specimen("duplication: 4 written / 6 read", wr, rd, 1'b1);

    // -------------------------------------------------------------
    // NEGATIVE CONTROL: a clean matched transfer must stay silent.
    // Without this, a scoreboard that errors unconditionally would pass.
    // -------------------------------------------------------------
    wr.delete(); rd.delete();
    for (int i = 0; i < 6; i++) begin
      wr.push_back(32'h1234_0000 + i);
      rd.push_back(32'h1234_0000 + i);
    end
    run_specimen("matched: 6 written / 6 read", wr, rd, 1'b0);

    // -------------------------------------------------------------
    // COULD-NOT-EVALUATE guard: if the specimens never ran, this test
    // must not be mistaken for a pass.
    // -------------------------------------------------------------
    if (specimens_run != 4)
      `uvm_error("SB_SELFTEST", $sformatf(
        "COULD-NOT-EVALUATE: expected 4 specimens, ran %0d", specimens_run))

    `uvm_info("SB_SELFTEST", $sformatf(
      "Self-test complete: %0d/%0d specimens produced the correct verdict",
      specimens_detected, specimens_run), UVM_LOW)

    repeat (5) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_SCOREBOARD_LOSS_SELFTEST_SV
