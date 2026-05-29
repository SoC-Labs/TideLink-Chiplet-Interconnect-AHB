// =============================================================================
// tb_autocal.sv — Standalone testbench for wlink_phy_align_calibrator
// =============================================================================
//
// This TB instantiates the calibration FSM with NO Wlink stack. cocotb drives
// the role_locked / swreset / lane_locked inputs and observes bit_slip /
// training_mode / calibration_done / lane_fault.
//
// The mocked "lane checker" is implemented in Python (test_autocal.py): for
// each test scenario the Python harness picks a target slip pattern, watches
// the FSM's `bit_slip` output, and drives `lane_locked[i]` high (after a small
// latency) only when bit_slip[3*i +: 3] matches the target and the test wants
// to allow that lane to lock. This is faster and easier than re-implementing
// the pattern-matching logic in Verilog for the standalone TB.
// =============================================================================

`timescale 1ns/1ps

module tb_autocal;

    logic        clk = 1'b0;
    logic        rst = 1'b1;

    logic        role_locked = 1'b0;
    logic        swreset     = 1'b0;
    logic [7:0]  lane_locked = 8'h00;

    logic [23:0] apb_bit_slip_override = 24'h0;
    logic        apb_override_enable   = 1'b0;

    wire  [23:0] bit_slip;
    wire         training_mode;
    wire         calibration_done;
    wire  [7:0]  lane_fault;
    wire  [3:0]  state;

    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES(32),
        .NUM_LANES   (8)
    ) u_dut (
        .clk                   (clk),
        .rst                   (rst),
        .role_locked           (role_locked),
        .swreset               (swreset),
        .lane_locked           (lane_locked),
        .apb_bit_slip_override (apb_bit_slip_override),
        .apb_override_enable   (apb_override_enable),
        .bit_slip              (bit_slip),
        .training_mode         (training_mode),
        .calibration_done      (calibration_done),
        .lane_fault            (lane_fault),
        .state                 (state)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_autocal);
    end

endmodule
