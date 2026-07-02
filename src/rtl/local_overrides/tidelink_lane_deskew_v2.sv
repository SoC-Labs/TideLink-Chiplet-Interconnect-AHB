// -----------------------------------------------------------------------------
// tidelink_lane_deskew — SoC Labs LOCAL OVERRIDE of
// deps/tidelink-phy/rtl/tidelink_lane_deskew.sv (submodule copy stays
// pristine, same idiom as the V1 flist's local_overrides deskew). Wired in by
// flists/tidelink_fpga_v2.flist in place of the deps file. ONE functional
// deviation from the submodule:
//
//   F3c IDLE-ZERO sync_hit QUALIFIER (2026-07-02): sync_hit additionally
//   requires the captured lane word to be NONZERO. At SYNC_REANCHOR_TOL=5
//   (the 2026-06-24 marginal-eye fix) lane 0's SYNC slice 0x1F00 has
//   popcount 5 == TOL, so the ALL-ZERO inter-packet IDLE word is a
//   within-tolerance "match" on lane 0 — the anti-poison self-gating then
//   sees a CONTINUOUS match (gap resets every beat), `periodic` can never
//   assert, and lane 0 can NEVER commit sync_seen on a quiet link.
//   Sim-proven (test_31 F3 re-anchor: slave sync_seen_vec stuck 0xFE, lane 0
//   alone missing, while the peer force-beaconed for ms) and consistent with
//   the silicon zero-poke "sync_seen_vec sparse" observation. An all-zero
//   word is definitionally IDLE, never a beacon (every TIDELINK_SYNC_WORD
//   slice is nonzero, minimum popcount = 5 on lane 0); rejecting it keeps
//   the full tol-5 margin on every real capture (the only rejected "real"
//   beacon is the measure-zero capture where EXACTLY the 5 set bits all
//   flipped — which the periodic confirm run would reject anyway).
// -----------------------------------------------------------------------------
// tidelink_lane_deskew
//
// 8-lane cross-lane word-clock deskew FIFO — PRIME-AND-CONTINUOUS read controller.
//
// Each lane (gpiorx_N) deserialises 16 bits onto its own io_link_clk_N word
// clock. The eight word clocks are FREQUENCY-LOCKED (all derived ÷16 from the
// same recovered pad_clk_rx) but PHASE-SKEWED by up to ~7 word-periods. The
// Wlink RX link layer samples all eight lanes on lane-0's clock, so without
// deskew the assembled 128-bit word mixes bytes from different time-points.
//
// BIST DATAPATH NOTE (why this differs from the full-stack deskew): in the BIST
// the lane_checker oracle, the PRBS validators AND the framer ALL read this
// module's post-deskew out_data (rtl/wav/WavD2DGpio.v:338-352). So the read
// side MUST keep words flowing during TRAINING too. The writes therefore
// FREE-RUN on rst_n only (NOT gated by training_mode).
//
// READ CONTROLLER — PRIME-AND-CONTINUOUS (2026-06-04 bubble-bug fix):
//   Don't start reading until EVERY lane has built a cushion of >= PRIME_THRESH
//   buffered words (latch `primed`); then read continuously gated by all_ready.
//   The lanes are FREQUENCY-LOCKED so once primed the read rate equals the write
//   rate and each lane's occupancy holds ~PRIME_THRESH — all_ready stays HIGH,
//   zero bubbles. Priming happens once out of POR and persists (cal_swreset does
//   not reset this module), so words flow across training<->data transitions.
//   PRIME_THRESH=5: cushion > 2-flop sync latency, max occ ~12 < DEPTH 16.
//
// CDC: wr_ptr crosses to out_clk as GRAY (RX-audit Finding #2 fix, 2026-06-09).
// The write pointer is a free-running multi-bit counter in lane_clk; out_clk is
// async to it, so a plain per-bit BINARY 2-flop sync can sample the bus mid
// multi-bit transition and latch a "torn" code the counter NEVER held (e.g.
// 01111->10000 read as 11111). That spurious occupancy can drop all_ready for a
// beat -> read stall -> a duplicated/wrong post-deskew word -> a lane's PRBS
// self-sync validates momentarily then DROPS (the link_up=0 residual). A
// Gray-coded pointer changes exactly ONE bit per step, so any single-step
// transition the sync straddles resolves to either the old or the new value —
// never a torn one (standard async-FIFO CDC). The write side keeps the BINARY
// pointer for the local memory address; only the CROSSING copy is Gray. After
// gray->bin on the read side the value is bit-identical to the binary pointer,
// so the occupancy math (wr_sync_bin - rd) and prime timing are UNCHANGED.
// /tmp/deskew_repro/tb_cdc_tear.sv: 18 torn captures binary vs 0 Gray.
//
// out_valid: high on each aligned read beat (observability tap only).
//
// training_mode_i: retained for interface compatibility but UNUSED here. The
// EPOCH-anchor capture/apply are CONTENT-ONLY (fix2, 2026-06-14): the training
// exit is detected from the RX stream itself (a Hamming-streak on the constant
// pattern followed by the first data word), NOT gated on training_mode_i. That
// is deliberate: training_mode_i on this die is die_a's OWN LOCAL TX training
// signal (effective_training_mode_rx in rtl/wav/WavD2DGpio.v) — uncorrelated
// with the PEER's pattern->data edge that actually arrives on this deskew's RX
// input. The 2994848 gate keyed capture to that wrong die/clock so it never
// fired on die_a's RX (silicon B->A bring-up fail). WavD2DGpioRx does byte-
// align only — there is NO RX-stream training signal — so the exit MUST be
// content-derived. See the TRAINING-ANCHORED EPOCH PRIMING block below.
//
// -----------------------------------------------------------------------------
// SYNC-BEACON RE-ANCHOR (2026-06-08, SPEC_PHY_SYNC_BEACON §3.3, Task E) —
//   parameter-gated by SYNC_REANCHOR_EN (default 1'b0 = OFF):
//
//   The prime-and-continuous controller equalises per-lane FIFO *latency* but it
//   uses a SINGLE common read pointer, so it does NOT correct residual per-lane
//   *word-skew*: at any non-zero skew the slice each lane presents on a given
//   out_clk beat comes from a DIFFERENT write index, so a moving cross-lane word
//   is not realigned (SPEC F2 "re-anchor proven infeasible"). The re-anchor path
//   MEASURES that residual skew from the in-band SYNC beacon and corrects it.
//
//   When SYNC_REANCHOR_EN=1: each lane watches its write stream for its own SYNC
//   slice (TIDELINK_SYNC_WORD[16*gi +: 16]); on a match it latches the write
//   index the SYNC landed at (sync_wr_idx_l[gi]) + a valid flag. Those binary
//   indices CDC into out_clk through the SAME 2-flop binary-pointer pattern as
//   the write pointers (g_sync_sync mirrors g_wr_sync). Once all 8 lanes have a
//   synchronised SYNC index, the read side derives per-lane read pointers
//   rd_ptr_l[gi] = rd_base + (sync_idx[gi] - sync_ref) so that when rd_base
//   sweeps up to sync_ref EVERY lane presents its SYNC slice on the SAME beat —
//   a MEASURED alignment replacing the prime heuristic's guess.
//
//   Safety: if SYNC_REANCHOR_EN=0 the read pointer is the original single rd_ptr
//   and NONE of the new logic touches rd_ptr/out_data (bit-identical to today —
//   the regression guarantee). If enabled but no SYNC is seen on all lanes within
//   REANCHOR_TIMEOUT primed read beats, the controller FALLS BACK to the common
//   rd_ptr (never wedges). Cold-start ordering (SPEC §6 S1): the first SYNC must
//   arrive after the FIFOs have filled past the 2-flop sync latency; with DEPTH
//   16 (usable spread 13) and PRIME_THRESH 5 there is ample headroom for ~7-word
//   skew. A wrong (slip,phase) yields honest mis-alignment — the per-lane SYNC
//   slices simply never line up, so out_data never reads TIDELINK_SYNC_WORD.
// -----------------------------------------------------------------------------
// TRAINING-ANCHORED EPOCH PRIMING (2026-06-12, V37_FINAL_DIAGNOSIS fix #1) —
//   parameter-gated by EPOCH_ANCHOR_EN (default 1'b0 = OFF, bit-identical):
//
//   WHY: prime-and-continuous equalises per-lane FIFO *occupancy*, which only
//   aligns lanes whose content delay equals their word-clock phase delay. On
//   silicon the two are DECOUPLED: each lane's word clock is phase-skewed by
//   < 1 word period, but its deserialised CONTENT can lag whole word-EPOCHS
//   (3-7 on the z2_02 ribbon — slip/word-pin/capture pipeline differences). A
//   common read pointer then assembles a 128-bit word whose 16-bit slices come
//   from DIFFERENT transmitted words: per-lane training (period-1 pattern,
//   epoch-blind) locks perfectly while multi-byte packet fields straddle
//   epochs and never decode (the v37 B->A CR failure).
//
//   ANCHOR EVENT — the TRAINING EXIT edge, zero TX change: the integrated TX
//   (rtl/wav/WavD2DGpio.v) drives every lane with its CONSTANT 16-bit pattern
//   PATTERN_W[i] (USE_PRBS_TRAINING=0, USE_TAG_PAIR=1) while training, and all
//   eight per-lane serialisers drop training on the SAME word boundary
//   (common io_training_mode, per-lane word-aligned mux latch, lock-step
//   `count`). So the pattern->data content transition is a cross-lane
//   SIMULTANEOUS wire event, and at that moment every lane is LOCKED (the
//   bring-up only releases training from a held lk=ff state), i.e. its
//   slip/phase decode is correct. Training ENTRY is NOT usable: lanes acquire
//   lock mid-sweep at per-lane times, so the first pattern-match is not a
//   common event. Mid-window the pattern is period-1 and carries no epoch
//   information at all — only the exit edge does.
//
//   WRITE SIDE (per lane, lane_clk) — CONTENT-ONLY (fix2, 2026-06-14): a
//   Hamming matcher scores each incoming word against PATTERN_W[i] (dist <=
//   EPOCH_MATCH_THRESH counts as the pattern; dist >= 16-THRESH covers a pair-
//   swapped lane seeing ~P). A saturating streak counter qualifies the match
//   run; on the first NON-match after a streak >= EPOCH_STREAK_MIN the lane
//   latches wr_ptr_l (the index the first DATA word is written at) into
//   ep_anchor_idx and increments ep_anchor_cnt. This fires on the PEER's real
//   pattern->data edge as it arrives IN-BAND on the RX stream — which is what
//   training_mode_i (this die's OWN local TX training, see top-of-file note)
//   could NOT observe. LAST-QUALIFIED-EDGE-WINS self-healing: a corrupted word
//   mid-training fakes an exit, but the streak rebuilds and the TRUE exit
//   overwrites the anchor; in data mode a >=STREAK_MIN run of pattern-close
//   words is ~(0.2)^8 per position, and a single spurious lane cannot apply
//   (all-fresh + settle + span gates). Each new training window re-arms
//   naturally (the streak rebuilds and the freshness counter advances).
//
//   READ SIDE (out_clk): epoch_anchored is STICKY once engaged (c332722
//   behaviour, safe: offsets only ever re-load on a NEW coherent, all-fresh,
//   span-OK set, and a fresh training window advances the per-lane freshness
//   counters). anchor idx+cnt cross on 2-flop syncs (values are
//   captured-static well before use — the settle window below guarantees the
//   bus is quiescent when read). When ALL lanes are FRESH since the
//   last application (all-fresh, counter-compare — one stale/dead/masked lane
//   vetoes; a noise double-capture still reads fresh) and the
//   synced bus has been stable for EPOCH_SETTLE beats (> max skew + sync
//   latency), per-lane offsets are computed from anchor-index DIFFERENCES
//   (wrap-safe: deltas vs lane 0 interpreted as PW-bit signed, true span
//   <= ~9 << 2^(PW-1)) and latched: lane_off_e[i] = max_delta - delta[i] >= 0,
//   so every lane reads AT or BEHIND the common rd_ptr — always inside
//   already-written data. A span > EPOCH_OFF_MAX (= DEPTH-PRIME_THRESH-3,
//   the overwrite-safety budget: entry age = occupancy + offset must stay
//   < DEPTH) REJECTS the application and keeps the previous offsets (never
//   wedges, never tears the FIFO). Offsets hold latched through data mode and
//   are replaced only by the next complete training-exit measurement.
//
//   WHY APPLYING AT EXIT IS SAFE (vs the SYNC re-anchor's mid-stream shift):
//   the offset load lands EPOCH_SETTLE+~spread beats after training exit —
//   inside the idle gap between training drop and the (SW-triggered, much
//   later) FCSM CR bootstrap — so no live framing exists to disrupt. The
//   pattern is period-1, so offsets are also invisible to the lane_checker
//   during training.
// -----------------------------------------------------------------------------

`default_nettype none

// Single source of truth for the cross-lane SYNC beacon constant. Included at
// $unit scope (matching tidelink_training_patterns.svh) so TIDELINK_SYNC_WORD is
// visible to this module and persists for later files in a single-comp-unit
// build; the guard makes a repeat include in another file a harmless no-op.
`include "tidelink_sync_word.svh"
// Per-lane constant training words (PATTERN_W[i] = P/~P, P=0x12EB) — the
// epoch-anchor matcher reference. Same $unit-scope include idiom + guard as
// tidelink_sync_word.svh above.
`include "tidelink_training_patterns.svh"

module tidelink_lane_deskew #(
    parameter int LANES     = 8,
    parameter int WIDTH     = 16,
    // FIFO depth = 1<<DEPTH_LOG. V37-robust: 5 => DEPTH 32 (was 4 => 16), so
    // EPOCH_OFF_MAX = DEPTH-PRIME_THRESH-3 = 24 (was 8) — 3x epoch-skew margin
    // on the marginal silicon eye (z2 ribbon spans up to ~9 words; the old
    // budget of 8 vetoed any spread that drifted past it -> silent zero-offset
    // fallback). DEPTH/ptr-width (PW=DEPTH_LOG+1) all derive from this.
    parameter int DEPTH_LOG = 5,           // FIFO depth = 1<<DEPTH_LOG = 32 entries
    // SYNC-beacon deterministic re-anchor. Default OFF => bit-identical to the
    // pre-beacon module (regression guarantee). See header + SPEC §3.3.
    parameter bit SYNC_REANCHOR_EN = 1'b0,
    // Per-lane SYNC-slice Hamming tolerance for the re-anchor's write-side
    // sync_seen capture (2026-06-22 marginal-eye fix). The g_sync_capture
    // matcher latches sync_seen when popcount(slice ^ sync_slice) <=
    // SYNC_REANCHOR_TOL, mirroring the framer's TOLERANT sync_detect
    // (tidelink_phy_sync_detect eff_tol; WlinkRxLinkLayer sync_detect) so the
    // re-anchor is no STRICTER than the framer it feeds — the bug this fixes was
    // an EXACT `==` here that NEVER fired on the marginal silicon eye (measured
    // ~4-bit Hamming distance: RX 0x4bac vs SYNC L2 0x5b4c = dist 4) while the
    // framer matched at tol=5 (APB SWI_SYNC_TOL 0x2128=0x5e4).
    //
    // DEFAULT 4, NOT 5 (and WHY it differs from the framer's 5): the framer's
    // detector qualifies its tolerant per-lane compares with a CROSS-LANE
    // simultaneous AND over all masked-in lanes on ONE out_clk beat (see
    // tidelink_phy_sync_detect: mask_full_match = &(lane_match | ~lane_mask)).
    // That joint qualifier drops its payload false-fire rate to ~2^-(16*popcnt),
    // so tol=5 is safe THERE. This deskew capture is a PER-LANE, ONE-SHOT,
    // FIRST-ARRIVAL latch in each lane's OWN write clock (the eight lanes are on
    // different lane_clk's, so a clean cross-lane AND is not available on the
    // write side). A per-lane one-shot at tol=5 latches on the FIRST payload word
    // that lands within 5 bits of that lane's slice; the unit test's dense
    // low-12-bit counter payload (0xA000|t) DOES put one lane (lane5, slice
    // 0xB5A6) within 5 bits early (sim-proven: latches a DATA index at k=1-4 ->
    // wrong offset -> never coheres). tol=4 covers the full measured silicon
    // margin (dist 4) AND is payload-clean on every regression scenario
    // (sim-proven: 0 payload false-fires at tol<=4; lane5 false-fires only at
    // tol=5). So 4 is the largest tolerance that BOTH engages on the marginal eye
    // AND stays payload-safe under a per-lane one-shot latch. An operator needing
    // the framer's full 5 must accept the higher per-lane false-fire odds (raise
    // this param) or add a cross-lane qualifier to the capture (future work).
    // At SYNC_REANCHOR_TOL=0 the compare reduces to the historical exact ==
    // (popcount <= 0 iff xor==0) — bit-identical to the pre-fix module.
    parameter int unsigned SYNC_REANCHOR_TOL = 4,
    // SELF-GATING periodic-confirm depth (2026-06-23, sticky-poison PRIMARY fix).
    // K = number of CONSECUTIVE SYNC-slice matches that must recur at a CONSISTENT
    // periodic write-index (same residue mod SYNC_PERIOD, exactly one period apart,
    // no intervening match) before the per-lane sync_seen_l / sync_idx_l commit.
    // The real SYNC beacon recurs every SYNC_PERIOD words at a fixed phase, so it
    // satisfies the gate; sporadic or continuous pre-SYNC POISON does not (a
    // continuous within-tol stream keeps the gap counter from saturating, so the
    // periodic re-match never fires). This is the proven WavD2DGpioRx wpa pattern
    // (WPA_CONFIRM=3) mirrored into the deskew lane_clk domain. NEEDS NO external
    // enable / SW pulse, so a broken APB->PHY clear path cannot defeat it.
    //   K=2 (default — KEPT at 2 when the periodic confirm was loosened to the
    //        windowed index compare SYNC_IDX_TOL below, NOT raised to 3). The
    //        widened residue window does add a small SPORADIC-coincidence surface
    //        (a non-periodic within-tol word could coincidentally re-match ~one
    //        period later inside the +/-TOL arc), which a deeper K would harden.
    //        BUT the load-bearing anti-poison gate — a CONTINUOUS within-tol stream
    //        keeps the gap from ever saturating, so the periodic re-match NEVER
    //        fires — is INDEPENDENT of K and already rejects the proven poison at
    //        K=2 (the unit poison tests pass at K=2). And raising K is actively
    //        COUNTER-productive on silicon for a different, MEASURED reason: real
    //        payload is arbitrary user data and ~7% of 16-bit words land within
    //        tol=4 of some lane's SYNC slice (e.g. 299/4096 for lane5's 0xB5A6),
    //        so each per-lane matcher takes frequent payload FALSE-FIRES that reset
    //        the gap and disrupt the confirm run. A DEEPER confirm (more consecutive
    //        clean periodic re-matches required) is MORE easily broken by that
    //        payload noise — measured: at K=3 lane5 fails to arm under the
    //        0xA000-base payload that K=2 tolerates. So K=2 is the most payload-
    //        robust depth that still rejects the continuous poison and tolerates the
    //        index jitter. (A future cross-lane qualifier on the capture, like the
    //        framer's joint AND, would let K rise safely; out of scope here.)
    //   K=3+: TWO+ periodic re-confirms. Hardens the sporadic-coincidence case but,
    //        per the above, is LESS robust to real within-tol payload noise. Use
    //        only with a tighter SYNC_REANCHOR_TOL or a payload-clean link.
    //   K=1: DEGENERATE first-arrival latch (the historical behaviour) — used by
    //        the unit-test NEGATIVE control to show the poison STILL breaks the
    //        link without the consecutive-consistent gate. Capped at 7 (3-bit
    //        confirm counter); a value > the link's available periodic SYNC count
    //        would never commit, so keep it small.
    parameter int unsigned SYNC_CONFIRM = 2,
    // PERIODIC-CONFIRM INDEX JITTER TOLERANCE (2026-06-23, silicon jitter fix).
    // The self-gating arm's periodic re-match was an EXACT residue compare
    // (wr_res == sync_cand_res, exactly GAP_MAX non-matches apart). On SILICON the
    // per-lane recovered word-clock PHASE WANDERS, so the write-index residue at
    // successive SYNC arrivals JITTERS by +/-1-2 word-epochs and the EXACT compare
    // almost never re-confirms (measured via the 0x215C sync_seen_vec obs: only
    // 0-1 of 4 active lanes arm, sync_seen_vec=0x00 or 0x40, while the framer's
    // own per-lane detector 0x2144 reaches 0xe5 — the lanes DO carry SYNC). This
    // tolerance widens BOTH jitter axes of the periodic re-match by +/-SYNC_IDX_TOL:
    //   * INDEX axis: the candidate residue match becomes a CIRCULAR-distance
    //     window |wr_res - sync_cand_res| (mod SYNC_PERIOD) <= SYNC_IDX_TOL instead
    //     of exact equality (re-centered to the latest residue on each confirm so
    //     slow monotonic drift cannot walk out of a fixed window).
    //   * TIMING axis: the gap-saturate gate becomes a WINDOW [GAP_MAX-TOL,
    //     GAP_MAX+TOL] (early/late arrival by +/-TOL non-match words) instead of a
    //     point at GAP_MAX, and the run-break grace is extended to GAP_MAX+TOL so a
    //     late SYNC does not break the confirm run.
    // BOTH axes move with the SAME clock wander, so a single +/-TOL tolerance on
    // each models +/-TOL word-epochs of phase jitter.
    //
    // THE ANTI-POISON PROPERTY IS PRESERVED AND INDEPENDENT OF THIS WINDOW: the
    // load-bearing gate is that the gap counter must reach ~one SYNC_PERIOD of
    // NON-match between periodic confirms. A CONTINUOUS within-tol poison stream
    // (the unit-test model) matches EVERY beat, so sync_gap RESETS to 0 on every
    // beat and can NEVER reach even GAP_MAX-TOL (= 29 at the default) -> the
    // periodic gate never fires regardless of how wide the INDEX window is. Widening
    // SYNC_IDX_TOL therefore does NOT re-open the continuous-poison hole (VERIFIED
    // in the unit test: test_exp2*_poison still rejects poison at SYNC_IDX_TOL=2).
    //
    // DEFAULT 2 (covers the measured +/-1-2 residue jitter). Elab guard: must be
    // < SYNC_PERIOD/2 (a window wider than half a period would wrap and accept
    // every residue, defeating the periodic phase identity). At SYNC_IDX_TOL=0 the
    // residue window reduces to exact equality and the gap window to a point at
    // GAP_MAX -> bit-identical to the pre-jitter EXACT self-gating arm.
    parameter int unsigned SYNC_IDX_TOL = 2,
    // SYNC insertion period (link words between SYNC beacons) the self-gating arm
    // expects the SYNC to recur at. Defaults to TIDELINK_SYNC_PERIOD (32) from the
    // $unit include — the SAME default the inserter/detector use
    // (tidelink_phy_sync_insert / tidelink_phy_sync_detect). The periodic-confirm
    // gate keys on wr_ptr_l mod SYNC_PERIOD; it MUST match the TX cadence.
    parameter int unsigned SYNC_PERIOD = TIDELINK_SYNC_PERIOD,
    // Training-anchored cross-lane word-EPOCH priming (V37 fix #1). Default
    // OFF => bit-identical to the pre-epoch module (regression guarantee).
    // Mutually exclusive with SYNC_REANCHOR_EN (elab guard below). See the
    // TRAINING-ANCHORED EPOCH PRIMING header block.
    parameter bit EPOCH_ANCHOR_EN = 1'b0,
    // Anchor matcher Hamming budget: dist(word, PATTERN_W[i]) <= THRESH is
    // "still training pattern" (and >= 16-THRESH covers an inverted pair).
    // Must be < 8 so an idle 0x0000 word (dist 8 from both P and ~P) is a
    // clean NON-match. 3 tolerates per-word noise without false exits.
    parameter int unsigned EPOCH_MATCH_THRESH = 3,
    // Consecutive pattern matches required before a falling edge qualifies as
    // a training-exit anchor (anti-alias against pattern-close data words).
    parameter int unsigned EPOCH_STREAK_MIN  = 8,
    // out_clk beats the synced anchor bus must be stable (with all lanes
    // fresh) before offsets load. Must exceed max inter-lane exit spread
    // (~9 words) + 2-flop sync latency; 32 gives >3x margin.
    parameter int unsigned EPOCH_SETTLE     = 32,
    // Multi-sample training-exit confirmation (fix3, 2026-06-15). The write-side
    // capture must see EPOCH_EXIT_CONFIRM CONSECUTIVE non-match words before it
    // latches the anchor — the index snapshotted is the FIRST non-match (= true
    // exit + 0, alignment-exact). A single corrupted late-training word (a bit-
    // error burst on a marginal eye) reads as one non-match while the streak is
    // already >= STREAK_MIN, which previously faked the exit edge EARLY and gave
    // that lane a wrong ep_anchor_idx. Requiring K real data words after the
    // streak filters that glitch: the next legitimate pattern word aborts the
    // pending confirmation, but the REAL exit is permanent data so it always
    // qualifies.
    //
    // fix4 (2026-06-15): K reduced 4 -> 2 and the HARD abort-on-any-match is
    // replaced by a SOFT abort (see g_epoch_capture). K=4 made the anchor
    // UNREACHABLE on a cleanly-locked eye: the only non-matches there are
    // isolated single-word bit errors, so a lone non-match opened the window and
    // the very next (pattern) word hard-reset ep_confirm to 0 -> the window never
    // reached 4 -> never committed (die_a anc=0 on silicon, die_b a noisier eye
    // anchored with a garbage growing span). The soft abort tolerates a SINGLE
    // isolated intervening match inside an open window; only TWO CONSECUTIVE
    // matches (= the training pattern has genuinely resumed) abort it. A lone
    // corrupted training-exit word still produces 1 non-match then RESUMING
    // pattern (>=2 consecutive matches) -> abort -> no premature mis-anchor (the
    // property K was added to guard). A REAL exit = permanent data = >=2 non-
    // matches -> commit. die_a's sparse post-exit stream (occasional isolated
    // pattern-like word among data) -> isolated matches forgiven -> commit.
    parameter int unsigned EPOCH_EXIT_CONFIRM = 2
) (
    input  wire                          rst_n,         // async reset, active low
    input  wire [LANES-1:0]              lane_clk,
    input  wire [LANES*WIDTH-1:0]        lane_data,
    input  wire                          training_mode_i, // interface-compat (unused; content-only anchor)
    // REDUCED-LANE link (2026-06-17): per-lane ACTIVE mask, 1 = lane in use.
    // Mirrors the calibrator / sync-detect / Wlink RX gather lane_mask idiom
    // (& lane_mask, | ~lane_mask). A masked-out (0) lane's FIFO may never fill
    // (dead/marginal/garbage conductor) — its occupancy MUST NOT gate the word
    // read, and the epoch-anchor cross-lane consensus MUST exclude it. At the
    // default 0xFF (every lane active) every `| ~lane_mask` term is 0 and every
    // `& lane_mask` term is 1, so the readiness + anchor expressions reduce
    // EXACTLY to the pre-mask behaviour — BIT-IDENTICAL (regression guarantee).
    input  wire [LANES-1:0]              lane_mask,
    input  wire                          out_clk,
    // STICKY-POISON RE-ARM CLEAR (2026-06-23, sync_seen poison fix). A 1-cycle
    // pulse (out_clk domain) that re-arms the per-lane SYNC re-anchor capture:
    // it clears sync_seen_l + sync_idx_l on EVERY lane AND drops the read-side
    // `reanchored` latch, so the NEXT clean SYNC (now flowing in data mode after
    // force_always) is captured at its TRUE per-lane index instead of a pre-SYNC
    // poison word grabbed out of POR. Routed from WavD2DGpio's sync_obs_clr_pulse
    // (the SW W1-pulse SoC 0x44032100[5], already CDC'd to gpiorx_0_io_link_clk =
    // this out_clk and edge-detected to one cycle). Held 0 => bit-identical to the
    // pre-fix module (the clear term is inert and synthesises away under
    // SYNC_REANCHOR_EN=0). See the g_sync_capture re-arm block below.
    input  wire                          sync_obs_clr_i,
    output logic [LANES*WIDTH-1:0]       out_data,
    output logic                         out_valid,       // aligned read beat (obs tap)
    // Engagement observables (V37-robust fix #4): epoch_anchored_o = offsets
    // measured & active; epoch_span_o = the last measured cross-lane epoch span
    // (in words). Both are 0 unless EPOCH_ANCHOR_EN. Route to a PHY status
    // register through WlinkGPIOPHY/WavD2DGpio for silicon bring-up visibility;
    // unconnected (pruned) where not consumed.
    output logic                         epoch_anchored_o,
    output logic [DEPTH_LOG:0]           epoch_span_o,
    // STICKY-POISON OBSERVABILITY (2026-06-23). Per-lane out_clk-synced sync_seen
    // vector — surfaces to APB (SoC 0x44032140 bits[14:7]; see WavD2DGpio status
    // mapping) so silicon can distinguish 'no lane latched' (0x00) from 'latched
    // inconsistent indices' (set but never coherent) from 'latched + coherent'.
    // 0 unless SYNC_REANCHOR_EN (the g_reanchor / g_sync_sync blocks are pruned).
    output logic [LANES-1:0]             sync_seen_vec_o,
    // DATA-MODE per-lane SYNC HAMMING-DISTANCE OBS (SoC Labs 2026-06-25, the
    // winscan metric). Per-lane 5-bit live Hamming distance of the most-recent
    // incoming word to that lane's SYNC slice — the SAME sync_dist_w the
    // g_sync_capture sync_hit (<= SYNC_REANCHOR_TOL) is derived from. Registered
    // in lane_clk then 2-flop-synced into out_clk (mirrors sync_seen_vec_o).
    // Lane L at [5L +: 5]. This is the DATA-mode per-lane eye-quality metric the
    // winscan centres the IDELAY tap on (training dist_raw=0 / livematch
    // saturates / sync_seen re-arm is broken — none give a usable DATA-mode
    // gradient; this distance does). 0 unless SYNC_REANCHOR_EN (the capture
    // block is pruned). READ-ONLY: no existing net is rewired by adding it, so
    // the datapath is bit-identical.
    output logic [LANES*5-1:0]           sync_dist_vec_o
);
    localparam int DEPTH        = 1 << DEPTH_LOG;
    localparam int PRIME_THRESH = 5;   // cushion before first read (see header)
    localparam int PW           = DEPTH_LOG + 1;   // pointer width (binary & gray)

    // Epoch-anchor overwrite-safety budget: a lane reading rd_ptr - off sees
    // an entry of age (occupancy + off); steady occupancy is PRIME_THRESH with
    // up to ~3 beats of CDC/prime slack, so off (and therefore the measured
    // anchor SPAN) must stay <= DEPTH - PRIME_THRESH - 3 (= 24 at DEPTH 32).
    localparam int EPOCH_OFF_MAX = DEPTH - PRIME_THRESH - 3;

    // Elaboration guards (mirrors tidelink_phy_align_if): the epoch anchor is
    // hand-rolled for the 8x16 GPIO PHY and shares rd_ptr_l with the SYNC
    // re-anchor — refuse configs no implementation supports instead of
    // silently elaborating them.
    initial begin
        if (EPOCH_ANCHOR_EN && SYNC_REANCHOR_EN)
            $fatal(1, "tidelink_lane_deskew: EPOCH_ANCHOR_EN and SYNC_REANCHOR_EN are mutually exclusive");
        if (EPOCH_ANCHOR_EN && (LANES != 8 || WIDTH != 16))
            $fatal(1, "tidelink_lane_deskew: EPOCH_ANCHOR_EN requires LANES=8/WIDTH=16 (got %0d/%0d)", LANES, WIDTH);
        if (EPOCH_ANCHOR_EN && (EPOCH_OFF_MAX < 7))
            $fatal(1, "tidelink_lane_deskew: EPOCH_ANCHOR_EN needs DEPTH_LOG>=4 (EPOCH_OFF_MAX=%0d < 7)", EPOCH_OFF_MAX);
        if (EPOCH_ANCHOR_EN && (EPOCH_MATCH_THRESH >= 8))
            $fatal(1, "tidelink_lane_deskew: EPOCH_MATCH_THRESH=%0d must be < 8 (idle-word rejection)", EPOCH_MATCH_THRESH);
        if (EPOCH_ANCHOR_EN && (EPOCH_STREAK_MIN < 2 || EPOCH_STREAK_MIN > 15))
            $fatal(1, "tidelink_lane_deskew: EPOCH_STREAK_MIN=%0d outside [2,15] (4-bit saturating streak)", EPOCH_STREAK_MIN);
        if (EPOCH_ANCHOR_EN && (EPOCH_EXIT_CONFIRM < 1 || EPOCH_EXIT_CONFIRM > 7))
            $fatal(1, "tidelink_lane_deskew: EPOCH_EXIT_CONFIRM=%0d outside [1,7] (3-bit confirm counter)", EPOCH_EXIT_CONFIRM);
        // SYNC_REANCHOR_TOL must stay <= 7: the SYNC slices form a unique
        // descending-nibble ramp, but a per-lane tolerance >= 8 would accept
        // ~half of all 16-bit words (popcount <= 8 covers > 50% of the space)
        // and the per-lane sync_seen would false-fire on payload. The framer
        // sweeps 0..5; cap the budget the same.
        if (SYNC_REANCHOR_EN && (SYNC_REANCHOR_TOL > 7))
            $fatal(1, "tidelink_lane_deskew: SYNC_REANCHOR_TOL=%0d must be <= 7 (payload false-fire)", SYNC_REANCHOR_TOL);
        // SYNC_CONFIRM in [1,7]: 1 = degenerate first-arrival latch (negative
        // control); >1 = self-gating periodic-confirm run; <= 7 (3-bit counter).
        if (SYNC_REANCHOR_EN && (SYNC_CONFIRM < 1 || SYNC_CONFIRM > 7))
            $fatal(1, "tidelink_lane_deskew: SYNC_CONFIRM=%0d outside [1,7] (3-bit confirm counter)", SYNC_CONFIRM);
        // SYNC_PERIOD must be a power of two: the self-gating residue is taken as
        // the low bits of the binary write pointer (wr_ptr_l mod SYNC_PERIOD =
        // wr_ptr_l[SPW-1:0]). A non-power-of-two period would need a real modulo
        // (and the periodic scheme's phase identity would not align to a bit slice).
        if (SYNC_REANCHOR_EN && (SYNC_PERIOD < 2 || ((SYNC_PERIOD & (SYNC_PERIOD - 1)) != 0)))
            $fatal(1, "tidelink_lane_deskew: SYNC_PERIOD=%0d must be a power of two >= 2 (residue = low ptr bits)", SYNC_PERIOD);
        // SYNC_IDX_TOL must stay < SYNC_PERIOD/2: the periodic re-match is a
        // CIRCULAR residue window mod SYNC_PERIOD, so a tolerance >= half the period
        // wraps and accepts EVERY residue (the phase identity that distinguishes the
        // periodic SYNC from off-phase noise collapses). It also bounds the gap
        // window [GAP_MAX-TOL, GAP_MAX+TOL] safely inside one period. 0 = exact
        // (degenerate to the pre-jitter EXACT arm).
        if (SYNC_REANCHOR_EN && (SYNC_IDX_TOL >= (SYNC_PERIOD / 2)))
            $fatal(1, "tidelink_lane_deskew: SYNC_IDX_TOL=%0d must be < SYNC_PERIOD/2=%0d (circular residue window wraps)", SYNC_IDX_TOL, SYNC_PERIOD / 2);
    end

    // Gray <-> binary helpers for the write-pointer CDC (Finding #2 fix).
    // bin2gray: g = b ^ (b>>1). gray2bin: b[i] = ^(g >> i) (XOR-prefix). Pure
    // combinational, width-parametric over the full PW-bit pointer.
    function automatic logic [PW-1:0] bin2gray(input logic [PW-1:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction
    function automatic logic [PW-1:0] gray2bin(input logic [PW-1:0] g);
        logic [PW-1:0] b;
        int unsigned i;
        begin
            b = g;
            for (i = 1; i < PW; i = i + 1) b = b ^ (g >> i);
            gray2bin = b;
        end
    endfunction

    // (TIDELINK_SYNC_WORD comes from tidelink_sync_word.svh, included at $unit
    // scope above.)

    // training_mode_i unused here (writes free-run; read primes once). The EPOCH
    // anchor is CONTENT-ONLY (fix2, 2026-06-14): the 2994848 hardening gated the
    // capture on training_mode_i, but that wire is die_a's OWN LOCAL TX training
    // signal (effective_training_mode_rx, WavD2DGpio.v) — it is uncorrelated with
    // the PEER's RX-stream pattern->data edge that actually appears on this
    // deskew's RX input, so the gate never fired on die_a's RX and the anchor
    // never engaged (silicon B->A bring-up fail). WavD2DGpioRx does byte-align
    // only — there is NO RX-stream-derived training signal in the RTL — so the
    // exit must be detected from CONTENT (the Hamming-streak on the pattern), as
    // in c332722. Tie off training_mode_i for lint.
    wire _unused_training = training_mode_i;

    logic [DEPTH_LOG:0] rd_ptr;   // common read pointer (out_clk), binary
    logic               primed;   // read-side prime latch (persists after POR)

    // Only the GRAY write pointer crosses to out_clk now (Finding #2). The binary
    // pointer wr_ptr_l stays LOCAL to each lane's write generate (memory address +
    // re-anchor SYNC-index capture); it no longer needs a flattened export.
    logic [DEPTH_LOG:0] wr_gray_flat [LANES];   // per-lane GRAY write pointer (CDC copy)
    logic [WIDTH-1:0]   rd_word      [LANES];    // FIFO entry at this lane's read ptr
    logic [DEPTH_LOG:0] rd_ptr_l     [LANES];    // per-lane read pointer (==rd_ptr if OFF)

    // --- re-anchor: per-lane measured SYNC write-index + valid, write-clock side.
    // Tied to constants under SYNC_REANCHOR_EN=0 so synthesis prunes them and the
    // module is bit-identical to the pre-beacon version.
    logic [DEPTH_LOG:0] sync_wr_idx_flat [LANES];  // write index the SYNC landed at
    logic [LANES-1:0]   sync_seen_flat;            // this lane has captured a SYNC
    // DATA-MODE SYNC Hamming-distance obs (2026-06-25): per-lane live distance of
    // the most-recent incoming word to that lane's SYNC slice, registered in
    // lane_clk. Tied 0 under SYNC_REANCHOR_EN=0 (capture pruned) so it adds no
    // logic in the OFF/EPOCH builds.
    logic [4:0]         sync_dist_flat [LANES];

    // --- epoch anchor: per-lane training-exit write-index + freshness COUNTER,
    // write-clock side. A counter (not a toggle) so a double capture (noise-faked
    // exit overwritten by the true exit) still reads FRESH on the read side.
    // Tied to constants under EPOCH_ANCHOR_EN=0 so synthesis prunes them
    // (regression guarantee — same idiom as the SYNC nets above).
    logic [DEPTH_LOG:0] ep_anchor_idx_flat [LANES]; // write index of the FIRST data word
    logic [2:0]         ep_anchor_cnt_flat [LANES]; // increments on each qualified capture

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane_write
            logic [WIDTH-1:0]   mem_l [DEPTH];
            logic [DEPTH_LOG:0] wr_ptr_l;
            logic [DEPTH_LOG:0] wr_gray_l;   // registered Gray copy for the CDC

            // Free-run: capture one word per lane-clock edge (training words flow
            // too — the post-deskew lane_checker depends on it). Maintain a
            // registered GRAY copy of the (post-increment) write pointer so the
            // value crossing to out_clk changes exactly ONE bit per step
            // (Finding #2: a binary multi-bit CDC can latch a torn code).
            always_ff @(posedge lane_clk[gi] or negedge rst_n) begin
                if (!rst_n) begin
                    wr_ptr_l  <= '0;
                    wr_gray_l <= '0;
                end else begin
                    mem_l[wr_ptr_l[DEPTH_LOG-1:0]] <= lane_data[gi*WIDTH +: WIDTH];
                    wr_ptr_l  <= wr_ptr_l + 1'b1;
                    wr_gray_l <= bin2gray(wr_ptr_l + 1'b1);   // Gray of next binary value
                end
            end

            assign wr_gray_flat[gi] = wr_gray_l;
            assign rd_word[gi]      = mem_l[rd_ptr_l[gi][DEPTH_LOG-1:0]];

            // --- re-anchor SYNC-arrival capture (write side) -------------------
            // Latch the write INDEX (pre-increment wr_ptr_l = the address the word
            // is being written to this edge) the first time this lane's incoming
            // word equals its SYNC slice. Persisted (first-arrival anchor); cold
            // re-arm is not needed for a one-shot measured alignment.
            if (SYNC_REANCHOR_EN) begin : g_sync_capture
                logic [DEPTH_LOG:0] sync_idx_l;
                logic               sync_seen_l;
                // STICKY-POISON RE-ARM (2026-06-23). The 1-cycle clear pulse
                // sync_obs_clr_i arrives in out_clk (= gpiorx_0_io_link_clk = lane
                // 0's word clock). The eight lane word clocks are FREQUENCY-LOCKED
                // (all div-16 from the same recovered pad_clk_rx — see header), so
                // out_clk and this lane_clk[gi] are the SAME frequency, only
                // phase-skewed: a 2-flop synchroniser + rising-edge detect in this
                // lane's clock reliably captures the pulse exactly once (the
                // identical CDC idiom WavD2DGpio already uses to bring this same
                // APB W1-pulse into the RX link clock). On the re-arm edge the
                // per-lane sync_seen_l + sync_idx_l reset to their POR values, so
                // the NEXT clean SYNC slice (now flooding in data mode after
                // force_always) is captured at its TRUE write index instead of a
                // pre-SYNC poison word grabbed out of POR. Held 0 => clr_pulse_l
                // never fires and this is bit-identical to the first-arrival latch.
                logic clr_meta_l, clr_sync_l, clr_d_l;
                always_ff @(posedge lane_clk[gi] or negedge rst_n) begin
                    if (!rst_n) begin
                        clr_meta_l <= 1'b0;
                        clr_sync_l <= 1'b0;
                        clr_d_l    <= 1'b0;
                    end else begin
                        clr_meta_l <= sync_obs_clr_i;
                        clr_sync_l <= clr_meta_l;
                        clr_d_l    <= clr_sync_l;
                    end
                end
                wire clr_pulse_l = clr_sync_l & ~clr_d_l;   // 1-cycle re-arm
                wire  [WIDTH-1:0]   sync_slice = TIDELINK_SYNC_WORD[gi*WIDTH +: WIDTH];
                // TOLERANT sync_seen match (2026-06-22 marginal-eye fix). The
                // historical compare was an EXACT `==`; on SILICON the captured
                // SYNC slice is MARGINAL (measured ~4-bit Hamming distance from
                // the slice, e.g. RX 0x4bac vs L2 0x5b4c = dist 4) so `==` NEVER
                // fired -> all_sync_seen never asserted -> reanchored never
                // engaged. The FRAMER (tidelink_phy_sync_detect / WlinkRxLinkLayer)
                // uses a tolerant popcount(slice ^ SYNC) <= tol (tol=5 on silicon),
                // so the re-anchor was STRICTER than the framer it feeds. Reuse the
                // SAME tidelink_popcount16 the EPOCH matcher uses and match within
                // SYNC_REANCHOR_TOL (default 5 = the framer's tol). At TOL=0 this
                // reduces to popcount<=0 <=> exact == (regression-identical).
                wire [WIDTH-1:0] sync_xor = lane_data[gi*WIDTH +: WIDTH] ^ sync_slice;
                wire [4:0]       sync_dist_w;
                tidelink_popcount16 u_sync_pop (.x(sync_xor), .count(sync_dist_w));
                // F3c (2026-07-02, LOCAL OVERRIDE — see file header): reject
                // the all-zero IDLE word. Lane 0's slice 0x1F00 popcount(5)
                // == TOL(5), so idle-zeros continuously "match" on lane 0 and
                // the gap-reset anti-poison then blocks the periodic confirm
                // forever (post-clear sync_seen starvation, sim-proven).
                wire sync_hit = (sync_dist_w <= SYNC_REANCHOR_TOL[4:0])
                              && (|lane_data[gi*WIDTH +: WIDTH]);

                // ===========================================================
                // SELF-GATING PERIODIC-CONFIRM ARM (2026-06-23, sticky-poison
                // PRIMARY fix — no SW routing). Mirrors the proven confirm-run
                // logic in WavD2DGpioRx g_word_pin_auto (wpa_cand_q / wpa_conf_q
                // / wpa_gap_q, WPA_CONFIRM=3): a SYNC-slice match only commits
                // sync_idx_l / sync_seen_l after SYNC_CONFIRM CONSECUTIVE matches
                // that recur at a CONSISTENT periodic index — i.e. exactly
                // SYNC_PERIOD lane_clk edges apart, at the same write-index
                // residue (wr_ptr_l mod SYNC_PERIOD), with NO intervening match.
                //
                // WHY THIS REJECTS THE PRE-SYNC POISON (the silicon defect): the
                // real SYNC beacon recurs ONCE every SYNC_PERIOD words at a FIXED
                // phase, so between two SYNCs there are SYNC_PERIOD-1 non-matching
                // payload words and the gap counter SATURATES — the next SYNC is a
                // periodic re-match (gap == SYNC_PERIOD-1) at the SAME residue, so
                // the confirm run advances. Pre-SYNC poison is NOT periodic at the
                // SYNC phase: a one-off within-tol word never re-matches a period
                // later (gap never reaches SYNC_PERIOD-1 with the same residue ->
                // run stays 0), and a CONTINUOUS within-tol stream (e.g. a constant
                // poison word, the unit-test model) matches EVERY edge so the gap
                // RESETS to 0 each beat and NEVER saturates -> gap == SYNC_PERIOD-1
                // is never true -> the run never advances -> sync_seen_l stays 0
                // through the whole poison window. Only the genuine periodic SYNC
                // satisfies the gate, so no SW clear and no APB->PHY routing is
                // needed (it cannot be defeated by a broken clear path). The
                // tol=4 false-fire on a payload word is also hardened: a within-tol
                // payload word does not recur at the SYNC period either.
                //
                // SYNC_CONFIRM=1 is the DEGENERATE no-consecutive case (commit on
                // the first hit) = the historical first-arrival latch — used by the
                // unit test's NEGATIVE control to show the poison still breaks it
                // without the consecutive-consistent gate. At SYNC_CONFIRM=1 the
                // gap/residue qualifiers fold out (first sync_hit commits).
                // ===========================================================
                // Width of the periodic phase counter (residue + gap). The gap
                // counter must HOLD the value SYNC_PERIOD-1 (the saturation point =
                // exactly one period of non-matching words), so it is sized to
                // SYNC_PERIOD-1, NOT SYNC_PERIOD — at a power-of-two SYNC_PERIOD a
                // SYNC_PERIOD-wide field would alias SYNC_PERIOD to 0. SP is a
                // compile-time int from the $unit include. GAP_MAX is the full-int
                // saturation constant; SPW its width.
                localparam int unsigned SP      = SYNC_PERIOD;
                localparam int unsigned GAP_MAX  = (SP <= 1) ? 0 : (SP - 1);
                localparam int unsigned SPW      = (GAP_MAX < 1) ? 1 : ($clog2(GAP_MAX + 1));
                // JITTER-WINDOWED gap bounds (2026-06-23). The gap counter no longer
                // gates on the EXACT point GAP_MAX; it is allowed to drift +/-TOL
                // around it so an early/late SYNC (phase wander -> +/-TOL fewer/more
                // non-match words between beacons) still confirms:
                //   GAP_LO  = GAP_MAX-TOL : earliest gap that counts as "~one period"
                //   GAP_HI  = GAP_MAX+TOL : counter ceiling + run-break grace (a SYNC
                //                            up to TOL beats LATE still re-confirms;
                //                            only past GAP_HI is the run declared broken)
                // GAP_HI can exceed GAP_MAX, so the gap counter is widened to GPW
                // bits (was SPW). The residue field stays SPW (mod SYNC_PERIOD).
                localparam int unsigned TOL     = SYNC_IDX_TOL;
                localparam int unsigned GAP_LO  = (GAP_MAX > TOL) ? (GAP_MAX - TOL) : 0;
                localparam int unsigned GAP_HI  = GAP_MAX + TOL;
                localparam int unsigned GPW     = (GAP_HI < 1) ? 1 : ($clog2(GAP_HI + 1));
                localparam int unsigned HALF_SP = SP >> 1;   // SYNC_PERIOD/2 (circular fold)
                logic [SPW-1:0]     sync_cand_res;  // candidate residue (wr_ptr_l mod SP), re-centered each confirm
                logic               sync_cand_vld;  // candidate seeded by a REAL prior hit (not the reset value)
                logic [GPW-1:0]     sync_gap;       // lane_clk edges since last hit (sat. GAP_HI)
                logic [2:0]         sync_conf;       // consecutive periodic re-confirms (0..SYNC_CONFIRM)
                // Current write-index residue this edge (wr_ptr_l mod SYNC_PERIOD).
                // SYNC_PERIOD is a power of two (32 default), so the residue is
                // exactly the low SPW bits of the binary write pointer — no MODDIV,
                // no width hazard, and the period-residue scheme is only sound for
                // a power-of-two period anyway (the elab guard above enforces it).
                wire [SPW-1:0] wr_res = wr_ptr_l[SPW-1:0];
                // CIRCULAR residue distance |wr_res - sync_cand_res| mod SYNC_PERIOD.
                // wr_res/sync_cand_res are the low SPW bits, so the SPW-bit subtract
                // wraps mod SYNC_PERIOD automatically; fold the raw difference to the
                // shorter arc (min(raw, SP-raw)) so a +/-TOL jitter that straddles the
                // 0/SP-1 boundary still measures TOL, not SP-TOL.
                wire [SPW-1:0] res_raw  = wr_res - sync_cand_res;
                wire [SPW-1:0] res_dist = (res_raw <= HALF_SP[SPW-1:0])
                                          ? res_raw : (SP[SPW-1:0] - res_raw);
                wire res_in_win = (res_dist <= TOL[SPW-1:0]);
                // Gap counter saturates/holds at GAP_HI (was GAP_MAX). The periodic
                // confirm needs the gap to have reached the LOW edge of the window
                // (>= GAP_LO = ~one period of non-match), and the residue to be
                // within the circular window. gap_window is the load-bearing
                // anti-poison gate: a continuous within-tol poison resets sync_gap to
                // 0 every beat so it can never reach GAP_LO, regardless of TOL.
                wire gap_ceil   = (sync_gap == GAP_HI[GPW-1:0]);   // counter hold / run-break point
                wire gap_window = (sync_gap >= GAP_LO[GPW-1:0]);   // ~one-period-of-gap reached (anti-poison)
                // periodic re-match: gap ~one period, residue within window, AND the
                // candidate was SEEDED by a real prior hit. The sync_cand_vld guard is
                // load-bearing: the gap counter FREELY accumulates to saturation during
                // the pre-SYNC fill (the ~SYNC_PERIOD non-match words out of POR), so
                // WITHOUT this guard the FIRST real SYNC could be mis-classified as a
                // "periodic re-match" against the RESET candidate residue (0) whenever
                // its residue happens to fall within +/-TOL of 0 -> it would advance the
                // confirm run WITHOUT ever seeding sync_cand_idx (which would stay 0,
                // the reset value) -> a wrong, instance-inconsistent committed index.
                // Requiring a real seed first makes the FIRST hit ALWAYS fall through to
                // the seed branch (sets sync_cand_vld), exactly as the "start
                // non-saturated" reset comment intended but the free-running gap broke.
                wire periodic   = sync_cand_vld && gap_window && res_in_win;
                always_ff @(posedge lane_clk[gi] or negedge rst_n) begin
                    if (!rst_n) begin
                        sync_idx_l    <= '0;
                        sync_seen_l   <= 1'b0;
                        sync_cand_res <= '0;
                        sync_cand_vld <= 1'b0;   // no real seed yet -> first hit seeds
                        sync_gap      <= '0;
                        sync_conf     <= 3'd0;
                    end else if (clr_pulse_l) begin
                        // SECONDARY SW RE-ARM (held inert if its APB->PHY routing is
                        // dead on silicon): drop the latch + confirm run so the next
                        // periodic SYNC re-captures fresh. The clear WINS over a
                        // same-edge sync_hit. The self-gating arm above is the
                        // PRIMARY mechanism; this path is a harmless extra re-arm.
                        sync_idx_l    <= '0;
                        sync_seen_l   <= 1'b0;
                        sync_cand_res <= '0;
                        sync_cand_vld <= 1'b0;   // re-arm: next hit re-seeds (see reset)
                        sync_gap      <= '0;
                        sync_conf     <= 3'd0;
                    end else if (!sync_seen_l) begin
                        if (sync_hit) begin
                            // gap resets on EVERY match (so a continuous-match poison
                            // never lets gap saturate -> periodic never asserts).
                            sync_gap <= '0;
                            if (SYNC_CONFIRM[2:0] == 3'd1) begin
                                // DEGENERATE (negative control): first hit commits =
                                // historical first-arrival latch (poison NOT rejected).
                                sync_idx_l  <= wr_ptr_l;
                                sync_seen_l <= 1'b1;
                            end else if (periodic) begin
                                // Periodic re-match WITHIN the jitter window (residue
                                // within +/-TOL of the re-centered candidate, gap in
                                // [GAP_LO,GAP_HI] = ~one SYNC_PERIOD on from the last
                                // match): advance the confirm run; commit at
                                // SYNC_CONFIRM-1 prior confirms. RE-CENTER the
                                // candidate residue to THIS observation so slow
                                // monotonic phase drift tracks along and cannot walk
                                // out of a fixed +/-TOL window over many periods.
                                sync_cand_res <= wr_res;        // track the jitter
                                if (sync_conf == (SYNC_CONFIRM[2:0] - 3'd1)) begin
                                    // COMMIT THIS CONFIRMING SYNC's index (a RECENT write
                                    // index, close to the live write pointer). CROSS-LANE
                                    // CONSISTENCY under jitter: every lane SEEDS on the
                                    // SAME beacon instance (the first SYNC each lane sees
                                    // — guaranteed by the sync_cand_vld guard, so the
                                    // free-running pre-SYNC gap cannot false-classify the
                                    // first hit as a periodic re-match), then confirms one
                                    // beacon per SYNC_PERIOD, so all lanes commit on the
                                    // SAME instance (#K+1); their committed indices differ
                                    // only by the cross-lane word SKEW — exactly what the
                                    // read-side (max_dist - sync_dist) offset corrects.
                                    // The CONFIRMING index (not the stale seed) is
                                    // committed so sync_dist = sync_idx - rd_ptr stays a
                                    // small FORWARD distance the read side can act on (the
                                    // seed would by now sit far BEHIND rd_ptr and wrap
                                    // sync_dist negative -> the read-side span math breaks,
                                    // observed as 0% coherence on the fixed-skew tests).
                                    sync_idx_l  <= wr_ptr_l;
                                    sync_seen_l <= 1'b1;
                                end else begin
                                    sync_conf <= sync_conf + 3'd1;
                                end
                            end else begin
                                // A within-tol hit that is NOT a periodic re-match:
                                // either the FIRST hit (gap not yet ~one period) or an
                                // off-window match (gap saturated but residue outside
                                // the +/-TOL arc -> not the expected phase). (Re)seed
                                // the candidate residue and restart the confirm run (wpa
                                // "new candidate"). Mark the candidate VALID so the next
                                // within-window hit qualifies as periodic (and so the
                                // free-running pre-SYNC gap cannot false-fire periodic
                                // against the reset-0 candidate before a real seed).
                                sync_cand_res <= wr_res;
                                sync_cand_vld <= 1'b1;
                                sync_conf     <= 3'd0;
                            end
                        end else begin
                            // Non-match: advance the gap up to the GAP_HI ceiling
                            // (= GAP_MAX+TOL, the late-arrival grace). Only once the
                            // gap reaches GAP_HI with STILL no periodic re-match has a
                            // full period + the +TOL late grace elapsed with the
                            // expected SYNC missed -> break the confirm run (wpa:
                            // periodic re-match missed -> conf <- 0). Holding the
                            // count at GAP_HI keeps gap_window asserted so a SYNC that
                            // is merely LATE (gap pinned at the ceiling) still confirms
                            // when it lands; the run only resets once per missed period
                            // (sync_conf already 0 thereafter, harmless re-write).
                            if (!gap_ceil) sync_gap <= sync_gap + 1'b1;
                            else           sync_conf <= 3'd0;
                        end
                    end
                end
                assign sync_wr_idx_flat[gi] = sync_idx_l;
                assign sync_seen_flat[gi]   = sync_seen_l;

                // DATA-MODE SYNC Hamming-distance OBS (2026-06-25, the winscan
                // metric). Register the LIVE per-lane distance of the current
                // incoming word to this lane's SYNC slice (sync_dist_w, the same
                // value sync_hit thresholds at SYNC_REANCHOR_TOL) in lane_clk, so
                // the out_clk synchroniser samples a flop (not combinational) —
                // identical CDC-source discipline to wr_gray_l / sync_seen_l. It
                // is a pure read-only fan-out of sync_dist_w; it does NOT gate the
                // capture FSM or the datapath. In DATA mode the SYNC beacon floods
                // every SYNC_PERIOD words, so a winscan reading this register sees
                // each active lane's true RX-eye margin to its slice (a small
                // distance = a well-centred IDELAY tap; the value to minimise).
                logic [4:0] sync_dist_q;
                always_ff @(posedge lane_clk[gi] or negedge rst_n) begin
                    if (!rst_n) sync_dist_q <= 5'd16;   // POR = max distance (no word seen)
                    else        sync_dist_q <= sync_dist_w;
                end
                assign sync_dist_flat[gi] = sync_dist_q;
            end else begin : g_no_sync_capture
                assign sync_wr_idx_flat[gi] = '0;
                assign sync_seen_flat[gi]   = 1'b0;
                assign sync_dist_flat[gi]   = 5'd0;
            end

            // --- epoch-anchor training-exit capture (write side) ---------------
            // CONTENT-ONLY (fix2, 2026-06-14 — reverts the 2994848 training_mode_i
            // gate back to c332722's behaviour; see the tie-off note above for
            // WHY the gate was wrong). Hamming-match the incoming word against
            // this lane's CONSTANT training word (or its inverse — pair-swap
            // tolerant; dist to ~P is exactly 16 - dist to P).
            //
            // MULTI-SAMPLE EXIT CONFIRMATION (fix3, 2026-06-15): a qualified
            // falling edge no longer latches immediately. After a streak >=
            // STREAK_MIN, the FIRST non-match snapshots the candidate index
            // (ep_cand_idx <= wr_ptr_l = the first data word's write index) and
            // opens a confirmation window (ep_confirm 0->1). The anchor commits
            // ONLY after EPOCH_EXIT_CONFIRM consecutive non-matches, and the
            // latched index is that FIRST one (true exit + 0, alignment-exact).
            // ANY pattern word during the window ABORTS it (ep_confirm <= 0) — it
            // was a glitch, not the exit. WHY: on a marginal eye a per-lane bit-
            // error burst on a late training word reads as a lone non-match while
            // the streak is already saturated; the old logic latched THAT
            // corrupted word's index EARLY (e.g. 12->9), faking the exit before
            // the real edge and garbling the assembled epoch -> garbled addr ->
            // write_complete never fires. Requiring K real data words filters
            // single (and up to K-1 long) bursts: a legitimate pattern word
            // follows the glitch and aborts, but the TRUE exit is permanent data
            // so the window completes and qualifies.
            // Last-qualified-edge-wins (self-healing) is preserved: a NEW training
            // window rebuilds the streak and re-runs the confirmation, bumping the
            // freshness counter so the read side re-measures. epoch_anchored stays
            // sticky once engaged (safe: offsets only ever re-load on a NEW
            // coherent, fresh, span-OK set; downstream all-fresh + settle + span
            // gates still veto a single spurious lane).
            if (EPOCH_ANCHOR_EN) begin : g_epoch_capture
                wire [15:0] ep_xor = lane_data[gi*WIDTH +: WIDTH]
                                     ^ PATTERN_W[gi];
                wire [4:0]  ep_dist;
                tidelink_popcount16 u_ep_pop (.x(ep_xor), .count(ep_dist));
                wire ep_match = (ep_dist <= EPOCH_MATCH_THRESH[4:0]) ||
                                (ep_dist >= (5'd16 - EPOCH_MATCH_THRESH[4:0]));

                logic [3:0]         ep_streak;      // saturating consecutive-match count
                logic [2:0]         ep_confirm;     // consecutive non-matches after a qualified streak (0 = idle/closed)
                logic [1:0]         ep_gapmatch;    // consecutive matches WITHIN an open window (soft-abort, fix4)
                logic [DEPTH_LOG:0] ep_cand_idx;    // snapshot of the FIRST non-match's write index
                logic [DEPTH_LOG:0] ep_anchor_idx;
                logic [2:0]         ep_anchor_cnt;
                always_ff @(posedge lane_clk[gi] or negedge rst_n) begin
                    if (!rst_n) begin
                        ep_streak     <= '0;
                        ep_confirm    <= '0;
                        ep_gapmatch   <= '0;
                        ep_cand_idx   <= '0;
                        ep_anchor_idx <= '0;
                        ep_anchor_cnt <= '0;
                    end else if (ep_match) begin
                        if (ep_confirm != 3'd0) begin
                            // SOFT ABORT (fix4): a match INSIDE an open confirm
                            // window. Tolerate a SINGLE isolated intervening match
                            // (a lone idle/bit-errored pattern-like word among the
                            // post-exit data); only TWO CONSECUTIVE matches mean
                            // the training pattern has genuinely RESUMED -> abort.
                            if (ep_gapmatch == 2'd1) begin
                                // second consecutive match -> real pattern resumed:
                                // ABORT the window and resume streak counting from
                                // the two matches just seen (still must reach
                                // STREAK_MIN before a new window can open).
                                ep_confirm  <= '0;
                                ep_gapmatch <= '0;
                                ep_streak   <= 4'd2;
                            end else begin
                                // FIRST match in the gap -> FORGIVE: hold ep_confirm
                                // (do NOT reset), just note the consecutive match.
                                ep_gapmatch <= 2'd1;
                            end
                        end else begin
                            // Window CLOSED: pattern word builds the match streak,
                            // confirmation idle (unchanged pre-fix behaviour).
                            if (ep_streak != 4'hF) ep_streak <= ep_streak + 1'b1;
                            ep_gapmatch <= '0;
                        end
                    end else begin
                        // Non-match word. Clear the per-gap consecutive-match count
                        // (so "consecutive" is measured within each gap), then:
                        ep_gapmatch <= '0;
                        if (ep_confirm != 3'd0) begin
                            // Confirmation already open — advance toward commit.
                            // COMMIT (once) when this completes EPOCH_EXIT_CONFIRM
                            // non-matches; latch the FIRST index (ep_cand_idx).
                            // ep_confirm holds the count of non-matches seen BEFORE
                            // this beat, so the Kth beat is where ep_confirm == K-1.
                            // Forgiven intervening matches do NOT advance ep_confirm,
                            // so the K count is over NON-MATCH words only.
                            if (ep_confirm == (EPOCH_EXIT_CONFIRM[2:0] - 3'd1)) begin
                                ep_anchor_idx <= ep_cand_idx;       // true exit + 0
                                ep_anchor_cnt <= ep_anchor_cnt + 1'b1;
                                ep_confirm    <= '0;                // re-arm for next window
                            end else begin
                                ep_confirm <= ep_confirm + 1'b1;
                            end
                        end else if (ep_streak >= EPOCH_STREAK_MIN[3:0]) begin
                            // FIRST non-match after a qualified streak: snapshot
                            // the candidate index and open the window. K==1
                            // commits immediately (EPOCH_EXIT_CONFIRM-1 == 0).
                            ep_cand_idx <= wr_ptr_l;                // first data word's index
                            if (EPOCH_EXIT_CONFIRM[2:0] == 3'd1) begin
                                ep_anchor_idx <= wr_ptr_l;
                                ep_anchor_cnt <= ep_anchor_cnt + 1'b1;
                                ep_confirm    <= '0;
                            end else begin
                                ep_confirm <= 3'd1;
                            end
                        end
                        ep_streak <= '0;
                    end
                end
                assign ep_anchor_idx_flat[gi] = ep_anchor_idx;
                assign ep_anchor_cnt_flat[gi] = ep_anchor_cnt;
            end else begin : g_no_epoch_capture
                assign ep_anchor_idx_flat[gi] = '0;
                assign ep_anchor_cnt_flat[gi] = '0;
            end
        end
    endgenerate

    // 2-flop synchroniser of each lane's GRAY write pointer into out_clk, then
    // gray->bin back to a BINARY pointer (Finding #2 fix). The GRAY value crosses
    // the clock boundary (single-bit-per-step => tear-immune); wr_ptr_sync1 is the
    // recovered binary pointer the occupancy math consumes EXACTLY as before — a
    // settled Gray code converts to the identical binary value the counter held,
    // so occupancy (wr_ptr_sync1 - rd_ptr) and prime timing are unchanged.
    logic [DEPTH_LOG:0] wr_gray_sync0 [LANES];   // 1st sync flop (Gray)
    logic [DEPTH_LOG:0] wr_gray_sync1 [LANES];   // 2nd sync flop (Gray, settled)
    logic [DEPTH_LOG:0] wr_ptr_sync1  [LANES];   // gray->bin: binary write ptr in out_clk

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_wr_sync
            always_ff @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) begin
                    wr_gray_sync0[gi] <= '0;
                    wr_gray_sync1[gi] <= '0;
                end else begin
                    wr_gray_sync0[gi] <= wr_gray_flat[gi];
                    wr_gray_sync1[gi] <= wr_gray_sync0[gi];
                end
            end
            // Combinational gray->bin of the settled 2nd-stage value. (Gray 0 ->
            // binary 0, so the reset-time occupancy is identical to before.)
            assign wr_ptr_sync1[gi] = gray2bin(wr_gray_sync1[gi]);
        end
    endgenerate

    // --- re-anchor: CDC the per-lane SYNC index + seen flag into out_clk, reusing
    // the SAME 2-flop binary-pointer pattern as g_wr_sync above (SPEC §6 S1 — do
    // not invent a new synchroniser). Generate-gated so SYNC_REANCHOR_EN=0 has
    // NO extra flops (bit-identical to today); sync_seen_sync1 then reads 0 and
    // the re-anchor block is fully pruned.
    logic [DEPTH_LOG:0] sync_idx_sync1 [LANES];
    logic [LANES-1:0]   sync_seen_sync1;

    generate
        if (SYNC_REANCHOR_EN) begin : g_sync_sync
            logic [DEPTH_LOG:0] sync_idx_sync0 [LANES];
            logic [LANES-1:0]   sync_seen_sync0;
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane
                always_ff @(posedge out_clk or negedge rst_n) begin
                    if (!rst_n) begin
                        sync_idx_sync0[gi]  <= '0;
                        sync_idx_sync1[gi]  <= '0;
                        sync_seen_sync0[gi] <= 1'b0;
                        sync_seen_sync1[gi] <= 1'b0;
                    end else begin
                        sync_idx_sync0[gi]  <= sync_wr_idx_flat[gi];
                        sync_idx_sync1[gi]  <= sync_idx_sync0[gi];
                        sync_seen_sync0[gi] <= sync_seen_flat[gi];
                        sync_seen_sync1[gi] <= sync_seen_sync0[gi];
                    end
                end
            end
        end else begin : g_no_sync_sync
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane
                assign sync_idx_sync1[gi]  = '0;
                assign sync_seen_sync1[gi] = 1'b0;
            end
        end
    endgenerate

    // STICKY-POISON OBSERVABILITY (2026-06-23): surface the out_clk-synced
    // per-lane sync_seen vector so silicon can tell apart 'no lane latched'
    // (0x00), 'latched inconsistent indices' (set, but out_data never coheres),
    // and 'latched + coherent'. sync_seen_sync1 is 0 in the OFF/EPOCH builds
    // (g_no_sync_sync ties it), so this is 0 unless SYNC_REANCHOR_EN.
    assign sync_seen_vec_o = sync_seen_sync1;

    // DATA-MODE SYNC Hamming-distance OBS (2026-06-25, the winscan metric) —
    // 2-flop synchronise each lane's lane_clk-registered sync_dist_flat into
    // out_clk, reusing the SAME pattern as g_sync_sync above (do not invent a
    // new synchroniser). Generate-gated so SYNC_REANCHOR_EN=0 adds NO flops
    // (sync_dist_vec_o reads 0). A 5-bit value can momentarily tear during a
    // scan word, but the metric is read repeatedly while the SYNC beacon floods
    // (quasi-static) — the same accepted multi-bit-2-flop treatment the eye-width
    // / raw-word snapshots use. Lane L occupies sync_dist_vec_o[5L +: 5].
    logic [4:0] sync_dist_sync1 [LANES];
    generate
        if (SYNC_REANCHOR_EN) begin : g_sync_dist_sync
            logic [4:0] sync_dist_sync0 [LANES];
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane
                always_ff @(posedge out_clk or negedge rst_n) begin
                    if (!rst_n) begin
                        sync_dist_sync0[gi] <= 5'd0;
                        sync_dist_sync1[gi] <= 5'd0;
                    end else begin
                        sync_dist_sync0[gi] <= sync_dist_flat[gi];
                        sync_dist_sync1[gi] <= sync_dist_sync0[gi];
                    end
                end
            end
        end else begin : g_no_sync_dist_sync
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane
                assign sync_dist_sync1[gi] = 5'd0;
            end
        end
    endgenerate
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_sync_dist_pack
            assign sync_dist_vec_o[5*gi +: 5] = sync_dist_sync1[gi];
        end
    endgenerate

    // Per-lane occupancy gates: has-data (>=1) and primed (>= PRIME_THRESH).
    // Occupancy is measured against the COMMON rd_ptr base; with the re-anchor
    // offsets all per-lane read pointers stay within [rd_ptr, rd_ptr+max_skew], a
    // span the prime cushion + DEPTH headroom covers (see header cold-start note).
    wire [LANES-1:0] lane_has_data;
    wire [LANES-1:0] lane_primed;

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_occ
            wire [DEPTH_LOG:0] occ = wr_ptr_sync1[gi] - rd_ptr;
            assign lane_has_data[gi] = (occ != '0);
            assign lane_primed[gi]   = (occ >= PRIME_THRESH[DEPTH_LOG:0]);
        end
    endgenerate

    // REDUCED-LANE link (2026-06-17): a masked-out lane never fills its FIFO, so
    // its has-data / primed term must NOT veto the word read. `| ~lane_mask`
    // forces every masked lane's term to 1 (the SAME idiom the calibrator's
    // probe_all_locked / lane_done and the RX SYNC-detect use). At lane_mask=0xFF
    // `~lane_mask == 0` so this reduces to the original `&lane_has_data` /
    // `&lane_primed` — bit-identical. The masked lanes' 16-bit out_data slices
    // become don't-care; the downstream Wlink RX gather drops them by mask.
    wire all_ready  = &(lane_has_data | ~lane_mask);
    wire all_primed = &(lane_primed   | ~lane_mask);

    // -------------------------------------------------------------------------
    // PRIME-AND-CONTINUOUS read base pointer (out_clk). Unchanged from the
    // pre-beacon module: hold off until all lanes have >= PRIME_THRESH words
    // (latch primed), then advance one aligned word per out_clk gated by
    // all_ready. primed persists after POR (no per-training re-prime).
    // -------------------------------------------------------------------------
    wire advance = primed & all_ready;   // common read-pointer step this beat

    always_ff @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr    <= '0;
            primed    <= 1'b0;
            out_valid <= 1'b0;
        end else if (!primed) begin
            out_valid <= 1'b0;
            if (all_primed) primed <= 1'b1;
        end else if (all_ready) begin
            rd_ptr    <= rd_ptr + 1'b1;
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;   // underrun safety: hold out_data, drop valid
        end
    end

    // -------------------------------------------------------------------------
    // OUT_DATA + per-lane read pointer.
    //
    // SYNC_REANCHOR_EN=0 (REGRESSION PATH — bit-identical to today): rd_ptr_l[gi]
    // is the single common rd_ptr and out_data registers rd_word on each
    // advancing beat, exactly as the pre-beacon module did (the re-anchor block
    // below is generate-pruned, so no extra logic or registers exist).
    //
    // SYNC_REANCHOR_EN=1 (RE-ANCHOR PATH): once all 8 lanes have a synchronised
    // SYNC index, derive a per-lane BACKWARD read offset lane_off[gi] =
    // (max_idx - sync_idx[gi]) so each lane reads rd_ptr_l[gi] = rd_ptr -
    // lane_off[gi]. max_idx is the LATEST-arriving SYNC, so every offset is >= 0
    // and every per-lane read pointer is AT or BEHIND rd_ptr — always inside
    // already-written, primed data (safe direction; no read-ahead of writes).
    // When the common rd_ptr base sweeps up to max_idx, lane gi reads
    // max_idx - (max_idx - sync_idx[gi]) = sync_idx[gi] = its SYNC slice, so ALL
    // 8 SYNC slices land on the SAME beat -> out_data == TIDELINK_SYNC_WORD. The
    // offsets are latched once (reanchored) and ride along with rd_ptr, so the
    // measured alignment holds every subsequent beat. If SYNC never completes on
    // all lanes within REANCHOR_TIMEOUT advancing beats, reanchored stays 0 and
    // the module falls back to the common-pointer behaviour (never wedges).
    // -------------------------------------------------------------------------
    integer ri;
    always_ff @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data <= '0;
        end else if (advance) begin
            for (ri = 0; ri < LANES; ri = ri + 1) begin
                out_data[ri*WIDTH +: WIDTH] <= rd_word[ri];
            end
        end
    end

    generate
        if (EPOCH_ANCHOR_EN) begin : g_epoch
            // ----------------------------------------------------------------
            // TRAINING-ANCHORED EPOCH PRIMING, read side (see header block).
            // ----------------------------------------------------------------
            // CONTENT-ONLY (fix2): no training_mode_i re-arm here. epoch_anchored
            // is sticky once engaged (c332722 behaviour) — safe because offsets
            // only ever re-load on a NEW coherent (all-fresh, settled, span-OK)
            // anchor set, and a fresh training window advances the per-lane
            // freshness counters naturally. The observable ep_span_meas below
            // still records the last measured span.
            // 2-flop sync of each lane's anchor index + freshness token into
            // out_clk. The index bus is captured-static long before it is read
            // (the settle window requires EPOCH_SETTLE quiescent beats), so a
            // plain binary 2-flop is sufficient here — same argument as the
            // g_sync_sync block above; any mid-transition tear shows up as a
            // "change" and simply restarts the settle window.
            logic [DEPTH_LOG:0] ep_idx_sync0 [LANES];
            logic [DEPTH_LOG:0] ep_idx_sync1 [LANES];
            logic [2:0]         ep_cnt_sync0 [LANES];
            logic [2:0]         ep_cnt_sync1 [LANES];
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_ep_sync
                always_ff @(posedge out_clk or negedge rst_n) begin
                    if (!rst_n) begin
                        ep_idx_sync0[gi] <= '0;
                        ep_idx_sync1[gi] <= '0;
                        ep_cnt_sync0[gi] <= '0;
                        ep_cnt_sync1[gi] <= '0;
                    end else begin
                        ep_idx_sync0[gi] <= ep_anchor_idx_flat[gi];
                        ep_idx_sync1[gi] <= ep_idx_sync0[gi];
                        ep_cnt_sync0[gi] <= ep_anchor_cnt_flat[gi];
                        ep_cnt_sync1[gi] <= ep_cnt_sync0[gi];
                    end
                end
            end

            // Freshness: a lane is fresh while its synced capture counter
            // differs from the value consumed at the last application. ALL
            // lanes must be fresh — a dead/masked/never-locked lane vetoes
            // (safe fall back to previous offsets / plain prime-and-continuous).
            logic [2:0]       ep_applied_cnt [LANES];
            logic [LANES-1:0] ep_fresh;
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_ep_fresh
                assign ep_fresh[gi] = (ep_cnt_sync1[gi] != ep_applied_cnt[gi]);
            end
            // REDUCED-LANE link: a masked lane never anchors, so it would never
            // read fresh and would permanently veto every offset load. `|
            // ~lane_mask` forces a masked lane's freshness term to 1 so only the
            // UNMASKED lanes must be fresh — the active subset re-measures
            // exactly as the full 8 did. lane_mask=0xFF => unchanged (&ep_fresh).
            wire ep_all_fresh = &(ep_fresh | ~lane_mask);

            // Change detector + settle window: anchors from one exit event
            // arrive within ~(skew spread + sync) beats of each other; wait
            // until the whole synced bus has been quiet for EPOCH_SETTLE
            // beats so the offset load is atomic over one coherent set.
            logic [DEPTH_LOG:0] ep_idx_prev [LANES];
            logic [2:0]         ep_cnt_prev [LANES];
            logic               ep_changed;
            integer ci;
            // REDUCED-LANE link: only UNMASKED lanes' anchor idx/cnt feed the
            // settle "changed" detector — a masked lane's slot carries garbage
            // (dead conductor) that could toggle every beat and hold the settle
            // window open forever. `lane_mask[ci]` gates each term in; at 0xFF
            // every lane counts (unchanged).
            always_comb begin
                ep_changed = 1'b0;
                for (ci = 0; ci < LANES; ci = ci + 1) begin
                    if (lane_mask[ci] && (ep_idx_sync1[ci] != ep_idx_prev[ci])) ep_changed = 1'b1;
                    if (lane_mask[ci] && (ep_cnt_sync1[ci] != ep_cnt_prev[ci])) ep_changed = 1'b1;
                end
            end

            localparam int EP_SW = $clog2(EPOCH_SETTLE + 1);
            logic [EP_SW-1:0] ep_settle_ctr;
            wire ep_apply = ep_all_fresh & ~ep_changed &
                            (ep_settle_ctr == EPOCH_SETTLE[EP_SW-1:0]);

            // Wrap-safe per-lane epoch deltas vs lane 0 (PW-bit signed; the
            // true span is <= EPOCH_OFF_MAX << 2^(PW-1), so the signed
            // interpretation cannot alias) and their signed max/min.
            // REDUCED-LANE link: the per-lane epoch delta is taken vs lane 0,
            // but ONLY UNMASKED lanes fold into the cross-lane max/min span. A
            // masked lane's anchor index is garbage (never captured) and must
            // not stretch the span (which would force a spurious span-reject) or
            // pull a real lane's offset. The reference is lane 0's index: note
            // the final offset lane_off = ep_max_d - ep_delta = ep_max_d -
            // (idx[lo]-idx[0]) is INVARIANT to the reference (the -idx[0] term
            // cancels), so using lane 0 as the arithmetic origin is safe even
            // when lane 0 is itself masked. ep_max_d/ep_min_d seed from the
            // first unmasked lane so an all-negative or all-positive active set
            // is not clamped at 0. lane_mask=0xFF => every lane folds in and the
            // seed is lane 0's delta 0 (== the original behaviour).
            logic signed [DEPTH_LOG:0] ep_delta [LANES];
            logic signed [DEPTH_LOG:0] ep_max_d;
            logic signed [DEPTH_LOG:0] ep_min_d;
            logic                      ep_seen_active;
            integer di;
            always_comb begin
                ep_max_d       = '0;
                ep_min_d       = '0;
                ep_seen_active = 1'b0;
                for (di = 0; di < LANES; di = di + 1) begin
                    ep_delta[di] = signed'(ep_idx_sync1[di] - ep_idx_sync1[0]);
                    if (lane_mask[di]) begin
                        if (!ep_seen_active) begin
                            ep_max_d = ep_delta[di];
                            ep_min_d = ep_delta[di];
                        end else begin
                            if (ep_delta[di] > ep_max_d) ep_max_d = ep_delta[di];
                            if (ep_delta[di] < ep_min_d) ep_min_d = ep_delta[di];
                        end
                        ep_seen_active = 1'b1;
                    end
                end
            end
            wire signed [DEPTH_LOG+1:0] ep_span =
                {ep_max_d[DEPTH_LOG], ep_max_d} - {ep_min_d[DEPTH_LOG], ep_min_d};
            localparam logic signed [DEPTH_LOG+1:0] EP_SPAN_MAX =
                EPOCH_OFF_MAX[DEPTH_LOG+1:0];
            wire ep_span_ok = (ep_span <= EP_SPAN_MAX);

            logic [DEPTH_LOG:0] lane_off_e [LANES]; // per-lane BACKWARD offset (held)
            logic               epoch_anchored;     // offsets loaded & active
            logic [DEPTH_LOG:0] ep_span_meas;       // last measured span (obs)

            integer lo;
            always_ff @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) begin
                    epoch_anchored <= 1'b0;
                    ep_span_meas   <= '0;
                    ep_settle_ctr  <= '0;
                    for (lo = 0; lo < LANES; lo = lo + 1) begin
                        lane_off_e[lo]     <= '0;
                        ep_idx_prev[lo]    <= '0;
                        ep_cnt_prev[lo]    <= '0;
                        ep_applied_cnt[lo] <= '0;
                    end
                end else begin
                    for (lo = 0; lo < LANES; lo = lo + 1) begin
                        ep_idx_prev[lo] <= ep_idx_sync1[lo];
                        ep_cnt_prev[lo] <= ep_cnt_sync1[lo];
                    end
                    // settle window
                    if (!ep_all_fresh || ep_changed || ep_apply) begin
                        ep_settle_ctr <= '0;
                    end else if (ep_settle_ctr != EPOCH_SETTLE[EP_SW-1:0]) begin
                        ep_settle_ctr <= ep_settle_ctr + 1'b1;
                    end
                    // one-shot application per coherent anchor set (content-only,
                    // c332722 behaviour).
                    if (ep_apply) begin
                        for (lo = 0; lo < LANES; lo = lo + 1) begin
                            ep_applied_cnt[lo] <= ep_cnt_sync1[lo]; // consume even on reject
                        end
                        ep_span_meas <= ep_span[DEPTH_LOG:0]; // record even on reject (obs)
                        if (ep_span_ok) begin
                            for (lo = 0; lo < LANES; lo = lo + 1) begin
                                // REDUCED-LANE link: an active lane reads behind
                                // the common rd_ptr by (max_active - its delta);
                                // a MASKED lane's slice is don't-care (Wlink RX
                                // gather drops it) so park its offset at 0 — its
                                // garbage anchor index must never set a backward
                                // read that could underflow. lane_mask=0xFF => the
                                // ternary is always the real offset (unchanged).
                                lane_off_e[lo] <= lane_mask[lo]
                                    ? unsigned'(ep_max_d - ep_delta[lo]) // >= 0, <= span
                                    : '0;
                            end
                            epoch_anchored <= 1'b1;
                        end else begin
                            // SPAN-REJECT SELF-HEAL (fix4, span > EPOCH_OFF_MAX):
                            // a die measuring noise produces a growing, over-budget
                            // span. Previously epoch_anchored stayed sticky and held
                            // STALE offsets, reporting a false "anchored=1". Instead
                            // DROP to plain prime-and-continuous (zero offsets, no
                            // tear) and report honestly, so a later GOOD roll can
                            // re-engage. The offsets revert to 0 (rd_ptr_l == rd_ptr).
                            for (lo = 0; lo < LANES; lo = lo + 1) begin
                                lane_off_e[lo] <= '0;
                            end
                            epoch_anchored <= 1'b0;
                        end
                    end
                end
            end

            // Per-lane read pointer = rd_ptr - held backward offset (0 until
            // the first application, so identical to the common pointer).
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_rd_ep_off
                assign rd_ptr_l[gi] = epoch_anchored ? (rd_ptr - lane_off_e[gi])
                                                     : rd_ptr;
            end

            // Engagement observables (fix #4).
            assign epoch_anchored_o = epoch_anchored;
            assign epoch_span_o     = ep_span_meas;

            // Sink the (constant-tied, SYNC_REANCHOR_EN=0) SYNC re-anchor nets
            // so this config is lint-clean (same idiom as g_no_reanchor).
            wire [LANES-1:0] _unused_idx;
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_ep_sink
                assign _unused_idx[gi] = ^{sync_wr_idx_flat[gi], sync_idx_sync1[gi]};
            end
            wire _unused_sync = ^{_unused_idx, sync_seen_flat, sync_seen_sync1};
        end else if (SYNC_REANCHOR_EN) begin : g_reanchor
            logic [DEPTH_LOG:0] lane_off [LANES];  // per-lane BACKWARD offset (held)
            logic               reanchored;        // offsets loaded & active

            // All ACTIVE lanes have a synchronised SYNC-arrival index. `|
            // ~lane_mask` excludes masked lanes (which never see SYNC) so the
            // re-anchor latches on the unmasked subset. lane_mask=0xFF =>
            // &sync_seen_sync1 (unchanged). (This path is param-OFF in the V2
            // build — SYNC_REANCHOR_EN=1'b0 — and pruned; kept correct here.)
            wire all_sync_seen = &(sync_seen_sync1 | ~lane_mask);

            // Combinational per-lane SYNC distance ahead of the read pointer
            // (sync_idx - rd_ptr, a small non-negative span mod 2^(DEPTH_LOG+1))
            // and its maximum: the lane whose SYNC is furthest ahead = the
            // latest-arriving SYNC, used as the common alignment reference.
            //
            // REDUCED-LANE link (2026-06-22): only UNMASKED lanes fold into the
            // cross-lane max_dist. A masked lane never captures its SYNC slice
            // (it carries 0x0000 on the wire — PHY TX zeroes it — so sync_seen
            // stays 0 and sync_idx_sync1 stays 0); its sync_dist = 0 - rd_ptr is
            // then a LARGE unsigned span that would otherwise become max_dist and
            // hand every ACTIVE lane a bogus huge backward offset -> occ wraps ->
            // the active subset never primes -> wedge. The same `lane_mask[di]`
            // gate the EPOCH g_epoch span uses (lines ~749-766) excludes masked
            // lanes here. max_dist seeds from the FIRST unmasked lane so an
            // all-large active set is not clamped at 0. lane_mask=0xFF => every
            // lane folds in, seed is lane 0 (== the original full-8 behaviour).
            logic [DEPTH_LOG:0] sync_dist [LANES];
            logic [DEPTH_LOG:0] max_dist;
            logic [DEPTH_LOG:0] min_dist;
            logic               sr_seen_active;
            integer di;
            always_comb begin
                max_dist       = '0;
                min_dist       = '0;
                sr_seen_active = 1'b0;
                for (di = 0; di < LANES; di = di + 1) begin
                    sync_dist[di] = sync_idx_sync1[di] - rd_ptr;
                    if (lane_mask[di]) begin
                        if (!sr_seen_active) begin
                            max_dist = sync_dist[di];
                            min_dist = sync_dist[di];
                        end else begin
                            if (sync_dist[di] > max_dist) max_dist = sync_dist[di];
                            if (sync_dist[di] < min_dist) min_dist = sync_dist[di];
                        end
                        sr_seen_active = 1'b1;
                    end
                end
            end

            // Cross-lane SYNC SPAN = the largest backward offset any lane will be
            // given (lane_off = max_dist - sync_dist, maximised for the EARLIEST
            // SYNC = min_dist). The X-glitch / apparent "stall" fix (2026-06-22):
            // the offsets are computed against the CURRENT rd_ptr and then HELD, so
            // the most-backward lane reads rd_ptr - span. At the moment all lanes
            // first carry a SYNC index the common rd_ptr is still tiny (~1-2), so
            // rd_ptr - span UNDERFLOWS to a high write index that lane has not yet
            // reached -> reads uninitialised mem_l -> ONE beat of X on out_data.
            // The unit test's int(out_data) then throws and mis-reads that single
            // X as "out_data NEVER updated" (a false STALL). Defer the latch until
            // rd_ptr has swept up to at least `span` so rd_ptr - span >= 0 for the
            // most-backward lane and every per-lane read points at already-written
            // data. The FIFO holds PRIME_THRESH+ words behind rd_ptr and span is
            // bounded well under DEPTH, so the deferral is a few beats and the
            // timeout (RTO >> fill+spread) still covers it. lane_mask=0xFF =>
            // span is the full-8 span (unchanged latch math, just later & safe).
            wire [DEPTH_LOG:0] sr_span = max_dist - min_dist;
            wire sr_rd_safe = (rd_ptr >= sr_span);

            // Timeout: count advancing beats; saturate. If SYNC never completes
            // on all lanes, fall back to the common pointer (reanchored stays 0).
            localparam int RTO = (1 << DEPTH_LOG) * 8;   // generous (>> fill+spread)
            localparam int RTOW = $clog2(RTO + 1);
            logic [RTOW-1:0] to_ctr;
            wire timed_out = (to_ctr >= RTO[RTOW-1:0]);

            // STICKY-POISON RE-ARM, read side (2026-06-23). sync_obs_clr_i is
            // already in out_clk (= gpiorx_0_io_link_clk), so edge-detect it here
            // with no resync. On the re-arm edge the read-side latch drops:
            // reanchored -> 0, offsets -> 0 (revert to plain prime-and-continuous),
            // timeout counter -> 0 (give the fresh measurement a full RTO window).
            // The write side re-arms sync_seen_l in parallel; once the clean SYNC
            // re-captures the TRUE per-lane indices, all_sync_seen reasserts and the
            // latch re-fires on the CORRECT offsets. Held 0 => clr_pulse_o never
            // fires (bit-identical). NOTE the re-arm here can momentarily un-shift an
            // already-aligned link; that is acceptable because the recipe pulses the
            // clear ONCE during cold bring-up (after force_always SYNC starts), not
            // on a live data link — the same "anchor in the idle gap" property the
            // EPOCH path relies on.
            logic clr_o_d;
            always_ff @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) clr_o_d <= 1'b0;
                else        clr_o_d <= sync_obs_clr_i;
            end
            wire clr_pulse_o = sync_obs_clr_i & ~clr_o_d;

            // RE-ARM SETTLE GATE (2026-06-23). Dropping `reanchored` on the clear
            // is not enough on its own: the write-side sync_seen_l clears in each
            // lane_clk, but its 0 has to propagate back through the 2-flop
            // sync_seen_sync0/1 CDC into out_clk. For those 2-3 beats all_sync_seen
            // still reads 1 carrying the STALE POISON indices, so a bare re-latch
            // would re-engage on the poison the very next beat. `rearm_wait` blocks
            // the re-latch until all_sync_seen has actually been observed LOW after
            // the clear (= the cleared seen vector reached out_clk); only then,
            // once the CLEAN SYNC re-fills sync_seen on the TRUE indices, does the
            // latch re-fire. Held 0 (no clear) => rearm_wait stays 0 — bit-identical.
            logic rearm_wait;
            always_ff @(posedge out_clk or negedge rst_n) begin
                if (!rst_n)               rearm_wait <= 1'b0;
                else if (clr_pulse_o)     rearm_wait <= 1'b1;   // arm the wait
                else if (!all_sync_seen)  rearm_wait <= 1'b0;   // cleared state reached out_clk
            end

            integer lo;
            always_ff @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) begin
                    reanchored <= 1'b0;
                    to_ctr     <= '0;
                    for (lo = 0; lo < LANES; lo = lo + 1) lane_off[lo] <= '0;
                end else if (clr_pulse_o) begin
                    // RE-ARM: drop the (poison-latched) re-anchor so a fresh,
                    // post-clear measurement re-engages on the clean SYNC indices.
                    reanchored <= 1'b0;
                    to_ctr     <= '0;
                    for (lo = 0; lo < LANES; lo = lo + 1) lane_off[lo] <= '0;
                // 2026-06-25 EYE-CENTER FIX: dropped `!timed_out` from the latch
                // gate. RTO (256 beats ~55us) expires long before an on-silicon
                // IDELAY eye-centering winscan (seconds) brings all active lanes
                // into SYNC, so the timeout permanently vetoed reanchored even
                // though all_sync_seen later went true (sync_seen_vec=0xe4 on
                // centered die_b, yet reanchored stuck 0). The latch now fires
                // whenever all_sync_seen && sr_rd_safe, however late. SAFE: when
                // !reanchored the per-lane read pointer already IS the common
                // rd_ptr (the timeout's only "fallback"), so removing the veto
                // does not change the not-yet-anchored datapath; it only lets a
                // late-but-valid SYNC set still latch. Poison protection is
                // upstream (sync_seen self-gating), unaffected. to_ctr kept for obs.
                end else if (advance && !reanchored && !rearm_wait) begin
                    // Latch once, when all ACTIVE lanes carry a synchronised SYNC
                    // index. REDUCED-LANE link: an ACTIVE lane reads behind the
                    // common rd_ptr by (max_dist - its sync_dist) so all active
                    // SYNC slices land on one beat; a MASKED lane's slice is
                    // don't-care (Wlink RX gather drops it) so park its offset at
                    // 0 — its garbage sync_idx (never captured) must never set a
                    // backward read that could underflow into unwritten memory.
                    // lane_mask=0xFF => the ternary is always the real offset
                    // (== the original full-8 behaviour, bit-identical).
                    if (all_sync_seen && sr_rd_safe) begin
                        for (lo = 0; lo < LANES; lo = lo + 1) begin
                            lane_off[lo] <= lane_mask[lo]
                                ? (max_dist - sync_dist[lo])  // >= 0, <= span
                                : '0;
                        end
                        reanchored <= 1'b1;
                    end else begin
                        // SYNC not yet on every active lane, OR rd_ptr has not yet
                        // swept past the span (the backward read would underflow
                        // into unwritten memory and glitch out_data to X — the
                        // false-stall above). Keep advancing the common pointer and
                        // count toward the fallback timeout; the SYNC indices ride
                        // along (sync_dist shrinks as rd_ptr grows) until the latch
                        // is safe. rd_ptr advances one per beat so sr_rd_safe goes
                        // true within `span` beats — well inside RTO.
                        to_ctr <= to_ctr + 1'b1;
                    end
                end
            end

            // Per-lane read pointer = rd_ptr - held backward offset (0 until
            // re-anchored, so identical to the common pointer pre-anchor). rd_ptr
            // and lane_off both update on out_clk, so the index is glitch-free.
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_rd_off
                assign rd_ptr_l[gi] = reanchored ? (rd_ptr - lane_off[gi]) : rd_ptr;
            end

            // Sink the (constant-tied, EPOCH_ANCHOR_EN=0) epoch-anchor nets.
            wire [LANES-1:0] _unused_ep_idx;
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_sr_ep_sink
                assign _unused_ep_idx[gi] = ^{ep_anchor_idx_flat[gi],
                                              ep_anchor_cnt_flat[gi]};
            end
            wire _unused_ep = ^{_unused_ep_idx};
            // RE-ANCHOR ENGAGEMENT OBSERVABLES (FIX 2, 2026-06-22): repurpose the
            // EPOCH status ports for the SYNC re-anchor so reading SoC 0x44032140
            // (EPOCH_STATUS, fed by epoch_anchored_o / epoch_span_o through
            // WlinkGPIOPHY -> WavD2DGpio) shows whether the re-anchor ENGAGED on
            // silicon — previously this read 0 in the SYNC_REANCHOR_EN=1 build
            // (the port was tied 0), so there was no way to tell a marginal-eye
            // mis-fire from a successful latch. epoch_anchored_o now mirrors the
            // `reanchored` latch (1 = offsets measured & active); epoch_span_o
            // carries the measured cross-lane SYNC span (max_dist - min_dist =
            // sr_span, in words) captured the beat the latch fired (else 0). Bit
            // map for 0x44032140 in the SYNC_REANCHOR build:
            //   bit[0]    = reanchored (re-anchor engaged)
            //   bits[6:1] = sr_span at engage (cross-lane SYNC word-span)  [DEPTH_LOG:0]
            // gated by SYNC_REANCHOR_EN (this whole g_reanchor block is pruned
            // when OFF, so the ports revert to the constant-0 tie in g_no_reanchor).
            logic [DEPTH_LOG:0] sr_span_meas;     // span snapshotted at engage (obs)
            always_ff @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) begin
                    sr_span_meas <= '0;
                end else if (clr_pulse_o) begin
                    sr_span_meas <= '0;           // re-arm: clear the stale span obs
                end else if (advance && !reanchored && !rearm_wait
                             && all_sync_seen && sr_rd_safe) begin
                    // same condition as the lane_off latch above: record the span
                    // the offsets were derived from, once, on the engage beat.
                    sr_span_meas <= sr_span;
                end
            end
            assign epoch_anchored_o = reanchored;     // re-anchor engaged
            assign epoch_span_o     = sr_span_meas;   // measured SYNC cross-lane span
        end else begin : g_no_reanchor
            // Regression path: per-lane read pointer IS the common rd_ptr. The
            // SYNC-capture / CDC nets are constant-tied and feed nothing here;
            // sink them (same _unused_ idiom as training_mode_i above) so the
            // OFF config is lint-clean and the synthesiser prunes them.
            wire [LANES-1:0] _unused_idx;
            for (gi = 0; gi < LANES; gi = gi + 1) begin : g_rd_common
                assign rd_ptr_l[gi]  = rd_ptr;
                assign _unused_idx[gi] = ^{sync_wr_idx_flat[gi], sync_idx_sync1[gi],
                                           ep_anchor_idx_flat[gi],
                                           ep_anchor_cnt_flat[gi]};
            end
            wire _unused_sync = ^{_unused_idx, sync_seen_flat, sync_seen_sync1};
            assign epoch_anchored_o = 1'b0;   // anchor not in this config
            assign epoch_span_o     = '0;
        end
    endgenerate

endmodule

`default_nettype wire
