// =============================================================================
// tidelink_tx_gen.sv — PL-side TX traffic generator (campaign "v1")
//
// Drives the EXISTING ahb_tx AHB-Lite port of tidelink_fc_adapter as a master,
// so that every piece of the measured datapath (the held-NONSEQ transfer lock,
// the 1-entry skid, the honest-back-pressure completion rule and the
// TX_STALL_TIMEOUT backstop) stays in the path. Only the Zynq PS->PL bridge is
// removed — which is precisely the ~96 PL cycles/word that makes the link look
// ~83% idle and hides every link-side throughput improvement from measurement.
//
// SAFETY — read before changing anything here:
//
//   * POR-DISARMED. TXGEN_CTRL[0] EN resets to 0 and gen_owns_o can only assert
//     while EN=1 AND a run is active. With EN=0 the select is a constant-0 net,
//     so the 2:1 mux in tidelink_top constant-folds and the adapter's TX port is
//     driven by exactly the same nets as a build without this module. Combined
//     with TXGEN_PRESENT=0 (which removes the module and the mux entirely) the
//     ASIC netlist is provably unchanged. This mirrors the RX-FIFO TWIN 2
//     runtime ARM (tidelink_apb_regs.sv:226 / tidelink_fifo_ctrl.sv:160).
//
//   * EN survives STOP and CLR. Only POR or an explicit EN=0 write clears it —
//     the TWIN-2 lesson that a FLUSH-style control must not silently disarm
//     (tidelink_apb_regs.sv:237-243).
//
//   * HARDWARE CREDIT GATE IS MANDATORY. The peer's RX FIFO write side has NO
//     backpressure: fc_wr_ready is tied 1 (tidelink_fifo_mem.sv:92) and a write
//     arriving with zero credit is SILENTLY DROPPED with only a sticky overrun
//     (tidelink_fifo_ctrl.sv:482-501). A line-rate generator without this gate
//     would destroy data at line rate. We gate on pair_credit_count — the local
//     view of the PEER's free credit, maintained in hardware by the peer's
//     returner — never on the local FIFO's own credit (that is the wrong
//     buffer) and never on the Wlink fe_* credit (that protects the 16-deep
//     replay FIFO, i.e. the wire, not the peer's 16 KB RX SRAM; the generator
//     honours it for free through hreadyout).
//
//   * RESERVE-THEN-SEND. The full (len+2) is consumed at packet START, not at
//     completion: the adapter accepts 1 word/hclk, so a completion-time consume
//     would let the next packet arm against credit already spoken for.
//
//   * PACKETS ARE ATOMIC. A run never abandons a packet mid-flight. A truncated
//     packet leaves the peer's packet_active_r/write_target_addr_r armed
//     (tidelink_fifo_ctrl.sv:146-164) — the state that mints credit above MAX on
//     a later drain. Reserving up front makes that unreachable. If the adapter
//     ERRORs mid-packet (its stall timeout fired) we latch ERR_AHB, STOP, and do
//     NOT auto-restart: the peer is mid-packet and software must FLUSH it.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.  David Mapstone (d.a.mapstone@soton.ac.uk)
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`default_nettype none

module tidelink_tx_gen #(
    parameter int unsigned SYS_DATA_W = 32,
    parameter int unsigned RAM_ADDR_W = 14,
    // Peer RX FIFO capacity in words; (len+2) must fit. Mirrors
    // tidelink_fifo_ctrl.sv MAX_CREDITS = 1 << (RAM_ADDR_W-2).
    parameter int unsigned MAX_CREDITS = (1 << (RAM_ADDR_W - 2)),
    // SIM-ONLY negative-control knob. Defeats the credit gate so a test can
    // prove the peer DOES overrun without it. NEVER set in a shipping flist —
    // a green no-overrun test proves nothing without this arm.
    parameter bit          CREDIT_GATE_DIS = 1'b0
) (
    input  wire                      hclk,
    input  wire                      hresetn,

    // ---- APB Region E register file (decoded in tidelink_top) --------------
    input  wire                      reg_sel,      // region hit
    input  wire                [2:0] reg_addr,     // paddr[4:2]
    input  wire                      reg_write,    // already qualified with
                                                   // !fc_cfg_apb_active in top:
                                                   // a peer must never be able
                                                   // to arm this block
    input  wire [SYS_DATA_W-1:0]     reg_wdata,
    output logic [SYS_DATA_W-1:0]    reg_rdata,

    // ---- Peer-credit interface (tidelink_apb_regs) -------------------------
    input  wire [SYS_DATA_W-1:0]     pair_credit_count,
    input  wire                      pair_credit_en,
    output logic                     credit_consume_vld,
    output logic [SYS_DATA_W-1:0]    credit_consume_val,

    // ---- AHB master toward tidelink_fc_adapter's TX aperture ---------------
    output logic                     gen_owns,     // mux select in top
    output logic [RAM_ADDR_W-1:0]    gen_haddr,
    output logic               [1:0] gen_htrans,
    output logic               [2:0] gen_hsize,
    output logic                     gen_hwrite,
    output logic [SYS_DATA_W-1:0]    gen_hwdata,
    input  wire                      fc_hreadyout, // from the adapter
    input  wire                      fc_hresp,     // from the adapter

    // ---- External-master activity (for the ownership handshake) ------------
    // NOTE: ahb_tx_hsel is tied 1'b1 at the IP boundary
    // (fpga/vivado_ip/tidelink_vivado_wrapper.v:577), so HSEL CANNOT be used as
    // an idle indicator. htrans[1] is the only usable one.
    input  wire                [1:0] ext_htrans,

    output logic                     txgen_active  // observability / mark_debug
);

    // ---- Register offsets (Region E, paddr[4:2]) ---------------------------
    localparam logic [2:0] R_CTRL   = 3'h0;
    localparam logic [2:0] R_PKT    = 3'h1;
    localparam logic [2:0] R_GAP    = 3'h2;
    localparam logic [2:0] R_BUDGET = 3'h3;
    localparam logic [2:0] R_STATUS = 3'h4;
    localparam logic [2:0] R_WORDS  = 3'h5;
    localparam logic [2:0] R_STALL  = 3'h6;
    localparam logic [2:0] R_ID     = 3'h7;

    localparam logic [SYS_DATA_W-1:0] TXGEN_ID_VAL = 32'h5447_0100; // "TG" v1.0

    localparam int unsigned LEN_W = 12;
    // total_words = len + 2 <= MAX_CREDITS  (2-word header), as
    // tidelink_fifo_ctrl.sv:242.
    localparam logic [LEN_W-1:0] MAX_PKT_LEN = LEN_W'(MAX_CREDITS - 2);

    // Word 0 header encoding MUST match tidelink/packet.py encode_word0 and the
    // RX FIFO decode: length in [31:20], pkt_type in [19:18]. The peer only
    // STORES a packet whose type is WR_REQ; a RD_REQ (type 0) would not land as
    // data. This is the same header the proven send path emits (0x00240000 =
    // WR_REQ, length 2).
    localparam logic [1:0] PKT_WR_REQ = 2'b01;

    // ---- Control state -----------------------------------------------------
    logic                    en_r;          // CTRL[0] — POR-disarmed arm
    logic                    forever_r;     // CTRL[3]
    logic                    running_r;
    logic [LEN_W-1:0]        pkt_len_r;
    logic [LEN_W-1:0]        dest_off_r;
    logic [15:0]             ipg_r;
    logic [15:0]             margin_r;
    logic [SYS_DATA_W-1:0]   budget_r;

    // Status
    logic                    done_r;        // sticky
    logic                    err_ahb_r;     // sticky
    logic                    ext_abort_r;   // sticky
    logic [SYS_DATA_W-1:0]   words_r;       // saturating
    logic [SYS_DATA_W-1:0]   stall_r;       // saturating

    // Datapath state
    typedef enum logic [1:0] {S_IDLE, S_ARMED, S_SEND, S_GAP} state_e;
    state_e                  state_r;
    logic [LEN_W+1:0]        beat_r;        // ADDRESS beat: 0=len,1=dest,2..N+1
    logic [LEN_W+1:0]        total_beats_r; // pkt_len + 2
    logic [15:0]             gap_r;
    logic [15:0]             seq_r;         // packet sequence, into the payload
    // AHB is PIPELINED: the adapter latches HADDR in the address phase and reads
    // HWDATA LIVE in the NEXT (data) phase (fc_adapter tx_fc_word =
    // {type, tx_addr_r, ahb_tx_hwdata}). So HWDATA must trail HADDR by one cycle:
    // data_word_r holds the data for the address accepted last cycle, and
    // data_pend_r marks that a data phase is outstanding (so ownership is held
    // through the final data phase after the last address has been issued).
    logic [SYS_DATA_W-1:0]   data_word_r;
    logic                    data_pend_r;

    // Register writes ---------------------------------------------------------
    wire reg_hit   = reg_sel && reg_write;
    wire wr_ctrl   = reg_hit && (reg_addr == R_CTRL);
    wire start_pulse = wr_ctrl && reg_wdata[1];
    wire stop_pulse  = wr_ctrl && reg_wdata[2];
    wire clr_pulse   = wr_ctrl && reg_wdata[4];

    // Credit accounting -------------------------------------------------------
    wire [SYS_DATA_W-1:0] need_words = SYS_DATA_W'(pkt_len_r) + 32'd2;
    wire [SYS_DATA_W-1:0] need_total = need_words + SYS_DATA_W'(margin_r);
    // Fail-closed: pair_credit_count is POR 0, so a run simply never starts
    // until the peer has actually granted credit.
    wire credit_ok = CREDIT_GATE_DIS ? 1'b1
                                     : (pair_credit_en && (pair_credit_count >= need_total));

    // Ownership: only take the port while the external master is idle, and hold
    // it for the whole packet once taken.
    //
    // FIX (2026-07-30, audit finding A4 — see cocotb/tidelink_txgen/
    // test_txgen_ext_hijack.py for the pre-fix repro): HTRANS is an
    // ADDRESS-phase-only signal — an AHB master drives IDLE throughout the
    // DATA phase of a beat it already had accepted, so `~ext_htrans[1]` alone
    // reads "idle" for the whole of an outstanding external data phase, and
    // ownership could switch mid-transfer. Because the adapter reads HWDATA
    // LIVE in the data phase (tidelink_fc_adapter.sv tx_fc_word =
    // {type, tx_addr_r, ahb_tx_hwdata}), the word committed to the link was
    // {external ADDRESS, generator DATA} — silent single-word corruption.
    //
    // ext_data_pend_r closes the gap: while this module does not own the
    // port, fc_hreadyout is exactly what the external master sees as its own
    // hreadyout (tidelink_top.sv ties ext_hreadyout = fc_hreadyout whenever
    // !gen_owns), so "an address phase was just accepted" and "the
    // outstanding data phase just completed" are both directly observable
    // from signals this module already has. Held while gen_owns so a stale
    // 0 can't reappear if ownership somehow returns before the tracker is
    // re-armed (defensive; by construction gen_owns and ext_data_pend_r=1
    // should never coexist once ext_idle gates on this too).
    logic ext_data_pend_r;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            ext_data_pend_r <= 1'b0;
        else if (!gen_owns) begin
            if (ext_htrans[1] && fc_hreadyout)      ext_data_pend_r <= 1'b1;
            else if (ext_data_pend_r && fc_hreadyout) ext_data_pend_r <= 1'b0;
        end
    end

    wire ext_idle   = ~ext_htrans[1] && !ext_data_pend_r;
    wire can_take   = en_r && running_r && ext_idle && credit_ok;
    // An external beat while we own the port is refused by tidelink_top with a
    // two-cycle AHB ERROR; record it so the refusal is never silent. Widened
    // to the SAME predicate ext_idle checks (was ext_htrans[1] alone, which
    // is structurally blind to a data-phase-only overlap — the exact gap the
    // fix above closes) so any residual overlap is at least sticky-recorded,
    // never silent.
    wire ext_collide = gen_owns && (ext_htrans[1] || ext_data_pend_r);

    // Still issuing addresses for this packet (vs. draining the final data).
    wire sending_addr = (state_r == S_SEND) && (beat_r < total_beats_r);
    // A data phase completes on every hready cycle a data phase is outstanding.
    wire data_complete = (state_r == S_SEND) && fc_hreadyout && data_pend_r;

    // ---- Payload ------------------------------------------------------------
    // Position-encoded so a 2-word shift (the phantom-pop signature,
    // tidelink_fifo_ctrl.sv:324-339) is caught by a byte-exact drain.
    logic [SYS_DATA_W-1:0] beat_data;
    always_comb begin
        beat_data = '0;
        unique case (beat_r)
            // Length [31:20] + WR_REQ type [19:18] — matches encode_word0 and
            // the 0x00240000-class header the proven send path uses.
            {(LEN_W+2){1'b0}}                      : beat_data = {pkt_len_r, PKT_WR_REQ, 18'h0};
            {{(LEN_W+1){1'b0}}, 1'b1}              : beat_data = {{(SYS_DATA_W-LEN_W){1'b0}}, dest_off_r};
            default                                : beat_data = {seq_r, 16'(beat_r)};
        endcase
    end

    // ---- Main sequencer -----------------------------------------------------
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            en_r          <= 1'b0;      // POR-DISARMED
            forever_r     <= 1'b0;
            running_r     <= 1'b0;
            pkt_len_r     <= LEN_W'(4);
            dest_off_r    <= '0;
            ipg_r         <= '0;
            margin_r      <= '0;
            budget_r      <= '0;
            done_r        <= 1'b0;
            err_ahb_r     <= 1'b0;
            ext_abort_r   <= 1'b0;
            words_r       <= '0;
            stall_r       <= '0;
            state_r       <= S_IDLE;
            beat_r        <= '0;
            total_beats_r <= '0;
            gap_r         <= '0;
            seq_r         <= '0;
            data_word_r   <= '0;
            data_pend_r   <= 1'b0;
        end else begin
            // --- register writes ------------------------------------------
            if (wr_ctrl) begin
                en_r      <= reg_wdata[0];   // explicit 0 disarms; STOP/CLR do not
                forever_r <= reg_wdata[3];
            end
            if (reg_hit && (reg_addr == R_PKT)) begin
                pkt_len_r  <= (reg_wdata[LEN_W-1:0] > MAX_PKT_LEN) ? MAX_PKT_LEN
                                                                   : reg_wdata[LEN_W-1:0];
                dest_off_r <= reg_wdata[16 +: LEN_W];
            end
            if (reg_hit && (reg_addr == R_GAP)) begin
                ipg_r    <= reg_wdata[15:0];
                margin_r <= reg_wdata[31:16];
            end
            if (reg_hit && (reg_addr == R_BUDGET)) budget_r <= reg_wdata;

            if (clr_pulse) begin             // must NOT disturb en_r
                done_r      <= 1'b0;
                err_ahb_r   <= 1'b0;
                ext_abort_r <= 1'b0;
                words_r     <= '0;
                stall_r     <= '0;
            end

            if (ext_collide) ext_abort_r <= 1'b1;

            // --- run control ----------------------------------------------
            if (stop_pulse) running_r <= 1'b0;
            else if (start_pulse && en_r) begin
                running_r <= 1'b1;           // START without EN is a no-op
                done_r    <= 1'b0;
            end

            // --- stall accounting (saturating) ----------------------------
            if (running_r && (state_r != S_SEND) && !(&stall_r)) begin
                stall_r <= stall_r + 1'b1;
            end else if (gen_owns && (state_r == S_SEND) && !fc_hreadyout && !(&stall_r)) begin
                stall_r <= stall_r + 1'b1;
            end

            // --- sequencer -------------------------------------------------
            unique case (state_r)
                S_IDLE: begin
                    if (running_r) state_r <= S_ARMED;
                end

                S_ARMED: begin
                    if (!running_r) begin
                        state_r <= S_IDLE;
                    end else if (!forever_r && (budget_r == '0)) begin
                        running_r <= 1'b0;
                        done_r    <= 1'b1;
                        state_r   <= S_IDLE;
                    end else if (can_take) begin
                        // Reserve the whole packet's credit BEFORE the first beat.
                        total_beats_r <= (LEN_W+2)'(pkt_len_r) + (LEN_W+2)'(2);
                        beat_r        <= '0;
                        data_pend_r   <= 1'b0;
                        state_r       <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (fc_hresp) begin
                        // The adapter's TX_STALL_TIMEOUT fired. Stop; do NOT
                        // auto-restart — the peer is mid-packet.
                        err_ahb_r   <= 1'b1;
                        running_r   <= 1'b0;
                        data_pend_r <= 1'b0;
                        state_r     <= S_IDLE;
                    end else if (fc_hreadyout) begin
                        // One HREADY governs both phases: this cycle completes any
                        // outstanding data phase AND accepts the current address.
                        if (data_complete && !(&words_r)) words_r <= words_r + 1'b1;
                        if (sending_addr) begin
                            // Accept address beat_r; its data trails one cycle.
                            data_word_r <= beat_data;
                            data_pend_r <= 1'b1;
                            beat_r      <= beat_r + 1'b1;
                        end else begin
                            // Final data phase just drained — packet complete.
                            data_pend_r <= 1'b0;
                            seq_r       <= seq_r + 1'b1;
                            gap_r       <= ipg_r;
                            // FIX (link-survey campaign, 2026-08-01): when the
                            // configured inter-packet gap is already zero,
                            // S_GAP would do nothing but immediately observe
                            // gap_r=='0 and fall through to S_ARMED on its
                            // very next cycle (see S_GAP below) — that extra
                            // registered check-then-transition cycle is pure
                            // dead time with IPG=0. Skip straight to S_ARMED
                            // in that case; S_ARMED unconditionally
                            // re-validates running_r/budget_r/can_take
                            // regardless of which state it was entered from,
                            // so admission safety is unchanged — only the
                            // timing of that check moves one cycle earlier.
                            // The ipg_r!=0 path (gap_r counting down) is
                            // completely untouched.
                            state_r     <= (ipg_r == '0) ? S_ARMED : S_GAP;
                            if (!forever_r) begin
                                budget_r <= (budget_r > SYS_DATA_W'(total_beats_r))
                                          ? (budget_r - SYS_DATA_W'(total_beats_r)) : '0;
                            end
                        end
                    end
                end

                S_GAP: begin
                    if (gap_r != '0) gap_r <= gap_r - 1'b1;
                    else             state_r <= running_r ? S_ARMED : S_IDLE;
                end

                default: state_r <= S_IDLE;
            endcase
        end
    end

    // Consume the reservation on the cycle the packet is admitted.
    assign credit_consume_vld = (state_r == S_ARMED) && can_take && !CREDIT_GATE_DIS
                             && !(!forever_r && (budget_r == '0));
    assign credit_consume_val = need_words;

    // ---- AHB master drive ---------------------------------------------------
    // Ownership holds for the whole packet — through the final data phase after
    // the last address is issued (data_pend_r), so the last word is never
    // orphaned by dropping the mux early.
    assign gen_owns   = (state_r == S_SEND);
    // Address phase only while addresses remain; every beat NONSEQ (addresses
    // differ each beat, so the adapter's same-address held-NONSEQ lock never
    // engages, fc_adapter:240). Once the last address is issued we drive IDLE
    // and only the trailing data phase completes.
    assign gen_htrans = sending_addr ? 2'b10 : 2'b00;
    assign gen_hsize  = 3'b010;                     // 32-bit
    assign gen_hwrite = 1'b1;
    assign gen_haddr  = RAM_ADDR_W'({beat_r, 2'b00});
    // HWDATA trails HADDR by one cycle (AHB pipelining): present the data for
    // the address accepted last cycle.
    assign gen_hwdata = data_word_r;
    assign txgen_active = gen_owns;

    // ---- Register reads -----------------------------------------------------
    always_comb begin
        reg_rdata = '0;
        unique case (reg_addr)
            R_CTRL:   reg_rdata = {27'h0, 1'b0, forever_r, 1'b0, 1'b0, en_r};
            R_PKT:    reg_rdata = {{(16-LEN_W){1'b0}}, dest_off_r,
                                   {(16-LEN_W){1'b0}}, pkt_len_r};
            R_GAP:    reg_rdata = {margin_r, ipg_r};
            R_BUDGET: reg_rdata = budget_r;
            R_STATUS: reg_rdata = {25'h0,
                                   !CREDIT_GATE_DIS,     // [6] gate compiled in
                                   ext_abort_r,          // [5]
                                   err_ahb_r,            // [4]
                                   (gen_owns && !fc_hreadyout), // [3] STALL_AHB
                                   (running_r && !credit_ok),   // [2] STALL_CREDIT
                                   done_r,               // [1]
                                   running_r};           // [0]
            R_WORDS:  reg_rdata = words_r;
            R_STALL:  reg_rdata = stall_r;
            R_ID:     reg_rdata = TXGEN_ID_VAL;
            default:  reg_rdata = '0;
        endcase
    end

endmodule

`default_nettype wire
