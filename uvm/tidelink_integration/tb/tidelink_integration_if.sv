///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_if.sv
///////////////////////////////////////////////////////////////////////////////
// Simple SystemVerilog interface for clock/reset access in the integration
// testbench. UVM tests use this to wait for reset deassertion and access
// interrupt signals from the DUT.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_integration_if (
  input logic clk,
  input logic rst_n
);

  // Interrupt outputs from DUT (directly wired in top.sv)
  logic released_credits_irq;
  logic doorbell_irq;
  logic packet_committed_irq;

endinterface
