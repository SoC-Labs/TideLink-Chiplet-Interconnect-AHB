// Cocotb wrapper for tidelink_mul_iter
// Exposes all multiplier ports for cocotb access.
module tb_top (
    input  logic                clk,
    input  logic                resetn,

    // Control
    input  logic                start,
    output logic                busy,
    output logic                done,

    // Operands
    input  logic signed [31:0]  a,
    input  logic        [31:0]  b,

    // Result
    output logic signed [63:0]  result
);

    tidelink_mul_iter u_dut (
        .clk    (clk),
        .resetn (resetn),
        .start  (start),
        .busy   (busy),
        .done   (done),
        .a      (a),
        .b      (b),
        .result (result)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
