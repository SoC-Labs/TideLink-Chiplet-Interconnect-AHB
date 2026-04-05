///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// End-to-end packet scoreboard for the TideLink integration testbench.
//
// Tracks:
//   1. TX aperture writes: data written to FC adapter TX path
//   2. FIFO reads: data read back from RX FIFO after loopback delivery
//   3. Config writes: sideband packets delivered to config registers
//
// The loopback topology means every TX aperture write should appear as an
// RX FIFO write (FIFO_DATA packets) or config register write (SIDEBAND
// packets). The scoreboard compares TX data against RX read-back data.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_SCOREBOARD_SV
`define GUARD_TIDELINK_INTEGRATION_SCOREBOARD_SV

// Analysis imp declarations for two AHB monitor streams and one APB monitor stream
`uvm_analysis_imp_decl(_tx_ahb)
`uvm_analysis_imp_decl(_fifo_ahb)
`uvm_analysis_imp_decl(_cfg_apb)

class tidelink_integration_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(tidelink_integration_scoreboard)

  // Analysis exports
  uvm_analysis_imp_tx_ahb   #(svt_ahb_transaction, tidelink_integration_scoreboard) tx_ahb_export;
  uvm_analysis_imp_fifo_ahb #(svt_ahb_transaction, tidelink_integration_scoreboard) fifo_ahb_export;
  uvm_analysis_imp_cfg_apb  #(apb_master_transaction, tidelink_integration_scoreboard) cfg_apb_export;

  // TX write data queue (words written to TX aperture)
  bit [31:0] tx_write_data[$];
  bit [13:0] tx_write_addr[$];

  // RX read data queue (words read from FIFO)
  bit [31:0] rx_read_data[$];
  bit [13:0] rx_read_addr[$];

  // Counters
  int unsigned tx_write_count;
  int unsigned fifo_read_count;
  int unsigned fifo_write_count;
  int unsigned cfg_write_count;
  int unsigned cfg_read_count;
  int unsigned packet_match_count;
  int unsigned packet_mismatch_count;

  function new(string name = "tidelink_integration_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    tx_write_count        = 0;
    fifo_read_count       = 0;
    fifo_write_count      = 0;
    cfg_write_count       = 0;
    cfg_read_count        = 0;
    packet_match_count    = 0;
    packet_mismatch_count = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    tx_ahb_export   = new("tx_ahb_export", this);
    fifo_ahb_export = new("fifo_ahb_export", this);
    cfg_apb_export  = new("cfg_apb_export", this);
  endfunction

  // ---------------------------------------------------------------
  // TX aperture AHB transactions (from VIP master monitor)
  // Tracks packet data written into the FC adapter TX path
  // ---------------------------------------------------------------
  virtual function void write_tx_ahb(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;

    if (tr.trans_type == svt_ahb_transaction::IDLE)
      return;

    if (!$cast(mtr, tr))
      `uvm_fatal("SB_CAST", "Failed to cast svt_ahb_transaction to svt_ahb_master_transaction")

    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      tx_write_count++;
      if (mtr.data.size() > 0) begin
        tx_write_data.push_back(mtr.data[0]);
        tx_write_addr.push_back(mtr.addr[13:0]);
        `uvm_info("SB_TX", $sformatf("TX WRITE addr=0x%04h data=0x%08h (queued %0d)",
          mtr.addr, mtr.data[0], tx_write_data.size()), UVM_HIGH)
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // FIFO AHB transactions (from VIP master monitor on FIFO read port)
  // Tracks data read back from the RX FIFO
  // ---------------------------------------------------------------
  virtual function void write_fifo_ahb(svt_ahb_transaction tr);
    svt_ahb_master_transaction mtr;

    if (tr.trans_type == svt_ahb_transaction::IDLE)
      return;

    if (!$cast(mtr, tr))
      `uvm_fatal("SB_CAST", "Failed to cast svt_ahb_transaction to svt_ahb_master_transaction")

    if (mtr.xact_type == svt_ahb_transaction::WRITE) begin
      fifo_write_count++;
    end else if (mtr.xact_type == svt_ahb_transaction::READ) begin
      fifo_read_count++;
      if (mtr.data.size() > 0) begin
        rx_read_data.push_back(mtr.data[0]);
        rx_read_addr.push_back(mtr.addr[13:0]);
        `uvm_info("SB_FIFO", $sformatf("FIFO READ addr=0x%04h data=0x%08h (queued %0d)",
          mtr.addr, mtr.data[0], rx_read_data.size()), UVM_HIGH)
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // Config APB transactions (from APB master agent monitor)
  // Tracks sideband register reads/writes
  // ---------------------------------------------------------------
  virtual function void write_cfg_apb(apb_master_transaction tr);
    if (tr.write) begin
      cfg_write_count++;
      `uvm_info("SB_CFG", $sformatf("CFG WRITE addr=0x%04h data=0x%08h",
        tr.addr, tr.wdata), UVM_MEDIUM)
    end else begin
      cfg_read_count++;
      `uvm_info("SB_CFG", $sformatf("CFG READ addr=0x%04h data=0x%08h",
        tr.addr, tr.rdata), UVM_MEDIUM)
    end
  endfunction

  // ---------------------------------------------------------------
  // Compare loopback packet data
  // Call from test after a full TX write + RX read cycle completes
  // ---------------------------------------------------------------
  function void compare_loopback_data();
    int unsigned min_size;

    if (tx_write_data.size() == 0 && rx_read_data.size() == 0)
      return;

    if (tx_write_data.size() != rx_read_data.size()) begin
      `uvm_warning("SB_PKT", $sformatf(
        "Loopback data count mismatch: %0d TX writes, %0d RX reads",
        tx_write_data.size(), rx_read_data.size()))
    end

    min_size = (tx_write_data.size() < rx_read_data.size()) ?
               tx_write_data.size() : rx_read_data.size();

    for (int i = 0; i < min_size; i++) begin
      if (tx_write_data[i] !== rx_read_data[i]) begin
        `uvm_error("SB_PKT", $sformatf(
          "Loopback mismatch at word %0d: TX wrote=0x%08h @ 0x%04h, RX read=0x%08h @ 0x%04h",
          i, tx_write_data[i], tx_write_addr[i], rx_read_data[i], rx_read_addr[i]))
        packet_mismatch_count++;
      end else begin
        `uvm_info("SB_PKT", $sformatf(
          "Loopback match word %0d: 0x%08h @ addr 0x%04h",
          i, tx_write_data[i], tx_write_addr[i]), UVM_HIGH)
        packet_match_count++;
      end
    end

    // Clear queues for next comparison
    tx_write_data.delete();
    tx_write_addr.delete();
    rx_read_data.delete();
    rx_read_addr.delete();
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    // Final comparison if data remains
    compare_loopback_data();

    `uvm_info("SB_REPORT", $sformatf(
      "\n---------- Integration Scoreboard Summary ----------\n"   +
      "  TX aperture writes:     %0d\n"                            +
      "  FIFO reads:             %0d\n"                            +
      "  FIFO writes (FC RX):    %0d\n"                            +
      "  Config writes:          %0d\n"                            +
      "  Config reads:           %0d\n"                            +
      "  Loopback word matches:  %0d\n"                            +
      "  Loopback word mismatches: %0d\n"                          +
      "----------------------------------------------------",
      tx_write_count, fifo_read_count, fifo_write_count,
      cfg_write_count, cfg_read_count,
      packet_match_count, packet_mismatch_count), UVM_LOW)

    if (packet_mismatch_count > 0)
      `uvm_error("SB_REPORT", $sformatf(
        "%0d loopback data mismatches detected", packet_mismatch_count))
  endfunction

endclass

`endif // GUARD_TIDELINK_INTEGRATION_SCOREBOARD_SV
