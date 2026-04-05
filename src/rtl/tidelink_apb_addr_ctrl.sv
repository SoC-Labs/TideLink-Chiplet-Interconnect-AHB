//-----------------------------------------------------------------------------
// SoCLabs TideLink APB Address Translation Control
//
// APB register bank that holds the segment address table and base offset
// used by the tidelink_addr_translation block.
//
// Register map (word-addressed from APB base):
//   0x000          — base_offset register
//   0x004..0x100   — segment address registers (NUM_SEG_REGS words),
//                    each packing (SEG_PER_REG) segment entries
//   0xFD0..0xFFF   — CoreSight PID/CID identification registers
//
// Each segment register packs SEG_PER_REG entries of SEG_IDX_W bits.
// With defaults (SEG_IDX_W=8, DATA_W=32) this gives 4 segments per
// register and 64 registers for 256 segments.
//
// Parameters:
//   ADDR_W      — APB address width (default 12)
//   DATA_W      — APB data width (default 32)
//   SEG_IDX_W   — Segment index width in bits (default 8)
//   NUM_SEGS    — Total number of segment entries (default 256)
//
// Based on: apb_control (axi-chiplet-controller)
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

module tidelink_apb_addr_ctrl #(
    parameter ADDR_W        = 12,
    parameter DATA_W        = 32,
    parameter SEG_IDX_W     = 8,
    parameter NUM_SEGS      = 256
)(
    input  wire             PCLK,
    input  wire             PRESETn,

    apb4_if.subordinate     CTRL_APB,

    output wire [SEG_IDX_W-1:0]  seg_addr [NUM_SEGS],
    output wire [DATA_W-1:0]     base_offset
);

// --------------------------------------------------------------------------
// Derived parameters
// --------------------------------------------------------------------------
localparam SEG_PER_REG   = DATA_W / SEG_IDX_W;
localparam NUM_SEG_REGS  = NUM_SEGS / SEG_PER_REG;
localparam NUM_REGS      = 1 + NUM_SEG_REGS;       // base_offset + seg regs
localparam REG_IDX_W     = ADDR_W - 2;             // word-address width

// --------------------------------------------------------------------------
// CoreSight identification
// --------------------------------------------------------------------------
localparam [7:0] PIDR0 = 8'h59;
localparam [7:0] PIDR1 = 8'h16;
localparam [7:0] PIDR2 = 8'h15;
localparam [7:0] PIDR3 = 8'h00;
localparam [7:0] PIDR4 = 8'h00;
localparam [7:0] PIDR5 = 8'h00;
localparam [7:0] PIDR6 = 8'h00;
localparam [7:0] PIDR7 = 8'h00;
localparam [7:0] CIDR0 = 8'h50;
localparam [7:0] CIDR1 = 8'h51;
localparam [7:0] CIDR2 = 8'h4C;
localparam [7:0] CIDR3 = 8'h54;

// --------------------------------------------------------------------------
// APB interface
// --------------------------------------------------------------------------
wire reg_read_en;
wire reg_write_en;
reg  [DATA_W-1:0] reg_rdata;

assign CTRL_APB.pready  = 1'b1;
assign CTRL_APB.pslverr = 1'b0;

assign reg_read_en  = CTRL_APB.psel & (~CTRL_APB.pwrite);
assign reg_write_en = CTRL_APB.psel & (~CTRL_APB.penable) & CTRL_APB.pwrite;
assign CTRL_APB.prdata = reg_rdata;

wire [REG_IDX_W-1:0] reg_word_addr;
assign reg_word_addr = CTRL_APB.paddr[ADDR_W-1:2];

// --------------------------------------------------------------------------
// Base offset register (index 0)
// --------------------------------------------------------------------------
reg [DATA_W-1:0] base_offset_reg;

always @(posedge PCLK or negedge PRESETn) begin
    if (~PRESETn) begin
        base_offset_reg <= {DATA_W{1'b0}};
    end else if (reg_write_en && (reg_word_addr == '0)) begin
        for (int b = 0; b < (DATA_W / 8); b = b + 1) begin
            if (CTRL_APB.pstrb[b])
                base_offset_reg[b*8 +: 8] <= CTRL_APB.pwdata[b*8 +: 8];
        end
    end
end

assign base_offset = base_offset_reg;

// --------------------------------------------------------------------------
// Segment address registers (indices 1..NUM_SEG_REGS)
//
// Each register packs SEG_PER_REG segment entries. On reset, each
// segment is initialised to the identity mapping (seg N -> N).
// --------------------------------------------------------------------------
reg [DATA_W-1:0] addr_seg_reg [NUM_SEG_REGS];

genvar k;
generate
    for (k = 0; k < NUM_SEG_REGS; k = k + 1) begin : gen_seg_reg
        // Build identity-map reset value: seg[k*SEG_PER_REG+j] = k*SEG_PER_REG+j
        localparam [DATA_W-1:0] RST_VAL = init_seg_reg(k);

        always @(posedge PCLK or negedge PRESETn) begin
            if (~PRESETn) begin
                addr_seg_reg[k] <= RST_VAL;
            end else if (reg_write_en && (reg_word_addr == (k + 1))) begin
                for (int b = 0; b < (DATA_W / 8); b = b + 1) begin
                    if (CTRL_APB.pstrb[b])
                        addr_seg_reg[k][b*8 +: 8] <= CTRL_APB.pwdata[b*8 +: 8];
                end
            end
        end
    end
endgenerate

// Identity-map reset value function
function automatic [DATA_W-1:0] init_seg_reg(input integer reg_idx);
    integer s;
    init_seg_reg = '0;
    for (s = 0; s < SEG_PER_REG; s = s + 1) begin
        init_seg_reg[s*SEG_IDX_W +: SEG_IDX_W] = SEG_IDX_W'(reg_idx * SEG_PER_REG + s);
    end
endfunction

// --------------------------------------------------------------------------
// Unpack segment registers into the per-segment output array
// --------------------------------------------------------------------------
genvar r, s;
generate
    for (r = 0; r < NUM_SEG_REGS; r = r + 1) begin : gen_unpack_reg
        for (s = 0; s < SEG_PER_REG; s = s + 1) begin : gen_unpack_seg
            assign seg_addr[r * SEG_PER_REG + s] =
                addr_seg_reg[r][s * SEG_IDX_W +: SEG_IDX_W];
        end
    end
endgenerate

// --------------------------------------------------------------------------
// Read mux
// --------------------------------------------------------------------------
always @(*) begin
    reg_rdata = {DATA_W{1'b0}};
    if (reg_read_en) begin
        if (reg_word_addr == '0) begin
            reg_rdata = base_offset_reg;
        end else if (reg_word_addr >= 1 && reg_word_addr <= NUM_SEG_REGS) begin
            reg_rdata = addr_seg_reg[reg_word_addr - 1];
        end else begin
            case (reg_word_addr)
                10'h3F4: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR4};
                10'h3F5: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR5};
                10'h3F6: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR6};
                10'h3F7: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR7};
                10'h3F8: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR0};
                10'h3F9: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR1};
                10'h3FA: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR2};
                10'h3FB: reg_rdata = {{(DATA_W-8){1'b0}}, PIDR3};
                10'h3FC: reg_rdata = {{(DATA_W-8){1'b0}}, CIDR0};
                10'h3FD: reg_rdata = {{(DATA_W-8){1'b0}}, CIDR1};
                10'h3FE: reg_rdata = {{(DATA_W-8){1'b0}}, CIDR2};
                10'h3FF: reg_rdata = {{(DATA_W-8){1'b0}}, CIDR3};
                default: reg_rdata = 32'hCAFECAFE;
            endcase
        end
    end
end

endmodule
