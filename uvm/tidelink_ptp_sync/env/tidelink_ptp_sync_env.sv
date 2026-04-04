///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_sync_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for PTP synchronisation verification.
//
// Contains SVT AHB system envs for PHC and PTP ports on both chiplet sides,
// plus config-register access agents, a convergence scoreboard, coverage
// collector, and virtual sequencer for coordinated multi-port sequences.
//
// Per chiplet:
//   - PHC AHB (12-bit address): NS_INCR, NS_INCR_FRAC, SET_TIME, HW_CAP reads
//   - PTP AHB (4-bit address):  PTP_CTRL, PTP_RX_PAYLOAD
//   - CFG AHB (12-bit address): TideLink config registers
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_SYNC_ENV_SV
`define GUARD_TIDELINK_PTP_SYNC_ENV_SV

// ---------------------------------------------------------------
// SVT AHB system configurations
// ---------------------------------------------------------------

// PHC AHB config: active master drives 12-bit address space
class ptp_phc_ahb_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_phc_ahb_config)
  function new(string name = "ptp_phc_ahb_config");
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
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_0FFF);
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// PTP AHB config: active master drives 4-bit address space
class ptp_ptp_ahb_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_ptp_ahb_config)
  function new(string name = "ptp_ptp_ahb_config");
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
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_003F);
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// CFG AHB config: active master for TideLink config registers
class ptp_cfg_ahb_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_cfg_ahb_config)
  function new(string name = "ptp_cfg_ahb_config");
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
    this.set_addr_range(0, 32'h0000_0000, 32'h0000_0FFF);
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// ---------------------------------------------------------------
// Main environment
// ---------------------------------------------------------------
class tidelink_ptp_sync_env extends uvm_env;

  `uvm_component_utils(tidelink_ptp_sync_env)

  // Chiplet A agents
  svt_ahb_system_env       a_phc_ahb_sys_env;
  svt_ahb_system_env       a_ptp_ahb_sys_env;
  svt_ahb_system_env       a_cfg_ahb_sys_env;

  // Chiplet B agents
  svt_ahb_system_env       b_phc_ahb_sys_env;
  svt_ahb_system_env       b_ptp_ahb_sys_env;
  svt_ahb_system_env       b_cfg_ahb_sys_env;

  // Shared components
  ptp_sync_scoreboard      sb;
  ptp_sync_coverage        cov;
  ptp_sync_vseq            vseqr;

  // Configurations
  ptp_phc_ahb_config       a_phc_cfg, b_phc_cfg;
  ptp_ptp_ahb_config       a_ptp_cfg, b_ptp_cfg;
  ptp_cfg_ahb_config       a_cfg_cfg, b_cfg_cfg;

  function new(string name = "tidelink_ptp_sync_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_ptp_sync_env...", UVM_LOW)

    // Create configurations
    a_phc_cfg = ptp_phc_ahb_config::type_id::create("a_phc_cfg");
    b_phc_cfg = ptp_phc_ahb_config::type_id::create("b_phc_cfg");
    a_ptp_cfg = ptp_ptp_ahb_config::type_id::create("a_ptp_cfg");
    b_ptp_cfg = ptp_ptp_ahb_config::type_id::create("b_ptp_cfg");
    a_cfg_cfg = ptp_cfg_ahb_config::type_id::create("a_cfg_cfg");
    b_cfg_cfg = ptp_cfg_ahb_config::type_id::create("b_cfg_cfg");

    // Pass configurations to SVT system envs
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_phc_ahb_sys_env", "cfg", a_phc_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_phc_ahb_sys_env", "cfg", b_phc_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_ptp_ahb_sys_env", "cfg", a_ptp_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_ptp_ahb_sys_env", "cfg", b_ptp_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_cfg_ahb_sys_env", "cfg", a_cfg_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_cfg_ahb_sys_env", "cfg", b_cfg_cfg);

    // Create SVT AHB system envs
    a_phc_ahb_sys_env = svt_ahb_system_env::type_id::create("a_phc_ahb_sys_env", this);
    b_phc_ahb_sys_env = svt_ahb_system_env::type_id::create("b_phc_ahb_sys_env", this);
    a_ptp_ahb_sys_env = svt_ahb_system_env::type_id::create("a_ptp_ahb_sys_env", this);
    b_ptp_ahb_sys_env = svt_ahb_system_env::type_id::create("b_ptp_ahb_sys_env", this);
    a_cfg_ahb_sys_env = svt_ahb_system_env::type_id::create("a_cfg_ahb_sys_env", this);
    b_cfg_ahb_sys_env = svt_ahb_system_env::type_id::create("b_cfg_ahb_sys_env", this);

    // Scoreboard and coverage
    sb  = ptp_sync_scoreboard::type_id::create("sb", this);
    cov = ptp_sync_coverage::type_id::create("cov", this);

    // Virtual sequencer
    vseqr = ptp_sync_vseq::type_id::create("vseqr", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Wire up virtual sequencer handles
    vseqr.a_phc_sqr = a_phc_ahb_sys_env.master[0].sequencer;
    vseqr.a_ptp_sqr = a_ptp_ahb_sys_env.master[0].sequencer;
    vseqr.a_cfg_sqr = a_cfg_ahb_sys_env.master[0].sequencer;
    vseqr.b_phc_sqr = b_phc_ahb_sys_env.master[0].sequencer;
    vseqr.b_ptp_sqr = b_ptp_ahb_sys_env.master[0].sequencer;
    vseqr.b_cfg_sqr = b_cfg_ahb_sys_env.master[0].sequencer;
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_SYNC_ENV_SV
