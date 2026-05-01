///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_mismatch_sweep.sv — Diagnostic-only mismatch sweep (F)
///////////////////////////////////////////////////////////////////////////////
// Walks a curated set of (a_mask, b_mask) pairs with deliberately mismatched
// values and records observable symptoms:
//   - link_interrupts at 0x240 (crc_errors W1C, ecc_corrected W1C, ecc_corrupted W1C)
//   - link_status at 0x234 (in_error_state, tx_active, rx_active)
//   - whether a probe packet round-tripped at all
//   - scoreboard a2b compare result (clean, mismatched, timed out)
//
// Writes one CSV row per pair to lane_mask_mismatch.csv in the sim directory.
// The output feeds the design of a future mask-matches-peer autoneg
// handshake (see SHORTCOMINGS.md #14a). This test is DIAGNOSTIC ONLY:
// every iteration is expected to produce *some* symptom; the test passes
// as long as the sweep completes (not as long as every probe succeeds).
//
// Each iteration brings the link up from scratch in a fresh test instance
// is too heavy — this test instead programs the masks at runtime with
// LL disabled, then re-enables LL between iterations. If the link wedges
// on a mismatched mask, the per-iteration timeout limits damage to that
// row of the CSV.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_MISMATCH_SWEEP_SV
`define GUARD_TEST_TOP_LANE_MASK_MISMATCH_SWEEP_SV

class test_top_lane_mask_mismatch_sweep extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_mismatch_sweep)

  localparam bit [14:0] WLINK_LINK_ENABLE_RESET = 15'h0208;
  localparam bit [14:0] WLINK_LANE_MASK         = 15'h0214;
  localparam bit [14:0] WLINK_LINK_STATUS       = 15'h0234;
  localparam bit [14:0] WLINK_LINK_INTERRUPTS   = 15'h0240;
  localparam bit [31:0] LL_ENABLE_DEFAULT       = 32'h0002_7F07;
  localparam bit [31:0] LL_ENABLE_DISABLED      = LL_ENABLE_DEFAULT & ~32'h0000_0006;

  typedef struct {
    bit [15:0] a_mask;
    bit [15:0] b_mask;
    string     label;
  } mismatch_pair_t;

  mismatch_pair_t pairs[];

  function new(string name = "test_top_lane_mask_mismatch_sweep",
               uvm_component parent = null);
    super.new(name, parent);
    // Start at default — the per-iteration loop reprograms.
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
    // Generous global timeout — sweep covers ~15 mask pairs at ~5 ms each.
    test_timeout_cycles = 20_000_000;

    pairs = new[15];
    pairs[ 0] = '{16'h00FF, 16'h007F, "peer_thinks_more_lanes_drop_top"};
    pairs[ 1] = '{16'h007F, 16'h00FF, "we_think_more_lanes_drop_top"};
    pairs[ 2] = '{16'h00FF, 16'h00FB, "peer_drops_middle_we_dont"};
    pairs[ 3] = '{16'h00FB, 16'h00FF, "we_drop_middle_peer_doesnt"};
    pairs[ 4] = '{16'h007F, 16'h00FB, "both_reduced_disagree_which_lane"};
    pairs[ 5] = '{16'h000F, 16'h00F0, "opposite_halves"};
    pairs[ 6] = '{16'h0001, 16'h00FF, "peer_minimum_we_full"};
    pairs[ 7] = '{16'h00FF, 16'h0001, "we_minimum_peer_full"};
    pairs[ 8] = '{16'h0001, 16'h0080, "single_lane_disagree"};
    pairs[ 9] = '{16'h006E, 16'h00B7, "non_contig_disagree"};
    pairs[10] = '{16'h003F, 16'h007F, "off_by_one_top"};
    pairs[11] = '{16'h00FE, 16'h00FF, "off_by_one_bottom"};
    pairs[12] = '{16'h00C3, 16'h003C, "complementary_drops"};
    pairs[13] = '{16'h00FF, 16'h0000, "peer_dead"};
    pairs[14] = '{16'h0055, 16'h00AA, "alternating_disagree"};
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

  // Clear W1C interrupt bits before an iteration so we observe only this
  // iteration's errors.
  virtual task clear_link_interrupts(side_t side);
    write_cfg_reg_raw(side, WLINK_LINK_INTERRUPTS, 32'h0001_0101);
  endtask

  virtual task main_phase(uvm_phase phase);
    int        fd;
    string     csv_path = "lane_mask_mismatch.csv";
    int        i;
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];
    bit [31:0] a_int, b_int, a_status, b_status;
    bit        rx_clean;
    int        sb_a2b_errors_before, sb_a2b_errors_after;

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Lane-mask mismatch diagnostic sweep ===", UVM_LOW)

    // Start with default mask, link up.
    init_system_with_lane_mask();

    // Open CSV report
    fd = $fopen(csv_path, "w");
    if (fd == 0)
      `uvm_fatal("TEST", $sformatf("Could not open %s for writing", csv_path))
    $fwrite(fd,
      "label,a_mask,b_mask,a_int_post,b_int_post,a_status_post,b_status_post,rx_clean,rx_size\n");

    for (i = 0; i < pairs.size(); i++) begin
      `uvm_info("TEST", $sformatf(
        "[%0d/%0d] %s: A=0x%04h B=0x%04h",
        i + 1, pairs.size(), pairs[i].label, pairs[i].a_mask, pairs[i].b_mask),
        UVM_LOW)

      disable_ll_both();
      // Apply mismatched masks (symmetric within each side: tx = rx)
      write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK,
                         {pairs[i].a_mask, pairs[i].a_mask});
      write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK,
                         {pairs[i].b_mask, pairs[i].b_mask});
      clear_link_interrupts(SIDE_A);
      clear_link_interrupts(SIDE_B);
      enable_ll_both();

      // Try to send a probe packet
      pkt_data = new[2];
      pkt_data[0] = 32'hABCD_0000 | i;
      pkt_data[1] = 32'h1234_0000 | i;
      rx_clean = 1'b0;
      read_data = new[0];

      fork
        begin
          write_packet(SIDE_A, pkt_data);
          repeat (phy_transit_wait) @(posedge tb_if.clk);
          read_packet(SIDE_B, 2, read_data);
          if (read_data.size() == 2 && read_data[0] == pkt_data[0]
              && read_data[1] == pkt_data[1]) begin
            rx_clean = 1'b1;
          end
        end
        begin
          // Bound the iteration regardless of outcome
          repeat (phy_transit_wait * 4) @(posedge tb_if.clk);
        end
      join_any
      disable fork;

      // Sample status after the probe
      read_cfg_reg_raw(SIDE_A, WLINK_LINK_INTERRUPTS, a_int);
      read_cfg_reg_raw(SIDE_B, WLINK_LINK_INTERRUPTS, b_int);
      read_cfg_reg_raw(SIDE_A, WLINK_LINK_STATUS,     a_status);
      read_cfg_reg_raw(SIDE_B, WLINK_LINK_STATUS,     b_status);

      $fwrite(fd, "%s,0x%04h,0x%04h,0x%08h,0x%08h,0x%08h,0x%08h,%0d,%0d\n",
        pairs[i].label, pairs[i].a_mask, pairs[i].b_mask,
        a_int, b_int, a_status, b_status, rx_clean, read_data.size());

      `uvm_info("TEST", $sformatf(
        "  result: rx_clean=%0d rx_size=%0d a_int=0x%08h b_int=0x%08h",
        rx_clean, read_data.size(), a_int, b_int), UVM_LOW)
    end

    $fclose(fd);
    `uvm_info("TEST", $sformatf("Sweep complete. Report at %s", csv_path), UVM_LOW)

    // Restore default mask before phase end so other tests in the same
    // run start from a sane state.
    disable_ll_both();
    write_cfg_reg_raw(SIDE_A, WLINK_LANE_MASK, {16'h00FF, 16'h00FF});
    write_cfg_reg_raw(SIDE_B, WLINK_LANE_MASK, {16'h00FF, 16'h00FF});
    enable_ll_both();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_MISMATCH_SWEEP_SV
