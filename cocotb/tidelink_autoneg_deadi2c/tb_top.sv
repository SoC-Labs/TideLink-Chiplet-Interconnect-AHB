// Cocotb wrapper for tidelink_autoneg — DEAD-I2C bare-link reproduce.
//
// Instantiates the CURRENT SHIPPING autoneg FSM
// (src/rtl/local_overrides/tidelink_autoneg.sv, the one wired into the
// bare-link / eth-chiplet builds — NOT the older deps copy that the
// cocotb/tidelink_autoneg suite compiles). AXI-Lite responses are driven by
// cocotb to model the I2C master core, so the test can present a DEAD I2C bus
// (every peer transaction NACKs) and observe that the SYNC-beacon enabler
// (local_training_mode_set) never pulses.
//
// vs. cocotb/tidelink_autoneg/tb_top.sv this adds the local-override-only
// ports (role_strap_i + the L4/finalize coordination + obs taps). role_strap_i
// is exposed so the test can strap this die MASTER (the bare-link posture);
// the coordination inputs are tied inactive (they only matter once the FSM
// reaches the training/finalize states, which the dead-I2C park never does).

module tb_top (
    // ── Clocks and Resets ──────────────────────────────────────────────
    input  logic        clk,
    input  logic        poresetn,

    // ── Configuration (from NEGO_* registers) ──────────────────────────
    input  logic        nego_en,
    input  logic        nego_start,
    input  logic  [1:0] nego_pri_sel,
    input  logic        nego_fallback,
    input  logic        nego_force_lock,

    // ── Priority inputs ────────────────────────────────────────────────
    input  logic [15:0] nego_priority_reg,
    input  logic [15:0] nego_priority_i,
    input  logic [15:0] puf_seed,
    input  logic        puf_ready,

    // ── Timeout ────────────────────────────────────────────────────────
    input  logic [31:0] nego_timeout_reg,

    // ── I2C bus monitoring ─────────────────────────────────────────────
    input  logic        i2c_sda_i,
    input  logic        i2c_scl_i,

    // ── I2C prescaler ──────────────────────────────────────────────────
    input  logic [15:0] i2c_prescale_reg,

    // ── Role strap (local_override only): NACK/timeout fallback role ────
    input  logic        role_strap_i,

    // ── AXI-Lite slave responses (driven by cocotb to model the I2C core) ─
    input  logic        m_axil_awready,
    input  logic        m_axil_wready,
    input  logic  [1:0] m_axil_bresp,
    input  logic        m_axil_bvalid,
    input  logic        m_axil_arready,
    input  logic [31:0] m_axil_rdata,
    input  logic  [1:0] m_axil_rresp,
    input  logic        m_axil_rvalid,

    // ── AXI-Lite master outputs (observable by cocotb) ─────────────────
    output logic  [7:0] m_axil_awaddr,
    output logic        m_axil_awvalid,
    output logic [31:0] m_axil_wdata,
    output logic  [3:0] m_axil_wstrb,
    output logic        m_axil_wvalid,
    output logic        m_axil_bready,
    output logic  [7:0] m_axil_araddr,
    output logic        m_axil_arvalid,
    output logic        m_axil_rready,

    // ── Role control outputs ───────────────────────────────────────────
    output logic        nego_role_r,
    output logic        nego_set_role_cfg,
    output logic        nego_role_value,
    output logic        nego_set_role_lock,

    // ── Status outputs ─────────────────────────────────────────────────
    output logic  [3:0] nego_state,
    output logic        nego_done,
    output logic        nego_error,
    output logic        nego_won,
    output logic        nego_lost,
    output logic        sda_start_seen,
    output logic        nego_error_irq,

    // ── Phase 2 mask-handshake ─────────────────────────────────────────
    input  logic        mask_hs_auto_en,
    input  logic  [7:0] local_tx_lane_mask_i,
    input  logic  [7:0] local_rx_lane_mask_i,
    output logic  [7:0] peer_tx_lane_mask_o,
    output logic  [7:0] peer_rx_lane_mask_o,
    output logic        mask_hs_local_match,
    output logic        mask_hs_local_fail,

    // ── Phase 3 I²C-train coordination ─────────────────────────────────
    input  logic        train_auto_en,
    input  logic        train_sw_step,
    input  logic        train_retrain_req,
    input  logic  [3:0] train_poll_timeout,
    input  logic  [7:0] train_fsm_wait_hi,
    input  logic  [7:0] local_swi_lane_locked_i,
    input  logic  [7:0] local_swi_lane_fault_i,
    input  logic        local_calibration_done_i,
    output logic        local_training_mode_set,
    output logic        local_training_mode_clr,
    output logic        local_swreset_pulse,
    output logic  [3:0] train_state_o,
    output logic        train_ok_o,
    output logic        train_fail_o,
    output logic        train_in_progress_o,
    output logic        train_peer_nack_o,
    output logic  [7:0] train_peer_lane_locked_o,
    output logic  [7:0] train_peer_lane_fault_o,
    output logic  [7:0] train_local_lane_fault_o,
    output logic        train_fail_irq_o
);

    tidelink_autoneg u_dut (
        .clk                (clk),
        .poresetn           (poresetn),
        .nego_en            (nego_en),
        .nego_start         (nego_start),
        .nego_pri_sel       (nego_pri_sel),
        .nego_fallback      (nego_fallback),
        .nego_force_lock    (nego_force_lock),
        .nego_priority_reg  (nego_priority_reg),
        .nego_priority_i    (nego_priority_i),
        .puf_seed           (puf_seed),
        .puf_ready          (puf_ready),
        .nego_timeout_reg   (nego_timeout_reg),
        .i2c_sda_i          (i2c_sda_i),
        .i2c_scl_i          (i2c_scl_i),
        .i2c_prescale_reg   (i2c_prescale_reg),
        .role_strap_i       (role_strap_i),
        .m_axil_awaddr      (m_axil_awaddr),
        .m_axil_awvalid     (m_axil_awvalid),
        .m_axil_awready     (m_axil_awready),
        .m_axil_wdata       (m_axil_wdata),
        .m_axil_wstrb       (m_axil_wstrb),
        .m_axil_wvalid      (m_axil_wvalid),
        .m_axil_wready      (m_axil_wready),
        .m_axil_bresp       (m_axil_bresp),
        .m_axil_bvalid      (m_axil_bvalid),
        .m_axil_bready      (m_axil_bready),
        .m_axil_araddr      (m_axil_araddr),
        .m_axil_arvalid     (m_axil_arvalid),
        .m_axil_arready     (m_axil_arready),
        .m_axil_rdata       (m_axil_rdata),
        .m_axil_rresp       (m_axil_rresp),
        .m_axil_rvalid      (m_axil_rvalid),
        .m_axil_rready      (m_axil_rready),
        .nego_role_r        (nego_role_r),
        .nego_set_role_cfg  (nego_set_role_cfg),
        .nego_role_value    (nego_role_value),
        .nego_set_role_lock (nego_set_role_lock),
        .nego_state         (nego_state),
        .nego_done          (nego_done),
        .nego_error         (nego_error),
        .nego_won           (nego_won),
        .nego_lost          (nego_lost),
        .sda_start_seen     (sda_start_seen),
        .nego_error_irq     (nego_error_irq),
        // Phase 2 mask-handshake
        .local_tx_lane_mask_i (local_tx_lane_mask_i),
        .local_rx_lane_mask_i (local_rx_lane_mask_i),
        .peer_tx_lane_mask_o  (peer_tx_lane_mask_o),
        .peer_rx_lane_mask_o  (peer_rx_lane_mask_o),
        .mask_hs_local_match  (mask_hs_local_match),
        .mask_hs_local_fail   (mask_hs_local_fail),
        .mask_hs_auto_en      (mask_hs_auto_en),
        // Phase 3 I²C-train coordination
        .train_auto_en             (train_auto_en),
        .train_sw_step             (train_sw_step),
        .train_retrain_req         (train_retrain_req),
        .train_poll_timeout        (train_poll_timeout),
        .train_fsm_wait_hi         (train_fsm_wait_hi),
        .local_swi_lane_locked_i   (local_swi_lane_locked_i),
        .local_swi_lane_fault_i    (local_swi_lane_fault_i),
        .local_calibration_done_i  (local_calibration_done_i),
        // L4 / finalize coordination — inactive (park never reaches training)
        .local_cal_in_hold_i       (1'b0),
        .local_fin_wait_i          (1'b0),
        .local_finalizing_i        (1'b0),
        .local_training_mode_set   (local_training_mode_set),
        .local_training_mode_clr   (local_training_mode_clr),
        .local_swreset_pulse       (local_swreset_pulse),
        .train_state_o             (train_state_o),
        .train_ok_o                (train_ok_o),
        .train_fail_o              (train_fail_o),
        .train_in_progress_o       (train_in_progress_o),
        .train_peer_nack_o         (train_peer_nack_o),
        .train_peer_lane_locked_o  (train_peer_lane_locked_o),
        .train_peer_lane_fault_o   (train_peer_lane_fault_o),
        .train_local_lane_fault_o  (train_local_lane_fault_o),
        .train_fail_irq_o          (train_fail_irq_o)
        // obs_*/fin_*/peer_ready_to_serve_o outputs left unconnected
    );

endmodule
