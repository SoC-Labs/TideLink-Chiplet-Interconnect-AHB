//-----------------------------------------------------------------------------
// SoCLabs TideLink Iterative Multiplier
//
// 32×32 signed × unsigned shift-and-add multiplier.
// Produces a 64-bit signed result in 32 clock cycles.
//
// Interface:
//   start pulse → 32 cycles → done pulse + result valid
//   a = signed multiplicand, b = unsigned multiplier (e.g. PI gain)
//   result = a × b (signed 64-bit)
//
// Area: ~2K gates (vs ~15K for combinational 32×32 multiply)
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_mul_iter (
    input  wire                 clk,
    input  wire                 resetn,

    // Control
    input  wire                 start,       // Pulse: begin multiply
    output wire                 busy,        // High during computation
    output wire                 done,        // Pulse: result valid

    // Operands (latched on start)
    input  wire signed [31:0]  a,           // Signed multiplicand
    input  wire        [31:0]  b,           // Unsigned multiplier

    // Result (valid when done asserts)
    output wire signed [63:0]  result
);

    // =========================================================================
    // State
    // =========================================================================
    logic        active_r;
    logic [4:0]  count_r;       // 0..31, counts bits of b processed
    logic signed [63:0] accum_r;
    logic        [31:0] b_shift_r;
    logic signed [63:0] a_ext_r;     // sign-extended a, shifted left by count

    // =========================================================================
    // Control
    // =========================================================================
    assign busy   = active_r;
    assign done   = active_r && (count_r == 5'd31);
    assign result = accum_r + (b_shift_r[0] ? a_ext_r : 64'sd0);

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            active_r  <= 1'b0;
            count_r   <= 5'd0;
            accum_r   <= 64'sd0;
            b_shift_r <= 32'd0;
            a_ext_r   <= 64'sd0;
        end else if (start && !active_r) begin
            // Latch operands and start
            active_r  <= 1'b1;
            count_r   <= 5'd0;
            accum_r   <= 64'sd0;
            b_shift_r <= b;
            // Sign-extend a to 64 bits. The 64'() size cast preserves the
            // operand's signedness, so on `input wire signed [31:0] a` it is
            // exactly the {{32{a[31]}}, a} it replaces -- without the manual
            // sign bit (which mixed a signed variable with an unsigned
            // replication inside one concatenation, and which silently goes
            // wrong the day `a` changes width).
            a_ext_r   <= 64'(a);
        end else if (active_r) begin
            // Shift-and-add: if current bit of b is 1, add shifted a
            if (b_shift_r[0])
                accum_r <= accum_r + a_ext_r;

            // Shift for next bit
            a_ext_r   <= a_ext_r <<< 1;
            b_shift_r <= b_shift_r >> 1;
            count_r   <= count_r + 5'd1;

            // Done on cycle 31
            if (count_r == 5'd31)
                active_r <= 1'b0;
        end
    end

endmodule
