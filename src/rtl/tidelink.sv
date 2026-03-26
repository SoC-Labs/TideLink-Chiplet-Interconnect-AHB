//-----------------------------------------------------------------------------
// SoCLabs TideLink Top-Level Module
// - Wraps a TideLink AHB FIFO (AHB slave), a TideLink AHB Returner
//   (AHB master), and an APB slave register interface for configuration
//   and status.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0  // APB base address of the paired tidelink
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  logic                    hclk,
    input  logic                    hresetn,

    // --------------------------------------------------------------------------
    // AHB Slave Interface (to TideLink AHB FIFO)
    // --------------------------------------------------------------------------
    input  logic                    ahbs_hsel,
    input  logic                    ahbs_hready,
    input  logic              [1:0] ahbs_htrans,
    input  logic              [2:0] ahbs_hsize,
    input  logic                    ahbs_hwrite,
    input  logic   [RAM_ADDR_W-1:0] ahbs_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbs_hwdata,
    output logic                    ahbs_hreadyout,
    output logic                    ahbs_hresp,
    output logic   [SYS_DATA_W-1:0] ahbs_hrdata,

    // --------------------------------------------------------------------------
    // AHB Master Interface (from TideLink AHB Returner)
    // --------------------------------------------------------------------------
    output logic   [SYS_ADDR_W-1:0] ahbm_haddr,
    output logic   [SYS_DATA_W-1:0] ahbm_hwdata,
    output logic              [1:0] ahbm_htrans,
    output logic              [2:0] ahbm_hsize,
    output logic                    ahbm_hwrite,
    input  logic                    ahbm_hready,
    input  logic                    ahbm_hresp,
    input  logic   [SYS_DATA_W-1:0] ahbm_hrdata,

    // --------------------------------------------------------------------------
    // APB Slave Interface (Configuration and Status Registers)
    // --------------------------------------------------------------------------
    input  logic                    apbs_psel,
    input  logic                    apbs_penable,
    input  logic                    apbs_pwrite,
    input  logic   [APB_ADDR_W-1:0] apbs_paddr,
    input  logic   [SYS_DATA_W-1:0] apbs_pwdata,
    output logic   [SYS_DATA_W-1:0] apbs_prdata,
    output logic                    apbs_pready,
    output logic                    apbs_pslverr,

    // --------------------------------------------------------------------------
    // Interrupt Output (released tokens notification to CPU)
    // --------------------------------------------------------------------------
    output logic                    released_tokens_irq
);

    // --------------------------------------------------------------------------
    // Internal Wiring
    // --------------------------------------------------------------------------

    // TideLink AHB FIFO status and sideband signals
    logic                  read_complete;
    logic [RAM_ADDR_W-2:0] current_token_count;
    logic [RAM_ADDR_W-1:0] packet_word_length;

    // TideLink AHB Returner status
    logic                   returner_busy;

    // --------------------------------------------------------------------------
    // APB Register Map
    // --------------------------------------------------------------------------
    // Region 0 (paddr[5]=0): Configuration and Status
    //   Offset 0x000: Pair Base Address       (RO) - TIDELINK_PAIR_BASE parameter
    //   Offset 0x004: (reserved)
    //   Offset 0x008: Packet Word Length      (RO) - sideband from FIFO
    //   Offset 0x00C: Token Count             (RO) - current total token count
    //   Offset 0x010: Status Register         (RO)
    //                 [0] returner_busy
    //   Offset 0x014: Doorbell Register       (W1C) - write any value to trigger doorbell
    //
    // Region 1 (paddr[5]=1): Released Tokens Receiver
    //   Offset 0x020: Released Tokens Accumulator (W-add / R-clear)
    //                 Write: value is ADDED to accumulator (from remote tidelink returner)
    //                 Read:  returns accumulated total, then clears counter and interrupt
    // --------------------------------------------------------------------------

    // Paired tidelink's target addresses (derived from parameter)
    localparam [SYS_ADDR_W-1:0] PAIR_RELEASED_TOKENS_ADDR = TIDELINK_PAIR_BASE + SYS_ADDR_W'('h20); // Region 1: accumulator
    localparam [SYS_ADDR_W-1:0] PAIR_DOORBELL_ADDR        = TIDELINK_PAIR_BASE + SYS_ADDR_W'('h14); // Region 0: doorbell

    // Region select
    wire apb_region = apbs_paddr[5];
    wire apb_write  = apbs_psel && apbs_penable && apbs_pwrite;
    wire apb_read   = apbs_psel && apbs_penable && !apbs_pwrite;

    // ── Region 0: Configuration and Status Registers ────────────────────────

    logic doorbell_trigger;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            doorbell_trigger <= 1'b0;
        end else begin
            // Doorbell is a self-clearing pulse — deassert after one cycle
            doorbell_trigger <= 1'b0;

            if (apb_write && !apb_region) begin
                case (apbs_paddr[4:2])
                    3'h5: doorbell_trigger <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // ── Reset deassertion detector ──────────────────────────────────────────
    // Generates a one-cycle pulse when hresetn transitions from 0 to 1.
    // On this pulse, the returner rings the paired tidelink's doorbell so
    // the pair responds with its total free token count.

    logic reset_n_d1, reset_n_d2;
    wire  reset_deassert_pulse = reset_n_d1 & ~reset_n_d2;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            reset_n_d1 <= 1'b0;
            reset_n_d2 <= 1'b0;
        end else begin
            reset_n_d1 <= 1'b1;
            reset_n_d2 <= reset_n_d1;
        end
    end

    // ── Region 1: Released Tokens Receiver ──────────────────────────────────
    // Another tidelink's returner writes token counts here via the bus fabric.
    // Values accumulate. The first arrival asserts released_tokens_irq.
    // A CPU read returns the total and clears both counter and interrupt.

    logic [SYS_DATA_W-1:0] released_tokens_acc;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            released_tokens_acc <= '0;
        end else if (apb_read && apb_region && apbs_paddr[4:2] == 3'h0) begin
            // Read-to-clear: CPU reads the accumulator → reset to 0
            released_tokens_acc <= '0;
        end else if (apb_write && apb_region && apbs_paddr[4:2] == 3'h0) begin
            // Write-to-add: incoming token count is added to accumulator
            released_tokens_acc <= released_tokens_acc + apbs_pwdata;
        end
    end

    // Interrupt: asserted when accumulator is non-zero (tokens have been released)
    // Cleared automatically when CPU reads the accumulator (read-to-clear)
    assign released_tokens_irq = (released_tokens_acc != '0);

    // ── APB Read Mux ────────────────────────────────────────────────────────

    always_comb begin
        apbs_prdata = '0;
        if (apb_region) begin
            // Region 1: Released Tokens Receiver
            case (apbs_paddr[4:2])
                3'h0:    apbs_prdata = released_tokens_acc;
                default: ;
            endcase
        end else begin
            // Region 0: Configuration and Status
            case (apbs_paddr[4:2])
                3'h0:    apbs_prdata = TIDELINK_PAIR_BASE;
                3'h2:    apbs_prdata = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length};
                3'h3:    apbs_prdata = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_token_count};
                3'h4:    apbs_prdata = {{(SYS_DATA_W-1){1'b0}}, returner_busy};
                default: ;
            endcase
        end
    end

    // APB always ready, no errors
    assign apbs_pready  = 1'b1;
    assign apbs_pslverr = 1'b0;

    // Sideband wiring to returner
    // Delta: tokens freed by the last completed read (packet_word_length + 1 for the length word)
    wire [SYS_DATA_W-1:0] token_delta_data = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length} + 1;
    // Total: all currently free tokens
    wire [SYS_DATA_W-1:0] token_count_data = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_token_count};

    // --------------------------------------------------------------------------
    // TideLink AHB FIFO Instance
    // --------------------------------------------------------------------------
    tidelink_ahb #(
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .RAM_DATA_W (RAM_DATA_W)
    ) u_tidelink_ahb (
        .hclk                   (hclk),
        .hresetn                (hresetn),
        .hsel                   (ahbs_hsel),
        .hready                 (ahbs_hready),
        .htrans                 (ahbs_htrans),
        .hsize                  (ahbs_hsize),
        .hwrite                 (ahbs_hwrite),
        .haddr                  (ahbs_haddr),
        .hwdata                 (ahbs_hwdata),
        .hreadyout              (ahbs_hreadyout),
        .hresp                  (ahbs_hresp),
        .hrdata                 (ahbs_hrdata),
        .read_complete          (read_complete),
        .current_token_count    (current_token_count),
        .packet_word_length_out (packet_word_length)
    );

    // --------------------------------------------------------------------------
    // TideLink AHB Returner Instance
    // --------------------------------------------------------------------------
    // Channel 0 (highest priority): release tokens on read completion
    //   → writes DELTA (tokens freed by this read) to pair's accumulator
    // Channel 1: doorbell — triggered by software OR by pair's reset
    //   → writes TOTAL free tokens to pair's accumulator
    // Channel 2 (lowest priority): reset doorbell — fires on reset deassertion
    //   → rings pair's doorbell register so pair responds with its total free tokens
    tidelink_ahb_returner #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
    ) u_tidelink_ahb_returner (
        .hclk        (hclk),
        .hresetn     (hresetn),

        // Channel 0: release tokens (read_complete → write delta to pair's accumulator)
        .interrupt_0 (read_complete),
        .write_addr_0(PAIR_RELEASED_TOKENS_ADDR),
        .write_data_0(token_delta_data),

        // Channel 1: doorbell (triggered → write total free tokens to pair's accumulator)
        .interrupt_1 (doorbell_trigger),
        .write_addr_1(PAIR_RELEASED_TOKENS_ADDR),
        .write_data_1(token_count_data),

        // Channel 2: reset doorbell (reset deassertion → ring pair's doorbell)
        .interrupt_2 (reset_deassert_pulse),
        .write_addr_2(PAIR_DOORBELL_ADDR),
        .write_data_2(32'h1),

        // AHB Master
        .haddr       (ahbm_haddr),
        .hwdata      (ahbm_hwdata),
        .htrans      (ahbm_htrans),
        .hsize       (ahbm_hsize),
        .hwrite      (ahbm_hwrite),
        .hready      (ahbm_hready),
        .hresp       (ahbm_hresp),
        .hrdata      (ahbm_hrdata),
        .busy        (returner_busy)
    );

endmodule
