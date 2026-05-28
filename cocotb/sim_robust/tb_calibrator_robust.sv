// =============================================================================
// tb_calibrator_robust.sv — standalone TB for sim_robust tests
// =============================================================================
//
// Wraps tidelink_phy_align_calibrator (this branch's signature: DWELL_CYCLES
// + NUM_LANES only) so the sim_robust suite can:
//
//   * Drive role_locked / swreset / lane_locked directly from cocotb
//   * Read out cur_state, lane_done, lane_fault_q via hierarchical refs
//   * Inject reset glitches and observe FSM behaviour
//   * Force internal signals (cur_state, lane_done[]) to silicon-failure
//     patterns and verify the calibrator's observable output fingerprint
//     matches what we have seen on the FPGA pair bring-up:
//       cal_done=0, lane_fault=0x00, training_mode stuck
//
// Small DWELL_CYCLES keeps each test under ~1 ms wall-clock.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_calibrator_robust #(
    parameter int DWELL_CYCLES = 8,
    parameter int NUM_LANES    = 8
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,
    output logic [23:0] bit_slip,
    output logic        training_mode,
    output logic        calibration_done,
    output logic [7:0]  lane_fault,
    output logic [3:0]  state
);

    // Synthesised dwell_min_dist from lane_locked (spec §7.1). No
    // lane_checker in this robustness TB; map locked→5'd0,
    // unlocked→5'd16 so the FSM's continuous-metric scoring path
    // reproduces the legacy binary-lane_locked semantics.
    logic [39:0] dwell_min_dist_synth;
    always_comb begin
        for (int li = 0; li < 8; li++)
            dwell_min_dist_synth[5*li +: 5] = lane_locked[li] ? 5'd0 : 5'd16;
    end

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES (DWELL_CYCLES),
        .NUM_LANES    (NUM_LANES)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        // Spec §7.1: synthesised from lane_locked (see declaration above).
        .dwell_min_dist_i       (dwell_min_dist_synth),
        .apb_bit_slip_override  (apb_bit_slip_override),
        .apb_override_enable    (apb_override_enable),
        .min_lock_dwells_i      (4'h0),
        .cr_pkt_seen_i          (1'b1),
        .bit_slip               (bit_slip),
        .phase_offset           (/* unconnected */),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .lane_fault             (lane_fault),
        .state                  (state),
        .sweep_active_o         (/* unconnected */),
        .swi_eye_lane_sel       (3'd0),
        .swi_eye_dwell_us       (32'd0),
        .swi_eye_ctrl           (32'd0),
        .eye_status             (/* unconnected */),
        .eye_score_idx          (7'd0),
        .eye_score_data         (/* unconnected */),
        .eye_score_lane_passed  (/* unconnected */),
        .eye_score_best         (/* unconnected */),
        .eye_score_best_slip    (/* unconnected */),
        .eye_score_best_phase   (/* unconnected */)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_calibrator_robust);
    end

endmodule

`default_nettype wire
