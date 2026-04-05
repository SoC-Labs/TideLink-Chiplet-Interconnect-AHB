//-----------------------------------------------------------------------------
// SoCLabs TideLink PTP Servo — Autonomous Hardware Clock Synchronisation
//
// Implements fully autonomous PTP clock synchronisation without CPU
// intervention. Operates in one of two modes:
//
//   Grandmaster: Captures t1/t4 timestamps after SYNC/DELAY_REQ exchange,
//                sends timestamps to Subordinate via FC SIDEBAND packets.
//
//   Subordinate: Captures t2/t3 timestamps, receives t1/t4 from Grandmaster
//                via FC SIDEBAND mailbox, computes offset/delay, adjusts PHC.
//
// Timestamp exchange uses FC SIDEBAND packets (4 per timestamp, 32 bits each)
// written to the remote side's mailbox registers via the existing FC RX
// config path. No short packet data_id allocation is needed.
//
// Clock discipline:
//   - Large offset (|offset| > threshold or seconds mismatch): SET_TIME phase step
//   - Small offset: PI controller adjusts NS_INCR_FRAC for frequency steering
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

module tidelink_ptp_servo #(
    parameter SYS_DATA_W = 32,
    parameter FC_DATA_W  = 48,
    // Default PI gains in Q0.32 fixed-point
    parameter [SYS_DATA_W-1:0] DEFAULT_KP         = 32'h0000_B333,  // ~0.7
    parameter [SYS_DATA_W-1:0] DEFAULT_KI         = 32'h0000_4CCC,  // ~0.3
    parameter [SYS_DATA_W-1:0] DEFAULT_STEP_THRESH = 32'd1000,       // 1000 ns
    // Anti-windup: clamp integral accumulator to ±INTEGRAL_MAX
    parameter signed [63:0]    INTEGRAL_MAX        = 64'sh0000_00FF_FFFF_FFFF  // ~±1099 sec
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  logic                    clk,
    input  logic                    resetn,

    // --------------------------------------------------------------------------
    // Register Interface (Region 3 from APB pass-through)
    // --------------------------------------------------------------------------
    input  logic                    servo_reg_write,
    input  logic              [2:0] servo_reg_addr,
    input  logic   [SYS_DATA_W-1:0] servo_reg_wdata,
    output logic   [SYS_DATA_W-1:0] servo_reg_rdata,

    // --------------------------------------------------------------------------
    // PTP Event Inputs (from tidelink_ptp)
    // --------------------------------------------------------------------------
    input  logic                    sync_tx_done,
    input  logic                    dreq_tx_done,
    input  logic                    sync_rx_done,
    input  logic                    dreq_rx_done,

    // --------------------------------------------------------------------------
    // PHC Hardware Capture (direct wire from PHC clock core)
    // --------------------------------------------------------------------------
    input  logic             [47:0] hw_cap_seconds,
    input  logic             [29:0] hw_cap_nanoseconds,
    input  logic  [SYS_DATA_W-1:0] hw_cap_sub_nanoseconds,

    // --------------------------------------------------------------------------
    // FC SIDEBAND Injection (to FC adapter TX arbiter)
    // --------------------------------------------------------------------------
    output logic                    servo_fc_valid,
    output logic   [FC_DATA_W-1:0]  servo_fc_data,
    input  logic                    servo_fc_ready,

    // --------------------------------------------------------------------------
    // Timestamp Mailbox Write (from FC RX config path via APB)
    // --------------------------------------------------------------------------
    input  logic                    mbox_reg_write,
    input  logic              [2:0] mbox_reg_addr,   // 3-bit offset within mailbox
    input  logic  [SYS_DATA_W-1:0]  mbox_reg_wdata,

    // --------------------------------------------------------------------------
    // DELAY_REQ Trigger (to tidelink_ptp TX path)
    // --------------------------------------------------------------------------
    output logic                    servo_dreq_trigger,

    // --------------------------------------------------------------------------
    // PHC Adjustment Outputs (direct wire to PHC clock core)
    // --------------------------------------------------------------------------
    output logic                    phc_hw_set_time,
    output logic             [47:0] phc_hw_set_seconds,
    output logic             [29:0] phc_hw_set_nanoseconds,
    output logic                    phc_hw_adj_valid,
    output logic  [SYS_DATA_W-1:0]  phc_hw_adj_ns_incr_frac,

    // --------------------------------------------------------------------------
    // Status
    // --------------------------------------------------------------------------
    output logic                    servo_locked
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam [1:0]  PKT_SIDEBAND = 2'b01;
    localparam [29:0] NS_PER_SECOND = 30'd999_999_999;
    // One second in nanoseconds
    localparam signed [30:0] ONE_SEC_NS = 31'sd1_000_000_000;

    // Mailbox target offsets (where SIDEBAND packets write on the remote side)
    // These are APB register offsets within TideLink config space
    localparam [13:0] MBOX_SEC_LO_OFFSET  = 14'h068;
    localparam [13:0] MBOX_SEC_HI_OFFSET  = 14'h06C;
    localparam [13:0] MBOX_NS_OFFSET      = 14'h070;
    localparam [13:0] MBOX_SUB_NS_OFFSET  = 14'h074;

    // =========================================================================
    // Configuration Registers
    // Region 2 (addr 3-7, servo_reg_addr 0-4):
    //   0 (0x04C): SERVO_CTRL       — [0] enable, [1] mode (0=GM, 1=Sub)
    //   1 (0x050): SERVO_KP         — Proportional gain Q0.32
    //   2 (0x054): SERVO_KI         — Integral gain Q0.32
    //   3 (0x058): SERVO_STEP_THRESH — Step threshold (ns)
    //   4 (0x05C): SERVO_STATUS     — [0] locked, [1] active, [31:2] offset
    // Region 3 (addr 0-1, servo_reg_addr 5-6):
    //   5 (0x060): SERVO_DELAY      — Last one-way delay (ns)
    //   6 (0x064): SERVO_NS_FRAC    — Current NS_INCR_FRAC driven
    // =========================================================================

    logic        servo_enable_r;
    logic        servo_mode_r;           // 0=Grandmaster, 1=Subordinate
    logic [SYS_DATA_W-1:0] servo_kp_r;
    logic [SYS_DATA_W-1:0] servo_ki_r;
    logic [SYS_DATA_W-1:0] servo_step_thresh_r;

    // Status registers (read-only, updated by computation)
    logic signed [31:0] last_offset_r;   // Signed nanoseconds
    logic        [31:0] last_delay_r;    // Unsigned nanoseconds
    logic [SYS_DATA_W-1:0] current_frac_r;

    // Forward declarations (FSMs defined below)
    wire gm_active;
    wire sub_active;

    // Register writes
    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            servo_enable_r     <= 1'b0;
            servo_mode_r       <= 1'b0;
            servo_kp_r         <= DEFAULT_KP;
            servo_ki_r         <= DEFAULT_KI;
            servo_step_thresh_r <= DEFAULT_STEP_THRESH;
        end else if (servo_reg_write) begin
            case (servo_reg_addr)
                3'h0: begin
                    servo_enable_r <= servo_reg_wdata[0];
                    servo_mode_r   <= servo_reg_wdata[1];
                end
                3'h1: servo_kp_r          <= servo_reg_wdata;
                3'h2: servo_ki_r          <= servo_reg_wdata;
                3'h3: servo_step_thresh_r <= servo_reg_wdata;
                default: ;
            endcase
        end
    end

    // Register reads (addr 0-4 = config from Region 2, addr 5-6 = status from Region 3)
    always_comb begin
        servo_reg_rdata = '0;
        case (servo_reg_addr)
            3'h0: servo_reg_rdata = {{(SYS_DATA_W-2){1'b0}}, servo_mode_r, servo_enable_r};
            3'h1: servo_reg_rdata = servo_kp_r;
            3'h2: servo_reg_rdata = servo_ki_r;
            3'h3: servo_reg_rdata = servo_step_thresh_r;
            3'h4: servo_reg_rdata = {{(SYS_DATA_W-2){1'b0}}, gm_active | sub_active, servo_locked};
            3'h5: servo_reg_rdata = last_offset_r;       // Region 3 offset 0x060
            3'h6: servo_reg_rdata = last_delay_r;        // Region 3 offset 0x064
            3'h7: servo_reg_rdata = current_frac_r;      // Region 3 offset 0x068
            default: ;
        endcase
    end

    // =========================================================================
    // Timestamp Storage (110 bits each: 48-bit sec + 30-bit ns + 32-bit sub_ns)
    // =========================================================================

    // GM timestamps (captured from PHC hw_cap wires)
    logic [47:0] gm_t1_sec, gm_t4_sec;
    logic [29:0] gm_t1_ns,  gm_t4_ns;
    logic [SYS_DATA_W-1:0] gm_t1_sub, gm_t4_sub;

    // Sub local timestamps (captured from PHC hw_cap wires)
    logic [47:0] sub_t2_sec, sub_t3_sec;
    logic [29:0] sub_t2_ns,  sub_t3_ns;
    logic [SYS_DATA_W-1:0] sub_t2_sub, sub_t3_sub;

    // Sub remote timestamps (received via FC SIDEBAND mailbox)
    logic [47:0] sub_t1_sec, sub_t4_sec;
    logic [29:0] sub_t1_ns,  sub_t4_ns;
    logic [SYS_DATA_W-1:0] sub_t1_sub, sub_t4_sub;

    // =========================================================================
    // Timestamp Mailbox — Receives FC SIDEBAND writes from remote side
    // =========================================================================
    // The FC RX config path writes SIDEBAND payload to APB registers.
    // When the address falls in the mailbox range, it's routed here.
    // Writing SUB_NS (last word) triggers a "timestamp complete" pulse.

    logic [31:0] mbox_sec_lo_r;
    logic [15:0] mbox_sec_hi_r;
    logic [29:0] mbox_ns_r;
    logic        mbox_ts_complete;  // Pulse: full timestamp received

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mbox_sec_lo_r   <= '0;
            mbox_sec_hi_r   <= '0;
            mbox_ns_r       <= '0;
            mbox_ts_complete <= 1'b0;
        end else begin
            mbox_ts_complete <= 1'b0;
            if (mbox_reg_write) begin
                // Region 3 paddr[4:2]: 2=SEC_LO, 3=SEC_HI, 4=NS (last word triggers complete)
                case (mbox_reg_addr)
                    3'h2: mbox_sec_lo_r <= mbox_reg_wdata;
                    3'h3: mbox_sec_hi_r <= mbox_reg_wdata[15:0];
                    3'h4: begin
                        mbox_ns_r        <= mbox_reg_wdata[29:0];
                        mbox_ts_complete <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // Assembled mailbox timestamp + sub-ns (not sent over link, tied to zero)
    wire [47:0] mbox_seconds    = {mbox_sec_hi_r, mbox_sec_lo_r};
    wire [29:0] mbox_nanoseconds = mbox_ns_r;
    wire [SYS_DATA_W-1:0] mbox_sub_ns = '0;

    // =========================================================================
    // Grandmaster FSM
    // =========================================================================

    typedef enum logic [3:0] {
        GM_IDLE         = 4'd0,
        GM_CAPTURE_T1   = 4'd1,
        GM_WAIT_DREQ_RX = 4'd2,
        GM_CAPTURE_T4   = 4'd3,
        GM_SEND_T1_0    = 4'd4,
        GM_SEND_T1_1    = 4'd5,
        GM_SEND_T1_2    = 4'd6,
        GM_SEND_T1_3    = 4'd7,
        GM_SEND_T4_0    = 4'd8,
        GM_SEND_T4_1    = 4'd9,
        GM_SEND_T4_2    = 4'd10,
        GM_SEND_T4_3    = 4'd11
    } gm_state_t;

    gm_state_t gm_state_r;
    assign gm_active = (gm_state_r != GM_IDLE);

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            gm_state_r <= GM_IDLE;
        end else if (!servo_enable_r || servo_mode_r) begin
            // Disabled or in Subordinate mode
            gm_state_r <= GM_IDLE;
        end else begin
            case (gm_state_r)
                GM_IDLE: begin
                    if (sync_tx_done)
                        gm_state_r <= GM_CAPTURE_T1;
                end

                GM_CAPTURE_T1: begin
                    gm_t1_sec  <= hw_cap_seconds;
                    gm_t1_ns   <= hw_cap_nanoseconds;
                    gm_t1_sub  <= hw_cap_sub_nanoseconds;
                    gm_state_r <= GM_WAIT_DREQ_RX;
                end

                GM_WAIT_DREQ_RX: begin
                    if (dreq_rx_done)
                        gm_state_r <= GM_CAPTURE_T4;
                end

                GM_CAPTURE_T4: begin
                    gm_t4_sec  <= hw_cap_seconds;
                    gm_t4_ns   <= hw_cap_nanoseconds;
                    gm_t4_sub  <= hw_cap_sub_nanoseconds;
                    gm_state_r <= GM_SEND_T1_0;
                end

                // Send t1 as 4 FC SIDEBAND packets
                GM_SEND_T1_0: if (servo_fc_ready) gm_state_r <= GM_SEND_T1_1;
                GM_SEND_T1_1: if (servo_fc_ready) gm_state_r <= GM_SEND_T1_2;
                GM_SEND_T1_2: if (servo_fc_ready) gm_state_r <= GM_SEND_T1_3;
                GM_SEND_T1_3: if (servo_fc_ready) gm_state_r <= GM_SEND_T4_0;

                // Send t4 as 4 FC SIDEBAND packets
                GM_SEND_T4_0: if (servo_fc_ready) gm_state_r <= GM_SEND_T4_1;
                GM_SEND_T4_1: if (servo_fc_ready) gm_state_r <= GM_SEND_T4_2;
                GM_SEND_T4_2: if (servo_fc_ready) gm_state_r <= GM_SEND_T4_3;
                GM_SEND_T4_3: if (servo_fc_ready) gm_state_r <= GM_IDLE;

                default: gm_state_r <= GM_IDLE;
            endcase
        end
    end

    // GM FC SIDEBAND TX mux
    logic                   gm_fc_valid;
    logic [FC_DATA_W-1:0]  gm_fc_data;

    always_comb begin
        gm_fc_valid = 1'b0;
        gm_fc_data  = '0;
        case (gm_state_r)
            GM_SEND_T1_0: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_SEC_LO_OFFSET, gm_t1_sec[31:0]};  end
            GM_SEND_T1_1: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_SEC_HI_OFFSET, {16'b0, gm_t1_sec[47:32]}}; end
            GM_SEND_T1_2: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_NS_OFFSET,     {2'b0, gm_t1_ns}};  end
            GM_SEND_T1_3: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_SUB_NS_OFFSET, gm_t1_sub};         end
            GM_SEND_T4_0: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_SEC_LO_OFFSET, gm_t4_sec[31:0]};  end
            GM_SEND_T4_1: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_SEC_HI_OFFSET, {16'b0, gm_t4_sec[47:32]}}; end
            GM_SEND_T4_2: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_NS_OFFSET,     {2'b0, gm_t4_ns}};  end
            GM_SEND_T4_3: begin gm_fc_valid = 1'b1; gm_fc_data = {PKT_SIDEBAND, MBOX_SUB_NS_OFFSET, gm_t4_sub};         end
            default: ;
        endcase
    end

    // =========================================================================
    // Subordinate FSM
    // =========================================================================

    typedef enum logic [3:0] {
        SUB_IDLE         = 4'd0,
        SUB_CAPTURE_T2   = 4'd1,
        SUB_SEND_DREQ    = 4'd2,
        SUB_WAIT_DREQ_TX = 4'd3,
        SUB_CAPTURE_T3   = 4'd4,
        SUB_WAIT_T1      = 4'd5,
        SUB_LATCH_T1     = 4'd6,
        SUB_WAIT_T4      = 4'd7,
        SUB_LATCH_T4     = 4'd8,
        SUB_COMPUTE_1    = 4'd9,
        SUB_COMPUTE_2    = 4'd10,
        SUB_COMPUTE_3    = 4'd11,
        SUB_COMPUTE_4    = 4'd12,
        SUB_ADJUST       = 4'd13
    } sub_state_t;

    sub_state_t sub_state_r;
    assign sub_active = (sub_state_r != SUB_IDLE);

    // =========================================================================
    // Offset/Delay Computation Pipeline Registers
    // =========================================================================
    // All arithmetic uses 30-bit nanosecond values (sub-ns dropped).
    // Seconds differences checked separately for phase step decisions.

    logic signed [30:0] d_fwd_r;      // t2 - t1 (forward path, ns)
    logic signed [30:0] d_rev_r;      // t4 - t3 (reverse path, ns)
    logic signed [31:0] raw_offset_r;
    logic signed [31:0] raw_delay_r;
    logic signed [31:0] offset_r;     // raw_offset >>> 1
    logic signed [31:0] delay_r;      // raw_delay >>> 1

    // Seconds difference tracking
    logic signed [48:0] sec_diff_fwd_r;  // t2_sec - t1_sec
    logic signed [48:0] sec_diff_rev_r;  // t4_sec - t3_sec
    logic               needs_phase_step_r;

    // PI controller state (32-bit: ±2.15 seconds max accumulated error)
    logic signed [31:0] integral_r;

    // Locked detection: offset below threshold for consecutive exchanges
    localparam LOCK_COUNT = 4;
    logic [3:0] lock_counter_r;

    // =========================================================================
    // Subordinate FSM Logic
    // =========================================================================

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sub_state_r        <= SUB_IDLE;
            d_fwd_r            <= '0;
            d_rev_r            <= '0;
            raw_offset_r       <= '0;
            raw_delay_r        <= '0;
            offset_r           <= '0;
            delay_r            <= '0;
            sec_diff_fwd_r     <= '0;
            sec_diff_rev_r     <= '0;
            needs_phase_step_r <= 1'b0;
            integral_r         <= '0;
            lock_counter_r     <= '0;
            servo_locked       <= 1'b0;
            last_offset_r      <= '0;
            last_delay_r       <= '0;
            current_frac_r     <= '0;
            phc_hw_set_time       <= 1'b0;
            phc_hw_set_seconds    <= '0;
            phc_hw_set_nanoseconds <= '0;
            phc_hw_adj_valid      <= 1'b0;
            phc_hw_adj_ns_incr_frac <= '0;
        end else begin
            // Default: deassert one-cycle pulses
            phc_hw_set_time  <= 1'b0;
            phc_hw_adj_valid <= 1'b0;

            if (!servo_enable_r || !servo_mode_r) begin
                // Disabled or in Grandmaster mode
                sub_state_r <= SUB_IDLE;
            end else begin
                case (sub_state_r)
                    SUB_IDLE: begin
                        if (sync_rx_done)
                            sub_state_r <= SUB_CAPTURE_T2;
                    end

                    SUB_CAPTURE_T2: begin
                        sub_t2_sec  <= hw_cap_seconds;
                        sub_t2_ns   <= hw_cap_nanoseconds;
                        sub_t2_sub  <= hw_cap_sub_nanoseconds;
                        sub_state_r <= SUB_SEND_DREQ;
                    end

                    SUB_SEND_DREQ: begin
                        // servo_dreq_trigger asserted combinationally below
                        sub_state_r <= SUB_WAIT_DREQ_TX;
                    end

                    SUB_WAIT_DREQ_TX: begin
                        if (dreq_tx_done)
                            sub_state_r <= SUB_CAPTURE_T3;
                    end

                    SUB_CAPTURE_T3: begin
                        sub_t3_sec  <= hw_cap_seconds;
                        sub_t3_ns   <= hw_cap_nanoseconds;
                        sub_t3_sub  <= hw_cap_sub_nanoseconds;
                        sub_state_r <= SUB_WAIT_T1;
                    end

                    SUB_WAIT_T1: begin
                        if (mbox_ts_complete)
                            sub_state_r <= SUB_LATCH_T1;
                    end

                    SUB_LATCH_T1: begin
                        sub_t1_sec  <= mbox_seconds;
                        sub_t1_ns   <= mbox_nanoseconds;
                        sub_t1_sub  <= mbox_sub_ns;
                        sub_state_r <= SUB_WAIT_T4;
                    end

                    SUB_WAIT_T4: begin
                        if (mbox_ts_complete)
                            sub_state_r <= SUB_LATCH_T4;
                    end

                    SUB_LATCH_T4: begin
                        sub_t4_sec  <= mbox_seconds;
                        sub_t4_ns   <= mbox_nanoseconds;
                        sub_t4_sub  <= mbox_sub_ns;
                        sub_state_r <= SUB_COMPUTE_1;
                    end

                    // ── Offset Computation Pipeline ──────────────────────
                    SUB_COMPUTE_1: begin
                        // d_fwd = t2 - t1
                        d_fwd_r <= $signed({1'b0, sub_t2_ns, sub_t2_sub}) -
                                   $signed({1'b0, sub_t1_ns, sub_t1_sub});
                        sec_diff_fwd_r <= $signed({1'b0, sub_t2_sec}) -
                                          $signed({1'b0, sub_t1_sec});
                        sub_state_r <= SUB_COMPUTE_2;
                    end

                    SUB_COMPUTE_2: begin
                        // d_rev = t4 - t3
                        d_rev_r <= $signed({1'b0, sub_t4_ns, sub_t4_sub}) -
                                   $signed({1'b0, sub_t3_ns, sub_t3_sub});
                        sec_diff_rev_r <= $signed({1'b0, sub_t4_sec}) -
                                          $signed({1'b0, sub_t3_sec});
                        // Adjust d_fwd for seconds borrow/carry
                        // Only handle |sec_diff| <= 1 arithmetically; larger
                        // differences force a phase step (no multiply needed).
                        case (sec_diff_fwd_r)
                            49'sd0:  ; // Same second — no adjustment
                            49'sd1:  d_fwd_r <= d_fwd_r + ONE_SEC_NS;
                            -49'sd1: d_fwd_r <= d_fwd_r - ONE_SEC_NS;
                            default: ; // |sec_diff| > 1 handled below
                        endcase
                        if (sec_diff_fwd_r > 49'sd1 || sec_diff_fwd_r < -49'sd1)
                            needs_phase_step_r <= 1'b1;
                        sub_state_r <= SUB_COMPUTE_3;
                    end

                    SUB_COMPUTE_3: begin
                        // Adjust d_rev for seconds borrow/carry
                        case (sec_diff_rev_r)
                            49'sd0:  ; // Same second — no adjustment
                            49'sd1:  d_rev_r <= d_rev_r + ONE_SEC_NS;
                            -49'sd1: d_rev_r <= d_rev_r - ONE_SEC_NS;
                            default: ; // |sec_diff| > 1 handled below
                        endcase
                        // Compute raw offset and delay
                        raw_offset_r <= $signed({d_fwd_r[62], d_fwd_r}) -
                                        $signed({d_rev_r[62], d_rev_r});
                        raw_delay_r  <= $signed({d_fwd_r[62], d_fwd_r}) +
                                        $signed({d_rev_r[62], d_rev_r});
                        if (sec_diff_rev_r > 49'sd1 || sec_diff_rev_r < -49'sd1)
                            needs_phase_step_r <= 1'b1;
                        sub_state_r <= SUB_COMPUTE_4;
                    end

                    SUB_COMPUTE_4: begin
                        // Divide by 2 (arithmetic right shift)
                        offset_r <= raw_offset_r >>> 1;
                        delay_r  <= raw_delay_r >>> 1;
                        sub_state_r <= SUB_ADJUST;
                    end

                    // ── Clock Adjustment ─────────────────────────────────
                    SUB_ADJUST: begin
                        // Extract nanosecond portion of offset for status
                        // offset_r is in sub-nanosecond units ({ns, sub_ns})
                        // Shift right by 32 to get ns portion
                        last_offset_r <= offset_r;
                        last_delay_r  <= delay_r;

                        if (needs_phase_step_r ||
                            ($signed(offset_r) > $signed(servo_step_thresh_r)) ||
                            ($signed(offset_r) < -$signed(servo_step_thresh_r))) begin
                            // Phase step — correct time directly
                            phc_hw_set_time <= 1'b1;
                            // Corrected time = local_a (t2) - offset
                            // offset > 0 means Sub ahead, so subtract
                            phc_hw_set_seconds    <= sub_t2_sec;
                            phc_hw_set_nanoseconds <= sub_t2_ns -
                                                      offset_r[61:32]; // ns portion of offset
                            // Reset integral on phase step
                            integral_r     <= '0;
                            lock_counter_r <= '0;
                            servo_locked   <= 1'b0;
                        end else begin
                            // Frequency steering via PI controller
                            // Anti-windup: saturate integral to prevent unbounded growth
                            if ($signed(integral_r + offset_r) > INTEGRAL_MAX)
                                integral_r <= INTEGRAL_MAX;
                            else if ($signed(integral_r + offset_r) < -INTEGRAL_MAX)
                                integral_r <= -INTEGRAL_MAX;
                            else
                                integral_r <= integral_r + offset_r;

                            // PI output computation
                            // p_term = kp * offset_ns (Q0.32 * signed)
                            // i_term = ki * integral_ns (Q0.32 * signed)
                            // Take upper 32 bits of 64-bit product
                            current_frac_r <= current_frac_r -
                                pi_output(servo_kp_r, offset_r,
                                          servo_ki_r, integral_r[63:32]);
                            phc_hw_adj_valid      <= 1'b1;
                            phc_hw_adj_ns_incr_frac <= current_frac_r -
                                pi_output(servo_kp_r, offset_r,
                                          servo_ki_r, integral_r[63:32]);

                            // Lock detection
                            if ($unsigned(offset_r) < servo_step_thresh_r[31:2]) begin
                                if (lock_counter_r < LOCK_COUNT)
                                    lock_counter_r <= lock_counter_r + 4'd1;
                                else
                                    servo_locked <= 1'b1;
                            end else begin
                                lock_counter_r <= '0;
                                servo_locked   <= 1'b0;
                            end
                        end

                        sub_state_r <= SUB_IDLE;
                    end

                    default: sub_state_r <= SUB_IDLE;
                endcase
            end
        end
    end

    // =========================================================================
    // PI Output Function — kp * offset + ki * integral
    // =========================================================================
    // Returns the adjustment to NS_INCR_FRAC (signed, 32-bit)
    // Uses Q0.32 fixed-point gains: multiply 32-bit signed offset by 32-bit
    // unsigned gain, take upper 32 bits of 64-bit product.

    function automatic logic signed [31:0] pi_output(
        input logic [31:0] kp,
        input logic signed [31:0] offset_ns,
        input logic [31:0] ki,
        input logic signed [31:0] integral_ns
    );
        logic signed [63:0] p_term;
        logic signed [63:0] i_term;
        p_term = $signed({{32{offset_ns[31]}}, offset_ns}) * $signed({1'b0, kp});
        i_term = $signed({{32{integral_ns[31]}}, integral_ns}) * $signed({1'b0, ki});
        return 32'((p_term + i_term) >>> 32);
    endfunction

    // =========================================================================
    // Output Muxing — Servo DELAY_REQ Trigger
    // =========================================================================
    assign servo_dreq_trigger = (sub_state_r == SUB_SEND_DREQ);

    // =========================================================================
    // Output Muxing — FC SIDEBAND TX (from active FSM)
    // =========================================================================
    // Only GM FSM sends FC packets; Sub FSM only receives via mailbox.
    assign servo_fc_valid = gm_fc_valid;
    assign servo_fc_data  = gm_fc_data;

endmodule
