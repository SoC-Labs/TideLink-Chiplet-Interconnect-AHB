///////////////////////////////////////////////////////////////////////////////
// tidelink_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for TideLink verification.
//
// Contains:
//   - SVT AHB system env for FIFO side (active master + passive slave)
//   - SVT AHB system env for returner side (passive master + active slave)
//   - Custom APB master agent for register access
//   - Scoreboard
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_ENV_SV
`define GUARD_TIDELINK_ENV_SV

class tidelink_env extends uvm_env;

  `uvm_component_utils(tidelink_env)

  // Components
  svt_ahb_system_env    fifo_ahb_sys_env;   // FIFO AHB slave (VIP master drives)
  svt_ahb_system_env    ret_ahb_sys_env;    // Returner AHB master (VIP slave responds)
  apb_master_agent      apb_agt;            // APB register access
  tidelink_scoreboard   sb;

  // Configurations
  tidelink_fifo_ahb_config  fifo_ahb_cfg;
  tidelink_ret_ahb_config   ret_ahb_cfg;

  function new(string name = "tidelink_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_env...", UVM_LOW)

    // Create or get FIFO AHB configuration
    if (!uvm_config_db#(tidelink_fifo_ahb_config)::get(this, "", "fifo_ahb_cfg", fifo_ahb_cfg)) begin
      fifo_ahb_cfg = tidelink_fifo_ahb_config::type_id::create("fifo_ahb_cfg");
    end

    // Create or get returner AHB configuration
    if (!uvm_config_db#(tidelink_ret_ahb_config)::get(this, "", "ret_ahb_cfg", ret_ahb_cfg)) begin
      ret_ahb_cfg = tidelink_ret_ahb_config::type_id::create("ret_ahb_cfg");
    end

    // Pass configurations to SVT system envs
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "fifo_ahb_sys_env", "cfg", fifo_ahb_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "ret_ahb_sys_env", "cfg", ret_ahb_cfg);

    // Create components
    fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("fifo_ahb_sys_env", this);
    ret_ahb_sys_env  = svt_ahb_system_env::type_id::create("ret_ahb_sys_env", this);
    apb_agt          = apb_master_agent::type_id::create("apb_agt", this);
    sb               = tidelink_scoreboard::type_id::create("sb", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Connect FIFO AHB master monitor -> scoreboard
    fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.fifo_ahb_export);

    // Connect returner AHB master monitor -> scoreboard
    // (passive master monitors what DUT's returner drives)
    ret_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.ret_ahb_export);

    // Connect APB monitor -> scoreboard
    apb_agt.ap.connect(sb.apb_export);
  endfunction

endclass

`endif // GUARD_TIDELINK_ENV_SV
