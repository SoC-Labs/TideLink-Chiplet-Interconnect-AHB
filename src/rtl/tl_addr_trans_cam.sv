//-----------------------------------------------------------------------------
// SoCLabs TideLink CAM-Based Address Translation
//
// Combinational address remapping using N programmable match/replace rules
// instead of a full 256-entry segment table. Each rule compares the upper
// byte of the normalised address against a match value; if it matches and
// the rule is enabled, the upper byte is replaced. Lowest-index rule wins
// when multiple rules match. If no rule matches, the address passes through
// unchanged (identity mapping).
//
// Operation:
//   addr_norm[31:24] = (addr_i - base_offset)[31:24]
//   for each rule k (0 to NUM_RULES-1):
//     if (rule_enable[k] && rule_match[k] == addr_norm[31:24]):
//       addr_o = {rule_replace[k], addr_i[23:0]}  (first match wins)
//   if no match:
//       addr_o = {addr_norm[31:24], addr_i[23:0]}  (identity passthrough)
//
// Parameters:
//   NUM_RULES — Number of programmable rules (default 8)
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

module tl_addr_trans_cam #(
    parameter NUM_RULES = 8
)(
    input  wire [31:0]  addr_i,
    output wire [31:0]  addr_o,

    input  wire [31:0]  base_offset,
    input  wire         global_enable,

    // Rule table: packed arrays from register block
    input  wire [NUM_RULES-1:0]  rule_enable,
    input  wire [7:0]            rule_match   [NUM_RULES],
    input  wire [7:0]            rule_replace [NUM_RULES]
);

// --------------------------------------------------------------------------
// Normalise address: subtract base_offset, use upper byte as lookup key
// --------------------------------------------------------------------------
wire [31:0] addr_norm;
assign addr_norm = addr_i - base_offset;

wire [7:0] addr_upper;
assign addr_upper = addr_norm[31:24];

// --------------------------------------------------------------------------
// Lower 24 bits always pass through from addr_i (not addr_norm)
// --------------------------------------------------------------------------
assign addr_o[23:0] = addr_i[23:0];

// --------------------------------------------------------------------------
// Parallel match + priority encode
// --------------------------------------------------------------------------
wire [NUM_RULES-1:0] match;

genvar k;
generate
    for (k = 0; k < NUM_RULES; k = k + 1) begin : gen_match
        assign match[k] = rule_enable[k] & (rule_match[k] == addr_upper);
    end
endgenerate

// Priority encoder: lowest-index matching rule wins
// If no match or global_enable is off, pass through addr_upper unchanged
reg [7:0] addr_o_upper;
assign addr_o[31:24] = addr_o_upper;

// Ascending loop with early-exit flag synthesizes as a parallel priority
// tree rather than the cascading mux chain of the descending-overwrite form.
integer i;
reg found;
always @(*) begin
    addr_o_upper = addr_upper; // default: identity passthrough
    found = 1'b0;
    if (global_enable) begin
        for (i = 0; i < NUM_RULES; i = i + 1) begin
            if (match[i] && !found) begin
                addr_o_upper = rule_replace[i];
                found = 1'b1;
            end
        end
    end
end

endmodule
