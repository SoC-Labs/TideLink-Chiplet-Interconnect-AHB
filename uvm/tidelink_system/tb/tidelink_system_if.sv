///////////////////////////////////////////////////////////////////////////////
// tidelink_system_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface for clock/reset and interrupt access in the
// paired-system testbench. UVM tests use this to wait for reset deassertion
// and monitor interrupt signals from both chiplet sides.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_system_if (
  input logic clk,
  input logic rst_n
);

  // Interrupt outputs from Chiplet A
  logic a_released_credits_irq;
  logic a_doorbell_irq;
  logic a_packet_committed_irq;

  // Interrupt outputs from Chiplet B
  logic b_released_credits_irq;
  logic b_doorbell_irq;
  logic b_packet_committed_irq;

endinterface
