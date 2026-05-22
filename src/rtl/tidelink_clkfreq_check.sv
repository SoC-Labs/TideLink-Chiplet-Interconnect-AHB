//-----------------------------------------------------------------------------
// SoCLabs TideLink Clock-Frequency Cross-Check
//
// Guards against the "wrong bitstream loaded" / mismatched clk_wiz class of
// mistake on a chiplet link.  Each side of the link runs this module and
// compares its own link-TX clock against the recovered remote link-RX clock
// (which is the *other* board's TX clock).  If both bitstreams were built with
// the same link-clock configuration the two clocks are the same frequency and
// the per-window edge counts match within tolerance.  If one board was built
// at, say, 25 MHz and the other at 50 MHz, the counts diverge ~2:1 and
// freq_mismatch_sticky latches high.
//
// Method: a free-running counter in each clock domain, sampled over a fixed
// measurement window defined in the local domain.  The remote (link_clk)
// counter is brought across the clock boundary with a Gray-coded value through
// a 2-FF synchroniser (only one bit changes per increment, so no metastable
// multi-bit corruption).  Because both window snapshots see the same constant
// synchroniser latency, the *delta* between snapshots is skew-free.
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

module tidelink_clkfreq_check #(
    parameter int WINDOW_BITS = 16,  // measurement window = 2^WINDOW_BITS local cycles
    parameter int CNT_W       = 20,  // counter width; must exceed WINDOW_BITS with
                                     // headroom for the worst expected ratio
                                     // (CNT_W-WINDOW_BITS bits => up to 2^(diff)x)
    parameter int SYNC_STAGES = 2,   // synchroniser chain depth (min 2)
    parameter int TOL_COUNTS  = 256  // allowed |link-local| edge-count deviation
                                     // per window (covers ppm drift + jitter +
                                     // the +/-1 window-boundary quantisation)
)(
    // ── local link-TX clock domain (measurement reference) ──────────────
    input  wire                 local_clk,
    input  wire                 local_rst_n,

    // ── recovered remote link-RX clock domain ──────────────────────────
    input  wire                 link_clk,
    input  wire                 link_rst_n,

    // ── control ─────────────────────────────────────────────────────────
    input  wire                 link_up,    // arm only when the link is stable

    // ── status (all in local_clk domain) ───────────────────────────────
    output logic                freq_match,            // last window within tolerance
    output logic                freq_mismatch_sticky,  // latched: any window out of tol
    output logic                measured_once,         // >=1 window has completed
    output logic [CNT_W-1:0]    local_window_count,    // local edges in last window
    output logic [CNT_W-1:0]    link_window_count,     // link  edges in last window
    output logic                measurement_valid      // 1-cycle pulse at window close
);

    // =====================================================================
    // link_clk domain: free-running binary counter + registered Gray code.
    // Registering the Gray of the *next* count keeps a single clean FF output
    // on the crossing net (no combinational glitch into the synchroniser).
    // =====================================================================
    logic [CNT_W-1:0] link_bin_l;
    logic [CNT_W-1:0] link_gray_l;

    always_ff @(posedge link_clk or negedge link_rst_n) begin
        if (!link_rst_n) begin
            link_bin_l  <= '0;
            link_gray_l <= '0;
        end else begin
            link_bin_l  <= link_bin_l + 1'b1;
            link_gray_l <= (link_bin_l + 1'b1) ^ ((link_bin_l + 1'b1) >> 1);
        end
    end

    // =====================================================================
    // local_clk domain: 2-FF synchronise the Gray vector, then decode.
    // =====================================================================
    (* cdc_sync = "true" *)
    logic [CNT_W-1:0] link_gray_meta;
    (* cdc_sync = "true" *)
    logic [CNT_W-1:0] link_gray_sync;

    always_ff @(posedge local_clk or negedge local_rst_n) begin
        if (!local_rst_n) begin
            link_gray_meta <= '0;
            link_gray_sync <= '0;
        end else begin
            link_gray_meta <= link_gray_l;
            link_gray_sync <= link_gray_meta;
        end
    end

    function automatic logic [CNT_W-1:0] gray2bin(input logic [CNT_W-1:0] g);
        logic [CNT_W-1:0] b;
        b[CNT_W-1] = g[CNT_W-1];
        for (int i = CNT_W-2; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    wire [CNT_W-1:0] link_bin_local = gray2bin(link_gray_sync);

    // =====================================================================
    // local_clk domain: window timer, local free-running counter, compare.
    // =====================================================================
    logic [CNT_W-1:0]       local_cnt;
    logic [WINDOW_BITS-1:0] window_cnt;
    logic                   armed;
    logic [CNT_W-1:0]       local_snap_prev;
    logic [CNT_W-1:0]       link_snap_prev;

    always_ff @(posedge local_clk or negedge local_rst_n) begin
        if (!local_rst_n) begin
            local_cnt            <= '0;
            window_cnt           <= '0;
            armed                <= 1'b0;
            local_snap_prev      <= '0;
            link_snap_prev       <= '0;
            freq_match           <= 1'b0;
            freq_mismatch_sticky <= 1'b0;
            measured_once        <= 1'b0;
            measurement_valid    <= 1'b0;
            local_window_count   <= '0;
            link_window_count    <= '0;
        end else begin
            local_cnt         <= local_cnt + 1'b1;
            measurement_valid <= 1'b0;  // default; pulsed at window close

            if (!link_up) begin
                // Link not stable: hold off measuring. Keep sticky latched
                // (a real mismatch stays flagged across a link bounce) and
                // re-arm cleanly on the next link_up.
                armed      <= 1'b0;
                window_cnt <= '0;
            end else if (!armed) begin
                // First armed cycle: snapshot baselines and skip this window
                // to flush the synchroniser pipe and the RX-clock startup.
                armed           <= 1'b1;
                window_cnt      <= '0;
                local_snap_prev <= local_cnt;
                link_snap_prev  <= link_bin_local;
            end else begin
                window_cnt <= window_cnt + 1'b1;

                if (&window_cnt) begin
                    // window boundary: compute skew-free deltas (mod 2^CNT_W)
                    automatic logic [CNT_W-1:0] ld =
                        local_cnt     - local_snap_prev;
                    automatic logic [CNT_W-1:0] kd =
                        link_bin_local - link_snap_prev;
                    automatic logic [CNT_W-1:0] ad =
                        (kd >= ld) ? (kd - ld) : (ld - kd);

                    local_window_count <= ld;
                    link_window_count  <= kd;
                    measurement_valid  <= 1'b1;
                    measured_once      <= 1'b1;

                    if (ad <= TOL_COUNTS) begin
                        freq_match <= 1'b1;
                    end else begin
                        freq_match           <= 1'b0;
                        freq_mismatch_sticky <= 1'b1;
                    end

                    local_snap_prev <= local_cnt;
                    link_snap_prev  <= link_bin_local;
                end
            end
        end
    end

endmodule
