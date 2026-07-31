// =============================================================================
// tb_fixe.sv — unit wrapper around the DEPLOYED FPGA calibrator override
//   src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv
//
// PURPOSE: reproduce the I1 / FIX-E training-hold self-deadlock in simulation.
//
//   The S_HOLD(6) -> S_VALIDATE(9) transition is gated at
//   tidelink_phy_align_calibrator_v2.sv:1499 on
//       (hold_ctr >= HOLD_MAX) && !swi_training_mode_r
//   i.e. on the hold-timer AND on the SW training-hold being RELEASED — NOT on
//   cr_seen or full lane lock.  A bring-up recipe that holds SWI_TRAINING_MODE=1
//   while polling cal_done therefore self-deadlocks: the die parks in S_HOLD
//   forever (state=6, cal_done=0), because S_HOLD->S_VALIDATE->S_DONE (which
//   sets cal_done) can only fire once training is released.  This wrapper makes
//   swi_training_hold_i a top-level drivable port so the cocotb test can model
//   the training hold (deadlock) and its release (recovery).
//
// This is a UNIT tb: it compiles ONLY the calibrator (self-contained module,
// no submodules / no vendor IP) with SHRUNK dwell/hold/validation timers so a
// full S_ARM..S_HOLD..S_VALIDATE..S_DONE traversal completes in a few hundred
// cycles instead of the ~10 ms silicon HOLD.  Timer MAGNITUDES only are changed
// via #() — every FSM arm, and the :1499 gate, is exercised verbatim.
//
// The calibrator override is DEPS-independent: it is the exact RTL that
// flists/tidelink_fpga_v2.flist builds for the KR260 / Z2 FPGA images.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fixe #(
    // Shrunk timers — behaviour-preserving (magnitude only).
    parameter int DWELL_CYCLES       = 8,
    parameter int LOCK_THRESH        = 2,
    parameter int HOLD_CYCLES        = 64,   // HOLD_MAX = 63
    parameter int VALIDATION_TIMEOUT = 128,
    // VAL_TIMEOUT_TO_DONE=1 is part of FIX-E: once training is released and the
    // FSM reaches S_VALIDATE, a val-timeout (MAX_RESWEEPS==0) latches S_DONE
    // instead of thrashing.  The test ALSO drives cr_pkt_seen_i=1 on release
    // (modelling "cr_seen goes 0->1 the instant the link enters data mode"),
    // giving a fast validate_confirm path; VAL_TIMEOUT_TO_DONE is the belt-and-
    // braces terminal.
    parameter bit VAL_TIMEOUT_TO_DONE = 1'b1
)(
    input  wire        clk,
    input  wire        rst,

    // Bring-up sequencing
    input  wire        role_locked,
    input  wire        swreset,
    input  wire [7:0]  lane_locked,

    // FIX-E control-plane knobs (the whole point of this tb)
    input  wire        swi_training_hold_i,   // SWI_TRAINING_MODE (CTRL[6])
    input  wire        cr_pkt_seen_i,         // real-data validation oracle

    // Observability
    output wire        training_mode,
    output wire        calibration_done,
    output wire        validation_timed_out,
    output wire [7:0]  lane_fault,
    output wire [3:0]  state,
    output wire        cal_in_hold_o
);

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES            (DWELL_CYCLES),
        .LOCK_THRESH             (LOCK_THRESH),
        .NUM_LANES               (8),
        .MAX_RESWEEPS            (0),
        .MIN_LOCK_DWELLS         (2),
        .USE_SYNC_VALIDATE       (1'b0),
        .HOLD_CYCLES             (HOLD_CYCLES),
        .EARLY_EXIT_ON_ALL_LOCKED(1'b0),
        .VALIDATION_TIMEOUT      (VALIDATION_TIMEOUT),
        .VAL_TIMEOUT_TO_DONE     (VAL_TIMEOUT_TO_DONE),
        .LANE_PIN_CONVERGE       (1'b0),
        .PRBS_EYESCAN            (1'b0),
        .EYESCAN_DWELL           (64)
    ) u_dut (
        .clk                   (clk),
        .rst                   (rst),
        .role_locked           (role_locked),
        .swreset               (swreset),
        .lane_locked           (lane_locked),
        .lane_mask             (8'hFF),                // all lanes active
        .apb_bit_slip_override (24'd0),
        .apb_override_enable   (1'b0),
        .min_lock_dwells_i     (4'd0),                 // probe path (centering off)
        .swi_training_hold_i   (swi_training_hold_i),  // <-- FIX-E gate input
        .cr_pkt_seen_i         (cr_pkt_seen_i),        // <-- S_VALIDATE oracle
        .sync_seen_i           (1'b0),
        .lane_synced_i         (8'h00),
        .lane_pin_converge_en_i(1'b0),
        .force_recal_i         (1'b0),                 // pre-P1 tie
        .bit_slip              (/* unused */),
        .phase_offset          (/* unused */),
        .training_mode         (training_mode),
        .calibration_done      (calibration_done),
        .validation_timed_out  (validation_timed_out),
        .lane_fault            (lane_fault),
        .state                 (state),
        .sweep_active_o        (/* unused */),
        .eye_lane_sel          (3'd0),
        .eye_score_best        (/* unused */),
        .eye_score_best_phase  (/* unused */),
        .eye_score_best_slip   (/* unused */),
        .eye_score_lane_passed (/* unused */),
        .cal_in_hold_o         (cal_in_hold_o)
    );

endmodule

`default_nettype wire
