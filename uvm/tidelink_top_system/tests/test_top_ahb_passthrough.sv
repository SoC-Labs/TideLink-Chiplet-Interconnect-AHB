///////////////////////////////////////////////////////////////////////////////
// test_top_ahb_passthrough.sv — AHB regular access path via XHB500 + Wlink
///////////////////////////////////////////////////////////////////////////////
// Exercises the ahb_sub -> XHB500 AHB→AXI -> Wlink -> remote XHB500 AXI→AHB
// -> ahb_mng path. This is the standard AHB passthrough that bypasses the
// TideLink FIFO mechanism.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AHB_PASSTHROUGH_SV
`define GUARD_TEST_TOP_AHB_PASSTHROUGH_SV

class test_top_ahb_passthrough extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_ahb_passthrough)

  function new(string name = "test_top_ahb_passthrough", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top AHB Passthrough A->B ===", UVM_LOW)

    // Init Wlink (needed for AHB passthrough path too)
    init_wlink();

    // Write via A's ahb_sub — should appear on B's ahb_mng
    env.a_sub_ahb_sys_env.master[0].sequencer.get_cfg(get_cfg);

    `uvm_info("TEST", "Writing via A SUB port...", UVM_LOW)
    `uvm_create_on(txn, env.a_sub_ahb_sys_env.master[0].sequencer)
    txn.cfg = get_cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == 32'h0000_1000;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == 32'hCAFE_F00D;
    });
    `uvm_send(txn)

    // Wait for AHB -> AXI -> Wlink -> PHY -> Wlink -> AXI -> AHB
    repeat (500) @(posedge tb_if.clk);

    `uvm_info("TEST", "AHB passthrough write complete.", UVM_LOW)

    // Read via A's ahb_sub
    `uvm_create_on(txn, env.a_sub_ahb_sys_env.master[0].sequencer)
    txn.cfg = get_cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      addr       == 32'h0000_2000;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
    });
    `uvm_send(txn)

    repeat (500) @(posedge tb_if.clk);

    `uvm_info("TEST", "AHB passthrough read complete.", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
