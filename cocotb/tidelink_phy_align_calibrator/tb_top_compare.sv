// =============================================================================
// tb_top.sv — standalone unit testbench for tidelink_phy_align_calibrator
// =============================================================================
//
// Drives the calibrator's primary inputs (clk/rst, role_locked, swreset,
// lane_locked[7:0]) directly from cocotb so we can paint arbitrary lock
// trajectories across the (slip,phase) sweep and observe which
// (slip,phase) the FSM latches per lane. Two instances are elaborated:
//
//   u_dut_best  — silicon default: EARLY_EXIT_ON_ALL_LOCKED = 1'b0
//                 (§9.9 best-of-sweep widest-eye latch)
//   u_dut_first — legacy compat:  EARLY_EXIT_ON_ALL_LOCKED = 1'b1
//                 (§9.7 first-match-wins behaviour)
//
// Both instances are fed THE SAME stimulus by the cocotb driver, so the
// difference in their latched (slip,phase) outputs is purely the
// selection policy. This lets a single test prove that best-of-sweep
// picks a different (better) (slip,phase) on an "eye-edge marginal"
// input pattern.
//
// DWELL_CYCLES is parameterised down so the full 128-point sweep
// completes in ~tens of microseconds of cocotb sim time. HOLD_CYCLES
// follows DWELL_CYCLES' formula automatically (8 * 128 * DWELL_CYCLES).
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================

`timescale 1ns/1ps

module tb_top #(
    // Match the silicon LOCK_THRESH (lane checker default 16). Both DUT
    // instances inherit this so their best-of-sweep gate matches what
    // would fire at silicon.
    parameter int LOCK_THRESH  = 16,
    // Shrink the dwell so the 128-point sweep completes quickly. The
    // selection-policy difference between best-of-sweep and first-match
    // is independent of DWELL_CYCLES so long as the marginal lock
    // duration is shorter than DWELL_CYCLES (i.e. doesn't reach the run-
    // length cap). 32 leaves plenty of room.
    parameter int DWELL_CYCLES = 32,
    // §9.11: lower than silicon default 4 so the test stimulus' 4-wide
    // contiguous phase run (slip=3, phase=4..7) promotes to best_run.
    // Set to 4 to mirror silicon default; the stimulus paints a 4-wide
    // eye explicitly.
    parameter int MIN_LOCK_DWELLS = 4
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        role_locked,
    input  wire        swreset,
    input  wire [7:0]  lane_locked,

    // Best-of-sweep DUT outputs
    output wire [23:0] best_bit_slip,
    output wire [31:0] best_phase_offset,
    output wire        best_training_mode,
    output wire        best_calibration_done,
    output wire [7:0]  best_lane_fault,
    output wire [3:0]  best_state,

    // First-match DUT outputs
    output wire [23:0] first_bit_slip,
    output wire [31:0] first_phase_offset,
    output wire        first_training_mode,
    output wire        first_calibration_done,
    output wire [7:0]  first_lane_fault,
    output wire [3:0]  first_state
);

    // Synthesised dwell_min_dist from lane_locked (spec §7.1). Both DUTs
    // share the same lane_locked stimulus, so they share the synthesised
    // metric.  locked → 5'd0 (best); unlocked → 5'd16 (worst).
    logic [39:0] dwell_min_dist_synth;
    always_comb begin
        for (int li = 0; li < 8; li++)
            dwell_min_dist_synth[5*li +: 5] = lane_locked[li] ? 5'd0 : 5'd16;
    end

    // -----------------------------------------------------------------------
    // Best-of-sweep DUT (silicon default — EARLY_EXIT_ON_ALL_LOCKED = 0)
    // -----------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES              (DWELL_CYCLES),
        .LOCK_THRESH               (LOCK_THRESH),
        .EARLY_EXIT_ON_ALL_LOCKED  (1'b0),
        .MIN_LOCK_DWELLS           (MIN_LOCK_DWELLS)
    ) u_dut_best (
        .clk                   (clk),
        .rst                   (rst),
        .role_locked           (role_locked),
        .swreset               (swreset),
        .lane_locked           (lane_locked),
        // Spec §7.1: synthesised from lane_locked (see header comment).
        .dwell_min_dist_i      (dwell_min_dist_synth),
        .apb_bit_slip_override (24'h0),
        .apb_override_enable   (1'b0),
        .min_lock_dwells_i     (4'h0),
        .cr_pkt_seen_i         (1'b1),    // §9.11d: tie HIGH to bypass S_VALIDATE in unit TB
        .bit_slip              (best_bit_slip),
        .phase_offset          (best_phase_offset),
        .training_mode         (best_training_mode),
        .calibration_done      (best_calibration_done),
        .lane_fault            (best_lane_fault),
        .state                 (best_state),
        .sweep_active_o        (/* unconnected */),
        // v2 eye-visibility — tie to safe defaults.
        .swi_eye_lane_sel      (3'd0),
        .swi_eye_dwell_us      (32'd0),
        .swi_eye_ctrl          (32'd0),
        .eye_status            (/* unconnected */),
        .eye_score_idx         (7'd0),
        .eye_score_data        (/* unconnected */),
        .eye_score_lane_passed (/* unconnected */),
        .eye_score_best        (/* unconnected */),
        .eye_score_best_slip   (/* unconnected */),
        .eye_score_best_phase  (/* unconnected */)
    );

    // -----------------------------------------------------------------------
    // First-match DUT (legacy §9.7 — EARLY_EXIT_ON_ALL_LOCKED = 1)
    // -----------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES              (DWELL_CYCLES),
        .LOCK_THRESH               (LOCK_THRESH),
        .EARLY_EXIT_ON_ALL_LOCKED  (1'b1)
    ) u_dut_first (
        .clk                   (clk),
        .rst                   (rst),
        .role_locked           (role_locked),
        .swreset               (swreset),
        .lane_locked           (lane_locked),
        // Spec §7.1: synthesised from lane_locked (see header comment).
        .dwell_min_dist_i      (dwell_min_dist_synth),
        .apb_bit_slip_override (24'h0),
        .apb_override_enable   (1'b0),
        .min_lock_dwells_i     (4'h0),
        .cr_pkt_seen_i         (1'b1),    // §9.11d: tie HIGH to bypass S_VALIDATE in unit TB
        .bit_slip              (first_bit_slip),
        .phase_offset          (first_phase_offset),
        .training_mode         (first_training_mode),
        .calibration_done      (first_calibration_done),
        .lane_fault            (first_lane_fault),
        .state                 (first_state),
        .sweep_active_o        (/* unconnected */),
        // v2 eye-visibility — tie to safe defaults.
        .swi_eye_lane_sel      (3'd0),
        .swi_eye_dwell_us      (32'd0),
        .swi_eye_ctrl          (32'd0),
        .eye_status            (/* unconnected */),
        .eye_score_idx         (7'd0),
        .eye_score_data        (/* unconnected */),
        .eye_score_lane_passed (/* unconnected */),
        .eye_score_best        (/* unconnected */),
        .eye_score_best_slip   (/* unconnected */),
        .eye_score_best_phase  (/* unconnected */)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
