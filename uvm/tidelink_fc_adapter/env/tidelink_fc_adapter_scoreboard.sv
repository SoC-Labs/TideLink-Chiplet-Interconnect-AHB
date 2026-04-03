///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_scoreboard.sv
///////////////////////////////////////////////////////////////////////////////
// UVM scoreboard for TideLink FC Adapter verification.
//
// Tracks:
//   1. TX path: AHB writes to TX aperture -> expected FC TX FIFO_DATA packets
//   2. Sideband: AHB writes to returner port -> expected FC TX SIDEBAND packets
//   3. RX path: FC RX input -> expected AHB master writes on FIFO/config ports
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_SCOREBOARD_SV
`define GUARD_TIDELINK_FC_ADAPTER_SCOREBOARD_SV

// Analysis imp declarations
`uvm_analysis_imp_decl(_fc_tx)
`uvm_analysis_imp_decl(_rx_fifo)
`uvm_analysis_imp_decl(_rx_cfg)

class tidelink_fc_adapter_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(tidelink_fc_adapter_scoreboard)

  // Analysis exports
  uvm_analysis_imp_fc_tx   #(fc_seq_item, tidelink_fc_adapter_scoreboard) fc_tx_export;
  uvm_analysis_imp_rx_fifo #(ahb_rx_observed_item, tidelink_fc_adapter_scoreboard) rx_fifo_export;
  uvm_analysis_imp_rx_cfg  #(ahb_rx_observed_item, tidelink_fc_adapter_scoreboard) rx_cfg_export;

  // Expected FC TX queue (predicted from AHB TX aperture + returner writes)
  fc_seq_item expected_fc_tx_q[$];

  // Expected RX AHB write queue (predicted from FC RX input)
  ahb_rx_observed_item expected_rx_fifo_q[$];
  ahb_rx_observed_item expected_rx_cfg_q[$];

  // Counters
  int unsigned fc_tx_match_count;
  int unsigned fc_tx_mismatch_count;
  int unsigned fc_tx_unexpected_count;
  int unsigned rx_fifo_match_count;
  int unsigned rx_fifo_mismatch_count;
  int unsigned rx_fifo_unexpected_count;
  int unsigned rx_cfg_match_count;
  int unsigned rx_cfg_mismatch_count;
  int unsigned rx_cfg_unexpected_count;

  function new(string name = "tidelink_fc_adapter_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    fc_tx_match_count       = 0;
    fc_tx_mismatch_count    = 0;
    fc_tx_unexpected_count  = 0;
    rx_fifo_match_count     = 0;
    rx_fifo_mismatch_count  = 0;
    rx_fifo_unexpected_count = 0;
    rx_cfg_match_count      = 0;
    rx_cfg_mismatch_count   = 0;
    rx_cfg_unexpected_count = 0;
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    fc_tx_export   = new("fc_tx_export", this);
    rx_fifo_export = new("rx_fifo_export", this);
    rx_cfg_export  = new("rx_cfg_export", this);
  endfunction

  // ---------------------------------------------------------------
  // Predict: called by tests/env to add expected FC TX packets
  // ---------------------------------------------------------------
  function void predict_fc_tx(fc_seq_item expected);
    expected_fc_tx_q.push_back(expected);
    `uvm_info("SB_PREDICT", $sformatf("Predicted FC TX: pkt_type=%s addr=0x%04h data=0x%08h (queue=%0d)",
      expected.pkt_type.name(), expected.addr_offset, expected.payload,
      expected_fc_tx_q.size()), UVM_HIGH)
  endfunction

  // ---------------------------------------------------------------
  // Predict: called by tests/env to add expected RX AHB writes
  // ---------------------------------------------------------------
  function void predict_rx_fifo(bit [13:0] addr, bit [31:0] data);
    ahb_rx_observed_item exp;
    exp = ahb_rx_observed_item::type_id::create("exp_rx_fifo");
    exp.addr    = addr;
    exp.data    = data;
    exp.is_fifo = 1'b1;
    expected_rx_fifo_q.push_back(exp);
  endfunction

  function void predict_rx_cfg(bit [13:0] addr, bit [31:0] data);
    ahb_rx_observed_item exp;
    exp = ahb_rx_observed_item::type_id::create("exp_rx_cfg");
    exp.addr    = addr;
    exp.data    = data;
    exp.is_fifo = 1'b0;
    expected_rx_cfg_q.push_back(exp);
  endfunction

  // ---------------------------------------------------------------
  // FC TX monitor callback: compare actual FC TX vs predicted
  // ---------------------------------------------------------------
  virtual function void write_fc_tx(fc_seq_item actual);
    if (expected_fc_tx_q.size() == 0) begin
      `uvm_error("SB_FC_TX", $sformatf(
        "Unexpected FC TX: pkt_type=%s addr=0x%04h data=0x%08h",
        actual.pkt_type.name(), actual.addr_offset, actual.payload))
      fc_tx_unexpected_count++;
      return;
    end

    begin
      fc_seq_item expected;
      expected = expected_fc_tx_q.pop_front();

      if (actual.pkt_type    !== expected.pkt_type ||
          actual.addr_offset !== expected.addr_offset ||
          actual.payload     !== expected.payload) begin
        `uvm_error("SB_FC_TX", $sformatf(
          "FC TX mismatch!\n  Expected: pkt_type=%s addr=0x%04h data=0x%08h\n  Actual:   pkt_type=%s addr=0x%04h data=0x%08h",
          expected.pkt_type.name(), expected.addr_offset, expected.payload,
          actual.pkt_type.name(), actual.addr_offset, actual.payload))
        fc_tx_mismatch_count++;
      end else begin
        `uvm_info("SB_FC_TX", $sformatf("FC TX match: pkt_type=%s addr=0x%04h data=0x%08h",
          actual.pkt_type.name(), actual.addr_offset, actual.payload), UVM_MEDIUM)
        fc_tx_match_count++;
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // RX FIFO write callback
  // ---------------------------------------------------------------
  virtual function void write_rx_fifo(ahb_rx_observed_item actual);
    if (expected_rx_fifo_q.size() == 0) begin
      `uvm_error("SB_RX_FIFO", $sformatf(
        "Unexpected RX FIFO write: addr=0x%04h data=0x%08h",
        actual.addr, actual.data))
      rx_fifo_unexpected_count++;
      return;
    end

    begin
      ahb_rx_observed_item expected;
      expected = expected_rx_fifo_q.pop_front();

      if (actual.addr !== expected.addr || actual.data !== expected.data) begin
        `uvm_error("SB_RX_FIFO", $sformatf(
          "RX FIFO write mismatch!\n  Expected: addr=0x%04h data=0x%08h\n  Actual:   addr=0x%04h data=0x%08h",
          expected.addr, expected.data, actual.addr, actual.data))
        rx_fifo_mismatch_count++;
      end else begin
        `uvm_info("SB_RX_FIFO", $sformatf("RX FIFO match: addr=0x%04h data=0x%08h",
          actual.addr, actual.data), UVM_MEDIUM)
        rx_fifo_match_count++;
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // RX Config write callback
  // ---------------------------------------------------------------
  virtual function void write_rx_cfg(ahb_rx_observed_item actual);
    if (expected_rx_cfg_q.size() == 0) begin
      `uvm_error("SB_RX_CFG", $sformatf(
        "Unexpected RX CFG write: addr=0x%04h data=0x%08h",
        actual.addr, actual.data))
      rx_cfg_unexpected_count++;
      return;
    end

    begin
      ahb_rx_observed_item expected;
      expected = expected_rx_cfg_q.pop_front();

      if (actual.addr !== expected.addr || actual.data !== expected.data) begin
        `uvm_error("SB_RX_CFG", $sformatf(
          "RX CFG write mismatch!\n  Expected: addr=0x%04h data=0x%08h\n  Actual:   addr=0x%04h data=0x%08h",
          expected.addr, expected.data, actual.addr, actual.data))
        rx_cfg_mismatch_count++;
      end else begin
        `uvm_info("SB_RX_CFG", $sformatf("RX CFG match: addr=0x%04h data=0x%08h",
          actual.addr, actual.data), UVM_MEDIUM)
        rx_cfg_match_count++;
      end
    end
  endfunction

  // ---------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    `uvm_info("SB_REPORT", $sformatf({
      "\n---------- FC Adapter Scoreboard Summary ----------\n",
      "  FC TX matches:      %0d\n",
      "  FC TX mismatches:   %0d\n",
      "  FC TX unexpected:   %0d\n",
      "  FC TX pending:      %0d\n",
      "  RX FIFO matches:    %0d\n",
      "  RX FIFO mismatches: %0d\n",
      "  RX FIFO unexpected: %0d\n",
      "  RX FIFO pending:    %0d\n",
      "  RX CFG matches:     %0d\n",
      "  RX CFG mismatches:  %0d\n",
      "  RX CFG unexpected:  %0d\n",
      "  RX CFG pending:     %0d\n",
      "---------------------------------------------------"},
      fc_tx_match_count, fc_tx_mismatch_count, fc_tx_unexpected_count, expected_fc_tx_q.size(),
      rx_fifo_match_count, rx_fifo_mismatch_count, rx_fifo_unexpected_count, expected_rx_fifo_q.size(),
      rx_cfg_match_count, rx_cfg_mismatch_count, rx_cfg_unexpected_count, expected_rx_cfg_q.size()),
      UVM_LOW)

    if (fc_tx_mismatch_count > 0 || fc_tx_unexpected_count > 0)
      `uvm_error("SB_REPORT", "FC TX path errors detected")
    if (rx_fifo_mismatch_count > 0 || rx_fifo_unexpected_count > 0)
      `uvm_error("SB_REPORT", "RX FIFO path errors detected")
    if (rx_cfg_mismatch_count > 0 || rx_cfg_unexpected_count > 0)
      `uvm_error("SB_REPORT", "RX CFG path errors detected")

    if (expected_fc_tx_q.size() > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d predicted FC TX items never observed", expected_fc_tx_q.size()))
    if (expected_rx_fifo_q.size() > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d predicted RX FIFO items never observed", expected_rx_fifo_q.size()))
    if (expected_rx_cfg_q.size() > 0)
      `uvm_error("SB_REPORT", $sformatf("%0d predicted RX CFG items never observed", expected_rx_cfg_q.size()))
  endfunction

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_SCOREBOARD_SV
