//-----------------------------------------------------------------------------
// SoCLabs TideLink PHC CDC Synchronizer
//
// Clock domain crossing bridge between TideLink (hclk) and the external
// Precision Hardware Clock (phc_clk). Handles 6 signal paths:
//
//   Path 1: HW capture timestamps  (phc→hclk, 110-bit quasi-static snapshot)
//   Path 2: Free-running PHC time  (phc→hclk, 78-bit handshake snapshot)
//   Path 3: PPS pulse              (phc→hclk, toggle pulse sync)
//   Path 4: HW capture trigger     (hclk→phc, toggle pulse sync)
//   Path 5: Phase step command     (hclk→phc, 79-bit data+pulse handshake)
//   Path 6: Frequency adjust       (hclk→phc, 33-bit data+pulse handshake)
//
// Total cost: ~526 FFs (~3,200 gates) with BYPASS_CDC=0.
// Set BYPASS_CDC=1 when phc_clk == hclk to save ~506 FFs (~20 FFs remain
// for single-cycle output registers).
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_phc_cdc #(
    parameter SYS_DATA_W  = 32,
    parameter SYNC_STAGES = 2,    // Synchronizer chain depth (min 2)
    parameter BYPASS_CDC  = 0     // 1 = single-clock mode, bypass all CDC logic
)(
    // ── hclk domain ─────────────────────────────────────────────────────
    input  wire                     hclk,
    input  wire                     hresetn,

    // ── phc_clk domain ──────────────────────────────────────────────────
    input  wire                     phc_clk,
    input  wire                     phc_resetn,

    // ── DFT ─────────────────────────────────────────────────────────────
    input  wire                     scan_mode,

    // =====================================================================
    // hclk-side ports (connect to tidelink_top internals)
    // =====================================================================

    // Path 4: HW Capture trigger (hclk → phc_clk)
    input  wire                     h_hw_capture,

    // Path 1: HW Capture timestamps (phc_clk → hclk)
    output logic             [47:0] h_hw_cap_seconds,
    output logic             [29:0] h_hw_cap_nanoseconds,
    output logic [SYS_DATA_W-1:0]  h_hw_cap_sub_nanoseconds,

    // Path 2: Free-running PHC time (phc_clk → hclk)
    output logic             [29:0] h_phc_nanoseconds,
    output logic             [47:0] h_phc_seconds,

    // Path 3: PPS pulse (phc_clk → hclk)
    output wire                     h_phc_pps,

    // Path 5: Phase step command (hclk → phc_clk)
    input  wire                     h_hw_set_time,
    input  wire              [47:0] h_hw_set_seconds,
    input  wire              [29:0] h_hw_set_nanoseconds,

    // Path 6: Frequency adjust command (hclk → phc_clk)
    input  wire                     h_hw_adj_valid,
    input  wire  [SYS_DATA_W-1:0]  h_hw_adj_ns_incr_frac,

    // =====================================================================
    // phc_clk-side ports (connect to external PHC)
    // =====================================================================

    // Path 4: HW Capture trigger output to PHC
    output wire                     p_hw_capture,

    // Path 1: HW Capture timestamps from PHC
    input  wire              [47:0] p_hw_cap_seconds,
    input  wire              [29:0] p_hw_cap_nanoseconds,
    input  wire  [SYS_DATA_W-1:0]  p_hw_cap_sub_nanoseconds,

    // Path 2: Free-running PHC time
    input  wire              [29:0] p_phc_nanoseconds,
    input  wire              [47:0] p_phc_seconds,

    // Path 3: PPS pulse from PHC
    input  wire                     p_phc_pps,

    // Path 5: Phase step command to PHC
    output logic                    p_hw_set_time,
    output logic             [47:0] p_hw_set_seconds,
    output logic             [29:0] p_hw_set_nanoseconds,

    // Path 6: Frequency adjust command to PHC
    output logic                    p_hw_adj_valid,
    output logic [SYS_DATA_W-1:0]  p_hw_adj_ns_incr_frac
);

generate
if (BYPASS_CDC) begin : gen_bypass
    // =================================================================
    // Single-clock bypass: no synchronization, minimal register latency.
    // Use when phc_clk == hclk to save ~506 FFs.
    // =================================================================

    // Path 4: capture trigger — direct pass-through
    assign p_hw_capture = h_hw_capture;

    // Path 1: HW capture timestamps — single-cycle register
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            h_hw_cap_seconds         <= '0;
            h_hw_cap_nanoseconds     <= '0;
            h_hw_cap_sub_nanoseconds <= '0;
        end else begin
            h_hw_cap_seconds         <= p_hw_cap_seconds;
            h_hw_cap_nanoseconds     <= p_hw_cap_nanoseconds;
            h_hw_cap_sub_nanoseconds <= p_hw_cap_sub_nanoseconds;
        end
    end

    // Path 2: free-running PHC time — single-cycle register
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            h_phc_nanoseconds <= '0;
            h_phc_seconds     <= '0;
        end else begin
            h_phc_nanoseconds <= p_phc_nanoseconds;
            h_phc_seconds     <= p_phc_seconds;
        end
    end

    // Path 3: PPS — direct pass-through
    assign h_phc_pps = p_phc_pps;

    // Path 5: phase step — single-cycle register
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            p_hw_set_time        <= 1'b0;
            p_hw_set_seconds     <= '0;
            p_hw_set_nanoseconds <= '0;
        end else begin
            p_hw_set_time        <= h_hw_set_time;
            p_hw_set_seconds     <= h_hw_set_seconds;
            p_hw_set_nanoseconds <= h_hw_set_nanoseconds;
        end
    end

    // Path 6: frequency adjust — single-cycle register
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            p_hw_adj_valid        <= 1'b0;
            p_hw_adj_ns_incr_frac <= '0;
        end else begin
            p_hw_adj_valid        <= h_hw_adj_valid;
            p_hw_adj_ns_incr_frac <= h_hw_adj_ns_incr_frac;
        end
    end

end else begin : gen_cdc
    // =================================================================
    // Full CDC logic for asynchronous phc_clk / hclk domains
    // =================================================================

    // =====================================================================
    // Path 4: HW Capture Trigger (hclk → phc_clk) — Toggle Pulse Sync
    // =====================================================================

    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] cap_trig_sync_p;
    logic                   cap_trig_toggle_h;
    logic                   cap_trig_prev_p;

    // hclk: toggle on capture pulse
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            cap_trig_toggle_h <= 1'b0;
        else if (h_hw_capture)
            cap_trig_toggle_h <= ~cap_trig_toggle_h;
    end

    // phc_clk: synchronize toggle, detect edge
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            cap_trig_sync_p <= '0;
            cap_trig_prev_p <= 1'b0;
        end else begin
            cap_trig_sync_p <= {cap_trig_sync_p[SYNC_STAGES-2:0], cap_trig_toggle_h};
            cap_trig_prev_p <= cap_trig_sync_p[SYNC_STAGES-1];
        end
    end

    assign p_hw_capture = cap_trig_sync_p[SYNC_STAGES-1] ^ cap_trig_prev_p;

    // =====================================================================
    // Path 1: HW Capture Timestamps (phc_clk → hclk) — Quasi-Static
    // =====================================================================
    // PHC latches hw_cap_* atomically on p_hw_capture. Data is stable until
    // the next capture event. We synchronize a "done" flag and then sample
    // the (already stable) data in the hclk domain.

    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] cap_done_sync_h;
    logic                   cap_done_toggle_p;
    logic                   cap_done_prev_h;

    // phc_clk: toggle done flag after capture fires
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn)
            cap_done_toggle_p <= 1'b0;
        else if (p_hw_capture)
            cap_done_toggle_p <= ~cap_done_toggle_p;
    end

    // hclk: synchronize done flag, detect edge, sample data
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            cap_done_sync_h <= '0;
            cap_done_prev_h <= 1'b0;
        end else begin
            cap_done_sync_h <= {cap_done_sync_h[SYNC_STAGES-2:0], cap_done_toggle_p};
            cap_done_prev_h <= cap_done_sync_h[SYNC_STAGES-1];
        end
    end

    wire cap_done_pulse_h = cap_done_sync_h[SYNC_STAGES-1] ^ cap_done_prev_h;

    // Sample the quasi-static PHC capture registers when done flag arrives
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            h_hw_cap_seconds         <= '0;
            h_hw_cap_nanoseconds     <= '0;
            h_hw_cap_sub_nanoseconds <= '0;
        end else if (cap_done_pulse_h) begin
            h_hw_cap_seconds         <= p_hw_cap_seconds;
            h_hw_cap_nanoseconds     <= p_hw_cap_nanoseconds;
            h_hw_cap_sub_nanoseconds <= p_hw_cap_sub_nanoseconds;
        end
    end

    // =====================================================================
    // Path 2: Free-Running PHC Time (phc_clk → hclk) — Handshake Snapshot
    // =====================================================================
    // Continuous req/ack handshake: hclk requests snapshot, phc_clk latches
    // current time and acks, hclk samples the stable snapshot and re-requests.

    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] time_req_sync_p;
    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] time_ack_sync_h;
    logic                   time_req_toggle_h;
    logic                   time_req_prev_p;
    logic                   time_ack_toggle_p;
    logic                   time_ack_prev_h;

    // Snapshot holding registers (phc_clk domain)
    logic [47:0] time_snap_seconds_p;
    logic [29:0] time_snap_nanoseconds_p;

    // phc_clk: synchronize req, snapshot on edge, toggle ack
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            time_req_sync_p         <= '0;
            time_req_prev_p         <= 1'b0;
            time_ack_toggle_p       <= 1'b0;
            time_snap_seconds_p     <= '0;
            time_snap_nanoseconds_p <= '0;
        end else begin
            time_req_sync_p <= {time_req_sync_p[SYNC_STAGES-2:0], time_req_toggle_h};
            time_req_prev_p <= time_req_sync_p[SYNC_STAGES-1];

            // On req edge: snapshot free-running time and ack
            if (time_req_sync_p[SYNC_STAGES-1] ^ time_req_prev_p) begin
                time_snap_seconds_p     <= p_phc_seconds;
                time_snap_nanoseconds_p <= p_phc_nanoseconds;
                time_ack_toggle_p       <= ~time_ack_toggle_p;
            end
        end
    end

    // hclk: synchronize ack, sample snapshot, re-request
    // Note: time_req_toggle_h initialises to 1'b1 (not 1'b0) so that the
    // first request is issued immediately after reset. Without this, the
    // req/ack handshake deadlocks because both toggle signals start at 0
    // and neither side sees an edge to initiate the first transfer.
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            time_ack_sync_h    <= '0;
            time_ack_prev_h    <= 1'b0;
            time_req_toggle_h  <= 1'b1;   // Kick-start: first request after reset
            h_phc_seconds      <= '0;
            h_phc_nanoseconds  <= '0;
        end else begin
            time_ack_sync_h <= {time_ack_sync_h[SYNC_STAGES-2:0], time_ack_toggle_p};
            time_ack_prev_h <= time_ack_sync_h[SYNC_STAGES-1];

            // On ack edge: sample stable snapshot and immediately re-request
            if (time_ack_sync_h[SYNC_STAGES-1] ^ time_ack_prev_h) begin
                h_phc_seconds     <= time_snap_seconds_p;
                h_phc_nanoseconds <= time_snap_nanoseconds_p;
                time_req_toggle_h <= ~time_req_toggle_h;
            end
        end
    end

    // =====================================================================
    // Path 3: PPS Pulse (phc_clk → hclk) — Toggle Pulse Sync
    // =====================================================================

    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] pps_sync_h;
    logic                   pps_toggle_p;
    logic                   pps_prev_h;

    // phc_clk: toggle on PPS pulse
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn)
            pps_toggle_p <= 1'b0;
        else if (p_phc_pps)
            pps_toggle_p <= ~pps_toggle_p;
    end

    // hclk: synchronize toggle, detect edge
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pps_sync_h <= '0;
            pps_prev_h <= 1'b0;
        end else begin
            pps_sync_h <= {pps_sync_h[SYNC_STAGES-2:0], pps_toggle_p};
            pps_prev_h <= pps_sync_h[SYNC_STAGES-1];
        end
    end

    assign h_phc_pps = pps_sync_h[SYNC_STAGES-1] ^ pps_prev_h;

    // =====================================================================
    // Path 5: Phase Step Command (hclk → phc_clk) — Data+Pulse Handshake
    // =====================================================================

    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] set_req_sync_p;
    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] set_ack_sync_h;
    logic                   set_req_toggle_h;
    logic                   set_req_prev_p;
    logic                   set_ack_toggle_p;
    logic                   set_ack_prev_h;
    logic                   set_busy_h;

    // hclk: holding registers (stable before req toggles)
    logic [47:0] set_hold_seconds_h;
    logic [29:0] set_hold_nanoseconds_h;

    // hclk: on pulse, latch data and toggle req (if not busy)
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            set_req_toggle_h       <= 1'b0;
            set_busy_h             <= 1'b0;
            set_hold_seconds_h     <= '0;
            set_hold_nanoseconds_h <= '0;
            set_ack_sync_h         <= '0;
            set_ack_prev_h         <= 1'b0;
        end else begin
            set_ack_sync_h <= {set_ack_sync_h[SYNC_STAGES-2:0], set_ack_toggle_p};
            set_ack_prev_h <= set_ack_sync_h[SYNC_STAGES-1];

            // Ack received: clear busy
            if (set_ack_sync_h[SYNC_STAGES-1] ^ set_ack_prev_h)
                set_busy_h <= 1'b0;

            // New command: latch data and toggle req
            if (h_hw_set_time && !set_busy_h) begin
                set_hold_seconds_h     <= h_hw_set_seconds;
                set_hold_nanoseconds_h <= h_hw_set_nanoseconds;
                set_req_toggle_h       <= ~set_req_toggle_h;
                set_busy_h             <= 1'b1;
            end
        end
    end

    // phc_clk: sync req, latch data, pulse output, toggle ack
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            set_req_sync_p      <= '0;
            set_req_prev_p      <= 1'b0;
            set_ack_toggle_p    <= 1'b0;
            p_hw_set_time       <= 1'b0;
            p_hw_set_seconds    <= '0;
            p_hw_set_nanoseconds <= '0;
        end else begin
            set_req_sync_p <= {set_req_sync_p[SYNC_STAGES-2:0], set_req_toggle_h};
            set_req_prev_p <= set_req_sync_p[SYNC_STAGES-1];

            // Default: deassert pulse
            p_hw_set_time <= 1'b0;

            // On req edge: latch stable data, pulse, ack
            if (set_req_sync_p[SYNC_STAGES-1] ^ set_req_prev_p) begin
                p_hw_set_seconds     <= set_hold_seconds_h;
                p_hw_set_nanoseconds <= set_hold_nanoseconds_h;
                p_hw_set_time        <= 1'b1;
                set_ack_toggle_p     <= ~set_ack_toggle_p;
            end
        end
    end

    // =====================================================================
    // Path 6: Frequency Adjust (hclk → phc_clk) — Data+Pulse Handshake
    // =====================================================================

    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] adj_req_sync_p;
    (* cdc_sync = "true" *)
    logic [SYNC_STAGES-1:0] adj_ack_sync_h;
    logic                   adj_req_toggle_h;
    logic                   adj_req_prev_p;
    logic                   adj_ack_toggle_p;
    logic                   adj_ack_prev_h;
    logic                   adj_busy_h;

    // hclk: holding register
    logic [SYS_DATA_W-1:0] adj_hold_frac_h;

    // hclk: on pulse, latch data and toggle req
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            adj_req_toggle_h <= 1'b0;
            adj_busy_h       <= 1'b0;
            adj_hold_frac_h  <= '0;
            adj_ack_sync_h   <= '0;
            adj_ack_prev_h   <= 1'b0;
        end else begin
            adj_ack_sync_h <= {adj_ack_sync_h[SYNC_STAGES-2:0], adj_ack_toggle_p};
            adj_ack_prev_h <= adj_ack_sync_h[SYNC_STAGES-1];

            if (adj_ack_sync_h[SYNC_STAGES-1] ^ adj_ack_prev_h)
                adj_busy_h <= 1'b0;

            if (h_hw_adj_valid && !adj_busy_h) begin
                adj_hold_frac_h  <= h_hw_adj_ns_incr_frac;
                adj_req_toggle_h <= ~adj_req_toggle_h;
                adj_busy_h       <= 1'b1;
            end
        end
    end

    // phc_clk: sync req, latch data, pulse output, toggle ack
    always_ff @(posedge phc_clk or negedge phc_resetn) begin
        if (!phc_resetn) begin
            adj_req_sync_p       <= '0;
            adj_req_prev_p       <= 1'b0;
            adj_ack_toggle_p     <= 1'b0;
            p_hw_adj_valid       <= 1'b0;
            p_hw_adj_ns_incr_frac <= '0;
        end else begin
            adj_req_sync_p <= {adj_req_sync_p[SYNC_STAGES-2:0], adj_req_toggle_h};
            adj_req_prev_p <= adj_req_sync_p[SYNC_STAGES-1];

            p_hw_adj_valid <= 1'b0;

            if (adj_req_sync_p[SYNC_STAGES-1] ^ adj_req_prev_p) begin
                p_hw_adj_ns_incr_frac <= adj_hold_frac_h;
                p_hw_adj_valid        <= 1'b1;
                adj_ack_toggle_p      <= ~adj_ack_toggle_p;
            end
        end
    end

end
endgenerate

endmodule
