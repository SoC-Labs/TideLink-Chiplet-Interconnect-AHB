// =============================================================================
// tidelink_phy_align_regs.sv — APB debug shim for FCSM credit-handshake
//                              observability (Phase 2 of
//                              docs/TIDELINK_INTERFACE_DEBUG_PLAN.md §4).
// =============================================================================
//
// HISTORY: this module was originally an APB-decoded shim for the §9 PHY
// alignment soft-straps (swi_bit_slip, swi_training_mode). Those registers
// were promoted into Region 8 of the chiplet-controller APB block (MMIO
// 0x4403_2100..0x4403_211C). The shim was kept in the tree but became
// orphaned — no longer instantiated.
//
// PHASE 2 REPURPOSE: the shim has been re-tasked as a dedicated debug
// register bank that surfaces the master-side TideLink FCSM's credit-
// handshake internals into APB-readable counters and sticky bits. The
// upstream signals are sourced via a SystemVerilog `bind` of
// tidelink_fcsm_debug to the master FCSM (u_chiplet_controller.u_wlink.
// tl2wl.wlink_tidelinktl); this shim exposes the resulting counts and
// stickies as three new APB slots that live in the currently-unused
// 0x120-0x13F window of the TideLink config APB region (paddr[8:5]=4'b1001,
// "Region 9" in the apb_region decode of tidelink_apb_regs.sv).
//
// APB layout (local paddr offsets — see tidelink_apb_regs.sv for the
// region 0x120-0x13F redirect, MMIO base 0x4403_2000):
//   +0x28  CR_CRACK_COUNTS  (RO)
//          [7:0]   = cr_rx_count_i      — saturating 8-bit count of
//                                         pkt_is_cr_pkt rising edges (rx)
//          [15:8]  = cr_tx_count_i      — saturating 8-bit count of
//                                         cr_pkt_seen_rx rising edges
//                                         (sticky into TX domain)
//          [23:16] = crack_rx_count_i   — same for pkt_is_crack_pkt (rx)
//          [31:24] = crack_tx_count_i   — same for crack_pkt_seen_rx
//
//   +0x30  FCSM_STICKY      (RO)
//          [0]  ever_pkt_is_cr_rx      — sticky: pkt_is_cr_pkt was 1
//          [1]  ever_pkt_is_crack_rx   — sticky: pkt_is_crack_pkt was 1
//          [2]  ever_cr_pkt_seen_rx    — sticky: cr_pkt_seen_rx was 1
//          [3]  ever_crack_pkt_seen_rx — sticky: crack_pkt_seen_rx was 1
//          [4]  ever_fe_tx_credit_max_loaded — sticky: fe_tx_credit_max
//                                         became non-zero at any point
//          [31:5] reserved (0)
//
//   +0x38  CMD_FCSM_RETRY   (WO/W1P)
//          [0]  retry_pulse — write 1 to assert a 2-cycle pulse. See
//                              cmd_retry_pulse_o.
//
//          *** HARDWARE NOTE — SUBMODULE-READ-ONLY CONSTRAINT ***
//          The task spec requested that this pulse "reset the master
//          TideLink FCSM state register to 0/IDLE for 2 cycles". On HW
//          this would require driving `state <= 3'h0` inside the FCSM
//          (deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v
//          line 163). The submodule is read-only per the work-package
//          constraints, and SystemVerilog `force` is sim-only (not
//          synthesised by Vivado). The bind module in tidelink_fcsm_debug
//          therefore RECEIVES this pulse and uses it to CLEAR the local
//          debug counters + stickies (giving SW a way to start a fresh
//          observation window) but does NOT actually reset the FCSM. The
//          full reset-injection path is a Phase-3 deliverable requiring
//          a submodule bump (add a one-bit FCSM swreset port).
//
// All accesses are single-cycle (pready=1, pslverr=0). Writes to RO regs
// (slots +0x28 / +0x30) silently no-op; reads from CMD_FCSM_RETRY return
// the current cmd_retry_pulse_o level (debug-friendly: SW sees the pulse
// has self-cleared on the next read).
//
// =============================================================================

`timescale 1ns/1ps

module tidelink_phy_align_regs (
    input  wire        clk,
    input  wire        rstn,           // active-low system reset (hresetn)

    // APB slave (32-bit data, byte-strobed). paddr is the LOCAL offset
    // within the 0x120-0x13F window — see tidelink_apb_regs.sv for the
    // redirect path. Only paddr[5:3] is decoded here (8-byte slot stride).
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    /* verilator lint_off UNUSED */
    input  wire [11:0] paddr,   // only paddr[5:3] decoded (slot index)
    input  wire [31:0] pwdata,  // only pwdata[0] used (CMD_FCSM_RETRY trigger)
    input  wire [3:0]  pstrb,   // ignored — RO/W1P registers don't byte-strobe
    /* verilator lint_on UNUSED */
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // -----------------------------------------------------------------
    // Counter / sticky inputs from tidelink_fcsm_debug (bind target).
    // All driven in the hclk domain by tidelink_fcsm_debug after its
    // internal 2-flop CDC; this shim does NOT need to re-sync them.
    // -----------------------------------------------------------------
    input  wire [7:0]  cr_rx_count_i,
    input  wire [7:0]  cr_tx_count_i,
    input  wire [7:0]  crack_rx_count_i,
    input  wire [7:0]  crack_tx_count_i,

    input  wire        ever_pkt_is_cr_rx_i,
    input  wire        ever_pkt_is_crack_rx_i,
    input  wire        ever_cr_pkt_seen_rx_i,
    input  wire        ever_crack_pkt_seen_rx_i,
    input  wire        ever_fe_tx_credit_max_loaded_i,

    // CMD_FCSM_RETRY output: 2-cycle pulse, asserted after a write of
    // 1'b1 to paddr offset +0x38. Consumed by tidelink_fcsm_debug to
    // clear its local debug counters / stickies (see HW note above).
    output wire        cmd_retry_pulse_o
);

    // Single-cycle APB slave (always ready, no error)
    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    wire access_phase = psel & penable;
    wire write_strobe = access_phase & pwrite;

    // -------------------------------------------------------------------------
    // Slot decode — 8-byte slot stride (paddr[5:3]):
    //   3'b101 → +0x28 CR_CRACK_COUNTS  (RO)
    //   3'b110 → +0x30 FCSM_STICKY      (RO)
    //   3'b111 → +0x38 CMD_FCSM_RETRY   (W1P)
    // The tidelink_apb_regs decoder only forwards paddr in 0x120-0x13F
    // to this shim, so paddr[8:6] is don't-care here.
    // -------------------------------------------------------------------------
    wire [2:0] slot_sel = paddr[5:3];

    // -------------------------------------------------------------------------
    // CMD_FCSM_RETRY — 2-cycle pulse generator.
    //   Write 1 to bit[0] → asserts cmd_retry_pulse_o for 2 hclk cycles,
    //   then self-clears. Re-arms on the next write-1.
    //   The two-cycle width is enough to (a) span the 2-flop CDC into
    //   the FCSM clock domain inside tidelink_fcsm_debug and (b) leave
    //   a clean falling edge for any downstream consumer.
    // -------------------------------------------------------------------------
    reg [1:0] retry_pulse_cnt;
    wire      retry_write = write_strobe && (slot_sel == 3'b111) && pwdata[0];

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            retry_pulse_cnt <= 2'b00;
        end else if (retry_write) begin
            retry_pulse_cnt <= 2'b10;       // load 2 → 2-cycle pulse
        end else if (retry_pulse_cnt != 2'b00) begin
            retry_pulse_cnt <= retry_pulse_cnt - 2'b01;
        end
    end

    assign cmd_retry_pulse_o = |retry_pulse_cnt;

    // -------------------------------------------------------------------------
    // APB read mux
    // -------------------------------------------------------------------------
    always @* begin
        case (slot_sel)
            3'b101: prdata = {crack_tx_count_i,                                 // [31:24]
                              crack_rx_count_i,                                 // [23:16]
                              cr_tx_count_i,                                    // [15:8]
                              cr_rx_count_i};                                   // [7:0]
            3'b110: prdata = {27'h0,
                              ever_fe_tx_credit_max_loaded_i,                   // [4]
                              ever_crack_pkt_seen_rx_i,                         // [3]
                              ever_cr_pkt_seen_rx_i,                            // [2]
                              ever_pkt_is_crack_rx_i,                           // [1]
                              ever_pkt_is_cr_rx_i};                             // [0]
            3'b111: prdata = {31'h0, cmd_retry_pulse_o};                       // CMD_FCSM_RETRY readback (live pulse)
            default: prdata = 32'h0;
        endcase
    end

endmodule
