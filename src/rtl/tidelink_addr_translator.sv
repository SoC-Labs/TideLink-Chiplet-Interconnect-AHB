//-----------------------------------------------------------------------------
// SoCLabs TideLink Address Translator
//
// APB-configurable address remapping subsystem. Provides two independent
// address translation channels, each with its own APB register bank for
// programming segment-based address mapping.
//
// AHB subordinate interface is bridged to APB, then fanned out via an APB
// slave mux to two address translation register sets (slots 0 and 1).
// Each slot drives a combinational address_translation block that remaps
// the upper 8 bits of a 32-bit address using a 256-entry segment table.
//
// Based on: nanosoc_ss_chiplet_addr (nanosoc-chiplet-tech)
//
// External dependencies (must be on the compile file list):
//   - apb4_if            (SV interface)  — from axi-chiplet-controller
//   - apb_control        (SV module)     — from axi-chiplet-controller
//   - address_translation(SV module)     — from axi-chiplet-controller
//   - cmsdk_ahb_to_apb   (Verilog)       — from ARM CMSDK
//   - cmsdk_apb_slave_mux(Verilog)       — from ARM CMSDK
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
    parameter BE = 0 )(
    input  wire         CLK,
    input  wire         RESETn,

    // Chiplet Address Control AHB interface
    input  wire         chp_adr_hsel,           // AHB region select
    input  wire  [31:0] chp_adr_haddr,          // AHB address
    input  wire  [ 2:0] chp_adr_hburst,         // AHB burst
    input  wire         chp_adr_hmastlock,      // AHB lock
    input  wire  [ 3:0] chp_adr_hprot,          // AHB prot
    input  wire  [ 2:0] chp_adr_hsize,          // AHB size
    input  wire  [ 1:0] chp_adr_htrans,         // AHB transfer
    input  wire  [31:0] chp_adr_hwdata,         // AHB write data
    input  wire         chp_adr_hwrite,         // AHB write
    input  wire         chp_adr_hready,         // AHB ready
    output  wire [31:0] chp_adr_hrdata,         // AHB read-data
    output  wire        chp_adr_hresp,          // AHB response
    output  wire        chp_adr_hreadyout,      // AHB ready out


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

wire     [15:0]  i_paddr;
wire             i_psel;
wire             i_penable;
wire             i_pwrite;
wire     [2:0]   i_pprot;
wire     [3:0]   i_pstrb;
wire     [31:0]  i_pwdata;

// wire from APB slave mux to APB bridge
wire             i_pready_mux;
wire     [31:0]  i_prdata_mux;
wire             i_pslverr_mux;

// endian handling
wire             APBACTIVE;

wire   [31:0]    hwdata_le; // Little endian write data
wire   [31:0]    hrdata_le; // Little endian read data

generate
if (BE != 0) begin : gen_be_swap
    wire bigendian = 1'b1;
    wire reg_be_swap_ctrl_en = chp_adr_hsel & chp_adr_htrans[1] & chp_adr_hready;
    reg     [1:0]    reg_be_swap_ctrl;
    wire    [1:0]    nxt_be_swap_ctrl;

    assign nxt_be_swap_ctrl[1] = (chp_adr_hsize[1:0]==2'b10); // Swap upper and lower half word
    assign nxt_be_swap_ctrl[0] = (chp_adr_hsize[1:0]!=2'b00); // Swap byte within halfword

    always @(posedge CLK or negedge RESETn)
    begin
    if (~RESETn)
        reg_be_swap_ctrl <= 2'b00;
    else if (reg_be_swap_ctrl_en)
        reg_be_swap_ctrl <= nxt_be_swap_ctrl;
    end

    // swap byte within half word
    wire  [31:0] hwdata_mux_1 = (reg_be_swap_ctrl[0]) ?
        {chp_adr_hwdata[23:16],chp_adr_hwdata[31:24],chp_adr_hwdata[7:0],chp_adr_hwdata[15:8]}:
        {chp_adr_hwdata[31:24],chp_adr_hwdata[23:16],chp_adr_hwdata[15:8],chp_adr_hwdata[7:0]};
    // swap lower and upper half word
    assign       hwdata_le    = (reg_be_swap_ctrl[1]) ?
        {hwdata_mux_1[15: 0],hwdata_mux_1[31:16]}:
        {hwdata_mux_1[31:16],hwdata_mux_1[15:0]};
    // swap byte within half word
    wire  [31:0] hrdata_mux_1 = (reg_be_swap_ctrl[0]) ?
        {hrdata_le[23:16],hrdata_le[31:24],hrdata_le[ 7:0],hrdata_le[15:8]}:
        {hrdata_le[31:24],hrdata_le[23:16],hrdata_le[15:8],hrdata_le[7:0]};
    // swap lower and upper half word
    assign    chp_adr_hrdata       = (reg_be_swap_ctrl[1]) ?
        {hrdata_mux_1[15: 0],hrdata_mux_1[31:16]}:
        {hrdata_mux_1[31:16],hrdata_mux_1[15:0]};
end else begin : gen_no_swap
    assign hwdata_le       = chp_adr_hwdata;
    assign chp_adr_hrdata  = hrdata_le;
end
endgenerate

  // AHB to APB bus bridge
  cmsdk_ahb_to_apb
  #(.ADDRWIDTH      (16),
    .REGISTER_RDATA (1),
    .REGISTER_WDATA (0))
  u_ahb_to_apb(
    // AHB side
    .HCLK     (CLK),
    .HRESETn  (RESETn),
    .HSEL     (chp_adr_hsel),
    .HADDR    (chp_adr_haddr[15:0]),
    .HTRANS   (chp_adr_htrans),
    .HSIZE    (chp_adr_hsize),
    .HPROT    (chp_adr_hprot),
    .HWRITE   (chp_adr_hwrite),
    .HREADY   (chp_adr_hready),
    .HWDATA   (hwdata_le),

    .HREADYOUT(chp_adr_hreadyout), // AHB Outputs
    .HRDATA   (hrdata_le),
    .HRESP    (chp_adr_hresp),

    .PADDR    (i_paddr[15:0]),
    .PSEL     (i_psel),
    .PENABLE  (i_penable),
    .PSTRB    (i_pstrb),
    .PPROT    (i_pprot),
    .PWRITE   (i_pwrite),
    .PWDATA   (i_pwdata),

    .APBACTIVE(APBACTIVE),
    .PCLKEN   (1'b1),     // APB clock enable signal

    .PRDATA   (i_prdata_mux),
    .PREADY   (i_pready_mux),
    .PSLVERR  (i_pslverr_mux)
    );

  // APB slave multiplexer
  cmsdk_apb_slave_mux #( // Parameter to determine which ports are used
    .PORT0_ENABLE  (1), // address translator 0
    .PORT1_ENABLE  (1), // address translator 1
    .PORT2_ENABLE  (0), // not used
    .PORT3_ENABLE  (0), // not used
    .PORT4_ENABLE  (0), // not used
    .PORT5_ENABLE  (0), // not used
    .PORT6_ENABLE  (0), // not used
    .PORT7_ENABLE  (0), // not used
    .PORT8_ENABLE  (0), // not used
    .PORT9_ENABLE  (0), // not used
    .PORT10_ENABLE (0), // not used
    .PORT11_ENABLE (0), // not used
    .PORT12_ENABLE (0), // not used
    .PORT13_ENABLE (0), // not used
    .PORT14_ENABLE (0), // not used
    .PORT15_ENABLE (0)
  ) u_apb_slave_mux (
    // Inputs
    .DECODE4BIT        (i_paddr[15:12]),
    .PSEL              (i_psel),
    // PSEL (output) and return status & data (inputs) for each port
    .PSEL0             (CHP_ADR_APB_0.psel),
    .PREADY0           (CHP_ADR_APB_0.pready),
    .PRDATA0           (CHP_ADR_APB_0.prdata),
    .PSLVERR0          (CHP_ADR_APB_0.pslverr),

    .PSEL1             (CHP_ADR_APB_1.psel),
    .PREADY1           (CHP_ADR_APB_1.pready),
    .PRDATA1           (CHP_ADR_APB_1.prdata),
    .PSLVERR1          (CHP_ADR_APB_1.pslverr),

    .PSEL2             (),
    .PREADY2           (1'b1),
    .PRDATA2           (32'h00000000),
    .PSLVERR2          (1'b1),

    .PSEL3             (),
    .PREADY3           (1'b1),
    .PRDATA3           (32'h00000000),
    .PSLVERR3          (1'b1),

    .PSEL4             (),
    .PREADY4           (1'b1),
    .PRDATA4           (32'h00000000),
    .PSLVERR4          (1'b1),

    .PSEL5             (),
    .PREADY5           (1'b1),
    .PRDATA5           (32'h00000000),
    .PSLVERR5          (1'b1),

    .PSEL6             (),
    .PREADY6           (1'b1),
    .PRDATA6           (32'h00000000),
    .PSLVERR6          (1'b1),

    .PSEL7             (),
    .PREADY7           (1'b1),
    .PRDATA7           (32'h00000000),
    .PSLVERR7          (1'b1),

    .PSEL8             (),
    .PREADY8           (1'b1),
    .PRDATA8           (32'h00000000),
    .PSLVERR8          (1'b1),

    .PSEL9             (),
    .PREADY9           (1'b1),
    .PRDATA9           (32'h00000000),
    .PSLVERR9          (1'b1),

    .PSEL10            (),
    .PREADY10          (1'b1),
    .PRDATA10          (32'h00000000),
    .PSLVERR10         (1'b1),

    .PSEL11            (),
    .PREADY11          (1'b1),
    .PRDATA11          (32'h00000000),
    .PSLVERR11         (1'b1),

    .PSEL12            (),
    .PREADY12          (1'b1),
    .PRDATA12          (32'h00000000),
    .PSLVERR12         (1'b1),

    .PSEL13            (),
    .PREADY13          (1'b1),
    .PRDATA13          (32'h00000000),
    .PSLVERR13         (1'b1),

    .PSEL14            (),
    .PREADY14          (1'b1),
    .PRDATA14          (32'h00000000),
    .PSLVERR14         (1'b1),

    .PSEL15            (),
    .PREADY15          (1'b1),
    .PRDATA15          (32'h00000000),
    .PSLVERR15         (1'b1),

    // Output
    .PREADY            (i_pready_mux),
    .PRDATA            (i_prdata_mux),
    .PSLVERR           (i_pslverr_mux)
  );


assign CHP_ADR_APB_0.penable = i_penable;
assign CHP_ADR_APB_0.paddr = i_paddr;
assign CHP_ADR_APB_0.pwrite = i_pwrite;
assign CHP_ADR_APB_0.pwdata = i_pwdata;
assign CHP_ADR_APB_0.pstrb = i_pstrb;
assign CHP_ADR_APB_0.pwdata = i_pwdata;

assign CHP_ADR_APB_1.penable = i_penable;
assign CHP_ADR_APB_1.paddr = i_paddr;
assign CHP_ADR_APB_1.pwrite = i_pwrite;
assign CHP_ADR_APB_1.pwdata = i_pwdata;
assign CHP_ADR_APB_1.pstrb = i_pstrb;
assign CHP_ADR_APB_1.pwdata = i_pwdata;

wire [31:0]  base_offset_0;
wire [7:0]   seg_addr_0 [256];
wire [31:0]  base_offset_1;
wire [7:0]   seg_addr_1 [256];

apb_control u_apb_addr_translator_0(
    .PCLK(CLK),
    .PRESETn(RESETn),
    .CTRL_APB(CHP_ADR_APB_0),
    .seg_addr(seg_addr_0),
    .base_offset(base_offset_0)
);

address_translation u_addr_translator_0(
    .addr_i(chp0_ahb_haddr_i),
    .addr_o(chp0_ahb_haddr_o),
    .base_offset(base_offset_0),
    .seg_addr(seg_addr_0)
);

apb_control u_apb_addr_translator_1(
    .PCLK(CLK),
    .PRESETn(RESETn),
    .CTRL_APB(CHP_ADR_APB_1),
    .seg_addr(seg_addr_1),
    .base_offset(base_offset_1)
);

address_translation u_addr_translator_1(
    .addr_i(chp1_ahb_haddr_i),
    .addr_o(chp1_ahb_haddr_o),
    .base_offset(base_offset_1),
    .seg_addr(seg_addr_1)
);

endmodule
