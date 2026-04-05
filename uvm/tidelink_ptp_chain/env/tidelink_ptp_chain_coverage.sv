///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_coverage.sv
///////////////////////////////////////////////////////////////////////////////
// Minimal coverage collector placeholder for PTP chain testbench.
// PTP chain tests focus on convergence metrics rather than traditional
// functional coverage; this is reserved for future expansion.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_COVERAGE_SV
`define GUARD_TIDELINK_PTP_CHAIN_COVERAGE_SV

class tidelink_ptp_chain_coverage extends uvm_component;

  `uvm_component_utils(tidelink_ptp_chain_coverage)

  function new(string name = "tidelink_ptp_chain_coverage", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_CHAIN_COVERAGE_SV
