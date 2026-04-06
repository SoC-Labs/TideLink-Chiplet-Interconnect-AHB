///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface for clock/reset and PTP chain status access.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_ptp_chain_if (
  input logic clk,
  input logic rst_n
);

  // Reset control
  logic poresetn;

  // Servo lock status (directly from DUT outputs)
  logic a_servo_locked;
  logic b1_servo_locked;
  logic b2_servo_locked;
  logic c_servo_locked;

  // PTP IRQs
  logic a_ptp_irq;
  logic b1_ptp_irq;
  logic b2_ptp_irq;
  logic c_ptp_irq;

  // Packet committed IRQs
  logic a_packet_committed_irq;
  logic b1_packet_committed_irq;
  logic b2_packet_committed_irq;
  logic c_packet_committed_irq;

  // Wlink IRQs
  logic a_wlink_irq;
  logic b1_wlink_irq;
  logic b2_wlink_irq;
  logic c_wlink_irq;

  // Test-driven force control (set by tests, consumed by top.sv force logic)
  logic force_b1_servo_locked;
  logic force_b1_servo_locked_val;

  initial begin
    force_b1_servo_locked     = 1'b0;
    force_b1_servo_locked_val = 1'b0;
  end

endinterface
