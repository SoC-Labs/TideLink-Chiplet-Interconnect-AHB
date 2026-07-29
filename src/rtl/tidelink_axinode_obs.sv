// -----------------------------------------------------------------------------
// TideLink AXI data-node observability (silicon-feedback item I4)
//
// The credit-path OBS registers (OBS_FC_CREDIT @ 0x4403_219C) only surface the
// FCSM_6 SIDEBAND flow-control node. The AXI data nodes (AW/W/B/AR/R on both the
// target and initiator faces of the Wlink AXI2WL bridges) are the paths that
// actually WEDGE on silicon, and there was no APB-visible health field for them.
//
// This block taps the ten AXI channel handshakes (pure fan-out reads — it drives
// NOTHING back into the datapath, so it is behaviourally inert) and produces a
// single packed observability word:
//
//   * a LIVE per-channel "stalled" vector (valid & !ready this cycle),
//   * a STICKY per-channel "wedged" witness (a channel held continuously stalled
//     for >= 2**WEDGE_LOG2 app_clk cycles — a genuine wedge, not transient
//     backpressure, which drops the aggregate low and resets the counter),
//   * STICKY B/R response-error witnesses (a completed handshake carried
//     resp[1] = SLVERR/DECERR), and
//   * an aggregate DATA-NODES-HEALTHY bit = no wedge witness AND no response
//     error, so a firmware poll can diagnose an AXI-node wedge from APB alone.
//
// Detection runs in the AXI (app_clk) domain; the packed word is 2-flop
// synchronised into the register-read (apb_clk) domain. The sticky fields are
// monotonic, so the CDC snapshot is coherent; the live vector is a quasi-static
// debug snapshot (same treatment as the other sync_obs_* probes in the chiplet
// controller). In every current integration apb_clk == app_clk == hclk, so the
// synchroniser is a harmless pipeline there; it keeps the block correct if the
// two clocks are ever separated.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
// -----------------------------------------------------------------------------
`default_nettype none

module tidelink_axinode_obs #(
    // A channel held stalled (valid & !ready) for 2**WEDGE_LOG2 CONSECUTIVE
    // app_clk cycles, with the stall vector unchanged, latches its wedge
    // witness. 12 => 4096 cycles: orders beyond any legal per-word handshake
    // backpressure, so a witness means a real wedge, not congestion.
    parameter int WEDGE_LOG2 = 12
) (
    input  wire        app_clk,   // AXI data-node clock (detection domain)
    input  wire        apb_clk,   // register-read clock (obs output domain)
    input  wire        resetn,    // active-low, synchronous-deassert async-assert

    // Target face (Wlink axi_tgt_0_* — the local AXI master's view). Each channel
    // is "stalled" when valid & !ready regardless of transfer direction.
    input  wire        tgt_aw_valid, input  wire tgt_aw_ready,
    input  wire        tgt_w_valid,  input  wire tgt_w_ready,
    input  wire        tgt_b_valid,  input  wire tgt_b_ready,  input wire tgt_b_err,
    input  wire        tgt_ar_valid, input  wire tgt_ar_ready,
    input  wire        tgt_r_valid,  input  wire tgt_r_ready,  input wire tgt_r_err,

    // Initiator face (Wlink axi_ini_0_* — the remote AXI slave's view).
    input  wire        ini_aw_valid, input  wire ini_aw_ready,
    input  wire        ini_w_valid,  input  wire ini_w_ready,
    input  wire        ini_b_valid,  input  wire ini_b_ready,  input wire ini_b_err,
    input  wire        ini_ar_valid, input  wire ini_ar_ready,
    input  wire        ini_r_valid,  input  wire ini_r_ready,  input wire ini_r_err,

    // Packed observability word (apb_clk domain). Layout:
    //   [ 4: 0] tgt_stall_live  {r, ar, b, w, aw}  — valid & !ready this cycle
    //   [ 9: 5] ini_stall_live  {r, ar, b, w, aw}
    //   [14:10] tgt_wedge_sticky{r, ar, b, w, aw}  — stalled >= 2**WEDGE_LOG2 cyc
    //   [19:15] ini_wedge_sticky{r, ar, b, w, aw}
    //   [20]    tgt_resp_err_sticky — a tgt B/R handshake carried resp[1]
    //   [21]    ini_resp_err_sticky
    //   [22]    any_stall_live      — OR of the live stall vectors
    //   [23]    data_nodes_healthy  — ~(any wedge) & ~(any resp err)
    //   [31:24] 0xAD presence marker (old images / no-OBS reads read 0 here)
    output wire [31:0] obs_axinodes
);

    // ── Live per-channel stall (app_clk combinational): valid & !ready ──────
    wire [4:0] tgt_stall_c = { (tgt_r_valid  & ~tgt_r_ready),
                               (tgt_ar_valid & ~tgt_ar_ready),
                               (tgt_b_valid  & ~tgt_b_ready),
                               (tgt_w_valid  & ~tgt_w_ready),
                               (tgt_aw_valid & ~tgt_aw_ready) };
    wire [4:0] ini_stall_c = { (ini_r_valid  & ~ini_r_ready),
                               (ini_ar_valid & ~ini_ar_ready),
                               (ini_b_valid  & ~ini_b_ready),
                               (ini_w_valid  & ~ini_w_ready),
                               (ini_aw_valid & ~ini_aw_ready) };
    wire [9:0] stall_c = {ini_stall_c, tgt_stall_c};

    // ── app_clk-domain detection state ──────────────────────────────────────
    reg [9:0]            stall_live_q;   // registered snapshot of stall_c
    reg [9:0]            stall_prev_q;   // one cycle earlier, for stability test
    reg [WEDGE_LOG2:0]   persist_cnt_q;  // consecutive stable-stall cycles
    reg [9:0]            wedge_sticky_q; // per-channel wedge witness (sticky)
    reg                  tgt_err_q;      // sticky tgt B/R resp error
    reg                  ini_err_q;      // sticky ini B/R resp error

    wire cnt_saturated = persist_cnt_q[WEDGE_LOG2];

    always_ff @(posedge app_clk or negedge resetn) begin
        if (!resetn) begin
            stall_live_q   <= 10'h0;
            stall_prev_q   <= 10'h0;
            persist_cnt_q  <= '0;
            wedge_sticky_q <= 10'h0;
            tgt_err_q      <= 1'b0;
            ini_err_q      <= 1'b0;
        end else begin
            stall_live_q <= stall_c;
            stall_prev_q <= stall_live_q;

            // A wedge is a SINGLE stall pattern held continuously. Count while
            // the registered stall vector is non-zero AND unchanged; any change
            // (a completed handshake, a new channel, or an idle cycle) resets
            // the counter, so normal bursty backpressure never accumulates.
            if ((stall_live_q != 10'h0) && (stall_live_q == stall_prev_q)) begin
                if (!cnt_saturated)
                    persist_cnt_q <= persist_cnt_q + 1'b1;
            end else begin
                persist_cnt_q <= '0;
            end

            // Latch the wedge witness for exactly the channels stalled at
            // saturation (idempotent OR — survives until reset).
            if (cnt_saturated)
                wedge_sticky_q <= wedge_sticky_q | stall_live_q;

            // Response-error witnesses: sample resp on a completed handshake.
            if ((tgt_b_valid & tgt_b_ready & tgt_b_err) ||
                (tgt_r_valid & tgt_r_ready & tgt_r_err))
                tgt_err_q <= 1'b1;
            if ((ini_b_valid & ini_b_ready & ini_b_err) ||
                (ini_r_valid & ini_r_ready & ini_r_err))
                ini_err_q <= 1'b1;
        end
    end

    // ── 2-flop CDC into apb_clk ─────────────────────────────────────────────
    reg [9:0] stall_live_s0, stall_live_s1;
    reg [9:0] wedge_s0,      wedge_s1;
    reg       tgt_err_s0,    tgt_err_s1;
    reg       ini_err_s0,    ini_err_s1;

    always_ff @(posedge apb_clk or negedge resetn) begin
        if (!resetn) begin
            stall_live_s0 <= 10'h0; stall_live_s1 <= 10'h0;
            wedge_s0      <= 10'h0; wedge_s1      <= 10'h0;
            tgt_err_s0    <= 1'b0;  tgt_err_s1    <= 1'b0;
            ini_err_s0    <= 1'b0;  ini_err_s1    <= 1'b0;
        end else begin
            stall_live_s0 <= stall_live_q; stall_live_s1 <= stall_live_s0;
            wedge_s0      <= wedge_sticky_q; wedge_s1    <= wedge_s0;
            tgt_err_s0    <= tgt_err_q;     tgt_err_s1   <= tgt_err_s0;
            ini_err_s0    <= ini_err_q;     ini_err_s1   <= ini_err_s0;
        end
    end

    wire any_stall_live = |stall_live_s1;
    wire data_healthy   = ~(|wedge_s1) & ~tgt_err_s1 & ~ini_err_s1;

    assign obs_axinodes = { 8'hAD,          // [31:24] presence marker
                            data_healthy,   // [23]
                            any_stall_live, // [22]
                            ini_err_s1,     // [21]
                            tgt_err_s1,     // [20]
                            wedge_s1,       // [19:10]
                            stall_live_s1 };// [ 9: 0]
endmodule

`default_nettype wire
