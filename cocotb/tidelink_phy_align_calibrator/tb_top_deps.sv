// =============================================================================
// tb_top_deps.sv — standalone unit TB for the DEPLOYED (deps/) calibrator.
//
// Mirrors tb_top.sv exactly (same cocotb-facing port list, same instance name
// u_dut, same DWELL/HOLD/MIN_LOCK_DWELLS shrink knobs) but instantiates the
// deps/tidelink-phy calibrator instead of the src/ reference. After porting
// eye-centre selection into deps (2026-06-17), this lets test_calibrator_t3 /
// test_calibrator_s_probe_skip gate the ACTUALLY-DEPLOYED FSM.
//
// The deps FIX-series opt-in inputs (lane_mask / sync_seen_i / lane_synced_i /
// swi_training_hold_i / lane_pin_converge_en_i) are tied to their safe
// defaults (all lanes active, features OFF) so the FSM reduces to the same
// behaviour these tests were written for. The deps drops dwell_min_dist_i, so
// the synthesised distance metric is not needed here.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top_deps #(
    parameter int DWELL_CYCLES = 8,
    parameter int LOCK_THRESH  = 2,
    parameter int HOLD_CYCLES  = 2 * 128 * DWELL_CYCLES,
    parameter int MAX_RESWEEPS = 0,
    parameter int MIN_LOCK_DWELLS = 3
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,
    // FORCE-FULL-SWEEP CENTERING (2026-06-17): drivable so cocotb can A/B the
    // probe fast-path (=0) vs the centering full-sweep (!=0) on the deps FSM.
    // Existing tests leave this 0 (default reset value below) → bit-identical.
    input  logic [3:0]  min_lock_dwells_i,
    // Eye-width visibility — drivable lane select + observable run-tracker reads.
    input  logic [2:0]  eye_lane_sel,
    output logic [5:0]  eye_score_best,
    output logic [3:0]  eye_score_best_phase,
    output logic [2:0]  eye_score_best_slip,
    output logic        eye_score_lane_passed,
    output logic [23:0] bit_slip,
    output logic [31:0] phase_offset,
    output logic        training_mode,
    output logic        calibration_done,
    output logic        validation_timed_out,
    output logic [7:0]  lane_fault,
    output logic [3:0]  state
);

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES (DWELL_CYCLES),
        .LOCK_THRESH  (LOCK_THRESH),
        .HOLD_CYCLES  (HOLD_CYCLES),
        .MAX_RESWEEPS (MAX_RESWEEPS),
        .EARLY_EXIT_ON_ALL_LOCKED (1'b0),
        .MIN_LOCK_DWELLS          (MIN_LOCK_DWELLS)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        .lane_mask              (8'hFF),
        .apb_bit_slip_override  (apb_bit_slip_override),
        .apb_override_enable    (apb_override_enable),
        // Drivable from cocotb (reset 0 → use the synth-time MIN_LOCK_DWELLS
        // param default + S_PROBE fast-path; !=0 → centering full-sweep mode).
        .min_lock_dwells_i      (min_lock_dwells_i),
        .swi_training_hold_i    (1'b0),
        // Tie cr_pkt_seen_i HIGH so S_VALIDATE auto-passes (no FCSM here).
        .cr_pkt_seen_i          (1'b1),
        .sync_seen_i            (1'b0),
        .lane_synced_i          (8'h00),
        .lane_pin_converge_en_i (1'b0),
        .bit_slip               (bit_slip),
        .phase_offset           (phase_offset),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .validation_timed_out   (validation_timed_out),
        .lane_fault             (lane_fault),
        .state                  (state),
        .sweep_active_o         (/* unconnected */),
        .eye_lane_sel           (eye_lane_sel),
        .eye_score_best         (eye_score_best),
        .eye_score_best_phase   (eye_score_best_phase),
        .eye_score_best_slip    (eye_score_best_slip),
        .eye_score_lane_passed  (eye_score_lane_passed)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top_deps);
    end

endmodule

`default_nettype wire
