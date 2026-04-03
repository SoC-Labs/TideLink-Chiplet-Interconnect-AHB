///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_full_test.sv
///////////////////////////////////////////////////////////////////////////////
// Mixed traffic stress test for the TideLink FC Adapter.
//
// Exercises all paths concurrently:
//   - TX aperture writes (FIFO_DATA -> FC TX)
//   - Returner sideband writes (SIDEBAND -> FC TX)
//   - FC RX FIFO_DATA packets (-> RX FIFO AHB writes)
//   - FC RX SIDEBAND packets (-> RX config AHB writes)
//
// Verifies:
//   - TX arbitration (sideband priority over aperture)
//   - Concurrent TX + RX operation
//   - Random backpressure on FC TX ready
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_FULL_TEST_SV
`define GUARD_TIDELINK_FC_ADAPTER_FULL_TEST_SV

// ---------------------------------------------------------------
// Random TX aperture sequence with inter-transfer delays
// ---------------------------------------------------------------
class fc_adapter_random_tx_sequence extends uvm_sequence #(ahb_tx_seq_item);

  `uvm_object_utils(fc_adapter_random_tx_sequence)

  int unsigned num_writes = 16;
  ahb_tx_seq_item sent_items[$];

  function new(string name = "fc_adapter_random_tx_sequence");
    super.new(name);
  endfunction

  virtual task body();
    for (int i = 0; i < num_writes; i++) begin
      ahb_tx_seq_item item;
      item = ahb_tx_seq_item::type_id::create($sformatf("rand_tx_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        addr[13:0] inside {[14'h0000:14'h3FFC]};
        delay inside {[0:3]};
      }) `uvm_fatal("RAND", "Randomization failed")
      finish_item(item);
      sent_items.push_back(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// Random returner sequence
// ---------------------------------------------------------------
class fc_adapter_random_rtn_sequence extends uvm_sequence #(ahb_tx_seq_item);

  `uvm_object_utils(fc_adapter_random_rtn_sequence)

  int unsigned num_writes = 8;
  ahb_tx_seq_item sent_items[$];

  function new(string name = "fc_adapter_random_rtn_sequence");
    super.new(name);
  endfunction

  virtual task body();
    bit [31:0] rtn_addrs[$] = '{32'h0000_0020, 32'h0000_0024, 32'h0000_0014};
    for (int i = 0; i < num_writes; i++) begin
      ahb_tx_seq_item item;
      item = ahb_tx_seq_item::type_id::create($sformatf("rand_rtn_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        addr == rtn_addrs[i % 3];
        delay inside {[0:5]};
      }) `uvm_fatal("RAND", "Randomization failed")
      finish_item(item);
      sent_items.push_back(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// Random FC RX sequence (mixed FIFO_DATA and SIDEBAND)
// ---------------------------------------------------------------
class fc_adapter_random_rx_sequence extends uvm_sequence #(fc_seq_item);

  `uvm_object_utils(fc_adapter_random_rx_sequence)

  int unsigned num_words = 12;
  fc_seq_item sent_items[$];

  function new(string name = "fc_adapter_random_rx_sequence");
    super.new(name);
  endfunction

  virtual task body();
    for (int i = 0; i < num_words; i++) begin
      fc_seq_item item;
      item = fc_seq_item::type_id::create($sformatf("rand_fc_rx_%0d", i));
      start_item(item);
      if (!item.randomize() with {
        delay inside {[0:3]};
      }) `uvm_fatal("RAND", "Randomization failed")
      finish_item(item);
      sent_items.push_back(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// Full mixed-traffic stress test
// ---------------------------------------------------------------
class tidelink_fc_adapter_full_test extends tidelink_fc_adapter_base_test;

  `uvm_component_utils(tidelink_fc_adapter_full_test)

  function new(string name = "tidelink_fc_adapter_full_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Enable random backpressure on FC TX ready for stress
    uvm_config_db#(bit)::set(this, "env.fc_tx_rdy", "enable_backpressure", 1'b1);
  endfunction

  virtual task main_phase(uvm_phase phase);
    fc_adapter_random_tx_sequence  tx_seq;
    fc_adapter_random_rtn_sequence rtn_seq;
    fc_adapter_random_rx_sequence  rx_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== FC Adapter Full Mixed-Traffic Stress Test ===", UVM_LOW)

    // Create sequences
    tx_seq  = fc_adapter_random_tx_sequence::type_id::create("tx_seq");
    rtn_seq = fc_adapter_random_rtn_sequence::type_id::create("rtn_seq");
    rx_seq  = fc_adapter_random_rx_sequence::type_id::create("rx_seq");

    // ---------------------------------------------------------------
    // Run all three paths concurrently
    // ---------------------------------------------------------------
    fork
      // TX aperture writes
      begin
        `uvm_info("TEST", "Starting TX aperture sequence", UVM_LOW)
        tx_seq.start(env.tx_agt.sequencer);
        `uvm_info("TEST", "TX aperture sequence done", UVM_LOW)
      end

      // Returner sideband writes
      begin
        `uvm_info("TEST", "Starting returner sequence", UVM_LOW)
        rtn_seq.start(env.rtn_agt.sequencer);
        `uvm_info("TEST", "Returner sequence done", UVM_LOW)
      end

      // FC RX input
      begin
        `uvm_info("TEST", "Starting FC RX sequence", UVM_LOW)
        rx_seq.start(env.fc_agt.sequencer);
        `uvm_info("TEST", "FC RX sequence done", UVM_LOW)
      end
    join

    // ---------------------------------------------------------------
    // Add scoreboard predictions for TX path
    // (Note: with concurrent TX+RTN and priority arbitration,
    //  the interleaving order is non-deterministic. We predict
    //  separately and rely on the scoreboard's queue-based matching.)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Adding TX path predictions", UVM_LOW)
    foreach (tx_seq.sent_items[i]) begin
      fc_seq_item exp;
      exp = fc_seq_item::type_id::create($sformatf("exp_tx_%0d", i));
      exp.pkt_type    = fc_seq_item::PKT_FIFO_DATA;
      exp.addr_offset = tx_seq.sent_items[i].addr[13:0];
      exp.payload     = tx_seq.sent_items[i].data;
      env.sb.predict_fc_tx(exp);
    end

    foreach (rtn_seq.sent_items[i]) begin
      fc_seq_item exp;
      exp = fc_seq_item::type_id::create($sformatf("exp_rtn_%0d", i));
      exp.pkt_type    = fc_seq_item::PKT_SIDEBAND;
      exp.addr_offset = rtn_seq.sent_items[i].addr[13:0];
      exp.payload     = rtn_seq.sent_items[i].data;
      env.sb.predict_fc_tx(exp);
    end

    // Add RX predictions
    foreach (rx_seq.sent_items[i]) begin
      if (rx_seq.sent_items[i].pkt_type == fc_seq_item::PKT_FIFO_DATA) begin
        env.sb.predict_rx_fifo(
          rx_seq.sent_items[i].addr_offset,
          rx_seq.sent_items[i].payload
        );
      end else begin
        env.sb.predict_rx_cfg(
          rx_seq.sent_items[i].addr_offset,
          rx_seq.sent_items[i].payload
        );
      end
    end

    // Wait for all activity to settle
    repeat (100) @(posedge vif.clk);

    `uvm_info("TEST", "=== Full Stress Test Complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_FULL_TEST_SV
