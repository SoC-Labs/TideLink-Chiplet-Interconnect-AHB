// =============================================================================
// wlink_phy_align_calibrator.sv — Autonomous per-lane bit-slip calibration FSM
// =============================================================================
//
// STAGING — historical prototype. The integrated module is
// src/rtl/tidelink_phy_align_calibrator.sv; design rationale is in
// docs/TIDELINK_SPECIFICATION.md §9.10. This file is kept as a
// reference snapshot only. It replaces the SW-driven calibration
// sweep (cocotb / UVM hierarchical-ref writes to swi_bit_slip and
// swi_training_mode) with a deterministic in-RTL sequencer that runs the
// per-lane slip search on its own, with no firmware involvement.
//
// -----------------------------------------------------------------------------
// Interface
// -----------------------------------------------------------------------------
//
//   clk                  Link-clock domain (same as wlink_lane_checker.clk)
//   rst                  Active-high reset (typ. ~poresetn)
//
//   role_locked          Level signal from chiplet-controller role_lock_reg.
//                        Rising edge here is the master trigger for a
//                        calibration sweep (see Bring-up Sequencing Contract
//                        below).
//   swreset              Level signal from chiplet-controller swreset path.
//                        Asserting (i.e. swreset==1) cancels any in-flight
//                        calibration; on its falling edge (with role_locked
//                        still high) a fresh sweep is launched.
//   lane_locked[7:0]     Per-lane locked-status from wlink_lane_checker.
//
//   apb_bit_slip_override[23:0]  SW-debug: full 8-lane × 3-bit slip vector.
//   apb_override_enable          When 1, FSM is bypassed entirely — bit_slip
//                                drives directly from apb_bit_slip_override
//                                and training_mode/calibration_done are forced
//                                to a safe "no calibration in progress, link
//                                free to run" state (training_mode=0,
//                                calibration_done=1).
//
//   bit_slip[23:0]       Drives WavD2DGpio.swi_bit_slip (8 × 3 bits, lane N at
//                        bits [3*N+2 : 3*N]).
//   training_mode        Drives WavD2DGpio.swi_training_mode. Asserted during
//                        the sweep; deasserts once all lanes have either
//                        locked or faulted out. The integrator wires this
//                        such that cr_pkt generation is held off while
//                        training_mode=1 (see §9.8 of BRINGUP_REPORT.md).
//   calibration_done     Pulses-then-holds high once every lane has either
//                        locked or hit lane_fault. Goes low again on
//                        re-trigger (role_locked rising or swreset cycle).
//   lane_fault[7:0]      Sticky per-lane fault. Set if a lane's sweep
//                        exhausted all 8 slip values without locking.
//                        Cleared by the next sweep trigger.
//   state[3:0]           Debug FSM state for ILA visibility.
//
// -----------------------------------------------------------------------------
// Bring-up Sequencing Contract (CRITICAL — see §9.8 of BRINGUP_REPORT.md)
// -----------------------------------------------------------------------------
//
// The FSM is triggered on the rising edge of `role_locked`. At that point it
// immediately asserts `training_mode=1` and begins driving `bit_slip` through
// a per-lane sweep. The integrator MUST wire this such that the receive-side
// FCSM does not begin advancing past SEND_CREDITS1 while `training_mode=1` —
// the cleanest hook is to gate `swi_lltx_enable` (or equivalently the
// chiplet-controller's `swreset` deassertion to Wlink) with
// `calibration_done`. Concretely:
//
//   wire wlink_lltx_enable_gated = swi_lltx_enable & calibration_done;
//
// or by holding wlink_por_reset until calibration_done==1.
//
// Two trigger modes are supported:
//
//   (a) Rising edge of role_locked (cold boot / link re-up).
//   (b) Falling edge of swreset while role_locked is still high (SW-issued
//       link recalibrate without dropping role_locked).
//
// In both cases the FSM:
//   1. Clears lane_fault[7:0] and calibration_done.
//   2. Asserts training_mode=1.
//   3. Starts each lane at slip=0, dwell counter 0.
//   4. Per lane, parallel: dwells DWELL_CYCLES; if lane_locked[lane] rises
//      within the dwell, latches that slip value. Otherwise advances slip;
//      if all 8 slip values exhausted, sets lane_fault[lane]=1 and treats
//      the lane as "done".
//   5. Once every lane is either locked or faulted: asserts
//      calibration_done=1, deasserts training_mode=0.
//
// If `swreset` asserts mid-sweep, the FSM cancels and waits for swreset to
// deassert; that falling edge re-triggers the sweep from scratch.
//
// -----------------------------------------------------------------------------
// Sizing
// -----------------------------------------------------------------------------
//
// Parallel sweep, DWELL_CYCLES=32 (2× the 16-cycle LOCK_THRESH in the
// wlink_lane_checker). Worst-case 8 slip values × 32 cycles = 256 cycles, plus
// a small settle margin = ~280 cycles. Target ~1 µs at a 250 MHz link clock.
// =============================================================================

`timescale 1ns/1ps

module wlink_phy_align_calibrator #(
    // Dwell cycles per slip attempt. Must be > LOCK_THRESH in the lane checker
    // (default 16). Default 32 is 2× the checker threshold.
    parameter int DWELL_CYCLES = 32,
    // Number of lanes (informational — code is hand-rolled for 8 lanes).
    parameter int NUM_LANES    = 8
)(
    input  logic        clk,
    input  logic        rst,                       // active-high

    // Bring-up sequencing
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,

    // SW debug override (optional)
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,

    // Outputs to PHY
    output logic [23:0] bit_slip,
    output logic        training_mode,
    output logic        calibration_done,
    output logic [7:0]  lane_fault,
    output logic [3:0]  state                      // ILA visibility
);

    // -------------------------------------------------------------------------
    // State encoding (4-bit so it fits the `state[3:0]` debug output)
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE       = 4'd0,   // Waiting for role_locked rising / first sweep
        S_ARM        = 4'd1,   // Drop training, start sweep next cycle
        S_SWEEP      = 4'd2,   // Sweeping; dwell + advance per lane
        S_FINISH     = 4'd3,   // All lanes done; deassert training_mode
        S_DONE       = 4'd4,   // Calibration complete; idle until re-trigger
        S_CANCEL     = 4'd5    // swreset asserted mid-sweep; wait for deassert
    } state_t;

    state_t cur_state, nxt_state;
    assign state = cur_state;

    // -------------------------------------------------------------------------
    // Trigger detection: rising edge of role_locked, OR falling edge of swreset
    // while role_locked is high.
    // -------------------------------------------------------------------------
    logic role_locked_q;
    logic swreset_q;
    logic trigger_now;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            role_locked_q <= 1'b0;
            swreset_q     <= 1'b0;
        end else begin
            role_locked_q <= role_locked;
            swreset_q     <= swreset;
        end
    end

    // Rising edge of role_locked, or falling edge of swreset while role_locked
    // is asserted.
    wire role_locked_rise = role_locked & ~role_locked_q;
    wire swreset_fall     = ~swreset    &  swreset_q;
    assign trigger_now = role_locked_rise | (swreset_fall & role_locked);

    // -------------------------------------------------------------------------
    // Per-lane sweep state
    //
    // Each lane tracks:
    //   - slip[lane] : current slip attempt (3 bits)
    //   - done[lane] : lane has either locked or faulted out
    //
    // The dwell counter is shared across all lanes since the sweep is fully
    // parallel: every lane attempts slip=0 at the same time, every lane
    // advances at the same time. Lanes that lock early have `done` latched
    // and simply hold their latched slip while the slower lanes finish.
    //
    // NOTE on shared dwell counter: this is the simplest correct design.
    // Edge case: a fast lane locks at slip=0, but we keep walking — what
    // happens if the lane "un-locks" later? Answer: we already latched
    // done[lane], so the slip register for that lane is no longer advanced;
    // the lane_locked input may bounce around, but the slip is held at the
    // locking value. Re-trigger required to start over.
    // -------------------------------------------------------------------------
    logic [2:0] slip      [0:7];
    logic [7:0] lane_done;        // sticky during a sweep
    logic [7:0] lane_fault_q;
    logic [$clog2(DWELL_CYCLES+1)-1:0] dwell_ctr;
    localparam int DWELL_MAX = DWELL_CYCLES - 1;

    // Have we latched a lock for a lane that wasn't already done?
    logic [7:0] lane_new_lock;
    always_comb begin
        for (int i = 0; i < 8; i++)
            lane_new_lock[i] = ~lane_done[i] & lane_locked[i];
    end

    // All lanes have either locked-and-latched OR faulted out.
    wire all_done = &lane_done;

    // -------------------------------------------------------------------------
    // FSM next-state logic
    // -------------------------------------------------------------------------
    always_comb begin
        nxt_state = cur_state;
        unique case (cur_state)
            S_IDLE: begin
                if (trigger_now)        nxt_state = S_ARM;
            end
            S_ARM: begin
                if (swreset)            nxt_state = S_CANCEL;
                else                    nxt_state = S_SWEEP;
            end
            S_SWEEP: begin
                if (swreset)            nxt_state = S_CANCEL;
                else if (all_done)      nxt_state = S_FINISH;
            end
            S_FINISH: begin
                nxt_state = S_DONE;
            end
            S_DONE: begin
                if (trigger_now)        nxt_state = S_ARM;
            end
            S_CANCEL: begin
                if (!swreset)           nxt_state = S_ARM;   // restart fresh
            end
            default: nxt_state = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // State register
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) cur_state <= S_IDLE;
        else     cur_state <= nxt_state;
    end

    // -------------------------------------------------------------------------
    // Datapath: dwell counter, per-lane slip, done, fault
    // -------------------------------------------------------------------------
    // We key the datapath on cur_state (not nxt_state). To get the clears
    // synchronised with the *entry* into S_ARM, we use a dedicated edge
    // detect: when the next-state logic decides we should arm, we also need
    // the datapath to clear. Doing it via cur_state==S_ARM is one cycle
    // later than that decision — which is OK because we don't enter
    // S_SWEEP until the cycle after S_ARM (see next-state logic).
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dwell_ctr    <= '0;
            lane_done    <= 8'h00;
            lane_fault_q <= 8'h00;
            for (int i = 0; i < 8; i++) slip[i] <= 3'd0;
        end else begin
            unique case (cur_state)
                S_ARM: begin
                    // Fresh sweep — clear all state. cur_state==S_ARM
                    // persists for exactly one cycle (S_ARM → S_SWEEP or
                    // S_CANCEL), so this fires once per sweep launch.
                    dwell_ctr    <= '0;
                    lane_done    <= 8'h00;
                    lane_fault_q <= 8'h00;
                    for (int i = 0; i < 8; i++) slip[i] <= 3'd0;
                end

                S_SWEEP: begin
                    // First latch any new locks at the *current* slip value.
                    for (int i = 0; i < 8; i++) begin
                        if (lane_new_lock[i]) begin
                            lane_done[i] <= 1'b1;
                            // slip[i] holds — no advance for this lane.
                        end
                    end

                    if (dwell_ctr == DWELL_MAX[$clog2(DWELL_CYCLES+1)-1:0]) begin
                        // Dwell expired — for each still-not-done lane,
                        // either advance the slip or mark it as faulted.
                        dwell_ctr <= '0;
                        for (int i = 0; i < 8; i++) begin
                            if (!lane_done[i] && !lane_new_lock[i]) begin
                                if (slip[i] == 3'd7) begin
                                    lane_fault_q[i] <= 1'b1;
                                    lane_done[i]    <= 1'b1;
                                end else begin
                                    slip[i] <= slip[i] + 3'd1;
                                end
                            end
                        end
                    end else begin
                        dwell_ctr <= dwell_ctr + 1'b1;
                    end
                end

                S_CANCEL: begin
                    // Hold state; no advances. Slip values retained for ILA.
                end

                default: begin
                    // S_IDLE / S_FINISH / S_DONE — no datapath activity
                    // (clears handled in S_ARM branch above).
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Output drivers
    // -------------------------------------------------------------------------
    // Pack per-lane 3-bit slips into a 24-bit vector.
    logic [23:0] bit_slip_internal;
    always_comb begin
        bit_slip_internal = 24'h0;
        for (int i = 0; i < 8; i++)
            bit_slip_internal[3*i +: 3] = slip[i];
    end

    // APB override: drive bit_slip directly from the override register and
    // force the FSM's "no calibration in progress" outputs. In this mode the
    // PHY behaves exactly as the existing soft-strap design — SW is in
    // charge of slip selection.
    always_comb begin
        if (apb_override_enable) begin
            bit_slip         = apb_bit_slip_override;
            training_mode    = 1'b0;
            calibration_done = 1'b1;
        end else begin
            bit_slip         = bit_slip_internal;
            training_mode    = (cur_state == S_ARM) || (cur_state == S_SWEEP);
            calibration_done = (cur_state == S_DONE);
        end
    end

    assign lane_fault = lane_fault_q;

endmodule
