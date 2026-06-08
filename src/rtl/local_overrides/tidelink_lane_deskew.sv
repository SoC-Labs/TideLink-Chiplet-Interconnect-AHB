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
// SoC Labs 2026-06-08 — CONTENT-ANCHORED RE-PRIME ON THE SYNC WORD
// -----------------------------------------------------------------------------
// PROBLEM with the original training-edge re-prime (kept below as the BOOTSTRAP
// aligner, but insufficient as the steady-state aligner):
//   The original design captured each lane's FIRST data word after
//   training_mode falls as FIFO[0]. But training_mode is 2-flop-synced INTO
//   each lane's own clock (g_tm_sync) at a DIFFERENT phase per lane, so the
//   "first data word" each lane latches can be a DIFFERENT source word once the
//   lanes are word-skewed. mem[0] is then NOT the same TX word across lanes, the
//   assembled 128-bit bus mixes source words, and the framer mis-locks (it reads
//   a short-packet length byte at the wrong 16-bit offset -> is_long_pkt=1, no
//   SOP). On silicon this is the intermittent "12/12 byte-perfect one run,
//   0/12 long=1 the next" M->S delivery — the training-edge prime happens to
//   align on a lucky run and mis-aligns otherwise.
//
// FIX (the Interlaken lane-alignment approach): anchor word-0 on a KNOWN content
// marker that the TX ships SIMULTANEOUSLY on all 8 lanes. The TX glue
// (WavD2DGpio.v) injects a 128-bit SYNC word every 32 idle words in DATA mode;
// lane N carries the fixed 16-bit slice SYNC_SLICE[N]. Each lane detects ITS OWN
// slice in its own clock domain and captures the SYNC WORD ITSELF as FIFO[0]
// (wr_ptr origin reset to 1 so the following real data lands at [1], [2]...).
// Because the TX launched the SYNC on all lanes in the same TX word, every lane's
// FIFO[0] is provably the SAME source word — so rd_ptr=0 across lanes reassembles
// the COHERENT 128-bit SYNC word REGARDLESS of cross-lane skew. The framer then
// (a) matches io_link_data==SYNC_WORD and increments the sync_detected obs
// counter (HW proof the deskew aligned), and (b) strips it + re-syncs the packet
// boundary on it (WlinkRxLinkLayer.v:289-296). The real data immediately after is
// now lane-aligned and frames cleanly.
//
// CROSS-LANE COORDINATION (same-instance guarantee):
//   Lanes see their SYNC at different real-times (skew). The SYNC repeats every
//   32 words while max cross-lane skew is ~7 words, so once the FIRST lane sees
//   a SYNC, all others see the SAME instance within ~7 words << 32. We:
//     * per lane: on SYNC detect, set wr_ptr=0, write post-SYNC word at [0],
//       and TOGGLE a sync_seen marker (CDC-synced to the read domain);
//     * read side: when the first fresh sync_seen arrives, open a bounded
//       collection window (SYNC_WIN words). If ALL 8 lanes report a fresh
//       sync within the window, RE-PRIME (rd_ptr=0, primed=0, rebuild cushion)
//       so the next read starts at the coherent post-SYNC word. If the window
//       expires with <8 lanes (a missed/garbled SYNC on some lane), DISCARD and
//       wait for the next SYNC instance — never re-prime on a partial set.
//   FIFO DEPTH=8 holds the worst-case ~7-word skew between the leading lane's
//   post-SYNC write and the trailing lane's, so no lane overruns before the
//   read side re-primes.
//
// The training-mode re-prime remains the BOOTSTRAP (first alignment out of
// training, before any SYNC has been seen); the SYNC re-prime is the
// STEADY-STATE re-alignment that makes delivery robust to per-lane word skew.
// Prime-and-continuous bubble-fix behaviour (2026-06-04) is preserved unchanged.
//
// NO-OP for the zero-skew baseline: with zero skew all lanes see SYNC on the
// same out_clk edge, the window closes in 1 word, and the re-prime lands rd/wr
// at the same origin the training prime already established — bit-identical
// output. (Validated: cocotb/tidelink_top_pair test_01..11 stay green.)
//
// Author: SoC Labs (2026-06-03 — Bug A causal-chain fix;
//                    2026-06-04 — prime-and-continuous bubble fix;
//                    2026-06-08 — SYNC content-anchored re-prime)
// =============================================================================

`default_nettype none

module tidelink_lane_deskew #(
    parameter int LANES     = 8,
    parameter int WIDTH     = 16,
    parameter int DEPTH_LOG = 3,           // FIFO depth = 1<<DEPTH_LOG = 8 entries
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
    //   sync_seen_tgl[gi] toggles each time lane gi ANCHORS on its SYNC slice,
    //   i.e. writes the SYNC word at FIFO[0] and restarts wr_ptr. A toggle (not
    //   a pulse) survives the 2-flop CDC into out_clk regardless of the relative
    //   clock phases. The TX emits the SYNC only once per 32 idle words, so this
    //   toggles at most once per ~32 words per lane (no per-word thrash).
    reg [LANES-1:0]       sync_seen_tgl;

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_lane_write
            // This lane's 16-bit slice of the SYNC word.
            localparam [WIDTH-1:0] SYNC_SLICE = SYNC_WORD[gi*WIDTH +: WIDTH];
            wire this_word_is_sync =
                (lane_data[gi*WIDTH +: WIDTH] == SYNC_SLICE) & ~tm_sync1[gi];
            always @(posedge lane_clk[gi] or negedge rst_n) begin
                if (!rst_n) begin
                    wr_ptr[gi]       <= {(DEPTH_LOG+1){1'b0}};
                    sync_seen_tgl[gi]<= 1'b0;
                end else if (tm_sync1[gi]) begin
                    // Training mode (per-lane synced): hold FIFO empty AND reset
                    // this lane's write pointer to 0. This mirrors the read-side
                    // re-prime (rd_ptr<=0 / primed<=0 in the out_clk domain) so
                    // every training->data cycle restarts wr and rd from the same
                    // origin and word-0 of each lane re-aligns (BOOTSTRAP).
                    wr_ptr[gi]   <= {(DEPTH_LOG+1){1'b0}};
                end else if (this_word_is_sync) begin
                    // SYNC slice on this lane's bus: ANCHOR. Store the SYNC word
                    // ITSELF at FIFO[0] (so the read side reassembles the COHERENT
                    // 128-bit SYNC word as read-word-0 across all lanes; the framer
                    // then matches io_link_data==SYNC_WORD, increments the
                    // sync_detected counter, AND strips/re-syncs on it) and restart
                    // wr_ptr at 1 so the following real data lands at [1], [2]...
                    // Toggle the marker so the read side learns this lane anchored.
                    mem[gi][0]        <= lane_data[gi*WIDTH +: WIDTH];
                    wr_ptr[gi]        <= {{(DEPTH_LOG){1'b0}}, 1'b1}; // ptr -> 1
                    sync_seen_tgl[gi] <= ~sync_seen_tgl[gi];
                end else begin
                    // Data mode, ordinary word: capture this lane's 16-bit word.
                    mem[gi][wr_ptr[gi][DEPTH_LOG-1:0]] <= lane_data[gi*WIDTH +: WIDTH];
                    wr_ptr[gi] <= wr_ptr[gi] + 1'b1;
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
    // edge detector that fires a one-out_clk pulse each time a lane reports
    // a fresh SYNC re-alignment.
    // -----------------------------------------------------------------
    reg [LANES-1:0] sst_sync0, sst_sync1, sst_sync2;
    wire [LANES-1:0] lane_sync_pulse = sst_sync1 ^ sst_sync2; // toggle edge
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

    // -----------------------------------------------------------------
    // Common read pointer + all-lanes-have-data gate
    // -----------------------------------------------------------------
    reg  [DEPTH_LOG:0] rd_ptr;
    wire [LANES-1:0]   lane_has_data;

    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_has
            assign lane_has_data[gi] = (wr_ptr_sync1[gi] != rd_ptr);
        end
    endgenerate

    wire all_ready = &lane_has_data;

    // -----------------------------------------------------------------
    // SYNC re-prime collector (out_clk domain).
    //   sync_collect[gi] latches once lane gi reports a fresh SYNC pulse.
    //   A bounded window (sync_win_ctr) starts when the FIRST lane reports;
    //   if ALL lanes collect within the window, sync_reprime fires for one
    //   out_clk and the read FSM re-primes (rd_ptr=0, primed=0). If the window
    //   expires with <ALL lanes, the partial set is discarded (wait for next
    //   SYNC instance). This guarantees all lanes align to the SAME instance.
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
    // -----------------------------------------------------------------
    localparam int PRIME_THRESH = DEPTH / 2;

    reg primed;

    wire [LANES-1:0] lane_primed;
    generate
        for (gi = 0; gi < LANES; gi = gi + 1) begin : g_prime
            wire [DEPTH_LOG:0] occ = wr_ptr_sync1[gi] - rd_ptr;
            assign lane_primed[gi] = (occ >= PRIME_THRESH[DEPTH_LOG:0]);
        end
    endgenerate
    wire all_primed = &lane_primed;

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
    //   1. training (train_sync1)   -> re-prime origin, no reads  (BOOTSTRAP)
    //   2. sync_reprime pulse        -> re-align rd_ptr to the SYNC-anchored
    //                                   word-0 of every lane, rebuild cushion
    //   3. !primed                   -> build cushion, no reads
    //   4. all_ready                 -> one word per out_clk
    //   else                         -> underrun safety, hold out_data
    //
    // On sync_reprime: every lane's mem[0] is the SYNC word (the SAME source word
    // on all lanes). Setting rd_ptr=0 + primed=0 makes the next read start at that
    // coherent SYNC word once the cushion rebuilds — the framer counts+strips it
    // and re-syncs, then reads the lane-aligned real data behind it. We do NOT
    // emit a word on the re-prime cycle (out_data holds) so no torn word escapes.
    // -----------------------------------------------------------------
    integer ri;
    always @(posedge out_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr   <= {(DEPTH_LOG+1){1'b0}};
            primed   <= 1'b0;
            out_data <= {(LANES*WIDTH){1'b0}};
        end else if (train_sync1) begin
            // Training: re-prime from scratch, no reads (BOOTSTRAP).
            rd_ptr <= {(DEPTH_LOG+1){1'b0}};
            primed <= 1'b0;
        end else if (sync_reprime) begin
            // SYNC re-align: snap read origin to the per-lane post-SYNC word-0.
            rd_ptr <= {(DEPTH_LOG+1){1'b0}};
            primed <= 1'b0;
        end else if (!primed) begin
            // Build the cushion before the first read; latch primed once every
            // lane has >= PRIME_THRESH synced words. No out_data update yet.
            if (all_primed) begin
                primed <= 1'b1;
            end
        end else if (all_ready) begin
            // Primed steady state: one word per out_clk. all_ready stays high
            // for frequency-locked lanes (occupancy holds ~PRIME_THRESH).
            for (ri = 0; ri < LANES; ri = ri + 1) begin
                out_data[ri*WIDTH +: WIDTH] <= mem[ri][rd_ptr[DEPTH_LOG-1:0]];
            end
            rd_ptr <= rd_ptr + 1'b1;
        end
        // else: underrun safety -- hold out_data stable
    end

endmodule

`default_nettype wire
