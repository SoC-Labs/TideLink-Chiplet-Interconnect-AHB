// =============================================================================
// tb_top_eye.sv — testbench wrapper for the v2 Eye Visibility RTL proposal
//                 (docs/EYE_VISIBILITY_RTL_PROPOSAL.md).
// =============================================================================
//
// Wraps a single tidelink_phy_align_calibrator together with the new
// tidelink_eye_regs.sv APB shim (Region 10, MMIO 0x4403_2140..0x4403_217F).
// The cocotb test drives APB on this side and observes the calibrator's
// score buffer via the eye_regs read mux + via hierarchical xref into
// u_dut.score_buf.
//
// IMPORTANT — DEPENDS ON RTL FROM A PARALLEL AGENT
// ------------------------------------------------
// The RTL surfaces consumed by this testbench are added by
// `feat/eye-rtl-impl`:
//
//   * `tidelink_phy_align_calibrator` gains five new ports
//     (eye_lane_sel, eye_dwell_us, eye_enter_pulse, eye_force_phase_*,
//     eye_state, eye_last_swept_lane, score_buf — see proposal §6).
//   * `tidelink_eye_regs.sv`: NEW APB shim implementing the §5 register map.
//
// Until that branch merges, this tb compiles ONLY if both files exist —
// the test files (test_eye_*.py) are harness-complete but require the RTL
// surface to run. The flist `flist/tidelink_eye_visibility.flist` is the
// merge point for both modules.
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
    // Wires between eye_regs shim and the calibrator (v2 proposal §6 ports).
    // The RTL agent's calibrator picks these names up; if any rename is
    // required at merge time, this wrapper is the single place to adapt.
    // -------------------------------------------------------------------------
    logic [2:0]  eye_lane_sel;
    logic [31:0] eye_dwell_us;
    logic        eye_enter_pulse;
    logic        eye_reset_pulse;
    logic [1:0]  eye_mode;
    logic        eye_force_full_sweep;
    logic        eye_auto_increment_lane;
    logic [31:0] eye_force_phase_val;     // per-lane 4 b, lane N at [4N+3:4N]
    logic [23:0] eye_force_slip_val;      // per-lane 3 b
    logic        eye_force_phase_en;
    logic        eye_skip_calibrator;
    logic        eye_freeze_on_cal_done;
    logic [2:0]  eye_state;               // 0=IDLE 1=SWEEPING 2=DONE 3=TIMED_OUT 4=DRAINING
    logic [2:0]  eye_last_swept_lane;
    logic        eye_capture_valid;
    logic [3:0]  eye_cal_state_mirror;
    logic [3:0]  eye_sweep_phase_mirror;
    logic [15:0] eye_dwell_remaining_ms;

    // Score buffer read port driven by the eye_regs shim into the
    // calibrator. The shim emits a 7-bit index (slip[2:0],phase[3:0])
    // selected against the LANE_SEL register; the calibrator returns the
    // packed score word.
    logic [6:0]  score_rd_idx;
    logic [5:0]  score_rd_data;
    logic        score_lane_passed;
    logic [5:0]  score_best;
    logic [2:0]  score_best_slip;
    logic [3:0]  score_best_phase;

    // -------------------------------------------------------------------------
    // DUT — calibrator. The new ports below (prefixed `eye_`) are added on
    // the feat/eye-rtl-impl branch; tests will not compile until that
    // branch merges.
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
        .apb_bit_slip_override  (eye_force_slip_val),
        .apb_override_enable    (eye_force_phase_en),
        .bit_slip               (bit_slip),
        .phase_offset           (phase_offset),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .lane_fault             (lane_fault),
        .state                  (state),

        // ── v2 eye-visibility surface (added by feat/eye-rtl-impl) ────────
        .eye_lane_sel            (eye_lane_sel),
        .eye_dwell_us            (eye_dwell_us),
        .eye_enter_pulse         (eye_enter_pulse),
        .eye_reset_pulse         (eye_reset_pulse),
        .eye_mode                (eye_mode),
        .eye_force_full_sweep    (eye_force_full_sweep),
        .eye_auto_increment_lane (eye_auto_increment_lane),
        .eye_skip_calibrator     (eye_skip_calibrator),
        .eye_freeze_on_cal_done  (eye_freeze_on_cal_done),
        .eye_force_phase_val     (eye_force_phase_val),
        .eye_state               (eye_state),
        .eye_last_swept_lane     (eye_last_swept_lane),
        .eye_capture_valid       (eye_capture_valid),
        .eye_cal_state_mirror    (eye_cal_state_mirror),
        .eye_sweep_phase_mirror  (eye_sweep_phase_mirror),
        .eye_dwell_remaining_ms  (eye_dwell_remaining_ms),
        .score_rd_idx            (score_rd_idx),
        .score_rd_data           (score_rd_data),
        .score_lane_passed       (score_lane_passed),
        .score_best              (score_best),
        .score_best_slip         (score_best_slip),
        .score_best_phase        (score_best_phase)
    );

    // -------------------------------------------------------------------------
    // Eye regs APB shim (Region 10). Added by feat/eye-rtl-impl.
    // -------------------------------------------------------------------------
    tidelink_eye_regs u_eye_regs (
        .clk         (clk),
        .rstn        (~rst),

        .psel        (psel),
        .penable     (penable),
        .pwrite      (pwrite),
        .paddr       (paddr),
        .pwdata      (pwdata),
        .prdata      (prdata),
        .pready      (pready),
        .pslverr     (pslverr),

        // Outputs to calibrator
        .eye_lane_sel            (eye_lane_sel),
        .eye_dwell_us            (eye_dwell_us),
        .eye_enter_pulse         (eye_enter_pulse),
        .eye_reset_pulse         (eye_reset_pulse),
        .eye_mode                (eye_mode),
        .eye_force_full_sweep    (eye_force_full_sweep),
        .eye_auto_increment_lane (eye_auto_increment_lane),
        .eye_force_phase_en      (eye_force_phase_en),
        .eye_skip_calibrator     (eye_skip_calibrator),
        .eye_freeze_on_cal_done  (eye_freeze_on_cal_done),
        .eye_force_phase_val     (eye_force_phase_val),
        .eye_force_slip_val      (eye_force_slip_val),

        // Inputs back from calibrator
        .eye_state               (eye_state),
        .eye_last_swept_lane     (eye_last_swept_lane),
        .eye_capture_valid       (eye_capture_valid),
        .eye_cal_state_mirror    (eye_cal_state_mirror),
        .eye_sweep_phase_mirror  (eye_sweep_phase_mirror),
        .eye_dwell_remaining_ms  (eye_dwell_remaining_ms),

        // Indirect/burst data path
        .score_rd_idx            (score_rd_idx),
        .score_rd_data           (score_rd_data),
        .score_lane_passed       (score_lane_passed),
        .score_best              (score_best),
        .score_best_slip         (score_best_slip),
        .score_best_phase        (score_best_phase)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
