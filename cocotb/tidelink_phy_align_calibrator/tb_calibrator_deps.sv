// =============================================================================
// tb_calibrator_deps.sv — cocotb wrapper around the DEPLOYED (deps/) calibrator.
//
// The unit env historically compiled src/rtl/tidelink_phy_align_calibrator.sv
// (the eye-centre REFERENCE). After porting eye-centre selection INTO the
// deployed deps/tidelink-phy calibrator (2026-06-17), this wrapper lets the
// SAME cocotb tests gate the ACTUALLY-DEPLOYED RTL.
//
// The deps calibrator has a different (FIX-series) port list than src/: it adds
// lane_mask / sync_seen_i / lane_synced_i / swi_training_hold_i /
// lane_pin_converge_en_i and DROPS dwell_min_dist_i / crack_pkt_seen_i /
// resweep_ctr_o / the v2 eye-ctrl ports. This wrapper exposes the SAME cocotb-
// facing port list as tb_calibrator.sv (so test_calibrator*.py bind unchanged)
// and maps it onto the deps ports, tying the FIX-series opt-in inputs to their
// safe defaults (lane_mask=0xFF all-active, sync/pin features off). The cocotb
// validation oracle cr_pkt_seen_i is OR-merged with crack here exactly as the
// deps integration does it (cr | crack), so a TB that drives crack still
// confirms S_VALIDATE.
//
// Parameter overrides shrink the dwell/hold/validation timers so the FSM
// exercises every state arm in a few thousand cycles (RTL behaviour unchanged).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_calibrator_deps #(
    parameter int DWELL_CYCLES       = 16,
    parameter int LOCK_THRESH        = 8,
    parameter int HOLD_CYCLES        = 64,
    parameter int VALIDATION_TIMEOUT   = 256,
    parameter int MIN_LOCK_DWELLS      = 4,
    parameter int MAX_RESWEEPS         = 0,
    parameter int MAX_VALIDATE_RETRIES = 2   // unused by deps; kept for TB-arg parity
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

    // MAX_VALIDATE_RETRIES is a src-only knob; reference it so lint does not
    // flag the parameter as unused under the deps build.
    /* verilator lint_off UNUSEDPARAM */
    localparam int _unused_mvr = MAX_VALIDATE_RETRIES;
    /* verilator lint_on UNUSEDPARAM */

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES            (DWELL_CYCLES),
        .LOCK_THRESH             (LOCK_THRESH),
        .NUM_LANES               (8),
        .MAX_RESWEEPS            (MAX_RESWEEPS),
        .MIN_LOCK_DWELLS         (MIN_LOCK_DWELLS),
        .HOLD_CYCLES             (HOLD_CYCLES),
        .EARLY_EXIT_ON_ALL_LOCKED(1'b0),
        .VALIDATION_TIMEOUT      (VALIDATION_TIMEOUT),
        // The deps calibrator has no src-side M9 MAX_VALIDATE_RETRIES knob; its
        // equivalent timeout-terminal is VAL_TIMEOUT_TO_DONE (the M8 port). With
        // MAX_RESWEEPS==0 (the bring-up/HW default) enabling it converts the
        // infinite S_VALIDATE↔S_ARM re-arm into a clean S_DONE that sets
        // validation_timed_out — the behaviour test_validate_timeout_without_lock
        // checks. (Validation never short-circuits link_up, which still gates on
        // real PRBS sync.)
        .VAL_TIMEOUT_TO_DONE     (1'b1)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        // FIX-series opt-in inputs tied to their safe defaults: all lanes
        // active, SYNC/pin-converge features OFF (== bit-identical to the
        // pre-FIX behaviour exercised by these legacy tests).
        .lane_mask              (8'hFF),
        .apb_bit_slip_override  (apb_bit_slip_override),
        .apb_override_enable    (apb_override_enable),
        .min_lock_dwells_i      (min_lock_dwells_i),
        .swi_training_hold_i    (1'b0),
        // Same oracle merge as the deps integration: cr OR crack confirms.
        .cr_pkt_seen_i          (cr_pkt_seen_i | crack_pkt_seen_i),
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
        .sweep_active_o         (/* unused */),
        // EYE-WIDTH VISIBILITY ports — drive sel=0, leave reads unconnected.
        .eye_lane_sel           (3'd0),
        .eye_score_best         (/* unused */),
        .eye_score_best_phase   (/* unused */),
        .eye_score_best_slip    (/* unused */),
        .eye_score_lane_passed  (/* unused */)
    );

endmodule

`default_nettype wire
