// =============================================================================
// tb_calibrator_robust.sv — standalone TB for sim_robust tests
// =============================================================================
//
// Wraps tidelink_phy_align_calibrator (this branch's signature: DWELL_CYCLES
// + NUM_LANES only) so the sim_robust suite can:
//
//   * Drive role_locked / swreset / lane_locked directly from cocotb
//   * Read out cur_state, lane_done, lane_fault_q via hierarchical refs
//   * Inject reset glitches and observe FSM behaviour
//   * Force internal signals (cur_state, lane_done[]) to silicon-failure
//     patterns and verify the calibrator's observable output fingerprint
//     matches what we have seen on the FPGA pair bring-up:
//       cal_done=0, lane_fault=0x00, training_mode stuck
//
// Small DWELL_CYCLES keeps each test under ~1 ms wall-clock.
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

module tb_calibrator_robust #(
    parameter int DWELL_CYCLES = 8,
    parameter int NUM_LANES    = 8
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,
    output logic [23:0] bit_slip,
    output logic        training_mode,
    output logic        calibration_done,
    output logic [7:0]  lane_fault,
    output logic [3:0]  state
);

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES (DWELL_CYCLES),
        .NUM_LANES    (NUM_LANES)
    ) u_dut (
        .clk                    (clk),
        .rst                    (rst),
        .role_locked            (role_locked),
        .swreset                (swreset),
        .lane_locked            (lane_locked),
        .apb_bit_slip_override  (apb_bit_slip_override),
        .apb_override_enable    (apb_override_enable),
        .bit_slip               (bit_slip),
        .training_mode          (training_mode),
        .calibration_done       (calibration_done),
        .lane_fault             (lane_fault),
        .state                  (state)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_calibrator_robust);
    end

endmodule

`default_nettype wire
