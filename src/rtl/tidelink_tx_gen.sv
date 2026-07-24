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
    logic [LEN_W+1:0]        beat_r;        // 0=len word, 1=dest, 2..N+1 payload
    logic [LEN_W+1:0]        total_beats_r; // pkt_len + 2
    logic [15:0]             gap_r;
    logic [15:0]             seq_r;         // packet sequence, into the payload

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
    wire ext_idle   = ~ext_htrans[1];
    wire can_take   = en_r && running_r && ext_idle && credit_ok;
    // An external beat while we own the port is refused by tidelink_top with a
    // two-cycle AHB ERROR; record it so the refusal is never silent.
    wire ext_collide = gen_owns && ext_htrans[1];

    wire beat_accept = gen_owns && (state_r == S_SEND) && fc_hreadyout;
    wire last_beat   = beat_accept && (beat_r == (total_beats_r - (LEN_W+2)'(1)));

    // ---- Payload ------------------------------------------------------------
    // Position-encoded so a 2-word shift (the phantom-pop signature,
    // tidelink_fifo_ctrl.sv:324-339) is caught by a byte-exact drain.
    logic [SYS_DATA_W-1:0] beat_data;
    always_comb begin
        beat_data = '0;
        unique case (beat_r)
            // Length lives in [31:20] — tidelink_fifo_mem.sv:169.
            {(LEN_W+2){1'b0}}                      : beat_data = {pkt_len_r, 20'h0};
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
                        state_r       <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (fc_hresp) begin
                        // The adapter's TX_STALL_TIMEOUT fired. Stop; do NOT
                        // auto-restart — the peer is mid-packet.
                        err_ahb_r <= 1'b1;
                        running_r <= 1'b0;
                        state_r   <= S_IDLE;
                    end else if (beat_accept) begin
                        if (!(&words_r)) words_r <= words_r + 1'b1;
                        if (last_beat) begin
                            seq_r   <= seq_r + 1'b1;
                            gap_r   <= ipg_r;
                            state_r <= S_GAP;
                            if (!forever_r) begin
                                budget_r <= (budget_r > SYS_DATA_W'(total_beats_r))
                                          ? (budget_r - SYS_DATA_W'(total_beats_r)) : '0;
                            end
                        end else begin
                            beat_r <= beat_r + 1'b1;
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
    assign gen_owns   = (state_r == S_SEND);
    assign gen_htrans = gen_owns ? 2'b10 : 2'b00;   // every beat NONSEQ: the
                                                    // addresses differ, so the
                                                    // adapter's same-address
                                                    // held-NONSEQ lock never
                                                    // engages (fc_adapter:240)
    assign gen_hsize  = 3'b010;                     // 32-bit
    assign gen_hwrite = 1'b1;
    assign gen_haddr  = RAM_ADDR_W'({beat_r, 2'b00});
    assign gen_hwdata = beat_data;
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
