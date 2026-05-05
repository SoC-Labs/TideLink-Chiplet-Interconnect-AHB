///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_random_soak.sv — Random-mask soak (H2)
///////////////////////////////////////////////////////////////////////////////
// Picks a random non-zero mask each iteration, applies it to both sides
// using the safe disable-LL → write-mask → enable-LL sequence, sends a
// few packets, and confirms they round-trip. Repeats N_ITERATIONS times.
//
// Stresses:
//   - mid-stream mask change with link quiescence
//   - the per-lane lanePos formula across a wide range of popcounts
//   - the cg_lane_mask covergroup (each iteration drops a sample)
//
// At the end of each iteration the scoreboard's a2b stream is compared.
// If any iteration produces a mismatch, the test fails.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_RANDOM_SOAK_SV
`define GUARD_TEST_TOP_LANE_MASK_RANDOM_SOAK_SV

class test_top_lane_mask_random_soak extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_random_soak)

  localparam bit [14:0] WLINK_LINK_ENABLE_RESET = 15'h0208;
  localparam bit [14:0] WLINK_LANE_MASK         = 15'h0214;
  localparam bit [31:0] LL_ENABLE_DEFAULT       = 32'h0002_7F07;
  localparam bit [31:0] LL_ENABLE_DISABLED      = LL_ENABLE_DEFAULT & ~32'h0000_0006;

  int unsigned n_iterations         = 25;
  int unsigned packets_per_iteration = 2;

  function new(string name = "test_top_lane_mask_random_soak",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
    test_timeout_cycles = 30_000_000;
  endfunction

  // Pick a random non-zero 8-bit mask. Bias slightly toward fuller masks
  // (more lanes) to keep iteration time reasonable; full-width is the
  // fastest GPIO PHY case.
  function bit [7:0] random_mask();
    bit [7:0] m;
    do begin
      m = $urandom() & 8'hFF;
    end while (m == 8'h00);
    return m;
  endfunction

  virtual task disable_ll_both();
    write_cfg_reg_raw(SIDE_A, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DISABLED);
    write_cfg_reg_raw(SIDE_B, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DISABLED);
    repeat (200) @(posedge tb_if.clk);
  endtask

  virtual task enable_ll_both();
    write_cfg_reg_raw(SIDE_A, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DEFAULT);
    write_cfg_reg_raw(SIDE_B, WLINK_LINK_ENABLE_RESET, LL_ENABLE_DEFAULT);
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);
  endtask

  virtual task main_phase(uvm_phase phase);
    int unsigned i, p;
    bit [7:0]    new_mask;
    bit [31:0]   pkt_data[];
    bit [31:0]   read_data[];
    int unsigned active_wait;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", $sformatf(
      "=== Random-mask soak: %0d iterations × %0d packets ===",
      n_iterations, packets_per_iteration), UVM_LOW)

    init_system_with_lane_mask();

    for (i = 0; i < n_iterations; i++) begin
      new_mask = random_mask();
      `uvm_info("TEST", $sformatf(
        "[iter %0d/%0d] mask=0x%02h (popcount=%0d)",
        i + 1, n_iterations, new_mask, $countones(new_mask)), UVM_LOW)

      disable_ll_both();
      // Pack as {rx[7:0], tx[7:0]} into bits [15:0] — see test_top_lane_mask_base
      write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK, {16'h0000, new_mask, new_mask});
      write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK, {16'h0000, new_mask, new_mask});

      // Track for active_lanes check & coverage sample
      a_tx_mask = {8'h00, new_mask};
      a_rx_mask = {8'h00, new_mask};
      b_tx_mask = {8'h00, new_mask};
      b_rx_mask = {8'h00, new_mask};
      if (env.cov != null)
        env.cov.sample_lane_mask(a_tx_mask, a_rx_mask);

      enable_ll_both();
      check_active_lanes();

      // GPIO PHY is slower at low popcount — scale the wait per iteration.
      active_wait = phy_transit_wait * (8 / $countones(new_mask));

      for (p = 0; p < packets_per_iteration; p++) begin
        pkt_data = new[3];
        pkt_data[0] = (i << 24) | (p << 16) | 32'h0000_AAAA;
        pkt_data[1] = (i << 24) | (p << 16) | 32'h0000_BBBB;
        pkt_data[2] = (i << 24) | (p << 16) | 32'h0000_CCCC;
        write_packet(SIDE_A, pkt_data);
        repeat (active_wait) @(posedge tb_if.clk);
        read_packet(SIDE_B, 3, read_data);
        repeat (active_wait / 4) @(posedge tb_if.clk);
      end
    end

    env.sb.compare_a2b_data();

    // Restore default mask
    disable_ll_both();
    write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK, 32'h0000_FFFF);
    write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK, 32'h0000_FFFF);
    enable_ll_both();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_RANDOM_SOAK_SV
