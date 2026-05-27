// =============================================================================
// tb_top.sv  ── Two-instance axi_chiplet_controller pair with AUTOCAL_ENABLE=1
//
// Purpose
// -------
// Reproduce the M→S asymmetric calibrator/PHY bug at the smallest possible
// RTL scope. Strips the entire `tidelink_top` wrapper (FC adapter, returner,
// XHB500, FIFO, PTP, AHB, glue) and instantiates only the chiplet controller
// — which already contains the calibrator, Wlink, PHY, autoneg, R8 SW regs
// — twice, cross-wired through the same pad_skid as cocotb/wlink_pair.
//
// Difference vs. cocotb/wlink_pair/tb_top.sv:
//   * Explicit `.AUTOCAL_ENABLE(1'b1)` parameter override on BOTH instances.
//     (wlink_pair runs the default 0 and PASSES bidirectionally; the bug
//     in tidelink_top_pair only appears when AUTOCAL_ENABLE=1 turns the
//     in-RTL per-lane calibrator FSM on.)
//   * Per-lane skid parametrisation stripped (only uniform SKID_BITS); we
//     do not exercise skid sweeps in this env.
//   * `idelay_ref_clk` / `idelay_rst` ports tied to 1'b0 (USE_IDELAY=0
//     default — sim path bypasses Xilinx IDELAYE2).
// =============================================================================
`timescale 1ns/1ps

module tb_top #(
    parameter int SKID_BITS = `ifdef TB_TOP_SKID_BITS `TB_TOP_SKID_BITS `else 0 `endif
);

    // ----- Clocks & resets ----------------------------------------------------
    logic master_clk = 1'b0;
    logic slave_clk  = 1'b0;
    logic apb_clk;
    assign apb_clk = master_clk;

    logic m_poresetn = 1'b0, m_hresetn = 1'b0;
    logic s_poresetn = 1'b0, s_hresetn = 1'b0;
    logic poresetn, hresetn;
    assign poresetn = m_poresetn & s_poresetn;
    assign hresetn  = m_hresetn  & s_hresetn;

    // ----- Cross-wired GPIO PHY pads (master↔slave, via per-direction skid) ---
    wire        m_pad_clk_tx, s_pad_clk_tx;
    wire [7:0]  m_pad_tx,     s_pad_tx;
    wire        m_pad_clk_tx_skid, s_pad_clk_tx_skid;
    wire [7:0]  m_pad_tx_skid,     s_pad_tx_skid;

    pad_skid #(.SKID_BITS(SKID_BITS), .LANES(8)) u_skid_m2s (
        .pad_clk_in   (m_pad_clk_tx),
        .pad_data_in  (m_pad_tx),
        .pad_clk_out  (m_pad_clk_tx_skid),
        .pad_data_out (m_pad_tx_skid)
    );
    pad_skid #(.SKID_BITS(SKID_BITS), .LANES(8)) u_skid_s2m (
        .pad_clk_in   (s_pad_clk_tx),
        .pad_data_in  (s_pad_tx),
        .pad_clk_out  (s_pad_clk_tx_skid),
        .pad_data_out (s_pad_tx_skid)
    );

    // ----- APB master/slave interface (cocotb-driven) ------------------------
    logic        m_apb_psel, m_apb_penable, m_apb_pwrite;
    logic [12:0] m_apb_paddr;
    logic [2:0]  m_apb_pprot;
    logic [3:0]  m_apb_pstrb;
    logic [31:0] m_apb_pwdata;
    wire  [31:0] m_apb_prdata;
    wire         m_apb_pready, m_apb_pslverr;

    logic        s_apb_psel, s_apb_penable, s_apb_pwrite;
    logic [12:0] s_apb_paddr;
    logic [2:0]  s_apb_pprot;
    logic [3:0]  s_apb_pstrb;
    logic [31:0] s_apb_pwdata;
    wire  [31:0] s_apb_prdata;
    wire         s_apb_pready, s_apb_pslverr;

    // ctrl_reg interface — 4-bit addr (bit[3]=1 selects Region 8 inside chiplet)
    logic        m_ctrl_reg_write,  s_ctrl_reg_write;
    logic [3:0]  m_ctrl_reg_addr,   s_ctrl_reg_addr;
    logic [31:0] m_ctrl_reg_wdata,  s_ctrl_reg_wdata;
    wire  [31:0] m_ctrl_reg_rdata,  s_ctrl_reg_rdata;

    // Observable status
    wire m_role_is_master, s_role_is_master;
    wire m_role_locked,    s_role_locked;
    wire m_interrupt,      s_interrupt;
    wire m_tx_link_idle,   s_tx_link_idle;

    // Debug straps (default ON so APB drives can land before role_lock)
    logic m_apb_debug_unlock = 1'b1;
    logic s_apb_debug_unlock = 1'b1;
    logic m_mask_hs_bypass   = 1'b1;
    logic s_mask_hs_bypass   = 1'b1;

    // ----- Master ────────────────────────────────────────────────────────────
    axi_chiplet_controller #(
        .AUTOCAL_ENABLE(1'b1)
    ) u_master (
        .apb_clk(master_clk), .app_clk(master_clk), .user_hsclk(master_clk),
        .poresetn(m_poresetn), .hresetn(m_hresetn),
        .sb_reset_in(1'b0), .sb_reset_out(), .sb_wake(),

        .role_strap_i(1'b0),                 // master
        .role_is_master_o(m_role_is_master),
        .role_locked_o(m_role_locked),
        .apb_debug_unlock_i(m_apb_debug_unlock),
        .mask_hs_bypass_i(m_mask_hs_bypass),

        .nego_priority_i(16'h8000), .puf_seed(16'hA5A5), .puf_ready(1'b1),
        .nego_error_irq(),

        .ctrl_reg_write(m_ctrl_reg_write), .ctrl_reg_addr(m_ctrl_reg_addr),
        .ctrl_reg_wdata(m_ctrl_reg_wdata), .ctrl_reg_rdata(m_ctrl_reg_rdata),

        .apb_psel(m_apb_psel), .apb_paddr(m_apb_paddr), .apb_penable(m_apb_penable),
        .apb_pprot(m_apb_pprot), .apb_pstrb(m_apb_pstrb), .apb_pwrite(m_apb_pwrite),
        .apb_pwdata(m_apb_pwdata), .apb_prdata(m_apb_prdata),
        .apb_pready(m_apb_pready), .apb_pslverr(m_apb_pslverr),

        // AXI target — tie off
        .axi_tgt_0_aw_valid(1'b0), .axi_tgt_0_aw_ready(),
        .axi_tgt_0_aw_bits_id('0), .axi_tgt_0_aw_bits_addr('0),
        .axi_tgt_0_aw_bits_len('0), .axi_tgt_0_aw_bits_size('0),
        .axi_tgt_0_aw_bits_burst('0), .axi_tgt_0_aw_bits_lock(1'b0),
        .axi_tgt_0_aw_bits_cache('0), .axi_tgt_0_aw_bits_prot('0),
        .axi_tgt_0_aw_bits_qos('0),
        .axi_tgt_0_w_valid(1'b0), .axi_tgt_0_w_ready(),
        .axi_tgt_0_w_bits_data('0), .axi_tgt_0_w_bits_strb('0),
        .axi_tgt_0_w_bits_last(1'b0),
        .axi_tgt_0_b_valid(), .axi_tgt_0_b_ready(1'b1),
        .axi_tgt_0_b_bits_id(), .axi_tgt_0_b_bits_resp(),
        .axi_tgt_0_ar_valid(1'b0), .axi_tgt_0_ar_ready(),
        .axi_tgt_0_ar_bits_id('0), .axi_tgt_0_ar_bits_addr('0),
        .axi_tgt_0_ar_bits_len('0), .axi_tgt_0_ar_bits_size('0),
        .axi_tgt_0_ar_bits_burst('0), .axi_tgt_0_ar_bits_lock(1'b0),
        .axi_tgt_0_ar_bits_cache('0), .axi_tgt_0_ar_bits_prot('0),
        .axi_tgt_0_ar_bits_qos('0),
        .axi_tgt_0_r_valid(), .axi_tgt_0_r_ready(1'b1),
        .axi_tgt_0_r_bits_id(), .axi_tgt_0_r_bits_data(),
        .axi_tgt_0_r_bits_resp(), .axi_tgt_0_r_bits_last(),

        // AXI initiator — tie off
        .axi_ini_0_aw_valid(), .axi_ini_0_aw_ready(1'b1),
        .axi_ini_0_aw_bits_id(), .axi_ini_0_aw_bits_addr(),
        .axi_ini_0_aw_bits_len(), .axi_ini_0_aw_bits_size(),
        .axi_ini_0_aw_bits_burst(), .axi_ini_0_aw_bits_lock(),
        .axi_ini_0_aw_bits_cache(), .axi_ini_0_aw_bits_prot(),
        .axi_ini_0_aw_bits_qos(),
        .axi_ini_0_w_valid(), .axi_ini_0_w_ready(1'b1),
        .axi_ini_0_w_bits_data(), .axi_ini_0_w_bits_strb(),
        .axi_ini_0_w_bits_last(),
        .axi_ini_0_b_valid(1'b0), .axi_ini_0_b_ready(),
        .axi_ini_0_b_bits_id('0), .axi_ini_0_b_bits_resp('0),
        .axi_ini_0_ar_valid(), .axi_ini_0_ar_ready(1'b1),
        .axi_ini_0_ar_bits_id(), .axi_ini_0_ar_bits_addr(),
        .axi_ini_0_ar_bits_len(), .axi_ini_0_ar_bits_size(),
        .axi_ini_0_ar_bits_burst(), .axi_ini_0_ar_bits_lock(),
        .axi_ini_0_ar_bits_cache(), .axi_ini_0_ar_bits_prot(),
        .axi_ini_0_ar_bits_qos(),
        .axi_ini_0_r_valid(1'b0), .axi_ini_0_r_ready(),
        .axi_ini_0_r_bits_id('0), .axi_ini_0_r_bits_data('0),
        .axi_ini_0_r_bits_resp('0), .axi_ini_0_r_bits_last(1'b0),

        // GeneralBus / TideLink / PTP — tie off
        .generalbus_in(32'h0), .generalbus_out(),
        .tidelink_in(50'h0), .tidelink_out(),
        .ptp_in(26'h0), .ptp_out(),
        .tx_link_idle(m_tx_link_idle),

        // s_i2c_axi — tie off
        .s_i2c_axi_awvalid(1'b0), .s_i2c_axi_awid('0), .s_i2c_axi_awaddr('0),
        .s_i2c_axi_awlen('0), .s_i2c_axi_awsize('0), .s_i2c_axi_awburst('0),
        .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache('0), .s_i2c_axi_awprot('0),
        .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata('0), .s_i2c_axi_wstrb('0),
        .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(),
        .s_i2c_axi_bready(1'b1),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid('0), .s_i2c_axi_araddr('0),
        .s_i2c_axi_arlen('0), .s_i2c_axi_arsize('0), .s_i2c_axi_arburst('0),
        .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache('0), .s_i2c_axi_arprot('0),
        .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(),
        .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b1),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq(),

        .i2c_scl_i(1'b1), .i2c_scl_o(), .i2c_scl_t(),
        .i2c_sda_i(1'b1), .i2c_sda_o(), .i2c_sda_t(),

        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out(),
        .interrupt(m_interrupt),

        .pad_clk_tx(m_pad_clk_tx), .pad_tx(m_pad_tx),
        .pad_clk_rx(s_pad_clk_tx_skid), .pad_rx(s_pad_tx_skid),

        // IDELAY ports — sim/ASIC bypass (USE_IDELAY=0 default)
        .idelay_ref_clk(1'b0), .idelay_rst(1'b0)
    );

    // ----- Slave ─────────────────────────────────────────────────────────────
    axi_chiplet_controller #(
        .AUTOCAL_ENABLE(1'b1)
    ) u_slave (
        .apb_clk(slave_clk), .app_clk(slave_clk), .user_hsclk(slave_clk),
        .poresetn(s_poresetn), .hresetn(s_hresetn),
        .sb_reset_in(1'b0), .sb_reset_out(), .sb_wake(),

        .role_strap_i(1'b1),                 // slave
        .role_is_master_o(s_role_is_master),
        .role_locked_o(s_role_locked),
        .apb_debug_unlock_i(s_apb_debug_unlock),
        .mask_hs_bypass_i(s_mask_hs_bypass),

        .nego_priority_i(16'h7FFF), .puf_seed(16'h5A5A), .puf_ready(1'b1),
        .nego_error_irq(),

        .ctrl_reg_write(s_ctrl_reg_write), .ctrl_reg_addr(s_ctrl_reg_addr),
        .ctrl_reg_wdata(s_ctrl_reg_wdata), .ctrl_reg_rdata(s_ctrl_reg_rdata),

        .apb_psel(s_apb_psel), .apb_paddr(s_apb_paddr), .apb_penable(s_apb_penable),
        .apb_pprot(s_apb_pprot), .apb_pstrb(s_apb_pstrb), .apb_pwrite(s_apb_pwrite),
        .apb_pwdata(s_apb_pwdata), .apb_prdata(s_apb_prdata),
        .apb_pready(s_apb_pready), .apb_pslverr(s_apb_pslverr),

        .axi_tgt_0_aw_valid(1'b0), .axi_tgt_0_aw_ready(),
        .axi_tgt_0_aw_bits_id('0), .axi_tgt_0_aw_bits_addr('0),
        .axi_tgt_0_aw_bits_len('0), .axi_tgt_0_aw_bits_size('0),
        .axi_tgt_0_aw_bits_burst('0), .axi_tgt_0_aw_bits_lock(1'b0),
        .axi_tgt_0_aw_bits_cache('0), .axi_tgt_0_aw_bits_prot('0),
        .axi_tgt_0_aw_bits_qos('0),
        .axi_tgt_0_w_valid(1'b0), .axi_tgt_0_w_ready(),
        .axi_tgt_0_w_bits_data('0), .axi_tgt_0_w_bits_strb('0),
        .axi_tgt_0_w_bits_last(1'b0),
        .axi_tgt_0_b_valid(), .axi_tgt_0_b_ready(1'b1),
        .axi_tgt_0_b_bits_id(), .axi_tgt_0_b_bits_resp(),
        .axi_tgt_0_ar_valid(1'b0), .axi_tgt_0_ar_ready(),
        .axi_tgt_0_ar_bits_id('0), .axi_tgt_0_ar_bits_addr('0),
        .axi_tgt_0_ar_bits_len('0), .axi_tgt_0_ar_bits_size('0),
        .axi_tgt_0_ar_bits_burst('0), .axi_tgt_0_ar_bits_lock(1'b0),
        .axi_tgt_0_ar_bits_cache('0), .axi_tgt_0_ar_bits_prot('0),
        .axi_tgt_0_ar_bits_qos('0),
        .axi_tgt_0_r_valid(), .axi_tgt_0_r_ready(1'b1),
        .axi_tgt_0_r_bits_id(), .axi_tgt_0_r_bits_data(),
        .axi_tgt_0_r_bits_resp(), .axi_tgt_0_r_bits_last(),

        .axi_ini_0_aw_valid(), .axi_ini_0_aw_ready(1'b1),
        .axi_ini_0_aw_bits_id(), .axi_ini_0_aw_bits_addr(),
        .axi_ini_0_aw_bits_len(), .axi_ini_0_aw_bits_size(),
        .axi_ini_0_aw_bits_burst(), .axi_ini_0_aw_bits_lock(),
        .axi_ini_0_aw_bits_cache(), .axi_ini_0_aw_bits_prot(),
        .axi_ini_0_aw_bits_qos(),
        .axi_ini_0_w_valid(), .axi_ini_0_w_ready(1'b1),
        .axi_ini_0_w_bits_data(), .axi_ini_0_w_bits_strb(),
        .axi_ini_0_w_bits_last(),
        .axi_ini_0_b_valid(1'b0), .axi_ini_0_b_ready(),
        .axi_ini_0_b_bits_id('0), .axi_ini_0_b_bits_resp('0),
        .axi_ini_0_ar_valid(), .axi_ini_0_ar_ready(1'b1),
        .axi_ini_0_ar_bits_id(), .axi_ini_0_ar_bits_addr(),
        .axi_ini_0_ar_bits_len(), .axi_ini_0_ar_bits_size(),
        .axi_ini_0_ar_bits_burst(), .axi_ini_0_ar_bits_lock(),
        .axi_ini_0_ar_bits_cache(), .axi_ini_0_ar_bits_prot(),
        .axi_ini_0_ar_bits_qos(),
        .axi_ini_0_r_valid(1'b0), .axi_ini_0_r_ready(),
        .axi_ini_0_r_bits_id('0), .axi_ini_0_r_bits_data('0),
        .axi_ini_0_r_bits_resp('0), .axi_ini_0_r_bits_last(1'b0),

        .generalbus_in(32'h0), .generalbus_out(),
        .tidelink_in(50'h0), .tidelink_out(),
        .ptp_in(26'h0), .ptp_out(),
        .tx_link_idle(s_tx_link_idle),

        .s_i2c_axi_awvalid(1'b0), .s_i2c_axi_awid('0), .s_i2c_axi_awaddr('0),
        .s_i2c_axi_awlen('0), .s_i2c_axi_awsize('0), .s_i2c_axi_awburst('0),
        .s_i2c_axi_awlock(1'b0), .s_i2c_axi_awcache('0), .s_i2c_axi_awprot('0),
        .s_i2c_axi_awready(),
        .s_i2c_axi_wvalid(1'b0), .s_i2c_axi_wdata('0), .s_i2c_axi_wstrb('0),
        .s_i2c_axi_wlast(1'b0), .s_i2c_axi_wready(),
        .s_i2c_axi_bvalid(), .s_i2c_axi_bid(), .s_i2c_axi_bresp(),
        .s_i2c_axi_bready(1'b1),
        .s_i2c_axi_arvalid(1'b0), .s_i2c_axi_arid('0), .s_i2c_axi_araddr('0),
        .s_i2c_axi_arlen('0), .s_i2c_axi_arsize('0), .s_i2c_axi_arburst('0),
        .s_i2c_axi_arlock(1'b0), .s_i2c_axi_arcache('0), .s_i2c_axi_arprot('0),
        .s_i2c_axi_arready(),
        .s_i2c_axi_rvalid(), .s_i2c_axi_rid(), .s_i2c_axi_rdata(),
        .s_i2c_axi_rresp(), .s_i2c_axi_rlast(), .s_i2c_axi_rready(1'b1),
        .i2c_nbsy_irq(), .i2c_nrd_empty_irq(),

        .i2c_scl_i(1'b1), .i2c_scl_o(), .i2c_scl_t(),
        .i2c_sda_i(1'b1), .i2c_sda_o(), .i2c_sda_t(),

        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out(),
        .interrupt(s_interrupt),

        .pad_clk_tx(s_pad_clk_tx), .pad_tx(s_pad_tx),
        .pad_clk_rx(m_pad_clk_tx_skid), .pad_rx(m_pad_tx_skid),

        .idelay_ref_clk(1'b0), .idelay_rst(1'b0)
    );

    // ---------------------------------------------------------------
    // Top-level mirrors of useful internals for cocotb probing.
    // These avoid long hierarchical paths in Python.
    // ---------------------------------------------------------------
    wire [3:0] m_cal_cur_state = u_master.u_calibrator.cur_state;
    wire [3:0] s_cal_cur_state = u_slave .u_calibrator.cur_state;
    wire       m_cal_training_mode = u_master.cal_training_mode_w;
    wire       s_cal_training_mode = u_slave .cal_training_mode_w;
    wire       m_cal_calibration_done = u_master.cal_calibration_done_w;
    wire       s_cal_calibration_done = u_slave .cal_calibration_done_w;
    wire [7:0] m_lane_locked_w        = u_master.lane_locked_w;
    wire [7:0] s_lane_locked_w        = u_slave .lane_locked_w;
    wire [31:0] m_phase_offset        = u_master.cal_phase_offset_w;
    wire [31:0] s_phase_offset        = u_slave .cal_phase_offset_w;
    wire [23:0] m_bit_slip            = u_master.cal_bit_slip_w;
    wire [23:0] s_bit_slip            = u_slave .cal_bit_slip_w;

    // VCD dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
