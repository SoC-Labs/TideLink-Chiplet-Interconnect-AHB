// =============================================================================
// tb_top_eye.sv — testbench wrapper for the v2 Eye Visibility RTL proposal
//                 (docs/EYE_VISIBILITY_RTL_PROPOSAL.md).
// =============================================================================
//
// Wraps a single tidelink_phy_align_calibrator together with the
// tidelink_eye_regs.sv APB shim (Region 10, MMIO 0x4403_2140..0x4403_217F).
// The cocotb test drives APB on this side and observes the calibrator's
// score buffer via the eye_regs read mux + via hierarchical xref into
// u_dut.score_buf.
//
// Port-name reconciliation (post-integration, 2026-05-27)
// -------------------------------------------------------
// The cocotb-side initial port draft used unpacked separate signals
// (eye_enter_pulse, eye_reset_pulse, eye_mode[1:0], eye_force_full_sweep,
// eye_auto_increment_lane, eye_state[2:0], etc.). The RTL agent's
// implementation packed these into 32-bit registers exposed through the
// Region 10 shim — swi_eye_ctrl[31:0] and eye_status[31:0]. The cocotb
// tests are APB-driver-only (eye_common.py reads/writes Region 10), so
// reconciling at the wrapper boundary keeps the tests untouched.
//
// We override DWELL_CYCLES / HOLD_CYCLES to small values so the simulated
// 128-point sweep completes in <1 ms of wall clock. CLK_MHZ_PARAM is
// matched to the 100 MHz clock period (10 ns) we drive in the test.
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

module tb_top #(
    parameter int DWELL_CYCLES   = 8,
    parameter int LOCK_THRESH    = 2,
    parameter int HOLD_CYCLES    = 2 * 128 * DWELL_CYCLES,
    parameter int MAX_RESWEEPS   = 0,
    // Map the 1 MHz dwell-timer to our 100 MHz simulation clock so that
    // 1 µs of programmed dwell = 100 sim cycles. Matches the
    // CLK_MHZ parameter the v2 proposal specifies (§5b dwell timer).
    parameter int CLK_MHZ        = 100,
    parameter logic EARLY_EXIT_ON_ALL_LOCKED = 1'b0
)(
    input  logic        clk,
    input  logic        rst,

    // Calibrator bring-up inputs
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,

    // APB slave for the new Region 10 eye-regs shim. Only the low 8 bits
    // of paddr are decoded (range 0x40..0x7F maps to offsets 0x140..0x17F
    // of the proposal); upper bits are ignored.
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    // Calibrator outputs visible to the test
    output logic [23:0] bit_slip,
    output logic [31:0] phase_offset,
    output logic        training_mode,
    output logic        calibration_done,
    output logic [7:0]  lane_fault,
    output logic [3:0]  state
);

    // -------------------------------------------------------------------------
    // Bridge wires between eye_regs shim and the calibrator.
    // Names follow the RTL agent's actual port list
    // (tidelink_phy_align_calibrator.sv + tidelink_eye_regs.sv).
    // -------------------------------------------------------------------------
    logic [2:0]  swi_eye_lane_sel_w;
    logic [31:0] swi_eye_dwell_us_w;
    logic [31:0] swi_eye_ctrl_w;
    logic [31:0] eye_status_w;
    logic [6:0]  eye_score_idx_w;
    logic [5:0]  eye_score_data_w;
    logic        eye_score_lane_passed_w;
    logic [5:0]  eye_score_best_w;
    logic [2:0]  eye_score_best_slip_w;
    logic [3:0]  eye_score_best_phase_w;

    // Force-phase / force-slip overrides driven by the shim. SWI_FORCE_PHASE_EN
    // packs three control bits (override / skip-cal / freeze-done — see
    // proposal §5 + eye_common.FORCE_EN_*). The calibrator only uses the
    // low bit today; the rest are reserved.
    logic [31:0] swi_force_phase_en_w;
    logic [31:0] swi_force_phase_val_w;
    logic [31:0] swi_force_slip_val_w;

    // Per-lane CRC error counters: in standalone calibrator TB there is no
    // lane_checker, so the counters are tied to 0. The read-clear strobe
    // is observable on `eye_crc_err_cnt_clr_w` if a test wants to assert it.
    logic        eye_crc_err_cnt_clr_w;

    // Synthesised dwell_min_dist from lane_locked (spec §7.1). No
    // lane_checker is instantiated in this TB; map locked→5'd0,
    // unlocked→5'd16 so the FSM's continuous-metric scoring path
    // (lane_dist_pass_w) reproduces the legacy binary-lane_locked
    // pass/fail behaviour that the existing eye tests stimulate.
    logic [39:0] dwell_min_dist_synth;
    always_comb begin
        for (int li = 0; li < 8; li++)
            dwell_min_dist_synth[5*li +: 5] = lane_locked[li] ? 5'd0 : 5'd16;
    end

    // -------------------------------------------------------------------------
    // DUT — calibrator.
    // -------------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES             (DWELL_CYCLES),
        .LOCK_THRESH              (LOCK_THRESH),
        .HOLD_CYCLES              (HOLD_CYCLES),
        .MAX_RESWEEPS             (MAX_RESWEEPS),
        .EARLY_EXIT_ON_ALL_LOCKED (EARLY_EXIT_ON_ALL_LOCKED),
        .CLK_MHZ                  (CLK_MHZ)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        // Spec §7.1: per-lane dwell_min_dist input from new lane_checker.
        // No lane_checker in this TB → synthesise the continuous metric
        // from lane_locked so the new FSM scoring (lane_dist_pass_w =
        // (dwell_min_dist_i <= LOCK_DIST_THRESHOLD)) follows the legacy
        // binary lane_locked semantics that the eye tests still drive.
        .dwell_min_dist_i       (dwell_min_dist_synth),
        .apb_bit_slip_override  (swi_force_slip_val_w[23:0]),
        .apb_override_enable    (swi_force_phase_en_w[0]),
        // §9.11c / §9.11d unit-test defaults (no APB tune, auto-pass S_VALIDATE).
        .min_lock_dwells_i      (4'h0),
        .cr_pkt_seen_i          (1'b1),
        // P1 (2026-07-19): force_recal_i has no SV default port value (zero precedent in-tree; Vivado SV subset). Tie 0 = pre-P1 behaviour.
        .force_recal_i               (1'b0),
        .bit_slip               (bit_slip),
        .phase_offset           (phase_offset),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .lane_fault             (lane_fault),
        .state                  (state),
        // Spec §7.2: gates lane_checker vote during S_SWEEP. No lane_checker
        // here → leave unconnected.
        .sweep_active_o         (/* unconnected */),

        // ── v2 eye-visibility surface ────────────────────────────────────
        .swi_eye_lane_sel       (swi_eye_lane_sel_w),
        .swi_eye_dwell_us       (swi_eye_dwell_us_w),
        .swi_eye_ctrl           (swi_eye_ctrl_w),
        .eye_status             (eye_status_w),
        .eye_score_idx          (eye_score_idx_w),
        .eye_score_data         (eye_score_data_w),
        .eye_score_lane_passed  (eye_score_lane_passed_w),
        .eye_score_best         (eye_score_best_w),
        .eye_score_best_slip    (eye_score_best_slip_w),
        .eye_score_best_phase   (eye_score_best_phase_w)
    );

    // -------------------------------------------------------------------------
    // Eye regs APB shim (Region 10).
    // -------------------------------------------------------------------------
    tidelink_eye_regs #(
        .APB_ADDR_W (12),
        .SYS_DATA_W (32)
    ) u_eye_regs (
        .hclk        (clk),
        .hresetn     (~rst),

        .psel        (psel),
        .penable     (penable),
        .pwrite      (pwrite),
        .paddr       (paddr),
        .pwdata      (pwdata),
        .prdata      (prdata),
        .pready      (pready),
        .pslverr     (pslverr),

        // Outputs to calibrator
        .swi_eye_lane_sel        (swi_eye_lane_sel_w),
        .swi_eye_dwell_us        (swi_eye_dwell_us_w),
        .swi_eye_ctrl            (swi_eye_ctrl_w),
        .eye_status_i            (eye_status_w),
        .eye_score_idx           (eye_score_idx_w),
        .eye_score_data_i        (eye_score_data_w),
        .eye_score_lane_passed_i (eye_score_lane_passed_w),
        .eye_score_best_i        (eye_score_best_w),
        .eye_score_best_slip_i   (eye_score_best_slip_w),
        .eye_score_best_phase_i  (eye_score_best_phase_w),

        .swi_force_phase_en      (swi_force_phase_en_w),
        .swi_force_phase_val     (swi_force_phase_val_w),
        .swi_force_slip_val      (swi_force_slip_val_w),

        // No lane_checker in this standalone TB: tie counters to 0.
        .lane_crc_err_cnt_0_i    (8'h0),
        .lane_crc_err_cnt_1_i    (8'h0),
        .lane_crc_err_cnt_2_i    (8'h0),
        .lane_crc_err_cnt_3_i    (8'h0),
        .lane_crc_err_cnt_4_i    (8'h0),
        .lane_crc_err_cnt_5_i    (8'h0),
        .lane_crc_err_cnt_6_i    (8'h0),
        .lane_crc_err_cnt_7_i    (8'h0),
        .lane_crc_err_cnt_clr_o  (eye_crc_err_cnt_clr_w),

        .eye_last_slip_i         (bit_slip),
        .eye_last_lane_fault_i   (lane_fault)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
