///////////////////////////////////////////////////////////////////////////////
// test_top_ahb_passthrough.sv — AHB regular access path via XHB500 + Wlink
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AHB_PASSTHROUGH_SV
`define GUARD_TEST_TOP_AHB_PASSTHROUGH_SV

class test_top_ahb_passthrough extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_ahb_passthrough)

  function new(string name = "test_top_ahb_passthrough", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    top_sys_ahb_sub_write_sequence wr_seq;
    top_sys_ahb_sub_read_sequence  rd_seq;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top AHB Passthrough A->B ===", UVM_LOW)

    init_wlink();

    // Write via A's ahb_sub
    `uvm_info("TEST", "Writing via A SUB port...", UVM_LOW)
    wr_seq = top_sys_ahb_sub_write_sequence::type_id::create("wr_seq");
    wr_seq.addr = 32'h0000_1000;
    wr_seq.data = 32'hCAFE_F00D;
    wr_seq.start(env.a_sub_ahb_sys_env.master[0].sequencer);

    repeat (500) @(posedge tb_if.clk);
    `uvm_info("TEST", "AHB passthrough write complete.", UVM_LOW)

    // Read via A's ahb_sub
    rd_seq = top_sys_ahb_sub_read_sequence::type_id::create("rd_seq");
    rd_seq.addr = 32'h0000_2000;
    rd_seq.start(env.a_sub_ahb_sys_env.master[0].sequencer);

    repeat (500) @(posedge tb_if.clk);
    `uvm_info("TEST", "AHB passthrough read complete.", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif
