///////////////////////////////////////////////////////////////////////////////
// tidelink_integration_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for TideLink integration verification.
//
// Contains:
//   - SVT AHB system env for TX aperture (active master drives writes)
//   - SVT AHB system env for FIFO read (active master reads packets)
//   - SVT AHB system env for config registers (active master reads/writes)
//   - Integration scoreboard (end-to-end loopback verification)
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INTEGRATION_ENV_SV
`define GUARD_TIDELINK_INTEGRATION_ENV_SV

class tidelink_integration_env extends uvm_env;

  `uvm_component_utils(tidelink_integration_env)

  // Components
  svt_ahb_system_env                 tx_ahb_sys_env;    // TX aperture (VIP master drives)
  svt_ahb_system_env                 fifo_ahb_sys_env;  // FIFO read (VIP master reads)
  svt_ahb_system_env                 cfg_ahb_sys_env;   // Config registers (VIP master)
  tidelink_integration_scoreboard    sb;

  // Configurations
  tidelink_integration_tx_ahb_config   tx_ahb_cfg;
  tidelink_integration_fifo_ahb_config fifo_ahb_cfg;
  tidelink_integration_cfg_ahb_config  cfg_ahb_cfg;

  function new(string name = "tidelink_integration_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_integration_env...", UVM_LOW)

    // Create or get TX AHB configuration
    if (!uvm_config_db#(tidelink_integration_tx_ahb_config)::get(
        this, "", "tx_ahb_cfg", tx_ahb_cfg)) begin
      tx_ahb_cfg = tidelink_integration_tx_ahb_config::type_id::create("tx_ahb_cfg");
    end

    // Create or get FIFO AHB configuration
    if (!uvm_config_db#(tidelink_integration_fifo_ahb_config)::get(
        this, "", "fifo_ahb_cfg", fifo_ahb_cfg)) begin
      fifo_ahb_cfg = tidelink_integration_fifo_ahb_config::type_id::create("fifo_ahb_cfg");
    end

    // Create or get config AHB configuration
    if (!uvm_config_db#(tidelink_integration_cfg_ahb_config)::get(
        this, "", "cfg_ahb_cfg", cfg_ahb_cfg)) begin
      cfg_ahb_cfg = tidelink_integration_cfg_ahb_config::type_id::create("cfg_ahb_cfg");
    end

    // Pass configurations to SVT system envs
    uvm_config_db#(svt_ahb_system_configuration)::set(
      this, "tx_ahb_sys_env", "cfg", tx_ahb_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(
      this, "fifo_ahb_sys_env", "cfg", fifo_ahb_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(
      this, "cfg_ahb_sys_env", "cfg", cfg_ahb_cfg);

    // Create components
    tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("tx_ahb_sys_env", this);
    fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("fifo_ahb_sys_env", this);
    cfg_ahb_sys_env  = svt_ahb_system_env::type_id::create("cfg_ahb_sys_env", this);
    sb               = tidelink_integration_scoreboard::type_id::create("sb", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // TX aperture master monitor -> scoreboard
    tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.tx_ahb_export);

    // FIFO read master monitor -> scoreboard
    fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.fifo_ahb_export);

    // Config master monitor -> scoreboard
    cfg_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.cfg_ahb_export);
  endfunction

endclass

`endif // GUARD_TIDELINK_INTEGRATION_ENV_SV
