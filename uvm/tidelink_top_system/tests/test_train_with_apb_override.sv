///////////////////////////////////////////////////////////////////////////////
// test_train_with_apb_override.sv — SW pre-loads bit_slip; FSM respects
///////////////////////////////////////////////////////////////////////////////
// Verifies that SW writes to Region 8 `SWI_BIT_SLIP_LO` (0x4403_2104) persist
// across the training sub-flow — i.e. the autoneg FSM does not clobber the
// SW-loaded slip vector. With lane-status hooks tied to "all-locked", the
// training sub-flow runs to TRAIN_DONE on the first poll regardless of the
// slip value.
//
// In a production build the calibrator would consult the SW slip value via
// the autocal FSM's `apb_bit_slip_override` input. Here we just exercise the
// register-block side: a write-then-read round-trip with the FSM running
// in between.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TRAIN_WITH_APB_OVERRIDE_SV
`define GUARD_TEST_TRAIN_WITH_APB_OVERRIDE_SV

class test_train_with_apb_override extends test_top_train_base;

  `uvm_component_utils(test_train_with_apb_override)

  // Asymmetric slip pattern (the same example used in the cocotb pair-align
  // tests). lane K at bits [3K+2 : 3K]. Pattern = [3,5,0,2,7,1,4,6]:
  //   lane 0 = 3'b011 → bits[2:0]   = 3'h3
  //   lane 1 = 3'b101 → bits[5:3]   = 3'h5
  //   lane 2 = 3'b000 → bits[8:6]   = 3'h0
  //   lane 3 = 3'b010 → bits[11:9]  = 3'h2
  //   lane 4 = 3'b111 → bits[14:12] = 3'h7
  //   lane 5 = 3'b001 → bits[17:15] = 3'h1
  //   lane 6 = 3'b100 → bits[20:18] = 3'h4
  //   lane 7 = 3'b110 → bits[23:21] = 3'h6
  // Packed = 24'b110_100_001_111_010_000_101_011 = 24'hD1_E8AB
  // (Note: the exact pattern isn't critical — the test just asserts
  // persistence.)
  localparam bit [31:0] BIT_SLIP_PRELOAD = 32'h00D1_E8AB;

  function new(string name = "test_train_with_apb_override",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task pre_main_phase(uvm_phase phase);
    super.pre_main_phase(phase);
    tb_if.a_mask_hs_bypass = 1'b1;
    tb_if.b_mask_hs_bypass = 1'b1;
  endtask

  virtual task main_phase(uvm_phase phase);
    bit train_ok, train_fail;
    bit [31:0] slip_readback_a, slip_readback_b;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_train_with_apb_override ===", UVM_LOW)

    // Pre-load SWI_BIT_SLIP_LO on both sides BEFORE autoneg runs.
    write_cfg_reg_raw(SIDE_A, R8_SWI_BIT_SLIP_LO, BIT_SLIP_PRELOAD);
    write_cfg_reg_raw(SIDE_B, R8_SWI_BIT_SLIP_LO, BIT_SLIP_PRELOAD);

    force_local_status(SIDE_A, 8'hFF, 8'h00, 1'b1);
    force_local_status(SIDE_B, 8'hFF, 8'h00, 1'b1);

    program_train_cfg();
    wait_train_complete(train_ok, train_fail);
    `uvm_info("TEST", $sformatf("Train: ok=%0b fail=%0b", train_ok, train_fail),
              UVM_LOW)

    if (!train_ok)
      `uvm_error("TEST", "Expected train_ok=1 in override scenario")

    // Read back SWI_BIT_SLIP_LO on both sides — must match pre-load.
    read_cfg_reg_raw(SIDE_A, R8_SWI_BIT_SLIP_LO, slip_readback_a);
    read_cfg_reg_raw(SIDE_B, R8_SWI_BIT_SLIP_LO, slip_readback_b);
    `uvm_info("TEST", $sformatf(
      "Post-train SWI_BIT_SLIP_LO: A=0x%08h B=0x%08h (expected 0x%08h)",
      slip_readback_a, slip_readback_b, BIT_SLIP_PRELOAD), UVM_LOW)

    if (slip_readback_a !== BIT_SLIP_PRELOAD)
      `uvm_error("TEST", $sformatf(
        "[A] SWI_BIT_SLIP_LO mismatch: expected 0x%08h, got 0x%08h",
        BIT_SLIP_PRELOAD, slip_readback_a))
    if (slip_readback_b !== BIT_SLIP_PRELOAD)
      `uvm_error("TEST", $sformatf(
        "[B] SWI_BIT_SLIP_LO mismatch: expected 0x%08h, got 0x%08h",
        BIT_SLIP_PRELOAD, slip_readback_b))

    release_local_status(SIDE_A);
    release_local_status(SIDE_B);

    repeat (50) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TRAIN_WITH_APB_OVERRIDE_SV
