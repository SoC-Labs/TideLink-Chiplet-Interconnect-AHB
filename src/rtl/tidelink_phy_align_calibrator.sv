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
// Selection policy — EYE-CENTRE via MIN_LOCK_DWELLS (§9.11, 2026-05-27)
// -----------------------------------------------------------------------------
//
// FIELD MOTIVATION (history-of-policies):
//   §9.7  first-match-wins      — picked the FIRST passing point; latched the
//                                 eye EDGE → bringup_health_probe oscillated.
//   §9.9  best-of-sweep         — picked the highest-scoring per-dwell run
//                                 length; race-to-tie on bit-exact PHYs meant
//                                 M and S converged to DIFFERENT points (Agent
//                                 D: M=(0,0), S=(1,1)). Broke M→S decode.
//   §9.10 S_PROBE bias-to-(0,0) — Agent F's sim-fix: latch (0,0) on every
//                                 lane that locks at (0,0); fall through if
//                                 not. Passed cocotb 5/6 but is a sim-only win
//                                 — tdif-21 HW build proved (0,0) does NOT
//                                 lock on real silicon (no-op fix). Also
//                                 inverts the §9.9 eye-CENTRE intent: even
//                                 when the eye is centred ELSEWHERE the
//                                 policy clamps to (0,0).
//
// §9.11 NEW POLICY — eye-centre via MIN_LOCK_DWELLS contiguity along the
// PHASE axis:
//
//   * Sweep order is slip-OUTER, phase-INNER (was phase-outer, slip-inner
//     in §9.7/§9.9). The phase axis is the actual sub-bit sample-point eye
//     dimension on this GPIO-PHY; bit_slip is a 16-bit-window rotation
//     (typically one slip value is "right"). Walking phase inner-most so
//     that contiguous passing dwells = adjacent eye points.
//
//   * At each dwell-expire, per lane, decide whether THIS (slip, phase)
//     "passes" — defined as in-dwell lane_score >= LOCK_THRESH. Track a
//     running contiguous-phase-pass count `run_len[lane]`; reset to 0 when
//     phase wraps 15→0 (new slip) or when a phase fails.
//
//   * Maintain per-lane `best_run[lane]` — the longest contiguous PHASE run
//     seen anywhere on the sweep grid — together with the run's start
//     phase and the slip it was found at.
//
//   * At sweep exhaustion the FSM enters S_FINALIZE (one extra cycle); for
//     every lane whose `best_run >= MIN_LOCK_DWELLS`, latch
//     phase[i] = best_run_start_phase + (best_run-1)/2  (run CENTRE)
//     slip[i]  = best_run_slip                          (slip the run was at)
//     This puts the deserialiser AT THE CENTRE OF THE WIDEST EYE, not at
//     the edge — defeating both the §9.7 oscillation AND the §9.9 race-
//     to-tie (eye-centre is deterministic given identical lock maps).
//
//   * S_PROBE is RETAINED but DEMOTED to advisory: it records
//     `probe_lane_pass_q[lane]` for any lane that locks at (0,0) but does
//     NOT set lane_done. The full sweep ALWAYS runs. S_FINALIZE consults
//     probe_lane_pass_q ONLY as a fallback when no MIN_LOCK_DWELLS-wide
//     run was found anywhere on the grid (degenerate-eye safety net for
//     silicon at marginal margin).
//
// MIN_LOCK_DWELLS sizing: default 4 gives 25% margin on the 16-phase axis,
// matches the empirical eye width observed on tdif-22 (~6/16 phase combos
// passed). APB-runtime tunable via `min_lock_dwells_i[3:0]` so silicon
// deploys can raise it without re-synth.
//
// CORRECTNESS / COMPAT: the legacy first-match-wins (§9.7) behaviour is
// available via parameter `EARLY_EXIT_ON_ALL_LOCKED` (or its runtime hook
// `tb_early_exit_force_q`) — when set, a lane freezes on its first lock
// just as in §9.7 and S_FINALIZE is skipped. Provided for cocotb/UVM
// tests whose timing assumptions depend on first-match wall time.
//
// A lane is faulted only after the full 128-point space is exhausted AND
// `best_run < MIN_LOCK_DWELLS` AND `probe_lane_pass_q == 0`.
//
// If `swreset` asserts mid-sweep, the FSM cancels and waits for swreset to
// deassert; that falling edge re-triggers the sweep from scratch.
//
// -----------------------------------------------------------------------------
// Sizing
// -----------------------------------------------------------------------------
//
// Parallel sweep, DWELL_CYCLES=64 by default (4× the 16-cycle LOCK_THRESH
// in the wlink_lane_checker). Worst case under §9.11 eye-centre policy is
// the FULL 128-point space every sweep + 1 cycle for S_FINALIZE, i.e.
// 16 phase × 8 slip × 64 cycles + 1 = 8193 cycles. At a 250 MHz link
// clock that is ~33 µs.
//
// Flop budget vs §9.9 (8 lanes):
//   §9.11 NEW state for eye-centre selection:
//     - run_len[i]              5b × 8 = 40   (current contiguous phase run)
//     - best_run[i]             5b × 8 = 40   (longest run seen this sweep)
//     - best_run_start_phase[i] 4b × 8 = 32
//     - best_run_slip[i]        3b × 8 = 24
//     - cur_run_start_phase[i]  4b × 8 = 32
//     - probe_lane_pass_q[i]    1b × 8 =  8   (S_PROBE advisory verdict)
//   Removed from §9.9 (replaced by run-length tracking):
//     - best_score[i]           6b × 8 = 48   (was: dwell run-length)
//     - best_slip[i]            3b × 8 = 24
//     - best_phase[i]           4b × 8 = 32
//   Kept (still used by §9.11 dwell pass-check):
//     - lane_score[i]           6b × 8 = 48   (in-dwell lock count)
// Net delta: +72 flops (176 new − 104 removed). Combinational cost: one
// (lane_score >= LOCK_THRESH) comparator + run-length update per lane at
// each dwell-expire, plus a single combinational centre-of-run mux at
// S_FINALIZE.
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
    //   0 (silicon default) — §9.11 EYE-CENTRE policy via MIN_LOCK_DWELLS
    //     contiguity along phase axis. Sweep walks all 128 points; the
    //     latched (slip,phase) is the CENTRE of the widest contiguous
    //     phase-run that passed LOCK_THRESH. Defeats both the §9.7
    //     edge-of-eye oscillation AND the §9.9 race-to-tie that broke
    //     M→S decode on sim/HW with bit-exact-passing-everywhere PHYs.
    //   1 (compat / sim) — restore the §9.7 first-match-wins behaviour:
    //     a lane freezes on its first dwell with lane_locked rising and
    //     the sweep terminates early when all lanes are done. Existing
    //     cocotb/UVM tests whose timing assumptions depend on the early
    //     exit set this to 1 (via the tb_early_exit_force_q hierarchical-
    //     force hook below) without re-elaborating the design.
    parameter logic EARLY_EXIT_ON_ALL_LOCKED = 1'b0,
    // §9.11 eye-centre policy: minimum contiguous-passing-phase run length
    // for a (slip,phase) point to be accepted as the lane's latched eye
    // centre. Default 4 = 25% of the 16-phase axis, matches the empirical
    // tdif-22 eye width (~6/16 phase combos passing). Raise for tighter
    // centring; lower (down to 1) reduces the policy to "earliest passing
    // point wins" (the §9.9 race-to-tie returns at 1). Bounded 1..15 by
    // the 4-bit APB override register on the chiplet-controller side.
    parameter int MIN_LOCK_DWELLS = 4,
    // §9.11d Fix A1 (post-S_HOLD real-data validation): after S_HOLD
    // expires we enter S_VALIDATE with training_mode=0 (letting the FCSM
    // emit a CR_PKT). We wait up to VALIDATION_TIMEOUT cycles for our
    // local cr_pkt_seen_rx to assert (confirming our RX correctly decoded
    // the peer's CR_PKT — real-data validation of the latched per-lane
    // slip/phase, not just the training-byte criterion). On timeout we
    // re-arm (T3 retry budget applies) so the calibrator can try a
    // different (slip, phase). Default 4096 ≈ 80 µs at 50 MHz link_clk
    // — plenty for an FCSM CR exchange round trip.
    parameter int VALIDATION_TIMEOUT = 4096,
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

    // -----------------------------------------------------------------
    // Spec §7.1: per-lane continuous in-dwell minimum distance from the
    // new tidelink-gpio-phy lane_checker. dwell_min_dist_i[5*i +: 5] is
    // the smallest dist_score (= min(dist_match, 16 - dist_match)) seen
    // since the last sweep_active_o assertion / dwell start. Resets each
    // dwell. The calibrator uses this as a noise-robust scoring metric:
    // a single bit-flip during the dwell does not drop the score the way
    // the binary lane_locked[i] consecutive-match counter does.
    //
    // Wired from the lane_checker's dwell_min_dist_o output. Same clock
    // domain as the calibrator (link_clk_rx) → no CDC.
    // -----------------------------------------------------------------
    input  wire  [39:0] dwell_min_dist_i,

    // SW debug override (optional)
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,

    // §9.11c APB runtime MIN_LOCK_DWELLS override (Region 8 slot 3'h0
    // bits[7:4] via the axi_chiplet_controller local override). 0 = use
    // synth-time parameter default; 1..15 = override at runtime. Lets SW
    // tune the eye-centre policy's contiguity requirement without
    // re-elaboration. Slow APB-domain signal sampled in the calibrator
    // clock domain — see CDC note at the chiplet_controller instantiation.
    input  logic [3:0]  min_lock_dwells_i,

    // §9.11d Fix A1 real-data validation input.
    // Driven from axi_chiplet_controller's `obs_cr_pkt_seen_rx_w` — the
    // local Wlink FCSM's "saw the peer's CR_PKT on our RX" flag, sticky-
    // high once the credit-request packet has been decoded. Same clock
    // domain as the calibrator (recovered RX link clock) so no CDC.
    // Used by S_VALIDATE: if asserted during the validation window, the
    // latched per-lane (slip, phase) is confirmed working on real data
    // (not just training pattern) → S_DONE. If not asserted within
    // VALIDATION_TIMEOUT cycles, the latched values fail real-data decode
    // (OVERNIGHT_2026_05_27 "training too lenient" prediction) → re-arm.
    input  logic        cr_pkt_seen_i,

    // §9.11d Fix A2 (2026-06-04) real-data validation — CRACK companion.
    // Driven from axi_chiplet_controller's `obs_crack_pkt_seen_rx_w` (the
    // local FCSM's "saw the peer's CRACK_PKT on our RX" sticky flag). The
    // credit-init handshake is symmetric (both dies emit CR then CRACK), but
    // the master's RX framer byte-aligns AFTER the slave has already left
    // FCSM state 1 and switched to emitting CRACK-only — so on the master,
    // cr_pkt_seen never latches while crack_pkt_seen does. The Wlink FCSM
    // already tolerates this (it advances on cr OR crack, _GEN_34); this
    // input lets S_VALIDATE use the SAME criterion. Reaching FCSM state 4
    // with crack_pkt_seen=1 is conclusive proof the latched (slip,phase)
    // decodes real packets — the cr-vs-crack distinction is a timing
    // artifact, not a datapath-health signal. Without this, the master
    // hangs in S_VALIDATE (cal_done=0) while its FCSM is happy at state 4 —
    // the observed silicon symptom (cal_done=0, crack=1, FCSM=4).
    // Same clock domain as the calibrator (recovered RX link clock) → no CDC.
    input  logic        crack_pkt_seen_i,

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

    // -----------------------------------------------------------------
    // Spec §7.2: sweep_active_o gates the new lane_checker's voting
    // path during the calibrator's S_SWEEP — while (slip, phase) is
    // changing every dwell the 3-window vote sees inconsistent phases
    // and must be disabled. Driven from cur_state == S_SWEEP. The
    // checker uses this to clamp vote_enable = 0 regardless of
    // locked_pre. Vote re-enables in S_HOLD and post-S_DONE for
    // steady-state matching.
    // -----------------------------------------------------------------
    output wire         sweep_active_o,

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
        S_HOLD       = 4'd6,   // T3.2: locked locally; keep training_mode
                               //       high HOLD_CYCLES so the peer converges
        // -------------------------------------------------------------------
        // Spec §7.3 / f900e07 — S_PROBE: ACTIVE bias-to-(0,0) probe state.
        //
        // S_PROBE dwells DWELL_CYCLES at (sweep_slip=0, sweep_phase=0) — i.e.
        // the natural / un-shifted RX deserialiser configuration — and per-
        // lane checks whether the lane_checker locks on this rotation. For
        // every lane that DOES lock at (0,0), we latch slip[i]=0,
        // phase[i]=0, lane_done[i]=1 and seed best_run* with (0,0,
        // lock_thresh_6b) so neither the §9.11 eye-centre policy nor the
        // §9.11b any_pass safety net can displace the probe verdict for
        // those lanes (their work is gated off by lane_done[i] in S_SWEEP
        // and S_FINALIZE). Lanes that did NOT lock at (0,0) fall through
        // to the full S_SWEEP search.
        //
        // Note (spec §7.1): lane_score uses the new lane_checker's
        // continuous dwell_min_dist scoring — lane_dist_pass_w[i] gates
        // the per-cycle increment instead of the binary lane_locked[i].
        //
        // probe_lane_pass_q[lane] is also latched as the legacy §9.11b
        // S_FINALIZE fallback — lanes that fell through to S_SWEEP but
        // could not find a wide eye there can still rescue via the probe
        // verdict if (0,0) had passed.
        //
        // Transitions: S_ARM → S_PROBE always. On dwell_expire:
        //   * probe_all_locked → S_FINISH (skip the 128-point sweep)
        //   * partial pass     → S_SWEEP for the remaining lanes
        //
        // History: §9.10 (Agent F) introduced this with absolute priority;
        // §9.11 demoted it to advisory; spec §7.3 restores the f900e07
        // active form because the new dual-distance metric removes the
        // false-lock concern that motivated the §9.11 demotion (the
        // continuous metric is symmetric across own/inverse and cannot be
        // dragged into a swapped-lane rot-8 false lock).
        // -------------------------------------------------------------------
        S_PROBE      = 4'd7,
        // -------------------------------------------------------------------
        // §9.11 S_FINALIZE — single-cycle eye-centre selection.
        //
        // Entered when S_SWEEP exhausts (sweep_phase==15, sweep_slip==7,
        // dwell_expire). For every lane:
        //   * if best_run[i] >= min_lock_dwells_eff:
        //       phase[i] <= best_run_start_phase[i] + (best_run[i]-1)/2
        //       slip[i]  <= best_run_slip[i]
        //       lane_done[i] <= 1
        //   * elsif probe_lane_pass_q[i]:
        //       phase[i] <= 0; slip[i] <= 0;
        //       lane_done[i] <= 1
        //   * else:
        //       lane_fault_q[i] <= 1; lane_done[i] <= 1
        // -------------------------------------------------------------------
        S_FINALIZE   = 4'd8,
        // -------------------------------------------------------------------
        // §9.11d Fix A1 — post-S_HOLD real-data validation state.
        //
        // Entered from S_HOLD after HOLD_CYCLES expire. Drops training_mode
        // (so the FCSM can emit a CR_PKT — the start of bilateral credit
        // exchange that the bug regression test_05 needs). Waits up to
        // VALIDATION_TIMEOUT cycles for cr_pkt_seen_i to assert, meaning
        // our local RX (configured by the latched (slip, phase) per lane)
        // correctly decoded the peer's CR_PKT bytes.
        //
        //   * cr_pkt_seen_i asserts within timeout → S_DONE (latched values
        //     validated on REAL data, not just training pattern)
        //   * timeout without cr_pkt_seen → S_ARM (re-arm sweep with T3
        //     retry budget; the (slip, phase) was a training-pattern false-
        //     positive per OVERNIGHT_2026_05_27 prediction)
        //
        // Addresses the gap §9.11/§9.11b leaves: passing LOCK_THRESH on the
        // training byte is NECESSARY but not SUFFICIENT for stable data
        // decode (per OVERNIGHT_2026_05_27 SW-sweep evidence — 6/16 (M,S)
        // phase combos reached LINK_IDLE but doorbells didn't cross).
        // -------------------------------------------------------------------
        S_VALIDATE   = 4'd9
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
    //   - slip[lane]  : LATCHED slip (loaded from best_run_slip at S_FINALIZE,
    //                   or — in EARLY_EXIT mode — captured on first lock)
    //   - phase[lane] : LATCHED phase (run-centre at S_FINALIZE, or first-lock
    //                   iterator value in EARLY_EXIT mode)
    //   - done[lane]  : lane has either locked-and-latched (EARLY_EXIT
    //                   mode) or S_FINALIZE has assigned its (slip,phase)
    //
    // §9.11 eye-centre tracking (§9.9 best_score replaced):
    //   - lane_score[lane]          : 6-bit run-length counter of consecutive
    //                                 lane_locked=1 cycles within the CURRENT
    //                                 dwell window. Saturates at 6'h3F. Used
    //                                 only for the "dwell passed LOCK_THRESH"
    //                                 check at dwell_expire.
    //   - run_len[lane]             : 5-bit current contiguous-passing-phase
    //                                 count at the current slip. Resets on a
    //                                 failing dwell or when phase wraps 15→0
    //                                 (new slip).
    //   - cur_run_start_phase[lane] : phase at which the current run started.
    //   - best_run[lane]            : 5-bit longest passing-phase run seen
    //                                 anywhere on the sweep grid this sweep.
    //   - best_run_start_phase[lane]: phase where best_run started.
    //   - best_run_slip[lane]       : slip at which best_run was found.
    //   - probe_lane_pass_q[lane]   : 1-bit S_PROBE advisory verdict: 1 iff
    //                                 the lane locked at (slip=0, phase=0)
    //                                 during S_PROBE. Used as fallback in
    //                                 S_FINALIZE when best_run < MIN_LOCK_DWELLS.
    //
    // A SINGLE SHARED (slip,phase) iterator (sweep_slip, sweep_phase) plus a
    // shared dwell counter walks the search space — the sweep is fully
    // parallel across lanes.
    //
    // Iteration order is slip-OUTER, phase-INNER (§9.11; was phase-outer,
    // slip-inner in §9.7/§9.9): sweep_phase cycles 0→15, and only when it
    // wraps 15→0 does sweep_slip advance. Walking phase inner-most makes
    // contiguous passing dwells = adjacent eye points on the actual
    // sub-bit-sample-point axis, so the run-length tracker measures REAL
    // eye width and not a slip-rotation artefact.
    //
    // SELECTION POLICY (when early_exit_en_w==0, silicon default — §9.11):
    //   - lane_done[i] STAYS LOW for the entire sweep — every lane walks
    //     all 128 points. At each dwell-window expiry we check whether
    //     lane_score[i] >= LOCK_THRESH; if yes, extend run_len[i] and
    //     update best_run[i] if the run is now wider; if no (or on
    //     slip-change), close the run.
    //   - At sweep exhaustion the FSM transitions S_SWEEP → S_FINALIZE.
    //     In S_FINALIZE each lane's outputs are assigned:
    //       best_run[i] >= min_lock_dwells_eff  → eye centre of best_run
    //       elsif probe_lane_pass_q[i]          → (slip=0, phase=0)
    //       else                                → lane_fault[i] := 1
    //
    // LEGACY POLICY (early_exit_en_w==1):
    //   - lane_done[i] is set on the first dwell where lane_locked[i]
    //     rises, and slip[i]/phase[i] capture the iterator's current
    //     (slip,phase). Sweep terminates early when all lanes are done.
    //     Matches §9.7 first-match-wins exactly. S_FINALIZE is bypassed.
    // -------------------------------------------------------------------------
    logic [2:0] slip      [0:7];   // per-lane latched output slip
    logic [3:0] phase     [0:7];   // per-lane latched output phase
    logic [7:0] lane_done;         // sticky during a sweep
    logic [7:0] lane_fault_q;
    // Shared search iterator (slip-OUTER, phase-INNER per §9.11).
    logic [2:0] sweep_slip;        // 0..7
    logic [3:0] sweep_phase;       // 0..15
    logic [$clog2(DWELL_CYCLES+1)-1:0] dwell_ctr;
    localparam int DWELL_MAX = DWELL_CYCLES - 1;

    // §9.11 eye-centre tracking
    // EYE_WIDTH_W = ceil(log2(16+1)) = 5; phase axis is 0..15 + saturation.
    localparam int EYE_WIDTH_W = 5;
    logic [5:0]             lane_score             [0:7]; // in-dwell run, sat 6'h3F
    logic [EYE_WIDTH_W-1:0] run_len                [0:7]; // current phase run
    logic [EYE_WIDTH_W-1:0] best_run               [0:7]; // longest phase run
    logic [3:0]             cur_run_start_phase    [0:7];
    logic [3:0]             best_run_start_phase   [0:7];
    logic [2:0]             best_run_slip          [0:7];
    logic [7:0]             probe_lane_pass_q;
    // §9.11b single-point fallback: first (slip, phase) seen during S_SWEEP
    // where the lane scored >= LOCK_THRESH. Used as the LAST-RESORT safety
    // net in S_FINALIZE when (a) no MIN_LOCK_DWELLS-wide eye exists AND
    // (b) the (0,0) probe verdict also failed. Restores the §9.10
    // "any single passing point wins" coverage for narrow-eye corners
    // (per-lane delay, single-point cocotb PHY models, marginal-margin
    // silicon) without weakening the §9.11 eye-centre policy when an
    // eye exists. ~64 added flops (8 lanes × (3+4+1)).
    logic [7:0] any_pass_valid;
    logic [2:0] any_pass_slip  [0:7];
    logic [3:0] any_pass_phase [0:7];
    localparam logic [5:0] LANE_SCORE_MAX = 6'h3F;
    // Promote LOCK_THRESH to the 6-bit score width safely.
    wire   [5:0] lock_thresh_6b   = LOCK_THRESH[5:0];

    // -------------------------------------------------------------------------
    // Spec §7.1 / §4.2 — per-dwell distance-score threshold for the new
    // tidelink-gpio-phy lane_checker scoring path.
    //
    // The legacy lane_locked[i] input is a SW-visible binary lock signal
    // (gated by lock_thresh_i in the checker — typical default T=3 per
    // spec §4.2). The calibrator wants a TIGHTER, continuous metric for
    // eye-centre selection so that a single bit-flip during a dwell does
    // not zero the consecutive-match count.
    //
    // dwell_min_dist_i[5*i +: 5] is the minimum dist_score observed since
    // dwell start (continuous metric, §4.1 dual-distance). A dwell cycle
    // counts as "passing" for lane_score[i] iff that minimum is
    // <= LOCK_DIST_THRESHOLD (= 3, matching the default matcher T from
    // spec §4.2). This is intentionally stricter than the SW-visible
    // lane_locked[i] for two reasons:
    //   * Symmetric across own/inverse (dist_score = min(d, 16-d) — see
    //     §4.1) so a swapped-lane rot-8 false lock cannot drag the
    //     calibrator into the wrong eye centre.
    //   * Robust to single-cycle noise — the in-dwell *minimum* settles
    //     to 0 on a genuinely locked phase and only rises when an actual
    //     bit error occurs, instead of resetting on every glitch.
    // Backwards compat: lane_locked[i] is RETAINED as an input — it still
    // gates the `probe_lane_pass_q` advisory verdict in S_FINALIZE's
    // legacy path and is exposed unchanged via SWI_LANE_STATUS.
    // -------------------------------------------------------------------------
    localparam logic [4:0] LOCK_DIST_THRESHOLD = 5'd3;

    // -------------------------------------------------------------------------
    // Spec §7.2 — vote-disable strobe for the new lane_checker.
    // High while the calibrator is walking the (slip, phase) grid;
    // tells the checker's 3-window voter to clamp vote_enable=0.
    // -------------------------------------------------------------------------
    assign sweep_active_o = (cur_state == S_SWEEP);

    // Per-lane "this cycle passes" predicate using the new dist-score
    // metric. lane_dist_pass[i] = (dwell_min_dist_i for lane i is at or
    // below the LOCK_DIST_THRESHOLD).
    //
    // Fix A2 (audit 2026-05-29): no longer consumed by S_PROBE / S_SWEEP
    // because dwell_min_dist_o doesn't reset per dwell (see
    // docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md H1). Kept for
    // observability / future use once the lane_checker grows a per-dwell
    // reset; the dwell_min_dist_i port and the LOCK_DIST_THRESHOLD
    // localparam are retained likewise.
    /* verilator lint_off UNUSED */
    wire [7:0] lane_dist_pass_w;
    /* verilator lint_on UNUSED */
    genvar gdist;
    generate
        for (gdist = 0; gdist < 8; gdist = gdist + 1) begin : g_dist_pass
            assign lane_dist_pass_w[gdist] =
                (dwell_min_dist_i[5*gdist +: 5] <= LOCK_DIST_THRESHOLD);
        end
    endgenerate
    // §9.11c effective MIN_LOCK_DWELLS — APB runtime override beats synth
    // param. min_lock_dwells_i is 4 bits driven from
    // axi_chiplet_controller's swi_cal_min_dwells_r (Region 8 slot 3'h0
    // bits[7:4]). Reading 4'd0 in this port forces the synth-time param
    // default; non-zero overrides at runtime. Lets SW tune the centring
    // requirement live (e.g. lower to 1 if real silicon's eye is single-
    // point and the eye-centre policy can't find a 4-wide run).
    wire [EYE_WIDTH_W-1:0] min_lock_dwells_eff =
        (min_lock_dwells_i == 4'd0) ?
            MIN_LOCK_DWELLS[EYE_WIDTH_W-1:0] :
            {1'b0, min_lock_dwells_i};

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

    // Agent-F §9.10: at S_PROBE dwell_expire, are ALL 8 lanes locked at
    // (slip=0, phase=0)? lane_score[i] reaches LOCK_THRESH iff the lane
    // saw >= LOCK_THRESH consecutive lane_locked=1 cycles within this dwell.
    // If all 8 lanes pass, the sweep can be skipped entirely.
    wire [7:0] probe_lane_pass_w;
    genvar gprobe;
    generate
        for (gprobe = 0; gprobe < 8; gprobe = gprobe + 1) begin : g_probe_pass
            assign probe_lane_pass_w[gprobe] =
                (lane_score[gprobe] >= lock_thresh_6b);
        end
    endgenerate
    wire probe_all_locked = &probe_lane_pass_w;

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

    // §9.11d Fix A1 — validation-timeout counter (cycles in S_VALIDATE).
    // Saturates at VALIDATION_TIMEOUT-1; S_VALIDATE → S_ARM (re-sweep) on
    // saturation if cr_pkt_seen_i didn't assert.
    localparam int VAL_MAX = VALIDATION_TIMEOUT - 1;
    logic [$clog2(VALIDATION_TIMEOUT+1)-1:0] val_ctr;

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
                // Agent-F §9.10: enter S_PROBE first to test (slip=0, phase=0)
                // before the full 128-point sweep. See state-encoding comment.
                if (swreset)            nxt_state = S_CANCEL;
                else                    nxt_state = S_PROBE;
            end
            S_PROBE: begin
                // Spec §7.3 (port from f900e07): S_PROBE is ACTIVE — it
                // dwells DWELL_CYCLES at (sweep_slip=0, sweep_phase=0)
                // and, on dwell_expire, latches slip[i]=0/phase[i]=0/
                // lane_done[i]=1 for every lane whose in-dwell score
                // crossed lock_thresh_6b. The probe_lane_pass_q array
                // captures the per-lane verdict for the legacy
                // §9.11/§9.11b S_FINALIZE fallback path.
                //
                // Transitions:
                //   * swreset       → S_CANCEL
                //   * dwell_expire & probe_all_locked → S_FINISH
                //     (all 8 lanes locked at (0,0) — skip the 128-point
                //      sweep entirely; S_FINALIZE is bypassed because
                //      the per-lane latches happened in S_PROBE)
                //   * dwell_expire & partial pass → S_SWEEP
                //     (lanes that did NOT pass at (0,0) fall through
                //      to the normal best-of-sweep search)
                if (swreset)                       nxt_state = S_CANCEL;
                else if (dwell_expire) begin
                    if (probe_all_locked)          nxt_state = S_FINISH;
                    else                           nxt_state = S_SWEEP;
                end
            end
            S_SWEEP: begin
                // §9.11: best-of-sweep walks the full 128-point space and
                // transitions to S_FINALIZE on sweep_exhausted (one cycle
                // to compute per-lane eye-centre latches). EARLY_EXIT compat
                // mode keeps the §9.7 first-match-wins early termination
                // and bypasses S_FINALIZE — its per-lane latches happened
                // at first-lock in the datapath, lane_done is already set.
                if (swreset)                                   nxt_state = S_CANCEL;
                else if (early_exit_en_w && all_done)          nxt_state = S_FINISH;
                else if (sweep_exhausted)                      nxt_state = S_FINALIZE;
            end
            S_FINALIZE: begin
                // §9.11: single-cycle state. Datapath assigns per-lane
                // slip[i]/phase[i] (run centre), lane_done[i], or
                // lane_fault_q[i]. Transitions to S_FINISH unconditionally
                // (except swreset). All work happens in the datapath this
                // same cycle.
                if (swreset) nxt_state = S_CANCEL;
                else         nxt_state = S_FINISH;
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
                // which must NOT trigger a re-sweep.
                //
                // §9.11d Fix A1: at HOLD_CYCLES expire, instead of going
                // straight to S_DONE, enter S_VALIDATE to confirm the
                // latched (slip, phase) actually decodes the peer's CR_PKT
                // on real data (not just training pattern).
                if (swreset)                   nxt_state = S_CANCEL;
                else if (!role_locked)         nxt_state = S_DONE;
                else if (hold_ctr >= HOLD_MAX) nxt_state = S_VALIDATE;
            end
            S_VALIDATE: begin
                // §9.11d Fix A1 real-data validation.
                //
                // training_mode is now LOW (see output mux below — S_VALIDATE
                // intentionally NOT in the training-mode assert list). The
                // FCSM is free to emit its CR_PKT. Our local FCSM signals
                // cr_pkt_seen_rx (= cr_pkt_seen_i input here) when it
                // successfully decodes the peer's CR_PKT.
                //
                //   * cr_pkt_seen_i within timeout → S_DONE (real-data
                //     validated)
                //   * timeout without cr_pkt_seen → re-arm sweep (T3
                //     retry budget governs whether to give up via
                //     retry_exhausted, same path as a normal lane fault).
                if (swreset)                  nxt_state = S_CANCEL;
                else if (!role_locked)        nxt_state = S_DONE;
                // Fix A2: accept CR *or* CRACK (match FCSM _GEN_34). The
                // master only ever decodes the peer's CRACK (late framer
                // byte-align); validating on CRACK lets it reach S_DONE/
                // cal_done=1 exactly as its FCSM already reaches state 4.
                else if (cr_pkt_seen_i || crack_pkt_seen_i) nxt_state = S_DONE;
                else if (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0])
                    nxt_state = retry_exhausted ? S_DONE : S_ARM;
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

    // §9.11d Fix A1 — validation-timeout counter. Cleared whenever NOT in
    // S_VALIDATE; saturates at VAL_MAX while in S_VALIDATE.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                          val_ctr <= '0;
        else if (cur_state != S_VALIDATE) val_ctr <= '0;
        else if (val_ctr < VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0])
                                          val_ctr <= val_ctr + 1'b1;
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
            dwell_ctr            <= '0;
            lane_done            <= 8'h00;
            lane_fault_q         <= 8'h00;
            sweep_slip           <= 3'd0;
            sweep_phase          <= 4'd0;
            probe_lane_pass_q    <= 8'h00;
            any_pass_valid       <= 8'h00;
            for (int i = 0; i < 8; i++) begin
                slip[i]                  <= 3'd0;
                phase[i]                 <= 4'd0;
                lane_score[i]            <= 6'd0;
                run_len[i]               <= '0;
                best_run[i]              <= '0;
                cur_run_start_phase[i]   <= 4'd0;
                best_run_start_phase[i]  <= 4'd0;
                best_run_slip[i]         <= 3'd0;
                any_pass_slip[i]         <= 3'd0;
                any_pass_phase[i]        <= 4'd0;
            end
        end else begin
            // Bug #7 synth-safety: plain `case` + explicit default (below).
            case (cur_state)
                S_ARM: begin
                    // Fresh sweep — clear all per-sweep state. cur_state==S_ARM
                    // persists for exactly one cycle (S_ARM → S_PROBE or
                    // S_CANCEL), so this fires once per sweep launch.
                    dwell_ctr            <= '0;
                    lane_done            <= 8'h00;
                    lane_fault_q         <= 8'h00;
                    sweep_slip           <= 3'd0;
                    sweep_phase          <= 4'd0;
                    probe_lane_pass_q    <= 8'h00;
                    any_pass_valid       <= 8'h00;
                    for (int i = 0; i < 8; i++) begin
                        slip[i]                  <= 3'd0;
                        phase[i]                 <= 4'd0;
                        lane_score[i]            <= 6'd0;
                        run_len[i]               <= '0;
                        best_run[i]              <= '0;
                        cur_run_start_phase[i]   <= 4'd0;
                        best_run_start_phase[i]  <= 4'd0;
                        best_run_slip[i]         <= 3'd0;
                        any_pass_slip[i]         <= 3'd0;
                        any_pass_phase[i]        <= 4'd0;
                    end
                end

                // -----------------------------------------------------------
                // Spec §7.3 / f900e07 — S_PROBE: dwell DWELL_CYCLES at the
                // natural (slip=0, phase=0) point and per-lane latch (0,0)
                // for any lane whose continuous in-dwell minimum distance
                // (dwell_min_dist_i[5*i +: 5]) stays at/below
                // LOCK_DIST_THRESHOLD for >= LOCK_THRESH cycles.
                //
                // Note Step 6 scoring change (spec §7.1): lane_score
                // increments on lane_dist_pass_w[i] — the §4.1 continuous
                // dual-distance metric — instead of the legacy binary
                // lane_locked[i]. lane_locked[i] is retained for the
                // §9.11 advisory verdict (probe_lane_pass_q) so the
                // S_FINALIZE single-point and any-pass fallbacks still
                // observe the SW-visible lock criterion.
                //
                // sweep_slip/sweep_phase are 0 (cleared in S_ARM), so the
                // output mux drives (0,0) on every lane during S_PROBE.
                //
                // On dwell_expire (f900e07 active mode):
                //   - lanes with lane_score[i] >= lock_thresh_6b get
                //     slip[i]=0, phase[i]=0, lane_done[i]=1, and
                //     best_run is seeded so the §9.11 S_FINALIZE eye-
                //     centre selection cannot displace them.
                //   - Lanes that did NOT pass leave lane_done=0 and fall
                //     through to S_SWEEP (with their full sweep budget).
                // -----------------------------------------------------------
                S_PROBE: begin
                    // In-dwell lock counter (saturating).
                    // Fix A2 (audit 2026-05-29, see
                    // docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md):
                    // REVERTED from Step 6 (8409d6b) lane_dist_pass_w
                    // gating back to the binary lane_locked[i]. The
                    // lane_checker's dwell_min_dist_o is a monotonic
                    // running minimum that only resets on clear_noise or
                    // training_mode_rise (NOT per dwell), so
                    // lane_dist_pass_w[i] is sticky-true after dwell 1
                    // and lane_score saturates at every (slip, phase) —
                    // the calibrator can no longer distinguish a real
                    // eye from a transient hit. lane_locked[i] comes
                    // from a saturating consecutive-match counter inside
                    // tidelink_lane_checker_single which DOES reset on
                    // any miss within the cycle, giving correct per-
                    // dwell semantics.
                    for (int i = 0; i < 8; i++) begin
                        if (lane_locked[i]) begin
                            if (lane_score[i] != LANE_SCORE_MAX)
                                lane_score[i] <= lane_score[i] + 6'd1;
                        end else begin
                            lane_score[i] <= 6'd0;
                        end
                    end

                    if (dwell_expire) begin
                        // f900e07 active-mode probe latch: for every lane
                        // that reached lock_thresh_6b at (0,0), commit
                        // slip[i]=0, phase[i]=0, lane_done[i]=1, and seed
                        // best_run so the §9.11 eye-centre policy in
                        // S_FINALIZE leaves the probe verdict intact for
                        // those lanes (its !lane_done gate below skips
                        // them). Lanes that did NOT lock at (0,0) keep
                        // lane_done=0 and fall through to S_SWEEP.
                        //
                        // probe_lane_pass_q[] is ALSO latched (legacy
                        // §9.11 advisory verdict) so any S_FINALIZE
                        // fallback for OTHER lanes can still consult it.
                        for (int i = 0; i < 8; i++) begin
                            probe_lane_pass_q[i] <= (lane_score[i] >= lock_thresh_6b);
                            if (lane_score[i] >= lock_thresh_6b) begin
                                slip[i]       <= 3'd0;
                                phase[i]      <= 4'd0;
                                lane_done[i]  <= 1'b1;
                                // Seed best_run = lock_thresh so the
                                // eye-vis "best_score" mirror reports a
                                // pass, and the §9.11 S_FINALIZE
                                // best_run >= min_lock_dwells_eff
                                // comparison would NOT prefer some
                                // narrower late-sweep find for this
                                // lane (it is gated off by !lane_done[i]
                                // anyway, but the mirror still reads
                                // best_run* via eye_score).
                                best_run[i]              <= lock_thresh_6b[EYE_WIDTH_W-1:0];
                                best_run_start_phase[i]  <= 4'd0;
                                best_run_slip[i]         <= 3'd0;
                            end
                            // Fresh dwell window starts in S_SWEEP (or in
                            // S_FINISH if probe_all_locked → that path
                            // skips the sweep entirely).
                            lane_score[i] <= 6'd0;
                        end
                        dwell_ctr <= '0;
                        // sweep_slip/sweep_phase remain at 0 — S_SWEEP will
                        // begin scoring at (slip=0, phase=0). Note: this
                        // means (0,0) is re-measured at the start of
                        // S_SWEEP, which is harmless — the run-length
                        // tracker just sees a fresh lane_score window.
                    end else begin
                        dwell_ctr <= dwell_ctr +
                                     {{($clog2(DWELL_CYCLES+1)-1){1'b0}}, 1'b1};
                    end
                end

                S_SWEEP: begin
                    // ----- Per-lane in-dwell score -------------------------
                    // Fix A2 (audit 2026-05-29, see
                    // docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md):
                    // REVERTED from Step 6 (8409d6b) lane_dist_pass_w
                    // gating back to the binary lane_locked[i]. See the
                    // matching S_PROBE comment for the dwell-boundary
                    // reset bug: lane_checker's dwell_min_dist_o is a
                    // since-training-start monotonic minimum (no per-
                    // dwell reset), so the dist-pass predicate was
                    // sticky-true and the calibrator could not measure
                    // real eye quality. lane_locked[i] is the right per-
                    // dwell signal — saturating consecutive-match counter
                    // that resets on miss.
                    //
                    // f900e07 lane-done freeze (restored from advisory
                    // §9.11): for lanes that already latched (0,0) in
                    // S_PROBE (lane_done[i]=1), keep lane_score frozen at
                    // 0 so the best-of-sweep comparator below never fires
                    // for them. The output mux drives (slip[i], phase[i])
                    // = (0,0) regardless of what sweep_slip / sweep_phase
                    // are pointing at, so any "stale" passing dwell for
                    // OTHER lanes cannot steal a finished lane's latch.
                    for (int i = 0; i < 8; i++) begin
                        if (lane_done[i]) begin
                            lane_score[i] <= 6'd0;
                        end else if (lane_locked[i]) begin
                            if (lane_score[i] != LANE_SCORE_MAX)
                                lane_score[i] <= lane_score[i] + 6'd1;
                        end else begin
                            lane_score[i] <= 6'd0;
                        end
                    end

                    // ----- EARLY_EXIT compat path --------------------------
                    // Capture (slip,phase) on the first dwell where a
                    // not-done lane sees lane_locked rise. Sweep terminates
                    // early when every lane is done. Bypasses S_FINALIZE.
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
                        // ----- §9.11 run-length update -------------------
                        // For each lane: classify this dwell as pass/fail
                        // against LOCK_THRESH. If pass: extend the current
                        // phase-axis run; if the extended run exceeds the
                        // running best AND meets min_lock_dwells_eff,
                        // promote it. If fail: close the run.
                        //
                        // f900e07 §7.3 lane-done gate (active-mode
                        // S_PROBE restored): skip any_pass / run_len /
                        // best_run / cur_run_* updates for lanes already
                        // latched at (0,0) by S_PROBE — their best_run
                        // was seeded to lock_thresh_6b in the S_PROBE
                        // dwell-expire branch, and their lane_done[i]=1
                        // gates the output mux to (0,0). Keeping these
                        // arrays frozen for those lanes also means
                        // S_FINALIZE's best_run >= min_lock_dwells_eff
                        // branch reads the seeded (0,0,lock_thresh_6b)
                        // and re-assigns the same (0,0) — bit-identical
                        // outcome.
                        for (int i = 0; i < 8; i++) begin
                            if (!lane_done[i]) begin
                                // Combinational "this dwell passes" predicate.
                                // Using the JUST-incremented lane_score value is
                                // fine because lane_score has been counting for
                                // the full DWELL_CYCLES and now equals its
                                // in-dwell final value (saturated at 6'h3F).
                                if (lane_score[i] >= lock_thresh_6b) begin
                                    // §9.11b safety net: record the FIRST passing
                                    // (slip, phase) per lane. Used by S_FINALIZE
                                    // as the last-resort fallback when no
                                    // MIN_LOCK_DWELLS-wide run exists AND the
                                    // (0,0) probe verdict also failed.
                                    if (!any_pass_valid[i]) begin
                                        any_pass_valid[i] <= 1'b1;
                                        any_pass_slip[i]  <= sweep_slip;
                                        any_pass_phase[i] <= sweep_phase;
                                    end
                                    // Pass — extend or open a run at this slip.
                                    // If we're at the FIRST passing phase of a
                                    // new run, remember its starting phase.
                                    if (run_len[i] == '0) begin
                                        cur_run_start_phase[i] <= sweep_phase;
                                    end
                                    // Increment run length (saturating at
                                    // 5'd16 — the phase axis maxes at 16 wide).
                                    if (run_len[i] != 5'd16) begin
                                        run_len[i] <= run_len[i] + 5'd1;
                                    end
                                    // Update best_run if the EXTENDED run is
                                    // wider than the prior best AND clears
                                    // min_lock_dwells_eff. The new run length
                                    // is (run_len[i] + 1); we compute that as
                                    // a 5-bit value here to compare safely.
                                    if ((run_len[i] + 5'd1) >= min_lock_dwells_eff &&
                                        (run_len[i] + 5'd1) >  best_run[i]) begin
                                        best_run[i]             <= run_len[i] + 5'd1;
                                        // If run_len was 0 we just opened the
                                        // run at sweep_phase; otherwise the
                                        // start phase is already in cur_run_*.
                                        best_run_start_phase[i] <=
                                            (run_len[i] == '0) ? sweep_phase
                                                               : cur_run_start_phase[i];
                                        best_run_slip[i]        <= sweep_slip;
                                    end
                                end else begin
                                    // Fail — close the run.
                                    run_len[i] <= '0;
                                end
                            end
                            // Fresh dwell window next cycle.
                            lane_score[i] <= 6'd0;
                        end

                        // Dwell expired — advance the SHARED iterator.
                        //
                        // Fix B (audit 2026-05-29, see
                        // docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md):
                        // REVERTED §9.11c (phase-OUTER / slip-INNER) back
                        // to §9.11 phase-INNER / slip-OUTER ordering. With
                        // Fix A2 restoring real per-dwell scoring, run_len
                        // again measures contiguous PHASE points (the
                        // actual sub-bit eye axis) instead of slip
                        // rotations. The §9.11c motivation (M/S sweep
                        // overlap) was a workaround for the broken sticky
                        // score path — once A2 lands, eye-centre selection
                        // can find the real eye on a single slip without
                        // needing both calibrators to cross-cycle slips.
                        //
                        // On iter_at_end the FSM transitions to S_FINALIZE
                        // next cycle and the per-lane assigns happen there.
                        dwell_ctr <= '0;
                        if (sweep_phase == 4'd15) begin
                            // End-of-phase-scan for this slip — runs of
                            // contiguous phases at this slip are closed.
                            // Reset run_len for the next slip's fresh
                            // inner-phase scan (best_run is preserved).
                            sweep_phase <= 4'd0;
                            for (int i = 0; i < 8; i++) begin
                                run_len[i] <= '0;
                            end
                            if (sweep_slip == 3'd7) begin
                                // iter_at_end. FSM next-state goes to
                                // S_FINALIZE; we hold sweep_slip at 7,
                                // sweep_phase at 0 (post-wrap). No per-
                                // lane assigns here — they happen in
                                // S_FINALIZE.
                            end else begin
                                sweep_slip <= sweep_slip + 3'd1;
                            end
                        end else begin
                            sweep_phase <= sweep_phase + 4'd1;
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

                // -----------------------------------------------------------
                // §9.11 S_FINALIZE — one-cycle per-lane eye-centre latch.
                //
                // Entered from S_SWEEP on sweep_exhausted. For every lane,
                // assign the final (slip, phase) tuple and mark lane_done:
                //   * best_run[i] >= min_lock_dwells_eff → eye centre
                //   * elsif probe_lane_pass_q[i]        → (slip=0, phase=0)
                //   * else                              → lane_fault
                //
                // Eye centre = best_run_start_phase[i] + (best_run[i]-1)/2,
                // computed combinationally. The floor-of-midpoint puts the
                // sample point at or just before the middle of the widest
                // contiguous phase run, giving maximum margin to either
                // edge.
                // -----------------------------------------------------------
                S_FINALIZE: begin
                    for (int i = 0; i < 8; i++) begin
                        // f900e07 §7.3 lane-done gate: lanes that were
                        // already latched at (0,0) by S_PROBE skip the
                        // S_FINALIZE per-lane assigns entirely — their
                        // slip[i]/phase[i] are at (0,0), lane_done[i]=1,
                        // and their best_run was seeded to lock_thresh_6b
                        // so the eye-vis mirror reports a pass.
                        if (lane_done[i]) begin
                            // Preserve S_PROBE latch — no work.
                        end else if (best_run[i] >= min_lock_dwells_eff) begin
                            // BEST: §9.11 eye centre. best_run is at least
                            // MIN_LOCK_DWELLS wide; latch the run centre.
                            // (best_run - 1) >> 1 is the floor of
                            // (run/2 - 1/2), i.e. the index of the centre
                            // point relative to the run start. best_run is
                            // 5b, the shifted result is at most 7 (best_run
                            // <=16, (15>>1)=7), so the 4-bit truncation is
                            // safe and the sum start+centre is at most 15.
                            automatic logic [3:0] centre_off;
                            centre_off = (best_run[i] - 5'd1) >> 1;
                            slip[i]      <= best_run_slip[i];
                            phase[i]     <= best_run_start_phase[i] + centre_off;
                            lane_done[i] <= 1'b1;
                        end else if (probe_lane_pass_q[i]) begin
                            // FALLBACK 1: S_PROBE @ (0,0) verdict.
                            // No MIN_LOCK_DWELLS-wide run, but (0,0) locked
                            // during the dedicated probe dwell. Accept (0,0)
                            // — the §9.10 semantics, kept for bit-exact
                            // cocotb PHYs where (0,0) is the trivial-correct
                            // alignment.
                            slip[i]  <= 3'd0;
                            phase[i] <= 4'd0;
                            lane_done[i] <= 1'b1;
                        end else if (any_pass_valid[i]) begin
                            // FALLBACK 2: §9.11b single-point safety net.
                            // No wide run, (0,0) didn't lock during probe,
                            // but at least ONE sweep dwell passed
                            // LOCK_THRESH. Accept the FIRST such (slip,
                            // phase) — gives §9.10-equivalent "any-passing-
                            // point" coverage for narrow-eye corners
                            // (per-lane skew, marginal-margin silicon, the
                            // cocotb skewed env). Deterministic across M/S
                            // because both calibrators walk the same sweep
                            // order and latch first-passing.
                            slip[i]      <= any_pass_slip[i];
                            phase[i]     <= any_pass_phase[i];
                            lane_done[i] <= 1'b1;
                        end else begin
                            // Lane could not lock anywhere on the grid —
                            // true fault. Mark and exit; T3 retry budget at
                            // S_FINISH decides whether to re-sweep.
                            lane_fault_q[i] <= 1'b1;
                            lane_done[i]    <= 1'b1;
                        end
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
    // §9.11: best_score/best_slip/best_phase were renamed to
    // best_run/best_run_slip/best_run_start_phase during the eye-centre
    // rewrite. best_run is EYE_WIDTH_W (5b); zero-extend to 6b for the APB
    // eye_score output. best_run_slip / best_run_start_phase widths match.
    assign eye_score_best        = {1'b0, best_run             [eye_lane_sel_q]};
    assign eye_score_best_slip   =        best_run_slip        [eye_lane_sel_q];
    assign eye_score_best_phase  =        best_run_start_phase [eye_lane_sel_q];
    assign eye_score_lane_passed = ({1'b0, best_run[eye_lane_sel_q]} >= lock_thresh_6b);

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
    //   - the lane's LATCHED (slip,phase) once lane_done[i]=1 — that is,
    //     after S_FINALIZE in §9.11 eye-centre mode, or after the first
    //     lock in §9.7 EARLY_EXIT compat mode;
    //   - the LIVE shared iterator (sweep_phase,sweep_slip) while the
    //     sweep is still walking.
    // In §9.11 eye-centre mode all not-faulted lanes flip to "done"
    // together in S_FINALIZE (one cycle after the final dwell-window
    // expires); their outputs latch to the run-centre (best_run_start_phase
    // + (best_run-1)/2 at best_run_slip), or to (0,0) if probe_lane_pass_q
    // was set and no MIN_LOCK_DWELLS-wide run existed. Lanes with neither
    // a wide-enough run nor probe pass set lane_fault and hold their last
    // iterator value (sweep_slip=7, sweep_phase=0 — the post-iter-wrap
    // resting state).
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
            training_mode    = (cur_state == S_ARM)
                            || (cur_state == S_PROBE)
                            || (cur_state == S_SWEEP)
                            || (cur_state == S_FINALIZE)
                            || (cur_state == S_HOLD);
                                                        // S_PROBE    = §9.10/11 (0,0) advisory probe
                                                        // S_FINALIZE = §9.11 single-cycle latch
                                                        // S_HOLD     = T3.2 peer-aware
            calibration_done = (cur_state == S_DONE);
        end
    end

    assign lane_fault = lane_fault_q;

endmodule
