// =============================================================================
// tb_top.sv — Paired V2 (TIDELINK_PHY_V2) `tidelink_top` simulation: master +
//             slave cross-wired through their GPIO PHY pads, with PER-LANE
//             WHOLE-WORD EPOCH SKEW injection.
//
// Purpose (V37_FINAL_DIAGNOSIS_2026_06_12 — integrated pre-silicon gate)
// ----------------------------------------------------------------------
// V2 sibling of cocotb/tidelink_top_pair/tb_top.sv. Compiled against
// flists/tidelink_fpga_v2.flist (deps/tidelink-phy serdes + always-on
// calibrator + epoch-anchored deskew; the TIDELINK_PHY_V2 define is carried
// by the per-file v2shims, not by this tb).
//
// The v37 silicon defect — cross-lane word-EPOCH incoherence on a skewed
// RX — was invisible to every integrated sim because the pad_skid skew
// hooks only injected sub-word BIT skew. This tb adds per-lane, per-
// DIRECTION whole-word epoch offsets: lane n of a direction is delayed by
// (16*EPOCH_WORDS + SKID_BITS) pad_clk cycles. A 16-bit-multiple delay
// leaves the lane's word framing and clock phase untouched (per-lane
// training locks perfectly) while the lanes deliver different word EPOCHS
// into the 128-bit assembly — the exact decoupled v37 failure mode that
// the V2 epoch-deskew anchor (deps/tidelink-phy c332722) corrects.
//
// Knobs (all compile-time, driven from the Makefile):
//   TB_TOP_SKID_BITS / TB_TOP_SKID_L<n>   legacy uniform / per-lane BIT skew
//   TB_TOP_EPOCH_M2S_L<n>                 master->slave per-lane WORD skew
//                                         (slave's RX sees the epoch offsets)
//   TB_TOP_EPOCH_S2M_L<n>                 slave->master per-lane WORD skew
//                                         (master's RX — the historically
//                                         skewed z2_02 side)
//   TB_TOP_EPOCH_ANCHOR_DIS               NEGATIVE CONTROL: defparam the
//                                         WlinkGPIOPHY EPOCH_ANCHOR_EN to 0
//                                         on both dies (occupancy-only
//                                         deskew = the pre-fix V2 baseline;
//                                         the epoch-skew test must then FAIL)
//
// Everything else (DUT wiring, tie-offs, APB/AHB port surface, autonomy
// force hooks) is kept line-identical to the V1 pair tb so the two
// environments stay diffable.
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
    // Per-lane WHOLE-WORD epoch offsets, per direction (V37 defect class).
    // Units: 16-bit WORDS. Each lane's pad-level delay in that direction is
    // SKID_L<n> + 16*EPOCH_<dir>_L<n> pad_clk cycles. Word-multiple delays
    // pass through pad_skid cleanly (it is an arbitrary-depth per-lane shift
    // register; the MAX_SKID=7 note in its header only mirrors the
    // swi_bit_slip field width and is not enforced).
    // ─────────────────────────────────────────────────────────────────────────
    parameter int EPOCH_M2S_L0 = `ifdef TB_TOP_EPOCH_M2S_L0 `TB_TOP_EPOCH_M2S_L0 `else 0 `endif,
    parameter int EPOCH_M2S_L1 = `ifdef TB_TOP_EPOCH_M2S_L1 `TB_TOP_EPOCH_M2S_L1 `else 0 `endif,
    parameter int EPOCH_M2S_L2 = `ifdef TB_TOP_EPOCH_M2S_L2 `TB_TOP_EPOCH_M2S_L2 `else 0 `endif,
    parameter int EPOCH_M2S_L3 = `ifdef TB_TOP_EPOCH_M2S_L3 `TB_TOP_EPOCH_M2S_L3 `else 0 `endif,
    parameter int EPOCH_M2S_L4 = `ifdef TB_TOP_EPOCH_M2S_L4 `TB_TOP_EPOCH_M2S_L4 `else 0 `endif,
    parameter int EPOCH_M2S_L5 = `ifdef TB_TOP_EPOCH_M2S_L5 `TB_TOP_EPOCH_M2S_L5 `else 0 `endif,
    parameter int EPOCH_M2S_L6 = `ifdef TB_TOP_EPOCH_M2S_L6 `TB_TOP_EPOCH_M2S_L6 `else 0 `endif,
    parameter int EPOCH_M2S_L7 = `ifdef TB_TOP_EPOCH_M2S_L7 `TB_TOP_EPOCH_M2S_L7 `else 0 `endif,
    parameter int EPOCH_S2M_L0 = `ifdef TB_TOP_EPOCH_S2M_L0 `TB_TOP_EPOCH_S2M_L0 `else 0 `endif,
    parameter int EPOCH_S2M_L1 = `ifdef TB_TOP_EPOCH_S2M_L1 `TB_TOP_EPOCH_S2M_L1 `else 0 `endif,
    parameter int EPOCH_S2M_L2 = `ifdef TB_TOP_EPOCH_S2M_L2 `TB_TOP_EPOCH_S2M_L2 `else 0 `endif,
    parameter int EPOCH_S2M_L3 = `ifdef TB_TOP_EPOCH_S2M_L3 `TB_TOP_EPOCH_S2M_L3 `else 0 `endif,
    parameter int EPOCH_S2M_L4 = `ifdef TB_TOP_EPOCH_S2M_L4 `TB_TOP_EPOCH_S2M_L4 `else 0 `endif,
    parameter int EPOCH_S2M_L5 = `ifdef TB_TOP_EPOCH_S2M_L5 `TB_TOP_EPOCH_S2M_L5 `else 0 `endif,
    parameter int EPOCH_S2M_L6 = `ifdef TB_TOP_EPOCH_S2M_L6 `TB_TOP_EPOCH_S2M_L6 `else 0 `endif,
    parameter int EPOCH_S2M_L7 = `ifdef TB_TOP_EPOCH_S2M_L7 `TB_TOP_EPOCH_S2M_L7 `else 0 `endif,

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
    // Raw S->M skid output, fed into the (optional) marginal-eye injector.
    wire [NUM_PHY_LANES-1:0]      s_pad_tx_skid_raw;

    // Per-direction lane delay = legacy bit skid + 16 pad_clk cycles per
    // whole-word epoch offset. A word-multiple delay shifts the lane's
    // content by exactly one word EPOCH with no framing/clock-phase change.
    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES),
        .SKID_BITS_LANE0(SKID_L0 + 16*EPOCH_M2S_L0),
        .SKID_BITS_LANE1(SKID_L1 + 16*EPOCH_M2S_L1),
        .SKID_BITS_LANE2(SKID_L2 + 16*EPOCH_M2S_L2),
        .SKID_BITS_LANE3(SKID_L3 + 16*EPOCH_M2S_L3),
        .SKID_BITS_LANE4(SKID_L4 + 16*EPOCH_M2S_L4),
        .SKID_BITS_LANE5(SKID_L5 + 16*EPOCH_M2S_L5),
        .SKID_BITS_LANE6(SKID_L6 + 16*EPOCH_M2S_L6),
        .SKID_BITS_LANE7(SKID_L7 + 16*EPOCH_M2S_L7)
    ) u_skid_m2s (
        .pad_clk_in   (m_pad_clk_tx),
        .pad_data_in  (m_pad_tx),
        .pad_clk_out  (m_pad_clk_tx_skid),
        .pad_data_out (m_pad_tx_skid)
    );

    pad_skid #(
        .SKID_BITS(SKID_BITS), .LANES(NUM_PHY_LANES),
        .SKID_BITS_LANE0(SKID_L0 + 16*EPOCH_S2M_L0),
        .SKID_BITS_LANE1(SKID_L1 + 16*EPOCH_S2M_L1),
        .SKID_BITS_LANE2(SKID_L2 + 16*EPOCH_S2M_L2),
        .SKID_BITS_LANE3(SKID_L3 + 16*EPOCH_S2M_L3),
        .SKID_BITS_LANE4(SKID_L4 + 16*EPOCH_S2M_L4),
        .SKID_BITS_LANE5(SKID_L5 + 16*EPOCH_S2M_L5),
        .SKID_BITS_LANE6(SKID_L6 + 16*EPOCH_S2M_L6),
        .SKID_BITS_LANE7(SKID_L7 + 16*EPOCH_S2M_L7)
    ) u_skid_s2m (
        .pad_clk_in   (s_pad_clk_tx),
        .pad_data_in  (s_pad_tx),
        .pad_clk_out  (s_pad_clk_tx_skid),
        .pad_data_out (s_pad_tx_skid_raw)
    );

    // ─────────────────────────────────────────────────────────────────────────
    // MARGINAL-EYE fault injector on the S->M path (post-skid, pre-master-RX).
    // HARNESS ONLY. Default OFF (compile without TB_TOP_EYE_FAULT => the
    // raw skid output passes straight through, every existing test unchanged).
    // When TB_TOP_EYE_FAULT is defined, the injector is inserted and its
    // controls (err_en/err_mask/err_burst/err_period) are driven by cocotb
    // (hierarchical force) to corrupt the training-exit content edge and/or
    // sustained data on the master's RX — modelling the silicon eye that the
    // clean whole-word pad_skid does not.
    // ─────────────────────────────────────────────────────────────────────────
`ifdef TB_TOP_EYE_FAULT
    eye_fault #(.LANES(NUM_PHY_LANES)) u_eye_s2m (
        .pad_clk_in   (s_pad_clk_tx_skid),
        .pad_data_in  (s_pad_tx_skid_raw),
        .pad_clk_out  (/* unused: clk already forwarded by skid */),
        .pad_data_out (s_pad_tx_skid)
    );
`else
    assign s_pad_tx_skid = s_pad_tx_skid_raw;
`endif

    // ─────────────────────────────────────────────────────────────────────────
    // NEGATIVE CONTROL hook (step 3 of the v38 gate): force the V2 epoch-
    // deskew anchor OFF on both dies, reverting the deskew to the pre-fix
    // occupancy-only behaviour. EPOCH_ANCHOR_EN is a WlinkGPIOPHY parameter
    // (default 1'b1, deps/tidelink-phy c332722) that Wlink's instantiation
    // does not pass through, so a hierarchical defparam from the tb is the
    // cleanest non-invasive override (no submodule edit, no flist fork).
    // It propagates WlinkGPIOPHY -> WavD2DGpio -> tidelink_lane_deskew at
    // elaboration. With this define the epoch-skew test MUST fail — that
    // failure is the proof that the suite detects the v37 defect class.
    // ─────────────────────────────────────────────────────────────────────────
`ifdef TB_TOP_EPOCH_ANCHOR_DIS
    defparam u_master.u_chiplet_controller.u_wlink.phy.EPOCH_ANCHOR_EN = 1'b0;
    defparam u_slave.u_chiplet_controller.u_wlink.phy.EPOCH_ANCHOR_EN  = 1'b0;
`endif
    // Wave-0 #11: symmetric counterpart to _DIS — force the whole-word EPOCH
    // corrector ON *at the deskew instance* (Wlink forwards phy.EPOCH_ANCHOR_EN
    // to WavD2DGpio but NOT onward to tidelink_lane_deskew, so the corrector is
    // compiled OFF in the shipping stack — banner "deskew: m=0 s=0"). This
    // hierarchical override drives the deskew param directly so the skew-faithful
    // EPOCH_PROFILE=silicon path can be exercised with the corrector engaged.
`ifdef TB_TOP_EPOCH_ANCHOR_FORCE
    // EPOCH and SYNC_REANCHOR correctors are mutually exclusive (deskew elab
    // guard). The shipping stack runs SYNC_REANCHOR (needs the SYNC beacon,
    // which this bring-up leaves off); swap to the EPOCH corrector here.
    defparam u_master.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.SYNC_REANCHOR_EN = 1'b0;
    defparam u_slave.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.SYNC_REANCHOR_EN  = 1'b0;
    defparam u_master.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.EPOCH_ANCHOR_EN = 1'b1;
    defparam u_slave.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.EPOCH_ANCHOR_EN  = 1'b1;
`endif

    // ─────────────────────────────────────────────────────────────────────────
    // EPOCH-ANCHOR SELECT (2026-07-17): drive the WlinkGPIOPHY EPOCH_ANCHOR_EN
    // param =1 on both dies. With the plumbing fix (WavD2DGpio_v2 forwards the
    // param to u_deskew, SYNC_REANCHOR_EN = its complement) this PROPAGATES
    // phy -> gpio -> u_deskew through the REAL PARAMETER PATH — it is NOT a direct
    // defparam on u_deskew, so it exercises the shipping plumbing. Selects the
    // one-shot training-exit EPOCH corrector (SYNC_REANCHOR off). The elaboration
    // banner below then reads "master=1 (deskew: m=1)" — proof the hop is live.
    // ─────────────────────────────────────────────────────────────────────────
`ifdef TB_TOP_EPOCH_ANCHOR_EN
    defparam u_master.u_chiplet_controller.u_wlink.phy.EPOCH_ANCHOR_EN = 1'b1;
    defparam u_slave.u_chiplet_controller.u_wlink.phy.EPOCH_ANCHOR_EN  = 1'b1;
`endif

    // Elaboration self-check: print the anchor enable actually compiled into
    // the deskew of each die (guards against a silently-ignored defparam).
    initial begin
        #1;
        $display("[tb_top] EPOCH_ANCHOR_EN: master=%0d slave=%0d (deskew: m=%0d s=%0d)",
                 u_master.u_chiplet_controller.u_wlink.phy.EPOCH_ANCHOR_EN,
                 u_slave.u_chiplet_controller.u_wlink.phy.EPOCH_ANCHOR_EN,
                 u_master.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.EPOCH_ANCHOR_EN,
                 u_slave.u_chiplet_controller.u_wlink.phy.gpio.u_deskew.EPOCH_ANCHOR_EN);
    end

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
    // MASTER AHB-Sub — EXPOSED to cocotb (XHB500 transparent-window driver).
    //   A cocotb AHB-Lite master drives single word write/read at aperture
    //   0x4000_0000+off; the access transits ahb_sub -> XHB500 AHB->AXI ->
    //   chiplet controller s_axi -> FC aw/w/b/ar/r -> peer die -> XHB500
    //   AXI->AHB -> peer ahb_mng -> the per-die BRAM terminus below, and the
    //   read-back returns byte-exact. Mirrors
    //   cocotb/debug/tidelink_peer_aperture/tb_top.sv. Initialised to IDLE so
    //   the existing FC-datapath tests (which never touch ahb_sub) see a clean
    //   tied-off subordinate — no spurious XHB500 transactions / no X-prop.
    // -------------------------------------------------------------------------
    logic                          m_ahb_sub_hsel   = 1'b0;
    logic   [SYS_ADDR_W-1:0]       m_ahb_sub_haddr  = '0;
    logic                    [2:0] m_ahb_sub_hburst = 3'h0;
    logic                    [3:0] m_ahb_sub_hprot  = 4'h0;
    logic                    [2:0] m_ahb_sub_hsize  = 3'h2;
    logic                    [1:0] m_ahb_sub_htrans = 2'b00;
    logic   [SYS_DATA_W-1:0]       m_ahb_sub_hwdata = '0;
    logic                          m_ahb_sub_hwrite = 1'b0;
    logic                          m_ahb_sub_hready = 1'b1;
    wire    [SYS_DATA_W-1:0]       m_ahb_sub_hrdata;
    wire                           m_ahb_sub_hresp;
    wire                           m_ahb_sub_hreadyout;

    // -------------------------------------------------------------------------
    // Per-die AHB-Mng BRAM terminus (behavioural AHB-Lite slave).
    //   Replaces the ahb_mng tie-off on BOTH dies so a peer die's remote
    //   access (via the XHB500 transparent window) lands in a real memory and
    //   a read-back can return the stored value. Self-contained zero-wait
    //   AHB-Lite slave (tb_ahb_bram_slave, defined at the bottom of this file)
    //   — no CMSDK dependency; HREADY=1 / HRESP=0 constants avoid the known
    //   hready<->hresp comb-loop caveat.
    // -------------------------------------------------------------------------
    wire   [SYS_ADDR_W-1:0]       m_mng_haddr,  s_mng_haddr;
    wire                    [2:0] m_mng_hburst, s_mng_hburst;
    wire                    [6:0] m_mng_hprot,  s_mng_hprot;
    wire                    [2:0] m_mng_hsize,  s_mng_hsize;
    wire                    [1:0] m_mng_htrans, s_mng_htrans;
    wire   [SYS_DATA_W-1:0]       m_mng_hwdata, s_mng_hwdata;
    wire                          m_mng_hwrite, s_mng_hwrite;
    wire                          m_mng_hready,  s_mng_hready;
    wire   [SYS_DATA_W-1:0]       m_mng_hrdata,  s_mng_hrdata;
    wire                          m_mng_hresp,   s_mng_hresp;

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
        .hresetn           (m_hresetn_w),
        .poresetn          (m_poresetn_w),

        // AHB Sub — EXPOSED to cocotb (XHB500 transparent-window master)
        .ahb_sub_hsel      (m_ahb_sub_hsel),
        .ahb_sub_haddr     (m_ahb_sub_haddr),
        .ahb_sub_hburst    (m_ahb_sub_hburst),
        .ahb_sub_hprot     (m_ahb_sub_hprot),
        .ahb_sub_hsize     (m_ahb_sub_hsize),
        .ahb_sub_htrans    (m_ahb_sub_htrans),
        .ahb_sub_hwdata    (m_ahb_sub_hwdata),
        .ahb_sub_hwrite    (m_ahb_sub_hwrite),
        .ahb_sub_hready    (m_ahb_sub_hready),
        .ahb_sub_hrdata    (m_ahb_sub_hrdata),
        .ahb_sub_hresp     (m_ahb_sub_hresp),
        .ahb_sub_hreadyout (m_ahb_sub_hreadyout),

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

        // AHB Manager — terminated by a behavioural BRAM slave (u_m_mng_bram
        // below), the far-side terminus of the peer's XHB500 window.
        .ahb_mng_haddr     (m_mng_haddr),
        .ahb_mng_hburst    (m_mng_hburst),
        .ahb_mng_hprot     (m_mng_hprot),
        .ahb_mng_hsize     (m_mng_hsize),
        .ahb_mng_htrans    (m_mng_htrans),
        .ahb_mng_hwdata    (m_mng_hwdata),
        .ahb_mng_hwrite    (m_mng_hwrite),
        .ahb_mng_hready    (m_mng_hready),
        .ahb_mng_hrdata    (m_mng_hrdata),
        .ahb_mng_hresp     (m_mng_hresp),

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

        // AHB Manager — terminated by a behavioural BRAM slave (u_s_mng_bram
        // below): the far-side terminus of the MASTER's XHB500 window, where
        // a master ahb_sub write into aperture 0x4000_0000 lands.
        .ahb_mng_haddr     (s_mng_haddr),
        .ahb_mng_hburst    (s_mng_hburst),
        .ahb_mng_hprot     (s_mng_hprot),
        .ahb_mng_hsize     (s_mng_hsize),
        .ahb_mng_htrans    (s_mng_htrans),
        .ahb_mng_hwdata    (s_mng_hwdata),
        .ahb_mng_hwrite    (s_mng_hwrite),
        .ahb_mng_hready    (s_mng_hready),
        .ahb_mng_hrdata    (s_mng_hrdata),
        .ahb_mng_hresp     (s_mng_hresp),

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

    // =========================================================================
    // AHB-Mng BRAM terminus, one per die (behavioural AHB-Lite slave).
    // A remote access arriving on a die's ahb_mng (the far end of the peer's
    // XHB500 transparent window) is stored/served here. AW=12 => 4 KB => the
    // slave decodes HADDR[11:2]; the upper aperture bits (0x4000_0000) are
    // ignored, so any offset < 4 KB is a distinct word. Reset uses the same
    // per-die gated hresetn the DUT sees.
    // =========================================================================
    tb_ahb_bram_slave #(.AW(12)) u_m_mng_bram (
        .HCLK    (hclk),
        .HRESETn (m_hresetn_w),
        .HADDR   (m_mng_haddr),
        .HSIZE   (m_mng_hsize),
        .HTRANS  (m_mng_htrans),
        .HWDATA  (m_mng_hwdata),
        .HWRITE  (m_mng_hwrite),
        .HREADY  (m_mng_hready),
        .HRDATA  (m_mng_hrdata),
        .HRESP   (m_mng_hresp)
    );

    tb_ahb_bram_slave #(.AW(12)) u_s_mng_bram (
        .HCLK    (hclk),
        .HRESETn (s_hresetn_w),
        .HADDR   (s_mng_haddr),
        .HSIZE   (s_mng_hsize),
        .HTRANS  (s_mng_htrans),
        .HWDATA  (s_mng_hwdata),
        .HWRITE  (s_mng_hwrite),
        .HREADY  (s_mng_hready),
        .HRDATA  (s_mng_hrdata),
        .HRESP   (s_mng_hresp)
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

endmodule

// =============================================================================
// tb_ahb_bram_slave — self-contained zero-wait AHB-Lite BRAM slave, the sim
// terminus for a die's `ahb_mng` manager port (the far end of the peer's
// XHB500 transparent window). Full-word accesses; no CMSDK dependency.
//
// Timing (registered address phase, comb read data):
//   * HREADY = 1 constant, HRESP = 0 constant  → no hready<->hresp comb loop.
//   * Address phase captured every cycle (HREADY is always high): latch
//     HADDR/HWRITE/active into *_q.
//   * Data phase: on the NEXT edge, if the captured transfer was a write,
//     store HWDATA at the captured word index.
//   * HRDATA = mem[addr_q] combinationally — addr_q is registered so no loop;
//     it presents mem at the read address during the read data phase.
// =============================================================================
module tb_ahb_bram_slave #(
    parameter AW = 12,          // byte-address width => 2^AW bytes
    parameter DW = 32
) (
    input  wire            HCLK,
    input  wire            HRESETn,
    input  wire [31:0]     HADDR,
    input  wire [2:0]      HSIZE,   // unused (full-word); kept for port parity
    input  wire [1:0]      HTRANS,
    input  wire [DW-1:0]   HWDATA,
    input  wire            HWRITE,
    output wire            HREADY,
    output wire [DW-1:0]   HRDATA,
    output wire            HRESP
);
    localparam integer WORDS = (1 << (AW-2));

    reg [DW-1:0]  mem [0:WORDS-1];
    reg [AW-3:0]  addr_q;
    reg           wr_q;
    reg           active_q;

    wire            xfer_active = HTRANS[1];          // NONSEQ or SEQ
    wire [AW-3:0]   word_idx    = HADDR[AW-1:2];       // decode low AW bits only

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = {DW{1'b0}};
        addr_q   = '0;
        wr_q     = 1'b0;
        active_q = 1'b0;
    end

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_q   <= '0;
            wr_q     <= 1'b0;
            active_q <= 1'b0;
        end else begin
            // Data phase of the PREVIOUS (address-phase) transfer: commit write.
            if (active_q && wr_q)
                mem[addr_q] <= HWDATA;
            // Capture current address phase (HREADY constant-high => always).
            active_q <= xfer_active;
            wr_q     <= HWRITE;
            addr_q   <= word_idx;
        end
    end

    // tb stall hook (default 0 = zero-wait-state, unchanged for all existing
    // tests). A cocotb test may DEPOSIT force_stall=1 to hold HREADY low,
    // modelling a wedged far terminus / link hiccup so the master-side XHB500
    // slv never gets its b/r response — exercising the ahb_sub bounded-timeout
    // backstop (test_v2_xhb_window_stall.py). No other driver, so a deposit
    // holds; constant net otherwise (no hready<->hresp comb loop introduced).
    reg force_stall = 1'b0;
    assign HREADY = force_stall ? 1'b0 : 1'b1;   // zero wait state unless stalled
    assign HRESP  = 1'b0;   // always OKAY
    assign HRDATA = mem[addr_q];
endmodule
