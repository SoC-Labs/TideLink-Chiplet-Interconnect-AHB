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
    parameter APB_ADDR_W = 12
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
    output logic                    apbs_pslverr
);

    // --------------------------------------------------------------------------
    // Internal Wiring
    // --------------------------------------------------------------------------

    // TideLink AHB FIFO status and sideband signals
    logic                  write_addr_hit;
    logic                  read_addr_hit;
    logic [RAM_ADDR_W-2:0] current_token_count;
    logic [RAM_ADDR_W-1:0] packet_word_length;

    // TideLink AHB Returner status
    logic                   returner_busy;

    // --------------------------------------------------------------------------
    // APB Register Map
    // --------------------------------------------------------------------------
    // Offset 0x000: Release Tokens Address (RW) - target for token count on read completion
    // Offset 0x004: Doorbell Target Address (RW) - target for token count on doorbell
    // Offset 0x008: Packet Word Length      (RO) - sideband from FIFO
    // Offset 0x00C: Token Count             (RO) - current total token count
    // Offset 0x010: Status Register         (RO)
    //               [0] write_addr_hit
    //               [1] read_addr_hit
    //               [2] returner_busy
    // Offset 0x014: Doorbell Register       (W1C) - write any value to trigger doorbell
    // --------------------------------------------------------------------------

    logic [SYS_DATA_W-1:0] reg_release_tokens_addr;
    logic [SYS_DATA_W-1:0] reg_doorbell_addr;
    logic                  doorbell_trigger;

    // APB write logic
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            reg_release_tokens_addr <= '0;
            reg_doorbell_addr       <= '0;
            doorbell_trigger        <= 1'b0;
        end else begin
            // Doorbell is a self-clearing pulse — deassert after one cycle
            doorbell_trigger <= 1'b0;

            if (apbs_psel && apbs_penable && apbs_pwrite) begin
                case (apbs_paddr[4:2])
                    3'h0: reg_release_tokens_addr <= apbs_pwdata;
                    3'h1: reg_doorbell_addr       <= apbs_pwdata;
                    3'h5: doorbell_trigger        <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // APB read logic
    always_comb begin
        case (apbs_paddr[4:2])
            3'h0:    apbs_prdata = reg_release_tokens_addr;
            3'h1:    apbs_prdata = reg_doorbell_addr;
            3'h2:    apbs_prdata = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length};
            3'h3:    apbs_prdata = {{(SYS_DATA_W-RAM_ADDR_W+1){1'b0}}, current_token_count};
            3'h4:    apbs_prdata = {{(SYS_DATA_W-3){1'b0}}, returner_busy, read_addr_hit, write_addr_hit};
            3'h5:    apbs_prdata = '0; // Doorbell register reads as 0
            default: apbs_prdata = '0;
        endcase
    end

    // APB always ready, no errors
    assign apbs_pready  = 1'b1;
    assign apbs_pslverr = 1'b0;

    // Sideband wiring to returner
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
        .write_addr_hit         (write_addr_hit),
        .read_addr_hit          (read_addr_hit),
        .current_token_count    (current_token_count),
        .packet_word_length_out (packet_word_length)
    );

    // --------------------------------------------------------------------------
    // TideLink AHB Returner Instance
    // --------------------------------------------------------------------------
    // Channel 0 (priority): release tokens on read completion
    // Channel 1: doorbell — software-triggered via APB register write
    tidelink_ahb_returner #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
    ) u_tidelink_ahb_returner (
        .hclk        (hclk),
        .hresetn     (hresetn),

        // Channel 0: release tokens (read_addr_hit → write token count)
        .interrupt_0 (read_addr_hit),
        .write_addr_0(reg_release_tokens_addr[SYS_ADDR_W-1:0]),
        .write_data_0(token_count_data),

        // Channel 1: doorbell (software trigger → write token count)
        .interrupt_1 (doorbell_trigger),
        .write_addr_1(reg_doorbell_addr[SYS_ADDR_W-1:0]),
        .write_data_1(token_count_data),

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
