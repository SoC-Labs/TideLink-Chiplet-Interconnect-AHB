///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface for clock/reset and interrupt/status access in the
// tidelink_top paired-system testbench.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_top_system_if (
  input logic clk,
  input logic rst_n
);

  // Interrupt outputs from Chiplet A
  logic a_released_credits_irq;
  logic a_doorbell_irq;
  logic a_packet_committed_irq;
  logic a_wlink_irq;

  // Interrupt outputs from Chiplet B
  logic b_released_credits_irq;
  logic b_doorbell_irq;
  logic b_packet_committed_irq;
  logic b_wlink_irq;

  // Reset control (active-low)
  logic poresetn;

  // Test-driven reset control (set by tests, consumed by top.sv force logic)
  logic force_reset;

  // Per-lane perturb hooks (for damaged-lane simulation, Phase 4 of the
  // lane-mask sim plan). Default 0 = pass-through. When perturb_en[k]=1,
  // the corresponding pad path (A.tx[k] -> B.rx[k] for a2b, or
  // B.tx[k] -> A.rx[k] for b2a) is forced to perturb_val[k] instead of
  // the DUT-driven value. Tests use this to simulate a damaged ribbon
  // pin: with the lane mask excluding lane k, perturbing pad k must not
  // affect packet integrity.
  logic [7:0] a2b_lane_perturb_en;
  logic [7:0] a2b_lane_perturb_val;
  logic [7:0] b2a_lane_perturb_en;
  logic [7:0] b2a_lane_perturb_val;

  // Pad observability for the lane-mask PHY gating test. Sampled by top.sv
  // each cycle so tests can assert on per-lane TX pad values.
  logic [7:0] a_pad_tx_obs;
  logic [7:0] b_pad_tx_obs;

  // Per-side debug-unlock strap (allows local SW writes to Wlink in
  // slave mode). Default 1 = open. See axi_chiplet_controller.sv.
  logic a_apb_debug_unlock;
  logic b_apb_debug_unlock;

  // Per-side peer-mask handshake bypass strap. Default 1 = gate held
  // permanently open (preserves existing test behaviour). Tests that
  // exercise the gate drive these to 0 to engage the gate; SW (or, in
  // future, the autoneg FSM) must then write the local
  // link_lane_mask_hs_result @ 0x21C with peer_says_match=1 before
  // role_lock can latch.
  logic a_mask_hs_bypass;
  logic b_mask_hs_bypass;

  initial begin
    force_reset           = 1'b0;
    a2b_lane_perturb_en   = 8'h00;
    a2b_lane_perturb_val  = 8'h00;
    b2a_lane_perturb_en   = 8'h00;
    b2a_lane_perturb_val  = 8'h00;
    a_apb_debug_unlock    = 1'b1;
    b_apb_debug_unlock    = 1'b1;
    a_mask_hs_bypass      = 1'b1;
    b_mask_hs_bypass      = 1'b1;
  end

endinterface
