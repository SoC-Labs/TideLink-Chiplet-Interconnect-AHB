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
    parameter FC_DATA_W  = 48        // FC node data width
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
    input  wire  [RAM_ADDR_W-1:0]  ahb_tx_haddr,
    input  wire               [1:0] ahb_tx_htrans,
    input  wire               [2:0] ahb_tx_hsize,
    input  wire                     ahb_tx_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_tx_hwdata,
    input  wire                     ahb_tx_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_tx_hrdata,
    output wire                     ahb_tx_hresp,
    output wire                     ahb_tx_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Slave — Returner Interception
    // (Returner AHB master connects here; writes become FC sideband packets)
    // --------------------------------------------------------------------------
    input  wire  [SYS_ADDR_W-1:0]  rtn_haddr,
    input  wire  [SYS_DATA_W-1:0]  rtn_hwdata,
    input  wire               [1:0] rtn_htrans,
    input  wire               [2:0] rtn_hsize,
    input  wire                     rtn_hwrite,
    output wire                     rtn_hready,
    output wire                     rtn_hresp,
    output wire  [SYS_DATA_W-1:0]  rtn_hrdata,

    // --------------------------------------------------------------------------
    // AHB Master — RX FIFO Path (FIFO_DATA packets → local FIFO data window)
    // Uses addr_offset directly as FIFO byte address (no base address needed)
    // --------------------------------------------------------------------------
    output wire  [RAM_ADDR_W-1:0]  fc_rx_fifo_haddr,
    output wire  [SYS_DATA_W-1:0]  fc_rx_fifo_hwdata,
    output wire               [1:0] fc_rx_fifo_htrans,
    output wire               [2:0] fc_rx_fifo_hsize,
    output wire                     fc_rx_fifo_hwrite,
    input  wire                     fc_rx_fifo_hready,
    input  wire                     fc_rx_fifo_hresp,
    input  wire  [SYS_DATA_W-1:0]  fc_rx_fifo_hrdata,

    // --------------------------------------------------------------------------
    // AHB Master — RX Config Path (SIDEBAND packets → local APB config regs)
    // Uses addr_offset directly as APB register offset (no base address needed)
    // --------------------------------------------------------------------------
    output wire  [APB_ADDR_W-1:0]  fc_rx_cfg_haddr,
    output wire  [SYS_DATA_W-1:0]  fc_rx_cfg_hwdata,
    output wire               [1:0] fc_rx_cfg_htrans,
    output wire               [2:0] fc_rx_cfg_hsize,
    output wire                     fc_rx_cfg_hwrite,
    input  wire                     fc_rx_cfg_hready,
    input  wire                     fc_rx_cfg_hresp,
    input  wire  [SYS_DATA_W-1:0]  fc_rx_cfg_hrdata,

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

    // Address phase detection
    wire tx_valid_addr_phase = ahb_tx_hsel & ahb_tx_htrans[1] & ahb_tx_hready & ahb_tx_hwrite;

    // Registered address from address phase (valid in data phase)
    logic [RAM_ADDR_W-1:0] tx_addr_r;
    logic                  tx_data_phase_r;  // Flag: data phase pending
    
    wire rtn_fc_valid;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_addr_r       <= '0;
            tx_data_phase_r <= 1'b0;
        end else begin
            if (tx_valid_addr_phase) begin
                tx_addr_r       <= ahb_tx_haddr;
                tx_data_phase_r <= 1'b1;
            end else if (tx_data_phase_r && tl_fc_a2l_ready && !rtn_fc_valid) begin
                // Data phase completed, FC accepted the word (and returner not blocking)
                tx_data_phase_r <= 1'b0;
            end
        end
    end

    // TX aperture FC word (available during data phase)
    wire [FC_DATA_W-1:0] tx_fc_word  = {PKT_FIFO_DATA, tx_addr_r, ahb_tx_hwdata};
    wire                 tx_fc_valid = tx_data_phase_r;

    // TX aperture HREADY: stall when in data phase and FC not ready,
    // or when returner sideband has priority on the FC TX interface
    assign ahb_tx_hreadyout = tx_data_phase_r ? (tl_fc_a2l_ready & ~rtn_fc_valid) : 1'b1;
    assign ahb_tx_hresp     = 1'b0;  // No error responses
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
            end else if (rtn_pending_r && tl_fc_a2l_ready) begin
                rtn_pending_r <= 1'b0;
            end
        end
    end

    // Returner FC word (available during data phase)
    wire [FC_DATA_W-1:0] rtn_fc_word  = {PKT_SIDEBAND, rtn_addr_latched_r, rtn_hwdata};
    assign               rtn_fc_valid = rtn_pending_r;

    // Returner HREADY: stall when pending FC word can't be sent
    assign rtn_hready = rtn_pending_r ? tl_fc_a2l_ready : 1'b1;
    assign rtn_hresp  = 1'b0;
    assign rtn_hrdata = '0;

    // =========================================================================
    // TX Arbiter — Mux TX aperture and returner to single FC TX output
    // =========================================================================
    // Priority: returner sideband > TX aperture
    // (credit/doorbell are infrequent but time-sensitive — delaying credit
    // return can cause remote FIFO back-pressure)

    assign tl_fc_a2l_valid = tx_fc_valid | rtn_fc_valid;
    assign tl_fc_a2l_data  = rtn_fc_valid ? rtn_fc_word : tx_fc_word;

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

    rx_state_t rx_state_r, rx_state_next;

    // Latch FC RX word when accepted
    logic [FC_DATA_W-1:0] rx_fc_word_r;
    logic                 rx_pending_r;

    // Decoded fields from latched FC word
    wire  [1:0]            rx_pkt_type    = rx_fc_word_r[47:46];
    wire  [13:0]           rx_addr_offset = rx_fc_word_r[45:32];
    wire  [SYS_DATA_W-1:0] rx_payload    = rx_fc_word_r[31:0];

    // Route selection: which AHB master port to drive
    wire rx_is_fifo = (rx_pkt_type == PKT_FIFO_DATA);

    // HREADY from the active target port
    wire rx_active_hready = rx_is_fifo ? fc_rx_fifo_hready : fc_rx_cfg_hready;

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
            end else if (rx_state_r == RX_DATA_PHASE && rx_active_hready) begin
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
                if (rx_active_hready)
                    rx_state_next = RX_DATA_PHASE;
            end
            RX_DATA_PHASE: begin
                if (rx_active_hready)
                    rx_state_next = RX_IDLE;
            end
            default: rx_state_next = RX_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // RX FIFO AHB Master — drives FIFO_DATA writes to local FIFO data window
    // -------------------------------------------------------------------------
    assign fc_rx_fifo_haddr  = (rx_state_r == RX_ADDR_PHASE && rx_is_fifo) ? rx_addr_offset[RAM_ADDR_W-1:0] : '0;
    assign fc_rx_fifo_htrans = (rx_state_r == RX_ADDR_PHASE && rx_is_fifo) ? HTRANS_NONSEQ : HTRANS_IDLE;
    assign fc_rx_fifo_hsize  = HSIZE_WORD;
    assign fc_rx_fifo_hwrite = (rx_state_r == RX_ADDR_PHASE && rx_is_fifo) ? 1'b1 : 1'b0;
    assign fc_rx_fifo_hwdata = (rx_state_r == RX_DATA_PHASE && rx_is_fifo) ? rx_payload : '0;

    // -------------------------------------------------------------------------
    // RX Config AHB Master — drives SIDEBAND writes to local APB config regs
    // -------------------------------------------------------------------------
    assign fc_rx_cfg_haddr  = (rx_state_r == RX_ADDR_PHASE && !rx_is_fifo) ? rx_addr_offset[APB_ADDR_W-1:0] : '0;
    assign fc_rx_cfg_htrans = (rx_state_r == RX_ADDR_PHASE && !rx_is_fifo) ? HTRANS_NONSEQ : HTRANS_IDLE;
    assign fc_rx_cfg_hsize  = HSIZE_WORD;
    assign fc_rx_cfg_hwrite = (rx_state_r == RX_ADDR_PHASE && !rx_is_fifo) ? 1'b1 : 1'b0;
    assign fc_rx_cfg_hwdata = (rx_state_r == RX_DATA_PHASE && !rx_is_fifo) ? rx_payload : '0;

endmodule
