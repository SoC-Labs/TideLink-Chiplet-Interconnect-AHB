///////////////////////////////////////////////////////////////////////////////
// test_top_train_base.sv — Base class for I²C-coordinated training-mode tests
///////////////////////////////////////////////////////////////////////////////
// Provides shared APB helpers and Region 8 address constants for the
// `test_train_*` family (Phase 3 of the bring-up plan; see
// `docs/archive/proposals/i2c_train/UVM_TEST_PLAN.md`).
//
// The tests run autoneg with `train_auto_en=1` set in NEGO_TRAIN_CFG (Region
// 8 @ 0x4403_210C). After the existing mask-handshake completes the master
// FSM walks `ST_NEGO_DONE_PRE → ST_TRAIN_ENTER → ST_TRAIN_RUN →
// ST_TRAIN_POLL_PEER → ST_TRAIN_EXIT → ST_TRAIN_DONE`, coordinating the
// peer's training-mode entry/exit over the existing I²C sideband.
//
// The lane-status injection used by `test_train_lane_fault` and friends
// uses hierarchical force into the chiplet_controller's synced
// lane-locked/fault inputs (see `swi_lane_locked_in[]` reg in
// `axi_chiplet_controller.sv`). The default tied-off value is locked
// (0xFF, cal_done=1, fault=0) so the happy-path test sees an immediate
// poll success.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_TRAIN_BASE_SV
`define GUARD_TEST_TOP_TRAIN_BASE_SV

class test_top_train_base extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_train_base)

  // ---- Region 8 (Chiplet Extended) MMIO offsets within TideLink-config APB ----
  // MMIO base for TideLink-config is 0x4403_2000; the 15-bit raw address
  // used by write_cfg_reg_raw is `paddr + 0x2000`. Region 8 sits at
  // paddr 0x100..0x11C → raw 0x2100..0x211C.
  localparam bit [14:0] R8_SWI_TRAINING_MODE  = 15'h2100;
  localparam bit [14:0] R8_SWI_BIT_SLIP_LO    = 15'h2104;
  localparam bit [14:0] R8_SWI_LANE_STATUS    = 15'h2108;
  localparam bit [14:0] R8_NEGO_TRAIN_CFG     = 15'h210C;
  localparam bit [14:0] R8_NEGO_TRAIN_STATUS  = 15'h2110;
  localparam bit [14:0] R8_NEGO_TRAIN_STEP    = 15'h2114;
  localparam bit [14:0] R8_PHY_ALIGN_ID       = 15'h211C;

  // Region 4 / legacy NEGO offsets
  localparam bit [14:0] CTRL_NEGO_CFG_OFF     = 15'h2090;
  localparam bit [14:0] CTRL_NEGO_PRIORITY    = 15'h2098;
  localparam bit [14:0] CTRL_I2C_SLV_ADDR     = 15'h2088;
  localparam bit [14:0] CTRL_I2C_PRESCALE     = 15'h208C;
  localparam bit [14:0] CTRL_ROLE_CFG         = 15'h2080;

  // NEGO_TRAIN_STATUS bit positions (see I2C_TRAIN_PROTOCOL.md §3 / apb_redesign PROPOSAL §3.3.4)
  localparam int NTS_OK             = 0;
  localparam int NTS_FAIL           = 1;
  localparam int NTS_IN_PROGRESS    = 2;
  localparam int NTS_PEER_NACK      = 3;
  // bits[7:4] = train_state[3:0]
  // bits[15:8] = peer_lane_locked
  // bits[23:16] = peer_lane_fault
  // bits[31:24] = local_lane_fault

  function new(string name = "test_top_train_base", uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h00FF;
    a_rx_mask = 16'h00FF;
    b_tx_mask = 16'h00FF;
    b_rx_mask = 16'h00FF;
  endfunction

  // Configure both sides for I²C-coordinated autoneg + training.
  // Sets I²C slave address, prescale, priority (A wins master), and
  // NEGO_CFG (mask_hs_auto_en=1, force_lock=1, en=1) + NEGO_TRAIN_CFG
  // (train_auto_en=1 with optional poll-timeout / wait override).
  virtual task program_train_cfg(input bit [3:0]  poll_timeout = 4'd0,
                                 input bit [7:0]  wait_hi      = 8'd0);
    bit [31:0] cfg;
    `uvm_info("TEST", "Programming autoneg + train config on both sides", UVM_LOW)

    // I²C slave address (peer expects 0x7E claim writes)
    write_cfg_reg_raw(SIDE_A, CTRL_I2C_SLV_ADDR, 32'h0000_007E);
    write_cfg_reg_raw(SIDE_B, CTRL_I2C_SLV_ADDR, 32'h0000_007E);

    // Faster I²C prescale (1.4 MHz @ 100 MHz clk) — same value used by
    // test_top_peer_mask_auto for reliable SDA settle.
    write_cfg_reg_raw(SIDE_A, CTRL_I2C_PRESCALE, 32'h0000_0010);
    write_cfg_reg_raw(SIDE_B, CTRL_I2C_PRESCALE, 32'h0000_0010);

    // Priority: A (1) wins master, B (FFFE) loses → slave.
    write_cfg_reg_raw(SIDE_A, CTRL_NEGO_PRIORITY, 32'h0000_0001);
    write_cfg_reg_raw(SIDE_B, CTRL_NEGO_PRIORITY, 32'h0000_FFFE);

    // NEGO_TRAIN_CFG: bit[0]=train_auto_en, bits[7:4]=poll_timeout,
    // bits[15:8]=fsm_wait_hi.
    cfg = {16'h0, wait_hi, poll_timeout, 3'b000, 1'b1};
    write_cfg_reg_raw(SIDE_A, R8_NEGO_TRAIN_CFG, cfg);
    // The slave doesn't run the training FSM, but program identically so
    // the registers reflect a consistent SW view.
    write_cfg_reg_raw(SIDE_B, R8_NEGO_TRAIN_CFG, cfg);

    // NEGO_CFG: bit[0]=nego_en, bit[5]=force_lock. Mask-hs-auto (bit[6])
    // intentionally LEFT CLEAR — the autoneg's mask-handshake I²C path
    // is pre-existing-broken (see test_top_peer_mask_auto's "KNOWN
    // BLOCKED" comment / SHORTCOMINGS.md 14a). The training sub-flow
    // engages via ST_NEGO_DONE_PRE regardless of mask_hs_auto_en, so we
    // take the legacy POLL→NEGO_DONE_PRE branch to reach training.
    write_cfg_reg_raw(SIDE_A, CTRL_NEGO_CFG_OFF, 32'h0000_0021);
    write_cfg_reg_raw(SIDE_B, CTRL_NEGO_CFG_OFF, 32'h0000_0021);
  endtask

  // Poll master-side training status via tb_if observation hooks (driven
  // from top.sv module-scope to avoid HRP from package). Returns once
  // train_ok or train_fail is asserted (or after max_cycles). Test-side
  // assertions use the `tb_if.a_train_*_obs` mirrors directly.
  virtual task wait_train_complete(output bit train_ok,
                                    output bit train_fail,
                                    input int max_cycles = 200000);
    int polled = 0;
    forever begin
      if (tb_if.a_train_ok_obs || tb_if.a_train_fail_obs) break;
      if (polled >= max_cycles) begin
        `uvm_info("TEST", $sformatf(
          "wait_train_complete: hit cycle limit %0d cycles, ok=%0b fail=%0b state=%0d",
          polled, tb_if.a_train_ok_obs, tb_if.a_train_fail_obs,
          tb_if.a_train_state_obs), UVM_LOW)
        break;
      end
      repeat (200) @(posedge tb_if.clk);
      polled += 200;
    end
    train_ok   = tb_if.a_train_ok_obs;
    train_fail = tb_if.a_train_fail_obs;
  endtask

  // Per-side autocal observation injection. Drives `tb_if.<side>_train_*`
  // knobs; the module-scope force in top.sv overrides the chiplet
  // controller's placeholder regs. UVM tests use these to simulate
  // scenarios like "slave's lane 3 never locks" without instantiating
  // the calibrator. Avoids hierarchical refs from package scope.
  virtual function void force_local_status(side_t side,
                                            bit [7:0] lane_locked,
                                            bit [7:0] lane_fault,
                                            bit       cal_done);
    if (side == SIDE_A) begin
      tb_if.a_train_lane_locked = lane_locked;
      tb_if.a_train_lane_fault  = lane_fault;
      tb_if.a_train_cal_done    = cal_done;
      tb_if.a_train_force_en    = 1'b1;
    end else begin
      tb_if.b_train_lane_locked = lane_locked;
      tb_if.b_train_lane_fault  = lane_fault;
      tb_if.b_train_cal_done    = cal_done;
      tb_if.b_train_force_en    = 1'b1;
    end
  endfunction

  virtual function void release_local_status(side_t side);
    if (side == SIDE_A) tb_if.a_train_force_en = 1'b0;
    else                tb_if.b_train_force_en = 1'b0;
  endfunction

endclass

`endif // GUARD_TEST_TOP_TRAIN_BASE_SV
