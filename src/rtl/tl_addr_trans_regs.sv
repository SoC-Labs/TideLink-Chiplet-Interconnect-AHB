//-----------------------------------------------------------------------------
// SoCLabs TideLink CAM Address Translation Register Block
//
// APB register bank for the CAM-based address translator. Provides a
// base_offset register, a global enable control register, and N
// programmable match/replace rule registers.
//
// Register map (word-addressed from APB base):
//   0x000          — BASE_OFFSET register (RW, reset = 0)
//   0x004          — CTRL register ([0] = global_enable, RW, reset = 0)
//   0x010          — RULE_0  {[23:16] replace, [15:8] match, [0] enable}
//   0x014          — RULE_1
//   ...
//   0x010+4*(N-1)  — RULE_{N-1}
//   0xFD0..0xFFF   — CoreSight PID/CID identification registers (RO)
//
// Parameters:
//   ADDR_W    — APB address width (default 12)
//   DATA_W    — APB data width (default 32)
//   NUM_RULES — Number of match/replace rules (default 8)
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

module tl_addr_trans_regs #(
    parameter ADDR_W    = 12,
    parameter DATA_W    = 32,
    parameter NUM_RULES = 8
)(
    input  wire             PCLK,
    input  wire             PRESETn,

    apb4_if.subordinate     CTRL_APB,

    // Configuration outputs
    output wire [DATA_W-1:0]         base_offset,
    output wire                      global_enable,
    output wire [NUM_RULES-1:0]      rule_enable,
    output wire [7:0]                rule_match   [NUM_RULES],
    output wire [7:0]                rule_replace [NUM_RULES]
);

// --------------------------------------------------------------------------
// Derived parameters
// --------------------------------------------------------------------------
localparam REG_IDX_W = ADDR_W - 2;  // word-address width

// Rule register offsets: RULE_0 at word address 4 (byte 0x010), +1 per rule
localparam RULE_BASE_WORD = 4;  // 0x010 >> 2

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

// Zero-extended copy of the word address, for the comparisons against the
// UNSIZED integer localparams below (RULE_BASE_WORD, RULE_BASE_WORD+NUM_RULES,
// and the literal 1). Those localparams are 32-bit integers, so the compares
// were 10-bit-vs-32-bit and HAL rightly flagged them (ULCMPE/ULRELE/UELOPR).
//
// The narrow side is widened deliberately, and the wide side is left alone:
// zero-extension is exactly what the simulator was already doing, so this is
// bit-identical. Sizing the CONSTANTS down to REG_IDX_W instead would put
// RULE_BASE_WORD + NUM_RULES -- the rule window's UPPER bound -- at the mercy
// of the parameterised width, and a future NUM_RULES could silently truncate
// it and shrink the window.
wire [31:0] reg_word_addr_x = 32'(reg_word_addr);

// --------------------------------------------------------------------------
// BASE_OFFSET register (word address 0)
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
// CTRL register (word address 1, byte offset 0x004)
//   [0] = global_enable (RW, reset = 0)
// --------------------------------------------------------------------------
reg ctrl_enable_reg;

always @(posedge PCLK or negedge PRESETn) begin
    if (~PRESETn) begin
        ctrl_enable_reg <= 1'b0;
    end else if (reg_write_en && (reg_word_addr_x == 32'd1)) begin
        if (CTRL_APB.pstrb[0])
            ctrl_enable_reg <= CTRL_APB.pwdata[0];
    end
end

assign global_enable = ctrl_enable_reg;

// --------------------------------------------------------------------------
// RULE registers (word addresses RULE_BASE_WORD .. RULE_BASE_WORD+NUM_RULES-1)
//
// Layout per rule register:
//   [0]     — enable (RW, reset = 0)
//   [7:1]   — reserved
//   [15:8]  — match byte (RW, reset = 0)
//   [23:16] — replace byte (RW, reset = 0)
//   [31:24] — reserved
// --------------------------------------------------------------------------
reg [DATA_W-1:0] rule_reg [NUM_RULES];

genvar k;
generate
    for (k = 0; k < NUM_RULES; k = k + 1) begin : gen_rule_reg
        always @(posedge PCLK or negedge PRESETn) begin
            if (~PRESETn) begin
                rule_reg[k] <= {DATA_W{1'b0}};
            end else if (reg_write_en && (reg_word_addr_x == (RULE_BASE_WORD + k))) begin
                for (int b = 0; b < (DATA_W / 8); b = b + 1) begin
                    if (CTRL_APB.pstrb[b])
                        rule_reg[k][b*8 +: 8] <= CTRL_APB.pwdata[b*8 +: 8];
                end
            end
        end

        // Unpack fields
        assign rule_enable[k]  = rule_reg[k][0];
        assign rule_match[k]   = rule_reg[k][15:8];
        assign rule_replace[k] = rule_reg[k][23:16];
    end
endgenerate

// --------------------------------------------------------------------------
// Read mux
// --------------------------------------------------------------------------
always @(*) begin
    reg_rdata = {DATA_W{1'b0}};
    if (reg_read_en) begin
        if (reg_word_addr == '0) begin
            // BASE_OFFSET
            reg_rdata = base_offset_reg;
        end else if (reg_word_addr_x == 32'd1) begin
            // CTRL
            reg_rdata = {{(DATA_W-1){1'b0}}, ctrl_enable_reg};
        end else if (reg_word_addr_x >= RULE_BASE_WORD &&
                     reg_word_addr_x < (RULE_BASE_WORD + NUM_RULES)) begin
            // RULE registers
            reg_rdata = rule_reg[reg_word_addr_x - RULE_BASE_WORD];
        end else begin
            // PID/CID or default
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
