//-----------------------------------------------------------------------------
// SoCLabs TideLink PTP — Single-Phase PTP Module
//
// Implements a single-phase (2-message) Precision Time Protocol over a
// dedicated Wlink FC node (data_id=0xa2, 48-bit). Provides:
//
//   TX path: AHB slave → wait for tx_router_idle → FC TX + PHC hw_capture
//   RX path: FC RX → PHC hw_capture + payload latch + interrupt
//
// Timestamps are captured by pulsing phc_hw_capture at the exact FC
// handshake cycle. The actual timestamp values live in the external PHC's
// HW_CAP_* registers — this module does not contain a counter.
//
// FC data layout (48 bits, same structure as tidelink_fc_adapter):
//   [47:46] pkt_type    — 2'b10 = PTP message
//   [45:32] addr_offset — {10'b0, msg_type[3:0]}
//   [31:0]  payload     — software-defined (sequence number, etc.)
//
// msg_type: 4'h0 = SYNC (grandmaster → subordinate)
//           4'h1 = DELAY_REQ (subordinate → grandmaster)
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

module tidelink_ptp #(
    parameter SYS_DATA_W = 32,
    parameter FC_DATA_W  = 48
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,
    input  wire                     hresetn,

    // --------------------------------------------------------------------------
    // TX Router Idle (from chiplet controller, gating signal)
    // --------------------------------------------------------------------------
    input  wire                     tx_router_idle,

    // --------------------------------------------------------------------------
    // PTP FC TX Interface (to chiplet controller PTP FC node)
    // --------------------------------------------------------------------------
    output wire                     ptp_fc_a2l_valid,
    output wire   [FC_DATA_W-1:0]  ptp_fc_a2l_data,
    input  wire                     ptp_fc_a2l_ready,

    // --------------------------------------------------------------------------
    // PTP FC RX Interface (from chiplet controller PTP FC node)
    // --------------------------------------------------------------------------
    input  wire                     ptp_fc_l2a_valid,
    input  wire   [FC_DATA_W-1:0]  ptp_fc_l2a_data,
    output wire                     ptp_fc_l2a_accept,

    // --------------------------------------------------------------------------
    // PHC Hardware Capture (directly to PHC hw_capture input)
    // --------------------------------------------------------------------------
    output wire                     phc_hw_capture,

    // --------------------------------------------------------------------------
    // AHB Slave — PTP TX Write Port
    // CPU writes here to trigger a PTP FC message.
    // Address bits [3:0] carry msg_type; write data is FC payload.
    // --------------------------------------------------------------------------
    input  wire                     ahb_ptp_hsel,
    input  wire               [3:0] ahb_ptp_haddr,
    input  wire               [1:0] ahb_ptp_htrans,
    input  wire               [2:0] ahb_ptp_hsize,
    input  wire                     ahb_ptp_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_ptp_hwdata,
    input  wire                     ahb_ptp_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_ptp_hrdata,
    output wire                     ahb_ptp_hresp,
    output wire                     ahb_ptp_hreadyout,

    // --------------------------------------------------------------------------
    // Register Interface (directly wired from tidelink_apb_regs)
    // --------------------------------------------------------------------------
    input  wire                     ptp_reg_write,
    input  wire               [2:0] ptp_reg_addr,
    input  wire  [SYS_DATA_W-1:0]  ptp_reg_wdata,
    output logic [SYS_DATA_W-1:0]  ptp_reg_rdata,

    // --------------------------------------------------------------------------
    // Interrupt Output
    // --------------------------------------------------------------------------
    output wire                     ptp_irq
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam [1:0] PKT_PTP       = 2'b10;
    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;

    // =========================================================================
    // PTP Control Register (offset 0x034, mapped at ptp_reg_addr = 3'h5)
    // =========================================================================
    logic        ptp_enable_r;
    logic        ptp_rx_valid_r;
    logic [3:0]  ptp_rx_msg_type_r;

    // RX payload register (offset 0x038, mapped at ptp_reg_addr = 3'h6)
    logic [SYS_DATA_W-1:0] ptp_rx_payload_r;

    // =========================================================================
    // TX Path — AHB Slave → Wait for Idle → FC TX + PHC Capture
    // =========================================================================

    // AHB address phase detection
    wire tx_valid_addr_phase = ahb_ptp_hsel & ahb_ptp_htrans[1]
                             & ahb_ptp_hready & ahb_ptp_hwrite;

    // Registered state from address phase
    logic [3:0]  tx_msg_type_r;
    logic        tx_pending_r;

    // TX FSM states
    typedef enum logic [1:0] {
        TX_IDLE       = 2'b00,
        TX_WAIT_IDLE  = 2'b01,   // Waiting for tx_router_idle
        TX_SEND       = 2'b10    // FC valid asserted, waiting for ready
    } tx_state_t;

    tx_state_t tx_state_r, tx_state_next;

    // Registered payload from AHB data phase
    logic [SYS_DATA_W-1:0] tx_payload_r;
    logic                   tx_data_latched_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_msg_type_r    <= 4'b0;
            tx_pending_r     <= 1'b0;
            tx_payload_r     <= '0;
            tx_data_latched_r <= 1'b0;
            tx_state_r       <= TX_IDLE;
        end else begin
            tx_state_r <= tx_state_next;

            case (tx_state_r)
                TX_IDLE: begin
                    if (tx_valid_addr_phase) begin
                        tx_msg_type_r <= ahb_ptp_haddr[3:0];
                        tx_pending_r  <= 1'b1;
                        tx_data_latched_r <= 1'b0;
                    end
                end
                TX_WAIT_IDLE: begin
                    // Latch write data on first cycle of data phase
                    if (!tx_data_latched_r) begin
                        tx_payload_r      <= ahb_ptp_hwdata;
                        tx_data_latched_r <= 1'b1;
                    end
                end
                TX_SEND: begin
                    if (ptp_fc_a2l_ready) begin
                        tx_pending_r <= 1'b0;
                    end
                end
                default: ;
            endcase

            // Clear on PTP_CTRL clear bit
            if (ptp_reg_write && ptp_reg_addr == 3'h5 && ptp_reg_wdata[1]) begin
                tx_pending_r <= 1'b0;
            end
        end
    end

    // TX state transitions
    always_comb begin
        tx_state_next = tx_state_r;
        case (tx_state_r)
            TX_IDLE: begin
                if (tx_valid_addr_phase)
                    tx_state_next = TX_WAIT_IDLE;
            end
            TX_WAIT_IDLE: begin
                if (tx_router_idle && tx_data_latched_r)
                    tx_state_next = TX_SEND;
            end
            TX_SEND: begin
                if (ptp_fc_a2l_ready)
                    tx_state_next = TX_IDLE;
            end
            default: tx_state_next = TX_IDLE;
        endcase
    end

    // FC TX word assembly
    wire [FC_DATA_W-1:0] tx_fc_word = {PKT_PTP, 10'b0, tx_msg_type_r, tx_payload_r};

    // FC TX handshake
    assign ptp_fc_a2l_valid = (tx_state_r == TX_SEND) & ptp_enable_r;
    assign ptp_fc_a2l_data  = tx_fc_word;

    // FC TX handshake fires this cycle
    wire tx_handshake = ptp_fc_a2l_valid & ptp_fc_a2l_ready;

    // AHB slave: stall during TX_WAIT_IDLE and TX_SEND; release on handshake
    assign ahb_ptp_hreadyout = (tx_state_r == TX_IDLE) ? 1'b1 :
                               (tx_state_r == TX_SEND && ptp_fc_a2l_ready) ? 1'b1 : 1'b0;
    assign ahb_ptp_hresp  = 1'b0;
    assign ahb_ptp_hrdata = '0;   // Write-only port

    // =========================================================================
    // RX Path — FC RX → PHC Capture + Payload Latch + IRQ
    // =========================================================================

    // Accept FC RX whenever valid and we're not holding an unread word
    wire rx_accept = ptp_fc_l2a_valid & ptp_enable_r;

    assign ptp_fc_l2a_accept = rx_accept;

    // Decode received FC word fields
    wire [3:0]             rx_msg_type = ptp_fc_l2a_data[35:32];
    wire [SYS_DATA_W-1:0] rx_payload  = ptp_fc_l2a_data[31:0];

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ptp_rx_valid_r    <= 1'b0;
            ptp_rx_msg_type_r <= 4'b0;
            ptp_rx_payload_r  <= '0;
        end else begin
            if (rx_accept) begin
                ptp_rx_valid_r    <= 1'b1;
                ptp_rx_msg_type_r <= rx_msg_type;
                ptp_rx_payload_r  <= rx_payload;
            end

            // Clear on PTP_CTRL clear bit
            if (ptp_reg_write && ptp_reg_addr == 3'h5 && ptp_reg_wdata[1]) begin
                ptp_rx_valid_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // PHC Hardware Capture — pulse on TX handshake or RX accept
    // =========================================================================
    assign phc_hw_capture = tx_handshake | rx_accept;

    // =========================================================================
    // Interrupt — fires when rx_valid is set
    // =========================================================================
    assign ptp_irq = ptp_rx_valid_r & ptp_enable_r;

    // =========================================================================
    // PTP Control Register
    // =========================================================================
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ptp_enable_r <= 1'b0;
        end else if (ptp_reg_write && ptp_reg_addr == 3'h5) begin
            ptp_enable_r <= ptp_reg_wdata[0];
        end
    end

    // =========================================================================
    // Register Read Mux
    //   3'h5 (0x034): PTP_CTRL
    //   3'h6 (0x038): PTP_RX_PAYLOAD
    //   3'h7 (0x03C): PTP_STATUS
    // =========================================================================
    always_comb begin
        ptp_reg_rdata = '0;
        case (ptp_reg_addr)
            3'h5:    ptp_reg_rdata = {{(SYS_DATA_W-7){1'b0}}, ptp_rx_msg_type_r,
                                      ptp_rx_valid_r, 1'b0, ptp_enable_r};
            3'h6:    ptp_reg_rdata = ptp_rx_payload_r;
            3'h7:    ptp_reg_rdata = {{(SYS_DATA_W-2){1'b0}}, tx_pending_r, tx_router_idle};
            default: ;
        endcase
    end

endmodule
