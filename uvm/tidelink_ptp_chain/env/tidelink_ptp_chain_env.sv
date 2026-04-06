///////////////////////////////////////////////////////////////////////////////
// tidelink_ptp_chain_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for TideLink PTP chain verification.
// Contains 20 SVT AHB system envs (5 per side x 4 sides: a, b1, b2, c),
// 4 APB master agents, PTP scoreboard, coverage, and virtual sequencer.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_PTP_CHAIN_ENV_SV
`define GUARD_TIDELINK_PTP_CHAIN_ENV_SV

// ---------------------------------------------------------------
// SVT AHB system configurations
// ---------------------------------------------------------------

// Active master for subordinate ports (TX, FIFO, CFG, SUB, ADR)
class ptp_chain_ahb_master_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_chain_ahb_master_config)
  function new(string name = "ptp_chain_ahb_master_config");
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

// Active slave for manager ports (MNG -- DUT drives, VIP responds)
class ptp_chain_ahb_slave_config extends svt_ahb_system_configuration;
  `uvm_object_utils(ptp_chain_ahb_slave_config)
  function new(string name = "ptp_chain_ahb_slave_config");
    super.new(name);
    this.num_masters = 1;
    this.num_slaves  = 1;
    this.create_sub_cfgs(1, 1);
    // Passive master (monitors DUT's manager output)
    this.master_cfg[0].is_active = 0;
    this.master_cfg[0].data_width = 32;
    this.master_cfg[0].transaction_coverage_enable = 1;
    // Active slave (responds to DUT's manager transactions)
    this.slave_cfg[0].is_active = 1;
    this.slave_cfg[0].data_width = 32;
    this.slave_cfg[0].transaction_coverage_enable = 1;
    this.ahb_lite = 1;
    this.set_addr_range(0, 32'h0000_0000, 32'hFFFF_FFFF);
    // Disable protocol checks for manager path
    this.master_cfg[0].protocol_checks_enable = 0;
    this.slave_cfg[0].protocol_checks_enable  = 0;
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// ---------------------------------------------------------------
// Main environment
// ---------------------------------------------------------------
class tidelink_ptp_chain_env extends uvm_env;

  `uvm_component_utils(tidelink_ptp_chain_env)

  // ----- Side A agents -----
  svt_ahb_system_env       a_sub_ahb_sys_env;
  svt_ahb_system_env       a_tx_ahb_sys_env;
  svt_ahb_system_env       a_fifo_ahb_sys_env;

  svt_ahb_system_env       a_mng_ahb_sys_env;
  apb_master_agent         a_apb_agt;

  // ----- Side B1 agents -----
  svt_ahb_system_env       b1_sub_ahb_sys_env;
  svt_ahb_system_env       b1_tx_ahb_sys_env;
  svt_ahb_system_env       b1_fifo_ahb_sys_env;

  svt_ahb_system_env       b1_mng_ahb_sys_env;
  apb_master_agent         b1_apb_agt;

  // ----- Side B2 agents -----
  svt_ahb_system_env       b2_sub_ahb_sys_env;
  svt_ahb_system_env       b2_tx_ahb_sys_env;
  svt_ahb_system_env       b2_fifo_ahb_sys_env;

  svt_ahb_system_env       b2_mng_ahb_sys_env;
  apb_master_agent         b2_apb_agt;

  // ----- Side C agents -----
  svt_ahb_system_env       c_sub_ahb_sys_env;
  svt_ahb_system_env       c_tx_ahb_sys_env;
  svt_ahb_system_env       c_fifo_ahb_sys_env;

  svt_ahb_system_env       c_mng_ahb_sys_env;
  apb_master_agent         c_apb_agt;

  // ----- Shared components -----
  tidelink_ptp_chain_scoreboard  sb;
  tidelink_ptp_chain_coverage    cov;
  tidelink_ptp_chain_config      ptp_cfg;
  tidelink_ptp_chain_vseq        vseqr;

  // ----- AHB configurations -----
  ptp_chain_ahb_master_config  a_sub_cfg,  a_tx_cfg,  a_fifo_cfg;
  ptp_chain_ahb_slave_config   a_mng_cfg;
  ptp_chain_ahb_master_config  b1_sub_cfg, b1_tx_cfg, b1_fifo_cfg;
  ptp_chain_ahb_slave_config   b1_mng_cfg;
  ptp_chain_ahb_master_config  b2_sub_cfg, b2_tx_cfg, b2_fifo_cfg;
  ptp_chain_ahb_slave_config   b2_mng_cfg;
  ptp_chain_ahb_master_config  c_sub_cfg,  c_tx_cfg,  c_fifo_cfg;
  ptp_chain_ahb_slave_config   c_mng_cfg;

  function new(string name = "tidelink_ptp_chain_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_ptp_chain_env...", UVM_LOW)

    // ---------------------------------------------------------------
    // Create AHB configs -- Side A
    // ---------------------------------------------------------------
    a_sub_cfg  = ptp_chain_ahb_master_config::type_id::create("a_sub_cfg");
    a_tx_cfg   = ptp_chain_ahb_master_config::type_id::create("a_tx_cfg");
    a_fifo_cfg = ptp_chain_ahb_master_config::type_id::create("a_fifo_cfg");
    a_mng_cfg  = ptp_chain_ahb_slave_config::type_id::create("a_mng_cfg");

    // ---------------------------------------------------------------
    // Create AHB configs -- Side B1
    // ---------------------------------------------------------------
    b1_sub_cfg  = ptp_chain_ahb_master_config::type_id::create("b1_sub_cfg");
    b1_tx_cfg   = ptp_chain_ahb_master_config::type_id::create("b1_tx_cfg");
    b1_fifo_cfg = ptp_chain_ahb_master_config::type_id::create("b1_fifo_cfg");
    b1_mng_cfg  = ptp_chain_ahb_slave_config::type_id::create("b1_mng_cfg");

    // ---------------------------------------------------------------
    // Create AHB configs -- Side B2
    // ---------------------------------------------------------------
    b2_sub_cfg  = ptp_chain_ahb_master_config::type_id::create("b2_sub_cfg");
    b2_tx_cfg   = ptp_chain_ahb_master_config::type_id::create("b2_tx_cfg");
    b2_fifo_cfg = ptp_chain_ahb_master_config::type_id::create("b2_fifo_cfg");
    b2_mng_cfg  = ptp_chain_ahb_slave_config::type_id::create("b2_mng_cfg");

    // ---------------------------------------------------------------
    // Create AHB configs -- Side C
    // ---------------------------------------------------------------
    c_sub_cfg  = ptp_chain_ahb_master_config::type_id::create("c_sub_cfg");
    c_tx_cfg   = ptp_chain_ahb_master_config::type_id::create("c_tx_cfg");
    c_fifo_cfg = ptp_chain_ahb_master_config::type_id::create("c_fifo_cfg");
    c_mng_cfg  = ptp_chain_ahb_slave_config::type_id::create("c_mng_cfg");

    // ---------------------------------------------------------------
    // Set configs via config_db -- Side A
    // ---------------------------------------------------------------
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_sub_ahb_sys_env",  "cfg", a_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_tx_ahb_sys_env",   "cfg", a_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_fifo_ahb_sys_env", "cfg", a_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_mng_ahb_sys_env",  "cfg", a_mng_cfg);

    // ---------------------------------------------------------------
    // Set configs via config_db -- Side B1
    // ---------------------------------------------------------------
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b1_sub_ahb_sys_env",  "cfg", b1_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b1_tx_ahb_sys_env",   "cfg", b1_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b1_fifo_ahb_sys_env", "cfg", b1_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b1_mng_ahb_sys_env",  "cfg", b1_mng_cfg);

    // ---------------------------------------------------------------
    // Set configs via config_db -- Side B2
    // ---------------------------------------------------------------
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b2_sub_ahb_sys_env",  "cfg", b2_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b2_tx_ahb_sys_env",   "cfg", b2_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b2_fifo_ahb_sys_env", "cfg", b2_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b2_mng_ahb_sys_env",  "cfg", b2_mng_cfg);

    // ---------------------------------------------------------------
    // Set configs via config_db -- Side C
    // ---------------------------------------------------------------
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "c_sub_ahb_sys_env",  "cfg", c_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "c_tx_ahb_sys_env",   "cfg", c_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "c_fifo_ahb_sys_env", "cfg", c_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "c_mng_ahb_sys_env",  "cfg", c_mng_cfg);

    // ---------------------------------------------------------------
    // Create SVT AHB system envs -- Side A
    // ---------------------------------------------------------------
    a_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_sub_ahb_sys_env", this);
    a_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("a_tx_ahb_sys_env", this);
    a_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("a_fifo_ahb_sys_env", this);
    a_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_mng_ahb_sys_env", this);
    a_apb_agt          = apb_master_agent::type_id::create("a_apb_agt", this);

    // ---------------------------------------------------------------
    // Create SVT AHB system envs -- Side B1
    // ---------------------------------------------------------------
    b1_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("b1_sub_ahb_sys_env", this);
    b1_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("b1_tx_ahb_sys_env", this);
    b1_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("b1_fifo_ahb_sys_env", this);
    b1_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("b1_mng_ahb_sys_env", this);
    b1_apb_agt          = apb_master_agent::type_id::create("b1_apb_agt", this);

    // ---------------------------------------------------------------
    // Create SVT AHB system envs -- Side B2
    // ---------------------------------------------------------------
    b2_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("b2_sub_ahb_sys_env", this);
    b2_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("b2_tx_ahb_sys_env", this);
    b2_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("b2_fifo_ahb_sys_env", this);
    b2_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("b2_mng_ahb_sys_env", this);
    b2_apb_agt          = apb_master_agent::type_id::create("b2_apb_agt", this);

    // ---------------------------------------------------------------
    // Create SVT AHB system envs -- Side C
    // ---------------------------------------------------------------
    c_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("c_sub_ahb_sys_env", this);
    c_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("c_tx_ahb_sys_env", this);
    c_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("c_fifo_ahb_sys_env", this);
    c_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("c_mng_ahb_sys_env", this);
    c_apb_agt          = apb_master_agent::type_id::create("c_apb_agt", this);

    // ---------------------------------------------------------------
    // Scoreboard, coverage, config, virtual sequencer
    // ---------------------------------------------------------------
    sb      = tidelink_ptp_chain_scoreboard::type_id::create("sb", this);
    cov     = tidelink_ptp_chain_coverage::type_id::create("cov", this);
    ptp_cfg = tidelink_ptp_chain_config::type_id::create("ptp_cfg");
    vseqr   = tidelink_ptp_chain_vseq::type_id::create("vseqr", this);

    // Share PTP config with scoreboard
    uvm_config_db#(tidelink_ptp_chain_config)::set(this, "sb", "ptp_chain_cfg", ptp_cfg);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // ---------------------------------------------------------------
    // Virtual sequencer handles -- Side A
    // ---------------------------------------------------------------
    vseqr.a_sub_sqr  = a_sub_ahb_sys_env.master[0].sequencer;
    vseqr.a_tx_sqr   = a_tx_ahb_sys_env.master[0].sequencer;
    vseqr.a_fifo_sqr = a_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.a_apb_sqr  = a_apb_agt.sequencer;

    // ---------------------------------------------------------------
    // Virtual sequencer handles -- Side B1
    // ---------------------------------------------------------------
    vseqr.b1_sub_sqr  = b1_sub_ahb_sys_env.master[0].sequencer;
    vseqr.b1_tx_sqr   = b1_tx_ahb_sys_env.master[0].sequencer;
    vseqr.b1_fifo_sqr = b1_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.b1_apb_sqr  = b1_apb_agt.sequencer;

    // ---------------------------------------------------------------
    // Virtual sequencer handles -- Side B2
    // ---------------------------------------------------------------
    vseqr.b2_sub_sqr  = b2_sub_ahb_sys_env.master[0].sequencer;
    vseqr.b2_tx_sqr   = b2_tx_ahb_sys_env.master[0].sequencer;
    vseqr.b2_fifo_sqr = b2_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.b2_apb_sqr  = b2_apb_agt.sequencer;

    // ---------------------------------------------------------------
    // Virtual sequencer handles -- Side C
    // ---------------------------------------------------------------
    vseqr.c_sub_sqr  = c_sub_ahb_sys_env.master[0].sequencer;
    vseqr.c_tx_sqr   = c_tx_ahb_sys_env.master[0].sequencer;
    vseqr.c_fifo_sqr = c_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.c_apb_sqr  = c_apb_agt.sequencer;
  endfunction

endclass

`endif // GUARD_TIDELINK_PTP_CHAIN_ENV_SV
