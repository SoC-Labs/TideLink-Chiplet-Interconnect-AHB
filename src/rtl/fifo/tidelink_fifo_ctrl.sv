//-----------------------------------------------------------------------------
// SoCLabs TideLink FIFO Control Logic
// - Manages FIFO pointers, packet metadata, credit counting, and address
//   translation for the tidelink_fifo module.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_fifo_ctrl #(
    parameter RAM_ADDR_W = 14
)(
    // Clock/Reset
    input  wire                   hclk,
    input  wire                   hresetn,

    // AHB address-phase signals
    input  wire                   hsel,
    // hal lint_off USEPRT
    input  wire             [1:0] htrans,        // Only htrans[1] used for transfer detection
    // hal lint_on USEPRT
    input  wire                   hready,
    input  wire                   hwrite,
    input  wire  [RAM_ADDR_W-1:0] haddr,
    input  wire  [RAM_ADDR_W-1:0] hwdata,         // Only packet-length bits used

    // SRAM interface signals
    input  wire  [RAM_ADDR_W-1:0] rdata,          // Only packet-length bits used
    input  wire  [RAM_ADDR_W-3:0] addr,          // Word address from cmsdk_ahb_to_sram

    // Translated address outputs
    output logic [RAM_ADDR_W-3:0] translated_addr,      // Word address for SRAM
    output logic [RAM_ADDR_W-1:0] translated_haddr,     // Byte address for cmsdk_ahb_to_sram

    // Completion pulses (directly drive returner interrupt)
    output wire                   read_complete,

    // Credit count output
    output wire  [RAM_ADDR_W-2:0] current_credit_count,

    // Debug-visible state (exposed for testbench probing)
    output wire  [RAM_ADDR_W-1:0] write_ptr,
    output wire  [RAM_ADDR_W-1:0] read_ptr,
    output wire  [RAM_ADDR_W-1:0] write_target_addr,
    output wire  [RAM_ADDR_W-1:0] read_target_addr,
    output wire  [RAM_ADDR_W-1:0] packet_word_length,
    output wire  [RAM_ADDR_W-2:0] credit_count,

    // Interrupt: asserts when a packet is committed to the FIFO, clears on
    // first read from address 0 (recipient starts reading the packet)
    output wire                   packet_committed_irq,

    // Sticky error flags (cleared by flush)
    output wire                   overrun,        // Write discarded (buffer full)
    output wire                   underrun,       // Read with no packet available

    // Control inputs
    input  wire                   enable,         // EN gate: 1 = data window active
    input  wire                   flush           // Self-clearing flush: resets pointers/counters/errors
);

    localparam MAX_CREDITS = (1 << (RAM_ADDR_W - 2));

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    logic [RAM_ADDR_W-1:0] read_ptr_r,            read_ptr_nxt;
    logic [RAM_ADDR_W-1:0] write_ptr_r,           write_ptr_nxt;
    logic [RAM_ADDR_W-1:0] packet_word_length_r,  packet_word_length_nxt;
    logic                  check_addr_r,           check_addr_nxt;
    logic [RAM_ADDR_W-1:0] write_target_addr_r,   write_target_addr_nxt;
    logic [RAM_ADDR_W-1:0] read_target_addr_r,    read_target_addr_nxt;
    logic [RAM_ADDR_W-2:0] credit_count_r,          credit_count_nxt;

    // -------------------------------------------------------------------------
    // Shared completion signals (gated on hready for correct AHB handshake)
    // -------------------------------------------------------------------------
    logic valid_transfer;
    logic write_complete;

    assign valid_transfer = hsel && htrans[1] && hready && enable && (packet_word_length_r != '0);
    assign write_complete = valid_transfer && (haddr == write_target_addr_r) && hwrite;
    assign read_complete  = valid_transfer && (haddr == read_target_addr_r)  && ~hwrite;

    // -------------------------------------------------------------------------
    // Pointer Management and Address Translation
    // -------------------------------------------------------------------------
    always_comb begin
        write_ptr_nxt  = write_ptr_r;
        read_ptr_nxt   = read_ptr_r;

        if (write_complete) begin
            write_ptr_nxt = write_ptr_r + RAM_ADDR_W'((packet_word_length_r + RAM_ADDR_W'(1'd1)) * RAM_ADDR_W'(4'd4));
        end else if (read_complete) begin
            read_ptr_nxt = read_ptr_r + RAM_ADDR_W'((packet_word_length_r + RAM_ADDR_W'(1'd1)) * RAM_ADDR_W'(4'd4));
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            read_ptr_r  <= '0;
            write_ptr_r <= '0;
        end else if (flush) begin
            read_ptr_r  <= '0;
            write_ptr_r <= '0;
        end else begin
            read_ptr_r  <= read_ptr_nxt;
            write_ptr_r <= write_ptr_nxt;
        end
    end

    // Since cmsdk_ahb_to_sram now receives translated_haddr, its SRAMADDR
    // output (addr) is already in translated space — pass it through directly
    assign translated_addr = addr;

    // Combinational translated byte address for cmsdk_ahb_to_sram
    // This ensures buf_addr and buf_hit work in translated address space,
    // preventing false read-after-write merges across different packets
    assign translated_haddr = haddr + (hwrite ? write_ptr_r : read_ptr_r);

    // -------------------------------------------------------------------------
    // Packet Metadata Capture
    // -------------------------------------------------------------------------
    // Valid AHB access to address 0 (gated on hsel, htrans, hready)
    wire valid_ahb_access = hsel && htrans[1] && hready && enable;

    // Registered flag: a valid write to addr 0 occurred in the address phase.
    // hwdata is only valid in the DATA phase (one cycle later in AHB protocol),
    // so we capture it on the next cycle.
    logic capture_write_length_r, capture_write_length_nxt;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            capture_write_length_r <= 1'b0;
        end else if (flush) begin
            capture_write_length_r <= 1'b0;
        end else begin
            capture_write_length_r <= capture_write_length_nxt;
        end
    end

    always_comb begin
        check_addr_nxt           = check_addr_r;
        packet_word_length_nxt   = packet_word_length_r;
        capture_write_length_nxt = valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && hwrite;

        // Clear packet_word_length and check_addr on completion so stale
        // target addresses don't cause spurious hits and check_addr doesn't
        // capture stale rdata on the next cycle (BUG-005 fix)
        if (write_complete || read_complete) begin
            packet_word_length_nxt = '0;
            check_addr_nxt = 1'b0;
        end else if (capture_write_length_r) begin
            // Data phase of write to addr 0: hwdata is now valid
            packet_word_length_nxt = hwdata;
        end else if (valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && ~hwrite) begin
            // Read from addr 0: set flag to capture length from SRAM next cycle
            check_addr_nxt = 1'b1;
        end else if (check_addr_r) begin
            // Capture SRAM read data as packet length, clear flag
            packet_word_length_nxt = rdata;
            check_addr_nxt = 1'b0;
        end

        // Target address = packet length in bytes (packet length in words * 4)
        write_target_addr_nxt = packet_word_length_r * RAM_ADDR_W'(4'd4);
        read_target_addr_nxt  = packet_word_length_r * RAM_ADDR_W'(4'd4);
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            packet_word_length_r <= '0;
            check_addr_r         <= 1'b0;
            write_target_addr_r  <= '0;
            read_target_addr_r   <= '0;
        end else if (flush) begin
            packet_word_length_r <= '0;
            check_addr_r         <= 1'b0;
            write_target_addr_r  <= '0;
            read_target_addr_r   <= '0;
        end else begin
            packet_word_length_r <= packet_word_length_nxt;
            check_addr_r         <= check_addr_nxt;
            write_target_addr_r  <= write_target_addr_nxt;
            read_target_addr_r   <= read_target_addr_nxt;
        end
    end

    // -------------------------------------------------------------------------
    // Credit Counter
    // -------------------------------------------------------------------------
    always_comb begin
        credit_count_nxt = credit_count_r;
        if (write_complete) begin
            credit_count_nxt = credit_count_r - (RAM_ADDR_W-1)'(packet_word_length_r + RAM_ADDR_W'(1'd1));
        end else if (read_complete) begin
            credit_count_nxt = credit_count_r + (RAM_ADDR_W-1)'(packet_word_length_r + RAM_ADDR_W'(1'd1));
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            credit_count_r <= (RAM_ADDR_W-1)'(unsigned'(MAX_CREDITS));
        end else if (flush) begin
            credit_count_r <= (RAM_ADDR_W-1)'(unsigned'(MAX_CREDITS));
        end else begin
            credit_count_r <= credit_count_nxt;
        end
    end

    assign current_credit_count = credit_count_r;

    // -------------------------------------------------------------------------
    // Packet Committed IRQ
    // -------------------------------------------------------------------------
    // Set when write_complete fires (packet fully written to FIFO).
    // Cleared when recipient reads FIFO address 0 (start of packet read).
    logic packet_committed_irq_r, packet_committed_irq_nxt;

    always_comb begin
        packet_committed_irq_nxt = packet_committed_irq_r;
        if (write_complete) begin
            packet_committed_irq_nxt = 1'b1;
        end else if (valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && ~hwrite) begin
            packet_committed_irq_nxt = 1'b0;
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            packet_committed_irq_r <= 1'b0;
        end else if (flush) begin
            packet_committed_irq_r <= 1'b0;
        end else begin
            packet_committed_irq_r <= packet_committed_irq_nxt;
        end
    end

    assign packet_committed_irq = packet_committed_irq_r;

    // -------------------------------------------------------------------------
    // Overrun / Underrun Sticky Error Flags
    // -------------------------------------------------------------------------
    // OVERRUN: set when a valid AHB write occurs but the buffer is full
    //          (credit_count_r == 0). The write data is silently discarded.
    // UNDERRUN: set when a valid AHB read occurs but no packet is available
    //           (credit_count_r == MAX_CREDITS, i.e. buffer empty).
    // Both are sticky — once set, they remain set until cleared by FLUSH.

    logic overrun_r, underrun_r;

    wire overrun_event  = hsel && htrans[1] && hready && enable && hwrite
                          && (credit_count_r == '0);
    wire underrun_event = hsel && htrans[1] && hready && enable && ~hwrite
                          && (credit_count_r == (RAM_ADDR_W-1)'(unsigned'(MAX_CREDITS)));

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            overrun_r  <= 1'b0;
            underrun_r <= 1'b0;
        end else if (flush) begin
            overrun_r  <= 1'b0;
            underrun_r <= 1'b0;
        end else begin
            if (overrun_event)  overrun_r  <= 1'b1;
            if (underrun_event) underrun_r <= 1'b1;
        end
    end

    assign overrun  = overrun_r;
    assign underrun = underrun_r;

    // -------------------------------------------------------------------------
    // Debug-visible output assignments
    // -------------------------------------------------------------------------
    assign write_ptr          = write_ptr_r;
    assign read_ptr           = read_ptr_r;
    assign write_target_addr  = write_target_addr_r;
    assign read_target_addr   = read_target_addr_r;
    assign packet_word_length = packet_word_length_r;
    assign credit_count        = credit_count_r;

endmodule
