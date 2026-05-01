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

  initial begin
    force_reset           = 1'b0;
    a2b_lane_perturb_en   = 8'h00;
    a2b_lane_perturb_val  = 8'h00;
    b2a_lane_perturb_en   = 8'h00;
    b2a_lane_perturb_val  = 8'h00;
  end

endinterface
