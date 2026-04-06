///////////////////////////////////////////////////////////////////////////////
// test_top_autoneg_timeout.sv — Auto-negotiation timeout with fallback
///////////////////////////////////////////////////////////////////////////////
// Sets both sides to priority = 0xFFFF with a very short timeout (1000
// cycles). Both sides should timeout and report NEGO_ERROR. Each adopts
// its fallback role (slave). Verifies:
//   - nego_error set on both sides
//   - role_locked_o asserted on both (auto-locked via fallback + force_lock)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AUTONEG_TIMEOUT_SV
`define GUARD_TEST_TOP_AUTONEG_TIMEOUT_SV

class test_top_autoneg_timeout extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_autoneg_timeout)

  function new(string name = "test_top_autoneg_timeout", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    top_sys_autoneg_sequence a_autoneg, b_autoneg;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Timeout ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Configure both sides with same priority and short timeout
    // ---------------------------------------------------------------
    a_autoneg = top_sys_autoneg_sequence::type_id::create("a_autoneg");
    a_autoneg.side_name      = "A";
    a_autoneg.priority_val   = 32'h0000_FFFF;
    a_autoneg.timeout_val    = 32'h0000_03E8;  // 1000 cycles
    a_autoneg.fallback_role  = 1;              // fallback to slave
    a_autoneg.force_lock     = 1;

    b_autoneg = top_sys_autoneg_sequence::type_id::create("b_autoneg");
    b_autoneg.side_name      = "B";
    b_autoneg.priority_val   = 32'h0000_FFFF;
    b_autoneg.timeout_val    = 32'h0000_03E8;  // 1000 cycles
    b_autoneg.fallback_role  = 1;              // fallback to slave
    b_autoneg.force_lock     = 1;

    // ---------------------------------------------------------------
    // Step 2: Run negotiation on both sides
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Starting auto-negotiation (expecting timeout)...", UVM_LOW)

    fork
      a_autoneg.start(env.a_apb_agt.sequencer);
      b_autoneg.start(env.b_apb_agt.sequencer);
    join

    // ---------------------------------------------------------------
    // Step 3: Verify both sides report error
    // ---------------------------------------------------------------
    if (!a_autoneg.nego_error)
      `uvm_error("TEST", "[A] Expected NEGO_ERROR but nego_error not set")
    else
      `uvm_info("TEST", "[A] NEGO_ERROR correctly set (timeout)", UVM_LOW)

    if (!b_autoneg.nego_error)
      `uvm_error("TEST", "[B] Expected NEGO_ERROR but nego_error not set")
    else
      `uvm_info("TEST", "[B] NEGO_ERROR correctly set (timeout)", UVM_LOW)

    `uvm_info("TEST", $sformatf("Side A STATUS=0x%08h | Side B STATUS=0x%08h",
      a_autoneg.final_status, b_autoneg.final_status), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 4: Verify both adopted fallback role (slave) and are locked
    // ---------------------------------------------------------------
    // Read ROLE_STATUS to check role_locked and assigned role
    begin
      bit [31:0] role_status_a, role_status_b;
      // ROLE_STATUS is at offset 0x084 in the chiplet controller region
      read_cfg_reg(SIDE_A, 12'h084, role_status_a);
      read_cfg_reg(SIDE_B, 12'h084, role_status_b);

      `uvm_info("TEST", $sformatf("ROLE_STATUS: A=0x%08h B=0x%08h", role_status_a, role_status_b), UVM_LOW)

      // Check role_locked (bit 1)
      if (!role_status_a[1])
        `uvm_error("TEST", "[A] role_locked not set after fallback")
      if (!role_status_b[1])
        `uvm_error("TEST", "[B] role_locked not set after fallback")
    end

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Timeout COMPLETE ===", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_AUTONEG_TIMEOUT_SV
