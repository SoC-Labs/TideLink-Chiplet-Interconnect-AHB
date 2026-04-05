//-----------------------------------------------------------------------------
// SoCLabs TideLink APB Register Interface
// - APB slave register block for configuration, status, credit accumulators,
//   doorbell control, and reset detection.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_apb_regs #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0
)(
    // Clock and Reset
    input  logic                    hclk,
    input  logic                    hresetn,

    // APB Slave Interface
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    // hal lint_off USEPRT
    input  logic   [APB_ADDR_W-1:0] paddr,       // Only paddr[5:2] decoded
    // hal lint_on USEPRT
    input  logic   [SYS_DATA_W-1:0] pwdata,
    output logic   [SYS_DATA_W-1:0] prdata,
    output logic                    pready,
    output logic                    pslverr,

    // FIFO sideband inputs (from tidelink_fifo_mem)
    input  logic [RAM_ADDR_W-1:0]   packet_word_length,
    input  logic [RAM_ADDR_W-2:0]   current_credit_count,
    input  logic                    read_complete,

    // Returner status input (from tidelink_returner)
    input  logic                    returner_busy,

    // Error flag inputs (from FIFO and returner)
    input  logic                    fifo_overrun,
    input  logic                    fifo_underrun,
    input  logic                    master_error,

    // Packet committed flag (from FIFO ctrl, exposed in STATUS[4])
    input  logic                    packet_committed,

    // Control outputs (to FIFO and returner)
    output logic                    ctrl_flush,

    // Returner control outputs (to tidelink_fifo top-level for returner wiring)
    output logic                    doorbell_trigger,
    output logic                    reset_deassert_pulse,
    output logic [SYS_DATA_W-1:0]   credit_delta_data,
    output logic [SYS_DATA_W-1:0]   credit_count_data,
    output logic                    release_credits_trigger,

    // Pair base address output (RW register, used by tidelink_fifo.sv for returner targets)
    output logic [SYS_ADDR_W-1:0]   pair_base_addr,

    // IRQ outputs
    output logic                    released_credits_irq,
    output logic                    doorbell_irq,

    // PTP register pass-through (directly to/from tidelink_ptp module)
    output logic                    ptp_reg_write,
    output logic              [2:0] ptp_reg_addr,
    output logic [SYS_DATA_W-1:0]  ptp_reg_wdata,
    input  logic [SYS_DATA_W-1:0]  ptp_reg_rdata,
    output logic                    ptp_reg_region,  // 0=Region 1 (basic PTP), 1=Region 2 (HW sync)

    // Servo register pass-through (Region 2 addr>=3 and Region 3 reads)
    output logic                    servo_reg_write,
    output logic              [2:0] servo_reg_addr,
    output logic [SYS_DATA_W-1:0]  servo_reg_wdata,
    input  logic [SYS_DATA_W-1:0]  servo_reg_rdata,

    // Timestamp mailbox pass-through (Region 3 writes from FC SIDEBAND)
    output logic                    mbox_reg_write,
    output logic              [2:0] mbox_reg_addr,
    output logic [SYS_DATA_W-1:0]  mbox_reg_wdata
);

    // -------------------------------------------------------------------------
    // APB Register Map
    // -------------------------------------------------------------------------
    // Region 0 (paddr[6:5]=00): Configuration and Status
    //   0x000: Pair Base Address       (RW) - defaults to TIDELINK_PAIR_BASE param
    //   0x004: Release Threshold       (RW) - default 20, 0 = immediate release
    //   0x008: Packet Word Length      (RO)
    //   0x00C: Credit Count             (RO)
    //   0x010: Status Register         (RO) - expanded status and sticky errors
    //   0x014: Doorbell Register       (W1C) - self-clearing pulse
    //   0x018: Release Accumulator     (RO) - debug: pending unreleased credits
    //   0x01C: CTRL Register           (RW) - [0] Reserved, [1] FLUSH (self-clearing)
    //
    // Region 1 (paddr[6:5]=01): Incoming Credit Receivers + PTP Basic
    //   0x020: Released Credits Acc     (W-add / R-clear) IRQ: released_credits_irq
    //   0x024: Doorbell Response Acc   (W-add / R-clear) IRQ: doorbell_irq
    //   0x028: Pair Credit Counter      (RO)
    //   0x02C: Pair Credit Consume      (WO)
    //   0x030: Pair Credit Counter En   (RW) - bit[0] enable
    //   0x034: PTP_CTRL                 (RW) - pass-through to tidelink_ptp
    //   0x038: PTP_RX_PAYLOAD           (RO) - pass-through to tidelink_ptp
    //   0x03C: PTP_STATUS               (RO) - pass-through to tidelink_ptp
    //
    // Region 2 (paddr[6:5]=10): PTP HW Sync Initiator
    //   0x040: HW_SYNC_CTRL            (RW) - pass-through to tidelink_ptp
    //   0x044: HW_SYNC_INTERVAL        (RW) - pass-through to tidelink_ptp
    //   0x048: HW_SYNC_STATUS          (RO) - pass-through to tidelink_ptp
    // -------------------------------------------------------------------------

    // APB decode
    wire [1:0] apb_region = paddr[6:5];
    wire apb_write  = psel && penable && pwrite;
    wire apb_read   = psel && penable && !pwrite;

    // ── Region 0: Configuration Registers ───────────────────────────────────

    logic [SYS_DATA_W-1:0] release_threshold;

    // ── CTRL register (0x01C) ─────────────────────────────────────────────
    // [0] EN:    Reserved (reads as 0). Formerly gated AHB data window accesses.
    // [1] FLUSH: Write 1 to reset pointers, packet state, and sticky errors.
    //            Self-clearing.
    logic ctrl_flush_r;

    assign ctrl_flush  = ctrl_flush_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ctrl_flush_r  <= 1'b0;
        end else begin
            // FLUSH is self-clearing: assert for one cycle only
            ctrl_flush_r <= 1'b0;

            if (apb_write && (apb_region == 2'b00) && paddr[4:2] == 3'h7) begin
                if (pwdata[1])
                    ctrl_flush_r <= 1'b1;
            end
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pair_base_addr    <= TIDELINK_PAIR_BASE;
            doorbell_trigger  <= 1'b0;
            release_threshold <= SYS_DATA_W'(32'd20);
        end else begin
            doorbell_trigger <= 1'b0;

            if (apb_write && (apb_region == 2'b00)) begin
                case (paddr[4:2])
                    3'h0: pair_base_addr    <= pwdata[SYS_ADDR_W-1:0];
                    3'h1: release_threshold <= pwdata;
                    3'h5: doorbell_trigger  <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // ── Reset deassertion detector ────────────────────────────────────────────

    logic reset_n_d1, reset_n_d2;
    assign reset_deassert_pulse = reset_n_d1 & ~reset_n_d2;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            reset_n_d1 <= 1'b0;
            reset_n_d2 <= 1'b0;
        end else begin
            reset_n_d1 <= 1'b1;
            reset_n_d2 <= reset_n_d1;
        end
    end

    // ── Region 1: Released Credits Accumulator (0x020) ─────────────────────────

    logic [SYS_DATA_W-1:0] released_credits_acc;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            released_credits_acc <= '0;
        end else if (apb_read && (apb_region == 2'b01) && paddr[4:2] == 3'h0) begin
            released_credits_acc <= '0;
        end else if (apb_write && (apb_region == 2'b01) && paddr[4:2] == 3'h0) begin
            released_credits_acc <= released_credits_acc + pwdata;
        end
    end

    assign released_credits_irq = (released_credits_acc != '0);

    // ── Region 1: Doorbell Response Accumulator (0x024) ───────────────────────

    logic [SYS_DATA_W-1:0] doorbell_response_acc;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            doorbell_response_acc <= '0;
        end else if (apb_read && (apb_region == 2'b01) && paddr[4:2] == 3'h1) begin
            doorbell_response_acc <= '0;
        end else if (apb_write && (apb_region == 2'b01) && paddr[4:2] == 3'h1) begin
            doorbell_response_acc <= doorbell_response_acc + pwdata;
        end
    end

    assign doorbell_irq = (doorbell_response_acc != '0);

    // ── Region 1: Pair Credit Counter (0x028 / 0x02C / 0x030) ─────────────────

    logic [SYS_DATA_W-1:0] pair_credit_counter;
    logic                  pair_credit_counter_en;

    wire pair_counter_increment = apb_write && (apb_region == 2'b01) && paddr[4:2] == 3'h0;
    wire pair_counter_decrement = apb_write && (apb_region == 2'b01) && paddr[4:2] == 3'h3;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pair_credit_counter    <= '0;
            pair_credit_counter_en <= 1'b1;
        end else begin
            if (apb_write && (apb_region == 2'b01) && paddr[4:2] == 3'h4) begin
                pair_credit_counter_en <= pwdata[0];
            end

            if (pair_credit_counter_en) begin
                if (pair_counter_increment && pair_counter_decrement) begin
                    pair_credit_counter <= pair_credit_counter + pwdata - pwdata;
                end else if (pair_counter_increment) begin
                    pair_credit_counter <= pair_credit_counter + pwdata;
                end else if (pair_counter_decrement) begin
                    pair_credit_counter <= pair_credit_counter - pwdata;
                end
            end
        end
    end

    // ── Release threshold accumulator ───────────────────────────────────────
    // Accumulates credit deltas on each read_complete. When the accumulated
    // total meets or exceeds release_threshold, fires release_credits_trigger
    // and sends the full batch to the returner. Threshold=0 means immediate
    // release (backward-compatible with pre-threshold behaviour).

    wire [SYS_DATA_W-1:0] credit_delta_data_comb = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length} + SYS_DATA_W'(1);

    logic [SYS_DATA_W-1:0] release_acc;
    wire  [SYS_DATA_W-1:0] release_acc_next = release_acc + credit_delta_data_comb;
    wire  [SYS_DATA_W-1:0] effective_acc    = read_complete ? release_acc_next : release_acc;

    assign release_credits_trigger =
        (release_threshold == '0) ? read_complete :
        (effective_acc >= release_threshold);

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            release_acc <= '0;
        else if (ctrl_flush_r)
            release_acc <= '0;
        else if (release_credits_trigger)
            release_acc <= '0;
        else if (read_complete)
            release_acc <= release_acc_next;
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            credit_delta_data <= '0;
        else if (release_credits_trigger)
            credit_delta_data <= effective_acc;
    end

    // Total free credits (combinational)
    assign credit_count_data = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_credit_count};

    // ── PTP register pass-through ──────────────────────────────────────────────
    // PTP basic registers occupy Region 1 offsets 0x034/0x038/0x03C (paddr[4:2] = 5/6/7).
    // PTP HW sync registers occupy Region 2 offsets 0x040/0x044/0x048 (paddr[4:2] = 0/1/2).
    // Write/read decode is forwarded to the tidelink_ptp module via direct wires.
    assign ptp_reg_write  = (apb_write && (apb_region == 2'b01) && (paddr[4:2] >= 3'h5)) ||
                            (apb_write && (apb_region == 2'b10) && (paddr[4:2] <= 3'h2));
    assign ptp_reg_addr   = paddr[4:2];
    assign ptp_reg_wdata  = pwdata;
    assign ptp_reg_region = (apb_region == 2'b10);

    // Servo config: Region 2 addr 3-7 (offsets 0x04C-0x05C) → servo_reg_addr 0-4
    // Servo status: Region 3 addr 0-1 (offsets 0x060-0x064) → servo_reg_addr 5-6
    assign servo_reg_write = apb_write && (apb_region == 2'b10) && (paddr[4:2] >= 3'h3);
    assign servo_reg_addr  = (apb_region == 2'b11) ? (3'h5 + paddr[4:2]) : (paddr[4:2] - 3'h3);
    assign servo_reg_wdata = pwdata;

    // Timestamp mailbox: Region 3 (offsets 0x060-0x07C, written by FC SIDEBAND)
    assign mbox_reg_write = apb_write && (apb_region == 2'b11);
    assign mbox_reg_addr  = paddr[4:2];
    assign mbox_reg_wdata = pwdata;

    // ── APB Read Mux ──────────────────────────────────────────────────────────

    always_comb begin
        prdata = '0;
        case (apb_region)
            2'b00: begin // Region 0: Configuration and Status
                case (paddr[4:2])
                    3'h0:    prdata = pair_base_addr;
                    3'h1:    prdata = release_threshold;
                    3'h2:    prdata = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length};
                    3'h3:    prdata = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_credit_count};
                    3'h4:    prdata = {
                                 {(SYS_DATA_W-5){1'b0}},
                                 packet_committed,   // [4]
                                 master_error,        // [3]
                                 fifo_underrun,       // [2]
                                 fifo_overrun,        // [1]
                                 returner_busy        // [0]
                             };
                    3'h6:    prdata = release_acc;
                    3'h7:    prdata = {(SYS_DATA_W){1'b0}};
                    default: ;
                endcase
            end
            2'b01: begin // Region 1: Credits + PTP Basic
                case (paddr[4:2])
                    3'h0:    prdata = released_credits_acc;
                    3'h1:    prdata = doorbell_response_acc;
                    3'h2:    prdata = pair_credit_counter;
                    3'h4:    prdata = {{(SYS_DATA_W-1){1'b0}}, pair_credit_counter_en};
                    3'h5:    prdata = ptp_reg_rdata;  // PTP_CTRL
                    3'h6:    prdata = ptp_reg_rdata;  // PTP_RX_PAYLOAD
                    3'h7:    prdata = ptp_reg_rdata;  // PTP_STATUS
                    default: ;
                endcase
            end
            2'b10: begin // Region 2: PTP HW Sync (addr 0-2) + Servo Config (addr 3-7)
                if (paddr[4:2] >= 3'h3)
                    prdata = servo_reg_rdata;
                else
                    prdata = ptp_reg_rdata;
            end
            2'b11: begin // Region 3: Servo status + Mailbox (read-only)
                prdata = servo_reg_rdata;
            end
        endcase
    end

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

endmodule
