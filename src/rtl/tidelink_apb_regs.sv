//-----------------------------------------------------------------------------
// SoCLabs TideLink APB Register Interface
// - APB slave register block for configuration, status, token accumulators,
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

    // FIFO sideband inputs (from tidelink_fifo)
    input  logic [RAM_ADDR_W-1:0]   packet_word_length,
    input  logic [RAM_ADDR_W-2:0]   current_token_count,
    input  logic                    read_complete,

    // Returner status input (from tidelink_returner)
    input  logic                    returner_busy,

    // Returner control outputs (to tidelink top-level for returner wiring)
    output logic                    doorbell_trigger,
    output logic                    reset_deassert_pulse,
    output logic [SYS_DATA_W-1:0]   token_delta_data,
    output logic [SYS_DATA_W-1:0]   token_count_data,

    // Pair base address output (RW register, used by tidelink.sv for returner targets)
    output logic [SYS_ADDR_W-1:0]   pair_base_addr,

    // IRQ outputs
    output logic                    released_tokens_irq,
    output logic                    doorbell_irq
);

    // -------------------------------------------------------------------------
    // APB Register Map
    // -------------------------------------------------------------------------
    // Region 0 (paddr[5]=0): Configuration and Status
    //   0x000: Pair Base Address       (RW) - defaults to TIDELINK_PAIR_BASE param
    //   0x008: Packet Word Length      (RO)
    //   0x00C: Token Count             (RO)
    //   0x010: Status Register         (RO) - bit[0] returner_busy
    //   0x014: Doorbell Register       (W1C) - self-clearing pulse
    //
    // Region 1 (paddr[5]=1): Incoming Token Receivers
    //   0x020: Released Tokens Acc     (W-add / R-clear) IRQ: released_tokens_irq
    //   0x024: Doorbell Response Acc   (W-add / R-clear) IRQ: doorbell_irq
    //   0x028: Pair Token Counter      (RO)
    //   0x02C: Pair Token Consume      (WO)
    //   0x030: Pair Token Counter En   (RW) - bit[0] enable
    // -------------------------------------------------------------------------

    // APB decode
    wire apb_region = paddr[5];
    wire apb_write  = psel && penable && pwrite;
    wire apb_read   = psel && penable && !pwrite;

    // ── Region 0: Configuration Registers ───────────────────────────────────

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pair_base_addr   <= TIDELINK_PAIR_BASE;
            doorbell_trigger <= 1'b0;
        end else begin
            doorbell_trigger <= 1'b0;

            if (apb_write && !apb_region) begin
                case (paddr[4:2])
                    3'h0: pair_base_addr   <= pwdata[SYS_ADDR_W-1:0];
                    3'h5: doorbell_trigger <= 1'b1;
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

    // ── Region 1: Released Tokens Accumulator (0x020) ─────────────────────────

    logic [SYS_DATA_W-1:0] released_tokens_acc;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            released_tokens_acc <= '0;
        end else if (apb_read && apb_region && paddr[4:2] == 3'h0) begin
            released_tokens_acc <= '0;
        end else if (apb_write && apb_region && paddr[4:2] == 3'h0) begin
            released_tokens_acc <= released_tokens_acc + pwdata;
        end
    end

    assign released_tokens_irq = (released_tokens_acc != '0);

    // ── Region 1: Doorbell Response Accumulator (0x024) ───────────────────────

    logic [SYS_DATA_W-1:0] doorbell_response_acc;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            doorbell_response_acc <= '0;
        end else if (apb_read && apb_region && paddr[4:2] == 3'h1) begin
            doorbell_response_acc <= '0;
        end else if (apb_write && apb_region && paddr[4:2] == 3'h1) begin
            doorbell_response_acc <= doorbell_response_acc + pwdata;
        end
    end

    assign doorbell_irq = (doorbell_response_acc != '0);

    // ── Region 1: Pair Token Counter (0x028 / 0x02C / 0x030) ─────────────────

    logic [SYS_DATA_W-1:0] pair_token_counter;
    logic                  pair_token_counter_en;

    wire pair_counter_increment = apb_write && apb_region && paddr[4:2] == 3'h0;
    wire pair_counter_decrement = apb_write && apb_region && paddr[4:2] == 3'h3;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pair_token_counter    <= '0;
            pair_token_counter_en <= 1'b1;
        end else begin
            if (apb_write && apb_region && paddr[4:2] == 3'h4) begin
                pair_token_counter_en <= pwdata[0];
            end

            if (pair_token_counter_en) begin
                if (pair_counter_increment && pair_counter_decrement) begin
                    pair_token_counter <= pair_token_counter + pwdata - pwdata;
                end else if (pair_counter_increment) begin
                    pair_token_counter <= pair_token_counter + pwdata;
                end else if (pair_counter_decrement) begin
                    pair_token_counter <= pair_token_counter - pwdata;
                end
            end
        end
    end

    // ── APB Read Mux ──────────────────────────────────────────────────────────

    always_comb begin
        prdata = '0;
        if (apb_region) begin
            case (paddr[4:2])
                3'h0:    prdata = released_tokens_acc;
                3'h1:    prdata = doorbell_response_acc;
                3'h2:    prdata = pair_token_counter;
                3'h4:    prdata = {{(SYS_DATA_W-1){1'b0}}, pair_token_counter_en};
                default: ;
            endcase
        end else begin
            case (paddr[4:2])
                3'h0:    prdata = pair_base_addr;
                3'h2:    prdata = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length};
                3'h3:    prdata = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_token_count};
                3'h4:    prdata = {{(SYS_DATA_W-1){1'b0}}, returner_busy};
                default: ;
            endcase
        end
    end

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    // ── Token delta capture (BUG-001 fix) ─────────────────────────────────────
    // Register the delta on read_complete when packet_word_length is still valid.

    wire [SYS_DATA_W-1:0] token_delta_data_comb = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length} + SYS_DATA_W'(1);

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            token_delta_data <= '0;
        else if (read_complete)
            token_delta_data <= token_delta_data_comb;
    end

    // Total free tokens (combinational)
    assign token_count_data = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_token_count};

endmodule
