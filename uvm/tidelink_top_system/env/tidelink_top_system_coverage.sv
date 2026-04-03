///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_coverage.sv
///////////////////////////////////////////////////////////////////////////////
// Functional coverage for TideLink full tidelink_top paired verification.
// Reuses the same coverage model as the sub-component system test.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_COVERAGE_SV
`define GUARD_TIDELINK_TOP_SYSTEM_COVERAGE_SV

`uvm_analysis_imp_decl(_top_cov_a_tx)
`uvm_analysis_imp_decl(_top_cov_a_fifo)
`uvm_analysis_imp_decl(_top_cov_b_tx)
`uvm_analysis_imp_decl(_top_cov_b_fifo)

class tidelink_top_system_coverage extends uvm_component;

  `uvm_component_utils(tidelink_top_system_coverage)

  uvm_analysis_imp_top_cov_a_tx   #(svt_ahb_transaction, tidelink_top_system_coverage) a_tx_export;
  uvm_analysis_imp_top_cov_a_fifo #(svt_ahb_transaction, tidelink_top_system_coverage) a_fifo_export;
  uvm_analysis_imp_top_cov_b_tx   #(svt_ahb_transaction, tidelink_top_system_coverage) b_tx_export;
  uvm_analysis_imp_top_cov_b_fifo #(svt_ahb_transaction, tidelink_top_system_coverage) b_fifo_export;

  bit a_tx_active, b_tx_active;
  int unsigned a_tx_burst_count, b_tx_burst_count;
  int unsigned a_tx_total_words, b_tx_total_words;
  int unsigned a_fifo_total_reads, b_fifo_total_reads;
  int unsigned a_pkt_word_length, b_pkt_word_length;

  covergroup cg_packet_size;
    option.per_instance = 1;
    a_pkt_size: coverpoint a_pkt_word_length {
      bins pkt_single     = {1};
      bins pkt_small      = {[2:4]};
      bins pkt_medium     = {[5:16]};
      bins pkt_large      = {[17:255]};
      bins pkt_very_large = {[256:4095]};
    }
    b_pkt_size: coverpoint b_pkt_word_length {
      bins pkt_single     = {1};
      bins pkt_small      = {[2:4]};
      bins pkt_medium     = {[5:16]};
      bins pkt_large      = {[17:255]};
      bins pkt_very_large = {[256:4095]};
    }
  endgroup

  covergroup cg_bidirectional;
    option.per_instance = 1;
    a_tx_act: coverpoint a_tx_active;
    b_tx_act: coverpoint b_tx_active;
    bidir_cross: cross a_tx_act, b_tx_act;
  endgroup

  covergroup cg_traffic_volume;
    option.per_instance = 1;
    a_tx_vol: coverpoint a_tx_total_words {
      bins vol_low    = {[1:10]};
      bins vol_medium = {[11:100]};
      bins vol_high   = {[101:1000]};
      bins vol_stress = {[1001:$]};
    }
    b_tx_vol: coverpoint b_tx_total_words {
      bins vol_low    = {[1:10]};
      bins vol_medium = {[11:100]};
      bins vol_high   = {[101:1000]};
      bins vol_stress = {[1001:$]};
    }
  endgroup

  function new(string name = "tidelink_top_system_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_packet_size    = new();
    cg_bidirectional  = new();
    cg_traffic_volume = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    a_tx_export   = new("a_tx_export", this);
    a_fifo_export = new("a_fifo_export", this);
    b_tx_export   = new("b_tx_export", this);
    b_fifo_export = new("b_fifo_export", this);
  endfunction

  virtual function void write_top_cov_a_tx(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) begin
      if (a_tx_active) begin a_tx_active = 0; cg_bidirectional.sample(); end
      return;
    end
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      a_tx_active = 1;
      a_tx_burst_count++;
      a_tx_total_words++;
      if (mtr.addr[13:0] == 14'h0 && mtr.data.size() > 0) begin
        a_pkt_word_length = mtr.data[0];
        cg_packet_size.sample();
      end
      cg_bidirectional.sample();
      cg_traffic_volume.sample();
    end
  endfunction

  virtual function void write_top_cov_a_fifo(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::READ) a_fifo_total_reads++;
  endfunction

  virtual function void write_top_cov_b_tx(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) begin
      if (b_tx_active) begin b_tx_active = 0; cg_bidirectional.sample(); end
      return;
    end
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      b_tx_active = 1;
      b_tx_burst_count++;
      b_tx_total_words++;
      if (mtr.addr[13:0] == 14'h0 && mtr.data.size() > 0) begin
        b_pkt_word_length = mtr.data[0];
        cg_packet_size.sample();
      end
      cg_bidirectional.sample();
      cg_traffic_volume.sample();
    end
  endfunction

  virtual function void write_top_cov_b_fifo(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::READ) b_fifo_total_reads++;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    `uvm_info("COV_REPORT", $sformatf(
      "\n---------- Coverage Summary ----------\n" +
      "  A TX total words:   %0d\n" +
      "  B TX total words:   %0d\n" +
      "  A FIFO total reads: %0d\n" +
      "  B FIFO total reads: %0d\n" +
      "--------------------------------------",
      a_tx_total_words, b_tx_total_words,
      a_fifo_total_reads, b_fifo_total_reads), UVM_LOW)
  endfunction

endclass

`endif // GUARD_TIDELINK_TOP_SYSTEM_COVERAGE_SV
