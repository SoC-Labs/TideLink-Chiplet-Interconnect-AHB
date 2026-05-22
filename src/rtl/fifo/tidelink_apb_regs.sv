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
    output logic [SYS_DATA_W-1:0]  mbox_reg_wdata,

    // Chiplet controller register pass-through (Regions 4 + 8).
    // ctrl_reg_addr is widened from 3 to 4 bits: bits[2:0] are the slot
    // within the region, bit[3] selects between Region 4 (paddr[8]=0,
    // slots 0..7 -> 0x080..0x09C) and Region 8 (paddr[8]=1, slots 0..7
    // remapped to ctrl_reg_addr bits [3:0] = 4'b1000..4'b1111 -> 0x100..0x11C).
    output logic                    ctrl_reg_write,
    output logic              [3:0] ctrl_reg_addr,
    output logic [SYS_DATA_W-1:0]  ctrl_reg_wdata,
    input  logic [SYS_DATA_W-1:0]  ctrl_reg_rdata,

    // Performance profiling register pass-through (Regions 5-7)
    output logic                    perf_reg_write,
    output logic              [2:0] perf_reg_addr,
    output logic [SYS_DATA_W-1:0]  perf_reg_wdata,
    input  logic [SYS_DATA_W-1:0]  perf_reg_rdata,
    output logic              [1:0] perf_reg_region
);

    // -------------------------------------------------------------------------
    // APB Register Map
    // -------------------------------------------------------------------------
    // Region 0 (paddr[7:5]=000): Configuration and Status
    //   0x000: Pair Base Address       (RW) - defaults to TIDELINK_PAIR_BASE param
    //   0x004: Release Threshold       (RW) - default 20, 0 = immediate release
    //   0x008: Packet Word Length      (RO)
    //   0x00C: Credit Count             (RO)
    //   0x010: Status Register         (RO) - expanded status and sticky errors
    //   0x014: Doorbell Register       (W1C) - self-clearing pulse
    //   0x018: Release Accumulator     (RO) - debug: pending unreleased credits
    //   0x01C: CTRL Register           (RW) - [0] Reserved, [1] FLUSH (self-clearing)
    //
    // Region 1 (paddr[7:5]=001): Incoming Credit Receivers + PTP Basic
    //   0x020: Released Credits Acc     (W-add / R-clear) IRQ: released_credits_irq
    //   0x024: Doorbell Response Acc   (W-add / R-clear) IRQ: doorbell_irq
    //   0x028: Pair Credit Counter      (RO)
    //   0x02C: Pair Credit Consume      (WO)
    //   0x030: Pair Credit Counter En   (RW) - bit[0] enable
    //   0x034: PTP_CTRL                 (RW) - pass-through to tidelink_ptp
    //   0x038: PTP_RX_PAYLOAD           (RO) - pass-through to tidelink_ptp
    //   0x03C: PTP_STATUS               (RO) - pass-through to tidelink_ptp
    //
    // Region 2 (paddr[7:5]=010): PTP HW Sync Initiator
    //   0x040: HW_SYNC_CTRL            (RW) - [0] enable, [1] seq_clear (W1C), [2] force_en
    //   0x044: HW_SYNC_INTERVAL        (RW) - pass-through to tidelink_ptp
    //   0x048: HW_SYNC_STATUS          (RO) - [0] active, [1] busy, [17:2] seq_num, [18] phc_locked
    //
    // Region 8 (paddr[8:5]=1000, offsets 0x100-0x11F): Chiplet Extended.
    //   PHY-alignment and I2C-training registers. See
    //   staging/apb_redesign/PROPOSAL.md for layout.
    //
    //   0x100: SWI_TRAINING_MODE        (RW) - [0] training-mode enable
    //   0x104: SWI_BIT_SLIP_LO          (RW) - [23:0] per-lane bit-slip
    //   0x108: SWI_LANE_STATUS          (RO) - [7:0] locked, [15:8] fault, [16] cal_done
    //   0x10C: NEGO_TRAIN_CFG           (RW) - training handshake config
    //   0x110: NEGO_TRAIN_STATUS        (RO) - training FSM status
    //   0x114: NEGO_TRAIN_STEP          (RW) - W1P single-step pulse
    //   0x118: SWI_PHASE_OFFSET         (RW) - [31:0] per-lane sub-bit phase (8 x 4-bit, §9.7)
    //   0x11C: PHY_ALIGN_ID             (RO) - 0x5041_0100
    // -------------------------------------------------------------------------

    // APB decode. Widen region select to paddr[8:5] (4-bit) so that
    // paddr[8]=1 enters the new Region 8 block. Regions 0..7 keep their
    // original 3-bit decode (paddr[8]=0, paddr[7:5]=000..111).
    wire [3:0] apb_region       = paddr[8:5];
    wire       apb_region_is_ext = paddr[8];  // 1 = Region 8+ (extended)
    wire apb_write  = psel && penable && pwrite;
    wire apb_read   = psel && penable && !pwrite;

    // ── Region 0: Configuration Registers ───────────────────────────────────

    logic [SYS_DATA_W-1:0] release_threshold;

    // ── CTRL register (0x01C) ─────────────────────────────────────────────
    // [0] EN:    Reserved (reads as 0). Formerly gated AHB data window accesses.
    // [1] FLUSH: Write 1 to reset pointers, packet state, and sticky errors.
    //            Self-clearing.
    // [2] LOCK:  Shortcoming #25 fix — write-once. Once set, prevents modification
    //            of pair_base_addr and release_threshold until next reset.
    logic ctrl_flush_r;
    logic ctrl_lock_r;

    assign ctrl_flush  = ctrl_flush_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ctrl_flush_r  <= 1'b0;
            ctrl_lock_r   <= 1'b0;
        end else begin
            // FLUSH is self-clearing: assert for one cycle only
            ctrl_flush_r <= 1'b0;

            if (apb_write && (apb_region == 4'b0000) && paddr[4:2] == 3'h7) begin
                if (pwdata[1])
                    ctrl_flush_r <= 1'b1;
                // LOCK is write-once: can only be set, never cleared by software
                if (pwdata[2])
                    ctrl_lock_r <= 1'b1;
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

            if (apb_write && (apb_region == 4'b0000)) begin
                case (paddr[4:2])
                    // Shortcoming #25: pair_base_addr and release_threshold
                    // gated by lock bit
                    3'h0: if (!ctrl_lock_r) pair_base_addr    <= pwdata[SYS_ADDR_W-1:0];
                    3'h1: if (!ctrl_lock_r) release_threshold <= pwdata;
                    3'h5: doorbell_trigger  <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // ── Reset deassertion detector with debounce (Shortcoming #13) ────────────
    // The two-stage synchroniser detects async-to-sync reset deassertion.
    // A 4-cycle debounce counter filters glitches on hresetn during deassertion,
    // preventing multiple doorbell writes from reset bounce.

    logic reset_n_d1, reset_n_d2;
    logic [2:0] debounce_count_r;
    logic debounce_stable_r;

    // (HAL URDWIR cleanup: the unused wire `reset_n_raw_edge` previously here
    // was an unreferenced intermediate; the debouncer uses reset_n_d1/d2
    // directly via `debounce_count_r`.)

    // Pulse only fires after stable for 4 consecutive cycles
    assign reset_deassert_pulse = debounce_stable_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            reset_n_d1       <= 1'b0;
            reset_n_d2       <= 1'b0;
            debounce_count_r <= '0;
            debounce_stable_r <= 1'b0;
        end else begin
            reset_n_d1 <= 1'b1;
            reset_n_d2 <= reset_n_d1;

            // Debounce: count consecutive cycles where synchroniser output is stable high
            debounce_stable_r <= 1'b0;  // Default: no pulse
            if (!reset_n_d1) begin
                // Reset still active (or bouncing low) — restart count
                debounce_count_r <= '0;
            end else if (debounce_count_r < 3'd4) begin
                debounce_count_r <= debounce_count_r + 3'd1;
            end else if (debounce_count_r == 3'd4) begin
                // Stable for 4 cycles — emit pulse once
                debounce_stable_r <= 1'b1;
                debounce_count_r  <= 3'd5;  // Saturate to prevent re-firing
            end
        end
    end

    // ── Region 1: Released Credits Accumulator (0x020) ─────────────────────────

    logic [15:0] released_credits_acc;

    // Shortcoming #8 fix: handle simultaneous read-clear and write-add explicitly.
    // On standard APB, apb_read and apb_write are mutually exclusive (pwrite is
    // a single bit), so the simultaneous case cannot occur. This explicit handling
    // is defensive — if a future integration adds a second write port, the incoming
    // write value is retained rather than silently lost.
    wire acc0_read  = apb_read  && (apb_region == 4'b0001) && paddr[4:2] == 3'h0;
    wire acc0_write = apb_write && (apb_region == 4'b0001) && paddr[4:2] == 3'h0;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            released_credits_acc <= '0;
        end else if (acc0_read && acc0_write) begin
            // Simultaneous: clear old total, retain new delta
            released_credits_acc <= pwdata[15:0];
        end else if (acc0_read) begin
            released_credits_acc <= '0;
        end else if (acc0_write) begin
            // Saturating 16-bit add: clamp at 0xFFFF on overflow
            if ({1'b0, released_credits_acc} + {1'b0, pwdata[15:0]} > 17'h0FFFF)
                released_credits_acc <= 16'hFFFF;
            else
                released_credits_acc <= released_credits_acc + pwdata[15:0];
        end
    end

    assign released_credits_irq = (released_credits_acc != '0);

    // ── Region 1: Doorbell Response Accumulator (0x024) ───────────────────────

    logic [15:0] doorbell_response_acc;

    // Same defensive handling as released_credits_acc (Shortcoming #8)
    wire acc1_read  = apb_read  && (apb_region == 4'b0001) && paddr[4:2] == 3'h1;
    wire acc1_write = apb_write && (apb_region == 4'b0001) && paddr[4:2] == 3'h1;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            doorbell_response_acc <= '0;
        end else if (acc1_read && acc1_write) begin
            doorbell_response_acc <= pwdata[15:0];
        end else if (acc1_read) begin
            doorbell_response_acc <= '0;
        end else if (acc1_write) begin
            // Saturating 16-bit add: clamp at 0xFFFF on overflow
            if ({1'b0, doorbell_response_acc} + {1'b0, pwdata[15:0]} > 17'h0FFFF)
                doorbell_response_acc <= 16'hFFFF;
            else
                doorbell_response_acc <= doorbell_response_acc + pwdata[15:0];
        end
    end

    assign doorbell_irq = (doorbell_response_acc != '0);

    // ── Region 1: Pair Credit Counter (0x028 / 0x02C / 0x030) ─────────────────

    logic [SYS_DATA_W-1:0] pair_credit_counter;
    logic                  pair_credit_counter_en;

    wire pair_counter_increment = apb_write && (apb_region == 4'b0001) && paddr[4:2] == 3'h0;
    wire pair_counter_decrement = apb_write && (apb_region == 4'b0001) && paddr[4:2] == 3'h3;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pair_credit_counter    <= '0;
            pair_credit_counter_en <= 1'b1;
        end else begin
            if (apb_write && (apb_region == 4'b0001) && paddr[4:2] == 3'h4) begin
                pair_credit_counter_en <= pwdata[0];
            end

            if (pair_credit_counter_en) begin
                if (pair_counter_increment && pair_counter_decrement) begin
                    pair_credit_counter <= pair_credit_counter + pwdata - pwdata;
                end else if (pair_counter_increment) begin
                    pair_credit_counter <= pair_credit_counter + pwdata;
                end else if (pair_counter_decrement) begin
                    // Shortcoming #7 fix: saturate at zero to prevent unsigned underflow wrap
                    if (pair_credit_counter >= pwdata)
                        pair_credit_counter <= pair_credit_counter - pwdata;
                    else
                        pair_credit_counter <= '0;
                end
            end
        end
    end

    // ── Release threshold accumulator ───────────────────────────────────────
    // Accumulates credit deltas on each read_complete. When the accumulated
    // total meets or exceeds release_threshold, fires release_credits_trigger
    // and sends the full batch to the returner. Threshold=0 means immediate
    // release (backward-compatible with pre-threshold behaviour).

    wire [SYS_DATA_W-1:0] credit_delta_data_comb = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length} + SYS_DATA_W'(2);

    // Pipeline stage 1: register credit delta and read_complete to break
    // the zero-extend → add_1 → add_acc → compare combinational chain.
    // Two-cycle total latency is invisible (returner takes 3+ cycles per txn).
    logic [SYS_DATA_W-1:0] credit_delta_data_r;
    logic                   read_complete_pipe;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            credit_delta_data_r <= '0;
            read_complete_pipe  <= 1'b0;
        end else begin
            credit_delta_data_r <= credit_delta_data_comb;
            read_complete_pipe  <= read_complete;
        end
    end

    logic [SYS_DATA_W-1:0] release_acc;
    wire  [SYS_DATA_W-1:0] release_acc_next = release_acc + credit_delta_data_r;
    wire  [SYS_DATA_W-1:0] effective_acc    = read_complete_pipe ? release_acc_next : release_acc;

    // Pipeline stage 2: register effective_acc for threshold comparison.
    logic                  read_complete_d1;
    logic [SYS_DATA_W-1:0] effective_acc_d1;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            read_complete_d1 <= 1'b0;
            effective_acc_d1 <= '0;
        end else begin
            read_complete_d1 <= read_complete_pipe;
            effective_acc_d1 <= effective_acc;
        end
    end

    assign release_credits_trigger =
        (release_threshold == '0) ? read_complete_d1 :
        (read_complete_d1 && (effective_acc_d1 >= release_threshold));

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            release_acc <= '0;
        else if (ctrl_flush_r)
            release_acc <= '0;
        else if (release_credits_trigger)
            release_acc <= '0;
        else if (read_complete_pipe)
            release_acc <= release_acc_next;
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            credit_delta_data <= '0;
        else if (release_credits_trigger)
            credit_delta_data <= effective_acc_d1;
    end

    // Total free credits (combinational)
    assign credit_count_data = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_credit_count};

    // ── PTP register pass-through ──────────────────────────────────────────────
    // PTP basic registers occupy Region 1 offsets 0x034/0x038/0x03C (paddr[4:2] = 5/6/7).
    // PTP HW sync registers occupy Region 2 offsets 0x040/0x044/0x048 (paddr[4:2] = 0/1/2).
    // Write/read decode is forwarded to the tidelink_ptp module via direct wires.
    assign ptp_reg_write  = (apb_write && (apb_region == 4'b0001) && (paddr[4:2] >= 3'h5)) ||
                            (apb_write && (apb_region == 4'b0010) && (paddr[4:2] <= 3'h2));
    assign ptp_reg_addr   = paddr[4:2];
    assign ptp_reg_wdata  = pwdata;
    assign ptp_reg_region = (apb_region == 4'b0010);

    // Servo config: Region 2 addr 3-7 (offsets 0x04C-0x05C) → servo_reg_addr 0-4
    // Servo status: Region 3 addr 0-1 (offsets 0x060-0x064) → servo_reg_addr 5-6
    assign servo_reg_write = apb_write && (apb_region == 4'b0010) && (paddr[4:2] >= 3'h3);
    assign servo_reg_addr  = (apb_region == 4'b0011) ? (3'h5 + paddr[4:2]) : (paddr[4:2] - 3'h3);
    assign servo_reg_wdata = pwdata;

    // Timestamp mailbox: Region 3 (offsets 0x060-0x07C, written by FC SIDEBAND)
    assign mbox_reg_write = apb_write && (apb_region == 4'b0011);
    assign mbox_reg_addr  = paddr[4:2];
    assign mbox_reg_wdata = pwdata;

    // Chiplet controller: Region 4 (0x080-0x09C) AND Region 8 (0x100-0x11C).
    //   ctrl_reg_addr[3] selects between them.
    //   Region 4: ctrl_reg_addr = {1'b0, paddr[4:2]}, slots 0..7 (0x080..0x09C)
    //   Region 8: ctrl_reg_addr = {1'b1, paddr[4:2]}, slots 8..15 (0x100..0x11C)
    assign ctrl_reg_write = apb_write && ((apb_region == 4'b0100) ||
                                           (apb_region == 4'b1000));
    assign ctrl_reg_addr  = {apb_region_is_ext, paddr[4:2]};
    assign ctrl_reg_wdata = pwdata;

    // Performance profiling: Regions 5-7 (offsets 0x0A0-0x0FC).
    //   Compared against the wider region select; Region 8+ is NOT perf
    //   (it's the chiplet-extended block); guard with bounds.
    assign perf_reg_write  = apb_write && (apb_region >= 4'b0101) &&
                                          (apb_region <= 4'b0111);
    assign perf_reg_addr   = paddr[4:2];
    assign perf_reg_wdata  = pwdata;
    assign perf_reg_region = apb_region[1:0];

    // ── APB Read Mux ──────────────────────────────────────────────────────────

    always_comb begin
        prdata = '0;
        case (apb_region)
            4'b0000: begin // Region 0: Configuration and Status
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
                    // Shortcoming #11: peripheral ID/version register
                    // Reads from doorbell address (0x014) return ID.
                    // [31:16] = component ID (0x544C = "TL" for TideLink)
                    // [15:8]  = major version
                    // [7:0]   = minor version
                    3'h5:    prdata = 32'h544C_0100;  // TideLink v1.0
                    3'h6:    prdata = release_acc;
                    3'h7:    prdata = {{(SYS_DATA_W-3){1'b0}}, ctrl_lock_r, 2'b00};
                    default: ;
                endcase
            end
            4'b0001: begin // Region 1: Credits + PTP Basic
                case (paddr[4:2])
                    3'h0:    prdata = {{16{1'b0}}, released_credits_acc};
                    3'h1:    prdata = {{16{1'b0}}, doorbell_response_acc};
                    3'h2:    prdata = pair_credit_counter;
                    3'h4:    prdata = {{(SYS_DATA_W-1){1'b0}}, pair_credit_counter_en};
                    3'h5:    prdata = ptp_reg_rdata;  // PTP_CTRL
                    3'h6:    prdata = ptp_reg_rdata;  // PTP_RX_PAYLOAD
                    3'h7:    prdata = ptp_reg_rdata;  // PTP_STATUS
                    default: ;
                endcase
            end
            4'b0010: begin // Region 2: PTP HW Sync (addr 0-2) + Servo Config (addr 3-7)
                if (paddr[4:2] >= 3'h3)
                    prdata = servo_reg_rdata;
                else
                    prdata = ptp_reg_rdata;
            end
            4'b0011: begin // Region 3: Servo status + Mailbox (read-only)
                prdata = servo_reg_rdata;
            end
            4'b0100: begin // Region 4: Chiplet controller role config (pass-through)
                prdata = ctrl_reg_rdata;
            end
            4'b0101: prdata = perf_reg_rdata;
            4'b0110: prdata = perf_reg_rdata;
            4'b0111: prdata = perf_reg_rdata;
            4'b1000: begin // Region 8: Chiplet Extended (PHY align + I2C train)
                //   Same ctrl_reg_rdata pass-through path; the chiplet
                //   controller's read mux distinguishes Region 4 vs Region 8
                //   via ctrl_reg_addr[3].
                prdata = ctrl_reg_rdata;
            end
            default: ;
        endcase
    end

    assign pready  = 1'b1;

    // Assert pslverr for invalid accesses (writes to RO regs, reads from WO regs).
    // Output port driven directly from always_comb to avoid HAL REVROP.
    always_comb begin
        pslverr = 1'b0;
        if (psel && penable) begin
            case (apb_region)
                4'b0000: begin
                    if (pwrite) begin
                        case (paddr[4:2])
                            3'h2, 3'h3, 3'h4, 3'h6: pslverr = 1'b1; // Write to RO: PKT_WORD_LEN, CREDIT_COUNT, STATUS, REL_ACC
                            default: ;
                        endcase
                    end
                end
                4'b0001: begin
                    if (pwrite && paddr[4:2] == 3'h2)
                        pslverr = 1'b1; // Write to RO: PAIR_CREDIT_COUNTER
                    if (!pwrite && paddr[4:2] == 3'h3)
                        pslverr = 1'b1; // Read from WO: PAIR_CREDIT_CONSUME
                end
                4'b1000: begin // Region 8 RO slots
                    if (pwrite) begin
                        case (paddr[4:2])
                            3'h2, 3'h4, 3'h7: pslverr = 1'b1; // SWI_LANE_STATUS, NEGO_TRAIN_STATUS, PHY_ALIGN_ID
                            default: ;
                        endcase
                    end
                end
                default: ;
            endcase
        end
    end

endmodule
