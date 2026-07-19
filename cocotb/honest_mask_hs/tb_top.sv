// PENDING-DECISION #4 — HONEST_MASK_HS proof.
//
// Instantiates tidelink_top with HONEST_MASK_HS from `define. Only clocks/resets
// and the two straps (apb_debug_unlock_i, mask_hs_bypass_i) are connected; the
// rest is left dangling (we read only the mask-handshake nets after reset).
//
// The change under test is the ternary at tidelink_top.sv:2270-2271:
//   .apb_debug_unlock_i (HONEST_MASK_HS ? apb_debug_unlock_i : 1'b1)
//   .mask_hs_bypass_i   (HONEST_MASK_HS ? mask_hs_bypass_i   : 1'b1)
//
//   HONEST_MASK_HS=0 (default): controller sees 1'b1/1'b1 REGARDLESS of the
//        top straps -> mask_hs_gate_open forced 1 (peer-mask handshake bypassed,
//        APB debug permanently unlocked).
//   HONEST_MASK_HS=1: controller sees the real straps -> with straps=0 the gate
//        follows mask_hs_match (handshake genuinely gates; APB debug lockable).
`ifndef HONEST_MASK_HS
  `define HONEST_MASK_HS 0
`endif
// PENDING (DECISION #2) — debug-unlock is now an INDEPENDENT param.
// Default 1 = today's effective behaviour (APB debug permanently unlocked).
`ifndef DEBUG_UNLOCK_DEFAULT
  `define DEBUG_UNLOCK_DEFAULT 1
`endif

module tb_top (
    input logic hclk,
    input logic hresetn,
    input logic poresetn,
    input logic apb_debug_unlock_i,
    input logic mask_hs_bypass_i
);
    tidelink_top #(
        .HONEST_MASK_HS       (`HONEST_MASK_HS),
        .DEBUG_UNLOCK_DEFAULT (`DEBUG_UNLOCK_DEFAULT)
    ) u_dut (
        .hclk               (hclk),
        .hresetn            (hresetn),
        .poresetn           (poresetn),
        .apb_debug_unlock_i (apb_debug_unlock_i),
        .mask_hs_bypass_i   (mask_hs_bypass_i)
        // everything else intentionally dangling (targeted reset-state probe)
    );
endmodule
