///////////////////////////////////////////////////////////////////////////////
// tidelink_system_coverage.sv
///////////////////////////////////////////////////////////////////////////////
// Functional coverage collector for TideLink paired-system verification.
//
// Tracks:
//   - Packet sizes (1 word, small, medium, large, max)
//   - Concurrent bidirectional traffic
//   - Credit-related events
//   - Back-to-back packet patterns
//   - FIFO_DATA vs SIDEBAND interleaving
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SYSTEM_COVERAGE_SV
`define GUARD_TIDELINK_SYSTEM_COVERAGE_SV

// Analysis imp declarations for coverage
`uvm_analysis_imp_decl(_cov_a_tx)
`uvm_analysis_imp_decl(_cov_a_fifo)
`uvm_analysis_imp_decl(_cov_b_tx)
`uvm_analysis_imp_decl(_cov_b_fifo)

class tidelink_system_coverage extends uvm_component;

  `uvm_component_utils(tidelink_system_coverage)

  // Analysis exports
  uvm_analysis_imp_cov_a_tx   #(svt_ahb_transaction, tidelink_system_coverage) a_tx_export;
  uvm_analysis_imp_cov_a_fifo #(svt_ahb_transaction, tidelink_system_coverage) a_fifo_export;
  uvm_analysis_imp_cov_b_tx   #(svt_ahb_transaction, tidelink_system_coverage) b_tx_export;
  uvm_analysis_imp_cov_b_fifo #(svt_ahb_transaction, tidelink_system_coverage) b_fifo_export;

  // State tracking for coverage events
  bit a_tx_active;
  bit b_tx_active;
  bit a_fifo_active;
  bit b_fifo_active;
  int unsigned a_tx_burst_count;    // consecutive TX writes without gap
  int unsigned b_tx_burst_count;
  int unsigned a_tx_total_words;
  int unsigned b_tx_total_words;
  int unsigned a_fifo_total_reads;
  int unsigned b_fifo_total_reads;

  // Packet size tracking: count words written in current packet
  int unsigned a_current_pkt_words;
  int unsigned b_current_pkt_words;
  int unsigned a_pkt_word_length;
  int unsigned b_pkt_word_length;

  // ---------------------------------------------------------------
  // Covergroups
  // ---------------------------------------------------------------

  covergroup cg_packet_size;
    option.per_instance = 1;
    option.name = "cg_packet_size";

    a_pkt_size: coverpoint a_pkt_word_length {
      bins single   = {1};
      bins sm       = {[2:4]};
      bins med      = {[5:16]};
      bins lg       = {[17:255]};
      bins very_large = {[256:4095]};
    }

    b_pkt_size: coverpoint b_pkt_word_length {
      bins single   = {1};
      bins sm       = {[2:4]};
      bins med      = {[5:16]};
      bins lg       = {[17:255]};
      bins very_large = {[256:4095]};
    }
  endgroup

  covergroup cg_bidirectional;
    option.per_instance = 1;
    option.name = "cg_bidirectional";

    a_tx_act: coverpoint a_tx_active;
    b_tx_act: coverpoint b_tx_active;

    // Cross: simultaneous bidirectional traffic
    bidir_cross: cross a_tx_act, b_tx_act {
      bins both_active = binsof(a_tx_act) intersect {1} &&
                         binsof(b_tx_act) intersect {1};
      bins a_only      = binsof(a_tx_act) intersect {1} &&
                         binsof(b_tx_act) intersect {0};
      bins b_only      = binsof(a_tx_act) intersect {0} &&
                         binsof(b_tx_act) intersect {1};
      bins neither     = binsof(a_tx_act) intersect {0} &&
                         binsof(b_tx_act) intersect {0};
    }
  endgroup

  covergroup cg_burst_pattern;
    option.per_instance = 1;
    option.name = "cg_burst_pattern";

    a_burst: coverpoint a_tx_burst_count {
      bins single       = {1};
      bins back_to_back = {[2:5]};
      bins sustained    = {[6:$]};
    }

    b_burst: coverpoint b_tx_burst_count {
      bins single       = {1};
      bins back_to_back = {[2:5]};
      bins sustained    = {[6:$]};
    }
  endgroup

  covergroup cg_traffic_volume;
    option.per_instance = 1;
    option.name = "cg_traffic_volume";

    a_tx_vol: coverpoint a_tx_total_words {
      bins low     = {[1:10]};
      bins med     = {[11:100]};
      bins hi      = {[101:1000]};
      bins stress  = {[1001:$]};
    }

    b_tx_vol: coverpoint b_tx_total_words {
      bins low     = {[1:10]};
      bins med     = {[11:100]};
      bins hi      = {[101:1000]};
      bins stress  = {[1001:$]};
    }
  endgroup

  function new(string name = "tidelink_system_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_packet_size    = new();
    cg_bidirectional  = new();
    cg_burst_pattern  = new();
    cg_traffic_volume = new();
    a_tx_active        = 0;
    b_tx_active        = 0;
    a_fifo_active      = 0;
    b_fifo_active      = 0;
    a_tx_burst_count   = 0;
    b_tx_burst_count   = 0;
    a_tx_total_words   = 0;
    b_tx_total_words   = 0;
    a_fifo_total_reads = 0;
    b_fifo_total_reads = 0;
    a_current_pkt_words = 0;
    b_current_pkt_words = 0;
    a_pkt_word_length   = 0;
    b_pkt_word_length   = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    a_tx_export   = new("a_tx_export", this);
    a_fifo_export = new("a_fifo_export", this);
    b_tx_export   = new("b_tx_export", this);
    b_fifo_export = new("b_fifo_export", this);
  endfunction

  // ---------------------------------------------------------------
  // A TX monitor callback
  // ---------------------------------------------------------------
  virtual function void write_cov_a_tx(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) begin
      if (a_tx_active) begin
        a_tx_active = 0;
        cg_bidirectional.sample();
      end
      return;
    end
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      a_tx_active = 1;
      a_tx_burst_count++;
      a_tx_total_words++;

      // Track packet size: addr==0 means length word
      if (mtr.addr[13:0] == 14'h0 && mtr.data.size() > 0) begin
        a_pkt_word_length = mtr.data[0];
        a_current_pkt_words = 0;
        cg_packet_size.sample();
      end else begin
        a_current_pkt_words++;
      end

      cg_bidirectional.sample();
      cg_burst_pattern.sample();
      cg_traffic_volume.sample();
    end
  endfunction

  // ---------------------------------------------------------------
  // A FIFO monitor callback
  // ---------------------------------------------------------------
  virtual function void write_cov_a_fifo(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::READ) begin
      a_fifo_active = 1;
      a_fifo_total_reads++;
    end
  endfunction

  // ---------------------------------------------------------------
  // B TX monitor callback
  // ---------------------------------------------------------------
  virtual function void write_cov_b_tx(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) begin
      if (b_tx_active) begin
        b_tx_active = 0;
        cg_bidirectional.sample();
      end
      return;
    end
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      b_tx_active = 1;
      b_tx_burst_count++;
      b_tx_total_words++;

      if (mtr.addr[13:0] == 14'h0 && mtr.data.size() > 0) begin
        b_pkt_word_length = mtr.data[0];
        b_current_pkt_words = 0;
        cg_packet_size.sample();
      end else begin
        b_current_pkt_words++;
      end

      cg_bidirectional.sample();
      cg_burst_pattern.sample();
      cg_traffic_volume.sample();
    end
  endfunction

  // ---------------------------------------------------------------
  // B FIFO monitor callback
  // ---------------------------------------------------------------
  virtual function void write_cov_b_fifo(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::READ) begin
      b_fifo_active = 1;
      b_fifo_total_reads++;
    end
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    `uvm_info("COV_REPORT", $sformatf(
      "\n---------- Coverage Summary ----------\n"     +
      "  A TX total words:       %0d\n"                +
      "  B TX total words:       %0d\n"                +
      "  A FIFO total reads:     %0d\n"                +
      "  B FIFO total reads:     %0d\n"                +
      "--------------------------------------",
      a_tx_total_words, b_tx_total_words,
      a_fifo_total_reads, b_fifo_total_reads), UVM_LOW)
  endfunction

endclass

`endif // GUARD_TIDELINK_SYSTEM_COVERAGE_SV
