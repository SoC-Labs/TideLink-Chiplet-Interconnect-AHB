// =============================================================================
// tidelink_fcsm_debug.sv — FCSM credit-handshake debug observer (bind target)
// =============================================================================
//
// Phase 2 of docs/TIDELINK_INTERFACE_DEBUG_PLAN.md §4. Instrumentation
// module that is `bind`-attached to the master TideLink FCSM
// (deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v,
// hierarchical path u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl)
// from tidelink_top.sv. The bind lets us read the FCSM's internal
// `pkt_is_cr_pkt`, `pkt_is_crack_pkt`, `cr_pkt_seen_rx`,
// `crack_pkt_seen_rx`, and `fe_tx_credit_max` registers/wires without
// modifying the read-only Wlink submodule.
//
// Source signal map (FCSM_6 internal names, verified against
// WlinkGenericFCSM_6.v):
//   pkt_is_cr_pkt          @ line 174  — wire, RX clock domain
//   pkt_is_crack_pkt       @ line 176  — wire, RX clock domain
//   cr_pkt_seen_rx         @ line 183  — reg,  RX clock domain (sticky in
//                                              FCSM, cleared by FCSM)
//   crack_pkt_seen_rx      @ line 184  — reg,  RX clock domain
//   fe_tx_credit_max[7:0]  @ line 190  — reg,  TX clock domain (set when
//                                              CR/CRACK packet seen, used
//                                              for credit accounting)
//   clock                  @ line 2    — FCSM's clock port (TX clock)
//   reset                  @ line 3    — FCSM's reset port (TX-clk async)
//
// All five observation signals are slow-moving status (sticky / counted
// at SW poll rate, not per-cycle). The module synchronises them into
// the system hclk domain via 2-flop CDC, edge-detects in hclk, and
// accumulates into:
//   - four 8-bit saturating counters (cr_rx, cr_tx, crack_rx, crack_tx)
//   - five 1-bit sticky FFs (ever_*) cleared only by hresetn or by the
//     CMD_FCSM_RETRY pulse (driven from tidelink_phy_align_regs).
//
// All flops are clocked on hclk and reset by hresetn (active-low),
// per the work-package spec ("reset domain for new counter/sticky
// logic must be hresetn (system reset), not lane-checker reset").
//
// PORT-MAP NOTE — because this module is `bind`-instantiated, its port
// connections are resolved in the BOUND-MODULE scope (FCSM_6's
// internals). The hclk/hresetn/cmd_retry_pulse_i ports are driven by
// hierarchical references reaching UP to the tidelink_top scope (see
// the bind statement in tidelink_top.sv). The five tap inputs use
// unqualified names that bind to FCSM_6.pkt_is_cr_pkt etc.
//
// COUNTER/STICKY READ-BACK — the bind module exposes its internal
// counter and sticky FFs as module-scope `reg` storage (not output
// ports). tidelink_top.sv reads them via downward hierarchical
// references (e.g.
//   u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl.u_fcsm_debug
//     .cr_rx_count_r
// ) and pipes the result into the APB debug shim. Vivado/synthesis
// supports downward-hier reads of bind-module nets as a synthesizable
// dataflow path.
//
// TX-side counters (cr_tx_count_r, crack_tx_count_r) source from the
// FCSM's `cr_pkt_seen_rx` / `crack_pkt_seen_rx` registers, which the
// FCSM itself synchronises into the TX domain (see FCSM_6.v lines
// 603/606 `cr_pkt_seen_tx_demet_io_in`). We use option (a) from the
// spec: 2-FF synchroniser into hclk + rising-edge detect. The CR/CRACK
// "seen" signals stay high for many cycles (sticky in the FCSM until
// the FCSM consumes them), so dropping a single transition to CDC is
// not a worry — we get the rising edge reliably.
//
// =============================================================================

`timescale 1ns/1ps

module tidelink_fcsm_debug (
    // System clock + reset (driven from tidelink_top via the bind's
    // port-map: hierarchical refs to tidelink_top.hclk and
    // tidelink_top.hresetn).
    input  wire        hclk,
    input  wire        hresetn,         // active-low

    // Observation taps (sourced from inside WlinkGenericFCSM_6 via the
    // bind hierarchical reference in tidelink_top.sv).
    input  wire        pkt_is_cr_pkt_w,         // rx-clk domain
    input  wire        pkt_is_crack_pkt_w,      // rx-clk domain
    input  wire        cr_pkt_seen_rx_w,        // rx-clk sticky reg
    input  wire        crack_pkt_seen_rx_w,     // rx-clk sticky reg
    input  wire [7:0]  fe_tx_credit_max_w,      // tx-clk reg

    // CMD_FCSM_RETRY input — 2-cycle pulse from tidelink_phy_align_regs.
    // While asserted, the counters + stickies are cleared. See the HW
    // note in tidelink_phy_align_regs.sv: this pulse cannot reach the
    // FCSM's `state` register without a submodule bump.
    input  wire        cmd_retry_pulse_i
);

    // -------------------------------------------------------------------------
    // 2-flop CDC for each tap into the hclk domain. Option (a) per the
    // spec — simple, sparse-pulse-loss is acceptable for diagnostic
    // counters.
    // -------------------------------------------------------------------------
    reg pkt_cr_s0,      pkt_cr_s1,      pkt_cr_s2;
    reg pkt_crack_s0,   pkt_crack_s1,   pkt_crack_s2;
    reg cr_seen_s0,     cr_seen_s1,     cr_seen_s2;
    reg crack_seen_s0,  crack_seen_s1,  crack_seen_s2;
    reg [7:0] fe_tx_credit_max_s0, fe_tx_credit_max_s1;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pkt_cr_s0          <= 1'b0;
            pkt_cr_s1          <= 1'b0;
            pkt_cr_s2          <= 1'b0;
            pkt_crack_s0       <= 1'b0;
            pkt_crack_s1       <= 1'b0;
            pkt_crack_s2       <= 1'b0;
            cr_seen_s0         <= 1'b0;
            cr_seen_s1         <= 1'b0;
            cr_seen_s2         <= 1'b0;
            crack_seen_s0      <= 1'b0;
            crack_seen_s1      <= 1'b0;
            crack_seen_s2      <= 1'b0;
            fe_tx_credit_max_s0 <= 8'h00;
            fe_tx_credit_max_s1 <= 8'h00;
        end else begin
            pkt_cr_s0      <= pkt_is_cr_pkt_w;
            pkt_cr_s1      <= pkt_cr_s0;
            pkt_cr_s2      <= pkt_cr_s1;             // delayed copy for edge-detect
            pkt_crack_s0   <= pkt_is_crack_pkt_w;
            pkt_crack_s1   <= pkt_crack_s0;
            pkt_crack_s2   <= pkt_crack_s1;
            cr_seen_s0     <= cr_pkt_seen_rx_w;
            cr_seen_s1     <= cr_seen_s0;
            cr_seen_s2     <= cr_seen_s1;
            crack_seen_s0  <= crack_pkt_seen_rx_w;
            crack_seen_s1  <= crack_seen_s0;
            crack_seen_s2  <= crack_seen_s1;
            // Sync the 8-bit fe_tx_credit_max as individual bits — each
            // bit synced through its own 2-FF. Risk: a transient value
            // could be observed during the load, but fe_tx_credit_max
            // is sticky once loaded (only re-zeroed on a wlink reset)
            // so the steady state read is correct.
            fe_tx_credit_max_s0 <= fe_tx_credit_max_w;
            fe_tx_credit_max_s1 <= fe_tx_credit_max_s0;
        end
    end

    // Rising-edge detects (1 cycle pulses in the hclk domain).
    wire pkt_cr_rise     = pkt_cr_s1     & ~pkt_cr_s2;
    wire pkt_crack_rise  = pkt_crack_s1  & ~pkt_crack_s2;
    wire cr_seen_rise    = cr_seen_s1    & ~cr_seen_s2;
    wire crack_seen_rise = crack_seen_s1 & ~crack_seen_s2;
    wire fe_tx_credit_max_nonzero = |fe_tx_credit_max_s1;

    // -------------------------------------------------------------------------
    // Saturating 8-bit counters — clear by hresetn or cmd_retry_pulse_i.
    // Exposed via downward hierarchical reference from tidelink_top, so
    // the linter can't see the read side — silence UNUSED here.
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSED */
    reg [7:0] cr_rx_count_r;
    reg [7:0] cr_tx_count_r;
    reg [7:0] crack_rx_count_r;
    reg [7:0] crack_tx_count_r;
    /* verilator lint_on UNUSED */

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            cr_rx_count_r    <= 8'h00;
            cr_tx_count_r    <= 8'h00;
            crack_rx_count_r <= 8'h00;
            crack_tx_count_r <= 8'h00;
        end else if (cmd_retry_pulse_i) begin
            cr_rx_count_r    <= 8'h00;
            cr_tx_count_r    <= 8'h00;
            crack_rx_count_r <= 8'h00;
            crack_tx_count_r <= 8'h00;
        end else begin
            if (pkt_cr_rise     && (cr_rx_count_r    != 8'hFF)) cr_rx_count_r    <= cr_rx_count_r    + 8'h01;
            if (cr_seen_rise    && (cr_tx_count_r    != 8'hFF)) cr_tx_count_r    <= cr_tx_count_r    + 8'h01;
            if (pkt_crack_rise  && (crack_rx_count_r != 8'hFF)) crack_rx_count_r <= crack_rx_count_r + 8'h01;
            if (crack_seen_rise && (crack_tx_count_r != 8'hFF)) crack_tx_count_r <= crack_tx_count_r + 8'h01;
        end
    end

    // -------------------------------------------------------------------------
    // Sticky FFs — set once and held until hresetn (or cmd_retry_pulse_i).
    // Exposed via downward hierarchical reference from tidelink_top, so
    // the linter can't see the read side — silence UNUSED here.
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSED */
    reg ever_pkt_cr_r;
    reg ever_pkt_crack_r;
    reg ever_cr_seen_r;
    reg ever_crack_seen_r;
    reg ever_fe_tx_credit_max_r;
    /* verilator lint_on UNUSED */

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ever_pkt_cr_r           <= 1'b0;
            ever_pkt_crack_r        <= 1'b0;
            ever_cr_seen_r          <= 1'b0;
            ever_crack_seen_r       <= 1'b0;
            ever_fe_tx_credit_max_r <= 1'b0;
        end else if (cmd_retry_pulse_i) begin
            ever_pkt_cr_r           <= 1'b0;
            ever_pkt_crack_r        <= 1'b0;
            ever_cr_seen_r          <= 1'b0;
            ever_crack_seen_r       <= 1'b0;
            ever_fe_tx_credit_max_r <= 1'b0;
        end else begin
            if (pkt_cr_s1)               ever_pkt_cr_r           <= 1'b1;
            if (pkt_crack_s1)            ever_pkt_crack_r        <= 1'b1;
            if (cr_seen_s1)              ever_cr_seen_r          <= 1'b1;
            if (crack_seen_s1)           ever_crack_seen_r       <= 1'b1;
            if (fe_tx_credit_max_nonzero) ever_fe_tx_credit_max_r <= 1'b1;
        end
    end

endmodule
