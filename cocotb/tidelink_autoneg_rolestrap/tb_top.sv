// PENDING-DECISION #5 — role-from-STRAP two-die NACK proof.
//
// Two tidelink_autoneg instances (the src/rtl/local_overrides shipping copy):
//   die_a: role_strap_i = 0 (master strap)
//   die_b: role_strap_i = 1 (slave  strap)
// Both are driven identically to the I2C-NACK terminal path. The test observes
// each die's nego_role_value (the value latched into role_cfg_reg).
//
//   ROLE_FROM_STRAP=0 (legacy trap): both -> 1 (slave, slave)  => NO master
//   ROLE_FROM_STRAP=1 (fix):         die_a -> 0, die_b -> 1     => (master, slave)
//
// MODE=default compiles with +define+TB_ROLE_STRAP_DEFAULT, which omits the
// parameter override entirely so the instances take tidelink_autoneg's OWN
// DEFAULT. That is what proves DECISION #3's global flip actually landed —
// an explicit override would prove only that the ternary works.
`ifndef ROLE_FROM_STRAP
  `define ROLE_FROM_STRAP 0
`endif

`ifdef TB_ROLE_STRAP_DEFAULT
  `define RFS_PARAM
`else
  `define RFS_PARAM , .ROLE_FROM_STRAP (`ROLE_FROM_STRAP)
`endif

// Training-entry fallback test (2026-07-25). Defaults leave the ROLE test
// bit-identical: train_auto_en OFF (the FSM never enters training) and
// TRAIN_ENTRY_FALLBACK=0 (= the module default). The training test sets
// TB_TRAIN_AUTO_EN=1 and TB_TRAIN_FALLBACK=1/0 for its A/B.
`ifndef TB_TRAIN_AUTO_EN
  `define TB_TRAIN_AUTO_EN 1'b0
`endif
`ifndef TB_TRAIN_FALLBACK
  `define TB_TRAIN_FALLBACK 1'b0
`endif

module tb_top (
    input  logic clk,
    input  logic poresetn,
    input  logic nego_en,
    input  logic nego_start,
    // per-die AXI-Lite response inputs (driven by the I2C-master model)
    input  logic a_awready, a_wready, a_bvalid, a_arready, a_rvalid,
    input  logic [31:0] a_rdata,
    input  logic b_awready, b_wready, b_bvalid, b_arready, b_rvalid,
    input  logic [31:0] b_rdata,
    // per-die AXI-Lite master outputs (observed by the model)
    output logic a_awvalid, a_wvalid, a_bready, a_arvalid, a_rready,
    output logic [7:0] a_araddr,
    output logic b_awvalid, b_wvalid, b_bready, b_arvalid, b_rready,
    output logic [7:0] b_araddr,
    // observation
    output logic a_role_value, a_set_role_cfg, a_done, a_lost, a_role_r,
    output logic b_role_value, b_set_role_cfg, b_done, b_lost, b_role_r,
    output logic [4:0] a_state, b_state,
    output logic a_train_set, b_train_set
);

    // ------------------------------------------------------------------ die_a
    tidelink_autoneg #(
        .NEGO_BASE_DELAY (200)                // short backoff for a fast test
        `RFS_PARAM
        , .TRAIN_ENTRY_FALLBACK (`TB_TRAIN_FALLBACK)
    ) u_die_a (
        .clk(clk), .poresetn(poresetn),
        .nego_en(nego_en), .nego_start(nego_start),
        .nego_pri_sel(2'd0), .nego_fallback(1'b1), .nego_force_lock(1'b1),
        .role_strap_i(1'b0),                  // MASTER strap
        .nego_priority_reg(16'd0), .nego_priority_i(16'd0),
        .puf_seed(16'd0), .puf_ready(1'b0),
        .nego_timeout_reg(32'd1_000_000),
        .i2c_sda_i(1'b1), .i2c_scl_i(1'b1), .i2c_prescale_reg(16'd500),
        .m_axil_awaddr(), .m_axil_awvalid(a_awvalid), .m_axil_awready(a_awready),
        .m_axil_wdata(), .m_axil_wstrb(), .m_axil_wvalid(a_wvalid), .m_axil_wready(a_wready),
        .m_axil_bresp(2'd0), .m_axil_bvalid(a_bvalid), .m_axil_bready(a_bready),
        .m_axil_araddr(a_araddr), .m_axil_arvalid(a_arvalid), .m_axil_arready(a_arready),
        .m_axil_rdata(a_rdata), .m_axil_rresp(2'd0), .m_axil_rvalid(a_rvalid), .m_axil_rready(a_rready),
        .nego_role_r(a_role_r), .nego_set_role_cfg(a_set_role_cfg), .nego_role_value(a_role_value),
        .nego_set_role_lock(),
        .nego_state(a_state), .nego_done(a_done), .nego_error(), .nego_won(), .nego_lost(a_lost),
        .sda_start_seen(), .nego_error_irq(),
        .mask_hs_auto_en(1'b0), .local_tx_lane_mask_i(8'hFF), .local_rx_lane_mask_i(8'hFF),
        .peer_tx_lane_mask_o(), .peer_rx_lane_mask_o(), .mask_hs_local_match(), .mask_hs_local_fail(),
        .train_auto_en(`TB_TRAIN_AUTO_EN), .train_sw_step(1'b0), .train_retrain_req(1'b0),
        .train_poll_timeout(4'd0), .train_fsm_wait_hi(8'd0),
        .local_swi_lane_locked_i(8'd0), .local_swi_lane_fault_i(8'd0), .local_calibration_done_i(1'b0),
        .local_training_mode_set(a_train_set), .local_training_mode_clr(), .local_swreset_pulse(),
        .train_state_o(), .train_ok_o(), .train_fail_o(), .train_in_progress_o(),
        .train_peer_nack_o(), .train_peer_lane_locked_o(), .train_peer_lane_fault_o(),
        .train_local_lane_fault_o(), .train_fail_irq_o()
    );

    // ------------------------------------------------------------------ die_b
    tidelink_autoneg #(
        .NEGO_BASE_DELAY (200)
        `RFS_PARAM
        , .TRAIN_ENTRY_FALLBACK (`TB_TRAIN_FALLBACK)
    ) u_die_b (
        .clk(clk), .poresetn(poresetn),
        .nego_en(nego_en), .nego_start(nego_start),
        .nego_pri_sel(2'd0), .nego_fallback(1'b1), .nego_force_lock(1'b1),
        .role_strap_i(1'b1),                  // SLAVE strap
        .nego_priority_reg(16'd0), .nego_priority_i(16'd0),
        .puf_seed(16'd0), .puf_ready(1'b0),
        .nego_timeout_reg(32'd1_000_000),
        .i2c_sda_i(1'b1), .i2c_scl_i(1'b1), .i2c_prescale_reg(16'd500),
        .m_axil_awaddr(), .m_axil_awvalid(b_awvalid), .m_axil_awready(b_awready),
        .m_axil_wdata(), .m_axil_wstrb(), .m_axil_wvalid(b_wvalid), .m_axil_wready(b_wready),
        .m_axil_bresp(2'd0), .m_axil_bvalid(b_bvalid), .m_axil_bready(b_bready),
        .m_axil_araddr(b_araddr), .m_axil_arvalid(b_arvalid), .m_axil_arready(b_arready),
        .m_axil_rdata(b_rdata), .m_axil_rresp(2'd0), .m_axil_rvalid(b_rvalid), .m_axil_rready(b_rready),
        .nego_role_r(b_role_r), .nego_set_role_cfg(b_set_role_cfg), .nego_role_value(b_role_value),
        .nego_set_role_lock(),
        .nego_state(b_state), .nego_done(b_done), .nego_error(), .nego_won(), .nego_lost(b_lost),
        .sda_start_seen(), .nego_error_irq(),
        .mask_hs_auto_en(1'b0), .local_tx_lane_mask_i(8'hFF), .local_rx_lane_mask_i(8'hFF),
        .peer_tx_lane_mask_o(), .peer_rx_lane_mask_o(), .mask_hs_local_match(), .mask_hs_local_fail(),
        .train_auto_en(`TB_TRAIN_AUTO_EN), .train_sw_step(1'b0), .train_retrain_req(1'b0),
        .train_poll_timeout(4'd0), .train_fsm_wait_hi(8'd0),
        .local_swi_lane_locked_i(8'd0), .local_swi_lane_fault_i(8'd0), .local_calibration_done_i(1'b0),
        .local_training_mode_set(b_train_set), .local_training_mode_clr(), .local_swreset_pulse(),
        .train_state_o(), .train_ok_o(), .train_fail_o(), .train_in_progress_o(),
        .train_peer_nack_o(), .train_peer_lane_locked_o(), .train_peer_lane_fault_o(),
        .train_local_lane_fault_o(), .train_fail_irq_o()
    );

endmodule
