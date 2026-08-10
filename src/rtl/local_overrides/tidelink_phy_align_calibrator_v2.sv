// =============================================================================
// tidelink_phy_align_calibrator — SoC Labs LOCAL OVERRIDE of
// deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv (submodule copy stays
// pristine — the WavD2DGpio_v2 / tidelink_lane_deskew_v2 override idiom).
// Wired in by flists/tidelink_fpga_v2.flist and
// flists/tidelink_top_full_asic_v2.flist in place of the deps file.
// ONE functional deviation from the submodule:
//
//   P1 FORCED-RECAL W1P (2026-07-19, lane B1) — new input `force_recal_i`, a
//   dedicated software-reachable door that re-arms the calibrator ONCE on an
//   already-converged link. Driven from the acc's new Region-8 slot-0 bit[6]
//   SWI_FORCE_RECAL (axi_chiplet_controller.sv), POR default 0.
//
//   WHY: `calibrated_once_q` (below, ~line 700) latches on the first S_DONE and
//   permanently gates off BOTH calibrator re-trigger edges — so SWI_RECAL is a
//   measured NO-OP after first lock and there was NO firmware-reachable PHY
//   retrain at all, in the FPGA image AND the ASIC path. Evidence:
//   docs/LINK_RECOVERY_MECHANISM.md §4 — on a healthy link the calibrator FSM
//   was sampled 60x on both dies across the window where S_DONE -> S_ARM would
//   appear and it NEVER left S_DONE. §6.1 P1 proposes exactly this remedy, as
//   does the submodule's own comment ("a dedicated W1P").
//
//   WHAT IS PRESERVED: `calibrated_once_q` is NOT modified, NOT cleared, and
//   NOT qualified. It exists to reject the Bug-A (2026-06-28) IMPLICIT
//   re-trigger — the autoneg winner's ST_TRAIN_EXIT SWI_RECAL pulse landing
//   while the calibrator is already in S_DONE, which re-asserted training_mode
//   and squelched the master's CR/CRACK framing mid-FCSM-credit-init, wedging
//   the master at FCSM state 2 with zero TX credit (proof-of-fix: test_36).
//   Both gated edges (role_locked_rise_eff / swreset_fall_eff) keep their
//   `& ~calibrated_once_q` term VERBATIM. This change adds a NEW, EXPLICIT
//   door rather than widening the existing one: only a deliberate SW write to
//   SWI_FORCE_RECAL can pass, and nothing in the autoneg FSM drives that bit.
//   Steady-state behaviour is unchanged — the sticky stays set across a forced
//   recal, so the implicit edges remain gated before, during and after it.
//
//   DEFAULT-OFF: with SWI_FORCE_RECAL never written, force_recal_i is a
//   constant 0, force_recal_rise never fires, and trigger_now is bit-identical
//   to the submodule.
//
//   NOTE for other integrators: force_recal_i has NO SV default port value and
//   MUST be connected — tie 1'b0 for pre-P1 behaviour. Default port values
//   (IEEE 1800 §23.2.2.4) have ZERO precedent in this tree and Vivado's SV
//   synthesis subset is not reliably known to accept them, and fpga/filelist.tcl
//   feeds this file to Vivado OOC synthesis; VCS accepting it in sim proves
//   nothing about the FPGA/ASIC path. deps/tidelink-phy/rtl/tidelink_phy_bist_core.sv
//   instantiates the PRISTINE submodule copy via flists/tidelink_phy_v2.flist,
//   never this override, so it is unaffected.
//
//   ROT RISK (stated plainly): this is a fork of a 2367-line submodule file.
//   Future deps/tidelink-phy calibrator fixes will NOT reach the V2 build until
//   they are re-merged here. Re-diff against the submodule before any PHY uplift.
// =============================================================================
// wlink_phy_align_calibrator.sv — Autonomous per-lane bit-slip calibration FSM
// =============================================================================
//
// This module is the §9.6 "auto-staging FSM" described in BRINGUP_REPORT.md
// and now folded into docs/reference/TIDELINK_SPECIFICATION.md §9.10 (PHY-Align:
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
    // -------------------------------------------------------------------
    // EYE-CENTRE port (2026-06-17): §9.11 eye-centre selection policy
    // minimum contiguous-passing-phase run length for a (slip,phase) point
    // to be accepted as the lane's latched eye CENTRE in S_FINALIZE.
    // Ported from src/rtl/tidelink_phy_align_calibrator.sv (the unit-tested
    // reference) into the DEPLOYED deps/ calibrator: the deployed S_FINALIZE
    // previously selected the eye EDGE (first any_pass point), so the
    // marginal-RX die ("die_a") sampled real data off-centre → ~5% link-up
    // lottery. The eye-centre arm below moves the latched phase to the CENTRE
    // of the widest contiguous matched run.
    //
    // Default 2 (matches src/) = die_a marginal eye has only 2-3 consecutive
    // passing phases. Runtime-tunable via min_lock_dwells_i. RAISING it very
    // high (>16) makes the eye-centre arm a no-op (no run can ever satisfy
    // best_run >= min_lock_dwells_eff), so the FSM falls through to the
    // IDENTICAL pre-fix fallback stack — the bitstream can be made
    // bit-identical to today via that lever (GUARD requirement).
    parameter int MIN_LOCK_DWELLS = 2,
    // IMPLEMENTATION.md §3.5 Task G — when 1, the S_VALIDATE
    // confirm may ALSO be satisfied by a correctly-aligned SYNC beacon
    // (sync_seen_i), not only real PRBS data (cr_pkt_seen_i). DEFAULT 0 =
    // behaviour IDENTICAL to today (sync_seen_i is not consulted).
    parameter bit USE_SYNC_VALIDATE = 1'b0,
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
    // FIX D (2026-08-07, TL-009): 1 = PEER-AWARE S_HOLD release (hold training past
    // HOLD_MAX until all active lanes synced, backstop-bounded — widens the
    // bilateral overlap on a ms-skew bring-up so W+B cross). 0 (default) = original
    // blind HOLD_MAX timer, BIT-IDENTICAL. Enabled on the eth-chiplet HW path only.
    parameter bit HOLD_PEER_AWARE_EN = 1'b0,
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
    // M8 (tidelink port, 2026-06-09) — S_VALIDATE val-timeout terminal policy.
    // See memory project_tidelink_m6_m8_calibrator_validate_fix_2026_06_08.
    //
    // ROOT CAUSE (shared with tidelink M6/M8): a die that has trained but
    // cannot validate keeps cycling S_VALIDATE -> S_ARM (re-sweep). Each such
    // cycle re-drops/re-acquires this die's carrier and, with MAX_RESWEEPS==0
    // (the bring-up/HW default — retry_exhausted is hardwired 0), re-sweeps
    // FOREVER. The peer's lane_checker, which locks against THIS die's training
    // carrier, is starved during the repeated S_VALIDATE windows. This is the
    // bilateral S_VALIDATE-rendezvous carrier-starvation the bring-up audit
    // flagged.
    //
    // PORT NOTE — why NOT tidelink M8 change #1 (assert training_mode in
    // S_VALIDATE): in tidelink the validation oracle is the FCSM CR_PKT
    // handshake that fires AFTER S_VALIDATE, so training_mode may stay high
    // during S_VALIDATE harmlessly. In THIS repo the oracle is
    // cr_pkt_seen_i = prbs_all_synced_w, which requires live PRBS on the wire
    // DURING S_VALIDATE; the TX training mux (tidelink_gpio_phy_tx.sv) replaces
    // PRBS with the training pattern whenever training_mode=1. Asserting
    // training_mode in S_VALIDATE would stop THIS die's PRBS -> the PEER could
    // never sync -> peer never validates (regressing
    // test_prbs_validation_consulted / test_link_up_both_dirs). So change #1 is
    // NOT ported; only the timeout-terminal cure (change #2) is.
    //
    // When 1: on a S_VALIDATE val_ctr timeout WITHOUT validate_confirm, the FSM
    // latches to S_DONE (terminal, training stops thrashing) INSTEAD of S_ARM
    // re-sweep — but ONLY once the FIX-C re-sweep budget is spent
    // (retry_exhausted) OR re-sweep is disabled (MAX_RESWEEPS==0). This NEVER
    // short-circuits the FIX-C cand_idx escape search: when MAX_RESWEEPS!=0 and
    // budget remains, the timeout STILL goes to S_ARM and advances cand_idx
    // (FIX-C false-positive escape preserved). It only converts the
    // MAX_RESWEEPS==0 infinite-thrash case into a clean terminal. A timeout
    // give-up to S_DONE still sets validation_timed_out (give_up_to_done) so
    // cal_done is distinguishable from a real validation, and link_up stays 0
    // (link_up = cal_done & prbs_all_synced_w) — a false positive can NOT bring
    // the link up. DEFAULT 0 = behaviour IDENTICAL to today (golden suite
    // unchanged: with MAX_RESWEEPS!=0 the timeout arm is unchanged; with
    // MAX_RESWEEPS==0 it still re-sweeps as before).
    parameter bit VAL_TIMEOUT_TO_DONE = 1'b0,
    // FIX-H (2026-06-09): enable per-lane PRBS-sync PINNING so multi-lane
    // searches with per-lane-distinct PRBS-valid phases converge. Default 0 =
    // bit-identical to pre-fix (lane_synced_i ignored).
    parameter bit LANE_PIN_CONVERGE = 1'b0,
    // FIX-J (2026-06-09) — IN-S_VALIDATE PRBS phase EYESCAN.
    //
    // ROOT CAUSE FIX-H FAILED ON SILICON: FIX-H can only PIN a lane whose phase
    // was ALREADY parked on its PRBS-valid value BEFORE S_VALIDATE was entered.
    // The phase, however, is committed in S_FINALIZE while training_mode is HIGH
    // (S_ARM/S_PROBE/S_SWEEP/S_FINALIZE/S_HOLD) — PRBS is NOT on the wire during
    // any of those states (the TX training mux replaces PRBS with the training
    // pattern whenever training_mode=1, tidelink_gpio_phy_tx.sv:68). So the
    // calibrator can NEVER observe which phase is PRBS-valid while it is choosing
    // it; it only finds out (yes/no, for the ONE frozen guess) in the short
    // S_VALIDATE window. FIX-H therefore relies on blind cursor enumeration:
    // park a guessed phase, drop training, validate, re-arm on miss. On real
    // silicon the PRBS checker needs several clean words to sync AND the PEER
    // must be validating in the SAME window; with per-lane-distinct phases that
    // bilateral rendezvous never lands all lanes, so both dies cycle
    // S_HOLD<->S_VALIDATE with lane_synced=0 forever (the observed HW symptom).
    //
    // FIX-J: while in S_VALIDATE (training_mode LOW => PRBS ON THE WIRE, both
    // peers validating), WALK each still-unpinned lane's DRIVEN phase across the
    // 16 positions, dwelling EYESCAN_DWELL cycles per phase (>= the checker's
    // seed+sync latency), and PIN each lane the instant lane_synced_i[i] asserts.
    // This scores phases on PRBS validity WITH PRBS ON THE WIRE — the eye scan
    // the training-mode S_SWEEP can never do — and NEVER leaves S_VALIDATE
    // between phase trials, so it never drops the bilateral PRBS rendezvous
    // carrier. All lanes scan in parallel within ONE continuous S_VALIDATE
    // window; per-lane-distinct phases are all covered in 16*EYESCAN_DWELL
    // cycles. When every enabled lane is pinned, validate_confirm (= all-synced)
    // holds and S_VALIDATE -> S_DONE. Requires pin_converge_en (so lane_synced_i
    // is meaningful) AND PRBS_EYESCAN. Default 0 = behaviour bit-identical to
    // pre-FIX-J (S_VALIDATE holds the frozen phase exactly as before).
    parameter bit PRBS_EYESCAN = 1'b0,
    // FIX-J per-phase dwell (cycles) for the in-S_VALIDATE eyescan. Must exceed
    // the PRBS checker's seed+sync latency (1 seed word + SYNC_WORDS clean words
    // ~ 5 words) so a correct phase actually confirms within its dwell. Default
    // 64 (4 words at 16 link cycles/word, generous margin). VALIDATION_TIMEOUT
    // should be >= ~18*EYESCAN_DWELL so a full 16-phase scan plus settle fits.
    parameter int EYESCAN_DWELL = 64
)(
    input  logic        clk,
    input  logic        rst,                       // active-high

    // Bring-up sequencing
    input  logic        role_locked,
    input  logic        swreset,
    input  logic [7:0]  lane_locked,
    // ---------------------------------------------------------------------
    // LANE-MASK awareness (2026-06-11). Quasi-static per-lane active mask,
    // bit i = 1 → lane i is in use, bit i = 0 → lane i is MASKED (intentionally
    // not driven / dead ribbon conductor). Wired from bist_core's lane_mask_w
    // (a slow APB strap, reset 0xFF), same recovered-RX-link-clock domain as
    // this calibrator — no CDC. A masked lane is EXCLUDED from convergence,
    // NOT faulted: it is parked at (slip=0,phase=0), marked lane_done in S_ARM
    // so it never trains/sweeps/finalises, excluded from sweep_success, the
    // probe/early-exit all-lanes checks and the S_VALIDATE pin/eyescan.
    //
    // CRITICAL default-preservation: every mask-aware term below is gated so
    // that with lane_mask=8'hFF (all active — the v1 default and every existing
    // TB) it reduces EXACTLY to the pre-mask expression (| ~lane_mask == | 0,
    // & lane_mask == & 1, masked-lane branches dead). So 0xFF is bit-identical
    // to the pre-fix behaviour. Mirrors how bist_core's prbs_all_synced_w
    // already masks (| ~lane_mask). Integrators that don't drive this should
    // tie it to 8'hFF (all lanes active).
    input  logic [7:0]  lane_mask,

    // SW debug override (optional)
    input  logic [23:0] apb_bit_slip_override,
    input  logic        apb_override_enable,

    // EYE-CENTRE (2026-06-17): APB runtime MIN_LOCK_DWELLS override (mirrors
    // src/). Reading 4'd0 forces the synth-time MIN_LOCK_DWELLS parameter
    // default; 1..15 overrides at runtime. Slow APB-domain strap sampled in
    // the calibrator clock domain (rx_link_clk) — quasi-static, no CDC needed.
    // GUARD lever: a small value tightens centring; a large value disables the
    // eye-centre arm entirely (falls through to the legacy fallback stack), so
    // the bitstream can be made bit-identical to pre-fix from SW. Integrators
    // that don't drive this tie it to 4'd0 (= use the param default).
    input  logic [3:0]  min_lock_dwells_i,

    // FIX E (2026-06-08): SW-hold gate for bilateral coordinated release.
    // When asserted (1), the S_HOLD → S_VALIDATE transition is suppressed
    // regardless of hold_ctr. Both peer boards can be held in S_HOLD
    // indefinitely until SW simultaneously clears this on both, causing
    // them to advance to S_VALIDATE together (bilateral PRBS sync window).
    // Registered one cycle before use to break any long combinatorial path.
    // When 0 (default), S_HOLD advances to S_VALIDATE normally after
    // HOLD_CYCLES. No effect on any other state. Driven from CTRL[6]
    // (swi_training_mode APB register bit). Async default = 0 (no hold).
    input  logic        swi_training_hold_i,

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

    // IMPLEMENTATION.md §3.5 Task G — PHY SYNC-beacon "seen"
    // pulse (post-deskew aligned bus, same recovered RX link clock as this
    // calibrator → no CDC). Only consulted when USE_SYNC_VALIDATE=1; OR-merged
    // into the S_VALIDATE confirm so a correctly-aligned beacon can confirm
    // alignment without upstream real-data traffic. With USE_SYNC_VALIDATE=0
    // this input is ignored and behaviour is identical to today.
    input  logic        sync_seen_i,

    // FIX-H (2026-06-09, multi-lane convergence): per-lane PRBS-sync feedback.
    // Same recovered-RX-link-clock domain as the calibrator (driven from the
    // BIST core's lane_synced_w / the chiplet-controller's per-lane sync). When
    // LANE_PIN_CONVERGE=1, a lane that is observed PRBS-synced during S_VALIDATE
    // is PINNED: its latched (slip,phase) is frozen and its candidate cursor is
    // NOT advanced on subsequent aggregate validation failures. This decouples
    // the per-lane cursor search so lanes whose PRBS-valid phase differs (the
    // die_a cross-lane skew case) each converge independently instead of
    // marching the cursors in lockstep and skipping past their good points.
    // With LANE_PIN_CONVERGE=0 (default) this input is ignored and behaviour is
    // bit-identical to today.
    input  logic [7:0]  lane_synced_i,

    // FIX-H APB RUNTIME enable for pin-converge (CTRL[7] lane_pin_converge_en,
    // CDC'd into this rx_link_clk domain by the BIST core — see
    // pin_converge_en_sync there, mirroring score_decay_i's synchroniser).
    // The effective enable is (LANE_PIN_CONVERGE | lane_pin_converge_en_i): the
    // compile param keeps a default-OFF synth knob, while this SW bit lets ONE
    // build A/B pin-converge OFF vs ON on hardware. Async/reset default 0 =>
    // pin_converge_en=0 => behaviour bit-identical to pre-FIX-H. Quasi-static
    // (written once at bring-up), so a plain 2-flop bit-sync upstream suffices.
    input  logic        lane_pin_converge_en_i,

    // ---------------------------------------------------------------------
    // P1 FORCED-RECAL W1P (2026-07-19) — see the override banner at the top of
    // this file. Level input in THIS clock domain's terms: a 0->1 transition
    // (after 2-FF sync) re-arms the sweep exactly once, BYPASSING
    // calibrated_once_q while leaving that sticky itself untouched. Driven by
    // the acc's SWI_FORCE_RECAL (R8 slot0 bit[6]) pulse-stretcher, which
    // guarantees the assertion is wide enough to be sampled in this (much
    // slower) rx_link_clk domain.
    //
    // NO SV DEFAULT PORT VALUE, deliberately — see the override banner at the
    // top of this file. EVERY instantiator MUST connect this port; tie 1'b0 for
    // pre-P1 behaviour.
    // ---------------------------------------------------------------------
    input  logic        force_recal_i,

    // Outputs to PHY
    output logic [23:0] bit_slip,
    // Per-lane 4-bit phase offset, 8 lanes × 4 bits (lane N at bits
    // [4*N+3 : 4*N]). Drives WavD2DGpio.swi_phase_offset via the per-lane
    // distribution added in §9.7.
    output logic [31:0] phase_offset,
    output logic        training_mode,
    output logic        calibration_done,
    // MUST-FIX #2(b) (TB-6 hardening): sticky "gave up" flag. Distinguishes
    // "done because the latched (slip,phase) VALIDATED on real data" from
    // "done because the PRBS-validated re-sweep search EXHAUSTED its retry
    // budget (MAX_RESWEEPS) without ever validating". Latches 1 when the FSM
    // reaches S_DONE via a retry_exhausted path (the S_VALIDATE val_ctr-timeout
    // give-up, or the S_FINISH lane-fault give-up once the budget is spent).
    // Cleared on a fresh external trigger (trigger_now) or an swreset cancel
    // (S_CANCEL). cal_done semantics (= state==S_DONE) are UNCHANGED — this is
    // a PURELY ADDITIONAL observability bit. link_up (which ANDs PRBS sync)
    // remains the safe "really up" signal; this flag explicitly surfaces the
    // give-up case for SW.
    output logic        validation_timed_out,
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
    // EYE-WIDTH VISIBILITY (2026-06-17, purely additive diagnostic).
    //
    // Mirrors src/ ~1583-1586: a per-lane-selected read of the eye-centre
    // run tracker, so SW can read the matched-window WIDTH (in IDELAY/phase
    // taps) of any lane after a sweep — the decisive per-lane eye-quality
    // metric for diagnosing the marginal-RX die remotely. eye_lane_sel picks
    // the lane; eye_score_best = best_run of that lane (zero-extended to 6b),
    // eye_score_best_phase / _slip = the run's start phase / slip. These are
    // COMBINATIONAL reads of FSM registers in the calibrator clock domain —
    // zero datapath perturbation. Integrators reading nothing tie eye_lane_sel
    // to 0; the outputs are otherwise inert.
    // ---------------------------------------------------------------------
    input  logic [2:0]  eye_lane_sel,
    output logic [5:0]  eye_score_best,        // best_run (eye width) of sel lane
    output logic [3:0]  eye_score_best_phase,  // run start phase of sel lane
    output logic [2:0]  eye_score_best_slip,   // slip the run was at
    output logic        eye_score_lane_passed, // best_run >= LOCK_THRESH

    // ---------------------------------------------------------------------
    // L4 training-exit-deadlock fix (2026-07-01, purely additive decode).
    //
    // Asserted (1) while the calibrator is parked in S_HOLD (state 4'd6) —
    // i.e. locally converged, latched (slip,phase), holding training_mode
    // high waiting for the bilateral release. This is the LOCALLY-REACHABLE
    // rendezvous point for the autonomous training-exit: the autoneg FSM on
    // BOTH dies rendezvous on "both in S_HOLD" (readable over the peer's
    // SWI_LANE_STATUS I2C read), then does the bilateral swi_training_mode
    // clear which opens the S_HOLD → S_VALIDATE gate (line ~1339, gated on
    // !swi_training_mode_r). Pure combinational decode of cur_state — zero
    // datapath change; the S_HOLD gate itself is UNCHANGED.
    // ---------------------------------------------------------------------
    output wire         cal_in_hold_o
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
    // CDC: role_locked and swreset originate in the APB/controller domain and
    // are sampled here on clk (link_clk_rx). Synchronise each with a 2-flop
    // chain BEFORE any edge-detect or level use, plus a 3rd flop for a clean
    // one-cycle-delayed copy for edge detection. Every consumer below uses the
    // SYNCHRONISED value (role_locked_sync / swreset_sync), never the raw async
    // input — so a metastable sample cannot split the FSM (a glitchy edge could
    // mis-launch the sweep, or one S_CANCEL branch fire while another still saw
    // the old level).
    // -------------------------------------------------------------------------
    logic role_locked_s1, role_locked_s2, role_locked_s3;
    logic swreset_s1,     swreset_s2,     swreset_s3;
    // P1: force_recal_i gets the IDENTICAL 3-FF treatment (2 sync + 1 delayed
    // copy for edge detection) as the two pre-existing async trigger inputs.
    logic force_recal_s1, force_recal_s2, force_recal_s3;
    logic trigger_now;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            role_locked_s1 <= 1'b0; role_locked_s2 <= 1'b0; role_locked_s3 <= 1'b0;
            swreset_s1     <= 1'b0; swreset_s2     <= 1'b0; swreset_s3     <= 1'b0;
            force_recal_s1 <= 1'b0; force_recal_s2 <= 1'b0; force_recal_s3 <= 1'b0;
        end else begin
            role_locked_s1 <= role_locked;    role_locked_s2 <= role_locked_s1; role_locked_s3 <= role_locked_s2;
            swreset_s1     <= swreset;        swreset_s2     <= swreset_s1;     swreset_s3     <= swreset_s2;
            force_recal_s1 <= force_recal_i;  force_recal_s2 <= force_recal_s1; force_recal_s3 <= force_recal_s2;
        end
    end

    // Synchronised levels — every consumer below uses these, not the raw inputs.
    wire role_locked_sync = role_locked_s2;
    wire swreset_sync     = swreset_s2;

    // Rising edge of role_locked, or falling edge of swreset while role_locked
    // is asserted — computed from the synchronised values so the trigger cannot
    // glitch on a metastable sample.
    wire role_locked_rise = role_locked_s2 & ~role_locked_s3;
    wire swreset_fall     = ~swreset_s2    &  swreset_s3;

    // -------------------------------------------------------------------------
    // SoC Labs Bug-A / autonomous master-RX root cause + fix (2026-06-28):
    //   ROOT CAUSE — In the AUTONOMOUS I2C bring-up the WINNER (master) runs an
    //   extended training sub-flow in tidelink_autoneg (ST_TRAIN_ENTER/RUN/
    //   POLL_PEER/EXIT). At training-EXIT (autoneg state 15->16, ~656us in sim)
    //   the master's SWI_RECAL bit (= this calibrator's `swreset` input) PULSES
    //   0->1->0 while this calibrator is already in S_DONE. The FALLING edge of
    //   that recal pulse fires `trigger_now` (swreset_fall & role_locked_sync),
    //   kicking S_DONE -> S_ARM -> ... -> S_SWEEP, which re-asserts
    //   training_mode and SQUELCHES the master's Wlink CR/CRACK framing exactly
    //   while the FCSM credit-init handshake needs to complete: the master
    //   decoded the slave's long CR stream during the brief DONE window
    //   (cr_pkt_seen_rx=1, FCSM 1->2) but re-enters training before it can
    //   decode the slave's short CRACK burst, so crack_pkt_seen_rx STAYS 0 and
    //   the master FCSM wedges at state=2 with ZERO TX credit (M.state=2 cr=1
    //   crack=0 vs S.state=4). The LOSER (slave) exits autoneg early
    //   (NEGO_DONE), never issues the training-exit recal pulse, holds S_DONE,
    //   and completes CR/CRACK -> state=4.
    //
    //   FIX (calibrator-local, minimal, safe) — make calibration STICKY once
    //   genuinely complete: latch `calibrated_once_q` on first reaching S_DONE
    //   and from then on IGNORE the swreset/SWI_RECAL falling-edge re-trigger
    //   AND a role_locked re-pulse. A real cold boot still re-calibrates via
    //   `rst` (POR), which clears the sticky. NOTE: this masks the level/edge
    //   recal re-trigger only after a good lock; an explicit forced recal of an
    //   already-locked link must come via POR or a dedicated W1P.
    //   Proof-of-fix: cocotb test_36 reaches master crack=1 + M->S doorbell
    //   crosses. (This is the V2-PHY twin of the same fix in
    //   src/rtl/tidelink_phy_align_calibrator.sv — the V2 flist compiles THIS
    //   deps/tidelink-phy copy, so the bitstream-affecting change lives here.)
    // -------------------------------------------------------------------------
    reg calibrated_once_q;
    // FIX 1 (2026-08-06, TL-001 terminal-latch): latch the sticky ONLY on a
    // GENUINE success, not on a GIVE-UP S_DONE. Before this, calibrated_once_q
    // latched on ANY first reach of S_DONE — including a give-up (val-timeout /
    // retry-exhausted / escan-exhausted / role_locked dip). A give-up die then
    // permanently blocked its own re-arm (role_locked_rise_eff/swreset_fall_eff
    // gated by ~calibrated_once_q), stopped driving its training pattern, and the
    // PEER swept a silent lane forever -> best_run=0 both dies -> (0,0) framing
    // lottery -> cross-die WRITE data-drop. `validation_timed_out` is the existing
    // give-up discriminator (set 1 on the give_up_to_done transition, so already 1
    // on the first give-up S_DONE cycle; stays 0 on a real validate-confirm
    // S_DONE per the MUST-FIX #2b comment). Gating on it keeps the Bug-A sticky
    // behaviour for a genuine lock VERBATIM while letting a give-up keep re-arming
    // until the peer's training window overlaps (HW-confirmed by the bilateral
    // swi_training_mode FIX-3 pulse: forcing the pattern back converts drop->land).
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                                            calibrated_once_q <= 1'b0;
        else if (cur_state == S_DONE && !validation_timed_out) calibrated_once_q <= 1'b1;
    end
    // Once a good lock exists, suppress BOTH re-trigger edges (the spurious
    // training-exit SWI_RECAL pulse and any role_locked re-pulse). Cold boot
    // re-cals via POR (rst) which clears calibrated_once_q.
    wire role_locked_rise_eff = role_locked_rise & ~calibrated_once_q;
    wire swreset_fall_eff     = swreset_fall     & ~calibrated_once_q;

    // -------------------------------------------------------------------------
    // P1 FORCED-RECAL (2026-07-19, lane B1) — the EXPLICIT door.
    //
    // The two _eff terms above keep their `& ~calibrated_once_q` gating VERBATIM:
    // the Bug-A implicit re-triggers (the autoneg winner's ST_TRAIN_EXIT
    // SWI_RECAL pulse, and any role_locked re-pulse) stay rejected on a
    // converged eye, exactly as before.
    //
    // force_recal_rise is deliberately NOT gated by calibrated_once_q — that IS
    // the fix: it is the only path by which firmware can re-arm an
    // already-calibrated link short of a POR. It is safe to leave ungated
    // because, unlike `swreset`, NOTHING in the autoneg FSM or any other RTL
    // drives SWI_FORCE_RECAL — it is set only by a deliberate APB write, so it
    // cannot fire spuriously mid-handshake the way Bug-A's pulse did.
    //
    // Qualified by role_locked_sync for the same reason the swreset path is:
    // never launch a sweep on a link whose role has not been locked.
    //
    // NOT qualified by FCSM state — considered and REJECTED (2026-07-19).
    // The hazard is real: firmware that fires this mid-credit-init re-asserts
    // training_mode and squelches CR/CRACK, reproducing Bug-A's wedge by hand.
    // Two gates were proposed and both are worse than the hazard:
    //
    //  (a) "only in data mode" (fcsm[2], i.e. state 4/5). The forced door is
    //      ONLY ever needed once calibrated_once_q is set — i.e. AFTER first
    //      S_DONE. Before that the ordinary role_locked/swreset triggers still
    //      work, so the door is not needed during bring-up at all. But a link
    //      that reached S_DONE and then wedged at FCSM=2 (the Bug-A signature)
    //      would have the lever disabled at exactly the moment it is wanted.
    //  (b) "block only the credit-init states" — identical outcome: FCSM=2 IS
    //      the wedge state. Hardware cannot tell "transiting credit-init"
    //      (dangerous to interrupt) from "WEDGED in credit-init" (precisely when
    //      you want to retrain); the difference is TIME, not state, and
    //      resolving it needs a timeout = speculative new logic pre-tapeout.
    //
    // DECIDING ARGUMENT: the defect this whole change closes is "a firmware
    // control that SILENTLY DOES NOTHING" (SWI_RECAL after first lock). Adding a
    // state-dependent silent gate to its replacement would re-introduce exactly
    // that failure class — firmware writes the W1P, nothing happens, and with
    // bit[6] write-only there is no way to tell a gated write from an ignored
    // one. The control's contract is kept simple and honest instead: a write
    // ALWAYS attempts a retrain.
    //
    // Residual risk, stated plainly: firmware CAN wedge a link by firing this
    // during credit-init. That window is transient (µs) in healthy operation and
    // is firmware's to avoid — unlike Bug-A, which was automatic and
    // unavoidable. Firmware constraint: do not write SWI_FORCE_RECAL until the
    // FCSM has left credit-init, or as a deliberate recovery action after a
    // liveness check has already failed. Recovery from a self-inflicted wedge is
    // a POR, exactly as it is today.
    //
    // calibrated_once_q is NOT cleared here — it stays set through and after the
    // forced sweep, so steady-state gating of the implicit edges is identical
    // before, during and after a forced recal. This is a one-arming bypass, not
    // a mode change.
    // -------------------------------------------------------------------------
    wire force_recal_rise = force_recal_s2 & ~force_recal_s3;

    assign trigger_now = role_locked_rise_eff
                       | (swreset_fall_eff  & role_locked_sync)
                       | (force_recal_rise  & role_locked_sync);

    // FIX E: single-cycle register for the slow APB swi_training_hold_i input.
    // Breaks any long combinatorial fan-out path from the CTRL register.
    logic swi_training_mode_r;
    always_ff @(posedge clk or posedge rst)
        if (rst) swi_training_mode_r <= 1'b0;
        else     swi_training_mode_r <= swi_training_hold_i;

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

    // Per-lane in-dwell score: saturating consecutive-lock count (sat 6'h3F).
    logic [5:0]             lane_score             [0:7];
    // -------------------------------------------------------------------------
    // EYE-CENTRE run tracker (2026-06-17, ported from src/ ~651-657).
    // EYE_WIDTH_W = ceil(log2(16+1)) = 5; phase axis is 0..15 + saturation.
    //   - run_len[i]              : 5-bit current contiguous-passing-phase run
    //                               at the current slip. Resets on a failing
    //                               dwell or when phase wraps 15→0 (new slip).
    //   - best_run[i]             : 5-bit longest passing-phase run seen
    //                               anywhere on the sweep grid this sweep.
    //   - cur_run_start_phase[i]  : phase at which the current run started.
    //   - best_run_start_phase[i] : phase where best_run started.
    //   - best_run_slip[i]        : slip at which best_run was found.
    // These feed the S_FINALIZE eye-centre arm (run CENTRE selection) and the
    // eye-width visibility outputs. The first-sweep / non-cand_armed path is
    // the only consumer of the eye-centre arm — FIX-C re-sweeps suppress it.
    // -------------------------------------------------------------------------
    localparam int EYE_WIDTH_W = 5;
    logic [EYE_WIDTH_W-1:0] run_len                [0:7];
    logic [EYE_WIDTH_W-1:0] best_run               [0:7];
    // TL-CALWRAP: length of the passing run that STARTED at phase 0 this slip
    // (the circular-wrap 'head'), so a run reaching phase 15 can stitch across
    // the mod-16 phase 15<->0 boundary instead of splitting a wrap-straddling eye.
    logic [EYE_WIDTH_W-1:0] head_run_len           [0:7];
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
    // Per-lane dwell-score decay-per-miss. Was the APB 0x04C SCORE_DECAY
    // runtime field (Stage-2 #21: register + hclk->rx CDC deleted); the
    // deployed value was a uniform decay-2 on both dies, so bake it in.
    localparam logic [5:0] SCORE_DECAY    = 6'd2;
    // Promote LOCK_THRESH to the 6-bit score width safely.
    wire   [5:0] lock_thresh_6b   = LOCK_THRESH[5:0];

    // EYE-CENTRE (2026-06-17, ported from src/ ~736-739): effective
    // MIN_LOCK_DWELLS — APB runtime override (min_lock_dwells_i) beats the
    // synth-time parameter. min_lock_dwells_i==0 → use the parameter default;
    // 1..15 → runtime override. The eye-centre arm in S_FINALIZE requires a
    // run >= this width, so SETTING IT VERY HIGH disables the arm (no run on a
    // 16-phase axis can satisfy it) and the FSM falls through to the
    // pre-fix fallback stack — the bit-identical GUARD lever.
    wire [EYE_WIDTH_W-1:0] min_lock_dwells_eff =
        (min_lock_dwells_i == 4'd0) ?
            MIN_LOCK_DWELLS[EYE_WIDTH_W-1:0] :
            {1'b0, min_lock_dwells_i};

    // -------------------------------------------------------------------------
    // FORCE-FULL-SWEEP CENTERING MODE (2026-06-17, THE COMPLETION FIX).
    //
    // PROBLEM (silicon-verified): the S_PROBE (0,0) fast-path NEVER lets the
    // eye-centre arm fire. The constant period-16 training pattern matches at
    // (slip=0,phase=0) on ALL lanes (constant-pattern blindness), so
    // probe_all_locked asserts, S_PROBE seeds lane_done[i]=1 at (0,0) for those
    // lanes, and S_PROBE -> S_FINISH SKIPS the 128-point sweep. Every lane then
    // latches (0,0) = the eye EDGE on the marginal-RX die -> link comes up 0/15.
    //
    // CENTERING MODE = (min_lock_dwells_i != 0). Reuses the existing
    // APB-writable knob (Region 8 slot 3 bits[23:20]) as the master switch,
    // giving a runtime A/B on ONE bitstream:
    //   min_lock_dwells_i == 0 => OLD behaviour: S_ARM -> S_PROBE (the (0,0)
    //                             fast-path + all FIX-C/F/H behaviour), AND the
    //                             eye-centre arm is a no-op (min_lock_dwells_eff
    //                             falls back to the param). BIT-IDENTICAL to
    //                             pre-fix => the no-regression guarantee.
    //   min_lock_dwells_i != 0 => CENTERING: S_ARM -> S_SWEEP DIRECTLY (skip
    //                             S_PROBE), so the full (slip,phase) sweep runs
    //                             and S_FINALIZE's eye-centre arm selects the
    //                             window CENTRE with MIN_LOCK_DWELLS = N.
    //
    // S_SWEEP INITIALISATION when entered from S_ARM: SAFE. S_ARM's datapath
    // branch performs the FULL per-sweep reset (dwell_ctr<=0, sweep_slip<=0,
    // sweep_phase<=0, lane_done<=0 (modulo pinned/masked), lane_score<=0,
    // run_len/best_run/cur_run_start_phase/best_run_*/any_pass_* all <=0). The
    // S_PROBE state does NOT reset any of those (it only scores at (0,0) and, on
    // dwell_expire, seeds lane_done / best_run for (0,0)-passing lanes). S_SWEEP
    // therefore relies on S_ARM's clears, never on S_PROBE's. Skipping S_PROBE
    // entered straight into S_SWEEP starts the sweep at (slip=0,phase=0) with a
    // fresh dwell window — exactly what S_PROBE would have left behind minus the
    // (0,0) lane_done seeding we deliberately want to avoid.
    // -------------------------------------------------------------------------
    wire centering_mode = (min_lock_dwells_i != 4'd0);

    // -------------------------------------------------------------------------
    // FIX C (2026-06-03) — PRBS-validated re-sweep candidate cursor.
    //
    // PROBLEM (silicon-validated): the FSM's lock/done oracle is the
    // lane_checker matching the CONSTANT training pattern (0x12EB/0xED14).
    // A constant tolerates sampling errors that DESTROY real PRBS payload, so
    // the training-pattern criterion is a FALSE-POSITIVE oracle: the FSM
    // latches (e.g.) the (0,0) probe point, training "passes", but the PRBS
    // payload does NOT sync at that alignment (0/8 lanes). The real eye is
    // elsewhere (one direction synced 5/8 lanes only at phase=15).
    //
    // The pre-FIX-C S_VALIDATE gate (cr_pkt_seen_i) was the right HOOK but
    // (a) was tied 1'b1 in the BIST core so validation was a no-op, and
    // (b) on a validation FAILURE the re-sweep is DETERMINISTIC — S_PROBE
    //     re-latches (0,0) and S_FINALIZE re-picks the same best_run, so the
    //     re-sweep re-selects the SAME losing candidate forever (the constant
    //     lock-map is identical every sweep). No convergence.
    //
    // FIX C makes validation REAL (the BIST core now drives cr_pkt_seen_i from
    // "all enabled lanes PRBS-synced") AND makes the re-sweep ADVANCE to a
    // DIFFERENT per-lane (slip,phase) each time, guaranteeing convergence:
    //
    //   * cand_idx[lane][6:0] = {slip[2:0], phase[3:0]} is a per-lane search
    //     CURSOR, a monotone floor in sweep ordinal order (slip-outer,
    //     phase-inner — the same order the shared iterator walks). It starts
    //     at 0 and, on every validation FAILURE, advances strictly PAST the
    //     candidate that just failed PRBS validation
    //     (cand_idx <= {sel_slip, sel_phase} + 1) for every still-enabled lane.
    //
    //   * cand_armed (= we are RE-sweeping after >=1 validation failure, i.e.
    //     resweep_ctr != 0) switches the per-lane SELECTION policy from the
    //     §9.10/§9.11 probe+eye-centre+any_pass stack to a strict
    //     "first training-passing point AT OR AFTER cand_idx" rule (the
    //     any_pass datapath, now floored by cand_idx). The (0,0) probe latch
    //     and the eye-centre best_run promotion are SUPPRESSED while
    //     cand_armed so they cannot drag a re-sweep back to an excluded point.
    //
    // CONVERGENCE PROOF (the crux): each validation failure raises every
    // enabled lane's cand_idx strictly (by >=1) past the just-failed ordinal,
    // and the next re-sweep's any_pass picks the FIRST training-passing point
    // with ordinal >= cand_idx. Therefore successive re-sweeps enumerate the
    // training-passing points in STRICTLY ASCENDING ordinal order, validating
    // each against REAL PRBS. There are at most 128 ordinals, so the search
    // either reaches the PRBS-valid alignment (S_DONE) or exhausts the grid.
    // Termination on a genuine no-eye is bounded by MAX_RESWEEPS
    // (retry_exhausted -> S_DONE); set MAX_RESWEEPS >= 128 so the budget can
    // cover a full grid walk before giving up.
    //
    // FIRST-sweep behaviour is UNCHANGED (cand_armed=0 while resweep_ctr==0):
    // the existing probe + eye-centre + any_pass policy runs, so the common
    // good case (and every existing cocotb test, which forces early-exit and
    // never enters S_VALIDATE) is bit-identical to pre-FIX-C.
    // -------------------------------------------------------------------------
    logic [6:0] cand_idx [0:7];          // per-lane sweep-ordinal search floor
    // FIX-H: sticky per-lane "PRBS-synced, hold this (slip,phase)" pin. Set when
    // a lane is observed lane_synced_i during S_VALIDATE; cleared on a fresh
    // external trigger (trigger_now) or swreset cancel. While pinned, the lane's
    // latched slip/phase are held (S_FINALIZE/output mux), lane_done stays 1, and
    // its cursor is NOT advanced. Only meaningful when LANE_PIN_CONVERGE=1.
    logic [7:0] lane_pinned;
    // Slip/phase captured at the moment of pin (the PRBS-valid alignment).
    logic [2:0] pin_slip  [0:7];
    logic [3:0] pin_phase [0:7];
    // FIX-L (2026-06-09) — per-lane PIN DEBOUNCE. lane_synced_i[i] reflects the
    // phase the PRBS checker saw seed+SYNC_WORDS+pipe cycles AGO, not the phase
    // currently driven on phase[i]. If the eyescan cursor has stepped phase[i]
    // forward in the meantime, the old (FIX-H) pin captured the LIVE (advanced)
    // phase[i] — the observed pvalid+1 off-by-one that pins a lane at a NON-eye
    // phase, so it shows lane_pinned=1 but lane_synced=0 forever (the asymmetric
    // HW symptom). The fix (a) FREEZES phase[i] the instant lane_synced_i[i]
    // asserts (eyescan block) so the driven phase stops chasing, and (b) requires
    // lane_synced_i[i] to be HELD at that now-frozen phase for PIN_CONFIRM cycles
    // before the pin latches. A frozen overshoot phase is NOT the real eye, so the
    // checker drops sync within its latency and the debounce never completes —
    // the cursor resumes and re-finds the true eye. Only a frozen phase that
    // KEEPS the checker synced (the genuine eye) survives the debounce and pins.
    // PIN_CONFIRM must exceed the checker seed+sync latency so a real eye's sync
    // outlasts the window; reuse the eyescan dwell sizing (>= that latency).
    localparam int PIN_CONFIRM = EYESCAN_DWELL;
    logic [$clog2(EYESCAN_DWELL+1)-1:0] pin_confirm_ctr [0:7];
    // FIX-H effective enable: compile param OR the CDC'd APB runtime bit. Every
    // pin-converge gate below uses THIS, not the bare LANE_PIN_CONVERGE param,
    // so the feature can be toggled live by an APB poke (CTRL[7]=1) on one
    // build. When both are 0 (default) pin_converge_en is constant 0 and the
    // whole FIX-H datapath collapses to the pre-FIX-H behaviour (bit-identical).
    wire pin_converge_en = LANE_PIN_CONVERGE | lane_pin_converge_en_i;
    // cand_armed / sweep_ordinal are continuous-assigned further below, AFTER
    // resweep_ctr is declared (default_nettype none forbids the forward
    // reference). See the "FIX C cursor combinational" block near resweep_ctr.
    logic       cand_armed;
    logic [6:0]  sweep_ordinal;

    // Backwards compat: lane_locked[i] is RETAINED as an input — it still
    // gates the `probe_lane_pass_q` advisory verdict in S_FINALIZE's
    // legacy path and is exposed unchanged via SWI_LANE_STATUS.

    // -------------------------------------------------------------------------
    // Spec §7.2 — vote-disable strobe for the new lane_checker.
    // High while the calibrator is walking the (slip, phase) grid;
    // tells the checker's 3-window voter to clamp vote_enable=0.
    // -------------------------------------------------------------------------
    assign sweep_active_o = (cur_state == S_SWEEP);

    // L4 training-exit-deadlock fix: "locally LOCKED" decode (S_HOLD or beyond).
    // Refined 2026-07-01: assert for S_HOLD *and* S_VALIDATE/S_DONE, not strictly
    // S_HOLD. Reason: the two dies' POR-auto-cal RACES the training handshake — a
    // die that calibrated fast advances to S_DONE (locked) before the peer is even
    // held in S_HOLD, so a strict "==S_HOLD" rendezvous never fires (the peer sits
    // in S_DONE, not S_HOLD). "Locally locked" = has finished its sweep + latched
    // (slip,phase): S_HOLD (4'd6) | S_VALIDATE (4'd9) | S_DONE (4'd4). The autoneg
    // rendezvous ("both locally locked") then fires regardless of which die won the
    // POR-cal race, and ST_TRAIN_EXIT does the bilateral training-mode clear.
    assign cal_in_hold_o = (cur_state == S_HOLD)
                        || (cur_state == S_VALIDATE)
                        || (cur_state == S_DONE);

    // (eye-centre min-dwells selection removed in Stage 2a.2-ii — the
    //  training sweep now selects the first training-passing point per lane.)

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
    // Mask-aware: a MASKED lane is pre-set lane_done in S_ARM so it is already
    // included in &lane_done; the | ~lane_mask here is belt-and-braces so the
    // early-exit termination requires only ACTIVE lanes to be done even if a
    // future change defers the masked-lane lane_done set. At lane_mask=0xFF the
    // | term is 0 → &lane_done exactly (bit-identical).
    wire all_done = &(lane_done | ~lane_mask);

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
    // Mask-aware: only ACTIVE lanes need pass the (0,0) probe for the fast-path.
    // A masked lane is excluded (| ~lane_mask forces its term to 1). At 0xFF the
    // | term is 0 → &probe_lane_pass_w exactly (bit-identical).
    wire probe_all_locked = &(probe_lane_pass_w | ~lane_mask);

    // T3: a sweep is a genuine SUCCESS only if NO lane faulted (every lane
    // found a locking (phase,slip)). lane_fault_q is bounce-immune, unlike
    // &lane_locked. The per-deploy lottery failure mode is all_done=1 with
    // lane_fault_q != 0 — the peer's training pattern wasn't present during
    // this node's ~82 µs sweep because the two role_lock triggers were
    // ms-skewed (T1 HW-confirmed).
    // Mask-aware: a MASKED lane can never set lane_fault_q (it is pre-done in
    // S_ARM and the S_FINALIZE fault arm is gated by !lane_done), but mask the
    // reduction too so sweep_success keys ONLY off ACTIVE lanes' faults — the
    // exact mirror of bist_core's prbs_all_synced_w masking, and robust to any
    // future path that could set a masked lane's fault. At lane_mask=0xFF this
    // is ~|(lane_fault_q & 8'hFF) == ~|lane_fault_q exactly (bit-identical).
    wire sweep_success  = ~|(lane_fault_q & lane_mask);
    // Auto-retry budget since the last EXTERNAL trigger (see resweep_ctr
    // block). MAX_RESWEEPS==0 ⇒ never exhausts (retry while role_locked).
    logic [15:0] resweep_ctr;
    wire retry_exhausted = (MAX_RESWEEPS != 0) &&
                           (resweep_ctr >= MAX_RESWEEPS);

    // M8 (tidelink port) — S_VALIDATE val-timeout terminal-stop condition.
    // Asserted only when the M8 policy is enabled AND there is no FIX-C
    // re-sweep budget to exhaust (MAX_RESWEEPS==0, the bring-up/HW default
    // where retry_exhausted is permanently 0 -> the infinite-thrash case).
    // When MAX_RESWEEPS!=0 this stays 0 so the FIX-C escape re-sweep is taken
    // until retry_exhausted (no behaviour change for the bounded-budget case).
    // See the VAL_TIMEOUT_TO_DONE parameter header.
    wire val_timeout_stop = VAL_TIMEOUT_TO_DONE && (MAX_RESWEEPS == 0);

    // FIX C cursor combinational (placed here so resweep_ctr is already
    // declared — default_nettype none forbids forward net references):
    //   cand_armed     — engage the PRBS-validated re-sweep cursor selection.
    //                    High once at least one re-arm has happened
    //                    (resweep_ctr != 0), i.e. we are RE-sweeping after a
    //                    validation failure (or a T3 lottery fault). On the
    //                    very first sweep it is 0, so first-sweep selection is
    //                    bit-identical to pre-FIX-C.
    //   sweep_ordinal  — the live shared iterator as a 7-bit ordinal
    //                    {sweep_slip, sweep_phase} (slip-outer, phase-inner),
    //                    for comparison against the per-lane cand_idx floor.
    always_comb begin
        cand_armed    = (resweep_ctr != 16'd0);
        sweep_ordinal = {sweep_slip, sweep_phase};
    end

    // T3.2 peer-aware training-hold counter (cycles spent in S_HOLD).
    localparam int HOLD_MAX = HOLD_CYCLES - 1;
    logic [$clog2(HOLD_CYCLES+1)-1:0] hold_ctr;
    // FIX D (2026-08-07, TL-009 framing): PEER-AWARE S_HOLD release. S_HOLD's
    // intent (comment ~:1490) is to keep our training pattern up so the peer also
    // locks — but it uses a BLIND fixed HOLD_MAX timer, so on a ms-skew bring-up
    // this die drops its pattern before the peer has locked -> the peer sweeps a
    // silent lane -> bad framing -> the cross-die W/B round-trip doesn't cross ->
    // data-drop + write-stall wedge (0x21F8 witness, 235d758). FIX D holds training
    // past HOLD_MAX until this die's RX confirms ALL active lanes synced (peer
    // present+clean), bounded by a backstop so it never hangs. A good bring-up
    // (lanes synced by HOLD_MAX) releases at HOLD_MAX exactly as before.
    localparam int HOLD_BACKSTOP_CYCLES = HOLD_CYCLES * 3;   // hang-guard ~3x HOLD
    localparam int HOLD_BACKSTOP_MAX    = HOLD_BACKSTOP_CYCLES - 1;
    logic [$clog2(HOLD_BACKSTOP_CYCLES+1)-1:0] hold_ext_ctr;
    // Peer-present proxy: all ACTIVE lanes LOCKED (this die's RX is locked to the
    // peer's training pattern). Uses `lane_locked` (connected via lane_locked_w on
    // the eth-chiplet build) — NOT lane_synced_i, which is tied 8'h00 there.
    wire  all_lanes_locked_d = &(lane_locked | ~lane_mask);

    // §9.11d Fix A1 — validation-timeout counter (cycles in S_VALIDATE).
    // Saturates at VALIDATION_TIMEOUT-1; S_VALIDATE → S_ARM (re-sweep) on
    // saturation if cr_pkt_seen_i didn't assert.
    localparam int VAL_MAX = VALIDATION_TIMEOUT - 1;
    logic [$clog2(VALIDATION_TIMEOUT+1)-1:0] val_ctr;

    // -------------------------------------------------------------------------
    // FIX-J (2026-06-09) — in-S_VALIDATE PRBS (slip,phase) EYESCAN state.
    //
    // FIX-M (2026-06-09) — SLIP+PHASE walk. The original FIX-J/FIX-L eyescan
    // walked the 16-way PHASE cursor ONLY while pinning slip to 0, on the RTL
    // assumption (cand_idx note ~line 1442) that "the single PRBS-sync point is
    // always at slip=0". HW (commit bba0d11) REFUTES that: die_a held cs=9 the
    // whole window with lane_synced=0x00 — with slip forced to 0, NO phase was
    // the PRBS eye for those lanes. The deserialiser applies io_bit_slip as a
    // RIGHT-ROTATION of the assembled 16-bit window (WavD2DGpioRx.v line 279:
    // io_link_data = _link_data_rep[{2'b00,io_bit_slip} +: 16]) and io_phase_offset
    // as a sample-timing rotation of adj_count (line 205). The two compose into the
    // FULL 128-point (slip 0..7 x phase 0..15) alignment space the FIX-C cand_idx
    // already enumerates; a lane whose PRBS-valid alignment needs slip!=0 can NEVER
    // sync in a slip=0-confined scan. FIX-M walks BOTH cursors.
    //
    // escan_phase / escan_slip are the shared (phase,slip) cursors swept across the
    // 128-point space while in S_VALIDATE (PRBS on the wire). escan_dwell_ctr times
    // the per-POINT dwell (>= the PRBS checker seed+sync latency). escan_en gates
    // the whole datapath so it is inert (and synthesises away) unless
    // pin_converge_en && PRBS_EYESCAN. The eyescan only DRIVES unpinned lanes;
    // pinned lanes hold their (pin_slip,pin_phase) via the existing FIX-H output
    // path. Because the scan stays inside S_VALIDATE (never re-asserting
    // training_mode), the bilateral PRBS rendezvous carrier is held continuously
    // while every (slip,phase) point is tried.
    // -------------------------------------------------------------------------
    wire escan_en = pin_converge_en & PRBS_EYESCAN;
    localparam int ESCAN_MAX = EYESCAN_DWELL - 1;
    // FIX-M: one full walk is now 8 slips x 16 phases = 128 points (vs 16). Max
    // number of in-place rescan windows the eyescan holds S_VALIDATE for before
    // falling through to the normal re-arm / M8 terminal. Sized so the bilateral
    // rendezvous has SEVERAL full 128-point walks' worth of overlapping windows to
    // converge in, while a genuine no-eye die still terminates. Each rescan is one
    // VALIDATION_TIMEOUT window; the scan cursor advances CONTINUOUSLY across
    // windows (not reset on rescan), so the budget is counted in windows, not
    // points. At the tb/HW sizing VALIDATION_TIMEOUT ~= 3*EYESCAN_DWELL one window
    // covers ~3 points, so 512 windows >= ~1500 points >= ~12 full 128-pt walks.
    localparam int ESCAN_MAX_PASSES = 512;
    logic [3:0]                            escan_phase;
    logic [2:0]                            escan_slip;    // FIX-M: slip cursor 0..7
    logic [$clog2(EYESCAN_DWELL+1)-1:0]    escan_dwell_ctr;
    // Count of in-place rescan windows consumed since this S_VALIDATE rendezvous
    // began (reset only when S_VALIDATE is ENTERED from another state, NOT on an
    // in-place rescan). Bounds the carrier-up hold.
    logic [$clog2(ESCAN_MAX_PASSES+1)-1:0] escan_passes;
    // The val_ctr saturated (one scan window elapsed) without all lanes pinned.
    wire escan_window_timeout =
        (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0]);
    // The in-place rescan budget is spent — stop holding S_VALIDATE.
    wire escan_scan_exhausted = (escan_passes >= ESCAN_MAX_PASSES[$clog2(ESCAN_MAX_PASSES+1)-1:0]);

    // Task G S_VALIDATE confirm source. Always the real-data oracle
    // (cr_pkt_seen_i); when USE_SYNC_VALIDATE=1 a correctly-aligned SYNC beacon
    // (sync_seen_i) ALSO confirms. With USE_SYNC_VALIDATE=0 the SYNC term is a
    // constant 0 (synthesised away) so validate_confirm == cr_pkt_seen_i exactly
    // — behaviour identical to today.
    wire validate_confirm = cr_pkt_seen_i | (USE_SYNC_VALIDATE & sync_seen_i);

    // FIX-K (2026-06-09) — EYESCAN-mode confirm DEBOUNCE.
    //
    // ROOT CAUSE (HW asymmetric FIX-J failure): the S_VALIDATE next-state checks
    // validate_confirm (= prbs_all_synced_w = &(lane_synced | ~lane_mask)) at a
    // HIGHER precedence than the escan hold. On a PARTIAL lane_mask (broken-ribbon
    // deploy) that aggregate can assert MOMENTARILY when the few masked-in lanes
    // flicker-sync as the eyescan cursor sweeps past their PRBS-valid phases
    // (the observed HW lane_synced transients 0x60/0x03/0x01). A single such
    // 1-cycle assertion forced S_DONE (cs4) with the lanes NOT durably pinned and
    // validation_timed_out=0 — the calibrator terminated WITHOUT running the scan
    // to completion. (Reproduced: tb_cal_escan_precedence -> BUG-CONFIRMED.)
    //
    // FIX: while the eyescan is enabled, require validate_confirm to be HELD for a
    // full EYESCAN_DWELL window (>= the PRBS checker seed+sync latency, the same
    // dwell a real pin needs) before it may drive S_DONE. A momentary flicker
    // cannot trip the terminal; a genuine all-lanes-synced confirm (held stable)
    // still ends the scan promptly. Inert unless escan_en, so the non-eyescan
    // S_VALIDATE path (FIX-C/M8) is bit-identical to today.
    localparam int CONFIRM_STABLE = EYESCAN_DWELL;
    logic [$clog2(EYESCAN_DWELL+1)-1:0] confirm_ctr;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                           confirm_ctr <= '0;
        else if (cur_state != S_VALIDATE)  confirm_ctr <= '0;
        else if (!validate_confirm)        confirm_ctr <= '0;
        else if (confirm_ctr < CONFIRM_STABLE[$clog2(EYESCAN_DWELL+1)-1:0])
                                           confirm_ctr <= confirm_ctr + 1'b1;
    end
    // Stable confirm: in eyescan mode require the held window; otherwise the bare
    // confirm (non-eyescan paths unchanged).
    wire confirm_stable = (confirm_ctr >= CONFIRM_STABLE[$clog2(EYESCAN_DWELL+1)-1:0]);
    wire escan_confirm  = validate_confirm & confirm_stable;

    // FIX-J in-place rescan pulse: timeout, eyescan running, budget remains, not
    // confirmed. The FSM stays in S_VALIDATE; val_ctr + escan cursor restart.
    // (Declared after validate_confirm — default_nettype none forbids the
    // forward reference.)
    wire escan_rescan = escan_en && escan_window_timeout && !escan_scan_exhausted
                        && !validate_confirm && role_locked_sync && !swreset_sync;

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
                // FIX-G (root cause behind the FIX-E/FIX-F "stuck at S_IDLE"
                // symptom): arm on the role_locked LEVEL, not only its one-cycle
                // rising edge. This FSM is clocked by the recovered rx_link_clk,
                // which is sourced from the PEER's forwarded TX clock and is
                // stalled (peer not yet transmitting) or glitchy (just locking)
                // at bring-up. A one-cycle role_locked_rise pulse can be missed
                // on that clock and is never regenerated (role_locked stays
                // high) -> permanent S_IDLE. Level-arm re-evaluates every live
                // clock edge until it sticks. Gated by ~swreset_sync so we never
                // arm while held in reset. S_IDLE is only entered from reset, so
                // this cannot cause a spurious re-arm (S_DONE re-arm still goes
                // via the swreset path). trigger_now kept for the clean-clock
                // case + swreset_fall re-trigger.
                if (trigger_now | (role_locked_sync & ~swreset_sync))
                                        nxt_state = S_ARM;
            end
            S_ARM: begin
                // Agent-F §9.10: enter S_PROBE first to test (slip=0, phase=0)
                // before the full 128-point sweep. See state-encoding comment.
                //
                // FORCE-FULL-SWEEP CENTERING (2026-06-17): when centering_mode is
                // active (min_lock_dwells_i != 0), BYPASS S_PROBE and go DIRECTLY
                // to S_SWEEP. This avoids BOTH (a) the S_PROBE (0,0) lane_done
                // seeding and (b) the probe_all_locked -> S_FINISH skip of the
                // 128-point sweep, so the full sweep runs and S_FINALIZE's
                // eye-centre arm picks the window CENTRE. S_ARM's datapath branch
                // (below) has already done the full per-sweep reset, so S_SWEEP
                // starts cleanly at (slip=0,phase=0). When centering_mode==0 the
                // legacy S_ARM -> S_PROBE edge is taken (bit-identical to pre-fix).
                if (swreset_sync)            nxt_state = S_CANCEL;
                else if (centering_mode)     nxt_state = S_SWEEP;
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
                //
                // FIX C: the (0,0) probe fast-path (probe_all_locked ->
                // S_FINISH, bypassing the 128-point sweep) is DISABLED while
                // cand_armed (a re-sweep after a PRBS-validation failure).
                // (0,0) is exactly the candidate that just failed validation
                // — letting the fast-path re-latch it would loop forever.
                // A re-sweep ALWAYS runs the full cursor sweep so any_pass
                // advances past the excluded points.
                if (swreset_sync)                       nxt_state = S_CANCEL;
                else if (dwell_expire) begin
                    if (probe_all_locked && !cand_armed) nxt_state = S_FINISH;
                    else                                 nxt_state = S_SWEEP;
                end
            end
            S_SWEEP: begin
                // §9.11: best-of-sweep walks the full 128-point space and
                // transitions to S_FINALIZE on sweep_exhausted (one cycle
                // to compute per-lane eye-centre latches). EARLY_EXIT compat
                // mode keeps the §9.7 first-match-wins early termination
                // and bypasses S_FINALIZE — its per-lane latches happened
                // at first-lock in the datapath, lane_done is already set.
                if (swreset_sync)                                   nxt_state = S_CANCEL;
                else if (early_exit_en_w && all_done)          nxt_state = S_FINISH;
                else if (sweep_exhausted)                      nxt_state = S_FINALIZE;
            end
            S_FINALIZE: begin
                // §9.11: single-cycle state. Datapath assigns per-lane
                // slip[i]/phase[i] (run centre), lane_done[i], or
                // lane_fault_q[i]. Transitions to S_FINISH unconditionally
                // (except swreset). All work happens in the datapath this
                // same cycle.
                if (swreset_sync) nxt_state = S_CANCEL;
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
                else if (role_locked_sync)     nxt_state = S_ARM;
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
                if (swreset_sync)                   nxt_state = S_CANCEL;
                else if (!role_locked_sync)         nxt_state = S_DONE;
                // FIX E (2026-06-08): gate S_HOLD → S_VALIDATE on
                // swi_training_mode. When SW holds bit6=1, both peer boards
                // stay in S_HOLD (training TX) until SW simultaneously clears
                // bit6 on both — bilateral coordinated release. Without this
                // gate, one board exits S_HOLD autonomously and enters
                // S_VALIDATE alone; the peer is still sending training, so no
                // PRBS sync occurs and S_VALIDATE times out forever.
                // Has no effect when swi_training_mode=0 (normal autonomous
                // operation: hold_ctr expiry → S_VALIDATE as before).
                // FIX D (2026-08-07): PEER-AWARE release — require the minimum
                // HOLD_MAX AND all active lanes synced (peer present+clean) so we
                // don't drop our training pattern before the peer has locked. The
                // hold_ext_ctr backstop guarantees release if the peer never syncs.
                // Good bring-up (lanes synced by HOLD_MAX) releases at HOLD_MAX.
                else if (hold_ctr >= HOLD_MAX && (all_lanes_locked_d || !HOLD_PEER_AWARE_EN) && !swi_training_mode_r) nxt_state = S_VALIDATE;
                else if (HOLD_PEER_AWARE_EN && hold_ext_ctr >= HOLD_BACKSTOP_MAX[$clog2(HOLD_BACKSTOP_CYCLES+1)-1:0] && !swi_training_mode_r) nxt_state = S_VALIDATE;
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
                if (swreset_sync)                  nxt_state = S_CANCEL;
                else if (!role_locked_sync)        nxt_state = S_DONE;
                // FIX-K: in eyescan mode, a momentary validate_confirm (partial-mask
                // flicker-sync) must NOT terminate the scan — require the confirm to
                // be HELD a full EYESCAN_DWELL (escan_confirm). The non-eyescan path
                // keeps the bare validate_confirm (FIX-C/M8 behaviour unchanged).
                else if (escan_en ? escan_confirm : validate_confirm)
                                                   nxt_state = S_DONE;
                // FIX-J: when the eyescan is enabled (escan_en) it NEVER re-arms.
                // Re-arming re-asserts training_mode (S_ARM/S_SWEEP) and DROPS
                // this die's PRBS carrier — the exact event that starves the
                // peer's bilateral rendezvous and was the proximate cause of the
                // FIX-H HW stall (S_HOLD<->S_VALIDATE, lane_synced=0). The eyescan
                // already covers all 16 phases WITHIN S_VALIDATE, so re-sweeping
                // (which only re-runs the training-pattern S_SWEEP) can find
                // nothing the scan cannot. On a per-window timeout the FSM STAYS
                // in S_VALIDATE and re-scans in place (carrier held UP) so the
                // peer — also scanning in its own S_VALIDATE — can rendezvous and
                // every lane's PRBS phase is hit during the overlap. The bound
                // escan_scan_exhausted caps the carrier-up hold; once spent the
                // die latches a TERMINAL S_DONE (validation_timed_out set, link_up
                // still gated on real sync) WITHOUT ever re-sweeping — the
                // carrier-starvation-free give-up for a genuine no-eye die.
                else if (escan_en) begin
                    if (escan_scan_exhausted &&
                        (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0]))
                        nxt_state = S_DONE;        // bounded terminal, no re-sweep
                    else
                        nxt_state = S_VALIDATE;    // keep scanning, carrier UP
                end
                else if (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0])
                    // FIX-C: re-sweep (S_ARM, advancing cand_idx) to ESCAPE a
                    // false-positive candidate, until retry_exhausted -> S_DONE.
                    // M8: when VAL_TIMEOUT_TO_DONE, ALSO latch terminal on
                    // val_timeout_stop (= MAX_RESWEEPS==0, the infinite-thrash
                    // case) so a trained-but-unvalidated die stops dropping its
                    // carrier on the peer. retry_exhausted path is unchanged, so
                    // the FIX-C cand_idx escape search is fully preserved.
                    nxt_state = (retry_exhausted || val_timeout_stop)
                                  ? S_DONE : S_ARM;
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
        // FIX C: a validation FAILURE (S_VALIDATE -> S_ARM) is also an
        // auto-retry — count it against the budget AND it makes cand_armed
        // assert so the next sweep advances the candidate cursor.
        else if ((cur_state == S_VALIDATE) &&
                 (nxt_state  == S_ARM))           resweep_ctr <= resweep_ctr + 16'd1;
    end

    // -------------------------------------------------------------------------
    // MUST-FIX #2(b) — sticky validation_timed_out / cal_failed flag.
    //
    // Latches 1 when the FSM lands in S_DONE because the PRBS-validated
    // re-sweep search GAVE UP (retry budget exhausted), as opposed to landing
    // in S_DONE because a candidate actually validated. The two retry_exhausted
    // -> S_DONE arms in the next-state logic are:
    //   * S_VALIDATE: val_ctr >= VAL_MAX && retry_exhausted  (validation timeout
    //     give-up — the primary FIX C exhaustion case)
    //   * S_FINISH:   retry_exhausted                         (lane-fault give-up
    //     once the budget is spent — no eye anywhere on the grid)
    // Both mean "done, but never confirmed on real data". Cleared on a fresh
    // external trigger (trigger_now) or an swreset cancel (S_CANCEL), matching
    // the lifetime of the rest of the per-search state.
    //
    // NOTE: a NORMAL validation success (S_VALIDATE -> S_DONE via cr_pkt_seen_i)
    // does NOT set this — that arm is taken before val_ctr saturates, so the
    // (nxt_state==S_DONE && retry_exhausted && val_ctr>=VAL_MAX) qualifier is
    // false. Likewise a normal S_FINISH sweep_success -> S_HOLD/-> S_DONE does
    // not set it (retry_exhausted is the gating term).
    // M8: a val-timeout terminal via val_timeout_stop (MAX_RESWEEPS==0) is ALSO
    // a give-up — it lands in S_DONE without ever validating real PRBS — so it
    // must set validation_timed_out exactly like the retry_exhausted give-up.
    // It is gated on the SAME S_VALIDATE+val-saturated qualifier, so a normal
    // validate-confirm S_DONE (taken before saturation) never sets it.
    // FIX-J: the eyescan bounded terminal (escan_scan_exhausted, scan window
    // saturated, never all-pinned) also lands in S_DONE WITHOUT validating real
    // PRBS on every lane, so it is a give-up too — set validation_timed_out so
    // cal_done is distinguishable from a real convergence and link_up stays 0.
    wire escan_give_up =
        escan_en && escan_scan_exhausted && (cur_state == S_VALIDATE) &&
        (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0]) && !validate_confirm;
    wire give_up_to_done =
        (nxt_state == S_DONE) &&
        ((retry_exhausted &&
          (((cur_state == S_VALIDATE) &&
            (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0])) ||
           (cur_state == S_FINISH))) ||
         (val_timeout_stop && (cur_state == S_VALIDATE) &&
          (val_ctr >= VAL_MAX[$clog2(VALIDATION_TIMEOUT+1)-1:0])) ||
         escan_give_up);
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                                 validation_timed_out <= 1'b0;
        else if (trigger_now)                    validation_timed_out <= 1'b0;
        else if (cur_state == S_CANCEL)          validation_timed_out <= 1'b0;
        else if (give_up_to_done)                validation_timed_out <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // T3.2 hold counter: cycles spent in S_HOLD. Reset whenever NOT in
    // S_HOLD (each S_HOLD entry starts fresh); free-runs while in S_HOLD,
    // saturating at HOLD_MAX (the S_HOLD→S_DONE release condition).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin                      hold_ctr <= '0; hold_ext_ctr <= '0; end
        else if (cur_state != S_HOLD) begin hold_ctr <= '0; hold_ext_ctr <= '0; end
        else begin
            if (hold_ctr < HOLD_MAX[$clog2(HOLD_CYCLES+1)-1:0])
                hold_ctr <= hold_ctr + 1'b1;
            // FIX D: free-running backstop counter, saturates at HOLD_BACKSTOP_MAX
            if (hold_ext_ctr < HOLD_BACKSTOP_MAX[$clog2(HOLD_BACKSTOP_CYCLES+1)-1:0])
                hold_ext_ctr <= hold_ext_ctr + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // FIX C — per-lane candidate search cursor.
    //
    // Lifetime: reset to 0 on `rst` and on `trigger_now` (a FRESH external
    // trigger restarts the search from ordinal 0). It is DELIBERATELY NOT
    // cleared on S_ARM — S_ARM fires on every auto re-arm and the cursor must
    // PERSIST across re-sweeps for the search to make forward progress.
    //
    // Advance: on the validation-FAILURE edge (cur_state==S_VALIDATE &&
    // nxt_state==S_ARM) every lane's cursor jumps strictly PAST the candidate
    // that just failed PRBS validation: cand_idx <= {slip[i], phase[i]} + 1
    // (saturating at 7'h7F so a failure at the last ordinal does not wrap the
    // cursor back to 0 and re-try excluded points — once saturated the
    // any_pass floor admits nothing new and the lane faults, letting
    // MAX_RESWEEPS terminate the search). The aggregate cr_pkt_seen_i cannot
    // say WHICH lane's PRBS failed, so advancing all lanes together is the
    // correct conservative move (the gate needs ALL enabled lanes synced).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < 8; i++) cand_idx[i] <= 7'd0;
        end else if (trigger_now) begin
            for (int i = 0; i < 8; i++) cand_idx[i] <= 7'd0;
        end else if (pin_converge_en &&
                     (((cur_state == S_VALIDATE) && (nxt_state == S_ARM)) ||
                      ((cur_state == S_FINISH)   && (nxt_state == S_ARM)))) begin
            // FIX-H: advance the per-lane phase cursor on EVERY re-arm — both a
            // validation failure (cursor phase was in-band but PRBS-invalid) AND
            // a lane-fault re-sweep (cursor phase was not in the training band, so
            // no candidate was found). Advancing on both prevents a non-in-band
            // cursor phase from stalling the walk. Pinned lanes hold.
            for (int i = 0; i < 8; i++) begin
                if (lane_pinned[i]) begin
                    // Pinned (PRBS-synced) lane: HOLD its cursor.
                    cand_idx[i] <= cand_idx[i];
                end else begin
                    // FIX-H: unpinned lane — advance the per-lane PHASE cursor by
                    // 1, mod-16. The candidate search is confined to slip=0 (the
                    // ONLY slip where the self-sync PRBS payload is contiguous — a
                    // nonzero WavD2DGpioRx io_bit_slip rotates the assembled 16-bit
                    // word and destroys PRBS bit-order; the ambiguity map shows the
                    // single PRBS-sync point is always at slip=0). The only free
                    // variable is the 16-way phase (word-boundary) placement.
                    // cand_idx[i][3:0] is that phase; it wraps 15->0 so each
                    // unpinned lane re-enumerates all 16 phases independently. The
                    // mod-16 wrap (vs the FIX-C mod-128 saturate) lets a lane
                    // return to a phase another lane's failure dragged it past —
                    // the crux of the die_a multi-lane non-convergence. Lanes pin
                    // INDEPENDENTLY as each cursor lands on its PRBS-valid phase.
                    cand_idx[i] <= {3'd0, (cand_idx[i][3:0] + 4'd1)};   // mod-16 phase walk
                end
            end
        end else if ((cur_state == S_VALIDATE) && (nxt_state == S_ARM)) begin
            // Unchanged FIX-C behaviour when LANE_PIN_CONVERGE=0.
            for (int i = 0; i < 8; i++) begin
                cand_idx[i] <= ({slip[i], phase[i]} == 7'h7F)
                                 ? 7'h7F
                                 : ({slip[i], phase[i]} + 7'd1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // FIX-H (2026-06-09) — per-lane PRBS-sync PIN latch.
    //
    // During S_VALIDATE the latched (slip,phase) drives the deserialiser and the
    // PRBS payload is on the wire, so lane_synced_i[i] tells us EXACTLY which
    // lanes' latched alignment is PRBS-valid. Latch a sticky pin for each such
    // lane together with the (slip,phase) it synced at. Pinned lanes are then
    // held through every subsequent re-sweep (their cursor is frozen above, and
    // S_FINALIZE / the output mux re-assert pin_slip/pin_phase), so the search
    // collapses to only the still-unsynced lanes. When all enabled lanes are
    // pinned, validate_confirm (= cr_pkt_seen_i = all-enabled-synced) holds and
    // S_VALIDATE advances to S_DONE.
    //
    // Lifetime mirrors cand_idx: cleared on rst / trigger_now / S_CANCEL.
    // Gated entirely by LANE_PIN_CONVERGE so the default build is bit-identical.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            lane_pinned <= 8'h00;
            for (int i = 0; i < 8; i++) begin
                pin_slip[i]        <= 3'd0;
                pin_phase[i]       <= 4'd0;
                pin_confirm_ctr[i] <= '0;
            end
        end else if (trigger_now || (cur_state == S_CANCEL)) begin
            lane_pinned <= 8'h00;
            for (int i = 0; i < 8; i++) begin
                pin_slip[i]        <= 3'd0;
                pin_phase[i]       <= 4'd0;
                pin_confirm_ctr[i] <= '0;
            end
        end else if (pin_converge_en && (cur_state == S_VALIDATE)) begin
            for (int i = 0; i < 8; i++) begin
                // LANE-MASK: a MASKED lane is parked done at (0,0) and its PRBS
                // checker is disabled — never attempt to pin it (lane_synced_i[i]
                // is meaningless / could be forged high by the wrapper). Skipping
                // it here keeps the pin search confined to ACTIVE lanes. At
                // lane_mask=0xFF this guard is always false (bit-identical).
                if (!lane_mask[i]) begin
                    // masked — never pin.
                end else if (lane_pinned[i]) begin
                    // already pinned — hold.
                end else if (!lane_synced_i[i]) begin
                    // FIX-L: lost (or not yet) sync at the driven phase — restart
                    // the per-lane debounce. The eyescan block resumes walking
                    // phase[i] (its freeze gate is also !lane_synced_i[i]).
                    pin_confirm_ctr[i] <= '0;
                end else if (pin_confirm_ctr[i] <
                             PIN_CONFIRM[$clog2(EYESCAN_DWELL+1)-1:0] - 1'b1) begin
                    // FIX-L: synced AND phase frozen (eyescan holds phase[i] while
                    // lane_synced_i[i]) — count the held window. A frozen overshoot
                    // phase is not the eye, so the checker would drop sync and this
                    // counter would reset before completing; only the true eye
                    // survives PIN_CONFIRM cycles of continuous sync.
                    pin_confirm_ctr[i] <= pin_confirm_ctr[i] + 1'b1;
                end else begin
                    // Debounce complete at a stably-synced, frozen phase: PIN.
                    // phase[i] has been frozen for the whole window so capturing it
                    // now is the genuine PRBS-valid alignment (no off-by-one).
                    lane_pinned[i] <= 1'b1;
                    pin_slip[i]    <= slip[i];
                    pin_phase[i]   <= phase[i];
                end
            end
        end
    end

    // §9.11d Fix A1 — validation-timeout counter. Cleared whenever NOT in
    // S_VALIDATE; saturates at VAL_MAX while in S_VALIDATE.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                          val_ctr <= '0;
        else if (cur_state != S_VALIDATE) val_ctr <= '0;
        // FIX-J: on an in-place eyescan rescan, restart the window timer so each
        // budgeted rescan gets a fresh VALIDATION_TIMEOUT (the FSM stays in
        // S_VALIDATE, carrier up, but the per-window timeout must re-arm).
        else if (escan_rescan)            val_ctr <= '0;
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
            escan_phase          <= 4'd0;
            escan_slip           <= 3'd0;     // FIX-M
            escan_dwell_ctr      <= '0;
            escan_passes         <= '0;
            for (int i = 0; i < 8; i++) begin
                slip[i]                  <= 3'd0;
                phase[i]                 <= 4'd0;
                lane_score[i]            <= 6'd0;
                run_len[i]               <= '0;
                head_run_len[i]          <= '0;
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
                        head_run_len[i]          <= '0;
                        best_run[i]              <= '0;
                        cur_run_start_phase[i]   <= 4'd0;
                        best_run_start_phase[i]  <= 4'd0;
                        best_run_slip[i]         <= 3'd0;
                        any_pass_slip[i]         <= 3'd0;
                        any_pass_phase[i]        <= 4'd0;
                    end
                    // FIX-H: re-assert PINNED lanes' converged (slip,phase) and
                    // lane_done after the mass-clear, so a pinned lane holds its
                    // PRBS-valid alignment across the re-sweep instead of being
                    // re-searched. The output mux drives slip[i]/phase[i] for a
                    // done lane, and lane_done[i]=1 also freezes it in S_SWEEP /
                    // S_FINALIZE (skipped because !lane_done gates their work).
                    if (pin_converge_en) begin
                        for (int i = 0; i < 8; i++) begin
                            if (lane_pinned[i]) begin
                                slip[i]      <= pin_slip[i];
                                phase[i]     <= pin_phase[i];
                                lane_done[i] <= 1'b1;
                            end
                        end
                    end
                    // LANE-MASK (2026-06-11): park every MASKED lane DONE at the
                    // benign (slip=0,phase=0) (already cleared above) with NO
                    // fault. lane_done[i]=1 freezes the lane out of S_PROBE /
                    // S_SWEEP / S_FINALIZE (all gated by !lane_done[i]) and the
                    // S_FINALIZE preserve branch (if lane_done) fires before the
                    // fault arm, so a masked lane can NEVER set lane_fault_q. The
                    // output mux then drives (0,0) for it. At lane_mask=0xFF no
                    // bit is masked so this loop is a no-op (bit-identical).
                    for (int i = 0; i < 8; i++) begin
                        if (!lane_mask[i]) lane_done[i] <= 1'b1;
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
                            lane_score[i] <= (lane_score[i] > SCORE_DECAY)
                                             ? lane_score[i] - SCORE_DECAY : 6'd0;
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
                            // FIX C: while cand_armed (a PRBS-validation
                            // re-sweep) do NOT latch (0,0) / lane_done from the
                            // probe — (0,0) is an already-excluded candidate.
                            // The lane stays not-done and falls through to the
                            // full cursor sweep. probe_lane_pass_q is still
                            // recorded for observability but is NOT consulted
                            // by S_FINALIZE in cand_armed mode (see below).
                            if ((lane_score[i] >= lock_thresh_6b) && !cand_armed) begin
                                slip[i]       <= 3'd0;
                                phase[i]      <= 4'd0;
                                lane_done[i]  <= 1'b1;
                                // EYE-CENTRE (ported from src/ ~1171-1173):
                                // seed best_run = lock_thresh at (0,0) so the
                                // §9.11 S_FINALIZE eye-centre arm cannot
                                // displace the probe verdict for this lane
                                // (it is gated off by !lane_done[i] anyway),
                                // and the eye-width visibility mirror reports
                                // a pass for it.
                                best_run[i]             <= lock_thresh_6b[EYE_WIDTH_W-1:0];
                                best_run_start_phase[i] <= 4'd0;
                                best_run_slip[i]        <= 3'd0;
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
                            lane_score[i] <= (lane_score[i] > SCORE_DECAY)
                                             ? lane_score[i] - SCORE_DECAY : 6'd0;
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
                                    //
                                    // FIX C: while cand_armed, the "first
                                    // passing point" is FLOORED by cand_idx[i]
                                    // (the search cursor). Only points whose
                                    // sweep ordinal {slip,phase} is AT OR AFTER
                                    // the cursor are eligible, so any_pass
                                    // captures the first training-passing point
                                    // strictly past every previously
                                    // validation-failed candidate. This is what
                                    // makes successive re-sweeps enumerate
                                    // candidates in ascending order.
                                    // FIX-H pin-converge re-sweep: confine the
                                    // candidate search to slip=0 (the ONLY slip
                                    // where the self-sync PRBS payload is
                                    // contiguous — a nonzero WavD2DGpioRx
                                    // io_bit_slip rotates the assembled 16-bit word
                                    // and destroys PRBS bit-order, so PRBS-valid is
                                    // provably slip=0 + the right phase). Capture
                                    // the FIRST training-passing slip=0 point in
                                    // phase order; because the training-lock band
                                    // is contiguous and its LOWER EDGE coincides
                                    // with the PRBS-valid phase, this picks the
                                    // PRBS-valid (0, phase) directly instead of the
                                    // eye-CENTRE the §9.11 best_run policy would
                                    // pick (which overshoots the edge and is the
                                    // proximate cause of die_a never validating).
                                    // Try exactly ONE (0, phase) per re-sweep: the
                                    // phase the per-lane cursor points at. The
                                    // cursor walks all 16 phases mod-16 across
                                    // re-sweeps (advance logic below). PRBS
                                    // feedback pins the lane when its cursor lands
                                    // on the true PRBS-valid phase — this handles
                                    // training bands that WRAP around phase 15->0
                                    // (where the lowest sweep-order in-band phase
                                    // is NOT the PRBS-valid edge).
                                    if (pin_converge_en && cand_armed) begin
                                        if (!any_pass_valid[i] &&
                                            (sweep_slip == 3'd0) &&
                                            (sweep_phase == cand_idx[i][3:0])) begin
                                            any_pass_valid[i] <= 1'b1;
                                            any_pass_slip[i]  <= 3'd0;
                                            any_pass_phase[i] <= sweep_phase;
                                        end
                                    end else
                                    if (!any_pass_valid[i] &&
                                        (!cand_armed || (sweep_ordinal >= cand_idx[i]))) begin
                                        any_pass_valid[i] <= 1'b1;
                                        any_pass_slip[i]  <= sweep_slip;
                                        any_pass_phase[i] <= sweep_phase;
                                    end

                                    // ----- EYE-CENTRE run tracker -----------
                                    // (ported from src/ ~1281-1304). Extend or
                                    // open a contiguous-PHASE run at this slip.
                                    // On the FIRST passing phase of a new run,
                                    // remember its start phase; saturate run_len
                                    // at 5'd16 (phase axis is 16 wide). Promote
                                    // best_run when the EXTENDED run is BOTH wider
                                    // than the prior best AND clears
                                    // min_lock_dwells_eff. Run-tracking is kept
                                    // alongside the existing any_pass capture; it
                                    // feeds the S_FINALIZE eye-centre arm, which
                                    // is consulted ONLY on the first (non-cand_armed)
                                    // sweep — FIX-C re-sweeps keep using any_pass.
                                    if (run_len[i] == '0) begin
                                        cur_run_start_phase[i] <= sweep_phase;
                                    end
                                    if (run_len[i] != 5'd16) begin
                                        run_len[i] <= run_len[i] + 5'd1;
                                    end
                                    if ((run_len[i] + 5'd1) >= min_lock_dwells_eff &&
                                        (run_len[i] + 5'd1) >  best_run[i]) begin
                                        best_run[i]             <= run_len[i] + 5'd1;
                                        best_run_start_phase[i] <=
                                            (run_len[i] == '0) ? sweep_phase
                                                               : cur_run_start_phase[i];
                                        best_run_slip[i]        <= sweep_slip;
                                    end
                                    // TL-CALWRAP: circular stitch. A passing run reaching
                                    // phase 15 that connects to a passing head run from
                                    // phase 0 is ONE run on the mod-16 phase axis; promote
                                    // the stitched length so a wrap-straddling eye is NOT
                                    // split (the split undercounts best_run -> the lane
                                    // drops to the (0,0) fallback = the write-drop lottery).
                                    if ((sweep_phase == 4'd15) && (head_run_len[i] != '0) &&
                                        ((run_len[i] + 5'd1 + head_run_len[i]) >= min_lock_dwells_eff) &&
                                        ((run_len[i] + 5'd1 + head_run_len[i]) >  best_run[i])) begin
                                        best_run[i]             <= run_len[i] + 5'd1 + head_run_len[i];
                                        best_run_start_phase[i] <=
                                            (run_len[i] == '0) ? sweep_phase
                                                               : cur_run_start_phase[i];
                                        best_run_slip[i]        <= sweep_slip;
                                    end
                                end else begin
                                    // Fail — close the contiguous-phase run.
                                    run_len[i] <= '0;
                                    // TL-CALWRAP: freeze the phase-0 head-run length so a
                                    // later run reaching phase 15 can stitch the wrap.
                                    // cur_run_start_phase==0 && run_len!=0 uniquely marks
                                    // the run that began at phase 0.
                                    if ((cur_run_start_phase[i] == 4'd0) && (run_len[i] != '0) &&
                                        (head_run_len[i] == '0)) begin
                                        head_run_len[i] <= run_len[i];
                                    end
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
                            // EYE-CENTRE (ported from src/ ~1337-1340): reset
                            // run_len on the phase 15→0 wrap so a contiguous
                            // run can NEVER straddle a slip boundary (the phase
                            // axis is the real sub-bit eye dimension; a run that
                            // wrapped into the next slip would be a meaningless
                            // cross-slip artefact). best_run is preserved.
                            for (int i = 0; i < 8; i++) begin
                                run_len[i]      <= '0;
                                head_run_len[i] <= '0;
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
                        end else if ((best_run[i] >= min_lock_dwells_eff) && !cand_armed) begin
                            // EYE-CENTRE (ported from src/ ~1388-1401) — THE FIX.
                            // best_run is at least MIN_LOCK_DWELLS wide; latch the
                            // CENTRE of the widest contiguous matched phase run
                            // instead of the eye EDGE (the first any_pass point the
                            // deployed RTL previously picked). centre_off =
                            // (best_run-1)>>1 is the floor of the run midpoint;
                            // best_run<=16 so (15>>1)=7, the 4-bit truncation is safe
                            // and start+centre <= 15.
                            //
                            // PLACEMENT (no-regression rationale): this is the FIRST
                            // non-lane_done branch but is gated !cand_armed, so it
                            // fires ONLY on the first sweep. FIX-C re-sweeps
                            // (cand_armed=1) skip it and keep the EXACT cursor-floored
                            // any_pass / pin-converge selection — convergence search
                            // unchanged. Wide-eye lanes (all of die_b) move INWARD
                            // from an edge they already lock (strictly safe); narrow/
                            // no-eye lanes fall through to the identical fallbacks
                            // below. RAISING min_lock_dwells_eff disables this arm
                            // entirely (GUARD lever) → bit-identical to pre-fix.
                            automatic logic [3:0] centre_off;
                            // best_run<=16 so (best_run-1)>>1 <= 7 fits 4 bits;
                            // explicit slice keeps verilator WIDTH-clean.
                            centre_off = 4'(((best_run[i] - 5'd1) >> 1));
                            slip[i]      <= best_run_slip[i];
                            phase[i]     <= best_run_start_phase[i] + centre_off;
                            lane_done[i] <= 1'b1;
                        end else if (probe_lane_pass_q[i] && !cand_armed) begin
                            // FALLBACK 1: S_PROBE @ (0,0) verdict.
                            // No MIN_LOCK_DWELLS-wide run, but (0,0) locked
                            // during the dedicated probe dwell. Accept (0,0)
                            // — the §9.10 semantics, kept for bit-exact
                            // cocotb PHYs where (0,0) is the trivial-correct
                            // alignment.
                            //
                            // FIX C: suppressed while cand_armed — (0,0) is an
                            // excluded candidate on a re-sweep. Fall through to
                            // the cursor-floored any_pass below.
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
                        end else if (pin_converge_en && cand_armed) begin
                            // FIX-H: in pin-converge re-sweep, a lane that found
                            // no in-band candidate at its current cursor phase must
                            // NOT fault — a fault would zero sweep_success and send
                            // the FSM S_FINISH->S_ARM, bypassing S_VALIDATE so the
                            // per-lane PRBS-sync PIN can never latch. Instead park
                            // the lane at (0, cursor_phase) and mark it done (not
                            // faulted). The FSM then reaches S_VALIDATE; whichever
                            // lanes ARE PRBS-valid this window get pinned, and the
                            // rest advance their cursor on the next re-sweep. Over
                            // <=16 re-sweeps every lane's cursor visits its
                            // PRBS-valid phase and pins. Bounded by MAX_RESWEEPS.
                            slip[i]      <= 3'd0;
                            phase[i]     <= cand_idx[i][3:0];
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

                S_VALIDATE: begin
                    // -----------------------------------------------------------
                    // FIX-J: in-S_VALIDATE PRBS phase EYESCAN.
                    //
                    // PRBS is on the wire here (training_mode is LOW in
                    // S_VALIDATE). Walk every still-UNPINNED lane's DRIVEN phase
                    // across the 16 positions, dwelling EYESCAN_DWELL cycles per
                    // phase so the peer's PRBS checker can seed+sync. The existing
                    // FIX-H pin latch (always_ff below) fires the instant
                    // lane_synced_i[i] asserts, freezing pin_phase[i] at the phase
                    // currently driven — i.e. that lane's true PRBS eye, observed
                    // WITH PRBS ON THE WIRE. Pinned lanes hold pin_phase (driven
                    // by the FIX-H output path); only unpinned lanes follow the
                    // scan cursor. The scan never leaves S_VALIDATE, so it never
                    // drops the bilateral PRBS carrier between phase trials — the
                    // architectural cure for the FIX-H HW failure.
                    //
                    // Inert unless escan_en (pin_converge_en && PRBS_EYESCAN); the
                    // default build keeps the frozen-phase S_VALIDATE behaviour.
                    if (escan_en) begin
                        for (int i = 0; i < 8; i++) begin
                            // FIX-L: a lane whose PRBS checker is reporting sync
                            // (lane_synced_i[i]) must FREEZE its driven (slip,phase),
                            // NOT keep following the scan cursor. lane_synced_i[i]
                            // reflects the alignment the checker saw PRBS_SYNC_LAT+pipe
                            // cycles ago; if the cursor keeps walking phase[i]/slip[i]
                            // the pin latch (which samples the LIVE slip[i]/phase[i])
                            // captures a point AHEAD of the one that actually synced
                            // (the observed pvalid+1 off-by-one), so the lane never
                            // holds sync at the pinned point. Holding both the instant
                            // sync is observed keeps the driven alignment parked on the
                            // value that produced the sync until the pin latch (next
                            // cycle) captures it — making the pin latency-robust
                            // regardless of EYESCAN_DWELL vs sync-feedback latency.
                            // LANE-MASK: a MASKED lane stays parked at its (0,0)
                            // (set in S_ARM); the eyescan must NOT drive it with the
                            // scan cursor — it carries no PRBS so scanning it is
                            // pointless and would move it off its benign park. At
                            // lane_mask=0xFF this guard is always true (bit-identical).
                            if (lane_mask[i] && !lane_pinned[i] && !lane_synced_i[i]) begin
                                // FIX-M: drive this still-unsynced, unpinned lane at
                                // the FULL (slip,phase) scan cursor — NOT slip=0. The
                                // PRBS-valid alignment can require a NON-ZERO bit_slip
                                // (the deserialiser rotates the 16-bit window by
                                // io_bit_slip; word-boundary skew can put the
                                // contiguous-stream point at any of the 128 (slip,
                                // phase) combinations, exactly the FIX-C cand_idx
                                // space). lane_done[i] stays 1 so the output mux
                                // forwards slip[i]/phase[i] to the PHY.
                                slip[i]  <= escan_slip;
                                phase[i] <= escan_phase;
                            end
                            // else (synced-but-unpinned, or pinned): HOLD slip[i] AND
                            // phase[i] (no assignment => retain current values) so the
                            // pin captures the syncing alignment, not the next cursor
                            // step.
                        end
                        // FIX-M: per-POINT dwell, then advance the cursor over the
                        // 128-point (slip,phase) space: phase is the inner cursor
                        // (mod-16); when it wraps 15->0, advance slip (mod-8). This
                        // matches the cand_idx ordinal order {slip,phase}. The walk
                        // is CONTINUOUS across rescan windows (cursors not reset on a
                        // rescan), so a short VALIDATION_TIMEOUT still covers the
                        // whole 128-point space over successive windows while holding
                        // the carrier UP.
                        if (escan_rescan) begin
                            // In-place rescan window boundary: count the consumed
                            // window (carrier stays UP — see S_VALIDATE next-state)
                            // but DO NOT reset the (slip,phase) cursor.
                            escan_passes <= escan_passes + 1'b1;
                            if (escan_dwell_ctr >= ESCAN_MAX[$clog2(EYESCAN_DWELL+1)-1:0]) begin
                                escan_dwell_ctr <= '0;
                                escan_phase     <= escan_phase + 4'd1;
                                if (escan_phase == 4'd15) escan_slip <= escan_slip + 3'd1;
                            end else begin
                                escan_dwell_ctr <= escan_dwell_ctr + 1'b1;
                            end
                        end else if (escan_dwell_ctr >= ESCAN_MAX[$clog2(EYESCAN_DWELL+1)-1:0]) begin
                            // Per-point dwell elapsed: advance the cursor. phase
                            // mod-16 inner; slip mod-8 on the phase wrap.
                            escan_dwell_ctr <= '0;
                            escan_phase     <= escan_phase + 4'd1;
                            if (escan_phase == 4'd15) escan_slip <= escan_slip + 3'd1;
                        end else begin
                            escan_dwell_ctr <= escan_dwell_ctr + 1'b1;
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
                    // FIX-J/FIX-M: hold the eyescan cursor reset to (slip 0,
                    // phase 0) in every non-S_VALIDATE state, so each S_VALIDATE
                    // entry starts a fresh full 128-point (slip,phase) scan.
                    // (S_HOLD is the state immediately before S_VALIDATE, so this
                    // guarantees a clean start.)
                    escan_phase     <= 4'd0;
                    escan_slip      <= 3'd0;     // FIX-M
                    escan_dwell_ctr <= '0;
                    escan_passes    <= '0;
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

    // -------------------------------------------------------------------------
    // EYE-WIDTH VISIBILITY read surface (2026-06-17, ported from src/ ~1583-1586).
    // Combinational per-lane-selected read of the eye-centre run tracker. Pure
    // observability — zero datapath perturbation. best_run is EYE_WIDTH_W (5b);
    // zero-extend to 6b for the APB eye_score_best output.
    // -------------------------------------------------------------------------
    assign eye_score_best        = {1'b0, best_run             [eye_lane_sel]};
    assign eye_score_best_phase  =        best_run_start_phase [eye_lane_sel];
    assign eye_score_best_slip   =        best_run_slip        [eye_lane_sel];
    assign eye_score_lane_passed = ({1'b0, best_run[eye_lane_sel]} >= lock_thresh_6b);

endmodule
