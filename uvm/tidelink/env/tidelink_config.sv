///////////////////////////////////////////////////////////////////////////////
// tidelink_config.sv
///////////////////////////////////////////////////////////////////////////////
// Configuration for the TideLink UVM testbench.
//
// Uses TWO SVT AHB system configurations:
//   1. fifo_ahb_cfg: Active master drives DUT's FIFO AHB slave port
//   2. ret_ahb_cfg:  Active slave responds to DUT's returner AHB master port
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_CONFIG_SV
`define GUARD_TIDELINK_CONFIG_SV

// ---------------------------------------------------------------
// FIFO-side AHB configuration
// VIP master[0] is ACTIVE (drives AHB stimulus to DUT's FIFO slave)
// VIP slave[0] is PASSIVE (monitors DUT's slave responses)
// ---------------------------------------------------------------
class tidelink_fifo_ahb_config extends svt_ahb_system_configuration;

  `uvm_object_utils(tidelink_fifo_ahb_config)

  function new(string name = "tidelink_fifo_ahb_config");
    super.new(name);

    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);

    // Active master drives stimulus to DUT FIFO
    this.master_cfg[0].is_active = 1;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;

    // Passive slave monitors DUT responses
    this.slave_cfg[0].is_active = 0;
    this.slave_cfg[0].data_width = 32;
    this.slave_cfg[0].transaction_coverage_enable = 1;

    this.ahb_lite = 1;

    // FIFO address range: 0x0000 - 0x3FFF (16 KB)
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_3FFF);

    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction

endclass

// ---------------------------------------------------------------
// Returner-side AHB configuration
// VIP master[0] is PASSIVE (monitors DUT's returner master output)
// VIP slave[0] is ACTIVE (responds to DUT's returner writes)
// ---------------------------------------------------------------
class tidelink_ret_ahb_config extends svt_ahb_system_configuration;

  `uvm_object_utils(tidelink_ret_ahb_config)

  function new(string name = "tidelink_ret_ahb_config");
    super.new(name);

    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);

    // Passive master monitors DUT returner output
    this.master_cfg[0].is_active = 0;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;

    // Active slave responds to DUT returner writes
    this.slave_cfg[0].is_active = 1;
    this.slave_cfg[0].data_width = 32;
    this.slave_cfg[0].transaction_coverage_enable = 1;

    this.ahb_lite = 1;

    // Returner can target any address (pair base + offsets)
    this.set_addr_range(0, 32'h0000_0000, 32'hFFFF_FFFF);

    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction

endclass

`endif // GUARD_TIDELINK_CONFIG_SV
