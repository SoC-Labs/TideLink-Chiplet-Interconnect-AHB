///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_tx_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests the TX aperture path: AHB slave writes -> FC TX FIFO_DATA packets.
//
// Verifies:
//   - AHB writes to the TX aperture produce correct 48-bit FC TX output
//   - pkt_type = FIFO_DATA (2'b00)
//   - addr_offset matches the written AHB address
//   - payload matches the written AHB data
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_TX_TEST_SV
`define GUARD_TIDELINK_FC_ADAPTER_TX_TEST_SV

// ---------------------------------------------------------------
// TX aperture write sequence
// ---------------------------------------------------------------
class fc_adapter_tx_write_sequence extends uvm_sequence #(ahb_tx_seq_item);

  `uvm_object_utils(fc_adapter_tx_write_sequence)

  // Configurable number of writes
  int unsigned num_writes = 8;

  // Stored items for scoreboard prediction
  ahb_tx_seq_item sent_items[$];

  function new(string name = "fc_adapter_tx_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    for (int i = 0; i < num_writes; i++) begin
      ahb_tx_seq_item item;
      item = ahb_tx_seq_item::type_id::create($sformatf("tx_wr_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        addr[13:2] == i[11:0];  // Sequential word addresses
        delay == 0;
      }) `uvm_fatal("RAND", "Randomization failed")
      finish_item(item);
      sent_items.push_back(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// TX aperture test
// ---------------------------------------------------------------
class tidelink_fc_adapter_tx_test extends tidelink_fc_adapter_base_test;

  `uvm_component_utils(tidelink_fc_adapter_tx_test)

  function new(string name = "tidelink_fc_adapter_tx_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    fc_adapter_tx_write_sequence tx_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== FC Adapter TX Aperture Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Send writes through TX aperture
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Writing to TX aperture", UVM_LOW)
    tx_seq = fc_adapter_tx_write_sequence::type_id::create("tx_seq");
    tx_seq.num_writes = 8;
    tx_seq.start(env.tx_agt.sequencer);

    // ---------------------------------------------------------------
    // Step 2: Add scoreboard predictions
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 2: Adding scoreboard predictions", UVM_LOW)
    foreach (tx_seq.sent_items[i]) begin
      fc_seq_item exp;
      exp = fc_seq_item::type_id::create($sformatf("exp_tx_%0d", i));
      exp.pkt_type    = fc_seq_item::PKT_FIFO_DATA;
      exp.addr_offset = tx_seq.sent_items[i].addr[13:0];
      exp.payload     = tx_seq.sent_items[i].data;
      env.sb.predict_fc_tx(exp);
    end

    // Wait for all FC TX to complete
    repeat (50) @(posedge vif.clk);

    `uvm_info("TEST", "=== TX Aperture Test Complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_TX_TEST_SV
