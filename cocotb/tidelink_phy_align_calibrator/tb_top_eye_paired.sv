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
// Port-name reconciliation (post-integration, 2026-05-27)
// -------------------------------------------------------
// The cocotb-side initial port draft used unpacked separate signals
// (eye_enter_pulse, eye_reset_pulse, etc.). The RTL agent's implementation
// packed these into swi_eye_ctrl[31:0] / eye_status[31:0]. Cocotb tests
// drive APB only — the bundle macros below match the actual RTL contract.
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

    // Per-side internal nets between eye_regs and calibrator (RTL names).
    `define EYE_BUNDLE(P) \
        logic [2:0]  P``_swi_eye_lane_sel_w; \
        logic [31:0] P``_swi_eye_dwell_us_w; \
        logic [31:0] P``_swi_eye_ctrl_w; \
        logic [31:0] P``_eye_status_w; \
        logic [6:0]  P``_eye_score_idx_w; \
        logic [5:0]  P``_eye_score_data_w; \
        logic        P``_eye_score_lane_passed_w; \
        logic [5:0]  P``_eye_score_best_w; \
        logic [2:0]  P``_eye_score_best_slip_w; \
        logic [3:0]  P``_eye_score_best_phase_w; \
        logic [31:0] P``_swi_force_phase_en_w; \
        logic [31:0] P``_swi_force_phase_val_w; \
        logic [31:0] P``_swi_force_slip_val_w; \
        logic        P``_eye_crc_err_cnt_clr_w

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
        .apb_bit_slip_override  (a_swi_force_slip_val_w[23:0]),
        .apb_override_enable    (a_swi_force_phase_en_w[0]),
        .bit_slip               (a_bit_slip),
        .phase_offset           (a_phase_offset),
        .training_mode          (a_training_mode),
        .calibration_done       (a_calibration_done),
        .lane_fault             (a_lane_fault),
        .state                  (a_state),
        .swi_eye_lane_sel       (a_swi_eye_lane_sel_w),
        .swi_eye_dwell_us       (a_swi_eye_dwell_us_w),
        .swi_eye_ctrl           (a_swi_eye_ctrl_w),
        .eye_status             (a_eye_status_w),
        .eye_score_idx          (a_eye_score_idx_w),
        .eye_score_data         (a_eye_score_data_w),
        .eye_score_lane_passed  (a_eye_score_lane_passed_w),
        .eye_score_best         (a_eye_score_best_w),
        .eye_score_best_slip    (a_eye_score_best_slip_w),
        .eye_score_best_phase   (a_eye_score_best_phase_w)
    );

    tidelink_eye_regs #(
        .APB_ADDR_W (12),
        .SYS_DATA_W (32)
    ) u_a_eye_regs (
        .hclk        (clk),
        .hresetn     (~rst),
        .psel        (a_psel),
        .penable     (a_penable),
        .pwrite      (a_pwrite),
        .paddr       (a_paddr),
        .pwdata      (a_pwdata),
        .prdata      (a_prdata),
        .pready      (a_pready),
        .pslverr     (a_pslverr),
        .swi_eye_lane_sel        (a_swi_eye_lane_sel_w),
        .swi_eye_dwell_us        (a_swi_eye_dwell_us_w),
        .swi_eye_ctrl            (a_swi_eye_ctrl_w),
        .eye_status_i            (a_eye_status_w),
        .eye_score_idx           (a_eye_score_idx_w),
        .eye_score_data_i        (a_eye_score_data_w),
        .eye_score_lane_passed_i (a_eye_score_lane_passed_w),
        .eye_score_best_i        (a_eye_score_best_w),
        .eye_score_best_slip_i   (a_eye_score_best_slip_w),
        .eye_score_best_phase_i  (a_eye_score_best_phase_w),
        .swi_force_phase_en      (a_swi_force_phase_en_w),
        .swi_force_phase_val     (a_swi_force_phase_val_w),
        .swi_force_slip_val      (a_swi_force_slip_val_w),
        .lane_crc_err_cnt_0_i    (8'h0),
        .lane_crc_err_cnt_1_i    (8'h0),
        .lane_crc_err_cnt_2_i    (8'h0),
        .lane_crc_err_cnt_3_i    (8'h0),
        .lane_crc_err_cnt_4_i    (8'h0),
        .lane_crc_err_cnt_5_i    (8'h0),
        .lane_crc_err_cnt_6_i    (8'h0),
        .lane_crc_err_cnt_7_i    (8'h0),
        .lane_crc_err_cnt_clr_o  (a_eye_crc_err_cnt_clr_w),
        .eye_last_slip_i         (a_bit_slip),
        .eye_last_lane_fault_i   (a_lane_fault)
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
        .apb_bit_slip_override  (b_swi_force_slip_val_w[23:0]),
        .apb_override_enable    (b_swi_force_phase_en_w[0]),
        .bit_slip               (b_bit_slip),
        .phase_offset           (b_phase_offset),
        .training_mode          (b_training_mode),
        .calibration_done       (b_calibration_done),
        .lane_fault             (b_lane_fault),
        .state                  (b_state),
        .swi_eye_lane_sel       (b_swi_eye_lane_sel_w),
        .swi_eye_dwell_us       (b_swi_eye_dwell_us_w),
        .swi_eye_ctrl           (b_swi_eye_ctrl_w),
        .eye_status             (b_eye_status_w),
        .eye_score_idx          (b_eye_score_idx_w),
        .eye_score_data         (b_eye_score_data_w),
        .eye_score_lane_passed  (b_eye_score_lane_passed_w),
        .eye_score_best         (b_eye_score_best_w),
        .eye_score_best_slip    (b_eye_score_best_slip_w),
        .eye_score_best_phase   (b_eye_score_best_phase_w)
    );

    tidelink_eye_regs #(
        .APB_ADDR_W (12),
        .SYS_DATA_W (32)
    ) u_b_eye_regs (
        .hclk        (clk),
        .hresetn     (~rst),
        .psel        (b_psel),
        .penable     (b_penable),
        .pwrite      (b_pwrite),
        .paddr       (b_paddr),
        .pwdata      (b_pwdata),
        .prdata      (b_prdata),
        .pready      (b_pready),
        .pslverr     (b_pslverr),
        .swi_eye_lane_sel        (b_swi_eye_lane_sel_w),
        .swi_eye_dwell_us        (b_swi_eye_dwell_us_w),
        .swi_eye_ctrl            (b_swi_eye_ctrl_w),
        .eye_status_i            (b_eye_status_w),
        .eye_score_idx           (b_eye_score_idx_w),
        .eye_score_data_i        (b_eye_score_data_w),
        .eye_score_lane_passed_i (b_eye_score_lane_passed_w),
        .eye_score_best_i        (b_eye_score_best_w),
        .eye_score_best_slip_i   (b_eye_score_best_slip_w),
        .eye_score_best_phase_i  (b_eye_score_best_phase_w),
        .swi_force_phase_en      (b_swi_force_phase_en_w),
        .swi_force_phase_val     (b_swi_force_phase_val_w),
        .swi_force_slip_val      (b_swi_force_slip_val_w),
        .lane_crc_err_cnt_0_i    (8'h0),
        .lane_crc_err_cnt_1_i    (8'h0),
        .lane_crc_err_cnt_2_i    (8'h0),
        .lane_crc_err_cnt_3_i    (8'h0),
        .lane_crc_err_cnt_4_i    (8'h0),
        .lane_crc_err_cnt_5_i    (8'h0),
        .lane_crc_err_cnt_6_i    (8'h0),
        .lane_crc_err_cnt_7_i    (8'h0),
        .lane_crc_err_cnt_clr_o  (b_eye_crc_err_cnt_clr_w),
        .eye_last_slip_i         (b_bit_slip),
        .eye_last_lane_fault_i   (b_lane_fault)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
