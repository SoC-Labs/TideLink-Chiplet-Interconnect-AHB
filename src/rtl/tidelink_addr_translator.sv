//-----------------------------------------------------------------------------
// SoCLabs TideLink Address Translator
//
// APB-configurable address remapping subsystem. Uses CAM-based rule
// matching for area-efficient address translation. Each channel has N
// programmable match/replace rules (default 8) instead of a full 256-entry
// segment table, reducing register storage from 2048 FFs to ~169 FFs per
// channel.
//
// APB subordinate interface is fanned out via an APB slave mux to the
// channel register sets. Each channel drives a combinational CAM-based
// translation block.
//
// Based on: nanosoc_ss_chiplet_addr (nanosoc-chiplet-tech)
//
// External dependencies (must be on the compile file list):
//   - apb4_if             (SV interface)  — from axi-chiplet-controller
//   - tl_addr_trans_regs  (SV module)     — from tidelink src/rtl
//   - tl_addr_trans_cam   (SV module)     — from tidelink src/rtl
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

module tidelink_addr_translator #(
    parameter NUM_CHANNELS = 2,
    parameter NUM_RULES    = 8
)(
    input  wire         CLK,
    input  wire         RESETn,

    // Chiplet Address Control APB interface
    input   wire  [15:0] chp_adr_paddr,          // APB address
    input   wire         chp_adr_psel,           // APB select
    input   wire         chp_adr_penable,        // APB enable
    input   wire         chp_adr_pwrite,         // APB write
    input   wire  [31:0] chp_adr_pwdata,         // APB write data
    input   wire  [ 3:0] chp_adr_pstrb,          // APB byte strobe
    input   wire  [ 2:0] chp_adr_pprot,          // APB protection
    output  wire  [31:0] chp_adr_prdata,         // APB read data
    output  wire         chp_adr_pready,         // APB ready
    output  wire         chp_adr_pslverr,        // APB slave error


    input  wire [31:0]  chp0_ahb_haddr_i,
    input  wire [31:0]  chp1_ahb_haddr_i,

    output wire [31:0]  chp0_ahb_haddr_o,
    output wire [31:0]  chp1_ahb_haddr_o

);

// --------------------------------------------------------------------------
// Internal wires
// --------------------------------------------------------------------------
apb4_if CHP_ADR_APB_0();
apb4_if CHP_ADR_APB_1();

// Signals from APB slave mux
logic            i_pready_mux;
logic    [31:0]  i_prdata_mux;
logic            i_pslverr_mux;

// APB response outputs
assign chp_adr_prdata  = i_prdata_mux;
assign chp_adr_pready  = i_pready_mux;
assign chp_adr_pslverr = i_pslverr_mux;

  // Lightweight APB slave mux — only NUM_CHANNELS ports instantiated.
  // Replaces cmsdk_apb_slave_mux which carries full 16-port decode logic
  // even when PORT_ENABLE=0 (runtime disable, not synthesis optimize-out).
  logic psel_ch0, psel_ch1;

  always_comb begin
    // Default: no selection, error response
    psel_ch0      = 1'b0;
    psel_ch1      = 1'b0;
    i_pready_mux  = 1'b1;
    i_prdata_mux  = 32'h00000000;
    i_pslverr_mux = 1'b1;

    if (chp_adr_psel) begin
      case (chp_adr_paddr[15:12])
        4'h0: begin
          psel_ch0      = 1'b1;
          i_pready_mux  = CHP_ADR_APB_0.pready;
          i_prdata_mux  = CHP_ADR_APB_0.prdata;
          i_pslverr_mux = CHP_ADR_APB_0.pslverr;
        end
        4'h1: begin
          if (NUM_CHANNELS > 1) begin
            psel_ch1      = 1'b1;
            i_pready_mux  = CHP_ADR_APB_1.pready;
            i_prdata_mux  = CHP_ADR_APB_1.prdata;
            i_pslverr_mux = CHP_ADR_APB_1.pslverr;
          end
        end
        default: ; // error response (pslverr=1)
      endcase
    end
  end

  assign CHP_ADR_APB_0.psel = psel_ch0;
  assign CHP_ADR_APB_1.psel = psel_ch1;


// --------------------------------------------------------------------------
// Channel 0 APB wiring (always present)
// --------------------------------------------------------------------------
assign CHP_ADR_APB_0.penable = chp_adr_penable;
// apb4_if.paddr is 32-bit; this block's chp_adr_paddr port is 16-bit. Widen the
// narrow side: zero-extension is what the implicit assignment already did, and
// the register decode below only ever compares the low bits.
assign CHP_ADR_APB_0.paddr = {16'h0, chp_adr_paddr};
assign CHP_ADR_APB_0.pwrite = chp_adr_pwrite;
assign CHP_ADR_APB_0.pwdata = chp_adr_pwdata;
assign CHP_ADR_APB_0.pstrb = chp_adr_pstrb;

wire [31:0]            base_offset_0;
wire                   global_enable_0;
wire [NUM_RULES-1:0]  rule_enable_0;
wire [7:0]             rule_match_0   [NUM_RULES];
wire [7:0]             rule_replace_0 [NUM_RULES];

tl_addr_trans_regs #(
    .NUM_RULES (NUM_RULES)
) u_regs_0 (
    .PCLK          (CLK),
    .PRESETn       (RESETn),
    .CTRL_APB      (CHP_ADR_APB_0),
    .base_offset   (base_offset_0),
    .global_enable (global_enable_0),
    .rule_enable   (rule_enable_0),
    .rule_match    (rule_match_0),
    .rule_replace  (rule_replace_0)
);

tl_addr_trans_cam #(
    .NUM_RULES (NUM_RULES)
) u_cam_0 (
    .addr_i        (chp0_ahb_haddr_i),
    .addr_o        (chp0_ahb_haddr_o),
    .base_offset   (base_offset_0),
    .global_enable (global_enable_0),
    .rule_enable   (rule_enable_0),
    .rule_match    (rule_match_0),
    .rule_replace  (rule_replace_0)
);

// --------------------------------------------------------------------------
// Channel 1 (conditional on NUM_CHANNELS > 1)
// --------------------------------------------------------------------------
generate
if (NUM_CHANNELS > 1) begin : gen_ch1

    assign CHP_ADR_APB_1.penable = chp_adr_penable;
    // Same 16->32 zero-extension as channel 0 above.
    assign CHP_ADR_APB_1.paddr = {16'h0, chp_adr_paddr};
    assign CHP_ADR_APB_1.pwrite = chp_adr_pwrite;
    assign CHP_ADR_APB_1.pwdata = chp_adr_pwdata;
    assign CHP_ADR_APB_1.pstrb = chp_adr_pstrb;

    wire [31:0]            base_offset_1;
    wire                   global_enable_1;
    wire [NUM_RULES-1:0]  rule_enable_1;
    wire [7:0]             rule_match_1   [NUM_RULES];
    wire [7:0]             rule_replace_1 [NUM_RULES];

    tl_addr_trans_regs #(
        .NUM_RULES (NUM_RULES)
    ) u_regs_1 (
        .PCLK          (CLK),
        .PRESETn       (RESETn),
        .CTRL_APB      (CHP_ADR_APB_1),
        .base_offset   (base_offset_1),
        .global_enable (global_enable_1),
        .rule_enable   (rule_enable_1),
        .rule_match    (rule_match_1),
        .rule_replace  (rule_replace_1)
    );

    tl_addr_trans_cam #(
        .NUM_RULES (NUM_RULES)
    ) u_cam_1 (
        .addr_i        (chp1_ahb_haddr_i),
        .addr_o        (chp1_ahb_haddr_o),
        .base_offset   (base_offset_1),
        .global_enable (global_enable_1),
        .rule_enable   (rule_enable_1),
        .rule_match    (rule_match_1),
        .rule_replace  (rule_replace_1)
    );

end else begin : gen_ch1_tieoff

    assign chp1_ahb_haddr_o = 32'h0;

    // Tie off APB mux port 1 return signals
    assign CHP_ADR_APB_1.pready  = 1'b1;
    assign CHP_ADR_APB_1.prdata  = 32'h00000000;
    assign CHP_ADR_APB_1.pslverr = 1'b1;

end
endgenerate

endmodule
