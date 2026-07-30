///////////////////////////////////////////////////////////////////////////////
// tidelink_top_system_if.sv
///////////////////////////////////////////////////////////////////////////////
// SystemVerilog interface for clock/reset and interrupt/status access in the
// tidelink_top paired-system testbench.
///////////////////////////////////////////////////////////////////////////////

interface tidelink_top_system_if (
  input logic clk,
  input logic rst_n
);

  // Interrupt outputs from Chiplet A
  logic a_released_credits_irq;
  logic a_doorbell_irq;
  logic a_packet_committed_irq;
  logic a_wlink_irq;

  // Interrupt outputs from Chiplet B
  logic b_released_credits_irq;
  logic b_doorbell_irq;
  logic b_packet_committed_irq;
  logic b_wlink_irq;

  // Reset control (active-low)
  logic poresetn;

  // Test-driven reset control (set by tests, consumed by top.sv force logic).
  // force_reset:   pulses rst_n (system reset, preserves POR-domain state).
  // force_poreset: pulses poresetn — used to re-arm the autoneg FSM after
  //                programming NEGO_CFG, since BYPASS is terminal and only
  //                a POR re-triggers nego_en evaluation.
  logic force_reset;
  logic force_poreset;

  // Per-lane perturb hooks (for damaged-lane simulation, Phase 4 of the
  // lane-mask sim plan). Default 0 = pass-through. When perturb_en[k]=1,
  // the corresponding pad path (A.tx[k] -> B.rx[k] for a2b, or
  // B.tx[k] -> A.rx[k] for b2a) is forced to perturb_val[k] instead of
  // the DUT-driven value. Tests use this to simulate a damaged ribbon
  // pin: with the lane mask excluding lane k, perturbing pad k must not
  // affect packet integrity.
  logic [7:0] a2b_lane_perturb_en;
  logic [7:0] a2b_lane_perturb_val;
  logic [7:0] b2a_lane_perturb_en;
  logic [7:0] b2a_lane_perturb_val;

  // Pad observability for the lane-mask PHY gating test. Sampled by top.sv
  // each cycle so tests can assert on per-lane TX pad values.
  logic [7:0] a_pad_tx_obs;
  logic [7:0] b_pad_tx_obs;

  // Per-side debug-unlock strap (allows local SW writes to Wlink in
  // slave mode). Default 1 = open. See axi_chiplet_controller.sv.
  logic a_apb_debug_unlock;
  logic b_apb_debug_unlock;

  // Per-side peer-mask handshake bypass strap. Default 1 = gate held
  // permanently open (preserves existing test behaviour). Tests that
  // exercise the gate drive these to 0 to engage the gate; SW (or, in
  // future, the autoneg FSM) must then write the local
  // link_lane_mask_hs_result @ 0x21C with peer_says_match=1 before
  // role_lock can latch.
  logic a_mask_hs_bypass;
  logic b_mask_hs_bypass;

  // -------------------------------------------------------------------------
  // BRINGUP_REPORT.md §9 — per-lane bit-slip alignment test plumbing.
  //
  // a2b_skid_bits_per_lane / b2a_skid_bits_per_lane drive an in-line
  // pad_skid_lanes module on each PHY direction. Each entry is a 3-bit
  // value 0..7 specifying how many pad_clk cycles to delay that lane's
  // data wrt the clock. Default 0 = passthrough (existing tests behave
  // exactly as before).
  //
  // a_lane_locked / b_lane_locked are 8-bit readback signals fed by an
  // in-band wlink_lane_checker on each side. lane_locked[N]==1 means the
  // training pattern is byte-aligned on lane N — i.e. the slip applied by
  // swi_bit_slip[N] cancels the corresponding skid_bits_per_lane[N].
  //
  // a_align_*_drive / b_align_*_drive control the WavD2DGpio soft-strap
  // registers swi_bit_slip / swi_training_mode. tb_top.sv has an
  // always-block that force's the gpio register when the corresponding
  // _en signal is asserted (uvm_hdl_force is unreliable with the way
  // VCS optimises these constant-default regs; force/release from module
  // context is the robust approach, matching the existing force_reset
  // mechanism).
  // -------------------------------------------------------------------------
  logic [7:0][2:0] a2b_skid_bits_per_lane;   // master TX -> slave  RX
  logic [7:0][2:0] b2a_skid_bits_per_lane;   // slave  TX -> master RX
  logic [7:0]      a_lane_locked;            // observed on A's RX = b2a path
  logic [7:0]      b_lane_locked;            // observed on B's RX = a2b path

  // -------------------------------------------------------------------------
  // I1 sim-repro (2026-07-30): TideLink-FCSM CR-handshake observability. Driven
  // by top.sv continuous assigns from the wlink_tidelinktl probes on each die.
  // The silicon I1 signature is cr_seen=0 crack_seen=0 cal_done=0 fcsm=0 on
  // BOTH dies; test_top_i1_fcsm_bringup samples these after a staggered role-
  // lock bring-up and passes iff cr_seen latches on both sides.
  // -------------------------------------------------------------------------
  logic [2:0]      a_fcsm_state;
  logic [2:0]      b_fcsm_state;
  logic            a_cr_seen;
  logic            b_cr_seen;
  logic            a_crack_seen;
  logic            b_crack_seen;
  logic            a_cal_done;
  logic            b_cal_done;
  // Per-side soft-strap drive
  logic [23:0]     a_align_bit_slip;
  logic [23:0]     b_align_bit_slip;
  logic            a_align_bit_slip_en;
  logic            b_align_bit_slip_en;
  logic            a_align_training_mode;
  logic            b_align_training_mode;
  logic            a_align_training_mode_en;
  logic            b_align_training_mode_en;

  // Phase 3 — I²C-train injection knobs (Agent #4, retargeted by the §9
  // integration). Test-driven; the `always @(*)` in top.sv hierarchically
  // forces the per-side chiplet_controller's REAL calibrator/lane-checker
  // nets (lane_locked_w / cal_lane_fault_w / cal_calibration_done_w) when
  // *_force_en is asserted — NOT #4's deleted placeholder regs. Tests use
  // these to simulate lane-fault scenarios without running the calibrator.
  logic       a_train_force_en;
  logic [7:0] a_train_lane_locked;
  logic [7:0] a_train_lane_fault;
  logic       a_train_cal_done;
  logic       b_train_force_en;
  logic [7:0] b_train_lane_locked;
  logic [7:0] b_train_lane_fault;
  logic       b_train_cal_done;

  // Phase 3 — slave-I²C-disable injection for the no-peer-response test.
  // When asserted, top.sv forces the slave's i2c_slv_reset high so the
  // slave drops off the bus after autoneg completes.
  logic       b_i2c_slv_disable;

  // Phase 3 — train-status observation (driven by top.sv mirrors from the
  // chiplet_controller's train_*_w wires). Allows the UVM tests to assert
  // on FSM state without doing an APB read of NEGO_TRAIN_STATUS.
  logic [3:0]  a_train_state_obs;
  logic        a_train_ok_obs;
  logic        a_train_fail_obs;
  logic        a_train_in_progress_obs;
  logic        a_train_peer_nack_obs;
  logic [7:0]  a_train_peer_lane_locked_obs;
  logic [7:0]  a_train_peer_lane_fault_obs;
  logic [7:0]  a_train_local_lane_fault_obs;
  logic [15:0] a_nego_train_cfg_obs;

  initial begin
    force_reset           = 1'b0;
    force_poreset         = 1'b0;
    a2b_lane_perturb_en   = 8'h00;
    a2b_lane_perturb_val  = 8'h00;
    b2a_lane_perturb_en   = 8'h00;
    b2a_lane_perturb_val  = 8'h00;
    a_apb_debug_unlock    = 1'b1;
    b_apb_debug_unlock    = 1'b1;
    a_mask_hs_bypass      = 1'b1;
    b_mask_hs_bypass      = 1'b1;
    a2b_skid_bits_per_lane = '0;
    b2a_skid_bits_per_lane = '0;
    a_align_bit_slip         = 24'h0;
    b_align_bit_slip         = 24'h0;
    a_align_bit_slip_en      = 1'b0;
    b_align_bit_slip_en      = 1'b0;
    a_align_training_mode    = 1'b0;
    b_align_training_mode    = 1'b0;
    a_align_training_mode_en = 1'b0;
    b_align_training_mode_en = 1'b0;
    a_train_force_en      = 1'b0;
    a_train_lane_locked   = 8'hFF;
    a_train_lane_fault    = 8'h00;
    a_train_cal_done      = 1'b1;
    b_train_force_en      = 1'b0;
    b_train_lane_locked   = 8'hFF;
    b_train_lane_fault    = 8'h00;
    b_train_cal_done      = 1'b1;
    b_i2c_slv_disable     = 1'b0;
  end

endinterface
