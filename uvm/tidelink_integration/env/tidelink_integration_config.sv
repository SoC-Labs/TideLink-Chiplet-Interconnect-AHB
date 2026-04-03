///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_config.sv
///////////////////////////////////////////////////////////////////////////////
// SVT AHB system configurations for the integration testbench.
//
// Three AHB system environments:
//   1. tx_ahb_cfg:   Active master drives FC adapter TX aperture slave
//   2. fifo_ahb_cfg: Active master reads/writes RX FIFO data slave
//   3. cfg_ahb_cfg:  Active master reads/writes config register slave
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_CONFIG_SV
`define GUARD_TIDELINK_INTEGRATION_CONFIG_SV

// ---------------------------------------------------------------
// TX aperture AHB configuration
// VIP master[0] is ACTIVE (drives TX writes into FC adapter)
// VIP slave[0] is PASSIVE (monitors DUT slave responses)
// ---------------------------------------------------------------
class tidelink_integration_tx_ahb_config extends svt_ahb_system_configuration;

  `uvm_object_utils(tidelink_integration_tx_ahb_config)

  function new(string name = "tidelink_integration_tx_ahb_config");
    super.new(name);

    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);

    this.master_cfg[0].is_active = 1;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;

    this.slave_cfg[0].is_active = 0;
    this.slave_cfg[0].data_width = 32;
    this.slave_cfg[0].transaction_coverage_enable = 1;

    this.ahb_lite = 1;

    // TX aperture address range: 0x0000 - 0x3FFF (16 KB, matches RAM_ADDR_W=14)
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_3FFF);

    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction

endclass

// ---------------------------------------------------------------
// FIFO read AHB configuration
// VIP master[0] is ACTIVE (reads received packets from RX FIFO)
// VIP slave[0] is PASSIVE (monitors DUT slave responses)
// ---------------------------------------------------------------
class tidelink_integration_fifo_ahb_config extends svt_ahb_system_configuration;

  `uvm_object_utils(tidelink_integration_fifo_ahb_config)

  function new(string name = "tidelink_integration_fifo_ahb_config");
    super.new(name);

    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);

    this.master_cfg[0].is_active = 1;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;

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
// Config register AHB configuration
// VIP master[0] is ACTIVE (reads/writes config registers via AHB-to-APB bridge)
// VIP slave[0] is PASSIVE (monitors DUT slave responses)
// ---------------------------------------------------------------
class tidelink_integration_cfg_ahb_config extends svt_ahb_system_configuration;

  `uvm_object_utils(tidelink_integration_cfg_ahb_config)

  function new(string name = "tidelink_integration_cfg_ahb_config");
    super.new(name);

    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);

    this.master_cfg[0].is_active = 1;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;

    this.slave_cfg[0].is_active = 0;
    this.slave_cfg[0].data_width = 32;
    this.slave_cfg[0].transaction_coverage_enable = 1;

    this.ahb_lite = 1;

    // Config register address range: 0x000 - 0xFFF (4 KB, matches APB_ADDR_W=12)
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_0FFF);

    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction

endclass

`endif // GUARD_TIDELINK_INTEGRATION_CONFIG_SV
