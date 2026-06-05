// -----------------------------------------------------------------------------
// Generic Chiplet Controller with Runtime Master/Slave Role Selection
//
// Wraps the Chisel-generated Wlink core with:
//   - Both I2C master and I2C slave cores
//   - A role register block (master/slave selection before link-up)
//   - APB mux for Wlink register access (master vs slave mode)
//   - Wlink POR gating until role is locked
//
// The role is determined by a strap pin default, optionally overridden by
// a CPU register write, and locked before the Wlink link trains. Once locked,
// only a full power-on reset (poresetn) can change the role.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
// -----------------------------------------------------------------------------

module axi_chiplet_controller #(
    // SoC Labs §9 auto-cal enable. When 0 (default), the calibrator FSM is
    // held inert (role_locked tied to 0 from the calibrator's perspective)
    // so its outputs stay at 0 and the SW-override OR-mux is bit-exact
    // unchanged from the pre-autocal behaviour — required to keep the
    // cocotb hierarchical-force sweep tests passing. FPGA / ASIC builds
    // override this to 1 from tidelink_top.sv.
    parameter AUTOCAL_ENABLE = 1'b0,
    // SoC Labs §9 structural fix (2026-05-18): per-lane IDELAYE2 RX delay
    // element driven by the calibrator's existing per-lane phase value.
    // 0 (default) = bit-exact passthrough, NO Xilinx primitive — keeps the
    // cocotb wlink_pair / phy_align sweep TBs and the ASIC flist
    // (tidelink_top_full_asic.flist) elaborating identically. The FPGA
    // build (tidelink_top.sv → fpga build) overrides this to 1 and also
    // defines TIDELINK_USE_IDELAY. See tidelink_idelay_rx.sv.
    parameter USE_IDELAY     = 1'b0,
    // §9 clock fix: recovered-RX-clock global BUFG (FPGA only). Default 0 =
    // bit-exact passthrough (sim/ASIC/UVM); FPGA wrapper sets 1. Same
    // component.xml mechanism as USE_IDELAY. See tidelink_rxclk_buf.sv.
    parameter USE_CLKBUF     = 1'b0,
    // §9 T3a (2026-05-19): per-lane self-aligning RX. Each WavD2DGpioRx hunts
    // for its peer's training byte in the io_pad stream and slips `count` to
    // align to the byte boundary, killing the per-deploy 16-cycle count-phase
    // lottery that left master/slave anti-correlated. Default 0 = bit-exact
    // passthrough (sim/ASIC/UVM); FPGA wrapper sets 1 via component.xml.
    parameter USE_T3A        = 1'b0,

    // Phase 2 autonomy — POR-default value for NEGO_TRAIN_CFG (Region 8 slot
    // 3'h3, MMIO 0x4403_210C). Bit[0]=train_auto_en, bit[1]=train_sw_step,
    // bits[7:4]=poll_timeout (FSM uses T_POLL_TIMEOUT_DEFAULT when 0),
    // bits[15:8]=fsm_wait_hi (FSM uses T_TRAIN_FSM_DEFAULT when 0).
    //
    // Default 16'h0001 → train_auto_en=1 at POR, all timers fall back to
    // FSM-baked defaults. This makes the ASIC + FPGA + sim all enter the
    // autonomous training arm out of reset without any SW config write,
    // matching the v1 autonomy contract. Cocotb tests that need the legacy
    // train_auto_en=0 path (where the FSM legacy-bypasses to ST_NEGO_DONE
    // directly) override this parameter via the testbench wrapper.
    parameter [15:0] NEGO_TRAIN_CFG_RESET = 16'h0001,
    // NEGO_CFG POR value.
    // 7'h61 = nego_en[0]=1 + nego_force_lock[5]=1 + mask_hs_auto_en[6]=1
    //   → autoneg FSM engages out of POR, latches role_lock on completion,
    //     and runs the mask-handshake states (gates ST_NEGO_DONE_PRE).
    // Companion to NEGO_TRAIN_CFG_RESET — the two together make the chiplet
    // POR-boot directly into autonomous bring-up without any SW write.
    // Cocotb tests that need the legacy SW-driven path override to 7'h00.
    parameter [6:0]  NEGO_CFG_RESET       = 7'h61
) (

    // ── Clocks and Resets ────────────────────────────────────────────────
    input  wire             apb_clk,
    input  wire             app_clk,
    input  wire             user_hsclk,

    input  wire             poresetn,           // Power-on reset (active-low, clears role)
    input  wire             hresetn,            // System reset (active-low, preserves role)

    input  wire             sb_reset_in,
    output wire             sb_reset_out,
    output wire             sb_wake,

    // ── Role Configuration ───────────────────────────────────────────────
    input  wire             role_strap_i,        // 0=master, 1=slave (strap default)
    output wire             role_is_master_o,    // Effective role: 1=master
    output wire             role_locked_o,       // 1=role is locked, Wlink active

    // ── Debug strap: when 1, ungates external APB writes to Wlink in slave
    //                mode. Lets the slave's PYNQ Linux drive Wlink config
    //                directly, without I2C from the master. Bring-up debug
    //                only — not for production silicon.
    //
    //                DEBUG STRAP, tied to 0 in production, TAP-driven in
    //                debug only. As of Phase 4 of the autonomy plan
    //                (docs/ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_*),
    //                the FPGA bring-up flow (deploy_pair.sh) no longer
    //                asserts this strap at deploy: the autoneg FSM's
    //                mask_hs_local_match path drives mask_hs_match=1
    //                autonomously (see line 433). The AXI GPIO at
    //                0x4404_1000 is retained on the FPGA bitstream for
    //                future TAP-style debug poke, but is not written by
    //                the standard deploy script.
    input  wire             apb_debug_unlock_i,

    // ── Mask-handshake bypass strap: when 1, the peer-mask gate on
    //                role_lock is held permanently open. Default value
    //                is implementation-defined; production silicon ties
    //                this to 0 to enforce the handshake. Bring-up flows
    //                that don't yet drive the handshake (UVM, current
    //                FPGA bring-up scripts) tie it to 1.
    //
    //                DEBUG STRAP, tied to 0 in production, TAP-driven in
    //                debug only. Sibling of apb_debug_unlock_i — both are
    //                hardwired off on the chiplet bond pads and only
    //                asserted via a JTAG/TAP path for bench debug.
    input  wire             mask_hs_bypass_i,

    // ── Auto-Negotiation ────────────────────────────────────────────────
    input  wire [15:0]      nego_priority_i,     // External priority (OTP/UID)
    input  wire [15:0]      puf_seed,            // From TideChart PUF sampler
    input  wire             puf_ready,           // PUF sampling complete
    output wire             nego_error_irq,      // Negotiation error interrupt
    // Phase 1 G1b: sticky IRQ asserted when the autoneg FSM enters
    // ST_TRAIN_FAIL. Latches on the rising edge of train_fail_irq_w and
    // is cleared by a W1C to Region 8 slot 3'h3 (NEGO_TRAIN_CFG)
    // bit[16]. Held separately from `nego_error_irq` so existing handlers
    // don't get re-routed.
    output wire             train_fail_irq_o,

    // ── Controller Register Pass-Through (from tidelink_apb_regs) ────────
    //   ctrl_reg_addr widened to 5 bits (Bug N7/N8 silicon observability,
    //   2026-06-01). bits[4:3] now selects between three regions:
    //     2'b01 → Region 4 (ROLE/I²C/NEGO   @ 0x080-0x09C)
    //     2'b10 → Region 8 (SWI_*/NEGO_TRAIN_* @ 0x100-0x11C)
    //     2'b11 → Region C (autoneg observability @ 0x180-0x19C, RO)
    //
    // Bug N2 fix (2026-05-29): the input ports were renamed to
    // `apb_ctrl_reg_*` (external CPU/AHB→APB master from tidelink_apb_regs).
    // Internal nets `ctrl_reg_*` are OR-merged below with a slv_apb_*
    // (I²C-driven) decode so that the peer's I²C-write to Region 4/8 lands
    // on the same decoder. See block titled "Bug N2 fix" below.
    input  wire             apb_ctrl_reg_write,
    input  wire  [4:0]      apb_ctrl_reg_addr,
    input  wire  [31:0]     apb_ctrl_reg_wdata,
    output logic [31:0]     ctrl_reg_rdata,

    // ── Wlink APB (external, from tidelink_top decode) ───────────────────
    input  wire             apb_psel,
    input  wire  [12:0]     apb_paddr,
    input  wire             apb_penable,
    input  wire  [2:0]      apb_pprot,
    input  wire  [3:0]      apb_pstrb,
    input  wire             apb_pwrite,
    input  wire  [31:0]     apb_pwdata,
    output wire  [31:0]     apb_prdata,
    output wire             apb_pready,
    output wire             apb_pslverr,

    // ── AXI Target (from XHB500 AHB→AXI bridge) ─────────────────────────
    input  wire             axi_tgt_0_aw_valid,
    output wire             axi_tgt_0_aw_ready,
    input  wire  [11:0]     axi_tgt_0_aw_bits_id,
    input  wire  [35:0]     axi_tgt_0_aw_bits_addr,
    input  wire  [7:0]      axi_tgt_0_aw_bits_len,
    input  wire  [2:0]      axi_tgt_0_aw_bits_size,
    input  wire  [1:0]      axi_tgt_0_aw_bits_burst,
    input  wire             axi_tgt_0_aw_bits_lock,
    input  wire  [3:0]      axi_tgt_0_aw_bits_cache,
    input  wire  [2:0]      axi_tgt_0_aw_bits_prot,
    input  wire  [3:0]      axi_tgt_0_aw_bits_qos,

    input  wire             axi_tgt_0_w_valid,
    output wire             axi_tgt_0_w_ready,
    input  wire  [31:0]     axi_tgt_0_w_bits_data,
    input  wire  [3:0]      axi_tgt_0_w_bits_strb,
    input  wire             axi_tgt_0_w_bits_last,

    output wire             axi_tgt_0_b_valid,
    input  wire             axi_tgt_0_b_ready,
    output wire  [11:0]     axi_tgt_0_b_bits_id,
    output wire  [1:0]      axi_tgt_0_b_bits_resp,

    input  wire             axi_tgt_0_ar_valid,
    output wire             axi_tgt_0_ar_ready,
    input  wire  [11:0]     axi_tgt_0_ar_bits_id,
    input  wire  [35:0]     axi_tgt_0_ar_bits_addr,
    input  wire  [7:0]      axi_tgt_0_ar_bits_len,
    input  wire  [2:0]      axi_tgt_0_ar_bits_size,
    input  wire  [1:0]      axi_tgt_0_ar_bits_burst,
    input  wire             axi_tgt_0_ar_bits_lock,
    input  wire  [3:0]      axi_tgt_0_ar_bits_cache,
    input  wire  [2:0]      axi_tgt_0_ar_bits_prot,
    input  wire  [3:0]      axi_tgt_0_ar_bits_qos,

    output wire             axi_tgt_0_r_valid,
    input  wire             axi_tgt_0_r_ready,
    output wire  [11:0]     axi_tgt_0_r_bits_id,
    output wire  [31:0]     axi_tgt_0_r_bits_data,
    output wire  [1:0]      axi_tgt_0_r_bits_resp,
    output wire             axi_tgt_0_r_bits_last,

    // ── AXI Initiator (to XHB500 AXI→AHB bridge) ────────────────────────
    output wire             axi_ini_0_aw_valid,
    input  wire             axi_ini_0_aw_ready,
    output wire  [11:0]     axi_ini_0_aw_bits_id,
    output wire  [35:0]     axi_ini_0_aw_bits_addr,
    output wire  [7:0]      axi_ini_0_aw_bits_len,
    output wire  [2:0]      axi_ini_0_aw_bits_size,
    output wire  [1:0]      axi_ini_0_aw_bits_burst,
    output wire             axi_ini_0_aw_bits_lock,
    output wire  [3:0]      axi_ini_0_aw_bits_cache,
    output wire  [2:0]      axi_ini_0_aw_bits_prot,
    output wire  [3:0]      axi_ini_0_aw_bits_qos,

    output wire             axi_ini_0_w_valid,
    input  wire             axi_ini_0_w_ready,
    output wire  [31:0]     axi_ini_0_w_bits_data,
    output wire  [3:0]      axi_ini_0_w_bits_strb,
    output wire             axi_ini_0_w_bits_last,

    input  wire             axi_ini_0_b_valid,
    output wire             axi_ini_0_b_ready,
    input  wire  [11:0]     axi_ini_0_b_bits_id,
    input  wire  [1:0]      axi_ini_0_b_bits_resp,

    output wire             axi_ini_0_ar_valid,
    input  wire             axi_ini_0_ar_ready,
    output wire  [11:0]     axi_ini_0_ar_bits_id,
    output wire  [35:0]     axi_ini_0_ar_bits_addr,
    output wire  [7:0]      axi_ini_0_ar_bits_len,
    output wire  [2:0]      axi_ini_0_ar_bits_size,
    output wire  [1:0]      axi_ini_0_ar_bits_burst,
    output wire             axi_ini_0_ar_bits_lock,
    output wire  [3:0]      axi_ini_0_ar_bits_cache,
    output wire  [2:0]      axi_ini_0_ar_bits_prot,
    output wire  [3:0]      axi_ini_0_ar_bits_qos,

    input  wire             axi_ini_0_r_valid,
    output wire             axi_ini_0_r_ready,
    input  wire  [11:0]     axi_ini_0_r_bits_id,
    input  wire  [31:0]     axi_ini_0_r_bits_data,
    input  wire  [1:0]      axi_ini_0_r_bits_resp,
    input  wire             axi_ini_0_r_bits_last,

    // ── General Bus (interrupt forwarding) ───────────────────────────────
    input  wire  [31:0]     generalbus_in,
    output wire  [31:0]     generalbus_out,

    // ── TideLink FC Node (packed bus) ────────────────────────────────────
    input  wire  [49:0]     tidelink_in,
    output wire  [49:0]     tidelink_out,

    // ── PTP Short Packet (packed bus) ────────────────────────────────────
    input  wire  [25:0]     ptp_in,
    output wire  [25:0]     ptp_out,

    // ── TX Link Idle ─────────────────────────────────────────────────────
    output wire             tx_link_idle,

    // ── I2C Sideband AXI (master mode: CPU → I2C master → remote) ───────
    input  wire             s_i2c_axi_awvalid,
    input  wire  [1:0]      s_i2c_axi_awid,
    input  wire  [3:0]      s_i2c_axi_awaddr,
    input  wire  [7:0]      s_i2c_axi_awlen,
    input  wire  [2:0]      s_i2c_axi_awsize,
    input  wire  [1:0]      s_i2c_axi_awburst,
    input  wire             s_i2c_axi_awlock,
    input  wire  [3:0]      s_i2c_axi_awcache,
    input  wire  [2:0]      s_i2c_axi_awprot,
    output wire             s_i2c_axi_awready,

    input  wire             s_i2c_axi_wvalid,
    input  wire  [31:0]     s_i2c_axi_wdata,
    input  wire  [3:0]      s_i2c_axi_wstrb,
    input  wire             s_i2c_axi_wlast,
    output wire             s_i2c_axi_wready,

    output wire             s_i2c_axi_bvalid,
    output wire  [1:0]      s_i2c_axi_bid,
    output wire  [1:0]      s_i2c_axi_bresp,
    input  wire             s_i2c_axi_bready,

    input  wire             s_i2c_axi_arvalid,
    input  wire  [1:0]      s_i2c_axi_arid,
    input  wire  [3:0]      s_i2c_axi_araddr,
    input  wire  [7:0]      s_i2c_axi_arlen,
    input  wire  [2:0]      s_i2c_axi_arsize,
    input  wire  [1:0]      s_i2c_axi_arburst,
    input  wire             s_i2c_axi_arlock,
    input  wire  [3:0]      s_i2c_axi_arcache,
    input  wire  [2:0]      s_i2c_axi_arprot,
    output wire             s_i2c_axi_arready,

    output wire             s_i2c_axi_rvalid,
    output wire  [1:0]      s_i2c_axi_rid,
    output wire  [31:0]     s_i2c_axi_rdata,
    output wire  [1:0]      s_i2c_axi_rresp,
    output wire             s_i2c_axi_rlast,
    input  wire             s_i2c_axi_rready,

    // ── I2C Interrupts ───────────────────────────────────────────────────
    output wire             i2c_nbsy_irq,
    output wire             i2c_nrd_empty_irq,

    // ── I2C Pins (tristate, active-low drive) ────────────────────────────
    input  wire             i2c_scl_i,
    output wire             i2c_scl_o,
    output wire             i2c_scl_t,
    input  wire             i2c_sda_i,
    output wire             i2c_sda_o,
    output wire             i2c_sda_t,

    // ── Scan / DFT ───────────────────────────────────────────────────────
    input  wire             scan_mode,
    input  wire             scan_asyncrst_ctrl,
    input  wire             scan_clk,
    input  wire             scan_shift,
    input  wire             scan_in,
    output wire             scan_out,

    // ── Wlink Interrupt ──────────────────────────────────────────────────
    output wire             interrupt,

    // ── PHY Pads ─────────────────────────────────────────────────────────
    output wire             pad_clk_tx,
    output wire  [7:0]      pad_tx,
    input  wire             pad_clk_rx,
    input  wire  [7:0]      pad_rx,

    // ── §9 per-lane IDELAYE2 RX delay (FPGA only; USE_IDELAY=1) ───────────
    // 200 MHz IDELAYCTRL reference clock + its active-high reset. Both are
    // completely unused when USE_IDELAY=0 (passthrough) — tie to 1'b0 in
    // sim / ASIC. The FPGA BD drives idelay_ref_clk from a clk_wiz 200 MHz
    // output (see tidelink_design.tcl change spec in the agent report).
    input  wire             idelay_ref_clk,
    input  wire             idelay_rst,

    // ── v2 Eye visibility (docs/EYE_VISIBILITY_RTL_PROPOSAL.md) ───────────
    // Calibrator control surface (driven by tidelink_eye_regs at top level).
    input  wire  [2:0]      swi_eye_lane_sel_i,
    input  wire  [31:0]     swi_eye_dwell_us_i,
    input  wire  [31:0]     swi_eye_ctrl_i,
    input  wire  [6:0]      eye_score_idx_i,
    // Calibrator status / score readouts back to the eye_regs shim.
    output wire  [31:0]     eye_status_o,
    output wire  [5:0]      eye_score_data_o,
    output wire             eye_score_lane_passed_o,
    output wire  [5:0]      eye_score_best_o,
    output wire  [2:0]      eye_score_best_slip_o,
    output wire  [3:0]      eye_score_best_phase_o,
    // tidelink-gpio-phy lane_checker control & observability (replaces the
    // pre-rewrite crc_err_cnt counters; see deps/tidelink-gpio-phy spec §6, §10).
    input  wire  [23:0]     lane_lock_thresh_i,        // 8 × 3-bit per lane
    input  wire             lane_clear_noise_i,        // 1-cycle pulse from APB
    output wire  [7:0]      lane_mismatch_pulse_o,     // 1-cycle pulse per lane
    output wire  [15:0]     lane_wire_status_o,        // 8 × 2-bit wire status
    output wire  [39:0]     lane_dist_raw_o,           // 8 × 5-bit
    output wire  [39:0]     lane_dist_voted_o,         // 8 × 5-bit
    output wire  [39:0]     lane_dwell_min_dist_o,     // 8 × 5-bit
    output wire  [39:0]     lane_noise_min_o,          // 8 × 5-bit
    output wire  [39:0]     lane_noise_max_o,          // 8 × 5-bit
    output wire  [39:0]     lane_noise_mean_o,         // 8 × 5-bit
    output wire  [39:0]     lane_noise_current_o,      // 8 × 5-bit
    output wire  [7:0]      lane_canary_pass_o,        // bit-order canary
    output wire  [7:0]      lane_canary_valid_o,       // canary measurement done
    // Recovered RX clock — for the tidelink-gpio-phy APB slave's link_rx_clk
    // port at tidelink_top scope (spec §6 CDC contract; spec §10).
    output wire             link_rx_clk_o,
    // EYE_LAST_LATCHED mirror (current calibrator outputs).
    output wire  [23:0]     eye_last_slip_o,
    output wire  [7:0]      eye_last_lane_fault_o,
    // SoC Labs Bug-A FCSM observation 2026-06-02 — surface the three FCSM
    // gate signals up to tidelink_top so mark_debug at top level can route
    // them through the dbg_hub for ILA capture. (mark_debug inside the IP
    // package gets stripped by the IP-packaging step; doing it at top
    // works — see fc_rx_fifo_wdata pattern.)
    output wire             obs_a2l_replay_link_valid_o,
    output wire  [7:0]      obs_fe_rx_credit_max_o,
    output wire             obs_fe_rx_is_full_o,
    // SoC Labs Bug-A FCSM observation 2026-06-03
    output wire             obs_a2l_replay_app_valid_o
);

    // =====================================================================
    // Internal resets (Wlink uses active-high)
    // =====================================================================
    wire apb_reset     = ~hresetn;
    wire app_clk_reset = ~hresetn;

    // =====================================================================
    // Bug N2 fix (2026-05-29) — slv_apb_* fan-out to Region 4/8 + readback
    //
    // Diagnosis (docs/BUG_N2_DIAGNOSIS.md): the slave's I²C-driven APB ingress
    // (slv_apb_*) used to be muxed solely onto the Wlink core (wl_apb_*).
    // Region 4 / Region 8 chiplet-controller registers (ROLE_CFG, NEGO_*,
    // SWI_TRAINING_MODE @ 0x100, SWI_LANE_STATUS @ 0x108, …) sit BEHIND
    // ctrl_reg_write / ctrl_reg_addr / ctrl_reg_wdata, which up to now
    // were driven ONLY by the external CPU/AHB→APB master (renamed to
    // apb_ctrl_reg_* on this module's input port). The peer-side I²C
    // burst from the master autoneg FSM (ST_TRAIN_ENTER, etc.) therefore
    // never reached the slave's chiplet-controller register decoder, so
    // swi_training_mode_r stayed at 0 and ST_TRAIN_POLL_PEER timed out.
    //
    // Fix shape (Shape B from the diagnosis): inside this module, decode
    // slv_apb_* and OR-merge a locally-generated ctrl_reg_* path with the
    // external (apb_ctrl_reg_*) path. The merged ctrl_reg_* nets feed all
    // the existing Region 4 and Region 8 write logic untouched, so this
    // change is a strict fan-in widening — Wlink keeps owning every
    // address that does NOT decode to Region 4 / Region 8.
    //
    // Forward declarations: slv_apb_* are driven by the AXIL→APB bridge
    // instance below (u_axil2apb), but are needed up here so the merged
    // ctrl_reg_* wires can be referenced from the Role / Region-4 /
    // Region-8 logic that follows.
    // =====================================================================
    wire            slv_apb_psel;
    wire [12:0]     slv_apb_paddr;
    wire            slv_apb_penable;
    wire [2:0]      slv_apb_pprot;
    wire            slv_apb_pwrite;
    wire [31:0]     slv_apb_pwdata;
    wire [3:0]      slv_apb_pstrb;

    // slv_apb_* targets the chiplet-controller register decoder when its
    // address falls in Region 4 (paddr[8:5]=4'b0100 → 0x080-0x09C) or
    // Region 8 (paddr[8:5]=4'b1000 → 0x100-0x11C). Mirrors the external
    // path's decode in tidelink_apb_regs.sv:443-445.
    //
    // Note: no need to gate on !role_is_master here — the i2c_slave core
    // (drives slv_apb_*) is held in reset whenever role_is_master=1
    // (see i2c_slv_reset below: `~hresetn | role_is_master`). So
    // slv_apb_psel never pulses while we are master, and we avoid a
    // forward-reference to role_is_master.
    wire slv_apb_ctrl_region4 = (slv_apb_paddr[8:5] == 4'b0100);
    wire slv_apb_ctrl_region8 = (slv_apb_paddr[8:5] == 4'b1000);
    wire slv_apb_ctrl_regionC = (slv_apb_paddr[8:5] == 4'b1100);
    wire slv_apb_ctrl_hit     = slv_apb_psel &&
                                (slv_apb_ctrl_region4 || slv_apb_ctrl_region8 || slv_apb_ctrl_regionC);
    // Single-beat APB write completion: psel & penable & pwrite — one cycle.
    wire slv_apb_ctrl_write   = slv_apb_ctrl_hit && slv_apb_penable && slv_apb_pwrite;

    // ctrl_reg_addr layout (see tidelink_apb_regs.sv).
    //   ctrl_reg_addr = {paddr[8:7], paddr[4:2]} (5 bits)
    //     bits[4:3] = 2'b01 → Region 4
    //     bits[4:3] = 2'b10 → Region 8
    //     bits[4:3] = 2'b11 → Region C (Bug N7/N8 observability, RO)
    wire [4:0]  slv_ctrl_reg_addr  = {slv_apb_paddr[8:7], slv_apb_paddr[4:2]};
    wire [31:0] slv_ctrl_reg_wdata = slv_apb_pwdata;

    // OR-merge the external APB-driven ctrl_reg_* path with the I²C-driven
    // (slv_apb_*) path. The external CPU is idle during autonomous bring-up,
    // so cycle-level conflict is not expected; if both fired together the
    // slv_apb path wins on write data (mux-after-OR semantics) and the FSM
    // would observe a single ctrl_reg_write strobe. In practice the external
    // path is quiescent during ST_TRAIN_ENTER, so the priority is moot —
    // documented here so a future arbitration scheme can replace the OR if
    // needed.
    //
    // IMPORTANT: ctrl_reg_addr must be driven from slv_apb_* whenever the
    // I²C path is targeting Region 4/8/C — INCLUDING READS — because the
    // combinational ctrl_reg_rdata mux below uses ctrl_reg_addr[4:3] to
    // pick Region 4 / Region 8 / Region C, and region{4,8,C}_rdata index
    // off ctrl_reg_addr[2:0]. The WRITE strobe (ctrl_reg_write) on the
    // other hand stays gated on penable & pwrite so the always_ff blocks
    // below only fire on a real write completion.
    wire        ctrl_reg_write = apb_ctrl_reg_write || slv_apb_ctrl_write;
    wire [4:0]  ctrl_reg_addr  = slv_apb_ctrl_hit ? slv_ctrl_reg_addr
                                                  : apb_ctrl_reg_addr;
    wire [31:0] ctrl_reg_wdata = slv_apb_ctrl_write ? slv_ctrl_reg_wdata
                                                    : apb_ctrl_reg_wdata;

    // =====================================================================
    // Role Register Block
    //   Reset only by poresetn (survives warm hresetn reset)
    //   Register map (via ctrl_reg_* pass-through):
    //     0: ROLE_CFG      [0]=role (0=master,1=slave), [1]=role_lock (W1S)
    //     1: ROLE_STATUS   [0]=effective_role, [1]=locked, [2]=i2c_busy, [3]=i2c_addressed  (RO)
    //     2: I2C_SLV_ADDR  [6:0]=device address (default 0x00)
    //     3: I2C_PRESCALE  [15:0]=I2C master prescaler (default 1)
    // =====================================================================

    logic        role_cfg_reg;       // bit[0] of ROLE_CFG
    logic        role_lock_reg;      // bit[1] of ROLE_CFG (W1S, POR-only clear)
    logic [6:0]  i2c_slv_addr_reg;
    logic [15:0] i2c_prescale_reg;

    // Auto-negotiation registers (POR-only reset domain)
    logic [6:0]  nego_cfg_reg;       // NEGO_CFG[6:0]; bit[6]=mask_hs_auto_en
    logic [15:0] nego_priority_reg;  // NEGO_PRIORITY[15:0]
    logic [31:0] nego_timeout_reg;   // NEGO_TIMEOUT[31:0]

    // Auto-negotiation FSM wire forward declarations (instantiated later)
    // Bug N7/N8 silicon observability: mark_debug on FSM-side AXIL bus + role-
    // arbitration nets. Inert unless FPGA_INSERT_DEBUG_CORE=1 at build time.
    (* mark_debug = "true" *) wire [3:0]  nego_state_w;
    wire        nego_done_w, nego_error_w, nego_won_w, nego_lost_w, nego_sda_start_seen;
    wire        nego_role_w;
    wire        nego_set_role_cfg_w, nego_role_value_w, nego_set_role_lock_w;
    (* mark_debug = "true" *) wire [7:0]  fsm_axil_awaddr;
                              wire [7:0]  fsm_axil_araddr;
    (* mark_debug = "true" *) wire        fsm_axil_awvalid;
                              wire        fsm_axil_wvalid, fsm_axil_bready;
    wire        fsm_axil_arvalid, fsm_axil_rready;
    (* mark_debug = "true" *) wire [31:0] fsm_axil_wdata;
    wire [3:0]  fsm_axil_wstrb;
    (* mark_debug = "true" *) wire        nego_driving;

    wire         role_locked   = role_lock_reg;
    wire         nego_en       = nego_cfg_reg[0];
    wire         role_in_nego  = nego_en && !role_locked;
    wire         role_effective = role_locked  ? role_cfg_reg
                                : role_in_nego ? nego_role_w
                                :                role_strap_i;
    wire         role_is_master = ~role_effective;

    assign role_is_master_o = role_is_master;
    assign role_locked_o    = role_locked;

    // I2C slave status (directly from core)
    wire i2c_slv_busy;
    wire i2c_slv_addressed;

    // ====================================================================
    // Peer-mask handshake gating
    //   Hardware refuses to assert role_lock unless the peer-mask handshake
    //   has reported a match. Sequence (SW-driven for now; FSM automation
    //   is a follow-up):
    //     1. Both sides program their own Wlink lane_mask @ 0x214.
    //     2. Negotiation runs as before; when nego completes the FSM pulses
    //        nego_set_role_lock_w → that latches into nego_lock_pending_reg.
    //     3. Master SW reads peer's lane_mask via I2C, compares, and writes
    //        either 0x01 (match) or 0x02 (fail) to peer's
    //        link_lane_mask_hs_result @ 0x21C.
    //     4. wlink_mask_hs_result[0] going high releases the gate;
    //        role_lock_reg latches on the next clock.
    //     5. wlink_mask_hs_result[1] going high latches the sticky
    //        nego_mask_mismatch_reg, which surfaces on nego_status[8] and
    //        contributes to nego_error_irq.
    //   apb_debug_unlock_i bypasses the gate entirely (existing debug strap;
    //   used by the UVM testbench and bring-up flows that don't yet drive
    //   the handshake).
    //
    //   Phase 4 autonomy update: apb_debug_unlock_i and mask_hs_bypass_i are
    //   both DEBUG STRAPS — tied to 0 in production silicon, TAP-driven for
    //   bench debug only. The autoneg FSM's mask_hs_local_match path (line
    //   428 below, driven by u_autoneg at lines 1272-1273) now closes the
    //   handshake without SW intervention, so the standard FPGA deploy
    //   script (pynq_host/scripts/deploy_pair.sh) no longer asserts the
    //   AXI GPIO at 0x4404_1000 (apb_debug_unlock) at deploy time.
    // ====================================================================
    wire [1:0] wlink_mask_hs_result;  // [0]=peer_says_match, [1]=peer_says_fail

    // Autoneg peer-mask scaffolding (Phase 2A). Outputs zero until Phase 2B
    // wires them to FSM capture/verdict logic.
    wire [7:0] autoneg_peer_tx_lane_mask;
    wire [7:0] autoneg_peer_rx_lane_mask;
    wire       autoneg_mask_hs_local_match;
    wire       autoneg_mask_hs_local_fail;
    // Combined match/fail: SW path (Wlink hs_result register, written by SW
    // or master peer over I2C) OR FSM path (autoneg_mask_hs_local_match,
    // driven by Phase 2B's HW handshake).
    wire mask_hs_match     = wlink_mask_hs_result[0] | autoneg_mask_hs_local_match;
    wire mask_hs_fail      = wlink_mask_hs_result[1] | autoneg_mask_hs_local_fail;
    // apb_debug_unlock_i opens the gate too — see the debug-strap contract in
    // the comment block above ("apb_debug_unlock_i bypasses the gate
    // entirely"). The strap is wired to axi_gpio_debug_unlock @ 0x4404_1000
    // and asserted by the FPGA bring-up flow (deploy_pair.sh) on both boards,
    // so SW W1S of ROLE_CFG[1] can latch role_lock without the cross-board
    // I²C peer-mask handshake (which needs physical jumpers + SHORTCOMINGS-14a).
    // Production silicon ties apb_debug_unlock_i AND mask_hs_bypass_i to 0, so
    // the handshake stays mandatory there. The §9 SW-coordinated calibration
    // path (training_mode held HIGH on both sides) then brings the link up.
    wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i;

    reg  nego_lock_pending_reg;
    reg  nego_mask_mismatch_reg;
    wire nego_error_irq_internal;

    // Role registers — POR-only reset domain
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            role_cfg_reg           <= 1'b0;
            role_lock_reg          <= 1'b0;
            i2c_slv_addr_reg       <= 7'h7E;  // default to autoneg slave address so
                                                // post-role_lock device_address mux
                                                // doesn't NACK in-flight claim writes
            // Bug N1 second-cause fix (2026-05-29): POR default i2c_prescale=1
            // produces ~12.5 MHz I²C SCL at 50 MHz apb_clk, far above any
            // sensible bus rate. The slave's bit-detection FSM cannot track
            // those edges, so the address byte is mis-shifted, the slave
            // wedges holding SDA low, and the master's i2c_master_axil
            // bus_active_reg stays asserted forever (STATE_START_WAIT loop).
            // The autoneg FSM in turn polls TXN_POLL → TXN_CHECK → TXN_POLL
            // indefinitely because I2C_STS_BUSY never clears.
            //
            // 16'd125 yields 50 MHz / (125 * 4) = 100 kHz — the I²C standard
            // bus rate — which is the lowest spec-compliant value and gives
            // the slave's start/stop/bit detector ample margin. The TXN_PRESCALE
            // sub-step at ST_NEGO_CLAIM writes this value into the master's
            // PRESCALE register before the first CLAIM transaction, so the
            // entire autoneg mask-handshake runs at 100 kHz from cold boot.
            // See probe trace in test_13_bug_n1_second_cause_probe.py.
            i2c_prescale_reg       <= 16'd125;
            nego_cfg_reg           <= NEGO_CFG_RESET;
            // Bug N7 fix (2026-06-01): role_strap-derived asymmetric POR.
            // Identical priority on both dies (16'hFFFF default) made the
            // autoneg ST_NEGO_WAIT backoff timer compute identical delays
            // → neither claims first → both timeout → ST_ERROR with
            // sda_start_seen=0. test_18 reproduces it in sim (1258 s wall
            // pre-fix). The strap bit differentiates the two dies at FPGA
            // POR (axi_gpio_strap DOUT default per-target — die_a=0,
            // die_b=1), so this POR value is correct at the moment the
            // autoneg FSM samples nego_priority_reg.
            //   strap=0 (die_a / master) → priority=1 → low backoff → claims first
            //   strap=1 (die_b / slave)  → priority=2 → higher backoff → defers
            nego_priority_reg      <= role_strap_i ? 16'h0002 : 16'h0001;
            nego_timeout_reg       <= 32'd131_082_000;
            nego_lock_pending_reg  <= 1'b0;
            nego_mask_mismatch_reg <= 1'b0;
        end else begin
            // Sticky mismatch: latch on the first cycle the peer reports fail.
            if (mask_hs_fail)
                nego_mask_mismatch_reg <= 1'b1;

            // Latch the FSM's role-lock request OR a SW W1S of ROLE_CFG[1]
            // pre-lock; release on gate-open. The pending bit lets us hold
            // the lock intent across cycles while waiting for the
            // mask-handshake gate to open.
            if (nego_set_role_lock_w ||
                (ctrl_reg_write && !role_locked && ctrl_reg_addr == 5'b01_000 && ctrl_reg_wdata[1]))
                nego_lock_pending_reg <= 1'b1;
            else if (nego_lock_pending_reg && (mask_hs_gate_open || nego_lost_w))
                // Bug N9 fix: also clear pending on the lost path so the
                // pending bit doesn't stay asserted after role_lock_reg
                // has latched via the lost-side workaround below.
                nego_lock_pending_reg <= 1'b0;

            if (nego_set_role_cfg_w) begin
                // FSM role-cfg write-back has priority (single-cycle pulse).
                role_cfg_reg <= nego_role_value_w;
            end

            // role_lock latches when (a) the FSM has pending lock and the
            // mask gate is open, OR (b) software writes the lock bit and
            // the mask gate is open.
            //
            // Bug N9 fix (2026-06-02): the lost-side never opens its own
            // gate. When master loses autoneg (MISS_ACK on CLAIM, or
            // sda_start_detect early-exit on the slave's WAIT) the FSM
            // parks at ST_NEGO_DONE with nego_lost_w=1 and does NOT walk
            // the local MASK_RD_* / MASK_RES_TX states — so
            // autoneg_mask_hs_local_match stays 0. The fallback is
            // wlink_mask_hs_result[0]=1 (the peer writing the verdict
            // byte over I²C into our 0x21C reg), but the Wlink submodule
            // currently hardwires mask_hs_result_o to 2'b00
            // (deps/axi-chiplet-controller/logical/wlink/Wlink.v:210 —
            // port stub awaiting Chisel regen). With both gate-openers
            // permanently 0 on the lost side, role_lock_reg never
            // latches even though nego_lock_pending_reg is set.
            //
            // Workaround until the Wlink stub is regenerated: on the
            // lost path, trust the winner. The peer that won the autoneg
            // arbitration is responsible for the mask handshake; the
            // local die has neither participated in the comparison nor
            // can observe its outcome (Wlink port stubbed). Honour the
            // FSM's nego_set_role_lock pulse without waiting for a gate
            // signal that will never arrive.
            if ((nego_lock_pending_reg && mask_hs_gate_open) ||
                (nego_lock_pending_reg && nego_lost_w)) begin
                role_lock_reg <= 1'b1;
            end else if (ctrl_reg_write && !role_locked && ctrl_reg_addr == 5'b01_000) begin
                role_cfg_reg  <= ctrl_reg_wdata[0];
                if (ctrl_reg_wdata[1] && mask_hs_gate_open)
                    role_lock_reg <= 1'b1;
            end else if (ctrl_reg_write && !role_locked &&
                         (ctrl_reg_addr[4:3] == 2'b01) &&
                         (ctrl_reg_addr[2:0] != 3'h0)) begin
                // Slot 0 (ROLE_CFG) handled above with mask gate; remaining
                // pre-lock writable Region-4 registers handled here.
                case (ctrl_reg_addr[2:0])
                    3'h2: i2c_slv_addr_reg  <= ctrl_reg_wdata[6:0];
                    3'h3: i2c_prescale_reg  <= ctrl_reg_wdata[15:0];
                    3'h4: nego_cfg_reg      <= ctrl_reg_wdata[6:0];
                    3'h6: nego_priority_reg <= ctrl_reg_wdata[15:0];
                    3'h7: nego_timeout_reg  <= ctrl_reg_wdata[31:0];
                    default: ;
                endcase
            end else if (ctrl_reg_write && role_locked &&
                         (ctrl_reg_addr[4:3] == 2'b01)) begin
                // After lock, only I2C slave address, prescale, and nego regs remain writable
                case (ctrl_reg_addr[2:0])
                    3'h2: i2c_slv_addr_reg  <= ctrl_reg_wdata[6:0];
                    3'h3: i2c_prescale_reg  <= ctrl_reg_wdata[15:0];
                    3'h4: nego_cfg_reg      <= ctrl_reg_wdata[6:0];
                    3'h6: nego_priority_reg <= ctrl_reg_wdata[15:0];
                    3'h7: nego_timeout_reg  <= ctrl_reg_wdata[31:0];
                    default: ;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------
    // §9 auto-cal calibrator + lane-checker output nets. Declared here
    // (hoisted above the Region 8 block) because the Region 8
    // SWI_LANE_STATUS CDC synchroniser references them and this module
    // uses `default_nettype none` (no forward net references). The nets
    // are *driven* by the tidelink_lane_checker / tidelink_phy_align_
    // calibrator instances further down in the §9 block.
    // -----------------------------------------------------------------
    wire [23:0] cal_bit_slip_w;
    // §9.7: per-lane 4-bit phase offset from the calibrator (8 lanes ×
    // 4 bits, lane N at [4N+3:4N]). OR-merged with the Region 8
    // SWI_PHASE_OFFSET override below, same pattern as cal_bit_slip_w.
    wire [31:0] cal_phase_offset_w;
    wire        cal_training_mode_w;
    wire        cal_calibration_done_w;
    wire [7:0]  cal_lane_fault_w;
    wire [3:0]  cal_state_w;
    // M7 (2026-06-05): calibrator auto-retry counter for silicon observability
    wire [15:0] cal_resweep_ctr_w;
    // Forward declarations — definitions below; needed early so the
    // tidelink-gpio-phy lane_checker instantiation can wire them in.
    wire [31:0] swi_phase_offset_w;
    wire        swi_training_mode_w;
    wire [7:0]  lane_locked_w;
    // Wlink-exposed recovered link clock + per-lane 16-bit deserialised data.
    wire [127:0] phy_link_rx_rx_link_data_w;
    wire         phy_link_rx_rx_link_clk_w;

    // -----------------------------------------------------------------
    // SoC Labs credit-path observability (RO APB exposure, replaces the
    // ILA debug core). Wlink surfaces the FCSM (LL_RX -> cr_pkt -> FCSM)
    // internals + the byte-align FSM internals + two 16-bit saturating
    // ECC event counters. These nets are driven by the Wlink instance
    // further down; declared here (above the Region 8 block) because the
    // Region 8 CDC synchroniser references them and this module uses
    // `default_nettype none` (forward net refs are illegal). All sources
    // live in the recovered-RX-link / FCSM clock domains; the 2-flop
    // sync into apb_clk below mirrors the existing sync_lane_locked_*
    // pattern. cocotb tests can hierarchically force the *_w nets.
    // -----------------------------------------------------------------
    wire [2:0]  obs_fcsm_state_w;
    wire        obs_cr_pkt_seen_rx_w;
    wire        obs_crack_pkt_seen_rx_w;
    wire        obs_pkt_is_cr_pkt_w;
    wire        obs_pkt_is_crack_pkt_w;
    wire [1:0]  obs_llrx_state_w;
    wire        obs_is_short_pkt_w;
    wire        obs_is_long_pkt_w;
    wire        obs_llrx_valid_w;
    wire [15:0] obs_ecc_corrupted_cnt_w;
    wire [15:0] obs_ecc_corrected_cnt_w;
    // SoC Labs 2026-06-08: SYNC-detected saturating counter (cross-lane-skew obs)
    wire [15:0] obs_sync_detected_cnt_w;
    // SoC Labs Bug-A FCSM observation 2026-06-02
    wire        obs_a2l_replay_link_valid_w;
    wire [7:0]  obs_fe_rx_credit_max_w;
    wire        obs_fe_rx_is_full_w;
    // SoC Labs Bug-A FCSM observation 2026-06-03
    wire        obs_a2l_replay_app_valid_w;

    // Role/Region-4 register read mux. Region 8 reads served below the
    // region8_rdata mux and OR-merged into ctrl_reg_rdata.
    reg [31:0] region4_rdata;
    always_comb begin
        case (ctrl_reg_addr[2:0])
            3'h0:    region4_rdata = {30'b0, role_lock_reg, role_cfg_reg};
            3'h1:    region4_rdata = {28'b0, i2c_slv_addressed, i2c_slv_busy,
                                       role_locked, role_effective};
            3'h2:    region4_rdata = {25'b0, i2c_slv_addr_reg};
            3'h3:    region4_rdata = {16'b0, i2c_prescale_reg};
            3'h4:    region4_rdata = {25'd0, nego_cfg_reg};
            3'h5:    region4_rdata = {22'd0, nego_mask_mismatch_reg, nego_sda_start_seen, nego_lost_w, nego_won_w, nego_error_w, nego_done_w, nego_state_w};
            3'h6:    region4_rdata = {16'd0, nego_priority_reg};
            3'h7:    region4_rdata = nego_timeout_reg;
            default: region4_rdata = 32'b0;
        endcase
    end

    // Region 8 read mux is driven by the Phase 3 phy_align + I²C-train
    // register block instantiated below. Region C is the Bug N7/N8
    // autoneg observability bank (autoneg internal counters and i2c_master
    // STATUS). ctrl_reg_rdata picks Region 4 / Region 8 / Region C based on
    // ctrl_reg_addr[4:3].
    wire [31:0] region8_rdata;
    wire [31:0] regionC_rdata;
    always_comb begin
        unique case (ctrl_reg_addr[4:3])
            2'b01:   ctrl_reg_rdata = region4_rdata;
            2'b10:   ctrl_reg_rdata = region8_rdata;
            2'b11:   ctrl_reg_rdata = regionC_rdata;
            default: ctrl_reg_rdata = 32'b0;
        endcase
    end

    // =====================================================================
    // Region 8 — Chiplet Extended (PHY-align + I²C-train registers)
    //   Canonical home for the §9 soft-strap controls (formerly the interim
    //   shim at MMIO 0x4403_1000) plus the I²C-coordinated training
    //   protocol regs. Addresses are paddr 0x100..0x11C within the
    //   TideLink-config APB, MMIO 0x4403_2100..0x4403_211C. See
    //   docs/REGISTER_MAP.md "Region 8" and src/rdl/tidelink_regs.rdl.
    // =====================================================================

    // Slot 0 — SWI_TRAINING_MODE bit[0]. POR-only reset domain so training
    // state survives a warm hresetn.
    reg        swi_training_mode_r;
    // Slot 0 bit[1] — SWI_RECAL: SW-driven calibrator re-trigger. The
    // calibrator only self-triggers on the cold-boot role_locked rising
    // edge; under an SSH-staggered FPGA bring-up the two calibrators sweep
    // in non-overlapping windows and every lane faults with no way to
    // re-arm (role_lock is W1S, POR-only clear). This level bit feeds the
    // calibrator's `swreset`: SW writes {recal=1,train=1} to cancel the
    // stale S_DONE, holds the training pattern on BOTH boards, then writes
    // {recal=0,train=1}; the recal falling edge (role_locked still high)
    // re-triggers a fresh sweep that clears lane_fault — now against a live
    // peer pattern. POR-only domain, same as training_mode.
    reg        swi_recal_r;
    // Slot 1 — SWI_BIT_SLIP_LO bits[23:0] (8 × 3-bit per-lane slip)
    reg [23:0] swi_bit_slip_lo_r;
    // Slot 6 — SWI_PHASE_OFFSET bits[31:0] (8 × 4-bit per-lane sub-bit
    // sample-point phase). §9.7: SW override of the calibrator's per-lane
    // phase sweep, OR-merged with cal_phase_offset_w into the Wlink
    // swi_phase_offset_in port (same pattern as swi_bit_slip_lo_r). This
    // slot was the reserved "SWI_BIT_SLIP_HI" (16-lane builds); repurposed
    // for the 8-lane FPGA bring-up — see docs/REGISTER_MAP.md / RDL. The
    // legacy single-global-phase APB path (Wlink PHY-ctrl reg bits[20:17])
    // is independent and still works (per-lane OR-merge inside WavD2DGpio
    // means a lane left at 0 here still takes the global APB phase). POR-
    // only reset domain, same as the other §9 soft-straps.
    reg [31:0] swi_phase_offset_r;
    // Slot 3 — NEGO_TRAIN_CFG: bit[0]=auto_en, bit[1]=sw_step,
    //          bit[2]=retrain (W1P), bits[7:4]=poll_timeout,
    //          bits[15:8]=fsm_wait_hi.
    reg [15:0] nego_train_cfg_r;
    reg        nego_train_retrain_pulse;  // 1-cycle pulse on W1P write

    // Phase 1 G1b — sticky train-fail IRQ. Latches on train_fail_irq_w
    // rising-edge (the FSM holds it stable for the duration of
    // ST_TRAIN_FAIL); SW reads it via Region 8 slot 3'h3 bit[16] and
    // clears with W1C to the same bit position. The dead-ended
    // `_unused_phase3_b` wire is replaced by this register.
    reg        train_fail_irq_r;
    reg        train_fail_irq_w_d;   // 1-cycle delay for edge-detect

    // Forward decls — driven by the autoneg FSM (Step 4 wires these up).
    wire [3:0] train_state_w;
    wire       train_ok_w, train_fail_w, train_in_progress_w, train_peer_nack_w;
    wire [7:0] train_peer_lane_locked_w, train_peer_lane_fault_w;
    wire [7:0] train_local_lane_fault_w;
    wire       train_fail_irq_w;
    wire       local_training_mode_set_w, local_training_mode_clr_w;
    wire       local_swreset_pulse_w;

    // =====================================================================
    // §9 REWIRE (integration plan step 3/4): SWI_LANE_STATUS inputs come
    // from the REAL trunk autocal calibrator + lane checker, NOT from
    // Agent #4's placeholder reg-init constants. The source nets are
    // module-scope wires declared in the §9 block further down:
    //   lane_locked_w           ← tidelink_lane_checker.lane_locked
    //   cal_lane_fault_w        ← tidelink_phy_align_calibrator.lane_fault
    //   cal_calibration_done_w  ← tidelink_phy_align_calibrator.calibration_done
    // They live in the recovered-RX-clock domain; a 2-flop sync into the
    // apb_clk domain gives the autoneg FSM (which lives here) a stable
    // value. UVM tests can still hierarchically force the *_w nets to
    // inject scenarios; cocotb autocal tests drive them via the real FSM.
    // =====================================================================
    reg [7:0] sync_lane_locked_0, sync_lane_locked_1;
    reg [7:0] sync_lane_fault_0,  sync_lane_fault_1;
    reg       sync_cal_done_0,    sync_cal_done_1;

    // SoC Labs credit-path observability — same 2-flop apb_clk sync
    // pattern. The FCSM/byte-align bits are slow-moving status (state
    // wedges, sticky seen-flags); the ECC counters are sampled snapshots
    // (each bit independently 2-flop-synced — acceptable for a coherent-
    // enough debug snapshot at SW poll rate, exactly like sync_lane_*).
    reg [2:0]  sync_obs_fcsm_state_0,   sync_obs_fcsm_state_1;
    reg        sync_obs_cr_seen_0,      sync_obs_cr_seen_1;
    reg        sync_obs_crack_seen_0,   sync_obs_crack_seen_1;
    reg        sync_obs_pkt_cr_0,       sync_obs_pkt_cr_1;
    reg        sync_obs_pkt_crack_0,    sync_obs_pkt_crack_1;
    reg [1:0]  sync_obs_llrx_state_0,   sync_obs_llrx_state_1;
    reg        sync_obs_short_0,        sync_obs_short_1;
    reg        sync_obs_long_0,         sync_obs_long_1;
    reg        sync_obs_llrx_valid_0,   sync_obs_llrx_valid_1;
    reg [15:0] sync_obs_ecc_corrupt_0,  sync_obs_ecc_corrupt_1;
    reg [15:0] sync_obs_ecc_correct_0,  sync_obs_ecc_correct_1;
    // SoC Labs 2026-06-08: SYNC-detected saturating count, 2-flop apb_clk sync.
    reg [15:0] sync_obs_sync_det_0,     sync_obs_sync_det_1;
    // SoC Labs Bug-A FCSM observation 2026-06-02. dont_touch + mark_debug
    // needed on the apb_clk-synced flops because the signal chain feeding
    // them has no logical sink (only the dbg_hub) — without dont_touch,
    // synth opt prunes the entire chain back to constant zero.
    reg                                                                sync_obs_a2l_replay_v_0;
    reg                 sync_obs_a2l_replay_v_1;
    reg [7:0]                                                          sync_obs_fe_rx_cred_0;
    reg [7:0]           sync_obs_fe_rx_cred_1;
    reg                                                                sync_obs_fe_rx_full_0;
    reg                 sync_obs_fe_rx_full_1;
    // SoC Labs Bug-A FCSM observation 2026-06-03
    reg                                                                sync_obs_a2l_app_v_0;
    reg                 sync_obs_a2l_app_v_1;

    always_ff @(posedge apb_clk or negedge hresetn) begin
        if (!hresetn) begin
            sync_lane_locked_0 <= 8'h00;
            sync_lane_locked_1 <= 8'h00;
            sync_lane_fault_0  <= 8'h00;
            sync_lane_fault_1  <= 8'h00;
            sync_cal_done_0    <= 1'b0;
            sync_cal_done_1    <= 1'b0;
            sync_obs_fcsm_state_0  <= 3'b0;  sync_obs_fcsm_state_1  <= 3'b0;
            sync_obs_cr_seen_0     <= 1'b0;  sync_obs_cr_seen_1     <= 1'b0;
            sync_obs_crack_seen_0  <= 1'b0;  sync_obs_crack_seen_1  <= 1'b0;
            sync_obs_pkt_cr_0      <= 1'b0;  sync_obs_pkt_cr_1      <= 1'b0;
            sync_obs_pkt_crack_0   <= 1'b0;  sync_obs_pkt_crack_1   <= 1'b0;
            sync_obs_llrx_state_0  <= 2'b0;  sync_obs_llrx_state_1  <= 2'b0;
            sync_obs_short_0       <= 1'b0;  sync_obs_short_1       <= 1'b0;
            sync_obs_long_0        <= 1'b0;  sync_obs_long_1        <= 1'b0;
            sync_obs_llrx_valid_0  <= 1'b0;  sync_obs_llrx_valid_1  <= 1'b0;
            sync_obs_ecc_corrupt_0 <= 16'h0; sync_obs_ecc_corrupt_1 <= 16'h0;
            sync_obs_ecc_correct_0 <= 16'h0; sync_obs_ecc_correct_1 <= 16'h0;
            sync_obs_sync_det_0    <= 16'h0; sync_obs_sync_det_1    <= 16'h0;
            // SoC Labs Bug-A FCSM observation 2026-06-02
            sync_obs_a2l_replay_v_0 <= 1'b0;  sync_obs_a2l_replay_v_1 <= 1'b0;
            sync_obs_fe_rx_cred_0   <= 8'h0;  sync_obs_fe_rx_cred_1   <= 8'h0;
            sync_obs_fe_rx_full_0   <= 1'b0;  sync_obs_fe_rx_full_1   <= 1'b0;
            // SoC Labs Bug-A FCSM observation 2026-06-03
            sync_obs_a2l_app_v_0    <= 1'b0;  sync_obs_a2l_app_v_1    <= 1'b0;
        end else begin
            // REWIRED: real calibrator/lane_checker outputs (was #4's
            // swi_lane_locked_in=8'hFF / swi_lane_fault_in=8'h00 /
            // swi_calibration_done_in=1'b1 placeholders).
            sync_lane_locked_0 <= lane_locked_w;
            sync_lane_locked_1 <= sync_lane_locked_0;
            sync_lane_fault_0  <= cal_lane_fault_w;
            sync_lane_fault_1  <= sync_lane_fault_0;
            sync_cal_done_0    <= cal_calibration_done_w;
            sync_cal_done_1    <= sync_cal_done_0;
            // SoC Labs credit-path observability — 2-flop apb_clk sync.
            sync_obs_fcsm_state_0  <= obs_fcsm_state_w;
            sync_obs_fcsm_state_1  <= sync_obs_fcsm_state_0;
            sync_obs_cr_seen_0     <= obs_cr_pkt_seen_rx_w;
            sync_obs_cr_seen_1     <= sync_obs_cr_seen_0;
            sync_obs_crack_seen_0  <= obs_crack_pkt_seen_rx_w;
            sync_obs_crack_seen_1  <= sync_obs_crack_seen_0;
            sync_obs_pkt_cr_0      <= obs_pkt_is_cr_pkt_w;
            sync_obs_pkt_cr_1      <= sync_obs_pkt_cr_0;
            sync_obs_pkt_crack_0   <= obs_pkt_is_crack_pkt_w;
            sync_obs_pkt_crack_1   <= sync_obs_pkt_crack_0;
            sync_obs_llrx_state_0  <= obs_llrx_state_w;
            sync_obs_llrx_state_1  <= sync_obs_llrx_state_0;
            sync_obs_short_0       <= obs_is_short_pkt_w;
            sync_obs_short_1       <= sync_obs_short_0;
            sync_obs_long_0        <= obs_is_long_pkt_w;
            sync_obs_long_1        <= sync_obs_long_0;
            sync_obs_llrx_valid_0  <= obs_llrx_valid_w;
            sync_obs_llrx_valid_1  <= sync_obs_llrx_valid_0;
            sync_obs_ecc_corrupt_0 <= obs_ecc_corrupted_cnt_w;
            sync_obs_ecc_corrupt_1 <= sync_obs_ecc_corrupt_0;
            sync_obs_ecc_correct_0 <= obs_ecc_corrected_cnt_w;
            sync_obs_ecc_correct_1 <= sync_obs_ecc_correct_0;
            // SoC Labs 2026-06-08: SYNC-detected count apb_clk sync.
            sync_obs_sync_det_0    <= obs_sync_detected_cnt_w;
            sync_obs_sync_det_1    <= sync_obs_sync_det_0;
            // SoC Labs Bug-A FCSM observation 2026-06-02
            sync_obs_a2l_replay_v_0 <= obs_a2l_replay_link_valid_w;
            sync_obs_a2l_replay_v_1 <= sync_obs_a2l_replay_v_0;
            sync_obs_fe_rx_cred_0   <= obs_fe_rx_credit_max_w;
            sync_obs_fe_rx_cred_1   <= sync_obs_fe_rx_cred_0;
            sync_obs_fe_rx_full_0   <= obs_fe_rx_is_full_w;
            sync_obs_fe_rx_full_1   <= sync_obs_fe_rx_full_0;
            // SoC Labs Bug-A FCSM observation 2026-06-03
            sync_obs_a2l_app_v_0    <= obs_a2l_replay_app_valid_w;
            sync_obs_a2l_app_v_1    <= sync_obs_a2l_app_v_0;
        end
    end

    // Writeable Region-8 register storage. POR-only reset for
    // training-related state so it survives warm reset.
    wire region8_write = ctrl_reg_write && (ctrl_reg_addr[4:3] == 2'b10);

    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            swi_training_mode_r      <= 1'b0;
            swi_recal_r              <= 1'b0;
            swi_bit_slip_lo_r        <= 24'h0;
            swi_phase_offset_r       <= 32'h0;
            // Phase 2 autonomy — POR-tunable default for NEGO_TRAIN_CFG.
            // Wrapper (tidelink_top.sv) sets train_auto_en=1 by default;
            // cocotb wrappers override the parameter for legacy tests.
            nego_train_cfg_r         <= NEGO_TRAIN_CFG_RESET;
            nego_train_retrain_pulse <= 1'b0;
            train_fail_irq_r         <= 1'b0;
            train_fail_irq_w_d       <= 1'b0;
        end else begin
            // Default — retrain pulse self-clears every cycle
            nego_train_retrain_pulse <= 1'b0;
            // Local FSM-driven strobes (autoneg's ENTER/EXIT)
            if (local_training_mode_set_w)
                swi_training_mode_r <= 1'b1;
            else if (local_training_mode_clr_w)
                swi_training_mode_r <= 1'b0;

            // Phase 1 G1b — sticky train-fail IRQ. Latch on rising edge of
            // train_fail_irq_w; clear (with priority) on W1C to slot 3'h3
            // bit[16]. The edge-detect protects against a SW ack racing
            // with a re-entered ST_TRAIN_FAIL: the same FSM-stable level
            // can only re-arm after the FSM passes through ST_NEGO_DONE_PRE
            // (which deasserts train_fail_r at line 887-907 of
            // tidelink_autoneg.sv).
            train_fail_irq_w_d <= train_fail_irq_w;
            if (region8_write && (ctrl_reg_addr[2:0] == 3'h3) && ctrl_reg_wdata[16]) begin
                // W1C clear wins over a same-cycle rising edge (SW ack
                // path is the priority; the next FSM entry into
                // ST_TRAIN_FAIL will re-arm the latch).
                train_fail_irq_r <= 1'b0;
            end else if (train_fail_irq_w && !train_fail_irq_w_d) begin
                train_fail_irq_r <= 1'b1;
            end

            // APB-side writes — both local APB and slave-AXIL bridge
            // converge here via ctrl_reg_write.
            if (region8_write) begin
                case (ctrl_reg_addr[2:0])
                    3'h0: begin                                                // SWI_TRAINING_MODE
                        swi_training_mode_r <= ctrl_reg_wdata[0];
                        swi_recal_r         <= ctrl_reg_wdata[1];             // SWI_RECAL (level → calibrator swreset)
                    end
                    3'h1: swi_bit_slip_lo_r   <= ctrl_reg_wdata[23:0];        // SWI_BIT_SLIP_LO
                    3'h3: begin                                                // NEGO_TRAIN_CFG
                        nego_train_cfg_r <= ctrl_reg_wdata[15:0];
                        if (ctrl_reg_wdata[2])  // retrain W1P
                            nego_train_retrain_pulse <= 1'b1;
                        // bit[16] is the train_fail_irq W1C; handled above.
                    end
                    3'h5: begin                                                // NEGO_TRAIN_STEP (W1P, ignored in v1)
                        // Reserved for SW-step debug; not implemented.
                    end
                    3'h6: swi_phase_offset_r  <= ctrl_reg_wdata[31:0];        // SWI_PHASE_OFFSET (8 × 4-bit per-lane phase)
                    default: ;
                endcase
            end
        end
    end

    // Phase 1 G1b — drive the sticky IRQ output. Held HIGH until SW
    // acknowledges via W1C to slot 3'h3 bit[16]. No CDC needed: same
    // apb_clk as the consumer (top-level IRQ pin).
    assign train_fail_irq_o = train_fail_irq_r;

    // Region 8 read mux
    assign region8_rdata =
        (ctrl_reg_addr[2:0] == 3'h0) ? {30'h0, swi_recal_r, swi_training_mode_r} :
        (ctrl_reg_addr[2:0] == 3'h1) ? {8'h0, swi_bit_slip_lo_r}    :
        (ctrl_reg_addr[2:0] == 3'h2) ? {sync_obs_fe_rx_full_1,          // [31]    fe_rx_is_full   — FCSM 4->5 SEND credit gate (SoC Labs 2026-06-09)
                                        sync_obs_a2l_replay_v_1,        // [30]    a2l_fc_replay_link_valid — FCSM 4->5 SEND app-valid gate (link side)
                                        sync_obs_llrx_valid_1,          // [29]    LL_RX valid pkt
                                        sync_obs_pkt_crack_1,           // [28]    pkt_is_crack_pkt
                                        sync_obs_pkt_cr_1,              // [27]    pkt_is_cr_pkt
                                        sync_obs_long_1,                // [26]    is_long_pkt
                                        sync_obs_short_1,               // [25]    is_short_pkt
                                        sync_obs_crack_seen_1,          // [24]    crack_pkt_seen_rx
                                        sync_obs_cr_seen_1,             // [23]    cr_pkt_seen_rx
                                        sync_obs_llrx_state_1,          // [22:21] LL_RX byte-align FSM state
                                        sync_obs_a2l_app_v_1,           // [20]    a2l_replay_app_valid — app side (distinguishes skid-empty vs CDC-stuck)
                                        sync_obs_fcsm_state_1,          // [19:17] FCSM state (3b)
                                        sync_cal_done_1,                // [16]    calibration_done
                                        sync_lane_fault_1,              // [15:8]  lane_fault
                                        sync_lane_locked_1}         :  // [7:0] lane_locked — SWI_LANE_STATUS + SEND-GATE OBS
        (ctrl_reg_addr[2:0] == 3'h3) ? {15'h0,                       // [31:17] reserved
                                        train_fail_irq_r,            // [16]    Phase 1 G1b sticky IRQ (W1C via wdata[16])
                                        nego_train_cfg_r}           : // [15:0]  NEGO_TRAIN_CFG
        (ctrl_reg_addr[2:0] == 3'h4) ? {train_local_lane_fault_w,       // [31:24]
                                        train_peer_lane_fault_w,        // [23:16]
                                        train_peer_lane_locked_w,       // [15:8]
                                        train_state_w,                  // [7:4]
                                        train_peer_nack_w,              // [3]
                                        train_in_progress_w,            // [2]
                                        train_fail_w,                   // [1]
                                        train_ok_w}                  :  // [0]
        (ctrl_reg_addr[2:0] == 3'h5) ? {sync_obs_sync_det_1,             // [31:16] SYNC-detected sat. count — SoC Labs 2026-06-08 (cross-lane-deskew health). Replaces the DEAD ECC-corrected field ([31:16] was sync_obs_ecc_correct_1, always 0 because WlinkEccSyndrome.v ties corrected=0). RX>0 proves a COHERENT SYNC word reassembled.
                                        sync_obs_ecc_corrupt_1}      : // [15:0]  ECC-corrupted sat. count (also DEAD/0) — SYNC_DETECTED_COUNTER reg (was ECC_COUNTERS; was NEGO_TRAIN_STEP RO=0; W1P write path unchanged)
        (ctrl_reg_addr[2:0] == 3'h6) ? swi_phase_offset_r            : // SWI_PHASE_OFFSET (8 × 4-bit per-lane phase)
        (ctrl_reg_addr[2:0] == 3'h7) ? 32'h5041_0100                  : // PHY_ALIGN_ID = "PA" v1.0
                                       32'h0;

    // =====================================================================
    // Region C — Autoneg silicon observability (Bug N7/N8 probes)
    //   MMIO 0x44032180..0x4403219C (paddr 0x180..0x19C). All slots RO.
    //   Surfaces internal tidelink_autoneg counters/state + i2c_master
    //   STATUS so the silicon-debug path can see WHERE the FSM is wedged
    //   pre-CLAIM. Mirror only — no behaviour change.
    //
    //   Slot layout:
    //     3'h0  OBS_DELAY_CTR        — autoneg.delay_ctr_r[31:0]
    //     3'h1  OBS_TIMEOUT_CTR      — autoneg.timeout_ctr_r[31:0]
    //     3'h2  OBS_FSM_SUBSTATE     — packed:
    //              [31]    reserved
    //              [22:18] reserved
    //              [17:13] autoneg.init_wait_r[4:0]    (5b)
    //              [12:10] autoneg.axl_state_r[2:0]    (3b)
    //              [ 9: 7] autoneg.txn_step_r[2:0]     (3b)
    //              [ 6: 3] reserved
    //              [ 2: 0] reserved
    //              ── packing chosen so each field sits on a recognisable
    //              ── nibble boundary when read in hex
    //     3'h3  OBS_I2C_MST_STATUS   — {28'h0, i2c_master.status_o[3:0]}
    //                                  [3]=missed_ack [2]=bus_active
    //                                  [1]=bus_cont(0) [0]=busy
    //     3'h4  OBS_OBS_ID          — "OB" v1.0 marker = 0x4F42_0100
    //     3'h5  OBS_MASK_HS          — packed mask-handshake internals (2026-06-02)
    //              [ 7: 0] autoneg.peer_tx_lane_mask_r  (slave's capture of master's tx_mask)
    //              [15: 8] autoneg.peer_rx_lane_mask_r  (slave's capture of master's rx_mask)
    //              [16]    autoneg.mask_hs_local_match_r (sticky, MASK_RES_TX→DONE)
    //              [17]    autoneg.mask_hs_local_fail_r  (sticky)
    //              [18]    controller.nego_lock_pending_reg
    //              [19]    controller.mask_hs_match      (combined wlink|autoneg)
    //              [20]    controller.mask_hs_gate_open  (incl. bypass straps)
    //              [22:21] controller.wlink_mask_hs_result[1:0]
    //              [31:23] reserved
    //     3'h6..3'h7 reserved (return 0)
    //
    //   See deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv
    //   and src/rtl/local_overrides/i2c_master_axil.v for the register
    //   sources.
    // =====================================================================
    wire [31:0] obs_delay_ctr_w;
    wire [31:0] obs_timeout_ctr_w;
    wire  [4:0] obs_init_wait_w;
    wire  [2:0] obs_axl_state_w;
    wire  [2:0] obs_txn_step_w;
    wire  [3:0] obs_i2c_mst_status_w;

    // OBS_MASK_HS (slot 3'h5) — pack mask-handshake internals. peer_*_lane_mask
    // and autoneg_mask_hs_local_match/fail are sticky-latched inside the FSM
    // (tidelink_autoneg.sv ~line 448-468); nego_lock_pending_reg is the
    // controller's sticky bit; the remaining fields are combinational mirrors
    // of wires already used by the gating logic above.
    wire [31:0] obs_mask_hs_w = {9'h0,                                // [31:23] reserved
                                 wlink_mask_hs_result,                // [22:21]
                                 mask_hs_gate_open,                   // [20]
                                 mask_hs_match,                       // [19]
                                 nego_lock_pending_reg,               // [18]
                                 autoneg_mask_hs_local_fail,          // [17]
                                 autoneg_mask_hs_local_match,         // [16]
                                 autoneg_peer_rx_lane_mask,           // [15: 8]
                                 autoneg_peer_tx_lane_mask};          // [ 7: 0]

    // OBS_CAL (slot 3'h6 @ 0x44032198) — M7 (2026-06-05): silicon observability
    // for the slave-only-failure mode characterised at v14 (30%/10% slave/master
    // sweep-failure rates over 10 deploys). Layout:
    //   [ 3: 0] cal_state_w       — calibrator FSM state (4 bits)
    //   [19: 4] cal_resweep_ctr_w — auto-retry counter (non-zero = stuck cycling)
    //   [20]    swi_training_mode_w   — live training-mode (OR of cal + SW)
    //   [31:21] reserved
    // (M1/M2 sync verifier bits were originally planned here but the sync
    // registers are declared later in the file — forward reference. Could
    // be added in a future iteration; cal_state + resweep_ctr are
    // sufficient to discriminate H1/H2/H3 hypotheses.)
    wire [31:0] obs_cal_w = {11'h0,
                             swi_training_mode_w,
                             cal_resweep_ctr_w,
                             cal_state_w};

    assign regionC_rdata =
        (ctrl_reg_addr[2:0] == 3'h0) ? obs_delay_ctr_w                     :
        (ctrl_reg_addr[2:0] == 3'h1) ? obs_timeout_ctr_w                   :
        (ctrl_reg_addr[2:0] == 3'h2) ? {14'h0, obs_init_wait_w,
                                        obs_axl_state_w, obs_txn_step_w,
                                        7'h0}                              :
        (ctrl_reg_addr[2:0] == 3'h3) ? {28'h0, obs_i2c_mst_status_w}       :
        (ctrl_reg_addr[2:0] == 3'h4) ? 32'h4F42_0100                       : // "OB" v1.0
        (ctrl_reg_addr[2:0] == 3'h5) ? obs_mask_hs_w                       :
        (ctrl_reg_addr[2:0] == 3'h6) ? obs_cal_w                           : // M7 OBS_CAL
                                       32'h0;

    // =====================================================================
    // Wlink POR Gating
    //   Hold Wlink in reset until role is locked.
    //   swi_enable defaults HIGH, so link training starts automatically
    //   once por_reset deasserts.
    // =====================================================================
    wire wlink_por_reset = ~poresetn | ~role_locked;

    // Lane-mask handshake plumbing.
    //   wlink_*_lane_mask  — local mask, exposed by Wlink as a read-only mirror
    //                        of the swi_*_lane_mask registers. Drives the
    //                        tidelink_autoneg comparator and the master-side
    //                        I2C "send local mask" transaction.
    //   peer_*_lane_mask_w — peer mask captured by the autoneg FSM during the
    //                        handshake; latched into Wlink's LaneMaskPeer
    //                        register at offset 0x218 for SW diagnosis.
    wire [7:0] wlink_tx_lane_mask;
    wire [7:0] wlink_rx_lane_mask;
    wire [7:0] peer_tx_lane_mask_w;
    wire [7:0] peer_rx_lane_mask_w;

    assign peer_tx_lane_mask_w = autoneg_peer_tx_lane_mask;
    assign peer_rx_lane_mask_w = autoneg_peer_rx_lane_mask;

    // =====================================================================
    // I2C Core Resets — inactive core held in reset
    // =====================================================================
    wire i2c_mst_reset = ~hresetn | (~role_is_master & ~nego_driving);
    wire i2c_slv_reset = ~hresetn |  role_is_master;

    // =====================================================================
    // I2C Master Path
    //   AXI4 sideband → mkaxi2axil_bridge → i2c_master_axil → SCL/SDA
    // =====================================================================

    // Bridge-side AXI-Lite wires (from AXI4-to-AXI4L bridge)
    wire [7:0]  bridge_axil_awaddr;
    wire [2:0]  bridge_axil_awprot;
    wire        bridge_axil_awvalid;
    wire        bridge_axil_awready;
    wire [31:0] bridge_axil_wdata;
    wire [3:0]  bridge_axil_wstrb;
    wire        bridge_axil_wvalid;
    wire        bridge_axil_wready;
    wire [1:0]  bridge_axil_bresp;
    wire        bridge_axil_bvalid;
    wire        bridge_axil_bready;
    wire [7:0]  bridge_axil_araddr;
    wire [2:0]  bridge_axil_arprot;
    wire        bridge_axil_arvalid;
    wire        bridge_axil_arready;
    wire [31:0] bridge_axil_rdata;
    wire [1:0]  bridge_axil_rresp;
    wire        bridge_axil_rvalid;
    wire        bridge_axil_rready;

    // Muxed AXI-Lite wires (to I2C master)
    // Bug N7/N8 silicon observability: mark_debug on the I²C-master-facing
    // AXI-Lite. Inert unless FPGA_INSERT_DEBUG_CORE=1 at build time.
    wire [7:0]  mst_axil_awaddr;
    wire        mst_axil_awvalid;
    wire        mst_axil_awready;
    wire [31:0] mst_axil_wdata;
    wire [3:0]  mst_axil_wstrb;
    wire        mst_axil_wvalid;
    wire        mst_axil_wready;
    wire [1:0]  mst_axil_bresp;
    (* mark_debug = "true" *) wire        mst_axil_bvalid;
    wire        mst_axil_bready;
    wire [7:0]  mst_axil_araddr;
    wire        mst_axil_arvalid;
    (* mark_debug = "true" *) wire        mst_axil_arready;
    (* mark_debug = "true" *) wire [31:0] mst_axil_rdata;
    wire [1:0]  mst_axil_rresp;
    (* mark_debug = "true" *) wire        mst_axil_rvalid;
    wire        mst_axil_rready;

    wire        mst_scl_i, mst_scl_o, mst_scl_t;
    wire        mst_sda_i, mst_sda_o, mst_sda_t;

    mkaxi2axil_bridge u_axi2axil (
        .CLK                (apb_clk),
        .RST_N              (hresetn),

        .AXI4_AWVALID       (s_i2c_axi_awvalid),
        .AXI4_AWID          (s_i2c_axi_awid),
        .AXI4_AWADDR        ({4'h0, s_i2c_axi_awaddr}),
        .AXI4_AWLEN         (s_i2c_axi_awlen),
        .AXI4_AWSIZE        (s_i2c_axi_awsize),
        .AXI4_AWBURST       (s_i2c_axi_awburst),
        .AXI4_AWLOCK        (s_i2c_axi_awlock),
        .AXI4_AWCACHE       (s_i2c_axi_awcache),
        .AXI4_AWPROT        (s_i2c_axi_awprot),
        .AXI4_AWQOS         (4'h0),
        .AXI4_AWREGION      (4'h0),
        .AXI4_AWREADY       (s_i2c_axi_awready),

        .AXI4_WVALID        (s_i2c_axi_wvalid),
        .AXI4_WDATA         (s_i2c_axi_wdata),
        .AXI4_WSTRB         (s_i2c_axi_wstrb),
        .AXI4_WLAST         (s_i2c_axi_wlast),
        .AXI4_WREADY        (s_i2c_axi_wready),

        .AXI4_BVALID        (s_i2c_axi_bvalid),
        .AXI4_BID           (s_i2c_axi_bid),
        .AXI4_BRESP         (s_i2c_axi_bresp),
        .AXI4_BREADY        (s_i2c_axi_bready),

        .AXI4_ARVALID       (s_i2c_axi_arvalid),
        .AXI4_ARID          (s_i2c_axi_arid),
        .AXI4_ARADDR        ({4'h0, s_i2c_axi_araddr}),
        .AXI4_ARLEN         (s_i2c_axi_arlen),
        .AXI4_ARSIZE        (s_i2c_axi_arsize),
        .AXI4_ARBURST       (s_i2c_axi_arburst),
        .AXI4_ARLOCK        (s_i2c_axi_arlock),
        .AXI4_ARCACHE       (s_i2c_axi_arcache),
        .AXI4_ARPROT        (s_i2c_axi_arprot),
        .AXI4_ARQOS         (4'h0),
        .AXI4_ARREGION      (4'h0),
        .AXI4_ARREADY       (s_i2c_axi_arready),

        .AXI4_RVALID        (s_i2c_axi_rvalid),
        .AXI4_RID           (s_i2c_axi_rid),
        .AXI4_RDATA         (s_i2c_axi_rdata),
        .AXI4_RRESP         (s_i2c_axi_rresp),
        .AXI4_RLAST         (s_i2c_axi_rlast),
        .AXI4_RREADY        (s_i2c_axi_rready),

        .AXI4L_AWVALID      (bridge_axil_awvalid),
        .AXI4L_AWADDR       (bridge_axil_awaddr),
        .AXI4L_AWPROT       (bridge_axil_awprot),
        .AXI4L_AWREADY      (bridge_axil_awready),
        .AXI4L_WVALID       (bridge_axil_wvalid),
        .AXI4L_WDATA        (bridge_axil_wdata),
        .AXI4L_WSTRB        (bridge_axil_wstrb),
        .AXI4L_WREADY       (bridge_axil_wready),
        .AXI4L_BVALID       (bridge_axil_bvalid),
        .AXI4L_BRESP        (bridge_axil_bresp),
        .AXI4L_BREADY       (bridge_axil_bready),
        .AXI4L_ARVALID      (bridge_axil_arvalid),
        .AXI4L_ARADDR       (bridge_axil_araddr),
        .AXI4L_ARPROT       (bridge_axil_arprot),
        .AXI4L_ARREADY      (bridge_axil_arready),
        .AXI4L_RVALID       (bridge_axil_rvalid),
        .AXI4L_RRESP        (bridge_axil_rresp),
        .AXI4L_RDATA        (bridge_axil_rdata),
        .AXI4L_RREADY       (bridge_axil_rready)
    );

    // ── AXI-Lite bus mux: FSM vs bridge to I2C master ─────────────────────
    // FSM owns the I2C-master AXIL bus when in any active negotiation state:
    //   2=WAIT, 3=CLAIM, 4=POLL, 8=MASK_RES_TX (write peer's hs_result),
    //   9=MASK_RD_ADDR (set peer's reg pointer), 10=MASK_RD_DATA (read
    //   4 bytes from peer's link_lane_mask). States 0/1/5/6/7 are
    //   idle/init/done/bypass/error — the bridge owns the bus then so
    //   SW-issued I2C transactions (post-lock) can reach the IP.
    // nego_driving: FSM owns the I²C-master AXIL bus during
    //   2=WAIT, 3=CLAIM, 4=POLL,
    //   8=MASK_RES_TX, 9=MASK_RD_ADDR, 10=MASK_RD_DATA,
    // and during the training sub-flow:
    //   12=TRAIN_ENTER, 14=TRAIN_POLL_PEER, 15=TRAIN_EXIT.
    // State 11 (NEGO_DONE_PRE) and 13 (TRAIN_RUN) don't drive I²C.
    //
    // Note: nego_state_w is the 4-bit truncated view of the 5-bit
    // internal state, so the 5-bit ST_TRAIN_DONE (16) and ST_TRAIN_FAIL
    // (17) alias to 4'd0 and 4'd1 here — fine because we never want
    // nego_driving high in those terminal states, and 0/1 are IDLE/INIT
    // which set !role_in_nego.
    //
    // Also force nego_driving high after role_lock when train_in_progress
    // is asserted, because once role_lock latches role_in_nego goes low
    // and the AXIL mux would otherwise hand the bus back to the bridge.
    //
    // Bug N1 fix (2026-05-29): mask-handshake states 8/9/10 also need
    // post-lock coverage. When nego_won=1, role_lock_reg latches on the
    // SAME edge the FSM advances 4 (POLL) → 8 (MASK_RES_TX) — i.e. while
    // the FSM is in the middle of an I²C transaction with TXN_DATA /
    // AXL_WR_RESP in flight. role_in_nego falls to 0, dropping nego_driving
    // to 0 and handing the AXIL bus back to the bridge mid-write. The FSM
    // sits forever waiting for m_axil_bvalid the bridge will never source.
    // train_in_progress_w covers 11-15 but not 8-10. mask_hs_in_progress
    // closes the gap; the prior diagnosis is in
    // docs/AUTONOMY_PHASE0C_SIM_TRACE.md and the regression at
    // cocotb/tidelink_top_pair/test_12_bug_n1_mask_handshake_advance.py
    // exercises it.
    wire mask_hs_in_progress = (nego_state_w == 4'd8) ||
                               (nego_state_w == 4'd9) ||
                               (nego_state_w == 4'd10);
    assign nego_driving = (role_in_nego && ((nego_state_w == 4'd2) ||
                                             (nego_state_w == 4'd3) ||
                                             (nego_state_w == 4'd4) ||
                                             (nego_state_w == 4'd8) ||
                                             (nego_state_w == 4'd9) ||
                                             (nego_state_w == 4'd10))) ||
                          mask_hs_in_progress ||
                          train_in_progress_w;

    assign mst_axil_awaddr  = nego_driving ? fsm_axil_awaddr  : bridge_axil_awaddr;
    assign mst_axil_awvalid = nego_driving ? fsm_axil_awvalid : bridge_axil_awvalid;
    assign mst_axil_wdata   = nego_driving ? fsm_axil_wdata   : bridge_axil_wdata;
    assign mst_axil_wstrb   = nego_driving ? fsm_axil_wstrb   : bridge_axil_wstrb;
    assign mst_axil_wvalid  = nego_driving ? fsm_axil_wvalid  : bridge_axil_wvalid;
    assign mst_axil_bready  = nego_driving ? fsm_axil_bready  : bridge_axil_bready;
    assign mst_axil_araddr  = nego_driving ? fsm_axil_araddr  : bridge_axil_araddr;
    assign mst_axil_arvalid = nego_driving ? fsm_axil_arvalid : bridge_axil_arvalid;
    assign mst_axil_rready  = nego_driving ? fsm_axil_rready  : bridge_axil_rready;

    // Feedback from I2C master to bridge (gate when FSM is driving)
    assign bridge_axil_awready = nego_driving ? 1'b0 : mst_axil_awready;
    assign bridge_axil_wready  = nego_driving ? 1'b0 : mst_axil_wready;
    assign bridge_axil_bvalid  = nego_driving ? 1'b0 : mst_axil_bvalid;
    assign bridge_axil_bresp   = mst_axil_bresp;
    assign bridge_axil_arready = nego_driving ? 1'b0 : mst_axil_arready;
    assign bridge_axil_rvalid  = nego_driving ? 1'b0 : mst_axil_rvalid;
    assign bridge_axil_rdata   = mst_axil_rdata;
    assign bridge_axil_rresp   = mst_axil_rresp;

    i2c_master_axil u_i2c_master (
        .clk                (apb_clk),
        .rst                (i2c_mst_reset),
        .s_axil_awaddr      (mst_axil_awaddr[3:0]),
        .s_axil_awprot      (bridge_axil_awprot),
        .s_axil_awvalid     (mst_axil_awvalid),
        .s_axil_awready     (mst_axil_awready),
        .s_axil_wdata       (mst_axil_wdata),
        .s_axil_wstrb       (mst_axil_wstrb),
        .s_axil_wvalid      (mst_axil_wvalid),
        .s_axil_wready      (mst_axil_wready),
        .s_axil_bresp       (mst_axil_bresp),
        .s_axil_bvalid      (mst_axil_bvalid),
        .s_axil_bready      (mst_axil_bready),
        .s_axil_araddr      (mst_axil_araddr[3:0]),
        .s_axil_arprot      (bridge_axil_arprot),
        .s_axil_arvalid     (mst_axil_arvalid),
        .s_axil_arready     (mst_axil_arready),
        .s_axil_rdata       (mst_axil_rdata),
        .s_axil_rresp       (mst_axil_rresp),
        .s_axil_rvalid      (mst_axil_rvalid),
        .s_axil_rready      (mst_axil_rready),
        .nBSY_IRQ           (i2c_nbsy_irq),
        .nRD_EMPTY_IRQ      (i2c_nrd_empty_irq),
        .i2c_scl_i          (i2c_scl_i),
        .i2c_scl_o          (mst_scl_o),
        .i2c_scl_t          (mst_scl_t),
        .i2c_sda_i          (i2c_sda_i),
        .i2c_sda_o          (mst_sda_o),
        .i2c_sda_t          (mst_sda_t),
        // Bug N7/N8 silicon observability — Region C i2c_master STATUS probe
        .status_o           (obs_i2c_mst_status_w)
    );

    // =====================================================================
    // I2C Slave Path
    //   SCL/SDA → i2c_slave_axil_master → mkaxil2apb_bridge → internal APB
    // =====================================================================

    wire [12:0]  slv_axil_awaddr;
    wire [2:0]   slv_axil_awprot;
    wire         slv_axil_awvalid;
    wire         slv_axil_awready;
    wire [31:0]  slv_axil_wdata;
    wire [3:0]   slv_axil_wstrb;
    wire         slv_axil_wvalid;
    wire         slv_axil_wready;
    wire [1:0]   slv_axil_bresp;
    wire         slv_axil_bvalid;
    wire         slv_axil_bready;
    wire [12:0]  slv_axil_araddr;
    wire [2:0]   slv_axil_arprot;
    wire         slv_axil_arvalid;
    wire         slv_axil_arready;
    wire [31:0]  slv_axil_rdata;
    wire [1:0]   slv_axil_rresp;
    wire         slv_axil_rvalid;
    wire         slv_axil_rready;

    wire         slv_scl_o, slv_scl_t;
    wire         slv_sda_o, slv_sda_t;

    i2c_slave_axil_master #(
        .ADDR_WIDTH         (13)
    ) u_i2c_slave (
        .clk                (apb_clk),
        .rst                (i2c_slv_reset),

        .i2c_scl_i          (i2c_scl_i),
        .i2c_scl_o          (slv_scl_o),
        .i2c_scl_t          (slv_scl_t),
        .i2c_sda_i          (i2c_sda_i),
        .i2c_sda_o          (slv_sda_o),
        .i2c_sda_t          (slv_sda_t),

        .m_axil_awaddr      (slv_axil_awaddr),
        .m_axil_awprot      (slv_axil_awprot),
        .m_axil_awvalid     (slv_axil_awvalid),
        .m_axil_awready     (slv_axil_awready),
        .m_axil_wdata       (slv_axil_wdata),
        .m_axil_wstrb       (slv_axil_wstrb),
        .m_axil_wvalid      (slv_axil_wvalid),
        .m_axil_wready      (slv_axil_wready),
        .m_axil_bresp       (slv_axil_bresp),
        .m_axil_bvalid      (slv_axil_bvalid),
        .m_axil_bready      (slv_axil_bready),
        .m_axil_araddr      (slv_axil_araddr),
        .m_axil_arprot      (slv_axil_arprot),
        .m_axil_arvalid     (slv_axil_arvalid),
        .m_axil_arready     (slv_axil_arready),
        .m_axil_rdata       (slv_axil_rdata),
        .m_axil_rresp       (slv_axil_rresp),
        .m_axil_rvalid      (slv_axil_rvalid),
        .m_axil_rready      (slv_axil_rready),

        .busy               (i2c_slv_busy),
        .bus_addressed      (i2c_slv_addressed),
        .bus_active         (),
        .enable             (1'b1),
        .device_address     (role_in_nego ? 7'h7E : i2c_slv_addr_reg)
    );

    // AXI-Lite to APB bridge for I2C slave path
    // (slv_apb_* declarations hoisted above — see "Bug N2 fix" block.)

    // Wlink APB response wires — declared before first use (bridge outputs drive these)
    wire [31:0]     wl_apb_prdata;
    wire            wl_apb_pready;
    wire            wl_apb_pslverr;

    // Bug N2 fix: AXIL→APB bridge response gated by the slv_apb hit decode.
    // When slv_apb_* targets Region 4/8, the response is sourced from the
    // chiplet-controller's combinational ctrl_reg_rdata mux and PREADY is
    // asserted unconditionally (single-cycle ack, matching Wlink semantics).
    // Otherwise we pass Wlink's response through, exactly as before.
    wire [31:0]     slv_apb_bridge_prdata  = slv_apb_ctrl_hit ? ctrl_reg_rdata
                                                              : wl_apb_prdata;
    wire            slv_apb_bridge_pready  = slv_apb_ctrl_hit ? 1'b1
                                                              : wl_apb_pready;
    wire            slv_apb_bridge_pslverr = slv_apb_ctrl_hit ? 1'b0
                                                              : wl_apb_pslverr;

    mkaxil2apb_bridge u_axil2apb (
        .CLK                (apb_clk),
        .RST_N              (hresetn),

        .AXI4L_AWVALID      (slv_axil_awvalid),
        .AXI4L_AWADDR       (slv_axil_awaddr),
        .AXI4L_AWPROT       (slv_axil_awprot),
        .AXI4L_AWREADY      (slv_axil_awready),
        .AXI4L_WVALID       (slv_axil_wvalid),
        .AXI4L_WDATA        (slv_axil_wdata),
        .AXI4L_WSTRB        (slv_axil_wstrb),
        .AXI4L_WREADY       (slv_axil_wready),
        .AXI4L_BVALID       (slv_axil_bvalid),
        .AXI4L_BRESP        (slv_axil_bresp),
        .AXI4L_BREADY       (slv_axil_bready),
        .AXI4L_ARVALID      (slv_axil_arvalid),
        .AXI4L_ARADDR       (slv_axil_araddr),
        .AXI4L_ARPROT       (slv_axil_arprot),
        .AXI4L_ARREADY      (slv_axil_arready),
        .AXI4L_RVALID       (slv_axil_rvalid),
        .AXI4L_RRESP        (slv_axil_rresp),
        .AXI4L_RDATA        (slv_axil_rdata),
        .AXI4L_RREADY       (slv_axil_rready),

        .APB_PADDR          (slv_apb_paddr),
        .APB_PROT           (slv_apb_pprot),
        .APB_PENABLE        (slv_apb_penable),
        .APB_PWRITE         (slv_apb_pwrite),
        .APB_PWDATA         (slv_apb_pwdata),
        .APB_PSTRB          (slv_apb_pstrb),
        .APB_PSEL           (slv_apb_psel),
        // Bug N2 fix: response now sourced from a mux between the
        // chiplet-controller register decoder (Region 4/8 hits) and Wlink
        // (everything else). See slv_apb_bridge_* wires above.
        .APB_PREADY         (slv_apb_bridge_pready),
        .APB_PRDATA         (slv_apb_bridge_prdata),
        .APB_PSLVERR        (slv_apb_bridge_pslverr)
    );

    // =====================================================================
    // I2C Pin Mux
    // =====================================================================
    assign i2c_scl_o = role_is_master ? mst_scl_o : slv_scl_o;
    // SHORTCOMINGS-14a fix: the I2C slave core is a clock-stretching slave —
    // it pulls SCL low while the inbound AXIL→APB write to Wlink retires.
    // Forcing i2c_scl_t=1'b1 here discarded that stretch, so the peer master
    // clocked the next byte before the slave's APB round-trip landed →
    // multi-byte transactions wedged (mask-handshake + ST_TRAIN_*). Pass the
    // slave core's open-drain SCL drive onto the wired-AND bus instead.
    assign i2c_scl_t = role_is_master ? mst_scl_t : slv_scl_t;
    assign i2c_sda_o = role_is_master ? mst_sda_o : slv_sda_o;
    assign i2c_sda_t = role_is_master ? mst_sda_t : slv_sda_t;

    // =====================================================================
    // Auto-negotiation FSM
    // =====================================================================

    tidelink_autoneg u_autoneg (
        .clk                (apb_clk),
        .poresetn           (poresetn),
        .nego_en            (nego_cfg_reg[0]),
        .nego_start         (nego_cfg_reg[1]),
        .nego_pri_sel       (nego_cfg_reg[3:2]),
        .nego_fallback      (nego_cfg_reg[4]),
        .nego_force_lock    (nego_cfg_reg[5]),
        .nego_priority_reg  (nego_priority_reg),
        .nego_priority_i    (nego_priority_i),
        .puf_seed           (puf_seed),
        .puf_ready          (puf_ready),
        .nego_timeout_reg   (nego_timeout_reg),
        .i2c_sda_i          (i2c_sda_i),
        .i2c_scl_i          (i2c_scl_i),
        .i2c_prescale_reg   (i2c_prescale_reg),
        .m_axil_awaddr      (fsm_axil_awaddr),
        .m_axil_awvalid     (fsm_axil_awvalid),
        .m_axil_awready     (mst_axil_awready),
        .m_axil_wdata       (fsm_axil_wdata),
        .m_axil_wstrb       (fsm_axil_wstrb),
        .m_axil_wvalid      (fsm_axil_wvalid),
        .m_axil_wready      (mst_axil_wready),
        .m_axil_bresp       (mst_axil_bresp),
        .m_axil_bvalid      (mst_axil_bvalid),
        .m_axil_bready      (fsm_axil_bready),
        .m_axil_araddr      (fsm_axil_araddr),
        .m_axil_arvalid     (fsm_axil_arvalid),
        .m_axil_arready     (mst_axil_arready),
        .m_axil_rdata       (mst_axil_rdata),
        .m_axil_rresp       (mst_axil_rresp),
        .m_axil_rvalid      (mst_axil_rvalid),
        .m_axil_rready      (fsm_axil_rready),
        .nego_role_r        (nego_role_w),
        .nego_set_role_cfg  (nego_set_role_cfg_w),
        .nego_role_value    (nego_role_value_w),
        .nego_set_role_lock (nego_set_role_lock_w),
        .nego_state         (nego_state_w),
        .nego_done          (nego_done_w),
        .nego_error         (nego_error_w),
        .nego_won           (nego_won_w),
        .nego_lost          (nego_lost_w),
        .sda_start_seen     (nego_sda_start_seen),
        .nego_error_irq     (nego_error_irq_internal),

        // Phase 2 peer-mask handshake hooks. Local mask comes from Wlink's
        // tx_lane_mask_o / rx_lane_mask_o; captured peer mask drives Wlink's
        // link_lane_mask_peer @ 0x218; mask_hs_local_match feeds the gate.
        // These tie through to scaffolding registers in the FSM (currently
        // zeroed) — Phase 2B fills in the I2C transactions that populate
        // them.
        .local_tx_lane_mask_i (wlink_tx_lane_mask),
        .local_rx_lane_mask_i (wlink_rx_lane_mask),
        .peer_tx_lane_mask_o  (autoneg_peer_tx_lane_mask),
        .peer_rx_lane_mask_o  (autoneg_peer_rx_lane_mask),
        .mask_hs_local_match  (autoneg_mask_hs_local_match),
        .mask_hs_local_fail   (autoneg_mask_hs_local_fail),
        .mask_hs_auto_en      (nego_cfg_reg[6]),

        // Phase 3 — I²C-coordinated training-mode coordination. The
        // local_swi_lane_* inputs are the REAL calibrator/lane-checker
        // values (synced into apb_clk by the Region 8 CDC above), NOT
        // placeholders — so the autoneg FSM polls genuine lock/fault/done.
        .train_auto_en             (nego_train_cfg_r[0]),
        .train_sw_step             (nego_train_cfg_r[1]),
        .train_retrain_req         (nego_train_retrain_pulse),
        .train_poll_timeout        (nego_train_cfg_r[7:4]),
        .train_fsm_wait_hi         (nego_train_cfg_r[15:8]),
        .local_swi_lane_locked_i   (sync_lane_locked_1),
        .local_swi_lane_fault_i    (sync_lane_fault_1),
        .local_calibration_done_i  (sync_cal_done_1),
        .local_training_mode_set   (local_training_mode_set_w),
        .local_training_mode_clr   (local_training_mode_clr_w),
        .local_swreset_pulse       (local_swreset_pulse_w),
        .train_state_o             (train_state_w),
        .train_ok_o                (train_ok_w),
        .train_fail_o              (train_fail_w),
        .train_in_progress_o       (train_in_progress_w),
        .train_peer_nack_o         (train_peer_nack_w),
        .train_peer_lane_locked_o  (train_peer_lane_locked_w),
        .train_peer_lane_fault_o   (train_peer_lane_fault_w),
        .train_local_lane_fault_o  (train_local_lane_fault_w),
        .train_fail_irq_o          (train_fail_irq_w),

        // Bug N7/N8 silicon observability — Region C probes
        .obs_delay_ctr_o           (obs_delay_ctr_w),
        .obs_timeout_ctr_o         (obs_timeout_ctr_w),
        .obs_init_wait_o           (obs_init_wait_w),
        .obs_axl_state_o           (obs_axl_state_w),
        .obs_txn_step_o            (obs_txn_step_w)
    );

    // Phase 1 (G1, G1b) closure: all training-coordination outputs are
    // now consumed at this scope:
    //   * local_training_mode_set_w / clr_w → swi_training_mode_r mux
    //   * local_swreset_pulse_w           → u_calibrator.swreset (OR-merge
    //                                       with swi_recal_r, G1)
    //   * train_fail_irq_w                → train_fail_irq_r sticky reg
    //                                       (W1C via Region 8 slot 3'h3
    //                                       bit[16]; exported as
    //                                       train_fail_irq_o, G1b)
    // No `_unused_phase3_*` dead-end wires remain.

    // OR the FSM's error pulse with the sticky mask-mismatch flag so SW sees
    // either cause through the same IRQ line.
    assign nego_error_irq = nego_error_irq_internal | nego_mask_mismatch_reg;

    // =====================================================================
    // Wlink APB Mux
    //   Master mode: external APB drives Wlink directly
    //   Slave mode:  I2C slave APB has priority; external gets read-only
    //                access when I2C is idle
    // =====================================================================

    reg             wl_apb_psel;
    reg  [12:0]     wl_apb_paddr;
    reg             wl_apb_penable;
    reg  [2:0]      wl_apb_pprot;
    reg  [3:0]      wl_apb_pstrb;
    reg             wl_apb_pwrite;
    reg  [31:0]     wl_apb_pwdata;
    // wl_apb_prdata, wl_apb_pready, wl_apb_pslverr declared above (before bridge)

    // Slave mode: I2C path active when psel asserted
    wire slv_apb_active = slv_apb_psel && !role_is_master;

    // Bug N2 fix: slv_apb_* drives Wlink only when the address is NOT in
    // the chiplet-controller's register space (Region 4/8). When
    // slv_apb_ctrl_hit is asserted, the AXIL→APB bridge response comes
    // from ctrl_reg_rdata (see slv_apb_bridge_* mux above) and Wlink is
    // not poked, so PSEL must be held low for that case.
    wire slv_apb_to_wlink = slv_apb_active && !slv_apb_ctrl_hit;

    always_comb begin
        if (role_is_master) begin
            // Master mode: external APB direct to Wlink
            wl_apb_psel    = apb_psel;
            wl_apb_paddr   = apb_paddr;
            wl_apb_penable = apb_penable;
            wl_apb_pprot   = apb_pprot;
            wl_apb_pstrb   = apb_pstrb;
            wl_apb_pwrite  = apb_pwrite;
            wl_apb_pwdata  = apb_pwdata;
        end else if (slv_apb_to_wlink) begin
            // Slave mode, I2C path active, NOT targeting chiplet-controller
            // Region 4/8: forward to Wlink as before.
            wl_apb_psel    = slv_apb_psel;
            wl_apb_paddr   = slv_apb_paddr;
            wl_apb_penable = slv_apb_penable;
            wl_apb_pprot   = slv_apb_pprot;
            wl_apb_pstrb   = slv_apb_pstrb;
            wl_apb_pwrite  = slv_apb_pwrite;
            wl_apb_pwdata  = slv_apb_pwdata;
        end else if (slv_apb_active) begin
            // Slave mode, I2C path active, targets chiplet-controller (Bug N2
            // fix path). Don't poke Wlink — hold psel low. The bridge gets
            // its response from slv_apb_bridge_* (ctrl_reg_rdata).
            wl_apb_psel    = 1'b0;
            wl_apb_paddr   = '0;
            wl_apb_penable = 1'b0;
            wl_apb_pprot   = '0;
            wl_apb_pstrb   = '0;
            wl_apb_pwrite  = 1'b0;
            wl_apb_pwdata  = '0;
        end else if (apb_debug_unlock_i) begin
            // Slave mode + debug strap asserted: pass external APB through
            // *with* writes enabled. Bring-up debug — lets slave's PYNQ
            // configure Wlink locally without I2C from master.
            wl_apb_psel    = apb_psel;
            wl_apb_paddr   = apb_paddr;
            wl_apb_penable = apb_penable;
            wl_apb_pprot   = apb_pprot;
            wl_apb_pstrb   = apb_pstrb;
            wl_apb_pwrite  = apb_pwrite;
            wl_apb_pwdata  = apb_pwdata;
        end else begin
            // Slave mode, I2C idle: external APB read-only access
            wl_apb_psel    = apb_psel;
            wl_apb_paddr   = apb_paddr;
            wl_apb_penable = apb_penable;
            wl_apb_pprot   = apb_pprot;
            wl_apb_pstrb   = 4'b0;     // no byte strobes for reads
            wl_apb_pwrite  = 1'b0;     // gate writes in slave mode
            wl_apb_pwdata  = 32'b0;
        end
    end

    // =====================================================================
    // SoC Labs §9 PHY alignment — auto-cal calibrator + per-lane lock
    // checker. The interim APB shim (tidelink_phy_align_regs at the
    // Wlink-domain 0x4403_1000 carve, wl_apb_paddr[12]=1) was REMOVED in
    // the §9 integration: its SW-override + RO-status registers now live
    // in the Region 8 block above (MMIO 0x4403_2100..0x4403_211C). Wlink
    // therefore sees the full APB region directly (no paddr[12] split).
    // The calibrator/lane-checker output net declarations were hoisted
    // above the Region 8 block (this module uses `default_nettype none`,
    // so forward net references are illegal).
    // =====================================================================

    // cal_state_w is exposed only through the (now-removed) shim's
    // cal_state_in port; Region 8 SWI_LANE_STATUS does not surface it.
    // Keep the calibrator driving it but mark deliberately unused.
    /* verilator lint_off UNUSED */
    wire [3:0] _unused_cal_state = cal_state_w;
    /* verilator lint_on UNUSED */

    // =====================================================================
    // SoC Labs §9 auto-cal: per-lane lock checker + parallel slip-sweep FSM
    //
    // Both blocks live in the link_rx_clk domain (the recovered RX clock).
    // The lane checker observes the 128-bit deserialised lane data and
    // outputs lane_locked[7:0]. The calibrator polls lane_locked, drives
    // a per-lane bit_slip + training_mode pattern, and asserts
    // calibration_done once every lane has either locked or faulted out.
    //
    // The calibrator's outputs are OR'd with the Region 8 SW-override
    // regs (swi_bit_slip_lo_r / swi_training_mode_r) before driving Wlink
    // — this preserves the hierarchical-force backdoor path used by cocotb
    // (default SW-override = 0, default cal-not-running output = 0 →
    // bit-exact passthrough).
    // =====================================================================
    // tidelink-gpio-phy lane_checker (from deps/tidelink-gpio-phy submodule).
    // Spec: deps/tidelink-gpio-phy/docs/TRAINING_MODULE_SPEC.md §3-7.
    // Reset polarity: rst_n is active-low; role_locked is the natural enable
    // so connect directly (INTEGRATION_GUIDE.md §5.2). sweep_active is
    // derived from cal_state_w[2:0] == S_SWEEP (3'd2 in the calibrator's
    // state enum).
    wire sweep_active_w = (cal_state_w == 4'd2);
    assign link_rx_clk_o = phy_link_rx_rx_link_clk_w;

    // SoC Labs M2 (2026-06-05): reset synchroniser on lane_checker.rst_n.
    // Previous code wired `role_locked` (apb_clk-domain register) directly to
    // the 8-instance lane_checker reset tree clocked by phy_link_rx_rx_link_clk_w.
    // Without per-instance reset synchronisation the 8 checkers can deassert
    // reset on different cycles → some lanes start mid-pattern with stale
    // match_count, producing the silicon-only "slave fails to converge"
    // signature observed at v14 (30% over 10 deploys).
    // Pattern: async-assert / sync-deassert. role_locked falling instantly
    // re-asserts reset (POR), rising propagates through 2 FFs.
    reg lane_checker_rst_n_meta_r, lane_checker_rst_n_sync_r;
    always @(posedge phy_link_rx_rx_link_clk_w or negedge role_locked) begin
        if (!role_locked) begin
            lane_checker_rst_n_meta_r <= 1'b0;
            lane_checker_rst_n_sync_r <= 1'b0;
        end else begin
            lane_checker_rst_n_meta_r <= 1'b1;
            lane_checker_rst_n_sync_r <= lane_checker_rst_n_meta_r;
        end
    end

    // SoC Labs M1 third-leg (2026-06-05): synchronise swi_training_mode_w
    // into rx_link_clk before feeding the lane_checker's training_mode_w_i.
    // The lane_checker's internal training_mode_rise edge detect was the
    // primary failure-mode candidate H1 — a missed rising-edge skips the
    // match_count clear and the lane can never lock. 2-FF sync ensures the
    // edge presents as a clean 0→1 transition in the checker's clock
    // domain regardless of apb_clk phase relationship per deploy.
    reg swi_training_mode_lc_meta_r, swi_training_mode_lc_sync_r;
    always @(posedge phy_link_rx_rx_link_clk_w or negedge poresetn) begin
        if (!poresetn) begin
            swi_training_mode_lc_meta_r <= 1'b0;
            swi_training_mode_lc_sync_r <= 1'b0;
        end else begin
            swi_training_mode_lc_meta_r <= swi_training_mode_w;
            swi_training_mode_lc_sync_r <= swi_training_mode_lc_meta_r;
        end
    end

    tidelink_lane_checker u_lane_checker (
        .clk                 (phy_link_rx_rx_link_clk_w),
        .rst_n               (lane_checker_rst_n_sync_r), // M2: sync'd from role_locked
        .lane_data_i         (phy_link_rx_rx_link_data_w),
        .lock_thresh_i       (lane_lock_thresh_i),        // from APB regs at tidelink_top
        .training_mode_w_i   (swi_training_mode_lc_sync_r), // M1: sync'd from swi_training_mode_w
        .sweep_active_i      (sweep_active_w),
        .clear_noise_i       (lane_clear_noise_i),
        .lane_locked_o       (lane_locked_w),
        .mismatch_pulse_o    (lane_mismatch_pulse_o),
        .wire_status_o       (lane_wire_status_o),
        .dist_raw_o          (lane_dist_raw_o),
        .dist_voted_o        (lane_dist_voted_o),
        .dwell_min_dist_o    (lane_dwell_min_dist_o),     // for calibrator scoring (Stage 6)
        .noise_min_o         (lane_noise_min_o),
        .noise_max_o         (lane_noise_max_o),
        .noise_mean_o        (lane_noise_mean_o),
        .noise_current_o     (lane_noise_current_o),
        .canary_pass_o       (lane_canary_pass_o),
        .canary_valid_o      (lane_canary_valid_o)
    );

    // Calibrator role_locked trigger: gated by AUTOCAL_ENABLE (parameter,
    // default 0). When disabled the calibrator is held in S_IDLE; its
    // outputs stay at the safe defaults (bit_slip=0, training_mode=0,
    // calibration_done=0) so the OR-mux is a pure passthrough and existing
    // cocotb tests keep their hierarchical-force semantics.
    //
    // For the new cocotb autocal integration test, the test sets
    // `force u_<side>.u_chiplet.autocal_force_enable_q = 1'b1;` via
    // hierarchical reference to override the parameter at runtime.
    /* verilator lint_off UNDRIVEN */
    reg  autocal_force_enable_q = 1'b0;   // cocotb hierarchical-force hook
    /* verilator lint_on UNDRIVEN */
    wire autocal_enable_w        = AUTOCAL_ENABLE | autocal_force_enable_q;
    wire calibrator_role_locked  = role_locked & autocal_enable_w;

    // =====================================================================
    // Bug N3 fix (2026-05-30): re-arm calibrator when autoneg FSM enables
    // training-mode on this side.
    //
    // Symptom (test_10_autonomous_train_post_por, post Bug N1+N2 fixes):
    //   t≈ 61 µs  slave role_locked rises → calibrator's only trigger
    //             (role_locked_rise) fires → calibrator sweeps against
    //             master's NON-training traffic → finds no eye → parks
    //             in S_DONE with calibration_done=0.
    //   t≈ 2.3 ms master's I²C-write of slave's SWI_TRAINING_MODE=1
    //             lands (Bug N2 fix path) → slave's swi_training_mode_w
    //             rises → lane_checker now decodes the live training
    //             pattern → lane_locked_w=0xFF.
    //             BUT the calibrator is parked in S_DONE and has no
    //             re-arm trigger — `local_swreset_pulse_w` is only
    //             generated at ST_TRAIN_EXIT (post-success), not at
    //             ST_TRAIN_ENTER/RUN.
    //   t≈14461 ms master times out POLL_PEER on peer_cal_done=0 →
    //             ST_TRAIN_FAIL.
    //
    // Fix: detect `swi_training_mode_r` 0→1 rising edge and stretch it
    // into a T_SWRESET_HOLD-wide level pulse (127 apb_clk cycles, matches
    // the FSM's ST_TRAIN_EXIT pulse width). OR this into the calibrator's
    // swreset port. The calibrator's swreset_fall edge detector fires
    // when the pulse falls (with role_locked still high), re-triggering
    // a fresh sweep — this time against the live training pattern.
    //
    // CRITICAL — first-revision lesson learned: a prior version of this
    // fix triggered on `local_training_mode_set_w` (the autoneg FSM's
    // ST_TRAIN_ENTER ACK pulse). That signal fires on the MASTER's
    // chiplet only, because slave's autoneg FSM goes 4→5 (ST_NEGO_DONE)
    // directly upon losing — it never enters ST_TRAIN_ENTER. The SLAVE's
    // swi_training_mode_r is set by the I²C-driven APB write (Bug N2
    // fix path), not by local_training_mode_set_w. Detecting the rising
    // edge of swi_training_mode_r catches BOTH sides — master's
    // FSM-driven pulse AND slave's APB-write-driven pulse — without
    // coupling to the autoneg topology.
    //
    // Same clock domain (apb_clk) as the existing local_swreset_pulse_w
    // and swi_recal_r OR-merged into the same port, so the calibrator's
    // internal swreset_q edge-detect (rx_link_clk domain) sees the same
    // SW-paced ms-scale level it has always tolerated.
    // =====================================================================
    reg swi_training_mode_q;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) swi_training_mode_q <= 1'b0;
        else           swi_training_mode_q <= swi_training_mode_r;
    end
    wire swi_training_mode_rise = swi_training_mode_r & ~swi_training_mode_q;

    // Bug N14b widening (2026-06-02): the 127-cycle apb_clk pulse below
    // crosses into the rx_link_clk domain at the calibrator's swreset
    // input (line ~1881). On v1 ASIC silicon (apb_clk≈50 MHz,
    // link_rx_clk = pad_clk/16 ≈ 6.25 MHz), 127 apb_clk cycles = ~16
    // link_rx_clk cycles — adequate margin in nominal timing but
    // marginal once OCV / clock skew on the rx-recovered domain is
    // factored in. Silicon v13 showed master-on-lost-path with
    // lane_locked stuck at 0x00 and cal_done=0, consistent with the
    // re-arm pulse never propagating into the calibrator's rx_link_clk
    // swreset_q edge detector (Path B per docs/BUG_N14B…).
    //
    // Sim (cocotb/tidelink_top_pair/test_26) does NOT reproduce the
    // wedge — master converges in ~2 ms via the natural pre-TRAIN_ENTER
    // free-running sweep — so this widening is a defensive HW-only
    // backstop with zero impact on the sim regression suite. The pulse
    // is purely additive on the calibrator's swreset port (OR'd with
    // swi_recal_r and local_swreset_pulse_w), so a wider HIGH window
    // can only make S_CANCEL→S_ARM more reliable, never less. Widen to
    // 10-bit counter (1023 cycles ≈ 20.5 µs ≈ 128 link_rx_clk cycles at
    // ASIC speeds) — eight bits of headroom over the prior 127.
    reg [9:0] training_mode_swreset_hold_r;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            training_mode_swreset_hold_r <= 10'd0;
        else if (swi_training_mode_rise)
            training_mode_swreset_hold_r <= 10'd1023;  // 8× T_SWRESET_HOLD
        else if (training_mode_swreset_hold_r != 10'd0)
            training_mode_swreset_hold_r <= training_mode_swreset_hold_r - 10'd1;
    end
    wire training_mode_set_swreset_w = (training_mode_swreset_hold_r != 10'd0);

    // Path B — Bug N4 HW-real fix (2026-05-30): reduce HOLD_CYCLES default.
    //
    // The calibrator's HOLD_CYCLES default is 8 * 128 * DWELL_CYCLES =
    // 65536 link_rx_clk cycles. At HW (link_rx_clk = pad_clk/16 = ~1.5 MHz)
    // that's 43 ms of S_HOLD before S_VALIDATE/S_DONE. The autoneg FSM's
    // POLL_PEER timeout is 15 polls × ~600 µs ≈ 9 ms — way too short for
    // the calibrator's slave side to reach S_DONE within the FSM's poll
    // window, so master times out → ST_TRAIN_FAIL even though the slave's
    // (slip, phase) has been latched correctly and lanes ARE locked.
    //
    // 8 sweep-periods of HOLD was designed for FREE-RUNNING bring-up where
    // the peer's calibrator needed time to converge independently. Under
    // autoneg coordination, the master holds peer's training_mode HIGH via
    // its I²C-write (Bug N2 fix path); the peer's TX is reliably emitting
    // training pattern throughout ST_TRAIN_RUN + ST_TRAIN_POLL_PEER, so the
    // long mutual-overlap dwell is unnecessary.
    //
    // Reduce to 1024 link_rx_clk cycles (≈ 683 µs at HW, ≈ 340 µs in sim).
    // Keeps a small overlap margin but fits comfortably inside the autoneg
    // poll budget.
    tidelink_phy_align_calibrator #(
        .HOLD_CYCLES(32768),            // M10: 5.2ms at 6.25MHz → 4 full sweeps while slave trains;
                                        //      was 1024 (163μs, <1 sweep) which left master no time.
        .VALIDATION_TIMEOUT(2_000_000)  // M6: 320ms at 6.25MHz FPGA link clk
    ) u_calibrator (
        .clk                   (phy_link_rx_rx_link_clk_w),
        .rst                   (~poresetn),
        .role_locked           (calibrator_role_locked),
        // swreset → falling edge re-triggers a sweep while role_locked is
        // still high. Driven by Region 8 SWI_RECAL (slot 0 bit[1], MMIO
        // 0x4403_2100). Crosses apb_clk→rx_link_clk the same way
        // calibrator_role_locked does (relies on the calibrator's internal
        // swreset_q edge-detect; SW-paced ms-scale level so metastability on
        // the recal edge is a non-issue for bring-up). Needed because the
        // cold-boot role_locked edge sweeps in a staggered, non-overlapping
        // window under SSH deploy; SWI_RECAL lets SW re-arm with the
        // training pattern held HIGH on both boards.
        //
        // Phase 1 autonomy (G1): OR-merge the autoneg FSM's
        // `local_swreset_pulse_w` so ST_TRAIN_EXIT's T_SWRESET_HOLD (127-cycle)
        // pulse re-triggers a calibrator sweep without SW intervention. The
        // pulse is wholly inside the chiplet-controller scope and never flows
        // through the APB pwdata path, so the Tier-2 hardening shim in
        // tidelink_top.sv (AND-mask on 0x208 bit[3]) does NOT see this signal
        // — exactly what we want for an autonomous bring-up. SWI_RECAL keeps
        // working in parallel for SW-driven manual recovery.
        .swreset               (swi_recal_r | local_swreset_pulse_w),
        .lane_locked           (lane_locked_w),
        // tidelink-gpio-phy scoring (spec §7.1): the calibrator now uses a
        // continuous min-distance metric per dwell for eye-centre selection,
        // not just binary lane_locked. The new lane_checker drives this bus
        // from the per-lane voted Hamming distance (5-bit, 0..16).
        .dwell_min_dist_i      (lane_dwell_min_dist_o),
        // APB override of the calibrator is implemented in the OR-mux below
        // rather than inside the calibrator (the calibrator's APB override
        // gate is left disabled here to keep the calibrator running even
        // when SW writes a non-zero override — both contributions OR
        // together).
        .apb_bit_slip_override (24'h0),
        .apb_override_enable   (1'b0),
        // §9.11c — drive 0 to use the synth-time MIN_LOCK_DWELLS parameter
        // default. The full APB-tunable register (Region 8 slot 0 bits[7:4])
        // M11 (2026-06-10): wire NEGO_TRAIN_CFG[7:4] → calibrator min_lock_dwells_i.
        // 0 = use parameter default (now MIN_LOCK_DWELLS=2); 1..15 = runtime override.
        // Allows SW to lower the eye-centre contiguity requirement on marginal-eye
        // hardware (die_a 2-3 consecutive passing phases < old default of 4).
        .min_lock_dwells_i     (nego_train_cfg_r[7:4]),
        // §9.11d Fix A1 — post-S_HOLD real-data validation. Drive from the
        // local Wlink FCSM's "saw the peer's CR_PKT on our RX" sticky flag.
        // Same clock domain as the calibrator (rx_link_clk) so no CDC. WITHOUT
        // this wiring the calibrator's S_VALIDATE state stalls on an undriven
        // cr_pkt_seen_i (X-propagation in sim, floating in synth) — observed
        // as cal_done=0 stuck-in-HOLD in cocotb/tidelink_top_pair test_01
        // after the eye-visibility submodule sync regressed this connection.
        .cr_pkt_seen_i         (obs_cr_pkt_seen_rx_w),
        // Fix A2 (2026-06-04): CRACK companion to cr_pkt_seen_i. The master's
        // RX only ever decodes the peer's CRACK (late framer byte-align), so
        // S_VALIDATE must accept it too — same rx_link_clk domain, no CDC.
        .crack_pkt_seen_i      (obs_crack_pkt_seen_rx_w),
        .bit_slip              (cal_bit_slip_w),
        .phase_offset          (cal_phase_offset_w),
        .training_mode         (cal_training_mode_w),
        .calibration_done      (cal_calibration_done_w),
        .lane_fault            (cal_lane_fault_w),
        .state                 (cal_state_w),
        // M7 observability (2026-06-05): auto-retry counter for stuck-sweep
        // diagnosis. Non-zero on a die cycling through sweeps without
        // convergence. Wired to Region C slot 3'h6 (MMIO 0x44032198).
        .resweep_ctr_o         (cal_resweep_ctr_w),
        // sweep_active_o = (cur_state == S_SWEEP). Functionally equivalent
        // to (cal_state_w == 4'd2) which is what the lane_checker's
        // sweep_active_i still consumes; this output is reserved for any
        // future consumer wanting an isolated decode.
        .sweep_active_o        (/* tied to sweep_active_w by decode above */),
        // v2 Eye visibility surface — driven by tidelink_eye_regs at the
        // tidelink_top boundary, plumbed in/out through the new
        // axi_chiplet_controller ports above.
        .swi_eye_lane_sel      (swi_eye_lane_sel_i),
        .swi_eye_dwell_us      (swi_eye_dwell_us_i),
        .swi_eye_ctrl          (swi_eye_ctrl_i),
        .eye_status            (eye_status_o),
        .eye_score_idx         (eye_score_idx_i),
        .eye_score_data        (eye_score_data_o),
        .eye_score_lane_passed (eye_score_lane_passed_o),
        .eye_score_best        (eye_score_best_o),
        .eye_score_best_slip   (eye_score_best_slip_o),
        .eye_score_best_phase  (eye_score_best_phase_o)
    );

    // EYE_LAST_LATCHED mirror — surface the current calibrator slip vector
    // and lane_fault to the eye_regs shim at top level.
    assign eye_last_slip_o       = cal_bit_slip_w;
    assign eye_last_lane_fault_o = cal_lane_fault_w;
    // SoC Labs Bug-A FCSM observation 2026-06-02 — drive the new module
    // outputs from the apb_clk-synced 2-flop CDC registers.
    assign obs_a2l_replay_link_valid_o = sync_obs_a2l_replay_v_1;
    assign obs_fe_rx_credit_max_o      = sync_obs_fe_rx_cred_1;
    assign obs_fe_rx_is_full_o         = sync_obs_fe_rx_full_1;
    // SoC Labs Bug-A FCSM observation 2026-06-03
    assign obs_a2l_replay_app_valid_o  = sync_obs_a2l_app_v_1;

    // SW-override OR-mux: calibrator OR Region 8 SW-override regs
    // (swi_bit_slip_lo_r / swi_training_mode_r) → swi_bit_slip_in /
    // swi_training_mode_in. Defaults are zero on both sides, so legacy
    // behaviour (no calibrator firing, no SW writes) is bit-exact unchanged.
    // The Region 8 training_mode reg is itself OR-driven by the autoneg
    // I²C FSM's local_training_mode_set/clr strobes (Step 4), so the
    // I²C-coordinated training path, the autonomous calibrator, and a
    // direct SW override all merge here.
    wire [23:0] swi_bit_slip_w      = cal_bit_slip_w      | swi_bit_slip_lo_r;
    // §9.7 per-lane phase: calibrator OR Region 8 SWI_PHASE_OFFSET
    // override → Wlink swi_phase_offset_in. Same pattern + defaults as
    // swi_bit_slip_w (both sides zero at boot → the per-lane OR-merge
    // inside WavD2DGpio falls back to the global APB phase, so the
    // pre-§9.7 single-global-phase behaviour is bit-exact preserved).
    assign      swi_phase_offset_w  = cal_phase_offset_w  | swi_phase_offset_r;
    assign      swi_training_mode_w = cal_training_mode_w | swi_training_mode_r;

    // =====================================================================
    // SoC Labs §9 structural fix (2026-05-18): per-lane IDELAYE2 RX delay
    // element, calibrator-driven.
    //
    // pad_rx[7:0] enters here straight from the top-level FPGA pads. We
    // route it through tidelink_idelay_rx, which (USE_IDELAY=1, FPGA only)
    // inserts one Xilinx IDELAYE2 per lane whose tap is LOADED from the
    // SAME per-lane phase the calibrator already drives into the Wlink
    // deserialiser (swi_phase_offset_w[4N +: 4]). This converts the
    // calibrator's "phase" from a deserialiser bit-SELECT only into a real,
    // characterised clk-to-data delay at the IOB — the structural fix for
    // the build-to-build slave-RX-lock nondeterminism (the proven
    // bring-up blocker).
    //
    // USE_IDELAY=0 (sim/ASIC default) → pad_rx_dly == pad_rx, bit-exact,
    // no Xilinx primitive referenced. The Wlink instance below consumes
    // pad_rx_dly instead of pad_rx — identical behaviour when disabled.
    wire [7:0] pad_rx_dly;
    tidelink_idelay_rx #(
        .USE_IDELAY (USE_IDELAY),
        .NUM_LANES  (8),
        .IDELAY_GRP ("tidelink_rx_idelay"),
        .REFCLK_MHZ (200.0)
    ) u_idelay_rx (
        .idelay_ref_clk (idelay_ref_clk),
        .idelay_rst     (idelay_rst),
        // calibrator->tap wiring: identical packed source as the Wlink
        // .swi_phase_offset_in (lane N nibble at [4N+3:4N], 0..15).
        .phase_tap_i    (swi_phase_offset_w),
        .pad_rx_i       (pad_rx),
        .pad_rx_o       (pad_rx_dly)
    );

    // Interim phy_align shim removed: Wlink owns the entire APB region
    // again (no paddr[12] split, no response mux). External APB response
    // passes Wlink straight back, stalled when the I²C slave bridge is
    // active.
    assign apb_prdata  = wl_apb_prdata;
    assign apb_pready  = slv_apb_active ? 1'b0 : wl_apb_pready;
    assign apb_pslverr = slv_apb_active ? 1'b0 : wl_apb_pslverr;

    // =====================================================================
    // SoC Labs §9 clock fix (2026-05-19): put the recovered RX clock on a
    // dedicated global BUFG before it fans into the Wlink GPIO PHY. The
    // routed netlist showed pad_clk_rx reaching the 8 lanes' capture flops
    // through fabric LUTs (Place 30-568) — the netlist-proven root cause of
    // the dead Y7-MRCC RX direction (HW swap test ruled out physical).
    // USE_CLKBUF=0 (sim/ASIC) → pad_clk_rx_buf == pad_clk_rx, bit-exact,
    // no Xilinx primitive referenced.
    // =====================================================================
    wire pad_clk_rx_buf;
    tidelink_rxclk_buf #(
        .USE_CLKBUF (USE_CLKBUF)
    ) u_rxclk_buf (
        .clk_i (pad_clk_rx),
        .clk_o (pad_clk_rx_buf)
    );

    // =====================================================================
    // Wlink Core Instance
    // =====================================================================
    Wlink #(.USE_CLKBUF(USE_CLKBUF), .USE_T3A(USE_T3A)) u_wlink (
        .apb_clk                    (apb_clk),
        .app_clk                    (app_clk),
        .user_hsclk                 (user_hsclk),

        .apb_reset                  (apb_reset),
        .por_reset                  (wlink_por_reset),
        .app_clk_reset              (app_clk_reset),

        .sb_reset_in                (sb_reset_in),
        .sb_reset_out               (sb_reset_out),
        .sb_wake                    (sb_wake),

        // APB — Wlink owns the full region (interim phy_align shim removed;
        // §9 SW-override + status moved to Region 8 of the TideLink config
        // APB). No paddr[12] gating.
        .apbport_0_psel             (wl_apb_psel),
        .apbport_0_paddr            (wl_apb_paddr),
        .apbport_0_penable          (wl_apb_penable),
        .apbport_0_pprot            (wl_apb_pprot),
        .apbport_0_pstrb            (wl_apb_pstrb),
        .apbport_0_pwrite           (wl_apb_pwrite),
        .apbport_0_pwdata           (wl_apb_pwdata),
        .apbport_0_prdata           (wl_apb_prdata),
        .apbport_0_pready           (wl_apb_pready),
        .apbport_0_pslverr          (wl_apb_pslverr),

        // AXI target
        .axi_tgt_0_aw_valid         (axi_tgt_0_aw_valid),
        .axi_tgt_0_aw_ready         (axi_tgt_0_aw_ready),
        .axi_tgt_0_aw_bits_id       (axi_tgt_0_aw_bits_id),
        .axi_tgt_0_aw_bits_addr     (axi_tgt_0_aw_bits_addr),
        .axi_tgt_0_aw_bits_len      (axi_tgt_0_aw_bits_len),
        .axi_tgt_0_aw_bits_size     (axi_tgt_0_aw_bits_size),
        .axi_tgt_0_aw_bits_burst    (axi_tgt_0_aw_bits_burst),
        .axi_tgt_0_aw_bits_lock     (axi_tgt_0_aw_bits_lock),
        .axi_tgt_0_aw_bits_cache    (axi_tgt_0_aw_bits_cache),
        .axi_tgt_0_aw_bits_prot     (axi_tgt_0_aw_bits_prot),
        .axi_tgt_0_aw_bits_qos      (axi_tgt_0_aw_bits_qos),

        .axi_tgt_0_w_valid          (axi_tgt_0_w_valid),
        .axi_tgt_0_w_ready          (axi_tgt_0_w_ready),
        .axi_tgt_0_w_bits_data      (axi_tgt_0_w_bits_data),
        .axi_tgt_0_w_bits_strb      (axi_tgt_0_w_bits_strb),
        .axi_tgt_0_w_bits_last      (axi_tgt_0_w_bits_last),

        .axi_tgt_0_b_valid          (axi_tgt_0_b_valid),
        .axi_tgt_0_b_ready          (axi_tgt_0_b_ready),
        .axi_tgt_0_b_bits_id        (axi_tgt_0_b_bits_id),
        .axi_tgt_0_b_bits_resp      (axi_tgt_0_b_bits_resp),

        .axi_tgt_0_ar_valid         (axi_tgt_0_ar_valid),
        .axi_tgt_0_ar_ready         (axi_tgt_0_ar_ready),
        .axi_tgt_0_ar_bits_id       (axi_tgt_0_ar_bits_id),
        .axi_tgt_0_ar_bits_addr     (axi_tgt_0_ar_bits_addr),
        .axi_tgt_0_ar_bits_len      (axi_tgt_0_ar_bits_len),
        .axi_tgt_0_ar_bits_size     (axi_tgt_0_ar_bits_size),
        .axi_tgt_0_ar_bits_burst    (axi_tgt_0_ar_bits_burst),
        .axi_tgt_0_ar_bits_lock     (axi_tgt_0_ar_bits_lock),
        .axi_tgt_0_ar_bits_cache    (axi_tgt_0_ar_bits_cache),
        .axi_tgt_0_ar_bits_prot     (axi_tgt_0_ar_bits_prot),
        .axi_tgt_0_ar_bits_qos      (axi_tgt_0_ar_bits_qos),

        .axi_tgt_0_r_valid          (axi_tgt_0_r_valid),
        .axi_tgt_0_r_ready          (axi_tgt_0_r_ready),
        .axi_tgt_0_r_bits_id        (axi_tgt_0_r_bits_id),
        .axi_tgt_0_r_bits_data      (axi_tgt_0_r_bits_data),
        .axi_tgt_0_r_bits_resp      (axi_tgt_0_r_bits_resp),
        .axi_tgt_0_r_bits_last      (axi_tgt_0_r_bits_last),

        // AXI initiator
        .axi_ini_0_aw_valid         (axi_ini_0_aw_valid),
        .axi_ini_0_aw_ready         (axi_ini_0_aw_ready),
        .axi_ini_0_aw_bits_id       (axi_ini_0_aw_bits_id),
        .axi_ini_0_aw_bits_addr     (axi_ini_0_aw_bits_addr),
        .axi_ini_0_aw_bits_len      (axi_ini_0_aw_bits_len),
        .axi_ini_0_aw_bits_size     (axi_ini_0_aw_bits_size),
        .axi_ini_0_aw_bits_burst    (axi_ini_0_aw_bits_burst),
        .axi_ini_0_aw_bits_lock     (axi_ini_0_aw_bits_lock),
        .axi_ini_0_aw_bits_cache    (axi_ini_0_aw_bits_cache),
        .axi_ini_0_aw_bits_prot     (axi_ini_0_aw_bits_prot),
        .axi_ini_0_aw_bits_qos      (axi_ini_0_aw_bits_qos),

        .axi_ini_0_w_valid          (axi_ini_0_w_valid),
        .axi_ini_0_w_ready          (axi_ini_0_w_ready),
        .axi_ini_0_w_bits_data      (axi_ini_0_w_bits_data),
        .axi_ini_0_w_bits_strb      (axi_ini_0_w_bits_strb),
        .axi_ini_0_w_bits_last      (axi_ini_0_w_bits_last),

        .axi_ini_0_b_valid          (axi_ini_0_b_valid),
        .axi_ini_0_b_ready          (axi_ini_0_b_ready),
        .axi_ini_0_b_bits_id        (axi_ini_0_b_bits_id),
        .axi_ini_0_b_bits_resp      (axi_ini_0_b_bits_resp),

        .axi_ini_0_ar_valid         (axi_ini_0_ar_valid),
        .axi_ini_0_ar_ready         (axi_ini_0_ar_ready),
        .axi_ini_0_ar_bits_id       (axi_ini_0_ar_bits_id),
        .axi_ini_0_ar_bits_addr     (axi_ini_0_ar_bits_addr),
        .axi_ini_0_ar_bits_len      (axi_ini_0_ar_bits_len),
        .axi_ini_0_ar_bits_size     (axi_ini_0_ar_bits_size),
        .axi_ini_0_ar_bits_burst    (axi_ini_0_ar_bits_burst),
        .axi_ini_0_ar_bits_lock     (axi_ini_0_ar_bits_lock),
        .axi_ini_0_ar_bits_cache    (axi_ini_0_ar_bits_cache),
        .axi_ini_0_ar_bits_prot     (axi_ini_0_ar_bits_prot),
        .axi_ini_0_ar_bits_qos      (axi_ini_0_ar_bits_qos),

        .axi_ini_0_r_valid          (axi_ini_0_r_valid),
        .axi_ini_0_r_ready          (axi_ini_0_r_ready),
        .axi_ini_0_r_bits_id        (axi_ini_0_r_bits_id),
        .axi_ini_0_r_bits_data      (axi_ini_0_r_bits_data),
        .axi_ini_0_r_bits_resp      (axi_ini_0_r_bits_resp),
        .axi_ini_0_r_bits_last      (axi_ini_0_r_bits_last),

        // General bus
        .generalbus_in              (generalbus_in),
        .generalbus_out             (generalbus_out),

        // TideLink FC node
        .tidelink_in                (tidelink_in),
        .tidelink_out               (tidelink_out),

        // PTP short packet
        .ptp_in                     (ptp_in),
        .ptp_out                    (ptp_out),

        // TX link idle
        .tx_link_idle               (tx_link_idle),

        // Scan / DFT
        .scan_mode                  (scan_mode),
        .scan_asyncrst_ctrl         (scan_asyncrst_ctrl),
        .scan_clk                   (scan_clk),
        .scan_shift                 (scan_shift),
        .scan_in                    (scan_in),
        .scan_out                   (scan_out),

        // Interrupt
        .interrupt                  (interrupt),

        // PHY pads
        .pad_clk_tx                 (pad_clk_tx),
        .pad_tx_0                   (pad_tx[0]),
        .pad_tx_1                   (pad_tx[1]),
        .pad_tx_2                   (pad_tx[2]),
        .pad_tx_3                   (pad_tx[3]),
        .pad_tx_4                   (pad_tx[4]),
        .pad_tx_5                   (pad_tx[5]),
        .pad_tx_6                   (pad_tx[6]),
        .pad_tx_7                   (pad_tx[7]),
        .pad_clk_rx                 (pad_clk_rx_buf),
        // §9 IDELAYE2: pad_rx_dly == pad_rx when USE_IDELAY=0 (bit-exact);
        // per-lane IDELAYE2-delayed when USE_IDELAY=1 (FPGA).
        .pad_rx_0                   (pad_rx_dly[0]),
        .pad_rx_1                   (pad_rx_dly[1]),
        .pad_rx_2                   (pad_rx_dly[2]),
        .pad_rx_3                   (pad_rx_dly[3]),
        .pad_rx_4                   (pad_rx_dly[4]),
        .pad_rx_5                   (pad_rx_dly[5]),
        .pad_rx_6                   (pad_rx_dly[6]),
        .pad_rx_7                   (pad_rx_dly[7]),

        // Lane-mask exposure for the autoneg mask handshake (see
        // tidelink_autoneg.sv). The local outputs are read-only mirrors of
        // the swi_*_lane_mask registers; the peer inputs are driven by the
        // autoneg FSM after a successful handshake read transaction.
        .tx_lane_mask_o             (wlink_tx_lane_mask),
        .rx_lane_mask_o             (wlink_rx_lane_mask),
        .peer_tx_lane_mask_i        (peer_tx_lane_mask_w),
        .peer_rx_lane_mask_i        (peer_rx_lane_mask_w),
        .mask_hs_result_o           (wlink_mask_hs_result),
        // SoC Labs §9: alignment-control inputs = autocal calibrator
        // OR'd with Region 8 SW-override regs (MMIO 0x4403_2104 /
        // 0x4403_2100), the autoneg I²C training FSM also driving the
        // Region 8 training_mode reg.
        .swi_bit_slip_in            (swi_bit_slip_w),
        .swi_training_mode_in       (swi_training_mode_w),
        // §9.7: per-lane phase offset = calibrator OR Region 8
        // SWI_PHASE_OFFSET (MMIO 0x4403_2118).
        .swi_phase_offset_in        (swi_phase_offset_w),
        // SoC Labs §9 auto-cal: expose internal recovered RX clock + 128-bit
        // deserialised lane data for the lane_checker + calibrator instances.
        .phy_link_rx_rx_link_data_o (phy_link_rx_rx_link_data_w),
        .phy_link_rx_rx_link_clk_o  (phy_link_rx_rx_link_clk_w),
        // SoC Labs credit-path observability bundle (RO APB exposure).
        .obs_fcsm_state_o           (obs_fcsm_state_w),
        .obs_cr_pkt_seen_rx_o       (obs_cr_pkt_seen_rx_w),
        .obs_crack_pkt_seen_rx_o    (obs_crack_pkt_seen_rx_w),
        .obs_pkt_is_cr_pkt_o        (obs_pkt_is_cr_pkt_w),
        .obs_pkt_is_crack_pkt_o     (obs_pkt_is_crack_pkt_w),
        .obs_llrx_state_o           (obs_llrx_state_w),
        .obs_is_short_pkt_o         (obs_is_short_pkt_w),
        .obs_is_long_pkt_o          (obs_is_long_pkt_w),
        .obs_llrx_valid_o           (obs_llrx_valid_w),
        .obs_ecc_corrupted_cnt_o    (obs_ecc_corrupted_cnt_w),
        .obs_ecc_corrected_cnt_o    (obs_ecc_corrected_cnt_w),
        // SoC Labs 2026-06-08: SYNC-detected saturating count (cross-lane-skew).
        .obs_sync_detected_cnt_o    (obs_sync_detected_cnt_w),
        // SoC Labs Bug-A FCSM observation 2026-06-02
        .obs_a2l_replay_link_valid_o (obs_a2l_replay_link_valid_w),
        .obs_fe_rx_credit_max_o      (obs_fe_rx_credit_max_w),
        .obs_fe_rx_is_full_o         (obs_fe_rx_is_full_w),
        // SoC Labs Bug-A FCSM observation 2026-06-03
        .obs_a2l_replay_app_valid_o  (obs_a2l_replay_app_valid_w)
    );

endmodule
