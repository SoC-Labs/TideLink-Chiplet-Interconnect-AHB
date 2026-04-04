///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_sync_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface for clock/reset access in the PTP synchronisation
// testbench. UVM tests use this to wait for reset deassertion and to time
// inter-exchange intervals.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_ptp_sync_if (
  input logic clk,
  input logic rst_n
);

  // PHC hw_capture pulse outputs (directly observable by TB)
  logic a_hw_capture;
  logic b_hw_capture;

  // PTP-related interrupts
  logic a_ptp_irq;
  logic b_ptp_irq;

endinterface
