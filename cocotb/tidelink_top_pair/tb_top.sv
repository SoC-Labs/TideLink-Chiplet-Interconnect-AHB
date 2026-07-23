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
    // Per-lane skid overrides (S3-A repro). Each defaults to the uniform
    // SKID_BITS so legacy tests are unchanged. Set these via +define+ to inject
    // DIFFERENTIAL per-lane skew — the condition that makes the cross-lane
    // deskew FIFO glitch all_ready and inject bubble words (deskew-bubble bug).
    parameter int SKID_L0 = `ifdef TB_TOP_SKID_L0 `TB_TOP_SKID_L0 `else SKID_BITS `endif,
    parameter int SKID_L1 = `ifdef TB_TOP_SKID_L1 `TB_TOP_SKID_L1 `else SKID_BITS `endif,
    parameter int SKID_L2 = `ifdef TB_TOP_SKID_L2 `TB_TOP_SKID_L2 `else SKID_BITS `endif,
    parameter int SKID_L3 = `ifdef TB_TOP_SKID_L3 `TB_TOP_SKID_L3 `else SKID_BITS `endif,
    parameter int SKID_L4 = `ifdef TB_TOP_SKID_L4 `TB_TOP_SKID_L4 `else SKID_BITS `endif,
    parameter int SKID_L5 = `ifdef TB_TOP_SKID_L5 `TB_TOP_SKID_L5 `else SKID_BITS `endif,
    parameter int SKID_L6 = `ifdef TB_TOP_SKID_L6 `TB_TOP_SKID_L6 `else SKID_BITS `endif,
    parameter int SKID_L7 = `ifdef TB_TOP_SKID_L7 `TB_TOP_SKID_L7 `else SKID_BITS `endif,

    // ─────────────────────────────────────────────────────────────────────────
    // BYPASS_AUTONEG (Phase 0c — autonomy plan)
    // ─────────────────────────────────────────────────────────────────────────
    // 1 (default, legacy) ─ the autoneg FSM stays in ST_BYPASS at POR.
    //   Mechanism: `nego_cfg_reg` resets to 7'd0 in the integration wrapper
    //   (axi_chiplet_controller.sv:432) → `nego_en=0` → ST_IDLE goes straight
    //   to ST_BYPASS (tidelink_autoneg.sv:590). All the existing tests
    //   (test_01..test_09) use this mode and drive role-lock by writing
    //   ROLE_CFG via APB through the W1S path (the `mask_hs_bypass_i=1` strap
    //   below opens the gate).
    //
    // 0 (autonomy) ─ at time 0 the tb forces `nego_cfg_reg=7'h41` and
    //   `nego_train_cfg_r=16'h0001` on both dies so the FSM runs without any
    //   APB stimulus. nego_cfg_reg[0]=1 enables nego, [6]=1 enables the
    //   mask-handshake auto path, and nego_train_cfg_r[0]=1 enables the
    //   training sub-flow. The forces release after a few cycles so the
    //   regs behave normally for the rest of sim — the autoneg FSM samples
    //   them while we're forcing and is committed to walking the
    //   ST_NEGO_INIT → … → ST_TRAIN_DONE chain. Used by
    //   `test_10_autonomous_train_post_por.py` and any future Phase 7
    //   autonomy tests. Select via Makefile:
    //     make MODULE=test_10_autonomous_train_post_por \
    //          COMPILE_ARGS+=+define+TB_TOP_BYPASS_AUTONEG=0 ...
    //
    // NOTE: the tb's `m_mask_hs_bypass`/`s_mask_hs_bypass` straps remain at 1
    // in BOTH modes — they gate the post-mask-handshake ROLE_CFG W1S latch
    // path on the APB side (so legacy tests can write ROLE_CFG), and they do
    // NOT short-circuit the autoneg FSM itself. In BYPASS_AUTONEG=0 mode the
    // FSM still walks the full mask-handshake states; the strap just means
    // the resulting role_lock can land via either the FSM's
    // `nego_set_role_lock_w` path or an APB W1S, whichever fires first.
    parameter int BYPASS_AUTONEG = `ifdef TB_TOP_BYPASS_AUTONEG `TB_TOP_BYPASS_AUTONEG `else 1 `endif,

    // RELY_ON_RTL_PRIO_DEFAULTS (Bug N7 regression — test_18)
    //   0 = tb force-injects nego_priority_reg = master:0x0001, slave:0x0002
    //       at POR (legacy behaviour for test_10/test_16). This MASKS the
    //       Bug N7 priority deadlock because the priorities are made
    //       asymmetric by the testbench, not by RTL.
    //   1 = tb leaves nego_priority_reg alone. The RTL's POR default decides.
    //       On pre-Bug-N7-fix RTL the POR default is 16'hFFFF on both dies,
    //       so the FSMs deadlock in ST_NEGO_WAIT → time out to ST_ERROR.
    //       On post-fix RTL the default derives from role_strap_i:
    //         strap=0 (master) → 16'h0001
    //         strap=1 (slave)  → 16'h0002
    //       which is exactly what the legacy force was doing — confirming
    //       the RTL fix preserves the existing autoneg behaviour.
    //   Default = 0 (preserve existing tests).
    parameter int RELY_ON_RTL_PRIO_DEFAULTS = `ifdef TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS `TB_TOP_RELY_ON_RTL_PRIO_DEFAULTS `else 0 `endif,

    // NEGO_CFG_RESET / NEGO_TRAIN_CFG_RESET — the POR value of nego_cfg_reg /
    // nego_train_cfg_r inside axi_chiplet_controller (see its param header).
    // These are forwarded verbatim into BOTH tidelink_top instances below so a
    // test can prove TRUE zero-poke bring-up: the autonomy chain arms from the
    // POR reset value ALONE, with NO tb `force` (BYPASS_AUTONEG=1) and NO APB
    // write ever landing on NEGO_CFG (0x2090 / ctrl_reg_addr 5'h0C) or
    // NEGO_TRAIN_CFG (0x210C / ctrl_reg_addr 5'h13).
    //
    // Defaults MIRROR the tidelink_top RTL defaults (7'h00 / 16'h0001), so every
    // existing pair test elaborates byte-identically (an explicit param binding
    // to the same value is a no-op). The fail-first zero-poke test overrides
    // NEGO_CFG_RESET to 7'h61 at compile time:
    //   +define+TB_TOP_NEGO_CFG_RESET=7\'h61
    // 7'h61 = nego_en[0] | nego_force_lock[5] | mask_hs_auto_en[6] — the exact
    // value the FPGA image now carries via tidelink_vivado_wrapper's parameter
    // default (captured into the packaged IP's component.xml → OOC synth).
    parameter [6:0]  NEGO_CFG_RESET_TB       = `ifdef TB_TOP_NEGO_CFG_RESET `TB_TOP_NEGO_CFG_RESET `else 7'h00 `endif,
    parameter [15:0] NEGO_TRAIN_CFG_RESET_TB = `ifdef TB_TOP_NEGO_TRAIN_CFG_RESET `TB_TOP_NEGO_TRAIN_CFG_RESET `else 16'h0001 `endif,

    // RETIRE_EN — the F4 tapeout knob for the event-gated RETIRE-AUTONOMY
    // (the B->A channel fix). Forwarded verbatim into BOTH tidelink_top
    // instances below so a test can prove the parameter genuinely REACHES
    // axi_chiplet_controller.RETIRE_EN from the top, in both settings.
    //
    // Default MIRRORS the tidelink_top RTL default (1'b1), so every existing
    // pair test elaborates byte-identically (an explicit param binding to the
    // same value is a no-op). The retire_en_plumb gate suite overrides it at
    // compile time (decimal, mirroring the NEGO_CFG_RESET=97 convention above —
    // keeps the +define+ free of quotes for make/shell):
    //   +define+TB_TOP_RETIRE_EN=0
    // That override is the DISCRIMINATING proof of the plumbing: if the
    // tidelink_top -> controller forwarding were dead (the NEGO_CFG_RESET
    // failure mode — plumbed at the top but never forwarded, so every build
    // silently took the module default), a top-level 0 would have NO effect,
    // the controller would keep its own 1'b1 default and the retire would
    // still fire. Retire staying 0 is only possible if the 0 arrived.
    parameter        RETIRE_EN_TB            = `ifdef TB_TOP_RETIRE_EN `TB_TOP_RETIRE_EN `else 1'b1 `endif,

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

    // ── I2 per-die POR skew injection (PLAN_TIDELINK_INTEGRATION §3 I2) ──
    // cocotb holds {m,s}_por_gate low to delay one die's reset release
    // relative to the other (asymmetric-POR / deploy-skew emulation,
    // test_24_por_skew_sweep). Default 1 → per-die resets follow the
    // shared poresetn/hresetn bit-exactly, so every existing test is
    // unchanged. The pad gates squash the in-reset die's PHY outputs to 0
    // (real pads are driven-low/Hi-Z under reset; in sim they would X-poison
    // the live peer's RX).
    logic m_por_gate = 1'b1;
    logic s_por_gate = 1'b1;
    wire  m_poresetn_w = poresetn & m_por_gate;
    wire  m_hresetn_w  = hresetn  & m_por_gate;
    wire  s_poresetn_w = poresetn & s_por_gate;
    wire  s_hresetn_w  = hresetn  & s_por_gate;

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
        .SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES),
        .SKID_BITS_LANE0(SKID_L0), .SKID_BITS_LANE1(SKID_L1),
        .SKID_BITS_LANE2(SKID_L2), .SKID_BITS_LANE3(SKID_L3),
        .SKID_BITS_LANE4(SKID_L4), .SKID_BITS_LANE5(SKID_L5),
        .SKID_BITS_LANE6(SKID_L6), .SKID_BITS_LANE7(SKID_L7)
    ) u_skid_m2s (
        .pad_clk_in   (m_pad_clk_tx),
        .pad_data_in  (m_pad_tx),
        .pad_clk_out  (m_pad_clk_tx_skid),
        .pad_data_out (m_pad_tx_skid)
    );

    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES),
        .SKID_BITS_LANE0(SKID_L0), .SKID_BITS_LANE1(SKID_L1),
        .SKID_BITS_LANE2(SKID_L2), .SKID_BITS_LANE3(SKID_L3),
        .SKID_BITS_LANE4(SKID_L4), .SKID_BITS_LANE5(SKID_L5),
        .SKID_BITS_LANE6(SKID_L6), .SKID_BITS_LANE7(SKID_L7)
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
    // PTP — behavioural PHC models (see tb_phc_model.sv)
    // -------------------------------------------------------------------------
    // The previous tb tied every PHC port off (phc_*=0, phc_locked_i=1'b1),
    // which made HW_SYNC_STATUS[18] a spurious pass and meant NO real PTP sync
    // could be demonstrated over the link. Each die now owns a free-running
    // PHC clock model that the servo can capture and discipline; phc_locked_i
    // is driven realistically by the model (asserted only after the PHC has
    // been running, NOT hard-tied). The slave PHC is started with a large
    // initial offset vs the master so the servo has a real error to null.
    //
    // cocotb sets {m,s}_phc_init_{seconds,nanoseconds} BEFORE releasing
    // hresetn, and can pull {m,s}_phc_lock_enable low to test the lock gate.
    // -------------------------------------------------------------------------
    // Both PHCs start in the SAME second (the interesting PTP discipline here
    // is the sub-second offset). The slave carries a +50 us nanosecond skew
    // that the servo must null. Keeping the seconds equal mirrors a realistic
    // post-coarse-sync PTP scenario and avoids a whole-second ambiguity in the
    // servo's phase-step path (which sets seconds from the local t2 capture).
    logic [47:0] m_phc_init_seconds     = 48'd0;
    logic [29:0] m_phc_init_nanoseconds = 30'd0;
    logic        m_phc_lock_enable      = 1'b1;
    logic [47:0] s_phc_init_seconds     = 48'd0;
    logic [29:0] s_phc_init_nanoseconds = 30'd20_000;  // +20 us slave skew
    logic        s_phc_lock_enable      = 1'b1;

    // tidelink_top <-> PHC model nets (master)
    wire        m_phc_hw_capture;
    wire [29:0] m_phc_nanoseconds;
    wire [47:0] m_phc_seconds;
    wire        m_phc_pps;
    wire [47:0] m_phc_hw_cap_seconds;
    wire [29:0] m_phc_hw_cap_nanoseconds;
    wire [31:0] m_phc_hw_cap_sub_nanoseconds;
    wire        m_phc_hw_set_time;
    wire [47:0] m_phc_hw_set_seconds;
    wire [29:0] m_phc_hw_set_nanoseconds;
    wire        m_phc_hw_adj_valid;
    wire [31:0] m_phc_hw_adj_ns_incr_frac;
    wire        m_phc_locked;

    // tidelink_top <-> PHC model nets (slave)
    wire        s_phc_hw_capture;
    wire [29:0] s_phc_nanoseconds;
    wire [47:0] s_phc_seconds;
    wire        s_phc_pps;
    wire [47:0] s_phc_hw_cap_seconds;
    wire [29:0] s_phc_hw_cap_nanoseconds;
    wire [31:0] s_phc_hw_cap_sub_nanoseconds;
    wire        s_phc_hw_set_time;
    wire [47:0] s_phc_hw_set_seconds;
    wire [29:0] s_phc_hw_set_nanoseconds;
    wire        s_phc_hw_adj_valid;
    wire [31:0] s_phc_hw_adj_ns_incr_frac;
    wire        s_phc_locked;

    tb_phc_model #(.SYS_DATA_W(SYS_DATA_W), .NOMINAL_NS_INCR(1)) u_m_phc (
        .phc_clk                    (hclk),
        .phc_resetn                 (m_hresetn_w),
        .init_seconds               (m_phc_init_seconds),
        .init_nanoseconds           (m_phc_init_nanoseconds),
        .lock_enable_i              (m_phc_lock_enable),
        .phc_hw_capture             (m_phc_hw_capture),
        .phc_nanoseconds            (m_phc_nanoseconds),
        .phc_seconds                (m_phc_seconds),
        .phc_pps                    (m_phc_pps),
        .phc_hw_cap_seconds         (m_phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (m_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (m_phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time            (m_phc_hw_set_time),
        .phc_hw_set_seconds         (m_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (m_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (m_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (m_phc_hw_adj_ns_incr_frac),
        .phc_locked_o               (m_phc_locked)
    );

    tb_phc_model #(.SYS_DATA_W(SYS_DATA_W), .NOMINAL_NS_INCR(1)) u_s_phc (
        .phc_clk                    (hclk),
        .phc_resetn                 (s_hresetn_w),
        .init_seconds               (s_phc_init_seconds),
        .init_nanoseconds           (s_phc_init_nanoseconds),
        .lock_enable_i              (s_phc_lock_enable),
        .phc_hw_capture             (s_phc_hw_capture),
        .phc_nanoseconds            (s_phc_nanoseconds),
        .phc_seconds                (s_phc_seconds),
        .phc_pps                    (s_phc_pps),
        .phc_hw_cap_seconds         (s_phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (s_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (s_phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time            (s_phc_hw_set_time),
        .phc_hw_set_seconds         (s_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (s_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (s_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (s_phc_hw_adj_ns_incr_frac),
        .phc_locked_o               (s_phc_locked)
    );

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
        .TIDELINK_PAIR_BASE(M_PAIR_BASE),
        // Zero-poke POR arming — see the parameter header. Defaults mirror the
        // tidelink_top RTL defaults (7'h00/16'h0001) so existing tests are
        // byte-identical; test_zeropoke_por overrides NEGO_CFG_RESET → 7'h61.
        .NEGO_CFG_RESET      (NEGO_CFG_RESET_TB),
        .NEGO_TRAIN_CFG_RESET(NEGO_TRAIN_CFG_RESET_TB),
        // F4 RETIRE-AUTONOMY knob — default 1'b1 (no-op vs the RTL default);
        // test_retire_en_plumb overrides to 1'b0 to prove the plumbing is live.
        .RETIRE_EN           (RETIRE_EN_TB)
    ) u_master (
        .hclk              (hclk),
        .hresetn           (m_hresetn_w),
        .poresetn          (m_poresetn_w),

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

        // PHY pads — cross-wired via skid blocks (gated to 0 while the
        // driving die is held in reset — see I2 POR-skew block above)
        .pad_clk_tx        (m_pad_clk_tx),
        .pad_tx            (m_pad_tx),
        .pad_clk_rx        (s_pad_clk_tx_skid & s_por_gate),
        .pad_rx            (s_pad_tx_skid & {NUM_PHY_LANES{s_por_gate}}),

        // §9 IDELAYE2 RX delay ref clock (USE_IDELAY=0 default -> passthrough)
        .idelay_ref_clk    (1'b0),

        // PHC — driven by behavioural PHC model u_m_phc (PTP-over-link sync)
        .phc_clk                    (hclk),
        .phc_resetn                 (m_hresetn_w),
        .phc_nanoseconds            (m_phc_nanoseconds),
        .phc_seconds                (m_phc_seconds),
        .phc_pps                    (m_phc_pps),
        .phc_hw_cap_seconds         (m_phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (m_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (m_phc_hw_cap_sub_nanoseconds),
        .phc_locked_i               (m_phc_locked),

        // PTP AHB write port — tied off (cocotb uses APB register path)
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
        .phc_hw_capture             (m_phc_hw_capture),
        .phc_hw_set_time            (m_phc_hw_set_time),
        .phc_hw_set_seconds         (m_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (m_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (m_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (m_phc_hw_adj_ns_incr_frac),
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
        .TIDELINK_PAIR_BASE(S_PAIR_BASE),
        // Zero-poke POR arming — mirror of the master instance above.
        .NEGO_CFG_RESET      (NEGO_CFG_RESET_TB),
        .NEGO_TRAIN_CFG_RESET(NEGO_TRAIN_CFG_RESET_TB),
        // F4 RETIRE-AUTONOMY knob — default 1'b1 (no-op vs the RTL default);
        // test_retire_en_plumb overrides to 1'b0 to prove the plumbing is live.
        .RETIRE_EN           (RETIRE_EN_TB)
    ) u_slave (
        .hclk              (hclk),
        .hresetn           (s_hresetn_w),
        .poresetn          (s_poresetn_w),

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
        .pad_clk_rx        (m_pad_clk_tx_skid & m_por_gate),
        .pad_rx            (m_pad_tx_skid & {NUM_PHY_LANES{m_por_gate}}),

        .idelay_ref_clk    (1'b0),

        // PHC — driven by behavioural PHC model u_s_phc (PTP-over-link sync)
        .phc_clk                    (hclk),
        .phc_resetn                 (s_hresetn_w),
        .phc_nanoseconds            (s_phc_nanoseconds),
        .phc_seconds                (s_phc_seconds),
        .phc_pps                    (s_phc_pps),
        .phc_hw_cap_seconds         (s_phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (s_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (s_phc_hw_cap_sub_nanoseconds),
        .phc_locked_i               (s_phc_locked),

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
        .phc_hw_capture             (s_phc_hw_capture),
        .phc_hw_set_time            (s_phc_hw_set_time),
        .phc_hw_set_seconds         (s_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (s_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (s_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (s_phc_hw_adj_ns_incr_frac),
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

    // -------------------------------------------------------------------------
    // BYPASS_AUTONEG=0 — Phase 0c autonomous-training engagement
    // -------------------------------------------------------------------------
    // Force `nego_cfg_reg` and `nego_train_cfg_r` non-zero on both dies at
    // time 0 so the autoneg FSM runs the full ST_NEGO_INIT → ST_TRAIN_DONE
    // chain without any APB stimulus. Mirrors the production behaviour the
    // RTL agent will land via `NEGO_TRAIN_CFG_RESET` parameter override and
    // a future `NEGO_CFG_RESET` strap. Until that lands, the tb-side force
    // here is the simplest way to exercise the FSM in sim.
    //
    //   nego_cfg_reg bits ─ from axi_chiplet_controller.sv:1153-1207
    //     [0] nego_en           ← 1 (run autoneg)
    //     [1] nego_start        ← 0 (level-only; ST_NEGO_WAIT advances on
    //                              backoff timer regardless)
    //     [3:2] nego_pri_sel    ← 2'b00 (use `nego_priority_reg` ─ POR 0,
    //                              but the testbench `nego_priority_i` strap
    //                              feeds the FSM via the [1] mux when
    //                              nego_pri_sel=1; we leave it at 0 so the
    //                              backoff_delay term comes out trivial and
    //                              the FSM doesn't sit in ST_NEGO_WAIT for
    //                              eons)
    //     [4] nego_fallback     ← 0
    //     [5] nego_force_lock   ← 1 (latch role_locked on nego completion)
    //     [6] mask_hs_auto_en   ← 1 (run the mask-handshake states; required
    //                              before NEGO_DONE_PRE branches into
    //                              ST_TRAIN_ENTER)
    //
    //   nego_train_cfg_r ─ from axi_chiplet_controller.sv:1213-1217
    //     [0] train_auto_en     ← 1 (engage ST_TRAIN_ENTER on the master after
    //                              the mask handshake matches)
    //     [7:4] train_poll_timeout ← 0xF (15 polls before fail — full default)
    //     [15:8] train_fsm_wait_hi ← 0x00 (use the 4095-cycle default dwell)
    //
    //   nego_priority_reg also forced — without it the priority-mux gets
    //   selected_priority=0 and the backoff_delay computation in
    //   tidelink_autoneg.sv:377 still yields the NEGO_BASE_DELAY floor, but
    //   we want a tiny non-zero priority on the master and a slightly
    //   higher one on the slave so the natural ST_NEGO_WAIT timer always
    //   picks ONE side as the I²C claimer (instead of both sides racing).
    //
    // The forces last for the entire sim. Releasing them is unnecessary —
    // the FSM only samples cfg bits in the gated arms (e.g. ST_IDLE checks
    // nego_en) and the chiplet controller's APB-write logic can still
    // override at any time (the simulator merges force + driver, with
    // force taking priority). For Phase 0c we just need the regs to stay
    // hot for the full bring-up window.
    `define M_CTRL u_master.u_chiplet_controller
    `define S_CTRL u_slave.u_chiplet_controller
    initial begin
        if (BYPASS_AUTONEG == 0) begin
            $display("[%0t] tb_top: BYPASS_AUTONEG=0 — forcing autoneg+train at POR", $time);
            // Force at time 0 — before poresetn rises. The chiplet controller's
            // POR-reset clause (axi_chiplet_controller.sv:432) will try to set
            // nego_cfg_reg<=7'd0 on the (!poresetn) branch; force overrides
            // that assignment, so when poresetn rises the regs are already at
            // our target value. The autoneg FSM samples nego_en in ST_IDLE
            // and immediately advances to ST_NEGO_INIT.
            force `M_CTRL.nego_cfg_reg      = 7'h61;  // bits [6]=1, [5]=1, [0]=1
            force `M_CTRL.nego_train_cfg_r  = 16'h00F1;
            force `S_CTRL.nego_cfg_reg      = 7'h61;
            force `S_CTRL.nego_train_cfg_r  = 16'h00F1;
            // ─── nego_priority_reg force — Bug N7 regression gate ──────────
            // When RELY_ON_RTL_PRIO_DEFAULTS=0 (legacy), force priorities
            // asymmetric (master=1, slave=2) so the existing autoneg tests
            // remain deterministic regardless of the RTL POR default.
            // When =1 (test_18), leave the regs alone so the RTL POR default
            // (16'hFFFF pre-fix; role_strap-derived post-fix) is what the FSM
            // sees. This is the path that exercises Bug N7.
            if (RELY_ON_RTL_PRIO_DEFAULTS == 0) begin
                force `M_CTRL.nego_priority_reg = 16'h0001;
                force `S_CTRL.nego_priority_reg = 16'h0002;
            end
            // ─── Bug N1 (2026-05-29) — known RTL bug, see docs ─────────────
            // Bug N1: when nego completes with mask_hs_auto_en=1, the FSM
            // walks 4 (POLL) → 9 (MASK_RD_ADDR), and on the same edge
            // role_lock_reg latches → role_in_nego falls 0 → the
            // axi_chiplet_controller.sv:1045 `nego_driving` mux disconnects
            // the autoneg FSM from the i2c_master_axil bus. The FSM is then
            // stuck in TXN_DATA / AXL_WR_RESP forever (m_axil_bvalid never
            // arrives because the AXIL bus is muxed to the bridge).
            //
            // The training-state extension `train_in_progress_w` (autoneg.sv
            // :1656) covers states 11/12/13/14/15 but NOT 8/9/10 (the
            // mask-handshake states). RTL fix needed in
            // local_overrides/axi_chiplet_controller.sv:1045 — extend
            // nego_driving to also cover mask-handshake states post-lock.
            //
            // We deliberately do NOT force a workaround here because the
            // tb-side fix would mask the bug. Diagnostic test
            // cocotb/tidelink_top_pair/test_11_i2c_mask_rd_addr_probe.py
            // reproduces the hang with dense per-cycle probes of axl_state_r,
            // i2c_master state, and the bus pins.
            // Hold the force long enough that hresetn has been high for many
            // cycles and the FSM has fully sampled nego_en. After that, let
            // SW (or the FSM's own NEGO_TRAIN_CFG W1P retrain path) drive
            // the regs normally. 5000 ns @ 50 MHz hclk = 250 cycles.
            #5000;
            release `M_CTRL.nego_cfg_reg;
            release `M_CTRL.nego_train_cfg_r;
            release `S_CTRL.nego_cfg_reg;
            release `S_CTRL.nego_train_cfg_r;
            if (RELY_ON_RTL_PRIO_DEFAULTS == 0) begin
                release `M_CTRL.nego_priority_reg;
                release `S_CTRL.nego_priority_reg;
            end
            $display("[%0t] tb_top: BYPASS_AUTONEG=0 — autoneg forces released", $time);
        end
    end

    // ----- Waveform dump ------------------------------------------------------
    // Gated by TB_TOP_DUMP_WAVES so probe-only tests can opt out (the VCD
    // grows ~1 GB / minute under multi-test cocotb runs, OOMing the host).
    // Default ON to preserve prior behaviour; add +define+TB_TOP_NO_DUMP=1 to
    // disable. Run with: COMPILE_ARGS+="+define+TB_TOP_NO_DUMP" make ...
    `ifndef TB_TOP_NO_DUMP
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end
    `endif

    // ---- L4 training-exit-deadlock sim knob (2026-07-01) ---------------------
    // Shrink the V2 calibrator's S_HOLD dwell so the *de-forced* autonomous
    // training-exit test (test_31) is bounded WITHOUT bypassing any FSM state.
    // Production HOLD_CYCLES = 8*128*64 = 65536 link-clk cycles (≫ sim budget).
    // This is a pure TIMING knob (parameter override) — the calibrator still
    // walks S_SWEEP → S_HOLD → (hold_ctr expiry) → S_VALIDATE → S_DONE exactly
    // as on silicon; only the hold WIDTH shrinks. Guarded so the existing
    // (bypass-forced) tests are byte-identical. DWELL is also trimmed so a full
    // sweep (128 × DWELL) fits the poll budget.
    `ifdef TB_TOP_SHORT_CAL_HOLD
    defparam u_master.u_chiplet_controller.u_calibrator.HOLD_CYCLES  = `TB_TOP_SHORT_CAL_HOLD;
    defparam u_slave.u_chiplet_controller.u_calibrator.HOLD_CYCLES   = `TB_TOP_SHORT_CAL_HOLD;
    `endif
    `ifdef TB_TOP_SHORT_CAL_DWELL
    defparam u_master.u_chiplet_controller.u_calibrator.DWELL_CYCLES = `TB_TOP_SHORT_CAL_DWELL;
    defparam u_slave.u_chiplet_controller.u_calibrator.DWELL_CYCLES  = `TB_TOP_SHORT_CAL_DWELL;
    `endif

    // ---- Zero-poke assertion aid (2026-07-10) --------------------------------
    // PASSIVE sticky monitors (no DUT fanout) that latch the instant a ctrl-reg
    // write lands on NEGO_CFG or NEGO_TRAIN_CFG on either die. These are the ONLY
    // two registers whose value gates the autonomy chain; a genuine zero-poke POR
    // bring-up must leave them at their reset (parameter) value for the whole run.
    //
    //   ctrl_reg_addr = {paddr[8:7], paddr[4:2]}  (axi_chiplet_controller.sv:505)
    //   NEGO_CFG       = region4(2'b01) slot 3'h4  → 5'b01100 = 5'h0C (APB 0x2090)
    //   NEGO_TRAIN_CFG = region8(2'b10) slot 3'h3  → 5'b10011 = 5'h13 (APB 0x210C)
    //
    // ctrl_reg_write is the union of the local-APB write and the slave-AXIL
    // bridge write (axi_chiplet_controller.sv:528), so this catches a host poke
    // from EITHER config path. It is sampled on hclk (== apb_clk in this tb), the
    // same edge that would clock the new value into the register, so no
    // single-cycle write can be missed. test_zeropoke_por reads these and fails
    // if either is set. Inert for every other test (they never poke these regs).
    reg m_nego_poke_seen = 1'b0;
    reg s_nego_poke_seen = 1'b0;
    always @(posedge hclk) begin
        if (u_master.u_chiplet_controller.ctrl_reg_write &&
            ((u_master.u_chiplet_controller.ctrl_reg_addr == 5'h0C) ||
             (u_master.u_chiplet_controller.ctrl_reg_addr == 5'h13)))
            m_nego_poke_seen <= 1'b1;
        if (u_slave.u_chiplet_controller.ctrl_reg_write &&
            ((u_slave.u_chiplet_controller.ctrl_reg_addr == 5'h0C) ||
             (u_slave.u_chiplet_controller.ctrl_reg_addr == 5'h13)))
            s_nego_poke_seen <= 1'b1;
    end

    // ─────────────────────────────────────────────────────────────────────────
    // F4 — RETIRE_EN plumbing probe (test_retire_en_plumb)
    // ─────────────────────────────────────────────────────────────────────────
    // Hierarchical READ-BACK of RETIRE_EN as it actually landed INSIDE
    // axi_chiplet_controller — i.e. at the DESTINATION, not the value this tb
    // handed to tidelink_top. That distinction is the whole point: the
    // NEGO_CFG_RESET regression (plumbed at the top, never forwarded to the
    // consumer, so every bitstream silently built the module default) would be
    // INVISIBLE to a probe that read the top-level parameter back. This one
    // reads through the forwarding path, so if that path is missing or wrong
    // the probe reports the controller's own default and the test fails.
    //
    // A parameter is elaboration-constant, so these are constant wires; cocotb
    // reads them as ordinary signals (no VPI parameter access required, which
    // is simulator-dependent).
    wire retire_en_at_ctrl_m = u_master.u_chiplet_controller.RETIRE_EN;
    wire retire_en_at_ctrl_s = u_slave.u_chiplet_controller.RETIRE_EN;

endmodule
