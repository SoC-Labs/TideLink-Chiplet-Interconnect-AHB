//-----------------------------------------------------------------------------
// SoCLabs TideLink FIFO AHB Wrapper
// - Wraps the tidelink_fifo top-level and adds a cmsdk_ahb_to_apb bridge so
//   that the APB configuration/status registers are accessible via a second
//   AHB slave port.
//
// Interfaces:
//   ahbs_*    — AHB slave for FIFO data path (pass-through to tidelink_fifo)
//   ahbc_*    — AHB slave for configuration registers (via AHB-to-APB bridge)
//   ahbm_*    — AHB master from returner (pass-through from tidelink_fifo)
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_fifo_ahb #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0,
    // TWIN 2 (F10) — forwarded to tidelink_fifo. DEFAULT 1, and DELIBERATELY NOT
    // TIED 0 here. Two reasons, both verified:
    //   1. This wrapper HARDWIRES the FC direct-write port OFF (fc_wr_valid/write
    //      = 1'b0 at the instance below). The AHB slave is therefore the ONLY way
    //      to get data into the FIFO through this wrapper — tie this 0 and the
    //      FIFO becomes unfillable by any means (measured: 4 of the 14 *_via_ahb
    //      tests in cocotb/tidelink_ahb fail, and no other path can replace them).
    //   2. This module IS instantiated (cocotb/tidelink_ahb/tb_top.sv:68), and the
    //      sibling tidelink.sv is instantiated at tidelink_ahb.sv:139 — an earlier
    //      revision of this comment claimed "instantiated NOWHERE", which is FALSE
    //      and was corrected 2026-07-19 after adversarial review (F6). The correct
    //      argument is point 1 ALONE: the FC port is hardwired off here, so this
    //      wrapper is not in the silicon RX datapath — that runs
    //      tidelink_top.sv -> tidelink_fifo (tied 0 there, which is what actually
    //      closes F10). A tie here would buy no silicon safety and would break the
    //      only path that fills this FIFO. Do not reason about coverage from the
    //      old "nowhere" claim.
    // An integrator who ever DOES use this wrapper as a real RX FIFO must first
    // expose and wire fc_wr_*, and only then set this to 0.
    parameter ENABLE_AHB_WRITE = 1
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,
    input  wire                     hresetn,

    // --------------------------------------------------------------------------
    // AHB Slave Interface — FIFO data path (directly to tidelink_fifo)
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
    // AHB Master Interface — Returner (from tidelink_fifo)
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
    output wire                     released_credits_irq,
    output wire                     doorbell_irq,
    output wire                     packet_committed_irq,

    // --------------------------------------------------------------------------
    // PTP Register Pass-Through (to/from tidelink_ptp via tidelink_top)
    // --------------------------------------------------------------------------
    output wire                     ptp_reg_write,
    output wire               [2:0] ptp_reg_addr,
    output wire  [SYS_DATA_W-1:0]  ptp_reg_wdata,
    input  wire  [SYS_DATA_W-1:0]  ptp_reg_rdata,
    output wire                     ptp_reg_region   // 0=Region 1 (basic PTP), 1=Region 2 (HW sync)
);

    // --------------------------------------------------------------------------
    // Internal APB bus wires (bridge → tidelink_fifo APB slave)
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
    // TideLink FIFO Instance
    // --------------------------------------------------------------------------
    tidelink_fifo #(
        .SYS_ADDR_W       (SYS_ADDR_W),
        .SYS_DATA_W       (SYS_DATA_W),
        .RAM_ADDR_W       (RAM_ADDR_W),
        .RAM_DATA_W       (RAM_DATA_W),
        .APB_ADDR_W       (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE),
        // TWIN 2 (F10): forwarded, not tied — see the parameter declaration above
        // for why (this wrapper hardwires fc_wr_* off, and is not in the silicon
        // RX datapath). F10 is closed at tidelink_top.sv's tidelink_fifo instance.
        .ENABLE_AHB_WRITE (ENABLE_AHB_WRITE)
    ) u_tidelink_fifo (
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
        .released_credits_irq (released_credits_irq),
        .doorbell_irq         (doorbell_irq),
        .packet_committed_irq (packet_committed_irq),

        // PTP register pass-through
        .ptp_reg_write       (ptp_reg_write),
        .ptp_reg_addr        (ptp_reg_addr),
        .ptp_reg_wdata       (ptp_reg_wdata),
        .ptp_reg_rdata       (ptp_reg_rdata),
        .ptp_reg_region      (ptp_reg_region),

        // Servo register pass-through (tied off — servo not present in AHB wrapper)
        .servo_reg_write     (),
        .servo_reg_addr      (),
        .servo_reg_wdata     (),
        .servo_reg_rdata     ({SYS_DATA_W{1'b0}}),

        // FC direct write path (tied off — no FC adapter in AHB wrapper)
        .fc_wr_valid         (1'b0),
        .fc_wr_write         (1'b0),
        .fc_wr_addr          ({RAM_ADDR_W{1'b0}}),
        .fc_wr_wdata         ({SYS_DATA_W{1'b0}}),
        .fc_wr_ready         (),

        // Mbox register pass-through (tied off)
        .mbox_reg_write      (),
        .mbox_reg_addr       (),
        .mbox_reg_wdata      (),

        // Ctrl/Perf register read-back peers (tied off — this wrapper exposes
        // only the FIFO/APB/returner surface; the ctrl/perf regfile peers
        // live in tidelink_top, not here).
        .ctrl_reg_rdata      ({SYS_DATA_W{1'b0}}),
        .perf_reg_rdata      ({SYS_DATA_W{1'b0}}),

        // PUF read-port (tied off — no PUF instance in the AHB-only wrapper).
        .puf_addr            ({(RAM_ADDR_W-2){1'b0}}),
        .puf_req             (1'b0)
    );

endmodule
