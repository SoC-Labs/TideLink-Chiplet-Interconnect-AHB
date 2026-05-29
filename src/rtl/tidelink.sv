//-----------------------------------------------------------------------------
// SoCLabs TideLink Top-Level Module (legacy thin wrapper)
//
// Historical role: this module was the FIFO + Returner + APB-regs assembly
// before that combination was hoisted into src/rtl/fifo/tidelink_fifo.sv.
//
// Modern role: it is kept purely as a back-compat wrapper for
// src/rtl/tidelink_ahb.sv (and its cocotb env). It exposes the legacy port
// surface (clock/reset, single AHB slave + AHB master + APB slave + 3 IRQs)
// and internally instantiates the active tidelink_fifo, tying off the new
// pass-through ports (PTP / servo / mbox / ctrl / perf / fc_wr / puf) that
// the legacy port list does not carry.
//
// Live FPGA / ASIC builds use tidelink_top.sv -> tidelink_fifo_ahb.sv
// directly and never reach this file. See lint/Makefile near line 42 for the
// history of why this module exists.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0  // APB base address of the paired tidelink
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  logic                    hclk,
    input  logic                    hresetn,

    // --------------------------------------------------------------------------
    // AHB Slave Interface (FIFO data path)
    // --------------------------------------------------------------------------
    input  logic                    ahbs_hsel,
    input  logic                    ahbs_hready,
    input  logic              [1:0] ahbs_htrans,
    input  logic              [2:0] ahbs_hsize,
    input  logic                    ahbs_hwrite,
    input  logic   [RAM_ADDR_W-1:0] ahbs_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbs_hwdata,
    output wire                     ahbs_hreadyout,
    output wire                     ahbs_hresp,
    output wire    [SYS_DATA_W-1:0] ahbs_hrdata,

    // --------------------------------------------------------------------------
    // AHB Master Interface (Returner)
    // --------------------------------------------------------------------------
    output wire    [SYS_ADDR_W-1:0] ahbm_haddr,
    output wire    [SYS_DATA_W-1:0] ahbm_hwdata,
    output wire               [1:0] ahbm_htrans,
    output wire               [2:0] ahbm_hsize,
    output wire                     ahbm_hwrite,
    input  logic                    ahbm_hready,
    input  logic                    ahbm_hresp,
    input  logic   [SYS_DATA_W-1:0] ahbm_hrdata,

    // --------------------------------------------------------------------------
    // APB Slave Interface (Configuration and Status Registers)
    // --------------------------------------------------------------------------
    input  logic                    apbs_psel,
    input  logic                    apbs_penable,
    input  logic                    apbs_pwrite,
    input  logic   [APB_ADDR_W-1:0] apbs_paddr,
    input  logic   [SYS_DATA_W-1:0] apbs_pwdata,
    output wire    [SYS_DATA_W-1:0] apbs_prdata,
    output wire                     apbs_pready,
    output wire                     apbs_pslverr,

    // --------------------------------------------------------------------------
    // Interrupt Outputs
    // --------------------------------------------------------------------------
    output wire                     released_credits_irq,  // Pair freed credits (channel 0 deltas)
    output wire                     doorbell_irq,          // Pair responded to doorbell (channel 1 totals)
    output wire                     packet_committed_irq   // Packet committed to FIFO
);

    // --------------------------------------------------------------------------
    // tidelink_fifo subsumes the FIFO memory, APB register block, and the
    // Returner. The legacy port surface above does not carry the newer
    // PTP / servo / mbox / ctrl / perf / fc-direct-write / PUF pass-throughs,
    // so they are tied off locally here. Any future user of this wrapper
    // that needs those subsystems should instantiate tidelink_fifo_ahb or
    // tidelink_top directly.
    // --------------------------------------------------------------------------
    tidelink_fifo #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_fifo (
        .hclk                 (hclk),
        .hresetn              (hresetn),

        // AHB slave (FIFO data path)
        .ahbs_hsel            (ahbs_hsel),
        .ahbs_hready          (ahbs_hready),
        .ahbs_htrans          (ahbs_htrans),
        .ahbs_hsize           (ahbs_hsize),
        .ahbs_hwrite          (ahbs_hwrite),
        .ahbs_haddr           (ahbs_haddr),
        .ahbs_hwdata          (ahbs_hwdata),
        .ahbs_hreadyout       (ahbs_hreadyout),
        .ahbs_hresp           (ahbs_hresp),
        .ahbs_hrdata          (ahbs_hrdata),

        // AHB master (Returner)
        .ahbm_haddr           (ahbm_haddr),
        .ahbm_hwdata          (ahbm_hwdata),
        .ahbm_htrans          (ahbm_htrans),
        .ahbm_hsize           (ahbm_hsize),
        .ahbm_hwrite          (ahbm_hwrite),
        .ahbm_hready          (ahbm_hready),
        .ahbm_hresp           (ahbm_hresp),
        .ahbm_hrdata          (ahbm_hrdata),

        // APB slave (config / status)
        .apbs_psel            (apbs_psel),
        .apbs_penable         (apbs_penable),
        .apbs_pwrite          (apbs_pwrite),
        .apbs_paddr           (apbs_paddr),
        .apbs_pwdata          (apbs_pwdata),
        .apbs_prdata          (apbs_prdata),
        .apbs_pready          (apbs_pready),
        .apbs_pslverr         (apbs_pslverr),

        // Interrupts
        .released_credits_irq (released_credits_irq),
        .doorbell_irq         (doorbell_irq),
        .packet_committed_irq (packet_committed_irq),

        // PTP register pass-through — not exposed by this legacy wrapper
        .ptp_reg_write        (/* unused */),
        .ptp_reg_addr         (/* unused */),
        .ptp_reg_wdata        (/* unused */),
        .ptp_reg_rdata        ({SYS_DATA_W{1'b0}}),
        .ptp_reg_region       (/* unused */),

        // Servo register pass-through — not exposed
        .servo_reg_write      (/* unused */),
        .servo_reg_addr       (/* unused */),
        .servo_reg_wdata      (/* unused */),
        .servo_reg_rdata      ({SYS_DATA_W{1'b0}}),

        // Timestamp mailbox pass-through — not exposed
        .mbox_reg_write       (/* unused */),
        .mbox_reg_addr        (/* unused */),
        .mbox_reg_wdata       (/* unused */),

        // Chiplet controller register pass-through — not exposed
        .ctrl_reg_write       (/* unused */),
        .ctrl_reg_addr        (/* unused */),
        .ctrl_reg_wdata       (/* unused */),
        .ctrl_reg_rdata       ({SYS_DATA_W{1'b0}}),

        // Performance profiling register pass-through — not exposed
        .perf_reg_write       (/* unused */),
        .perf_reg_addr        (/* unused */),
        .perf_reg_wdata       (/* unused */),
        .perf_reg_rdata       ({SYS_DATA_W{1'b0}}),
        .perf_reg_region      (/* unused */),

        // Credit count observation (debug-only output) — not exposed
        .perf_credit_count    (/* unused */),

        // FC direct write interface — tied inactive (legacy wrapper has no FC)
        .fc_wr_valid          (1'b0),
        .fc_wr_write          (1'b0),
        .fc_wr_addr           ({RAM_ADDR_W{1'b0}}),
        .fc_wr_wdata          ({SYS_DATA_W{1'b0}}),
        .fc_wr_ready          (/* unused */),

        // PUF SRAM read interface — tied inactive
        .puf_addr             ({(RAM_ADDR_W-2){1'b0}}),
        .puf_req              (1'b0),
        .puf_rdata            (/* unused */),
        .puf_ack              (/* unused */)
    );

endmodule
