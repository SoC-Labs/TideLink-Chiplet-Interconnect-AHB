// =============================================================================
// tb_top.sv — bank-35 / bank-13 IDELAYCTRL asymmetry behavioural reproducer
// =============================================================================
//
// Purpose
// -------
// Behavioural cocotb testbench that reproduces — synthetically, with no
// Wav PHY in the loop — the per-bank IDELAYCTRL asymmetry observed on the
// Pynq-Z2 TideLink bring-up. On real silicon, Vivado places 6 of 8 master
// RX lanes in IDELAY column X0 (sharing IDELAYCTRL_X0Y0) and 2 in column X1
// (sharing a replicated IDELAYCTRL_X1Y2). Per-IDELAYCTRL VT variation gives
// marginally different tap-times per group, so the bank-35 lanes (master
// lane 1 + 3) and bank-13 lanes (6 lanes) have:
//   * different eye WIDTH    (bank-35 narrower → ~1 (slip,phase) point)
//   * different eye CENTRE   (bank-35 shifted by 1-2 points)
//
// The HW evidence is bringup_health_probe.log: master oscillates 0xf5 /
// 0xfd / 0xd5 / 0xd7 (lane 1 and 3 marginal); slave oscillates 0xce / 0x7f
// / 0xee (lane 0 and 4 marginal). The calibrator drives one uniform per-
// lane sweep without knowing about bank groups — see project memory entry
// `project_tidelink_fpga_bringup.md` for the full HW trajectory.
//
// What this TB models
// -------------------
// * ONE tidelink_phy_align_calibrator DUT (real RTL).
// * A SYNTHETIC eye-shape driver (no PHY, no Wlink) that watches the
//   calibrator's CURRENT (sweep_slip, sweep_phase) iterator and produces
//   a per-lane lane_locked[7:0] vector according to a parameterised eye
//   model per lane:
//
//     LANE_EYE_CENTRE_SLIP [i]  : the slip at which lane i's eye is centred
//     LANE_EYE_CENTRE_PHASE[i]  : the phase at which lane i's eye is centred
//     LANE_EYE_WIDTH       [i]  : half-width of the eye in points
//                                 (lane locks if both slip-distance and
//                                  phase-distance from centre are <= width)
//                                 1 = bank-35 narrow ("1-by-1 point");
//                                 3 = bank-13 normal ("wide eye")
//     LANE_SKEW_PHASE      [i]  : extra phase shift applied to the iterator
//                                 BEFORE the eye check (models per-bank
//                                 IDELAYCTRL tap-time variation)
//     LANE_NOISE_MASK      [i]  : if non-zero, the lane bounces in/out of
//                                 lock once every N dwell cycles outside the
//                                 eye centre (models marginal-edge bounce —
//                                 the bringup_health_probe oscillation)
//
// The driver is CLOCKED on the SAME `clk` the calibrator uses (which on
// silicon is the recovered link-rx clock). Per-lane parameters are
// registers, so the cocotb test can poke them via hierarchical assignment
// without re-elaborating.
//
// Why we don't reuse tb_top_compare.sv
// ------------------------------------
// The compare TB drives lane_locked from cocotb pure-Python, which means
// re-running 200 scenarios = 200 separate cocotb tests and the stimulus
// computation has to round-trip through the simulator boundary at every
// edge. This TB does the per-lane eye check in pure RTL, so one cocotb
// test can sweep many seeds quickly.
//
// We instantiate the SAME calibrator twice (best-of-sweep + first-match)
// so the same eye trajectory directly compares the two selection policies.
//
// Parameter knobs to keep sim wall-time low:
//   DWELL_CYCLES = 32   — full 128-point sweep in 128*32 = 4096 cycles.
//   LOCK_THRESH  = 16   — silicon default (matches lane_checker).
//
// SoC Labs §9 bank-asymmetry behavioural reproducer (2026-05-20).
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================

`timescale 1ns/1ps

module tb_top #(
    parameter int DWELL_CYCLES = 32,
    parameter int LOCK_THRESH  = 16
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        role_locked,
    input  wire        swreset,

    // Per-lane eye-shape control (driven by cocotb via hierarchical poke
    // before the role_locked rising edge). Packed 8-lane vectors:
    //   eye_centre_slip   3b * 8 = 24b
    //   eye_centre_phase  4b * 8 = 32b
    //   eye_width         3b * 8 = 24b    (0..7; 0 = single-point eye)
    //   eye_skew_phase    4b * 8 = 32b    (signed-ish: 4-bit phase shift)
    //   noise_enable      1b * 8 =  8b    (1 = lane bounces just outside eye)
    input  wire [23:0] eye_centre_slip,
    input  wire [31:0] eye_centre_phase,
    input  wire [23:0] eye_width,
    input  wire [31:0] eye_skew_phase,
    input  wire [7:0]  eye_noise_enable,

    // Best-of-sweep DUT outputs (silicon default)
    output wire [23:0] best_bit_slip,
    output wire [31:0] best_phase_offset,
    output wire        best_training_mode,
    output wire        best_calibration_done,
    output wire [7:0]  best_lane_fault,
    output wire [3:0]  best_state,

    // First-match DUT outputs (legacy §9.7)
    output wire [23:0] first_bit_slip,
    output wire [31:0] first_phase_offset,
    output wire        first_training_mode,
    output wire        first_calibration_done,
    output wire [7:0]  first_lane_fault,
    output wire [3:0]  first_state,

    // Per-lane lane_locked output from the synthetic driver (visible for
    // waveform / debug; both DUTs receive the same vector internally).
    output wire [7:0]  synth_lane_locked
);

    // -------------------------------------------------------------------------
    // §9 synthetic per-lane eye driver
    //
    // For each lane i, every clock cycle:
    //   1. Take the BEST DUT's current iterator (sweep_slip_b, sweep_phase_b).
    //   2. Apply per-lane phase skew (eye_skew_phase[i]): eff_phase = phase +
    //      skew (mod 16).
    //   3. Compute distance from this lane's eye centre (Chebyshev / L_inf):
    //         d_slip  = |eff_slip  - LANE_EYE_CENTRE_SLIP [i]|  (slip is 3-bit)
    //         d_phase = |eff_phase - LANE_EYE_CENTRE_PHASE[i]|  (mod 16)
    //   4. If max(d_slip, d_phase) <= LANE_EYE_WIDTH[i], lane is LOCKED.
    //      Otherwise lane is UNLOCKED, except when LANE_NOISE_ENABLE[i] is
    //      set and max(d_slip,d_phase) == LANE_EYE_WIDTH[i]+1: lane bounces
    //      (HIGH for the first ~LOCK_THRESH-2 cycles of each dwell, then
    //      LOW for the rest). This models the bringup_health_probe lock-
    //      edge oscillation: just barely clears LOCK_THRESH at the eye edge.
    //
    // Why the dwell_ctr is needed: the calibrator's score is the run-length
    // of consecutive lane_locked=1 cycles within a dwell window. Steady
    // HIGH for a dwell scores DWELL_CYCLES (saturates at 6'h3F=63 for
    // DWELL>=63; <=DWELL_CYCLES linearly). For best-of-sweep to prefer
    // a "wide" eye over a "marginal" eye, the wide eye must achieve a
    // LONGER in-dwell run than the marginal one — so we paint full-dwell
    // HIGH inside the eye and short (LOCK_THRESH-2) HIGH at the edge.
    //
    // Width of cocotb-visible state: we hook the BEST DUT's iterator
    // (sweep_slip / sweep_phase / dwell_ctr) — both DUTs sweep IDENTICALLY
    // (same parameters except EARLY_EXIT_ON_ALL_LOCKED). They both arrive
    // at the same iterator point at the same time, so one trajectory.
    // -------------------------------------------------------------------------

    // Capture BEST DUT's iterator for stimulus computation.
    wire [2:0]  sweep_slip_b  = u_dut_best.sweep_slip;
    wire [3:0]  sweep_phase_b = u_dut_best.sweep_phase;
    wire [$clog2(DWELL_CYCLES+1)-1:0] dwell_ctr_b = u_dut_best.dwell_ctr;

    // The marginal-edge bounce threshold (just barely clearing LOCK_THRESH).
    localparam int BOUNCE_HIGH_CYCLES = LOCK_THRESH + 2;

    logic [7:0] synth_lane_locked_q;

    // Distance helpers in pure combinational code (Verilator-clean).
    function automatic [3:0] abs_slip_diff(input [2:0] a, input [2:0] b);
        if (a >= b) abs_slip_diff = {1'b0, a - b};
        else        abs_slip_diff = {1'b0, b - a};
    endfunction

    // Phase distance is "circular" only when SKEW wraps; we use linear distance
    // (no wraparound) for the eye check — matches how Vivado tap delays move
    // a single direction relative to a fixed centre on real silicon.
    function automatic [4:0] abs_phase_diff(input [3:0] a, input [3:0] b);
        if (a >= b) abs_phase_diff = {1'b0, a - b};
        else        abs_phase_diff = {1'b0, b - a};
    endfunction

    // Modulo-16 addition of phase skew (Verilog 4-bit wraparound).
    function automatic [3:0] add_skew_mod16(input [3:0] phase, input [3:0] skew);
        add_skew_mod16 = phase + skew;
    endfunction

    // Per-lane combinational eye computation (one block per lane, generate
    // -unrolled so Verilator is happy with no per-iteration scratch flopping).
    logic [7:0] synth_lane_locked_d;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi++) begin : g_lane_eye
            logic [2:0] c_slip_l;
            logic [3:0] c_phase_l;
            logic [2:0] width_l;
            logic [3:0] skew_l;
            logic       noise_l;
            logic [3:0] eff_phase_l;
            logic [3:0] d_slip_l;
            logic [4:0] d_phase_l;
            logic [4:0] d_max_l;
            logic       in_eye_l;
            logic       at_edge_l;

            always_comb begin
                c_slip_l    = eye_centre_slip [3*gi +: 3];
                c_phase_l   = eye_centre_phase[4*gi +: 4];
                width_l     = eye_width       [3*gi +: 3];
                skew_l      = eye_skew_phase  [4*gi +: 4];
                noise_l     = eye_noise_enable[gi];

                // Apply skew BEFORE distance check. eff_phase models the
                // per-bank IDELAYCTRL tap-time misalignment: the iterator
                // says "we're at phase P", but in this lane's silicon
                // tap-time space we're actually at phase (P+skew) mod 16.
                eff_phase_l = add_skew_mod16(sweep_phase_b, skew_l);

                d_slip_l  = abs_slip_diff (sweep_slip_b, c_slip_l);
                d_phase_l = abs_phase_diff(eff_phase_l, c_phase_l);
                if ({1'b0, d_slip_l} > d_phase_l) d_max_l = {1'b0, d_slip_l};
                else                              d_max_l = d_phase_l;

                in_eye_l  = (d_max_l <= {2'b00, width_l});
                at_edge_l = (d_max_l == ({2'b00, width_l} + 5'd1));

                if (in_eye_l) begin
                    // Solid lock — HIGH every cycle, scores full dwell.
                    synth_lane_locked_d[gi] = 1'b1;
                end else if (noise_l && at_edge_l) begin
                    // Marginal-edge bounce: HIGH for the first
                    // BOUNCE_HIGH_CYCLES cycles of each dwell window
                    // (just barely clears LOCK_THRESH=16), then LOW.
                    // Score at this point = BOUNCE_HIGH_CYCLES (~18),
                    // well below the in-eye score (= DWELL_CYCLES=32).
                    if (dwell_ctr_b < BOUNCE_HIGH_CYCLES[$clog2(DWELL_CYCLES+1)-1:0])
                        synth_lane_locked_d[gi] = 1'b1;
                    else
                        synth_lane_locked_d[gi] = 1'b0;
                end else begin
                    synth_lane_locked_d[gi] = 1'b0;
                end
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) synth_lane_locked_q <= 8'h00;
        else     synth_lane_locked_q <= synth_lane_locked_d;
    end

    assign synth_lane_locked = synth_lane_locked_q;

    // -------------------------------------------------------------------------
    // Best-of-sweep DUT — silicon default (EARLY_EXIT_ON_ALL_LOCKED = 0).
    // The cocotb test does NOT touch tb_early_exit_force_q here, so the FSM
    // takes the §9.9 best-of-sweep path AND the S_FINISH→S_HOLD path on
    // success. We bound HOLD_CYCLES way down so the cocotb test doesn't
    // have to outlast 8 full sweep periods in S_HOLD.
    // -------------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES              (DWELL_CYCLES),
        .LOCK_THRESH               (LOCK_THRESH),
        .HOLD_CYCLES               (2 * 128 * DWELL_CYCLES),  // 2 sweeps
        .EARLY_EXIT_ON_ALL_LOCKED  (1'b0)
    ) u_dut_best (
        .clk                   (clk),
        .rst                   (rst),
        .role_locked           (role_locked),
        .swreset               (swreset),
        .lane_locked           (synth_lane_locked_q),
        .apb_bit_slip_override (24'h0),
        .apb_override_enable   (1'b0),
        .bit_slip              (best_bit_slip),
        .phase_offset          (best_phase_offset),
        .training_mode         (best_training_mode),
        .calibration_done      (best_calibration_done),
        .lane_fault            (best_lane_fault),
        .state                 (best_state)
    );

    // -------------------------------------------------------------------------
    // First-match DUT — legacy §9.7 (EARLY_EXIT_ON_ALL_LOCKED = 1). Same
    // stimulus (synth_lane_locked_q) so the only difference is the
    // selection policy.
    // -------------------------------------------------------------------------
    tidelink_phy_align_calibrator #(
        .DWELL_CYCLES              (DWELL_CYCLES),
        .LOCK_THRESH               (LOCK_THRESH),
        .HOLD_CYCLES               (2 * 128 * DWELL_CYCLES),
        .EARLY_EXIT_ON_ALL_LOCKED  (1'b1)
    ) u_dut_first (
        .clk                   (clk),
        .rst                   (rst),
        .role_locked           (role_locked),
        .swreset               (swreset),
        .lane_locked           (synth_lane_locked_q),
        .apb_bit_slip_override (24'h0),
        .apb_override_enable   (1'b0),
        .bit_slip              (first_bit_slip),
        .phase_offset          (first_phase_offset),
        .training_mode         (first_training_mode),
        .calibration_done      (first_calibration_done),
        .lane_fault            (first_lane_fault),
        .state                 (first_state)
    );

`ifndef VERILATOR
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end
`endif

endmodule
