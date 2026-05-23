// =============================================================================
// tb_top.sv — phc_pair: two-instance Wlink + tidelink_ptp pair
//
// Reproduces the HW PHC slave-RX gap in simulation.
//
// Setup:
//   - Two axi_chiplet_controller (Wlink) instances cross-wired through GPIO
//     PHY pads (same as wlink_pair).
//   - Each side has a tidelink_ptp instance wired to that Wlink's
//     ptp_in/ptp_out short-packet interface.
//   - Master tidelink_ptp.ptp_sp_tx_*  -> Wlink.ptp_in  (master)
//   - Slave  Wlink.ptp_out (slave)     -> Slave tidelink_ptp.ptp_sp_rx_*
//
// What this lets cocotb observe end-to-end:
//   master HW_SYNC fires -> Wlink TX -> GPIO PHY -> Wlink RX (slave) ->
//   slave tidelink_ptp.ptp_sp_rx_valid -> sync_rx_done / PTP_CTRL[2] (rx_valid)
//
// The HW PHC failure (docs/PHC_PHASE1_HW_REPORT.md §"Build #9 retry") manifests
// as: master HW_SYNC_STATUS advances (FSM firing) but slave never observes a
// short packet RX. test_phc_hw_sync_pair.py reproduces that gap and marks it
// xfail until the slave-RX wiring is fixed.
// =============================================================================
`timescale 1ns/1ps

module tb_top;

    // ----- Clocks & resets ---------------------------------------------------
    logic master_clk = 1'b0;
    logic slave_clk  = 1'b0;
    logic apb_clk;
    assign apb_clk = master_clk;

    // §9 FPGA-models mode: when PHC_PAIR_USE_FPGA_MODELS is defined the
    // axi_chiplet_controller instances are parameterised with USE_IDELAY=1
    // and USE_CLKBUF=1 — i.e. exactly what the pynq-z2-pair-all bitstream
    // builds. Real Xilinx IDELAYE2 / IDELAYCTRL / BUFG unisim cells are
    // referenced; the Makefile must pull them in (+y unisims, glbl.v).
    // A 200 MHz reference clock is generated for IDELAYCTRL.
    logic idelay_ref_clk = 1'b0;
    logic idelay_rst     = 1'b1;
    initial begin
        // 200 MHz reference (5 ns period)
        forever #2.5 idelay_ref_clk = ~idelay_ref_clk;
    end
    initial begin
        // Release after 200 ns so the BUFG/IDELAYCTRL settle before
        // master/slave hresetn deasserts (cocotb releases that ~1us in).
        #200 idelay_rst = 1'b0;
    end

    logic m_poresetn = 1'b0, m_hresetn = 1'b0;
    logic s_poresetn = 1'b0, s_hresetn = 1'b0;

    // ----- Cross-wired GPIO PHY pads (no skid; sim-clean shared clock) -------
    wire        m_pad_clk_tx, s_pad_clk_tx;
    wire [7:0]  m_pad_tx,     s_pad_tx;

    // ----- APB master/slave (drives Wlink config) ----------------------------
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

    // ctrl_reg interface (used for ROLE_CFG lock)
    logic        m_ctrl_reg_write,  s_ctrl_reg_write;
    logic [3:0]  m_ctrl_reg_addr,   s_ctrl_reg_addr;
    logic [31:0] m_ctrl_reg_wdata,  s_ctrl_reg_wdata;
    wire  [31:0] m_ctrl_reg_rdata,  s_ctrl_reg_rdata;

    wire m_role_is_master, s_role_is_master;
    wire m_role_locked,    s_role_locked;
    wire m_interrupt,      s_interrupt;
    wire m_tx_link_idle,   s_tx_link_idle;

    logic m_apb_debug_unlock = 1'b1;  // ungate slave APB writes too
    logic s_apb_debug_unlock = 1'b1;
    logic m_mask_hs_bypass   = 1'b1;
    logic s_mask_hs_bypass   = 1'b1;

    // ----- Per-side ptp_in / ptp_out (26 bits each) --------------------------
    // ptp_in  = {ptp_sp_tx_valid, ptp_sp_tx_data_id[7:0], ptp_sp_tx_payload[15:0], ptp_sp_rx_accept}
    // ptp_out = {ptp_sp_tx_ready, ptp_sp_rx_valid, ptp_sp_rx_data_id[7:0], ptp_sp_rx_payload[15:0]}
    wire [25:0] m_ptp_in;
    wire [25:0] m_ptp_out;
    wire [25:0] s_ptp_in;
    wire [25:0] s_ptp_out;

    // Master side: tidelink_ptp signals
    wire        m_ptp_sp_tx_valid;
    wire [7:0]  m_ptp_sp_tx_data_id;
    wire [15:0] m_ptp_sp_tx_payload;
    wire        m_ptp_sp_tx_ready;
    wire        m_ptp_sp_rx_valid;
    wire [7:0]  m_ptp_sp_rx_data_id;
    wire [15:0] m_ptp_sp_rx_payload;
    wire        m_ptp_sp_rx_accept;
    assign m_ptp_in            = {m_ptp_sp_tx_valid, m_ptp_sp_tx_data_id, m_ptp_sp_tx_payload, m_ptp_sp_rx_accept};
    assign m_ptp_sp_tx_ready   = m_ptp_out[25];
    assign m_ptp_sp_rx_valid   = m_ptp_out[24];
    assign m_ptp_sp_rx_data_id = m_ptp_out[23:16];
    assign m_ptp_sp_rx_payload = m_ptp_out[15:0];

    // Slave side: tidelink_ptp signals
    wire        s_ptp_sp_tx_valid;
    wire [7:0]  s_ptp_sp_tx_data_id;
    wire [15:0] s_ptp_sp_tx_payload;
    wire        s_ptp_sp_tx_ready;
    wire        s_ptp_sp_rx_valid;
    wire [7:0]  s_ptp_sp_rx_data_id;
    wire [15:0] s_ptp_sp_rx_payload;
    wire        s_ptp_sp_rx_accept;
    assign s_ptp_in            = {s_ptp_sp_tx_valid, s_ptp_sp_tx_data_id, s_ptp_sp_tx_payload, s_ptp_sp_rx_accept};
    assign s_ptp_sp_tx_ready   = s_ptp_out[25];
    assign s_ptp_sp_rx_valid   = s_ptp_out[24];
    assign s_ptp_sp_rx_data_id = s_ptp_out[23:16];
    assign s_ptp_sp_rx_payload = s_ptp_out[15:0];

    // ----- Per-side ptp_reg_* control (cocotb backdoor) ----------------------
    // tidelink_ptp uses ptp_reg_* (not APB) for register access. We expose
    // these directly to the testbench so the cocotb test can program HW_SYNC
    // CTRL/INTERVAL/STATUS without setting up a full APB mux.
    logic        m_ptp_reg_write = 1'b0;
    logic [2:0]  m_ptp_reg_addr  = '0;
    logic [31:0] m_ptp_reg_wdata = '0;
    wire  [31:0] m_ptp_reg_rdata;
    logic        m_ptp_reg_region = 1'b0;

    logic        s_ptp_reg_write = 1'b0;
    logic [2:0]  s_ptp_reg_addr  = '0;
    logic [31:0] s_ptp_reg_wdata = '0;
    wire  [31:0] s_ptp_reg_rdata;
    logic        s_ptp_reg_region = 1'b0;

    // PHC time inputs (drive from cocotb; default 0)
    logic [29:0] m_phc_nanoseconds = '0;
    logic [47:0] m_phc_seconds     = '0;
    logic        m_phc_pps         = 1'b0;
    logic [29:0] s_phc_nanoseconds = '0;
    logic [47:0] s_phc_seconds     = '0;
    logic        s_phc_pps         = 1'b0;

    wire m_phc_hw_capture;
    wire s_phc_hw_capture;
    wire m_ptp_irq, s_ptp_irq;
    wire m_sync_tx_done, m_dreq_tx_done, m_sync_rx_done, m_dreq_rx_done;
    wire s_sync_tx_done, s_dreq_tx_done, s_sync_rx_done, s_dreq_rx_done;

    // ----- Master tidelink_ptp ----------------------------------------------
    tidelink_ptp #(
        .SYS_DATA_W (32)
    ) u_master_ptp (
        .hclk               (master_clk),
        .hresetn            (m_hresetn),
        .tx_router_idle     (m_tx_link_idle),
        .ptp_sp_tx_valid    (m_ptp_sp_tx_valid),
        .ptp_sp_tx_data_id  (m_ptp_sp_tx_data_id),
        .ptp_sp_tx_payload  (m_ptp_sp_tx_payload),
        .ptp_sp_tx_ready    (m_ptp_sp_tx_ready),
        .ptp_sp_rx_valid    (m_ptp_sp_rx_valid),
        .ptp_sp_rx_data_id  (m_ptp_sp_rx_data_id),
        .ptp_sp_rx_payload  (m_ptp_sp_rx_payload),
        .ptp_sp_rx_accept   (m_ptp_sp_rx_accept),
        .phc_hw_capture     (m_phc_hw_capture),
        .phc_nanoseconds    (m_phc_nanoseconds),
        .phc_seconds        (m_phc_seconds),
        .phc_pps            (m_phc_pps),
        // AHB slave (unused — cocotb uses ptp_reg_* only)
        .ahb_ptp_hsel       (1'b0),
        .ahb_ptp_haddr      (4'h0),
        .ahb_ptp_htrans     (2'h0),
        .ahb_ptp_hsize      (3'h2),
        .ahb_ptp_hwrite     (1'b0),
        .ahb_ptp_hwdata     (32'h0),
        .ahb_ptp_hready     (1'b1),
        .ahb_ptp_hrdata     (),
        .ahb_ptp_hresp      (),
        .ahb_ptp_hreadyout  (),
        // Register interface
        .ptp_reg_write      (m_ptp_reg_write),
        .ptp_reg_addr       (m_ptp_reg_addr),
        .ptp_reg_wdata      (m_ptp_reg_wdata),
        .ptp_reg_rdata      (m_ptp_reg_rdata),
        .ptp_reg_region     (m_ptp_reg_region),
        // Servo
        .sync_tx_done       (m_sync_tx_done),
        .dreq_tx_done       (m_dreq_tx_done),
        .sync_rx_done       (m_sync_rx_done),
        .dreq_rx_done       (m_dreq_rx_done),
        .servo_dreq_trigger (1'b0),
        .phc_locked_i       (1'b1),
        .ptp_irq            (m_ptp_irq)
    );

    // ----- Slave tidelink_ptp -----------------------------------------------
    tidelink_ptp #(
        .SYS_DATA_W (32)
    ) u_slave_ptp (
        .hclk               (slave_clk),
        .hresetn            (s_hresetn),
        .tx_router_idle     (s_tx_link_idle),
        .ptp_sp_tx_valid    (s_ptp_sp_tx_valid),
        .ptp_sp_tx_data_id  (s_ptp_sp_tx_data_id),
        .ptp_sp_tx_payload  (s_ptp_sp_tx_payload),
        .ptp_sp_tx_ready    (s_ptp_sp_tx_ready),
        .ptp_sp_rx_valid    (s_ptp_sp_rx_valid),
        .ptp_sp_rx_data_id  (s_ptp_sp_rx_data_id),
        .ptp_sp_rx_payload  (s_ptp_sp_rx_payload),
        .ptp_sp_rx_accept   (s_ptp_sp_rx_accept),
        .phc_hw_capture     (s_phc_hw_capture),
        .phc_nanoseconds    (s_phc_nanoseconds),
        .phc_seconds        (s_phc_seconds),
        .phc_pps            (s_phc_pps),
        .ahb_ptp_hsel       (1'b0),
        .ahb_ptp_haddr      (4'h0),
        .ahb_ptp_htrans     (2'h0),
        .ahb_ptp_hsize      (3'h2),
        .ahb_ptp_hwrite     (1'b0),
        .ahb_ptp_hwdata     (32'h0),
        .ahb_ptp_hready     (1'b1),
        .ahb_ptp_hrdata     (),
        .ahb_ptp_hresp      (),
        .ahb_ptp_hreadyout  (),
        .ptp_reg_write      (s_ptp_reg_write),
        .ptp_reg_addr       (s_ptp_reg_addr),
        .ptp_reg_wdata      (s_ptp_reg_wdata),
        .ptp_reg_rdata      (s_ptp_reg_rdata),
        .ptp_reg_region     (s_ptp_reg_region),
        .sync_tx_done       (s_sync_tx_done),
        .dreq_tx_done       (s_dreq_tx_done),
        .sync_rx_done       (s_sync_rx_done),
        .dreq_rx_done       (s_dreq_rx_done),
        .servo_dreq_trigger (1'b0),
        .phc_locked_i       (1'b1),
        .ptp_irq            (s_ptp_irq)
    );

    // ----- Master Wlink (axi_chiplet_controller) ----------------------------
    axi_chiplet_controller u_master (
        .apb_clk(master_clk), .app_clk(master_clk), .user_hsclk(master_clk),
        .poresetn(m_poresetn), .hresetn(m_hresetn),
        .sb_reset_in(1'b0), .sb_reset_out(), .sb_wake(),

        .role_strap_i(1'b0),
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

        // AXI tied off
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
        // PTP wired to master tidelink_ptp
        .ptp_in(m_ptp_in), .ptp_out(m_ptp_out),
        .tx_link_idle(m_tx_link_idle),

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
        .pad_clk_rx(s_pad_clk_tx),  .pad_rx(s_pad_tx),

        // §9 IDELAYE2 RX delay reference (used only with USE_IDELAY=1).
        // Tied to live ref/rst — harmless when USE_IDELAY=0.
        .idelay_ref_clk(idelay_ref_clk),
        .idelay_rst(idelay_rst)
    );

    // ----- Slave Wlink ------------------------------------------------------
    axi_chiplet_controller u_slave (
        .apb_clk(slave_clk), .app_clk(slave_clk), .user_hsclk(slave_clk),
        .poresetn(s_poresetn), .hresetn(s_hresetn),
        .sb_reset_in(1'b0), .sb_reset_out(), .sb_wake(),

        .role_strap_i(1'b1),
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
        .ptp_in(s_ptp_in), .ptp_out(s_ptp_out),
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
        .pad_clk_rx(m_pad_clk_tx),  .pad_rx(m_pad_tx),

        // §9 IDELAYE2 RX delay reference (used only with USE_IDELAY=1).
        .idelay_ref_clk(idelay_ref_clk),
        .idelay_rst(idelay_rst)
    );

`ifdef PHC_PAIR_USE_FPGA_MODELS
    // §9 FPGA-models mode: force the parameter overrides on both Wlink
    // instances so the IDELAYE2 + BUFG generate-if branches elaborate
    // (mirrors the pynq-z2-pair-all bitstream config). Requires Vivado
    // unisim+glbl.v in the compile (see Makefile).
    defparam u_master.USE_IDELAY = 1'b1;
    defparam u_master.USE_CLKBUF = 1'b1;
    defparam u_slave.USE_IDELAY  = 1'b1;
    defparam u_slave.USE_CLKBUF  = 1'b1;
`endif

    // VCD dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
