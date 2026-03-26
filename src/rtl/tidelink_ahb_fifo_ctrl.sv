//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB FIFO Control Logic
// - Manages FIFO pointers, packet metadata, token counting, and address
//   translation for the tidelink_ahb module.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_ahb_fifo_ctrl #(
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32
)(
    // Clock/Reset
    input  wire                   hclk,
    input  wire                   hresetn,

    // AHB address-phase signals
    input  wire                   hsel,
    input  wire             [1:0] htrans,
    input  wire                   hwrite,
    input  wire  [RAM_ADDR_W-1:0] haddr,
    input  wire  [SYS_DATA_W-1:0] hwdata,

    // SRAM interface signals
    input  wire  [RAM_DATA_W-1:0] rdata,         // SRAM read data
    input  wire  [RAM_ADDR_W-3:0] addr,          // Word address from cmsdk_ahb_to_sram

    // Translated address output to SRAM
    output logic [RAM_ADDR_W-3:0] translated_addr,

    // Hit and token outputs
    output wire                   write_addr_hit,
    output wire                   read_addr_hit,
    output wire  [RAM_ADDR_W-2:0] current_token_count,

    // Debug-visible state (exposed for testbench probing)
    output wire  [RAM_ADDR_W-1:0] write_ptr,
    output wire  [RAM_ADDR_W-1:0] read_ptr,
    output wire  [RAM_ADDR_W-1:0] write_target_addr,
    output wire  [RAM_ADDR_W-1:0] read_target_addr,
    output wire  [RAM_ADDR_W-1:0] packet_word_length,
    output wire  [RAM_ADDR_W-2:0] token_count
);

    localparam MAX_TOKENS = (1 << (RAM_ADDR_W - 2));

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    logic [RAM_ADDR_W-1:0] read_ptr_r,            read_ptr_nxt;
    logic [RAM_ADDR_W-1:0] write_ptr_r,           write_ptr_nxt;
    logic [RAM_ADDR_W-3:0] ptr_offset,            ptr_offset_nxt;
    logic [RAM_ADDR_W-1:0] packet_word_length_r,  packet_word_length_nxt;
    logic [RAM_ADDR_W-1:0] packet_word_count_r,   packet_word_count_nxt;
    logic                  check_addr_r,           check_addr_nxt;
    logic [RAM_ADDR_W-1:0] write_target_addr_r,   write_target_addr_nxt;
    logic [RAM_ADDR_W-1:0] read_target_addr_r,    read_target_addr_nxt;
    logic [RAM_ADDR_W-2:0] token_count_r,          token_count_nxt;

    // -------------------------------------------------------------------------
    // Shared hit-detection signals
    // -------------------------------------------------------------------------
    logic valid_transfer;
    logic write_complete;
    logic read_complete;

    assign valid_transfer = hsel && htrans[1] && (packet_word_length_r != '0);
    assign write_complete = valid_transfer && (haddr == write_target_addr_r) && hwrite;
    assign read_complete  = valid_transfer && (haddr == read_target_addr_r) && ~hwrite;

    // -------------------------------------------------------------------------
    // Pointer Management and Address Translation
    // -------------------------------------------------------------------------
    always_comb begin
        write_ptr_nxt  = write_ptr_r;
        read_ptr_nxt   = read_ptr_r;
        ptr_offset_nxt = (hwrite ? write_ptr_r : read_ptr_r) >> 2;

        if (write_complete) begin
            write_ptr_nxt = write_ptr_r + (packet_word_length_r + 1) * 4;
        end else if (read_complete) begin
            read_ptr_nxt = read_ptr_r + (packet_word_length_r + 1) * 4;
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            read_ptr_r  <= '0;
            write_ptr_r <= '0;
            ptr_offset  <= '0;
        end else begin
            read_ptr_r  <= read_ptr_nxt;
            write_ptr_r <= write_ptr_nxt;
            ptr_offset  <= ptr_offset_nxt;
        end
    end

    // translated_addr = SRAMADDR from cmsdk_ahb_to_sram + registered pointer offset
    // Both are word addresses, both pipelined by 1 cycle, so they're aligned
    assign translated_addr = addr + ptr_offset;

    // -------------------------------------------------------------------------
    // Packet Metadata Capture
    // -------------------------------------------------------------------------
    always_comb begin
        check_addr_nxt         = check_addr_r;
        packet_word_length_nxt = packet_word_length_r;
        packet_word_count_nxt  = packet_word_count_r;

        if (haddr == 0 && hwrite) begin
            packet_word_length_nxt = hwdata[RAM_ADDR_W-1:0];
        end else if (haddr == 0 && ~hwrite) begin
            check_addr_nxt = 1'b1;
        end else if (check_addr_r) begin
            packet_word_length_nxt = rdata[RAM_ADDR_W-1:0];
            check_addr_nxt = 1'b0;
        end

        // Target address = packet length in bytes (packet length in words * 4)
        write_target_addr_nxt = packet_word_length_r * 4;
        read_target_addr_nxt  = packet_word_length_r * 4;
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            packet_word_length_r <= '0;
            packet_word_count_r  <= '0;
            check_addr_r         <= 1'b0;
            write_target_addr_r  <= '0;
            read_target_addr_r   <= '0;
        end else begin
            packet_word_length_r <= packet_word_length_nxt;
            packet_word_count_r  <= packet_word_count_nxt;
            check_addr_r         <= check_addr_nxt;
            write_target_addr_r  <= write_target_addr_nxt;
            read_target_addr_r   <= read_target_addr_nxt;
        end
    end

    // -------------------------------------------------------------------------
    // Hit Signal Outputs
    // -------------------------------------------------------------------------
    assign write_addr_hit = (haddr == write_target_addr_r) && (packet_word_length_r != '0);
    assign read_addr_hit  = (haddr == read_target_addr_r)  && (packet_word_length_r != '0);

    // -------------------------------------------------------------------------
    // Token Counter
    // -------------------------------------------------------------------------
    always_comb begin
        token_count_nxt = token_count_r;
        if (write_complete) begin
            token_count_nxt = token_count_r - (packet_word_length_r + 1);
        end else if (read_complete) begin
            token_count_nxt = token_count_r + (packet_word_length_r + 1);
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            token_count_r <= MAX_TOKENS;
        end else begin
            token_count_r <= token_count_nxt;
        end
    end

    assign current_token_count = token_count_r;

    // -------------------------------------------------------------------------
    // Debug-visible output assignments
    // -------------------------------------------------------------------------
    assign write_ptr          = write_ptr_r;
    assign read_ptr           = read_ptr_r;
    assign write_target_addr  = write_target_addr_r;
    assign read_target_addr   = read_target_addr_r;
    assign packet_word_length = packet_word_length_r;
    assign token_count        = token_count_r;

endmodule
