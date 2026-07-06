// =============================================================================
// tb_phc_model.sv — Behavioural Precision Hardware Clock (PHC) model for the
//                   integrated tidelink_top_pair PTP-over-link sync test.
//
// Purpose
// -------
// The production FPGA BD removes the real PHC (ptp-hardware-clock-ahb) for
// slice headroom, and the pair testbench previously TIED OFF every PHC port
// (phc_nanoseconds=0, phc_hw_cap_*=0, phc_locked_i=1'b1). With phc_locked_i
// hard-tied to 1 the HW_SYNC_STATUS[18] "locked" bit read back as a spurious
// pass even though zero PTP traffic crossed the link — see
// test_ptp_corrected_regs.py header.
//
// This module is a small, synthesis-agnostic *simulation* stand-in for the
// real PHC clock core. It is faithful to the exact PHC <-> tidelink_top
// contract (tidelink_top.sv:244-276):
//
//   * Free-running 48-bit seconds / 30-bit nanoseconds counter, advanced every
//     phc_clk by a programmable nominal nanosecond increment. A signed
//     fractional frequency-steer term (phc_hw_adj_ns_incr_frac, Q-fixed) lets
//     the servo trim the rate — exactly the NS_INCR_FRAC discipline the servo
//     drives (tidelink_ptp_servo.sv:632).
//
//   * On a phc_hw_capture pulse the *current* time is latched into the
//     hw_cap_seconds / hw_cap_nanoseconds outputs (the t1/t2/t3/t4 the servo
//     reads). This is the hardware-timestamp capture the PTP module triggers
//     at the short-packet handshake cycle (tidelink_ptp.sv:322).
//
//   * phc_hw_set_time jams the counter to (set_seconds, set_nanoseconds) —
//     the servo's coarse phase step (tidelink_ptp_servo.sv:589).
//
//   * phc_locked_i is driven REALISTICALLY (NOT tied to 1): it asserts only
//     after the PHC counter has been free-running for LOCK_AFTER_CYCLES phc
//     clocks past reset (modelling oscillator/PLL settle), and the testbench
//     can additionally gate it. This makes HW_SYNC_STATUS[18] meaningful.
//
// Only the nanosecond field is disciplined here (sub-nanosecond Q32 fraction
// is reported as 0); the servo arithmetic operates on 30-bit nanoseconds and
// drops sub-ns (tidelink_ptp_servo.sv:185), so a ns-granular model is exact
// for the convergence assertions.
//
// Copyright 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`timescale 1ns/1ps

module tb_phc_model #(
    parameter int SYS_DATA_W       = 32,
    // Nominal nanoseconds added per phc_clk tick (integer part of the rate).
    // Default 8 ns ~= a 125 MHz nominal PHC; the exact value is irrelevant to
    // the convergence proof, only that both PHCs share the same nominal and
    // start at different absolute times.
    parameter int NOMINAL_NS_INCR  = 8,
    // phc_locked_i asserts this many phc_clk ticks after reset deasserts.
    parameter int LOCK_AFTER_CYCLES = 64
)(
    input  wire                     phc_clk,
    input  wire                     phc_resetn,

    // Cocotb-loadable initial time (sampled at reset release).
    input  wire              [47:0] init_seconds,
    input  wire              [29:0] init_nanoseconds,
    // Cocotb gate — AND-ed into phc_locked_i (default high from the TB).
    input  wire                     lock_enable_i,

    // Capture trigger from tidelink_top (hclk-domain, already through CDC)
    input  wire                     phc_hw_capture,

    // Free-running time -> tidelink_top (drives PTP HW-sync FSM)
    output reg               [29:0] phc_nanoseconds,
    output reg               [47:0] phc_seconds,
    output reg                      phc_pps,

    // Captured timestamp snapshot -> tidelink_top servo
    output reg               [47:0] phc_hw_cap_seconds,
    output reg               [29:0] phc_hw_cap_nanoseconds,
    output reg  [SYS_DATA_W-1:0]    phc_hw_cap_sub_nanoseconds,

    // Discipline inputs from servo
    input  wire                     phc_hw_set_time,
    input  wire              [47:0] phc_hw_set_seconds,
    input  wire              [29:0] phc_hw_set_nanoseconds,
    input  wire                     phc_hw_adj_valid,
    input  wire [SYS_DATA_W-1:0]    phc_hw_adj_ns_incr_frac,

    // Realistic lock output (NOT tied)
    output reg                      phc_locked_o
);

    localparam [29:0] NS_PER_SECOND = 30'd1_000_000_000;

    // Sub-nanosecond accumulator (Q32). The servo's ns_incr_frac is a signed
    // correction to the nominal rate; we fold it into a fractional accumulator
    // so the integer-ns advance speeds up / slows down accordingly.
    reg signed [33:0] frac_acc;          // headroom for accumulation + carry
    reg signed [31:0] ns_incr_frac_r;    // latched frequency steer

    integer lock_ctr;

    // Combinational temporaries (module scope to stay portable across tools)
    reg signed [33:0] frac_next;
    reg signed [31:0] ns_advance;

    // Edge detect on the capture trigger (it is a 1-cycle pulse, but be safe)
    reg phc_hw_capture_d;

    always @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            phc_seconds              <= init_seconds;
            phc_nanoseconds          <= init_nanoseconds;
            phc_pps                  <= 1'b0;
            phc_hw_cap_seconds       <= '0;
            phc_hw_cap_nanoseconds   <= '0;
            phc_hw_cap_sub_nanoseconds <= '0;
            frac_acc                 <= '0;
            ns_incr_frac_r           <= '0;
            lock_ctr                 <= 0;
            phc_locked_o             <= 1'b0;
            phc_hw_capture_d         <= 1'b0;
        end else begin
            phc_hw_capture_d <= phc_hw_capture;

            // ---- Realistic lock: settle counter + TB gate ------------------
            if (lock_ctr < LOCK_AFTER_CYCLES)
                lock_ctr <= lock_ctr + 1;
            phc_locked_o <= (lock_ctr >= LOCK_AFTER_CYCLES) & lock_enable_i;

            // ---- Latch frequency steer -------------------------------------
            if (phc_hw_adj_valid)
                ns_incr_frac_r <= phc_hw_adj_ns_incr_frac;

            // ---- Compute this tick's nanosecond advance --------------------
            // integer advance = NOMINAL_NS_INCR + carry out of frac_acc.
            // frac_acc accumulates the signed fractional steer each tick;
            // when it overflows +/- 1.0 ns (Q32 -> 2^32) we carry into the
            // integer ns advance.
            // (Kept deliberately simple — only needs monotone, rate-trimmable.)
            frac_next  = frac_acc + {{2{ns_incr_frac_r[31]}}, ns_incr_frac_r};
            ns_advance = NOMINAL_NS_INCR;
            // Carry whole nanoseconds out of the Q32 fractional accumulator.
            if (frac_next >= $signed(34'sd4294967296)) begin // +1.0 ns
                ns_advance = ns_advance + 1;
                frac_next  = frac_next - 34'sd4294967296;
            end else if (frac_next <= -$signed(34'sd4294967296)) begin
                ns_advance = ns_advance - 1;
                frac_next  = frac_next + 34'sd4294967296;
            end

            // ---- Phase step (servo SET_TIME) takes priority -----------------
            if (phc_hw_set_time) begin
                phc_seconds     <= phc_hw_set_seconds;
                phc_nanoseconds <= phc_hw_set_nanoseconds;
                frac_acc        <= '0;
                phc_pps         <= 1'b0;
            end else begin
                frac_acc <= frac_next;
                // Advance ns with 1-second rollover.
                if (phc_nanoseconds + ns_advance[29:0] >= NS_PER_SECOND) begin
                    phc_nanoseconds <= (phc_nanoseconds + ns_advance[29:0]) - NS_PER_SECOND;
                    phc_seconds     <= phc_seconds + 48'd1;
                    phc_pps         <= 1'b1;
                end else begin
                    phc_nanoseconds <= phc_nanoseconds + ns_advance[29:0];
                    phc_pps         <= 1'b0;
                end
            end

            // ---- HW capture: latch current time on the trigger pulse -------
            if (phc_hw_capture && !phc_hw_capture_d) begin
                phc_hw_cap_seconds         <= phc_seconds;
                phc_hw_cap_nanoseconds     <= phc_nanoseconds;
                phc_hw_cap_sub_nanoseconds <= '0;
            end
        end
    end

endmodule
