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
    // RX-FIFO TWIN 2 (chip-killer) — BUILD-TIME master enable for the AHB
    // CPU-write-into-RX-FIFO path.
    //
    // DECISION (David, 2026-07-19): AHB-CPU-write-to-RX **IS a supported path**.
    // Therefore this parameter DEFAULTS TO 1'b1 (path buildable) and the ASIC
    // integration leaves it at 1'b1. It is retained only as a belt-and-braces
    // knob for an integration that genuinely wants an FC-write-only RX FIFO;
    // setting it to 1'b0 hard-disables the AHB write-side length latch AND the
    // AHB write completion (AHB READS are untouched in both settings).
    //
    // TWIN 2 IS FIXED BY A RUNTIME ARM, NOT BY THIS BUILD PARAM (2026-07-21) —
    // see `swi_ahb_inject_arm` / `ahb_write_en` below. The corruption was that
    // the write-side length latch armed on ANY AHB NONSEQ write to offset 0, so
    // a stray clear/probe write pair (offset 0 then offset 4) walked the
    // FC-SHARED write_ptr by two words and burned two credits, mis-framing the
    // NEXT genuine FC packet (write_ptr is shared: fc_translated_addr =
    // fc_wr_addr + write_ptr_r). A stray probe is bit-identical to a legal
    // minimal packet, so no pattern qualifier can separate them — only EXPLICIT
    // INTENT can. The path is therefore POR-DISARMED and software must set the
    // arm (APB CTRL[3]) before AHB-injecting; ENABLE_AHB_WRITE is AND-ed on top.
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

    // RX-FIFO TWIN 2 (chip-killer) — sticky fault: set if an AHB write into the
    // RX aperture (offset 0) was attempted while the inject path was DISARMED.
    // Turns the otherwise-silent no-op into a visible fault. Sticky; cleared by
    // flush/reset. Exposed in tidelink_apb_regs STATUS (0x010) bit[5].
    output wire                   ahb_inject_fault,

    // Control inputs
    input  wire                   flush,          // Self-clearing flush: resets pointers/counters/errors

    // RX-FIFO TWIN 2 (chip-killer) — RUNTIME ARM for the AHB CPU-write-into-RX
    // path. POR-DISARMED at the register source (tidelink_apb_regs CTRL[3]).
    // When 0 an AHB write to offset 0 can neither arm a packet-length latch nor
    // advance the FC-shared write_ptr, so a stray clear/probe write pair is a
    // NO-OP. When 1 the supported AHB-injection path (incl. a length-0 RD_REQ)
    // works exactly as intended. AND-ed with the build param ENABLE_AHB_WRITE.
    // AHB READS are NEVER gated by this (reads cannot corrupt).
    input  wire                   swi_ahb_inject_arm,

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

    // TWIN-2 FIX (2026-07-21) — the AHB CPU-write-into-RX path is enabled iff the
    // build param is set AND software has ARMED it at runtime (POR-disarmed).
    // This is the whole fix: a stray clear/probe write pair is indistinguishable
    // from a legal minimal packet, so no pattern qualifier can separate them —
    // only EXPLICIT INTENT (the arm) can. When disarmed the write side cannot
    // touch the FC-shared write_ptr / credit at all.
    wire ahb_write_en = ENABLE_AHB_WRITE && swi_ahb_inject_arm;

    // AHB write-completion gated by ahb_write_en: disarmed => the FC-shared
    // write_ptr / credit are un-advanceable from the AHB write side.
    wire ahb_write_complete = ahb_write_en && ahb_valid_transfer && (haddr == write_target_addr_r) && hwrite;

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

    // TWIN-2 FIX — qualified AHB packet-start. See the arm comment below.
    // Smallest legal packet is header(2 words); require that much credit.
    localparam [RAM_ADDR_W-2:0] MIN_PKT_CREDIT = (RAM_ADDR_W-1)'(2);
    wire ahb_write_addr0 = valid_ahb_access && (haddr == RAM_ADDR_W'(1'd0)) && hwrite;
    wire ahb_pkt_start_ok = ahb_write_addr0
                            && !packet_active_r
                            && !check_addr_r
                            && (credit_count_r >= MIN_PKT_CREDIT);

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
        // TWIN-2 FIX (2026-07-19) — QUALIFY the AHB write-side length latch.
        //
        // The latch may arm only on a LEGITIMATE PACKET START, not on any AHB
        // write that happens to hit offset 0:
        //   - !packet_active_r : no packet already in flight. A second offset-0
        //     write mid-packet must not re-arm and re-target the completion
        //     address underneath the packet being written.
        //   - !check_addr_r    : a read-side length capture is not pending, so
        //     the read and write metadata paths cannot fight over
        //     packet_word_length_r / *_target_addr_r in the same cycle.
        //   - credit_count_r >= packet_delta_min(=2) : the FIFO can actually
        //     accept the smallest legal packet. Arming with no credit can only
        //     burn pointer state for a packet that will be discarded.
        // NOTE: `!rx_fifo_empty` is deliberately NOT used here. That is the
        // correct predicate for the READ side (:243) — a read of an EMPTY FIFO
        // is the phantom-pop bug — but it is exactly WRONG for writes: the
        // normal case for accepting a new packet IS an empty FIFO.
        //
        // TWIN-2 FIX (2026-07-21): gated by ahb_write_en (build param AND the
        // POR-disarmed runtime arm), not by ENABLE_AHB_WRITE alone.
        //
        // HOLD-THROUGH-ADDRESS-PHASE (2026-07-21): the packet-length word is
        // sampled from hwdata one cycle after the arm. A CPU/BFM may hold the
        // AHB ADDRESS phase for MORE than one cycle (hsel+NONSEQ+haddr==0 kept
        // asserted, with the real hwdata only presented on the final beat — the
        // exact timing cocotbext's AHBLiteMaster uses). ahb_pkt_start_ok goes
        // false as soon as packet_active_r latches (mid-address), which would
        // freeze the capture on the STALE hwdata of an early cycle. So once
        // armed, KEEP the arm asserted for as long as the offset-0 write address
        // phase persists (ahb_write_addr0) — the LAST cycle (real length word)
        // wins. The old `!= 0` reject accidentally did this by refusing to latch
        // the stale zeros; the arm makes it explicit and length-0-safe.
        // Self-terminates the moment the address phase ends (ahb_write_addr0=0).
        capture_write_length_nxt = ahb_write_en
                                   && (ahb_pkt_start_ok
                                       || (capture_write_length_r && ahb_write_addr0));

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
            // AHB data phase of write to addr 0: hwdata is now valid.
            // Length is in bits [11:0] of the pre-extracted input (bits [31:20]
            // of the original word).
            //
            // TWIN-2 FIX (2026-07-21) — the OLD `!= 0` reject that lived here was
            // BOTH WRONG and FUTILE and has been REMOVED:
            //   * WRONG: length 0 is a LEGAL packet type (PKT_RD_REQ, a
            //     header-only read request). Rejecting it broke AHB-injected
            //     RD_REQ, which David confirmed is a SUPPORTED path.
            //   * FUTILE: a stray probe with a non-zero garbage length field is
            //     bit-identical to a valid minimal packet, so a `!= 0` test
            //     cannot separate them anyway.
            // The stray clear/probe pair is now blocked upstream by the runtime
            // ARM (capture_write_length_nxt is gated by ahb_write_en): with the
            // arm POR-disarmed, this branch is simply never reached for an
            // unarmed stray write. Once ARMED, every AHB-injected packet —
            // including a length-0 RD_REQ — is accepted, exactly as intended.
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
    // RX-FIFO TWIN 2 — sticky AHB-inject-while-disarmed fault (observability)
    // -------------------------------------------------------------------------
    // A NONSEQ AHB write into the RX aperture (offset 0) while the inject path
    // is DISARMED (ahb_write_en=0) is silently dropped by the arm gate. Latch a
    // sticky bit so software/an IRQ handler can SEE the attempt instead of it
    // vanishing. Sticky until flush/reset — same discipline as overrun/underrun.
    logic ahb_inject_fault_r;
    wire ahb_inject_fault_event = ahb_write_addr0 && !ahb_write_en;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            ahb_inject_fault_r <= 1'b0;
        else if (flush)
            ahb_inject_fault_r <= 1'b0;
        else if (ahb_inject_fault_event)
            ahb_inject_fault_r <= 1'b1;
    end

    assign ahb_inject_fault = ahb_inject_fault_r;

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
