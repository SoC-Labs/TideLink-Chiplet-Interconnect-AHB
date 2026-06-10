// =============================================================================
// tidelink_lane_deskew.sv — 8-lane cross-lane deskew FIFO
//   *** LOCAL OVERRIDE of deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv ***
//   (flist/tidelink_fpga.flist points here; the submodule copy is left pristine.)
//
// Each lane (gpiorx_N) deserialises 16 bits onto its own io_link_clk_N word
// clock. Because lanes' count counters reset/start at different pad_clk cycles
// (per-lane calibration timing), the 8 word clocks have persistent phase
// offsets of up to ~7 word-periods. The framer (WlinkRxLinkLayer) currently
// samples all 8 lanes on lane-0's clock — but at any given lane-0 edge, lanes
// 1..7 may be presenting words captured at DIFFERENT pad_clk cycles. The
// assembled 128-bit io_link_rx_rx_link_data is then a mix of bytes from
// different time-points, corrupting framer ECC and preventing SOP detection.
//
// This module absorbs the cross-lane skew with a per-lane shallow FIFO.
//
// =============================================================================
// SoC Labs 2026-06-08 — NON-DESTRUCTIVE SYNC ANCHOR (per-lane read pointers)
// -----------------------------------------------------------------------------
// PROBLEM with the original training-edge re-prime (kept below as the BOOTSTRAP
// aligner, but insufficient as the steady-state aligner):
//   The original design captured each lane's FIRST data word after
//   training_mode falls as FIFO[0]. But training_mode is 2-flop-synced INTO
//   each lane's own clock (g_tm_sync) at a DIFFERENT phase per lane, so the
//   "first data word" each lane latches can be a DIFFERENT source word once the
//   lanes are word-skewed. mem[0] is then NOT the same TX word across lanes, the
//   assembled 128-bit bus mixes source words, and the framer mis-locks.
//
// PROBLEM with the FIRST SYNC-anchor attempt (2026-06-08 morning, REGRESSED):
//   That version, on a SYNC slice match, wrote the SYNC to mem[0] AND reset the
//   lane's wr_ptr to 1 INDEPENDENTLY, per lane. A SINGLE lane anchoring — a
//   genuine SYNC, OR (1/65536 per lane per word) a SPURIOUS 16-bit data-word
//   match on ordinary traffic incl. the CR/CRACK calibration handshake —
//   corrupted THAT lane's FIFO alignment relative to the others, with no
//   collective re-prime. Zero-skew test_01/test_03 regressed.
//
// FIX (this file): make the SYNC anchor NON-DESTRUCTIVE.
//   * WRITE side ALWAYS writes the incoming word at mem[wr_ptr] and wr_ptr++ —
//     it NEVER resets wr_ptr on a SYNC. On a SYNC slice match it ADDITIONALLY
//     records the slot it just wrote the SYNC into (sync_pos[gi] <= wr_ptr) and
//     toggles a marker (sync_seen_tgl[gi]). A spurious single-lane match thus
//     only updates that lane's sync_pos + marker; the FIFO contents and the
//     write pointer are UNTOUCHED, so no lane's alignment is ever disrupted.
//   * READ side uses ONE common read pointer rd_ptr plus a per-lane RELATIVE
//     skew offset lane_off[gi] (default 0). The effective read address for lane
//     gi is (rd_ptr + lane_off[gi]). rd_ptr always advances +1 per read; the
//     offsets are static between re-primes. Re-alignment happens ONLY on the
//     COLLECTIVE re-prime: a bounded window collects fresh SYNC markers from all
//     8 lanes; only when ALL 8 report within the window does sync_reprime fire,
//     recomputing lane_off[gi] from the recorded SYNC slots: each lane's slot
//     minus the MINIMUM slot across lanes (offsets always >= 0, never wrap),
//     GATED so it is applied only when the cross-lane slot SPREAD >= 2 (real
//     word skew) and CLAMPED < PRIME_THRESH (read stays inside the cushion).
//     When the spread is <= 1 (zero skew within the +/-1 CDC sampling jitter of
//     the phase-staggered lane clocks) ALL offsets are forced to 0. Reading each
//     lane at its corrected address presents every lane's copy of the SAME
//     source word on one out_clk -> coherent 128-bit assembly, incl. the SYNC
//     itself (which the framer strips + re-syncs on; WlinkRxLinkLayer.v:289-296).
//   * CRUCIALLY the common rd_ptr is NEVER jumped and reads NEVER stall on a
//     re-prime — only the relative offsets change. So a re-prime does not lose
//     or duplicate in-flight words; sustained traffic flows through unbroken.
//   * If the window expires with <8 lanes (a missed/garbled SYNC on some lane,
//     OR a partial set from spurious matches), the partial set is DISCARDED and
//     no re-prime occurs — no FIFO is ever disrupted.
//
// NO-OP for the zero-skew baseline: with zero skew every lane records the SAME
// SYNC slot, so every lane_off[gi] computes to 0 and every lane reads mem[rd_ptr]
// — bit-identical to a single common read pointer (the pristine bubble-fix
// behaviour). A spurious data-word match on a lone lane only nudges that lane's
// sync_pos + marker; the collector discards the partial set on window expiry,
// and the offsets/rd_ptr are untouched -> functional no-op for sustained traffic
// too. (Validated: cocotb/tidelink_top_pair test_01..15.)
//
// CROSS-LANE COORDINATION (same-instance guarantee):
//   The SYNC repeats every 32 words while max cross-lane skew is ~7 words, so
//   once the FIRST lane records a SYNC, all others record the SAME instance
//   within ~7 words << 32. FIFO DEPTH=8 holds the worst-case ~7-word skew
//   between the leading lane's post-SYNC write and the trailing lane's.
//
// The training-mode re-prime remains the BOOTSTRAP (first alignment out of
// training, before any SYNC has been seen); the SYNC re-prime is the
// STEADY-STATE re-alignment that makes delivery robust to per-lane word skew.
// Prime-and-continuous bubble-fix behaviour (2026-06-04) is preserved unchanged.
//
// Author: SoC Labs (2026-06-03 — Bug A causal-chain fix;
//                    2026-06-04 — prime-and-continuous bubble fix;
//                    2026-06-08 — SYNC content-anchored re-prime;
//                    2026-06-08 — NON-DESTRUCTIVE per-lane-read-pointer redesign)
// =============================================================================

`default_nettype none

module tidelink_lane_deskew #(
    parameter int LANES     = 8,
    parameter int WIDTH     = 16,
    parameter int DEPTH_LOG = 4,           // FIFO depth = 1<<DEPTH_LOG = 16 entries
                                           // (must hold PRIME_THRESH cushion + the
                                           //  worst-case ~7-word cross-lane skew +
                                           //  the 2-flop wr_ptr CDC lag; DEPTH=8 was
                                           //  too shallow -> skewed lane never primed)
    // 128-bit SYNC word shipped by the TX (WavD2DGpio.v PHY_SYNC_WORD). Lane N
    // carries SYNC_WORD[16*N+15 : 16*N]. MUST bit-match the TX constant and the
    // RX framer SYNC_WORD (WlinkRxLinkLayer.v).
    parameter [127:0] SYNC_WORD =
        128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00,
    // Bounded window (in out_clk word periods) within which ALL lanes must
    // report a fresh SYNC for a re-prime to be accepted. Must exceed the
    // worst-case cross-lane skew (~7 words) AND the per-lane sync_seen CDC
    // latency (2 flops), and stay well under the SYNC period (32) so two SYNC
    // instances never overlap in one window. 16 = comfortable midpoint.
    parameter int SYNC_WIN  = 16
) (
    input  wire                          rst_n,
    // Per-lane write side (each lane has its own word clock)
    input  wire [LANES-1:0]              lane_clk,
    input  wire [LANES*WIDTH-1:0]        lane_data,
    // Training-end gate: hold FIFO writes OFF while training_mode=1.
    // First lane-clock edge AFTER training_mode falls captures the lane's
    // first DATA word as FIFO[0] (BOOTSTRAP align). Driven from the
    // calibrator's effective_training_mode signal (active-high during training).
    input  wire                          training_mode,
    // Common read side
    input  wire                          out_clk,
    output reg  [LANES*WIDTH-1:0]        out_data
);

    localparam int DEPTH = 1 << DEPTH_LOG;

    // -----------------------------------------------------------------
    // Per-lane: 2-flop sync of training_mode into the lane's clock
    // domain. After this, each lane has its own copy of
    // training_mode_sync. We write to the lane's FIFO only when
    // training_mode_sync == 0 (i.e. data mode).
    // -----------------------------------------------------------------
    // Per-lane unpacked arrays so each lane has its own bit and each
    // generated always_ff has a single driver scope (Verilator MULTIDRIVEN
    // warning otherwise).
    reg tm_sync0 [LANES-1:0];
    reg tm_sync1 [LANES-1:0];

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_tm_sync
            always @(posedge lane_clk[gi] or negedge rst_n) begin
                if (!rst_n) begin
                    tm_sync0[gi] <= 1'b1;
                    tm_sync1[gi] <= 1'b1;
                end else begin
                    tm_sync0[gi] <= training_mode;
                    tm_sync1[gi] <= tm_sync0[gi];
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------
    // Per-lane FIFO storage + write pointer
    // -----------------------------------------------------------------
    reg [WIDTH-1:0]       mem      [LANES-1:0] [DEPTH-1:0];
    reg [DEPTH_LOG:0]     wr_ptr   [LANES-1:0];   // 1 extra bit for full vs empty

    // Per-lane SYNC detect + sync_seen toggle marker (write-clk domain).
    //   sync_seen_tgl[gi] toggles each time lane gi sees its SYNC slice on the
    //   bus. A toggle (not a pulse) survives the 2-flop CDC into out_clk
    //   regardless of the relative clock phases. The TX emits the SYNC only once
    //   per 32 idle words, so this toggles at most once per ~32 words per lane
    //   (no per-word thrash) on genuine SYNC; a spurious 16-bit data match
    //   toggles it too but that only ever feeds the out_clk arrival-time
    //   collector — the FIFO contents and wr_ptr are NEVER disturbed
    //   (non-destructive anchor). sync_pos_full[gi] records the FULL wr_ptr
    //   (DEPTH_LOG+1 bits) at the SYNC write — this directly encodes lane gi's
    //   cross-lane WORD SKEW: the SAME source SYNC word lands at write position
    //   (S + delta[gi]) in each lane, so the relative skew delta is recovered
    //   from the relative sync_pos_full across lanes. The extra (wrap) bit makes
    //   that relative subtraction unambiguous for skews up to DEPTH words.
    reg [LANES-1:0]       sync_seen_tgl;
    reg [DEPTH_LOG:0]     sync_pos_full [LANES-1:0];   // FULL wr_ptr @ SYNC write

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane_write
            // This lane's 16-bit slice of the SYNC word.
            localparam [WIDTH-1:0] SYNC_SLICE = SYNC_WORD[gi*WIDTH +: WIDTH];
            wire this_word_is_sync =
                (lane_data[gi*WIDTH +: WIDTH] == SYNC_SLICE) & ~tm_sync1[gi];
            always @(posedge lane_clk[gi] or negedge rst_n) begin
                if (!rst_n) begin
                    wr_ptr[gi]        <= {(DEPTH_LOG+1){1'b0}};
                    sync_seen_tgl[gi] <= 1'b0;
                    sync_pos_full[gi] <= {(DEPTH_LOG+1){1'b0}};
                end else if (tm_sync1[gi]) begin
                    // Training mode (per-lane synced): hold FIFO empty AND reset
                    // this lane's write pointer to 0. This mirrors the read-side
                    // bootstrap re-prime (rd_ptr<=0 / offsets<=0 in the
                    // out_clk domain) so every training->data cycle restarts wr
                    // and rd from the same origin (BOOTSTRAP).
                    wr_ptr[gi] <= {(DEPTH_LOG+1){1'b0}};
                end else begin
                    // Data mode: ALWAYS write this lane's 16-bit word at the
                    // current slot and advance wr_ptr. NEVER reset wr_ptr on a
                    // SYNC — that is the destructive behaviour we are removing.
                    mem[gi][wr_ptr[gi][DEPTH_LOG-1:0]] <= lane_data[gi*WIDTH +: WIDTH];
                    wr_ptr[gi] <= wr_ptr[gi] + 1'b1;
                    if (this_word_is_sync) begin
                        // Record the FULL write position the SYNC landed at and
                        // toggle the marker. NON-DESTRUCTIVE: only metadata.
                        sync_pos_full[gi] <= wr_ptr[gi];
                        sync_seen_tgl[gi] <= ~sync_seen_tgl[gi];
                    end
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------
    // 2-flop synchronizer of each lane's wr_ptr into out_clk domain.
    // Lane clocks are FREQUENCY-LOCKED to out_clk (same source, same rate);
    // only the PHASE differs. With DEPTH=8 and worst-case skew ~7
    // word-periods, there's ample margin between wr and rd pointers.
    // -----------------------------------------------------------------
    reg [DEPTH_LOG:0] wr_ptr_sync0 [LANES-1:0];
    reg [DEPTH_LOG:0] wr_ptr_sync1 [LANES-1:0];

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_wr_sync
            always @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) begin
                    wr_ptr_sync0[gi] <= {(DEPTH_LOG+1){1'b0}};
                    wr_ptr_sync1[gi] <= {(DEPTH_LOG+1){1'b0}};
                end else begin
                    wr_ptr_sync0[gi] <= wr_ptr[gi];
                    wr_ptr_sync1[gi] <= wr_ptr_sync0[gi];
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------
    // 2-flop sync of the per-lane sync_seen toggle into out_clk, plus an
    // edge detector that fires a one-out_clk pulse each time a lane reports a
    // fresh SYNC. The FULL SYNC write position (sync_pos_full) is also 2-flop
    // synced into out_clk; it is stable for ~32 words after each toggle, so
    // sampling it two flops later is safe. The cross-lane word skew is recovered
    // from the RELATIVE sync_pos_full across lanes, in the (DEPTH_LOG+1)-bit
    // modular space (the wrap bit makes skews up to DEPTH words unambiguous).
    // -----------------------------------------------------------------
    reg [LANES-1:0] sst_sync0, sst_sync1, sst_sync2;
    wire [LANES-1:0] lane_sync_pulse = sst_sync1 ^ sst_sync2; // toggle edge

    reg [DEPTH_LOG:0] spf_sync0  [LANES-1:0];
    reg [DEPTH_LOG:0] spf_synced [LANES-1:0];

    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            sst_sync0 <= {LANES{1'b0}};
            sst_sync1 <= {LANES{1'b0}};
            sst_sync2 <= {LANES{1'b0}};
        end else begin
            sst_sync0 <= sync_seen_tgl;
            sst_sync1 <= sst_sync0;
            sst_sync2 <= sst_sync1;
        end
    end

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_spf_cdc
            always @(posedge out_clk or negedge rst_n) begin
                if (!rst_n) begin
                    spf_sync0[gi]  <= {(DEPTH_LOG+1){1'b0}};
                    spf_synced[gi] <= {(DEPTH_LOG+1){1'b0}};
                end else begin
                    spf_sync0[gi]  <= sync_pos_full[gi];
                    spf_synced[gi] <= spf_sync0[gi];
                end
            end
        end
    endgenerate

    // -----------------------------------------------------------------
    // Common read pointer + per-lane skew offset.
    //
    //   Read address for lane gi = rd_ptr + lane_off[gi]  (mod DEPTH).
    //
    //   lane_off[gi] is a RELATIVE per-lane word-skew correction, default 0.
    //   In the common (zero-skew) case every lane_off[gi] == 0, so every lane
    //   reads mem[rd_ptr] — bit-identical to a single shared read pointer (the
    //   pristine bubble-fix behaviour). The offsets become non-zero ONLY after
    //   a collective SYNC re-prime, and only by the RELATIVE skew between lanes
    //   (each lane's recorded SYNC slot minus the reference lane's). This makes
    //   the SYNC alignment a CONTINUOUS correction baked into the per-lane read
    //   ADDRESS — the master read pointer never jumps and the read cadence is
    //   never stalled, so sustained zero-skew traffic is a true functional
    //   no-op (no mid-stream re-point bubble). Under real word skew the offsets
    //   shear the lanes back into a coherent 128-bit word every cycle.
    // -----------------------------------------------------------------
    reg  [DEPTH_LOG:0] rd_ptr;
    reg  [DEPTH_LOG-1:0] lane_off [LANES-1:0];   // per-lane read-address offset

    // Per-lane effective read address (rd_ptr + that lane's skew offset).
    wire [DEPTH_LOG-1:0] rd_addr_lane [LANES-1:0];
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_rdaddr
            assign rd_addr_lane[gi] =
                rd_ptr[DEPTH_LOG-1:0] + lane_off[gi];
        end
    endgenerate

    // A lane has data while its effective read address has not caught the write
    // pointer. Occupancy uses the FULL-WIDTH rd_ptr (incl. its wrap bit) minus
    // the lane's read offset: occ = wr_ptr_sync1 - rd_ptr - lane_off. A lane
    // read `lane_off` slots ahead has that many fewer readable words. With
    // lane_off==0 this is exactly the pristine (wr_ptr_sync1 - rd_ptr).
    wire [LANES-1:0]   lane_has_data;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_has
            wire [DEPTH_LOG:0] occ_h =
                wr_ptr_sync1[gi] - rd_ptr
                  - {{(DEPTH_LOG+1-DEPTH_LOG){1'b0}}, lane_off[gi]};
            assign lane_has_data[gi] = (occ_h != {(DEPTH_LOG+1){1'b0}}) &
                                       ~occ_h[DEPTH_LOG];
        end
    endgenerate

    wire all_ready = &lane_has_data;

    // -----------------------------------------------------------------
    // SYNC re-prime collector (out_clk domain).
    //   sync_collect[gi] latches once lane gi reports a fresh SYNC pulse.
    //   A bounded window (sync_win_ctr) starts when the FIRST lane reports;
    //   if ALL lanes collect within the window, sync_reprime fires for one
    //   out_clk and the read FSM recomputes relative offsets (lane_off[gi],
    //   primed<=0). If the window expires with <ALL lanes, the partial set is
    //   discarded (wait for next SYNC instance). This guarantees all lanes
    //   align to the SAME instance.
    // -----------------------------------------------------------------
    reg [LANES-1:0]    sync_collect;
    reg                sync_collecting;
    reg [$clog2(SYNC_WIN+1)-1:0] sync_win_ctr;
    reg                sync_reprime;          // 1-cycle re-prime command

    wire [LANES-1:0]   sync_collect_next = sync_collect | lane_sync_pulse;
    wire               any_new_pulse     = |lane_sync_pulse;

    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_collect    <= {LANES{1'b0}};
            sync_collecting <= 1'b0;
            sync_win_ctr    <= '0;
            sync_reprime    <= 1'b0;
        end else begin
            sync_reprime <= 1'b0;   // default: pulse low
            if (!sync_collecting) begin
                // Idle: wait for the first lane to report a fresh SYNC.
                if (any_new_pulse) begin
                    sync_collect    <= lane_sync_pulse;
                    sync_collecting <= 1'b1;
                    sync_win_ctr    <= SYNC_WIN[$clog2(SYNC_WIN+1)-1:0];
                    // Single-lane corner (LANES==1 / all already in): complete now.
                    if (&lane_sync_pulse) begin
                        sync_reprime    <= 1'b1;
                        sync_collecting <= 1'b0;
                        sync_collect    <= {LANES{1'b0}};
                    end
                end
            end else begin
                if (&sync_collect_next) begin
                    // All lanes have now reported within the window -> re-prime.
                    sync_reprime    <= 1'b1;
                    sync_collecting <= 1'b0;
                    sync_collect    <= {LANES{1'b0}};
                end else if (sync_win_ctr == '0) begin
                    // Window expired with a partial set -> discard, wait for the
                    // next SYNC instance (do NOT re-prime on a partial set).
                    sync_collecting <= 1'b0;
                    sync_collect    <= {LANES{1'b0}};
                end else begin
                    sync_collect <= sync_collect_next;
                    sync_win_ctr <= sync_win_ctr - 1'b1;
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // PRIME-AND-CONTINUOUS read controller (bubble-bug fix, 2026-06-04)
    //
    // Do not read until EVERY lane has built a cushion of >= PRIME_THRESH synced
    // words (latch `primed`). The lanes are FREQUENCY-LOCKED (same forwarded
    // pad_clk / 16; only PHASE differs), so once primed the read rate equals the
    // write rate and each lane's occupancy holds steady at ~PRIME_THRESH, so
    // all_ready stays HIGH for the whole burst => zero bubbles. all_ready is kept
    // as an underrun safety so a genuine starvation still holds out_data.
    //
    // PRIME_THRESH must exceed the 2-flop wr_ptr_sync latency (2) plus worst-
    // case phase jitter. DEPTH/2 (=4 for DEPTH=8) gives 2 words of margin.
    // Occupancy is now computed per lane against that lane's own read pointer.
    // -----------------------------------------------------------------
    // PRIME_THRESH is the read-start cushion. It is HELD AT 4 (not DEPTH/2): with
    // DEPTH=16 a DEPTH/2=8 cushion plus a 7-word offset plus the 2-flop lag could
    // not coexist in the FIFO. 4 leaves room for off<=DEPTH-PRIME_THRESH-3 (=9).
    localparam int PRIME_THRESH = 4;

    reg primed;

    wire [LANES-1:0] lane_primed;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_prime
            // Occupancy measured against the lane's EFFECTIVE read address
            // (rd_ptr + lane_off), so a lane carrying a positive skew offset
            // must build a deeper cushion before it is considered primed.
            wire [DEPTH_LOG:0] occ =
                wr_ptr_sync1[gi] - rd_ptr
                  - {{(DEPTH_LOG+1-DEPTH_LOG){1'b0}}, lane_off[gi]};
            assign lane_primed[gi] = ~occ[DEPTH_LOG] &
                                     (occ >= PRIME_THRESH[DEPTH_LOG:0]);
        end
    endgenerate
    wire all_primed = &lane_primed;

    // -----------------------------------------------------------------
    // Wrap/jitter-immune relative skew-offset computation — PIPELINED.
    //
    // The SAME source SYNC word lands at write position (S + delta[gi]) in each
    // lane, where delta[gi] is lane gi's cross-lane WORD SKEW. spf_synced[gi] is
    // that write position (the FULL DEPTH_LOG+1-bit wr_ptr at the SYNC write),
    // CDC'd into out_clk. The RELATIVE skew of lane gi is recovered as the
    // modular distance of spf_synced[gi] from the lane that wrote its SYNC
    // EARLIEST (smallest write position) — done in the (DEPTH_LOG+1)-bit modular
    // space so a slot wrap-straddle (e.g. lane at 7 vs lane at 0) yields the true
    // small distance, not a spurious large one. To read every lane's copy of the
    // SAME source word at one rd_ptr, lane gi must be read deeper by exactly that
    // distance => off[gi] = (spf[gi] - spf_min) mod DEPTH.
    //
    // GATE on the modular SPREAD so a zero-skew link is an exact no-op:
    //   * spread <= 1  => within +/-1 CDC sampling jitter of the phase-staggered
    //                     lane clocks: force ALL offsets to 0 => every lane reads
    //                     mem[rd_ptr], bit-identical to the pristine single
    //                     common read pointer (no regression).
    //   * spread >= 2  => genuine word skew: apply the modular distance, clamped
    //                     < PRIME_THRESH so a read never addresses past the
    //                     primed cushion (no read-ahead of unwritten slots).
    //
    // Reference choice: we pick the lane whose modular distance from lane 0 is
    // the largest as the "earliest" (it wrote its SYNC first, deepest FIFO); all
    // other lanes measure a smaller-or-equal distance from it, so offsets are
    // >= 0 and bounded by the true skew.
    //
    // *** FPGA TIMING (2026-06-10): at DEPTH_LOG=4 (DEPTH=16) the single-cycle
    // combinational chain
    //   spf_synced -> d0 (8x sub) -> d0_min_s (linear signed-min/8) ->
    //   off_raw (8x sub) -> d_spread (linear max/8) -> off_cand (clamp) ->
    //   lane_off load / off_changed
    // is the MASTER critical path (WNS = -1.16 ns on the ~25 MHz out_clk/link
    // domain). DEPTH=8 closed; the wider 5-bit (MW=DEPTH_LOG+1) math at DEPTH=16
    // added the levels that broke it. KEY INSIGHT: lane_off only changes on a
    // sync_reprime, which fires at most once per SYNC period (~32 out_clk), and
    // spf_synced is STABLE for ~32 out_clk after each SYNC toggle (see g_spf_cdc
    // header). So the expensive recompute need NOT be single-cycle — it is spread
    // across a 4-stage out_clk PIPELINE that continuously tracks spf_synced. Each
    // stage registers one reduction so no single combinational path spans the
    // whole chain. The registered result off_cand_r[gi] is what sync_reprime
    // latches into lane_off. Because spf_synced holds for ~32 cycles >> the 4-cy
    // pipeline latency, off_cand_r is always settled to the current SYNC instance
    // long before sync_reprime fires (the collector window adds further delay),
    // so the pipelined result is bit-identical to the old combinational one.
    //
    //   Stage 1 (d0_r):       d0[gi]    = spf_synced[gi] - spf_synced[0]
    //   Stage 2 (d0_min_r):   d0_min_s  = signed-min over d0_r  (+ pipe d0_r->d0_r2)
    //   Stage 3 (off_raw_r):  off_raw   = d0_r2 - d0_min_r
    //   Stage 4 (off_cand_r): d_spread/skew_present/clamp -> off_cand
    // -----------------------------------------------------------------
    localparam int MW = DEPTH_LOG + 1;          // modular width (full wr_ptr)

    // --- Stage 1: register d0[gi] = spf_synced[gi] - spf_synced[0] (mod 2^MW) ---
    reg [MW-1:0] d0_r [LANES-1:0];
    integer s1;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s1 = 0; s1 < LANES; s1 = s1 + 1)
                d0_r[s1] <= {MW{1'b0}};
        end else begin
            for (s1 = 0; s1 < LANES; s1 = s1 + 1)
                d0_r[s1] <= spf_synced[s1] - spf_synced[0];   // mod 2^MW
        end
    end

    // --- Stage 2: register the SIGNED MINIMUM of d0_r (reference lane), and
    //     pipe d0_r forward (d0_r2) so stage 3 subtracts time-aligned operands. ---
    //
    // Reference lane: the one with the SMALLEST spf (least data in FIFO at SYNC
    // time = started writing LATEST = most delayed by cross-lane skew).
    //
    // CORRECT formula: off[gi] = d0[gi] - d0_min_signed, where d0_min_signed is
    // the MOST NEGATIVE (smallest signed) d0 across all lanes.  In the MW-bit
    // modular space, lanes that started writing LATER have NEGATIVE d0 (wrapped to
    // [2^MW-DEPTH+1..2^MW-1]).  We find the signed minimum using $signed
    // comparison — this correctly handles both:
    //   Case A (no real skew, all d0 near 0): d0_min_s = actual min d0 → off_raw
    //           = spread from minimum → d_spread = real range (0 for uniform d0).
    //   Case B (real skew, some d0 wrap negative): $signed treats wrapped values as
    //           negative → finds the most-lagging lane → off_raw = correct offsets.
    //   Seed with d0_r[0] (NOT zero): a zero seed leaves d0_min_s=0 for uniform
    //   d0 (e.g. {2,2,...}) → spurious offsets → SYNC mis-aligned. SoC Labs.
    reg [MW-1:0] d0_min_r;
    reg [MW-1:0] d0_r2 [LANES-1:0];
    integer si;
    integer s2;
    reg [MW-1:0] d0_min_v;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            d0_min_r <= {MW{1'b0}};
            for (s2 = 0; s2 < LANES; s2 = s2 + 1)
                d0_r2[s2] <= {MW{1'b0}};
        end else begin
            d0_min_v = d0_r[0];   // seed with lane 0; loop picks the signed minimum
            for (si = 1; si < LANES; si = si + 1) begin
                if ($signed(d0_r[si]) < $signed(d0_min_v))
                    d0_min_v = d0_r[si];
            end
            d0_min_r <= d0_min_v;
            for (s2 = 0; s2 < LANES; s2 = s2 + 1)
                d0_r2[s2] <= d0_r[s2];
        end
    end

    // --- Stage 3: register off_raw[gi] = (d0_r2[gi] - d0_min_r) mod 2^MW (lower
    //     DEPTH_LOG bits). ---
    reg [DEPTH_LOG-1:0] off_raw_r [LANES-1:0];
    integer s3;
    reg [MW-1:0] diff3;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s3 = 0; s3 < LANES; s3 = s3 + 1)
                off_raw_r[s3] <= {DEPTH_LOG{1'b0}};
        end else begin
            for (s3 = 0; s3 < LANES; s3 = s3 + 1) begin
                diff3 = d0_r2[s3] - d0_min_r;
                off_raw_r[s3] <= diff3[DEPTH_LOG-1:0];
            end
        end
    end

    // --- Stage 4: register the d_spread reduction, the spread gate, the clamp,
    //     and the final per-lane candidate offset off_cand_r[gi]. ---
    // d_spread = max(off_raw) = true worst-case cross-lane word skew. skew_present
    // gates the whole correction off (force offsets to 0) when the spread is <= 1.
    // CLAMP the applied offset so (PRIME_THRESH + 2-flop CDC lag + off) stays
    // within DEPTH-1 — i.e. off <= DEPTH-PRIME_THRESH-3. With DEPTH=16,
    // PRIME_THRESH=4 this caps off at 9, comfortably >= the worst-case real skew
    // (7), so a skewed lane can ALWAYS build occ >= PRIME_THRESH and prime.
    localparam int OFF_MAX = DEPTH - PRIME_THRESH - 3;   // = 9 for DEPTH=16
    reg [DEPTH_LOG-1:0] off_cand_r [LANES-1:0];
    integer s4;
    reg [DEPTH_LOG-1:0] dspread4;
    reg                 skew4;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s4 = 0; s4 < LANES; s4 = s4 + 1)
                off_cand_r[s4] <= {DEPTH_LOG{1'b0}};
        end else begin
            dspread4 = {DEPTH_LOG{1'b0}};
            for (s4 = 0; s4 < LANES; s4 = s4 + 1)
                if (off_raw_r[s4] > dspread4) dspread4 = off_raw_r[s4];
            skew4 = (dspread4 >= 2);   // <=1 within +/-1 CDC jitter => no-op
            for (s4 = 0; s4 < LANES; s4 = s4 + 1) begin
                off_cand_r[s4] <=
                    ~skew4                                   ? {DEPTH_LOG{1'b0}} :
                    (off_raw_r[s4] > OFF_MAX[DEPTH_LOG-1:0]) ? OFF_MAX[DEPTH_LOG-1:0] :
                                                              off_raw_r[s4];
            end
        end
    end

    // 2-flop synchronize training_mode into the out_clk domain so the read side
    // re-primes from scratch on every training->data cycle.
    reg train_sync0, train_sync1;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            train_sync0 <= 1'b1;
            train_sync1 <= 1'b1;
        end else begin
            train_sync0 <= training_mode;
            train_sync1 <= train_sync0;
        end
    end

    // -----------------------------------------------------------------
    // Read FSM. Priority:
    //   1. training (train_sync1)   -> reset rd_ptr + clear all skew offsets,
    //                                   no reads (BOOTSTRAP)
    //   2. sync_reprime pulse        -> load per-lane RELATIVE skew offsets
    //                                   (off_cand, from the SYNC write positions);
    //                                   the common rd_ptr is UNTOUCHED, no stall
    //   3. !primed                   -> build cushion, no reads
    //   4. all_ready                 -> one word per out_clk (advance rd_ptr)
    //   else                         -> underrun safety, hold out_data
    //
    // On sync_reprime: lane_off[gi] <= off_cand_r[gi] (the wrap-immune,
    // spread-gated, cushion-clamped relative word skew of lane gi versus the
    // earliest-writing lane at the SAME source SYNC word — now the REGISTERED
    // output of the 4-stage pipeline, settled to the current SYNC instance long
    // before sync_reprime fires). Reading lane gi at
    // (rd_ptr + lane_off[gi]) then presents every lane's copy of the SAME source
    // word on one out_clk -> coherent 128-bit assembly, incl. the SYNC itself
    // (which the framer strips + re-syncs on). Because the correction is purely
    // relative, ZERO skew yields all-zero offsets => bit-identical to a single
    // shared read pointer => true no-op for sustained zero-skew traffic (no jump,
    // no stall, no bubble). We hold out_data (no rd_ptr advance) on the reprime
    // cycle so the offset change never emits a torn word.
    // -----------------------------------------------------------------
    // A re-prime that would leave the offsets UNCHANGED (the zero-skew steady
    // state: off_cand == current lane_off, usually all-zero) must NOT perturb
    // the read at all — otherwise it injects a one-cycle bubble every ~32 words
    // that breaks sustained delivery. So gate the alignment STALL on an actual
    // offset change; an unchanged re-prime falls straight through to normal
    // reads (true no-op).
    wire off_changed = (|({off_cand_r[0]} ^ {lane_off[0]})) |
                       (|({off_cand_r[1]} ^ {lane_off[1]})) |
                       (|({off_cand_r[2]} ^ {lane_off[2]})) |
                       (|({off_cand_r[3]} ^ {lane_off[3]})) |
                       (|({off_cand_r[4]} ^ {lane_off[4]})) |
                       (|({off_cand_r[5]} ^ {lane_off[5]})) |
                       (|({off_cand_r[6]} ^ {lane_off[6]})) |
                       (|({off_cand_r[7]} ^ {lane_off[7]}));
    wire do_realign = sync_reprime & off_changed;

    integer ri;
    integer rj;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr   <= {(DEPTH_LOG+1){1'b0}};
            for (rj = 0; rj < LANES; rj = rj + 1)
                lane_off[rj] <= {DEPTH_LOG{1'b0}};
            primed   <= 1'b0;
            out_data <= {(LANES*WIDTH){1'b0}};
        end else if (train_sync1) begin
            // Training: re-prime origin + clear skew offsets, no reads (BOOTSTRAP).
            rd_ptr <= {(DEPTH_LOG+1){1'b0}};
            for (rj = 0; rj < LANES; rj = rj + 1)
                lane_off[rj] <= {DEPTH_LOG{1'b0}};
            primed <= 1'b0;
        end else if (do_realign) begin
            // SYNC re-align (offsets ACTUALLY change): load each lane's
            // wrap-immune, spread-gated, cushion-clamped relative skew offset
            // (off_cand). rd_ptr is left as-is; reads resume next cycle from the
            // corrected addresses; hold out_data this one cycle so the offset
            // step never emits a torn word. In zero skew off_changed is 0 so
            // this branch is never taken (no bubble).
            for (rj = 0; rj < LANES; rj = rj + 1)
                lane_off[rj] <= off_cand_r[rj];
        end else if (!primed) begin
            // Build the cushion before the first read; latch primed once every
            // lane has >= PRIME_THRESH synced words. No out_data update yet.
            if (all_primed) begin
                primed <= 1'b1;
            end
        end else if (all_ready) begin
            // Primed steady state: one word per out_clk. all_ready stays high
            // for frequency-locked lanes (occupancy holds ~PRIME_THRESH). Each
            // lane reads at (rd_ptr + lane_off[gi]); the common rd_ptr advances.
            for (ri = 0; ri < LANES; ri = ri + 1) begin
                out_data[ri*WIDTH +: WIDTH] <= mem[ri][rd_addr_lane[ri]];
            end
            rd_ptr <= rd_ptr + 1'b1;
        end
        // else: underrun safety -- hold out_data stable
    end

endmodule

`default_nettype wire
