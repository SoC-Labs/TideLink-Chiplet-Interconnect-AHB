//-----------------------------------------------------------------------------
// PHC Hardware Clock - Vivado IP Integrator Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Vivado IP Integrator wrapper for the SoC Labs PHC (ptp-hardware-clock-ahb).
// Instantiates phc_fpga_top — a structural mirror of phc.sv that additionally
// re-exports the current seconds/nanoseconds on its top-level boundary
// (tidelink_top needs those as discrete inputs).
//
// Exposes:
//   - APB slave (xilinx.com:interface:apb:1.0)
//   - clk / resetn (annotated, ASSOCIATED_BUSIF apb)
//   - pps_irq / alarm_irq (xilinx.com:signal:interrupt:1.0)
//   - Discrete: hw_capture_0_i, hw_cap_*_0_o, hw_set_*_0_i,
//     hw_adj_valid_0_i, hw_adj_ns_incr_frac_0_i, seconds_o, nanoseconds_o,
//     pps_o.
//
// HA1588 servo source 1 is tied off here so the BD doesn't need a per-signal
// constant fan-out. Ethernet PTP capture is also tied 0 (no Ethernet MAC in
// the bridge1 FPGA design).
//
// Operator note: the PHC core defaults NS_INCR=4 (250 MHz ASIC target). The
// FPGA bring-up scripts MUST write NS_INCR=20 (50 MHz cycle = 20 ns) before
// enabling CTRL.EN — see docs/PTP_HW_TEST_PLAN.md §1.1 / §7 R2.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module phc_vivado_wrapper #(
    parameter SYS_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [7:0] DEFAULT_NS_INCR = 8'd4
)(
    // =========================================================================
    // Clock and Reset
    // =========================================================================
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.CLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.CLK, ASSOCIATED_RESET resetn, ASSOCIATED_BUSIF apb, FREQ_HZ 50000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        clk,

    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 RST.RESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.RESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *)
    input  wire        resetn,

    // =========================================================================
    // APB Slave
    // The Xilinx axi_apb_bridge drives a 32-bit PADDR; the PHC core decodes
    // only [APB_ADDR_W-1:0] internally.
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PADDR"   *) input  wire [31:0] apb_paddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PENABLE" *) input  wire        apb_penable,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PWRITE"  *) input  wire        apb_pwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PSTRB"   *) input  wire  [3:0] apb_pstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PPROT"   *) input  wire  [2:0] apb_pprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PWDATA"  *) input  wire [31:0] apb_pwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PSEL"    *) input  wire        apb_psel,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PRDATA"  *) output wire [31:0] apb_prdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PREADY"  *) output wire        apb_pready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PSLVERR" *) output wire        apb_pslverr,

    // =========================================================================
    // Interrupt outputs
    // =========================================================================
    (* X_INTERFACE_INFO      = "xilinx.com:signal:interrupt:1.0 pps_irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME pps_irq, SENSITIVITY LEVEL_HIGH" *)
    output wire        pps_irq,

    (* X_INTERFACE_INFO      = "xilinx.com:signal:interrupt:1.0 alarm_irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME alarm_irq, SENSITIVITY LEVEL_HIGH" *)
    output wire        alarm_irq,

    // =========================================================================
    // Hardware servo source 0 (TideLink) - capture + set + freq adjust
    // =========================================================================
    input  wire        hw_capture_0_i,
    output wire [47:0] hw_cap_seconds_0_o,
    output wire [29:0] hw_cap_nanoseconds_0_o,
    output wire [31:0] hw_cap_sub_nanoseconds_0_o,
    input  wire        hw_set_time_0_i,
    input  wire [47:0] hw_set_seconds_0_i,
    input  wire [29:0] hw_set_nanoseconds_0_i,
    input  wire        hw_adj_valid_0_i,
    input  wire [31:0] hw_adj_ns_incr_frac_0_i,

    // =========================================================================
    // Current counter + PPS outputs
    // =========================================================================
    output wire [47:0] seconds_o,
    output wire [29:0] nanoseconds_o,
    output wire        pps_o
);

    phc_fpga_top #(
        .SYS_DATA_W      (SYS_DATA_W),
        .APB_ADDR_W      (APB_ADDR_W),
        .DEFAULT_NS_INCR (DEFAULT_NS_INCR)
    ) u_phc_top (
        .clk        (clk),
        .resetn     (resetn),

        // APB — truncate the 32-bit IPI PADDR to the core's internal width
        .psel       (apb_psel),
        .penable    (apb_penable),
        .pwrite     (apb_pwrite),
        .paddr      (apb_paddr[APB_ADDR_W-1:0]),
        .pwdata     (apb_pwdata),
        .prdata     (apb_prdata),
        .pready     (apb_pready),
        .pslverr    (apb_pslverr),

        // IRQs
        .pps_irq    (pps_irq),
        .alarm_irq  (alarm_irq),

        // Servo source 0 (TideLink)
        .hw_capture_0_i             (hw_capture_0_i),
        .hw_cap_seconds_0_o         (hw_cap_seconds_0_o),
        .hw_cap_nanoseconds_0_o     (hw_cap_nanoseconds_0_o),
        .hw_cap_sub_nanoseconds_0_o (hw_cap_sub_nanoseconds_0_o),
        .hw_set_time_0_i            (hw_set_time_0_i),
        .hw_set_seconds_0_i         (hw_set_seconds_0_i),
        .hw_set_nanoseconds_0_i     (hw_set_nanoseconds_0_i),
        .hw_adj_valid_0_i           (hw_adj_valid_0_i),
        .hw_adj_ns_incr_frac_0_i    (hw_adj_ns_incr_frac_0_i),

        // Servo source 1 (HA1588) — tied off
        .hw_capture_1_i             (1'b0),
        .hw_cap_seconds_1_o         (),
        .hw_cap_nanoseconds_1_o     (),
        .hw_cap_sub_nanoseconds_1_o (),
        .hw_set_time_1_i            (1'b0),
        .hw_set_seconds_1_i         (48'h0),
        .hw_set_nanoseconds_1_i     (30'h0),
        .hw_adj_valid_1_i           (1'b0),
        .hw_adj_ns_incr_frac_1_i    (32'h0),

        // External servo status (unused on FPGA)
        .servo_locked_i             (1'b0),
        .servo_phase_step_active_i  (1'b0),

        // Ethernet capture (no Ethernet MAC in BD)
        .eth_rx_capture             (1'b0),
        .eth_tx_capture             (1'b0),

        // PPS + re-exported current counter
        .pps_out                    (pps_o),
        .seconds_o                  (seconds_o),
        .nanoseconds_o              (nanoseconds_o)
    );

endmodule
