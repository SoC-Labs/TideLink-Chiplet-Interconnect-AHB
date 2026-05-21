//-----------------------------------------------------------------------------
// SoCLabs TideLink Segment-Based Address Translation
//
// Combinational address remapping block. Replaces the upper segment-index
// bits of an incoming address with a value looked up from a software-
// programmed segment table. Lower (passthrough) bits are forwarded
// unchanged.
//
// Operation:
//   seg_idx = addr_i[ADDR_W-1 -: SEG_IDX_W] - base_offset
//   addr_o  = { seg_addr[seg_idx], addr_i[PASSTHROUGH_W-1:0] }
//
// Parameters:
//   ADDR_W    — Total address width (default 32)
//   SEG_IDX_W — Width of the segment index field, i.e. the number of upper
//               address bits used for lookup (default 8)
//   NUM_SEGS  — Number of entries in the segment table. Must be
//               <= 2**SEG_IDX_W (default 256)
//
// Based on: address_translation (axi-chiplet-controller)
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

module tidelink_addr_translation #(
    parameter ADDR_W    = 32,
    parameter SEG_IDX_W = 8,
    parameter NUM_SEGS  = 256
)(
    input  wire [ADDR_W-1:0]      addr_i,
    output wire [ADDR_W-1:0]      addr_o,

    input  wire [ADDR_W-1:0]      base_offset,

    input  wire [SEG_IDX_W-1:0]   seg_addr [NUM_SEGS]
);

localparam PASSTHROUGH_W = ADDR_W - SEG_IDX_W;

// Subtract base offset on the segment index bits only — avoids a
// full ADDR_W-bit subtractor; only the upper SEG_IDX_W bits matter.
wire [SEG_IDX_W-1:0] seg_idx;
assign seg_idx = addr_i[ADDR_W-1 -: SEG_IDX_W] - base_offset[ADDR_W-1 -: SEG_IDX_W];

// Lower bits pass through unchanged
assign addr_o[PASSTHROUGH_W-1:0] = addr_i[PASSTHROUGH_W-1:0];

// Upper bits: direct array lookup (synthesises as a mux tree)
assign addr_o[ADDR_W-1 -: SEG_IDX_W] = seg_addr[seg_idx];

endmodule
