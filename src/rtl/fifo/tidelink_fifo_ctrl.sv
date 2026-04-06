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
    input  wire                   flush,          // Self-clearing flush: resets pointers/counters/errors

    // FC direct write interface (single-cycle addr+data, bypasses AHB)
    input  wire                   fc_wr_valid,
    input  wire                   fc_wr_write,
    input  wire  [RAM_ADDR_W-1:0] fc_wr_addr,
    input  wire  [RAM_ADDR_W-1:0] fc_wr_wdata,    // Only packet-length bits used

    // FC translated write address output (byte address with write_ptr offset)
    output wire  [RAM_ADDR_W-1:0] fc_translated_addr
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

    // Shared intermediate: packet length + 1 (word count including metadata)
    wire [RAM_ADDR_W-1:0] packet_delta = packet_word_length_r + RAM_ADDR_W'(1'd1);

    // -------------------------------------------------------------------------
    // Completion signals — dual-source (FC direct write + AHB read/write)
    // -------------------------------------------------------------------------
    logic write_complete;

    // FC direct write completion (single-cycle, addr+data in same cycle)
    wire fc_write_valid = fc_wr_valid && fc_wr_write && (packet_word_length_r != '0);
    wire fc_write_complete = fc_write_valid && (fc_wr_addr == write_target_addr_r);

    // AHB path completion (preserved for CPU reads + testbench backward compat)
    // Shortcoming #14 fix: check htrans == NONSEQ (2'b10), rejecting SEQ (2'b11)
    // beats from burst transfers which the FIFO logic cannot handle correctly.
    wire ahb_valid_transfer = hsel && (htrans == 2'b10) && hready && (packet_word_length_r != '0);
    wire ahb_write_complete = ahb_valid_transfer && (haddr == write_target_addr_r) && hwrite;

    assign write_complete = fc_write_complete || ahb_write_complete;
    assign read_complete  = ahb_valid_transfer && (haddr == read_target_addr_r) && ~hwrite;

    // -------------------------------------------------------------------------
    // Pointer Management and Address Translation
    // -------------------------------------------------------------------------
    always_comb begin
        write_ptr_nxt  = write_ptr_r;
        read_ptr_nxt   = read_ptr_r;

        if (write_complete) begin
            write_ptr_nxt = write_ptr_r + RAM_ADDR_W'(packet_delta << 2);
        end else if (read_complete) begin
            read_ptr_nxt = read_ptr_r + RAM_ADDR_W'(packet_delta << 2);
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

    // AHB path: translated byte address for cmsdk_ahb_to_sram (CPU reads + legacy writes)
    assign translated_haddr = haddr + (hwrite ? write_ptr_r : read_ptr_r);

    // FC direct write path: translated byte address (write_ptr offset applied)
    assign fc_translated_addr = fc_wr_addr + write_ptr_r;

    // -------------------------------------------------------------------------
    // Packet Metadata Capture — Dual Source
    // -------------------------------------------------------------------------
    // FC direct writes deliver addr+data in the same cycle (same-cycle capture).
    // AHB writes use the standard 2-phase protocol (pipelined capture).
    // AHB reads use check_addr_r to capture length from SRAM read data.

    // Shortcoming #14 fix: NONSEQ only (htrans == 2'b10), reject SEQ bursts
    wire valid_ahb_access = hsel && (htrans == 2'b10) && hready;

    // FC write to addr 0: same-cycle length capture
    wire fc_write_addr0 = fc_wr_valid && fc_wr_write && (fc_wr_addr == '0);

    // AHB write pipeline: addr phase detection → data phase capture
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

    // Shortcoming #3: maximum valid packet word length (total_words = length + 1 <= MAX_CREDITS)
    localparam [RAM_ADDR_W-1:0] MAX_PACKET_LEN = RAM_ADDR_W'(MAX_CREDITS - 1);

    // Clamp a raw length value to MAX_PACKET_LEN
    function automatic [RAM_ADDR_W-1:0] clamp_length(input [RAM_ADDR_W-1:0] raw);
        clamp_length = (raw > MAX_PACKET_LEN) ? MAX_PACKET_LEN : raw;
    endfunction

    always_comb begin
        check_addr_nxt           = check_addr_r;
        packet_word_length_nxt   = packet_word_length_r;
        capture_write_length_nxt = valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && hwrite;

        // Clear packet_word_length and check_addr on completion (BUG-005 fix)
        if (write_complete || read_complete) begin
            packet_word_length_nxt = '0;
            check_addr_nxt = 1'b0;
        end else if (fc_write_addr0) begin
            // FC direct write to addr 0: capture length immediately (same cycle)
            // Shortcoming #3 fix: clamp to prevent SRAM boundary overrun
            packet_word_length_nxt = clamp_length(fc_wr_wdata);
        end else if (capture_write_length_r) begin
            // AHB data phase of write to addr 0: hwdata is now valid
            // Shortcoming #3 fix: clamp to prevent SRAM boundary overrun
            packet_word_length_nxt = clamp_length(hwdata);
        end else if (valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && ~hwrite) begin
            // AHB read from addr 0: set flag to capture length from SRAM next cycle
            check_addr_nxt = 1'b1;
        end else if (check_addr_r) begin
            // Capture SRAM read data as packet length, clear flag
            // Shortcoming #3 fix: clamp to prevent SRAM boundary overrun
            packet_word_length_nxt = clamp_length(rdata);
            check_addr_nxt = 1'b0;
        end

        // Target address = packet length in bytes (packet length in words << 2)
        // Use _nxt value to eliminate 1-cycle lag when loading from SRAM read
        write_target_addr_nxt = RAM_ADDR_W'(packet_word_length_nxt << 2);
        read_target_addr_nxt  = RAM_ADDR_W'(packet_word_length_nxt << 2);
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
            // BUG-002 fix: saturate at zero to prevent unsigned underflow wrap
            if (credit_count_r >= (RAM_ADDR_W-1)'(packet_delta))
                credit_count_nxt = credit_count_r - (RAM_ADDR_W-1)'(packet_delta);
            else
                credit_count_nxt = '0;
        end else if (read_complete) begin
            credit_count_nxt = credit_count_r + (RAM_ADDR_W-1)'(packet_delta);
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

    wire overrun_event  = ((fc_wr_valid && fc_wr_write) ||
                           (hsel && (htrans == 2'b10) && hready && hwrite))
                          && (credit_count_r == '0);
    wire underrun_event = hsel && (htrans == 2'b10) && hready && ~hwrite
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
