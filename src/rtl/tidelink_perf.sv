//-----------------------------------------------------------------------------
// SoCLabs TideLink Performance Profiling Module
//
// Passive observation module for hardware timestamping and performance
// counters. Taps existing FC adapter and FIFO signals without affecting
// the datapath. Provides:
//
//   - Packet TX/RX timestamps using free-running PHC time
//   - Software-writable origin timestamp (for Ethernet MAC pipeline tracing)
//   - 8 saturating performance counters (packets, words, stalls, utilisation)
//   - Live debug registers (FC handshake status, in-flight word counts)
//   - Freeze mode for consistent snapshot reads
//
// Timestamps use the free-running PHC time from the CDC module (Path 2),
// NOT phc_hw_capture. This avoids arbitration with PTP and HA1588 servo.
// The CDC snapshot has ~4 cycle staleness — constant offset that cancels
// in differential measurements.
//
// Register map: Regions 5-7 (offsets 0x0A0-0x0FC) of TideLink APB space.
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

module tidelink_perf #(
    parameter SYS_DATA_W        = 32,
    parameter RAM_ADDR_W        = 14,
    parameter FC_DATA_W         = 48,
    // --- Congestion estimator (see CONGESTION_AWARE_ROUTING.md) ---
    parameter EWMA_ALPHA_SHIFT  = 4,     // alpha = 1/16, tau ~= 16 cycles
    parameter DERIV_WINDOW_LOG  = 8,     // sample derivative every 256 cycles
    parameter LOCAL_LINK_STATE_WIDTH = 5     // {starve, trend[1:0], level[1:0]}
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,
    input  wire                     hresetn,

    // --------------------------------------------------------------------------
    // Register Interface (from tidelink_apb_regs pass-through, Regions 5-7)
    // --------------------------------------------------------------------------
    input  wire                     perf_reg_write,
    input  wire              [2:0]  perf_reg_addr,     // paddr[4:2]
    input  wire  [SYS_DATA_W-1:0]  perf_reg_wdata,
    output logic [SYS_DATA_W-1:0]  perf_reg_rdata,
    input  wire              [1:0]  perf_reg_region,   // 00=Region5, 01=Region6, 10=Region7

    // --------------------------------------------------------------------------
    // Free-running PHC time (hclk domain, from CDC module Path 2)
    // --------------------------------------------------------------------------
    input  wire             [29:0]  phc_nanoseconds,
    input  wire             [31:0]  phc_seconds,       // Lower 32 bits sufficient

    // --------------------------------------------------------------------------
    // FC TX observation
    // --------------------------------------------------------------------------
    input  wire                     fc_tx_handshake,   // tl_fc_a2l_valid & tl_fc_a2l_ready
    input  wire                     fc_tx_is_data,     // pkt_type == FIFO_DATA (bit[47]==0)

    // --------------------------------------------------------------------------
    // FC RX observation
    // --------------------------------------------------------------------------
    input  wire                     fc_rx_handshake,   // tl_fc_l2a_valid & tl_fc_l2a_accept
    input  wire                     fc_rx_is_data,     // pkt_type == FIFO_DATA
    input  wire                     fc_rx_is_first,    // addr_offset == 0 (first word of packet)

    // --------------------------------------------------------------------------
    // TX aperture observation
    // --------------------------------------------------------------------------
    input  wire                     tx_pkt_start,      // AHB write to TX aperture addr 0

    // --------------------------------------------------------------------------
    // RX FIFO observation
    // --------------------------------------------------------------------------
    input  wire                     rx_pkt_committed,  // packet_committed_irq rising edge

    // --------------------------------------------------------------------------
    // Link status
    // --------------------------------------------------------------------------
    input  wire                     tx_router_idle,
    input  wire                     fc_tx_valid,       // tl_fc_a2l_valid (for stall detection)
    input  wire                     fc_tx_ready,       // tl_fc_a2l_ready
    input  wire                     fc_rx_valid,       // tl_fc_l2a_valid
    input  wire                     fc_rx_accept,      // tl_fc_l2a_accept

    // --------------------------------------------------------------------------
    // Credit observation
    // --------------------------------------------------------------------------
    input  wire [RAM_ADDR_W-2:0]    credit_count,

    // --------------------------------------------------------------------------
    // Congestion sideband output (to tidechart_controller)
    // See CONGESTION_AWARE_ROUTING.md for field semantics.
    // --------------------------------------------------------------------------
    output wire [LOCAL_LINK_STATE_WIDTH-1:0] local_link_state_o,
    output wire                          link_state_change_o,
    output wire [RAM_ADDR_W-2:0]         ewma_credit_o,      // debug only
    input  wire                          bcast_ack_i,        // clears starve sticky

    // --------------------------------------------------------------------------
    // Interrupt output
    // --------------------------------------------------------------------------
    output wire                     perf_irq
);

    // =========================================================================
    // Control Register (Region 5, offset 0x0A0)
    // =========================================================================
    logic        perf_enable_r;
    logic        perf_freeze_r;
    logic        perf_irq_en_r;

    wire perf_active = perf_enable_r & ~perf_freeze_r;

    // =========================================================================
    // Origin Timestamp (Region 5, offsets 0x0A4-0x0A8) — software-writable
    // =========================================================================
    logic [29:0] tx_origin_ns_r;
    logic [31:0] tx_origin_sec_r;

    // =========================================================================
    // TX Timestamp (Region 5, offsets 0x0B0-0x0B4)
    // =========================================================================
    logic [29:0] tx_start_ns_r;
    logic [31:0] tx_start_sec_r;
    logic        tx_ts_valid_r;

    // Capture TX timestamp on first FC FIFO_DATA word after a tx_pkt_start
    logic tx_pkt_active_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_pkt_active_r <= 1'b0;
            tx_start_ns_r   <= '0;
            tx_start_sec_r  <= '0;
            tx_ts_valid_r   <= 1'b0;
        end else begin
            // Clear on W1C
            if (perf_reg_write && perf_reg_region == 2'b00 && perf_reg_addr == 3'h0 && perf_reg_wdata[3])
                tx_ts_valid_r <= 1'b0;

            if (tx_pkt_start && perf_enable_r)
                tx_pkt_active_r <= 1'b1;

            if (tx_pkt_active_r && fc_tx_handshake && fc_tx_is_data && perf_active) begin
                tx_start_ns_r   <= phc_nanoseconds;
                tx_start_sec_r  <= phc_seconds;
                tx_ts_valid_r   <= 1'b1;
                tx_pkt_active_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // RX First Word Timestamp (Region 5, offsets 0x0B8-0x0BC)
    // =========================================================================
    logic [29:0] rx_first_ns_r;
    logic [31:0] rx_first_sec_r;
    logic        rx_first_valid_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            rx_first_ns_r    <= '0;
            rx_first_sec_r   <= '0;
            rx_first_valid_r <= 1'b0;
        end else begin
            if (perf_reg_write && perf_reg_region == 2'b00 && perf_reg_addr == 3'h0 && perf_reg_wdata[3])
                rx_first_valid_r <= 1'b0;

            if (fc_rx_handshake && fc_rx_is_data && fc_rx_is_first && perf_active) begin
                rx_first_ns_r    <= phc_nanoseconds;
                rx_first_sec_r   <= phc_seconds;
                rx_first_valid_r <= 1'b1;
            end
        end
    end

    // =========================================================================
    // RX Done Timestamp (Region 6, offsets 0x0C0-0x0C4)
    // =========================================================================
    logic [29:0] rx_done_ns_r;
    logic [31:0] rx_done_sec_r;
    logic        rx_done_valid_r;

    // Edge detect on packet_committed_irq
    logic rx_pkt_committed_d;
    wire  rx_pkt_committed_edge = rx_pkt_committed & ~rx_pkt_committed_d;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            rx_done_ns_r       <= '0;
            rx_done_sec_r      <= '0;
            rx_done_valid_r    <= 1'b0;
            rx_pkt_committed_d <= 1'b0;
        end else begin
            rx_pkt_committed_d <= rx_pkt_committed;

            if (perf_reg_write && perf_reg_region == 2'b00 && perf_reg_addr == 3'h0 && perf_reg_wdata[3])
                rx_done_valid_r <= 1'b0;

            if (rx_pkt_committed_edge && perf_active) begin
                rx_done_ns_r    <= phc_nanoseconds;
                rx_done_sec_r   <= phc_seconds;
                rx_done_valid_r <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Performance Counters (Region 6-7)
    // All saturating at 32'hFFFFFFFF, only increment when perf_active
    // =========================================================================

    logic [31:0] tx_pkt_count_r;
    logic [31:0] rx_pkt_count_r;
    logic [31:0] tx_word_count_r;
    logic [31:0] rx_word_count_r;
    logic [31:0] tx_stall_count_r;
    logic [31:0] rx_stall_count_r;
    logic [31:0] link_busy_count_r;
    logic [31:0] credit_starve_count_r;
    logic [31:0] sample_count_r;

    // In-flight tracking
    logic [15:0] tx_inflight_r;
    logic [15:0] rx_inflight_r;

    // Saturating increment helper
    function automatic logic [31:0] sat_inc(input logic [31:0] val);
        return (val == 32'hFFFFFFFF) ? val : val + 32'd1;
    endfunction

    wire clear_counters = perf_reg_write && perf_reg_region == 2'b00
                        && perf_reg_addr == 3'h0 && perf_reg_wdata[2];

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_pkt_count_r       <= '0;
            rx_pkt_count_r       <= '0;
            tx_word_count_r      <= '0;
            rx_word_count_r      <= '0;
            tx_stall_count_r     <= '0;
            rx_stall_count_r     <= '0;
            link_busy_count_r    <= '0;
            credit_starve_count_r <= '0;
            sample_count_r       <= '0;
            tx_inflight_r        <= '0;
            rx_inflight_r        <= '0;
        end else if (clear_counters) begin
            tx_pkt_count_r       <= '0;
            rx_pkt_count_r       <= '0;
            tx_word_count_r      <= '0;
            rx_word_count_r      <= '0;
            tx_stall_count_r     <= '0;
            rx_stall_count_r     <= '0;
            link_busy_count_r    <= '0;
            credit_starve_count_r <= '0;
            sample_count_r       <= '0;
            tx_inflight_r        <= '0;
            rx_inflight_r        <= '0;
        end else if (perf_enable_r & ~perf_freeze_r) begin
            // Sample counter (always increments when active)
            sample_count_r <= sat_inc(sample_count_r);

            // Packet counters
            if (tx_pkt_start)
                tx_pkt_count_r <= sat_inc(tx_pkt_count_r);
            if (rx_pkt_committed_edge)
                rx_pkt_count_r <= sat_inc(rx_pkt_count_r);

            // Word counters (FIFO_DATA only)
            if (fc_tx_handshake && fc_tx_is_data)
                tx_word_count_r <= sat_inc(tx_word_count_r);
            if (fc_rx_handshake && fc_rx_is_data)
                rx_word_count_r <= sat_inc(rx_word_count_r);

            // Stall counters
            if (fc_tx_valid && ~fc_tx_ready)
                tx_stall_count_r <= sat_inc(tx_stall_count_r);
            if (fc_rx_valid && ~fc_rx_accept)
                rx_stall_count_r <= sat_inc(rx_stall_count_r);

            // Link utilisation
            if (~tx_router_idle)
                link_busy_count_r <= sat_inc(link_busy_count_r);

            // Credit starvation
            if (credit_count == '0)
                credit_starve_count_r <= sat_inc(credit_starve_count_r);

            // In-flight tracking
            if (tx_pkt_start)
                tx_inflight_r <= '0;
            else if (fc_tx_handshake && fc_tx_is_data && tx_inflight_r != 16'hFFFF)
                tx_inflight_r <= tx_inflight_r + 16'd1;

            if (fc_rx_handshake && fc_rx_is_data && fc_rx_is_first)
                rx_inflight_r <= 16'd1;
            else if (fc_rx_handshake && fc_rx_is_data && rx_inflight_r != 16'hFFFF)
                rx_inflight_r <= rx_inflight_r + 16'd1;
        end
    end

    // =========================================================================
    // Congestion Estimator (Phase 1 — see CONGESTION_AWARE_ROUTING.md)
    //
    // Credit semantics: credit_count *high* means the remote FIFO has room;
    // credit_count *growing* means the remote side is draining. The level
    // field is therefore derived from the EWMA of credit_count (higher
    // credit_count => "light"), and the trend reflects credit growth.
    // =========================================================================
    localparam integer CREDIT_W = RAM_ADDR_W - 1;                    // 13 bits for RAM_ADDR_W=14
    localparam integer EWMA_ACC_W = CREDIT_W + EWMA_ALPHA_SHIFT;     // 17 bits (13 int + 4 frac)

    // Maximum credit pool size (= 2^(RAM_ADDR_W - 2) by FIFO convention,
    // but the credit_count port is CREDIT_W bits wide which is sufficient).
    localparam [CREDIT_W-1:0] CRED_Q = {CREDIT_W{1'b1}};             // max credit_count value
    localparam [CREDIT_W-1:0] CRED_QUART = CRED_Q >> 2;              // 25%
    localparam [CREDIT_W-1:0] CRED_HALF  = CRED_Q >> 1;              // 50%

    logic [EWMA_ACC_W-1:0]        ewma_acc_r;
    logic [CREDIT_W-1:0]          ewma_q_r;        // integer part of EWMA
    logic [DERIV_WINDOW_LOG-1:0]  deriv_sample_r;
    logic [CREDIT_W-1:0]          prev_credit_sample_r;
    logic signed [CREDIT_W:0]     deriv_r;
    logic [1:0]                   trend_r;
    logic [1:0]                   level_r;
    logic                         credit_starve_sticky_r;
    logic                         ewma_primed_r;   // first-cycle fast-seed flag

    wire [LOCAL_LINK_STATE_WIDTH-1:0] local_link_state_w =
        {credit_starve_sticky_r, trend_r, level_r};

    logic [LOCAL_LINK_STATE_WIDTH-1:0] local_link_state_prev_r;

    assign local_link_state_o  = local_link_state_w;
    assign ewma_credit_o       = ewma_q_r;
    // Pulse on quantised transitions; masked to perf_active so a disabled
    // perf block doesn't spuriously trigger the TideChart broadcaster.
    assign link_state_change_o = perf_active
                               & (local_link_state_w != local_link_state_prev_r);

    // EWMA integer part is the high CREDIT_W bits of the accumulator.
    wire [CREDIT_W-1:0] ewma_q_next = ewma_acc_r[EWMA_ACC_W-1 -: CREDIT_W];

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ewma_acc_r             <= '0;
            ewma_q_r               <= '0;
            ewma_primed_r          <= 1'b0;
            deriv_sample_r         <= '0;
            prev_credit_sample_r   <= '0;
            deriv_r                <= '0;
            trend_r                <= 2'b01;   // steady
            level_r                <= 2'b11;   // deep (no credits burned yet)
            credit_starve_sticky_r <= 1'b0;
            local_link_state_prev_r <= '0;
        end else if (perf_active) begin
            // -------- EWMA update (shift-and-add) ---------------------------
            if (!ewma_primed_r) begin
                // Seed accumulator from current credit_count on first active
                // cycle so we don't spend 3*tau cycles warming up from zero.
                ewma_acc_r    <= {{EWMA_ALPHA_SHIFT{1'b0}}, credit_count} <<
                                 EWMA_ALPHA_SHIFT;
                ewma_primed_r <= 1'b1;
            end else begin
                ewma_acc_r <= ewma_acc_r
                            - (ewma_acc_r >> EWMA_ALPHA_SHIFT)
                            + {{EWMA_ALPHA_SHIFT{1'b0}}, credit_count};
            end
            ewma_q_r <= ewma_q_next;

            // -------- Derivative window -------------------------------------
            deriv_sample_r <= deriv_sample_r + 1'b1;
            if (&deriv_sample_r) begin
                deriv_r <= $signed({1'b0, credit_count})
                         - $signed({1'b0, prev_credit_sample_r});
                prev_credit_sample_r <= credit_count;
            end

            // -------- Quantisation: level (from EWMA integer) ---------------
            // Convention: level describes *credit headroom*, so higher credit
            //   count => higher level value. Lower level values mean the
            //   remote FIFO is closer to full (we are closer to being stalled).
            //   00 = empty/starved, 01 = light, 10 = moderate, 11 = deep
            if (ewma_q_r == {CREDIT_W{1'b0}})
                level_r <= 2'b00;   // empty / starved: remote FIFO appears full
            else if (ewma_q_r < CRED_QUART)
                level_r <= 2'b01;   // light headroom
            else if (ewma_q_r < CRED_HALF)
                level_r <= 2'b10;   // moderate headroom
            else
                level_r <= 2'b11;   // deep headroom (remote has lots of room)

            // -------- Quantisation: trend (from signed derivative) ----------
            // deriv_r > 0  => credits growing => remote FIFO draining (good)
            //                => encode as "draining" (00)
            // deriv_r < 0  => credits shrinking => remote FIFO filling (bad)
            //                => encode as "growing_*" (10 slow / 11 fast)
            if (deriv_r < -$signed(14'sd4))
                trend_r <= 2'b11;   // growing fast (remote filling fast)
            else if (deriv_r < -$signed(14'sd1))
                trend_r <= 2'b10;   // growing slow
            else if (deriv_r > $signed(14'sd1))
                trend_r <= 2'b00;   // draining
            else
                trend_r <= 2'b01;   // steady

            // -------- Credit-starve sticky ----------------------------------
            if (bcast_ack_i)
                credit_starve_sticky_r <= 1'b0;
            else if (credit_count == '0)
                credit_starve_sticky_r <= 1'b1;

            // -------- Transition detection ---------------------------------
            local_link_state_prev_r <= local_link_state_w;
        end
    end

    // =========================================================================
    // Control Register Write
    // =========================================================================
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            perf_enable_r <= 1'b0;
            perf_freeze_r <= 1'b0;
            perf_irq_en_r <= 1'b0;
            tx_origin_ns_r  <= '0;
            tx_origin_sec_r <= '0;
        end else if (perf_reg_write && perf_reg_region == 2'b00) begin
            case (perf_reg_addr)
                3'h0: begin // PERF_CTRL
                    perf_enable_r <= perf_reg_wdata[0];
                    perf_freeze_r <= perf_reg_wdata[1];
                    perf_irq_en_r <= perf_reg_wdata[4];
                end
                3'h1: tx_origin_ns_r  <= perf_reg_wdata[29:0]; // TX_ORIGIN_NS
                3'h2: tx_origin_sec_r <= perf_reg_wdata;        // TX_ORIGIN_SEC
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Interrupt
    // =========================================================================
    assign perf_irq = rx_done_valid_r & perf_irq_en_r;

    // =========================================================================
    // Register Read Mux
    // =========================================================================
    always_comb begin
        perf_reg_rdata = '0;
        case (perf_reg_region)
            2'b00: begin // Region 5: Control & TX Timestamps
                case (perf_reg_addr)
                    3'h0: perf_reg_rdata = {27'b0, perf_irq_en_r, 1'b0, 1'b0, perf_freeze_r, perf_enable_r};
                    3'h1: perf_reg_rdata = {2'b0, tx_origin_ns_r};
                    3'h2: perf_reg_rdata = tx_origin_sec_r;
                    3'h3: perf_reg_rdata = {28'b0, perf_freeze_r, rx_done_valid_r, rx_first_valid_r, tx_ts_valid_r};
                    3'h4: perf_reg_rdata = {2'b0, tx_start_ns_r};
                    3'h5: perf_reg_rdata = tx_start_sec_r;
                    3'h6: perf_reg_rdata = {2'b0, rx_first_ns_r};
                    3'h7: perf_reg_rdata = rx_first_sec_r;
                    default: ;
                endcase
            end
            2'b01: begin // Region 6: RX Timestamps & Packet Counters
                case (perf_reg_addr)
                    3'h0: perf_reg_rdata = {2'b0, rx_done_ns_r};
                    3'h1: perf_reg_rdata = rx_done_sec_r;
                    3'h2: perf_reg_rdata = tx_pkt_count_r;
                    3'h3: perf_reg_rdata = rx_pkt_count_r;
                    3'h4: perf_reg_rdata = tx_word_count_r;
                    3'h5: perf_reg_rdata = rx_word_count_r;
                    3'h6: perf_reg_rdata = tx_stall_count_r;
                    3'h7: perf_reg_rdata = rx_stall_count_r;
                    default: ;
                endcase
            end
            2'b10: begin // Region 7: Link Counters & Debug
                case (perf_reg_addr)
                    3'h0: perf_reg_rdata = link_busy_count_r;
                    3'h1: perf_reg_rdata = credit_starve_count_r;
                    3'h2: perf_reg_rdata = sample_count_r;
                    3'h3: perf_reg_rdata = {
                        {(SYS_DATA_W-16){1'b0}}, // [31:16] reserved
                        fc_rx_valid,             // [15]
                        fc_tx_valid,             // [14]
                        credit_count,            // [13:1] (RAM_ADDR_W-1 = 13 bits)
                        tx_router_idle           // [0]
                    };
                    3'h4: perf_reg_rdata = {16'b0, tx_inflight_r};
                    3'h5: perf_reg_rdata = {16'b0, rx_inflight_r};
                    3'h6: begin                        // PERF_CONG_STATE
                        // Layout (CREDIT_W=13):
                        //   [12:0]   ewma_q_r
                        //   [15:13]  reserved
                        //   [17:16]  level
                        //   [19:18]  trend
                        //   [20]     credit_starve_sticky
                        //   [31:21]  reserved
                        perf_reg_rdata = '0;
                        perf_reg_rdata[CREDIT_W-1:0]       = ewma_q_r;
                        perf_reg_rdata[17:16]              = level_r;
                        perf_reg_rdata[19:18]              = trend_r;
                        perf_reg_rdata[20]                 = credit_starve_sticky_r;
                    end
                    3'h7: perf_reg_rdata = 32'h5046_0100; // PERF_ID: "PF" v1.0
                    default: ;
                endcase
            end
            default: ;
        endcase
    end

endmodule
