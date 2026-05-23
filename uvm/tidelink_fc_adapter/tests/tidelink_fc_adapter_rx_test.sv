///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_rx_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests the RX path: FC RX input -> AHB master writes to FIFO/config ports.
//
// Verifies:
//   - FIFO_DATA FC RX packets produce writes on fc_rx_fifo_* AHB port
//   - SIDEBAND FC RX packets produce writes on fc_rx_cfg_* AHB port
//   - addr_offset is correctly routed to the appropriate AHB address bus
//   - payload is correctly driven as AHB write data
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_RX_TEST_SV
`define GUARD_TIDELINK_FC_ADAPTER_RX_TEST_SV

// ---------------------------------------------------------------
// FC RX FIFO data sequence
// ---------------------------------------------------------------
class fc_rx_fifo_data_sequence extends uvm_sequence #(fc_seq_item);

  `uvm_object_utils(fc_rx_fifo_data_sequence)

  int unsigned num_words = 4;

  // Stored items for scoreboard prediction.
  // BUG-22 fix: pre_generate() freezes items before driving.
  fc_seq_item sent_items[$];

  function new(string name = "fc_rx_fifo_data_sequence");
    super.new(name);
  endfunction

  virtual function void pre_generate();
    sent_items.delete();
    for (int i = 0; i < num_words; i++) begin
      fc_seq_item item;
      item = fc_seq_item::type_id::create($sformatf("fc_rx_fifo_%0d", i));
      if (!item.randomize() with {
        pkt_type == fc_seq_item::PKT_FIFO_DATA;
        addr_offset[13:2] == i[11:0];
        delay == 0;
      }) `uvm_fatal("RAND", "Randomization failed")
      sent_items.push_back(item);
    end
  endfunction

  virtual task body();
    if (sent_items.size() == 0)
      pre_generate();
    foreach (sent_items[i]) begin
      fc_seq_item item = sent_items[i];
      start_item(item);
      finish_item(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// FC RX sideband sequence
// ---------------------------------------------------------------
class fc_rx_sideband_sequence extends uvm_sequence #(fc_seq_item);

  `uvm_object_utils(fc_rx_sideband_sequence)

  int unsigned num_words = 3;

  // Target APB register offsets
  bit [13:0] reg_offsets[$];

  // Stored items for scoreboard prediction.
  // BUG-22 fix: pre_generate() freezes items before driving.
  fc_seq_item sent_items[$];

  function new(string name = "fc_rx_sideband_sequence");
    super.new(name);
    reg_offsets = '{14'h020, 14'h024, 14'h014};
  endfunction

  virtual function void pre_generate();
    sent_items.delete();
    for (int i = 0; i < num_words && i < reg_offsets.size(); i++) begin
      fc_seq_item item;
      item = fc_seq_item::type_id::create($sformatf("fc_rx_sb_%0d", i));
      if (!item.randomize() with {
        pkt_type    == fc_seq_item::PKT_SIDEBAND;
        addr_offset == reg_offsets[i];
        delay == 0;
      }) `uvm_fatal("RAND", "Randomization failed")
      sent_items.push_back(item);
    end
  endfunction

  virtual task body();
    if (sent_items.size() == 0)
      pre_generate();
    foreach (sent_items[i]) begin
      fc_seq_item item = sent_items[i];
      start_item(item);
      finish_item(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// RX path test
// ---------------------------------------------------------------
class tidelink_fc_adapter_rx_test extends tidelink_fc_adapter_base_test;

  `uvm_component_utils(tidelink_fc_adapter_rx_test)

  function new(string name = "tidelink_fc_adapter_rx_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    fc_rx_fifo_data_sequence fifo_seq;
    fc_rx_sideband_sequence  sb_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== FC Adapter RX Path Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: FIFO_DATA packets — pre-generate, predict, then drive
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Pre-randomizing FIFO_DATA FC RX items", UVM_LOW)
    fifo_seq = fc_rx_fifo_data_sequence::type_id::create("fifo_seq");
    fifo_seq.num_words = 4;
    fifo_seq.pre_generate();

    foreach (fifo_seq.sent_items[i]) begin
      env.sb.predict_rx_fifo(
        fifo_seq.sent_items[i].addr_offset,
        fifo_seq.sent_items[i].payload
      );
    end

    `uvm_info("TEST", "Step 1: Sending FIFO_DATA FC RX packets", UVM_LOW)
    fifo_seq.start(env.fc_agt.sequencer);

    // Wait for all RX AHB writes to complete
    repeat (30) @(posedge vif.clk);

    // ---------------------------------------------------------------
    // Step 2: SIDEBAND packets — pre-generate, predict, then drive
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 2: Pre-randomizing SIDEBAND FC RX items", UVM_LOW)
    sb_seq = fc_rx_sideband_sequence::type_id::create("sb_seq");
    sb_seq.pre_generate();

    foreach (sb_seq.sent_items[i]) begin
      env.sb.predict_rx_cfg(
        sb_seq.sent_items[i].addr_offset,
        sb_seq.sent_items[i].payload
      );
    end

    `uvm_info("TEST", "Step 2: Sending SIDEBAND FC RX packets", UVM_LOW)
    sb_seq.start(env.fc_agt.sequencer);

    // Wait for all RX AHB writes to complete
    repeat (30) @(posedge vif.clk);

    `uvm_info("TEST", "=== RX Path Test Complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_RX_TEST_SV
