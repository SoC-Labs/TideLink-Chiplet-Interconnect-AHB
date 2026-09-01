///////////////////////////////////////////////////////////////////////////////
// tidelink_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// UVM scoreboard for TideLink verification.
//
// Tracks:
//   1. Packet data integrity: data written to FIFO matches data read back
//   2. Returner transactions: verifies credit returns and doorbell writes
//      target the correct pair addresses
//   3. APB register operations for coverage
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SCOREBOARD_SV
`define GUARD_TIDELINK_SCOREBOARD_SV

// Analysis imp declarations
`uvm_analysis_imp_decl(_fifo_ahb)
`uvm_analysis_imp_decl(_ret_ahb)
`uvm_analysis_imp_decl(_apb)

class tidelink_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(tidelink_scoreboard)

  // Analysis exports
  uvm_analysis_imp_fifo_ahb #(svt_ahb_transaction, tidelink_scoreboard) fifo_ahb_export;
  uvm_analysis_imp_ret_ahb  #(svt_ahb_transaction, tidelink_scoreboard) ret_ahb_export;
  uvm_analysis_imp_apb      #(apb_master_transaction, tidelink_scoreboard) apb_export;

  // Packet tracking: write data queue and read data queue
  bit [31:0] write_packet_data[$];
  bit [31:0] read_packet_data[$];

  // Expected pair base address (set by test via config_db)
  bit [31:0] expected_pair_base = 32'h4000_0000;

  // Counters
  int unsigned fifo_write_count;
  int unsigned fifo_read_count;
  int unsigned returner_txn_count;
  int unsigned apb_txn_count;
  int unsigned packet_match_count;
  int unsigned packet_mismatch_count;
  // Word-count mismatches (packets lost or duplicated). Distinct from
  // packet_mismatch_count, which only counts words that were compared and
  // differed — a lost word is never compared at all.
  int unsigned packet_count_mismatches;
  int unsigned returner_addr_errors;

  function new(string name = "tidelink_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    fifo_write_count      = 0;
    fifo_read_count       = 0;
    returner_txn_count    = 0;
    apb_txn_count         = 0;
    packet_match_count    = 0;
    packet_mismatch_count = 0;
    packet_count_mismatches = 0;
    returner_addr_errors  = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    fifo_ahb_export = new("fifo_ahb_export", this);
    ret_ahb_export  = new("ret_ahb_export", this);
    apb_export      = new("apb_export", this);

    void'(uvm_config_db#(bit [31:0])::get(this, "", "expected_pair_base", expected_pair_base));
  endfunction

  // ---------------------------------------------------------------
  // FIFO AHB transactions (from VIP master monitor)
  // Tracks packet writes and reads for data integrity checking
  // ---------------------------------------------------------------
  virtual function void write_fifo_ahb(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;

    // Filter out IDLE transactions (from gapped sequences) — check both
    // bus-level trans_type and sequence-level xact_type for robustness
    if (tr.trans_type == svt_ahb_transaction::IDLE)
      return;

    if (!$cast(mtr, tr))
      `uvm_fatal("SB_CAST", "Failed to cast svt_ahb_transaction to svt_ahb_master_transaction")

    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      fifo_write_count++;
      if (mtr.data.size() > 0) begin
        write_packet_data.push_back(mtr.data[0]);
        `uvm_info("SB_FIFO", $sformatf("FIFO WRITE addr=0x%04h data=0x%08h (queued %0d words)",
          mtr.addr, mtr.data[0], write_packet_data.size()), UVM_HIGH)
      end
    end else if (mtr.xact_type == svt_ahb_transaction::READ) begin
      fifo_read_count++;
      if (mtr.data.size() > 0) begin
        read_packet_data.push_back(mtr.data[0]);
        `uvm_info("SB_FIFO", $sformatf("FIFO READ addr=0x%04h data=0x%08h (queued %0d words)",
          mtr.addr, mtr.data[0], read_packet_data.size()), UVM_HIGH)
      end
    end
    // Any other xact_type (e.g. IDLE that slipped past the filter) is ignored
  endfunction

  // ---------------------------------------------------------------
  // Returner AHB transactions (from VIP master monitor on returner side)
  // Verifies that returner writes target correct pair addresses
  // ---------------------------------------------------------------
  virtual function void write_ret_ahb(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    bit [31:0] exp_released_addr;
    bit [31:0] exp_doorbell_resp_addr;
    bit [31:0] exp_doorbell_addr;

    if (tr.trans_type == svt_ahb_transaction::IDLE)
      return;

    if (!$cast(mtr, tr))
      return;

    returner_txn_count++;

    exp_released_addr      = expected_pair_base + 32'h0000_0020;
    exp_doorbell_resp_addr = expected_pair_base + 32'h0000_0024;
    exp_doorbell_addr      = expected_pair_base + 32'h0000_0014;

    // Check that the returner writes to one of the expected addresses
    if (mtr.addr !== exp_released_addr &&
        mtr.addr !== exp_doorbell_resp_addr &&
        mtr.addr !== exp_doorbell_addr) begin
      `uvm_error("SB_RET", $sformatf(
        "Returner wrote to unexpected addr=0x%08h (expected 0x%08h, 0x%08h, or 0x%08h)",
        mtr.addr, exp_released_addr, exp_doorbell_resp_addr, exp_doorbell_addr))
      returner_addr_errors++;
    end else begin
      `uvm_info("SB_RET", $sformatf("Returner WRITE addr=0x%08h data=0x%08h",
        mtr.addr, mtr.data.size() > 0 ? mtr.data[0] : 32'h0), UVM_MEDIUM)
    end
  endfunction

  // ---------------------------------------------------------------
  // APB transactions (from APB monitor)
  // ---------------------------------------------------------------
  virtual function void write_apb(apb_master_transaction tr);
    apb_txn_count++;
    `uvm_info("SB_APB", $sformatf("APB %s addr=0x%03h",
      tr.write ? "WRITE" : "READ", tr.addr), UVM_HIGH)
  endfunction

  // ---------------------------------------------------------------
  // Compare packet data (call from test when a full packet cycle completes)
  // ---------------------------------------------------------------
  function void compare_packet_data();
    int unsigned min_size;

    if (write_packet_data.size() == 0 && read_packet_data.size() == 0)
      return;

    // A word-count mismatch means words were LOST (or duplicated) between the
    // write side and the read side. This must FAIL the test: a scoreboard that
    // does not fail on packet loss is not a scoreboard.
    //
    // It was a `uvm_warning` until 2026-08-26, and the report_phase summary
    // below could NOT cover for it, for two independent reasons:
    //   1. min_size = min(write.size(), read.size()). With an empty read queue
    //      that is 0, the per-word loop runs ZERO times, and the per-word
    //      `uvm_error` is the only error this function used to raise. TOTAL
    //      PACKET LOSS therefore produced a clean log.
    //   2. This function delete()s both queues a few lines below, so by the
    //      time report_phase runs, the evidence has been wiped.
    // This line is the ONLY place a drop is detectable, and it was soft.
    // Ported from uvm/tidelink_system/env/tidelink_system_scoreboard.sv, which
    // was fixed for this exact defect on 2026-07-18.
    // Control: tests/tidelink_scoreboard_loss_selftest.sv
    if (write_packet_data.size() != read_packet_data.size()) begin
      packet_count_mismatches++;
      `uvm_error("SB_PKT", $sformatf(
        "Packet word-count mismatch: %0d words written, %0d words read (words lost or duplicated)",
        write_packet_data.size(), read_packet_data.size()))
    end

    min_size = (write_packet_data.size() < read_packet_data.size()) ?
               write_packet_data.size() : read_packet_data.size();

    for (int i = 0; i < min_size; i++) begin
      if (write_packet_data[i] !== read_packet_data[i]) begin
        `uvm_error("SB_PKT", $sformatf(
          "Packet data mismatch at word %0d: wrote=0x%08h, read=0x%08h",
          i, write_packet_data[i], read_packet_data[i]))
        packet_mismatch_count++;
      end else begin
        packet_match_count++;
      end
    end

    // Clear queues for next packet
    write_packet_data.delete();
    read_packet_data.delete();
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    // Final comparison if any data remains
    compare_packet_data();

    `uvm_info("SB_REPORT", $sformatf("\n---------- TideLink Scoreboard Summary ----------\n  FIFO writes:          %0d\n  FIFO reads:           %0d\n  Packet word matches:  %0d\n  Packet word mismatches: %0d\n  Packet count mismatches (loss/dup): %0d\n  Returner transactions: %0d\n  Returner addr errors:  %0d\n  APB transactions:      %0d\n-------------------------------------------------",
      fifo_write_count, fifo_read_count,
      packet_match_count, packet_mismatch_count,
      packet_count_mismatches,
      returner_txn_count, returner_addr_errors,
      apb_txn_count), UVM_LOW)

    if (packet_mismatch_count > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d packet data mismatches detected", packet_mismatch_count))
    // Backstop on a COUNTER, not on the queues: compare_packet_data() delete()s
    // the queues, so any report_phase check that inspects .size() is dead code.
    if (packet_count_mismatches > 0)
      `uvm_error("SB_REPORT", $sformatf(
        "%0d packet word-count mismatches detected (words lost or duplicated)",
        packet_count_mismatches))
    if (returner_addr_errors > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d returner address errors detected", returner_addr_errors))
  endfunction

endclass

`endif // GUARD_TIDELINK_SCOREBOARD_SV
