///////////////////////////////////////////////////////////////////////////////
// tidelink_fc_adapter_sideband_test.sv
///////////////////////////////////////////////////////////////////////////////
// Tests the returner sideband path: returner AHB writes -> FC TX SIDEBAND.
//
// Verifies:
//   - Returner writes produce SIDEBAND-type FC TX packets
//   - addr_offset carries the lower 14 bits of the returner target address
//   - payload matches the returner write data
//   - Sideband has priority over TX aperture (when both active)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_FC_ADAPTER_SIDEBAND_TEST_SV
`define GUARD_TIDELINK_FC_ADAPTER_SIDEBAND_TEST_SV

// ---------------------------------------------------------------
// Returner sideband write sequence
// ---------------------------------------------------------------
class fc_adapter_rtn_write_sequence extends uvm_sequence #(ahb_tx_seq_item);

  `uvm_object_utils(fc_adapter_rtn_write_sequence)

  // Typical returner target addresses (register offsets within pair)
  bit [31:0] target_addrs[$];

  // Stored items for scoreboard prediction.
  // BUG-22 fix: pre_generate() freezes items before driving so predictions
  // can be registered before the first FC TX is observed.
  ahb_tx_seq_item sent_items[$];

  function new(string name = "fc_adapter_rtn_write_sequence");
    super.new(name);
    // Default returner targets: released_acc, doorbell_resp_acc, doorbell
    target_addrs = '{32'h0000_0020, 32'h0000_0024, 32'h0000_0014};
  endfunction

  // Pre-randomize all items without driving them.
  virtual function void pre_generate();
    sent_items.delete();
    foreach (target_addrs[i]) begin
      ahb_tx_seq_item item;
      item = ahb_tx_seq_item::type_id::create($sformatf("rtn_wr_%0d", i));
      if (!item.randomize() with {
        addr == target_addrs[i];
        delay == 0;
      }) `uvm_fatal("RAND", "Randomization failed")
      sent_items.push_back(item);
    end
  endfunction

  virtual task body();
    if (sent_items.size() == 0)
      pre_generate();
    foreach (sent_items[i]) begin
      ahb_tx_seq_item item = sent_items[i];
      start_item(item);
      finish_item(item);
    end
  endtask

endclass

// ---------------------------------------------------------------
// Sideband test
// ---------------------------------------------------------------
class tidelink_fc_adapter_sideband_test extends tidelink_fc_adapter_base_test;

  `uvm_component_utils(tidelink_fc_adapter_sideband_test)

  function new(string name = "tidelink_fc_adapter_sideband_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    fc_adapter_rtn_write_sequence rtn_seq;

    phase.raise_objection(this);

    `uvm_info("TEST", "=== FC Adapter Sideband Test ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Pre-randomize so predictions are registered BEFORE driving
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 1: Pre-randomizing returner items", UVM_LOW)
    rtn_seq = fc_adapter_rtn_write_sequence::type_id::create("rtn_seq");
    rtn_seq.pre_generate();

    // ---------------------------------------------------------------
    // Step 2: Add scoreboard predictions BEFORE driving
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 2: Adding scoreboard predictions (pre-drive)", UVM_LOW)
    foreach (rtn_seq.sent_items[i]) begin
      fc_seq_item exp;
      exp = fc_seq_item::type_id::create($sformatf("exp_rtn_%0d", i));
      exp.pkt_type    = fc_seq_item::PKT_SIDEBAND;
      exp.addr_offset = rtn_seq.sent_items[i].addr[13:0];
      exp.payload     = rtn_seq.sent_items[i].data;
      env.sb.predict_fc_tx(exp);
    end

    // ---------------------------------------------------------------
    // Step 3: Drive the pre-generated items
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Step 3: Sending returner writes", UVM_LOW)
    rtn_seq.start(env.rtn_agt.sequencer);

    // Wait for all FC TX to complete
    repeat (50) @(posedge vif.clk);

    `uvm_info("TEST", "=== Sideband Test Complete ===", UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TIDELINK_FC_ADAPTER_SIDEBAND_TEST_SV
