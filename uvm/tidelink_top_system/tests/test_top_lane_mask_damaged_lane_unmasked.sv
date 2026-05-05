///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_damaged_lane_unmasked.sv — Positive-control for E3 (E4)
///////////////////////////////////////////////////////////////////////////////
// Same pad perturbation as test_top_lane_mask_damaged_lane (lane 7 stuck-at-1
// in both directions) but with mask=0xFF (default, no lane disabled). With
// the link expecting valid data on lane 7, the perturb corrupts every
// stripe — we expect either:
//   (a) the Wlink CRC error counter to fire (link_interrupts at 0x240 bit[0]),
//       OR
//   (b) the scoreboard a2b compare to fail
//
// If neither happens, the test FAILS — that means the pad perturb hook
// isn't actually injecting damage, and the positive result of the
// damaged-lane test cannot be trusted.
//
// This is a sanity test: the goal is to fail loudly when the perturb
// infrastructure isn't doing what we think. Once it passes (i.e. the
// expected damage is observed), the damaged-lane test's pass becomes
// meaningful.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_DAMAGED_LANE_UNMASKED_SV
`define GUARD_TEST_TOP_LANE_MASK_DAMAGED_LANE_UNMASKED_SV

class test_top_lane_mask_damaged_lane_unmasked extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_damaged_lane_unmasked)

  localparam bit [14:0] WLINK_LINK_INTERRUPTS = 15'h0240;

  function new(string name = "test_top_lane_mask_damaged_lane_unmasked",
               uvm_component parent = null);
    super.new(name, parent);
    // Default 0xFF — link expects data on every lane
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
    // Mismatches are the expected positive-control signal here
    top_system_a2b_expected_catcher::expect_a2b_mismatch = 1'b1;
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] a_int, b_int;
    bit        damage_observed = 1'b0;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Damaged lane unmasked — positive control ===", UVM_LOW)

    `uvm_info("TEST", "Forcing lane 7 stuck-at-1 in both directions", UVM_LOW)
    tb_if.a2b_lane_perturb_en[7]  = 1'b1;
    tb_if.a2b_lane_perturb_val[7] = 1'b1;
    tb_if.b2a_lane_perturb_en[7]  = 1'b1;
    tb_if.b2a_lane_perturb_val[7] = 1'b1;

    init_system_with_lane_mask();

    // Demote scoreboard a2b mismatches to UVM_INFO temporarily — we're
    // expecting them. Use a report catcher pattern.

    pkt_data = new[4];
    pkt_data[0] = 32'hAAAA_0001;
    pkt_data[1] = 32'hBBBB_0002;
    pkt_data[2] = 32'hCCCC_0003;
    pkt_data[3] = 32'hDDDD_0004;
    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait * 2) @(posedge tb_if.clk);

    // Try to read — may time out or return garbage
    fork
      begin
        read_packet(SIDE_B, 4, read_data);
      end
      begin
        repeat (phy_transit_wait * 4) @(posedge tb_if.clk);
        `uvm_info("TEST", "Read timed out — counts as damage observation", UVM_LOW)
      end
    join_any
    disable fork;

    // Check Wlink interrupt status on both sides — bit[0] = crc_errors W1C
    read_cfg_reg_raw(SIDE_A, WLINK_LINK_INTERRUPTS, a_int);
    read_cfg_reg_raw(SIDE_B, WLINK_LINK_INTERRUPTS, b_int);
    `uvm_info("TEST", $sformatf(
      "A.link_interrupts=0x%08h B.link_interrupts=0x%08h",
      a_int, b_int), UVM_LOW)

    if ((a_int & 32'h0000_0001) != 0 || (b_int & 32'h0000_0001) != 0) begin
      `uvm_info("TEST", "CRC error observed — perturb hook is functional", UVM_LOW)
      damage_observed = 1'b1;
    end

    if (read_data.size() != 4 || read_data != pkt_data) begin
      `uvm_info("TEST", $sformatf(
        "Scoreboard mismatch — perturb hook is functional (got size=%0d)",
        read_data.size()), UVM_LOW)
      damage_observed = 1'b1;
    end

    // The whole point of this test is to see the damage. If we don't,
    // something's wrong with the perturb infrastructure.
    if (!damage_observed) begin
      `uvm_error("TEST",
        "No damage observed at unmasked link with stuck pad — perturb hook may be ineffective. The positive-control behaviour expected by test_top_lane_mask_damaged_lane is NOT confirmed.")
    end

    // Release perturb
    tb_if.a2b_lane_perturb_en[7] = 1'b0;
    tb_if.b2a_lane_perturb_en[7] = 1'b0;

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_DAMAGED_LANE_UNMASKED_SV
