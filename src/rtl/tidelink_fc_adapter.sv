//-----------------------------------------------------------------------------
// SoCLabs TideLink FC Adapter
//
// Bridges TideLink AHB traffic to/from a dedicated Wlink FC node (48-bit,
// data_id=0xa1). Three functional paths:
//
//   TX aperture (AHB slave): CPU/DMA writes FIFO words → FC TX as FIFO_DATA
//   Returner interception (AHB slave): Returner credit/doorbell writes →
//                                      FC TX as CREDIT_RETURN / DOORBELL
//   RX path (AHB master): FC RX words → AHB writes to local FIFO / APB regs
//
// FC data layout (48 bits):
//   [47:46] pkt_type    — 00=FIFO_DATA, 01=SIDEBAND
//   [45:32] addr_offset — 14-bit byte address (covers 16KB FIFO aperture)
//   [31:0]  payload     — 32-bit data word
//
// TX arbitration: returner sideband has priority over TX aperture
// (credit/doorbell writes are infrequent but time-sensitive; delaying
// credit return can cause remote FIFO back-pressure).
//
// RX routing: FIFO_DATA writes go to RX_FIFO_BASE + addr_offset;
//             SIDEBAND writes go to RX_CFG_BASE + addr_offset.
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

module tidelink_fc_adapter #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,       // FIFO aperture address width
    parameter APB_ADDR_W = 12,       // APB config address width
    parameter FC_DATA_W  = 48,       // FC node data width
    // Bug-A wedge-mechanism fix (2026-06-11): bound the TX-aperture stall.
    // 2^16 hclk = ~1.3 ms @ 50 MHz — orders beyond healthy credit-return
    // latency; only a genuinely dead/stalled link reaches it. Sim overrides
    // this small (cocotb/tidelink_fc_adapter/test_buga.py).
    parameter TX_STALL_TIMEOUT_LOG2 = 16
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,
    input  wire                     hresetn,

    // --------------------------------------------------------------------------
    // AHB Slave — TX Aperture (CPU/DMA writes FIFO packets here)
    // --------------------------------------------------------------------------
    input  wire                     ahb_tx_hsel,
    input  wire   [RAM_ADDR_W-1:0]  ahb_tx_haddr,
    input  wire               [1:0] ahb_tx_htrans,
    input  wire               [2:0] ahb_tx_hsize,
    input  wire                     ahb_tx_hwrite,
    input  wire   [SYS_DATA_W-1:0]  ahb_tx_hwdata,
    input  wire                     ahb_tx_hready,
    output wire   [SYS_DATA_W-1:0]  ahb_tx_hrdata,
    output wire                     ahb_tx_hresp,
    output wire                     ahb_tx_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Slave — Returner Interception
    // (Returner AHB master connects here; writes become FC sideband packets)
    // --------------------------------------------------------------------------
    input  wire   [SYS_ADDR_W-1:0]  rtn_haddr,
    input  wire   [SYS_DATA_W-1:0]  rtn_hwdata,
    input  wire               [1:0] rtn_htrans,
    input  wire               [2:0] rtn_hsize,
    input  wire                     rtn_hwrite,
    output wire                     rtn_hready,
    output wire                     rtn_hresp,
    output wire   [SYS_DATA_W-1:0]  rtn_hrdata,

    // --------------------------------------------------------------------------
    // Direct Write — RX FIFO Path (FIFO_DATA packets → local FIFO data window)
    // Single-cycle valid/addr/data, bypasses AHB for 2x throughput.
    // mark_debug — Bug A probes per docs/ILA_PLACEMENT_AUDIT_2026_05_29.md §3
    // --------------------------------------------------------------------------
    output wire                     fc_rx_fifo_valid,
    output wire                     fc_rx_fifo_write,
    output wire   [RAM_ADDR_W-1:0]  fc_rx_fifo_addr,
    output wire   [SYS_DATA_W-1:0]  fc_rx_fifo_wdata,
    input  wire                     fc_rx_fifo_ready,

    // --------------------------------------------------------------------------
    // APB Master — RX Config Path (SIDEBAND packets → local APB config regs)
    // Drives APB directly, eliminating the AHB-to-APB bridge overhead.
    // --------------------------------------------------------------------------
    output wire  [APB_ADDR_W-1:0]  fc_rx_cfg_paddr,
    output wire  [SYS_DATA_W-1:0]  fc_rx_cfg_pwdata,
    output wire                     fc_rx_cfg_psel,
    output wire                     fc_rx_cfg_penable,
    output wire                     fc_rx_cfg_pwrite,
    input  wire  [SYS_DATA_W-1:0]  fc_rx_cfg_prdata,
    input  wire                     fc_rx_cfg_pready,

    // --------------------------------------------------------------------------
    // Servo Timestamp Injection (SIDEBAND packets from PTP servo)
    // --------------------------------------------------------------------------
    input  wire                     servo_fc_valid,
    input  wire   [FC_DATA_W-1:0]   servo_fc_data,
    output wire                     servo_fc_ready,

    // --------------------------------------------------------------------------
    // TideChart AXI-Stream Port (for TideChart or other external modules)
    // Packets with pkt_type=2'b10 are routed to/from this port.
    // Subtype 0x0020 (PUF_READ_REQ) is handled locally, not sent over FC.
    // --------------------------------------------------------------------------
    input  wire                     tc_axis_tx_tvalid,
    input  wire   [FC_DATA_W-1:0]   tc_axis_tx_tdata,
    output wire                     tc_axis_tx_tready,

    output reg                      tc_axis_rx_tvalid,
    output reg    [FC_DATA_W-1:0]   tc_axis_rx_tdata,
    input  wire                     tc_axis_rx_tready,

    // --------------------------------------------------------------------------
    // QoS Priority Hint (from TideChart TC_QOS_CFG, Phase 5A)
    // When >0, PKT_EXT packets get boosted above TX aperture FIFO_DATA.
    // When =0 (default), original fixed priority applies.
    // --------------------------------------------------------------------------
    input  wire               [2:0] tc_qos_priority,

    // --------------------------------------------------------------------------
    // PUF SRAM Read Interface (to tidelink_fifo_mem, for local PUF reads)
    // --------------------------------------------------------------------------
    output reg  [RAM_ADDR_W-3:0]    puf_addr,
    output reg                      puf_req,
    input  wire [31:0]              puf_rdata,
    input  wire                     puf_ack,

    // --------------------------------------------------------------------------
    // FC Node Interface (to Wlink TideLink FC node)
    // --------------------------------------------------------------------------
    output wire                     tl_fc_a2l_valid,
    output wire   [FC_DATA_W-1:0]   tl_fc_a2l_data,
    input  wire                     tl_fc_a2l_ready,

    input  wire                     tl_fc_l2a_valid,
    input  wire   [FC_DATA_W-1:0]   tl_fc_l2a_data,
    output wire                     tl_fc_l2a_accept
);

    // =========================================================================
    // FC packet type encoding
    // =========================================================================
    localparam [1:0] PKT_FIFO_DATA = 2'b00;
    localparam [1:0] PKT_SIDEBAND  = 2'b01;
    localparam [1:0] PKT_EXT       = 2'b10;  // Extension (TideChart etc.)

    // TideChart PUF subtypes (local-only, never sent over FC)
    localparam [13:0] SUB_PUF_READ_REQ = 14'h0020;
    localparam [13:0] SUB_PUF_READ_RSP = 14'h0021;

    // AHB constants
    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [2:0] HSIZE_WORD    = 3'b010;

    // =========================================================================
    // TX Aperture — AHB Slave → FC TX (FIFO_DATA packets)
    // =========================================================================
    //
    // AHB address phase: latch haddr when valid write detected
    // AHB data phase (next cycle): combine latched addr + hwdata → FC word
    // Stall HREADY when FC TX is not ready or returner has priority conflict

    // Forward declarations for skid buffer and arbiter signals (defined below)
    wire skid_can_accept;
    wire rtn_fc_valid;
    wire sideband_grant;
    wire arb_valid;

    // Address phase detection.
    //
    // Held-NONSEQ one-shot lock (SoC Labs 2026-07-03, silicon x5 TX dup fix):
    // the Xilinx axi_ahblite_bridge:3.0 master holds HTRANS=NONSEQ with
    // HADDR/HWDATA stable for the duration of its internal AXI transaction
    // (~10 hclk on the PS GP1->SMC->bridge path) while the vivado wrapper
    // loops our HREADYOUT back as HREADY. A level-only addr-phase detect
    // then re-latches every time a data phase completes during the hold ->
    // EXACTLY +5 duplicate FC words per single PS store on silicon (a2l
    // wptr +5/word, 4-word burst -> +20) -> pktnum (= replay rptr) walks 5x
    // -> fe credit ceiling 0x1f exhausted after ~6 words -> exp saturates
    // 0x20 -> NACK/replay wedge. Repro: cocotb/tidelink_fc_adapter/
    // test_held_nonseq.py (unfixed: 11 dups/store at unit-sim cadence).
    //
    // Contract: a held NONSEQ at the SAME address is ONE transfer. The lock
    // sets when an addr phase is accepted and suppresses re-acceptance until
    // HTRANS deasserts (IDLE gap between bridge transactions) or HADDR
    // moves (pipelined bursts unaffected). Trade-off (documented): a
    // spec-master issuing back-to-back same-address NONSEQ beats with no
    // IDLE gap would be collapsed to one transfer — unreachable through the
    // axi_ahblite_bridge, which idles between AXI transactions.
    logic                  tx_xfer_lock_r;
    logic [RAM_ADDR_W-1:0] tx_lock_addr_r;
    wire tx_lock_hit = tx_xfer_lock_r && (ahb_tx_haddr == tx_lock_addr_r);
    wire tx_valid_addr_phase = ahb_tx_hsel & ahb_tx_htrans[1] & ahb_tx_hready
                               & ahb_tx_hwrite & ~tx_lock_hit;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_xfer_lock_r <= 1'b0;
            tx_lock_addr_r <= '0;
        end else if (tx_valid_addr_phase) begin
            tx_xfer_lock_r <= 1'b1;
            tx_lock_addr_r <= ahb_tx_haddr;
        // TIDELINK 2026-07-08 (A->B 5x-over-advance / die_a-TX cap fix, v2): clear the
        // held-NONSEQ lock ONLY on a genuine transaction end -- a DESELECT (~hsel) or a
        // NEW NONSEQ at a DIFFERENT address. The 2026-07-07 version also cleared on a
        // bare IDLE beat (htrans==2'b00) WHILE hsel stays high; on silicon the
        // axi_ahblite_bridge inserts such a mid-held-NONSEQ IDLE (hsel held, htrans->
        // IDLE for a beat, then back to the SAME-address NONSEQ) -> the old clause
        // released the lock mid-store -> the next same-address NONSEQ re-accepted the
        // SAME store -> ~5 duplicate FC words/store STILL leaked on silicon (credit
        // ptr=30/31 after 8 words, exp saturates 0x20) even though the sim's continuous
        // held-NONSEQ writer (which deselects between stores) read 1:1 and hid it.
        // A mid-store IDLE with hsel HELD is a CONTINUATION, not a boundary: hold the
        // lock through it. Real words still separate correctly -- the data path writes
        // INCREMENTING addresses (tl39 txburst = TXBASE+i*4), so each new word is a
        // DIFFERENT-address NONSEQ that clears+re-locks below; and a true transaction
        // end deselects (~hsel). One PS store == one FC word == one a2l entry == one
        // emitted packet (the FCSM emit is 1:1). Verified in the pair sim with a
        // mid-hold-IDLE bridge model.
        end else if (!ahb_tx_hsel
                     || (ahb_tx_hsel & ahb_tx_htrans[1] & (ahb_tx_haddr != tx_lock_addr_r))) begin
            tx_xfer_lock_r <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // ILA debug taps (FPGA_INSERT_DEBUG_CORE=1) — die_a-TX tx_xfer_lock diagnosis
    // (2026-07-07). Probe the AHB-TX handshake + lock state + FC emit so a
    // silicon capture during an A->B burst shows EXACTLY why tx_xfer_lock re-arms
    // mid-held-NONSEQ on die_a (the 5x-over-advance that caps A->B at ~6 words).
    // mark_debug on live-driven wires (never constant-folded) => no dbg_hub /
    // opt_design LUTLP blocker. Stripped automatically on non-ILA builds.
    // -------------------------------------------------------------------------
    (* mark_debug = "true" *) wire        dbg_tx_hsel      = ahb_tx_hsel;
    (* mark_debug = "true" *) wire [1:0]  dbg_tx_htrans    = ahb_tx_htrans;
    (* mark_debug = "true" *) wire        dbg_tx_hready    = ahb_tx_hready;
    (* mark_debug = "true" *) wire        dbg_tx_hwrite    = ahb_tx_hwrite;
    (* mark_debug = "true" *) wire        dbg_tx_hreadyout = ahb_tx_hreadyout;
    (* mark_debug = "true" *) wire [7:0]  dbg_tx_haddr     = ahb_tx_haddr[7:0];
    (* mark_debug = "true" *) wire        dbg_tx_lock      = tx_xfer_lock_r;
    (* mark_debug = "true" *) wire        dbg_tx_lock_hit  = tx_lock_hit;
    (* mark_debug = "true" *) wire        dbg_tx_valid_ap  = tx_valid_addr_phase;
    (* mark_debug = "true" *) wire        dbg_tx_a2l_valid = tl_fc_a2l_valid;
    (* mark_debug = "true" *) wire        dbg_tx_arb_valid = arb_valid;

    // Registered address from address phase (valid in data phase)
    logic [RAM_ADDR_W-1:0] tx_addr_r;
    logic                  tx_data_phase_r;  // Flag: data phase pending

    // -------------------------------------------------------------------------
    // Bug-A fix (2026-06-09): the AHB-TX data phase completes ONLY when the
    // skid genuinely accepts the word. The old L10/L11 "wedge watchdog" forced
    // HREADYOUT=1 (acking the AHB beat to the PS) after WEDGE_LIMIT=16 cycles of
    // skid back-pressure *even though the 1-entry skid was still full* — and the
    // skid load condition (arb_valid && skid_can_accept) then refused the word.
    // Result: every CPU burst beat after the first was SILENTLY DROPPED whenever
    // tl_fc_a2l_ready stayed low for >16 cy. That is the normal bilateral
    // bring-up condition (FCSM in LINK_IDLE awaiting credit), so the app->link
    // replay FIFO never filled past one word and the master FCSM never advanced.
    // Reproduced by cocotb/tidelink_fc_adapter/test_buga.py
    //   ::test_watchdog_drops_second_write (tx_dropped_cnt=2, 3/4 beats lost).
    //
    // Correct behaviour for a 1-entry skid feeding a flow-controlled FC link:
    // HONESTLY back-pressure the CPU (hold HREADYOUT low) until the skid drains.
    // The link is a live consumer; transient not-ready is real, recoverable
    // back-pressure, not a wedge. A genuine permanent wedge is now handled at
    // the PS/AXI layer (axi_ahblite_bridge timeout) rather than by corrupting
    // the data stream here. tx_dropped_cnt_r retained for observability and is
    // now expected to read 0 in normal operation; any non-zero value flags a
    // genuine sustained wedge for software to inspect.
    logic [15:0] tx_dropped_cnt_r;  // observability only; never incremented on
                                    // healthy back-pressure (kept for HW probes)

    // ── Bug-A wedge-mechanism fix (2026-06-11): bounded stall + AHB ERROR ──
    // Honest back-pressure (hold HREADYOUT low) is correct for transient
    // skid-full, but holding it FOREVER converts a dead link into a PS AXI
    // deadlock: bench-confirmed on z2_02 (hwtest 5b storm, 2026-06-10 —
    // SSH death, JTAG rst -system required). The earlier assumption that
    // "the axi_ahblite_bridge timeout handles a permanent wedge" is FALSE
    // on Zynq-7000: the PS interconnect has no such timeout.
    //
    // After TX_STALL_TIMEOUT cycles of continuous data-phase back-pressure,
    // terminate the in-flight transfer with the standard AHB two-cycle
    // ERROR response (cy1: HREADYOUT=0 + HRESP=1; cy2: HREADYOUT=1 +
    // HRESP=1). The beat is dropped EXPLICITLY — the master sees ERROR
    // (the L11 watchdog's sin was dropping with OKAY) — and
    // tx_dropped_cnt_r increments, matching its documented "non-zero flags
    // a genuine sustained wedge" semantic. Healthy back-pressure below the
    // timeout is untouched: no error, no drop, the beat completes when the
    // skid drains.
    logic [TX_STALL_TIMEOUT_LOG2:0] tx_stall_ctr_r;
    logic                           tx_err1_r, tx_err2_r;
    wire tx_stalled = tx_data_phase_r && !(skid_can_accept && !sideband_grant);
    wire tx_stall_expired = tx_stall_ctr_r[TX_STALL_TIMEOUT_LOG2];

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_addr_r       <= '0;
            tx_data_phase_r <= 1'b0;
            tx_stall_ctr_r  <= '0;
            tx_err1_r       <= 1'b0;
            tx_err2_r       <= 1'b0;
        end else begin
            tx_err2_r <= tx_err1_r;
            tx_err1_r <= 1'b0;
            if (tx_valid_addr_phase) begin
                tx_addr_r       <= ahb_tx_haddr;
                tx_data_phase_r <= 1'b1;
                tx_stall_ctr_r  <= '0;
            end else if (tx_data_phase_r && skid_can_accept && !sideband_grant) begin
                // Data phase completes ONLY when the skid actually accepts the
                // word — never on a watchdog-forced ready (that dropped words).
                tx_data_phase_r <= 1'b0;
                tx_stall_ctr_r  <= '0;
            end else if (tx_stalled) begin
                if (tx_stall_expired) begin
                    // Abandon the beat with an explicit ERROR response.
                    tx_data_phase_r <= 1'b0;
                    tx_stall_ctr_r  <= '0;
                    tx_err1_r       <= 1'b1;
                end else begin
                    tx_stall_ctr_r <= tx_stall_ctr_r + 1'b1;
                end
            end
        end
    end

    // tx_dropped_cnt_r counts timeout-aborted beats (saturating). Zero in
    // normal operation INCLUDING healthy back-pressure; non-zero means the
    // link stalled past TX_STALL_TIMEOUT with a write in flight — the
    // documented "genuine sustained wedge" flag for software/ILA
    // (docs/ILA_PLACEMENT_AUDIT_2026_05_29.md §3).
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            tx_dropped_cnt_r <= '0;
        else if (tx_err1_r && tx_dropped_cnt_r != 16'hFFFF)
            tx_dropped_cnt_r <= tx_dropped_cnt_r + 16'd1;
    end

    // TX aperture FC word (available during data phase)
    wire [FC_DATA_W-1:0] tx_fc_word  = {PKT_FIFO_DATA, tx_addr_r, ahb_tx_hwdata};
    wire                 tx_fc_valid = tx_data_phase_r;

    // TX aperture HREADY: stall (back-pressure the CPU) while in the data phase
    // and the skid buffer can't accept the word, or while sideband has arbiter
    // priority. No watchdog-forced ready: a word is acked to the PS iff it is
    // actually captured into the skid, so a compliant AHB burst never loses a
    // beat (Bug-A fix, 2026-06-09). A stall that outlives TX_STALL_TIMEOUT
    // terminates in the two-cycle AHB ERROR response instead of a PS deadlock
    // (wedge-mechanism fix, 2026-06-11).
    assign ahb_tx_hreadyout = tx_err1_r ? 1'b0 :
                              tx_err2_r ? 1'b1 :
                              tx_data_phase_r
                              ? (skid_can_accept & ~sideband_grant)
                              : 1'b1;
    assign ahb_tx_hresp     = tx_err1_r | tx_err2_r;  // ERROR on stall timeout
    assign ahb_tx_hrdata    = '0;    // TX aperture is write-only

    // =========================================================================
    // Returner Interception — AHB Slave → FC TX (SIDEBAND packets)
    // =========================================================================
    //
    // The returner is a write-only AHB master with a 3-state FSM:
    //   IDLE → ADDR_PHASE → DATA_PHASE
    // We intercept its writes and convert them to FC sideband packets.
    // All returner writes use PKT_SIDEBAND. The addr_offset carries the
    // lower 14 bits of the target register address (0x014, 0x020, 0x024).
    // The RX side uses this to write to the correct APB register.

    // Address phase detection (returner drives htrans=NONSEQ for writes)
    wire rtn_valid_addr_phase = rtn_htrans[1] & rtn_hwrite;

    // Lower 14 bits of returner address = target register offset
    wire [13:0] rtn_addr_offset = rtn_haddr[13:0];

    logic [13:0] rtn_addr_latched_r;
    logic        rtn_pending_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            rtn_addr_latched_r <= '0;
            rtn_pending_r      <= 1'b0;
        end else begin
            if (rtn_valid_addr_phase && rtn_hready) begin
                rtn_addr_latched_r <= rtn_addr_offset;
                rtn_pending_r      <= 1'b1;
            end else if (rtn_pending_r && skid_can_accept) begin
                rtn_pending_r <= 1'b0;
            end
        end
    end

    // Returner FC word (available during data phase)
    wire [FC_DATA_W-1:0] rtn_fc_word  = {PKT_SIDEBAND, rtn_addr_latched_r, rtn_hwdata};
    assign               rtn_fc_valid = rtn_pending_r;

    // Returner HREADY: stall when pending FC word can't enter skid buffer
    assign rtn_hready = rtn_pending_r ? skid_can_accept : 1'b1;
    assign rtn_hresp  = 1'b0;
    assign rtn_hrdata = '0;

    // =========================================================================
    // TX Arbiter + Skid Buffer
    // =========================================================================
    // Priority: returner sideband > servo > TX aperture (with fairness)
    // A 1-entry skid buffer decouples the Wlink FC ready signal from the
    // AHB HREADY critical path. Common case (skid empty): AHB completes
    // without any Wlink timing dependency.
    //
    // Shortcoming #26 fix: after MAX_SIDEBAND_BURST consecutive sideband
    // grants, force one TX aperture grant to prevent indefinite starvation.

    localparam MAX_SIDEBAND_BURST = 4;
    localparam SB_CNT_W = $clog2(MAX_SIDEBAND_BURST + 1);

    logic [SB_CNT_W-1:0] sideband_burst_r;
    wire sideband_starving = (sideband_burst_r >= SB_CNT_W'(MAX_SIDEBAND_BURST))
                             && tx_fc_valid;

    // -------------------------------------------------------------------------
    // TideChart TX path: split local PUF requests from remote FC packets
    // -------------------------------------------------------------------------
    wire [13:0] tc_tx_subtype = tc_axis_tx_tdata[45:32];
    wire        tc_tx_is_puf  = tc_axis_tx_tvalid && (tc_tx_subtype == SUB_PUF_READ_REQ);
    wire        tc_tx_is_remote = tc_axis_tx_tvalid && !tc_tx_is_puf;

    // -------------------------------------------------------------------------
    // Local PUF read handler
    // Routes PUF_READ_REQ to SRAM, returns PUF_READ_RSP on tc_axis_rx
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        PUF_IDLE    = 2'b00,
        PUF_READ    = 2'b01,
        PUF_RESPOND = 2'b10
    } puf_state_t;

    puf_state_t puf_state_r;
    logic [31:0] puf_rdata_r;
    logic        puf_rsp_valid_r;
    logic [FC_DATA_W-1:0] puf_rsp_data_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            puf_state_r     <= PUF_IDLE;
            puf_req         <= 1'b0;
            puf_addr        <= '0;
            puf_rdata_r     <= '0;
            puf_rsp_valid_r <= 1'b0;
            puf_rsp_data_r  <= '0;
        end else begin
            case (puf_state_r)
                PUF_IDLE: begin
                    puf_rsp_valid_r <= 1'b0;
                    if (tc_tx_is_puf) begin
                        // Extract word address from payload
                        puf_addr    <= tc_axis_tx_tdata[RAM_ADDR_W-3:0];
                        puf_req     <= 1'b1;
                        puf_state_r <= PUF_READ;
                    end
                end

                PUF_READ: begin
                    if (puf_ack) begin
                        puf_req         <= 1'b0;
                        puf_rdata_r     <= puf_rdata;
                        puf_rsp_valid_r <= 1'b1;
                        puf_rsp_data_r  <= {PKT_EXT, SUB_PUF_READ_RSP, puf_rdata};
                        puf_state_r     <= PUF_RESPOND;
                    end
                end

                PUF_RESPOND: begin
                    if (tc_axis_rx_tready) begin
                        puf_rsp_valid_r <= 1'b0;
                        puf_state_r     <= PUF_IDLE;
                    end
                end

                default: puf_state_r <= PUF_IDLE;
            endcase
        end
    end

    // TideChart TX tready: PUF requests accepted by local handler;
    // remote packets accepted by FC arbiter
    assign tc_axis_tx_tready = tc_tx_is_puf ? (puf_state_r == PUF_IDLE) :
                               (skid_can_accept & ~sideband_starving);

    // Track consecutive sideband grants
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            sideband_burst_r <= '0;
        end else if (arb_valid && skid_can_accept) begin
            if (rtn_fc_valid || servo_fc_valid || tc_tx_is_remote) begin
                if (!sideband_starving && sideband_burst_r < SB_CNT_W'(MAX_SIDEBAND_BURST))
                    sideband_burst_r <= sideband_burst_r + SB_CNT_W'(1);
            end else begin
                sideband_burst_r <= '0;  // TX aperture granted, reset counter
            end
        end
    end

    // Arbiter output: priority-aware dispatch (Phase 5A QoS hinting)
    //
    // Fixed priority (always):
    //   1. Returner sideband (credit/doorbell — flow-control critical)
    //   2. Servo sideband (PTP timing)
    //
    // Configurable priority via tc_qos_priority:
    //   When tc_qos_priority > 0: TideChart PKT_EXT > TX aperture FIFO_DATA
    //   When tc_qos_priority = 0: TX aperture FIFO_DATA > TideChart PKT_EXT
    //
    // Starvation prevention applies regardless of QoS setting.
    wire ext_wants = tc_tx_is_remote;
    wire ext_boosted = ext_wants && (|tc_qos_priority);  // Priority > 0 boosts PKT_EXT

    wire ext_grant = ext_wants && !sideband_starving &&
                     (ext_boosted || !tx_fc_valid);       // If boosted: always win vs TX aperture
                                                          // If not boosted: only win when no TX data

    assign sideband_grant = (rtn_fc_valid || servo_fc_valid || ext_grant) && !sideband_starving;
    assign arb_valid = tx_fc_valid | rtn_fc_valid | servo_fc_valid | ext_wants;
    wire [FC_DATA_W-1:0] arb_data  = (sideband_grant && rtn_fc_valid)          ? rtn_fc_word      :
                                     (sideband_grant && servo_fc_valid)        ? servo_fc_data    :
                                     ext_grant                                 ? tc_axis_tx_tdata :
                                     tx_fc_word;

    // Skid buffer registers
    logic                  skid_valid_r;
    logic [FC_DATA_W-1:0]  skid_data_r;

    // Skid buffer can accept when empty OR when FC drains it this cycle
    assign skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            skid_valid_r <= 1'b0;
            skid_data_r  <= '0;
        end else begin
            if (arb_valid && skid_can_accept) begin
                // Load new word from arbiter
                skid_valid_r <= 1'b1;
                skid_data_r  <= arb_data;
            end else if (skid_valid_r && tl_fc_a2l_ready) begin
                // Drain: FC accepted, no new word
                skid_valid_r <= 1'b0;
            end
        end
    end

    // FC interface driven from skid buffer
    assign tl_fc_a2l_valid = skid_valid_r;
    assign tl_fc_a2l_data  = skid_data_r;

    // Servo FC ready: can enter arbiter when skid accepts and no higher-priority source active
    assign servo_fc_ready = skid_can_accept & ~rtn_fc_valid & ~tc_tx_is_remote & ~sideband_starving;

    // =========================================================================
    // RX Path — FC RX → Two AHB Masters (FIFO data + Config registers)
    // =========================================================================
    //
    // Receives 48-bit FC words from Wlink. Decodes pkt_type and replays as
    // AHB master writes on the appropriate port:
    //   FIFO_DATA → fc_rx_fifo_* (FIFO data window, addr_offset is byte addr)
    //   SIDEBAND  → fc_rx_cfg_*  (APB config regs, addr_offset is reg offset)
    //
    // FSM: IDLE → ADDR_PHASE → DATA_PHASE → IDLE
    // Same pattern as tidelink_returner.sv

    typedef enum logic [1:0] {
        RX_IDLE       = 2'b00,
        RX_ADDR_PHASE = 2'b01,
        RX_DATA_PHASE = 2'b10
    } rx_state_t;

    // mark_debug — Bug A probe (RX FSM state) per docs/ILA_PLACEMENT_AUDIT_2026_05_29.md §3
    rx_state_t rx_state_r;
    rx_state_t rx_state_next;

    // Latch FC RX word when accepted
    logic [FC_DATA_W-1:0] rx_fc_word_r;
    logic                 rx_pending_r;

    // Decoded fields from latched FC word
    // mark_debug — Bug A probe (decode of pkt_type, scopes mis-decode vs FIFO drop)
    wire  [1:0]            rx_pkt_type    = rx_fc_word_r[47:46];
    wire  [13:0]           rx_addr_offset = rx_fc_word_r[45:32];
    wire  [SYS_DATA_W-1:0] rx_payload    = rx_fc_word_r[31:0];

    // Route selection: which destination to drive
    // mark_debug — Bug A probe (should pulse with every FIFO write)
    wire rx_is_fifo = (rx_pkt_type == PKT_FIFO_DATA);
    wire rx_is_ext  = (rx_pkt_type == PKT_EXT);

    // Ready from the active target port (direct for FIFO, APB for config)
    // For ext packets, tc_axis_rx_tready is checked only when no PUF response is pending
    wire rx_active_ready = rx_is_fifo ? fc_rx_fifo_ready :
                           rx_is_ext  ? (tc_axis_rx_tready & ~puf_rsp_valid_r) :
                                        fc_rx_cfg_pready;

    // Accept FC RX data when idle and a word is available
    wire rx_accept = tl_fc_l2a_valid & (rx_state_r == RX_IDLE) & ~rx_pending_r;

    assign tl_fc_l2a_accept = rx_accept;

    // Latch incoming FC word
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            rx_fc_word_r <= '0;
            rx_pending_r <= 1'b0;
        end else begin
            if (rx_accept) begin
                rx_fc_word_r <= tl_fc_l2a_data;
                rx_pending_r <= 1'b1;
            end else if ((rx_state_r == RX_DATA_PHASE && rx_active_ready) ||
                        (rx_state_r == RX_ADDR_PHASE && rx_is_fifo && fc_rx_fifo_ready) ||
                        (rx_state_r == RX_ADDR_PHASE && rx_is_ext && tc_axis_rx_tready && !puf_rsp_valid_r)) begin
                // Clear pending: SIDEBAND in DATA_PHASE, FIFO/EXT in ADDR_PHASE
                rx_pending_r <= 1'b0;
            end
        end
    end

    // RX state machine
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            rx_state_r <= RX_IDLE;
        else
            rx_state_r <= rx_state_next;
    end

    always_comb begin
        rx_state_next = rx_state_r;
        case (rx_state_r)
            RX_IDLE: begin
                if (rx_pending_r)
                    rx_state_next = RX_ADDR_PHASE;
            end
            RX_ADDR_PHASE: begin
                if (rx_is_fifo) begin
                    // FIFO direct write: completes in this cycle (addr+data together)
                    if (fc_rx_fifo_ready)
                        rx_state_next = RX_IDLE;
                end else if (rx_is_ext) begin
                    // Extension packet: single-cycle handoff (wait for PUF response to clear)
                    if (tc_axis_rx_tready && !puf_rsp_valid_r)
                        rx_state_next = RX_IDLE;
                end else begin
                    // SIDEBAND APB setup phase → access phase
                    if (rx_active_ready)
                        rx_state_next = RX_DATA_PHASE;
                end
            end
            RX_DATA_PHASE: begin
                // Only SIDEBAND reaches here (APB access phase)
                if (rx_active_ready)
                    rx_state_next = RX_IDLE;
            end
            default: rx_state_next = RX_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // RX FIFO Direct Write — single-cycle addr+data to local FIFO
    // -------------------------------------------------------------------------
    assign fc_rx_fifo_valid = (rx_state_r == RX_ADDR_PHASE) && rx_is_fifo;
    assign fc_rx_fifo_write = 1'b1;
    assign fc_rx_fifo_addr  = rx_addr_offset[RAM_ADDR_W-1:0];
    assign fc_rx_fifo_wdata = rx_payload;

    // -------------------------------------------------------------------------
    // RX Config APB Master — drives SIDEBAND writes to local APB config regs
    // Maps RX FSM states to APB protocol:
    //   RX_ADDR_PHASE = APB setup phase  (psel=1, penable=0)
    //   RX_DATA_PHASE = APB access phase (psel=1, penable=1)
    // -------------------------------------------------------------------------
    wire rx_cfg_active = !rx_is_fifo && !rx_is_ext && (rx_state_r == RX_ADDR_PHASE || rx_state_r == RX_DATA_PHASE);
    assign fc_rx_cfg_paddr   = rx_addr_offset[APB_ADDR_W-1:0];
    assign fc_rx_cfg_pwdata  = rx_payload;
    assign fc_rx_cfg_pwrite  = 1'b1;  // all sideband writes
    assign fc_rx_cfg_psel    = rx_cfg_active;
    assign fc_rx_cfg_penable = !rx_is_fifo && !rx_is_ext && (rx_state_r == RX_DATA_PHASE);

    // -------------------------------------------------------------------------
    // TideChart RX AXI-Stream — mux remote PKT_EXT with local PUF responses
    // PUF responses have priority (they're time-sensitive at boot)
    // -------------------------------------------------------------------------
    wire remote_ext_valid = (rx_state_r == RX_ADDR_PHASE) && rx_is_ext;

    always @(*) begin
        if (puf_rsp_valid_r) begin
            tc_axis_rx_tvalid = 1'b1;
            tc_axis_rx_tdata  = puf_rsp_data_r;
        end else begin
            tc_axis_rx_tvalid = remote_ext_valid;
            tc_axis_rx_tdata  = rx_fc_word_r;
        end
    end

endmodule
