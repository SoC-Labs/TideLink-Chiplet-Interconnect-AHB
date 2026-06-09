// =============================================================================
// tb_calibrator.sv — thin cocotb wrapper around tidelink_phy_align_calibrator.
//
// The DUT has a large flat port list and no packed-vector-clock issues, so
// cocotb could in principle drive it directly. The reason for this wrapper is
// PARAMETER OVERRIDE: the silicon defaults DWELL_CYCLES=64, HOLD_CYCLES=
// 8*128*64 (=65536) and VALIDATION_TIMEOUT=2_000_000 make a full
// S_PROBE->S_SWEEP->S_FINALIZE->S_HOLD->S_VALIDATE traversal take tens of
// millions of cycles — far too slow for a unit test. Here we shrink those
// three to small values via #() so the FSM exercises every state arm in a
// few thousand cycles, WITHOUT touching the RTL's behaviour (only the
// magnitudes of the dwell / hold / validation timers).
//
// All other ports are passed straight through. Unused observability ports
// (eye_*) are tied off. Pure structural — faithful to the DUT.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_calibrator #(
    parameter int DWELL_CYCLES       = 16,
    parameter int LOCK_THRESH        = 8,
    parameter int HOLD_CYCLES        = 64,
    parameter int VALIDATION_TIMEOUT = 256,
    parameter int MIN_LOCK_DWELLS    = 4,
    parameter int MAX_RESWEEPS       = 0
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

    output wire [23:0] bit_slip,
    output wire [31:0] phase_offset,
    output wire        training_mode,
    output wire        calibration_done,
    output wire        validation_timed_out,
    output wire [7:0]  lane_fault,
    output wire [3:0]  state
);

    // dwell_min_dist_i is unused by the current scoring path (reverted to
    // binary lane_locked); tie to 0 (= "all lanes distance-pass") so it is
    // never the limiting factor.
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
