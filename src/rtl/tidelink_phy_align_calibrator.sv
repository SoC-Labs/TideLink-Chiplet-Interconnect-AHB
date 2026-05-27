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
    parameter int MIN_LOCK_DWELLS = 4
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
        // §9.10/§9.11 S_PROBE — advisory (0,0) probe state.
        //
        // S_PROBE dwells DWELL_CYCLES at (sweep_slip=0, sweep_phase=0) — i.e.
        // the natural / un-shifted RX deserialiser configuration — and per-
        // lane records whether the lane_checker locks on this rotation in
        // `probe_lane_pass_q[lane]`. The full S_SWEEP ALWAYS runs after; the
        // probe verdict is consulted by S_FINALIZE ONLY as a fallback when
        // no MIN_LOCK_DWELLS-wide eye is found anywhere on the grid for that
        // lane. §9.10 (Agent F) gave the probe ABSOLUTE priority — that was
        // a sim-only win, no-op on HW (tdif-21). §9.11 demotes it to
        // advisory so the eye-centre selection wins whenever it has a
        // valid run, and the probe is the degraded-margin safety net.
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
        S_FINALIZE   = 4'd8
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
    // Effective MIN_LOCK_DWELLS — synth-time parameter for now. A runtime
    // APB override (e.g. Region 8 SWI_CAL_MIN_DWELLS[3:0]) can be wired in
    // a follow-on patch via a local_overrides axi_chiplet_controller; the
    // calibrator port is omitted for now to keep the bring-up RTL change
    // limited to this file. Default 4 = ~25% margin on the 16-phase axis.
    wire [EYE_WIDTH_W-1:0] min_lock_dwells_eff =
        MIN_LOCK_DWELLS[EYE_WIDTH_W-1:0];

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
                // §9.11: S_PROBE is now ADVISORY. Dwell at (0,0) for
                // DWELL_CYCLES; the datapath records probe_lane_pass_q[i]
                // for any lane that locked at (0,0). At dwell_expire,
                // ALWAYS proceed to S_SWEEP — the full sweep runs so the
                // eye-centre selection has a real measurement to work
                // with. The probe verdict is consulted only in S_FINALIZE
                // as a fallback when no MIN_LOCK_DWELLS-wide eye exists.
                if (swreset)                       nxt_state = S_CANCEL;
                else if (dwell_expire)             nxt_state = S_SWEEP;
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
                // §9.10/§9.11 S_PROBE — dwell DWELL_CYCLES at the natural
                // (slip=0, phase=0) point and RECORD per-lane whether the
                // lane_checker locks at (0,0) into probe_lane_pass_q[]. Do
                // NOT set lane_done; the full S_SWEEP always runs and the
                // probe verdict is consulted by S_FINALIZE only as a
                // fallback when no MIN_LOCK_DWELLS-wide eye exists.
                //
                // sweep_slip/sweep_phase are 0 (cleared in S_ARM), so the
                // output mux drives (0,0) on every lane during S_PROBE.
                // -----------------------------------------------------------
                S_PROBE: begin
                    // In-dwell lock counter (saturating).
                    for (int i = 0; i < 8; i++) begin
                        if (lane_locked[i]) begin
                            if (lane_score[i] != LANE_SCORE_MAX)
                                lane_score[i] <= lane_score[i] + 6'd1;
                        end else begin
                            lane_score[i] <= 6'd0;
                        end
                    end

                    if (dwell_expire) begin
                        // §9.11: probe is ADVISORY. Latch the per-lane
                        // pass/fail verdict at (0,0); subsequent S_SWEEP
                        // runs the full grid and S_FINALIZE picks the
                        // eye centre (preferring it over this verdict).
                        for (int i = 0; i < 8; i++) begin
                            probe_lane_pass_q[i] <= (lane_score[i] >= lock_thresh_6b);
                            // Fresh dwell window starts in S_SWEEP.
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
                    // ----- Per-lane in-dwell lock counter ------------------
                    // Count consecutive lane_locked=1 cycles within the
                    // current dwell window; reset to 0 on any de-assert,
                    // saturate at LANE_SCORE_MAX. Cleared on dwell-window
                    // expiry (see dwell_expire branch below). §9.11 removes
                    // the lane_done freeze that §9.10 used to lock (0,0)
                    // pre-emptively — every lane scores at every point so
                    // the run-length tracker can find the widest eye.
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
                        // We do NOT gate this on lane_done — §9.11 removed
                        // the S_PROBE freeze, so every lane scores at every
                        // point. (early_exit_en_w bypass uses lane_done to
                        // suppress in the same cycle as iter advance; the
                        // run-length tracker is harmless work in that mode.)
                        for (int i = 0; i < 8; i++) begin
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
                            // Fresh dwell window next cycle.
                            lane_score[i] <= 6'd0;
                        end

                        // Dwell expired — advance the SHARED iterator
                        // (§9.11: slip-OUTER, phase-INNER). On the FINAL
                        // point (iter_at_end), the FSM transitions to
                        // S_FINALIZE next cycle and the per-lane assigns
                        // happen there.
                        dwell_ctr <= '0;
                        if (sweep_phase == 4'd15) begin
                            // End-of-phase-scan for this slip — runs at
                            // this slip are closed. Reset run_len for the
                            // next slip's fresh scan (best_run is preserved).
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
                        if (best_run[i] >= min_lock_dwells_eff) begin
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
