//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB Wrapper
// - Wraps the tidelink top-level and adds a cmsdk_ahb_to_apb bridge so that
//   the APB configuration/status registers are accessible via a second AHB
//   slave port.
//
// Interfaces:
//   ahbs_*    — AHB slave for FIFO data path (pass-through to tidelink)
//   ahbc_*    — AHB slave for configuration registers (via AHB-to-APB bridge)
//   ahbm_*    — AHB master from returner (pass-through from tidelink)
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_ahb #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,
    input  wire                     hresetn,

    // --------------------------------------------------------------------------
    // AHB Slave Interface — FIFO data path (directly to tidelink)
    // --------------------------------------------------------------------------
    input  wire                     ahbs_hsel,
    input  wire                     ahbs_hready,
    input  wire               [1:0] ahbs_htrans,
    input  wire               [2:0] ahbs_hsize,
    input  wire                     ahbs_hwrite,
    input  wire    [RAM_ADDR_W-1:0] ahbs_haddr,
    input  wire    [SYS_DATA_W-1:0] ahbs_hwdata,
    output wire                     ahbs_hreadyout,
    output wire                     ahbs_hresp,
    output wire    [SYS_DATA_W-1:0] ahbs_hrdata,

    // --------------------------------------------------------------------------
    // AHB Slave Interface — Configuration registers (via AHB-to-APB bridge)
    // --------------------------------------------------------------------------
    input  wire                     ahbc_hsel,
    input  wire                     ahbc_hready,
    input  wire               [1:0] ahbc_htrans,
    input  wire               [2:0] ahbc_hsize,
    input  wire                     ahbc_hwrite,
    input  wire    [APB_ADDR_W-1:0] ahbc_haddr,
    input  wire    [SYS_DATA_W-1:0] ahbc_hwdata,
    output wire                     ahbc_hreadyout,
    output wire                     ahbc_hresp,
    output wire    [SYS_DATA_W-1:0] ahbc_hrdata,

    // --------------------------------------------------------------------------
    // AHB Master Interface — Returner (from tidelink)
    // --------------------------------------------------------------------------
    output wire    [SYS_ADDR_W-1:0] ahbm_haddr,
    output wire    [SYS_DATA_W-1:0] ahbm_hwdata,
    output wire               [1:0] ahbm_htrans,
    output wire               [2:0] ahbm_hsize,
    output wire                     ahbm_hwrite,
    input  wire                     ahbm_hready,
    input  wire                     ahbm_hresp,
    input  wire    [SYS_DATA_W-1:0] ahbm_hrdata,

    // --------------------------------------------------------------------------
    // Interrupt Outputs
    // --------------------------------------------------------------------------
    output wire                     released_tokens_irq,
    output wire                     doorbell_irq
);

    // --------------------------------------------------------------------------
    // Internal APB bus wires (bridge → tidelink APB slave)
    // --------------------------------------------------------------------------
    wire [APB_ADDR_W-1:0] apb_paddr;
    wire                  apb_psel;
    wire                  apb_penable;
    wire                  apb_pwrite;
    wire [SYS_DATA_W-1:0] apb_pwdata;
    wire [SYS_DATA_W-1:0] apb_prdata;
    wire                  apb_pready;
    wire                  apb_pslverr;

    // --------------------------------------------------------------------------
    // AHB-to-APB Bridge (CMSDK)
    // --------------------------------------------------------------------------
    cmsdk_ahb_to_apb #(
        .ADDRWIDTH      (APB_ADDR_W),
        .REGISTER_RDATA (1),
        .REGISTER_WDATA (0)
    ) u_ahb_to_apb (
        // AHB Slave side
        .HCLK      (hclk),
        .HRESETn   (hresetn),
        .PCLKEN    (1'b1),

        .HSEL      (ahbc_hsel),
        .HADDR     (ahbc_haddr),
        .HTRANS    (ahbc_htrans),
        .HSIZE     (ahbc_hsize),
        .HPROT     (4'b0011),
        .HWRITE    (ahbc_hwrite),
        .HREADY    (ahbc_hready),
        .HWDATA    (ahbc_hwdata),

        .HREADYOUT (ahbc_hreadyout),
        .HRDATA    (ahbc_hrdata),
        .HRESP     (ahbc_hresp),

        // APB Master side
        .PADDR     (apb_paddr),
        .PSEL      (apb_psel),
        .PENABLE   (apb_penable),
        .PWRITE    (apb_pwrite),
        .PSTRB     (),
        .PPROT     (),
        .PWDATA    (apb_pwdata),
        .APBACTIVE (),

        .PRDATA    (apb_prdata),
        .PREADY    (apb_pready),
        .PSLVERR   (apb_pslverr)
    );

    // --------------------------------------------------------------------------
    // TideLink Instance
    // --------------------------------------------------------------------------
    tidelink #(
        .SYS_ADDR_W       (SYS_ADDR_W),
        .SYS_DATA_W       (SYS_DATA_W),
        .RAM_ADDR_W       (RAM_ADDR_W),
        .RAM_DATA_W       (RAM_DATA_W),
        .APB_ADDR_W       (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_tidelink (
        .hclk            (hclk),
        .hresetn         (hresetn),

        // AHB Slave — FIFO
        .ahbs_hsel       (ahbs_hsel),
        .ahbs_hready     (ahbs_hready),
        .ahbs_htrans     (ahbs_htrans),
        .ahbs_hsize      (ahbs_hsize),
        .ahbs_hwrite     (ahbs_hwrite),
        .ahbs_haddr      (ahbs_haddr),
        .ahbs_hwdata     (ahbs_hwdata),
        .ahbs_hreadyout  (ahbs_hreadyout),
        .ahbs_hresp      (ahbs_hresp),
        .ahbs_hrdata     (ahbs_hrdata),

        // AHB Master — Returner
        .ahbm_haddr      (ahbm_haddr),
        .ahbm_hwdata     (ahbm_hwdata),
        .ahbm_htrans     (ahbm_htrans),
        .ahbm_hsize      (ahbm_hsize),
        .ahbm_hwrite     (ahbm_hwrite),
        .ahbm_hready     (ahbm_hready),
        .ahbm_hresp      (ahbm_hresp),
        .ahbm_hrdata     (ahbm_hrdata),

        // APB Slave — from bridge
        .apbs_psel       (apb_psel),
        .apbs_penable    (apb_penable),
        .apbs_pwrite     (apb_pwrite),
        .apbs_paddr      (apb_paddr),
        .apbs_pwdata     (apb_pwdata),
        .apbs_prdata     (apb_prdata),
        .apbs_pready     (apb_pready),
        .apbs_pslverr    (apb_pslverr),

        // Interrupts
        .released_tokens_irq (released_tokens_irq),
        .doorbell_irq        (doorbell_irq)
    );

endmodule
