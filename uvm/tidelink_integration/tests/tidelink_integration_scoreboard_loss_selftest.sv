///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_scoreboard_loss_selftest.sv
///////////////////////////////////////////////////////////////////////////////
// CONTROL TEST for the packet-loss false-green defect (false-green register B1).
//
// Before 2026-08-26, `tidelink_integration_scoreboard::compare_loopback_data()`
// reported a TX/RX COUNT mismatch as a `uvm_warning` and then compared only
// `min(tx.size(), rx.size())` words. With an empty RX queue that loop executes
// ZERO times, so TOTAL PACKET LOSS across the loopback produced no `uvm_error`
// and the CI verdict (`grep -q 'failures="0"'`) stayed green. The queues are
// `delete()`d at the end of the same function, so the `report_phase` summary
// could never act as a backstop either.
//
// This test drives the scoreboard directly with invented specimens and asserts
// the scoreboard's OWN verdict. Run it against the pre-fix scoreboard and the
// three loss/duplication specimens raise zero errors, which it reports as a
// SELFTEST error. A negative control (matched queues) keeps a hard-wired
// always-error scoreboard from passing.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_SCOREBOARD_LOSS_SELFTEST_SV
`define GUARD_TIDELINK_INTEGRATION_SCOREBOARD_LOSS_SELFTEST_SV

// Counts and demotes the scoreboard's own SB_PKT errors so that a DELIBERATELY
// injected specimen does not fail this test. Anything else is re-thrown.
class integration_sb_pkt_error_counter extends uvm_report_catcher;

  `uvm_object_utils(integration_sb_pkt_error_counter)

  int unsigned n_errors;
  bit          armed;

  function new(string name = "integration_sb_pkt_error_counter");
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


class tidelink_integration_scoreboard_loss_selftest
  extends tidelink_integration_base_test;

  `uvm_component_utils(tidelink_integration_scoreboard_loss_selftest)

  integration_sb_pkt_error_counter sb_catcher;

  int unsigned specimens_run;
  int unsigned specimens_detected;

  function new(string name = "tidelink_integration_scoreboard_loss_selftest",
               uvm_component parent = null);
    super.new(name, parent);
    specimens_run      = 0;
    specimens_detected = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sb_catcher = integration_sb_pkt_error_counter::type_id::create("sb_catcher");
    uvm_report_cb::add(null, sb_catcher);
  endfunction

  // ---------------------------------------------------------------
  //   expect_error = 1 -> the scoreboard MUST raise >= 1 SB_PKT error
  //   expect_error = 0 -> the scoreboard MUST raise exactly 0
  // ---------------------------------------------------------------
  virtual function void run_specimen(string     label,
                                     bit [31:0] tx_words[$],
                                     bit [31:0] rx_words[$],
                                     bit        expect_error);
    int unsigned seen;
    int unsigned save_match;
    int unsigned save_mismatch;
    int unsigned save_count_mismatch;

    // These specimens are INVENTED, so the scoreboard must be left exactly as
    // it was found — otherwise the counter backstop added to report_phase would
    // fail this test on our own stimulus.
    save_match          = env.sb.packet_match_count;
    save_mismatch       = env.sb.packet_mismatch_count;
    save_count_mismatch = env.sb.packet_count_mismatches;

    env.sb.tx_write_data.delete();
    env.sb.tx_write_addr.delete();
    env.sb.rx_read_data.delete();
    env.sb.rx_read_addr.delete();
    foreach (tx_words[i]) begin
      env.sb.tx_write_data.push_back(tx_words[i]);
      env.sb.tx_write_addr.push_back(14'(i * 4));
    end
    foreach (rx_words[i]) begin
      env.sb.rx_read_data.push_back(rx_words[i]);
      env.sb.rx_read_addr.push_back(14'(i * 4));
    end

    sb_catcher.arm();
    env.sb.compare_loopback_data();
    sb_catcher.disarm();
    seen = sb_catcher.n_errors;

    specimens_run++;

    if (expect_error) begin
      if (seen == 0) begin
        `uvm_error("SB_SELFTEST", $sformatf(
          {"FALSE GREEN: specimen '%s' (%0d words TX, %0d words RX) produced ",
           "ZERO scoreboard errors. compare_loopback_data() cannot report ",
           "packet loss."},
          label, tx_words.size(), rx_words.size()))
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

    env.sb.tx_write_data.delete();
    env.sb.tx_write_addr.delete();
    env.sb.rx_read_data.delete();
    env.sb.rx_read_addr.delete();

    env.sb.packet_match_count      = save_match;
    env.sb.packet_mismatch_count   = save_mismatch;
    env.sb.packet_count_mismatches = save_count_mismatch;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] tx[$];
    bit [31:0] rx[$];

    phase.raise_objection(this);

    `uvm_info("TEST",
      "=== Integration scoreboard packet-loss self-test (control for B1) ===",
      UVM_LOW)

    // Specimen 1: TOTAL loss — the exact shape that used to pass (min_size 0).
    tx.delete(); rx.delete();
    for (int i = 0; i < 8; i++) tx.push_back(32'hA5A5_0000 + i);
    run_specimen("total loss: 8 TX / 0 RX", tx, rx, 1'b1);

    // Specimen 2: PARTIAL loss — surviving prefix matches byte-exactly.
    tx.delete(); rx.delete();
    for (int i = 0; i < 8; i++) tx.push_back(32'hDEAD_0000 + i);
    for (int i = 0; i < 5; i++) rx.push_back(32'hDEAD_0000 + i);
    run_specimen("partial loss: 8 TX / 5 RX", tx, rx, 1'b1);

    // Specimen 3: DUPLICATION — the other polarity of a count mismatch.
    tx.delete(); rx.delete();
    for (int i = 0; i < 4; i++) tx.push_back(32'hCAFE_0000 + i);
    for (int i = 0; i < 4; i++) rx.push_back(32'hCAFE_0000 + i);
    for (int i = 0; i < 2; i++) rx.push_back(32'hCAFE_0000 + i);
    run_specimen("duplication: 4 TX / 6 RX", tx, rx, 1'b1);

    // NEGATIVE CONTROL: a clean matched transfer must stay silent.
    tx.delete(); rx.delete();
    for (int i = 0; i < 6; i++) begin
      tx.push_back(32'h1234_0000 + i);
      rx.push_back(32'h1234_0000 + i);
    end
    run_specimen("matched: 6 TX / 6 RX", tx, rx, 1'b0);

    // COULD-NOT-EVALUATE guard.
    if (specimens_run != 4)
      `uvm_error("SB_SELFTEST", $sformatf(
        "COULD-NOT-EVALUATE: expected 4 specimens, ran %0d", specimens_run))

    `uvm_info("SB_SELFTEST", $sformatf(
      "Self-test complete: %0d/%0d specimens produced the correct verdict",
      specimens_detected, specimens_run), UVM_LOW)

    repeat (5) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_INTEGRATION_SCOREBOARD_LOSS_SELFTEST_SV
