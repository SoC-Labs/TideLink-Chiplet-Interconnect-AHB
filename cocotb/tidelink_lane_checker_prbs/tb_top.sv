// =============================================================================
// tb_top.sv — standalone cocotb unit testbench for tidelink_lane_checker
//             (feat/calibrator-prbs: PRBS-7 predictor lock-detect path).
// =============================================================================
//
// Wraps the per-lane single checker so cocotb can drive a 16-bit observed
// word per cycle and read back the `locked` output, while inspecting the
// internal predictor state. We instantiate the 8-lane wrapper too so
// per-lane cross-talk (a lane-j stream driven into lane-i's input) can be
// exercised at the wrapper level — the wrapper hard-wires LANE_TAG per
// lane, which is what we want to test for lane-uniqueness.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_top (
    input  wire         clk,
    input  wire         rst,
    input  wire [127:0] lane_data,
    output wire [7:0]   lane_locked
);

    // Use the small LOCK_THRESH so each test finishes quickly.
    tidelink_lane_checker #(.LOCK_THRESH(4)) u_dut (
        .clk        (clk),
        .rst        (rst),
        .lane_data  (lane_data),
        .lane_locked(lane_locked)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
