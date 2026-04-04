///////////////////////////////////////////////////////////////////////////////
// ptp_coverage.sv
///////////////////////////////////////////////////////////////////////////////
// Functional coverage collector for PTP stress characterisation.
// Covergroups track traffic load combinations, forward delay distribution,
// and TX router idle wait durations.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_COVERAGE_SV
`define GUARD_PTP_COVERAGE_SV

`uvm_analysis_imp_decl(_ptp_cov_timestamp)

class ptp_coverage extends uvm_component;

  `uvm_component_utils(ptp_coverage)

  uvm_analysis_imp_ptp_cov_timestamp #(ptp_timestamp_tuple, ptp_coverage) ts_export;

  // Sampled values
  int unsigned axi_load;
  int unsigned fifo_load;
  int unsigned gb_load;
  int unsigned fwd_delay_ns;
  int unsigned tx_idle_wait;

  // -------------------------------------------------------------------
  // cg_traffic_level: cross of AXI / FIFO / GB load levels
  // -------------------------------------------------------------------
  covergroup cg_traffic_level;
    option.per_instance = 1;

    cp_axi: coverpoint axi_load {
      bins idle       = {0};
      bins low        = {[1:25]};
      bins medium     = {[26:50]};
      bins high       = {[51:75]};
      bins saturated  = {[76:100]};
    }

    cp_fifo: coverpoint fifo_load {
      bins idle       = {0};
      bins low        = {[1:25]};
      bins medium     = {[26:50]};
      bins high       = {[51:75]};
      bins saturated  = {[76:100]};
    }

    cp_gb: coverpoint gb_load {
      bins idle       = {0};
      bins low        = {[1:25]};
      bins medium     = {[26:50]};
      bins high       = {[51:75]};
      bins saturated  = {[76:100]};
    }

    cx_all_loads: cross cp_axi, cp_fifo, cp_gb;
  endgroup

  // -------------------------------------------------------------------
  // cg_forward_delay: bins for forward delay distribution
  // -------------------------------------------------------------------
  covergroup cg_forward_delay;
    option.per_instance = 1;

    cp_fwd_delay: coverpoint fwd_delay_ns {
      bins very_low    = {[0:50]};
      bins low         = {[51:200]};
      bins medium      = {[201:500]};
      bins high        = {[501:1000]};
      bins very_high   = {[1001:5000]};
      bins extreme     = {[5001:$]};
    }
  endgroup

  // -------------------------------------------------------------------
  // cg_tx_router_idle_wait: bins for idle wait cycles before FC TX
  // -------------------------------------------------------------------
  covergroup cg_tx_router_idle_wait;
    option.per_instance = 1;

    cp_idle_wait: coverpoint tx_idle_wait {
      bins immediate   = {0};
      bins short_wait  = {[1:10]};
      bins medium_wait = {[11:100]};
      bins long_wait   = {[101:1000]};
      bins very_long   = {[1001:$]};
    }
  endgroup

  function new(string name = "ptp_coverage", uvm_component parent = null);
    super.new(name, parent);
    cg_traffic_level      = new();
    cg_forward_delay      = new();
    cg_tx_router_idle_wait = new();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ts_export = new("ts_export", this);
  endfunction

  // Called by the test/sequence layer to set traffic levels before sampling
  virtual function void set_traffic_levels(int unsigned axi, int unsigned fifo, int unsigned gb);
    axi_load  = axi;
    fifo_load = fifo;
    gb_load   = gb;
    cg_traffic_level.sample();
  endfunction

  // Called by the test/sequence layer to record idle wait duration
  virtual function void sample_idle_wait(int unsigned wait_cycles);
    tx_idle_wait = wait_cycles;
    cg_tx_router_idle_wait.sample();
  endfunction

  virtual function void write_ptp_cov_timestamp(ptp_timestamp_tuple t);
    real fwd;
    fwd = real'(t.t2) - real'(t.t1);
    fwd_delay_ns = (fwd < 0) ? 0 : int unsigned'(fwd);
    cg_forward_delay.sample();
  endfunction

  virtual function void report_phase(uvm_phase phase);
    `uvm_info("PTP_COV", $sformatf(
      "\n---------- PTP Coverage Summary ----------\n" +
      "  cg_traffic_level:       %0.1f%%\n" +
      "  cg_forward_delay:       %0.1f%%\n" +
      "  cg_tx_router_idle_wait: %0.1f%%\n" +
      "------------------------------------------",
      cg_traffic_level.get_coverage(),
      cg_forward_delay.get_coverage(),
      cg_tx_router_idle_wait.get_coverage()), UVM_LOW)
  endfunction

endclass

`endif // GUARD_PTP_COVERAGE_SV
