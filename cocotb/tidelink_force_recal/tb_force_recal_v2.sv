// =============================================================================
// tb_force_recal_v2.sv — cocotb wrapper around the V2 calibrator override
// (src/rtl/local_overrides/tidelink_phy_align_calibrator_v2.sv), i.e. the copy
// that flists/tidelink_fpga_v2.flist and flists/tidelink_top_full_asic_v2.flist
// actually build — the FPGA image AND the tapeout path.
//
// Exists to gate the P1 FORCED-RECAL W1P (2026-07-19, lane B1): it exposes
// force_recal_i as a DRIVABLE port alongside swreset / role_locked, so one
// testbench can drive all three trigger paths and compare them:
//
//   * swreset (== SWI_RECAL)  — must stay a NO-OP after first lock (Bug-A guard)
//   * role_locked re-pulse    — must stay a NO-OP after first lock (Bug-A guard)
//   * force_recal_i (NEW)     — must re-arm the sweep exactly once
//
// Parameter overrides shrink the dwell/hold/validation timers so a full
// converge → S_DONE → forced-recal → re-converge cycle runs in a few thousand
// cycles instead of millions. RTL behaviour is unchanged (magnitudes only).
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_force_recal_v2 #(
    parameter int DWELL_CYCLES       = 8,
    parameter int LOCK_THRESH        = 2,
    parameter int HOLD_CYCLES        = 64,
    parameter int VALIDATION_TIMEOUT = 256,
    parameter int MIN_LOCK_DWELLS    = 2,
    parameter int MAX_RESWEEPS       = 0
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

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES            (DWELL_CYCLES),
        .LOCK_THRESH             (LOCK_THRESH),
        .NUM_LANES               (8),
        .MAX_RESWEEPS            (MAX_RESWEEPS),
        .MIN_LOCK_DWELLS         (MIN_LOCK_DWELLS),
        .HOLD_CYCLES             (HOLD_CYCLES),
        .EARLY_EXIT_ON_ALL_LOCKED(1'b0),
        .VALIDATION_TIMEOUT      (VALIDATION_TIMEOUT),
        // Matches the acc's V2 instantiation (VAL_TIMEOUT_TO_DONE=1'b1) so the
        // unit env mirrors the deployed configuration.
        .VAL_TIMEOUT_TO_DONE     (1'b1)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        // FIX-series opt-in inputs at their safe defaults, exactly as
        // tb_calibrator_deps.sv ties them.
        .lane_mask              (8'hFF),
        .apb_bit_slip_override  (apb_bit_slip_override),
        .apb_override_enable    (apb_override_enable),
        .min_lock_dwells_i      (min_lock_dwells_i),
        .swi_training_hold_i    (1'b0),
        // Same oracle merge as the deps/acc integration: cr OR crack confirms.
        .cr_pkt_seen_i          (cr_pkt_seen_i | crack_pkt_seen_i),
        .sync_seen_i            (1'b0),
        .lane_synced_i          (8'h00),
        .lane_pin_converge_en_i (1'b0),
        // P1 — the port under test.
        .force_recal_i          (force_recal_i),
        .bit_slip               (bit_slip),
        .phase_offset           (phase_offset),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .validation_timed_out   (validation_timed_out),
        .lane_fault             (lane_fault),
        .state                  (state),
        .sweep_active_o         (/* unused */),
        .eye_lane_sel           (3'd0),
        .eye_score_best         (/* unused */),
        .eye_score_best_phase   (/* unused */),
        .eye_score_best_slip    (/* unused */),
        .eye_score_lane_passed  (/* unused */)
    );

endmodule

`default_nettype wire
