//-----------------------------------------------------------------------------
// SoCLabs TideLink — DFT Wrapper (SKELETON)
//
// Purpose:
//   Pre-position the integrated chiplet top (`tidelink_top`) for the ASIC
//   DFT flow. This wrapper exposes the test-mode signals (scan, BIST,
//   optional TAP) at a single boundary so the DFT tool (TestMAX / Tessent)
//   can identify them and the SDC can constrain them uniformly.
//
//   This is a SKELETON. It intentionally does not implement BIST itself
//   nor a TAP controller — both are closure tasks documented in
//   docs/DFT_PLAN_2026_05_28.md §4 and §5.
//
//   The wrapper:
//     - Adds a multi-bit scan-chain bus (8 chains by default, configurable)
//       running alongside the legacy 1-bit `scan_in`/`scan_out` stub
//       inherited from Wlink's `axi_chiplet_controller`. The 1-bit stub
//       remains wired so existing flows (LEC pin-down) continue to work
//       until the closure pass rationalises the two schemes.
//     - Adds a `test_mode` qualifier separate from `scan_en` (== shift)
//       so MBIST and TAP can each indicate their own active state without
//       colliding with ATPG shift mode.
//     - Adds MBIST control / status ports (`mbist_en`, `mbist_done`,
//       `mbist_pass`). The BIST controller is NOT instantiated here;
//       wrapper just tunnels the ports to where they will be wired in
//       the closure pass.
//     - Optional JTAG TAP pads gated by parameter `INCLUDE_TAP` (default 0).
//
//   Where the DFT tool will operate:
//     - The tool replaces functional flops inside `u_top` with mux-D scan
//       cells, configured to use `scan_en` as the shift select and
//       `scan_clk` (in test mode) as the shift clock. None of that
//       replacement happens at the RTL level — this file pre-positions
//       only the boundary signals.
//     - 2-FF synchronisers inside `u_top` get `set_dont_scan` per
//       `syn/asic/dft/insert_scan.tcl` stage 3.
//
//   Read DFT_PLAN §6 for the per-signal contract.
//
// References:
//   - docs/DFT_PLAN_2026_05_28.md
//   - docs/ASIC_READINESS_TEST_GAP_ANALYSIS_2026_05_28.md §2.5
//   - src/rtl/tidelink_top.sv (the wrapped DUT)
//   - syn/asic/formality/scripts/run_lec.tcl:259-275 (scan-pin pin-down)
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

module tidelink_dft_wrapper #(
    // ---- pass-through to tidelink_top -----------------------------------
    parameter SYS_ADDR_W        = 32,
    parameter SYS_DATA_W        = 32,
    parameter RAM_ADDR_W        = 14,
    parameter RAM_DATA_W        = 32,
    parameter APB_ADDR_W        = 12,
    parameter FC_DATA_W         = 48,
    parameter NUM_PHY_LANES     = 8,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0,
    parameter PHC_LOCK_GATE_EN  = 0,
    parameter USE_IDELAY        = 1'b0,
    parameter USE_CLKBUF        = 1'b0,
    parameter USE_T3A           = 1'b0,
    parameter HARDEN_SWI_ENABLE = 1'b1,
    // HONEST_MASK_HS — peer-mask-handshake authenticity gate. MUST be forwarded:
    // tidelink_top defaults it to 1'b0, and at tidelink_top.sv:2270-2271 a 0
    // makes it DISCARD the apb_debug_unlock_i / mask_hs_bypass_i port values and
    // substitute 1'b1. This wrapper declares those pins (:239-240) and wires them
    // (:613-614), so the ASIC LOOKS strapped while the straps are dead silicon and
    // mask_hs_gate_open (= mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i)
    // is permanently forced open — i.e. APB debug permanently unlocked in the chip.
    // The parameter was simply absent from the instantiation below; that omission
    // is invisible to the asic_v*_elab gates, which elaborate only.
    //
    // Default stays 1'b0 so this commit is behaviourally bit-identical. Setting it
    // to 1'b1 is a deliberate TAPEOUT DECISION, and it has a prerequisite:
    // mask_hs_match = wlink_mask_hs_result[0] | autoneg_mask_hs_local_match
    // (axi_chiplet_controller.sv:642), and Wlink.v:433 hard-ties
    // mask_hs_result_o = 2'b00 — so with HONEST_MASK_HS=1 the gate can ONLY be
    // opened by the I2C autoneg local-match path or by a real strap. Verify that
    // path (or drive the straps) BEFORE flipping this, or the gate latches shut.
    //
    // PENDING (DECISION #2, David 2026-07-19) — SPLIT PREPARED, NOT APPLIED.
    // HONEST_MASK_HS used to fold BOTH selects, so 1'b0 ("ship debug unlocked")
    // ALSO permanently bypassed the peer-mask handshake. DEBUG_UNLOCK_DEFAULT
    // below separates them. Defaults are unchanged and byte-identical.
    parameter HONEST_MASK_HS    = 1'b1,
    // PENDING (DECISION #2) — APB debug-unlock, independent of HONEST_MASK_HS.
    //   1'b1 (default) = today's behaviour: APB debug permanently unlocked.
    //   1'b0 = controller follows the real apb_debug_unlock_i pin (lockable).
    // HONEST_MASK_HS=1'b1 with this left at 1'b1 gives an honest handshake with
    // debug still unlocked — previously unreachable.
    parameter DEBUG_UNLOCK_DEFAULT = 1'b1,
    // S2 scaffold: PHY v2 select pass-through (default 0 = bit-identical;
    // see tidelink_top parameter declaration for semantics).
    parameter logic USE_PHY_V2  = 1'b0,
    // F4 (2026-07-15): RETIRE-AUTONOMY enable pass-through. Forwards to
    // tidelink_top.RETIRE_EN → axi_chiplet_controller.RETIRE_EN. Default 1'b1
    // mirrors tidelink_top's default, so this is bit-identical to the pre-F4
    // elaboration — it exposes the knob WITHOUT changing behaviour.
    //
    // This wrapper is the ASIC integration face, so it is the level at which
    // the tapeout owner makes the conscious RETIRE choice the handover rule
    // demands: override to 1'b0, or bind to a bond-strap input, at the SoC top.
    // NOTE: as of this commit the ASIC path is INERT either way — this wrapper
    // does not forward NEGO_CFG_RESET, so tidelink_top's safe 7'h00 default
    // applies, nego_en=0, and the retire (gated on nego_en & role_locked &
    // train_auto_en) can never fire. RETIRE_EN only becomes live once the ASIC
    // straps autonomy on; the knob is plumbed now so that choice is available
    // at that point rather than requiring an axi_chiplet_controller edit.
    parameter RETIRE_EN         = 1'b1,
    // ASIC zero-poke autonomy default. Forwarded verbatim to
    // tidelink_top.NEGO_CFG_RESET → axi_chiplet_controller.NEGO_CFG_RESET,
    // which is the POR value of nego_cfg_reg (nego_en = bit[0]).
    //
    // DECISION (David, 2026-07-19): the ASIC integration ships 7'h61 —
    // zero-poke autonomy ON from POR (nego_en=1, force_lock=1,
    // mask_hs_auto_en=1), the mandated hardware-autonomy posture.
    //
    // THIS VALUE IS SET HERE, at the ASIC integration, and deliberately NOT by
    // changing tidelink_top's 7'h00 default: the FPGA takes its value from its
    // own wrapper (fpga/vivado_ip/tidelink_vivado_wrapper.v), and moving the
    // shared default would surprise other integrations.
    //
    // History: the wrapper previously did NOT forward NEGO_CFG_RESET at all, so
    // the ASIC path silently took tidelink_top's 7'h00 and zero-poke could
    // NEVER fire on the ASIC — the NEGO_CFG_RESET-silently-0x00 failure class.
    // A pass-through is not enough; the value must ARRIVE at the controller,
    // which is what cocotb/asic_nego_cfg_plumb proves by hierarchical readback.
    //   7'h00 = autonomy OFF, SW-driven (the legacy/safe posture).
    parameter [6:0] NEGO_CFG_RESET = 7'h61,
    // Terminal role from strap. Forwarded to tidelink_top.ROLE_FROM_STRAP.
    // DECISION (David, 2026-07-19): default 1'b1 — the I2C-NACK / timeout
    // terminal role derives from role_strap_i (a real top-level port), so a
    // dead I2C no longer forces both dies slave and autonomy stays reachable.
    // NOTE: this wrapper passes the param down explicitly, so its default (not
    // tidelink_top's) is what the ASIC gets — both are 1'b1.
    parameter bit ROLE_FROM_STRAP = 1'b1,
    // RX-FIFO TWIN 2 master enable. Forwarded verbatim to
    // tidelink_top.ENABLE_AHB_WRITE.
    // DECISION (David, 2026-07-19): AHB-CPU-write-to-RX IS SUPPORTED, so the
    // ASIC keeps this at 1'b1 (path FUNCTIONAL). TWIN 2 is closed in
    // tidelink_fifo_ctrl by QUALIFYING the write-side arm, not by this gate.
    parameter bit ENABLE_AHB_WRITE = 1'b1,

    // ---- DFT-specific ---------------------------------------------------
    // Number of mux-D scan chains exposed at this wrapper. 8 is the
    // default per DFT_PLAN §3.2. Set to 1 for pre-synth elaboration sanity.
    parameter SCAN_CHAINS = 8,

    // Include a vanilla 1149.1-2013 TAP controller. Default 0 (deferred
    // for v1 per DFT_PLAN §5). When 1, the wrapper exposes JTAG pads but
    // does not instantiate boundary cells — closure task.
    parameter INCLUDE_TAP = 0
)(
    // =========================================================================
    // Functional ports — all pass through unchanged to u_top
    // =========================================================================
    // Clock / reset
    input  wire                          hclk,
    input  wire                          hresetn,
    input  wire                          poresetn,
    input  wire                          phc_clk,
    input  wire                          phc_resetn,

    // AHB subordinate — regular access to remote
    input  wire                          ahb_sub_hsel,
    input  wire  [SYS_ADDR_W-1:0]        ahb_sub_haddr,
    input  wire                    [2:0] ahb_sub_hburst,
    input  wire                    [3:0] ahb_sub_hprot,
    input  wire                    [2:0] ahb_sub_hsize,
    input  wire                    [1:0] ahb_sub_htrans,
    input  wire  [SYS_DATA_W-1:0]        ahb_sub_hwdata,
    input  wire                          ahb_sub_hwrite,
    input  wire                          ahb_sub_hready,
    output wire  [SYS_DATA_W-1:0]        ahb_sub_hrdata,
    output wire                          ahb_sub_hresp,
    output wire                          ahb_sub_hreadyout,

    // AHB TX aperture
    input  wire                          ahb_tx_hsel,
    input  wire  [RAM_ADDR_W-1:0]        ahb_tx_haddr,
    input  wire                    [1:0] ahb_tx_htrans,
    input  wire                    [2:0] ahb_tx_hsize,
    input  wire                          ahb_tx_hwrite,
    input  wire  [SYS_DATA_W-1:0]        ahb_tx_hwdata,
    input  wire                          ahb_tx_hready,
    output wire  [SYS_DATA_W-1:0]        ahb_tx_hrdata,
    output wire                          ahb_tx_hresp,
    output wire                          ahb_tx_hreadyout,

    // AHB RX FIFO window
    input  wire                          ahb_fifo_hsel,
    input  wire  [RAM_ADDR_W-1:0]        ahb_fifo_haddr,
    input  wire                    [1:0] ahb_fifo_htrans,
    input  wire                    [2:0] ahb_fifo_hsize,
    input  wire                          ahb_fifo_hwrite,
    input  wire  [SYS_DATA_W-1:0]        ahb_fifo_hwdata,
    input  wire                          ahb_fifo_hready,
    output wire  [SYS_DATA_W-1:0]        ahb_fifo_hrdata,
    output wire                          ahb_fifo_hresp,
    output wire                          ahb_fifo_hreadyout,

    // AHB manager
    output wire  [SYS_ADDR_W-1:0]        ahb_mng_haddr,
    output wire                    [2:0] ahb_mng_hburst,
    output wire                    [6:0] ahb_mng_hprot,
    output wire                    [2:0] ahb_mng_hsize,
    output wire                    [1:0] ahb_mng_htrans,
    output wire  [SYS_DATA_W-1:0]        ahb_mng_hwdata,
    output wire                          ahb_mng_hwrite,
    input  wire                          ahb_mng_hready,
    input  wire  [SYS_DATA_W-1:0]        ahb_mng_hrdata,
    input  wire                          ahb_mng_hresp,

    // APB unified
    input  wire                   [14:0] apb_paddr,
    input  wire                          apb_penable,
    input  wire                          apb_pwrite,
    input  wire                    [3:0] apb_pstrb,
    input  wire                    [2:0] apb_pprot,
    input  wire  [SYS_DATA_W-1:0]        apb_pwdata,
    input  wire                          apb_psel,
    output wire  [SYS_DATA_W-1:0]        apb_prdata,
    output wire                          apb_pready,
    output wire                          apb_pslverr,

    // Wlink reference clock
    input  wire                          user_ref_clk,

    // PHY pads
    output wire                          pad_clk_tx,
    output wire  [NUM_PHY_LANES-1:0]     pad_tx,
    input  wire                          pad_clk_rx,
    input  wire  [NUM_PHY_LANES-1:0]     pad_rx,
    input  wire                          idelay_ref_clk,

    // AHB PTP TX
    input  wire                          ahb_ptp_hsel,
    input  wire                    [3:0] ahb_ptp_haddr,
    input  wire                    [1:0] ahb_ptp_htrans,
    input  wire                    [2:0] ahb_ptp_hsize,
    input  wire                          ahb_ptp_hwrite,
    input  wire  [SYS_DATA_W-1:0]        ahb_ptp_hwdata,
    input  wire                          ahb_ptp_hready,
    output wire  [SYS_DATA_W-1:0]        ahb_ptp_hrdata,
    output wire                          ahb_ptp_hresp,
    output wire                          ahb_ptp_hreadyout,

    // PHC
    output wire                          phc_hw_capture,
    input  wire                   [29:0] phc_nanoseconds,
    input  wire                   [47:0] phc_seconds,
    input  wire                          phc_pps,
    input  wire                   [47:0] phc_hw_cap_seconds,
    input  wire                   [29:0] phc_hw_cap_nanoseconds,
    input  wire  [SYS_DATA_W-1:0]        phc_hw_cap_sub_nanoseconds,
    output wire                          phc_hw_set_time,
    output wire                   [47:0] phc_hw_set_seconds,
    output wire                   [29:0] phc_hw_set_nanoseconds,
    output wire                          phc_hw_adj_valid,
    output wire  [SYS_DATA_W-1:0]        phc_hw_adj_ns_incr_frac,
    input  wire                          phc_locked_i,
    output wire                          servo_locked,

    // IRQs
    output wire                          released_credits_irq,
    output wire                          doorbell_irq,
    output wire                          packet_committed_irq,
    output wire                          ptp_irq,
    output wire                          perf_irq,
    output wire                          wlink_irq,

    // TideChart AXIS
    input  wire                          tc_axis_tx_tvalid,
    input  wire  [FC_DATA_W-1:0]         tc_axis_tx_tdata,
    output wire                          tc_axis_tx_tready,
    output wire                          tc_axis_rx_tvalid,
    output wire  [FC_DATA_W-1:0]         tc_axis_rx_tdata,
    input  wire                          tc_axis_rx_tready,
    input  wire                    [2:0] tc_qos_priority,

    // Congestion sideband
    output wire                    [4:0] tl_local_link_state_o,
    output wire                          tl_link_state_change_o,
    output wire                   [12:0] tl_ewma_credit_o,
    input  wire                          tl_bcast_ack_i,

    // Link status / reset / role
    output wire                          link_active,
    // Data-mode strobe (Wlink FCSM in its operational region, state >= 4 ==
    // "the link carries FC/EXT words"). Forwarded verbatim from tidelink_top.
    // TideChart's root election MUST be gated on this, NOT on link_active:
    // link_active == role_locked and asserts ~25us earlier, before a CLAIM can
    // cross the die boundary, which silently dual-roots a 2-chiplet fabric.
    // See docs/TIDECHART_G1_SEQUENCING_CONTRACT.md (finding G1).
    output wire                          tl_data_mode_o,
    output wire                          d2d_reset_o,
    input  wire                          role_strap_i,
    output wire                          role_is_master_o,
    output wire                          role_locked_o,
    input  wire                          apb_debug_unlock_i,
    input  wire                          mask_hs_bypass_i,

    // Autoneg
    input  wire                   [15:0] nego_priority_i,
    input  wire                   [15:0] puf_seed,
    input  wire                          puf_ready,
    output wire                          nego_error_irq,

    // I2C
    input  wire                          i2c_scl_i,
    output wire                          i2c_scl_o,
    output wire                          i2c_scl_t,
    input  wire                          i2c_sda_i,
    output wire                          i2c_sda_o,
    output wire                          i2c_sda_t,

    // I2C AXI (master)
    input  wire                          s_i2c_axi_awvalid,
    input  wire                    [1:0] s_i2c_axi_awid,
    input  wire                    [3:0] s_i2c_axi_awaddr,
    input  wire                    [7:0] s_i2c_axi_awlen,
    input  wire                    [2:0] s_i2c_axi_awsize,
    input  wire                    [1:0] s_i2c_axi_awburst,
    input  wire                          s_i2c_axi_awlock,
    input  wire                    [3:0] s_i2c_axi_awcache,
    input  wire                    [2:0] s_i2c_axi_awprot,
    output wire                          s_i2c_axi_awready,
    input  wire                          s_i2c_axi_wvalid,
    input  wire  [SYS_DATA_W-1:0]        s_i2c_axi_wdata,
    input  wire                    [3:0] s_i2c_axi_wstrb,
    input  wire                          s_i2c_axi_wlast,
    output wire                          s_i2c_axi_wready,
    output wire                          s_i2c_axi_bvalid,
    output wire                    [1:0] s_i2c_axi_bid,
    output wire                    [1:0] s_i2c_axi_bresp,
    input  wire                          s_i2c_axi_bready,
    input  wire                          s_i2c_axi_arvalid,
    input  wire                    [1:0] s_i2c_axi_arid,
    input  wire                    [3:0] s_i2c_axi_araddr,
    input  wire                    [7:0] s_i2c_axi_arlen,
    input  wire                    [2:0] s_i2c_axi_arsize,
    input  wire                    [1:0] s_i2c_axi_arburst,
    input  wire                          s_i2c_axi_arlock,
    input  wire                    [3:0] s_i2c_axi_arcache,
    input  wire                    [2:0] s_i2c_axi_arprot,
    output wire                          s_i2c_axi_arready,
    output wire                          s_i2c_axi_rvalid,
    output wire                    [1:0] s_i2c_axi_rid,
    output wire  [SYS_DATA_W-1:0]        s_i2c_axi_rdata,
    output wire                    [1:0] s_i2c_axi_rresp,
    output wire                          s_i2c_axi_rlast,
    input  wire                          s_i2c_axi_rready,

    // I2C IRQs
    output wire                          i2c_nbsy_irq,
    output wire                          i2c_nrd_empty_irq,

    // =========================================================================
    // DFT ports — NEW at this wrapper boundary
    // =========================================================================

    // Global test-mode qualifier. Distinct from scan_en (== shift) so
    // MBIST and TAP can each indicate active without driving ATPG shift.
    //   0 = functional
    //   1 = any test mode (ATPG, MBIST, TAP)
    input  wire                          test_mode,

    // Scan-shift enable (active-high per DFT_PLAN §3.3)
    input  wire                          scan_en,

    // Test clock for scan-shift. SDC-constrained as an independent
    // create_clock — see DFT_PLAN §3.4. During functional mode the
    // tool gates this through `test_mode | scan_en` so the clock tree
    // is dormant.
    input  wire                          scan_clk,

    // Multi-chain scan bus. Width controlled by SCAN_CHAINS parameter.
    // The DFT tool inserts the chains internally; these are the
    // top-level head / tail anchors.
    input  wire  [SCAN_CHAINS-1:0]       scan_in,
    output wire  [SCAN_CHAINS-1:0]       scan_out,

    // Hold async resets de-asserted during shift. Already present in
    // u_top as `scan_asyncrst_ctrl` — wrapper just forwards.
    input  wire                          scan_asyncrst_ctrl,

    // MBIST control / status (APB-visible status block lives in the
    // closure RTL, not in this skeleton).
    input  wire                          mbist_en,
    output wire                          mbist_done,
    output wire                          mbist_pass,

    // JTAG TAP pads. Tied off when INCLUDE_TAP=0.
    input  wire                          tap_tck,
    input  wire                          tap_tms,
    input  wire                          tap_tdi,
    output wire                          tap_tdo,
    input  wire                          tap_trstn
);

    // -------------------------------------------------------------------------
    // INTERNAL: scan-chain tunnelling
    //
    // The DFT tool will replace functional flops inside u_top with mux-D
    // scan cells, then stitch them into the `scan_in[]` / `scan_out[]`
    // chains exposed at the wrapper boundary. No RTL is needed for that
    // (the tool does it post-synth). For now, we pass head/tail through
    // to placeholders so the elaborator is happy.
    //
    // Chain 0 also feeds the legacy 1-bit `scan_in` port that u_top
    // already has. The closure pass collapses these to a single scheme.
    // -------------------------------------------------------------------------

    // Tap chain[0] for the legacy 1-bit stub.
    wire legacy_scan_in  = scan_in[0];
    wire legacy_scan_out;

    // Pre-stitch placeholders. The tool replaces these with the actual
    // first/last scan flops of each chain. Until then, simply forward
    // each chain head to its tail so the elaborator does not flag
    // undriven ports. This is observably a no-op in functional mode.
    //
    // NOTE: real tool-driven stitching will replace this with the
    // chain head -> ... -> chain tail flop path. Do NOT preserve this
    // assign in the post-synth netlist.
    //
    // synopsys translate_off
    initial $display("INFO[tidelink_dft_wrapper] scan chains pre-stitched; expect tool replacement post-synth.");
    // synopsys translate_on

    // For chain 0 the tail is taken from the legacy `scan_out` of u_top.
    // For chains 1..N-1 the wrapper forwards heads to tails as a
    // placeholder. The DFT tool's `insert_dft` step replaces these.
    genvar gi;
    generate
        for (gi = 1; gi < SCAN_CHAINS; gi = gi + 1) begin : g_chain_pass
            // scan-replace target: between scan_in[gi] and scan_out[gi]
            // the tool inserts a chain of scan flops. The pass-through
            // assign is a placeholder so elaboration succeeds.
            assign scan_out[gi] = scan_in[gi];
        end
    endgenerate

    assign scan_out[0] = legacy_scan_out;

    // -------------------------------------------------------------------------
    // INTERNAL: MBIST controller (NOT INSTANTIATED IN THIS SKELETON)
    //
    // Closure task: instantiate `tidelink_mbist_ctrl` (Tessent-generated
    // or hand-rolled). For now we tie off the status so the wrapper
    // elaborates clean.
    //
    // Future hookup will:
    //   - drive a mux on the rf_16k macro inside u_top/u_fifo/u_sram
    //     so BIST patterns drive the macro when mbist_en=1
    //   - capture Q[31:0] into a CRC-16 signature compactor
    //   - expose done / pass / fail_addr / signature to APB
    // -------------------------------------------------------------------------

    assign mbist_done = 1'b0;
    assign mbist_pass = 1'b0;

    // Mark mbist_en as used so lint is clean. It is otherwise unconnected
    // in this skeleton — closure wires it to the controller.
    wire _unused_mbist_en = mbist_en;

    // -------------------------------------------------------------------------
    // INTERNAL: JTAG TAP (NOT INSTANTIATED IN THIS SKELETON)
    //
    // Default INCLUDE_TAP=0 — TAP deferred for v1 per DFT_PLAN §5.
    // When enabled in closure, instantiate a 1149.1 TAP controller and
    // wire it to `tap_t{ck,ms,di,do,rstn}` plus boundary cells on every
    // IO pad. Boundary cells are NOT in this scaffold.
    // -------------------------------------------------------------------------

    generate
        if (INCLUDE_TAP == 0) begin : g_no_tap
            // Tie off TDO so the output is driven; consume TDI/TMS/TCK/TRSTN
            // to keep lint happy.
            assign tap_tdo = 1'b0;
            wire _unused_tap_tck   = tap_tck;
            wire _unused_tap_tms   = tap_tms;
            wire _unused_tap_tdi   = tap_tdi;
            wire _unused_tap_trstn = tap_trstn;
        end else begin : g_tap
            // CLOSURE TODO: instantiate jtag_tap_top or DesignWare TAP
            // and wire to boundary cells + MBIST run instruction.
            assign tap_tdo = tap_tdi;  // straight bypass placeholder
        end
    endgenerate

    // -------------------------------------------------------------------------
    // u_top — the wrapped DUT
    //
    // The legacy 1-bit scan stub on tidelink_top stays wired; chain 0
    // tail comes back out through `legacy_scan_out`. Other chains are
    // implicit and only resolved by the DFT tool's chain-insertion.
    //
    // `scan_mode` (the legacy single-bit) is asserted whenever any test
    // mode is active: ATPG shift (scan_en) OR MBIST (mbist_en) OR
    // global test_mode. This keeps the existing scan_mode-gated paths
    // (e.g. tidelink_phc_cdc bypass) active in every test condition.
    // -------------------------------------------------------------------------

    wire any_test_mode = test_mode | scan_en | mbist_en;

    tidelink_top #(
        .SYS_ADDR_W         (SYS_ADDR_W),
        .SYS_DATA_W         (SYS_DATA_W),
        .RAM_ADDR_W         (RAM_ADDR_W),
        .RAM_DATA_W         (RAM_DATA_W),
        .APB_ADDR_W         (APB_ADDR_W),
        .FC_DATA_W          (FC_DATA_W),
        .NUM_PHY_LANES      (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE (TIDELINK_PAIR_BASE),
        .PHC_LOCK_GATE_EN   (PHC_LOCK_GATE_EN),
        .USE_IDELAY         (USE_IDELAY),
        .USE_CLKBUF         (USE_CLKBUF),
        .USE_T3A            (USE_T3A),
        .HARDEN_SWI_ENABLE  (HARDEN_SWI_ENABLE),
        // Peer-mask-handshake authenticity gate. WITHOUT this line tidelink_top
        // takes its own 1'b0 default and throws away apb_debug_unlock_i /
        // mask_hs_bypass_i — the strap pins this wrapper declares and wires become
        // dead silicon. See the parameter declaration above for the tapeout note.
        .HONEST_MASK_HS     (HONEST_MASK_HS),
        // PENDING (DECISION #2) — split pass-through, default neutral.
        .DEBUG_UNLOCK_DEFAULT (DEBUG_UNLOCK_DEFAULT),
        // S2 scaffold: PHY v2 select (default 0 = bit-identical)
        .USE_PHY_V2         (USE_PHY_V2),
        // F4: RETIRE-AUTONOMY knob — forwarded verbatim so the ASIC top can
        // gate/strap it without editing axi_chiplet_controller.
        .RETIRE_EN          (RETIRE_EN),
        // PENDING-DECISION #6: forward NEGO_CFG_RESET so ASIC zero-poke autonomy
        // is expressible at the DFT wrapper (was previously NOT forwarded → the
        // ASIC silently took 7'h00 and autonomy could never fire).
        .NEGO_CFG_RESET     (NEGO_CFG_RESET),
        // PENDING-DECISION #5: terminal role from strap (default 1'b0 = today)
        .ROLE_FROM_STRAP    (ROLE_FROM_STRAP),
        // PENDING-DECISION #1: RX-FIFO AHB-write gate (default 1'b1 bit-identical)
        .ENABLE_AHB_WRITE   (ENABLE_AHB_WRITE)
    ) u_top (
        // Clock / reset
        .hclk                       (hclk),
        .hresetn                    (hresetn),
        .poresetn                   (poresetn),
        .phc_clk                    (phc_clk),
        .phc_resetn                 (phc_resetn),

        // AHB sub
        .ahb_sub_hsel               (ahb_sub_hsel),
        .ahb_sub_haddr              (ahb_sub_haddr),
        .ahb_sub_hburst             (ahb_sub_hburst),
        .ahb_sub_hprot              (ahb_sub_hprot),
        .ahb_sub_hsize              (ahb_sub_hsize),
        .ahb_sub_htrans             (ahb_sub_htrans),
        .ahb_sub_hwdata             (ahb_sub_hwdata),
        .ahb_sub_hwrite             (ahb_sub_hwrite),
        .ahb_sub_hready             (ahb_sub_hready),
        .ahb_sub_hrdata             (ahb_sub_hrdata),
        .ahb_sub_hresp              (ahb_sub_hresp),
        .ahb_sub_hreadyout          (ahb_sub_hreadyout),

        // AHB tx
        .ahb_tx_hsel                (ahb_tx_hsel),
        .ahb_tx_haddr               (ahb_tx_haddr),
        .ahb_tx_htrans              (ahb_tx_htrans),
        .ahb_tx_hsize               (ahb_tx_hsize),
        .ahb_tx_hwrite              (ahb_tx_hwrite),
        .ahb_tx_hwdata              (ahb_tx_hwdata),
        .ahb_tx_hready              (ahb_tx_hready),
        .ahb_tx_hrdata              (ahb_tx_hrdata),
        .ahb_tx_hresp               (ahb_tx_hresp),
        .ahb_tx_hreadyout           (ahb_tx_hreadyout),

        // AHB fifo
        .ahb_fifo_hsel              (ahb_fifo_hsel),
        .ahb_fifo_haddr             (ahb_fifo_haddr),
        .ahb_fifo_htrans            (ahb_fifo_htrans),
        .ahb_fifo_hsize             (ahb_fifo_hsize),
        .ahb_fifo_hwrite            (ahb_fifo_hwrite),
        .ahb_fifo_hwdata            (ahb_fifo_hwdata),
        .ahb_fifo_hready            (ahb_fifo_hready),
        .ahb_fifo_hrdata            (ahb_fifo_hrdata),
        .ahb_fifo_hresp             (ahb_fifo_hresp),
        .ahb_fifo_hreadyout         (ahb_fifo_hreadyout),

        // AHB mng
        .ahb_mng_haddr              (ahb_mng_haddr),
        .ahb_mng_hburst             (ahb_mng_hburst),
        .ahb_mng_hprot              (ahb_mng_hprot),
        .ahb_mng_hsize              (ahb_mng_hsize),
        .ahb_mng_htrans             (ahb_mng_htrans),
        .ahb_mng_hwdata             (ahb_mng_hwdata),
        .ahb_mng_hwrite             (ahb_mng_hwrite),
        .ahb_mng_hready             (ahb_mng_hready),
        .ahb_mng_hrdata             (ahb_mng_hrdata),
        .ahb_mng_hresp              (ahb_mng_hresp),

        // APB
        .apb_paddr                  (apb_paddr),
        .apb_penable                (apb_penable),
        .apb_pwrite                 (apb_pwrite),
        .apb_pstrb                  (apb_pstrb),
        .apb_pprot                  (apb_pprot),
        .apb_pwdata                 (apb_pwdata),
        .apb_psel                   (apb_psel),
        .apb_prdata                 (apb_prdata),
        .apb_pready                 (apb_pready),
        .apb_pslverr                (apb_pslverr),

        // Scan / DFT — LEGACY 1-bit stub: re-driven from the
        // multi-chain bus. `scan_mode` is the union of all test modes
        // so the in-design scan_mode-gated bypass paths fire in every
        // mode.
        .scan_mode                  (any_test_mode),
        .scan_asyncrst_ctrl         (scan_asyncrst_ctrl),
        .scan_clk                   (scan_clk),
        .scan_shift                 (scan_en),
        .scan_in                    (legacy_scan_in),
        .scan_out                   (legacy_scan_out),

        // Wlink ref
        .user_ref_clk               (user_ref_clk),

        // PHY pads
        .pad_clk_tx                 (pad_clk_tx),
        .pad_tx                     (pad_tx),
        .pad_clk_rx                 (pad_clk_rx),
        .pad_rx                     (pad_rx),
        .idelay_ref_clk             (idelay_ref_clk),

        // AHB PTP
        .ahb_ptp_hsel               (ahb_ptp_hsel),
        .ahb_ptp_haddr              (ahb_ptp_haddr),
        .ahb_ptp_htrans             (ahb_ptp_htrans),
        .ahb_ptp_hsize              (ahb_ptp_hsize),
        .ahb_ptp_hwrite             (ahb_ptp_hwrite),
        .ahb_ptp_hwdata             (ahb_ptp_hwdata),
        .ahb_ptp_hready             (ahb_ptp_hready),
        .ahb_ptp_hrdata             (ahb_ptp_hrdata),
        .ahb_ptp_hresp              (ahb_ptp_hresp),
        .ahb_ptp_hreadyout          (ahb_ptp_hreadyout),

        // PHC
        .phc_hw_capture             (phc_hw_capture),
        .phc_nanoseconds            (phc_nanoseconds),
        .phc_seconds                (phc_seconds),
        .phc_pps                    (phc_pps),
        .phc_hw_cap_seconds         (phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time            (phc_hw_set_time),
        .phc_hw_set_seconds         (phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (phc_hw_adj_ns_incr_frac),
        .phc_locked_i               (phc_locked_i),
        .servo_locked               (servo_locked),

        // IRQs
        .released_credits_irq       (released_credits_irq),
        .doorbell_irq               (doorbell_irq),
        .packet_committed_irq       (packet_committed_irq),
        .ptp_irq                    (ptp_irq),
        .perf_irq                   (perf_irq),
        .wlink_irq                  (wlink_irq),

        // TideChart
        .tc_axis_tx_tvalid          (tc_axis_tx_tvalid),
        .tc_axis_tx_tdata           (tc_axis_tx_tdata),
        .tc_axis_tx_tready          (tc_axis_tx_tready),
        .tc_axis_rx_tvalid          (tc_axis_rx_tvalid),
        .tc_axis_rx_tdata           (tc_axis_rx_tdata),
        .tc_axis_rx_tready          (tc_axis_rx_tready),
        .tc_qos_priority            (tc_qos_priority),

        // Congestion sideband
        .tl_local_link_state_o      (tl_local_link_state_o),
        .tl_link_state_change_o     (tl_link_state_change_o),
        .tl_ewma_credit_o           (tl_ewma_credit_o),
        .tl_bcast_ack_i             (tl_bcast_ack_i),

        // Link / role
        .link_active                (link_active),
        .tl_data_mode_o             (tl_data_mode_o),
        .d2d_reset_o                (d2d_reset_o),
        .role_strap_i               (role_strap_i),
        .role_is_master_o           (role_is_master_o),
        .role_locked_o              (role_locked_o),
        .apb_debug_unlock_i         (apb_debug_unlock_i),
        .mask_hs_bypass_i           (mask_hs_bypass_i),

        // Autoneg
        .nego_priority_i            (nego_priority_i),
        .puf_seed                   (puf_seed),
        .puf_ready                  (puf_ready),
        .nego_error_irq             (nego_error_irq),

        // I2C
        .i2c_scl_i                  (i2c_scl_i),
        .i2c_scl_o                  (i2c_scl_o),
        .i2c_scl_t                  (i2c_scl_t),
        .i2c_sda_i                  (i2c_sda_i),
        .i2c_sda_o                  (i2c_sda_o),
        .i2c_sda_t                  (i2c_sda_t),

        // I2C AXI
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
        .i2c_nbsy_irq               (i2c_nbsy_irq),
        .i2c_nrd_empty_irq          (i2c_nrd_empty_irq)
    );

endmodule
