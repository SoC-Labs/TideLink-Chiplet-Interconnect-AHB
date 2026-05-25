// =============================================================================
// tb_top.sv — Paired `tidelink_top` simulation: master + slave cross-wired
//             through their GPIO PHY pads.
//
// Purpose
// -------
// This testbench instantiates TWO complete `tidelink_top` modules and wires
// their PHY pads together with a per-direction `pad_skid` block (default
// SKID_BITS=0 = passthrough). Both `tidelink_top` instances expose:
//   - APB unified config port  (0x0000-0x1FFF Wlink / 0x2000+ TideLink + R8)
//   - AHB TX aperture          (write packets into the FC node TX path)
//   - AHB FIFO read port       (read received packets back)
//   - AHB sub / mng / ptp      (TIED OFF for this test)
//
// The test in `test_tidelink_pair_doorbell.py` drives the full bring-up
// chain observed on HW for the bridge1 b24 deploy on 2026-05-24:
//   1. role_lock master + slave
//   2. wait for cal_done + lane_locked=0xff
//   3. write slot 0 = 0x0 then the Wlink LL swreset bootstrap (0x...f08 ->
//      f00 -> f07) — the `to_data_mode` sequence
//   4. verify cr_pkt_seen_rx / crack_pkt_seen_rx latch on BOTH sides
//   5. verify PAIR_CREDIT_COUNTER reads non-zero (the gate HW failed)
//   6. ring DOORBELL master->slave, verify DOORBELL_RESPONSE_ACC on slave
//   7. ring DOORBELL slave->master, verify DOORBELL_RESPONSE_ACC on master
//
// If the test reproduces the HW symptom (cr/crack latch but PAIR_CREDIT
// remains 0 / doorbell doesn't cross), we have an isolated sim repro of
// the residual on bridge1 b24.
//
// Implementation choices
// ----------------------
//   * AHB ports we don't drive (sub / mng / ptp) are tied off the same way
//     uvm/tidelink_top_system/tb/top.sv does it.
//   * The APB pstrb/pprot are wired to constants per-side (cocotb just
//     drives psel/penable/pwrite/paddr/pwdata).
//   * Both DUTs share `hclk` for now (the HW symptom is independent of
//     PLL drift — both sides use the same gen_clock from the same
//     ila_clk MMCM in fpga/targets/pynq-z2-pair-flip-ila).
//   * AHB TX aperture is driven by cocotbext-ahb's AHBLiteMaster, so the
//     hsel / htrans / etc. are EXPOSED as testbench ports rather than
//     tied to 1'b1 (the way the UVM tb hardcodes hsel=1'b1 wouldn't work
//     for cocotb's address-phase / data-phase protocol).
//   * pad_skid is reused unchanged from cocotb/wlink_pair/pad_skid.sv.
// =============================================================================
`timescale 1ns/1ps

module tb_top #(
    // Bit-level skid inserted between TX and RX pads (legacy uniform). 0 =
    // passthrough. The HW bug repro path uses SKID=0 because the FPGA-side
    // misalignment is now handled by USE_T3A + the IDELAYE2 calibrator on
    // silicon; in sim we want the protocol-level path stripped of that
    // skew.
    parameter int SKID_BITS = `ifdef TB_TOP_SKID_BITS `TB_TOP_SKID_BITS `else 0 `endif,

    // Stick parameters mostly mirrored from `tidelink_top` defaults; only
    // change those that need to be different in sim vs. silicon.
    parameter SYS_ADDR_W    = 32,
    parameter SYS_DATA_W    = 32,
    parameter RAM_ADDR_W    = 14,
    parameter RAM_DATA_W    = 32,
    parameter APB_ADDR_W    = 12,
    parameter FC_DATA_W     = 48,
    parameter NUM_PHY_LANES = 8,
    parameter [SYS_ADDR_W-1:0] M_PAIR_BASE = 32'h44032000,   // master's view of slave
    parameter [SYS_ADDR_W-1:0] S_PAIR_BASE = 32'h44032000    // slave's view of master
);

    // -------------------------------------------------------------------------
    // Clocks and resets
    // -------------------------------------------------------------------------
    logic hclk     = 1'b0;
    logic ref_clk  = 1'b0;
    logic poresetn = 1'b0;
    logic hresetn  = 1'b0;

    // Per-side debug strap (cocotb drives high to ungate slave APB writes
    // before role_lock — same role as fpga gpio 0x44041000).
    logic m_apb_debug_unlock = 1'b1;
    logic s_apb_debug_unlock = 1'b1;

    // Bypass autoneg lane-mask handshake gate (mirrors the wlink_pair tb).
    logic m_mask_hs_bypass = 1'b1;
    logic s_mask_hs_bypass = 1'b1;

    // -------------------------------------------------------------------------
    // Cross-wired GPIO PHY pads
    //   master TX -> m_pad_clk_tx / m_pad_tx -> u_skid_m2s -> slave RX
    //   slave  TX -> s_pad_clk_tx / s_pad_tx -> u_skid_s2m -> master RX
    // -------------------------------------------------------------------------
    wire                          m_pad_clk_tx, s_pad_clk_tx;
    wire [NUM_PHY_LANES-1:0]      m_pad_tx,     s_pad_tx;
    wire                          m_pad_clk_tx_skid, s_pad_clk_tx_skid;
    wire [NUM_PHY_LANES-1:0]      m_pad_tx_skid,     s_pad_tx_skid;

    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES)
    ) u_skid_m2s (
        .pad_clk_in   (m_pad_clk_tx),
        .pad_data_in  (m_pad_tx),
        .pad_clk_out  (m_pad_clk_tx_skid),
        .pad_data_out (m_pad_tx_skid)
    );

    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES)
    ) u_skid_s2m (
        .pad_clk_in   (s_pad_clk_tx),
        .pad_data_in  (s_pad_tx),
        .pad_clk_out  (s_pad_clk_tx_skid),
        .pad_data_out (s_pad_tx_skid)
    );

    // -------------------------------------------------------------------------
    // AHB TX aperture interface — driven per-side by cocotbext-ahb's
    // AHBLiteMaster. We expose the full set of AHB-Lite signals (cocotbext
    // names: hsel/haddr/htrans/hsize/hwrite/hwdata/hready_in + outputs).
    // -------------------------------------------------------------------------
    // Master TX aperture
    logic                          m_ahb_tx_hsel;
    logic   [RAM_ADDR_W-1:0]       m_ahb_tx_haddr;
    logic                    [1:0] m_ahb_tx_htrans;
    logic                    [2:0] m_ahb_tx_hsize;
    logic                          m_ahb_tx_hwrite;
    logic   [SYS_DATA_W-1:0]       m_ahb_tx_hwdata;
    logic                          m_ahb_tx_hready_in;
    wire    [SYS_DATA_W-1:0]       m_ahb_tx_hrdata;
    wire                           m_ahb_tx_hresp;
    wire                           m_ahb_tx_hready;
    // Slave TX aperture
    logic                          s_ahb_tx_hsel;
    logic   [RAM_ADDR_W-1:0]       s_ahb_tx_haddr;
    logic                    [1:0] s_ahb_tx_htrans;
    logic                    [2:0] s_ahb_tx_hsize;
    logic                          s_ahb_tx_hwrite;
    logic   [SYS_DATA_W-1:0]       s_ahb_tx_hwdata;
    logic                          s_ahb_tx_hready_in;
    wire    [SYS_DATA_W-1:0]       s_ahb_tx_hrdata;
    wire                           s_ahb_tx_hresp;
    wire                           s_ahb_tx_hready;

    // Tie hready_in to the slave's hready output (single-master model).
    wire m_ahb_tx_hready_loop = m_ahb_tx_hready;
    wire s_ahb_tx_hready_loop = s_ahb_tx_hready;

    // -------------------------------------------------------------------------
    // AHB FIFO read port (CPU reads received packets back).
    // -------------------------------------------------------------------------
    // Master FIFO read port
    logic                          m_ahb_fifo_hsel;
    logic   [RAM_ADDR_W-1:0]       m_ahb_fifo_haddr;
    logic                    [1:0] m_ahb_fifo_htrans;
    logic                    [2:0] m_ahb_fifo_hsize;
    logic                          m_ahb_fifo_hwrite;
    logic   [SYS_DATA_W-1:0]       m_ahb_fifo_hwdata;
    logic                          m_ahb_fifo_hready_in;
    wire    [SYS_DATA_W-1:0]       m_ahb_fifo_hrdata;
    wire                           m_ahb_fifo_hresp;
    wire                           m_ahb_fifo_hready;
    // Slave FIFO read port
    logic                          s_ahb_fifo_hsel;
    logic   [RAM_ADDR_W-1:0]       s_ahb_fifo_haddr;
    logic                    [1:0] s_ahb_fifo_htrans;
    logic                    [2:0] s_ahb_fifo_hsize;
    logic                          s_ahb_fifo_hwrite;
    logic   [SYS_DATA_W-1:0]       s_ahb_fifo_hwdata;
    logic                          s_ahb_fifo_hready_in;
    wire    [SYS_DATA_W-1:0]       s_ahb_fifo_hrdata;
    wire                           s_ahb_fifo_hresp;
    wire                           s_ahb_fifo_hready;

    // -------------------------------------------------------------------------
    // APB unified config port — manually driven from cocotb (mirrors the
    // wlink_pair `apb_*` style — psel/penable/pwrite/paddr/pwdata).
    // -------------------------------------------------------------------------
    // Master APB
    logic         m_apb_psel,  m_apb_penable, m_apb_pwrite;
    logic [14:0]  m_apb_paddr;
    logic         [3:0]  m_apb_pstrb;
    logic         [2:0]  m_apb_pprot;
    logic [SYS_DATA_W-1:0] m_apb_pwdata;
    wire  [SYS_DATA_W-1:0] m_apb_prdata;
    wire                   m_apb_pready;
    wire                   m_apb_pslverr;
    // Slave APB
    logic         s_apb_psel,  s_apb_penable, s_apb_pwrite;
    logic [14:0]  s_apb_paddr;
    logic         [3:0]  s_apb_pstrb;
    logic         [2:0]  s_apb_pprot;
    logic [SYS_DATA_W-1:0] s_apb_pwdata;
    wire  [SYS_DATA_W-1:0] s_apb_prdata;
    wire                   s_apb_pready;
    wire                   s_apb_pslverr;

    // -------------------------------------------------------------------------
    // Interrupts / status — observable but not asserted-on here.
    // -------------------------------------------------------------------------
    wire m_released_credits_irq, m_doorbell_irq, m_packet_committed_irq;
    wire m_ptp_irq, m_perf_irq, m_wlink_irq;
    wire m_role_is_master, m_role_locked, m_link_active, m_d2d_reset_o;

    wire s_released_credits_irq, s_doorbell_irq, s_packet_committed_irq;
    wire s_ptp_irq, s_perf_irq, s_wlink_irq;
    wire s_role_is_master, s_role_locked, s_link_active, s_d2d_reset_o;

    // I2C — pull-up bus model (tristate AND) so both sides see idle high.
    wire m_i2c_scl_o, m_i2c_scl_t, m_i2c_sda_o, m_i2c_sda_t;
    wire s_i2c_scl_o, s_i2c_scl_t, s_i2c_sda_o, s_i2c_sda_t;
    wire i2c_scl = (m_i2c_scl_t ? 1'b1 : m_i2c_scl_o) & (s_i2c_scl_t ? 1'b1 : s_i2c_scl_o);
    wire i2c_sda = (m_i2c_sda_t ? 1'b1 : m_i2c_sda_o) & (s_i2c_sda_t ? 1'b1 : s_i2c_sda_o);

    // =========================================================================
    // DUT: master `tidelink_top`
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE(M_PAIR_BASE)
    ) u_master (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),

        // AHB Sub — TIED OFF (not exercised; XHB500 path)
        .ahb_sub_hsel      (1'b0),
        .ahb_sub_haddr     (32'h0),
        .ahb_sub_hburst    (3'h0),
        .ahb_sub_hprot     (4'h0),
        .ahb_sub_hsize     (3'h0),
        .ahb_sub_htrans    (2'b00),
        .ahb_sub_hwdata    (32'h0),
        .ahb_sub_hwrite    (1'b0),
        .ahb_sub_hready    (1'b1),
        .ahb_sub_hrdata    (/* unused */),
        .ahb_sub_hresp     (/* unused */),
        .ahb_sub_hreadyout (/* unused */),

        // AHB TX aperture — driven by cocotbext-ahb
        .ahb_tx_hsel       (m_ahb_tx_hsel),
        .ahb_tx_haddr      (m_ahb_tx_haddr),
        .ahb_tx_htrans     (m_ahb_tx_htrans),
        .ahb_tx_hsize      (m_ahb_tx_hsize),
        .ahb_tx_hwrite     (m_ahb_tx_hwrite),
        .ahb_tx_hwdata     (m_ahb_tx_hwdata),
        .ahb_tx_hready     (m_ahb_tx_hready_loop),
        .ahb_tx_hrdata     (m_ahb_tx_hrdata),
        .ahb_tx_hresp      (m_ahb_tx_hresp),
        .ahb_tx_hreadyout  (m_ahb_tx_hready),

        // AHB FIFO read — driven by cocotbext-ahb (could be tied off but kept
        // active so future tests can check what landed in the RX FIFO).
        .ahb_fifo_hsel     (m_ahb_fifo_hsel),
        .ahb_fifo_haddr    (m_ahb_fifo_haddr),
        .ahb_fifo_htrans   (m_ahb_fifo_htrans),
        .ahb_fifo_hsize    (m_ahb_fifo_hsize),
        .ahb_fifo_hwrite   (m_ahb_fifo_hwrite),
        .ahb_fifo_hwdata   (m_ahb_fifo_hwdata),
        .ahb_fifo_hready   (m_ahb_fifo_hready),
        .ahb_fifo_hrdata   (m_ahb_fifo_hrdata),
        .ahb_fifo_hresp    (m_ahb_fifo_hresp),
        .ahb_fifo_hreadyout(m_ahb_fifo_hready),

        // AHB Manager — tied off (slave VIP would normally answer here).
        // Pad outputs are dangling; ahb_mng_hready/hrdata/hresp are inputs.
        .ahb_mng_haddr     (/* unused */),
        .ahb_mng_hburst    (/* unused */),
        .ahb_mng_hprot     (/* unused */),
        .ahb_mng_hsize     (/* unused */),
        .ahb_mng_htrans    (/* unused */),
        .ahb_mng_hwdata    (/* unused */),
        .ahb_mng_hwrite    (/* unused */),
        .ahb_mng_hready    (1'b1),
        .ahb_mng_hrdata    (32'h0),
        .ahb_mng_hresp     (1'b0),

        // APB unified config port
        .apb_psel          (m_apb_psel),
        .apb_paddr         (m_apb_paddr),
        .apb_penable       (m_apb_penable),
        .apb_pwrite        (m_apb_pwrite),
        .apb_pstrb         (m_apb_pstrb),
        .apb_pprot         (m_apb_pprot),
        .apb_pwdata        (m_apb_pwdata),
        .apb_prdata        (m_apb_prdata),
        .apb_pready        (m_apb_pready),
        .apb_pslverr       (m_apb_pslverr),

        // Scan / DFT — tied off
        .scan_mode         (1'b0),
        .scan_asyncrst_ctrl(1'b0),
        .scan_clk          (1'b0),
        .scan_shift        (1'b0),
        .scan_in           (1'b0),
        .scan_out          (/* unused */),

        // Wlink PLL reference
        .user_ref_clk      (ref_clk),

        // PHY pads — cross-wired via skid blocks
        .pad_clk_tx        (m_pad_clk_tx),
        .pad_tx            (m_pad_tx),
        .pad_clk_rx        (s_pad_clk_tx_skid),
        .pad_rx            (s_pad_tx_skid),

        // §9 IDELAYE2 RX delay ref clock (USE_IDELAY=0 default -> passthrough)
        .idelay_ref_clk    (1'b0),

        // PHC — tied off (PTP not exercised)
        .phc_clk                    (hclk),
        .phc_resetn                 (hresetn),
        .phc_nanoseconds            (30'h0),
        .phc_seconds                (48'h0),
        .phc_pps                    (1'b0),
        .phc_hw_cap_seconds         (48'h0),
        .phc_hw_cap_nanoseconds     (30'h0),
        .phc_hw_cap_sub_nanoseconds (32'h0),
        .phc_locked_i               (1'b1),

        // PTP AHB write port — tied off
        .ahb_ptp_hsel               (1'b0),
        .ahb_ptp_haddr              (4'h0),
        .ahb_ptp_htrans             (2'b00),
        .ahb_ptp_hsize              (3'h0),
        .ahb_ptp_hwrite             (1'b0),
        .ahb_ptp_hwdata             (32'h0),
        .ahb_ptp_hready             (1'b1),
        .ahb_ptp_hrdata             (/* unused */),
        .ahb_ptp_hresp              (/* unused */),
        .ahb_ptp_hreadyout          (/* unused */),
        .phc_hw_capture             (/* unused */),
        .phc_hw_set_time            (/* unused */),
        .phc_hw_set_seconds         (/* unused */),
        .phc_hw_set_nanoseconds     (/* unused */),
        .phc_hw_adj_valid           (/* unused */),
        .phc_hw_adj_ns_incr_frac    (/* unused */),
        .servo_locked               (/* unused */),

        // TideChart axis — tied off with defined zeros (avoid X
        // propagation through tc_qos_priority into TX router).
        .tc_axis_tx_tvalid (1'b0),
        .tc_axis_tx_tdata  ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready (/* unused */),
        .tc_axis_rx_tvalid (/* unused */),
        .tc_axis_rx_tdata  (/* unused */),
        .tc_axis_rx_tready (1'b1),
        .tc_qos_priority   (3'h0),

        // Congestion sideband
        .tl_local_link_state_o  (/* unused */),
        .tl_link_state_change_o (/* unused */),
        .tl_ewma_credit_o       (/* unused */),
        .tl_bcast_ack_i         (1'b0),

        // Link status & reset out
        .link_active       (m_link_active),
        .d2d_reset_o       (m_d2d_reset_o),

        // Role (master)
        .role_strap_i      (1'b0),
        .role_is_master_o  (m_role_is_master),
        .role_locked_o     (m_role_locked),
        .apb_debug_unlock_i(m_apb_debug_unlock),
        .mask_hs_bypass_i  (m_mask_hs_bypass),

        // Autoneg — provide non-zero priority so the negotiator settles
        // deterministically.
        .nego_priority_i   (16'h8000),
        .puf_seed          (16'hA5A5),
        .puf_ready         (1'b1),
        .nego_error_irq    (/* unused */),

        // I2C
        .i2c_scl_i         (i2c_scl),
        .i2c_scl_o         (m_i2c_scl_o),
        .i2c_scl_t         (m_i2c_scl_t),
        .i2c_sda_i         (i2c_sda),
        .i2c_sda_o         (m_i2c_sda_o),
        .i2c_sda_t         (m_i2c_sda_t),

        // I2C sideband AXI — tied off
        .s_i2c_axi_awvalid (1'b0),
        .s_i2c_axi_awid    (2'b00),
        .s_i2c_axi_awaddr  (4'h0),
        .s_i2c_axi_awlen   (8'h00),
        .s_i2c_axi_awsize  (3'h0),
        .s_i2c_axi_awburst (2'b00),
        .s_i2c_axi_awlock  (1'b0),
        .s_i2c_axi_awcache (4'h0),
        .s_i2c_axi_awprot  (3'h0),
        .s_i2c_axi_awready (/* unused */),
        .s_i2c_axi_wvalid  (1'b0),
        .s_i2c_axi_wdata   (32'h0),
        .s_i2c_axi_wstrb   (4'h0),
        .s_i2c_axi_wlast   (1'b0),
        .s_i2c_axi_wready  (/* unused */),
        .s_i2c_axi_bvalid  (/* unused */),
        .s_i2c_axi_bid     (/* unused */),
        .s_i2c_axi_bresp   (/* unused */),
        .s_i2c_axi_bready  (1'b1),
        .s_i2c_axi_arvalid (1'b0),
        .s_i2c_axi_arid    (2'b00),
        .s_i2c_axi_araddr  (4'h0),
        .s_i2c_axi_arlen   (8'h00),
        .s_i2c_axi_arsize  (3'h0),
        .s_i2c_axi_arburst (2'b00),
        .s_i2c_axi_arlock  (1'b0),
        .s_i2c_axi_arcache (4'h0),
        .s_i2c_axi_arprot  (3'h0),
        .s_i2c_axi_arready (/* unused */),
        .s_i2c_axi_rvalid  (/* unused */),
        .s_i2c_axi_rid     (/* unused */),
        .s_i2c_axi_rdata   (/* unused */),
        .s_i2c_axi_rresp   (/* unused */),
        .s_i2c_axi_rlast   (/* unused */),
        .s_i2c_axi_rready  (1'b1),

        // I2C interrupts
        .i2c_nbsy_irq      (/* unused */),
        .i2c_nrd_empty_irq (/* unused */),

        // Interrupts
        .released_credits_irq (m_released_credits_irq),
        .doorbell_irq         (m_doorbell_irq),
        .packet_committed_irq (m_packet_committed_irq),
        .ptp_irq              (m_ptp_irq),
        .perf_irq             (m_perf_irq),
        .wlink_irq            (m_wlink_irq)
    );

    // =========================================================================
    // DUT: slave `tidelink_top`
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .FC_DATA_W         (FC_DATA_W),
        .NUM_PHY_LANES     (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE(S_PAIR_BASE)
    ) u_slave (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .poresetn          (poresetn),

        .ahb_sub_hsel      (1'b0),
        .ahb_sub_haddr     (32'h0),
        .ahb_sub_hburst    (3'h0),
        .ahb_sub_hprot     (4'h0),
        .ahb_sub_hsize     (3'h0),
        .ahb_sub_htrans    (2'b00),
        .ahb_sub_hwdata    (32'h0),
        .ahb_sub_hwrite    (1'b0),
        .ahb_sub_hready    (1'b1),
        .ahb_sub_hrdata    (/* unused */),
        .ahb_sub_hresp     (/* unused */),
        .ahb_sub_hreadyout (/* unused */),

        .ahb_tx_hsel       (s_ahb_tx_hsel),
        .ahb_tx_haddr      (s_ahb_tx_haddr),
        .ahb_tx_htrans     (s_ahb_tx_htrans),
        .ahb_tx_hsize      (s_ahb_tx_hsize),
        .ahb_tx_hwrite     (s_ahb_tx_hwrite),
        .ahb_tx_hwdata     (s_ahb_tx_hwdata),
        .ahb_tx_hready     (s_ahb_tx_hready_loop),
        .ahb_tx_hrdata     (s_ahb_tx_hrdata),
        .ahb_tx_hresp      (s_ahb_tx_hresp),
        .ahb_tx_hreadyout  (s_ahb_tx_hready),

        .ahb_fifo_hsel     (s_ahb_fifo_hsel),
        .ahb_fifo_haddr    (s_ahb_fifo_haddr),
        .ahb_fifo_htrans   (s_ahb_fifo_htrans),
        .ahb_fifo_hsize    (s_ahb_fifo_hsize),
        .ahb_fifo_hwrite   (s_ahb_fifo_hwrite),
        .ahb_fifo_hwdata   (s_ahb_fifo_hwdata),
        .ahb_fifo_hready   (s_ahb_fifo_hready),
        .ahb_fifo_hrdata   (s_ahb_fifo_hrdata),
        .ahb_fifo_hresp    (s_ahb_fifo_hresp),
        .ahb_fifo_hreadyout(s_ahb_fifo_hready),

        .ahb_mng_haddr     (/* unused */),
        .ahb_mng_hburst    (/* unused */),
        .ahb_mng_hprot     (/* unused */),
        .ahb_mng_hsize     (/* unused */),
        .ahb_mng_htrans    (/* unused */),
        .ahb_mng_hwdata    (/* unused */),
        .ahb_mng_hwrite    (/* unused */),
        .ahb_mng_hready    (1'b1),
        .ahb_mng_hrdata    (32'h0),
        .ahb_mng_hresp     (1'b0),

        .apb_psel          (s_apb_psel),
        .apb_paddr         (s_apb_paddr),
        .apb_penable       (s_apb_penable),
        .apb_pwrite        (s_apb_pwrite),
        .apb_pstrb         (s_apb_pstrb),
        .apb_pprot         (s_apb_pprot),
        .apb_pwdata        (s_apb_pwdata),
        .apb_prdata        (s_apb_prdata),
        .apb_pready        (s_apb_pready),
        .apb_pslverr       (s_apb_pslverr),

        .scan_mode         (1'b0),
        .scan_asyncrst_ctrl(1'b0),
        .scan_clk          (1'b0),
        .scan_shift        (1'b0),
        .scan_in           (1'b0),
        .scan_out          (/* unused */),

        .user_ref_clk      (ref_clk),

        .pad_clk_tx        (s_pad_clk_tx),
        .pad_tx            (s_pad_tx),
        .pad_clk_rx        (m_pad_clk_tx_skid),
        .pad_rx            (m_pad_tx_skid),

        .idelay_ref_clk    (1'b0),

        .phc_clk                    (hclk),
        .phc_resetn                 (hresetn),
        .phc_nanoseconds            (30'h0),
        .phc_seconds                (48'h0),
        .phc_pps                    (1'b0),
        .phc_hw_cap_seconds         (48'h0),
        .phc_hw_cap_nanoseconds     (30'h0),
        .phc_hw_cap_sub_nanoseconds (32'h0),
        .phc_locked_i               (1'b1),

        .ahb_ptp_hsel               (1'b0),
        .ahb_ptp_haddr              (4'h0),
        .ahb_ptp_htrans             (2'b00),
        .ahb_ptp_hsize              (3'h0),
        .ahb_ptp_hwrite             (1'b0),
        .ahb_ptp_hwdata             (32'h0),
        .ahb_ptp_hready             (1'b1),
        .ahb_ptp_hrdata             (/* unused */),
        .ahb_ptp_hresp              (/* unused */),
        .ahb_ptp_hreadyout          (/* unused */),
        .phc_hw_capture             (/* unused */),
        .phc_hw_set_time            (/* unused */),
        .phc_hw_set_seconds         (/* unused */),
        .phc_hw_set_nanoseconds     (/* unused */),
        .phc_hw_adj_valid           (/* unused */),
        .phc_hw_adj_ns_incr_frac    (/* unused */),
        .servo_locked               (/* unused */),

        .tc_axis_tx_tvalid (1'b0),
        .tc_axis_tx_tdata  ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready (/* unused */),
        .tc_axis_rx_tvalid (/* unused */),
        .tc_axis_rx_tdata  (/* unused */),
        .tc_axis_rx_tready (1'b1),
        .tc_qos_priority   (3'h0),

        .tl_local_link_state_o  (/* unused */),
        .tl_link_state_change_o (/* unused */),
        .tl_ewma_credit_o       (/* unused */),
        .tl_bcast_ack_i         (1'b0),

        .link_active       (s_link_active),
        .d2d_reset_o       (s_d2d_reset_o),

        // Role (slave)
        .role_strap_i      (1'b1),
        .role_is_master_o  (s_role_is_master),
        .role_locked_o     (s_role_locked),
        .apb_debug_unlock_i(s_apb_debug_unlock),
        .mask_hs_bypass_i  (s_mask_hs_bypass),

        .nego_priority_i   (16'h7FFF),
        .puf_seed          (16'h5A5A),
        .puf_ready         (1'b1),
        .nego_error_irq    (/* unused */),

        .i2c_scl_i         (i2c_scl),
        .i2c_scl_o         (s_i2c_scl_o),
        .i2c_scl_t         (s_i2c_scl_t),
        .i2c_sda_i         (i2c_sda),
        .i2c_sda_o         (s_i2c_sda_o),
        .i2c_sda_t         (s_i2c_sda_t),

        .s_i2c_axi_awvalid (1'b0),
        .s_i2c_axi_awid    (2'b00),
        .s_i2c_axi_awaddr  (4'h0),
        .s_i2c_axi_awlen   (8'h00),
        .s_i2c_axi_awsize  (3'h0),
        .s_i2c_axi_awburst (2'b00),
        .s_i2c_axi_awlock  (1'b0),
        .s_i2c_axi_awcache (4'h0),
        .s_i2c_axi_awprot  (3'h0),
        .s_i2c_axi_awready (/* unused */),
        .s_i2c_axi_wvalid  (1'b0),
        .s_i2c_axi_wdata   (32'h0),
        .s_i2c_axi_wstrb   (4'h0),
        .s_i2c_axi_wlast   (1'b0),
        .s_i2c_axi_wready  (/* unused */),
        .s_i2c_axi_bvalid  (/* unused */),
        .s_i2c_axi_bid     (/* unused */),
        .s_i2c_axi_bresp   (/* unused */),
        .s_i2c_axi_bready  (1'b1),
        .s_i2c_axi_arvalid (1'b0),
        .s_i2c_axi_arid    (2'b00),
        .s_i2c_axi_araddr  (4'h0),
        .s_i2c_axi_arlen   (8'h00),
        .s_i2c_axi_arsize  (3'h0),
        .s_i2c_axi_arburst (2'b00),
        .s_i2c_axi_arlock  (1'b0),
        .s_i2c_axi_arcache (4'h0),
        .s_i2c_axi_arprot  (3'h0),
        .s_i2c_axi_arready (/* unused */),
        .s_i2c_axi_rvalid  (/* unused */),
        .s_i2c_axi_rid     (/* unused */),
        .s_i2c_axi_rdata   (/* unused */),
        .s_i2c_axi_rresp   (/* unused */),
        .s_i2c_axi_rlast   (/* unused */),
        .s_i2c_axi_rready  (1'b1),

        .i2c_nbsy_irq      (/* unused */),
        .i2c_nrd_empty_irq (/* unused */),

        .released_credits_irq (s_released_credits_irq),
        .doorbell_irq         (s_doorbell_irq),
        .packet_committed_irq (s_packet_committed_irq),
        .ptp_irq              (s_ptp_irq),
        .perf_irq             (s_perf_irq),
        .wlink_irq            (s_wlink_irq)
    );

    // ----- Waveform dump ------------------------------------------------------
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
