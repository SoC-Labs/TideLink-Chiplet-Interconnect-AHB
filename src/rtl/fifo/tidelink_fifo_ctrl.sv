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
    parameter RAM_ADDR_W = 14,
    // PENDING-DECISION #1 — RX-FIFO TWIN 2 (chip-killer, 2026-07-16).
    //   1'b1 (default) = current behaviour, BIT-IDENTICAL to today: an AHB
    //         NONSEQ write to this RX FIFO arms the write-side packet length
    //         latch (capture_write_length) and can complete a write
    //         (ahb_write_complete), advancing the FC-SHARED write_ptr and
    //         burning credit. There is NO supported CPU-write-to-RX path in the
    //         product (RX FIFO is filled by the peer over the FC direct-write
    //         port only), so any stray AHB write to offset 0/4 — a clear, a
    //         probe, a mis-decoded access — walks write_ptr and mis-frames the
    //         NEXT genuine FC packet. See sim proof in cocotb/tidelink_fifo_twin2.
    //   1'b0 = ASIC posture: the RX FIFO is FC-write-only. The AHB write-side
    //         length latch AND the AHB write-completion are disabled, so the
    //         write_ptr/credit can ONLY be advanced by the FC direct-write path.
    //         AHB READS (the CPU draining the FIFO) are untouched.
    // The gate is a parameter-constant AND, so it constant-folds at elaboration
    // (1'b1 => the historical expression, no added logic).
    parameter bit ENABLE_AHB_WRITE = 1'b1
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
    logic                  packet_active_r,        packet_active_nxt;
    logic [RAM_ADDR_W-1:0] write_target_addr_r,   write_target_addr_nxt;
    logic [RAM_ADDR_W-1:0] read_target_addr_r,    read_target_addr_nxt;
    logic [RAM_ADDR_W-2:0] credit_count_r,          credit_count_nxt;

    // Shared intermediate: payload length + 2 (2-word header + N payload words)
    wire [RAM_ADDR_W-1:0] packet_delta = packet_word_length_r + RAM_ADDR_W'(2'd2);

    // Credit + delta at FULL RAM_ADDR_W width, for the saturate-at-MAX compare
    // in the credit counter below. credit_count_r <= 2^13-1 and packet_delta
    // <= 2^12, so this cannot overflow RAM_ADDR_W=14 bits. Declared at module
    // scope (not inside the always_comb): a declaration in an unnamed
    // procedural block is not portable across synthesis tools, and this file is
    // compiled by both the FPGA and the ASIC flows.
    wire [RAM_ADDR_W-1:0] credit_sum = RAM_ADDR_W'(credit_count_r) + packet_delta;

    // RX FIFO is EMPTY iff no credit has been consumed. This is the SAME predicate
    // the sticky `underrun` flag already uses (see underrun_event below) — reuse it
    // rather than invent a second notion of emptiness.
    wire rx_fifo_empty = (credit_count_r == (RAM_ADDR_W-1)'(unsigned'(MAX_CREDITS)));

    // -------------------------------------------------------------------------
    // Completion signals — dual-source (FC direct write + AHB read/write)
    // -------------------------------------------------------------------------
    logic write_complete;

    // FC direct write completion (single-cycle, addr+data in same cycle)
    wire fc_write_valid = fc_wr_valid && fc_wr_write && packet_active_r;
    wire fc_write_complete = fc_write_valid && (fc_wr_addr == write_target_addr_r);

    // AHB path completion (preserved for CPU reads + testbench backward compat)
    // Shortcoming #14 fix: check htrans == NONSEQ (2'b10), rejecting SEQ (2'b11)
    // beats from burst transfers which the FIFO logic cannot handle correctly.
    wire ahb_valid_transfer = hsel && (htrans == 2'b10) && hready && packet_active_r;
    // PENDING-DECISION #1: AHB write-completion gated. ENABLE_AHB_WRITE=0 makes
    // the FC-shared write_ptr / credit un-advanceable from the AHB write side.
    wire ahb_write_complete = ENABLE_AHB_WRITE && ahb_valid_transfer && (haddr == write_target_addr_r) && hwrite;

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

    // Maximum payload length: total_words = length + 2 <= MAX_CREDITS (2-word header)
    localparam [RAM_ADDR_W-1:0] MAX_PACKET_LEN = RAM_ADDR_W'(MAX_CREDITS - 2);

    // Clamp a raw length value to MAX_PACKET_LEN
    function automatic [RAM_ADDR_W-1:0] clamp_length(input [RAM_ADDR_W-1:0] raw);
        clamp_length = (raw > MAX_PACKET_LEN) ? MAX_PACKET_LEN : raw;
    endfunction

    always_comb begin
        check_addr_nxt           = check_addr_r;
        packet_word_length_nxt   = packet_word_length_r;
        packet_active_nxt        = packet_active_r;
        // PENDING-DECISION #1: AHB write-side length latch gated. With
        // ENABLE_AHB_WRITE=0 an AHB write to offset 0 never arms packet_active,
        // so the TWIN-2 corruption (write_ptr walk + credit burn) cannot occur.
        capture_write_length_nxt = ENABLE_AHB_WRITE && valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && hwrite;

        // Clear packet_word_length, packet_active, and check_addr on completion (BUG-005 fix)
        if (write_complete || read_complete) begin
            packet_word_length_nxt = '0;
            packet_active_nxt = 1'b0;
            check_addr_nxt = 1'b0;
        end else if (fc_write_addr0) begin
            // FC direct write to addr 0: capture length immediately (same cycle)
            // Length is in bits [11:0] of the pre-extracted input (bits [31:20] of original word)
            packet_word_length_nxt = clamp_length(fc_wr_wdata);
            packet_active_nxt = 1'b1;
        end else if (capture_write_length_r) begin
            // AHB data phase of write to addr 0: hwdata is now valid
            // Length is in bits [11:0] of the pre-extracted input (bits [31:20] of original word)
            packet_word_length_nxt = clamp_length(hwdata);
            packet_active_nxt = 1'b1;
        end else if (valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && ~hwrite
                     && !rx_fifo_empty) begin
            // AHB read from addr 0: set flag to capture length from SRAM next cycle.
            //
            // SILICON DEFECT FIX (2026-07-14) — the `&& !rx_fifo_empty` qualifier.
            // Without it, a read of offset 0 on an EMPTY FIFO latched a packet
            // length from the zeroed SRAM (FPGA BRAM powers up all-zero => rdata=0
            // => clamp_length(0)=0), set packet_active_r, and made
            // read_target_addr = (0+1)<<2 = 4. The very next read in the sweep hit
            // offset 4, fired read_complete, and popped a PHANTOM zero-length
            // packet: read_ptr advanced by packet_delta(=2) words AND credit_count
            // was incremented ABOVE MAX_CREDITS (an impossible state that
            // over-advertises buffer space to the peer).
            //
            // Consequence: ANY driver that polls/drains an empty RX FIFO silently
            // corrupts the read pointer, so every later aperture read is shifted by
            // two words. Proven on silicon 2026-07-14: a pre-send `rxn` drain made a
            // byte-exact 28-word burst read back as 26 words starting at payload[2];
            // removing the drain restored byte-exactness (soak 0/6 -> 8/8). Sim was
            // blind because the vendor SRAM model is X-init (not zero) at t=0.
            //
            // Reading an empty FIFO must be a NO-OP. The sticky `underrun` flag
            // (underrun_event, below) already reports the condition to software.
            check_addr_nxt = 1'b1;
        end else if (check_addr_r) begin
            // Capture SRAM read data as packet length, clear flag
            packet_word_length_nxt = clamp_length(rdata);
            packet_active_nxt = 1'b1;
            check_addr_nxt = 1'b0;
        end

        // Target address = (payload_length + 1) in bytes — last word is dest_addr
        // (at offset 0x4) plus N payload words. Use _nxt to eliminate 1-cycle lag.
        write_target_addr_nxt = RAM_ADDR_W'((packet_word_length_nxt + RAM_ADDR_W'(1)) << 2);
        read_target_addr_nxt  = RAM_ADDR_W'((packet_word_length_nxt + RAM_ADDR_W'(1)) << 2);
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            packet_word_length_r <= '0;
            packet_active_r      <= 1'b0;
            check_addr_r         <= 1'b0;
            write_target_addr_r  <= '0;
            read_target_addr_r   <= '0;
        end else if (flush) begin
            packet_word_length_r <= '0;
            packet_active_r      <= 1'b0;
            check_addr_r         <= 1'b0;
            write_target_addr_r  <= '0;
            read_target_addr_r   <= '0;
        end else begin
            packet_word_length_r <= packet_word_length_nxt;
            packet_active_r      <= packet_active_nxt;
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
            // SILICON DEFECT FIX (2026-07-15) — saturate at MAX_CREDITS. This is
            // the exact MIRROR of the write side's saturate-at-zero above; the
            // read side was never given a ceiling.
            //
            // Without it, a read_complete for a packet the FIFO is not actually
            // holding mints credit ABOVE MAX_CREDITS — an impossible state that
            // OVER-ADVERTISES buffer space to the peer and invites a real
            // overrun of the receive buffer.
            //
            // The f9b94b7 `!rx_fifo_empty` guard does NOT cover this. That fix
            // stops an AHB read of offset 0 from ARMING the length latch on an
            // empty FIFO. But packet_active_r / packet_word_length_r /
            // read_target_addr_r are also armed by the FC WRITE path
            // (fc_write_addr0, :198). If a packet's header arrives and the
            // packet never completes (write_complete needs the exact beat at
            // write_target_addr), those stay armed; a later protocol-legal drain
            // then hits read_target_addr, read_complete fires (:107, gated only
            // by packet_active_r) and credit is minted above max.
            //
            // A truncated packet is reachable BY DESIGN on silicon: after
            // TX_STALL_TIMEOUT (2^16 hclk) of continuous back-pressure the FC
            // adapter deliberately abandons the in-flight beat with an AHB ERROR
            // (tidelink_fc_adapter.sv:250-300). If that beat is a packet's last
            // word, this is exactly the state entered. Link errors and a
            // data-mode toggle mid-packet do the same.
            //
            // Reproduced (credit 4096 -> 4106, no harness misbehaviour) and
            // gated by cocotb/tidelink_top_pair_v2/test_v2_truncated_pkt_credit.
            //
            // INERT ON THE HEALTHY PATH: every committed packet decrements by
            // the same packet_delta the matching read increments by, so credit
            // never legitimately reaches MAX_CREDITS from below — the clamp
            // cannot fire on a correct exchange.
            if (credit_sum > RAM_ADDR_W'(unsigned'(MAX_CREDITS)))
                credit_count_nxt = (RAM_ADDR_W-1)'(unsigned'(MAX_CREDITS));
            else
                credit_count_nxt = (RAM_ADDR_W-1)'(credit_sum);
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
