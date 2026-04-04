///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_stress_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for PTP delay-variance characterisation under
// different interconnect load conditions. Extends the tidelink_top_system
// agent topology with PTP-specific AHB ports and a dedicated PHC access
// path per side.
//
// Per-side AHB agents (active masters):
//   ptp  — PTP AHB slave write port (triggers FC message)
//   phc  — PHC register access (timestamp readback)
//   sub  — AHB passthrough (background AXI traffic)
//   tx   — TideLink TX aperture (background FIFO traffic)
//   cfg  — TideLink config registers
//
// Per-side APB agent:
//   apb  — Wlink controller configuration
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_STRESS_ENV_SV
`define GUARD_TIDELINK_PTP_STRESS_ENV_SV

// ---------------------------------------------------------------
// SVT AHB master config (active master, passive slave)
// ---------------------------------------------------------------
class ptp_stress_ahb_master_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_stress_ahb_master_config)
  function new(string name = "ptp_stress_ahb_master_config");
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
    this.set_addr_range(0, 32'h0000_0000, 32'hFFFF_FFFF);
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// ---------------------------------------------------------------
// SVT AHB slave config (passive master, active slave — for MNG)
// ---------------------------------------------------------------
class ptp_stress_ahb_slave_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_stress_ahb_slave_config)
  function new(string name = "ptp_stress_ahb_slave_config");
    super.new(name);
    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);
    this.master_cfg[0].is_active = 0;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;
    this.slave_cfg[0].is_active = 1;
    this.slave_cfg[0].data_width = 32;
    this.slave_cfg[0].transaction_coverage_enable = 1;
    this.ahb_lite = 1;
    this.set_addr_range(0, 32'h0000_0000, 32'hFFFF_FFFF);
    this.master_cfg[0].protocol_checks_enable = 0;
    this.slave_cfg[0].protocol_checks_enable  = 0;
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// ---------------------------------------------------------------
// Virtual sequencer
// ---------------------------------------------------------------
class ptp_stress_vseqr extends uvm_sequencer;

  `uvm_component_utils(ptp_stress_vseqr)

  // Chiplet A sequencer handles
  svt_ahb_master_transaction_sequencer a_ptp_sqr;
  svt_ahb_master_transaction_sequencer a_phc_sqr;
  svt_ahb_master_transaction_sequencer a_sub_sqr;
  svt_ahb_master_transaction_sequencer a_tx_sqr;
  svt_ahb_master_transaction_sequencer a_fifo_sqr;
  svt_ahb_master_transaction_sequencer a_cfg_sqr;
  apb_master_sequencer                 a_apb_sqr;

  // Chiplet B sequencer handles
  svt_ahb_master_transaction_sequencer b_ptp_sqr;
  svt_ahb_master_transaction_sequencer b_phc_sqr;
  svt_ahb_master_transaction_sequencer b_sub_sqr;
  svt_ahb_master_transaction_sequencer b_tx_sqr;
  svt_ahb_master_transaction_sequencer b_fifo_sqr;
  svt_ahb_master_transaction_sequencer b_cfg_sqr;
  apb_master_sequencer                 b_apb_sqr;

  function new(string name = "ptp_stress_vseqr", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

// ---------------------------------------------------------------
// Main environment
// ---------------------------------------------------------------
class tidelink_ptp_stress_env extends uvm_env;

  `uvm_component_utils(tidelink_ptp_stress_env)

  // Chiplet A agents — subordinate ports (active masters)
  svt_ahb_system_env  a_ptp_ahb_sys_env;
  svt_ahb_system_env  a_phc_ahb_sys_env;
  svt_ahb_system_env  a_sub_ahb_sys_env;
  svt_ahb_system_env  a_tx_ahb_sys_env;
  svt_ahb_system_env  a_fifo_ahb_sys_env;
  svt_ahb_system_env  a_cfg_ahb_sys_env;
  svt_ahb_system_env  a_mng_ahb_sys_env;
  apb_master_agent    a_apb_agt;

  // Chiplet B agents
  svt_ahb_system_env  b_ptp_ahb_sys_env;
  svt_ahb_system_env  b_phc_ahb_sys_env;
  svt_ahb_system_env  b_sub_ahb_sys_env;
  svt_ahb_system_env  b_tx_ahb_sys_env;
  svt_ahb_system_env  b_fifo_ahb_sys_env;
  svt_ahb_system_env  b_cfg_ahb_sys_env;
  svt_ahb_system_env  b_mng_ahb_sys_env;
  apb_master_agent    b_apb_agt;

  // Shared components
  ptp_scoreboard        sb;
  ptp_coverage          cov;
  ptp_stress_vseqr      vseqr;
  ptp_config            cfg;

  // Configurations
  ptp_stress_ahb_master_config a_ptp_cfg, a_phc_cfg, a_sub_cfg, a_tx_cfg, a_fifo_cfg, a_cfg_cfg;
  ptp_stress_ahb_slave_config  a_mng_cfg;
  ptp_stress_ahb_master_config b_ptp_cfg, b_phc_cfg, b_sub_cfg, b_tx_cfg, b_fifo_cfg, b_cfg_cfg;
  ptp_stress_ahb_slave_config  b_mng_cfg;

  function new(string name = "tidelink_ptp_stress_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_ptp_stress_env...", UVM_LOW)

    // Retrieve or create ptp_config
    if (!uvm_config_db#(ptp_config)::get(this, "", "ptp_cfg", cfg)) begin
      cfg = ptp_config::type_id::create("ptp_cfg");
      `uvm_info("build_phase", "Using default ptp_config.", UVM_MEDIUM)
    end

    // Create configs — Chiplet A
    a_ptp_cfg  = ptp_stress_ahb_master_config::type_id::create("a_ptp_cfg");
    a_phc_cfg  = ptp_stress_ahb_master_config::type_id::create("a_phc_cfg");
    a_sub_cfg  = ptp_stress_ahb_master_config::type_id::create("a_sub_cfg");
    a_tx_cfg   = ptp_stress_ahb_master_config::type_id::create("a_tx_cfg");
    a_fifo_cfg = ptp_stress_ahb_master_config::type_id::create("a_fifo_cfg");
    a_cfg_cfg  = ptp_stress_ahb_master_config::type_id::create("a_cfg_cfg");
    a_mng_cfg  = ptp_stress_ahb_slave_config::type_id::create("a_mng_cfg");

    // Create configs — Chiplet B
    b_ptp_cfg  = ptp_stress_ahb_master_config::type_id::create("b_ptp_cfg");
    b_phc_cfg  = ptp_stress_ahb_master_config::type_id::create("b_phc_cfg");
    b_sub_cfg  = ptp_stress_ahb_master_config::type_id::create("b_sub_cfg");
    b_tx_cfg   = ptp_stress_ahb_master_config::type_id::create("b_tx_cfg");
    b_fifo_cfg = ptp_stress_ahb_master_config::type_id::create("b_fifo_cfg");
    b_cfg_cfg  = ptp_stress_ahb_master_config::type_id::create("b_cfg_cfg");
    b_mng_cfg  = ptp_stress_ahb_slave_config::type_id::create("b_mng_cfg");

    // Set configs via config_db — Chiplet A
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_ptp_ahb_sys_env",  "cfg", a_ptp_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_phc_ahb_sys_env",  "cfg", a_phc_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_sub_ahb_sys_env",  "cfg", a_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_tx_ahb_sys_env",   "cfg", a_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_fifo_ahb_sys_env", "cfg", a_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_cfg_ahb_sys_env",  "cfg", a_cfg_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_mng_ahb_sys_env",  "cfg", a_mng_cfg);

    // Set configs via config_db — Chiplet B
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_ptp_ahb_sys_env",  "cfg", b_ptp_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_phc_ahb_sys_env",  "cfg", b_phc_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_sub_ahb_sys_env",  "cfg", b_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_tx_ahb_sys_env",   "cfg", b_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_fifo_ahb_sys_env", "cfg", b_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_cfg_ahb_sys_env",  "cfg", b_cfg_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_mng_ahb_sys_env",  "cfg", b_mng_cfg);

    // Create SVT AHB system envs — Chiplet A
    a_ptp_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_ptp_ahb_sys_env", this);
    a_phc_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_phc_ahb_sys_env", this);
    a_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_sub_ahb_sys_env", this);
    a_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("a_tx_ahb_sys_env", this);
    a_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("a_fifo_ahb_sys_env", this);
    a_cfg_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_cfg_ahb_sys_env", this);
    a_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_mng_ahb_sys_env", this);
    a_apb_agt          = apb_master_agent::type_id::create("a_apb_agt", this);

    // Create SVT AHB system envs — Chiplet B
    b_ptp_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_ptp_ahb_sys_env", this);
    b_phc_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_phc_ahb_sys_env", this);
    b_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_sub_ahb_sys_env", this);
    b_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("b_tx_ahb_sys_env", this);
    b_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("b_fifo_ahb_sys_env", this);
    b_cfg_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_cfg_ahb_sys_env", this);
    b_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_mng_ahb_sys_env", this);
    b_apb_agt          = apb_master_agent::type_id::create("b_apb_agt", this);

    // Scoreboard, coverage, virtual sequencer
    sb    = ptp_scoreboard::type_id::create("sb", this);
    cov   = ptp_coverage::type_id::create("cov", this);
    vseqr = ptp_stress_vseqr::type_id::create("vseqr", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Virtual sequencer handles — Chiplet A
    vseqr.a_ptp_sqr  = a_ptp_ahb_sys_env.master[0].sequencer;
    vseqr.a_phc_sqr  = a_phc_ahb_sys_env.master[0].sequencer;
    vseqr.a_sub_sqr  = a_sub_ahb_sys_env.master[0].sequencer;
    vseqr.a_tx_sqr   = a_tx_ahb_sys_env.master[0].sequencer;
    vseqr.a_fifo_sqr = a_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.a_cfg_sqr  = a_cfg_ahb_sys_env.master[0].sequencer;
    vseqr.a_apb_sqr  = a_apb_agt.sequencer;

    // Virtual sequencer handles — Chiplet B
    vseqr.b_ptp_sqr  = b_ptp_ahb_sys_env.master[0].sequencer;
    vseqr.b_phc_sqr  = b_phc_ahb_sys_env.master[0].sequencer;
    vseqr.b_sub_sqr  = b_sub_ahb_sys_env.master[0].sequencer;
    vseqr.b_tx_sqr   = b_tx_ahb_sys_env.master[0].sequencer;
    vseqr.b_fifo_sqr = b_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.b_cfg_sqr  = b_cfg_ahb_sys_env.master[0].sequencer;
    vseqr.b_apb_sqr  = b_apb_agt.sequencer;
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_STRESS_ENV_SV
