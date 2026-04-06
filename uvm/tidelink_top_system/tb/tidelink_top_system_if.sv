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

  initial begin
    force_reset = 1'b0;
  end

endinterface
