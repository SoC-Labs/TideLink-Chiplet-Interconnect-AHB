// =============================================================================
// err_inject.sv — datapath ERROR INJECTOR for the F14 error-injection bench
//                 (HARNESS ONLY — cocotb/tidelink_error_injection).
//
// Sits on a GPIO-PHY lane bus, post-skid / pre-RX, on EITHER direction. Unlike
// eye_fault.sv (which only XOR-flips masked lanes on the S->M path), this
// injector supports the full fault taxonomy the F14 matrix needs, on BOTH
// directions, and models a link-clock dropout:
//
//   mode 2'd0  STUCK-0  : masked lanes forced to constant 1'b0
//   mode 2'd1  STUCK-1  : masked lanes forced to constant 1'b1
//   mode 2'd2  STUCK-X  : masked lanes forced to 1'bx (metastable / floating —
//                         exposes X-propagation / silent-corruption paths)
//   mode 2'd3  FLIP     : masked lanes inverted (bit-error / marginal eye)
//
// A separate clk_kill control forces pad_clk_out LOW (the receiver's recovered
// link clock stops advancing — models a mid-burst clock glitch/dropout on that
// direction). Data injection is gated by inj_en; clock kill by clk_kill; the
// two are independent so cocotb can glitch clock-only, data-only, or both.
//
// ALL controls are declaration-time-initialised undriven regs — cocotb's
// hierarchical value-set (deposit) is the ONLY driver, exactly like eye_fault.
// Default = pure passthrough, so a build that instantiates but never enables
// the injector is bit-identical to the un-injected harness.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module err_inject #(
    parameter int LANES = 8
) (
    input  wire             pad_clk_in,
    input  wire [LANES-1:0] pad_data_in,
    output wire             pad_clk_out,
    output wire [LANES-1:0] pad_data_out
);
    // cocotb-driven controls (deposit-only; decl-time init = no injection).
    logic             inj_en   = 1'b0;   // 1 = data injection active
    logic [LANES-1:0] lane_mask = '0;    // which lanes are corrupted
    logic [1:0]       mode      = 2'd0;   // 0=stuck0 1=stuck1 2=stuckX 3=flip
    logic             clk_kill  = 1'b0;   // 1 = pad_clk_out forced low

    assign pad_clk_out = clk_kill ? 1'b0 : pad_clk_in;

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_lane
            logic corr;
            always @(*) begin
                case (mode)
                    2'd0:    corr = 1'b0;
                    2'd1:    corr = 1'b1;
                    2'd2:    corr = 1'bx;
                    default: corr = ~pad_data_in[l];
                endcase
            end
            assign pad_data_out[l] = (inj_en && lane_mask[l]) ? corr
                                                              : pad_data_in[l];
        end
    endgenerate

endmodule

`default_nettype wire
