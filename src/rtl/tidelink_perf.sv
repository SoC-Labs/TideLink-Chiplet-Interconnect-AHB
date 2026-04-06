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
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter FC_DATA_W  = 48
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
                        {(SYS_DATA_W-15){1'b0}},
                        fc_rx_valid,               // [14]
                        fc_tx_valid,               // [13]
                        credit_count,              // [12:0] (RAM_ADDR_W-1 bits)
                        tx_router_idle             // [0] — shifted by credit width
                    };
                    3'h4: perf_reg_rdata = {16'b0, tx_inflight_r};
                    3'h5: perf_reg_rdata = {16'b0, rx_inflight_r};
                    3'h6: perf_reg_rdata = '0; // DBG_SCRATCH handled in CTRL write
                    3'h7: perf_reg_rdata = 32'h5046_0100; // PERF_ID: "PF" v1.0
                    default: ;
                endcase
            end
            default: ;
        endcase
    end

endmodule
