///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_env.sv
///////////////////////////////////////////////////////////////////////////////
// Top-level UVM environment for TideLink full tidelink_top paired-system
// verification. Contains 10 SVT AHB system envs (5 per chiplet side),
// 2 APB master agents, scoreboard, coverage, and virtual sequencer.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_TOP_SYSTEM_ENV_SV
`define GUARD_TIDELINK_TOP_SYSTEM_ENV_SV

// ---------------------------------------------------------------
// SVT AHB system configurations
// ---------------------------------------------------------------

// Active master for subordinate ports (TX, FIFO, CFG, SUB)
class top_sys_ahb_master_config extends svt_ahb_system_configuration;
  `uvm_object_utils(top_sys_ahb_master_config)
  function new(string name = "top_sys_ahb_master_config");
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

// Active slave for manager ports (MNG — DUT drives, VIP responds)
class top_sys_ahb_slave_config extends svt_ahb_system_configuration;
  `uvm_object_utils(top_sys_ahb_slave_config)
  function new(string name = "top_sys_ahb_slave_config");
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
    // Disable protocol checks for manager path (DUT may not drive hprot/hmastlock)
    this.master_cfg[0].protocol_checks_enable = 0;
    this.slave_cfg[0].protocol_checks_enable  = 0;
    this.master_cfg[0].enable_xml_gen = 0;
    this.slave_cfg[0].enable_xml_gen  = 0;
  endfunction
endclass

// ---------------------------------------------------------------
// Main environment
// ---------------------------------------------------------------
class tidelink_top_system_env extends uvm_env;

  `uvm_component_utils(tidelink_top_system_env)

  // Chiplet A agents — subordinate ports (active masters)
  svt_ahb_system_env       a_sub_ahb_sys_env;
  svt_ahb_system_env       a_tx_ahb_sys_env;
  svt_ahb_system_env       a_fifo_ahb_sys_env;
  // Chiplet A manager port (active slave)
  svt_ahb_system_env       a_mng_ahb_sys_env;
  // Chiplet A APB agent (unified config: Wlink + TideLink regs)
  apb_master_agent         a_apb_agt;

  // Chiplet B agents
  svt_ahb_system_env       b_sub_ahb_sys_env;
  svt_ahb_system_env       b_tx_ahb_sys_env;
  svt_ahb_system_env       b_fifo_ahb_sys_env;
  svt_ahb_system_env       b_mng_ahb_sys_env;
  apb_master_agent         b_apb_agt;

  // Shared components
  tidelink_top_system_scoreboard   sb;
  tidelink_top_system_coverage     cov;
  tidelink_top_system_vseq         vseqr;

  // Configurations
  top_sys_ahb_master_config  a_sub_cfg, a_tx_cfg, a_fifo_cfg;
  top_sys_ahb_slave_config   a_mng_cfg;
  top_sys_ahb_master_config  b_sub_cfg, b_tx_cfg, b_fifo_cfg;
  top_sys_ahb_slave_config   b_mng_cfg;

  function new(string name = "tidelink_top_system_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    `uvm_info("build_phase", "Building tidelink_top_system_env...", UVM_LOW)

    // Create configs — Chiplet A
    a_sub_cfg  = top_sys_ahb_master_config::type_id::create("a_sub_cfg");
    a_tx_cfg   = top_sys_ahb_master_config::type_id::create("a_tx_cfg");
    a_fifo_cfg = top_sys_ahb_master_config::type_id::create("a_fifo_cfg");
    a_mng_cfg  = top_sys_ahb_slave_config::type_id::create("a_mng_cfg");

    // Create configs — Chiplet B
    b_sub_cfg  = top_sys_ahb_master_config::type_id::create("b_sub_cfg");
    b_tx_cfg   = top_sys_ahb_master_config::type_id::create("b_tx_cfg");
    b_fifo_cfg = top_sys_ahb_master_config::type_id::create("b_fifo_cfg");
    b_mng_cfg  = top_sys_ahb_slave_config::type_id::create("b_mng_cfg");

    // Set configs via config_db
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_sub_ahb_sys_env",  "cfg", a_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_tx_ahb_sys_env",   "cfg", a_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_fifo_ahb_sys_env", "cfg", a_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "a_mng_ahb_sys_env",  "cfg", a_mng_cfg);

    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_sub_ahb_sys_env",  "cfg", b_sub_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_tx_ahb_sys_env",   "cfg", b_tx_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_fifo_ahb_sys_env", "cfg", b_fifo_cfg);
    uvm_config_db#(svt_ahb_system_configuration)::set(this, "b_mng_ahb_sys_env",  "cfg", b_mng_cfg);

    // Create SVT AHB system envs — Chiplet A
    a_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_sub_ahb_sys_env", this);
    a_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("a_tx_ahb_sys_env", this);
    a_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("a_fifo_ahb_sys_env", this);
    a_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("a_mng_ahb_sys_env", this);
    a_apb_agt          = apb_master_agent::type_id::create("a_apb_agt", this);

    // Create SVT AHB system envs — Chiplet B
    b_sub_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_sub_ahb_sys_env", this);
    b_tx_ahb_sys_env   = svt_ahb_system_env::type_id::create("b_tx_ahb_sys_env", this);
    b_fifo_ahb_sys_env = svt_ahb_system_env::type_id::create("b_fifo_ahb_sys_env", this);
    b_mng_ahb_sys_env  = svt_ahb_system_env::type_id::create("b_mng_ahb_sys_env", this);
    b_apb_agt          = apb_master_agent::type_id::create("b_apb_agt", this);

    // Scoreboard, coverage, virtual sequencer
    sb    = tidelink_top_system_scoreboard::type_id::create("sb", this);
    cov   = tidelink_top_system_coverage::type_id::create("cov", this);
    vseqr = tidelink_top_system_vseq::type_id::create("vseqr", this);

    `uvm_info("build_phase", "Build complete.", UVM_LOW)
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Chiplet A monitors -> scoreboard
    a_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.a_tx_export);
    a_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.a_fifo_export);
    a_sub_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.a_sub_export);

    // Chiplet B monitors -> scoreboard
    b_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.b_tx_export);
    b_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.b_fifo_export);
    b_sub_ahb_sys_env.master[0].monitor.item_observed_port.connect(sb.b_sub_export);

    // Coverage
    a_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.a_tx_export);
    a_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.a_fifo_export);
    b_tx_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.b_tx_export);
    b_fifo_ahb_sys_env.master[0].monitor.item_observed_port.connect(cov.b_fifo_export);

    // Virtual sequencer handles
    vseqr.a_sub_sqr  = a_sub_ahb_sys_env.master[0].sequencer;
    vseqr.a_tx_sqr   = a_tx_ahb_sys_env.master[0].sequencer;
    vseqr.a_fifo_sqr = a_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.a_apb_sqr  = a_apb_agt.sequencer;

    vseqr.b_sub_sqr  = b_sub_ahb_sys_env.master[0].sequencer;
    vseqr.b_tx_sqr   = b_tx_ahb_sys_env.master[0].sequencer;
    vseqr.b_fifo_sqr = b_fifo_ahb_sys_env.master[0].sequencer;
    vseqr.b_apb_sqr  = b_apb_agt.sequencer;
  endfunction

endclass

`endif // GUARD_TIDELINK_TOP_SYSTEM_ENV_SV
