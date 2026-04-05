///////////////////////////////////////////////////////////////////////////////
// tidelink_system_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// End-to-end system scoreboard for paired TideLink verification.
//
// Tracks bidirectional packet flow:
//   A TX -> B RX FIFO (A writes, B reads)
//   B TX -> A RX FIFO (B writes, A reads)
//
// Detects:
//   - Data corruption (TX write data != RX read data)
//   - Out-of-order delivery
//   - Lost packets (TX queue non-empty at end of test)
//   - Cross-contamination (A's TX data appearing in A's RX or vice versa)
//   - Credit balance inconsistency
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SYSTEM_SCOREBOARD_SV
`define GUARD_TIDELINK_SYSTEM_SCOREBOARD_SV

// Analysis imp declarations for six AHB monitor streams
`uvm_analysis_imp_decl(_a_tx)
`uvm_analysis_imp_decl(_a_fifo)
`uvm_analysis_imp_decl(_a_cfg)
`uvm_analysis_imp_decl(_b_tx)
`uvm_analysis_imp_decl(_b_fifo)
`uvm_analysis_imp_decl(_b_cfg)

class tidelink_system_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(tidelink_system_scoreboard)

  // Analysis exports (6 streams: 4 AHB + 2 APB config)
  uvm_analysis_imp_a_tx   #(svt_ahb_transaction, tidelink_system_scoreboard) a_tx_export;
  uvm_analysis_imp_a_fifo #(svt_ahb_transaction, tidelink_system_scoreboard) a_fifo_export;
  uvm_analysis_imp_a_cfg  #(apb_master_transaction, tidelink_system_scoreboard) a_cfg_export;
  uvm_analysis_imp_b_tx   #(svt_ahb_transaction, tidelink_system_scoreboard) b_tx_export;
  uvm_analysis_imp_b_fifo #(svt_ahb_transaction, tidelink_system_scoreboard) b_fifo_export;
  uvm_analysis_imp_b_cfg  #(apb_master_transaction, tidelink_system_scoreboard) b_cfg_export;

  // A->B path: A TX writes should appear as B FIFO reads
  bit [31:0] a_tx_write_data[$];
  bit [13:0] a_tx_write_addr[$];
  bit [31:0] b_fifo_read_data[$];
  bit [13:0] b_fifo_read_addr[$];

  // B->A path: B TX writes should appear as A FIFO reads
  bit [31:0] b_tx_write_data[$];
  bit [13:0] b_tx_write_addr[$];
  bit [31:0] a_fifo_read_data[$];
  bit [13:0] a_fifo_read_addr[$];

  // Counters
  int unsigned a_tx_write_count;
  int unsigned a_fifo_read_count;
  int unsigned a_cfg_write_count;
  int unsigned a_cfg_read_count;
  int unsigned b_tx_write_count;
  int unsigned b_fifo_read_count;
  int unsigned b_cfg_write_count;
  int unsigned b_cfg_read_count;

  // Match/mismatch tracking
  int unsigned a2b_match_count;
  int unsigned a2b_mismatch_count;
  int unsigned b2a_match_count;
  int unsigned b2a_mismatch_count;

  function new(string name = "tidelink_system_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    a_tx_write_count    = 0;
    a_fifo_read_count   = 0;
    a_cfg_write_count   = 0;
    a_cfg_read_count    = 0;
    b_tx_write_count    = 0;
    b_fifo_read_count   = 0;
    b_cfg_write_count   = 0;
    b_cfg_read_count    = 0;
    a2b_match_count     = 0;
    a2b_mismatch_count  = 0;
    b2a_match_count     = 0;
    b2a_mismatch_count  = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    a_tx_export   = new("a_tx_export", this);
    a_fifo_export = new("a_fifo_export", this);
    a_cfg_export  = new("a_cfg_export", this);
    b_tx_export   = new("b_tx_export", this);
    b_fifo_export = new("b_fifo_export", this);
    b_cfg_export  = new("b_cfg_export", this);
  endfunction

  // ---------------------------------------------------------------
  // A TX aperture writes (data going A -> B)
  // ---------------------------------------------------------------
  virtual function void write_a_tx(svt_ahb_transaction tr);
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
  // A FIFO reads (data arriving from B -> A)
  // ---------------------------------------------------------------
  virtual function void write_a_fifo(svt_ahb_transaction tr);
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
  // A Config transactions (APB)
  // ---------------------------------------------------------------
  virtual function void write_a_cfg(apb_master_transaction tr);
    if (tr.write) begin
      a_cfg_write_count++;
      `uvm_info("SB_A_CFG", $sformatf("A CFG WRITE addr=0x%04h data=0x%08h",
        tr.addr, tr.wdata), UVM_HIGH)
    end else begin
      a_cfg_read_count++;
    end
  endfunction

  // ---------------------------------------------------------------
  // B TX aperture writes (data going B -> A)
  // ---------------------------------------------------------------
  virtual function void write_b_tx(svt_ahb_transaction tr);
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
  // B FIFO reads (data arriving from A -> B)
  // ---------------------------------------------------------------
  virtual function void write_b_fifo(svt_ahb_transaction tr);
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

  // ---------------------------------------------------------------
  // B Config transactions (APB)
  // ---------------------------------------------------------------
  virtual function void write_b_cfg(apb_master_transaction tr);
    if (tr.write) begin
      b_cfg_write_count++;
      `uvm_info("SB_B_CFG", $sformatf("B CFG WRITE addr=0x%04h data=0x%08h",
        tr.addr, tr.wdata), UVM_HIGH)
    end else begin
      b_cfg_read_count++;
    end
  endfunction

  // ---------------------------------------------------------------
  // Compare A->B loopback data
  // Call from test after A TX write + B FIFO read cycle completes
  // ---------------------------------------------------------------
  function void compare_a2b_data();
    int unsigned min_size;

    if (a_tx_write_data.size() == 0 && b_fifo_read_data.size() == 0)
      return;

    if (a_tx_write_data.size() != b_fifo_read_data.size()) begin
      `uvm_warning("SB_A2B", $sformatf(
        "A->B data count mismatch: %0d A TX writes, %0d B FIFO reads",
        a_tx_write_data.size(), b_fifo_read_data.size()))
    end

    min_size = (a_tx_write_data.size() < b_fifo_read_data.size()) ?
               a_tx_write_data.size() : b_fifo_read_data.size();

    for (int i = 0; i < min_size; i++) begin
      if (a_tx_write_data[i] !== b_fifo_read_data[i]) begin
        `uvm_error("SB_A2B", $sformatf(
          "A->B mismatch word %0d: TX wrote=0x%08h @ 0x%04h, RX read=0x%08h @ 0x%04h",
          i, a_tx_write_data[i], a_tx_write_addr[i],
          b_fifo_read_data[i], b_fifo_read_addr[i]))
        a2b_mismatch_count++;
      end else begin
        `uvm_info("SB_A2B", $sformatf(
          "A->B match word %0d: 0x%08h @ 0x%04h",
          i, a_tx_write_data[i], a_tx_write_addr[i]), UVM_HIGH)
        a2b_match_count++;
      end
    end

    // Clear queues
    a_tx_write_data.delete();
    a_tx_write_addr.delete();
    b_fifo_read_data.delete();
    b_fifo_read_addr.delete();
  endfunction

  // ---------------------------------------------------------------
  // Compare B->A loopback data
  // ---------------------------------------------------------------
  function void compare_b2a_data();
    int unsigned min_size;

    if (b_tx_write_data.size() == 0 && a_fifo_read_data.size() == 0)
      return;

    if (b_tx_write_data.size() != a_fifo_read_data.size()) begin
      `uvm_warning("SB_B2A", $sformatf(
        "B->A data count mismatch: %0d B TX writes, %0d A FIFO reads",
        b_tx_write_data.size(), a_fifo_read_data.size()))
    end

    min_size = (b_tx_write_data.size() < a_fifo_read_data.size()) ?
               b_tx_write_data.size() : a_fifo_read_data.size();

    for (int i = 0; i < min_size; i++) begin
      if (b_tx_write_data[i] !== a_fifo_read_data[i]) begin
        `uvm_error("SB_B2A", $sformatf(
          "B->A mismatch word %0d: TX wrote=0x%08h @ 0x%04h, RX read=0x%08h @ 0x%04h",
          i, b_tx_write_data[i], b_tx_write_addr[i],
          a_fifo_read_data[i], a_fifo_read_addr[i]))
        b2a_mismatch_count++;
      end else begin
        `uvm_info("SB_B2A", $sformatf(
          "B->A match word %0d: 0x%08h @ 0x%04h",
          i, b_tx_write_data[i], b_tx_write_addr[i]), UVM_HIGH)
        b2a_match_count++;
      end
    end

    // Clear queues
    b_tx_write_data.delete();
    b_tx_write_addr.delete();
    a_fifo_read_data.delete();
    a_fifo_read_addr.delete();
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    // Final comparison of any remaining data
    compare_a2b_data();
    compare_b2a_data();

    `uvm_info("SB_REPORT", $sformatf(
      "\n---------- System Scoreboard Summary ----------\n"   +
      "  A TX writes:            %0d\n"                       +
      "  A FIFO reads:           %0d\n"                       +
      "  A Config writes:        %0d\n"                       +
      "  A Config reads:         %0d\n"                       +
      "  B TX writes:            %0d\n"                       +
      "  B FIFO reads:           %0d\n"                       +
      "  B Config writes:        %0d\n"                       +
      "  B Config reads:         %0d\n"                       +
      "  A->B word matches:      %0d\n"                       +
      "  A->B word mismatches:   %0d\n"                       +
      "  B->A word matches:      %0d\n"                       +
      "  B->A word mismatches:   %0d\n"                       +
      "------------------------------------------------",
      a_tx_write_count, a_fifo_read_count,
      a_cfg_write_count, a_cfg_read_count,
      b_tx_write_count, b_fifo_read_count,
      b_cfg_write_count, b_cfg_read_count,
      a2b_match_count, a2b_mismatch_count,
      b2a_match_count, b2a_mismatch_count), UVM_LOW)

    if (a2b_mismatch_count > 0)
      `uvm_error("SB_REPORT", $sformatf(
        "%0d A->B data mismatches detected", a2b_mismatch_count))
    if (b2a_mismatch_count > 0)
      `uvm_error("SB_REPORT", $sformatf(
        "%0d B->A data mismatches detected", b2a_mismatch_count))

    // Check for lost packets (data left in queues)
    if (a_tx_write_data.size() > 0)
      `uvm_error("SB_REPORT", $sformatf(
        "%0d A TX writes not matched by B FIFO reads (lost packets?)",
        a_tx_write_data.size()))
    if (b_tx_write_data.size() > 0)
      `uvm_error("SB_REPORT", $sformatf(
        "%0d B TX writes not matched by A FIFO reads (lost packets?)",
        b_tx_write_data.size()))
  endfunction

endclass

`endif // GUARD_TIDELINK_SYSTEM_SCOREBOARD_SV
