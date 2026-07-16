// =============================================================================
// tb_deskew.sv — thin cocotb test wrapper around tidelink_lane_deskew.
//
// The DUT's lane_clk / lane_data are PACKED vector ports. cocotb cannot cleanly
// (a) take a RisingEdge on a single bit of a packed input vector, nor (b) drive
// a 16-bit slice of a packed input without an X-prone read-modify-write. This
// wrapper exposes per-lane SCALAR clocks (lane_clk0..7) and per-lane 16-bit
// data ports (lane_data0..7), concatenating them onto the DUT's packed buses.
// out_data is exposed split per-lane too for convenient checking, plus the raw
// 128-bit out_data for whole-word compares.
//
// 2026-06-17: targets the V2 deskew (deps/tidelink-phy/rtl/tidelink_lane_deskew
// .sv). Adds the new lane_mask input (REDUCED-LANE link) and surfaces out_valid
// + the epoch observables so the masked-subset readiness fix is testable. The
// DUT's training-mode port is `training_mode_i`; the EPOCH_ANCHOR_EN param is
// overridable via TB_EPOCH_ANCHOR_EN (default 0 = occupancy-only path).
//
// 2026-06-22: surface SYNC_REANCHOR_EN (overridable via TB_SYNC_REANCHOR_EN,
// default 0) so the SYNC-beacon re-anchor path can be unit-tested directly. It
// is MUTUALLY EXCLUSIVE with EPOCH_ANCHOR_EN (the DUT $fatal's if both are set),
// so a SYNC_REANCHOR build must pass TB_EPOCH_ANCHOR_EN=0.
//
// Pure structural — no behaviour added. Faithful to the DUT.
// =============================================================================
`default_nettype none

module tb_deskew #(
    parameter bit EPOCH_ANCHOR_EN  = 1'b0,
    parameter bit SYNC_REANCHOR_EN = 1'b0,
    // 2026-06-22: expose the re-anchor's per-lane SYNC-slice Hamming tolerance so
    // the marginal-eye test can prove EXACT (TOL=0) FAILS while TOLERANT (TOL=4)
    // COHERES on the same bit-errored SYNC slices. Default 4 = the DUT default.
    parameter int unsigned SYNC_REANCHOR_TOL = 4,
    // 2026-06-23: expose the self-gating periodic-confirm depth so the poison test
    // can prove K>=2 REJECTS the pre-SYNC poison (coheres without any SW clear)
    // while K=1 (degenerate first-arrival latch) STILL breaks under poison — the
    // negative control proving the consecutive-consistent gate is the fix.
    parameter int unsigned SYNC_CONFIRM = 2
) (
    input  wire        rst_n,
    input  wire        training_mode,
    input  wire        out_clk,

    input  wire [7:0]  lane_mask,

    // 2026-06-23: STICKY-POISON re-arm clear pulse (out_clk domain), the unit-
    // test model of WavD2DGpio's sync_obs_clr_pulse (SoC 0x44032100[5]). Default
    // 0 (do_reset drives it) => bit-identical to the pre-fix capture.
    input  wire        sync_obs_clr,

    input  wire        lane_clk0, lane_clk1, lane_clk2, lane_clk3,
    input  wire        lane_clk4, lane_clk5, lane_clk6, lane_clk7,

    input  wire [15:0] lane_data0, lane_data1, lane_data2, lane_data3,
    input  wire [15:0] lane_data4, lane_data5, lane_data6, lane_data7,

    output wire [127:0] out_data,
    output wire         out_valid,
    output wire         epoch_anchored,
    output wire [5:0]   epoch_span,
    output wire [7:0]   sync_seen_vec,   // 2026-06-23 per-lane out_clk-synced sync_seen
    output wire [39:0]  sync_dist_vec,   // 2026-06-25 per-lane out_clk-synced SYNC Hamming distance (winscan metric)

    // 2026-06-23: SYNC re-anchor INTERNAL observation taps (read-only hierarchical
    // refs) so the silicon-debug experiments can see WHY the latch does/does not
    // fire: per-lane write-side sync_seen, the out_clk-synced seen vector, the
    // all_sync_seen fold, the rd-pointer/span safety gate, and the reanchored
    // latch. All gated to 0 when SYNC_REANCHOR_EN=0 (the g_reanchor block is
    // pruned). Pure observation — does not alter DUT behaviour.
    output wire [7:0]   obs_sync_seen_wr,    // write-side per-lane sync_seen_l
    output wire [7:0]   obs_sync_seen_sync1, // out_clk-synced per-lane seen
    output wire         obs_all_sync_seen,   // &(seen | ~mask)
    output wire         obs_sr_rd_safe,      // rd_ptr >= span gate
    output wire         obs_reanchored       // the latch
);

    wire [7:0]   lane_clk  = { lane_clk7, lane_clk6, lane_clk5, lane_clk4,
                               lane_clk3, lane_clk2, lane_clk1, lane_clk0 };

    wire [127:0] lane_data = { lane_data7, lane_data6, lane_data5, lane_data4,
                               lane_data3, lane_data2, lane_data1, lane_data0 };

    tidelink_lane_deskew #(
        .EPOCH_ANCHOR_EN   (EPOCH_ANCHOR_EN),
        .SYNC_REANCHOR_EN  (SYNC_REANCHOR_EN),
        .SYNC_REANCHOR_TOL (SYNC_REANCHOR_TOL),
        .SYNC_CONFIRM      (SYNC_CONFIRM)
    ) u_dut (
        .rst_n           (rst_n),
        .lane_clk        (lane_clk),
        .lane_data       (lane_data),
        .training_mode_i (training_mode),
        .lane_mask       (lane_mask),
        .out_clk         (out_clk),
        .sync_obs_clr_i  (sync_obs_clr),
        .out_data        (out_data),
        .out_valid       (out_valid),
        .epoch_anchored_o(epoch_anchored),
        .epoch_span_o    (epoch_span),
        .sync_seen_vec_o (sync_seen_vec),
        .sync_dist_vec_o (sync_dist_vec)   // 2026-06-25 winscan metric
    );

    // ---- SYNC re-anchor observation taps (hierarchical, read-only) ----------
    // Guarded by SYNC_REANCHOR_EN: the g_sync_capture / g_reanchor scopes only
    // exist when enabled; tie the taps to 0 otherwise so the OFF/EPOCH builds
    // still elaborate.
    genvar oi;
    generate
        if (SYNC_REANCHOR_EN) begin : g_obs
            for (oi = 0; oi < 8; oi = oi + 1) begin : g_obs_lane
                assign obs_sync_seen_wr[oi] =
                    u_dut.g_lane_write[oi].g_sync_capture.sync_seen_l;
            end
            assign obs_sync_seen_sync1 = u_dut.sync_seen_sync1;
            assign obs_all_sync_seen   = u_dut.g_reanchor.all_sync_seen;
            assign obs_sr_rd_safe      = u_dut.g_reanchor.sr_rd_safe;
            assign obs_reanchored      = u_dut.g_reanchor.reanchored;
        end else begin : g_obs_off
            assign obs_sync_seen_wr    = 8'h00;
            assign obs_sync_seen_sync1 = 8'h00;
            assign obs_all_sync_seen   = 1'b0;
            assign obs_sr_rd_safe      = 1'b0;
            assign obs_reanchored      = 1'b0;
        end
    endgenerate

endmodule

`default_nettype wire
