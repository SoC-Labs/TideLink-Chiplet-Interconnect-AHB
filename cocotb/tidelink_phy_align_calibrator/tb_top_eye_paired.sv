// =============================================================================
// tb_top_eye_paired.sv — TWO tidelink_phy_align_calibrator instances each
//                        wrapped with a tidelink_eye_regs shim. Used by
//                        test_eye_paired_entry to verify Mechanism α
//                        (paired-manual + dwell timer) — proposal §4.
// =============================================================================
//
// Both calibrators are identical, share a single clock and reset, and each
// has its own dedicated APB slave. The cocotb test issues ENTER on side A
// and side B within a small skew window (≤1 µs) and asserts that both
// reach STATE=DONE and that the two score buffers are populated
// independently (i.e. one die's capture does NOT bleed into the other).
//
// The two calibrators are NOT cross-wired — the proposal §4 expressly
// states that Mechanism α requires no link path between the dies. Each
// calibrator runs its own sweep against its own lane_locked stim from
// cocotb.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top #(
    parameter int DWELL_CYCLES = 8,
    parameter int LOCK_THRESH  = 2,
    parameter int HOLD_CYCLES  = 2 * 128 * DWELL_CYCLES,
    parameter int MAX_RESWEEPS = 0,
    parameter int CLK_MHZ      = 100,
    parameter logic EARLY_EXIT_ON_ALL_LOCKED = 1'b0
)(
    input  logic        clk,
    input  logic        rst,

    // Side A
    input  logic        a_role_locked,
    input  logic        a_swreset,
    input  logic [7:0]  a_lane_locked,
    input  logic        a_psel,
    input  logic        a_penable,
    input  logic        a_pwrite,
    input  logic [11:0] a_paddr,
    input  logic [31:0] a_pwdata,
    output logic [31:0] a_prdata,
    output logic        a_pready,
    output logic        a_pslverr,
    output logic [3:0]  a_state,
    output logic        a_calibration_done,

    // Side B
    input  logic        b_role_locked,
    input  logic        b_swreset,
    input  logic [7:0]  b_lane_locked,
    input  logic        b_psel,
    input  logic        b_penable,
    input  logic        b_pwrite,
    input  logic [11:0] b_paddr,
    input  logic [31:0] b_pwdata,
    output logic [31:0] b_prdata,
    output logic        b_pready,
    output logic        b_pslverr,
    output logic [3:0]  b_state,
    output logic        b_calibration_done
);

    // Per-side internal nets between eye_regs and calibrator
    `define EYE_BUNDLE(P) \
        logic [2:0]  P``_eye_lane_sel; \
        logic [31:0] P``_eye_dwell_us; \
        logic        P``_eye_enter_pulse; \
        logic        P``_eye_reset_pulse; \
        logic [1:0]  P``_eye_mode; \
        logic        P``_eye_force_full_sweep; \
        logic        P``_eye_auto_increment_lane; \
        logic        P``_eye_force_phase_en; \
        logic        P``_eye_skip_calibrator; \
        logic        P``_eye_freeze_on_cal_done; \
        logic [31:0] P``_eye_force_phase_val; \
        logic [23:0] P``_eye_force_slip_val; \
        logic [2:0]  P``_eye_state; \
        logic [2:0]  P``_eye_last_swept_lane; \
        logic        P``_eye_capture_valid; \
        logic [3:0]  P``_eye_cal_state_mirror; \
        logic [3:0]  P``_eye_sweep_phase_mirror; \
        logic [15:0] P``_eye_dwell_remaining_ms; \
        logic [6:0]  P``_score_rd_idx; \
        logic [5:0]  P``_score_rd_data; \
        logic        P``_score_lane_passed; \
        logic [5:0]  P``_score_best; \
        logic [2:0]  P``_score_best_slip; \
        logic [3:0]  P``_score_best_phase

    `EYE_BUNDLE(a);
    `EYE_BUNDLE(b);

    // Per-side ignored calibrator outputs (cocotb tests only consume
    // a_state / a_calibration_done at this TB level; deeper observables
    // are read via hierarchical xref into u_a.u_dut.score_buf etc.).
    logic [23:0] a_bit_slip, b_bit_slip;
    logic [31:0] a_phase_offset, b_phase_offset;
    logic        a_training_mode, b_training_mode;
    logic [7:0]  a_lane_fault, b_lane_fault;

    // -------------------------------------------------------------------------
    // Side A
    // -------------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES             (DWELL_CYCLES),
        .LOCK_THRESH              (LOCK_THRESH),
        .HOLD_CYCLES              (HOLD_CYCLES),
        .MAX_RESWEEPS             (MAX_RESWEEPS),
        .EARLY_EXIT_ON_ALL_LOCKED (EARLY_EXIT_ON_ALL_LOCKED),
        .CLK_MHZ                  (CLK_MHZ)
    ) u_a_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (a_role_locked),
        .swreset                (a_swreset),
        .lane_locked            (a_lane_locked),
        .apb_bit_slip_override  (a_eye_force_slip_val),
        .apb_override_enable    (a_eye_force_phase_en),
        .bit_slip               (a_bit_slip),
        .phase_offset           (a_phase_offset),
        .training_mode          (a_training_mode),
        .calibration_done       (a_calibration_done),
        .lane_fault             (a_lane_fault),
        .state                  (a_state),
        .eye_lane_sel            (a_eye_lane_sel),
        .eye_dwell_us            (a_eye_dwell_us),
        .eye_enter_pulse         (a_eye_enter_pulse),
        .eye_reset_pulse         (a_eye_reset_pulse),
        .eye_mode                (a_eye_mode),
        .eye_force_full_sweep    (a_eye_force_full_sweep),
        .eye_auto_increment_lane (a_eye_auto_increment_lane),
        .eye_skip_calibrator     (a_eye_skip_calibrator),
        .eye_freeze_on_cal_done  (a_eye_freeze_on_cal_done),
        .eye_force_phase_val     (a_eye_force_phase_val),
        .eye_state               (a_eye_state),
        .eye_last_swept_lane     (a_eye_last_swept_lane),
        .eye_capture_valid       (a_eye_capture_valid),
        .eye_cal_state_mirror    (a_eye_cal_state_mirror),
        .eye_sweep_phase_mirror  (a_eye_sweep_phase_mirror),
        .eye_dwell_remaining_ms  (a_eye_dwell_remaining_ms),
        .score_rd_idx            (a_score_rd_idx),
        .score_rd_data           (a_score_rd_data),
        .score_lane_passed       (a_score_lane_passed),
        .score_best              (a_score_best),
        .score_best_slip         (a_score_best_slip),
        .score_best_phase        (a_score_best_phase)
    );

    tidelink_eye_regs u_a_eye_regs (
        .clk         (clk),
        .rstn        (~rst),
        .psel        (a_psel),
        .penable     (a_penable),
        .pwrite      (a_pwrite),
        .paddr       (a_paddr),
        .pwdata      (a_pwdata),
        .prdata      (a_prdata),
        .pready      (a_pready),
        .pslverr     (a_pslverr),
        .eye_lane_sel            (a_eye_lane_sel),
        .eye_dwell_us            (a_eye_dwell_us),
        .eye_enter_pulse         (a_eye_enter_pulse),
        .eye_reset_pulse         (a_eye_reset_pulse),
        .eye_mode                (a_eye_mode),
        .eye_force_full_sweep    (a_eye_force_full_sweep),
        .eye_auto_increment_lane (a_eye_auto_increment_lane),
        .eye_force_phase_en      (a_eye_force_phase_en),
        .eye_skip_calibrator     (a_eye_skip_calibrator),
        .eye_freeze_on_cal_done  (a_eye_freeze_on_cal_done),
        .eye_force_phase_val     (a_eye_force_phase_val),
        .eye_force_slip_val      (a_eye_force_slip_val),
        .eye_state               (a_eye_state),
        .eye_last_swept_lane     (a_eye_last_swept_lane),
        .eye_capture_valid       (a_eye_capture_valid),
        .eye_cal_state_mirror    (a_eye_cal_state_mirror),
        .eye_sweep_phase_mirror  (a_eye_sweep_phase_mirror),
        .eye_dwell_remaining_ms  (a_eye_dwell_remaining_ms),
        .score_rd_idx            (a_score_rd_idx),
        .score_rd_data           (a_score_rd_data),
        .score_lane_passed       (a_score_lane_passed),
        .score_best              (a_score_best),
        .score_best_slip         (a_score_best_slip),
        .score_best_phase        (a_score_best_phase)
    );

    // -------------------------------------------------------------------------
    // Side B
    // -------------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES             (DWELL_CYCLES),
        .LOCK_THRESH              (LOCK_THRESH),
        .HOLD_CYCLES              (HOLD_CYCLES),
        .MAX_RESWEEPS             (MAX_RESWEEPS),
        .EARLY_EXIT_ON_ALL_LOCKED (EARLY_EXIT_ON_ALL_LOCKED),
        .CLK_MHZ                  (CLK_MHZ)
    ) u_b_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (b_role_locked),
        .swreset                (b_swreset),
        .lane_locked            (b_lane_locked),
        .apb_bit_slip_override  (b_eye_force_slip_val),
        .apb_override_enable    (b_eye_force_phase_en),
        .bit_slip               (b_bit_slip),
        .phase_offset           (b_phase_offset),
        .training_mode          (b_training_mode),
        .calibration_done       (b_calibration_done),
        .lane_fault             (b_lane_fault),
        .state                  (b_state),
        .eye_lane_sel            (b_eye_lane_sel),
        .eye_dwell_us            (b_eye_dwell_us),
        .eye_enter_pulse         (b_eye_enter_pulse),
        .eye_reset_pulse         (b_eye_reset_pulse),
        .eye_mode                (b_eye_mode),
        .eye_force_full_sweep    (b_eye_force_full_sweep),
        .eye_auto_increment_lane (b_eye_auto_increment_lane),
        .eye_skip_calibrator     (b_eye_skip_calibrator),
        .eye_freeze_on_cal_done  (b_eye_freeze_on_cal_done),
        .eye_force_phase_val     (b_eye_force_phase_val),
        .eye_state               (b_eye_state),
        .eye_last_swept_lane     (b_eye_last_swept_lane),
        .eye_capture_valid       (b_eye_capture_valid),
        .eye_cal_state_mirror    (b_eye_cal_state_mirror),
        .eye_sweep_phase_mirror  (b_eye_sweep_phase_mirror),
        .eye_dwell_remaining_ms  (b_eye_dwell_remaining_ms),
        .score_rd_idx            (b_score_rd_idx),
        .score_rd_data           (b_score_rd_data),
        .score_lane_passed       (b_score_lane_passed),
        .score_best              (b_score_best),
        .score_best_slip         (b_score_best_slip),
        .score_best_phase        (b_score_best_phase)
    );

    tidelink_eye_regs u_b_eye_regs (
        .clk         (clk),
        .rstn        (~rst),
        .psel        (b_psel),
        .penable     (b_penable),
        .pwrite      (b_pwrite),
        .paddr       (b_paddr),
        .pwdata      (b_pwdata),
        .prdata      (b_prdata),
        .pready      (b_pready),
        .pslverr     (b_pslverr),
        .eye_lane_sel            (b_eye_lane_sel),
        .eye_dwell_us            (b_eye_dwell_us),
        .eye_enter_pulse         (b_eye_enter_pulse),
        .eye_reset_pulse         (b_eye_reset_pulse),
        .eye_mode                (b_eye_mode),
        .eye_force_full_sweep    (b_eye_force_full_sweep),
        .eye_auto_increment_lane (b_eye_auto_increment_lane),
        .eye_force_phase_en      (b_eye_force_phase_en),
        .eye_skip_calibrator     (b_eye_skip_calibrator),
        .eye_freeze_on_cal_done  (b_eye_freeze_on_cal_done),
        .eye_force_phase_val     (b_eye_force_phase_val),
        .eye_force_slip_val      (b_eye_force_slip_val),
        .eye_state               (b_eye_state),
        .eye_last_swept_lane     (b_eye_last_swept_lane),
        .eye_capture_valid       (b_eye_capture_valid),
        .eye_cal_state_mirror    (b_eye_cal_state_mirror),
        .eye_sweep_phase_mirror  (b_eye_sweep_phase_mirror),
        .eye_dwell_remaining_ms  (b_eye_dwell_remaining_ms),
        .score_rd_idx            (b_score_rd_idx),
        .score_rd_data           (b_score_rd_data),
        .score_lane_passed       (b_score_lane_passed),
        .score_best              (b_score_best),
        .score_best_slip         (b_score_best_slip),
        .score_best_phase        (b_score_best_phase)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
