//-----------------------------------------------------------------------------
// nanosoc_eth_chiplet — structural integration top for the nanoSoC ethernet
// chiplet: the multicore SoC, a TideLink die-to-die link, and the TideChart
// chiplet-ID controller, wired side by side.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module owns the INTEGRATION and nothing else — it forks none of the
// three components, it instantiates them. Everything here is dictated by the
// three RTL boundaries; where this file makes a policy choice it says WHY.
//
// The SoC's die-to-die port is deliberately LINK-AGNOSTIC (nothing in the SoC
// names TideLink). All the TideLink-specific knowledge lives at THIS level:
//
//   * d2d_ahb_m  (SoC manager, the 32 MB window 0x2E000000..0x2FFFFFFF) is
//     sub-decoded by u_d2d_decode into TideLink's four AHB subordinates plus
//     two AHB->APB bridges. Address/control/write-data fan out DIRECTLY from
//     d2d_ahb_m to every slave; the decoder owns only the HSELs and the
//     data-phase response mux (see chiplet_d2d_decode.sv header).
//   * d2d_ahb_s  (SoC's 6th matrix initiator) is driven by TideLink's incoming
//     manager port ahb_mng — the remote die reaching shared SRAM + the mailbox.
//   * d2d_irq[15:0] gathers TideLink + TideChart interrupts: [7:0] land on
//     CPU0's NVIC (data plane), [15:8] on CPU1's (link management).
//   * d2d_phc_* is PHC hardware servo source 0 — the cross-die timebase.
//
// GEOMETRY (from the SoC's generated defaults and TideLink's RTL defaults):
//   SYS_ADDR_W = SYS_DATA_W = 32; TideLink RAM_ADDR_W = 14 (the tx/fifo
//   apertures are 16 KB, so their AHB address is haddr[13:0]); TideChart is
//   instantiated single-port (NUM_PORTS=1) with FC_DATA_W=48.
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// CPU0 (network_core) IMEM preload image — DEFAULT.
//
// Overridable three ways, deliberately, because the four consumers of this file
// each have a different one of them available:
//
//   1. leave it alone           -> "image.hex", resolved by $readmemh against
//                                  the COMPILER's working directory. Both HAPS-SX
//                                  flows already stage the built firmware there
//                                  (fpga/haps-sx/Makefile: IMAGE_HEX := $(BUILD)/
//                                  image.hex, and Vivado/ProtoCompiler are run
//                                  from $(BUILD)); it also matches the SoC's own
//                                  default for CC_IMEM_MEM_FPGA_IMG, so CPU0 and
//                                  CPU1 stay symmetric.
//   2. +define+NANOSOC_ETH_IMEM_IMG="<path>"   command-line flows.
//   3. `define NANOSOC_ETH_IMEM_IMG "<path>" prepended to a materialised copy of
//      this file  -> the ipx::package_project route. A project-level define does
//      NOT survive packaging as a fileset property, which is why the value used
//      to be hardcoded here; but an IN-BODY define does, and
//      tidelink/fpga/vivado_ip/nanosoc_eth_chiplet_filelist.tcl already relies on
//      exactly that mechanism for `RAM_PRELOAD` (sl_ahb_rom.v) and
//      `TIDELINK_PHY_V2` (the v2 shims). Same lever, one more file.
//   4. instance override .ETH_IMEM_IMG("<path>") on the parameter below, for any
//      flow that instantiates this RTL top directly (the HAPS-SX board top, the
//      g2_soc_pair bench).
//
// NEVER put an absolute path here. It bakes one developer's $HOME into tracked
// RTL that the ASIC filelist compiles, so a clone anywhere else silently gets a
// nonexistent hex.
//-----------------------------------------------------------------------------
`ifndef NANOSOC_ETH_IMEM_IMG
  `define NANOSOC_ETH_IMEM_IMG "image.hex"
`endif

module nanosoc_eth_chiplet #(
    // TideLink GPIO-PHY lane count. RTL default is 8; kept as a chiplet param so
    // the PHY-pad boundary width tracks the instance parameter in one place.
    parameter NUM_PHY_LANES = 8,
    // TideChart grandmaster-election priority (lower wins). Threads straight to
    // tidechart_shim. Strap it DIFFERENTLY per die (e.g. die_a 0x0001, die_b
    // 0x0002); equal values on both dies leave the election without a tiebreak
    // and both dies can settle as root.
    parameter [15:0] DEVICE_CLASS = 16'h0001,
    // CPU0 (network_core) IMEM $readmemh preload image. See the header
    // above for the four ways to set it and why none of them is a
    // hardcoded absolute path.
    parameter ETH_IMEM_IMG = `NANOSOC_ETH_IMEM_IMG
) (
    // =========================================================================
    // SoC boundary — EVERY nanosoc_multicore_soc port that is NOT d2d_* is
    // re-exported here 1:1 (same name, same width). The d2d_* ports are
    // consumed internally by the link and never reach this boundary.
    // SYS_ADDR_W = SYS_DATA_W = 32 (the SoC's generated defaults).
    // =========================================================================
    // -- System clock / reset --
    input  wire        sys_fclk,
    input  wire        sys_sysresetn,
    output wire        sys_poresetn,
    output wire        sys_hclk,
    output wire        sys_hresetn,
    input  wire        sys_scanenable,
    input  wire        sys_testmode,
    input  wire        sys_sysresetreq,
    // -- External AHB slave: testbench access to the ethernet subsystem --
    input  wire [31:0] eth_ss_0_haddr,
    input  wire  [1:0] eth_ss_0_htrans,
    input  wire        eth_ss_0_hwrite,
    input  wire  [2:0] eth_ss_0_hsize,
    input  wire  [2:0] eth_ss_0_hburst,
    input  wire  [3:0] eth_ss_0_hprot,
    input  wire [31:0] eth_ss_0_hwdata,
    input  wire        eth_ss_0_hmastlock,
    output wire [31:0] eth_ss_0_hrdata,
    output wire        eth_ss_0_hready,
    output wire        eth_ss_0_hresp,
    // -- CPU0 (network core) / CPU1 (chip core) sideband --
    input  wire        network_core_pmuenable,
    input  wire        chip_core_pmuenable,
    input  wire        network_core_nmi,
    output wire        network_core_txev,
    input  wire        network_core_rxev,
    output wire        network_core_lockup,
    output wire        network_core_sysresetreq,
    output wire        network_core_sleeping,
    output wire        network_core_sleepdeep,
    input  wire        chip_core_nmi,
    output wire        chip_core_txev,
    input  wire        chip_core_rxev,
    output wire        chip_core_lockup,
    output wire        chip_core_sysresetreq,
    output wire        chip_core_sleeping,
    output wire        chip_core_sleepdeep,
    // -- Debug access port (SWJ-DP / JTAG) --
    input  wire        dap_swclktck,
    input  wire        dap_swditms,
    output wire        dap_swdo,
    output wire        dap_swdoen,
    input  wire        dap_tdi,
    output wire        dap_tdo,
    output wire        dap_ntdoen,
    input  wire        dap_ntrst,
    input  wire        dap_npotrst,
    input  wire        dap_swj_enable,
    // -- RMII ethernet PHY --
    input  wire        rmii_ref_clk,
    output wire  [1:0] rmii_txd,
    output wire        rmii_tx_en,
    input  wire  [1:0] rmii_rxd,
    input  wire        rmii_crs_dv,
    // -- MDIO --
    input  wire        md_pad_i,
    output wire        mdc_pad_o,
    output wire        md_pad_o,
    output wire        md_padoe_o,
    // -- UARTs / CPU1 watchdog --
    input  wire        uart_rxd,
    output wire        uart_txd,
    input  wire        chip_core_uart_rxd,
    output wire        chip_core_uart_txd,
    output wire        chip_core_wdog_reset,
    // -- RTC / PTP time out --
    input  wire        rtc_clk,
    output wire [31:0] rtc_time_ptp_ns,
    output wire [47:0] rtc_time_ptp_sec,
    output wire        rtc_time_one_pps,
    // -- Ethernet / PHC interrupts + status --
    output wire        eth_irq,
    output wire        phc_pps_out,   // ALSO drives TideLink phc_pps internally
    output wire        phc_pps_irq,
    output wire        phc_alarm_irq,
    output wire        ha1588_servo_locked,
    // -- QSPI flash --
    output wire        qspi_sclk,
    output wire        qspi_csn,
    output wire  [3:0] qspi_io_o,
    input  wire  [3:0] qspi_io_i,
    output wire  [3:0] qspi_io_e,
    // -- PL022 SPI --
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire  [2:0] spi_ss,
    // -- HOSTIO4 P1 --
    input  wire  [6:0] hostio4_p1_in,
    output wire  [6:0] hostio4_p1_out,
    output wire  [6:0] hostio4_p1_outen,

    // =========================================================================
    // TideLink GPIO-PHY pads — the die-to-die wire to the far die.
    // =========================================================================
    output wire                     pad_clk_tx,
    output wire [NUM_PHY_LANES-1:0] pad_tx,
    input  wire                     pad_clk_rx,
    input  wire [NUM_PHY_LANES-1:0] pad_rx,
    input  wire                     user_ref_clk,     // Wlink PLL reference clock
    input  wire                     idelay_ref_clk,   // 200 MHz IDELAYCTRL ref (FPGA IDELAY only)

    // =========================================================================
    // TideLink I2C sideband (open-drain tristate) + role strap.
    // =========================================================================
    input  wire        i2c_scl_i,
    output wire        i2c_scl_o,
    output wire        i2c_scl_t,
    input  wire        i2c_sda_i,
    output wire        i2c_sda_o,
    output wire        i2c_sda_t,
    input  wire        role_strap_i,

    // =========================================================================
    // Link bring-up straps. Ports rather than internal tie-offs: their values
    // are a per-die decision the integrator makes at the pad ring.
    //
    //   nego_priority_i     auto-negotiation priority, normally from OTP or a die
    //                       UID. Two dies both presenting 0 have no tiebreak.
    //   mask_hs_bypass_i    together open the software-driven role-lock path used
    //   apb_debug_unlock_i  during bring-up; both low keeps that path shut.
    //   puf_seed/puf_ready  from TideChart's PUF sampler, when enabled.
    // =========================================================================
    input  wire [15:0] nego_priority_i,
    input  wire        mask_hs_bypass_i,
    input  wire        apb_debug_unlock_i,
    input  wire [15:0] puf_seed,
    input  wire        puf_ready,

    // =========================================================================
    // DFT. Exposed at the boundary so a production pad ring can wire them to the
    // scan controller; tying them off internally would drop the chiplet's scan
    // chain.
    // =========================================================================
    input  wire        scan_mode,
    input  wire        scan_asyncrst_ctrl,
    input  wire        scan_clk,
    input  wire        scan_shift,
    input  wire        scan_in,
    output wire        scan_out,

    // =========================================================================
    // Link status / observability for bring-up and silicon debug. The physical
    // team decides whether each becomes a pad, a test point or a register bit.
    // =========================================================================
    output wire        link_active_o,      // Wlink link layer is up
    output wire        d2d_reset_o,        // die-to-die reset out
    output wire        role_is_master_o,   // resolved link role
    output wire        role_locked_o,      // role latched
    output wire        servo_locked_o,     // TideLink PTP servo lock (NOT the PHC's; see D2D_PORT.md 6f)
    output wire [12:0] tl_ewma_credit_o,   // congestion telemetry
    output wire        tidechart_irq_o     // TideChart controller interrupt
);

    //=========================================================================
    // Internal nets
    //=========================================================================

    // --- D2D outbound: SoC manager d2d_ahb_m -> u_d2d_decode + slaves ---
    // Address/control/write-data are SoC outputs that fan out DIRECTLY to the
    // slaves; the decoder returns the muxed response (hrdata/hready/hresp).
    wire [31:0] d2d_ahb_m_haddr;
    wire  [1:0] d2d_ahb_m_htrans;
    wire        d2d_ahb_m_hwrite;
    wire  [2:0] d2d_ahb_m_hsize;
    wire  [2:0] d2d_ahb_m_hburst;
    wire  [3:0] d2d_ahb_m_hprot;
    wire [31:0] d2d_ahb_m_hwdata;
    wire [31:0] d2d_ahb_m_hrdata;   // u_d2d_decode -> SoC (muxed read data)
    wire        d2d_ahb_m_hready;   // u_d2d_decode -> SoC AND broadcast slave HREADY
    wire        d2d_ahb_m_hresp;    // u_d2d_decode -> SoC (muxed response)

    // Per-slave selects from the decoder.
    wire        hsel_tx, hsel_fifo, hsel_ptp, hsel_tlapb, hsel_tcapb, hsel_peer;

    // Registered "the outstanding data phase is the peer aperture".
    wire        dph_peer;

    // HREADY presented to TideLink's `ahb_sub` subordinate.
    //
    // Forced high while the peer owns the data phase, otherwise the true global
    // HREADY.
    //
    // It must NOT be `d2d_ahb_m_hready`. That is the decoder's response mux, which
    // selects the peer's own `hreadyout` during the peer data phase, and TideLink's
    // `ahb_sub_hreadyout` reads `ahb_sub_hready` combinationally
    // (tidelink_top.sv:1119,1169). Feeding it back closes a cycle with no register
    // in it:
    //
    //     hready -> ext_addr_phase -> ext_is_nonseq -> ahb_sub_hreadyout
    //            -> hready_r (DPH_PEER arm) -> hready
    //
    // which oscillates on back-to-back peer transfers (a memcpy across the
    // aperture). VCS does not error; it spins with simulation time frozen.
    //
    // AMBA forbids a subordinate's HREADYOUT being a function of HREADY, so
    // withholding the peer's own contribution from its own HREADY input removes an
    // input the subordinate should never have used. Every other slave still sees
    // the true global HREADY, so a peer address phase presented during another
    // slave's wait state is still correctly ignored.
    //
    // `ahb_sub` is the ONLY TideLink port with this dependence: ahb_ptp_hreadyout
    // is constant 1, ahb_tx_hreadyout is registered state only, the FIFO bottoms
    // out at cmsdk_ahb_to_sram (HREADYOUT = 1'b1), and both APB banks are
    // cmsdk_ahb_to_apb, whose HREADYOUT is a function of registered FSM state.
    //
    // See docs/design/D2D_HREADY_LOOP.md.
    wire        hready_to_peer = dph_peer ? 1'b1 : d2d_ahb_m_hready;

    // ---- Peer-write data steering into TideLink's ahb_sub --------------------
    // TideLink's ahb_sub XHB500 bridge pipelines the AHB ADDRESS by one cycle
    // (tidelink_top.sv:1156, pipe_haddr_r) but samples write data LIVE, and it
    // sequences the AXI AW beat and the W beat independently. A compliant AHB
    // master drives HWDATA for its single data-phase cycle and then releases the
    // bus, so if the W beat has not fired by then XHB500 captures the RELEASED bus
    // (0). The W channel can backpressure for an arbitrary number of cycles under
    // CDC / credit / outstanding-write pressure, so no FIXED delay aligns them.
    //
    // Scheme: pass the LIVE per-beat payload straight through to ahb_sub_hwdata,
    // and substitute a FROZEN copy only across a beat the master has already
    // released whose W beat has not yet landed.
    //   * passthrough keeps per-beat data correct on a continuous INCR<n> burst,
    //     where a SEQ beat's W beat can land the same cycle the master presents it;
    //   * the freeze is the released-bus defence for a single write.
    //
    // The unfreeze is gated ONLY by `w_beat_consumed` (s_axi_wvalid & s_axi_wready
    // at the ahb_sub boundary, per BEAT, no wlast) — the one event that certifies
    // this beat reached the link. Two release conditions that look equivalent and
    // are not:
    //   * do NOT release on ~dph_peer alone. chiplet_d2d_decode advances dph_code
    //     only on hready, so dph_peer never drops mid-burst and the hold would
    //     deliver beat 0's payload on every beat.
    //   * do NOT OR the release with wr_hold_r or synth_b_pending. Either couples
    //     it to something other than the W handshake, and the hold can advance past
    //     a beat the link never consumed.
    // d2d_ahb_m_hready is read only to detect the RELEASE point (when to freeze),
    // never to advance past a beat.
    //
    // ahb_sub carries only the peer-aperture path, so holding there is safe.
    // -------------------------------------------------------------------------
    reg         peer_wr_r;            // in-flight peer access is a write
    reg         cap_done_r;           // 1 = present the FROZEN hold (released, not-yet-consumed beat)
    reg         peer_wcon_r;          // current beat's W beat already landed (consume-before-release)
    reg  [31:0] hwdata_hold_r;        // frozen payload captured at the release edge

    // Per-beat W-channel consumption at the ahb_sub/XHB500 boundary, from
    // tidelink_top's ahb_sub_w_beat_consumed_o (= s_axi_wvalid & s_axi_wready),
    // wired at the u_tidelink instantiation below.
    wire w_beat_consumed;

    // ahb_sub_hwdata (wired below at the tidelink instance): LIVE passthrough,
    // frozen hold substituted only across a released-but-unconsumed beat.
    wire [31:0] d2d_ahb_m_hwdata_q = cap_done_r ? hwdata_hold_r : d2d_ahb_m_hwdata;

    always @(posedge sys_hclk or negedge sys_hresetn) begin
        if (!sys_hresetn) begin
            peer_wr_r     <= 1'b0;
            cap_done_r    <= 1'b0;
            peer_wcon_r   <= 1'b0;
            hwdata_hold_r <= 32'h0;
        end else begin
            if (hsel_peer & d2d_ahb_m_hready)
                peer_wr_r <= d2d_ahb_m_hwrite & d2d_ahb_m_htrans[1];

            if (dph_peer & peer_wr_r) begin
                if (cap_done_r) begin
                    // Frozen on a released-but-unconsumed beat: unfreeze the cycle
                    // its W beat actually lands.
                    if (w_beat_consumed) begin
                        cap_done_r  <= 1'b0;
                        peer_wcon_r <= 1'b0;
                    end
                end else if (d2d_ahb_m_hready) begin
                    // Master COMPLETED (released) this beat's AHB data phase:
                    //  * W beat already landed (now or earlier) -> beat fully handed
                    //    off; keep passing the next beat straight through.
                    //  * else released BEFORE consumption (the released-bus hazard)
                    //    -> FREEZE the just-driven value and hold until
                    //    w_beat_consumed.
                    if (peer_wcon_r | w_beat_consumed)
                        peer_wcon_r <= 1'b0;
                    else begin
                        cap_done_r    <= 1'b1;
                        hwdata_hold_r <= d2d_ahb_m_hwdata;   // capture the released payload
                    end
                end else if (w_beat_consumed) begin
                    // W beat landed while the master still holds this beat
                    // (consume-before-release, the non-bufferable norm): remember it
                    // so we never freeze an already-consumed beat at release.
                    peer_wcon_r <= 1'b1;
                end
            end

            if (~dph_peer) begin
                cap_done_r  <= 1'b0;   // idle re-arm (single-write safety net)
                peer_wcon_r <= 1'b0;
            end
        end
    end

    // Per-slave data-phase responses back into the decoder.
    wire [31:0] hrdata_tx,    hrdata_fifo,    hrdata_ptp,    hrdata_tlapb,    hrdata_tcapb,    hrdata_peer;
    wire        hreadyout_tx, hreadyout_fifo, hreadyout_ptp, hreadyout_tlapb, hreadyout_tcapb, hreadyout_peer;
    wire        hresp_tx,     hresp_fifo,     hresp_ptp,     hresp_tlapb,     hresp_tcapb,     hresp_peer;

    // =========================================================================
    // BUFFERABLE (EWR) PEER-WRITE REJECT — fail loud on an unvalidated path.
    //
    // The depth-1 hold above is validated for NON-bufferable (hprot[2]=0) peer
    // writes only. A bufferable peer write instead reaches XHB500's early-write-
    // response path (up to HAZARD_LIST_SIZE=4 posted writes, early-synthesised B),
    // whose depth>1 behaviour through a single-deep hold is untested and could
    // corrupt silently. hprot is master-driven passthrough end to end, so the path
    // is architecturally reachable. Three layers make it visible instead:
    //
    //   (iii) a 2-cycle AHB HRESP=ERROR to the master for ANY bufferable peer
    //         write, single or burst, so software cannot mistake an unvalidated
    //         write for a landed OKAY;
    //   (ii)  a sticky synthesizable observation flag (mark_debug), held to reset,
    //         for post-hoc silicon/ILA visibility;
    //   (i)   a simulation $error under `ifndef SYNTHESIS.
    //
    // SUPERSEDED IN PART (see "CHANGE 2 of 2" below). Layer (iii), the HRESP=
    // ERROR, has been REMOVED: the ahb_sub_hprot tie-down at the u_tidelink
    // instantiation now clears HPROT[3:2] on the peer path, so a bufferable peer
    // write can no longer arm XHB500's EWR and no longer needs rejecting. Layer
    // (ii) is unchanged and still observes the master's real request. Layer (i)
    // has been REPOINTED from "the master asked for bufferable" (now benign) to
    // "the tie-down is in effect at the ahb_sub boundary" (a real defect).
    // The paragraphs below describe the ORIGINAL reject and are kept for the
    // rationale; where they say ERROR is presented, that no longer happens.
    //
    // The reject is DECIDED at the address phase on hprot[2] (ewr_peer_wr_aphase),
    // before any data enters the hold; the ERROR is presented in the immediately
    // following data phase. The scope is deliberately blanket — no depth-2+
    // collision detection on an already-untested path.
    //
    // MECHANISM: a top-level interpose on the peer response wires between
    // u_tidelink (which drives *_tl) and u_d2d_decode (which consumes hresp_peer /
    // hreadyout_peer). It mirrors the 2-cycle ERROR chiplet_d2d_decode already
    // raises for an unmapped default (its dflt_err2 sequencer,
    // chiplet_d2d_decode.sv:197-206) but lives here so neither shared file is
    // touched. Read data passes through unchanged; a write ignores hrdata.
    //
    // For hprot[2]=0, ewr_reject_active was 0, so the decoder saw TideLink's native
    // response verbatim and the validated path was bit-for-bit unaffected. (After
    // CHANGE 2 the override and ewr_reject_active are gone entirely, so this now
    // holds for EVERY hprot value.)
    //
    // LIMIT: the ERROR goes to the MASTER. It does not un-post whatever ahb_sub may
    // already have forwarded to the far die — hready_to_peer completes ahb_sub's
    // transfer independently. The guarantee is that the master is TOLD the write
    // failed, not that no data crossed. Also gating hsel_peer so nothing is posted
    // is described in BURST_FIX_GUARD.md and deliberately not implemented.
    // =========================================================================
    // tidelink ahb_sub native response; the reject mux overrides it.
    wire [31:0] hrdata_peer_tl;
    wire        hreadyout_peer_tl;
    wire        hresp_peer_tl;

    // Address-phase detect: a bufferable peer WRITE is accepted THIS cycle.
    // hsel_peer already implies htrans[1] (a real transfer); qualify with the
    // data-phase accept (d2d_ahb_m_hready), write-ness, and the bufferable bit.
    wire ewr_peer_wr_aphase = hsel_peer & d2d_ahb_m_hready
                            & d2d_ahb_m_hwrite & d2d_ahb_m_hprot[2];

    // ---- CHANGE 2 of 2: GUARD DEMOTED TO OBSERVE-ONLY -----------------------
    // Depends on CHANGE 1 (the ahb_sub_hprot tie-down at the u_tidelink
    // instantiation). Revert BOTH together, or neither: this block on its own
    // would leave a bufferable peer write unguarded AND unrejected.
    //
    // WHY. The 2-cycle HRESP=ERROR existed because a bufferable peer write
    // reached XHB500's EWR path, whose depth>1 behaviour through the depth-1
    // hold is untested. With CHANGE 1 the bridge's hprot[2]/[3] are 0 for every
    // peer transfer, so EWR can no longer arm and such a write is now handled by
    // the SAME validated non-bufferable path as any other. Continuing to ERROR
    // it would fail traffic that is, by construction, safe — and DMA-250 and
    // other initiators legitimately set HPROT[2].
    //
    // WHAT IS KEPT. ewr_peer_wr_aphase still reads the UNMODIFIED
    // d2d_ahb_m_hprot[2], so the sticky bit still records the genuine fact "an
    // initiator requested a bufferable peer write" for silicon/ILA triage. It is
    // deliberately NOT repointed at the tied-down value, which would be 0 by
    // construction and would observe nothing.
    (* mark_debug = "true" *) reg ewr_seen_sticky_r;  // sticky obs — set on detect, held to reset

    always @(posedge sys_hclk or negedge sys_hresetn) begin
        if (!sys_hresetn)
            ewr_seen_sticky_r <= 1'b0;
        else if (ewr_peer_wr_aphase)
            ewr_seen_sticky_r <= 1'b1;   // read-only; changes no behaviour
    end

    // Peer responses now pass TideLink through verbatim — no reject override.
    assign hrdata_peer    = hrdata_peer_tl;   // writes ignore hrdata
    assign hreadyout_peer = hreadyout_peer_tl;
    assign hresp_peer     = hresp_peer_tl;

`ifndef SYNTHESIS
    // Simulation assertion, REPOINTED. Asserting on what the MASTER requested is
    // no longer a failure (CHANGE 1 makes it safe). What must never happen is the
    // tie-down not holding, so assert the INVARIANT at the ahb_sub boundary: the
    // bits TideLink actually receives must be 0 on every peer transfer. This
    // fails loud if CHANGE 1 is ever reverted, bypassed, or reordered, which the
    // old assertion could not detect.
    always @(posedge sys_hclk) begin
        if (sys_hresetn === 1'b1 && hsel_peer === 1'b1 &&
            (u_tidelink.ahb_sub_hprot[3:2] !== 2'b00))
            $error("[EWR_TIEDOWN] ahb_sub_hprot[3:2]=0b%02b at TideLink (expected 00): haddr=0x%08h master hprot=0x%0h @ %0t -- the peer-path HPROT tie-down is NOT in effect; XHB500 EWR/cacheable paths are reachable.",
                   u_tidelink.ahb_sub_hprot[3:2], d2d_ahb_m_haddr, d2d_ahb_m_hprot, $time);
    end
`endif

    // --- D2D inbound: TideLink ahb_mng -> SoC d2d_ahb_s ---
    wire [31:0] d2d_ahb_s_haddr;
    wire  [2:0] d2d_ahb_s_hburst;
    wire  [6:0] d2d_ahb_s_hprot;    // TideLink is AHB5 [6:0]; SoC takes [3:0]
    wire  [2:0] d2d_ahb_s_hsize;
    wire  [1:0] d2d_ahb_s_htrans;
    wire [31:0] d2d_ahb_s_hwdata;
    wire        d2d_ahb_s_hwrite;
    wire        d2d_ahb_s_hready;   // SoC -> TideLink (slave ready back to manager)
    wire [31:0] d2d_ahb_s_hrdata;   // SoC -> TideLink
    wire        d2d_ahb_s_hresp;    // SoC -> TideLink

    // --- Cross-die PHC servo source 0 ---
    wire [47:0] d2d_phc_seconds;
    wire [29:0] d2d_phc_nanoseconds;
    wire [47:0] d2d_phc_hw_cap_seconds;
    wire [29:0] d2d_phc_hw_cap_nanoseconds;
    wire [31:0] d2d_phc_hw_cap_sub_nanoseconds;
    wire        d2d_phc_hw_capture;
    wire        d2d_phc_hw_set_time;
    wire [47:0] d2d_phc_hw_set_seconds;
    wire [29:0] d2d_phc_hw_set_nanoseconds;
    wire        d2d_phc_hw_adj_valid;
    wire [31:0] d2d_phc_hw_adj_ns_incr_frac;

    // --- Interrupts ---
    wire [15:0] d2d_irq;
    // TideLink interrupt sources.
    wire        tl_released_credits_irq, tl_doorbell_irq, tl_packet_committed_irq;
    wire        tl_ptp_irq, tl_perf_irq, tl_wlink_irq;
    wire        tl_nego_error_irq, tl_train_fail_irq;
    wire        tl_i2c_nbsy_irq, tl_i2c_nrd_empty_irq;
    // TideChart interrupt source.
    wire        tc_tidechart_irq;

    // --- TideLink APB config bridge (0x2E03xxxx, 15-bit window) ---
    wire [14:0] tlapb_paddr;
    wire        tlapb_penable, tlapb_pwrite, tlapb_psel, tlapb_pready, tlapb_pslverr;
    wire  [3:0] tlapb_pstrb;
    wire  [2:0] tlapb_pprot;
    wire [31:0] tlapb_pwdata, tlapb_prdata;

    // --- TideChart APB config bridge (0x2E04xxxx, 12-bit window) ---
    wire [11:0] tcapb_paddr;
    wire        tcapb_penable, tcapb_pwrite, tcapb_psel, tcapb_pready, tcapb_pslverr;
    wire [31:0] tcapb_pwdata, tcapb_prdata;

    // --- TideChart AXI-Stream seam (single port; FC_DATA_W = 48) ---
    // Direction naming per TideLink: tc_axis_tx_* is TideChart -> TideLink,
    // tc_axis_rx_* is TideLink -> TideChart.
    wire        tc_tx_tvalid;   // TC -> TL
    wire [47:0] tc_tx_tdata;
    wire        tc_tx_tready;
    wire        tc_rx_tvalid;   // TL -> TC
    wire [47:0] tc_rx_tdata;
    wire        tc_rx_tready;
    // Congestion sideband.
    wire  [4:0] tc_local_link_state;   // TideLink quantised {starve,trend,level}
    wire        tc_link_state_change;
    wire        tc_bcast_ack;
    wire        tc_link_active;
    // TideLink's FCSM>=4 "link carries FC/EXT words" strobe (tl_data_mode_o). This
    // gates the TideChart root election below, NOT tc_link_active: tc_link_active
    // is role_locked_o, which asserts ~5us before the link can carry a CLAIM, so
    // electing on it lets both dies claim root.
    wire        tc_data_mode;

    //=========================================================================
    // DEAD-END SINKS FOR DELIBERATELY UNUSED INSTANCE OUTPUTS
    //
    // Convention for this file:
    //
    //   1. NEVER omit a pin. An omitted pin is indistinguishable from an
    //      oversight, and on an INPUT it floats — Z in simulation, tied
    //      arbitrarily by synthesis. Verilator reports PINMISSING and HAL reports
    //      UNCONI; both gate.
    //
    //   2. For an unused OUTPUT, `.port()` is not enough. It is inert in silicon
    //      but reported forever (Verilator PINCONNECTEMPTY, HAL *W,UNCONN), and
    //      the integration ruleset waives HAL's UNCONO (a module's own undriven
    //      output) WITHOUT waiving UNCONN (a dangling output at an instance) — so
    //      it leaves permanent, unwaived residue for the next reviewer to re-judge.
    //
    //   3. Instead, drive the unused output into a NAMED `*_nc` wire declared here
    //      with a one-line reason. That is what nanosoc_gen emits in the generated
    //      SoC top (`cc_periph_uart_txen_nc`, `dap_ss_0_jtagnsw_nc`, ...) and what
    //      the HAL waiver actually names: "intentional dead-end sinks routed to
    //      named `*_nc` wires" (`-nocheck URDWIR`,
    //      nanosoc-multicore-system/lint/hal.tcl:117), so the waiver's own
    //      justification applies to exactly what it waives.
    //
    // Synthesis removes a driven-but-unread wire, so this costs nothing in silicon
    // and each decision stays greppable as `_nc` with its reason attached.
    //
    // ANYTHING ADDED HERE MUST BE A DELIBERATE DEAD END. If a signal has a
    // plausible consumer, wire it up — `_nc` is a decision, not a parking space.
    //=========================================================================

    // SoC d2d manager: locked-transfer indication. Every slave in the D2D
    // window has a REDUCED AHB shape with no HMASTLOCK port at all — TideLink's
    // ahb_sub/ahb_tx/ahb_fifo/ahb_ptp declare none, and cmsdk_ahb_to_apb has no
    // HMASTLOCK input (BP210 r1p1 cmsdk_ahb_to_apb.v:41-72). There is nowhere
    // for it to go; the D2D window carries no locked sequences.
    wire        soc_d2d_ahb_m_hmastlock_nc;

    // cmsdk_ahb_to_apb APBACTIVE: a clock-gating HINT for an APB power domain.
    // Neither APB bank is clock-gated in this build (both bridges run PCLKEN=1
    // at HCLK), so there is no gate for the hint to drive.
    wire        tlapb_apbactive_nc;
    wire        tcapb_apbactive_nc;

    // TideChart's APB slave port carries neither PSTRB nor PPROT (see the
    // tidechart_shim port list: apb_paddr/psel/penable/pwrite/pwdata only), so
    // the bridge's byte-strobe and protection outputs have no destination.
    // Word writes only, unprivileged/secure attributes not policed.
    wire  [3:0] tcapb_pstrb_nc;
    wire  [2:0] tcapb_pprot_nc;

    // TideLink I2C-sideband AXI slave. There is no CPU-driven I2C master path
    // in v1: every request-side input of this port is tied inactive above
    // (awvalid/wvalid/arvalid = 0), so the slave is permanently idle and its
    // response channels can never carry a transaction. Tied off as a block; if
    // an I2C master is ever added, ALL of these become real nets together.
    wire        tl_i2c_axi_awready_nc;
    wire        tl_i2c_axi_wready_nc;
    wire        tl_i2c_axi_bvalid_nc;
    wire  [1:0] tl_i2c_axi_bid_nc;
    wire  [1:0] tl_i2c_axi_bresp_nc;
    wire        tl_i2c_axi_arready_nc;
    wire        tl_i2c_axi_rvalid_nc;
    wire  [1:0] tl_i2c_axi_rid_nc;
    wire [31:0] tl_i2c_axi_rdata_nc;
    wire  [1:0] tl_i2c_axi_rresp_nc;
    wire        tl_i2c_axi_rlast_nc;

    // TideChart <-> IRQC AXI-Stream pair. The
    // ahb-chiplet-irqc block is NOT instantiated in this chiplet, so the
    // TC->IRQC stream has no consumer and the IRQC->TC stream has no producer.
    // The corresponding INPUTS are tied idle at the instance (tready_i = 0,
    // tvalid_i = 0), which is what keeps the streams quiescent; these are the
    // matching output ends.
    wire        tc_to_irqc_tvalid_nc;
    wire [47:0] tc_to_irqc_tdata_nc;
    wire        tc_to_irqc_tlast_nc;
    wire        irqc_to_tc_tready_nc;

    //=========================================================================
    // Link status to the boundary.
    //
    // `tc_link_active` is not merely observability: it also closes the TX
    // aperture in u_d2d_decode, so a link-down write to 0x2E000000 takes a bus
    // fault instead of wedging the SoC's matrix. Exporting it lets a bring-up
    // script see the same bit the hardware gate is using.
    //=========================================================================
    assign link_active_o   = tc_link_active;
    assign tidechart_irq_o = tc_tidechart_irq;

    //=========================================================================
    // The multicore SoC. Default parameters (SYS_ADDR_W=SYS_DATA_W=32, the
    // deployed memory map). Every non-d2d port maps straight to this boundary;
    // the d2d_* ports drive the link below.
    //
    // FIRMWARE BAKE: ETH_IMEM_MEM_FPGA_IMG initialises CPU0 (network_core) IMEM at
    // bitstream time, through the `ifdef RAM_PRELOAD preload-BRAM path
    // (nanosoc_region_imem -> sl_ahb_rom -> sl_fpga_rom_word). RAM_PRELOAD is
    // defined in-body by the eth-chiplet filelist
    // (vivado_ip/nanosoc_eth_chiplet_filelist.tcl) — the define does not survive
    // ipx::package_project as a fileset property — and the image path rides the
    // SAME in-body mechanism (see ETH_IMEM_IMG / `NANOSOC_ETH_IMEM_IMG at the top
    // of this file). Nothing here is ASIC-relevant: no ASIC flow defines
    // RAM_PRELOAD, so nanosoc_region_imem takes its `else` SRAM branch, sl_ahb_rom
    // is not even in the ASIC filelist, and this string reaches no $readmemh.
    //=========================================================================
    nanosoc_multicore_soc #(
        .ETH_IMEM_MEM_FPGA_IMG (ETH_IMEM_IMG)
    ) u_soc (
        // System clock / reset
        .sys_fclk                       (sys_fclk),
        .sys_sysresetn                  (sys_sysresetn),
        .sys_poresetn                   (sys_poresetn),
        .sys_hclk                       (sys_hclk),
        .sys_hresetn                    (sys_hresetn),
        .sys_scanenable                 (sys_scanenable),
        .sys_testmode                   (sys_testmode),
        .sys_sysresetreq                (sys_sysresetreq),
        // External ethernet-subsystem AHB slave
        .eth_ss_0_haddr                 (eth_ss_0_haddr),
        .eth_ss_0_htrans                (eth_ss_0_htrans),
        .eth_ss_0_hwrite                (eth_ss_0_hwrite),
        .eth_ss_0_hsize                 (eth_ss_0_hsize),
        .eth_ss_0_hburst                (eth_ss_0_hburst),
        .eth_ss_0_hprot                 (eth_ss_0_hprot),
        .eth_ss_0_hwdata                (eth_ss_0_hwdata),
        .eth_ss_0_hmastlock             (eth_ss_0_hmastlock),
        .eth_ss_0_hrdata                (eth_ss_0_hrdata),
        .eth_ss_0_hready                (eth_ss_0_hready),
        .eth_ss_0_hresp                 (eth_ss_0_hresp),
        // D2D outbound manager (link window 0x2E/0x2F)
        .d2d_ahb_m_haddr                (d2d_ahb_m_haddr),
        .d2d_ahb_m_htrans               (d2d_ahb_m_htrans),
        .d2d_ahb_m_hwrite               (d2d_ahb_m_hwrite),
        .d2d_ahb_m_hsize                (d2d_ahb_m_hsize),
        .d2d_ahb_m_hburst               (d2d_ahb_m_hburst),
        .d2d_ahb_m_hprot                (d2d_ahb_m_hprot),
        .d2d_ahb_m_hwdata               (d2d_ahb_m_hwdata),
        .d2d_ahb_m_hmastlock            (soc_d2d_ahb_m_hmastlock_nc),  // reduced slaves carry no hmastlock
        .d2d_ahb_m_hrdata               (d2d_ahb_m_hrdata),
        .d2d_ahb_m_hready               (d2d_ahb_m_hready),
        .d2d_ahb_m_hresp                (d2d_ahb_m_hresp),
        // D2D inbound subordinate (remote die -> shared SRAM + mailbox)
        .d2d_ahb_s_haddr                (d2d_ahb_s_haddr),
        .d2d_ahb_s_htrans               (d2d_ahb_s_htrans),
        .d2d_ahb_s_hwrite               (d2d_ahb_s_hwrite),
        .d2d_ahb_s_hsize                (d2d_ahb_s_hsize),
        .d2d_ahb_s_hburst               (d2d_ahb_s_hburst),
        .d2d_ahb_s_hprot                (d2d_ahb_s_hprot[3:0]),  // AHB5 [6:0] -> AHB-Lite [3:0]
        .d2d_ahb_s_hwdata               (d2d_ahb_s_hwdata),
        .d2d_ahb_s_hmastlock            (1'b0),                  // ahb_mng has no hmastlock
        .d2d_ahb_s_hrdata               (d2d_ahb_s_hrdata),
        .d2d_ahb_s_hready               (d2d_ahb_s_hready),
        .d2d_ahb_s_hresp                (d2d_ahb_s_hresp),
        // D2D interrupts (assembled below)
        .d2d_irq                        (d2d_irq),
        // Cross-die PHC servo source 0
        .d2d_phc_seconds                (d2d_phc_seconds),
        .d2d_phc_nanoseconds            (d2d_phc_nanoseconds),
        .d2d_phc_hw_cap_seconds         (d2d_phc_hw_cap_seconds),
        .d2d_phc_hw_cap_nanoseconds     (d2d_phc_hw_cap_nanoseconds),
        .d2d_phc_hw_cap_sub_nanoseconds (d2d_phc_hw_cap_sub_nanoseconds),
        .d2d_phc_hw_capture             (d2d_phc_hw_capture),
        .d2d_phc_hw_set_time            (d2d_phc_hw_set_time),
        .d2d_phc_hw_set_seconds         (d2d_phc_hw_set_seconds),
        .d2d_phc_hw_set_nanoseconds     (d2d_phc_hw_set_nanoseconds),
        .d2d_phc_hw_adj_valid           (d2d_phc_hw_adj_valid),
        .d2d_phc_hw_adj_ns_incr_frac    (d2d_phc_hw_adj_ns_incr_frac),
        // CPU sideband
        .network_core_pmuenable         (network_core_pmuenable),
        .chip_core_pmuenable            (chip_core_pmuenable),
        .network_core_nmi               (network_core_nmi),
        .network_core_txev              (network_core_txev),
        .network_core_rxev              (network_core_rxev),
        .network_core_lockup            (network_core_lockup),
        .network_core_sysresetreq       (network_core_sysresetreq),
        .network_core_sleeping          (network_core_sleeping),
        .network_core_sleepdeep         (network_core_sleepdeep),
        .chip_core_nmi                  (chip_core_nmi),
        .chip_core_txev                 (chip_core_txev),
        .chip_core_rxev                 (chip_core_rxev),
        .chip_core_lockup               (chip_core_lockup),
        .chip_core_sysresetreq          (chip_core_sysresetreq),
        .chip_core_sleeping             (chip_core_sleeping),
        .chip_core_sleepdeep            (chip_core_sleepdeep),
        // Debug access port
        .dap_swclktck                   (dap_swclktck),
        .dap_swditms                    (dap_swditms),
        .dap_swdo                       (dap_swdo),
        .dap_swdoen                     (dap_swdoen),
        .dap_tdi                        (dap_tdi),
        .dap_tdo                        (dap_tdo),
        .dap_ntdoen                     (dap_ntdoen),
        .dap_ntrst                      (dap_ntrst),
        .dap_npotrst                    (dap_npotrst),
        .dap_swj_enable                 (dap_swj_enable),
        // RMII PHY
        .rmii_ref_clk                   (rmii_ref_clk),
        .rmii_txd                       (rmii_txd),
        .rmii_tx_en                     (rmii_tx_en),
        .rmii_rxd                       (rmii_rxd),
        .rmii_crs_dv                    (rmii_crs_dv),
        // MDIO
        .md_pad_i                       (md_pad_i),
        .mdc_pad_o                      (mdc_pad_o),
        .md_pad_o                       (md_pad_o),
        .md_padoe_o                     (md_padoe_o),
        // UARTs / CPU1 watchdog
        .uart_rxd                       (uart_rxd),
        .uart_txd                       (uart_txd),
        .chip_core_uart_rxd             (chip_core_uart_rxd),
        .chip_core_uart_txd             (chip_core_uart_txd),
        .chip_core_wdog_reset           (chip_core_wdog_reset),
        // RTC / PTP time
        .rtc_clk                        (rtc_clk),
        .rtc_time_ptp_ns                (rtc_time_ptp_ns),
        .rtc_time_ptp_sec               (rtc_time_ptp_sec),
        .rtc_time_one_pps               (rtc_time_one_pps),
        // Ethernet / PHC interrupts + status
        .eth_irq                        (eth_irq),
        .phc_pps_out                    (phc_pps_out),
        .phc_pps_irq                    (phc_pps_irq),
        .phc_alarm_irq                  (phc_alarm_irq),
        .ha1588_servo_locked            (ha1588_servo_locked),
        // QSPI flash
        .qspi_sclk                      (qspi_sclk),
        .qspi_csn                       (qspi_csn),
        .qspi_io_o                      (qspi_io_o),
        .qspi_io_i                      (qspi_io_i),
        .qspi_io_e                      (qspi_io_e),
        // PL022 SPI
        .spi_sclk                       (spi_sclk),
        .spi_mosi                       (spi_mosi),
        .spi_miso                       (spi_miso),
        .spi_ss                         (spi_ss),
        // HOSTIO4
        .hostio4_p1_in                  (hostio4_p1_in),
        .hostio4_p1_out                 (hostio4_p1_out),
        .hostio4_p1_outen               (hostio4_p1_outen)
    );

    //=========================================================================
    // D2D window sub-decoder. Owns the six HSELs and the data-phase response
    // mux; address/control fan out directly (below) from d2d_ahb_m_*.
    //=========================================================================
    chiplet_d2d_decode u_d2d_decode (
        .hclk           (sys_hclk),
        .hresetn        (sys_hresetn),
        .haddr          (d2d_ahb_m_haddr),
        .htrans         (d2d_ahb_m_htrans),
        .link_active_i      (tc_link_active),   // TX aperture closed while the link is down
        .hrdata         (d2d_ahb_m_hrdata),
        .hready         (d2d_ahb_m_hready),
        .hresp          (d2d_ahb_m_hresp),
        .hsel_tx        (hsel_tx),
        .hsel_fifo      (hsel_fifo),
        .hsel_ptp       (hsel_ptp),
        .hsel_tlapb     (hsel_tlapb),
        .hsel_tcapb     (hsel_tcapb),
        .hsel_peer      (hsel_peer),
        .dph_peer       (dph_peer),
        .hrdata_tx      (hrdata_tx),      .hreadyout_tx    (hreadyout_tx),    .hresp_tx    (hresp_tx),
        .hrdata_fifo    (hrdata_fifo),    .hreadyout_fifo  (hreadyout_fifo),  .hresp_fifo  (hresp_fifo),
        .hrdata_ptp     (hrdata_ptp),     .hreadyout_ptp   (hreadyout_ptp),   .hresp_ptp   (hresp_ptp),
        .hrdata_tlapb   (hrdata_tlapb),   .hreadyout_tlapb (hreadyout_tlapb), .hresp_tlapb (hresp_tlapb),
        .hrdata_tcapb   (hrdata_tcapb),   .hreadyout_tcapb (hreadyout_tcapb), .hresp_tcapb (hresp_tcapb),
        .hrdata_peer    (hrdata_peer),    .hreadyout_peer  (hreadyout_peer),  .hresp_peer  (hresp_peer)
    );

    //=========================================================================
    // AHB->APB bridge: TideLink config window (0x2E03xxxx). The top apb_paddr
    // is a 15-bit unified window (Wlink + FIFO/PTP + addr-translator regs), so
    // ADDRWIDTH=15. PCLKEN=1 runs the APB at HCLK. Slaves see the broadcast
    // HREADY (u_d2d_decode.hready); its response feeds back as *_tlapb.
    //=========================================================================
    cmsdk_ahb_to_apb #(.ADDRWIDTH(15)) u_tlapb_bridge (
        .HCLK       (sys_hclk),
        .HRESETn    (sys_hresetn),
        .PCLKEN     (1'b1),
        .HSEL       (hsel_tlapb),
        .HADDR      (d2d_ahb_m_haddr[14:0]),
        .HTRANS     (d2d_ahb_m_htrans),
        .HSIZE      (d2d_ahb_m_hsize),
        .HPROT      (d2d_ahb_m_hprot),
        .HWRITE     (d2d_ahb_m_hwrite),
        .HREADY     (d2d_ahb_m_hready),
        .HWDATA     (d2d_ahb_m_hwdata),
        .HREADYOUT  (hreadyout_tlapb),
        .HRDATA     (hrdata_tlapb),
        .HRESP      (hresp_tlapb),
        .PADDR      (tlapb_paddr),
        .PENABLE    (tlapb_penable),
        .PWRITE     (tlapb_pwrite),
        .PSTRB      (tlapb_pstrb),
        .PPROT      (tlapb_pprot),
        .PWDATA     (tlapb_pwdata),
        .PSEL       (tlapb_psel),
        .APBACTIVE  (tlapb_apbactive_nc),   // clock-gating hint — no gate here
        .PRDATA     (tlapb_prdata),
        .PREADY     (tlapb_pready),
        .PSLVERR    (tlapb_pslverr)
    );

    //=========================================================================
    // AHB->APB bridge: TideChart config window (0x2E04xxxx). TideChart's APB
    // register offset is narrow; ADDRWIDTH=12 covers the block. TideChart's APB
    // carries NO PSTRB/PPROT, so those bridge outputs are left open.
    //=========================================================================
    cmsdk_ahb_to_apb #(.ADDRWIDTH(12)) u_tcapb_bridge (
        .HCLK       (sys_hclk),
        .HRESETn    (sys_hresetn),
        .PCLKEN     (1'b1),
        .HSEL       (hsel_tcapb),
        .HADDR      (d2d_ahb_m_haddr[11:0]),
        .HTRANS     (d2d_ahb_m_htrans),
        .HSIZE      (d2d_ahb_m_hsize),
        .HPROT      (d2d_ahb_m_hprot),
        .HWRITE     (d2d_ahb_m_hwrite),
        .HREADY     (d2d_ahb_m_hready),
        .HWDATA     (d2d_ahb_m_hwdata),
        .HREADYOUT  (hreadyout_tcapb),
        .HRDATA     (hrdata_tcapb),
        .HRESP      (hresp_tcapb),
        .PADDR      (tcapb_paddr),
        .PENABLE    (tcapb_penable),
        .PWRITE     (tcapb_pwrite),
        .PSTRB      (tcapb_pstrb_nc),       // TideChart APB has no PSTRB
        .PPROT      (tcapb_pprot_nc),       // TideChart APB has no PPROT
        .PWDATA     (tcapb_pwdata),
        .PSEL       (tcapb_psel),
        .APBACTIVE  (tcapb_apbactive_nc),   // clock-gating hint — no gate here
        .PRDATA     (tcapb_prdata),
        .PREADY     (tcapb_pready),
        .PSLVERR    (tcapb_pslverr)
    );

    //=========================================================================
    // TideLink drop-in chiplet interconnect. Defaults keep RAM_ADDR_W=14
    // (tx/fifo apertures are 16 KB -> haddr[13:0]). NUM_PHY_LANES passes to the
    // GPIO PHY pads.
    //=========================================================================
    // SELF_ARM_TRAIN_EN(1): self-latch role_lock on the ROLE_CFG[1] write. The
    // peer-I2C mask handshake never completes on this chiplet, so the default
    // gated latch leaves role_locked=0, which holds the mutual clock enable and the
    // calibrator in reset (cal_done=0, fcsm=0). Opt-in on THIS instance only; other
    // tidelink integrations keep the 1'b0 default. See tidelink/docs/I1_SELFARM_FIX.md.
    // TXGEN_PRESENT(0): tidelink_top defaults this to 1'b1 for the FPGA bring-up
    // builds, so it must be set explicitly HERE or the PL-side TX traffic generator
    // (~1,771 cells, ~2,981 um2) is synthesised into silicon. The ASIC DFT wrapper
    // that would otherwise clear it (tidelink/src/rtl/asic/tidelink_dft_wrapper.sv)
    // is in no flist — the chip instantiates tidelink_top directly.
    tidelink_top #(.NUM_PHY_LANES(NUM_PHY_LANES), .SELF_ARM_TRAIN_EN(1'b1), .AUTO_ANCHOR_EN(1'b1), .TXGEN_PRESENT(1'b0)) u_tidelink (
        // Clocks / resets — all from the SoC clock/reset controller output.
        .hclk       (sys_hclk),
        .hresetn    (sys_hresetn),
        .poresetn   (sys_poresetn),
        .phc_clk    (sys_hclk),       // PHC shares the AHB clock in this build
        .phc_resetn (sys_hresetn),
        // D2D link-clock divider ratio. 3'd0 = /1 bypass — the pre-divider clock
        // path, which is what this tapeout ships and the ONLY ratio signed off.
        //
        // The knob is reachable by the build but INERT in silicon, for two reasons
        // that this literal is not:
        //   (a) No register drives it. That register belongs in TIDELINK's APB
        //       quadrant 11 (paddr[14:13], tidelink_top.sv:846-854 declares
        //       apb_sel_* for quadrants 00/01/10 only and the response mux falls
        //       through for 11), a free 8 KB at SoC 0x2E03_6000-0x2E03_7FFF — NOT
        //       in this chiplet's APB space. Design: docs/design/D2D_RATE_CONTROL_ARCH.md.
        //       It is write-gated on !role_locked_o, because a rate change
        //       invalidates the calibrator's phase offset and is legal only while
        //       the PHY is held in POR; there is no warm-change path. It reaches
        //       u_link_clk_div.ratio_i through a STICKY SOURCE MUX, so this tie
        //       stays the reset-time source rather than a placeholder to delete.
        //   (b) No SDC constrains a divided ratio. ASIC/genus-innovus/inputs/
        //       tidelink_constraints.sdc signs off the /1 configuration only and
        //       pins the bypass leg with set_case_analysis on the divider's enable
        //       flops, so a clean STA says nothing about /2../16. The evidence for
        //       the divided modes is SIMULATION ONLY: cocotb/tidelink_top_pair
        //       passes all 11 tests at /1 /2 /4 /8 /16, which is a digital go/no-go,
        //       not an eye or BER measurement.
        //
        // Connecting this port requires the PINNED tidelink submodule to declare
        // it, or the superproject stops elaborating from its own pin. To test
        // whether it is wired, anchor on the connection form — a bare
        // `grep -c link_clk_div_ratio_i` also counts the mentions in this comment:
        //     grep -cE '^[[:space:]]*\.link_clk_div_ratio_i'
        .link_clk_div_ratio_i (3'd0),
        // ahb_sub — peer aperture (0x2F, address-translated). Full 32-bit haddr;
        // carries hburst/hprot; no hmastlock (reduced shape).
        .ahb_sub_hsel       (hsel_peer),
        .ahb_sub_haddr      (d2d_ahb_m_haddr),
        .ahb_sub_hburst     (d2d_ahb_m_hburst),
        // ---- CHANGE 1 of 2: EWR TIE-DOWN (revert this line alone to undo) ----
        // Force non-cacheable/non-bufferable on the peer path. HPROT[2]
        // (bufferable) is the sole arm of XHB500's early-write-response: the
        // bridge is instantiated as .hprot({3'h0, xhb_sub_hprot}) so hprot[6]
        // is hardwired 0 and `ewr <= hprot[2] & ~hprot[6]`
        // (..._core_wdata.sv:248) reduces to exactly this bit; the same term
        // gates hazard_add (..._core_addr.sv:233) and pause_addr_submit
        // (:155), i.e. the multiple-outstanding-write behaviour the D2D wedge
        // builds on. HPROT[3] (cacheable) is cleared too: it sets write_mod /
        // awcache[1] and clears singles_burst (..._core_addr.sv:147), which
        // lets a fixed-length burst become one multi-beat AXI burst rather
        // than singles. HPROT[1:0] pass through unchanged so the
        // privileged/data mapping into awprot (..._core_addr.sv:254) stays
        // correct. Downstream of the bus matrix, so this covers ALL
        // initiators (both CPUs, DMA-250, DAP, debug bridge, backdoor).
        //
        // ⚠ DEPENDENTS — DO NOT RELAX THIS WITHOUT RE-READING THEM.
        // Forcing hprot[2]=0 here makes hprot[2]=1 UNREACHABLE for peer
        // writes, which in turn makes two existing protections DEAD CODE:
        //   (1) the bufferable/EWR guard above (ewr_peer_wr_aphase arms on
        //       exactly hsel_peer & hready & hwrite & d2d_ahb_m_hprot[2]);
        //   (2) XHB500's Fix-K hazard-list BID correction, which is EWR-only.
        // That is deliberate and is a STRONGER property than the guard gave:
        // the dangerous path cannot be CONSTRUCTED, rather than being caught
        // at runtime. But it means THIS LINE is now the sole thing standing
        // between peer writes and the untested EWR depth>1 path. If it is
        // ever relaxed for throughput (peer bursts issue as AXI singles with
        // it in place, which is a real cost), (1) and (2) must be revived
        // FIRST — by then they will read as dead code and be easy to delete.
        .ahb_sub_hprot      ({2'b00, d2d_ahb_m_hprot[1:0]}),  // force non-cacheable/non-bufferable on the peer path
        .ahb_sub_hsize      (d2d_ahb_m_hsize),
        .ahb_sub_htrans     (d2d_ahb_m_htrans),
        .ahb_sub_hwdata     (d2d_ahb_m_hwdata_q),   // live, frozen on release — see above
        .ahb_sub_hwrite     (d2d_ahb_m_hwrite),
        .ahb_sub_hready     (hready_to_peer),   // NOT d2d_ahb_m_hready — comb loop
        // TideLink's native peer response feeds the EWR-reject mux (*_tl); that mux
        // drives the decoder-facing hrdata_peer / hreadyout_peer / hresp_peer.
        .ahb_sub_hrdata     (hrdata_peer_tl),
        .ahb_sub_hresp      (hresp_peer_tl),
        .ahb_sub_hreadyout  (hreadyout_peer_tl),
        // Per-beat W-consumption strobe — see the peer-write steering block above.
        .ahb_sub_w_beat_consumed_o (w_beat_consumed),
        // ahb_tx — TX aperture (0x2E00). RAM_ADDR_W haddr[13:0]; no hburst/hprot.
        .ahb_tx_hsel        (hsel_tx),
        .ahb_tx_haddr       (d2d_ahb_m_haddr[13:0]),
        .ahb_tx_htrans      (d2d_ahb_m_htrans),
        .ahb_tx_hsize       (d2d_ahb_m_hsize),
        .ahb_tx_hwrite      (d2d_ahb_m_hwrite),
        .ahb_tx_hwdata      (d2d_ahb_m_hwdata),
        .ahb_tx_hready      (d2d_ahb_m_hready),
        .ahb_tx_hrdata      (hrdata_tx),
        .ahb_tx_hresp       (hresp_tx),
        .ahb_tx_hreadyout   (hreadyout_tx),
        // ahb_fifo — local RX FIFO read window (0x2E01). Same reduced shape.
        .ahb_fifo_hsel      (hsel_fifo),
        .ahb_fifo_haddr     (d2d_ahb_m_haddr[13:0]),
        .ahb_fifo_htrans    (d2d_ahb_m_htrans),
        .ahb_fifo_hsize     (d2d_ahb_m_hsize),
        .ahb_fifo_hwrite    (d2d_ahb_m_hwrite),
        .ahb_fifo_hwdata    (d2d_ahb_m_hwdata),
        .ahb_fifo_hready    (d2d_ahb_m_hready),
        .ahb_fifo_hrdata    (hrdata_fifo),
        .ahb_fifo_hresp     (hresp_fifo),
        .ahb_fifo_hreadyout (hreadyout_fifo),
        // ahb_mng — incoming manager from the peer (drives SoC d2d_ahb_s).
        .ahb_mng_haddr      (d2d_ahb_s_haddr),
        .ahb_mng_hburst     (d2d_ahb_s_hburst),
        .ahb_mng_hprot      (d2d_ahb_s_hprot),
        .ahb_mng_hsize      (d2d_ahb_s_hsize),
        .ahb_mng_htrans     (d2d_ahb_s_htrans),
        .ahb_mng_hwdata     (d2d_ahb_s_hwdata),
        .ahb_mng_hwrite     (d2d_ahb_s_hwrite),
        .ahb_mng_hready     (d2d_ahb_s_hready),
        .ahb_mng_hrdata     (d2d_ahb_s_hrdata),
        .ahb_mng_hresp      (d2d_ahb_s_hresp),
        // apb — unified 15-bit config port from u_tlapb_bridge.
        .apb_paddr          (tlapb_paddr),
        .apb_penable        (tlapb_penable),
        .apb_pwrite         (tlapb_pwrite),
        .apb_pstrb          (tlapb_pstrb),
        .apb_pprot          (tlapb_pprot),
        .apb_pwdata         (tlapb_pwdata),
        .apb_psel           (tlapb_psel),
        .apb_prdata         (tlapb_prdata),
        .apb_pready         (tlapb_pready),
        .apb_pslverr        (tlapb_pslverr),
        // Scan / DFT — passed straight through from the chiplet boundary.
        .scan_mode          (scan_mode),
        .scan_asyncrst_ctrl (scan_asyncrst_ctrl),
        .scan_clk           (scan_clk),
        .scan_shift         (scan_shift),
        .scan_in            (scan_in),
        .scan_out           (scan_out),
        // Wlink PLL reference clock (chiplet boundary).
        .user_ref_clk       (user_ref_clk),
        // GPIO PHY pads (chiplet boundary).
        .pad_clk_tx         (pad_clk_tx),
        .pad_tx             (pad_tx),
        .pad_clk_rx         (pad_clk_rx),
        .pad_rx             (pad_rx),
        .idelay_ref_clk     (idelay_ref_clk),
        // ahb_ptp — PTP TX write port (0x2E02). 4-bit register window.
        .ahb_ptp_hsel       (hsel_ptp),
        .ahb_ptp_haddr      (d2d_ahb_m_haddr[3:0]),
        .ahb_ptp_htrans     (d2d_ahb_m_htrans),
        .ahb_ptp_hsize      (d2d_ahb_m_hsize),
        .ahb_ptp_hwrite     (d2d_ahb_m_hwrite),
        .ahb_ptp_hwdata     (d2d_ahb_m_hwdata),
        .ahb_ptp_hready     (d2d_ahb_m_hready),
        .ahb_ptp_hrdata     (hrdata_ptp),
        .ahb_ptp_hresp      (hresp_ptp),
        .ahb_ptp_hreadyout  (hreadyout_ptp),
        // Cross-die PHC servo source 0.
        .phc_hw_capture             (d2d_phc_hw_capture),
        .phc_nanoseconds            (d2d_phc_nanoseconds),
        .phc_seconds                (d2d_phc_seconds),
        .phc_pps                    (phc_pps_out),   // SoC phc_pps_out drives the servo
        .phc_hw_cap_seconds         (d2d_phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (d2d_phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (d2d_phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time            (d2d_phc_hw_set_time),
        .phc_hw_set_seconds         (d2d_phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (d2d_phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (d2d_phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (d2d_phc_hw_adj_ns_incr_frac),
        .phc_locked_i               (1'b1),   // single-link deployment: PHC lock always granted
        // Servo status. NOT routed into the SoC: the SoC's PHC servo_locked
        // input is owned by the ethernet HA1588 servo (D2D_PORT.md §6f). This
        // is TideLink's own PTP servo lock, exported straight to the chiplet
        // boundary for bring-up observability instead (see the port comment).
        .servo_locked               (servo_locked_o),
        // Interrupt outputs.
        .released_credits_irq (tl_released_credits_irq),
        .doorbell_irq         (tl_doorbell_irq),
        .packet_committed_irq (tl_packet_committed_irq),
        .ptp_irq              (tl_ptp_irq),
        .perf_irq             (tl_perf_irq),
        .wlink_irq            (tl_wlink_irq),
        // TideChart AXI-Stream seam.
        .tc_axis_tx_tvalid    (tc_tx_tvalid),
        .tc_axis_tx_tdata     (tc_tx_tdata),
        .tc_axis_tx_tready    (tc_tx_tready),
        .tc_axis_rx_tvalid    (tc_rx_tvalid),
        .tc_axis_rx_tdata     (tc_rx_tdata),
        .tc_axis_rx_tready    (tc_rx_tready),
        // QoS priority hint — TideChart TC_QOS_CFG not wired in v1; fixed priority.
        .tc_qos_priority      (3'b000),
        // Congestion sideband to TideChart.
        .tl_local_link_state_o  (tc_local_link_state),
        .tl_link_state_change_o (tc_link_state_change),
        .tl_ewma_credit_o       (tl_ewma_credit_o),
        .tl_bcast_ack_i         (tc_bcast_ack),
        // Link status.
        .link_active            (tc_link_active),
        // Data-mode status (FCSM>=4) — drives the TideChart election gate below.
        .tl_data_mode_o         (tc_data_mode),
        // Reset output — no consumer at this integration level.
        .d2d_reset_o            (d2d_reset_o),
        // Role selection (strap in; resolved role/lock outputs unused in v1).
        .role_strap_i           (role_strap_i),
        .role_is_master_o       (role_is_master_o),
        .role_locked_o          (role_locked_o),
        .apb_debug_unlock_i     (apb_debug_unlock_i),
        .mask_hs_bypass_i       (mask_hs_bypass_i),
        // Auto-negotiation.
        .nego_priority_i        (nego_priority_i),
        .puf_seed               (puf_seed),
        .puf_ready              (puf_ready),
        .nego_error_irq         (tl_nego_error_irq),
        .train_fail_irq         (tl_train_fail_irq),
        // I2C sideband pads (chiplet boundary).
        .i2c_scl_i              (i2c_scl_i),
        .i2c_scl_o              (i2c_scl_o),
        .i2c_scl_t              (i2c_scl_t),
        .i2c_sda_i              (i2c_sda_i),
        .i2c_sda_o              (i2c_sda_o),
        .i2c_sda_t              (i2c_sda_t),
        // I2C sideband AXI slave — no CPU-driven I2C master path in v1; drive all
        // request inputs inactive (no transactions can start), and sink every
        // response output into a named `*_nc` dead end (see the sink block above).
        .s_i2c_axi_awvalid  (1'b0),
        .s_i2c_axi_awid     (2'b00),
        .s_i2c_axi_awaddr   (4'h0),
        .s_i2c_axi_awlen    (8'h00),
        .s_i2c_axi_awsize   (3'b000),
        .s_i2c_axi_awburst  (2'b00),
        .s_i2c_axi_awlock   (1'b0),
        .s_i2c_axi_awcache  (4'h0),
        .s_i2c_axi_awprot   (3'b000),
        .s_i2c_axi_awready  (tl_i2c_axi_awready_nc),
        .s_i2c_axi_wvalid   (1'b0),
        .s_i2c_axi_wdata    (32'h0),
        .s_i2c_axi_wstrb    (4'h0),
        .s_i2c_axi_wlast    (1'b0),
        .s_i2c_axi_wready   (tl_i2c_axi_wready_nc),
        .s_i2c_axi_bvalid   (tl_i2c_axi_bvalid_nc),
        .s_i2c_axi_bid      (tl_i2c_axi_bid_nc),
        .s_i2c_axi_bresp    (tl_i2c_axi_bresp_nc),
        .s_i2c_axi_bready   (1'b0),
        .s_i2c_axi_arvalid  (1'b0),
        .s_i2c_axi_arid     (2'b00),
        .s_i2c_axi_araddr   (4'h0),
        .s_i2c_axi_arlen    (8'h00),
        .s_i2c_axi_arsize   (3'b000),
        .s_i2c_axi_arburst  (2'b00),
        .s_i2c_axi_arlock   (1'b0),
        .s_i2c_axi_arcache  (4'h0),
        .s_i2c_axi_arprot   (3'b000),
        .s_i2c_axi_arready  (tl_i2c_axi_arready_nc),
        .s_i2c_axi_rvalid   (tl_i2c_axi_rvalid_nc),
        .s_i2c_axi_rid      (tl_i2c_axi_rid_nc),
        .s_i2c_axi_rdata    (tl_i2c_axi_rdata_nc),
        .s_i2c_axi_rresp    (tl_i2c_axi_rresp_nc),
        .s_i2c_axi_rlast    (tl_i2c_axi_rlast_nc),
        .s_i2c_axi_rready   (1'b0),
        // I2C interrupts.
        .i2c_nbsy_irq       (tl_i2c_nbsy_irq),
        .i2c_nrd_empty_irq  (tl_i2c_nrd_empty_irq)
    );

    //=========================================================================
    // TideChart controller (via the flattening shim). Single link port
    // (NUM_PORTS=1) facing this one TideLink; FC_DATA_W=48 matches the seam.
    //=========================================================================
    tidechart_shim #(
        .NUM_PORTS    (1),
        .FC_DATA_W    (48),
        .DEVICE_CLASS (DEVICE_CLASS)     // per-die election priority strap
    ) u_tidechart (
        .clk    (sys_hclk),
        .resetn (sys_hresetn),
        // AXI-Stream seam. rx = TideLink -> TideChart, tx = TideChart -> TideLink.
        .tc_axis_rx_tvalid          (tc_rx_tvalid),
        .tc_axis_rx_tdata_flat      (tc_rx_tdata),
        .tc_axis_rx_tready          (tc_rx_tready),
        .tc_axis_tx_tvalid          (tc_tx_tvalid),
        .tc_axis_tx_tdata_flat      (tc_tx_tdata),
        .tc_axis_tx_tready          (tc_tx_tready),
        // The root election gates on DATA-MODE (FCSM>=4), not on the premature
        // tc_link_active (== role_locked_o). NUM_PORTS=1 here, so the 1-bit
        // tc_data_mode maps directly. tc_link_active is still driven and still
        // consumed by link_active_o and u_d2d_decode.
        .link_active                (tc_data_mode),
        // Root-election tie-break, reused from the role strap (master ties 0,
        // slave ties 1) so it costs no extra pad. It MUST differ between the two
        // dies: left unconnected the election falls back to LFSR/PUF entropy and
        // both dies can claim root. This overloads role_strap_i with a second
        // meaning — if the role and the election root ever need to differ, this
        // becomes a real port.
        .device_strap               ({7'b0, role_strap_i}),
        // Congestion sideband.
        .local_link_state_i_flat    (tc_local_link_state),
        .local_link_state_change_i  (tc_link_state_change),
        .local_bcast_ack_o          (tc_bcast_ack),
        // APB from u_tcapb_bridge (12-bit bridge PADDR sliced to APB_ADDR_W=8).
        .apb_paddr                  (tcapb_paddr[7:0]),
        .apb_psel                   (tcapb_psel),
        .apb_penable                (tcapb_penable),
        .apb_pwrite                 (tcapb_pwrite),
        .apb_pwdata                 (tcapb_pwdata),
        .apb_prdata                 (tcapb_prdata),
        .apb_pready                 (tcapb_pready),
        .apb_pslverr                (tcapb_pslverr),
        // Interrupt.
        .tidechart_irq              (tc_tidechart_irq),
        // IRQC AXI-Stream pair — the ahb-chiplet-irqc block is NOT present in this
        // integration, so both streams are held idle: TC->IRQC has no consumer
        // (tready low), IRQC->TC has no producer (tvalid low). The output ends go
        // to named `*_nc` sinks (see the sink block above).
        .tc_to_irqc_tvalid_o        (tc_to_irqc_tvalid_nc),
        .tc_to_irqc_tdata_o         (tc_to_irqc_tdata_nc),
        .tc_to_irqc_tready_i        (1'b0),
        .tc_to_irqc_tlast_o         (tc_to_irqc_tlast_nc),
        .irqc_to_tc_tvalid_i        (1'b0),
        .irqc_to_tc_tdata_i         (32'h0),
        .irqc_to_tc_tready_o        (irqc_to_tc_tready_nc)
    );

    //=========================================================================
    // D2D interrupt vector. [7:0] -> CPU0 NVIC (data plane), [15:8] -> CPU1 NVIC
    // (link management). Fixed assignment per the wrapper contract.
    //=========================================================================
    assign d2d_irq = {
        1'b0,                     // [15] reserved
        tc_tidechart_irq,         // [14] TideChart
        tl_i2c_nrd_empty_irq,     // [13]
        tl_i2c_nbsy_irq,          // [12]
        tl_perf_irq,              // [11]
        tl_train_fail_irq,        // [10]
        tl_nego_error_irq,        // [9]
        tl_wlink_irq,             // [8]
        4'b0000,                  // [7:4] reserved
        tl_ptp_irq,               // [3]
        tl_packet_committed_irq,  // [2]
        tl_released_credits_irq,  // [1]
        tl_doorbell_irq           // [0]
    };

endmodule
