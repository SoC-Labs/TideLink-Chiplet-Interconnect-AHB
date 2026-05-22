//-----------------------------------------------------------------------------
// PHC Hardware Clock - FPGA Top (BD-friendly wrapper)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module mirrors phc.sv but additionally re-exports the current time
// (seconds / nanoseconds) on its top-level boundary. tidelink_top requires
// those signals as discrete inputs (HW sync initiator timing); the
// upstream phc.sv keeps them internal and exposes them only via APB.
//
// Apart from the extra top-level ports this is a structural copy of phc.sv
// (clock-core + apb-regs + servo source-0/1 mux) so the behaviour is
// bit-identical to the verified UVM/cocotb regression.
//
// Source 1 (HA1588) is left on the boundary in case it is wired later;
// the FPGA wrapper (phc_vivado_wrapper.v) ties it off.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module phc_fpga_top #(
    parameter SYS_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [7:0] DEFAULT_NS_INCR = 8'd4
)(
    input  logic                    clk,
    input  logic                    resetn,

    // APB slave
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic   [APB_ADDR_W-1:0] paddr,
    input  logic   [SYS_DATA_W-1:0] pwdata,
    output wire    [SYS_DATA_W-1:0] prdata,
    output wire                     pready,
    output wire                     pslverr,

    // Interrupts
    output wire                     pps_irq,
    output wire                     alarm_irq,

    // Hardware servo source 0 (TideLink autonomous servo)
    input  wire                     hw_capture_0_i,
    output wire             [47:0]  hw_cap_seconds_0_o,
    output wire             [29:0]  hw_cap_nanoseconds_0_o,
    output wire   [SYS_DATA_W-1:0]  hw_cap_sub_nanoseconds_0_o,
    input  wire                     hw_set_time_0_i,
    input  wire             [47:0]  hw_set_seconds_0_i,
    input  wire             [29:0]  hw_set_nanoseconds_0_i,
    input  wire                     hw_adj_valid_0_i,
    input  wire   [SYS_DATA_W-1:0]  hw_adj_ns_incr_frac_0_i,

    // Hardware servo source 1 (HA1588 — tied off on FPGA)
    input  wire                     hw_capture_1_i,
    output wire             [47:0]  hw_cap_seconds_1_o,
    output wire             [29:0]  hw_cap_nanoseconds_1_o,
    output wire   [SYS_DATA_W-1:0]  hw_cap_sub_nanoseconds_1_o,
    input  wire                     hw_set_time_1_i,
    input  wire             [47:0]  hw_set_seconds_1_i,
    input  wire             [29:0]  hw_set_nanoseconds_1_i,
    input  wire                     hw_adj_valid_1_i,
    input  wire   [SYS_DATA_W-1:0]  hw_adj_ns_incr_frac_1_i,

    // External servo status (HA1588 path; FPGA ties 0)
    input  wire                     servo_locked_i,
    input  wire                     servo_phase_step_active_i,

    // Ethernet PTP capture (FPGA ties 0)
    input  wire                     eth_rx_capture,
    input  wire                     eth_tx_capture,

    // PPS
    output wire                     pps_out,

    // Current counter — re-exported (in addition to APB read-back)
    output wire             [47:0]  seconds_o,
    output wire             [29:0]  nanoseconds_o
);

    // ------------------------------------------------------------------------
    // Internal wiring (same set as phc.sv)
    // ------------------------------------------------------------------------
    logic                   ctrl_enable;
    logic                   ctrl_set_time;
    logic                   ctrl_capture;
    logic             [7:0] ns_incr;
    logic [SYS_DATA_W-1:0]  ns_incr_frac;
    logic            [47:0] set_seconds;
    logic            [29:0] set_nanoseconds;

    logic            [47:0] seconds;
    logic            [29:0] nanoseconds;
    logic [SYS_DATA_W-1:0]  sub_nanoseconds;

    logic            [47:0] cap_seconds;
    logic            [29:0] cap_nanoseconds;
    logic [SYS_DATA_W-1:0]  cap_sub_nanoseconds;

    logic            [47:0] hw_cap_seconds;
    logic            [29:0] hw_cap_nanoseconds;
    logic [SYS_DATA_W-1:0]  hw_cap_sub_nanoseconds;

    logic            [47:0] eth_rx_cap_seconds;
    logic            [29:0] eth_rx_cap_nanoseconds;
    logic [SYS_DATA_W-1:0]  eth_rx_cap_sub_nanoseconds;

    logic            [47:0] eth_tx_cap_seconds;
    logic            [29:0] eth_tx_cap_nanoseconds;
    logic [SYS_DATA_W-1:0]  eth_tx_cap_sub_nanoseconds;

    logic                   pps;
    logic                   alarm_hit;

    assign pps_out       = pps;
    assign seconds_o     = seconds;
    assign nanoseconds_o = nanoseconds;

    // Both source-0 and source-1 see the same hw_cap_* values (mirrors phc.sv)
    assign hw_cap_seconds_0_o         = hw_cap_seconds;
    assign hw_cap_nanoseconds_0_o     = hw_cap_nanoseconds;
    assign hw_cap_sub_nanoseconds_0_o = hw_cap_sub_nanoseconds;
    assign hw_cap_seconds_1_o         = hw_cap_seconds;
    assign hw_cap_nanoseconds_1_o     = hw_cap_nanoseconds;
    assign hw_cap_sub_nanoseconds_1_o = hw_cap_sub_nanoseconds;

    // ------------------------------------------------------------------------
    // Servo source mux (mirrors phc.sv:170)
    // ------------------------------------------------------------------------
    logic                   servo_src_sel;
    logic                   ha1588_servo_en;
    logic            [29:0] sync_interval;

    logic                   muxed_hw_capture;
    logic                   muxed_hw_set_time;
    logic            [47:0] muxed_hw_set_seconds;
    logic            [29:0] muxed_hw_set_nanoseconds;
    logic                   muxed_hw_adj_valid;
    logic [SYS_DATA_W-1:0]  muxed_hw_adj_ns_incr_frac;

    always_comb begin
        if (servo_src_sel) begin
            muxed_hw_capture          = hw_capture_1_i;
            muxed_hw_set_time         = hw_set_time_1_i;
            muxed_hw_set_seconds      = hw_set_seconds_1_i;
            muxed_hw_set_nanoseconds  = hw_set_nanoseconds_1_i;
            muxed_hw_adj_valid        = hw_adj_valid_1_i;
            muxed_hw_adj_ns_incr_frac = hw_adj_ns_incr_frac_1_i;
        end else begin
            muxed_hw_capture          = hw_capture_0_i;
            muxed_hw_set_time         = hw_set_time_0_i;
            muxed_hw_set_seconds      = hw_set_seconds_0_i;
            muxed_hw_set_nanoseconds  = hw_set_nanoseconds_0_i;
            muxed_hw_adj_valid        = hw_adj_valid_0_i;
            muxed_hw_adj_ns_incr_frac = hw_adj_ns_incr_frac_0_i;
        end
    end

    // ------------------------------------------------------------------------
    // Clock core
    // ------------------------------------------------------------------------
    phc_clock_core #(
        .SYS_DATA_W (SYS_DATA_W)
    ) u_clock_core (
        .clk                (clk),
        .resetn             (resetn),

        .enable             (ctrl_enable),
        .set_time           (ctrl_set_time),
        .capture            (ctrl_capture),
        .hw_capture         (muxed_hw_capture),

        .ns_incr            (ns_incr),
        .ns_incr_frac       (ns_incr_frac),

        .set_seconds        (set_seconds),
        .set_nanoseconds    (set_nanoseconds),

        .hw_set_time        (muxed_hw_set_time),
        .hw_set_seconds     (muxed_hw_set_seconds),
        .hw_set_nanoseconds (muxed_hw_set_nanoseconds),
        .hw_adj_valid       (muxed_hw_adj_valid),
        .hw_adj_ns_incr_frac(muxed_hw_adj_ns_incr_frac),

        .seconds            (seconds),
        .nanoseconds        (nanoseconds),
        .sub_nanoseconds    (sub_nanoseconds),

        .cap_seconds        (cap_seconds),
        .cap_nanoseconds    (cap_nanoseconds),
        .cap_sub_nanoseconds(cap_sub_nanoseconds),

        .hw_cap_seconds        (hw_cap_seconds),
        .hw_cap_nanoseconds    (hw_cap_nanoseconds),
        .hw_cap_sub_nanoseconds(hw_cap_sub_nanoseconds),

        .eth_rx_capture            (eth_rx_capture),
        .eth_tx_capture            (eth_tx_capture),
        .eth_rx_cap_seconds        (eth_rx_cap_seconds),
        .eth_rx_cap_nanoseconds    (eth_rx_cap_nanoseconds),
        .eth_rx_cap_sub_nanoseconds(eth_rx_cap_sub_nanoseconds),
        .eth_tx_cap_seconds        (eth_tx_cap_seconds),
        .eth_tx_cap_nanoseconds    (eth_tx_cap_nanoseconds),
        .eth_tx_cap_sub_nanoseconds(eth_tx_cap_sub_nanoseconds),

        .pps                (pps)
    );

    // ------------------------------------------------------------------------
    // APB register file
    // ------------------------------------------------------------------------
    phc_apb_regs #(
        .SYS_DATA_W      (SYS_DATA_W),
        .APB_ADDR_W      (APB_ADDR_W),
        .DEFAULT_NS_INCR (DEFAULT_NS_INCR)
    ) u_apb_regs (
        .clk                (clk),
        .resetn             (resetn),

        .psel               (psel),
        .penable            (penable),
        .pwrite             (pwrite),
        .paddr              (paddr),
        .pwdata             (pwdata),
        .prdata             (prdata),
        .pready             (pready),
        .pslverr            (pslverr),

        .hw_capture         (muxed_hw_capture),

        .ctrl_enable        (ctrl_enable),
        .ctrl_set_time      (ctrl_set_time),
        .ctrl_capture       (ctrl_capture),
        .ns_incr            (ns_incr),
        .ns_incr_frac       (ns_incr_frac),
        .set_seconds        (set_seconds),
        .set_nanoseconds    (set_nanoseconds),

        .seconds            (seconds),
        .nanoseconds        (nanoseconds),
        .sub_nanoseconds    (sub_nanoseconds),

        .cap_seconds        (cap_seconds),
        .cap_nanoseconds    (cap_nanoseconds),
        .cap_sub_nanoseconds(cap_sub_nanoseconds),

        .hw_cap_seconds        (hw_cap_seconds),
        .hw_cap_nanoseconds    (hw_cap_nanoseconds),
        .hw_cap_sub_nanoseconds(hw_cap_sub_nanoseconds),

        .eth_rx_capture            (eth_rx_capture),
        .eth_tx_capture            (eth_tx_capture),
        .eth_rx_cap_seconds        (eth_rx_cap_seconds),
        .eth_rx_cap_nanoseconds    (eth_rx_cap_nanoseconds),
        .eth_rx_cap_sub_nanoseconds(eth_rx_cap_sub_nanoseconds),
        .eth_tx_cap_seconds        (eth_tx_cap_seconds),
        .eth_tx_cap_nanoseconds    (eth_tx_cap_nanoseconds),
        .eth_tx_cap_sub_nanoseconds(eth_tx_cap_sub_nanoseconds),

        .pps                (pps),
        .alarm_hit          (alarm_hit),
        .pps_irq            (pps_irq),
        .alarm_irq          (alarm_irq),

        .servo_src_sel          (servo_src_sel),
        .ha1588_servo_en        (ha1588_servo_en),
        .sync_interval          (sync_interval),
        .servo_locked           (servo_locked_i),
        .servo_phase_step_active(servo_phase_step_active_i)
    );

endmodule
