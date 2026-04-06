///////////////////////////////////////////////////////////////////////////////
// test_top_autoneg_bypass.sv — Auto-negotiation bypass (backward compat)
///////////////////////////////////////////////////////////////////////////////
// Verifies that the existing boot flow (static role lock via init_wlink())
// works correctly when auto-negotiation is NOT enabled on either side.
// This proves backward compatibility with the pre-autoneg flow.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AUTONEG_BYPASS_SV
`define GUARD_TEST_TOP_AUTONEG_BYPASS_SV

class test_top_autoneg_bypass extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_autoneg_bypass)

  function new(string name = "test_top_autoneg_bypass", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];
    bit [31:0] nego_status_a, nego_status_b;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Bypass ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Use standard static role lock (no autoneg)
    // ---------------------------------------------------------------
    init_system();

    // ---------------------------------------------------------------
    // Step 2: Verify NEGO_STATUS shows idle (no negotiation ran)
    // ---------------------------------------------------------------
    read_cfg_reg(SIDE_A, REG_NEGO_STATUS, nego_status_a);
    read_cfg_reg(SIDE_B, REG_NEGO_STATUS, nego_status_b);

    if (nego_status_a[NEGO_STATUS_DONE])
      `uvm_error("TEST", "[A] NEGO_STATUS.done unexpectedly set in bypass mode")
    if (nego_status_b[NEGO_STATUS_DONE])
      `uvm_error("TEST", "[B] NEGO_STATUS.done unexpectedly set in bypass mode")

    `uvm_info("TEST", $sformatf("NEGO_STATUS: A=0x%08h B=0x%08h (both idle as expected)",
      nego_status_a, nego_status_b), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 3: Send packet A->B and verify normal data flow
    // ---------------------------------------------------------------
    pkt_data = new[4];
    pkt_data[0] = 32'hAAAA_BBBB;
    pkt_data[1] = 32'hCCCC_DDDD;
    pkt_data[2] = 32'hEEEE_FFFF;
    pkt_data[3] = 32'h0011_2233;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    // ---------------------------------------------------------------
    // Step 4: Send packet B->A to verify bidirectional flow
    // ---------------------------------------------------------------
    pkt_data[0] = 32'h4455_6677;
    pkt_data[1] = 32'h8899_AABB;
    pkt_data[2] = 32'hCCDD_EEFF;
    pkt_data[3] = 32'h0102_0304;
    write_packet(SIDE_B, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_A, 4, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_b2a_data();

    check_no_errors(SIDE_A);
    check_no_errors(SIDE_B);

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Bypass COMPLETE ===", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_AUTONEG_BYPASS_SV
