// =============================================================================
// wlink_phy_align_calibrator.sv — Autonomous per-lane bit-slip calibration FSM
// =============================================================================
//
// This module is the §9.6 "auto-staging FSM" described in BRINGUP_REPORT.md
// and now folded into docs/TIDELINK_SPECIFICATION.md §9.10 (PHY-Align:
// Integration Notes). It replaces the SW-driven calibration
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
// the same (phase,slip) at the same dwell; the sweep is fully parallel).
//
// Iteration order is **phase-outer, slip-inner**:
//
//     for phase in 0..15:           // outer
//         for slip in 0..7:         // inner
//             dwell DWELL_CYCLES; score each lane's lock duration
//
// -----------------------------------------------------------------------------
// Selection policy — BEST-OF-SWEEP widest-eye latch (§9.9, 2026-05-20)
// -----------------------------------------------------------------------------
//
// FIELD MOTIVATION: with first-match-wins (the §9.7 policy) the chosen
// (slip,phase) for a marginal lane was the FIRST eye edge encountered in
// the sweep order, not the eye CENTRE. Lanes that just barely cleared the
// 16-consec-match LOCK_THRESH at the eye edge bounced in/out of lock in
// steady state — see bringup_health_probe trajectories oscillating
// 0xf5/0xfd/0xd5/0xd7 (master) and 0xce/0x7f/0xee (slave).
//
// New policy: at every dwell window we score each lane's lock-count
// behaviour at the current (slip,phase) and remember the BEST scoring
// pair per lane. The sweep ALWAYS walks the full 128-point space (no
// per-lane freeze on first lock); at sweep exhaustion each lane's
// outputs latch to its best-scoring (slip,phase). The score is the
// run-length of consecutive lane_locked=1 cycles captured during the
// dwell window (saturating at 6 bits, i.e. DWELL_CYCLES <= 63 contributes
// linearly, longer is clamped).
//
// CORRECTNESS / COMPAT: the legacy first-match-wins behaviour is
// available via parameter `EARLY_EXIT_ON_ALL_LOCKED` (or its runtime
// hook `tb_early_exit_force_q`) — when set, a lane freezes on its first
// lock just as in §9.7. This is provided for cocotb/UVM tests whose
// timing assumptions depend on first-match wall time.
//
// A lane is faulted only after the full 128-point space is exhausted
// AND its best_score never reached LOCK_THRESH.
//
// If `swreset` asserts mid-sweep, the FSM cancels and waits for swreset to
// deassert; that falling edge re-triggers the sweep from scratch.
//
// -----------------------------------------------------------------------------
// Sizing
// -----------------------------------------------------------------------------
//
// Parallel sweep, DWELL_CYCLES=64 by default (4× the 16-cycle LOCK_THRESH
// in the wlink_lane_checker; raised from 32 in §9.9 so the per-dwell
// score has more dynamic range without ballooning sweep time). Worst
// case under the best-of-sweep policy is the FULL 128-point space every
// time, 16 phase × 8 slip × 64 cycles = 8192 cycles, plus settle margin.
// At a 250 MHz link clock that is ~33 µs.
//
// Added flop budget vs §9.7 (8 lanes):
//   - best_score[i]    6b × 8 = 48 flops
//   - best_slip[i]     3b × 8 = 24 flops
//   - best_phase[i]    4b × 8 = 32 flops
//   - lane_score[i]    6b × 8 = 48 flops
// Total ≈ 150 new flops. Combinational cost: one 6-bit comparator + one
// 6-bit add per lane (4 cycles slack to LOCK_THRESH clearance, generous).
// =============================================================================

`timescale 1ns/1ps

module tidelink_phy_align_calibrator #(
    // Dwell cycles per slip attempt. Must be > LOCK_THRESH in the lane checker
    // (default 16). Default 64 is 4× the checker threshold; raised from
    // 32 in §9.9 to give the best-of-sweep score more dynamic range.
    parameter int DWELL_CYCLES = 64,
    // Lane checker LOCK_THRESH (default 16) — mirrored here so the
    // best-of-sweep score gate matches the checker's lock criterion.
    parameter int LOCK_THRESH  = 16,
    // Number of lanes (informational — code is hand-rolled for 8 lanes).
    parameter int NUM_LANES    = 8,
    // T3 (per-deploy lottery fix): if a sweep finishes WITHOUT all lanes
    // locked (some faulted because the peer's training window didn't
    // overlap ours), auto re-sweep instead of giving up — keeping
    // training_mode high so two skew-triggered nodes converge. 0 = retry
    // while role_locked (correct cold bring-up). Non-zero = terminal fault
    // after this many auto-retries (a definite end for sim / non-bring-up).
    parameter int MAX_RESWEEPS = 0,
    // T3.2 (peer-aware training hold): on this node's OWN sweep_success do
    // NOT release immediately. The first node to succeed must keep
    // training_mode high long enough for the (role_lock-skew-delayed) peer
    // — now fed a guaranteed-continuous pattern — to ALSO reach
    // sweep_success. Hold HOLD_CYCLES (≫ 2 sweep periods) then release;
    // both nodes time out within ≤2 sweeps of each other and the latched
    // per-lane (slip,phase) holds through the skew. Defeats the
    // first-to-succeed-abandons-the-peer deadlock the HW T3 test exposed.
    // Default = 8 full sweep periods (1 sweep = 128 × DWELL_CYCLES).
    parameter int HOLD_CYCLES  = 8 * 128 * DWELL_CYCLES,
    // §9.9 best-of-sweep selection toggle:
    //   0 (silicon default) — sweep ALL 128 (slip,phase) per sweep, pick
    //     the per-lane (slip,phase) with the LONGEST in-dwell run of
    //     lane_locked=1, latch at sweep exhaustion. Defeats marginal-eye
    //     oscillation seen in HW (bringup_health_probe).
    //   1 (compat / sim) — restore the §9.7 first-match-wins behaviour:
    //     a lane freezes on its first dwell with lane_locked rising and
    //     the sweep terminates early when all lanes are done. Existing
    //     cocotb/UVM tests whose timing assumptions depend on the early
    //     exit set this to 1 (via the tb_early_exit_force_q hierarchical-
    //     force hook below) without re-elaborating the design.
    parameter logic EARLY_EXIT_ON_ALL_LOCKED = 1'b0,
    // v2 EYE: clock-rate constant (MHz) used to convert the
    // SWI_EYE_DWELL_US APB value into a cycle count. FPGA app_clk runs at
    // 250 MHz; TSMC65 ASIC at ~100 MHz. Set at elaboration.
    parameter int CLK_MHZ = 250,
    // v2 EYE: when 1, expand score_buf from [0:127] (one lane) to
    // [0:7][0:127] (all lanes). Default 0 keeps the 768-bit single-lane
    // footprint (Option A). Wide mode is reserved for chiplet variants
    // with spare area; SW exposed via SWI_EYE_LANE_SEL[3] "all-lanes".
    parameter int EYE_BUF_WIDE = 0
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
    output logic [3:0]  state,                     // ILA visibility

    // ---------------------------------------------------------------------
    // v2 EYE VISIBILITY interface (Region 10 — tidelink_eye_regs.sv).
    //
    // The new datapath is gated entirely on swi_eye_ctrl[5:4] == 2'b01
    // (single-lane Option A) and the ENTER pulse, so a zeroed control
    // word leaves every existing signal untouched (MODE=00 = bit-identical
    // to the pre-v2 RTL).  Integrators that don't yet drive these ports
    // should tie them to 0.
    // ---------------------------------------------------------------------
    input  logic [2:0]  swi_eye_lane_sel,
    input  logic [31:0] swi_eye_dwell_us,
    input  logic [31:0] swi_eye_ctrl,
    output logic [31:0] eye_status,
    // Score-buffer read port.  EYE_SCORE_IDX selects a point (slip[2:0] in
    // [6:4], phase[3:0] in [3:0]); EYE_SCORE_DATA returns the 6-bit lane
    // score at that point of the currently selected lane.  The selection
    // outputs (best_*) report the chosen point for the captured lane.
    input  logic [6:0]  eye_score_idx,
    output logic [5:0]  eye_score_data,
    output logic        eye_score_lane_passed,
    output logic [5:0]  eye_score_best,
    output logic [2:0]  eye_score_best_slip,
    output logic [3:0]  eye_score_best_phase
);

    // HAL USEPAR @104: anchor NUM_LANES to the hand-rolled 8-lane code.
    // The body still uses literal `8` because lane_locked[7:0] and
    // bit_slip[23:0]=3*8 are fixed-width ports; this elab-time assertion
    // turns a stray instantiation-time override into a $fatal instead of
    // a silent miscompile.
    initial begin
        if (NUM_LANES != 8) begin
            $fatal(1, "tidelink_phy_align_calibrator: NUM_LANES=%0d not supported (must be 8)", NUM_LANES);
        end
    end

    // -------------------------------------------------------------------------
    // State encoding (4-bit so it fits the `state[3:0]` debug output)
    //
    // HAL ENMNFU @136: only 6 of the 16 4-bit encodings are named. The width
    // is intentionally 4 bits to expose the FSM state on `state[3:0]` for the
    // ILA / pynq debug path. Codes 4'd6..4'd15 are reserved for future
    // states (e.g. S_HOLD on the v1.1 branch) and treated as `default:` in
    // the next-state logic below — see `default: nxt_state = S_IDLE;` arm.
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE       = 4'd0,   // Waiting for role_locked rising / first sweep
        S_ARM        = 4'd1,   // Drop training, start sweep next cycle
        S_SWEEP      = 4'd2,   // Sweeping; dwell + advance per lane
        S_FINISH     = 4'd3,   // All lanes done; decide release vs re-sweep
        S_DONE       = 4'd4,   // Calibration complete; idle until re-trigger
        S_CANCEL     = 4'd5,   // swreset asserted mid-sweep; wait for deassert
        S_HOLD       = 4'd6    // T3.2: locked locally; keep training_mode
                               //       high HOLD_CYCLES so the peer converges
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
    // §9.9 runtime EARLY_EXIT override hook (cocotb/UVM compat).
    //
    // The silicon parameter EARLY_EXIT_ON_ALL_LOCKED defaults to 1'b0
    // (best-of-sweep). Cocotb/UVM tests that assumed §9.7 first-match
    // timing can force this register to 1 via the hierarchical handle
    //   <tb>.<calibrator>.tb_early_exit_force_q
    // — exactly the same pattern axi_chiplet_controller already uses to
    // gate role_locked into the calibrator (see autocal_force_enable_q).
    // Initialised to 0 here so RTL elab is unambiguous; cocotb force lifts
    // it before role_locked rises.
    /* verilator lint_off UNDRIVEN */
    reg tb_early_exit_force_q = 1'b0;
    /* verilator lint_on UNDRIVEN */
    wire early_exit_en_w = EARLY_EXIT_ON_ALL_LOCKED | tb_early_exit_force_q;

    // -------------------------------------------------------------------------
    // Per-lane sweep state
    //
    // Each lane tracks:
    //   - slip[lane]  : LATCHED slip (loaded from best_slip at sweep end,
    //                   or — in EARLY_EXIT mode — captured on first lock)
    //   - phase[lane] : LATCHED phase (same)
    //   - done[lane]  : lane has either locked-and-latched (EARLY_EXIT
    //                   mode) or the sweep has ended and the lane was
    //                   scored or faulted out
    //
    // §9.9 best-of-sweep adds:
    //   - lane_score[lane]  : 6-bit run-length counter of consecutive
    //                         lane_locked=1 cycles within the CURRENT
    //                         dwell window. Resets on dwell-window entry.
    //                         Saturates at 6'h3F.
    //   - best_score[lane]  : 6-bit best run-length seen at any
    //                         (slip,phase) so far this sweep
    //   - best_slip[lane]   : 3-bit slip value at which best_score was
    //                         achieved
    //   - best_phase[lane]  : 4-bit phase value at which best_score was
    //                         achieved
    //
    // A SINGLE SHARED (phase,slip) iterator (sweep_phase, sweep_slip) plus a
    // shared dwell counter walks the search space — the sweep is fully
    // parallel.
    //
    // Iteration order is phase-outer, slip-inner: sweep_slip cycles 0→7,
    // and only when it wraps 7→0 does sweep_phase advance. With phase=0
    // the inner slip loop is byte-for-byte the original slip-only sweep.
    //
    // SELECTION POLICY (when early_exit_en_w==0, silicon default):
    //   - lane_done[i] STAYS LOW for the entire sweep — every lane walks
    //     all 128 points. At each dwell-window expiry we compare
    //     lane_score[i] vs best_score[i]; if greater, update
    //     best_{score,slip,phase}[i].
    //   - At sweep exhaustion (phase==15, slip==7, dwell expired) we
    //     LATCH slip[i]/phase[i] from best_slip/best_phase for every lane
    //     whose best_score >= LOCK_THRESH; lanes that never made the
    //     LOCK_THRESH bar set lane_fault[i].
    //
    // LEGACY POLICY (early_exit_en_w==1):
    //   - lane_done[i] is set on the first dwell where lane_locked[i]
    //     rises, and slip[i]/phase[i] capture the iterator's current
    //     (slip,phase). Sweep terminates early when all lanes are done.
    //     Matches §9.7 first-match-wins exactly.
    // -------------------------------------------------------------------------
    logic [2:0] slip      [0:7];   // per-lane latched output slip
    logic [3:0] phase     [0:7];   // per-lane latched output phase
    logic [7:0] lane_done;         // sticky during a sweep
    logic [7:0] lane_fault_q;
    // Shared search iterator (phase-outer, slip-inner).
    logic [2:0] sweep_slip;        // 0..7
    logic [3:0] sweep_phase;       // 0..15
    logic [$clog2(DWELL_CYCLES+1)-1:0] dwell_ctr;
    localparam int DWELL_MAX = DWELL_CYCLES - 1;

    // §9.9 best-of-sweep tracking
    logic [5:0] lane_score  [0:7];   // per-lane in-dwell run-length, saturating
    logic [5:0] best_score  [0:7];   // best run-length seen this sweep
    logic [2:0] best_slip   [0:7];
    logic [3:0] best_phase  [0:7];
    localparam logic [5:0] LANE_SCORE_MAX = 6'h3F;
    // Promote LOCK_THRESH to the 6-bit score width safely.
    wire   [5:0] lock_thresh_6b   = LOCK_THRESH[5:0];

    // Have we latched a lock for a lane that wasn't already done?
    // (Only used by the EARLY_EXIT path; best-of-sweep ignores it.)
    logic [7:0] lane_new_lock;
    always_comb begin
        for (int i = 0; i < 8; i++)
            lane_new_lock[i] = ~lane_done[i] & lane_locked[i];
    end

    // All lanes have either locked-and-latched OR faulted out. Only the
    // EARLY_EXIT path uses this to terminate the sweep early; best-of-sweep
    // always walks to exhaustion.
    wire all_done = &lane_done;

    // §9.9: dwell-window-expiry strobe at the final iterator point
    // (sweep_phase==15, sweep_slip==7, dwell_ctr==DWELL_MAX). Drives both
    // the FSM termination edge and the end-of-sweep best_* → slip[]/phase[]
    // latch in the datapath.
    wire dwell_expire    = (dwell_ctr == DWELL_MAX[$clog2(DWELL_CYCLES+1)-1:0]);
    wire iter_at_end     = (sweep_slip == 3'd7) && (sweep_phase == 4'd15);
    wire sweep_exhausted = (cur_state == S_SWEEP) && dwell_expire && iter_at_end;

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

    // T3.2 peer-aware training-hold counter (cycles spent in S_HOLD).
    localparam int HOLD_MAX = HOLD_CYCLES - 1;
    logic [$clog2(HOLD_CYCLES+1)-1:0] hold_ctr;

    // -------------------------------------------------------------------------
    // FSM next-state logic
    // -------------------------------------------------------------------------
    always_comb begin
        nxt_state = cur_state;
        // Bug #7 synth-safety (from fix/calibrator-structural): plain `case`
        // + explicit default (below) instead of `unique case`, so synth cannot
        // treat it as a parallel-case/full-case license and prune state arms
        // (same defect class as the Bug #1/#2 latches). nxt_state defaults to
        // cur_state above, so an undecoded state holds.
        case (cur_state)
            S_IDLE: begin
                if (trigger_now)        nxt_state = S_ARM;
            end
            S_ARM: begin
                if (swreset)            nxt_state = S_CANCEL;
                else                    nxt_state = S_SWEEP;
            end
            S_SWEEP: begin
                // §9.9: in best-of-sweep mode the sweep ALWAYS walks the
                // full 128-point space — the datapath sets the dedicated
                // sweep_exhausted strobe on the final dwell-window expiry.
                // In EARLY_EXIT compat mode the sweep terminates as soon
                // as every lane is locked (or faulted), matching §9.7.
                if (swreset)                                   nxt_state = S_CANCEL;
                else if (early_exit_en_w && all_done)          nxt_state = S_FINISH;
                else if (sweep_exhausted)                      nxt_state = S_FINISH;
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
                // T3.2: a genuinely all-locked sweep enters S_HOLD (NOT
                // straight to S_DONE) to keep our TX training pattern up
                // while the skew-delayed peer also converges. A faulted
                // sweep auto re-sweeps while role_locked (T3).
                //
                // §9.9 sim compat: when tb_early_exit_force_q is asserted
                // (cocotb hierarchical-force), skip the HOLD_CYCLES wait —
                // sim peers converge deterministically without the wall-time
                // overlap-margin S_HOLD provides in silicon. Without this
                // bypass, every integration test would need a ≥1.5M apb_clk
                // timeout to outlast HOLD_CYCLES (8·128·DWELL_CYCLES @
                // link_clk_rx ≈ pad_clk/16). Silicon (hook undriven, =0) is
                // unaffected; production bring-up keeps the T3.2 hold.
                if (sweep_success && !tb_early_exit_force_q)
                                          nxt_state = S_HOLD;
                else if (sweep_success)   nxt_state = S_DONE;  // sim bypass
                else if (retry_exhausted) nxt_state = S_DONE;
                else if (role_locked)     nxt_state = S_ARM;
                else                      nxt_state = S_DONE;
            end
            S_DONE: begin
                if (trigger_now)        nxt_state = S_ARM;
            end
            S_CANCEL: begin
                if (!swreset)           nxt_state = S_ARM;   // restart fresh
            end
            S_HOLD: begin
                // Latched all lanes; keep training_mode high (TX pattern +
                // clk_en) HOLD_CYCLES so the peer — now fed our continuous
                // pattern — also reaches sweep_success. We deliberately do
                // NOT react to lane_locked here: our (slip,phase) is latched
                // and physically correct; the peer switching to real data on
                // its own release will (correctly) drop our lane_checker,
                // which must NOT trigger a re-sweep. S_DONE is sticky.
                if (swreset)                   nxt_state = S_CANCEL;
                else if (!role_locked)         nxt_state = S_DONE;
                else if (hold_ctr >= HOLD_MAX) nxt_state = S_DONE;
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
    // T3.2 hold counter: cycles spent in S_HOLD. Reset whenever NOT in
    // S_HOLD (each S_HOLD entry starts fresh); free-runs while in S_HOLD,
    // saturating at HOLD_MAX (the S_HOLD→S_DONE release condition).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                       hold_ctr <= '0;
        else if (cur_state != S_HOLD)  hold_ctr <= '0;
        else if (hold_ctr < HOLD_MAX[$clog2(HOLD_CYCLES+1)-1:0])
                                       hold_ctr <= hold_ctr + 1'b1;
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
                slip[i]       <= 3'd0;
                phase[i]      <= 4'd0;
                lane_score[i] <= 6'd0;
                best_score[i] <= 6'd0;
                best_slip[i]  <= 3'd0;
                best_phase[i] <= 4'd0;
            end
        end else begin
            // Bug #7 synth-safety: plain `case` + explicit default (below).
            case (cur_state)
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
                        slip[i]       <= 3'd0;
                        phase[i]      <= 4'd0;
                        lane_score[i] <= 6'd0;
                        best_score[i] <= 6'd0;
                        best_slip[i]  <= 3'd0;
                        best_phase[i] <= 4'd0;
                    end
                end

                S_SWEEP: begin
                    // ----- Per-lane run-length score -----------------------
                    // Count consecutive lane_locked=1 cycles within the
                    // current dwell window; reset to 0 on any de-assert,
                    // saturate at LANE_SCORE_MAX. Cleared on dwell-window
                    // entry (see dwell_expire branch below).
                    for (int i = 0; i < 8; i++) begin
                        if (lane_locked[i]) begin
                            if (lane_score[i] != LANE_SCORE_MAX)
                                lane_score[i] <= lane_score[i] + 6'd1;
                        end else begin
                            lane_score[i] <= 6'd0;
                        end
                    end

                    // ----- EARLY_EXIT compat path --------------------------
                    // Capture (slip,phase) on the first dwell where a
                    // not-done lane sees lane_locked rise. Sweep terminates
                    // early when every lane is done.
                    if (early_exit_en_w) begin
                        for (int i = 0; i < 8; i++) begin
                            if (lane_new_lock[i]) begin
                                lane_done[i] <= 1'b1;
                                slip[i]      <= sweep_slip;
                                phase[i]     <= sweep_phase;
                            end
                        end
                    end

                    if (dwell_expire) begin
                        // ----- Best-of-sweep score capture -----------------
                        // At dwell-window expiry, compare this lane's
                        // in-window run-length against its running best
                        // and update best_{score,slip,phase} if greater.
                        // Done unconditionally so the legacy path also
                        // populates best_* (harmless side effect — outputs
                        // still come from slip[]/phase[]).
                        for (int i = 0; i < 8; i++) begin
                            if (lane_score[i] > best_score[i]) begin
                                best_score[i] <= lane_score[i];
                                best_slip[i]  <= sweep_slip;
                                best_phase[i] <= sweep_phase;
                            end
                            // Fresh dwell window next cycle.
                            lane_score[i] <= 6'd0;
                        end

                        // Dwell expired — advance the SHARED iterator
                        // (phase-outer, slip-inner). On the FINAL point
                        // (iter_at_end), finalise per-lane outputs.
                        dwell_ctr <= '0;
                        if (sweep_slip == 3'd7) begin
                            sweep_slip <= 3'd0;
                            if (sweep_phase == 4'd15) begin
                                // ----- Sweep exhaustion --------------------
                                // Best-of-sweep latch: for every lane whose
                                // best_score met LOCK_THRESH, load slip[]/
                                // phase[] from best_*; lanes that never met
                                // the bar fault out. In EARLY_EXIT mode the
                                // not-already-done lanes also fault, since
                                // sweep_phase==15&&slip==7 with no lock
                                // means the full space yielded no first-
                                // match — same fault semantics as §9.7.
                                // sweep_phase holds at 15.
                                for (int i = 0; i < 8; i++) begin
                                    if (early_exit_en_w) begin
                                        // §9.7 fault rule preserved.
                                        if (!lane_done[i] && !lane_new_lock[i]) begin
                                            lane_fault_q[i] <= 1'b1;
                                            lane_done[i]    <= 1'b1;
                                        end
                                    end else begin
                                        // §9.9 best-of-sweep latch.
                                        // best_score updated above in the
                                        // same cycle takes precedence (the
                                        // NBA on best_score is for NEXT
                                        // cycle, so the load uses the
                                        // PRE-update value plus the just-
                                        // observed lane_score if greater).
                                        // Encode that decision here directly.
                                        if (lane_score[i] > best_score[i]) begin
                                            if (lane_score[i] >= lock_thresh_6b) begin
                                                slip[i]  <= sweep_slip;
                                                phase[i] <= sweep_phase;
                                            end else begin
                                                lane_fault_q[i] <= 1'b1;
                                            end
                                        end else begin
                                            if (best_score[i] >= lock_thresh_6b) begin
                                                slip[i]  <= best_slip[i];
                                                phase[i] <= best_phase[i];
                                            end else begin
                                                lane_fault_q[i] <= 1'b1;
                                            end
                                        end
                                        lane_done[i] <= 1'b1;
                                    end
                                end
                            end else begin
                                sweep_phase <= sweep_phase + 4'd1;
                            end
                        end else begin
                            sweep_slip <= sweep_slip + 3'd1;
                        end
                    end else begin
                        // HAL PADMSB+UELOPR @288: width-match the increment
                        // to dwell_ctr ($clog2(DWELL_CYCLES+1) bits) so the
                        // RHS does not zero-pad a 1-bit literal across an
                        // unequal-length operand.
                        dwell_ctr <= dwell_ctr +
                                     {{($clog2(DWELL_CYCLES+1)-1){1'b0}}, 1'b1};
                    end
                end

                S_CANCEL: begin
                    // Hold state; no advances. Iterator/latched values
                    // retained for ILA.
                end

                default: begin
                    // S_IDLE / S_FINISH / S_DONE / S_HOLD — no datapath
                    // activity (clears handled in S_ARM branch above).
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // v2 EYE VISIBILITY datapath (proposal §6 + §13).
    //
    //   swi_eye_ctrl bit layout (re-stated here for the gating logic):
    //     [0]   ENTER          — W1P from APB; one-cycle arm pulse
    //     [1]   RESET          — W1P from APB; clears capture_valid + buf
    //     [5:4] MODE           — 2'b00 off, 2'b01 single-lane (Option A)
    //     [7]   REMOTE_TRIG_EN — reserved (Mechanism β, RAZ in v2)
    //     [8]   FORCE_FULL_SWEEP — informational mirror only here
    //     [9]   AUTO_INC_LANE — auto-advance lane_sel after each DONE
    //
    //   eye_status packing (§5 register map):
    //     [2:0]   state (0=IDLE, 1=SWEEPING, 2=DONE, 3=TIMED_OUT)
    //     [6:4]   last_swept_lane_id
    //     [7]     capture_valid (sticky, cleared by RESET)
    //     [11:8]  calibrator cur_state mirror
    //     [15:12] sweep_phase mirror
    //     [31:16] dwell_remaining_ms (saturating)
    // -------------------------------------------------------------------------
    wire eye_enter_pulse = swi_eye_ctrl[0];
    wire eye_reset_pulse = swi_eye_ctrl[1];
    wire [1:0] eye_mode  = swi_eye_ctrl[5:4];
    wire eye_auto_inc    = swi_eye_ctrl[9];
    wire eye_mode_single = (eye_mode == 2'b01);

    // 48-bit dwell countdown — large enough for 10 s @ 250 MHz × 1000
    // safety margin.  Loaded on ENTER from DWELL_US × CLK_MHZ.
    logic [47:0] dwell_ctr_us;
    wire  [47:0] dwell_load_val = {16'd0, swi_eye_dwell_us} *
                                  48'(CLK_MHZ);

    // Sticky-arm latch: ENTER pulse arms a sweep; cleared when sweep
    // completes (cur_state→S_DONE) or on RESET / forced timeout.
    logic eye_arm_q;
    logic eye_capture_valid_q;
    logic eye_timed_out_q;
    logic [2:0] eye_lane_sel_q;     // latched at ENTER; auto-incs in §13.3

    // EYE state for SW (matches eye_status[2:0]):
    //   3'd0 IDLE — eye_mode_single=0 or never armed
    //   3'd1 SWEEPING
    //   3'd2 DONE
    //   3'd3 TIMED_OUT
    logic [2:0] eye_state_q;

    // Single-lane Option A score buffer.  Wide-mode (EYE_BUF_WIDE=1)
    // extends to per-lane along a generate.  Index encoding matches
    // EYE_SCORE_IDX: idx[6:4]=slip, idx[3:0]=phase.
    logic [5:0] score_buf [0:127];
    generate if (EYE_BUF_WIDE) begin : g_wide_buf
        // Reserved wide-mode storage (Option A wide variant).  Each lane
        // owns its own 768-bit buffer; the read mux uses eye_lane_sel_q
        // as the row select.  Same no-reset policy as the single-lane
        // buffer (Verilator 4.028 cannot NBA an array under a for-loop).
        logic [5:0] score_buf_wide [0:7][0:127];
        always_ff @(posedge clk) begin
            if (eye_arm_q && (cur_state == S_SWEEP) && dwell_expire) begin
                for (int i = 0; i < 8; i++)
                    score_buf_wide[i][{sweep_slip, sweep_phase}] <= lane_score[i];
            end
        end
    end endgenerate

    // -------------------------------------------------------------------------
    // Eye arm / state machine.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            eye_arm_q           <= 1'b0;
            eye_capture_valid_q <= 1'b0;
            eye_timed_out_q     <= 1'b0;
            eye_lane_sel_q      <= 3'd0;
            eye_state_q         <= 3'd0;
            dwell_ctr_us        <= 48'd0;
        end else begin
            // RESET pulse: clears valid + timeout, returns to IDLE.
            if (eye_reset_pulse) begin
                eye_arm_q           <= 1'b0;
                eye_capture_valid_q <= 1'b0;
                eye_timed_out_q     <= 1'b0;
                eye_state_q         <= 3'd0;
                dwell_ctr_us        <= 48'd0;
            end else if (eye_enter_pulse && eye_mode_single) begin
                // ENTER pulse: capture lane_sel, load dwell, arm sweep.
                eye_arm_q           <= 1'b1;
                eye_lane_sel_q      <= swi_eye_lane_sel;
                eye_timed_out_q     <= 1'b0;
                eye_state_q         <= 3'd1;       // SWEEPING
                dwell_ctr_us        <= dwell_load_val;
            end else if (eye_arm_q) begin
                // While armed, count down dwell and watch for completion.
                if (dwell_ctr_us != 48'd0)
                    dwell_ctr_us <= dwell_ctr_us - 48'd1;

                if (cur_state == S_DONE) begin
                    eye_arm_q           <= 1'b0;
                    eye_capture_valid_q <= 1'b1;
                    eye_state_q         <= 3'd2;   // DONE
                    if (eye_auto_inc)
                        eye_lane_sel_q <= eye_lane_sel_q + 3'd1;
                end else if (dwell_ctr_us == 48'd0) begin
                    // Dwell timer expired without DONE → force timeout.
                    eye_arm_q       <= 1'b0;
                    eye_timed_out_q <= 1'b1;
                    eye_state_q     <= 3'd3;       // TIMED_OUT
                end
            end
        end
    end

    // Score-buffer write port (single-lane Option A).  Only writes when
    // we are in the SWEEP state with a dwell-window expiry and the eye
    // capture is armed.  Buffer contents are NOT zeroed on reset — SW
    // is expected to gate reads on eye_status.capture_valid; in
    // synthesisable form this maps onto a distributed RAM that does
    // not require an array-wide reset.  Verilator 4.028 cannot NBA an
    // array inside a for-loop, so we deliberately omit the clear.
    always_ff @(posedge clk) begin
        if (eye_arm_q && (cur_state == S_SWEEP) && dwell_expire) begin
            score_buf[{sweep_slip, sweep_phase}] <=
                lane_score[eye_lane_sel_q];
        end
    end

    // EYE_SCORE_DATA read port: combinational read from the single-lane
    // buffer.  In wide-mode the parent design's read mux is responsible
    // for picking the right row.
    assign eye_score_data        = score_buf[eye_score_idx];
    // best_score / best_slip / best_phase / lane_passed mirror the
    // existing per-lane sweep result for the selected lane.
    assign eye_score_best        = best_score [eye_lane_sel_q];
    assign eye_score_best_slip   = best_slip  [eye_lane_sel_q];
    assign eye_score_best_phase  = best_phase [eye_lane_sel_q];
    assign eye_score_lane_passed = (best_score[eye_lane_sel_q] >= lock_thresh_6b);

    // dwell_remaining_ms saturates at 16'hFFFF; ms = us/1000, computed
    // from the 48-bit counter divided by 1000*CLK_MHZ.  Synthesises to a
    // small constant divider — only used for SW progress display.
    wire [47:0] dwell_remaining_ms_w = dwell_ctr_us /
                                        (48'(CLK_MHZ) * 48'd1000);
    wire [15:0] dwell_remaining_ms   = (dwell_remaining_ms_w > 48'hFFFF) ?
                                       16'hFFFF :
                                       dwell_remaining_ms_w[15:0];

    assign eye_status = {
        dwell_remaining_ms,             // [31:16]
        sweep_phase,                    // [15:12]
        cur_state,                      // [11:8]
        eye_capture_valid_q,            // [7]
        eye_lane_sel_q,                 // [6:4]
        1'b0,                           // [3] reserved
        eye_state_q                     // [2:0]
    };

    // -------------------------------------------------------------------------
    // Output drivers
    // -------------------------------------------------------------------------
    // Per lane, the PHY must see:
    //   - the lane's LATCHED (slip,phase) once it is done — that is, after
    //     sweep exhaustion in best-of-sweep mode, or after the first lock
    //     in EARLY_EXIT mode;
    //   - the LIVE shared iterator (sweep_phase,sweep_slip) while the
    //     sweep is still walking.
    // In best-of-sweep mode all lanes flip to "done" together (one cycle
    // after the final dwell-window expires) and their outputs latch to
    // best_slip/best_phase or to the just-observed (sweep_slip,sweep_phase)
    // if its lane_score exceeded best_score. Lanes with best_score below
    // LOCK_THRESH set lane_fault and hold their last iterator value.
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
            training_mode    = (cur_state == S_ARM) || (cur_state == S_SWEEP)
                            || (cur_state == S_HOLD);   // T3.2: hold pattern
            calibration_done = (cur_state == S_DONE);
        end
    end

    assign lane_fault = lane_fault_q;

endmodule
