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

  // Error injection control (set by test, consumed by top.sv force logic)
  logic inject_a_rtn_error;   // Force hresp=1 on A's returner slave
  logic inject_b_rtn_error;   // Force hresp=1 on B's returner slave
  logic force_reset;          // Force system reset

  // Initialize to safe defaults
  initial begin
    inject_a_rtn_error = 1'b0;
    inject_b_rtn_error = 1'b0;
    force_reset        = 1'b0;
  end

endinterface
