///////////////////////////////////////////////////////////////////////////////
// test_top_align_base.sv — Base class for §9 per-lane bit-slip alignment tests
///////////////////////////////////////////////////////////////////////////////
// Provides helpers that:
//   - Configure the per-lane skid (TX-side misalignment) on each direction
//     via tb_if.{a2b,b2a}_skid_bits_per_lane.
//   - Drive WavD2DGpio's swi_bit_slip / swi_training_mode registers on each
//     DUT by hierarchical reference (no APB plumbing yet — matches the
//     cocotb wlink_pair `test_pair_align.py` approach).
//   - Sweep slip 0..7 per lane and identify the value that locks the
//     in-band wlink_lane_checker on each side.
//   - Toggle the per-side resets so the deserialiser flushes after exiting
//     training mode.
//
// Hierarchy paths used (mirrors cocotb test_pair_align.py):
//   test_top.u_tidelink_top_<a|b>.u_chiplet_controller.u_wlink.phy.gpio
//     - swi_bit_slip[23:0]      24-bit packed, lane N = bits[3N+2:3N]
//     - swi_training_mode       1-bit, both serialiser + checker enable
//
// The lane-lock observables come from tb_if.{a,b}_lane_locked (driven by
// in-band wlink_lane_checker instances in top.sv).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_ALIGN_BASE_SV
`define GUARD_TEST_TOP_ALIGN_BASE_SV

class test_top_align_base extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_align_base)

  // Cycles to wait at each slip candidate before reading lane_locked.
  // 400 matches the cocotb baseline; with the GPIO PHY ~8x faster than
  // the 1-lane case, 400 sys clocks is plenty for the 16-match threshold.
  int unsigned settle_cycles = 400;

  // Cycles to hold reset during the post-training swreset toggle.
  int unsigned swreset_cycles = 200;

  // The per-side calibrated slip values, populated by calibrate_both().
  bit [2:0] a_slip[8];   // master(A)-RX slip — for B->A path
  bit [2:0] b_slip[8];   // slave(B)-RX  slip — for A->B path

  function new(string name = "test_top_align_base",
               uvm_component parent = null);
    super.new(name, parent);
    // Alignment tests need more time than vanilla single-packet runs because
    // of the per-lane slip sweep (8 lanes × 8 candidates × settle_cycles).
    test_timeout_cycles = 10_000_000;
  endfunction

  // ----------------------------------------------------------------------
  // Soft-strap drive via tb_if (always-block-driven force/release in
  // tb_top — see bottom of top.sv). The package cannot reach hierarchical
  // refs directly, and uvm_hdl_force is unreliable on the GPIO's
  // constant-default regs, so we proxy through the interface.
  // ----------------------------------------------------------------------

  // Set the entire 24-bit packed swi_bit_slip on side A or B.
  task set_slip_packed(side_t side, bit [23:0] packed_slip);
    if (side == SIDE_A) begin
      tb_if.a_align_bit_slip    = packed_slip;
      tb_if.a_align_bit_slip_en = 1'b1;
    end else begin
      tb_if.b_align_bit_slip    = packed_slip;
      tb_if.b_align_bit_slip_en = 1'b1;
    end
  endtask

  task get_slip_packed(side_t side, output bit [23:0] packed_slip);
    if (side == SIDE_A) packed_slip = tb_if.a_align_bit_slip;
    else                packed_slip = tb_if.b_align_bit_slip;
  endtask

  // Set a single lane's 3-bit slip on side A or B (read-modify-write).
  task set_lane_slip(side_t side, int lane, bit [2:0] slip);
    bit [23:0] cur;
    bit [23:0] mask;
    get_slip_packed(side, cur);
    mask = 24'h7 << (3 * lane);
    cur = (cur & ~mask) | ({21'b0, slip} << (3 * lane));
    set_slip_packed(side, cur);
  endtask

  task set_all_slip(side_t side, bit [2:0] slip);
    bit [23:0] packed_slip = '0;
    for (int i = 0; i < 8; i++)
      packed_slip |= ({21'b0, slip} << (3 * i));
    set_slip_packed(side, packed_slip);
  endtask

  task set_per_lane_slip(side_t side, bit [2:0] slips[8]);
    bit [23:0] packed_slip = '0;
    for (int i = 0; i < 8; i++)
      packed_slip |= ({21'b0, slips[i]} << (3 * i));
    set_slip_packed(side, packed_slip);
  endtask

  task set_training_mode(side_t side, bit on);
    if (side == SIDE_A) begin
      tb_if.a_align_training_mode    = on;
      tb_if.a_align_training_mode_en = 1'b1;
    end else begin
      tb_if.b_align_training_mode    = on;
      tb_if.b_align_training_mode_en = 1'b1;
    end
  endtask

  // Read lane_locked observable for the given side.
  function bit [7:0] read_lane_locked(side_t side);
    if (side == SIDE_A) return tb_if.a_lane_locked;
    else                return tb_if.b_lane_locked;
  endfunction

  // ----------------------------------------------------------------------
  // Skid injection helpers (writes the virtual interface).
  // ----------------------------------------------------------------------
  task apply_skid_a2b(bit [2:0] skids[8]);
    for (int i = 0; i < 8; i++) tb_if.a2b_skid_bits_per_lane[i] = skids[i];
  endtask

  task apply_skid_b2a(bit [2:0] skids[8]);
    for (int i = 0; i < 8; i++) tb_if.b2a_skid_bits_per_lane[i] = skids[i];
  endtask

  task apply_skid_both(bit [2:0] skids[8]);
    apply_skid_a2b(skids);
    apply_skid_b2a(skids);
  endtask

  // ----------------------------------------------------------------------
  // Calibration — sweep slip 0..7 on each lane independently, return the
  // first value that locks. Updates a_slip[] / b_slip[].
  // ----------------------------------------------------------------------
  task calibrate_lane(side_t side, int lane, output bit found, output bit [2:0] result);
    bit [7:0] locked;
    found = 1'b0;
    result = 3'd0;
    for (int s = 0; s < 8; s++) begin
      set_lane_slip(side, lane, s[2:0]);
      repeat (settle_cycles) @(posedge tb_if.clk);
      locked = read_lane_locked(side);
      if (locked[lane]) begin
        result = s[2:0];
        found  = 1'b1;
        return;
      end
    end
  endtask

  // Calibrate both sides, all 8 lanes. Returns count of lanes that locked.
  task calibrate_both(output int unsigned a_locked_count,
                       output int unsigned b_locked_count);
    bit       a_ok, b_ok;
    bit [2:0] a_r,  b_r;
    a_locked_count = 0;
    b_locked_count = 0;
    for (int lane = 0; lane < 8; lane++) begin
      calibrate_lane(SIDE_B, lane, b_ok, b_r);
      calibrate_lane(SIDE_A, lane, a_ok, a_r);
      a_slip[lane] = a_r;
      b_slip[lane] = b_r;
      if (a_ok) a_locked_count++;
      if (b_ok) b_locked_count++;
      `uvm_info("ALIGN", $sformatf(
        "  lane %0d: B(A->B)=%s%0d  A(B->A)=%s%0d",
        lane, b_ok ? "" : "MISS-", b_r, a_ok ? "" : "MISS-", a_r), UVM_MEDIUM)
    end
  endtask

  // Pulse poresetn + rst_n via the existing tb_if.force_* hooks (driven by
  // always-blocks in tb_top — see the bottom of top.sv). This lets the
  // deserialiser pipelines flush after dropping training_mode.
  task toggle_swreset();
    tb_if.force_poreset = 1'b1;
    tb_if.force_reset   = 1'b1;
    repeat (swreset_cycles) @(posedge tb_if.clk);
    tb_if.force_poreset = 1'b0;
    repeat (2) @(posedge tb_if.clk);
    tb_if.force_reset   = 1'b0;
    repeat (50) @(posedge tb_if.clk);
  endtask

  // ----------------------------------------------------------------------
  // High-level bring-up sequence used by the §9 alignment tests:
  //   1. Apply skid pattern (caller-provided) to the a2b / b2a paths.
  //   2. Enable training_mode + zero slip on both sides BEFORE link-up.
  //   3. Bring up Wlink (init_wlink) — the training pattern carries.
  //   4. Sweep slip per lane, latch calibrated values.
  //   5. Disable training_mode, toggle swreset, restart Wlink + TideLink.
  // ----------------------------------------------------------------------
  task align_and_init_system(bit [2:0] a2b_skids[8], bit [2:0] b2a_skids[8]);
    int unsigned a_locked_count, b_locked_count;

    `uvm_info("ALIGN", "Applying per-lane skid + training pattern", UVM_LOW)
    apply_skid_a2b(a2b_skids);
    apply_skid_b2a(b2a_skids);

    set_training_mode(SIDE_A, 1'b1);
    set_training_mode(SIDE_B, 1'b1);
    set_all_slip     (SIDE_A, 3'd0);
    set_all_slip     (SIDE_B, 3'd0);

    // Bring up Wlink so the link-clock starts and training data flows.
    init_wlink();
    repeat (500) @(posedge tb_if.clk);

    `uvm_info("ALIGN", $sformatf(
      "Pre-calibration: A.lane_locked=0x%02h  B.lane_locked=0x%02h",
      tb_if.a_lane_locked, tb_if.b_lane_locked), UVM_LOW)

    calibrate_both(a_locked_count, b_locked_count);

    `uvm_info("ALIGN", $sformatf(
      "Post-calibration: A.lane_locked=0x%02h (%0d lanes)  B.lane_locked=0x%02h (%0d lanes)",
      tb_if.a_lane_locked, a_locked_count,
      tb_if.b_lane_locked, b_locked_count), UVM_LOW)

    // Exit training mode and bring up the live link. swi_bit_slip is
    // sim-only soft-strap that persists across the swreset (it is not
    // gated by POR — same as in the cocotb sandbox).
    set_training_mode(SIDE_A, 1'b0);
    set_training_mode(SIDE_B, 1'b0);
    toggle_swreset();

    init_system();
  endtask

endclass

`endif // GUARD_TEST_TOP_ALIGN_BASE_SV
