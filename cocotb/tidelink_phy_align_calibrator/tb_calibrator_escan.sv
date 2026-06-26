// =============================================================================
// tb_calibrator_escan.sv — eyescan-engaged wrapper around
// tidelink_phy_align_calibrator for the FIX-CENTER run-centring unit test.
//
// The base tb_calibrator.sv does NOT expose the FIX-J/L eyescan ports
// (lane_mask, lane_synced_i, lane_pin_converge_en_i, sync_seen_i,
// swi_training_hold_i) and does not set PRBS_EYESCAN, so it can never engage
// escan_en. This wrapper:
//   * sets PRBS_EYESCAN=1 (so escan_en = pin_converge_en & PRBS_EYESCAN),
//   * exposes lane_synced_i + lane_pin_converge_en_i + lane_mask as drivable
//     ports so a test can model a multi-phase synced window and observe the
//     CENTRE pin, and
//   * shrinks EYESCAN_DWELL / MIN_PRBS_HOLD / HOLD_CYCLES / VALIDATION_TIMEOUT
//     so a full S_PROBE->S_HOLD->S_VALIDATE->eyescan traversal runs in a few
//     thousand cycles WITHOUT touching RTL behaviour (only timer magnitudes).
//
// Also surfaces pin_phase[0] / pin_slip[0] / lane_pinned via hierarchical
// observation in the test (u_dut.lane_pinned etc.) — they are internal to the
// DUT but +acc/-debug_access makes them readable.
//
// A joint work commissioned on behalf of SoC Labs, Arm Academic Access license.
// Contributors: David Mapstone (d.a.mapstone@soton.ac.uk)
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_calibrator_escan #(
    parameter int DWELL_CYCLES       = 8,
    parameter int LOCK_THRESH        = 4,
    parameter int HOLD_CYCLES        = 32,
    parameter int VALIDATION_TIMEOUT = 8192,
    parameter int MIN_LOCK_DWELLS    = 2,
    parameter int MAX_RESWEEPS       = 4,
    parameter int EYESCAN_DWELL      = 4,
    parameter int MIN_PRBS_HOLD      = 8
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        role_locked,
    input  wire        swreset,
    input  wire [7:0]  lane_locked,

    input  wire [23:0] apb_bit_slip_override,
    input  wire        apb_override_enable,
    input  wire [3:0]  min_lock_dwells_i,

    input  wire        cr_pkt_seen_i,
    input  wire        crack_pkt_seen_i,

    // FIX-J/L eyescan oracle inputs (the surface the engaged sim drives).
    input  wire [7:0]  lane_mask,
    input  wire [7:0]  lane_synced_i,
    input  wire        lane_pin_converge_en_i,
    input  wire        swi_training_hold_i,
    input  wire        sync_seen_i,

    output wire [23:0] bit_slip,
    output wire [31:0] phase_offset,
    output wire        training_mode,
    output wire        calibration_done,
    output wire        validation_timed_out,
    output wire [7:0]  lane_fault,
    output wire [3:0]  state
);

    wire [39:0] dwell_min_dist_i = 40'd0;

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES            (DWELL_CYCLES),
        .LOCK_THRESH             (LOCK_THRESH),
        .NUM_LANES               (8),
        .MAX_RESWEEPS            (MAX_RESWEEPS),
        .HOLD_CYCLES             (HOLD_CYCLES),
        .EARLY_EXIT_ON_ALL_LOCKED(1'b0),
        .MIN_LOCK_DWELLS         (MIN_LOCK_DWELLS),
        .VALIDATION_TIMEOUT      (VALIDATION_TIMEOUT),
        .MAX_VALIDATE_RETRIES    (2),
        .CLK_MHZ                 (250),
        .EYE_BUF_WIDE            (0),
        // Engage the FIX-J/L/CENTER eyescan: compile it in, gate it at runtime
        // with lane_pin_converge_en_i. VAL_TIMEOUT_TO_DONE=1 + MAX_RESWEEPS>0
        // mirrors the deployed instance (bounded terminal, never hangs).
        .USE_SYNC_VALIDATE       (1'b0),
        .VAL_TIMEOUT_TO_DONE     (1'b1),
        .LANE_PIN_CONVERGE       (1'b0),
        .PRBS_EYESCAN            (1'b1),
        .EYESCAN_DWELL           (EYESCAN_DWELL),
        .MIN_PRBS_HOLD           (MIN_PRBS_HOLD)
    ) u_dut (
        .clk                  (clk),
        .rst                  (rst),
        .role_locked          (role_locked),
        .swreset              (swreset),
        .lane_locked          (lane_locked),
        .lane_mask            (lane_mask),
        .dwell_min_dist_i     (dwell_min_dist_i),
        .apb_bit_slip_override(apb_bit_slip_override),
        .apb_override_enable  (apb_override_enable),
        .min_lock_dwells_i    (min_lock_dwells_i),
        .cr_pkt_seen_i        (cr_pkt_seen_i),
        .crack_pkt_seen_i     (crack_pkt_seen_i),
        .swi_training_hold_i  (swi_training_hold_i),
        .sync_seen_i          (sync_seen_i),
        .lane_synced_i        (lane_synced_i),
        .lane_pin_converge_en_i(lane_pin_converge_en_i),
        .bit_slip             (bit_slip),
        .phase_offset         (phase_offset),
        .training_mode        (training_mode),
        .calibration_done     (calibration_done),
        .validation_timed_out (validation_timed_out),
        .lane_fault           (lane_fault),
        .state                (state),
        .resweep_ctr_o        (/* unused */),
        .escan_min_hold_o     (/* unused */),
        .sweep_active_o       (/* unused */),
        .swi_eye_lane_sel     (3'd0),
        .swi_eye_dwell_us     (32'd0),
        .swi_eye_ctrl         (32'd0),
        .eye_status           (/* unused */),
        .eye_score_idx        (7'd0),
        .eye_score_data       (/* unused */),
        .eye_score_lane_passed(/* unused */),
        .eye_score_best       (/* unused */),
        .eye_score_best_slip  (/* unused */),
        .eye_score_best_phase (/* unused */)
    );

endmodule

`default_nettype wire
