// =============================================================================
// tb_top.sv — standalone unit testbench for tidelink_phy_align_calibrator
// =============================================================================
//
// Purpose: pin the §9 calibrator FSM's two critical bring-up properties at
// unit level (no PHY, no Wlink, no APB):
//
//   * T3   (continuous re-sweep on faulted sweep + role_locked).
//   * T3.2 (S_HOLD after sweep_success keeps training_mode high HOLD_CYCLES).
//
// We override DWELL_CYCLES + HOLD_CYCLES to small values so the FSM's
// 128-point sweep completes in a few thousand cycles instead of millions.
// The RTL behaviour under test (FSM transitions) is unchanged — only the
// magnitudes (sweep_exhausted timing, hold_ctr saturation) shrink.
//
// The lane_locked input is driven directly by the cocotb test — no PHY in
// the loop — so we can script "all lanes lock during sweep" (sweep_success
// = ~|lane_fault_q = 1 → S_HOLD) and "no lane locks" (sweep_success = 0 →
// re-sweep auto-arm) deterministically.
//
// EARLY_EXIT_ON_ALL_LOCKED is left at the silicon default (1'b0,
// best-of-sweep). The T3 / T3.2 transitions out of S_FINISH depend on
// sweep_success / role_locked, NOT on early-exit specifics — both
// EARLY_EXIT modes traverse S_FINISH and apply the same release logic.
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
    // Small DWELL_CYCLES so the full 128-point sweep is ~1k cycles instead
    // of 8k. The RTL's run-length scoring saturates at 6'h3F (=63); we set
    // LOCK_THRESH=2 so even a 2-cycle lane_locked window scores as a
    // "good" dwell. This keeps the wall-clock under a second per test.
    parameter int DWELL_CYCLES = 8,
    parameter int LOCK_THRESH  = 2,
    // 2 sweep periods of hold instead of 8 — keeps the wall-clock short
    // while still proving "hold > 1 sweep". The RTL has a localparam-
    // derived default HOLD_CYCLES = 8 * 128 * DWELL_CYCLES — we override
    // it directly so the cocotb test has a known small bound.
    parameter int HOLD_CYCLES  = 2 * 128 * DWELL_CYCLES,
    // T3: 0 = retry while role_locked (cold bring-up default).
    parameter int MAX_RESWEEPS = 0,
    // §9.11 eye-centre contiguity. Production silicon default is 4 (25%
    // of the 16-phase axis), but the test_eye_offcenter / placeholder
    // stimuli use 3×3 eyes which give phase-axis runs of 3, so we lower
    // the unit-test default to 3 here. test_eye_offcenter assertions
    // are written for "the widest eye wins"; with this default a 3-wide
    // phase run promotes correctly.
    parameter int MIN_LOCK_DWELLS = 3
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,
    output logic [23:0] bit_slip,
    output logic [31:0] phase_offset,
    output logic        training_mode,
    output logic        calibration_done,
    output logic [7:0]  lane_fault,
    output logic [3:0]  state
);

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES (DWELL_CYCLES),
        .LOCK_THRESH  (LOCK_THRESH),
        .HOLD_CYCLES  (HOLD_CYCLES),
        .MAX_RESWEEPS (MAX_RESWEEPS),
        // §9.11 eye-centre (silicon default). EARLY_EXIT compat mode is
        // exercised by the integrated phy_align tests; this unit TB
        // focuses on the silicon FSM behaviour.
        .EARLY_EXIT_ON_ALL_LOCKED (1'b0),
        .MIN_LOCK_DWELLS          (MIN_LOCK_DWELLS)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        .apb_bit_slip_override  (apb_bit_slip_override),
        .apb_override_enable    (apb_override_enable),
        .bit_slip               (bit_slip),
        .phase_offset           (phase_offset),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .lane_fault             (lane_fault),
        .state                  (state)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
