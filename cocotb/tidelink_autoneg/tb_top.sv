// Cocotb wrapper for tidelink_autoneg unit testing
//
// Instantiates the tidelink_autoneg FSM directly (not the full
// axi_chiplet_controller). AXI-Lite responses are driven by cocotb
// to simulate the I2C master core's behavior.

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

    // ── AXI-Lite slave responses (driven by cocotb to simulate I2C master) ─
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

    // ── Phase 2 mask-handshake (tied off for autoneg-only tests) ───────
    input  logic        mask_hs_auto_en,
    input  logic  [7:0] local_tx_lane_mask_i,
    input  logic  [7:0] local_rx_lane_mask_i,
    output logic  [7:0] peer_tx_lane_mask_o,
    output logic  [7:0] peer_rx_lane_mask_o,
    output logic        mask_hs_local_match,
    output logic        mask_hs_local_fail,

    // ── Phase 3 I²C-train coordination (tied off for autoneg-only tests) ─
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
        .mask_hs_auto_en      (mask_hs_auto_en)
        // Phase 3 I²C-train coordination ports are not present on this branch
        // (added in a later commit). Tie-offs of the unconnected tb_top
        // train_* I/Os below keep the harness pin-compatible with sister
        // testbenches without binding into the DUT.
    );

    // Drive constant 0 onto the test-bench tb_top train_* outputs so cocotb
    // can still read them (matches the harness ABI for the other autoneg
    // testbenches in the tree). These are NOT connected to the DUT.
    assign local_training_mode_set  = 1'b0;
    assign local_training_mode_clr  = 1'b0;
    assign local_swreset_pulse      = 1'b0;
    assign train_state_o            = 4'd0;
    assign train_ok_o               = 1'b0;
    assign train_fail_o             = 1'b0;
    assign train_in_progress_o      = 1'b0;
    assign train_peer_nack_o        = 1'b0;
    assign train_peer_lane_locked_o = 8'd0;
    assign train_peer_lane_fault_o  = 8'd0;
    assign train_local_lane_fault_o = 8'd0;
    assign train_fail_irq_o         = 1'b0;

endmodule
