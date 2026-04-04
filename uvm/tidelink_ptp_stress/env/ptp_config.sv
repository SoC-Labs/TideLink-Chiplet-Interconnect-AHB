///////////////////////////////////////////////////////////////////////////////
// ptp_config.sv
///////////////////////////////////////////////////////////////////////////////
// UVM configuration object for the PTP stress testbench.
// Contains PHC/PTP register offsets, traffic rate parameters, and
// exchange count / timeout settings.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_CONFIG_SV
`define GUARD_PTP_CONFIG_SV

class ptp_config extends uvm_object;

  `uvm_object_utils(ptp_config)

  // -------------------------------------------------------------------
  // PHC Register Offsets (within cfg AHB address space)
  // -------------------------------------------------------------------
  bit [11:0] PHC_HW_CAP_SECONDS_LO  = 12'h040;
  bit [11:0] PHC_HW_CAP_SECONDS_HI  = 12'h044;
  bit [11:0] PHC_HW_CAP_NANOSECONDS = 12'h048;
  bit [11:0] PHC_NS_INCR            = 12'h004;
  bit [11:0] PHC_CTRL               = 12'h000;

  // -------------------------------------------------------------------
  // PTP Register Offsets (within cfg AHB address space)
  // -------------------------------------------------------------------
  bit [11:0] PTP_CTRL       = 12'h034;
  bit [11:0] PTP_RX_PAYLOAD = 12'h038;
  bit [11:0] PTP_STATUS     = 12'h03C;

  // -------------------------------------------------------------------
  // Traffic Rate Parameters (0 = idle, 100 = saturated)
  // -------------------------------------------------------------------
  rand int unsigned axi_traffic_rate;
  rand int unsigned fifo_traffic_rate;
  rand int unsigned gb_traffic_rate;

  constraint c_traffic_rates {
    axi_traffic_rate  inside {[0:100]};
    fifo_traffic_rate inside {[0:100]};
    gb_traffic_rate   inside {[0:100]};
  }

  // -------------------------------------------------------------------
  // PTP Exchange Parameters
  // -------------------------------------------------------------------
  int unsigned num_ptp_exchanges     = 1000;
  int unsigned timeout_per_exchange  = 50000;  // clock cycles

  // -------------------------------------------------------------------
  // PHC Configuration
  // -------------------------------------------------------------------
  bit [31:0] phc_ns_incr = 32'd4;  // 4 ns per clock cycle (250 MHz)

  function new(string name = "ptp_config");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "ptp_config: axi=%0d%%, fifo=%0d%%, gb=%0d%%, exchanges=%0d, timeout=%0d",
      axi_traffic_rate, fifo_traffic_rate, gb_traffic_rate,
      num_ptp_exchanges, timeout_per_exchange);
  endfunction

endclass

`endif // GUARD_PTP_CONFIG_SV
