///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_stress_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface for clock/reset, PTP interrupt, and status access
// in the PTP stress testbench.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_ptp_stress_if (
  input logic clk,
  input logic rst_n
);

  // PTP interrupt outputs
  logic a_ptp_irq;
  logic b_ptp_irq;

  // TideLink interrupt outputs from Chiplet A
  logic a_released_credits_irq;
  logic a_doorbell_irq;
  logic a_packet_committed_irq;
  logic a_wlink_irq;

  // TideLink interrupt outputs from Chiplet B
  logic b_released_credits_irq;
  logic b_doorbell_irq;
  logic b_packet_committed_irq;
  logic b_wlink_irq;

  // Reset control (active-low)
  logic poresetn;

endinterface
