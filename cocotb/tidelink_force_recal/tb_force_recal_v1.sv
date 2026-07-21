// =============================================================================
// tb_force_recal_v1.sv — cocotb wrapper around the V1 calibrator
// (src/rtl/tidelink_phy_align_calibrator.sv), i.e. the copy that
// flists/tidelink_fpga.flist and flists/tidelink_top_full_asic.flist build.
//
// The V1 calibrator carries the IDENTICAL calibrated_once_q sticky as the V2
// deps copy, so the P1 FORCED-RECAL W1P was applied to BOTH. This wrapper lets
// the SAME cocotb tests (test_force_recal.py) gate the V1 trunk/ASIC path.
//
// Port-list deltas vs the V2 wrapper: V1 has dwell_min_dist_i / crack_pkt_seen_i
// / resweep_ctr_o / the v2 eye-ctrl surface and LACKS lane_mask / sync_seen_i /
// lane_synced_i / swi_training_hold_i / lane_pin_converge_en_i. The cocotb-facing
// port list is kept IDENTICAL to tb_force_recal_v2 so the tests bind unchanged.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_force_recal_v1 #(
    parameter int DWELL_CYCLES         = 8,
    parameter int LOCK_THRESH          = 2,
    parameter int HOLD_CYCLES          = 64,
    parameter int VALIDATION_TIMEOUT   = 256,
    parameter int MIN_LOCK_DWELLS      = 2,
    parameter int MAX_RESWEEPS         = 0,
    parameter int MAX_VALIDATE_RETRIES = 2
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        role_locked,
    input  wire        swreset,
    input  wire        force_recal_i,     // P1 — the port under test
    input  wire [7:0]  lane_locked,

    input  wire [23:0] apb_bit_slip_override,
    input  wire        apb_override_enable,
    input  wire [3:0]  min_lock_dwells_i,

    input  wire        cr_pkt_seen_i,
    input  wire        crack_pkt_seen_i,

    output wire [23:0] bit_slip,
    output wire [31:0] phase_offset,
    output wire        training_mode,
    output wire        calibration_done,
    output wire        validation_timed_out,
    output wire [7:0]  lane_fault,
    output wire [3:0]  state
);

    // Unused by the current scoring path (binary lane_locked); 0 = "all lanes
    // distance-pass" so it is never the limiting factor.
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
        .MAX_VALIDATE_RETRIES    (MAX_VALIDATE_RETRIES),
        .CLK_MHZ                 (250),
        .EYE_BUF_WIDE            (0)
    ) u_dut (
        .clk                  (clk),
        .rst                  (rst),
        .role_locked          (role_locked),
        .swreset              (swreset),
        .lane_locked          (lane_locked),
        .dwell_min_dist_i     (dwell_min_dist_i),
        .apb_bit_slip_override(apb_bit_slip_override),
        .apb_override_enable  (apb_override_enable),
        .min_lock_dwells_i    (min_lock_dwells_i),
        .cr_pkt_seen_i        (cr_pkt_seen_i),
        .crack_pkt_seen_i     (crack_pkt_seen_i),
        // P1 — the port under test.
        .force_recal_i        (force_recal_i),
        .bit_slip             (bit_slip),
        .phase_offset         (phase_offset),
        .training_mode        (training_mode),
        .calibration_done     (calibration_done),
        .validation_timed_out (validation_timed_out),
        .lane_fault           (lane_fault),
        .state                (state),
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
