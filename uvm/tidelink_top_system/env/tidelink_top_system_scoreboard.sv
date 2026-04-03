///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// End-to-end system scoreboard for full tidelink_top paired verification.
//
// Tracks:
//   - TideLink FIFO path: A TX -> B RX FIFO, B TX -> A RX FIFO
//   - AHB passthrough path: A SUB -> Wlink -> B MNG, B SUB -> Wlink -> A MNG
//   - Data corruption, out-of-order, lost packets
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_SCOREBOARD_SV
`define GUARD_TIDELINK_TOP_SYSTEM_SCOREBOARD_SV

// Analysis imp declarations for 8 AHB monitor streams
`uvm_analysis_imp_decl(_top_a_tx)
`uvm_analysis_imp_decl(_top_a_fifo)
`uvm_analysis_imp_decl(_top_a_cfg)
`uvm_analysis_imp_decl(_top_a_sub)
`uvm_analysis_imp_decl(_top_b_tx)
`uvm_analysis_imp_decl(_top_b_fifo)
`uvm_analysis_imp_decl(_top_b_cfg)
`uvm_analysis_imp_decl(_top_b_sub)

class tidelink_top_system_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(tidelink_top_system_scoreboard)

  // Analysis exports
  uvm_analysis_imp_top_a_tx   #(svt_ahb_transaction, tidelink_top_system_scoreboard) a_tx_export;
  uvm_analysis_imp_top_a_fifo #(svt_ahb_transaction, tidelink_top_system_scoreboard) a_fifo_export;
  uvm_analysis_imp_top_a_cfg  #(svt_ahb_transaction, tidelink_top_system_scoreboard) a_cfg_export;
  uvm_analysis_imp_top_a_sub  #(svt_ahb_transaction, tidelink_top_system_scoreboard) a_sub_export;
  uvm_analysis_imp_top_b_tx   #(svt_ahb_transaction, tidelink_top_system_scoreboard) b_tx_export;
  uvm_analysis_imp_top_b_fifo #(svt_ahb_transaction, tidelink_top_system_scoreboard) b_fifo_export;
  uvm_analysis_imp_top_b_cfg  #(svt_ahb_transaction, tidelink_top_system_scoreboard) b_cfg_export;
  uvm_analysis_imp_top_b_sub  #(svt_ahb_transaction, tidelink_top_system_scoreboard) b_sub_export;

  // TideLink FIFO path: A TX -> B FIFO
  bit [31:0] a_tx_write_data[$];
  bit [13:0] a_tx_write_addr[$];
  bit [31:0] b_fifo_read_data[$];
  bit [13:0] b_fifo_read_addr[$];

  // TideLink FIFO path: B TX -> A FIFO
  bit [31:0] b_tx_write_data[$];
  bit [13:0] b_tx_write_addr[$];
  bit [31:0] a_fifo_read_data[$];
  bit [13:0] a_fifo_read_addr[$];

  // AHB passthrough path: A SUB writes -> B MNG receives
  bit [31:0] a_sub_write_data[$];
  bit [31:0] a_sub_write_addr[$];

  // AHB passthrough path: B SUB writes -> A MNG receives
  bit [31:0] b_sub_write_data[$];
  bit [31:0] b_sub_write_addr[$];

  // Counters
  int unsigned a_tx_write_count, a_fifo_read_count;
  int unsigned a_cfg_write_count, a_cfg_read_count;
  int unsigned a_sub_write_count, a_sub_read_count;
  int unsigned b_tx_write_count, b_fifo_read_count;
  int unsigned b_cfg_write_count, b_cfg_read_count;
  int unsigned b_sub_write_count, b_sub_read_count;
  int unsigned a2b_match_count, a2b_mismatch_count;
  int unsigned b2a_match_count, b2a_mismatch_count;

  function new(string name = "tidelink_top_system_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    a_tx_export   = new("a_tx_export", this);
    a_fifo_export = new("a_fifo_export", this);
    a_cfg_export  = new("a_cfg_export", this);
    a_sub_export  = new("a_sub_export", this);
    b_tx_export   = new("b_tx_export", this);
    b_fifo_export = new("b_fifo_export", this);
    b_cfg_export  = new("b_cfg_export", this);
    b_sub_export  = new("b_sub_export", this);
  endfunction

  // ---------------------------------------------------------------
  // A TX aperture writes (data going A -> B via FC)
  // ---------------------------------------------------------------
  virtual function void write_top_a_tx(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      a_tx_write_count++;
      if (mtr.data.size() > 0) begin
        a_tx_write_data.push_back(mtr.data[0]);
        a_tx_write_addr.push_back(mtr.addr[13:0]);
        `uvm_info("SB_A_TX", $sformatf("A TX WRITE addr=0x%04h data=0x%08h (q=%0d)",
          mtr.addr, mtr.data[0], a_tx_write_data.size()), UVM_HIGH)
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // A FIFO reads (data arriving from B -> A via FC)
  // ---------------------------------------------------------------
  virtual function void write_top_a_fifo(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::READ) begin
      a_fifo_read_count++;
      if (mtr.data.size() > 0) begin
        a_fifo_read_data.push_back(mtr.data[0]);
        a_fifo_read_addr.push_back(mtr.addr[13:0]);
        `uvm_info("SB_A_FIFO", $sformatf("A FIFO READ addr=0x%04h data=0x%08h (q=%0d)",
          mtr.addr, mtr.data[0], a_fifo_read_data.size()), UVM_HIGH)
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // A Config transactions
  // ---------------------------------------------------------------
  virtual function void write_top_a_cfg(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) a_cfg_write_count++;
    else if (mtr.xact_type == svt_ahb_transaction::READ) a_cfg_read_count++;
  endfunction

  // ---------------------------------------------------------------
  // A SUB (regular AHB passthrough) writes
  // ---------------------------------------------------------------
  virtual function void write_top_a_sub(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      a_sub_write_count++;
      if (mtr.data.size() > 0) begin
        a_sub_write_data.push_back(mtr.data[0]);
        a_sub_write_addr.push_back(mtr.addr);
        `uvm_info("SB_A_SUB", $sformatf("A SUB WRITE addr=0x%08h data=0x%08h",
          mtr.addr, mtr.data[0]), UVM_HIGH)
      end
    end else if (mtr.xact_type == svt_ahb_transaction::READ) begin
      a_sub_read_count++;
    end
  endfunction

  // ---------------------------------------------------------------
  // B TX aperture writes (data going B -> A via FC)
  // ---------------------------------------------------------------
  virtual function void write_top_b_tx(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      b_tx_write_count++;
      if (mtr.data.size() > 0) begin
        b_tx_write_data.push_back(mtr.data[0]);
        b_tx_write_addr.push_back(mtr.addr[13:0]);
        `uvm_info("SB_B_TX", $sformatf("B TX WRITE addr=0x%04h data=0x%08h (q=%0d)",
          mtr.addr, mtr.data[0], b_tx_write_data.size()), UVM_HIGH)
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // B FIFO reads (data arriving from A -> B via FC)
  // ---------------------------------------------------------------
  virtual function void write_top_b_fifo(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::READ) begin
      b_fifo_read_count++;
      if (mtr.data.size() > 0) begin
        b_fifo_read_data.push_back(mtr.data[0]);
        b_fifo_read_addr.push_back(mtr.addr[13:0]);
        `uvm_info("SB_B_FIFO", $sformatf("B FIFO READ addr=0x%04h data=0x%08h (q=%0d)",
          mtr.addr, mtr.data[0], b_fifo_read_data.size()), UVM_HIGH)
      end
    end
  endfunction

  virtual function void write_top_b_cfg(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) b_cfg_write_count++;
    else if (mtr.xact_type == svt_ahb_transaction::READ) b_cfg_read_count++;
  endfunction

  virtual function void write_top_b_sub(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;
    if (tr.trans_type == svt_ahb_transaction::IDLE) return;
    if (!$cast(mtr, tr)) return;
    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      b_sub_write_count++;
      if (mtr.data.size() > 0) begin
        b_sub_write_data.push_back(mtr.data[0]);
        b_sub_write_addr.push_back(mtr.addr);
      end
    end else if (mtr.xact_type == svt_ahb_transaction::READ) begin
      b_sub_read_count++;
    end
  endfunction

  // ---------------------------------------------------------------
  // Compare TideLink A->B data
  // ---------------------------------------------------------------
  function void compare_a2b_data();
    int unsigned min_size;
    if (a_tx_write_data.size() == 0 && b_fifo_read_data.size() == 0) return;
    if (a_tx_write_data.size() != b_fifo_read_data.size())
      `uvm_warning("SB_A2B", $sformatf("A->B count mismatch: %0d TX, %0d FIFO",
        a_tx_write_data.size(), b_fifo_read_data.size()))
    min_size = (a_tx_write_data.size() < b_fifo_read_data.size()) ?
               a_tx_write_data.size() : b_fifo_read_data.size();
    for (int i = 0; i < min_size; i++) begin
      if (a_tx_write_data[i] !== b_fifo_read_data[i]) begin
        `uvm_error("SB_A2B", $sformatf("A->B mismatch word %0d: TX=0x%08h, RX=0x%08h",
          i, a_tx_write_data[i], b_fifo_read_data[i]))
        a2b_mismatch_count++;
      end else begin
        a2b_match_count++;
      end
    end
    a_tx_write_data.delete(); a_tx_write_addr.delete();
    b_fifo_read_data.delete(); b_fifo_read_addr.delete();
  endfunction

  // ---------------------------------------------------------------
  // Compare TideLink B->A data
  // ---------------------------------------------------------------
  function void compare_b2a_data();
    int unsigned min_size;
    if (b_tx_write_data.size() == 0 && a_fifo_read_data.size() == 0) return;
    if (b_tx_write_data.size() != a_fifo_read_data.size())
      `uvm_warning("SB_B2A", $sformatf("B->A count mismatch: %0d TX, %0d FIFO",
        b_tx_write_data.size(), a_fifo_read_data.size()))
    min_size = (b_tx_write_data.size() < a_fifo_read_data.size()) ?
               b_tx_write_data.size() : a_fifo_read_data.size();
    for (int i = 0; i < min_size; i++) begin
      if (b_tx_write_data[i] !== a_fifo_read_data[i]) begin
        `uvm_error("SB_B2A", $sformatf("B->A mismatch word %0d: TX=0x%08h, RX=0x%08h",
          i, b_tx_write_data[i], a_fifo_read_data[i]))
        b2a_mismatch_count++;
      end else begin
        b2a_match_count++;
      end
    end
    b_tx_write_data.delete(); b_tx_write_addr.delete();
    a_fifo_read_data.delete(); a_fifo_read_addr.delete();
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    compare_a2b_data();
    compare_b2a_data();
    `uvm_info("SB_REPORT", $sformatf(
      "\n---------- Top System Scoreboard Summary ----------\n" +
      "  A TX writes:            %0d\n"   +
      "  A FIFO reads:           %0d\n"   +
      "  A CFG writes/reads:     %0d/%0d\n" +
      "  A SUB writes/reads:     %0d/%0d\n" +
      "  B TX writes:            %0d\n"   +
      "  B FIFO reads:           %0d\n"   +
      "  B CFG writes/reads:     %0d/%0d\n" +
      "  B SUB writes/reads:     %0d/%0d\n" +
      "  A->B matches/mismatches: %0d/%0d\n" +
      "  B->A matches/mismatches: %0d/%0d\n" +
      "----------------------------------------------------",
      a_tx_write_count, a_fifo_read_count,
      a_cfg_write_count, a_cfg_read_count,
      a_sub_write_count, a_sub_read_count,
      b_tx_write_count, b_fifo_read_count,
      b_cfg_write_count, b_cfg_read_count,
      b_sub_write_count, b_sub_read_count,
      a2b_match_count, a2b_mismatch_count,
      b2a_match_count, b2a_mismatch_count), UVM_LOW)

    if (a2b_mismatch_count > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d A->B mismatches", a2b_mismatch_count))
    if (b2a_mismatch_count > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d B->A mismatches", b2a_mismatch_count))
    if (a_tx_write_data.size() > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d A TX writes unmatched", a_tx_write_data.size()))
    if (b_tx_write_data.size() > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d B TX writes unmatched", b_tx_write_data.size()))
  endfunction

endclass

`endif // GUARD_TIDELINK_TOP_SYSTEM_SCOREBOARD_SV
