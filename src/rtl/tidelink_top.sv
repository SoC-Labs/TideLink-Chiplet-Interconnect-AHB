//-----------------------------------------------------------------------------
// SoCLabs TideLink Top-Level Chiplet Subsystem
//
// Wraps all chiplet communication components into a single module:
//   - TideLink RX FIFO (tidelink_fifo_ahb): receive-side packet buffer
//   - TideLink FC Adapter: bridges AHB TX aperture and returner to
//     a dedicated Wlink FC node (data_id=0xa1, 48-bit)
//   - XHB500 AHB-to-AXI bridge: regular AHB subordinate path
//   - XHB500 AXI-to-AHB bridge: regular AHB manager path
//   - Address Translator: APB-configurable address remapping for AXI path
//   - Chiplet Controller (modified Wlink): link layer, FC, CRC/ECC, PHY
//
// External interfaces:
//   ahb_sub_*  — AHB subordinate: regular AHB access to remote side
//                (via XHB500 → AXI → Wlink, address translated)
//   ahb_tx_*   — AHB subordinate: TideLink TX aperture (direct to FC node,
//                same aperture size as remote RX FIFO, no address translation)
//   ahb_fifo_* — AHB subordinate: local RX FIFO data window (read packets)
//   ahb_mng_*  — AHB manager: incoming from remote side (via XHB500)
//   apb_*      — APB subordinate: unified configuration port
//                (0x0000-0x1FFF: Wlink chiplet controller,
//                 0x2000-0x3FFF: TideLink config + PTP registers,
//                 0x4000-0x5FFF: Address translator configuration)
//
// Reference: nanosoc_ss_chiplet_mng.v in nanosoc-chiplet-tech
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_top #(
    // System parameters
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,

    // TideLink FIFO parameters
    parameter RAM_ADDR_W = 14,       // FIFO SRAM address width (16KB default)
    parameter RAM_DATA_W = 32,       // FIFO SRAM data width
    parameter APB_ADDR_W = 12,       // APB register address width

    // TideLink FC node parameters
    parameter FC_DATA_W  = 48,       // FC node data width (matches AXI W channel)

    // PHY parameters
    parameter NUM_PHY_LANES = 8,     // Number of GPIO PHY lanes (default 8 for production)

    // Default pair base address (for returner — routed through FC sideband)
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0,

    // PHC lock gate for multi-hop PTP chaining
    // 0 = no gating (backward compat), 1 = gate HW sync on phc_locked_i
    parameter PHC_LOCK_GATE_EN = 0,

    // SoC Labs §9 structural fix: per-lane IDELAYE2 RX delay element driven
    // by the calibrator. 0 (default) = bit-exact passthrough, no Xilinx
    // primitive (sim / ASIC). The FPGA IP wrapper overrides to 1 (carried in
    // the packaged IP's component.xml — no preprocessor define needed; see
    // tidelink_idelay_rx.sv header for why the old `ifdef was removed).
    parameter USE_IDELAY = 1'b0,
    // §9 clock fix: recovered-RX-clock BUFG forward (sim/ASIC default 0;
    // FPGA wrapper sets 1, carried in component.xml). tidelink_rxclk_buf.sv.
    parameter USE_CLKBUF = 1'b0,
    // §9 T3a (2026-05-19): per-lane self-aligning RX comma hunt (sim/ASIC
    // default 0; FPGA wrapper sets 1, carried in component.xml). Each
    // WavD2DGpioRx slips its `count` once per io_por_reset to align to the
    // peer's training-byte boundary, killing the per-deploy 16-cycle phase
    // lottery. See deps/.../wlink/WavD2DGpioRx.v header.
    parameter USE_T3A    = 1'b0,
    // S2 scaffold (PLAN_TIDELINK_INTEGRATION, 2026-06-10): select the NEW
    // shared PHY component (deps/tidelink-phy, feat/phy-refactor line) in
    // place of the current WavD2DGpio datapath inside u_chiplet_controller.
    // 0 (default, EVERYWHERE today) = bit-identical to the pre-scaffold RTL:
    // the g_phy_v2 generate arm (see u_chiplet_controller site below)
    // elaborates empty and nothing else is touched. 1 = reserved for the S3
    // drop-in; sources come from flists/tidelink_phy_v2.flist (not yet
    // included by any live flist). Do NOT set to 1 yet — the arm is a
    // placeholder, not a functional PHY.
    parameter logic USE_PHY_V2 = 1'b0,
    // Tier 2 RTL hardening (2026-05-25): force swi_enable=1 on any APB write
    // that asserts swi_swreset=1 to Wlink register 0x208. Protects the 7
    // FCSMs from buggy SW that writes {swreset=1, swi_enable=0} together —
    // without this guard such a write returns all FCSMs to IDLE and loses
    // CR/CRACK sticky state per FC.scala:619. Default 1 (ON) on FPGA/ASIC
    // — bit-exact-safe because the OR engages ONLY when SW already toggles
    // swreset, leaving the well-behaved swreset W1S→W1C sequence unaffected.
    // See docs/TIDELINK_PHASE0_OBS_20260524_2109.md §9.
    parameter HARDEN_SWI_ENABLE = 1'b1,

    // Interface-debug stubs (Phase 3 of TIDELINK_INTERFACE_DEBUG_PLAN §5).
    // When asserted, the corresponding module is replaced by tie-offs to
    // minimise the implicated logic surface for ILA debug bitstreams.
    // Defaults to 0 → normal instantiation (this change is a no-op).
    //   STUB_SERVO        — replaces u_servo (tidelink_ptp_servo)
    //   STUB_PERF         — replaces u_perf  (tidelink_perf)
    //   STUB_PTP          — replaces u_ptp   (tidelink_ptp); REQUIRES
    //                       STUB_SERVO=1 (servo waits on dreq_tx_done from PTP)
    //   BYPASS_ADDR_XLAT  — replaces u_addr_translator with passthrough
    parameter STUB_SERVO       = 1'b0,
    parameter STUB_PERF        = 1'b0,
    parameter STUB_PTP         = 1'b0,
    parameter BYPASS_ADDR_XLAT = 1'b0,

    // Phase 2 autonomy — POR-default for NEGO_TRAIN_CFG @ 0x4403_210C.
    // 16'h0001 = train_auto_en=1; all timers fall back to FSM defaults.
    // ASIC, FPGA and sim all enter the autonomous training arm out of
    // reset with no SW config write. Cocotb wrappers that need to test
    // the legacy bypass (train_auto_en=0) override this to 16'h0000.
    parameter [15:0] NEGO_TRAIN_CFG_RESET = 16'h0001,
    // NEGO_CFG POR value (companion to NEGO_TRAIN_CFG_RESET).
    // 7'h61 = nego_en + nego_force_lock + mask_hs_auto_en
    // ASIC + FPGA POR boot directly into autonomous bring-up.
    // SoC Labs 2026-06-18: default 7'h00 (autoneg OFF, SW-driven) for the
    // reduced-lane bring-up — see axi_chiplet_controller NEGO_CFG_RESET note.
    // The slave's lane mask is autoneg-locked at 0xff under 7'h61; SW-driven
    // lets both dies set their mask. Revisit 7'h61 once mask-handshake
    // propagates the reduced mask to the slave.
    parameter [6:0]  NEGO_CFG_RESET       = 7'h00,
    // Zero-poke winscan converge-lock — POR-default forwarded verbatim to the
    // axi_chiplet_controller (see its WINSCAN_CONVERGE_LOCK_EN note). 1'b0 =
    // today's behaviour, bit-identical for sim/ASIC; the FPGA vivado wrapper
    // drives 1'b1, exactly the NEGO_CFG_RESET plumbing pattern.
    parameter bit    WINSCAN_CONVERGE_LOCK_EN = 1'b0,
    // HONEST_MASK_HS — peer-mask handshake authenticity gate (from kr260-pair-onchip).
    //   0 (default) = legacy bench tie: the inner axi_chiplet_controller's
    //       apb_debug_unlock_i / mask_hs_bypass_i are held 1'b1 (see the
    //       u_chiplet_controller instantiation below), so mask_hs_gate_open is
    //       permanently forced open. Single-die Z2/ASIC targets are BYTE-IDENTICAL
    //       to today — a parameter-constant ternary folds to the historical 1'b1
    //       ties at elaboration.
    //   1 = drive the inner controller from the real top-level apb_debug_unlock_i /
    //       mask_hs_bypass_i ports (declared but previously DISCARDED) so the
    //       peer-mask handshake must GENUINELY match. Used by the kr260 on-chip pair
    //       to prove hardware autonomy without either bypass strap — and the intended
    //       ASIC production posture (closes the "APB permanently unlocked" chip-killer).
    parameter        HONEST_MASK_HS       = 1'b0,
    // Phase 2 autonomy — RETIRE-AUTONOMY enable (the B->A channel fix).
    // Forwards to axi_chiplet_controller.RETIRE_EN. When 1, an event-gated
    // retire latches on (reanchored & fcsm==4) held ~160 ms and DISARM-PARKs
    // the winscan FSM, replicating the manual `0x210C=0` escape hatch that the
    // silicon recipe takes. Silicon-validated 10/10 all channels at cd2db38.
    //
    // DEFAULT = 1'b1. Deliberate; the reasoning:
    //  1. BIT-EQUIVALENCE (mandatory): the FPGA image is validated WITH the
    //     retire. Defaulting 0 here would silently REVERT the validated
    //     bitstream to the known-livelocking B->A 0/10 behaviour — the exact
    //     class of regression the NEGO_CFG_RESET precedent warns about
    //     (plumbed, never forwarded => every bitstream silently built 7'h00).
    //  2. NOT A SILENT CHIP-DEFAULT: the retire SET is *already* gated on the
    //     raw armed conjunction (nego_en & role_locked & train_auto_en). The
    //     autonomy opt-in gate is NEGO_CFG_RESET, whose tidelink_top default
    //     is the safe 7'h00 => nego_en=0 => the retire can NEVER fire on a
    //     default ASIC integration regardless of RETIRE_EN. So 1'b1 changes
    //     behaviour for nobody who has not ALREADY consciously opted into
    //     autonomy by strapping NEGO_CFG_RESET != 0.
    //  3. FAIL-SAFE DIRECTION: an ASIC that DOES strap nego_en wants autonomy
    //     that WORKS. RETIRE_EN=0 + nego_en=1 is precisely the broken
    //     configuration (winscan livelock, B->A dead). Defaulting 0 would ship
    //     the known-bad autonomy to any integration that straps 7'h61.
    // The F4 gap is closed by making RETIRE_EN EXPRESSIBLE at the top (and on
    // the packaged IP face), not by flipping the default: the ASIC integration
    // can now set 0 or wire a bond strap without editing the controller.
    parameter        RETIRE_EN            = 1'b1,
    // PENDING-DECISION #1 — RX-FIFO TWIN 2 (chip-killer). Forwards to
    // tidelink_fifo → tidelink_fifo_mem → tidelink_fifo_ctrl.ENABLE_AHB_WRITE.
    //   1'b1 (default) = current behaviour, BIT-IDENTICAL: AHB CPU writes to the
    //         RX FIFO can advance the FC-shared write_ptr / burn credit.
    //   1'b0 = ASIC posture: RX FIFO is FC-write-only; the AHB write side cannot
    //         touch write_ptr/credit (AHB reads unaffected). Closes the
    //         stray-AHB-write-mis-frames-next-FC-packet chip-killer.
    parameter bit    ENABLE_AHB_WRITE     = 1'b1,
    // PENDING-DECISION #5 — terminal role from strap, not the I2C-NACK constant.
    // Forwards to axi_chiplet_controller.ROLE_FROM_STRAP → tidelink_autoneg.
    //   1'b0 (default) = BIT-IDENTICAL: I2C NACK => slave, timeout => nego_fallback
    //         (=> the both-dies-slave trap on a dead I2C, autonomy structurally dead).
    //   1'b1 = ASIC posture: NACK terminal role AND timeout fallback derive from
    //         role_strap_i, so a (master,slave) strap survives a dead I2C.
    parameter bit    ROLE_FROM_STRAP      = 1'b0
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,           // AHB / application clock
    input  wire                     hresetn,        // Active-low reset
    input  wire                     poresetn,       // Power-on reset (active-low)
    input  wire                     phc_clk,        // PHC clock (may differ from hclk)
    input  wire                     phc_resetn,     // PHC reset (active-low)

    // --------------------------------------------------------------------------
    // AHB Subordinate — Regular AHB access to remote side
    // (via XHB500 AHB→AXI → Wlink → remote XHB500 AXI→AHB)
    // --------------------------------------------------------------------------
    input  wire                     ahb_sub_hsel,
    input  wire  [SYS_ADDR_W-1:0]  ahb_sub_haddr,
    input  wire               [2:0] ahb_sub_hburst,
    input  wire               [3:0] ahb_sub_hprot,
    input  wire               [2:0] ahb_sub_hsize,
    input  wire               [1:0] ahb_sub_htrans,
    input  wire  [SYS_DATA_W-1:0]  ahb_sub_hwdata,
    input  wire                     ahb_sub_hwrite,
    input  wire                     ahb_sub_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_sub_hrdata,
    output wire                     ahb_sub_hresp,
    output wire                     ahb_sub_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Subordinate — TideLink TX Aperture
    // (direct to TideLink FC node, same size as remote RX FIFO)
    // --------------------------------------------------------------------------
    input  wire                     ahb_tx_hsel,
    input  wire  [RAM_ADDR_W-1:0]  ahb_tx_haddr,
    input  wire               [1:0] ahb_tx_htrans,
    input  wire               [2:0] ahb_tx_hsize,
    input  wire                     ahb_tx_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_tx_hwdata,
    input  wire                     ahb_tx_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_tx_hrdata,
    output wire                     ahb_tx_hresp,
    output wire                     ahb_tx_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Subordinate — Local RX FIFO data window (read received packets)
    // --------------------------------------------------------------------------
    input  wire                     ahb_fifo_hsel,
    input  wire   [RAM_ADDR_W-1:0]  ahb_fifo_haddr,
    input  wire               [1:0] ahb_fifo_htrans,
    input  wire               [2:0] ahb_fifo_hsize,
    input  wire                     ahb_fifo_hwrite,
    input  wire   [SYS_DATA_W-1:0]  ahb_fifo_hwdata,
    input  wire                     ahb_fifo_hready,
    output wire   [SYS_DATA_W-1:0]  ahb_fifo_hrdata,
    output wire                     ahb_fifo_hresp,
    output wire                     ahb_fifo_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Manager — Incoming from remote side (via XHB500 AXI→AHB)
    // --------------------------------------------------------------------------
    output wire    [SYS_ADDR_W-1:0] ahb_mng_haddr,
    output wire               [2:0] ahb_mng_hburst,
    output wire               [6:0] ahb_mng_hprot,
    output wire               [2:0] ahb_mng_hsize,
    output wire               [1:0] ahb_mng_htrans,
    output wire    [SYS_DATA_W-1:0] ahb_mng_hwdata,
    output wire                     ahb_mng_hwrite,
    // HREADY flows slave→manager in AHB. tidelink_top is the manager
    // on this bus (the chiplet drives transactions out into the local
    // SoC fabric), so HREADY is an input — the slave's ready signal
    // back to the manager. Formality LEC flagged the previous `output`
    // declaration as a directly-undriven primary output port.
    input  wire                     ahb_mng_hready,
    input  wire    [SYS_DATA_W-1:0] ahb_mng_hrdata,
    input  wire                     ahb_mng_hresp,

    // --------------------------------------------------------------------------
    // APB Subordinate — Unified configuration port
    //   0x0000-0x1FFF: Wlink chiplet controller (PHY, link, FC nodes)
    //   0x2000-0x203F: TideLink FIFO config + PTP registers
    // --------------------------------------------------------------------------
    input  wire              [14:0] apb_paddr,
    input  wire                     apb_penable,
    input  wire                     apb_pwrite,
    input  wire               [3:0] apb_pstrb,
    input  wire               [2:0] apb_pprot,
    input  wire  [SYS_DATA_W-1:0]  apb_pwdata,
    input  wire                     apb_psel,
    output wire  [SYS_DATA_W-1:0]  apb_prdata,
    output wire                     apb_pready,
    output wire                     apb_pslverr,

    // --------------------------------------------------------------------------
    // Scan / DFT
    // --------------------------------------------------------------------------
    input  wire                     scan_mode,
    input  wire                     scan_asyncrst_ctrl,
    input  wire                     scan_clk,
    input  wire                     scan_shift,
    input  wire                     scan_in,
    output wire                     scan_out,

    // --------------------------------------------------------------------------
    // Reference clock for Wlink PLL
    // --------------------------------------------------------------------------
    input  wire                     user_ref_clk,

    // --------------------------------------------------------------------------
    // PHY Pads (width depends on NUM_PHY_LANES: 1 for GPIO, 8 for SerDes)
    // --------------------------------------------------------------------------
    output wire                              pad_clk_tx,
    output wire        [NUM_PHY_LANES-1:0]   pad_tx,
    input  wire                              pad_clk_rx,
    input  wire        [NUM_PHY_LANES-1:0]   pad_rx,

    // SoC Labs §9 IDELAYE2 RX delay: 200 MHz IDELAYCTRL reference clock.
    // Used only when USE_IDELAY=1 (FPGA). Tie 1'b0 in sim / ASIC — the
    // controller's tidelink_idelay_rx is pure passthrough then.
    input  wire                              idelay_ref_clk,

    // --------------------------------------------------------------------------
    // AHB Subordinate — PTP TX Write Port
    // (CPU writes here to trigger PTP FC messages)
    // --------------------------------------------------------------------------
    input  wire                     ahb_ptp_hsel,
    input  wire               [3:0] ahb_ptp_haddr,
    input  wire               [1:0] ahb_ptp_htrans,
    input  wire               [2:0] ahb_ptp_hsize,
    input  wire                     ahb_ptp_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_ptp_hwdata,
    input  wire                     ahb_ptp_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_ptp_hrdata,
    output wire                     ahb_ptp_hresp,
    output wire                     ahb_ptp_hreadyout,

    // --------------------------------------------------------------------------
    // PHC Hardware Capture Output (directly to external PHC hw_capture input)
    // --------------------------------------------------------------------------
    output wire                     phc_hw_capture,

    // --------------------------------------------------------------------------
    // PHC Time Inputs (from external PHC, for hardware sync initiator)
    // --------------------------------------------------------------------------
    input  wire              [29:0] phc_nanoseconds,
    input  wire              [47:0] phc_seconds,
    input  wire                     phc_pps,

    // --------------------------------------------------------------------------
    // PHC Hardware Capture Inputs (from external PHC, for servo timestamp capture)
    // --------------------------------------------------------------------------
    input  wire              [47:0] phc_hw_cap_seconds,
    input  wire              [29:0] phc_hw_cap_nanoseconds,
    input  wire  [SYS_DATA_W-1:0]  phc_hw_cap_sub_nanoseconds,

    // --------------------------------------------------------------------------
    // PHC Hardware Adjustment Outputs (from servo to external PHC)
    // --------------------------------------------------------------------------
    output wire                     phc_hw_set_time,
    output wire              [47:0] phc_hw_set_seconds,
    output wire              [29:0] phc_hw_set_nanoseconds,
    output wire                     phc_hw_adj_valid,
    output wire    [SYS_DATA_W-1:0] phc_hw_adj_ns_incr_frac,

    // --------------------------------------------------------------------------
    // External PHC Lock Gate (for multi-hop PTP chaining)
    // When PHC_LOCK_GATE_EN=1, gates HW sync initiator on this signal.
    // Tie to 1'b1 for single-link deployments.
    // --------------------------------------------------------------------------
    input  wire                     phc_locked_i,

    // --------------------------------------------------------------------------
    // Servo Status
    // --------------------------------------------------------------------------
    output wire                     servo_locked,

    // --------------------------------------------------------------------------
    // Interrupt Outputs
    // --------------------------------------------------------------------------
    output wire                     released_credits_irq,
    output wire                     doorbell_irq,
    output wire                     packet_committed_irq,
    output wire                     ptp_irq,
    output wire                     perf_irq,
    output wire                     wlink_irq,

    // --------------------------------------------------------------------------
    // TideChart AXI-Stream Port (for TideChart or other external modules)
    // Packets with pkt_type=2'b10 are routed to/from this port.
    // Subtype 0x0020 (PUF_READ_REQ) is handled locally by the FC adapter.
    // --------------------------------------------------------------------------
    input  wire                     tc_axis_tx_tvalid,
    input  wire    [FC_DATA_W-1:0]  tc_axis_tx_tdata,
    output wire                     tc_axis_tx_tready,

    output wire                     tc_axis_rx_tvalid,
    output wire    [FC_DATA_W-1:0]  tc_axis_rx_tdata,
    input  wire                     tc_axis_rx_tready,

    // --------------------------------------------------------------------------
    // QoS Priority Hint (Phase 5A, from TideChart TC_QOS_CFG register)
    // When >0: TideChart PKT_EXT packets are prioritised above FIFO_DATA
    // When =0: original fixed priority (FIFO_DATA may win over PKT_EXT)
    // --------------------------------------------------------------------------
    input  wire               [2:0] tc_qos_priority,

    // --------------------------------------------------------------------------
    // Congestion sideband (Phase 1, to TideChart link-state agent)
    // Pure combinational: same hclk domain as everything else in this module.
    // See docs/../../../tidechart/docs/CONGESTION_AWARE_ROUTING.md.
    //   tl_local_link_state_o = {starve, trend[1:0], level[1:0]}
    //   tl_link_state_change_o = one-cycle pulse on any quantised transition
    //   tl_bcast_ack_i = level-sensitive, clears starve-sticky after broadcast
    // --------------------------------------------------------------------------
    output wire               [4:0] tl_local_link_state_o,
    output wire                     tl_link_state_change_o,
    output wire              [12:0] tl_ewma_credit_o,
    input  wire                     tl_bcast_ack_i,

    // --------------------------------------------------------------------------
    // Link active status (Wlink link layer is up and operational)
    // --------------------------------------------------------------------------
    output wire                     link_active,

    // --------------------------------------------------------------------------
    // Reset output
    // --------------------------------------------------------------------------
    output wire                     d2d_reset_o,

    // --------------------------------------------------------------------------
    // Chiplet Controller Role Selection
    // --------------------------------------------------------------------------
    input  wire                     role_strap_i,
    output wire                     role_is_master_o,
    output wire                     role_locked_o,
    input  wire                     apb_debug_unlock_i,
    input  wire                     mask_hs_bypass_i,

    // --------------------------------------------------------------------------
    // Auto-Negotiation
    // --------------------------------------------------------------------------
    input  wire [15:0]              nego_priority_i,    // External negotiation priority (OTP/UID)
    input  wire [15:0]              puf_seed,           // From TideChart PUF sampler
    input  wire                     puf_ready,          // PUF sampling complete
    output wire                     nego_error_irq,     // Negotiation error interrupt
    // Phase 1 autonomy G1b: sticky IRQ asserted when the autoneg FSM enters
    // ST_TRAIN_FAIL (see deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv
    // line 1665). Latched and W1C-cleared inside u_chiplet_controller —
    // Region 8 slot 3'h3 bit[16] (MMIO 0x4403_210C). Kept separate from
    // nego_error_irq so existing handlers don't get re-routed.
    output wire                     train_fail_irq,

    // --------------------------------------------------------------------------
    // I2C Sideband (open-drain tristate)
    // --------------------------------------------------------------------------
    input  wire                     i2c_scl_i,
    output wire                     i2c_scl_o,
    output wire                     i2c_scl_t,
    input  wire                     i2c_sda_i,
    output wire                     i2c_sda_o,
    output wire                     i2c_sda_t,

    // --------------------------------------------------------------------------
    // I2C Sideband AXI (master mode: CPU → I2C master → remote)
    // --------------------------------------------------------------------------
    input  wire                     s_i2c_axi_awvalid,
    input  wire               [1:0] s_i2c_axi_awid,
    input  wire               [3:0] s_i2c_axi_awaddr,
    input  wire               [7:0] s_i2c_axi_awlen,
    input  wire               [2:0] s_i2c_axi_awsize,
    input  wire               [1:0] s_i2c_axi_awburst,
    input  wire                     s_i2c_axi_awlock,
    input  wire               [3:0] s_i2c_axi_awcache,
    input  wire               [2:0] s_i2c_axi_awprot,
    output wire                     s_i2c_axi_awready,
    input  wire                     s_i2c_axi_wvalid,
    input  wire  [SYS_DATA_W-1:0]  s_i2c_axi_wdata,
    input  wire               [3:0] s_i2c_axi_wstrb,
    input  wire                     s_i2c_axi_wlast,
    output wire                     s_i2c_axi_wready,
    output wire                     s_i2c_axi_bvalid,
    output wire               [1:0] s_i2c_axi_bid,
    output wire               [1:0] s_i2c_axi_bresp,
    input  wire                     s_i2c_axi_bready,
    input  wire                     s_i2c_axi_arvalid,
    input  wire               [1:0] s_i2c_axi_arid,
    input  wire               [3:0] s_i2c_axi_araddr,
    input  wire               [7:0] s_i2c_axi_arlen,
    input  wire               [2:0] s_i2c_axi_arsize,
    input  wire               [1:0] s_i2c_axi_arburst,
    input  wire                     s_i2c_axi_arlock,
    input  wire               [3:0] s_i2c_axi_arcache,
    input  wire               [2:0] s_i2c_axi_arprot,
    output wire                     s_i2c_axi_arready,
    output wire                     s_i2c_axi_rvalid,
    output wire               [1:0] s_i2c_axi_rid,
    output wire  [SYS_DATA_W-1:0]  s_i2c_axi_rdata,
    output wire               [1:0] s_i2c_axi_rresp,
    output wire                     s_i2c_axi_rlast,
    input  wire                     s_i2c_axi_rready,

    // --------------------------------------------------------------------------
    // I2C Interrupts
    // --------------------------------------------------------------------------
    output wire                     i2c_nbsy_irq,
    output wire                     i2c_nrd_empty_irq
);

    // =========================================================================
    // Internal AXI wiring (XHB500 ↔ Chiplet Controller)
    // =========================================================================

    // AXI subordinate path (ahb_sub → XHB500 AHB→AXI → chiplet controller s_axi)
    wire [11:0]  s_axi_awid;
    wire [35:0]  s_axi_awaddr;
    wire  [7:0]  s_axi_awlen;
    wire  [2:0]  s_axi_awsize;
    wire  [1:0]  s_axi_awburst;
    wire         s_axi_awlock;
    wire  [3:0]  s_axi_awcache;
    wire  [2:0]  s_axi_awprot;
    wire  [3:0]  s_axi_awqos;
    wire         s_axi_awvalid;
    wire         s_axi_awready;

    wire [31:0]  s_axi_wdata;
    wire  [3:0]  s_axi_wstrb;
    wire         s_axi_wlast;
    wire         s_axi_wvalid;
    wire         s_axi_wready;

    wire [11:0]  s_axi_bid;
    wire  [1:0]  s_axi_bresp;
    wire         s_axi_bvalid;
    wire         s_axi_bready;

    wire [11:0]  s_axi_arid;
    wire [35:0]  s_axi_araddr;
    wire  [7:0]  s_axi_arlen;
    wire  [2:0]  s_axi_arsize;
    wire  [1:0]  s_axi_arburst;
    wire         s_axi_arlock;
    wire  [3:0]  s_axi_arcache;
    wire  [2:0]  s_axi_arprot;
    wire  [3:0]  s_axi_arqos;
    wire         s_axi_arvalid;
    wire         s_axi_arready;

    wire [11:0]  s_axi_rid;
    wire [31:0]  s_axi_rdata;
    wire  [1:0]  s_axi_rresp;
    wire         s_axi_rlast;
    wire         s_axi_rvalid;
    wire         s_axi_rready;

    // AXI manager path (chiplet controller m_axi → XHB500 AXI→AHB → ahb_mng)
    wire [11:0]  m_axi_awid;
    wire [35:0]  m_axi_awaddr;
    wire  [7:0]  m_axi_awlen;
    wire  [2:0]  m_axi_awsize;
    wire  [1:0]  m_axi_awburst;
    wire         m_axi_awlock;
    wire  [3:0]  m_axi_awcache;
    wire  [2:0]  m_axi_awprot;
    wire  [3:0]  m_axi_awqos;
    wire         m_axi_awvalid;
    wire         m_axi_awready;

    wire [31:0]  m_axi_wdata;
    wire  [3:0]  m_axi_wstrb;
    wire         m_axi_wlast;
    wire         m_axi_wvalid;
    wire         m_axi_wready;

    wire [11:0]  m_axi_bid;
    wire  [1:0]  m_axi_bresp;
    wire         m_axi_bvalid;
    wire         m_axi_bready;

    wire [11:0]  m_axi_arid;
    wire [35:0]  m_axi_araddr;
    wire  [7:0]  m_axi_arlen;
    wire  [2:0]  m_axi_arsize;
    wire  [1:0]  m_axi_arburst;
    wire         m_axi_arlock;
    wire  [3:0]  m_axi_arcache;
    wire  [2:0]  m_axi_arprot;
    wire  [3:0]  m_axi_arqos;
    wire         m_axi_arvalid;
    wire         m_axi_arready;

    wire [11:0]  m_axi_rid;
    wire [31:0]  m_axi_rdata;
    wire  [1:0]  m_axi_rresp;
    wire         m_axi_rlast;
    wire         m_axi_rvalid;
    wire         m_axi_rready;

    // =========================================================================
    // TideLink FC Node wiring (FC adapter ↔ Chiplet Controller)
    // =========================================================================
    // Separate valid/ready/data signals (used by FC adapter)
    // mark_debug — Bug A probes per docs/ILA_PLACEMENT_AUDIT_2026_05_29.md §3
    // (master FC TX boundary + slave FC RX boundary). hclk-native, captured by
    // u_dbg_int via insert_debug_core.tcl auto-scrape.
    wire                   tl_fc_a2l_valid;
    wire [FC_DATA_W-1:0]   tl_fc_a2l_data;
    wire                   tl_fc_a2l_ready;
    wire                   tl_fc_l2a_valid;
    wire [FC_DATA_W-1:0]   tl_fc_l2a_data;
    wire                   tl_fc_l2a_accept;

    // =========================================================================
    // PTP Short Packet wiring (PTP module ↔ Chiplet Controller)
    // =========================================================================
    // mark_debug on PHC short-packet boundary nets — ILA capture per
    // docs/PHC_PHASE1_HW_REPORT.md §"Build #13 + Proposal #3"
    // (feat/phc-ila-debug). hclk-domain, captured by insert_debug_core.tcl.
    wire                   ptp_sp_tx_valid;
    wire            [7:0]  ptp_sp_tx_data_id;
    wire           [15:0]  ptp_sp_tx_payload;
    wire                   ptp_sp_tx_ready;
    wire                   ptp_sp_rx_valid;
    wire            [7:0]  ptp_sp_rx_data_id;
    wire           [15:0]  ptp_sp_rx_payload;
    wire                   ptp_sp_rx_accept;

    // TX link idle signal from chiplet controller (Wlink tx_link_idle output)
    // Directly driven by .tx_link_idle port on the Wlink instance
    // mark_debug — Bug B probe (HW_SYNC defer gate) per audit §4
    wire                   tx_router_idle;

    // PTP register interface (PTP module ↔ APB regs, via pass-through)
    wire                   ptp_reg_write;
    wire            [2:0]  ptp_reg_addr;
    wire [SYS_DATA_W-1:0] ptp_reg_wdata;
    wire [SYS_DATA_W-1:0] ptp_reg_rdata;
    wire                   ptp_reg_region;

    // Servo register interface (servo ↔ APB regs, via pass-through)
    wire                   servo_reg_write;
    wire            [2:0]  servo_reg_addr;
    wire [SYS_DATA_W-1:0] servo_reg_wdata;
    wire [SYS_DATA_W-1:0] servo_reg_rdata;

    // Servo mailbox interface (FC RX SIDEBAND → servo timestamp mailbox)
    wire                   mbox_reg_write;
    wire            [2:0]  mbox_reg_addr;
    wire [SYS_DATA_W-1:0] mbox_reg_wdata;

    // Chiplet controller register interface (APB regs Regions 4 + 8 + C ↔ controller).
    // ctrl_reg_addr is 5 bits — bits[2:0] are the slot within the region;
    // bits[4:3] are the region selector:
    //   2'b01 → Region 4 (slots 0..7, 0x080..0x09C, ROLE/I²C/NEGO)
    //   2'b10 → Region 8 (slots 0..7, 0x100..0x11C, PHY-align / I²C-train)
    //   2'b11 → Region C (slots 0..7, 0x180..0x19C, Bug N7/N8 silicon
    //                     observability — autoneg probe registers, RO)
    wire                   ctrl_reg_write;
    wire            [4:0]  ctrl_reg_addr;
    // SoC Labs perlane-wp (2026-06-16): Region 10 (SoC 0x2144/0x2148/0x214C)
    // select from tidelink_apb_regs into the chiplet controller (the sweep
    // oracle + per-lane word-pin registers). V1 ties it low (bit-identical).
    wire                   ctrl_reg_r10;
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap): Region D
    // (SoC 0x4403_21A0-0x4403_21A8) select from tidelink_apb_regs into the
    // chiplet controller. V1 ties it low (bit-identical).
    wire                   ctrl_reg_rd;
    wire [SYS_DATA_W-1:0] ctrl_reg_wdata;
    wire [SYS_DATA_W-1:0] ctrl_reg_rdata;

    // Performance profiling register interface (APB regs Regions 5-7 ↔ perf)
    wire                   perf_reg_write;
    wire            [2:0]  perf_reg_addr;
    wire [SYS_DATA_W-1:0] perf_reg_wdata;
    wire [SYS_DATA_W-1:0] perf_reg_rdata;
    wire            [1:0]  perf_reg_region;
    wire [RAM_ADDR_W-2:0]  perf_credit_count;

    // Servo ↔ PTP event signals
    wire                   sync_tx_done;
    wire                   dreq_tx_done;
    wire                   sync_rx_done;
    wire                   dreq_rx_done;
    wire                   servo_dreq_trigger;

    // Servo ↔ FC adapter (SIDEBAND injection)
    wire                   servo_fc_valid;
    wire [FC_DATA_W-1:0]  servo_fc_data;
    wire                   servo_fc_ready;

    // =========================================================================
    // PHC CDC intermediate wires (hclk-domain ↔ tidelink_phc_cdc ↔ phc_clk)
    // =========================================================================
    // _raw signals: hclk-domain outputs from u_ptp / u_servo (before CDC)
    // _sync signals: hclk-domain inputs to u_ptp / u_servo (after CDC)
    wire                    phc_hw_capture_raw;     // from u_ptp → CDC → PHC
    wire             [29:0] phc_nanoseconds_sync;   // from PHC → CDC → u_ptp
    wire             [47:0] phc_seconds_sync;        // from PHC → CDC → u_ptp
    wire                    phc_pps_sync;            // from PHC → CDC → u_ptp
    wire             [47:0] phc_hw_cap_seconds_sync;       // from PHC → CDC → u_servo
    wire             [29:0] phc_hw_cap_nanoseconds_sync;   // from PHC → CDC → u_servo
    wire [SYS_DATA_W-1:0]  phc_hw_cap_sub_nanoseconds_sync;
    wire                    phc_hw_set_time_raw;           // from u_servo → CDC → PHC
    wire             [47:0] phc_hw_set_seconds_raw;
    wire             [29:0] phc_hw_set_nanoseconds_raw;
    wire                    phc_hw_adj_valid_raw;
    wire [SYS_DATA_W-1:0]  phc_hw_adj_ns_incr_frac_raw;

    // =========================================================================
    // Returner AHB master wiring (tidelink_fifo_ahb → FC adapter interception)
    // =========================================================================
    wire [SYS_ADDR_W-1:0]  rtn_haddr;
    wire [SYS_DATA_W-1:0]  rtn_hwdata;
    wire              [1:0] rtn_htrans;
    wire              [2:0] rtn_hsize;
    wire                    rtn_hwrite;
    wire                    rtn_hready;
    wire                    rtn_hresp;
    wire [SYS_DATA_W-1:0]  rtn_hrdata;

    // =========================================================================
    // FC adapter RX direct write wiring (single-cycle, replaces AHB mux)
    // =========================================================================
    wire                    fc_rx_fifo_valid;
    wire                    fc_rx_fifo_write;
    wire [RAM_ADDR_W-1:0]  fc_rx_fifo_addr;
    wire [SYS_DATA_W-1:0]  fc_rx_fifo_wdata;
    // mark_debug — Bug A probe (back-pressure from FIFO controller) per audit §3
    wire                    fc_rx_fifo_ready;

    // SoC Labs Bug-A FCSM observation 2026-06-02 — apb_clk synced gate
    // signals for the FCSM state-4 → state-5 transition, exposed by
    // u_chiplet_controller. mark_debug + dont_touch + keep_hierarchy is
    // needed because the signal chain from WlinkGenericFCSM_6 has no
    // logical sink outside dbg_hub — without dont_touch Vivado optimizes
    // the whole chain away. (mark_debug alone works for fc_rx_fifo_wdata
    // because it has real downstream logic sinks; obs_* don't.)
    wire        obs_a2l_replay_link_valid_w;
    wire [7:0]  obs_fe_rx_credit_max_w;
    wire        obs_fe_rx_is_full_w;
    // SoC Labs Bug-A FCSM observation 2026-06-03
    wire        obs_a2l_replay_app_valid_w;

    // PUF SRAM read path (FC adapter ↔ FIFO)
    wire [RAM_ADDR_W-3:0]  puf_addr;
    wire                    puf_req;
    wire [31:0]             puf_rdata;
    wire                    puf_ack;

    // FC adapter RX config path — APB-native
    wire [APB_ADDR_W-1:0]  fc_cfg_apb_paddr;
    wire [SYS_DATA_W-1:0]  fc_cfg_apb_pwdata;
    wire                    fc_cfg_apb_psel;
    wire                    fc_cfg_apb_penable;
    wire                    fc_cfg_apb_pwrite;
    wire [SYS_DATA_W-1:0]  fc_cfg_apb_prdata;
    wire                    fc_cfg_apb_pready;
    wire                    fc_cfg_apb_pslverr;

    // =========================================================================
    // Unified APB address decode
    //   paddr[14:13] == 00 → Wlink chiplet controller (paddr[12:0])
    //   paddr[14:13] == 01 → TideLink config registers (paddr[11:0])
    //   paddr[14:13] == 10 → Address translator config (paddr[12:0])
    //   paddr[14:13] == 11 → Reserved
    // =========================================================================
    wire apb_sel_wlink     = apb_psel && !apb_paddr[14] && !apb_paddr[13];
    wire apb_sel_tidelink  = apb_psel && !apb_paddr[14] &&  apb_paddr[13];
    wire apb_sel_addr_xlat = apb_psel &&  apb_paddr[14] && !apb_paddr[13];

    // Wlink APB response signals
    wire [SYS_DATA_W-1:0] wlink_prdata;
    wire                   wlink_pready;
    wire                   wlink_pslverr;

    // TideLink regs APB response signals (from APB mux below)
    wire [SYS_DATA_W-1:0] tl_regs_prdata;
    wire                   tl_regs_pready;
    wire                   tl_regs_pslverr;

    // Address translator APB response signals
    wire [SYS_DATA_W-1:0] adr_xlat_prdata;
    wire                   adr_xlat_pready;
    wire                   adr_xlat_pslverr;

    // Unified APB response mux
    assign apb_prdata  = apb_sel_wlink     ? wlink_prdata     :
                         apb_sel_tidelink  ? tl_regs_prdata   :
                         apb_sel_addr_xlat ? adr_xlat_prdata   : '0;
    assign apb_pready  = apb_sel_wlink     ? wlink_pready     :
                         apb_sel_tidelink  ? tl_regs_pready   :
                         apb_sel_addr_xlat ? adr_xlat_pready   : 1'b1;
    assign apb_pslverr = apb_sel_wlink     ? wlink_pslverr    :
                         apb_sel_tidelink  ? tl_regs_pslverr  :
                         apb_sel_addr_xlat ? adr_xlat_pslverr  : 1'b0;

    // =========================================================================
    // TideLink config APB mux: 2:1 TRANSACTION-ATOMIC arbiter
    //   Source 0: FC adapter RX config (fc_cfg_apb_*, APB-native; peer
    //             credit/doorbell/returner config writes)
    //   Source 1: external unified APB port (PS CPU reads/writes to Region 8)
    //
    // The FC config port must NEVER preempt an external PS access that is already
    // in its ACCESS phase.  On the Zynq-7000 M_AXI_GP there is NO bus timeout, so
    // a preempted PS access hangs the CPU for ever (Bus error on every later
    // access).  The FC adapter, by contrast, tolerates pready backpressure -- its
    // RX FSM (tidelink_fc_adapter.sv:588-630) holds psel/paddr/pwdata stable and
    // waits on fc_rx_cfg_pready, and tidelink_apb_regs acks combinationally
    // (fifo/tidelink_apb_regs.sv:650, pready=1'b1), so a held-off FC waits at
    // most 1-2 cycles.  So the PS wins any conflict; the FC waits.
    //
    //   ext_txn    : an external Region-8 access is in its ACCESS phase (psel &
    //                penable) -- the exact window the old bare mux corrupted.
    //   ext_lock_q : registered grant, latched from the first STALLED external
    //                ACCESS cycle and held until the access is acked.  Belt &
    //                braces: even if a slow Region-10/11 shim slave stretches the
    //                access across many cycles, the FC can never slip in on an
    //                intermediate edge.  The bare !ext_txn term already covers the
    //                common single-cycle-ack case; the lock hardens the
    //                multi-cycle stall.
    // The FC config port is granted only when no external access owns or is
    // waiting for the bus.  (The bounded-stall watchdog that makes the PS bus
    // structurally hang-proof lives just below the tl_apb_* declarations, since
    // it references tl_apb_pready.)
    // =========================================================================
    wire ext_txn = apb_sel_tidelink && apb_penable;   // external in ACCESS phase

    reg  ext_lock_q;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            ext_lock_q <= 1'b0;
        else if (ext_txn && !tl_regs_pready)          // access started, not yet acked
            ext_lock_q <= 1'b1;
        else if (tl_regs_pready)                       // access completed -> release
            ext_lock_q <= 1'b0;
    end

    wire fc_cfg_apb_active = fc_cfg_apb_psel && !ext_txn && !ext_lock_q;

    // APB signals to tidelink_fifo APB slave
    wire [APB_ADDR_W-1:0]  tl_apb_paddr;
    wire                    tl_apb_psel;
    wire                    tl_apb_penable;
    wire                    tl_apb_pwrite;
    wire [SYS_DATA_W-1:0]  tl_apb_pwdata;
    wire [SYS_DATA_W-1:0]  tl_apb_prdata;
    wire                    tl_apb_pready;
    wire                    tl_apb_pslverr;

    // -------------------------------------------------------------------------
    // BOUNDED EXTERNAL STALL (belt & braces).  The arbitration above stops the FC
    // from starving the PS, but a genuinely stuck sub-slave (tl_apb_pready never
    // rising) would still hang the PS -- and the Zynq has no timeout of its own.
    // Saturate a counter on a stalled external ACCESS and, past the limit,
    // complete it with pready+pslverr so the PS bus is STRUCTURALLY incapable of
    // locking up.  ext_stall_err_q latches sticky (POR-cleared) for post-mortem
    // (waveform/ILA-visible; not APB-mapped -- no free obs-reg slot, see the
    // commit message).  EXT_STALL_LIMIT >> any legal ack (apb_regs acks in 1).
    // -------------------------------------------------------------------------
    localparam [10:0] EXT_STALL_LIMIT = 11'd1024;
    reg  [10:0] ext_stall_ctr_q;
    reg         ext_stall_err_q;
    wire ext_stalled = ext_txn && !tl_apb_pready && !fc_cfg_apb_active;
    wire ext_timeout = (ext_stall_ctr_q == EXT_STALL_LIMIT);

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ext_stall_ctr_q <= 11'd0;
            ext_stall_err_q <= 1'b0;
        end else if (!ext_stalled) begin
            ext_stall_ctr_q <= 11'd0;                   // idle or completing -> reset
        end else if (ext_stall_ctr_q != EXT_STALL_LIMIT) begin
            ext_stall_ctr_q <= ext_stall_ctr_q + 11'd1;
            if (ext_stall_ctr_q == EXT_STALL_LIMIT - 11'd1)
                ext_stall_err_q <= 1'b1;                // latch sticky as it fires
        end
    end

    assign tl_apb_paddr   = fc_cfg_apb_active ? fc_cfg_apb_paddr   : apb_paddr[APB_ADDR_W-1:0];
    assign tl_apb_psel    = fc_cfg_apb_active ? fc_cfg_apb_psel    : apb_sel_tidelink;
    assign tl_apb_penable = fc_cfg_apb_active ? fc_cfg_apb_penable : apb_penable;
    assign tl_apb_pwrite  = fc_cfg_apb_active ? fc_cfg_apb_pwrite  : apb_pwrite;
    assign tl_apb_pwdata  = fc_cfg_apb_active ? fc_cfg_apb_pwdata  : apb_pwdata;

    // =========================================================================
    // v2 Eye visibility shim: tidelink_eye_regs (Region 10, paddr 0x140-0x17F).
    //
    // Same OR-mux pattern as the FCSM debug shim above: tidelink_apb_regs
    // returns 0 for the Region 10 range and the shim's prdata/pready/
    // pslverr are substituted at this scope when eye_shim_sel matches.
    //
    // The calibrator-side ports (swi_eye_*, eye_*) are wired through to
    // the calibrator inside u_chiplet_controller.  Until that submodule
    // is regenerated to expose the new ports on its boundary, the
    // calibrator-data inputs to the shim (eye_status_i and friends) are
    // tied off to 0 and the control outputs (swi_eye_ctrl, etc.) are
    // routed into the top-level so a follow-on commit can wire them via
    // hierarchical reference or via new chiplet-controller ports.
    // =========================================================================
    wire eye_shim_sel = tl_apb_psel && (tl_apb_paddr[8:5] == 4'b1010);

    wire [SYS_DATA_W-1:0]  eye_shim_prdata;
    wire                    eye_shim_pready;
    wire                    eye_shim_pslverr;

    // Calibrator-facing wires.  Connected through axi_chiplet_controller's
    // new v2 eye-visibility ports (deps/axi-chiplet-controller@ed3bd0f).
    wire [2:0]  eye_swi_lane_sel_w;
    wire [31:0] eye_swi_dwell_us_w;
    wire [31:0] eye_swi_ctrl_w;
    wire [31:0] eye_status_w;
    wire [6:0]  eye_score_idx_w;
    wire [5:0]  eye_score_data_w;
    wire        eye_score_lane_passed_w;
    wire [5:0]  eye_score_best_w;
    wire [2:0]  eye_score_best_slip_w;
    wire [3:0]  eye_score_best_phase_w;
    wire [31:0] eye_force_phase_en_w;
    wire [31:0] eye_force_phase_val_w;
    wire [31:0] eye_force_slip_val_w;
    wire        eye_crc_err_cnt_clr_w;

    // EYE_LAST_LATCHED mirror — sourced from u_chiplet_controller (see below).
    wire [23:0] eye_last_slip_w;
    wire [7:0]  eye_last_lane_fault_w;

    // tidelink-gpio-phy observability bus from the new lane_checker (replaces
    // the legacy 8x crc_err_cnt counters; see
    // deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md §6, INTEGRATION_GUIDE
    // §6.2). Each per-lane signal packs 5/2/1 bits/lane × 8 lanes as documented
    // in the submodule's RTL_ARCHITECTURE.md.
    wire [23:0] lane_lock_thresh_w;       // APB regs → checker
    wire        lane_clear_noise_w;       // APB regs → checker (1-cycle pulse)
    wire [7:0]  lane_mismatch_pulse_w;
    wire [15:0] lane_wire_status_w;
    wire [39:0] lane_dist_raw_w;
    wire [39:0] lane_dist_voted_w;
    wire [39:0] lane_dwell_min_dist_w;
    wire [39:0] lane_noise_min_w;
    wire [39:0] lane_noise_max_w;
    wire [39:0] lane_noise_mean_w;
    wire [39:0] lane_noise_current_w;
    wire [7:0]  lane_canary_pass_w;
    wire [7:0]  lane_canary_valid_w;
    // Recovered RX clock surfaced from u_chiplet_controller.link_rx_clk_o
    // (deps/axi-chiplet-controller@3e0e711) for the new gpio_phy_apb_regs
    // slave's link_rx_clk port.
    wire        gpio_phy_link_rx_clk_w;

    // CLK_MHZ = 250 (FPGA app_clk) — same constant as the calibrator's
    // CLK_MHZ default.  Used here only to document the timing assumption
    // shared by the dwell-counter conversion in tidelink_phy_align_calibrator.

`ifndef TIDELINK_PHY_V2
    tidelink_eye_regs #(
        .APB_ADDR_W (APB_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
    ) u_eye_regs (
        .hclk                    (hclk),
        .hresetn                 (hresetn),

        .psel                    (eye_shim_sel),
        .penable                 (tl_apb_penable),
        .pwrite                  (tl_apb_pwrite),
        .paddr                   (tl_apb_paddr),
        .pwdata                  (tl_apb_pwdata),
        .prdata                  (eye_shim_prdata),
        .pready                  (eye_shim_pready),
        .pslverr                 (eye_shim_pslverr),

        .swi_eye_lane_sel        (eye_swi_lane_sel_w),
        .swi_eye_dwell_us        (eye_swi_dwell_us_w),
        .swi_eye_ctrl            (eye_swi_ctrl_w),
        .eye_status_i            (eye_status_w),
        .eye_score_idx           (eye_score_idx_w),
        .eye_score_data_i        (eye_score_data_w),
        .eye_score_lane_passed_i (eye_score_lane_passed_w),
        .eye_score_best_i        (eye_score_best_w),
        .eye_score_best_slip_i   (eye_score_best_slip_w),
        .eye_score_best_phase_i  (eye_score_best_phase_w),

        .swi_force_phase_en      (eye_force_phase_en_w),
        .swi_force_phase_val     (eye_force_phase_val_w),
        .swi_force_slip_val      (eye_force_slip_val_w),

        // Legacy CRC counters tied to 0 — eye-toolkit web GUI migrates per
        // deps/tidelink-gpio-phy/docs/INTEGRATION_GUIDE.md §6.2 to consume
        // SWI_LANE_NOISE_VOTED_* from the new tidelink_gpio_phy_apb_regs slave
        // instantiated below (paddr[8:5]==4'b1011, relative offset 0x160).
        .lane_crc_err_cnt_0_i    (8'h0),
        .lane_crc_err_cnt_1_i    (8'h0),
        .lane_crc_err_cnt_2_i    (8'h0),
        .lane_crc_err_cnt_3_i    (8'h0),
        .lane_crc_err_cnt_4_i    (8'h0),
        .lane_crc_err_cnt_5_i    (8'h0),
        .lane_crc_err_cnt_6_i    (8'h0),
        .lane_crc_err_cnt_7_i    (8'h0),
        .lane_crc_err_cnt_clr_o  (eye_crc_err_cnt_clr_w),

        .eye_last_slip_i         (eye_last_slip_w),
        .eye_last_lane_fault_i   (eye_last_lane_fault_w)
    );
`else
    // S3 PHY swap: eye-vis retired (AUDIT #17) — tidelink_eye_regs is absent
    // from the V2 flist. Tie every net the instance drove. Region 10 APB
    // reads return 0 with no wait states; the eye control/force surface is
    // inert. (lane_lock_thresh_w / lane_clear_noise_w are unaffected — they
    // come from the tidelink_gpio_phy_apb_regs slave, which remains.)
    assign eye_shim_prdata        = {SYS_DATA_W{1'b0}};
    assign eye_shim_pready        = 1'b1;
    assign eye_shim_pslverr       = 1'b0;
    assign eye_swi_lane_sel_w     = 3'h0;
    assign eye_swi_dwell_us_w     = 32'h0;
    assign eye_swi_ctrl_w         = 32'h0;
    assign eye_score_idx_w        = 7'h0;
    assign eye_force_phase_en_w   = 1'b0;
    assign eye_force_phase_val_w  = 4'h0;
    assign eye_force_slip_val_w   = 3'h0;
    assign eye_crc_err_cnt_clr_w  = 1'b0;
`endif

    // SWI_FORCE_PHASE_EN/VAL/SLIP_VAL are reserved register slots (proposal
    // §5); the calibrator does not consume them in v2 — kept as drivable
    // RW shadows for SW.  Mark as intentionally unused at this scope.
    // eye_crc_err_cnt_clr_w is still produced by tidelink_eye_regs but the
    // counters it used to clear were removed by the lane-checker rewrite
    // (deps/tidelink-gpio-phy, INTEGRATION_GUIDE §6.2); marked unused at
    // this scope until the eye_regs slot is repurposed or deprecated.
    /* verilator lint_off UNUSED */
    wire _unused_eye_force = |{eye_force_phase_en_w, eye_force_phase_val_w,
                                eye_force_slip_val_w};
    wire _unused_eye_crc_clr = eye_crc_err_cnt_clr_w;
    /* verilator lint_on UNUSED */

    // =========================================================================
    // tidelink-gpio-phy APB slave (Region 11, paddr 0x160-0x17F).
    //
    // Instantiated per deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md §6.1
    // and INTEGRATION_GUIDE.md §5/§6.3. Carries the per-lane noise
    // observability + SW-writable lock threshold + wiring/canary status that
    // replace the legacy crc_err_cnt counters now sourced from the new
    // u_chiplet_controller observability bus (see below). Same OR-mux pattern
    // as the dbg_shim and eye_shim blocks above.
    //
    // SPEC DEVIATION: the spec quotes absolute address 0x4403_2120 (§6.1),
    // implying offset 0x120 inside the tidelink APB region. The dbg shim
    // already owns paddr[8:5]==4'b1001 (0x120-0x13F), and eye_regs owns
    // 4'b1010 (0x140-0x15F), so the next free 32-byte aperture is 4'b1011
    // (0x160-0x17F). The internal register map (THRESH at slave-paddr 0x20
    // through CANARY at 0x3C) is preserved by synthesising the slave-facing
    // paddr as {3'b001, tl_apb_paddr[4:0]} so its address decode still
    // matches.
    //
    // CLOCK DOMAIN NOTE: the spec's CDC (apb_clk ↔ link_rx_clk) is satisfied
    // by wiring the slave's link_rx_clk to the controller's new link_rx_clk_o
    // output (added in deps/axi-chiplet-controller@3e0e711). The slave's
    // 2-flop synchronisers now operate across genuine hclk → recovered RX
    // clock boundaries per spec §6.
    //
    // rst_n is driven directly from role_locked per INTEGRATION_GUIDE §5.2
    // ("Connect .rst_n(role_locked) directly — NO inverter"). apb_rst_n is
    // the standard hresetn.
    // =========================================================================
    // Region 11 gpio_phy slave: SoC 0x2160-0x217F (paddr[8:5]==4'b1011) ->
    // slave-internal 0x20-0x3F. The slave also defines SWI_EPOCH_STATUS at
    // slave-paddr 0x40, which does NOT fit the 32-byte 0x1011 window (Region C
    // autoneg owns 0x2180+). In V2 the eye_regs block (Region 10, paddr[8:5]==
    // 4'b1010, SoC 0x2140-0x215F) is ABSENT, so its first word at SoC 0x2140 is
    // free; we route exactly that word to slave-paddr 0x40. SWI_EPOCH_STATUS is
    // therefore readable at SoC 0x4403_2140 in V2 (matches the PHY REGISTER_MAP).
`ifdef TIDELINK_PHY_V2
    wire gpio_phy_epoch_sel = tl_apb_psel && (tl_apb_paddr[8:0] == 9'h140);
    wire gpio_phy_apb_sel   = (tl_apb_psel && (tl_apb_paddr[8:5] == 4'b1011))
                              || gpio_phy_epoch_sel;
`else
    wire gpio_phy_apb_sel = tl_apb_psel && (tl_apb_paddr[8:5] == 4'b1011);
`endif

    wire [SYS_DATA_W-1:0]  gpio_phy_apb_prdata;
    wire                    gpio_phy_apb_pready;
    wire                    gpio_phy_apb_pslverr;

`ifdef TIDELINK_PHY_V2
    // SoC Labs V2 epoch-anchor engagement obs 2026-06-14. Driven by
    // u_chiplet_controller (WlinkGPIOPHY lane-deskew anchor state, in the
    // recovered link_rx_rx_link_clk domain) and consumed by the
    // tidelink_gpio_phy_apb_regs slave below, which 2-flop-syncs into apb_clk
    // and exposes them at SWI_EPOCH_STATUS (paddr 0x40 -> SoC MMIO 0x4403_2140:
    // [0]=epoch_anchored, [6:1]=epoch_span). V1 builds never see these.
    wire                    gpio_phy_epoch_anchored_w;
    wire [5:0]              gpio_phy_epoch_span_w;
`endif

    tidelink_gpio_phy_apb_regs u_gpio_phy_apb_regs (
        // APB clock / reset
        .apb_clk             (hclk),
        .apb_rst_n           (hresetn),

        // APB3 interface — paddr synthesised so the slave's internal
        // localparams (8'h20..8'h3C) line up with the four LSB-bits of
        // tl_apb_paddr inside the 0x160-0x17F aperture.
        .psel                (gpio_phy_apb_sel),
        .penable             (tl_apb_penable),
        .pwrite              (tl_apb_pwrite),
`ifdef TIDELINK_PHY_V2
        // SoC 0x2140 (freed eye word, V2-only) -> slave-paddr 0x40
        // (SWI_EPOCH_STATUS); the Region 11 window 0x2160-0x217F maps as before.
        .paddr               (gpio_phy_epoch_sel ? 8'h40
                                                 : {3'b001, tl_apb_paddr[4:0]}),
`else
        .paddr               ({3'b001, tl_apb_paddr[4:0]}),
`endif
        .pwdata              (tl_apb_pwdata),
        .prdata              (gpio_phy_apb_prdata),
        .pready              (gpio_phy_apb_pready),
        .pslverr             (gpio_phy_apb_pslverr),

        // link_rx_clk domain — recovered RX clock exposed on the controller
        // (deps/axi-chiplet-controller@3e0e711). role_locked is active-high,
        // connected directly to rst_n per INTEGRATION_GUIDE §5.2.
        .link_rx_clk         (gpio_phy_link_rx_clk_w),
        .link_rx_rst_n       (role_locked_o),

        // CDC outputs → u_chiplet_controller (consumed by the new lane_checker
        // through the controller's lane_lock_thresh_i / lane_clear_noise_i
        // ports added in deps/axi-chiplet-controller@68d625d).
        .lock_thresh_o       (lane_lock_thresh_w),
        .noise_mode_o        (/* unused at tidelink_top scope */),
        .clear_noise_pulse_o (lane_clear_noise_w),

        // Per-lane observability inputs — driven by u_chiplet_controller's
        // new lane_*_o outputs (see u_chiplet_controller instantiation below).
        .noise_min_i         (lane_noise_min_w),
        .noise_max_i         (lane_noise_max_w),
        .noise_mean_i        (lane_noise_mean_w),
        .noise_current_i     (lane_noise_current_w),
        .dist_raw_i          (lane_dist_raw_w),
        .dist_voted_i        (lane_dist_voted_w),
        .wire_status_i       (lane_wire_status_w),
        .canary_pass_i       (lane_canary_pass_w),
        .canary_valid_i      (lane_canary_valid_w)
`ifdef TIDELINK_PHY_V2
        // SoC Labs V2 epoch-anchor obs 2026-06-14 — engagement state from the
        // WlinkGPIOPHY lane-deskew engine (via u_chiplet_controller). Read at
        // SWI_EPOCH_STATUS (paddr 0x40 -> SoC MMIO 0x4403_2140).
        ,
        .epoch_anchored_i    (gpio_phy_epoch_anchored_w),
        .epoch_span_i        (gpio_phy_epoch_span_w)
`endif
    );

    // Observability-bus outputs from u_chiplet_controller that the new APB
    // slave does NOT directly consume (mismatch_pulse_o, dwell_min_dist_o).
    // mismatch_pulse_o is consumed by the eye-toolkit GUI via aggregated
    // readback (INTEGRATION_GUIDE §6.2); dwell_min_dist_o feeds the
    // calibrator (internal to the controller). Both are pinned to the
    // observability bus here for downstream consumers / future bind probes
    // and marked intentionally unused at this scope.
    /* verilator lint_off UNUSED */
    wire _unused_lane_obs = |{lane_mismatch_pulse_w, lane_dwell_min_dist_w};
    /* verilator lint_on UNUSED */

    // tl_apb_prdata mux: when a shim is selected, return its rdata;
    // otherwise return u_tidelink's APB rdata (tidelink_internal_prdata).
    // Order: Region 10 (eye) > Region 11 (gpio_phy) > everything else.
    wire [SYS_DATA_W-1:0]  tidelink_internal_prdata;
    wire                    tidelink_internal_pready;
    wire                    tidelink_internal_pslverr;

`ifdef TIDELINK_PHY_V2
    // V2: SoC 0x2140 (gpio_phy_epoch_sel) lives inside the eye_shim_sel address
    // range (0x2140-0x215F), so the gpio_phy slave must win that single word.
    // eye_shim returns 0 in V2 anyway (Region 10 retired), so checking the
    // gpio slave first is safe for every other address too.
    //
    // SoC Labs perlane-wp (2026-06-16): the new sweep-oracle / per-lane word-pin
    // registers also live in the eye_shim address range (SoC 0x2144/0x2148/
    // 0x214C). They are served by the chiplet controller via tidelink_internal_*
    // (ctrl_reg path), so they must fall THROUGH eye_shim — exclude them here,
    // exactly like gpio_phy_epoch_sel excludes 0x2140.
    // EYE-WIDTH OBS DECODE FIX (2026-06-17): slot 4 (SoC 0x2150, paddr[4:0]=5'h10)
    // is the EYE_WIDTH_SEL diagnostic. It is decoded in the chiplet controller's
    // region10_rdata (ctrl_reg_r10 path) and reaches this scope via
    // tidelink_internal_prdata. Like 0x2144/0x2148/0x214C it MUST be excluded
    // from eye_shim_sel_eff so it falls through to tidelink_internal_prdata;
    // otherwise eye_shim (tied to 0 in V2) wins and 0x2150 reads 0x00000000 with
    // NO 0xE7 marker — the silicon symptom. region10_hit in tidelink_apb_regs
    // already routes 0x2150 (paddr[4:2]=3'h4 != 0) to ctrl_reg_r10, so the
    // controller serves {0xE7,...,sync_eye_width_1} once eye_shim is excluded.
    wire perlane_wp_sel = tl_apb_psel
                          && (tl_apb_paddr[8:5] == 4'b1010)
                          && ((tl_apb_paddr[4:0] == 5'h04)    // 0x2144 SYNC_LANE_LIVE
                           || (tl_apb_paddr[4:0] == 5'h08)    // 0x2148 WORD_PIN_PERLANE
                           || (tl_apb_paddr[4:0] == 5'h0C)    // 0x214C WORD_PIN_PERLANE_EN
                           || (tl_apb_paddr[4:0] == 5'h10)    // 0x2150 EYE_WIDTH_SEL (RO)
                           || (tl_apb_paddr[4:0] == 5'h14)    // 0x2154 EYE_LANE_SEL (RW, Task 3)
                           // SoC Labs V2 data-send obs 2026-06-21: 0x2158 is the
                           // A2L_REPLAY_OBS RO word (Region 10 slot 6), served by the
                           // chiplet controller's region10_rdata. Exclude it from
                           // eye_shim so it falls through to tidelink_internal_prdata;
                           // otherwise eye_shim (tied 0 in V2) wins and 0x2158 reads
                           // 0x00000000 with NO 0xA2 marker (same trap as 0x2150).
                           || (tl_apb_paddr[4:0] == 5'h18)    // 0x2158 A2L_REPLAY_OBS (RO)
                           // STICKY-POISON sync_seen obs 2026-06-23: 0x215C is the
                           // SYNC_SEEN_VEC RO word (Region 10 slot 7), served by the
                           // chiplet controller's region10_rdata. Exclude it from
                           // eye_shim so it falls through to tidelink_internal_prdata;
                           // otherwise eye_shim (tied 0 in V2) wins and 0x215C reads
                           // 0x00000000 with NO 0x5F marker (same trap as 0x2150/0x2158).
                           || (tl_apb_paddr[4:0] == 5'h1C));  // 0x215C SYNC_SEEN_VEC (RO)
    wire eye_shim_sel_eff = eye_shim_sel && !perlane_wp_sel;
    assign tl_apb_prdata  = gpio_phy_apb_sel   ? gpio_phy_apb_prdata   :
                            eye_shim_sel_eff   ? eye_shim_prdata       :
                                                 tidelink_internal_prdata;
    assign tl_apb_pready  = gpio_phy_apb_sel   ? gpio_phy_apb_pready   :
                            eye_shim_sel_eff   ? eye_shim_pready       :
                                                 tidelink_internal_pready;
    assign tl_apb_pslverr = gpio_phy_apb_sel   ? gpio_phy_apb_pslverr  :
                            eye_shim_sel_eff   ? eye_shim_pslverr      :
                                                 tidelink_internal_pslverr;
`else
    assign tl_apb_prdata  = eye_shim_sel       ? eye_shim_prdata       :
                            gpio_phy_apb_sel   ? gpio_phy_apb_prdata   :
                                                 tidelink_internal_prdata;
    assign tl_apb_pready  = eye_shim_sel       ? eye_shim_pready       :
                            gpio_phy_apb_sel   ? gpio_phy_apb_pready   :
                                                 tidelink_internal_pready;
    assign tl_apb_pslverr = eye_shim_sel       ? eye_shim_pslverr      :
                            gpio_phy_apb_sel   ? gpio_phy_apb_pslverr  :
                                                 tidelink_internal_pslverr;
`endif

    // Route APB responses back to both sources.  GATE the FC response: the FC is
    // told 'ready' only in the cycles it actually owns the bus (fc_cfg_apb_active)
    // -- otherwise it is held off (pready=0) and, per its RX FSM, cleanly stalls
    // with its transaction intact.  prdata is passed through unconditionally: the
    // FC issues writes only (fc_rx_cfg_pwrite=1) and ignores read data.
    assign fc_cfg_apb_prdata  = tl_apb_prdata;
    assign fc_cfg_apb_pready  = fc_cfg_apb_active ? tl_apb_pready  : 1'b0;
    assign fc_cfg_apb_pslverr = fc_cfg_apb_active ? tl_apb_pslverr : 1'b0;

    // External (PS) response.  When the FC owns the bus the PS is stalled
    // (pready=0) -- but the arbiter above guarantees fc_cfg_apb_active=0 whenever
    // an external access is in its ACCESS phase, so the PS is never actually
    // starved here.  ext_timeout force-completes a stuck-slave stall with a bus
    // error so the PS can never hang (the Zynq has no timeout of its own).
    assign tl_regs_prdata  = fc_cfg_apb_active ? '0   : tl_apb_prdata;
    assign tl_regs_pready  = fc_cfg_apb_active ? 1'b0 : (tl_apb_pready  | ext_timeout);
    assign tl_regs_pslverr = fc_cfg_apb_active ? 1'b0 : (tl_apb_pslverr | ext_timeout);

    // =========================================================================
    // Address translation wiring + pipeline register
    // =========================================================================
    wire [SYS_ADDR_W-1:0]  translated_sub_haddr;  // combinational output from translator

    // Pipeline register: breaks the 256:1 segment mux + adder combinational
    // path between the address translator and XHB500. Inserts one wait state
    // per new NONSEQ transfer; SEQ beats pass through without stalling.
    logic [SYS_ADDR_W-1:0] pipe_haddr_r;
    logic              [1:0] pipe_htrans_r;
    logic              [2:0] pipe_hsize_r;
    logic                    pipe_hwrite_r;
    logic              [2:0] pipe_hburst_r;
    logic              [3:0] pipe_hprot_r;
    logic                    pipe_hsel_r;
    logic                    pipe_valid_r;   // latched address phase ready for XHB500

    // Detect new address phase on external port.
    // SoC Labs 2026-07-05 comb-loop fix: do NOT qualify with ahb_sub_hready.
    // The FPGA wrapper loops ahb_sub_hreadyout back into ahb_sub_hready, and
    // ahb_sub_hreadyout (below) depended on ext_is_nonseq -> hreadyout was a
    // combinational function of itself (Vivado: "1 combinational loop (HIGH)").
    // On silicon the bridge / this pipe / XHB500 sampled the ring divergently:
    // window WRITES phantom-completed at the bridge (vanish), HWDATA was
    // captured one cycle late (poison), double-accepts corrupted FC credit
    // (fcsm 4->0 under sustained window traffic). Reproduced deterministically
    // in sim by test_v2_xhb_window_bridge (bridge-accurate BFM). Dropping the
    // hready term is safe for this single-master port: pipe_valid_r blocks
    // re-latch of a held NONSEQ, and the pipe clears exactly at the master's
    // address-phase completion edge (hreadyout==raw whenever pipe_valid_r).
    wire ext_addr_phase = ahb_sub_hsel & ahb_sub_htrans[1];
    wire ext_is_nonseq  = ext_addr_phase & (ahb_sub_htrans == 2'b10);

    // XHB500 hreadyout / hresp (raw, before pipeline + timeout insertion)
    wire xhb_sub_hreadyout_raw;
    wire xhb_sub_hresp_raw;

    // ── ahb_sub bounded stall backstop (2026-07-06) ───────────────────────────
    // The XHB500 subordinate holds hreadyout low for the whole data phase of a
    // window transfer while it waits on the AXI/link round-trip to the peer. If
    // the link wedges (credit stall, PHY drop), that hreadyout can stay low
    // FOREVER -> ahb_sub_hreadyout (below) stays low -> the Xilinx
    // axi_ahblite_bridge and the Zynq PS interconnect block indefinitely with no
    // PS-side timeout, wedging z2_02 off-net (physical power-cycle to recover;
    // bench-confirmed on the tl-data aperture before its own backstop —
    // tidelink_fc_adapter.sv:247-329, TX_STALL_TIMEOUT). This mirrors that fix
    // for the window path: after SUB_STALL_TIMEOUT hclk cycles of a single
    // transfer held stalled, terminate it with the standard AHB two-cycle ERROR
    // response (cy1: HREADYOUT=0 + HRESP=1; cy2: HREADYOUT=1 + HRESP=1) so the
    // bridge/PS un-block with a recoverable bus error (SIGBUS) instead of hanging.
    //
    // 2^16 hclk (~2.6 ms @ 25 MHz FPGA rig, ~14 ms @ 4.7 MHz) is orders beyond a
    // legitimate slow-but-progressing window round-trip: the counter RESETS every
    // time the front-end stops stalling (i.e. on every completed beat — see
    // ext_stalled), so a long healthy burst never accumulates; ONLY a single beat
    // held stalled continuously past the timeout (a genuine wedge) can trip it.
    //
    // NO COMB LOOP (this is the load-bearing invariant that cb33c9f established):
    // every term below is a register or derives ONLY from ahb_sub_hsel/htrans
    // (ext_is_nonseq), pipe_valid_r (reg) and xhb_sub_hreadyout_raw (XHB500's own
    // output) — NEVER from ahb_sub_hready (the wrapper loopback). ahb_sub_hreadyout
    // gains only the sub_err{1,2}_r register overrides, so it remains free of any
    // combinational dependence on ahb_sub_hready.
`ifdef TIDELINK_SUB_STALL_TIMEOUT_LOG2
    // Sim override (cocotb/tidelink_top_pair_v2/test_v2_xhb_window_stall.py drives
    // it small so the backstop trips in a few hundred cycles instead of ~2^16).
    localparam int SUB_STALL_TIMEOUT_LOG2 = `TIDELINK_SUB_STALL_TIMEOUT_LOG2;
`else
    localparam int SUB_STALL_TIMEOUT_LOG2 = 16;   // ~2^16 hclk; see rationale above
`endif
    logic [SUB_STALL_TIMEOUT_LOG2:0] sub_stall_ctr_r;
    logic                            sub_err1_r, sub_err2_r;
    // Front-end is holding HREADYOUT low (a transfer is in flight and not
    // progressing): the pipeline-fill stall cycle OR — the case that actually
    // wedges the PS — XHB500 holding its data phase low while it waits on the
    // cross-link b/r response. NOTE the data-phase stall persists AFTER
    // pipe_valid_r clears (XHB500 has already accepted the address and the
    // master has dropped to IDLE), so it is detected by xhb_sub_hreadyout_raw==0
    // directly, NOT via pipe_valid_r. On an idle bus XHB500 drives raw==1
    // (tidelink_top.sv:1181), so idle => not stalled => the counter resets and
    // every completed beat (raw pulses high) re-zeroes it. Frozen during the
    // 2-cycle ERROR response so one wedged transfer is counted exactly once.
    wire sub_stall_fill    = ext_is_nonseq && !pipe_valid_r;
    wire sub_stall_busy    = !xhb_sub_hreadyout_raw;
    wire ext_stalled       = (sub_stall_fill || sub_stall_busy)
                             && !sub_err1_r && !sub_err2_r;
    wire sub_stall_expired = sub_stall_ctr_r[SUB_STALL_TIMEOUT_LOG2];

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pipe_haddr_r   <= '0;
            pipe_htrans_r  <= 2'b00;
            pipe_hsize_r   <= 3'b0;
            pipe_hwrite_r  <= 1'b0;
            pipe_hburst_r  <= 3'b0;
            pipe_hprot_r   <= 4'b0;
            pipe_hsel_r    <= 1'b0;
            pipe_valid_r   <= 1'b0;
        end else begin
            if (ext_is_nonseq && !pipe_valid_r) begin
                // Latch address-phase signals + translated address
                pipe_haddr_r   <= translated_sub_haddr;
                pipe_htrans_r  <= ahb_sub_htrans;
                pipe_hsize_r   <= ahb_sub_hsize;
                pipe_hwrite_r  <= ahb_sub_hwrite;
                pipe_hburst_r  <= ahb_sub_hburst;
                pipe_hprot_r   <= ahb_sub_hprot;
                pipe_hsel_r    <= 1'b1;
                pipe_valid_r   <= 1'b1;
            end else if (pipe_valid_r && xhb_sub_hreadyout_raw) begin
                // XHB500 accepted the address phase, clear pipeline
                pipe_valid_r   <= 1'b0;
                pipe_hsel_r    <= 1'b0;
                pipe_htrans_r  <= 2'b00;
            end else if (sub_err1_r) begin
                // Stall-timeout abort: abandon the in-flight (wedged) transfer so
                // it cannot re-trigger the backstop or hold hsel into XHB500.
                pipe_valid_r   <= 1'b0;
                pipe_hsel_r    <= 1'b0;
                pipe_htrans_r  <= 2'b00;
            end
        end
    end

    // Stall-timeout counter + 2-cycle AHB ERROR sequencer (registered; driven
    // off hclk; never combinationally dependent on ahb_sub_hready — see above).
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            sub_stall_ctr_r <= '0;
            sub_err1_r      <= 1'b0;
            sub_err2_r      <= 1'b0;
        end else begin
            sub_err2_r <= sub_err1_r;   // ERROR cycle 2 follows cycle 1
            sub_err1_r <= 1'b0;         // default: one-shot
            if (!ext_stalled) begin
                sub_stall_ctr_r <= '0;                 // resets every completed beat
            end else if (sub_stall_expired) begin
                sub_stall_ctr_r <= '0;
                sub_err1_r      <= 1'b1;               // fire the ERROR response
            end else begin
                sub_stall_ctr_r <= sub_stall_ctr_r + 1'b1;
            end
        end
    end

    // Signals presented to XHB500: pipeline register when valid, pass-through for SEQ
    wire [SYS_ADDR_W-1:0] xhb_sub_haddr  = pipe_valid_r ? pipe_haddr_r  : translated_sub_haddr;
    wire              [1:0] xhb_sub_htrans = pipe_valid_r ? pipe_htrans_r : ahb_sub_htrans;
    wire              [2:0] xhb_sub_hsize  = pipe_valid_r ? pipe_hsize_r  : ahb_sub_hsize;
    wire                    xhb_sub_hwrite = pipe_valid_r ? pipe_hwrite_r : ahb_sub_hwrite;
    wire              [2:0] xhb_sub_hburst = pipe_valid_r ? pipe_hburst_r : ahb_sub_hburst;
    wire              [3:0] xhb_sub_hprot  = pipe_valid_r ? pipe_hprot_r  : ahb_sub_hprot;
    wire                    xhb_sub_hsel   = pipe_valid_r ? pipe_hsel_r   : ahb_sub_hsel;
    // HREADY to XHB500: during pipeline fill cycle, hold low so XHB500 ignores
    // the stale address; once pipeline is valid, pass through XHB500's own hreadyout
    // (comb-loop fix, part 2): the else-arm used ahb_sub_hready — the last
    // remaining hready-in fan-in to XHB500's FSM through the wrapper loopback.
    // Use XHB500's own raw hreadyout instead (idle bus: raw==1 anyway).
    wire                    xhb_sub_hready = pipe_valid_r ? xhb_sub_hreadyout_raw :
                                             (ext_is_nonseq ? 1'b0 : xhb_sub_hreadyout_raw);

    // External hreadyout: stall upstream during the pipeline fill cycle. The
    // sub_err{1,2}_r overrides drive the two-cycle AHB ERROR response when the
    // stall backstop trips (cy1 HREADYOUT=0, cy2 HREADYOUT=1) — both are
    // registers, so no combinational dependence on ahb_sub_hready is introduced.
    assign ahb_sub_hreadyout = sub_err1_r ? 1'b0 :
                               sub_err2_r ? 1'b1 :
                               (ext_is_nonseq && !pipe_valid_r) ? 1'b0 :
                               xhb_sub_hreadyout_raw;
    // External hresp: XHB500's own hresp, overridden to ERROR for the two-cycle
    // backstop response. (XHB500 normally holds hresp=OKAY on the window path.)
    assign ahb_sub_hresp     = (sub_err1_r | sub_err2_r) ? 1'b1 : xhb_sub_hresp_raw;

    // =========================================================================
    // 1. TideLink RX FIFO (tidelink_fifo)
    //    - AHB slave: FIFO data window (via mux from CPU + FC adapter RX)
    //    - APB slave: config registers (via APB mux above)
    //    - AHB master: returner → routed to FC adapter for sideband transport
    // =========================================================================
    tidelink_fifo #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE),
        .ENABLE_AHB_WRITE  (ENABLE_AHB_WRITE)
    ) u_tidelink_fifo (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave — FIFO data window (muxed: FC adapter RX writes + CPU reads)
        // AHB Slave — FIFO data window (CPU reads, direct connection, no mux)
        .ahbs_hsel         (ahb_fifo_hsel),
        .ahbs_hready       (ahb_fifo_hready),
        .ahbs_htrans       (ahb_fifo_htrans),
        .ahbs_hsize        (ahb_fifo_hsize),
        .ahbs_hwrite       (ahb_fifo_hwrite),
        .ahbs_haddr        (ahb_fifo_haddr),
        .ahbs_hwdata       (ahb_fifo_hwdata),
        .ahbs_hreadyout    (ahb_fifo_hreadyout),
        .ahbs_hresp        (ahb_fifo_hresp),
        .ahbs_hrdata       (ahb_fifo_hrdata),

        // APB Slave — Config registers (via APB mux: FC adapter + external APB)
        // prdata/pready/pslverr go through tidelink_internal_* so the eye
        // (Region 10) and gpio_phy (Region 11) shims can arbitrate via the
        // tl_apb_prdata mux above.
        .apbs_psel         (tl_apb_psel),
        .apbs_penable      (tl_apb_penable),
        .apbs_pwrite       (tl_apb_pwrite),
        .apbs_paddr        (tl_apb_paddr),
        .apbs_pwdata       (tl_apb_pwdata),
        .apbs_prdata       (tidelink_internal_prdata),
        .apbs_pready       (tidelink_internal_pready),
        .apbs_pslverr      (tidelink_internal_pslverr),

        // AHB Master — Returner (routed to FC adapter, NOT external bus)
        .ahbm_haddr        (rtn_haddr),
        .ahbm_hwdata       (rtn_hwdata),
        .ahbm_htrans       (rtn_htrans),
        .ahbm_hsize        (rtn_hsize),
        .ahbm_hwrite       (rtn_hwrite),
        .ahbm_hready       (rtn_hready),
        .ahbm_hresp        (rtn_hresp),
        .ahbm_hrdata       (rtn_hrdata),

        // Interrupts
        .released_credits_irq (released_credits_irq),
        .doorbell_irq         (doorbell_irq),
        .packet_committed_irq (packet_committed_irq),

        // PTP register pass-through (to/from tidelink_ptp)
        .ptp_reg_write       (ptp_reg_write),
        .ptp_reg_addr        (ptp_reg_addr),
        .ptp_reg_wdata       (ptp_reg_wdata),
        .ptp_reg_rdata       (ptp_reg_rdata),
        .ptp_reg_region      (ptp_reg_region),

        // Servo register pass-through (to/from tidelink_ptp_servo)
        .servo_reg_write     (servo_reg_write),
        .servo_reg_addr      (servo_reg_addr),
        .servo_reg_wdata     (servo_reg_wdata),
        .servo_reg_rdata     (servo_reg_rdata),

        // Timestamp mailbox pass-through (FC SIDEBAND → servo)
        .mbox_reg_write      (mbox_reg_write),
        .mbox_reg_addr       (mbox_reg_addr),
        .mbox_reg_wdata      (mbox_reg_wdata),

        // Chiplet controller register pass-through
        .ctrl_reg_write      (ctrl_reg_write),
        .ctrl_reg_addr       (ctrl_reg_addr),
        .ctrl_reg_r10        (ctrl_reg_r10),   // perlane-wp Region-10 select
        .ctrl_reg_rd         (ctrl_reg_rd),    // rxcap Region-D select
        .ctrl_reg_wdata      (ctrl_reg_wdata),
        .ctrl_reg_rdata      (ctrl_reg_rdata),

        // Performance profiling register pass-through
        .perf_reg_write      (perf_reg_write),
        .perf_reg_addr       (perf_reg_addr),
        .perf_reg_wdata      (perf_reg_wdata),
        .perf_reg_rdata      (perf_reg_rdata),
        .perf_reg_region     (perf_reg_region),

        // Credit count observation (for performance profiling)
        .perf_credit_count   (perf_credit_count),

        // FC direct write (from FC adapter, bypasses AHB for FIFO writes)
        .fc_wr_valid         (fc_rx_fifo_valid),
        .fc_wr_write         (fc_rx_fifo_write),
        .fc_wr_addr          (fc_rx_fifo_addr),
        .fc_wr_wdata         (fc_rx_fifo_wdata),
        .fc_wr_ready         (fc_rx_fifo_ready),
        // PUF SRAM read (from FC adapter, for TideChart boot entropy)
        .puf_addr            (puf_addr),
        .puf_req             (puf_req),
        .puf_rdata           (puf_rdata),
        .puf_ack             (puf_ack)
    );

    // =========================================================================
    // 2. TideLink FC Adapter
    //    - TX path: AHB slave (TX aperture) → FC node TX
    //    - RX path: FC node RX → AHB master → local RX FIFO
    //    - Sideband: Intercepts returner AHB master → FC sideband packets
    // =========================================================================
    tidelink_fc_adapter #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .APB_ADDR_W (APB_ADDR_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_fc_adapter (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave — TX aperture (CPU/DMA writes FIFO packets here)
        .ahb_tx_hsel       (ahb_tx_hsel),
        .ahb_tx_haddr      (ahb_tx_haddr),
        .ahb_tx_htrans     (ahb_tx_htrans),
        .ahb_tx_hsize      (ahb_tx_hsize),
        .ahb_tx_hwrite     (ahb_tx_hwrite),
        .ahb_tx_hwdata     (ahb_tx_hwdata),
        .ahb_tx_hready     (ahb_tx_hready),
        .ahb_tx_hrdata     (ahb_tx_hrdata),
        .ahb_tx_hresp      (ahb_tx_hresp),
        .ahb_tx_hreadyout  (ahb_tx_hreadyout),

        // AHB Slave — Returner interception (returner thinks this is remote)
        .rtn_haddr         (rtn_haddr),
        .rtn_hwdata        (rtn_hwdata),
        .rtn_htrans        (rtn_htrans),
        .rtn_hsize         (rtn_hsize),
        .rtn_hwrite        (rtn_hwrite),
        .rtn_hready        (rtn_hready),
        .rtn_hresp         (rtn_hresp),
        .rtn_hrdata        (rtn_hrdata),

        // AHB Master — RX FIFO path (internal, via FIFO mux)
        // Direct Write — RX FIFO path (single-cycle, no AHB mux)
        .fc_rx_fifo_valid  (fc_rx_fifo_valid),
        .fc_rx_fifo_write  (fc_rx_fifo_write),
        .fc_rx_fifo_addr   (fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (fc_rx_fifo_ready),

        // AHB Master — RX Config path (internal, via config mux)
        // APB Master — RX Config path (direct APB, no AHB-to-APB bridge)
        .fc_rx_cfg_paddr   (fc_cfg_apb_paddr),
        .fc_rx_cfg_pwdata  (fc_cfg_apb_pwdata),
        .fc_rx_cfg_psel    (fc_cfg_apb_psel),
        .fc_rx_cfg_penable (fc_cfg_apb_penable),
        .fc_rx_cfg_pwrite  (fc_cfg_apb_pwrite),
        .fc_rx_cfg_prdata  (fc_cfg_apb_prdata),
        .fc_rx_cfg_pready  (fc_cfg_apb_pready),

        // Servo FC SIDEBAND injection (timestamp exchange)
        .servo_fc_valid    (servo_fc_valid),
        .servo_fc_data     (servo_fc_data),
        .servo_fc_ready    (servo_fc_ready),

        // TideChart AXI-Stream port
        .tc_axis_tx_tvalid   (tc_axis_tx_tvalid),
        .tc_axis_tx_tdata    (tc_axis_tx_tdata),
        .tc_axis_tx_tready   (tc_axis_tx_tready),
        .tc_axis_rx_tvalid   (tc_axis_rx_tvalid),
        .tc_axis_rx_tdata    (tc_axis_rx_tdata),
        .tc_axis_rx_tready   (tc_axis_rx_tready),

        // QoS priority hint
        .tc_qos_priority     (tc_qos_priority),

        // PUF SRAM read (to FIFO memory)
        .puf_addr            (puf_addr),
        .puf_req             (puf_req),
        .puf_rdata           (puf_rdata),
        .puf_ack             (puf_ack),

        // FC Node interface (to Wlink TideLink FC node)
        .tl_fc_a2l_valid   (tl_fc_a2l_valid),
        .tl_fc_a2l_data    (tl_fc_a2l_data),
        .tl_fc_a2l_ready   (tl_fc_a2l_ready),
        .tl_fc_l2a_valid   (tl_fc_l2a_valid),
        .tl_fc_l2a_data    (tl_fc_l2a_data),
        .tl_fc_l2a_accept  (tl_fc_l2a_accept)
    );

    // =========================================================================
    // 2b. TideLink PTP Module (Short Packet)
    //     - TX path: AHB slave → wait for tx_router_idle → Short Packet TX
    //     - RX path: Short Packet RX → payload latch + PHC hw_capture
    //     - Registers: PTP_CTRL/PTP_RX_PAYLOAD/PTP_STATUS via APB pass-through
    //
    // Interface-debug stub: when STUB_PTP=1 the module is replaced by tie-offs
    // (see header parameter block). Stub also asserts ahb_ptp_hreadyout=1 so
    // the PTP slave port doesn't stall the local bus.
    // =========================================================================
    // Elaboration-time safety check for invalid stub combinations.
    initial begin
        if (STUB_PTP == 1'b1 && STUB_SERVO == 1'b0) begin
            $error("STUB_PTP=1 requires STUB_SERVO=1 (servo waits on dreq_tx_done from ptp)");
        end
    end

    generate if (STUB_PTP == 1'b0) begin : gen_ptp_real
        tidelink_ptp #(
            .SYS_DATA_W       (SYS_DATA_W),
            .PHC_LOCK_GATE_EN (PHC_LOCK_GATE_EN)
        ) u_ptp (
            .hclk              (hclk),
            .hresetn           (hresetn),

            // TX router idle (from chiplet controller)
            .tx_router_idle    (tx_router_idle),

            // PTP Short Packet TX interface
            .ptp_sp_tx_valid   (ptp_sp_tx_valid),
            .ptp_sp_tx_data_id (ptp_sp_tx_data_id),
            .ptp_sp_tx_payload (ptp_sp_tx_payload),
            .ptp_sp_tx_ready   (ptp_sp_tx_ready),

            // PTP Short Packet RX interface
            .ptp_sp_rx_valid   (ptp_sp_rx_valid),
            .ptp_sp_rx_data_id (ptp_sp_rx_data_id),
            .ptp_sp_rx_payload (ptp_sp_rx_payload),
            .ptp_sp_rx_accept  (ptp_sp_rx_accept),

            // PHC hardware capture
            .phc_hw_capture    (phc_hw_capture_raw),

            // PHC time inputs (for hardware sync initiator, via CDC)
            .phc_nanoseconds   (phc_nanoseconds_sync),
            .phc_seconds        (phc_seconds_sync),
            .phc_pps            (phc_pps_sync),

            // AHB slave — PTP TX write port
            .ahb_ptp_hsel      (ahb_ptp_hsel),
            .ahb_ptp_haddr     (ahb_ptp_haddr),
            .ahb_ptp_htrans    (ahb_ptp_htrans),
            .ahb_ptp_hsize     (ahb_ptp_hsize),
            .ahb_ptp_hwrite    (ahb_ptp_hwrite),
            .ahb_ptp_hwdata    (ahb_ptp_hwdata),
            .ahb_ptp_hready    (ahb_ptp_hready),
            .ahb_ptp_hrdata    (ahb_ptp_hrdata),
            .ahb_ptp_hresp     (ahb_ptp_hresp),
            .ahb_ptp_hreadyout (ahb_ptp_hreadyout),

            // Register interface (from APB regs pass-through)
            .ptp_reg_write     (ptp_reg_write),
            .ptp_reg_addr      (ptp_reg_addr),
            .ptp_reg_wdata     (ptp_reg_wdata),
            .ptp_reg_rdata     (ptp_reg_rdata),
            .ptp_reg_region    (ptp_reg_region),

            // Servo event outputs
            .sync_tx_done      (sync_tx_done),
            .dreq_tx_done      (dreq_tx_done),
            .sync_rx_done      (sync_rx_done),
            .dreq_rx_done      (dreq_rx_done),

            // Servo DELAY_REQ injection
            .servo_dreq_trigger (servo_dreq_trigger),

            // External PHC lock gate (for multi-hop chaining)
            .phc_locked_i      (phc_locked_i),

            // Interrupt
            .ptp_irq           (ptp_irq)
        );
    end else begin : gen_ptp_stub
        // Short-packet TX interface — quiescent (never request a packet)
        assign ptp_sp_tx_valid   = 1'b0;
        assign ptp_sp_tx_data_id = 8'h00;
        assign ptp_sp_tx_payload = 16'h0000;
        // Short-packet RX accept — held high so the controller sinks any RX
        // beats without backpressure (we don't care about RX payload here).
        assign ptp_sp_rx_accept  = 1'b1;

        // PHC hw_capture — never pulse
        assign phc_hw_capture_raw = 1'b0;

        // Servo event pulses — never fire
        assign sync_tx_done = 1'b0;
        assign dreq_tx_done = 1'b0;
        assign sync_rx_done = 1'b0;
        assign dreq_rx_done = 1'b0;

        // AHB PTP slave — reply OKAY/READY immediately, zero rdata
        assign ahb_ptp_hrdata    = '0;
        assign ahb_ptp_hresp     = 1'b0;
        assign ahb_ptp_hreadyout = 1'b1;

        // PTP APB register read-back — zero
        assign ptp_reg_rdata = '0;

        // Interrupt — never assert
        assign ptp_irq = 1'b0;
    end endgenerate

    // =========================================================================
    // 2c. TideLink PTP Servo (Autonomous Clock Synchronisation)
    //     - Grandmaster: captures t1/t4, sends via FC SIDEBAND to Subordinate
    //     - Subordinate: captures t2/t3, receives t1/t4, computes offset,
    //       adjusts PHC via SET_TIME or NS_INCR_FRAC
    //
    // Interface-debug stub: when STUB_SERVO=1 the module is replaced by
    // tie-offs (see header parameter block).
    // =========================================================================
    generate if (STUB_SERVO == 1'b0) begin : gen_servo_real
        tidelink_ptp_servo #(
            .SYS_DATA_W (SYS_DATA_W),
            .FC_DATA_W  (FC_DATA_W)
        ) u_servo (
            .clk                    (hclk),
            .resetn                 (hresetn),

            // Register interface (from APB regs, Region 2 addr 3-7 + Region 3)
            .servo_reg_write        (servo_reg_write),
            .servo_reg_addr         (servo_reg_addr),
            .servo_reg_wdata        (servo_reg_wdata),
            .servo_reg_rdata        (servo_reg_rdata),

            // PTP event inputs
            .sync_tx_done           (sync_tx_done),
            .dreq_tx_done           (dreq_tx_done),
            .sync_rx_done           (sync_rx_done),
            .dreq_rx_done           (dreq_rx_done),

            // PHC hardware capture (via CDC from PHC)
            .hw_cap_seconds         (phc_hw_cap_seconds_sync),
            .hw_cap_nanoseconds     (phc_hw_cap_nanoseconds_sync),

            // FC SIDEBAND injection (to FC adapter)
            .servo_fc_valid         (servo_fc_valid),
            .servo_fc_data          (servo_fc_data),
            .servo_fc_ready         (servo_fc_ready),

            // Timestamp mailbox (from FC RX config path via APB)
            .mbox_reg_write         (mbox_reg_write),
            .mbox_reg_addr          (mbox_reg_addr),
            .mbox_reg_wdata         (mbox_reg_wdata),

            // DELAY_REQ trigger (to PTP TX path)
            .servo_dreq_trigger     (servo_dreq_trigger),

            // PHC adjustment outputs (via CDC to external PHC)
            .phc_hw_set_time        (phc_hw_set_time_raw),
            .phc_hw_set_seconds     (phc_hw_set_seconds_raw),
            .phc_hw_set_nanoseconds (phc_hw_set_nanoseconds_raw),
            .phc_hw_adj_valid       (phc_hw_adj_valid_raw),
            .phc_hw_adj_ns_incr_frac(phc_hw_adj_ns_incr_frac_raw),

            // Status
            .servo_locked           (servo_locked)
        );
    end else begin : gen_servo_stub
        // Servo register read-back — zero
        assign servo_reg_rdata = '0;

        // FC SIDEBAND injection — never request
        assign servo_fc_valid = 1'b0;
        assign servo_fc_data  = '0;

        // DELAY_REQ trigger to PTP — never fire
        assign servo_dreq_trigger = 1'b0;

        // PHC adjustment outputs — idle (no SET_TIME / no NS_INCR_FRAC update)
        assign phc_hw_set_time_raw        = 1'b0;
        assign phc_hw_set_seconds_raw     = '0;
        assign phc_hw_set_nanoseconds_raw = '0;
        assign phc_hw_adj_valid_raw       = 1'b0;
        assign phc_hw_adj_ns_incr_frac_raw = '0;

        // Status — never locked
        assign servo_locked = 1'b0;
    end endgenerate

    // =========================================================================
    // 2c. PHC Clock Domain Crossing Bridge
    //     All PHC ↔ TideLink signals pass through this module.
    //     When phc_clk = hclk, the module adds benign pipeline latency.
    // =========================================================================
    tidelink_phc_cdc #(
        .SYS_DATA_W  (SYS_DATA_W),
        .SYNC_STAGES (2)
    ) u_phc_cdc (
        .hclk       (hclk),
        .hresetn    (hresetn),
        .phc_clk    (phc_clk),
        .phc_resetn (phc_resetn),
        .scan_mode  (scan_mode),

        // Path 4: HW Capture trigger (hclk → phc_clk)
        .h_hw_capture               (phc_hw_capture_raw),
        .p_hw_capture               (phc_hw_capture),

        // Path 1: HW Capture timestamps (phc_clk → hclk)
        .p_hw_cap_seconds           (phc_hw_cap_seconds),
        .p_hw_cap_nanoseconds       (phc_hw_cap_nanoseconds),
        .p_hw_cap_sub_nanoseconds   (phc_hw_cap_sub_nanoseconds),
        .h_hw_cap_seconds           (phc_hw_cap_seconds_sync),
        .h_hw_cap_nanoseconds       (phc_hw_cap_nanoseconds_sync),
        .h_hw_cap_sub_nanoseconds   (phc_hw_cap_sub_nanoseconds_sync),

        // Path 2: Free-running PHC time (phc_clk → hclk)
        .p_phc_nanoseconds          (phc_nanoseconds),
        .p_phc_seconds              (phc_seconds),
        .h_phc_nanoseconds          (phc_nanoseconds_sync),
        .h_phc_seconds              (phc_seconds_sync),

        // Path 3: PPS pulse (phc_clk → hclk)
        .p_phc_pps                  (phc_pps),
        .h_phc_pps                  (phc_pps_sync),

        // Path 5: Phase step command (hclk → phc_clk)
        .h_hw_set_time              (phc_hw_set_time_raw),
        .h_hw_set_seconds           (phc_hw_set_seconds_raw),
        .h_hw_set_nanoseconds       (phc_hw_set_nanoseconds_raw),
        .p_hw_set_time              (phc_hw_set_time),
        .p_hw_set_seconds           (phc_hw_set_seconds),
        .p_hw_set_nanoseconds       (phc_hw_set_nanoseconds),

        // Path 6: Frequency adjust (hclk → phc_clk)
        .h_hw_adj_valid             (phc_hw_adj_valid_raw),
        .h_hw_adj_ns_incr_frac      (phc_hw_adj_ns_incr_frac_raw),
        .p_hw_adj_valid             (phc_hw_adj_valid),
        .p_hw_adj_ns_incr_frac      (phc_hw_adj_ns_incr_frac)
    );

    // =========================================================================
    // 2d. TideLink Performance Profiling Module
    //     Passive observer: timestamps TX/RX events, counts packets/words/stalls.
    //     Uses free-running PHC time (Path 2 CDC), not phc_hw_capture.
    // =========================================================================

    // Derived observation signals for tidelink_perf
    wire fc_tx_handshake = tl_fc_a2l_valid & tl_fc_a2l_ready;
    wire fc_rx_handshake = tl_fc_l2a_valid & tl_fc_l2a_accept;
    wire fc_tx_is_data   = (tl_fc_a2l_data[47:46] == 2'b00);
    wire fc_rx_is_data   = (tl_fc_l2a_data[47:46] == 2'b00);
    wire fc_rx_is_first  = fc_rx_is_data & (tl_fc_l2a_data[45:32] == '0);
    wire tx_pkt_start    = ahb_tx_hsel & ahb_tx_htrans[1] & ahb_tx_hready & ahb_tx_hwrite & (ahb_tx_haddr == '0);

    // Interface-debug stub: when STUB_PERF=1 the module is replaced by
    // tie-offs (see header parameter block). Perf is a passive observer, so
    // stubbing it is structurally safe.
    generate if (STUB_PERF == 1'b0) begin : gen_perf_real
        tidelink_perf #(
            .SYS_DATA_W (SYS_DATA_W),
            .RAM_ADDR_W (RAM_ADDR_W),
            .FC_DATA_W  (FC_DATA_W)
        ) u_perf (
            .hclk              (hclk),
            .hresetn           (hresetn),

            // Register interface (from APB regs, Regions 5-7)
            .perf_reg_write    (perf_reg_write),
            .perf_reg_addr     (perf_reg_addr),
            .perf_reg_wdata    (perf_reg_wdata),
            .perf_reg_rdata    (perf_reg_rdata),
            .perf_reg_region   (perf_reg_region),

            // Free-running PHC time (hclk domain, from CDC Path 2)
            .phc_nanoseconds   (phc_nanoseconds_sync[29:0]),
            .phc_seconds       (phc_seconds_sync[31:0]),

            // FC TX observation
            .fc_tx_handshake   (fc_tx_handshake),
            .fc_tx_is_data     (fc_tx_is_data),

            // FC RX observation
            .fc_rx_handshake   (fc_rx_handshake),
            .fc_rx_is_data     (fc_rx_is_data),
            .fc_rx_is_first    (fc_rx_is_first),

            // TX aperture observation
            .tx_pkt_start      (tx_pkt_start),

            // RX FIFO observation
            .rx_pkt_committed  (packet_committed_irq),

            // Link status
            .tx_router_idle    (tx_router_idle),
            .fc_tx_valid       (tl_fc_a2l_valid),
            .fc_tx_ready       (tl_fc_a2l_ready),
            .fc_rx_valid       (tl_fc_l2a_valid),
            .fc_rx_accept      (tl_fc_l2a_accept),

            // Credit observation
            .credit_count      (perf_credit_count),

            // Congestion sideband (Phase 1 — see CONGESTION_AWARE_ROUTING.md)
            .local_link_state_o  (tl_local_link_state_o),
            .link_state_change_o (tl_link_state_change_o),
            .ewma_credit_o       (tl_ewma_credit_o),
            .bcast_ack_i         (tl_bcast_ack_i),

            // Interrupt
            .perf_irq          (perf_irq)
        );
    end else begin : gen_perf_stub
        // Perf APB register read-back — zero
        assign perf_reg_rdata = '0;

        // Congestion sideband — idle / no change
        assign tl_local_link_state_o  = 5'b0;
        assign tl_link_state_change_o = 1'b0;
        assign tl_ewma_credit_o       = '0;

        // Interrupt — never assert
        assign perf_irq = 1'b0;
    end endgenerate

    // =========================================================================
    // 3. XHB500 AHB-to-AXI Bridge (subordinate path: AHB → AXI → Wlink)
    //    Address translation applied to haddr before the bridge
    // =========================================================================
    xhb500_ahb_to_axi_bridge_chiplet_slv u_xhb_sub (
        .clk               (hclk),
        .resetn             (hresetn),
        .buf_write_error_irq(),
        .irq_en            (1'b0),

        .hsel              (xhb_sub_hsel),
        .hnonsec           (1'b0),
        .haddr             (xhb_sub_haddr),
        .htrans            (xhb_sub_htrans),
        .hsize             (xhb_sub_hsize),
        .hwrite            (xhb_sub_hwrite),
        .hready            (xhb_sub_hready),
        .hprot             ({3'h0, xhb_sub_hprot}),
        .hburst            (xhb_sub_hburst),
        .hmastlock         (1'b0),
        .hwdata            (ahb_sub_hwdata),
        .hexcl             (1'b0),
        .hmaster           (12'd0),
        .hrdata            (ahb_sub_hrdata),
        .hreadyout         (xhb_sub_hreadyout_raw),
        .hresp             (xhb_sub_hresp_raw),
        .hexokay           (),
        .hqos              (4'h0),
        .hregion           (4'h0),
        .hnsaid            (4'h0),

        .awvalid           (s_axi_awvalid),
        .awaddr            (s_axi_awaddr[31:0]),
        .awburst           (s_axi_awburst),
        .awid              (s_axi_awid),
        .awlen             (s_axi_awlen),
        .awsize            (s_axi_awsize),
        .awlock            (s_axi_awlock),
        .awprot            (s_axi_awprot),
        .awready           (s_axi_awready),
        .awcache           (s_axi_awcache),
        .awqos             (s_axi_awqos),

        .arvalid           (s_axi_arvalid),
        .araddr            (s_axi_araddr[31:0]),
        .arburst           (s_axi_arburst),
        .arid              (s_axi_arid),
        .arlen             (s_axi_arlen),
        .arsize            (s_axi_arsize),
        .arlock            (s_axi_arlock),
        .arprot            (s_axi_arprot),
        .arready           (s_axi_arready),
        .arcache           (s_axi_arcache),
        .arqos             (s_axi_arqos),

        .wvalid            (s_axi_wvalid),
        .wlast             (s_axi_wlast),
        .wstrb             (s_axi_wstrb),
        .wdata             (s_axi_wdata),
        .wready            (s_axi_wready),

        .rvalid            (s_axi_rvalid),
        .rid               (s_axi_rid),
        .rlast             (s_axi_rlast),
        .rdata             (s_axi_rdata),
        .rresp             (s_axi_rresp),
        .rready            (s_axi_rready),

        .bvalid            (s_axi_bvalid),
        .bid               (s_axi_bid),
        .bresp             (s_axi_bresp),
        .bready            (s_axi_bready),

        .awakeup           (),
        .clk_qactive       (),
        .clk_qreqn         (1'b1),
        .clk_qacceptn      (),
        .clk_qdeny         (),
        .pwr_qactive       (),
        .pwr_qreqn         (1'b1),
        .pwr_qacceptn      (),
        .pwr_qdeny         ()
    );

    // Upper 4 bits of 36-bit AXI address not used
    assign s_axi_awaddr[35:32] = 4'h0;
    assign s_axi_araddr[35:32] = 4'h0;

    // =========================================================================
    // 4. XHB500 AXI-to-AHB Bridge (manager path: Wlink → AXI → AHB)
    // =========================================================================
    xhb500_axi_to_ahb_bridge_chiplet_mst u_xhb_mng (
        .clk               (hclk),
        .resetn             (hresetn),

        .clk_qactive       (),
        .clk_qreqn         (1'b1),
        .clk_qacceptn      (),
        .clk_qdeny         (),
        .pwr_qactive       (),
        .pwr_qreqn         (1'b1),
        .pwr_qacceptn      (),
        .pwr_qdeny         (),

        .awvalid           (m_axi_awvalid),
        .awready           (m_axi_awready),
        .awaddr            (m_axi_awaddr[31:0]),
        .awburst           (m_axi_awburst),
        .awid              (m_axi_awid),
        .awlen             (m_axi_awlen),
        .awsize            (m_axi_awsize),
        .awlock            (m_axi_awlock),
        .awprot            (m_axi_awprot),
        .awcache           (m_axi_awcache),

        .arvalid           (m_axi_arvalid),
        .arready           (m_axi_arready),
        .araddr            (m_axi_araddr[31:0]),
        .arburst           (m_axi_arburst),
        .arid              (m_axi_arid),
        .arlen             (m_axi_arlen),
        .arsize            (m_axi_arsize),
        .arlock            (m_axi_arlock),
        .arprot            (m_axi_arprot),
        .arcache           (m_axi_arcache),

        .wvalid            (m_axi_wvalid),
        .wready            (m_axi_wready),
        .wlast             (m_axi_wlast),
        .wstrb             (m_axi_wstrb),
        .wdata             (m_axi_wdata),

        .rvalid            (m_axi_rvalid),
        .rready            (m_axi_rready),
        .rid               (m_axi_rid),
        .rlast             (m_axi_rlast),
        .rdata             (m_axi_rdata),
        .rresp             (m_axi_rresp),

        .bvalid            (m_axi_bvalid),
        .bready            (m_axi_bready),
        .bid               (m_axi_bid),
        .bresp             (m_axi_bresp),

        .ardomain          (2'b00),
        .awdomain          (2'b00),
        .awakeup           (1'b1),
        .awnsaid           (4'h0),
        .arnsaid           (4'h0),
        .awqos             (m_axi_awqos),
        .arqos             (m_axi_arqos),
        .awregion          (4'h0),
        .arregion          (4'h0),

        .hnonsec           (),
        .haddr             (ahb_mng_haddr),
        .htrans            (ahb_mng_htrans),
        .hsize             (ahb_mng_hsize),
        .hwrite            (ahb_mng_hwrite),
        .hprot             (ahb_mng_hprot),
        .hburst            (ahb_mng_hburst),
        .hmastlock         (),
        .hwdata            (ahb_mng_hwdata),
        .hexcl             (),
        .hmaster           (),
        .hrdata            (ahb_mng_hrdata),
        .hready            (ahb_mng_hready),
        .hresp             (ahb_mng_hresp),

        .hexokay           (1'b0),
        .hwstrb            (),
        .hqos              (),
        .hregion           (),
        .hnsaid            ()
    );

    // =========================================================================
    // 5. Address Translator
    //    APB-configurable address remapping for the regular AHB bridge path
    //    Config accessed via unified APB port, region 2 (0x4000-0x5FFF)
    //
    // Interface-debug bypass: when BYPASS_ADDR_XLAT=1 the translator is
    // replaced by a pure passthrough — translated_sub_haddr = ahb_sub_haddr,
    // and the APB slave responds READY/OKAY with zero rdata.
    // =========================================================================
    generate if (BYPASS_ADDR_XLAT == 1'b0) begin : gen_addr_xlat_real
        tidelink_addr_translator #(
            .NUM_CHANNELS (1)
        ) u_addr_translator (
            .CLK               (hclk),
            .RESETn            (hresetn),

            // APB slave for address translator configuration
            .chp_adr_paddr     ({3'b000, apb_paddr[12:0]}),
            .chp_adr_psel      (apb_sel_addr_xlat),
            .chp_adr_penable   (apb_penable),
            .chp_adr_pwrite    (apb_pwrite),
            .chp_adr_pwdata    (apb_pwdata),
            .chp_adr_pstrb     (apb_pstrb),
            .chp_adr_pprot     (apb_pprot),
            .chp_adr_prdata    (adr_xlat_prdata),
            .chp_adr_pready    (adr_xlat_pready),
            .chp_adr_pslverr   (adr_xlat_pslverr),

            // Address translation: input from ahb_sub, output to XHB500
            .chp0_ahb_haddr_i  (ahb_sub_haddr),
            .chp0_ahb_haddr_o  (translated_sub_haddr),

            // Second translation port unused (tie off)
            .chp1_ahb_haddr_i  (32'h0),
            .chp1_ahb_haddr_o  ()
        );
    end else begin : gen_addr_xlat_bypass
        // Passthrough — no translation
        assign translated_sub_haddr = ahb_sub_haddr;

        // APB slave — immediate OKAY/READY, zero rdata
        assign adr_xlat_prdata  = '0;
        assign adr_xlat_pready  = 1'b1;
        assign adr_xlat_pslverr = 1'b0;
    end endgenerate

    // =========================================================================
    // 6. Chiplet Controller (Wlink with TideLink FC node)
    //    Handles link layer, flow control, CRC/ECC, and SERDES PHY
    //    Generated module: Wlink (Chisel output)
    //    Note: Wlink uses active-high resets
    // =========================================================================

    // ── Tier 2 RTL hardening: swi_enable guard + swreset block on 0x208 ──────
    // Intercept the APB pwdata flowing into u_chiplet_controller for writes
    // to Wlink register 0x208 (swi_enable[0], lltx_enable[1], lltx_enable_1[2],
    // swreset[3]).
    //
    // Behaviour:
    //   (a) Force pwdata[0]=1 — keep swi_enable HIGH across any 0x208 write
    //       so the 7 FCSMs don't get dropped to IDLE / lose CR/CRACK sticky
    //       state when SW pulses other bits in this register.
    //   (b) Force pwdata[3]=0 — block the swreset bit from ever reaching
    //       Wlink. swreset feeds app_clk_reset_scan_wrs_io_reset_in which
    //       resets axi2wl (the Wlink AXI target). If SW pulses swreset while
    //       an AHB-sub transaction is in flight at the xhb500 AHB->AXI bridge,
    //       axi2wl resets mid-burst, BVALID never returns, the PS7
    //       M_AXI_GP0 SmartConnect SI port saturates, and the whole PL slave
    //       set wedges until USB power-cycle. Blocking swreset at the
    //       hardening shim is cheap and unblocks bring-up; SW recovery of a
    //       stale LL_TX FIFO needs a different mechanism (e.g. slot0=0x3→0x1).
    //
    // Gate predicate covers (a): apb_sel_wlink && apb_pwrite && paddr==0x208
    // && pwdata[3]==1. (b) reuses the same address+direction predicate via
    // harden_swi_block_swreset (no pwdata[3] dependence — we mask whether the
    // bit is asserted or not, but the bit is W1C inside Wlink so a 0 write
    // is a no-op anyway). Address writes to other registers and reads are
    // bit-exact unchanged. HARDEN_SWI_ENABLE=0 disables both overrides.
    wire [SYS_DATA_W-1:0] apb_pwdata_to_chip;
    wire harden_swi_addr_match = apb_sel_wlink
                               & apb_pwrite
                               & (apb_paddr[12:0] == 13'h208);
    wire harden_swi_apply = HARDEN_SWI_ENABLE
                          & harden_swi_addr_match
                          & apb_pwdata[3];
    wire harden_swi_block_swreset = HARDEN_SWI_ENABLE
                                  & harden_swi_addr_match;
    // (a) OR-force bit[0]=1 when swreset bit would otherwise be set
    //     and (b) AND-mask bit[3]=0 on every write to 0x208
    wire [SYS_DATA_W-1:0] swi_enable_or_mask   = {{(SYS_DATA_W-1){1'b0}}, 1'b1};
    wire [SYS_DATA_W-1:0] swreset_clear_mask   = ~({{(SYS_DATA_W-4){1'b0}}, 1'b1, 3'b000});
    assign apb_pwdata_to_chip =
        (harden_swi_apply         ? (apb_pwdata | swi_enable_or_mask) : apb_pwdata)
        & (harden_swi_block_swreset ? swreset_clear_mask : {SYS_DATA_W{1'b1}});

    // =========================================================================
    // S2 scaffold — PHY v2 swap site (PLAN_TIDELINK_INTEGRATION §1/§5, S2→S3)
    //
    // This generate arm marks WHERE the new shared PHY component
    // (deps/tidelink-phy @ feat/phy-refactor; sources enumerated in
    // flists/tidelink_phy_v2.flist) drops in: it will replace the
    // WavD2DGpio serdes datapath that today lives INSIDE
    // u_chiplet_controller, leaving the L3 surface (role block, I2C,
    // training FSM, Wlink POR gating) untouched and driving the new L2
    // through the alignment contract (swi_*/status bundle —
    // tidelink_phy_align_if once it lands).
    //
    // S2 contract: with USE_PHY_V2=0 (the only supported value today) this
    // arm elaborates EMPTY and the build is bit-identical to pre-scaffold
    // RTL. The S3 drop-in fills g_phy_v2 with tidelink_gpio_phy_tx/rx (+
    // deskew/checker/mask stack), muxes the pad_* and link-clock
    // connections away from the controller-internal PHY, and ties the new
    // calibrator/contract surface into the existing swi_* APB plumbing.
    // =========================================================================
    if (USE_PHY_V2) begin : g_phy_v2
        // S3 drop-in site; see docs (PLAN_TIDELINK_INTEGRATION S3 / AUDIT 4b)
        // and flists/tidelink_phy_v2.flist. Intentionally empty in S2.
    end

    // SoC Labs §9 auto-cal: enable the in-RTL per-lane calibration FSM at
    // the TideLink integration level. The chiplet controller defaults to
    // 0 (disabled) so the cocotb wlink_pair sweep tests keep their
    // hierarchical-force semantics; turning it on here means every TideLink
    // build (FPGA + ASIC + UVM) runs the calibrator after role_locked rises.
    axi_chiplet_controller #(
        // Re-enabled for build #3 (Fix A2 + Fix B per
        // docs/CALIBRATOR_HW_FAILURE_AUDIT_2026_05_29.md). The
        // workaround AUTOCAL=0 (commit f2ab31c) is reverted here because
        // the audit identified the real root cause: the calibrator's
        // Step 6 (8409d6b) score predicate latched onto the lane_checker's
        // monotonic dwell_min_dist_o (no per-dwell reset) and went
        // sticky-true after dwell 1, so every (slip, phase) sweep point
        // looked like a pass and the calibrator returned iterator-reset
        // artefacts instead of a measured eye centre. Reverting that
        // predicate to lane_locked[i] (Fix A2) restores real per-dwell
        // semantics; reverting iteration to phase-INNER (Fix B) restores
        // run_len = adjacent-phase eye width. AUTOCAL=1 is needed to
        // actually exercise the calibrator on silicon and validate.
        .AUTOCAL_ENABLE(1'b1),
        // §9 structural fix: forward the IDELAYE2 enable. Default 0 keeps
        // sim/ASIC bit-exact; the FPGA vivado wrapper sets this to 1.
        .USE_IDELAY    (USE_IDELAY),
        .USE_CLKBUF    (USE_CLKBUF),
        // §9 T3a: self-aligning RX comma hunt. Default 0 sim/ASIC bit-exact.
        .USE_T3A       (USE_T3A),
        // Phase 2 autonomy — POR-default for NEGO_TRAIN_CFG. See module
        // parameter declaration for semantics.
        .NEGO_TRAIN_CFG_RESET (NEGO_TRAIN_CFG_RESET),
        .NEGO_CFG_RESET       (NEGO_CFG_RESET),
        // PENDING-DECISION #5: terminal role from strap (default 1'b0 = today).
        .ROLE_FROM_STRAP      (ROLE_FROM_STRAP),
        // Zero-poke winscan converge-lock — forwarded verbatim (default 1'b0).
        .WINSCAN_CONVERGE_LOCK_EN (WINSCAN_CONVERGE_LOCK_EN),
        // Phase 2 autonomy — RETIRE-AUTONOMY tapeout knob (F4). Forwarded so
        // the ASIC integration can gate/strap the retire WITHOUT editing the
        // controller. See the module parameter declaration for the default
        // rationale.
        .RETIRE_EN            (RETIRE_EN)
    ) u_chiplet_controller (
        .apb_clk                    (hclk),
        .app_clk                    (hclk),
        .user_hsclk                 (user_ref_clk),

        .poresetn                   (poresetn),
        .hresetn                    (hresetn),

        .sb_reset_in                (1'b0),
        .sb_reset_out               (d2d_reset_o),
        .sb_wake                    (),

        // Role configuration
        .role_strap_i               (role_strap_i),
        .role_is_master_o           (role_is_master_o),
        .role_locked_o              (role_locked_o),
        // SoC Labs 2026-06-18 — REDUCED-LANE SW-driven bring-up (autoneg off):
        // force both to 1. mask_hs_bypass opens mask_hs_gate_open so the SW
        // ROLE_CFG W1S role-lock latches WITHOUT the autoneg mask handshake
        // (else role_locked never asserts -> Wlink held in reset -> link dead).
        // apb_debug_unlock frees SW APB writes to the Wlink config (incl the
        // lane mask) on the non-master die. Bench-debug straps; revisit when
        // re-enabling autoneg for production.
        // HONEST_MASK_HS gate (from kr260-pair-onchip): default 0 folds both selects
        // to the historical 1'b1 ties => byte-identical single-die netlist. With 1 they
        // drive from the real module ports (:362-363, previously DEAD) so mask_hs_gate_open
        // = mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i is no longer forced open
        // and the peer-mask handshake must genuinely match.
        .apb_debug_unlock_i         (HONEST_MASK_HS ? apb_debug_unlock_i : 1'b1),
        .mask_hs_bypass_i           (HONEST_MASK_HS ? mask_hs_bypass_i   : 1'b1),
        .nego_priority_i            (nego_priority_i),
        .puf_seed                   (puf_seed),
        .puf_ready                  (puf_ready),
        .nego_error_irq             (nego_error_irq),
        // Phase 1 autonomy G1b — sticky train-fail IRQ (W1C @ slot 3'h3 bit[16])
        .train_fail_irq_o           (train_fail_irq),

        // Controller register pass-through (from APB regs Region 4)
        // Bug N2 fix: input ports renamed to apb_ctrl_reg_* on the chiplet
        // controller side so a parallel I²C-driven (slv_apb_*) path can
        // OR-merge inside it. ctrl_reg_rdata stays as-is (combinational
        // mux output for both external APB and slv_apb readbacks).
        .apb_ctrl_reg_write         (ctrl_reg_write),
        .apb_ctrl_reg_addr          (ctrl_reg_addr),
        .apb_ctrl_reg_r10           (ctrl_reg_r10),   // perlane-wp Region-10 select
        .apb_ctrl_reg_rd            (ctrl_reg_rd),    // rxcap Region-D select
        .apb_ctrl_reg_wdata         (ctrl_reg_wdata),
        .ctrl_reg_rdata             (ctrl_reg_rdata),

        // APB control interface (from unified APB port, Wlink region)
        .apb_psel                   (apb_sel_wlink),
        .apb_paddr                  (apb_paddr[12:0]),
        .apb_penable                (apb_penable),
        .apb_pprot                  (apb_pprot),
        .apb_pstrb                  (apb_pstrb),
        .apb_pwrite                 (apb_pwrite),
        // Tier 2 hardening: swi_enable forced HIGH on swreset writes
        .apb_pwdata                 (apb_pwdata_to_chip),
        .apb_prdata                 (wlink_prdata),
        .apb_pready                 (wlink_pready),
        .apb_pslverr                (wlink_pslverr),

        // AXI target (from XHB500 AHB→AXI bridge)
        .axi_tgt_0_aw_valid         (s_axi_awvalid),
        .axi_tgt_0_aw_ready         (s_axi_awready),
        .axi_tgt_0_aw_bits_id       (s_axi_awid),
        .axi_tgt_0_aw_bits_addr     (s_axi_awaddr),
        .axi_tgt_0_aw_bits_len      (s_axi_awlen),
        .axi_tgt_0_aw_bits_size     (s_axi_awsize),
        .axi_tgt_0_aw_bits_burst    (s_axi_awburst),
        .axi_tgt_0_aw_bits_lock     (s_axi_awlock),
        .axi_tgt_0_aw_bits_cache    (s_axi_awcache),
        .axi_tgt_0_aw_bits_prot     (s_axi_awprot),
        .axi_tgt_0_aw_bits_qos      (s_axi_awqos),

        .axi_tgt_0_w_valid          (s_axi_wvalid),
        .axi_tgt_0_w_ready          (s_axi_wready),
        .axi_tgt_0_w_bits_data      (s_axi_wdata),
        .axi_tgt_0_w_bits_strb      (s_axi_wstrb),
        .axi_tgt_0_w_bits_last      (s_axi_wlast),

        .axi_tgt_0_b_valid          (s_axi_bvalid),
        .axi_tgt_0_b_ready          (s_axi_bready),
        .axi_tgt_0_b_bits_id        (s_axi_bid),
        .axi_tgt_0_b_bits_resp      (s_axi_bresp),

        .axi_tgt_0_ar_valid         (s_axi_arvalid),
        .axi_tgt_0_ar_ready         (s_axi_arready),
        .axi_tgt_0_ar_bits_id       (s_axi_arid),
        .axi_tgt_0_ar_bits_addr     (s_axi_araddr),
        .axi_tgt_0_ar_bits_len      (s_axi_arlen),
        .axi_tgt_0_ar_bits_size     (s_axi_arsize),
        .axi_tgt_0_ar_bits_burst    (s_axi_arburst),
        .axi_tgt_0_ar_bits_lock     (s_axi_arlock),
        .axi_tgt_0_ar_bits_cache    (s_axi_arcache),
        .axi_tgt_0_ar_bits_prot     (s_axi_arprot),
        .axi_tgt_0_ar_bits_qos      (s_axi_arqos),

        .axi_tgt_0_r_valid          (s_axi_rvalid),
        .axi_tgt_0_r_ready          (s_axi_rready),
        .axi_tgt_0_r_bits_id        (s_axi_rid),
        .axi_tgt_0_r_bits_data      (s_axi_rdata),
        .axi_tgt_0_r_bits_resp      (s_axi_rresp),
        .axi_tgt_0_r_bits_last      (s_axi_rlast),

        // AXI initiator (to XHB500 AXI→AHB bridge)
        .axi_ini_0_aw_valid         (m_axi_awvalid),
        .axi_ini_0_aw_ready         (m_axi_awready),
        .axi_ini_0_aw_bits_id       (m_axi_awid),
        .axi_ini_0_aw_bits_addr     (m_axi_awaddr),
        .axi_ini_0_aw_bits_len      (m_axi_awlen),
        .axi_ini_0_aw_bits_size     (m_axi_awsize),
        .axi_ini_0_aw_bits_burst    (m_axi_awburst),
        .axi_ini_0_aw_bits_lock     (m_axi_awlock),
        .axi_ini_0_aw_bits_cache    (m_axi_awcache),
        .axi_ini_0_aw_bits_prot     (m_axi_awprot),
        .axi_ini_0_aw_bits_qos      (m_axi_awqos),

        .axi_ini_0_w_valid          (m_axi_wvalid),
        .axi_ini_0_w_ready          (m_axi_wready),
        .axi_ini_0_w_bits_data      (m_axi_wdata),
        .axi_ini_0_w_bits_strb      (m_axi_wstrb),
        .axi_ini_0_w_bits_last      (m_axi_wlast),

        .axi_ini_0_b_valid          (m_axi_bvalid),
        .axi_ini_0_b_ready          (m_axi_bready),
        .axi_ini_0_b_bits_id        (m_axi_bid),
        .axi_ini_0_b_bits_resp      (m_axi_bresp),

        .axi_ini_0_ar_valid         (m_axi_arvalid),
        .axi_ini_0_ar_ready         (m_axi_arready),
        .axi_ini_0_ar_bits_id       (m_axi_arid),
        .axi_ini_0_ar_bits_addr     (m_axi_araddr),
        .axi_ini_0_ar_bits_len      (m_axi_arlen),
        .axi_ini_0_ar_bits_size     (m_axi_arsize),
        .axi_ini_0_ar_bits_burst    (m_axi_arburst),
        .axi_ini_0_ar_bits_lock     (m_axi_arlock),
        .axi_ini_0_ar_bits_cache    (m_axi_arcache),
        .axi_ini_0_ar_bits_prot     (m_axi_arprot),
        .axi_ini_0_ar_bits_qos      (m_axi_arqos),

        .axi_ini_0_r_valid          (m_axi_rvalid),
        .axi_ini_0_r_ready          (m_axi_rready),
        .axi_ini_0_r_bits_id        (m_axi_rid),
        .axi_ini_0_r_bits_data      (m_axi_rdata),
        .axi_ini_0_r_bits_resp      (m_axi_rresp),
        .axi_ini_0_r_bits_last      (m_axi_rlast),

        // General bus FC node (legacy cross-chiplet interrupt forwarding):
        // tied off at the TideLink boundary. Cross-chiplet interrupts now
        // go through the dedicated ahb-chiplet-interrupt-controller IP
        // (Wlink FC data_id = 0xa3). The Wlink GeneralBus node remains in
        // the axi_chiplet_controller RTL but is unused from here.
        .generalbus_in              (32'h0),
        .generalbus_out             (/* unused */),

        // TideLink FC node (packed bus, 50-bit = 48-bit data + 2 control)
        .tidelink_in                ({tl_fc_a2l_valid, tl_fc_a2l_data, tl_fc_l2a_accept}),
        .tidelink_out               ({tl_fc_a2l_ready, tl_fc_l2a_valid, tl_fc_l2a_data}),

        // PTP Short Packet port (26-bit packed bus)
        .ptp_in                     ({ptp_sp_tx_valid, ptp_sp_tx_data_id, ptp_sp_tx_payload, ptp_sp_rx_accept}),
        .ptp_out                    ({ptp_sp_tx_ready, ptp_sp_rx_valid, ptp_sp_rx_data_id, ptp_sp_rx_payload}),

        // TX link idle (for PTP jitter-free timestamp capture)
        .tx_link_idle               (tx_router_idle),

        // I2C Sideband AXI (master mode: CPU → I2C master → remote)
        .s_i2c_axi_awvalid          (s_i2c_axi_awvalid),
        .s_i2c_axi_awid             (s_i2c_axi_awid),
        .s_i2c_axi_awaddr           (s_i2c_axi_awaddr),
        .s_i2c_axi_awlen            (s_i2c_axi_awlen),
        .s_i2c_axi_awsize           (s_i2c_axi_awsize),
        .s_i2c_axi_awburst          (s_i2c_axi_awburst),
        .s_i2c_axi_awlock           (s_i2c_axi_awlock),
        .s_i2c_axi_awcache          (s_i2c_axi_awcache),
        .s_i2c_axi_awprot           (s_i2c_axi_awprot),
        .s_i2c_axi_awready          (s_i2c_axi_awready),
        .s_i2c_axi_wvalid           (s_i2c_axi_wvalid),
        .s_i2c_axi_wdata            (s_i2c_axi_wdata),
        .s_i2c_axi_wstrb            (s_i2c_axi_wstrb),
        .s_i2c_axi_wlast            (s_i2c_axi_wlast),
        .s_i2c_axi_wready           (s_i2c_axi_wready),
        .s_i2c_axi_bvalid           (s_i2c_axi_bvalid),
        .s_i2c_axi_bid              (s_i2c_axi_bid),
        .s_i2c_axi_bresp            (s_i2c_axi_bresp),
        .s_i2c_axi_bready           (s_i2c_axi_bready),
        .s_i2c_axi_arvalid          (s_i2c_axi_arvalid),
        .s_i2c_axi_arid             (s_i2c_axi_arid),
        .s_i2c_axi_araddr           (s_i2c_axi_araddr),
        .s_i2c_axi_arlen            (s_i2c_axi_arlen),
        .s_i2c_axi_arsize           (s_i2c_axi_arsize),
        .s_i2c_axi_arburst          (s_i2c_axi_arburst),
        .s_i2c_axi_arlock           (s_i2c_axi_arlock),
        .s_i2c_axi_arcache          (s_i2c_axi_arcache),
        .s_i2c_axi_arprot           (s_i2c_axi_arprot),
        .s_i2c_axi_arready          (s_i2c_axi_arready),
        .s_i2c_axi_rvalid           (s_i2c_axi_rvalid),
        .s_i2c_axi_rid              (s_i2c_axi_rid),
        .s_i2c_axi_rdata            (s_i2c_axi_rdata),
        .s_i2c_axi_rresp            (s_i2c_axi_rresp),
        .s_i2c_axi_rlast            (s_i2c_axi_rlast),
        .s_i2c_axi_rready           (s_i2c_axi_rready),

        // I2C interrupts
        .i2c_nbsy_irq               (i2c_nbsy_irq),
        .i2c_nrd_empty_irq          (i2c_nrd_empty_irq),

        // I2C pins (tristate)
        .i2c_scl_i                  (i2c_scl_i),
        .i2c_scl_o                  (i2c_scl_o),
        .i2c_scl_t                  (i2c_scl_t),
        .i2c_sda_i                  (i2c_sda_i),
        .i2c_sda_o                  (i2c_sda_o),
        .i2c_sda_t                  (i2c_sda_t),

        // Scan / DFT
        .scan_mode                  (scan_mode),
        .scan_asyncrst_ctrl         (scan_asyncrst_ctrl),
        .scan_clk                   (scan_clk),
        .scan_shift                 (scan_shift),
        .scan_in                    (scan_in),
        .scan_out                   (scan_out),

        // Interrupts
        .interrupt                  (wlink_irq),

        // PHY pads
        .pad_clk_tx                 (pad_clk_tx),
        .pad_tx                     (pad_tx),
        .pad_clk_rx                 (pad_clk_rx),
        .pad_rx                     (pad_rx),

        // §9 IDELAYE2 RX delay: 200 MHz ref clock + active-high reset
        // (derived from poresetn). Unused inside the controller when
        // USE_IDELAY=0 (pure passthrough).
        .idelay_ref_clk             (idelay_ref_clk),
        .idelay_rst                 (~poresetn),

        // v2 Eye visibility — driven by u_eye_regs shim at this scope.
        .swi_eye_lane_sel_i         (eye_swi_lane_sel_w),
        .swi_eye_dwell_us_i         (eye_swi_dwell_us_w),
        .swi_eye_ctrl_i             (eye_swi_ctrl_w),
        .eye_score_idx_i            (eye_score_idx_w),
        .eye_status_o               (eye_status_w),
        .eye_score_data_o           (eye_score_data_w),
        .eye_score_lane_passed_o    (eye_score_lane_passed_w),
        .eye_score_best_o           (eye_score_best_w),
        .eye_score_best_slip_o      (eye_score_best_slip_w),
        .eye_score_best_phase_o     (eye_score_best_phase_w),
        // tidelink-gpio-phy lane_checker observability bus (replaces the
        // legacy per-lane crc_err_cnt counters; see deps/axi-chiplet-controller
        // @68d625d and deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md §6).
        // Control inputs (lane_lock_thresh_i, lane_clear_noise_i) are driven
        // by the new tidelink_gpio_phy_apb_regs slave above; the 13
        // observability outputs are consumed by that slave (noise/wire/canary
        // fields) and by downstream calibrator/eye-toolkit logic (mismatch
        // pulse, dwell-min distance).
        .lane_lock_thresh_i         (lane_lock_thresh_w),
        .lane_clear_noise_i         (lane_clear_noise_w),
        .lane_mismatch_pulse_o      (lane_mismatch_pulse_w),
        .lane_wire_status_o         (lane_wire_status_w),
        .lane_dist_raw_o            (lane_dist_raw_w),
        .lane_dist_voted_o          (lane_dist_voted_w),
        .lane_dwell_min_dist_o      (lane_dwell_min_dist_w),
        .lane_noise_min_o           (lane_noise_min_w),
        .lane_noise_max_o           (lane_noise_max_w),
        .lane_noise_mean_o          (lane_noise_mean_w),
        .lane_noise_current_o       (lane_noise_current_w),
        .lane_canary_pass_o         (lane_canary_pass_w),
        .lane_canary_valid_o        (lane_canary_valid_w),
        // Recovered RX clock — fed to the gpio_phy_apb_regs slave's
        // link_rx_clk port (deps/axi-chiplet-controller@3e0e711).
        .link_rx_clk_o              (gpio_phy_link_rx_clk_w),
        .eye_last_slip_o            (eye_last_slip_w),
        .eye_last_lane_fault_o      (eye_last_lane_fault_w),
        // SoC Labs Bug-A FCSM observation 2026-06-02 — wire to top-level
        // probes with mark_debug; the IP-internal mark_debug is stripped by
        // packaging, but tidelink_top is the OUTER scope (FPGA wrapper)
        // where probes survive (see fc_rx_fifo_wdata pattern).
        .obs_a2l_replay_link_valid_o (obs_a2l_replay_link_valid_w),
        .obs_fe_rx_credit_max_o      (obs_fe_rx_credit_max_w),
        .obs_fe_rx_is_full_o         (obs_fe_rx_is_full_w),
        // SoC Labs Bug-A FCSM observation 2026-06-03
        .obs_a2l_replay_app_valid_o  (obs_a2l_replay_app_valid_w)
`ifdef TIDELINK_PHY_V2
        // SoC Labs V2 epoch-anchor obs 2026-06-14 — engagement state out to the
        // tidelink_gpio_phy_apb_regs slave (SWI_EPOCH_STATUS @ 0x4403_2140).
        ,
        .obs_epoch_anchored_o        (gpio_phy_epoch_anchored_w),
        .obs_epoch_span_o            (gpio_phy_epoch_span_w)
`endif
    );

    // =========================================================================
    // Link active status — role_locked_o indicates Wlink link is operational
    // =========================================================================
    assign link_active = role_locked_o;

endmodule
