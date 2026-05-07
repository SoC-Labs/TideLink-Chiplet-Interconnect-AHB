// =============================================================================
// tb_top.sv — Two-instance Wlink/chiplet-controller pair simulation
//
// Tests the bring-up handshake between two axi_chiplet_controller instances
// cross-wired via their GPIO PHY pads. Both instances share apb_clk (the most
// optimistic case — real boards have independent PLLs). Cocotb drives the APB
// of each instance and observes link state.
//
// Motivation: bench testing on Pynq-Z2 pair shows per-FC FCSMs never advance
// out of state 1; cr_pkt_seen never latches. This testbench answers:
// "does the protocol bring up at all when both sides are RTL-clean and use a
//  perfectly-shared clock?"
// =============================================================================
`timescale 1ns/1ps

module tb_top;

    // ----- Clocks & resets ----------------------------------------------------
    // Default: shared 50 MHz clock (optimistic — same package, common PLL).
    // Drift mode: cocotb sets DRIFT_PPM > 0 via setattr to delay slave's edge
    //             slightly each cycle, simulating independent PLLs.
    // The slave's apb_clk / app_clk / user_hsclk are on `slave_clk`. The
    // master's are on `master_clk`. pad_clk_tx is forwarded across to the
    // peer's pad_clk_rx — so each side's RX is on the *peer's* clock.

    // Both clocks driven by cocotb's Clock class so each test can pick its
    // own period. master_clk and slave_clk are initialised low; cocotb
    // starts each with the desired period inside the test setup.
    logic master_clk = 1'b0;
    logic slave_clk  = 1'b0;
    logic apb_clk;                          // alias for cocotb compat
    assign apb_clk = master_clk;

    // Per-side resets — each can be deasserted independently to simulate
    // staggered POR.
    logic m_poresetn = 1'b0, m_hresetn = 1'b0;
    logic s_poresetn = 1'b0, s_hresetn = 1'b0;
    // For backward compat with original test:
    logic poresetn, hresetn;
    assign poresetn = m_poresetn & s_poresetn;
    assign hresetn  = m_hresetn  & s_hresetn;

    // ----- Cross-wired GPIO PHY pads ------------------------------------------
    wire        m_pad_clk_tx, s_pad_clk_tx;
    wire [7:0]  m_pad_tx,     s_pad_tx;

    // ----- APB master/slave interface (cocotb drives via DUT_M / DUT_S) -------
    // Master APB
    logic        m_apb_psel, m_apb_penable, m_apb_pwrite;
    logic [12:0] m_apb_paddr;
    logic [2:0]  m_apb_pprot;
    logic [3:0]  m_apb_pstrb;
    logic [31:0] m_apb_pwdata;
    wire  [31:0] m_apb_prdata;
    wire         m_apb_pready, m_apb_pslverr;
    // Slave APB
    logic        s_apb_psel, s_apb_penable, s_apb_pwrite;
    logic [12:0] s_apb_paddr;
    logic [2:0]  s_apb_pprot;
    logic [3:0]  s_apb_pstrb;
    logic [31:0] s_apb_pwdata;
    wire  [31:0] s_apb_prdata;
    wire         s_apb_pready, s_apb_pslverr;

    // ----- ctrl_reg interface (used for ROLE_CFG lock) ------------------------
    logic        m_ctrl_reg_write,  s_ctrl_reg_write;
    logic [2:0]  m_ctrl_reg_addr,   s_ctrl_reg_addr;
    logic [31:0] m_ctrl_reg_wdata,  s_ctrl_reg_wdata;
    wire  [31:0] m_ctrl_reg_rdata,  s_ctrl_reg_rdata;

    // ----- Observable status --------------------------------------------------
    wire m_role_is_master, s_role_is_master;
    wire m_role_locked,    s_role_locked;
    wire m_interrupt,      s_interrupt;
    wire m_tx_link_idle,   s_tx_link_idle;

    // Debug strap (default 0; set high in cocotb to ungate slave APB writes)
    logic m_apb_debug_unlock = 1'b0;
    logic s_apb_debug_unlock = 1'b0;

    // Peer-mask handshake bypass (added 2026-05-06): the chiplet controller's
    // role_lock_reg now refuses to latch unless mask_hs_match | mask_hs_bypass_i.
    // For the wlink_pair sim we keep the gate fully open — the sim cross-wires
    // the lane-mask sideband internally so the autoneg-driven handshake doesn't
    // apply, and we want role_lock to behave identically to the pre-handshake
    // RTL. Production silicon should drive this from a real strap.
    logic m_mask_hs_bypass = 1'b1;
    logic s_mask_hs_bypass = 1'b1;

    // ----- Master instance ----------------------------------------------------
    axi_chiplet_controller u_master (
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

        // AXI initiator — tie off (sink ready=1, return inactive)
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

        // I2C pins — tie idle high
        .i2c_scl_i(1'b1), .i2c_scl_o(), .i2c_scl_t(),
        .i2c_sda_i(1'b1), .i2c_sda_o(), .i2c_sda_t(),

        // Scan / DFT — tie off
        .scan_mode(1'b0), .scan_asyncrst_ctrl(1'b0), .scan_clk(1'b0),
        .scan_shift(1'b0), .scan_in(1'b0), .scan_out(),
        .interrupt(m_interrupt),

        // PHY pads — cross-wired
        .pad_clk_tx(m_pad_clk_tx), .pad_tx(m_pad_tx),
        .pad_clk_rx(s_pad_clk_tx), .pad_rx(s_pad_tx)
    );

    // ----- Slave instance -----------------------------------------------------
    axi_chiplet_controller u_slave (
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
        .pad_clk_rx(m_pad_clk_tx), .pad_rx(m_pad_tx)
    );

    // VCD dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
