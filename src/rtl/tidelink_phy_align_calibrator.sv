// =============================================================================
// wlink_phy_align_calibrator.sv — Autonomous per-lane bit-slip calibration FSM
// =============================================================================
//
// STAGING — not yet integrated into trunk RTL. This module is a prototype of
// the §9.6 "auto-staging FSM" called out in BRINGUP_REPORT.md and the §2.2
// gap in docs/PHY_ALIGN_NEXT_STEPS.md. It replaces the SW-driven calibration
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
//   phase_offset[31:0]   Drives WavD2DGpio.swi_phase_offset (8 × 4 bits,
//                        lane N at bits [4*N+3 : 4*N]). Per-lane sub-bit
//                        sample-point adjust. See "Search strategy" below.
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
//   3. Starts each lane at slip=0, phase=0, dwell counter 0.
//   4. Per lane, parallel: dwells DWELL_CYCLES; if lane_locked[lane] rises
//      within the dwell, latches that (phase,slip) pair. Otherwise the
//      shared (phase,slip) iterator advances; once all 128 combinations
//      are exhausted for a lane it has lane_fault[lane]=1 and is "done".
//   5. Once every lane is either locked or faulted: asserts
//      calibration_done=1, deasserts training_mode=0.
//
// -----------------------------------------------------------------------------
// Search strategy — per-lane slip × phase sweep (§9.7, 2026-05-15)
// -----------------------------------------------------------------------------
//
// HARDWARE MOTIVATION: on the Pynq-Z2 GPIO-PHY pair, bit-slip-only locks
// only ~5/8 lanes; the remaining ~3 lanes (different per board) have a
// sub-bit (sample-point) misalignment that a byte-boundary slip cannot
// correct. They need a per-lane PHASE offset. A single global phase
// cannot satisfy lanes whose sub-bit misalignment differs, so the search
// is per-lane in BOTH dimensions.
//
// The search space per lane is slip ∈ [0..7] × phase ∈ [0..15] (128
// points). It is walked by a SINGLE SHARED iterator (all lanes attempt
// the same (phase,slip) at the same dwell; the sweep is fully parallel,
// exactly like the original slip-only design — lanes that lock early
// latch their pair and hold it while slower lanes finish).
//
// Iteration order is **phase-outer, slip-inner**:
//
//     for phase in 0..15:           // outer
//         for slip in 0..7:         // inner
//             dwell DWELL_CYCLES; latch any newly-locked lane
//
// WHY THIS ORDER (critical correctness property): with phase=0 the inner
// loop is byte-for-byte the ORIGINAL slip-only sweep (slip 0→7, same
// DWELL_CYCLES, same latch-on-lock, same advance rule). Therefore any
// lane that locked on slip alone in the pre-§9.7 design locks at the
// IDENTICAL slip value, in the IDENTICAL cycle, during the phase=0
// pass — before any non-zero phase is ever applied. The bit-slip-only
// behaviour, the role_locked trigger, the swreset re-trigger, and the
// lane_fault / calibration_done / state semantics are all preserved
// bit-exact; the phase dimension only ever runs for lanes that the
// original design would have FAULTED (slip exhausted at phase 0).
//
// A lane is faulted only after the full 128-point space is exhausted
// (phase==15 && slip==7 with no lock).
//
// If `swreset` asserts mid-sweep, the FSM cancels and waits for swreset to
// deassert; that falling edge re-triggers the sweep from scratch.
//
// -----------------------------------------------------------------------------
// Sizing
// -----------------------------------------------------------------------------
//
// Parallel sweep, DWELL_CYCLES=32 (2× the 16-cycle LOCK_THRESH in the
// wlink_lane_checker). Worst-case (a lane that needs the very last
// combination, or faults) is 16 phase × 8 slip × 32 cycles = 4096
// cycles, plus a small settle margin. At a 250 MHz link clock that is
// ~16 µs worst case; the common case (most lanes lock at phase 0 in the
// first 256 cycles, only the 2–3 phase-needing lanes walk further) is
// far shorter. The slip-only convergence time is UNCHANGED for any lane
// that locks during the phase=0 pass.
// =============================================================================

`timescale 1ns/1ps

module tidelink_phy_align_calibrator #(
    // Dwell cycles per slip attempt. Must be > LOCK_THRESH in the lane checker
    // (default 16). Default 32 is 2× the checker threshold.
    parameter int DWELL_CYCLES = 32,
    // Number of lanes (informational — code is hand-rolled for 8 lanes).
    parameter int NUM_LANES    = 8,
    // T3 (per-deploy lottery fix): if a sweep finishes WITHOUT all lanes
    // locked (some faulted because the peer's training window didn't
    // overlap ours), auto re-sweep instead of giving up — keeping
    // training_mode high so two skew-triggered nodes converge. 0 = retry
    // while role_locked (correct cold bring-up). Non-zero = terminal fault
    // after this many auto-retries (a definite end for sim / non-bring-up).
    parameter int MAX_RESWEEPS = 0
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
    // Per-lane 4-bit phase offset, 8 lanes × 4 bits (lane N at bits
    // [4*N+3 : 4*N]). Drives WavD2DGpio.swi_phase_offset via the per-lane
    // distribution added in §9.7.
    output logic [31:0] phase_offset,
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
    //   - slip[lane]  : latched/working slip attempt   (3 bits, 0..7)
    //   - phase[lane] : latched/working phase attempt  (4 bits, 0..15)
    //   - done[lane]  : lane has either locked or faulted out
    //
    // A SINGLE SHARED (phase,slip) iterator (sweep_phase, sweep_slip) plus a
    // shared dwell counter walks the search space — the sweep is fully
    // parallel: every not-done lane attempts the same (phase,slip) at the
    // same time, and the iterator advances for all of them together. A lane
    // that locks latches the iterator's CURRENT (phase,slip) into its own
    // slip[]/phase[] registers and sets lane_done; its outputs then hold
    // that locking pair while slower lanes keep walking.
    //
    // Iteration order is phase-outer, slip-inner (see header "Search
    // strategy"): sweep_slip cycles 0→7, and only when it wraps 7→0 does
    // sweep_phase advance. With phase=0 the inner slip loop is byte-for-byte
    // the original slip-only sweep, so slip-only-lockable lanes are
    // unaffected.
    //
    // NOTE on shared dwell counter / late un-lock: identical to the
    // original design. Once lane_done[lane] is set, slip[]/phase[] for
    // that lane are frozen at the locking pair; lane_locked may bounce but
    // the held value does not change. Re-trigger required to start over.
    // -------------------------------------------------------------------------
    logic [2:0] slip      [0:7];   // per-lane latched/working slip
    logic [3:0] phase     [0:7];   // per-lane latched/working phase
    logic [7:0] lane_done;         // sticky during a sweep
    logic [7:0] lane_fault_q;
    // Shared search iterator (phase-outer, slip-inner).
    logic [2:0] sweep_slip;        // 0..7
    logic [3:0] sweep_phase;       // 0..15
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

    // T3: a sweep is a genuine SUCCESS only if NO lane faulted (every lane
    // found a locking (phase,slip)). lane_fault_q is bounce-immune, unlike
    // &lane_locked. The per-deploy lottery failure mode is all_done=1 with
    // lane_fault_q != 0 — the peer's training pattern wasn't present during
    // this node's ~82 µs sweep because the two role_lock triggers were
    // ms-skewed (T1 HW-confirmed).
    wire sweep_success  = ~|lane_fault_q;
    // Auto-retry budget since the last EXTERNAL trigger (see resweep_ctr
    // block). MAX_RESWEEPS==0 ⇒ never exhausts (retry while role_locked).
    logic [15:0] resweep_ctr;
    wire retry_exhausted = (MAX_RESWEEPS != 0) &&
                           (resweep_ctr >= MAX_RESWEEPS);

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
                // T3 lottery fix. Release to the link (→ S_DONE →
                // calibration_done → lltx/FCSM) ONLY on a genuine
                // all-lanes-locked sweep, or after the retry cap. A sweep
                // that faulted because the peer's training window didn't
                // overlap ours auto re-sweeps while role_locked, holding
                // training_mode high (it is high in S_ARM/S_SWEEP) so our
                // TX keeps the training pattern up. Two skew-triggered
                // nodes then re-sweep continuously until their windows
                // coincide — converting the ms-scale non-overlap (fatal)
                // into a ≤few-hundred-µs convergence delay (benign).
                if (sweep_success || retry_exhausted) nxt_state = S_DONE;
                else if (role_locked)                 nxt_state = S_ARM;
                else                                  nxt_state = S_DONE;
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
    // T3 re-sweep counter — auto-retries since the last EXTERNAL trigger.
    // Cleared by reset and by trigger_now (a fresh role_locked rising /
    // swreset-fall cycle resets the retry budget). Incremented exactly on
    // the S_FINISH→S_ARM auto-retry edge. Deliberately NOT touched by the
    // S_ARM mass-clear datapath branch (that clears per-sweep state; the
    // retry budget must survive auto re-arms). Bring-up default
    // MAX_RESWEEPS=0 ⇒ this just free-runs and retry_exhausted stays 0.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                                  resweep_ctr <= 16'd0;
        else if (trigger_now)                     resweep_ctr <= 16'd0;
        else if ((cur_state == S_FINISH) &&
                 (nxt_state  == S_ARM))           resweep_ctr <= resweep_ctr + 16'd1;
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
            sweep_slip   <= 3'd0;
            sweep_phase  <= 4'd0;
            for (int i = 0; i < 8; i++) begin
                slip[i]  <= 3'd0;
                phase[i] <= 4'd0;
            end
        end else begin
            unique case (cur_state)
                S_ARM: begin
                    // Fresh sweep — clear all state. cur_state==S_ARM
                    // persists for exactly one cycle (S_ARM → S_SWEEP or
                    // S_CANCEL), so this fires once per sweep launch.
                    dwell_ctr    <= '0;
                    lane_done    <= 8'h00;
                    lane_fault_q <= 8'h00;
                    sweep_slip   <= 3'd0;
                    sweep_phase  <= 4'd0;
                    for (int i = 0; i < 8; i++) begin
                        slip[i]  <= 3'd0;
                        phase[i] <= 4'd0;
                    end
                end

                S_SWEEP: begin
                    // First latch any new locks at the *current* shared
                    // (phase,slip) iterator value into that lane's own
                    // slip[]/phase[] registers, then freeze the lane.
                    for (int i = 0; i < 8; i++) begin
                        if (lane_new_lock[i]) begin
                            lane_done[i] <= 1'b1;
                            slip[i]      <= sweep_slip;
                            phase[i]     <= sweep_phase;
                        end
                    end

                    if (dwell_ctr == DWELL_MAX[$clog2(DWELL_CYCLES+1)-1:0]) begin
                        // Dwell expired — advance the SHARED iterator
                        // (phase-outer, slip-inner) and, if the full
                        // 128-point space is now exhausted, fault every
                        // lane that is still not done.
                        dwell_ctr <= '0;
                        if (sweep_slip == 3'd7) begin
                            sweep_slip <= 3'd0;
                            if (sweep_phase == 4'd15) begin
                                // Search space exhausted: any lane that
                                // never locked (and is not already done)
                                // faults out. sweep_phase holds at 15.
                                for (int i = 0; i < 8; i++) begin
                                    if (!lane_done[i] && !lane_new_lock[i]) begin
                                        lane_fault_q[i] <= 1'b1;
                                        lane_done[i]    <= 1'b1;
                                    end
                                end
                            end else begin
                                sweep_phase <= sweep_phase + 4'd1;
                            end
                        end else begin
                            sweep_slip <= sweep_slip + 3'd1;
                        end
                    end else begin
                        dwell_ctr <= dwell_ctr + 1'b1;
                    end
                end

                S_CANCEL: begin
                    // Hold state; no advances. Iterator/latched values
                    // retained for ILA.
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
    // Per lane, the PHY must see:
    //   - the lane's LATCHED (slip,phase) once it is done (locked/faulted),
    //   - the LIVE shared iterator (sweep_phase,sweep_slip) while it is
    //     still being swept.
    // This reproduces the original slip-only design exactly: at phase=0 a
    // not-done lane presents sweep_slip walking 0→7 each dwell (same as the
    // old per-lane slip[] advancing), and freezes on lock. A faulted lane
    // holds its last-tried (slip=7, phase=15) — same "hold" behaviour as
    // the original (which held slip=7).
    logic [23:0] bit_slip_internal;
    logic [31:0] phase_offset_internal;
    always_comb begin
        bit_slip_internal     = 24'h0;
        phase_offset_internal = 32'h0;
        for (int i = 0; i < 8; i++) begin
            if (lane_done[i]) begin
                bit_slip_internal[3*i +: 3]     = slip[i];
                phase_offset_internal[4*i +: 4] = phase[i];
            end else begin
                bit_slip_internal[3*i +: 3]     = sweep_slip;
                phase_offset_internal[4*i +: 4] = sweep_phase;
            end
        end
    end

    // APB override: drive bit_slip directly from the override register and
    // force the FSM's "no calibration in progress" outputs. In this mode the
    // PHY behaves exactly as the existing soft-strap design — SW is in
    // charge of slip selection. phase_offset is forced to 0 so the global
    // APB phase path (WavD2DGpio PHY-ctrl reg) keeps full control.
    always_comb begin
        if (apb_override_enable) begin
            bit_slip         = apb_bit_slip_override;
            phase_offset     = 32'h0;
            training_mode    = 1'b0;
            calibration_done = 1'b1;
        end else begin
            bit_slip         = bit_slip_internal;
            phase_offset     = phase_offset_internal;
            training_mode    = (cur_state == S_ARM) || (cur_state == S_SWEEP);
            calibration_done = (cur_state == S_DONE);
        end
    end

    assign lane_fault = lane_fault_q;

endmodule
