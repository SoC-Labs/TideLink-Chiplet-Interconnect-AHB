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
    // Credit-leak fix (2026-06-12): pulse from the returner the cycle it
    // captures write_data_0, so the delta can accumulate until truly sent.
    input  logic                    credit_delta_captured,
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

    // Chiplet controller register pass-through (Regions 4 + 8 + C).
    // ctrl_reg_addr is widened to 5 bits: bits[2:0] are the slot
    // within the region, bits[4:3] select between Region 4 (paddr[8:5]=4'b0100,
    // slots 0..7 -> 0x080..0x09C), Region 8 (paddr[8:5]=4'b1000, slots 0..7
    // -> 0x100..0x11C) and Region C (paddr[8:5]=4'b1100, slots 0..7
    // -> 0x180..0x19C, autoneg observability — Bug N7/N8 silicon probes,
    // 2026-06-01). Encoding:
    //   ctrl_reg_addr[4:3] = 2'b01 → Region 4
    //   ctrl_reg_addr[4:3] = 2'b10 → Region 8
    //   ctrl_reg_addr[4:3] = 2'b11 → Region C (read-only observability)
    output logic                    ctrl_reg_write,
    output logic              [4:0] ctrl_reg_addr,
    // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override (2026-06-16,
    // perlane-wp): Region 10 (apb_region 4'b1010, SoC 0x4403_2144-0x4403_214C)
    // select. The naive {apb_region[3:2],...} maps Region 10 onto Region 8's
    // 2'b10 select and aliases it (same family as the Region 9 special-case), so
    // Region 10 is carried as a SEPARATE 1-bit select alongside the normal
    // ctrl_reg_addr; the controller decodes its 3 slots off ctrl_reg_addr[2:0]
    // when this bit is high. 0x2140 (EPOCH_STATUS, paddr 0x140 slot 0) stays
    // routed to the gpio_phy slave in tidelink_top — only 0x2144/0x2148/0x214C
    // (slots 1/2/3) are claimed here. V1 ties this low (bit-identical).
    output logic                    ctrl_reg_r10,
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap): Region D
    // (apb_region 4'b1101, SoC 0x4403_21A0-0x4403_21A8) select. Like Region 10
    // it folds onto the controller's 2'b00 select; this 1-bit flag (mirroring
    // ctrl_reg_r10) disambiguates. RO; V1 ties it low (bit-identical).
    output logic                    ctrl_reg_rd,
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
    //   PHY-alignment and I2C-training registers.
    //
    //   0x100: SWI_TRAINING_MODE        (RW) - [0] training-mode enable
    //   0x104: SWI_BIT_SLIP_LO          (RW) - [23:0] per-lane bit-slip
    //   0x108: SWI_LANE_STATUS          (RO) - [7:0] locked, [15:8] fault, [16] cal_done
    //   0x10C: NEGO_TRAIN_CFG           (RW) - training handshake config
    //   0x110: NEGO_TRAIN_STATUS        (RO) - training FSM status
    //   0x114: NEGO_TRAIN_STEP          (RW) - W1P single-step pulse
    //   0x118: SWI_PHASE_OFFSET         (RW) - [31:0] per-lane sub-bit phase (8 x 4-bit, §9.7)
    //   0x11C: PHY_ALIGN_ID             (RO) - 0x5041_0100
    //
    // Region 9 (paddr[8:5]=1001, offsets 0x120-0x13F): SYNC-insert TX
    //   observability (SoC Labs 2026-06-15, PART 1; RO). Routed to the chiplet
    //   controller's SYNC-OBS bank on region-select 2'b00.
    //   0x120: SYNC_OBS  (RO) - [15:0] tx_sync_ins_cnt, [16] tx_link_idle_level,
    //                            [17] tx_training_level, [31:24] 0x5C marker.
    //   V2-only data; reads 0 in V1 (region was previously RESERVED/reads-0).
    //
    // Region 10 (paddr[8:5]=1010, offsets 0x140-0x17F): Eye visibility v2.
    //   Owned by tidelink_eye_regs (instantiated in tidelink_top.sv).  As
    //   with Region 9 the parent OR-mux substitutes the shim's prdata;
    //   the local read-mux entry returns 0 / READY so a peer-aperture
    //   transaction does not see a decode hole.
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

    // mark_debug — Bug A probes per docs/ILA_PLACEMENT_AUDIT_2026_05_29.md §3.
    // pclk-domain (async to hclk u_dbg_int sampling clock) — accept CDC skew
    // for visibility of live update pattern vs polled APB snapshots.
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

    // Credit-leak fix (2026-06-12): credit_delta_data ACCUMULATES across
    // triggers while the returner has not yet captured it. Previously a
    // second trigger (returner busy / sideband backpressure) OVERWROTE the
    // unsent delta and release_acc had already been zeroed — those credits
    // were never returned to the peer (permanent leak; starvation under
    // sustained load). Capture and trigger on the same cycle: the returner
    // latched the OLD value this cycle, so load just the new delta.
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            credit_delta_data <= '0;
        else if (credit_delta_captured && release_credits_trigger)
            credit_delta_data <= effective_acc_d1;
        else if (credit_delta_captured)
            credit_delta_data <= '0;
        else if (release_credits_trigger)
            credit_delta_data <= credit_delta_data + effective_acc_d1;
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

    // Chiplet controller: Region 4 (0x080-0x09C), Region 8 (0x100-0x11C),
    // and Region C (0x180-0x19C, RO observability).
    //   ctrl_reg_addr[4:3] selects between them:
    //     2'b01 = Region 4 (apb_region == 4'b0100)
    //     2'b10 = Region 8 (apb_region == 4'b1000)
    //     2'b11 = Region C (apb_region == 4'b1100) — Bug N7/N8 silicon probes
    //   Writes to Region C are accepted at the strobe but have no
    //   effect (the controller decoder ignores any ctrl_reg_addr[4]=1
    //   writes; reads return the autoneg observability mirror).
    //
    // SoC Labs SYNC-insert TX obs 2026-06-15 (PART 1): NEW Region 9
    // (apb_region == 4'b1001, SoC 0x4403_2120-0x213C) routes the V2 SYNC-OBS
    // bank into the SAME ctrl_reg bus on the previously-unused region-select
    // ctrl_reg_addr[4:3]==2'b00 (the chiplet controller decodes 2'b00 as the
    // SYNC-OBS bank). The naive {apb_region[3:2],...} would map region 9 onto
    // 2'b10 (== Region 8) and alias it, so region 9 is special-cased to 2'b00.
    // Region 9 was RESERVED/reads-0 before, and the V1 controller ties the
    // 2'b00 bank to 0, so V1 reads of 0x2120 still return 0 (bit-identical).
    // SoC Labs perlane-wp (2026-06-16): Region 10 slots 1/2/3 (SoC 0x2144/0x2148/
    // 0x214C) are the new sweep-oracle / per-lane word-pin registers. Slot 0
    // (0x2140) stays the EPOCH_STATUS gpio_phy word (routed separately in
    // tidelink_top), so it is excluded here. The Region-10 select is a separate
    // 1-bit flag (ctrl_reg_r10) because apb_region 4'b1010 would otherwise alias
    // Region 8 on ctrl_reg_addr[4:3]==2'b10.
    // NOTE: TIDELINK_PHY_V2 is NOT visible in this file — the define is carried
    // by the per-file v2shims (src/rtl/v2shims/) which only wrap Wlink.v /
    // axi_chiplet_controller.sv / tidelink_top.sv, and apb_regs is compiled
    // BEFORE them. So region10_hit is UNCONDITIONAL here, exactly like the
    // Region 9 routing above (line ~507). V1 safety is provided downstream: the
    // controller ties region10_rdata = 0 in V1 (the read), and tidelink_top's V1
    // prdata mux lets eye_shim win Region 10 (so 0x2148 reads still hit eye_regs).
    // The ctrl_reg_write strobe that this adds for Region 10 lands on no V1
    // register (region10_write is V2-only in the controller) — inert, the same
    // as the always-routed Region 9 strobe.
    wire region10_hit = (apb_region == 4'b1010) && (paddr[4:2] != 3'h0);
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap): Region D
    // (paddr[8:5]=4'b1101, SoC 0x4403_21A0-0x4403_21BF) -> controller Region D.
    // RO observability; all 8 slots map (no slot-0 carve-out, unlike Region 10).
    wire regionD_hit = (apb_region == 4'b1101);
    assign ctrl_reg_r10   = region10_hit;
    assign ctrl_reg_rd    = regionD_hit;
    assign ctrl_reg_write = apb_write && ((apb_region == 4'b0100) ||
                                           (apb_region == 4'b1000) ||
                                           (apb_region == 4'b1001) ||
                                           (apb_region == 4'b1100) ||
                                           region10_hit ||
                                           regionD_hit);
    // Region 9, Region 10 and Region D all fold onto ctrl_reg_addr[4:3]==2'b00
    // (the controller disambiguates 10 via ctrl_reg_r10 and D via ctrl_reg_rd);
    // the slot index (paddr[4:2]) selects the word within each bank.
    assign ctrl_reg_addr  = ((apb_region == 4'b1001) || region10_hit || regionD_hit)
                                ? {2'b00, paddr[4:2]}
                                : {apb_region[3:2], paddr[4:2]};
    assign ctrl_reg_wdata = pwdata;

    // Performance profiling: Regions 5-7 (offsets 0x0A0-0x0FC).
    //   Compared against the wider region select; Region 8+ is NOT perf
    //   (it's the chiplet-extended block); guard with bounds.
    assign perf_reg_write  = apb_write && (apb_region >= 4'b0101) &&
                                          (apb_region <= 4'b0111);
    assign perf_reg_addr   = paddr[4:2];
    assign perf_reg_wdata  = pwdata;
    // Wave-0 fix #9 (2026-07-17): perf regions live at apb_region 5..7 (gated
    // above), so the 2-bit local region index must be (apb_region-5):
    //   region 5 -> 2'b00 (PERF_CTRL/TX-ts), 6 -> 2'b01, 7 -> 2'b10.
    // The old `apb_region[1:0]` mapped {5,6,7}->{01,10,11} and could NEVER
    // produce 2'b00, so PERF_CTRL (region 5, the enable/freeze/clear reg) was
    // physically UNWRITABLE and every perf counter read 0. Behaviour-neutral
    // for regions 6/7 reads; only enables PERF_CTRL writes.
    assign perf_reg_region = (apb_region - 4'd5);

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
                //   controller's read mux distinguishes Region 4 / Region 8
                //   / Region C via ctrl_reg_addr[4:3].
                prdata = ctrl_reg_rdata;
            end
            4'b1001: begin // Region 9: SYNC TX-obs + RX SYNC-DETECT + LANE_MASK (V2)
                //   SoC Labs 2026-06-15. Slot 0 (0x4403_2120) = SYNC-insert TX
                //   obs (RO, PART 1). Slot 1 (0x4403_2124) = RX mask-aware
                //   SYNC-DETECT count + per-lane sticky vector (RO, PART 1 — the
                //   key diagnostic). Slot 2 (0x4403_2128) = SW LANE_MASK for the
                //   RX detector (RW, default 0xFF, PART 3). Same ctrl_reg_rdata
                //   pass-through; the chiplet controller decodes this bank on
                //   region-select 2'b00 (ctrl_reg_addr special-cased above).
                //   V2-only data; reads 0 in V1.
                prdata = ctrl_reg_rdata;
            end
            4'b1100: begin // Region C: Autoneg silicon observability (RO)
                //   Bug N7/N8 probes — delay_ctr, timeout_ctr, init_wait,
                //   axl_state, txn_step, i2c_master STATUS. Shares the
                //   ctrl_reg_rdata pass-through bus; the chiplet
                //   controller's read mux picks Region C via
                //   ctrl_reg_addr[4:3] == 2'b11. See
                //   src/rtl/local_overrides/axi_chiplet_controller.sv
                //   "Region C — Autoneg Observability" block.
                prdata = ctrl_reg_rdata;
            end
            4'b1010: begin // Region 10: Eye visibility v2 (V1) / perlane-wp (V2)
                //   V1: read mux returns 0 — the parent (tidelink_top.sv)
                //   substitutes prdata from tidelink_eye_regs via the
                //   eye_shim_sel OR-mux.
                //   V2 (perlane-wp, 2026-06-16): the eye_regs block is absent;
                //   slots 1/2/3 (SoC 0x2144/0x2148/0x214C) carry the new sweep
                //   oracle + per-lane word-pin registers from the chiplet
                //   controller (ctrl_reg_rdata, decoded via ctrl_reg_r10). Slot 0
                //   (0x2140 = EPOCH_STATUS) is served by the gpio_phy OR-mux in
                //   tidelink_top, so it is left at 0 here.
                prdata = region10_hit ? ctrl_reg_rdata : '0;
            end
            4'b1101: begin // Region D: RX-FRAMER long-DATA STICKY CAPTURE (rxcap)
                //   SoC Labs 2026-06-21. Slots 0/1/2 (SoC 0x4403_21A0/21A4/21A8)
                //   = RXCAP0 / RXCAP1 / FCSMCAP — the die_b receiver sticky-OBS
                //   words. RO. Same ctrl_reg_rdata pass-through; the chiplet
                //   controller decodes this bank on region-select 2'b00
                //   (ctrl_reg_rd special-cased above). V2-only data; reads 0 in V1.
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
                4'b1001: begin // Region 9: SYNC TX-obs (slot0) + SYNC-DETECT
                    // (slot1) are RO; slot2 (0x4403_2128) is the RW SW LANE_MASK
                    // for the RX SYNC detector (PART 3, 2026-06-15). Writes to
                    // any other Region 9 slot raise pslverr.
                    if (pwrite && (paddr[4:2] != 3'h2)) pslverr = 1'b1;
                end
                4'b1100: begin // Region C: all slots RO (Bug N7/N8 observability)
                    if (pwrite) pslverr = 1'b1;
                end
                4'b1010: begin
                    // Region 10 owns its own pslverr (RO write + MODE=10
                    // decode-err) inside tidelink_eye_regs.  Parent OR-mux
                    // substitutes that pslverr; leave the local entry 0.
                end
                4'b1101: begin // Region D: rxcap sticky-OBS — all slots RO
                    if (pwrite) pslverr = 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule
