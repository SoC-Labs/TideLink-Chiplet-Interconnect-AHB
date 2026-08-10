///////////////////////////////////////////////////////////////////////////////
// test_top_i1_fcsm_bringup.sv
///////////////////////////////////////////////////////////////////////////////
// I1 sim-repro (sim/i1-repro-uvm-topsystem, 2026-07-30).
//
// Reproduces the TideLink silicon I1 bring-up blocker in the paired-die UVM
// env: with the 5 muxed AXI FC nodes (WlinkGenericFCSM{,_1..4}) sourced from
// src/rtl/local_overrides/ (the shipping I1 override; FCSM_SRC=local) a COLD,
// STAGGERED role-lock bring-up leaves cr_pkt_seen_rx never asserting ->
// SEND_CREDITS1 stuck -> FCSM parked at state 0 on both dies. With the pristine
// deps FCSM (FCSM_SRC=deps) the same stagger is expected to bring the CR
// handshake up (cr_seen=1). FCSM_SRC is a COMPILE choice (Makefile flist), not
// a runtime knob — build each simv separately.
//
// This test does NOT rely on full AHB data delivery: the silicon signature is
// the FCSM CR-handshake 4-tuple (cr_seen / crack_seen / cal_done / fcsm_state),
// mirrored onto tb_if by top.sv. GREEN = cr_seen latches on BOTH dies; RED =
// cr_seen stays 0 (the I1 signature).
//
// Plusargs:
//   +ROLE_STAGGER_CYC=<N>  cycles between the early die's role_lock and the
//                          late die's role_lock (default 0 = benign/coordinated).
//   +EARLY_DIE=A|B         which die locks first (default B, matching #14b:
//                          the slave latches role_lock ~ahead of the master).
//   +CR_WAIT_CYC=<N>       cycles to poll for cr_seen after data-mode (def 60000).
//   +NO_CAL_BYPASS         (consumed in top.sv) disable the calibrator sim bypass.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_I1_FCSM_BRINGUP_SV
`define GUARD_TEST_TOP_I1_FCSM_BRINGUP_SV

class test_top_i1_fcsm_bringup extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_i1_fcsm_bringup)

  // Wlink register offsets (absolute in the unified APB space)
  localparam bit [14:0] APB_ROLE_CFG      = 15'h2080;
  localparam bit [14:0] APB_R8_SLOT0      = 15'h2100;
  localparam bit [14:0] APB_R8_LANE_STAT  = 15'h2108; // bit16 = cal_done
  localparam bit [14:0] APB_WL_ENR        = 15'h0208; // Wlink LINK_ENABLE_RESET

  localparam bit [31:0] ROLE_CFG_MASTER_LOCK = 32'h0000_0002;
  localparam bit [31:0] ROLE_CFG_SLAVE_LOCK  = 32'h0000_0003;
  localparam bit [31:0] LL_BOOT_SWRESET_ON   = 32'h0002_7f08;
  localparam bit [31:0] LL_BOOT_SWRESET_OFF  = 32'h0002_7f00;
  localparam bit [31:0] LL_BOOT_ENABLE       = 32'h0002_7f07;

  int unsigned role_stagger_cyc = 0;
  int unsigned cr_wait_cyc      = 60000;
  string       early_die        = "B";
  // Periodic re-bring-up (the marginal-link retry stand-in): every
  // REBRINGUP_HCLK cycles, drop+restore the LL enable on both dies. Each drop
  // resets the FC nodes to state 0 (emit counts zeroed). 0 = disabled.
  int unsigned rebringup_hclk   = 0;
  int unsigned obs_cyc          = 60000;
  // Observation accumulators
  bit          a_cr_ever, b_cr_ever;
  bit          a_crack_ever, b_crack_ever;
  int unsigned max_a_state, max_b_state;
  bit          stop_rebringup;
  int unsigned rebringup_count;

  function new(string name = "test_top_i1_fcsm_bringup", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'($value$plusargs("ROLE_STAGGER_CYC=%d", role_stagger_cyc));
    void'($value$plusargs("CR_WAIT_CYC=%d", cr_wait_cyc));
    void'($value$plusargs("EARLY_DIE=%s", early_die));
    void'($value$plusargs("REBRINGUP_HCLK=%d", rebringup_hclk));
    void'($value$plusargs("OBS_CYC=%d", obs_cyc));
    test_timeout_cycles = 8_000_000;
  endfunction

  // absolute-address APB write to one side
  task apb_wr(side_t side, bit [14:0] addr, bit [31:0] data);
    integration_cfg_write_sequence wr;
    wr = integration_cfg_write_sequence::type_id::create("wr");
    wr.addr = addr; wr.data = data;
    if (side == SIDE_A) wr.start(env.a_apb_agt.sequencer);
    else                wr.start(env.b_apb_agt.sequencer);
  endtask

  task apb_rd(side_t side, bit [14:0] addr, output bit [31:0] data);
    integration_cfg_read_sequence rd;
    rd = integration_cfg_read_sequence::type_id::create("rd");
    rd.addr = addr;
    if (side == SIDE_A) rd.start(env.a_apb_agt.sequencer);
    else                rd.start(env.b_apb_agt.sequencer);
    data = rd.rdata;
  endtask

  task role_lock_side(side_t side);
    apb_wr(side, APB_ROLE_CFG, (side == SIDE_A) ? ROLE_CFG_MASTER_LOCK
                                                : ROLE_CFG_SLAVE_LOCK);
  endtask

  task to_data_mode(side_t side);
    apb_wr(side, APB_R8_SLOT0, 32'h0);
    repeat (20) @(posedge tb_if.clk);
    apb_wr(side, APB_WL_ENR, LL_BOOT_SWRESET_ON);
    repeat (20) @(posedge tb_if.clk);
    apb_wr(side, APB_WL_ENR, LL_BOOT_SWRESET_OFF);
    repeat (20) @(posedge tb_if.clk);
    apb_wr(side, APB_WL_ENR, LL_BOOT_ENABLE);
    repeat (20) @(posedge tb_if.clk);
  endtask

  function void dump_tuple(string tag);
    `uvm_info("I1", $sformatf(
      "%s  A[fcsm=%0d cr=%0b crack=%0b cal=%0b]  B[fcsm=%0d cr=%0b crack=%0b cal=%0b]",
      tag,
      tb_if.a_fcsm_state, tb_if.a_cr_seen, tb_if.a_crack_seen, tb_if.a_cal_done,
      tb_if.b_fcsm_state, tb_if.b_cr_seen, tb_if.b_crack_seen, tb_if.b_cal_done), UVM_LOW)
    $display("[I1_TUPLE] %s  A[fcsm=%0d cr=%0b crack=%0b cal=%0b]  B[fcsm=%0d cr=%0b crack=%0b cal=%0b]",
      tag,
      tb_if.a_fcsm_state, tb_if.a_cr_seen, tb_if.a_crack_seen, tb_if.a_cal_done,
      tb_if.b_fcsm_state, tb_if.b_cr_seen, tb_if.b_crack_seen, tb_if.b_cal_done);
  endfunction

  // One marginal-link retry pulse: drop the LL enable (swreset off = disable)
  // then re-enable, on both dies. Mirrors the peer's re-bring-up on a marginal
  // link; each drop resets the FC nodes to state 0 (emit counts zeroed).
  task pulse_rebringup();
    apb_wr(SIDE_A, APB_WL_ENR, LL_BOOT_SWRESET_OFF);
    apb_wr(SIDE_B, APB_WL_ENR, LL_BOOT_SWRESET_OFF);
    repeat (5) @(posedge tb_if.clk);
    apb_wr(SIDE_A, APB_WL_ENR, LL_BOOT_ENABLE);
    apb_wr(SIDE_B, APB_WL_ENR, LL_BOOT_ENABLE);
    rebringup_count++;
  endtask

  // Sample the 4-tuple into the accumulators (called from the observe loop).
  function void sample();
    if (tb_if.a_cr_seen)    a_cr_ever    = 1;
    if (tb_if.b_cr_seen)    b_cr_ever    = 1;
    if (tb_if.a_crack_seen) a_crack_ever = 1;
    if (tb_if.b_crack_seen) b_crack_ever = 1;
    if (tb_if.a_fcsm_state > max_a_state) max_a_state = tb_if.a_fcsm_state;
    if (tb_if.b_fcsm_state > max_b_state) max_b_state = tb_if.b_fcsm_state;
  endfunction

  virtual task main_phase(uvm_phase phase);
    side_t early, late;
    int unsigned waited, since_pulse;
    phase.raise_objection(this);
    timeout_watchdog(phase);

    $display("[I1_CFG] ROLE_STAGGER_CYC=%0d EARLY_DIE=%s REBRINGUP_HCLK=%0d OBS_CYC=%0d",
             role_stagger_cyc, early_die, rebringup_hclk, obs_cyc);

    early = (early_die == "A") ? SIDE_A : SIDE_B;
    late  = (early == SIDE_A) ? SIDE_B : SIDE_A;

    // ---- Staggered role-lock (optional #14b lever; default 0 = coordinated) --
    role_lock_side(early);
    if (role_stagger_cyc > 0) repeat (role_stagger_cyc) @(posedge tb_if.clk);
    role_lock_side(late);

    // settle + let the calibrator (sim-bypassed) reach cal_done
    repeat (2000) @(posedge tb_if.clk);
    sample(); dump_tuple("post-role-lock");

    // ---- Drop training / bootstrap LL -> data mode on both dies -------------
    to_data_mode(SIDE_A);
    to_data_mode(SIDE_B);
    sample(); dump_tuple("post-data-mode");

    // ---- Observation window, with optional periodic re-bring-up -------------
    // Primary oracle = cr_pkt_seen_rx EVER latching on both dies (== silicon
    // SWI_LANE_STATUS[23]). Corroborating = max FCSM state reached (LINK_IDLE=4).
    waited = 0; since_pulse = 0;
    while (waited < obs_cyc) begin
      repeat (200) @(posedge tb_if.clk);
      waited += 200; since_pulse += 200;
      sample();
      if (rebringup_hclk > 0 && since_pulse >= rebringup_hclk) begin
        pulse_rebringup();
        since_pulse = 0;
      end
      if ((waited % 10000) == 0)
        dump_tuple($sformatf("obs@%0d(reb=%0d)", waited, rebringup_count));
    end
    sample(); dump_tuple("final");

    // ---- Verdict ------------------------------------------------------------
    $display("[I1_STATS] rebringups=%0d  cr_ever A=%0b B=%0b  crack_ever A=%0b B=%0b  max_fcsm A=%0d B=%0d",
             rebringup_count, a_cr_ever, b_cr_ever, a_crack_ever, b_crack_ever,
             max_a_state, max_b_state);
    if (a_cr_ever && b_cr_ever) begin
      $display("[I1_VERDICT] GREEN: cr_pkt_seen_rx latched on BOTH dies (max_fcsm A=%0d B=%0d)",
               max_a_state, max_b_state);
      `uvm_info("I1", "VERDICT=GREEN (CR handshake achieved on both dies)", UVM_LOW)
    end else begin
      $display("[I1_VERDICT] RED: cr_pkt_seen_rx NEVER latched on both (A=%0b B=%0b) max_fcsm A=%0d B=%0d -- I1 SIGNATURE",
               a_cr_ever, b_cr_ever, max_a_state, max_b_state);
      `uvm_error("I1", $sformatf(
        "VERDICT=RED: cr_pkt_seen_rx never asserted on both dies (A=%0b B=%0b), max FCSM (A=%0d B=%0d) — I1 bring-up signature",
        a_cr_ever, b_cr_ever, max_a_state, max_b_state))
    end

    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_I1_FCSM_BRINGUP_SV
