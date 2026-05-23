//-----------------------------------------------------------------------------
// SoCLabs TideLink PTP — Single-Phase PTP Module (Short Packet)
//
// Implements a single-phase (2-message) Precision Time Protocol over
// dedicated Wlink short packets. Provides:
//
//   TX path: AHB slave → wait for tx_router_idle → Short Packet TX + PHC hw_capture
//   RX path: Short Packet RX → PHC hw_capture + payload latch + interrupt
//
// Timestamps are captured by pulsing phc_hw_capture at the exact short packet
// handshake cycle. The actual timestamp values live in the external PHC's
// HW_CAP_* registers — this module does not contain a counter.
//
// Short packet data_id encoding:
//   0x50 = PTP SYNC       (Grandmaster → Subordinate)
//   0x51 = PTP DELAY_REQ  (Subordinate → Grandmaster)
//
// Short packet wire format (32 bits on die-to-die link):
//   [31:24] ECC        — mandatory Hamming SEC/DED
//   [23:8]  payload    — 16 usable bits (sequence number or metadata)
//   [7:0]   data_id    — 0x50 or 0x51
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
    parameter PHC_LOCK_GATE_EN = 0   // 0 = no gating (backward compat), 1 = gate HW sync on phc_locked_i
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
    // PTP Short Packet TX Interface (to chiplet controller)
    // --------------------------------------------------------------------------
    output wire                     ptp_sp_tx_valid,
    output wire              [7:0]  ptp_sp_tx_data_id,
    output wire             [15:0]  ptp_sp_tx_payload,
    input  wire                     ptp_sp_tx_ready,

    // --------------------------------------------------------------------------
    // PTP Short Packet RX Interface (from chiplet controller)
    // --------------------------------------------------------------------------
    input  wire                     ptp_sp_rx_valid,
    input  wire              [7:0]  ptp_sp_rx_data_id,
    input  wire             [15:0]  ptp_sp_rx_payload,
    output wire                     ptp_sp_rx_accept,

    // --------------------------------------------------------------------------
    // PHC Hardware Capture (directly to PHC hw_capture input)
    // --------------------------------------------------------------------------
    output wire                     phc_hw_capture,

    // --------------------------------------------------------------------------
    // PHC Time Inputs (for hardware sync initiator timing)
    // --------------------------------------------------------------------------
    input  wire              [29:0] phc_nanoseconds,
    input  wire              [47:0] phc_seconds,
    input  wire                     phc_pps,

    // --------------------------------------------------------------------------
    // AHB Slave — PTP TX Write Port
    // CPU writes here to trigger a PTP short packet message.
    // Address bits [3:0] carry msg_type; write data[15:0] is SP payload.
    // --------------------------------------------------------------------------
    input  wire                     ahb_ptp_hsel,
    input  wire               [3:0] ahb_ptp_haddr,
    input  wire               [1:0] ahb_ptp_htrans,
    input  wire               [2:0] ahb_ptp_hsize,
    input  wire                     ahb_ptp_hwrite,
    input  wire   [SYS_DATA_W-1:0]  ahb_ptp_hwdata,
    input  wire                     ahb_ptp_hready,
    output wire   [SYS_DATA_W-1:0]  ahb_ptp_hrdata,
    output wire                     ahb_ptp_hresp,
    output wire                     ahb_ptp_hreadyout,

    // --------------------------------------------------------------------------
    // Register Interface (directly wired from tidelink_apb_regs)
    // --------------------------------------------------------------------------
    input  wire                     ptp_reg_write,
    input  wire               [2:0] ptp_reg_addr,
    input  wire   [SYS_DATA_W-1:0]  ptp_reg_wdata,
    output logic  [SYS_DATA_W-1:0]  ptp_reg_rdata,
    input  wire                     ptp_reg_region,  // 0=Region 1 (basic PTP), 1=Region 2 (HW sync)

    // --------------------------------------------------------------------------
    // Servo Event Outputs (pulse on PTP handshake events)
    // --------------------------------------------------------------------------
    output wire                     sync_tx_done,   // SYNC TX handshake completed
    output wire                     dreq_tx_done,   // DELAY_REQ TX handshake completed
    output wire                     sync_rx_done,   // SYNC RX accepted
    output wire                     dreq_rx_done,   // DELAY_REQ RX accepted

    // --------------------------------------------------------------------------
    // Servo DELAY_REQ Injection (autonomous servo triggers DELAY_REQ TX)
    // --------------------------------------------------------------------------
    input  wire                     servo_dreq_trigger,

    // --------------------------------------------------------------------------
    // External PHC Lock Gate (for multi-hop PTP chaining)
    // When PHC_LOCK_GATE_EN=1, HW sync initiator is gated by this signal.
    // Tie to 1'b1 if unused.
    // --------------------------------------------------------------------------
    input  wire                     phc_locked_i,

    // --------------------------------------------------------------------------
    // Interrupt Output
    // --------------------------------------------------------------------------
    output wire                     ptp_irq
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam [7:0] DATA_ID_SYNC      = 8'h50;
    localparam [7:0] DATA_ID_DELAY_REQ = 8'h51;
    localparam [1:0] HTRANS_IDLE       = 2'b00;
    localparam [1:0] HTRANS_NONSEQ     = 2'b10;

    // =========================================================================
    // PTP Control Register (offset 0x034, mapped at ptp_reg_addr = 3'h5)
    // =========================================================================
    logic        ptp_enable_r;
    logic        ptp_rx_valid_r;
    logic [3:0]  ptp_rx_msg_type_r;

    // RX payload register (offset 0x038, mapped at ptp_reg_addr = 3'h6)
    logic [SYS_DATA_W-1:0] ptp_rx_payload_r;

    // =========================================================================
    // HW Sync Initiator — Forward Declarations
    // =========================================================================
    // hw_sync_trigger is asserted by the HW sync FSM when it wants to inject
    // a SYNC message into the TX path (defined in full below).
    wire hw_sync_trigger;
    wire [15:0] hw_seq_num_r;

    // =========================================================================
    // TX Path — AHB Slave / HW Sync → Wait for Idle → Short Packet TX + PHC Capture
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

    // Registered payload from AHB data phase (16 bits for short packet)
    logic [15:0] tx_payload_r;
    logic        tx_data_latched_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tx_msg_type_r    <= 4'b0;
            tx_pending_r     <= 1'b0;
            tx_payload_r     <= 16'h0;
            tx_data_latched_r <= 1'b0;
            tx_state_r       <= TX_IDLE;
        end else begin
            tx_state_r <= tx_state_next;

            case (tx_state_r)
                TX_IDLE: begin
                    if (tx_valid_addr_phase) begin
                        // Software AHB path (highest priority)
                        tx_msg_type_r     <= ahb_ptp_haddr[3:0];
                        tx_pending_r      <= 1'b1;
                        tx_data_latched_r <= 1'b0;
                    end else if (hw_sync_trigger) begin
                        // Hardware sync initiator path
                        tx_msg_type_r     <= 4'h0;  // SYNC
                        tx_payload_r      <= hw_seq_num_r;
                        tx_pending_r      <= 1'b1;
                        tx_data_latched_r <= 1'b1;  // payload already loaded
                    end else if (servo_dreq_trigger & ptp_enable_r) begin
                        // Autonomous servo DELAY_REQ injection (lowest priority)
                        tx_msg_type_r     <= 4'h1;  // DELAY_REQ
                        tx_payload_r      <= 16'h0;
                        tx_pending_r      <= 1'b1;
                        tx_data_latched_r <= 1'b1;
                    end
                end
                TX_WAIT_IDLE: begin
                    // Latch write data on first cycle of data phase (lower 16 bits for SP)
                    if (!tx_data_latched_r) begin
                        tx_payload_r      <= ahb_ptp_hwdata[15:0];
                        tx_data_latched_r <= 1'b1;
                    end
                end
                TX_SEND: begin
                    if (ptp_sp_tx_ready) begin
                        tx_pending_r <= 1'b0;
                    end
                end
                default: ;
            endcase

            // Clear on PTP_CTRL clear bit
            if (ptp_reg_write && !ptp_reg_region && ptp_reg_addr == 3'h5 && ptp_reg_wdata[1]) begin
                tx_pending_r <= 1'b0;
            end
        end
    end

    // TX state transitions
    always_comb begin
        tx_state_next = tx_state_r;
        case (tx_state_r)
            TX_IDLE: begin
                if (tx_valid_addr_phase || hw_sync_trigger ||
                    (servo_dreq_trigger & ptp_enable_r))
                    tx_state_next = TX_WAIT_IDLE;
            end
            TX_WAIT_IDLE: begin
                // tx_router_idle is sourced from the Wlink LL TX `link_idle`
                // signal in the tx_link_clk domain. In FPGA bring-up the link
                // carries periodic LP-state (preq/pstate) frames that hold
                // link_idle low for long bursts, so the original hard gate
                // can deadlock the PTP TX path. The force_en bit (HW_SYNC_CTRL
                // bit[2]) lets software bypass the gate when sub-cycle TX
                // timestamp jitter is acceptable (typical bring-up). Cocotb
                // gate-tests (PTP-03/14/15) leave force_en=0 so they still
                // exercise the original behaviour.
                if ((tx_router_idle || hw_sync_force_en_r) && tx_data_latched_r)
                    tx_state_next = TX_SEND;
            end
            TX_SEND: begin
                if (ptp_sp_tx_ready)
                    tx_state_next = TX_IDLE;
            end
            default: tx_state_next = TX_IDLE;
        endcase
    end

    // Short packet TX: encode msg_type into data_id
    assign ptp_sp_tx_data_id = (tx_msg_type_r == 4'h0) ? DATA_ID_SYNC : DATA_ID_DELAY_REQ;
    assign ptp_sp_tx_payload = tx_payload_r;

    // Short packet TX handshake
    assign ptp_sp_tx_valid = (tx_state_r == TX_SEND) & ptp_enable_r;

    // TX handshake fires this cycle
    wire tx_handshake = ptp_sp_tx_valid & ptp_sp_tx_ready;

    // AHB slave: stall during TX_WAIT_IDLE and TX_SEND; release on handshake
    assign ahb_ptp_hreadyout = (tx_state_r == TX_IDLE) ? 1'b1 :
                               (tx_state_r == TX_SEND && ptp_sp_tx_ready) ? 1'b1 : 1'b0;
    assign ahb_ptp_hresp  = 1'b0;
    assign ahb_ptp_hrdata = '0;   // Write-only port

    // =========================================================================
    // RX Path — Short Packet RX → PHC Capture + Payload Latch + IRQ
    // =========================================================================

    // Accept SP RX whenever valid and PTP is enabled
    wire rx_accept = ptp_sp_rx_valid & ptp_enable_r;

    assign ptp_sp_rx_accept = rx_accept;

    // Decode received short packet: data_id → msg_type
    wire [3:0]  rx_msg_type = (ptp_sp_rx_data_id == DATA_ID_SYNC) ? 4'h0 : 4'h1;
    wire [15:0] rx_payload  = ptp_sp_rx_payload;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ptp_rx_valid_r    <= 1'b0;
            ptp_rx_msg_type_r <= 4'b0;
            ptp_rx_payload_r  <= '0;
        end else begin
            if (rx_accept) begin
                ptp_rx_valid_r    <= 1'b1;
                ptp_rx_msg_type_r <= rx_msg_type;
                ptp_rx_payload_r  <= {{(SYS_DATA_W-16){1'b0}}, rx_payload};
            end

            // Clear on PTP_CTRL clear bit
            if (ptp_reg_write && !ptp_reg_region && ptp_reg_addr == 3'h5 && ptp_reg_wdata[1]) begin
                ptp_rx_valid_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // PHC Hardware Capture — pulse on TX handshake or RX accept
    // =========================================================================
    assign phc_hw_capture = tx_handshake | rx_accept;

    // =========================================================================
    // Servo Event Outputs — decode handshake events by message type
    // =========================================================================
    assign sync_tx_done = tx_handshake & (ptp_sp_tx_data_id == DATA_ID_SYNC);
    assign dreq_tx_done = tx_handshake & (ptp_sp_tx_data_id == DATA_ID_DELAY_REQ);
    assign sync_rx_done = rx_accept    & (ptp_sp_rx_data_id == DATA_ID_SYNC);
    assign dreq_rx_done = rx_accept    & (ptp_sp_rx_data_id == DATA_ID_DELAY_REQ);

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
        end else if (ptp_reg_write && !ptp_reg_region && ptp_reg_addr == 3'h5) begin
            ptp_enable_r <= ptp_reg_wdata[0];
        end
    end

    // =========================================================================
    // HW Sync Initiator — Registers and FSM
    // =========================================================================
    //
    // Region 2 registers (ptp_reg_region=1):
    //   3'h0 (0x040): HW_SYNC_CTRL     — [0] enable, [1] seq_clear (W1C), [2] force_en
    //   3'h1 (0x044): HW_SYNC_INTERVAL — sync interval in nanoseconds [29:0]
    //   3'h2 (0x048): HW_SYNC_STATUS   — [0] active, [1] busy, [17:2] seq_num, [18] phc_locked
    // =========================================================================

    localparam [29:0] NS_PER_SECOND = 30'd999_999_999;
    localparam [29:0] DEFAULT_INTERVAL = 30'd999_999_999; // ~1 second (1e9 - 1)

    // HW sync registers
    logic        hw_sync_en_r;
    logic        hw_sync_en_prev_r;    // for rising-edge detection
    logic        hw_sync_force_en_r;   // force-enable, bypasses phc_locked_i gate
    logic [29:0] hw_sync_interval_r;
    logic [15:0] hw_seq_num_int_r;

    assign hw_seq_num_r = hw_seq_num_int_r;

    // PHC lock gate — controls HW_SYNC_IDLE → HW_SYNC_ARMED transition
    // When PHC_LOCK_GATE_EN=0, gate is always 1 (backward compatible).
    // When PHC_LOCK_GATE_EN=1, gate requires phc_locked_i OR hw_sync_force_en_r.
    wire hw_sync_gate = (PHC_LOCK_GATE_EN == 0) ? 1'b1
                      : (hw_sync_force_en_r | phc_locked_i);

    // Rising-edge detection on gate (for enable-before-lock ordering)
    logic hw_sync_gate_prev_r;

    // Target timestamp for next SYNC fire
    logic [47:0] target_seconds_r;
    logic [29:0] target_ns_r;

    // HW sync FSM states
    typedef enum logic [1:0] {
        HW_SYNC_IDLE    = 2'b00,
        HW_SYNC_ARMED   = 2'b01,
        HW_SYNC_FIRE    = 2'b10,
        HW_SYNC_WAIT_TX = 2'b11
    } hw_sync_state_t;

    hw_sync_state_t hw_sync_state_r, hw_sync_state_next;

    // Rising edge of hw_sync_en
    wire hw_sync_en_rising = hw_sync_en_r & ~hw_sync_en_prev_r;

    // Rising edge of gate (phc_locked_i or force_en asserted while enable held high)
    wire hw_sync_gate_rising = hw_sync_gate & ~hw_sync_gate_prev_r;

    // PHC time comparison: current time >= target time
    wire phc_time_reached = (phc_seconds > target_seconds_r) ||
                            (phc_seconds == target_seconds_r &&
                             phc_nanoseconds >= target_ns_r);

    // Advance target by interval (with nanosecond rollover)
    logic [30:0] next_ns_sum;
    logic [29:0] next_target_ns;
    logic [47:0] next_target_seconds;

    always_comb begin
        next_ns_sum = {1'b0, target_ns_r} + {1'b0, hw_sync_interval_r};
        if (next_ns_sum > {1'b0, NS_PER_SECOND}) begin
            next_target_ns      = next_ns_sum[29:0] - NS_PER_SECOND - 30'd1;
            next_target_seconds = target_seconds_r + 48'd1;
        end else begin
            next_target_ns      = next_ns_sum[29:0];
            next_target_seconds = target_seconds_r;
        end
    end

    // HW sync trigger: asserted for one cycle in FIRE state when TX FSM is idle
    assign hw_sync_trigger = (hw_sync_state_r == HW_SYNC_FIRE) &&
                             (tx_state_r == TX_IDLE) &&
                             !tx_valid_addr_phase;  // AHB has priority

    // HW sync FSM — state transitions
    always_comb begin
        hw_sync_state_next = hw_sync_state_r;
        case (hw_sync_state_r)
            HW_SYNC_IDLE: begin
                if ((hw_sync_en_rising && hw_sync_gate) ||
                    (hw_sync_en_r && hw_sync_gate_rising))
                    hw_sync_state_next = HW_SYNC_ARMED;
            end
            HW_SYNC_ARMED: begin
                if (!hw_sync_en_r)
                    hw_sync_state_next = HW_SYNC_IDLE;
                else if (phc_time_reached)
                    hw_sync_state_next = HW_SYNC_FIRE;
            end
            HW_SYNC_FIRE: begin
                if (!hw_sync_en_r)
                    hw_sync_state_next = HW_SYNC_IDLE;
                else if (hw_sync_trigger)
                    hw_sync_state_next = HW_SYNC_WAIT_TX;
            end
            HW_SYNC_WAIT_TX: begin
                if (!hw_sync_en_r)
                    hw_sync_state_next = HW_SYNC_IDLE;
                else if (tx_state_r == TX_IDLE)
                    hw_sync_state_next = HW_SYNC_ARMED;
            end
            default: hw_sync_state_next = HW_SYNC_IDLE;
        endcase
    end

    // HW sync FSM — registered state
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            hw_sync_state_r    <= HW_SYNC_IDLE;
            hw_sync_en_r       <= 1'b0;
            hw_sync_en_prev_r  <= 1'b0;
            hw_sync_force_en_r <= 1'b0;
            hw_sync_gate_prev_r <= 1'b0;
            hw_sync_interval_r <= DEFAULT_INTERVAL;
            hw_seq_num_int_r   <= 16'b0;
            target_seconds_r   <= 48'b0;
            target_ns_r        <= 30'b0;
        end else begin
            hw_sync_state_r     <= hw_sync_state_next;
            hw_sync_en_prev_r   <= hw_sync_en_r;
            hw_sync_gate_prev_r <= hw_sync_gate;

            // Register writes (Region 2)
            if (ptp_reg_write && ptp_reg_region) begin
                case (ptp_reg_addr)
                    3'h0: begin // HW_SYNC_CTRL
                        hw_sync_en_r       <= ptp_reg_wdata[0];
                        hw_sync_force_en_r <= ptp_reg_wdata[2];
                        if (ptp_reg_wdata[1])  // seq_clear (W1C)
                            hw_seq_num_int_r <= 16'b0;
                    end
                    3'h1: begin // HW_SYNC_INTERVAL
                        hw_sync_interval_r <= ptp_reg_wdata[29:0];
                    end
                    default: ;
                endcase
            end

            // FSM actions
            case (hw_sync_state_r)
                HW_SYNC_IDLE: begin
                    if ((hw_sync_en_rising && hw_sync_gate) ||
                        (hw_sync_en_r && hw_sync_gate_rising)) begin
                        // Latch initial target = current PHC time + interval
                        if (({1'b0, phc_nanoseconds} + {1'b0, hw_sync_interval_r}) > {1'b0, NS_PER_SECOND}) begin
                            target_ns_r      <= phc_nanoseconds + hw_sync_interval_r - NS_PER_SECOND - 30'd1;
                            target_seconds_r <= phc_seconds + 48'd1;
                        end else begin
                            target_ns_r      <= phc_nanoseconds + hw_sync_interval_r;
                            target_seconds_r <= phc_seconds;
                        end
                    end
                end
                HW_SYNC_WAIT_TX: begin
                    if (hw_sync_en_r && tx_state_r == TX_IDLE) begin
                        // Advance target and increment sequence number
                        target_ns_r      <= next_target_ns;
                        target_seconds_r <= next_target_seconds;
                        hw_seq_num_int_r <= hw_seq_num_int_r + 16'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Register Read Mux
    //   Region 1 (ptp_reg_region=0):
    //     3'h5 (0x034): PTP_CTRL
    //     3'h6 (0x038): PTP_RX_PAYLOAD
    //     3'h7 (0x03C): PTP_STATUS
    //   Region 2 (ptp_reg_region=1):
    //     3'h0 (0x040): HW_SYNC_CTRL     — [0] enable, [1] seq_clear (W1C), [2] force_en
    //     3'h1 (0x044): HW_SYNC_INTERVAL
    //     3'h2 (0x048): HW_SYNC_STATUS   — [0] active, [1] busy, [17:2] seq_num, [18] phc_locked
    // =========================================================================
    always_comb begin
        ptp_reg_rdata = '0;
        if (ptp_reg_region) begin
            // Region 2: HW Sync Initiator registers
            case (ptp_reg_addr)
                3'h0:    ptp_reg_rdata = {{(SYS_DATA_W-3){1'b0}}, hw_sync_force_en_r,
                                          1'b0, hw_sync_en_r};  // [2] force_en, [1] seq_clear (W1C, reads 0), [0] enable
                3'h1:    ptp_reg_rdata = {{(SYS_DATA_W-30){1'b0}}, hw_sync_interval_r};
                3'h2:    ptp_reg_rdata = {{(SYS_DATA_W-19){1'b0}}, phc_locked_i,     // [18] phc_locked
                                          hw_seq_num_int_r,
                                          (hw_sync_state_r != HW_SYNC_IDLE) &&
                                          (hw_sync_state_r != HW_SYNC_ARMED), // [1] busy
                                          hw_sync_en_r};                       // [0] active
                default: ;
            endcase
        end else begin
            // Region 1: Basic PTP registers
            case (ptp_reg_addr)
                3'h5:    ptp_reg_rdata = {{(SYS_DATA_W-7){1'b0}}, ptp_rx_msg_type_r,
                                          ptp_rx_valid_r, 1'b0, ptp_enable_r};
                3'h6:    ptp_reg_rdata = ptp_rx_payload_r;
                3'h7:    ptp_reg_rdata = {{(SYS_DATA_W-2){1'b0}}, tx_pending_r, tx_router_idle};
                default: ;
            endcase
        end
    end

endmodule
