// SPDX-License-Identifier: Apache-2.0
//
// TL-020 landmine defuse (2026-08-08) — David Mapstone / SoC Labs.
//
// wlink_wlink_ptp_tl_a2l_48x4 is the app-to-link replay FIFO memory of the PTP
// FC node (WlinkGenericFCReplayV2_15 -> WavFIFO_23.v:103, instantiated with
// #(.DATA_SIZE(48), .ADDR_SIZE(2)) => 48-bit x depth-4). The Chisel memory
// generator emitted behavioral .v models for its SIBLINGS
// (deps/.../wlink_wlink_tidelink_tl_a2l_48x16.v, .../wlink_wlink_axi_bFC_a2l_14x8.v,
// etc.) but NEVER emitted this one, so any build that ELABORATES the PTP FC node
// died with "Error-[CFCILFBI] Cannot find cell wlink_wlink_ptp_tl_a2l_48x4". It
// was only dormant because the current tops do not instantiate the PTP FC node.
//
// This model is a byte-for-byte structural copy of the sibling _48x16 model (the
// same simple dual-clock behavioral SRAM the logical flist uses for every other
// a2l memory), renamed and re-defaulted to depth 4. Adding it is ZERO current-
// netlist-impact: the module is compiled but not elaborated until the PTP FC node
// is enabled (TL-010), at which point it resolves cleanly instead of aborting.
//
// TAPEOUT NOTE (David / TL-010): if the PTP FC node is enabled for silicon, swap
// this behavioral model for the proper tech SRAM macro at map time, exactly as is
// done for the sibling a2l memories — do NOT ship the behavioral model.
module wlink_wlink_ptp_tl_a2l_48x4 #(
  parameter                     DATA_SIZE        = 48,
  parameter                     ADDR_SIZE        = 2
)(
  input  wire                   wclk,
  input  wire                   rclk,
  input  wire                   wclken,
  input  wire                   read_en,
  input  wire                   wreset,
  input  wire                   wfull,
  input  wire [ADDR_SIZE-1:0]   waddr,
  input  wire [ADDR_SIZE-1:0]   raddr,
  input  wire [DATA_SIZE-1:0]   wdata,
  output wire [DATA_SIZE-1:0]   rdata
);

localparam    DEPTH = 1<<ADDR_SIZE;
wire web;
wire reb;

  reg [DATA_SIZE-1:0]   mem [0:DEPTH-1];

  assign rdata  = mem[raddr];

  integer i;
  always @(posedge wclk or posedge wreset) begin
    if(wreset) begin
      for(i = 0; i< (1<<ADDR_SIZE); i = i + 1) begin
        mem[i]      <= {DATA_SIZE{1'b0}};
      end
    end else begin
      if(wclken & ~wfull) begin
        mem[waddr]  <= wdata;
      end
    end
  end

endmodule
