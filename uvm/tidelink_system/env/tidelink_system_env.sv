///////////////////////////////////////////////////////////////////////////////
// tidelink_system_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for TideLink paired-system verification.
//
// Contains 4 SVT AHB system envs (2 per chiplet side: TX + FIFO), plus
// 2 APB master agents (1 per side for config registers), a system-level
// scoreboard, coverage collector, and virtual sequencer for coordinated
// multi-port sequences.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_SYSTEM_ENV_SV
`define GUARD_TIDELINK_SYSTEM_ENV_SV

// ---------------------------------------------------------------
// SVT AHB system configurations (same pattern as integration env)
// ---------------------------------------------------------------

class sys_tx_ahb_config extends svt_ahb_system_configuration;
  `uvm_object_utils(sys_tx_ahb_config)
  function new(string name = "sys_tx_ahb_config");
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
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_3FFF);
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

class sys_fifo_ahb_config extends svt_ahb_system_configuration;
  `uvm_object_utils(sys_fifo_ahb_config)
  function new(string name = "sys_fifo_ahb_config");
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
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_3FFF);
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// ---------------------------------------------------------------
// Main environment
// ---------------------------------------------------------------
class tidelink_system_env extends uvm_env;

  `uvm_component_utils(tidelink_system_env)

  // Chiplet A agents
  svt_ahb_system_env       a_tx_ahb_sys_env;
  svt_ahb_system_env       a_fifo_ahb_sys_env;
  apb_master_agent         a_cfg_apb_agent;

  // Chiplet B agents
  svt_ahb_system_env       b_tx_ahb_sys_env;
  svt_ahb_system_env       b_fifo_ahb_sys_env;
  apb_master_agent         b_cfg_apb_agent;

  // Shared components
  tidelink_system_scoreboard   sb;
  tidelink_system_coverage     cov;
  tidelink_system_vseq         vseqr;

  // Configurations (4 total, 2 per side — TX + FIFO AHB only)
  sys_tx_ahb_config   a_tx_cfg, b_tx_cfg;
  sys_fifo_ahb_config a_fifo_cfg, b_fifo_cfg;

  function new(string name = "tidelink_system_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_system_env...", UVM_LOW)

    // Create configurations
    a_tx_cfg   = sys_tx_ahb_config::type_id::create("a_tx_cfg");
    b_tx_cfg   = sys_tx_ahb_config::type_id::create("b_tx_cfg");
    a_fifo_cfg = sys_fifo_ahb_config::type_id::create("a_fifo_cfg");
    b_fifo_cfg = sys_fifo_ahb_config::type_id::create("b_fifo_cfg");

    // Pass configurations to SVT system envs
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_tx_ahb_sys_env",   "cfg", a_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_fifo_ahb_sys_env", "cfg", a_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_tx_ahb_sys_env",   "cfg", b_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_fifo_ahb_sys_env", "cfg", b_fifo_cfg);

    // APB agents are ACTIVE (driver + sequencer)
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "a_cfg_apb_agent", "is_active", UVM_ACTIVE);
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "b_cfg_apb_agent", "is_active", UVM_ACTIVE);

    // Create SVT AHB system envs
    a_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("a_tx_ahb_sys_env", this);
    a_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("a_fifo_ahb_sys_env", this);
    b_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("b_tx_ahb_sys_env", this);
    b_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("b_fifo_ahb_sys_env", this);

    // Create APB config agents
    a_cfg_apb_agent = apb_master_agent::type_id::create("a_cfg_apb_agent", this);
    b_cfg_apb_agent = apb_master_agent::type_id::create("b_cfg_apb_agent", this);

    // System scoreboard and coverage
    sb  = tidelink_system_scoreboard::type_id::create("sb", this);
    cov = tidelink_system_coverage::type_id::create("cov", this);

    // Virtual sequencer
    vseqr = tidelink_system_vseq::type_id::create("vseqr", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Chiplet A monitor -> scoreboard
    a_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.a_tx_export);
    a_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.a_fifo_export);
    a_cfg_apb_agent.ap.connect(sb.a_cfg_export);

    // Chiplet B monitor -> scoreboard
    b_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.b_tx_export);
    b_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.b_fifo_export);
    b_cfg_apb_agent.ap.connect(sb.b_cfg_export);

    // Chiplet A monitor -> coverage
    a_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.a_tx_export);
    a_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.a_fifo_export);
    b_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.b_tx_export);
    b_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.b_fifo_export);

    // Wire up virtual sequencer's handles
    vseqr.a_tx_sqr   = a_tx_ahb_sys_env.master[0].sequencer;
    vseqr.a_fifo_sqr = a_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.a_cfg_sqr  = a_cfg_apb_agent.sequencer;
    vseqr.b_tx_sqr   = b_tx_ahb_sys_env.master[0].sequencer;
    vseqr.b_fifo_sqr = b_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.b_cfg_sqr  = b_cfg_apb_agent.sequencer;
  endfunction

endclass

`endif // GUARD_TIDELINK_SYSTEM_ENV_SV
