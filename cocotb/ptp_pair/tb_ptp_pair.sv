// =============================================================================
// tb_ptp_pair.sv — Paired-Wlink testbench with PTP Short-Packet drivers
//
// Sibling of cocotb/wlink_pair/tb_top.sv. The wlink_pair TB ties
// `ptp_in` / `ptp_out` of each chiplet controller to constant zero, which
// makes it impossible to inject PTP sync (data_id=0x50) or follow-up
// (data_id=0x51) packets from cocotb. This TB exposes the 26-bit packed
// PTP buses on both sides so cocotb can drive them and observe peer
// SP RX traffic on the wire.
//
// Per the wlink RTL (src/rtl/local_overrides/Wlink.v):
//   ptp_in  = {sp_tx_valid, sp_tx_data_id[7:0], sp_tx_payload[15:0], sp_rx_accept}
//   ptp_out = {sp_tx_ready, sp_rx_valid, sp_rx_data_id[7:0], sp_rx_payload[15:0]}
//
// Packet sizes per src/rtl/tidelink_ptp.sv §"Short packet wire format":
//   * data_id 0x50 = PHC SYNC
//   * data_id 0x51 = PHC DELAY_REQ / FOLLOW_UP (task: 0x50/0x51 sync/follow-up)
//
// The TB is otherwise byte-for-byte equivalent to wlink_pair/tb_top.sv
// (same pad skid, same lane checker, same clock topology), so any pair
// bring-up assertion that holds in wlink_pair holds here.
//
// Tests live alongside in cocotb/ptp_pair/test_ptp_*.py.
// =============================================================================
`timescale 1ns/1ps

module tb_ptp_pair #(
    parameter int SKID_BITS = 0,
    parameter int SKID_BITS_LANE0 = SKID_BITS,
    parameter int SKID_BITS_LANE1 = SKID_BITS,
    parameter int SKID_BITS_LANE2 = SKID_BITS,
    parameter int SKID_BITS_LANE3 = SKID_BITS,
    parameter int SKID_BITS_LANE4 = SKID_BITS,
    parameter int SKID_BITS_LANE5 = SKID_BITS,
    parameter int SKID_BITS_LANE6 = SKID_BITS,
    parameter int SKID_BITS_LANE7 = SKID_BITS
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

    // ----- Cross-wired GPIO PHY pads (same as wlink_pair/tb_top.sv) ----------
    wire        m_pad_clk_tx, s_pad_clk_tx;
    wire [7:0]  m_pad_tx,     s_pad_tx;
    wire        m_pad_clk_tx_skid, s_pad_clk_tx_skid;
    wire [7:0]  m_pad_tx_skid,     s_pad_tx_skid;

    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(8),
        .SKID_BITS_LANE0(SKID_BITS_LANE0),
        .SKID_BITS_LANE1(SKID_BITS_LANE1),
        .SKID_BITS_LANE2(SKID_BITS_LANE2),
        .SKID_BITS_LANE3(SKID_BITS_LANE3),
        .SKID_BITS_LANE4(SKID_BITS_LANE4),
        .SKID_BITS_LANE5(SKID_BITS_LANE5),
        .SKID_BITS_LANE6(SKID_BITS_LANE6),
        .SKID_BITS_LANE7(SKID_BITS_LANE7),
        .STUCK_LANES_MASK(8'h00)
    ) u_skid_m2s (
        .pad_clk_in   (m_pad_clk_tx),
        .pad_data_in  (m_pad_tx),
        .pad_clk_out  (m_pad_clk_tx_skid),
        .pad_data_out (m_pad_tx_skid)
    );
    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(8),
        .SKID_BITS_LANE0(SKID_BITS_LANE0),
        .SKID_BITS_LANE1(SKID_BITS_LANE1),
        .SKID_BITS_LANE2(SKID_BITS_LANE2),
        .SKID_BITS_LANE3(SKID_BITS_LANE3),
        .SKID_BITS_LANE4(SKID_BITS_LANE4),
        .SKID_BITS_LANE5(SKID_BITS_LANE5),
        .SKID_BITS_LANE6(SKID_BITS_LANE6),
        .SKID_BITS_LANE7(SKID_BITS_LANE7),
        .STUCK_LANES_MASK(8'h00)
    ) u_skid_s2m (
        .pad_clk_in   (s_pad_clk_tx),
        .pad_data_in  (s_pad_tx),
        .pad_clk_out  (s_pad_clk_tx_skid),
        .pad_data_out (s_pad_tx_skid)
    );

    // ----- Lane checker plumbing (kept for wlink_pair parity) -----------------
    wire [127:0] m_rx_lane_data  = u_master.u_wlink.phy.gpio.io_link_rx_rx_link_data;
    wire         m_rx_link_clk   = u_master.u_wlink.phy.gpio.io_link_rx_rx_link_clk;
    wire [127:0] s_rx_lane_data  = u_slave.u_wlink.phy.gpio.io_link_rx_rx_link_data;
    wire         s_rx_link_clk   = u_slave.u_wlink.phy.gpio.io_link_rx_rx_link_clk;
    wire m_checker_rst = ~m_poresetn;
    wire s_checker_rst = ~s_poresetn;
    wire [7:0] master_lane_locked;
    wire [7:0] slave_lane_locked;
    tidelink_lane_checker u_master_checker (
        .clk(m_rx_link_clk), .rst(m_checker_rst),
        .lane_data(m_rx_lane_data), .lane_locked(master_lane_locked)
    );
    tidelink_lane_checker u_slave_checker (
        .clk(s_rx_link_clk), .rst(s_checker_rst),
        .lane_data(s_rx_lane_data), .lane_locked(slave_lane_locked)
    );

    // ----- APB / ctrl_reg / status (cocotb compat) ----------------------------
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

    logic        m_ctrl_reg_write,  s_ctrl_reg_write;
    logic [3:0]  m_ctrl_reg_addr,   s_ctrl_reg_addr;
    logic [31:0] m_ctrl_reg_wdata,  s_ctrl_reg_wdata;
    wire  [31:0] m_ctrl_reg_rdata,  s_ctrl_reg_rdata;

    wire m_role_is_master, s_role_is_master;
    wire m_role_locked,    s_role_locked;
    wire m_interrupt,      s_interrupt;
    wire m_tx_link_idle,   s_tx_link_idle;

    logic m_apb_debug_unlock = 1'b0;
    logic s_apb_debug_unlock = 1'b0;
    logic m_mask_hs_bypass   = 1'b1;
    logic s_mask_hs_bypass   = 1'b1;

    // -------------------------------------------------------------------------
    // PTP Short-Packet drivers (the only difference vs wlink_pair tb_top.sv)
    //   - <side>_ptp_tx_*  : DUT-driven TX side (cocotb drives valid/data_id/
    //                       payload, observes ready)
    //   - <side>_ptp_rx_*  : observed RX bus from the link, cocotb drives accept
    // -------------------------------------------------------------------------
    // Master TX inputs (cocotb-driven)
    logic        m_ptp_sp_tx_valid    = 1'b0;
    logic [7:0]  m_ptp_sp_tx_data_id  = 8'h00;
    logic [15:0] m_ptp_sp_tx_payload  = 16'h0000;
    logic        m_ptp_sp_rx_accept   = 1'b1;   // default accept all
    // Master RX/TX-ready outputs (DUT-driven, observed by cocotb)
    wire         m_ptp_sp_tx_ready;
    wire         m_ptp_sp_rx_valid;
    wire [7:0]   m_ptp_sp_rx_data_id;
    wire [15:0]  m_ptp_sp_rx_payload;

    logic        s_ptp_sp_tx_valid    = 1'b0;
    logic [7:0]  s_ptp_sp_tx_data_id  = 8'h00;
    logic [15:0] s_ptp_sp_tx_payload  = 16'h0000;
    logic        s_ptp_sp_rx_accept   = 1'b1;
    wire         s_ptp_sp_tx_ready;
    wire         s_ptp_sp_rx_valid;
    wire [7:0]   s_ptp_sp_rx_data_id;
    wire [15:0]  s_ptp_sp_rx_payload;

    // ----- Master instance ----------------------------------------------------
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
        // PTP packed bus — drive from cocotb. Bit layout from Wlink.v
        // matches src/rtl/tidelink_top.sv lines 1778-1779:
        //   ptp_in  = {sp_tx_valid, sp_tx_data_id[7:0], sp_tx_payload[15:0], sp_rx_accept}
        //   ptp_out = {sp_tx_ready, sp_rx_valid, sp_rx_data_id[7:0], sp_rx_payload[15:0]}
        .ptp_in ({m_ptp_sp_tx_valid, m_ptp_sp_tx_data_id, m_ptp_sp_tx_payload, m_ptp_sp_rx_accept}),
        .ptp_out({m_ptp_sp_tx_ready, m_ptp_sp_rx_valid,   m_ptp_sp_rx_data_id, m_ptp_sp_rx_payload}),
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
        .pad_clk_rx(s_pad_clk_tx_skid), .pad_rx(s_pad_tx_skid)
    );

    // ----- Slave instance -----------------------------------------------------
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
        .ptp_in ({s_ptp_sp_tx_valid, s_ptp_sp_tx_data_id, s_ptp_sp_tx_payload, s_ptp_sp_rx_accept}),
        .ptp_out({s_ptp_sp_tx_ready, s_ptp_sp_rx_valid,   s_ptp_sp_rx_data_id, s_ptp_sp_rx_payload}),
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
        .pad_clk_rx(m_pad_clk_tx_skid), .pad_rx(m_pad_tx_skid)
    );

    // VCD dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_ptp_pair);
    end

endmodule
