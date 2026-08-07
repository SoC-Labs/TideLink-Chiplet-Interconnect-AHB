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
    // Z2 no-data-delivery fix (2026-07-30, docs/HANDOVER_Z2_PICKUP_2026_07_30.md
    // §5): pass-through to Wlink.EPOCH_ANCHOR_EN. Default 0 = bit-exact
    // passthrough everywhere; a board-level integration overrides to 1 to swap
    // in the training-EXIT anchored deskew corrector (V2 only; inert under V1).
    parameter EPOCH_ANCHOR_EN = 1'b0,

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
    //
    // SoC Labs 2026-06-18 — REDUCED-LANE BRING-UP: default to 7'h00 (autoneg
    // OFF, SW-driven path). With autoneg ON the SLAVE die's Wlink config block
    // (incl. the lane mask) is owned by the autoneg I2C path and ignores SW
    // GP0 writes, and the mask handshake is bypassed — so the slave is stuck
    // at the default 8-lane mask 0xff while the master masks to a reduced lane
    // set, mis-framing master->slave CR. Disabling autoneg lets SW set ROLE_CFG
    // + the lane mask on BOTH dies (the master path is already SW-writable),
    // exactly like the pair_v2 sim recipe. REVISIT for production: re-enable
    // autoneg (7'h61) once the mask handshake propagates the reduced mask to
    // the slave (wire peer_rx_lane_mask_i / un-bypass mask_hs).
    parameter [6:0]  NEGO_CFG_RESET       = 7'h00,
    // Terminal role from strap, not the I2C-NACK constant. Forwarded to
    // tidelink_autoneg.ROLE_FROM_STRAP. DECISION (David, 2026-07-19): default
    // is now 1'b1 (strap honoured) so a dead I2C no longer forces both dies
    // slave. 1'b0 = legacy trap (NACK => slave, timeout => nego_fallback).
    parameter bit    ROLE_FROM_STRAP      = 1'b1,
    // Forwards to tidelink_autoneg.TRAIN_ENTRY_FALLBACK. DEFAULT OFF (shipping
    // behaviour unchanged). 1 = on a dead I2C bus, the training transaction
    // enters training from strap instead of hanging/erroring with the SYNC
    // beacon dark. The symmetric completion of DECISION #3 for training entry.
    parameter bit    TRAIN_ENTRY_FALLBACK = 1'b0,
    // I1 eth-chiplet bring-up fix (2026-07-30, docs/I1_SELFARM_FIX.md).
    // SELF-ARM ROLE-LOCK ON EXPLICIT SW INTENT. DEFAULT OFF — every existing
    // deps/Z2/onchip build is byte-behaviour-identical (constant-folds away).
    // When 1, a SW W1S of ROLE_CFG[1] latches role_lock_reg IMMEDIATELY, without
    // waiting for the peer mask-handshake gate (mask_hs_gate_open) or the
    // nego_lost_w fallback — both stay 0 on a die whose peer-I2C control plane
    // never completes (the eth-chiplet). role_locked is a MUTUAL CLOCK ENABLE
    // (wlink_por_reset = ~role_locked, below), so with it stuck 0 the forwarded
    // pad_clk_tx / calibrator are held in reset and cal_done can never assert.
    // Self-latching on the SW intent honours the design principle "role-lock must
    // NEVER wait on a protocol event" (project_role_lock_is_a_mutual_clock_enable).
    // The genuine-integrity witness mask_hs_verified_reg (the mask_hs_match-ALONE
    // latch above) is LEFT UNTOUCHED, so RETIRED-autonomy entry still fails closed
    // — a self-armed role_lock does NOT forge it. When set, this ALSO makes SW own
    // swi_training_mode_r: the autoneg's ST_TRAIN_EXIT clear is gated off (below)
    // so it cannot wipe an SW-held training out from under the cal_done poll.
    // Set 1'b1 ONLY on the eth-chiplet tidelink_top instantiation; every other
    // integration keeps the 1'b0 default.
    parameter bit    SELF_ARM_TRAIN_EN    = 1'b0,
    // AUTO_ANCHOR_EN (2026-08-04): on link-up, pulse the SYNC beacon once (gated
    // on TX-idle so it can never delete a live D2D word) to latch the deskew
    // re-anchor on the nego_en=0 / SELF_ARM eth-chiplet path — the shipping
    // SYNC-reanchor corrector otherwise never sees a beacon (reanchored=0 ->
    // data mis-frames = the R1/deskew wedge). Default-OFF constant-folds the FSM
    // + the SYNC-port ORs (bit-identical). Set 1'b1 ONLY on the eth-chiplet.
    parameter bit    AUTO_ANCHOR_EN       = 1'b0,
    // Consolidation 2026-07-15: winscan converge-lock knob, retained ONLY for
    // tidelink_top elaboration parity (tidelink_top threads it to this ACC).
    // INERT on this line: we chose phase2's asymmetric peer-serve finalize FSM,
    // not tapeout's dormant + converge-lock strategy, so the lock mechanism is
    // absent here and the param defaults OFF. The bring-up lottery is addressed
    // physically (P-B capture-clock hoist), not by this lock.
    parameter bit    WINSCAN_CONVERGE_LOCK_EN = 1'b0,
    // SoC Labs 2026-06-29 — AUTONOMOUS ON-CHIP IDELAY WINSCAN FSM enable.
    // 1 (default) = the on-chip cross-lane deskew winscan FSM is BUILT and may
    // run, but ONLY when armed via the autonomous nego path (nego_en &
    // role_locked); when nego_en=0 (the proven SW-role_lock / host-winscan
    // path) the FSM is permanently dormant and the per-lane IDELAY tap regs
    // (swi_phase_offset_r / swi_phase_lsb_r) keep their APB-written values
    // bit-identically — the host winscan() and the SW data regression are
    // UNAFFECTED. 0 = the FSM is removed entirely (the autonomous deskew layer
    // reverts to the pre-winscan behaviour, i.e. relies on the host loop only).
    // The FSM body is additionally `ifdef TIDELINK_PHY_V2 (it consumes V2-only
    // obs_sync_dist_vec / swi_phase_lsb), so in V1 it is absent regardless.
    parameter bit    WINSCAN_FSM_EN       = 1'b1,
    // EVENT-GATED AUTONOMY RETIRE enable (2026-07-15, F4 tapeout knob). 1 =
    // once the link is provably up (reanchored & bilateral FC), the die
    // autonomously retires the winscan/force-SYNC autonomy (replicating the
    // 0x210C=0 escape hatch) — THE B->A channel fix on the FPGA autonomy path.
    // Default 1 = enabled for FPGA autonomy. The ASIC integration MUST make a
    // CONSCIOUS choice here (set 0, or wire a bond strap) per the handover
    // no-silent-chip-default rule: the retire PARKS the on-chip winscan, so an
    // ASIC that wants the classic always-armed behaviour, or a strap-gated
    // retire, sets this explicitly. Gates ONLY the retire SET; with 0 the
    // autonomy_armed term is bit-identical to the pre-fix RTL.
    parameter bit    RETIRE_EN            = 1'b1,
    // Per-tap settle dwell (apb_clk cycles). The host winscan sleeps ~50 ms per
    // tap so the IDELAYE2 reload + the cross-lane SYNC re-flood settle before
    // SYNC_DIST is sampled; 50 ms @ 50 MHz apb_clk ≈ 2.5 M cycles. Generous by
    // design — this dwell is the key correctness knob (too short and a lane is
    // sampled mid-reload / before SYNC re-floods, picking a false centre). In
    // simulation the IDELAY is passthrough and SYNC floods every beat, so the
    // TB shrinks it via the `tb_winscan_dwell_short_q` hierarchical hook (same
    // pattern as the calibrator's tb_early_exit_force_q) — see the FSM block.
    parameter int    WINSCAN_DWELL        = 2_500_000
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
    // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override (2026-06-16,
    // perlane-wp): Region 10 select (main APB port). High when the access is to
    // SoC 0x4403_2144/0x4403_2148/0x4403_214C (the new sweep-oracle / per-lane
    // word-pin registers). apb_region 4'b1010 would otherwise alias Region 8 on
    // ctrl_reg_addr[4:3]==2'b10, so the select rides a dedicated flag; the slot
    // (paddr[4:2]) is on ctrl_reg_addr[2:0] (folded onto the 2'b00 bank). V1 ties
    // this 0 -> the Region-10 bank is inert (bit-identical).
    input  wire             apb_ctrl_reg_r10,
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — Region D
    // disambiguator. Region D (paddr[8:5]=4'b1101, SoC 0x4403_21A0+) folds onto
    // ctrl_reg_addr[4:3]==2'b00 (same as Region 9/10); this 1-bit flag from
    // tidelink_apb_regs.sv picks Region D, exactly mirroring apb_ctrl_reg_r10.
    input  wire             apb_ctrl_reg_rd,
    // SoC Labs AXI data-node observability 2026-07-29 (I4) — Region F
    // disambiguator. Region F (paddr[8:5]=4'b1111, SoC 0x4403_21E0+) folds onto
    // ctrl_reg_addr[4:3]==2'b00 (same as Region 9/10/D); this 1-bit flag from
    // tidelink_apb_regs.sv picks Region F, exactly mirroring apb_ctrl_reg_rd.
    // Unlike the V2-only 9/10/D banks, Region F is LIVE in both V1 and V2 (the
    // AXI data nodes exist in both), so it is never tied 0 downstream.
    input  wire             apb_ctrl_reg_rf,
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
    output wire             obs_a2l_replay_app_valid_o,
    // SoC Labs TideChart sequencing contract 2026-07-17 (G1 dual-root fix) —
    // docs/TIDECHART_G1_SEQUENCING_CONTRACT.md.
    //
    // "The Wlink link layer is in its credit/data-exchange region", i.e. the
    // link genuinely CARRIES FC/EXT words. This is a strictly LATER milestone
    // than role_locked_o (~5us later in sim): role_locked only means the roles
    // are settled and PHY training MAY start. TideChart's root election must be
    // gated on THIS, not on role_locked/link_active — gating on role_locked
    // elects before any CLAIM can cross the die boundary, so both dies
    // self-root (a silent dual-root).
    //
    // Domain: apb_clk. Source is sync_obs_fcsm_state_1, the far side of the
    // existing 2-flop apb_clk synchroniser on the Wlink FCSM state (the same
    // net already published as APB 0x2108[19:17] and already consumed by the
    // retire-autonomy logic). NOTE the decode `>= 3'd4` on a 3-bit state is
    // EXACTLY bit [2], so this is a single synchronised flop output with no
    // multi-bit decode hazard — it cannot glitch on a partial CDC update.
    // The FCSM's operational region is states 4..7 (4=data exchange,
    // 5=LINK_DATA, 6=SEND_ACK, 7=SEND_NACK); 0..3 are reset/CR/credit init.
    // That region is CLOSED — no arc returns to 0..3 short of reset — so
    // bit[2] is exactly "the LL has reached its operational region", and it is
    // monotonic by construction. Holding through 6/7 is INTENDED: SEND_ACK is
    // routine healthy traffic and SEND_NACK is a retransmission request, not a
    // link-down event. This port is NOT a link-health/liveness signal; if one
    // is ever needed it must be a separate port.
    // (Corrected 2026-07-19 after review finding F8 — the previous "states are
    // 0..5" was false; 6 and 7 exist. See the contract doc §3.1/§6.5.)
    // See docs/TIDECHART_G1_SEQUENCING_CONTRACT.md §3.1.
    output wire             data_mode_o
`ifdef TIDELINK_PHY_V2
    // SoC Labs V2 epoch-anchor engagement obs 2026-06-14 — pass-through of the
    // WlinkGPIOPHY lane-deskew anchor state up to tidelink_top's
    // tidelink_gpio_phy_apb_regs.epoch_*_i (SWI_EPOCH_STATUS @ 0x4403_2140).
    // link_rx_rx_link_clk domain; the APB slave 2-flop-syncs into apb_clk
    // itself, so NO sync here. V1 builds never see these ports.
    ,
    output wire             obs_epoch_anchored_o,
    output wire  [5:0]      obs_epoch_span_o,
    // TL-009 leak witness from tidelink_top's XHB500 ahb_sub side (Region F slot
    // 3'h6 @ 0x21F8). Unconnected in bare-link/debug tb instantiations (floats,
    // harmless — they never read 0x21F8); tidelink_top drives it on the HW build.
    input  wire  [31:0]     xhb_sub_obs_word_i
`endif
);

    // =====================================================================
    // Internal resets (Wlink uses active-high)
    // =====================================================================
    wire apb_reset     = ~hresetn;
    // SoC Labs 2026-06-21: app_clk_reset assigned below (after role_locked decl) so it
    // can mirror wlink_por_reset's ~role_locked gating. This makes the a2l replay FIFO's
    // app/write-side reset release COHERENTLY with its link/read-side reset (which is
    // already held by ~role_locked), eliminating the asymmetric reset-RELEASE skew that
    // desyncs the replay ACK-pointer synchronizer (silicon: a2l_full=1 / link_empty=1 on
    // the first AHB_TX write -> FCSM wedged state 4 -> die_b RXW=0). NOT apb_reset, which
    // must stay alive pre-role_locked so SW can drive the bring-up recipe + read OBS taps.
    wire app_clk_reset;

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
    wire [3:0]  nego_state_w;
    wire        nego_done_w, nego_error_w, nego_won_w, nego_lost_w, nego_sda_start_seen;
    wire        nego_role_w;
    wire        nego_set_role_cfg_w, nego_role_value_w, nego_set_role_lock_w;
    wire [7:0]  fsm_axil_awaddr;
                              wire [7:0]  fsm_axil_araddr;
    wire        fsm_axil_awvalid;
                              wire        fsm_axil_wvalid, fsm_axil_bready;
    wire        fsm_axil_arvalid, fsm_axil_rready;
    wire [31:0] fsm_axil_wdata;
    wire [3:0]  fsm_axil_wstrb;
    wire        nego_driving;

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
    // 2026-07-24 — apb_debug_unlock_i REMOVED from this OR (F2b). It served TWO
    // unrelated purposes and they must be independent:
    //   (1) "bypass the peer-mask gate"  — a SHAM opener, removed here;
    //   (2) "enable external-APB WRITES to Wlink on a slave die" (:3599) — a
    //       real, still-needed bring-up capability.
    // Because one strap did both, the handshake could never be honest while
    // bring-up worked. MEASURED both ways on kr260-pair-onchip: with the strap
    // welded 1 the slave showed gate_open=1 while mask_hs_match=0 (the SHAM,
    // 07-23); with it driven 0 the gate became honest but the slave's Wlink
    // config writes were silently dropped read-only, so FC never bootstrapped
    // and BOTH dies stuck at fcsm=2 (07-24). Dropping the term here decouples
    // them: debug-unlock may stay asserted for bring-up WITHOUT ever forging a
    // peer-mask match.
    // The gate now opens ONLY on a genuine match, or via the dedicated
    // mask_hs_bypass_i debug strap (xlconstant 0 in production, and the ONLY
    // remaining explicit escape — which the §5.4 autonomy proof checks).
    wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i;

    reg  nego_lock_pending_reg;
    // Sticky witness that a GENUINE peer-mask match was observed on this die
    // (never settable by mask_hs_bypass_i or the nego_lost_w free pass).
    // Gates entry to autonomous RETIRED operation; mirrored in OBS_MASK_HS[23].
    reg  mask_hs_verified_reg;
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
            mask_hs_verified_reg   <= 1'b0;
        end else begin
            // 2026-07-24 — GENUINE-HANDSHAKE WITNESS (sticky, POR-only clear).
            // Latches the first cycle this die observes a REAL peer-mask match:
            // either its own comparator verdict (master) or the winner's I2C
            // verdict byte sniffed at Wlink 0x21C (slave, see Wlink.v). It is
            // deliberately driven from mask_hs_match ALONE — never from
            // mask_hs_bypass_i and never from nego_lost_w — so no strap and no
            // "trust the winner" fallback can forge it.
            //
            // WHY THIS EXISTS: role_lock still latches on the lost path via the
            // nego_lost_w free pass (see the role_lock block below), because
            // role_locked is a MUTUAL CLOCK ENABLE — wlink_por_reset (:2832)
            // gates this die's forwarded pad_clk_tx, which IS the peer's
            // pad_clk_rx. Making role_lock itself wait for the verdict would
            // (a) collapse the ~3.1 ms bring-up stagger the CR/CRACK exchange
            // relies on, and (b) on the I2C-NACK fallback leave a die that never
            // receives a verdict permanently gating its own PHY clock — a hard,
            // bilateral, unrecoverable dead link.
            // So integrity is enforced HERE instead: this witness gates entry to
            // autonomous RETIRED operation, which fails closed in a recoverable,
            // observable way rather than by bricking the clock.
            if (mask_hs_match)
                mask_hs_verified_reg <= 1'b1;

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
            else if (nego_lock_pending_reg && (mask_hs_gate_open || nego_lost_w || SELF_ARM_TRAIN_EN))
                // Bug N9 fix: also clear pending on the lost path so the
                // (SELF_ARM_TRAIN_EN: clear pending on the self-arm path too, so
                //  the pending bit doesn't stay stuck after role_lock latches via
                //  the self-arm term below — symmetric with the lost-side clear.
                //  Default 0 ⇒ this term constant-folds away, bit-identical.)
                // pending bit doesn't stay asserted after role_lock_reg
                // has latched via the lost-side workaround below.
                // (2026-07-24: this term is paired with the lost-side lock
                // below — both were retired together as F3 and both were
                // REVERTED together after the silicon A/B showed fcsm stalling
                // at 2. Do not remove one without the other: clearing on
                // nego_lost_w while the lock requires a gate would drop the
                // intent and deadlock the slave.)
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
            //
            // 2026-07-24 (F3) — ATTEMPTED AND REVERTED, MEASURED ON SILICON.
            // With the 0x21C verdict sniffer in place (F1) the lost side CAN
            // now open its own gate, so this free pass is no longer strictly
            // necessary and tightening it looked correct. It is NOT SAFE YET:
            // removing the `nego_lost_w` term makes the slave latch role_lock
            // LATER (only once the winner's I2C verdict has arrived) instead of
            // immediately at ST_NEGO_DONE. role_locked gates the slave's Wlink
            // out of reset, so the later release misses the training window and
            // the FC state machine stalls.
            //   A/B on kr260-pair-onchip, identical flow, 2026-07-24:
            //     F1 only          -> match=1 gate=1 locked=1 fcsm=4  (healthy)
            //     F1 + this change -> match=1 gate=1 locked=1 fcsm=2  (stalled)
            // Sim did NOT catch it: the v2 pair test passes, and test_24's own
            // docstring disclaims asserting downstream training ("TRAIN_RUN /
            // TRAIN_POLL_PEER ... may still fail under straps=0, tracked
            // separately"). The integrity hole this would close is already
            // closed in practice by F1 (the slave's gate opens on a genuine
            // match), so the free pass is now redundant rather than load-bearing.
            // TO RETIRE IT PROPERLY: make the slave's Wlink-out-of-reset
            // independent of the role_lock TIMING (or hold the training window
            // open until the verdict lands), then re-run this A/B.
            if ((nego_lock_pending_reg && mask_hs_gate_open) ||
                (nego_lock_pending_reg && nego_lost_w) ||
                // I1 SELF-ARM (2026-07-30): third OR term. With the peer-I2C
                // control plane dead on the eth-chiplet, neither mask_hs_gate_open
                // nor nego_lost_w ever fires, so role_lock_reg stayed 0 and held
                // the mutual clock enable / calibrator in reset (cal_done=0,
                // fcsm=0). This latches role_lock on the SW ROLE_CFG[1] intent
                // (which set nego_lock_pending_reg above) as soon as the param is
                // enabled. mask_hs_verified_reg is NOT set here, so the honest
                // integrity witness is preserved. Default 1'b0 ⇒ constant-folds
                // away ⇒ every existing build is byte-behaviour-identical.
                (nego_lock_pending_reg && SELF_ARM_TRAIN_EN)) begin
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
    // L4 training-exit-deadlock fix (2026-07-01): "locally parked in S_HOLD"
    // from the deps calibrator (rx_link_clk domain; CDC-synced to apb_clk as
    // sync_cal_in_hold_1 before feeding the autoneg FSM). This is the
    // rendezvous the autonomous training-exit uses (both dies in S_HOLD).
    wire        cal_in_hold_w;
    // M7 (2026-06-05): calibrator auto-retry counter for silicon observability
    wire [15:0] cal_resweep_ctr_w;
    // I1 winscan obs (2026-07-30): calibrator validation-timeout give-up flag
    // (sticky in the calibrator; was left UNCONNECTED on the V2 instance). RO tap
    // for tidelink_winscan_obs -> Region F WINSCAN_STAT[5]. Zero datapath change.
    wire        cal_valto_w;
    // EYE-WIDTH VISIBILITY (2026-06-17): per-lane-selected eye-width read from
    // the deps calibrator (rx_link_clk domain; CDC-synced to apb_clk before the
    // APB read mux). best = matched-window WIDTH (taps) of the SWI_EYE_LANE_SEL
    // lane; start (slip,phase) of that run; passed = best >= LOCK_THRESH.
    wire [5:0]  cal_eye_best_w;
    wire [3:0]  cal_eye_best_phase_w;
    wire [2:0]  cal_eye_best_slip_w;
    wire        cal_eye_lane_passed_w;
    // Task 3 (2026-06-17): effective eye-width lane select. In V2 the APB-writable
    // swi_eye_lane_sel_r (Region 10 slot 5, SoC 0x2154) drives it so all 8 lanes
    // scan remotely; in V1 it falls back to the swi_eye_lane_sel_i input port
    // (driven by tidelink_eye_regs at top level — bit-identical). The wire is
    // declared here; its continuous assignment lives below the swi_eye_lane_sel_r
    // declaration (VCS forbids forward reference to a reg under
    // `default_nettype none`).
    wire [2:0]  eye_lane_sel_eff;
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
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — packed
    // sticky framer (llrx) + FCSM (tl2wl) words from the Wlink obs bundle.
    // rx-link-clk / io_rx_clk domains; 2-flop-synced to apb_clk below and read
    // at the new Region D (SoC MMIO 0x4403_21A0/0x4403_21A4/0x4403_21A8) in V2.
    wire [31:0] obs_rxcap0_w;
    wire [31:0] obs_rxcap1_w;
    wire [31:0] obs_fcsmcap_w;
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
    // SoC Labs V2 data-send observation 2026-06-21 — a2l replay buffer true
    // app_ready (app-clk domain) and link_empty (link-clk domain). Both are
    // pure read-only fan-outs of existing FCSM/replay nets, 2-flop synced to
    // apb_clk below and read at Region 10 slots 6/7 (SoC 0x4403_2158/0x215C).
    wire        obs_a2l_replay_app_ready_w;
    wire        obs_a2l_replay_link_empty_w;
    // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 — a2l replay
    // buffer raw write ptr / app-clk-synced ACK ptr / false-FULL flag / enable
    // demet term of app_ready. All app-clk domain, pure read-only fan-outs of
    // existing replay-buffer nets; 2-flop synced to apb_clk below and PACKED
    // into the spare bits of the 0x2158 A2L_REPLAY_OBS word.
    wire [4:0]  obs_a2l_wptr_w;
    wire [4:0]  obs_a2l_synced_ack_w;
    wire        obs_a2l_full_w;
    wire        obs_a2l_enable_app_demet_w;
    // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
    // — a2l replay buffer read-side reset (== fifo_io_rreset) and LINK read
    // binary pointer (== link_cur_addr). Link-clk domain, pure read-only fan-outs
    // of existing replay-buffer nets; 2-flop synced to apb_clk below and PACKED
    // into the spare bits of the 0x2158 A2L_REPLAY_OBS word (rptr [18:14],
    // rreset [19]).
    wire        obs_a2l_rreset_w;
    wire [4:0]  obs_a2l_rptr_w;
    // SoC Labs FC credit observation 2026-06-12 — far-end RX credit pointer
    // (FCSM tx-clk domain). Consumed by the OBS_FC_CREDIT Region C slot.
    wire [7:0]  obs_fe_rx_ptr_w;
`ifdef TIDELINK_PHY_V2
    // SoC Labs SYNC-insert TX observability 2026-06-15 (PART 1) — raw probe from
    // the V2 WlinkGPIOPHY fork, io_link_tx_tx_link_clk domain. 2-flop synced to
    // apb_clk below (sync_obs_tx_sync_*). Read at the new SYNC-OBS register
    // (SoC MMIO 0x4403_2120). V2-only (the V1 PHY fork has no such ports).
    wire [15:0] obs_tx_sync_ins_cnt_w;
    wire        obs_tx_link_idle_level_w;
    wire        obs_tx_training_level_w;
    // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 1) — raw probe
    // from the V2 WlinkGPIOPHY fork (post-deskew word, rx-link-clk domain).
    // 2-flop synced to apb_clk below (sync_obs_sync_seen_*). Read at the new
    // SYNC-DETECT register (SoC MMIO 0x4403_2124). V2-only.
    wire [15:0] obs_sync_seen_cnt_w;
    wire [7:0]  obs_sync_seen_lane_w;
    // SoC Labs RX RAW-WORD + PERMUTATION obs (2026-06-15, rawobs) — raw probes
    // from the V2 WlinkGPIOPHY fork (post-deskew word, rx-link-clk domain).
    // 2-flop synced to apb_clk below (dbg_obs_*). Read at Region 9 slots 3..7
    // (SoC MMIO 0x4403_212C..0x4403_213C). V2-only.
    wire [127:0] obs_dbg_raw_word_w;
    wire [7:0]   obs_dbg_lane_any_match_w;
    wire [3:0]   obs_dbg_best_popcount_w;
    wire [31:0]  obs_dbg_slice_idx_w;
    // SoC Labs PER-LANE SYNC-match LIVE oracle (2026-06-16, perlane-wp) — raw
    // rx-link-clk-domain "matched since last clear" per-lane vector from the V2
    // WlinkGPIOPHY fork. 2-flop synced to apb_clk below (sync_obs_lane_live_*).
    // Read at the new LIVE-MATCH register (SoC MMIO 0x4403_2144). V2-only.
    wire [7:0]   obs_sync_lane_live_w;
    // SoC Labs STICKY-POISON per-lane deskew sync_seen vector (2026-06-23) — raw
    // rx-link-clk-domain per-lane "SYNC re-anchor committed" vector from the V2
    // WlinkGPIOPHY fork (deskew sync_seen_vec_o). 2-flop synced to apb_clk below
    // (sync_obs_seen_vec_*). Read at the new SYNC-SEEN register (SoC MMIO
    // 0x4403_215C, Region 10 slot 7, RO). V2-only.
    wire [7:0]   obs_sync_seen_vec_w;
    // DATA-MODE per-lane SYNC HAMMING-DISTANCE OBS (2026-06-25, the winscan
    // metric) — raw rx-link-clk-domain per-lane 5-bit Hamming distance of the
    // current word to that lane's SYNC slice from the V2 WlinkGPIOPHY fork
    // (deskew sync_dist_vec_o). 2-flop synced to apb_clk below
    // (sync_obs_dist_vec_*) then lane-selected. Read at the new SYNC-DIST
    // register (SoC MMIO 0x4403_21AC, Region D slot 3, RO). V2-only.
    wire [39:0]  obs_sync_dist_vec_w;
    // R-A FINALIZE ANCHOR-VERIFY (2026-07-04) — raw rx-link-clk-domain sticky
    // from the WavD2DGpio_v2 local override: the ENGAGED deskew re-anchor has
    // delivered >=1 post-deskew word EXACTLY equal to TIDELINK_SYNC_WORD on
    // every active lane simultaneously (zero tolerance — the wrong-slot
    // mis-anchor detector: a lane whose sticky sync_idx latched one slot off
    // matches its own slice one beat AWAY from the others, so the
    // simultaneous exact match can never fire on a mis-anchored link).
    // Cleared by POR / the F3 sync_obs_clr. 2-FF synced to apb_clk below
    // (ws_verify_q) and consumed by the winscan WS_FINALIZE release gate.
    wire         obs_anchor_verified_w;
`endif

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
    // SoC Labs SYNC-insert TX obs 2026-06-15 (PART 1): the previously unused
    // region-select 2'b00 carries the new SYNC-OBS register bank (Region 9, SoC
    // MMIO 0x4403_2120-0x4403_213C). tidelink_apb_regs.sv maps apb_region
    // 4'b1001 onto ctrl_reg_addr[4:3]==2'b00. In V1 this bank is tied 0 so the
    // legacy default-0 read for that select is preserved.
    wire [31:0] region9_sync_obs_rdata;
    // SoC Labs perlane-wp (2026-06-16): Region 10 (SoC 0x2144/0x2148/0x214C)
    // shares the 2'b00 select with Region 9; apb_ctrl_reg_r10 picks Region 10.
    wire [31:0] region10_rdata;
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — Region D
    // (rxcap) read data. Folds onto the same 2'b00 controller select as Region
    // 9/10; apb_ctrl_reg_rd disambiguates (takes priority over r10/r9 because
    // tidelink_apb_regs.sv asserts at most one of {rd, r10} for a given paddr).
    wire [31:0] regionD_rxcap_rdata;
    // SoC Labs AXI data-node observability (I4, 2026-07-29). Region F
    // (0x4403_21E0+) also folds onto 2'b00; apb_ctrl_reg_rf picks it, taking
    // priority over rd/r10/r9 (tidelink_apb_regs.sv asserts at most one of
    // {rf, rd, r10} for any paddr). Live in both V1 and V2 (assigned below,
    // outside the `ifdef TIDELINK_PHY_V2` guard the other 2'b00 banks use).
    wire [31:0] regionF_axinodes_rdata;
    always_comb begin
        unique case (ctrl_reg_addr[4:3])
            2'b00:   ctrl_reg_rdata = apb_ctrl_reg_rf  ? regionF_axinodes_rdata
                                    : apb_ctrl_reg_rd  ? regionD_rxcap_rdata
                                    : apb_ctrl_reg_r10 ? region10_rdata
                                                       : region9_sync_obs_rdata;
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

    // ---------------------------------------------------------------------
    // Slot 0 bit[6] — SWI_FORCE_RECAL (P1, 2026-07-19, lane B1). WRITE-1-PULSE.
    //
    // THE DEFECT IT CLOSES: the calibrator latches `calibrated_once_q` on its
    // first S_DONE and from then on gates off BOTH re-trigger edges, so the
    // level SWI_RECAL above is a MEASURED NO-OP after first lock — there was no
    // firmware-reachable PHY retrain at all, in the FPGA image AND the ASIC
    // path (docs/LINK_RECOVERY_MECHANISM.md §4: the FSM was sampled 60x on both
    // dies and never left S_DONE; §6.1 P1 is this remedy).
    //
    // WHY A SEPARATE BIT AND NOT A WIDER SWI_RECAL: `swi_recal_r` shares the
    // calibrator's `swreset` port with the autoneg FSM's local_swreset_pulse_w.
    // calibrated_once_q exists precisely to reject that IMPLICIT pulse (Bug-A:
    // the winner's ST_TRAIN_EXIT recal re-entered training mid-FCSM-credit-init
    // and wedged the master at state 2 with zero TX credit). SWI_FORCE_RECAL is
    // driven by NOTHING but a deliberate APB write, so the calibrator can honour
    // it unconditionally without weakening that guard.
    //
    // WHY A PULSE STRETCHER: this is a W1P in the apb_clk domain (~100 MHz) but
    // the calibrator lives in rx_link_clk (~1.5-6.25 MHz on FPGA, /16 of pad
    // clk). A single apb_clk-wide pulse would be MISSED entirely by the
    // calibrator's 2-FF synchroniser — the classic slow-destination CDC trap.
    // Holding the request for FORCE_RECAL_STRETCH apb_clk cycles guarantees the
    // destination sees a stable 1 across many of its own edges (1024 apb cycles
    // ~= 15 rx_link_clk cycles at the WORST ratio of 100 MHz : 1.5 MHz). The
    // calibrator edge-detects the synced level, so a wide assertion still
    // produces exactly ONE re-arm.
    //
    // Bounded and self-clearing (no handshake, so no way to deadlock if the
    // calibrator never responds). POR-only domain, same as the two bits above.
    //
    // OPEN-LOOP, AND SAID PLAINLY: this timer has NO feedback path from the
    // calibrator. Its expiry means "the request was PRESENTED for 1024 apb_clk
    // cycles", NOT "the calibrator consumed it". The stretch is sized so that
    // presentation is sufficient at every supported clock ratio, but the only
    // authoritative evidence a retrain actually happened is the calibrator FSM
    // leaving S_DONE (Region C OBS_CAL / cal_state). This is why bit[6] is
    // write-only and reads back 0 (see the Region 8 read mux) rather than
    // exposing a "busy"/"consumed" status that could not honestly mean either.
    // ---------------------------------------------------------------------
    localparam int FORCE_RECAL_STRETCH = 1024;
    reg        swi_force_recal_r;
    reg [10:0] force_recal_ctr_r;
    // Combinational W1P write strobe. region8_write / ctrl_reg_write are module
    // -scope wires declared further down; both are `wire`, and this is a
    // continuous-assign context, so there is no `default_nettype none forward
    // -reference problem (unlike a reg read in the region8 mux above).
    wire       force_recal_w1p_w = ctrl_reg_write
                                   && (ctrl_reg_addr[4:3] == 2'b10)   // Region 8
                                   && (ctrl_reg_addr[2:0] == 3'h0)    // slot 0
                                   && ctrl_reg_wdata[6];              // SWI_FORCE_RECAL
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            swi_force_recal_r <= 1'b0;
            force_recal_ctr_r <= 11'd0;
        end else if (force_recal_w1p_w) begin
            // (Re-)arm. A write during an in-flight stretch simply reloads it.
            swi_force_recal_r <= 1'b1;
            force_recal_ctr_r <= FORCE_RECAL_STRETCH[10:0];
        end else if (force_recal_ctr_r != 11'd0) begin
            force_recal_ctr_r <= force_recal_ctr_r - 11'd1;
            if (force_recal_ctr_r == 11'd1)
                swi_force_recal_r <= 1'b0;   // deassert -> ready for the next W1P
        end
    end
`ifdef TIDELINK_PHY_V2
    // Slot 0 bit[2] — SWI_SYNC_INSERT_EN: DEFAULT-OFF enable for the V2 PHY's
    // SYNC-word re-hunt beacon (tidelink_phy_sync_insert inside WavD2DGpio).
    // Wlink RX framer is a byte-counter with no SOP; on silicon die_a can lock
    // the wrong packet byte-phase and never decode the peer CR. SYNC gives the
    // framer a periodic re-hunt beacon. SoC addr = Region 8 slot 0 = 0x44032100,
    // bit[2]. Reset 0 -> the PHY inserter is a pure passthrough so the TX
    // datapath is bit-identical to today (zero-regression default). V2-only so
    // the V1 build stays bit-identical (V1 has its own idle-gated insertion).
    reg        swi_sync_insert_en_r;
    // Slot 0 bit[3] — SWI_SYNC_FORCE_ALWAYS: DEFAULT-OFF gate-fix control for the
    // V2 PHY's SYNC beacon (PART 2, 2026-06-15). The inserter is gated by
    // io_link_tx_tx_idle, which is sparse during the FC handshake and rarely
    // coincides with the 1-in-32 inserter counter on silicon (RX SYNC-detect
    // count stays 0). With this bit set the PHY DROPS the idle term so the beacon
    // fires on enable alone (it still self-gates on ~training internally). SoC
    // addr = Region 8 slot 0 = 0x44032100, bit[3]. Reset 0 -> original idle-gated
    // production behaviour (bit-identical when SWI_SYNC_INSERT_EN is also 0).
    // V2-only so the V1 build stays bit-identical.
    reg        swi_sync_force_always_r;
    // Slot 0 bit[4] — SWI_SYNC_ROBUST_DETECT: DEFAULT-OFF selectable robust framer
    // re-hunt (PART 2, 2026-06-15). Reset 0. When 0 the framer re-hunt is the
    // legacy full-128 exact compare only (bit-identical). When 1 the PHY's
    // mask-aware per-lane SYNC detector also drives the re-hunt (the silicon fix
    // for the full-128 compare never firing). SoC addr = Region 8 slot 0 =
    // 0x44032100, bit[4]. V2-only so the V1 build stays bit-identical.
    reg        swi_sync_robust_detect_r;
    // SoC Labs RX SYNC-detect SW LANE_MASK (PART 3, 2026-06-15) — 8-bit
    // SW-writable per-lane mask feeding the PHY detector's lane_mask_i, so the
    // operator can mask marginal lanes on silicon. Reset 0xFF (all lanes in).
    // SoC addr = Region 9 slot 2 = 0x44032128. V2-only.
    reg [7:0]  swi_sync_lane_mask_r;
    // SoC Labs RX SYNC-detect Hamming TOLERANCE (2026-06-17) — 5-bit SW-writable
    // per-lane SYNC-slice Hamming budget feeding the PHY detector's sync_tol_i
    // (and the 0x2144 live-match oracle). Lets the operator sweep 0..5 on
    // marginal-eye silicon so a lane that drops 1 bit/word in its SYNC slice
    // still matches and the framer re-anchor engages. Reset 0 (EXACT match ->
    // bit-identical to all prior images). Shares the LANE_MASK register: SoC
    // addr = Region 9 slot 2 = 0x44032128 [12:8]. V2-only.
    reg [4:0]  swi_sync_tol_r;
    // SoC Labs PER-LANE SYNC-match SWEEP ORACLE + word-pin override (2026-06-16,
    // perlane-wp). All V2-only so the V1 build stays bit-identical.
    //   swi_sync_obs_clr_r        : Region 8 slot 0 bit[5] SWI_SYNC_OBS_CLR
    //                               (SoC 0x44032100[5]). W1-PULSE, self-clearing —
    //                               held high for exactly one apb_clk on a wdata
    //                               bit[5]=1 write, then auto-clears. The PHY
    //                               2-flop-syncs + edge-detects it (one clear per
    //                               write) to reset the per-lane live/sticky/raw
    //                               obs. Reset 0 (no clear) -> bit-identical.
    //   swi_word_pin_perlane_r    : 8 x 4-bit per-lane word-pin override value,
    //                               lane L at [4L+3:4L] (SoC 0x44032148 [31:0]).
    //   swi_word_pin_perlane_en_r : 8-bit per-lane override enable, lane L at
    //                               bit L (SoC 0x4403214C [7:0]). Reset all-0 so
    //                               every lane keeps its legacy auto/global pin
    //                               (bit-identical datapath).
    reg        swi_sync_obs_clr_r;
    reg [31:0] swi_word_pin_perlane_r;
    reg [7:0]  swi_word_pin_perlane_en_r;
    // EYE-WIDTH LANE SELECT (2026-06-17, Task 3). APB-writable 3-bit field that
    // picks WHICH lane's eye-width the 0x2150 EYE_WIDTH_SEL register reports, so
    // ALL 8 lanes can be scanned remotely from one register pair. Was hardwired
    // 3'h0 at tidelink_top.sv (only lane 0 readable). Region 10 slot 5
    // (SoC 0x4403_2154 [2:0]). Reset = lane 0 (bit-identical to the old tie).
    reg [2:0]  swi_eye_lane_sel_r;
    // DATA-MODE SYNC-DIST LANE SELECT (2026-06-25, the winscan metric). APB-
    // writable 3-bit field that picks WHICH lane's SYNC Hamming distance the
    // 0x4403_21AC SYNC_DIST_OBS register reports, so all 8 lanes are scanned
    // remotely from one register pair (mirrors swi_eye_lane_sel_r). Region D
    // slot 4 (SoC 0x4403_21B0 [2:0]). Reset = lane 0.
    reg [2:0]  swi_dist_lane_sel_r;
`endif
    // FULL-RANGE IDELAY TAP LSB (2026-06-25). Per-lane low bit of the 5-bit RX
    // IDELAY tap: tap[N] = {swi_phase_offset_w[4N +: 4], swi_phase_lsb_r[N]} =
    // 2*nibble + lsb. The coarse nibble (SWI_PHASE_OFFSET 0x118) supplies the
    // high 4 bits; this reg supplies bit[0], so the tap reaches the FULL 0..31
    // IDELAYE2 range (odd taps + upper half) instead of the even-only 0,2,..30.
    // Region D slot 5 (SoC 0x4403_21B4 [7:0], lane N at bit N) — write decode is
    // V2-only (Region D), but the REG is declared in BOTH builds so the always-
    // present u_idelay_rx instance can wire .lsb_i unconditionally. Reset 0 =>
    // tap stays {nibble,1'b0} = the historical even-only behaviour, BIT-IDENTICAL
    // (in V1 there is no write path, so it stays 0 forever — zero regression).
    reg [7:0]  swi_phase_lsb_r;
    // Task 3 effective-select assignment (placed after swi_eye_lane_sel_r so the
    // reg reference is BACKWARD, satisfying VCS under `default_nettype none).
`ifdef TIDELINK_PHY_V2
    assign eye_lane_sel_eff = swi_eye_lane_sel_r;
`else
    assign eye_lane_sel_eff = swi_eye_lane_sel_i;
`endif
    // Slot 1 — SWI_BIT_SLIP_LO bits[23:0] (8 × 3-bit per-lane slip)
    reg [23:0] swi_bit_slip_lo_r;
`ifdef TIDELINK_PHY_V2
    // V2 word-pin override (mirrors BIST BIT_SLIP_OVR[28:24]). V2-only so the
    // V1 build stays bit-identical. Captured from SWI_BIT_SLIP_LO writes.
    reg [3:0]  swi_word_pin_ovr_r;       // [27:24] manual global word pin
    reg        swi_word_pin_auto_dis_r;  // [28] 1 = force manual (auto off)
`endif
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
    // M11b: calibrator MIN_LOCK_DWELLS runtime override — slot 3 [23:20].
    // Separate from nego_train_cfg_r[7:4] (= autoneg train_poll_timeout).
    reg [3:0]  min_lock_dwells_r;
    reg        nego_train_retrain_pulse;  // 1-cycle pulse on W1P write

    // LOOP-9 AUTONOMY SCOPE (2026-07-03, silicon-root-caused): the single
    // qualifier for EVERY autonomous SYNC/winscan/handoff machine (the SYNC
    // config drive + F1b heal, the winscan FSM kick, the fch handoff arm).
    // nego_en & role_locked is NOT sufficient to exclude the manual recipe:
    // on silicon NEGO_CFG PORs to 0x61 (nego_en=1) and the proven manual
    // recipe never writes 0x2090 — it disarms autonomy by writing
    // NEGO_TRAIN_CFG 0x210C = 0 FIRST (td_v2_hwlib.sh rcp :91), i.e. the
    // real manual-vs-autonomous discriminator is train_auto_en (0x210C
    // bit[0], POR 1 for zero-poke). Without this term the winscan FSM kicked
    // on the MANUAL recipe's training falls (pre-existing since 8705a99,
    // previously masked because mid-scan kicks were LOST); the FIX-1
    // abort-restart let the recipe's LAST recal fall restart a ~8 s silicon
    // force-SYNC window (winscan_force_sync ORs into insert_en AND
    // force_always at the Wlink ports) that then overlapped MANUAL data
    // mode — force_always is the R4 word-deleter: die_b credit_count=4098 /
    // underrun=1, GP1 zeros, TXSYNC 0x2120=0x5c01ffff while R8 correctly
    // read 0x10 (the reg was clean; the PORT OR was not). Contract: with
    // train_auto_en=0 (or nego_en=0) every APB R8 write is AUTHORITATIVE
    // and all autonomous machines are dormant/parked — the manual path is
    // bit-identical. A mid-run disarm also PARKS an in-flight winscan (see
    // the FSM's disarm arc) so 0x210C=0 is an immediate on-silicon escape
    // hatch from a stuck force window.
    // ── EVENT-GATED AUTONOMY RETIRE (2026-07-15, silicon B->A fix) ──────────
    // autonomy_retire_q is a STICKY ONE-SHOT that autonomously replicates the
    // proven on-silicon escape hatch `0x210C=0` (clear train_auto_en). Once the
    // link is provably up (REANCHORED & bilateral FC seen, then a short dwell —
    // see the retire block below for why reanchored, NOT winscan_done, and why
    // early), it drops the effective autonomy_armed term. That fires the FSM's
    // LOOP-9 DISARM-PARK arc (:~4640),
    // which drops winscan_force_sync / ws_serve_active_r (the FORCED-SYNC chain
    // OR'd into the Wlink insert_en+force_always+robust ports) — the ACTUAL B->A
    // corruptor: on the receiver (die_a) a stuck autonomous force window keeps
    // SYNC beating over the B->A payload so its RX framer never commits. SILICON
    // PROOF (td_b2a_diag2.log): B->A recovered byte-exact the instant die_a's
    // autonomy_armed dropped (0x210C=0) — with R8 STILL 0x14 (insert_en=1) and
    // reanchored=0 — so insert_en/R8[2] is NOT the blocker; autonomy_armed is.
    // KEEPS the manual path bit-identical: retire only ever asserts on the
    // armed autonomous path (nego_en & role_locked & train_auto_en); with
    // nego_en=0 or train_auto_en=0 it can never set, so autonomy_armed is
    // unchanged. PER-EPISODE: re-armed (cleared) on swi_training_mode_rise so a
    // retrain/re-scan restores the forced-SYNC chain the peer needs and avoids
    // the ws_kicked_q re-scan trap — see the retire block below.
    reg  autonomy_retire_q;
    wire autonomy_armed = nego_en & role_locked & nego_train_cfg_r[0]
                        & ~autonomy_retire_q;

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
    // R-B (2026-07-04): the autoneg is in ST_FIN_RDV/ST_FIN_GO and owns the
    // I2C-master AXIL bus (nego_state_w's 4-bit truncation aliases 18/19 to
    // WAIT/CLAIM, so nego_driving needs this dedicated level).
    wire       fin_rdv_in_progress_w;
    wire [7:0] train_peer_lane_locked_w, train_peer_lane_fault_w;
    wire [7:0] train_local_lane_fault_w;
    wire       train_fail_irq_w;
    wire       local_training_mode_set_w, local_training_mode_clr_w;
    wire       local_swreset_pulse_w;

    // Forward decl (R4b 2026-07-02; the D2 fix removed the upstream SYNC-OFF
    // consumer, but the WINSCAN_OBS readback + anchored-late obs still read it
    // ahead of the driver) — DRIVEN by the FC data-mode handoff sequencer
    // (block after the autoneg instance). `default_nettype none` forbids a
    // forward reference, so the declaration is hoisted here; the driver keeps
    // its documented position in the fch block below.
    reg        fch_done_r;      // sticky: this fch episode's burst completed
    // Q1 QUIESCE-BEFORE-FINALIZE (2026-07-04) forward decls — same hoist
    // rationale (the WINSCAN_OBS readback reads fch_quiesced_r upstream of the
    // fch block that drives it; the fch block reads fch_quiesce_req upstream
    // of the V2 winscan section that assigns it).
    //   fch_quiesced_r  : sticky — the LL swi_swreset (FCCTRL 0x208 bit[3]) is
    //                     currently held ON by the quiesce path (the early
    //                     FCH_LL_SWRESET_ON write issued at WS_FINALIZE entry).
    //                     Cleared when the bootstrap walk deasserts it, or by
    //                     the disarm-release write. WINSCAN_OBS 0x21B8[8].
    //   fch_quiesce_req : level request from the winscan FSM — asserted while
    //                     the FSM sits in WS_FINALIZE / WS_FIN_CLRLOW on the
    //                     ARMED autonomous path (V2 winscan section assigns
    //                     it; the V1 arm ties it 0 so the fch sequencer is
    //                     bit-identical on V1).
    reg        fch_quiesced_r;
    wire       fch_quiesce_req;
    // -------------------------------------------------------------------------
    // SoC Labs FCH APB WATCHDOG (2026-07-09, ported from f1b3aac) — silicon-observed.
    //
    // The fch sequencer takes ownership of the Wlink APB bus (fch_active_r, see
    // the wl_apb_* mux) and, in FCH_ACCESS, waits on wl_apb_pready with NO
    // TIMEOUT. The external (PS) APB takes its pready from that SAME bus
    // (`assign apb_pready = ... : wl_apb_pready`) with no arbitration term, and
    // tidelink_top routes every 0x2xxx access to it (tidelink_top.sv:711).
    //
    // Consequence, measured on silicon 2026-07-09 (die_a, master, autonomous
    // bring-up): the FCH burst's first write is FCH_LL_SWRESET_ON (0x27f09),
    // which puts the Wlink LL into swi_swreset. If wl_apb_pready then never
    // returns, the FSM sits in FCH_ACCESS forever with fch_active_r=1, so
    // apb_pready is pinned low and EVERY PS access to the 0x2xxx region never
    // completes. Zynq-7000 M_AXI_GP has no transaction timeout -> the CPU takes
    // a Bus error / hangs in kernel space while Linux stays alive. The link
    // itself trains fine (the peer reaches fcsm=4 cal=1) -- what dies is the
    // processor's view of the PL. That is why "autonomous data = 0/28": you
    // cannot drive data from die_a's PS at all. It was never the FC path.
    //
    // Fix, in two parts:
    //   1. This watchdog. If FCH_ACCESS does not see wl_apb_pready within
    //      FCH_WDOG_LIMIT cycles, abort the burst, RELEASE the bus
    //      (fch_active_r=0) and latch a sticky error + the failing write index.
    //      The bootstrap then fails VISIBLY and RECOVERABLY instead of taking
    //      the processor's bus down with it.
    //   2. Mask apb_pready while fch_active_r (see the assign near the bottom),
    //      so a concurrent PS access is STALLED rather than completing against
    //      the sequencer's transaction (an APB protocol violation today).
    //
    // Software: WINSCAN_OBS 0x21B8 is FULL on this branch ([23:0] all packed —
    // FIX-D ws_verify_stuck at [14], ws_waitpeer at [15], etc.), so unlike the
    // upstream f1b3aac (which used 0x21B8[14]/[16:15]) this port exposes the
    // status in the previously-RESERVED regionD slot 7:
    //   FCH_OBS 0x4403_21BC (RO):
    //     [ 0]    fch_stall_err  (sticky) — the LL never acked the fch APB write
    //     [ 2:1]  fch_stall_widx          — 0=SWRESET_ON,1=SWRESET_OFF,2=ENABLE
    //     [ 3]    fch_active_r   (live)   — sequencer currently owns the wl_apb bus
    //     [31:24] 0xFC presence marker (old images read 0 here = STALE package_ip)
    //   Non-zero [0] means the LL never acked the APB write; [2:1] says which.
    // -------------------------------------------------------------------------
    reg        fch_stall_err_q;    // sticky: an FCH APB access timed out
    reg [1:0]  fch_stall_widx_q;   // which write was in flight when it timed out
    localparam [19:0] FCH_WDOG_LIMIT = 20'd500_000; // ~10 ms @ 50 MHz: >> any legal APB ack
    // R-B ASYMMETRIC PEER-SERVE rendezvous plumbing — RE-ARMED (2026-07-07).
    // History: the Loop-12 SYMMETRIC rendezvous (BOTH dies park in
    // WS_FIN_WAITPEER and BOTH re-confirm over each other's constant idle)
    // regressed b-first on silicon (mutual anchor starvation, 0x21B8=0x57000005
    // both) and was reverted dormant (Loop-13). This is the ASYMMETRIC rework:
    // only die_a (MASTER) parks in WS_FIN_WAITPEER, runs the rendezvous and
    // re-confirms; die_b (SLAVE) HOLDS its already-good anchor and merely SERVES
    // idle beacons (ws_serve_active_r) so it never re-confirms over constant
    // idle — the mutual-starvation mechanism is gone by construction.
    //   ws_fin_wait_lvl : LEVEL — the MASTER is parked quiesced in
    //                     WS_FIN_WAITPEER (role_is_master-gated). Fed to
    //                     u_autoneg.local_fin_wait_i (master ST_FIN_RDV/GO entry
    //                     arc). The SLAVE's peer-visible SWI_LANE_STATUS[27] is
    //                     ready-to-serve instead (see the [27] mux). Tied 0 on
    //                     V1 (arm below).
    //   nego_fin_go_w   : u_autoneg.fin_go_o — the master's local finalize
    //                     release (the slave's FINALIZE_GO write completed).
    //                     Consumed by the WS_FIN_WAITPEER Phase-1 release.
    wire       ws_fin_wait_lvl;
    wire       nego_fin_go_w;
    // FIX-B (2026-07-07 PEER-READY ENTRY GATE) — the broadened "MASTER is in ANY
    // finalize state" level (WS_FINALIZE | WS_FIN_CLRLOW | WS_FIN_WAITPEER),
    // role_is_master-gated. Fed to u_autoneg.local_finalizing_i so the autoneg
    // enters the SIDE-EFFECT-FREE ST_FIN_RDV POLL as soon as the master starts
    // finalizing (not only once parked in WS_FIN_WAITPEER) — it reads the peer's
    // ready-to-serve bit (SWI_LANE_STATUS[27]) WITHOUT writing a GO (the GO write
    // stays gated on the NARROW ws_fin_wait_lvl / local_fin_wait_i). The captured
    // peer bit comes back as peer_ready_to_serve_w below.
    wire       ws_finalizing_lvl;
    // FIX-B: u_autoneg.peer_ready_to_serve_o — the peer's SWI_LANE_STATUS[27]
    // (ready-to-serve) as captured by the master's ST_FIN_RDV poll. Gates the
    // WS_FINALIZE fallback entry into WS_FIN_WAITPEER (~4619): a FIRST-armed die
    // whose peer is still arming (peer[27]=0) must NOT fall into the serve
    // rendezvous — it takes the base fail-open (Loop-14 83% path, sticky anchor
    // preserved). Only the 2nd-armed die (peer in data mode, [27]=1) rendezvouses.
    wire       peer_ready_to_serve_w;

`ifdef TIDELINK_PHY_V2
    // ── Autonomous on-chip IDELAY WINSCAN FSM forward decls (2026-06-29) ──────
    // Driven by the winscan FSM block (placed after the FC handoff sequencer,
    // where all its inputs are in scope). Declared here so the PHY-consumption
    // mux (swi_phase_offset_in / .lsb_i / .swi_sync_force_always_in) and the FC
    // handoff arm-gate, both upstream of the FSM block, can reference them.
    //   ws_phase_offset_r : per-lane coarse nibble the FSM drives while it owns
    //                       the taps (lane L nibble at [4L+:4]); = swi_phase_
    //                       offset_r layout. OR-merged with cal_phase_offset_w
    //                       exactly as the host-written reg is.
    //   ws_phase_lsb_r    : per-lane tap LSB the FSM drives (lane L at bit L).
    //   winscan_owns_taps : 1 while the FSM is actively sweeping/holding taps —
    //                       mux selects the FSM values over the APB regs. 0 when
    //                       dormant => APB/host regs pass through bit-identically.
    //   winscan_force_sync: 1 across the scan — OR'd into the PHY SYNC controls
    //                       (force_always + insert_en + robust_detect), the on-
    //                       chip equivalent of the host's R8=0x1C; dropped at
    //                       the FINALIZE EXIT (F3/F4 2026-07-02: held through
    //                       FINALIZE so the post-clear re-confirm sees on-grid
    //                       beacons; = the host's R8=0x14 once anchored).
    //   winscan_done      : 1 once the scan + finalize completed for this nego
    //                       episode — gates the FC data-mode handoff.
    //   ws_degenerate_q   : R2c (2026-07-02) sticky DEGENERATE-SCAN flag: the
    //                       full sweep saw NO metric variation on any scanned
    //                       lane (flat distance ⇒ nothing was actually
    //                       measured — the silicon taps-(0,0,0,0) signature).
    //                       The FSM then RESTORES THE SEEDED (host/APB) taps
    //                       instead of shipping the arbitrary argmin tap 0
    //                       (see the WS_NEXT_LANE_ENTER guard for why the
    //                       seed, not a "middle" tap: the nibble is OR-merged
    //                       into the deserialiser phase) and still raises
    //                       winscan_done (never-done would DEADLOCK the
    //                       fch_pending_r handoff gate with no retry path);
    //                       this flag makes the condition loud via the Region-D
    //                       WINSCAN_OBS slot (0x21B8).
    //   ws_anchor_timeout_q : F4 (2026-07-02) sticky FAIL-LOUD flag: the
    //                       WS_FINALIZE anchor gate (winscan_done held until
    //                       the CDC'd deskew `reanchored` status is 1 — the
    //                       on-chip equivalent of the manual host's 0x2140
    //                       reanchored poll) TIMED OUT and released anyway.
    //                       Surfaced at WINSCAN_OBS 0x21B8 bit[2]. Cleared on
    //                       a fresh scan episode (WS_ARM), like ws_degenerate_q.
    //   ws_anchor_late_q  : FIX-3 obs (2026-07-03) sticky "anchored-late":
    //                       the CDC'd deskew `reanchored` (ws_anchor_q) ROSE
    //                       while fch_done_r was already set — the anchor
    //                       arrived AFTER the handoff had bootstrapped
    //                       (i.e. the episode released on timeout/fail-open
    //                       and the link healed late). WINSCAN_OBS 0x21B8[3].
    //                       Cleared on a fresh scan episode (WS_ARM).
    //   ws_abort_cnt_q    : FIX-1 obs (2026-07-03) saturating count of
    //                       episode-binding ABORT-RESTARTS (a gated training
    //                       fall consumed MID-SCAN — the pre-fix silently-lost
    //                       kick). WINSCAN_OBS 0x21B8[7:4]. POR-cleared only.
    //   ws_vfy_retry_q    : R-A (2026-07-04) sticky "ANCHOR-VERIFY RETRY
    //                       happened": a FIX-3 clear-retry fired while the
    //                       CDC'd `reanchored` was ALREADY 1 — i.e. the
    //                       anchor latched but the zero-tolerance
    //                       anchor-verify (ws_verify_q — all active lanes
    //                       EXACT on one post-deskew beat) did NOT, the
    //                       wrong-slot mis-anchor signature (die_b byte-lane
    //                       [23:16] 0x24->0x5c). WINSCAN_OBS 0x21B8[9].
    //                       Cleared on a fresh scan episode (WS_ARM).
    //   ws_retry_cnt_q    : FIX-4 obs (2026-07-04) per-episode ANCHOR-RETRY
    //                       ATTEMPT COUNTER: increments (saturating at 7) on
    //                       every FIX-3 clear-retry arc (WS_FINALIZE ->
    //                       WS_FIN_CLRLOW). 0 = anchored+verified in the
    //                       FIRST window; N = N retries fired (N+1 windows);
    //                       5 with 0x21B8[2]=1 = budget exhausted, failed
    //                       open. WINSCAN_OBS 0x21B8[13:11]. Cleared on a
    //                       fresh scan episode (WS_ARM). THE key statistic
    //                       for the retry-compounding model: the 8-roll
    //                       silicon lottery could not distinguish "5 retries
    //                       ran, all failed" from "no retry ran" — this can.
    //   ws_rdv_timeout_q  : R-B rendezvous-timeout sticky — DORMANT since
    //                       Loop-13 (2026-07-04): the winscan no longer
    //                       parks in WS_FIN_WAITPEER (the Loop-12 aligned
    //                       rendezvous regressed b-first on silicon), so
    //                       this bit can never set — it always reads 0. The
    //                       WINSCAN_OBS 0x21B8[10] slot and the WS_ARM
    //                       clear are KEPT so the obs map is stable for the
    //                       future R-B rework.
    //   ws_fin_go_reg_q   : R-B sticky FINALIZE_GO capture — the peer
    //                       master's I2C write of Region 8 slot 7 (0x211C
    //                       bit[0], W1P) landed. Cleared on a training rise.
    //                       DORMANT since Loop-13: nothing consumes it (the
    //                       winscan no longer waits on a GO); the 0x211C
    //                       W1P plumbing is kept for the R-B rework.
    reg [31:0] ws_phase_offset_r;
    reg [7:0]  ws_phase_lsb_r;
    reg        winscan_owns_taps;
    reg        winscan_force_sync;
    reg        winscan_done;
    reg        ws_degenerate_q;
    reg        ws_anchor_timeout_q;
    reg        ws_anchor_late_q;
    reg [3:0]  ws_abort_cnt_q;
    reg        ws_vfy_retry_q;
    reg [2:0]  ws_retry_cnt_q;
    reg        ws_rdv_timeout_q;
    // FIX-D (2026-07-07 AUGMENTED OBSERVABILITY) — packed into the FREE
    // 0x21B8[23:14] field (no register-map change). Silicon decode:
    //   [23:20] ws_state_r            — live winscan FSM state
    //   [19:18] ws_waitpeer_reentry_cnt — 2-bit sat: WS_FINALIZE→WS_FIN_WAITPEER
    //                                     entries this episode (the NODONE /
    //                                     livelock detector — >1 = ping-pong)
    //   [17:16] ws_serve_cnt_q        — 2-bit sat (SLAVE): ws_serve_active_r
    //                                     rising edges this episode (the die_b
    //                                     re-serve-thrash driver)
    //   [15]    ws_waitpeer_entered_q — sticky: the master parked in WS_FIN_WAITPEER
    //   [14]    ws_verify_stuck_q     — sticky: anchor latched (ws_anchor_q=1)
    //                                     while verify stayed low (ws_verify_q=0)
    //                                     for >WS_VFY_STUCK_N cycles = the
    //                                     wrong-slot / verify-never-passes signature
    //                                     (the Lever-1-premise signal)
    reg        ws_waitpeer_entered_q;
    reg [1:0]  ws_waitpeer_reentry_cnt;
    reg [1:0]  ws_serve_cnt_q;
    reg        ws_verify_stuck_q;
    // Declared EARLY (moved from the winscan FSM reg block) so the Region-D obs
    // read mux at 0x21B8 (which is above the FSM in the file) can pack
    // ws_state_r into [23:20] — VCS enforces declaration-before-use.
    reg [3:0]  ws_state_r;
    reg        ws_fin_go_reg_q;
    // R-B ASYMMETRIC PEER-SERVE (2026-07-07) — die_b (SLAVE) serve state.
    //   ws_serve_active_r : the SLAVE is actively SERVING forced SYNC beacons
    //                       for the peer master's WS_FIN_WAITPEER re-confirm.
    //                       Set when this die is the slave, has finished its own
    //                       winscan (winscan_done — its anchor is already good
    //                       and HELD) AND the master's FINALIZE_GO landed
    //                       (ws_fin_go_reg_q). Q'd into the PHY SYNC-insert
    //                       force ports (insert_en+force_always+robust) so SYNC
    //                       fires EVERY grid slot toward the master regardless
    //                       of its keepalive/idle — WITHOUT quiescing its FC
    //                       (its RX stays live to receive the master's credit).
    //                       Time-bounded by ws_serve_to_r (the master re-anchors
    //                       well within it); on expiry the force drops and its
    //                       FC TX resumes. NO swreset, NO re-bootstrap.
    reg        ws_serve_active_r;
    reg        ws_serve_active_d;   // 1-cycle delay for the serve falling edge
    reg [28:0] ws_serve_to_r;       // serve-window timeout countdown

    // ── Autonomous SYNC-detect config drive shadows (2026-06-30) ──────────────
    // The LAST autonomy layer: on the autonomous (nego_en) path the host's rcp
    // SYNC-detect config (LANEMASK 0xe4, SYNCTOL tol=5, R8 SYNC_EN=0x1D) is never
    // applied, so the on-chip winscan's SYNC-detect runs against the POR defaults
    // (swi_sync_lane_mask_r=0xFF, swi_sync_tol_r=0, all SYNC bits 0). With
    // lane_mask=0xFF the deskew `all_sync_seen = &(sync_seen_vec | ~lane_mask)`
    // waits for ALL 8 lanes when only the 0xe4 set is active → reanchored never
    // latches → FCSM wedges at 1. The drive below (in the Region-8/9 reg-write
    // always_ff) replicates rcp's SYNC-detect config autonomously at training-RUN,
    // then strips the SYNC-insert bits once the winscan/reanchor completes
    // (mirroring the host's enter_data_mode R8=0x10 SYNC-off AFTER reanchor).
    // Self-contained 1-cycle edge shadows so the drive needs no forward reference
    // to swi_training_mode_rise / winscan_done's own edge (declared further down).
    //
    // R3 arm-order race fix (2026-07-02): SYNC-ON is a ONE-SHOT on the full
    // conjunction (nego_en & role_locked & swi_training_mode_r) becoming true,
    // NOT an edge detect on swi_training_mode_r alone. On silicon, when the
    // MASTER arms first its autoneg I2C-writes the slave's SWI_TRAINING_MODE=1
    // BEFORE the slave's nego_en/role_locked have latched — the old edge
    // detector consumed the training rise while the gate was false, so the
    // slave never got SYNC_EN (R8=0x00, tol=0) and both calibrators parked at
    // cstate=6 forever. sync_cfg_on_fired_q clears on the training FALL so a
    // re-training episode re-fires the drive.
    reg        sync_cfg_on_fired_q; // one-shot: SYNC-ON fired this training episode
    // D2 "NEVER BLIND-OFF" (2026-07-03, silicon-root-caused, supersedes the
    // R4b/F2 timed SYNC-OFF): the autonomous SYNC-OFF timer is DELETED. Each
    // die used to kill its beacons on a LOCAL timer (fch_done_r +
    // SYNC_OFF_SETTLE) while the PEER's WS_FINALIZE re-anchor could still be
    // refilling — the refill needs PEER beacons, and one missed SYNC_PERIOD
    // grid slot resets the deskew's confirm run (tidelink_lane_deskew_v2
    // gap_ceil → sync_conf<=0). The starved die ended partial sync_seen,
    // rea=0, 0x21B8[2] sticky, an unanchored fch bootstrap, credit_max=0 and
    // dead data. NO timer can bound that skew: the arm-stagger (episode
    // binding, FIX-1) plus scan variance is unbounded. New PERMANENT
    // autonomous data-mode state:
    //   swi_sync_insert_en_r = 1 (idle-gated beacon), robust_detect = 1,
    //   sync_cfg_hold_q = 1 (the F1b every-cycle heal — now REQUIRED
    //   permanently: it is what makes the state permanent against I2C
    //   full-word R8 slot-0 clobbers).
    // Only force-SYNC ever drops (winscan_force_sync at the WS_FINALIZE exit
    // arms; swi_sync_force_always_r is never set autonomously — R4a).
    // DATA-SAFETY (why beacons-on is the correct permanent state): idle-gated
    // insertion is data-safe by this design's own history — the fch bootstrap
    // + ≈0.5 s of data mode already ran under idle-gated beacons on
    // eye-intact silicon (the F2 settle window); the R4 word-deleter was
    // FORCE-always, not idle-gated insert; steady-state cost ≈ one idle slot
    // per 32 words. Persistent beacons + robust detect additionally give
    // drift self-healing (the deskew can re-confirm at any time), and FIX-3's
    // anchor clear-retries are only meaningful because the peer is never
    // dark. (sync_cfg_wsdone_q / sync_off_settle_r / SYNC_OFF_SETTLE /
    // tb_syncoff_settle_short_q retired with the timer.)
    //
    // F1b (2026-07-02): SYNC-config HOLD phase — 1 from the autonomous
    // SYNC-ON, now PERMANENT (D2). While set, the drive RE-ASSERTS
    // insert_en/robust every cycle so a master-side I2C full-word R8 slot-0
    // write (the autoneg's SWI_TRAINING_MODE writes land as whole-register
    // writes on the slave via the AXIL->APB bridge) cannot strip the SYNC
    // config. See the F1b comment at the drive.
    reg        sync_cfg_hold_q;
`endif

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
    // L4 training-exit-deadlock fix (2026-07-01): 2-flop apb_clk sync of the
    // calibrator's cal_in_hold_o (locally parked in S_HOLD). Fed to the
    // autoneg FSM (local_cal_in_hold_i) and packed into SWI_LANE_STATUS so
    // the PEER can read it over I2C.
    reg       sync_cal_in_hold_0, sync_cal_in_hold_1;

    // Local Wlink lane-mask mirrors (read-only outputs of the Wlink swi_*_
    // lane_mask registers; POR default 0xFF, 0xE4 under TD_AUTO_LANE_MASK_E4).
    // Declared here (before first use) — the M2 autonomous SYNC-mask drive in
    // the Region-8/9 write block consumes wlink_rx_lane_mask; also feeds the
    // autoneg mask handshake and the calibrator lane_mask (below).
    wire [7:0] wlink_tx_lane_mask;
    wire [7:0] wlink_rx_lane_mask;

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
    // SoC Labs V2 data-send observation 2026-06-21 — 2-flop apb_clk sync of the
    // a2l replay app_ready (app-clk) and link_empty (link-clk) taps. Same
    // quasi-static-snapshot treatment as the other obs bits.
    reg                                                                sync_obs_a2l_app_rdy_0;
    reg                 sync_obs_a2l_app_rdy_1;
    reg                                                                sync_obs_a2l_lnk_empty_0;
    reg                 sync_obs_a2l_lnk_empty_1;
    // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 — 2-flop apb_clk
    // sync of the a2l replay raw write ptr / synced ACK ptr / full / enable
    // demet taps. Same quasi-static-snapshot treatment as the other obs bits.
    reg [4:0]           sync_obs_a2l_wptr_0;
    reg [4:0]           sync_obs_a2l_wptr_1;
    reg [4:0]           sync_obs_a2l_sack_0;
    reg [4:0]           sync_obs_a2l_sack_1;
    reg                 sync_obs_a2l_full_0;
    reg                 sync_obs_a2l_full_1;
    reg                 sync_obs_a2l_endem_0;
    reg                 sync_obs_a2l_endem_1;
    // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
    // — 2-flop apb_clk sync of the a2l replay read-side reset (link-clk) and the
    // LINK read binary pointer (link-clk). Same quasi-static-snapshot treatment.
    reg                 sync_obs_a2l_rreset_0;
    reg                 sync_obs_a2l_rreset_1;
    reg [4:0]           sync_obs_a2l_rptr_0;
    reg [4:0]           sync_obs_a2l_rptr_1;
    // SoC Labs FC credit observation 2026-06-12 — same 2-flop apb_clk
    // treatment as sync_obs_fe_rx_cred (quasi-static obs snapshot; per-bit
    // coherence not guaranteed mid-update, fine for poll-rate debug reads).
    reg [7:0]                                                          sync_obs_fe_rx_ptr_0;
    reg [7:0]           sync_obs_fe_rx_ptr_1;
`ifdef TIDELINK_PHY_V2
    // SoC Labs SYNC-insert TX observability 2026-06-15 (PART 1) — same 2-flop
    // apb_clk treatment as sync_obs_sync_det. The 16-bit count is a quasi-static
    // snapshot (saturating, monotonic at poll rate); the two level bits are
    // slow-moving status. Read at the SYNC-OBS register (SoC MMIO 0x4403_2120).
    reg [15:0]          sync_obs_tx_sync_ins_0,   sync_obs_tx_sync_ins_1;
    reg                 sync_obs_tx_idle_0,       sync_obs_tx_idle_1;
    reg                 sync_obs_tx_train_0,      sync_obs_tx_train_1;
    // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 1) — same
    // 2-flop apb_clk treatment. The 16-bit count is a quasi-static saturating
    // snapshot; the 8-bit lane vector is a sticky "ever-matched" set. Read at the
    // SYNC-DETECT register (SoC MMIO 0x4403_2124).
    reg [15:0]          sync_obs_sync_seen_cnt_0, sync_obs_sync_seen_cnt_1;
    reg [7:0]           sync_obs_sync_seen_lane_0, sync_obs_sync_seen_lane_1;
    // SoC Labs RX RAW-WORD + PERMUTATION obs (2026-06-15, rawobs) — same 2-flop
    // apb_clk treatment. These are STICKY snapshots in the rx-link-clk domain
    // (the raw word + slice map only re-latch on a new fixed-position best-match,
    // i.e. essentially quasi-static at the APB poll rate; the match vector +
    // popcount move with them). Read at Region 9 slots 3..7 (SoC MMIO
    // 0x4403_212C..0x4403_213C). Pure observability — never fed back.
    reg [127:0]         dbg_obs_raw_word_0,   dbg_obs_raw_word_1;
    reg [7:0]           dbg_obs_lane_match_0, dbg_obs_lane_match_1;
    reg [3:0]           dbg_obs_popcount_0,   dbg_obs_popcount_1;
    reg [31:0]          dbg_obs_slice_idx_0,  dbg_obs_slice_idx_1;
    // SoC Labs PER-LANE SYNC-match LIVE oracle (2026-06-16, perlane-wp) — same
    // 2-flop apb_clk treatment as the sticky lane vector. Read at the LIVE-MATCH
    // register (SoC MMIO 0x4403_2144).
    reg [7:0]           sync_obs_lane_live_0, sync_obs_lane_live_1;
    // SoC Labs STICKY-POISON per-lane deskew sync_seen vector (2026-06-23) — same
    // 2-flop apb_clk treatment. Per-lane "SYNC re-anchor committed a periodic-
    // confirmed index". Read at the SYNC-SEEN register (SoC MMIO 0x4403_215C).
    reg [7:0]           sync_obs_seen_vec_0, sync_obs_seen_vec_1;
    // DATA-MODE per-lane SYNC HAMMING-DISTANCE OBS (2026-06-25, the winscan
    // metric) — same 2-flop apb_clk treatment as the 128-bit raw-word snapshot.
    // Per-lane 5-bit live distance to the SYNC slice, packed 8x5=40 bits. A
    // winscan reads it quasi-statically (SYNC floods in data mode), so the multi-
    // bit 2-flop is the same accepted treatment as the raw-word/eye-width
    // snapshots. Lane-selected at read time by swi_dist_lane_sel_r (SoC
    // 0x4403_21B0). Read at SoC 0x4403_21AC (Region D slot 3, RO).
    reg [39:0]          sync_obs_dist_vec_0, sync_obs_dist_vec_1;
    // EYE-WIDTH VISIBILITY (2026-06-17) — 2-flop apb_clk sync of the selected
    // lane's eye-width fields, packed 14-bit {passed, slip[2:0], phase[3:0],
    // best[5:0]} from the rx_link_clk-domain calibrator. Same treatment as the
    // live SYNC vector above. Read at 0x4403_2150.
    reg [13:0]          sync_eye_width_0, sync_eye_width_1;
    // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) — 2-flop
    // apb_clk sync of the three packed sticky words from the Wlink obs bundle
    // (rx-link-clk / io_rx_clk domain). Each word is a sticky / capture-once /
    // saturating snapshot, so the per-word multi-bit 2-flop is the same accepted
    // quasi-static treatment as the raw-word/eye-width snapshots above. Read at
    // Region D (SoC 0x4403_21A0/0x4403_21A4/0x4403_21A8).
    reg [31:0]          sync_obs_rxcap0_0, sync_obs_rxcap0_1;
    reg [31:0]          sync_obs_rxcap1_0, sync_obs_rxcap1_1;
    reg [31:0]          sync_obs_fcsmcap_0, sync_obs_fcsmcap_1;
`endif

    always_ff @(posedge apb_clk or negedge hresetn) begin
        if (!hresetn) begin
            sync_lane_locked_0 <= 8'h00;
            sync_lane_locked_1 <= 8'h00;
            sync_lane_fault_0  <= 8'h00;
            sync_lane_fault_1  <= 8'h00;
            sync_cal_done_0    <= 1'b0;
            sync_cal_done_1    <= 1'b0;
            sync_cal_in_hold_0 <= 1'b0;
            sync_cal_in_hold_1 <= 1'b0;
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
            // SoC Labs V2 data-send observation 2026-06-21
            sync_obs_a2l_app_rdy_0  <= 1'b0;  sync_obs_a2l_app_rdy_1  <= 1'b0;
            sync_obs_a2l_lnk_empty_0 <= 1'b0; sync_obs_a2l_lnk_empty_1 <= 1'b0;
            // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21
            sync_obs_a2l_wptr_0     <= 5'h0;  sync_obs_a2l_wptr_1     <= 5'h0;
            sync_obs_a2l_sack_0     <= 5'h0;  sync_obs_a2l_sack_1     <= 5'h0;
            sync_obs_a2l_full_0     <= 1'b0;  sync_obs_a2l_full_1     <= 1'b0;
            sync_obs_a2l_endem_0    <= 1'b0;  sync_obs_a2l_endem_1    <= 1'b0;
            // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
            sync_obs_a2l_rreset_0   <= 1'b0;  sync_obs_a2l_rreset_1   <= 1'b0;
            sync_obs_a2l_rptr_0     <= 5'h0;  sync_obs_a2l_rptr_1     <= 5'h0;
            // SoC Labs FC credit observation 2026-06-12
            sync_obs_fe_rx_ptr_0    <= 8'h0;  sync_obs_fe_rx_ptr_1    <= 8'h0;
`ifdef TIDELINK_PHY_V2
            // SoC Labs SYNC-insert TX observability 2026-06-15 (PART 1)
            sync_obs_tx_sync_ins_0  <= 16'h0; sync_obs_tx_sync_ins_1  <= 16'h0;
            sync_obs_tx_idle_0      <= 1'b0;  sync_obs_tx_idle_1      <= 1'b0;
            sync_obs_tx_train_0     <= 1'b0;  sync_obs_tx_train_1     <= 1'b0;
            // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 1)
            sync_obs_sync_seen_cnt_0  <= 16'h0; sync_obs_sync_seen_cnt_1  <= 16'h0;
            sync_obs_sync_seen_lane_0 <= 8'h0;  sync_obs_sync_seen_lane_1 <= 8'h0;
            // SoC Labs RX RAW-WORD + PERMUTATION obs (2026-06-15, rawobs)
            dbg_obs_raw_word_0   <= 128'h0;        dbg_obs_raw_word_1   <= 128'h0;
            dbg_obs_lane_match_0 <= 8'h0;          dbg_obs_lane_match_1 <= 8'h0;
            dbg_obs_popcount_0   <= 4'h0;          dbg_obs_popcount_1   <= 4'h0;
            dbg_obs_slice_idx_0  <= 32'hFFFF_FFFF; dbg_obs_slice_idx_1  <= 32'hFFFF_FFFF;
            // SoC Labs PER-LANE SYNC-match LIVE oracle (2026-06-16, perlane-wp)
            sync_obs_lane_live_0 <= 8'h0;          sync_obs_lane_live_1 <= 8'h0;
            // SoC Labs STICKY-POISON per-lane deskew sync_seen vector (2026-06-23)
            sync_obs_seen_vec_0  <= 8'h0;          sync_obs_seen_vec_1  <= 8'h0;
            // DATA-MODE per-lane SYNC Hamming-distance obs (2026-06-25)
            sync_obs_dist_vec_0  <= 40'h0;         sync_obs_dist_vec_1  <= 40'h0;
            sync_eye_width_0     <= 14'h0;         sync_eye_width_1     <= 14'h0;
            // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap)
            sync_obs_rxcap0_0    <= 32'h0;         sync_obs_rxcap0_1    <= 32'h0;
            sync_obs_rxcap1_0    <= 32'h0;         sync_obs_rxcap1_1    <= 32'h0;
            sync_obs_fcsmcap_0   <= 32'h0;         sync_obs_fcsmcap_1   <= 32'h0;
`endif
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
            sync_cal_in_hold_0 <= cal_in_hold_w;
            sync_cal_in_hold_1 <= sync_cal_in_hold_0;
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
            // SoC Labs V2 data-send observation 2026-06-21
            sync_obs_a2l_app_rdy_0  <= obs_a2l_replay_app_ready_w;
            sync_obs_a2l_app_rdy_1  <= sync_obs_a2l_app_rdy_0;
            sync_obs_a2l_lnk_empty_0 <= obs_a2l_replay_link_empty_w;
            sync_obs_a2l_lnk_empty_1 <= sync_obs_a2l_lnk_empty_0;
            // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21
            sync_obs_a2l_wptr_0     <= obs_a2l_wptr_w;
            sync_obs_a2l_wptr_1     <= sync_obs_a2l_wptr_0;
            sync_obs_a2l_sack_0     <= obs_a2l_synced_ack_w;
            sync_obs_a2l_sack_1     <= sync_obs_a2l_sack_0;
            sync_obs_a2l_full_0     <= obs_a2l_full_w;
            sync_obs_a2l_full_1     <= sync_obs_a2l_full_0;
            sync_obs_a2l_endem_0    <= obs_a2l_enable_app_demet_w;
            sync_obs_a2l_endem_1    <= sync_obs_a2l_endem_0;
            // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
            sync_obs_a2l_rreset_0   <= obs_a2l_rreset_w;
            sync_obs_a2l_rreset_1   <= sync_obs_a2l_rreset_0;
            sync_obs_a2l_rptr_0     <= obs_a2l_rptr_w;
            sync_obs_a2l_rptr_1     <= sync_obs_a2l_rptr_0;
            // SoC Labs FC credit observation 2026-06-12
            sync_obs_fe_rx_ptr_0    <= obs_fe_rx_ptr_w;
            sync_obs_fe_rx_ptr_1    <= sync_obs_fe_rx_ptr_0;
`ifdef TIDELINK_PHY_V2
            // SoC Labs SYNC-insert TX observability 2026-06-15 (PART 1) — 2-flop
            // sync of the TX-link-clk-domain probe into apb_clk.
            sync_obs_tx_sync_ins_0  <= obs_tx_sync_ins_cnt_w;
            sync_obs_tx_sync_ins_1  <= sync_obs_tx_sync_ins_0;
            sync_obs_tx_idle_0      <= obs_tx_link_idle_level_w;
            sync_obs_tx_idle_1      <= sync_obs_tx_idle_0;
            sync_obs_tx_train_0     <= obs_tx_training_level_w;
            sync_obs_tx_train_1     <= sync_obs_tx_train_0;
            // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 1) —
            // 2-flop sync of the rx-link-clk-domain probe into apb_clk.
            sync_obs_sync_seen_cnt_0  <= obs_sync_seen_cnt_w;
            sync_obs_sync_seen_cnt_1  <= sync_obs_sync_seen_cnt_0;
            sync_obs_sync_seen_lane_0 <= obs_sync_seen_lane_w;
            sync_obs_sync_seen_lane_1 <= sync_obs_sync_seen_lane_0;
            // SoC Labs RX RAW-WORD + PERMUTATION obs (2026-06-15, rawobs) —
            // 2-flop sync of the rx-link-clk-domain sticky snapshots into apb_clk.
            // Quasi-static (re-latch only on a new best-match), so the multi-bit
            // 2-flop is the same accepted treatment as the lane vector above.
            dbg_obs_raw_word_0   <= obs_dbg_raw_word_w;
            dbg_obs_raw_word_1   <= dbg_obs_raw_word_0;
            dbg_obs_lane_match_0 <= obs_dbg_lane_any_match_w;
            dbg_obs_lane_match_1 <= dbg_obs_lane_match_0;
            dbg_obs_popcount_0   <= obs_dbg_best_popcount_w;
            dbg_obs_popcount_1   <= dbg_obs_popcount_0;
            dbg_obs_slice_idx_0  <= obs_dbg_slice_idx_w;
            dbg_obs_slice_idx_1  <= dbg_obs_slice_idx_0;
            // SoC Labs PER-LANE SYNC-match LIVE oracle (2026-06-16, perlane-wp) —
            // 2-flop sync of the rx-link-clk-domain live vector into apb_clk.
            sync_obs_lane_live_0 <= obs_sync_lane_live_w;
            sync_obs_lane_live_1 <= sync_obs_lane_live_0;
            // SoC Labs STICKY-POISON per-lane deskew sync_seen vector (2026-06-23)
            // — 2-flop sync of the rx-link-clk-domain per-lane sync_seen vector
            // into apb_clk (each bit independent + quasi-static = tear-immune).
            sync_obs_seen_vec_0  <= obs_sync_seen_vec_w;
            sync_obs_seen_vec_1  <= sync_obs_seen_vec_0;
            // DATA-MODE per-lane SYNC Hamming-distance obs (2026-06-25) — 2-flop
            // sync of the rx-link-clk-domain 8x5b distance pack into apb_clk.
            // Quasi-static while SYNC floods; lane-selected at read.
            sync_obs_dist_vec_0  <= obs_sync_dist_vec_w;
            sync_obs_dist_vec_1  <= sync_obs_dist_vec_0;
            // EYE-WIDTH VISIBILITY (2026-06-17): 2-flop sync of the selected
            // lane's eye-width pack into apb_clk. Quasi-static after a sweep.
            sync_eye_width_0     <= {cal_eye_lane_passed_w, cal_eye_best_slip_w,
                                     cal_eye_best_phase_w,  cal_eye_best_w};
            sync_eye_width_1     <= sync_eye_width_0;
            // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap) —
            // 2-flop sync of the three packed sticky words into apb_clk.
            sync_obs_rxcap0_0    <= obs_rxcap0_w;
            sync_obs_rxcap0_1    <= sync_obs_rxcap0_0;
            sync_obs_rxcap1_0    <= obs_rxcap1_w;
            sync_obs_rxcap1_1    <= sync_obs_rxcap1_0;
            sync_obs_fcsmcap_0   <= obs_fcsmcap_w;
            sync_obs_fcsmcap_1   <= sync_obs_fcsmcap_0;
`endif
        end
    end

    // Writeable Region-8 register storage. POR-only reset for
    // training-related state so it survives warm reset.
    wire region8_write = ctrl_reg_write && (ctrl_reg_addr[4:3] == 2'b10);
`ifdef TIDELINK_PHY_V2
    // SoC Labs RX SYNC-detect SW LANE_MASK (PART 3, 2026-06-15) — Region 9
    // (ctrl_reg_addr[4:3]==2'b00) is the SYNC-OBS/CTRL bank. Slot 2 (0x44032128)
    // is the SW-writable detector lane mask. V2-only; V1 leaves Region 9 read-0.
    wire region9_write = ctrl_reg_write && (ctrl_reg_addr[4:3] == 2'b00)
                         && !apb_ctrl_reg_r10;
    // SoC Labs perlane-wp (2026-06-16): Region 10 write (SoC 0x2148/0x214C). It
    // shares the 2'b00 select with Region 9; apb_ctrl_reg_r10 disambiguates so a
    // Region-10 write never aliases a Region-9 slot (and vice versa, above).
    wire region10_write = ctrl_reg_write && (ctrl_reg_addr[4:3] == 2'b00)
                          && apb_ctrl_reg_r10;
    // SoC Labs winscan obs (2026-06-25): Region D write (SoC 0x4403_21B0 SYNC_DIST
    // lane-sel, 0x4403_21B4 SWI_PHASE_LSB). Region D shares the 2'b00 controller
    // select with Region 9/10; apb_ctrl_reg_rd disambiguates (asserted on the
    // 4'b1101 address for reads AND writes — it is purely address-decoded in
    // tidelink_apb_regs). The rxcap slots 0/1/2 stay RO; only the new slots
    // 4/5 are writable. apb_ctrl_reg_rd takes priority over r10 for this address,
    // so a Region-D write never aliases a Region-9/10 slot.
    wire regionD_write = ctrl_reg_write && (ctrl_reg_addr[4:3] == 2'b00)
                         && apb_ctrl_reg_rd;
`endif

    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            swi_training_mode_r      <= 1'b0;
            swi_recal_r              <= 1'b0;
            swi_bit_slip_lo_r        <= 24'h0;
            // FULL-RANGE IDELAY TAP LSB (2026-06-25) — declared in BOTH builds so
            // the always-present u_idelay_rx can wire .lsb_i. Reset 0 => even-only
            // tap (bit-identical). V1 has no write path, so it stays 0 forever.
            swi_phase_lsb_r          <= 8'h0;
`ifdef TIDELINK_PHY_V2
            swi_sync_insert_en_r     <= 1'b0;   // POR = SYNC-insert OFF (zero-regression default)
            swi_sync_force_always_r  <= 1'b0;   // POR = idle-gated (PART2 gate fix off; bit-identical)
            swi_sync_robust_detect_r <= 1'b0;   // POR = robust re-hunt OFF (PART2; bit-identical)
            swi_sync_lane_mask_r     <= 8'hFF;  // POR = all lanes in (PART3 detector mask default)
            swi_sync_tol_r           <= 5'h00;  // POR = EXACT match (Hamming tol 0 -> bit-identical)
            swi_word_pin_ovr_r       <= 4'h0;
            swi_word_pin_auto_dis_r  <= 1'b0;   // POR = autonomous word-pin
            // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override
            // (2026-06-16, perlane-wp). All reset to the legacy default.
            swi_sync_obs_clr_r       <= 1'b0;   // W1-pulse — never held
            swi_word_pin_perlane_r   <= 32'h0;  // POR = no per-lane override value
            swi_word_pin_perlane_en_r <= 8'h0;  // POR = all lanes legacy (bit-identical)
            swi_eye_lane_sel_r       <= 3'h0;   // Task 3: eye-width lane sel, reset lane 0
            swi_dist_lane_sel_r      <= 3'h0;   // winscan: SYNC-dist lane sel, reset lane 0
            // Autonomous SYNC-detect config drive shadows (2026-06-30; R3
            // one-shot rework 2026-07-02).
            sync_cfg_on_fired_q      <= 1'b0;
            sync_cfg_hold_q          <= 1'b0;  // F1b/D2: hold engages at SYNC-ON,
                                               // then PERMANENT (never blind-OFF)
`endif
            swi_phase_offset_r       <= 32'h0;
            // Phase 2 autonomy — POR-tunable default for NEGO_TRAIN_CFG.
            // Wrapper (tidelink_top.sv) sets train_auto_en=1 by default;
            // cocotb wrappers override the parameter for legacy tests.
            nego_train_cfg_r         <= NEGO_TRAIN_CFG_RESET;
            // M11b (2026-06-10): calibrator MIN_LOCK_DWELLS runtime override
            // moved out of nego_train_cfg_r[7:4] — that nibble is the autoneg
            // FSM's train_poll_timeout (consumed at u_autoneg, and the tb/SW
            // value 0x00F1 was silently forcing MIN_LOCK_DWELLS=15). Own
            // 4-bit field at slot 3 [23:20]; 0 = use the RTL parameter.
            min_lock_dwells_r        <= 4'd1;  // H4 fix: centering_mode ON by default (was 0=off -> S_PROBE (0,0) edge-framing lottery). Full sweep + eye-centre from the auto cal.
            nego_train_retrain_pulse <= 1'b0;
            train_fail_irq_r         <= 1'b0;
            train_fail_irq_w_d       <= 1'b0;
        end else begin
            // Default — retrain pulse self-clears every cycle
            nego_train_retrain_pulse <= 1'b0;
`ifdef TIDELINK_PHY_V2
            // SoC Labs perlane-wp (2026-06-16): SWI_SYNC_OBS_CLR is a W1-PULSE.
            // It self-clears every cycle; a slot-0 bit[5] write re-asserts it for
            // exactly one apb_clk below. The PHY 2-flop-syncs + edge-detects it,
            // so a single pulse produces exactly one clear of the per-lane obs.
            swi_sync_obs_clr_r <= 1'b0;
`endif
            // Local FSM-driven strobes (autoneg's ENTER/EXIT)
            if (local_training_mode_set_w)
                swi_training_mode_r <= 1'b1;
            // I1 SELF-ARM (2026-07-30): gate the autoneg's ST_TRAIN_EXIT clear
            // when SELF_ARM_TRAIN_EN. On the self-arm bring-up the PS holds
            // SWI_TRAINING_MODE=1 over the whole cal_done poll; a running autoneg
            // (were nego_en=1) would else drive local_training_mode_clr_w at
            // ST_TRAIN_EXIT and wipe that SW-held training before the calibrator
            // completes. Only the explicit SW slot-0 write (the region8_write
            // case below, which fires LATER in this block and therefore wins)
            // may clear training on the self-arm path — matching the PS recipe's
            // step-3 SWI_TRAINING_MODE=0 that takes the falling edge to data mode.
            // Default 1'b0 ⇒ ~SELF_ARM_TRAIN_EN constant-folds to 1 ⇒ every
            // existing build keeps the ungated clear, bit-identical.
            else if (local_training_mode_clr_w && !SELF_ARM_TRAIN_EN)
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
`ifdef TIDELINK_PHY_V2
                        swi_sync_insert_en_r    <= ctrl_reg_wdata[2];        // SWI_SYNC_INSERT_EN (V2 PHY SYNC beacon, DEFAULT 0)
                        swi_sync_force_always_r <= ctrl_reg_wdata[3];        // SWI_SYNC_FORCE_ALWAYS (PART2 gate fix, DEFAULT 0)
                        swi_sync_robust_detect_r <= ctrl_reg_wdata[4];       // SWI_SYNC_ROBUST_DETECT (PART2 robust re-hunt, DEFAULT 0)
                        swi_sync_obs_clr_r      <= ctrl_reg_wdata[5];        // SWI_SYNC_OBS_CLR (perlane-wp W1-pulse; self-clears next cycle)
`endif
                    end
                    3'h1: begin
                        swi_bit_slip_lo_r   <= ctrl_reg_wdata[23:0];          // SWI_BIT_SLIP_LO
`ifdef TIDELINK_PHY_V2
                        swi_word_pin_ovr_r      <= ctrl_reg_wdata[27:24];     // V2 word-pin override
                        swi_word_pin_auto_dis_r <= ctrl_reg_wdata[28];        // V2 auto-disable chicken bit
`endif
                    end
                    3'h3: begin                                                // NEGO_TRAIN_CFG
                        nego_train_cfg_r <= ctrl_reg_wdata[15:0];
                        // M11b: [23:20] = calibrator MIN_LOCK_DWELLS override
                        // (0 = RTL parameter default)
                        min_lock_dwells_r <= ctrl_reg_wdata[23:20];
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
`ifdef TIDELINK_PHY_V2
            // SoC Labs RX SYNC-detect SW LANE_MASK (PART 3, 2026-06-15) — Region 9
            // slot 2 (SoC MMIO 0x4403_2128) write. 8-bit; default 0xFF (POR above).
            if (region9_write && (ctrl_reg_addr[2:0] == 3'h2)) begin
                swi_sync_lane_mask_r <= ctrl_reg_wdata[7:0];
                // SoC Labs RX SYNC-detect Hamming TOLERANCE (2026-06-17) — shares
                // the LANE_MASK word: [12:8] = SWI_SYNC_TOL (0 = exact). The same
                // write carries both fields; reset/default 0 -> bit-identical.
                swi_sync_tol_r       <= ctrl_reg_wdata[12:8];
            end
            // SoC Labs PER-LANE word-pin override (perlane-wp) — Region 10 slot 2
            // (0x2148) value, slot 3 (0x214C) enable. RW; default 0 (legacy).
            if (region10_write && (ctrl_reg_addr[2:0] == 3'h2))
                swi_word_pin_perlane_r    <= ctrl_reg_wdata[31:0];
            if (region10_write && (ctrl_reg_addr[2:0] == 3'h3))
                swi_word_pin_perlane_en_r <= ctrl_reg_wdata[7:0];
            // Task 3 (2026-06-17): EYE_WIDTH_SEL lane select — Region 10 slot 5
            // (SoC 0x4403_2154 [2:0]). Picks the lane the 0x2150 eye-width read
            // reports, so all 8 lanes scan remotely from one bitstream.
            if (region10_write && (ctrl_reg_addr[2:0] == 3'h5))
                swi_eye_lane_sel_r        <= ctrl_reg_wdata[2:0];
            // SoC Labs winscan obs (2026-06-25) — Region D writable slots:
            //   slot 4 (SoC 0x4403_21B0 [2:0]) SYNC_DIST_SEL — picks the lane the
            //     0x21AC SYNC_DIST_OBS read reports (all 8 lanes from one bitstream).
            //   slot 5 (SoC 0x4403_21B4 [7:0]) SWI_PHASE_LSB — per-lane RX IDELAY
            //     tap LSB (lane N at bit N); tap = 2*nibble + lsb -> full 0..31.
            if (regionD_write && (ctrl_reg_addr[2:0] == 3'h4))
                swi_dist_lane_sel_r       <= ctrl_reg_wdata[2:0];
            if (regionD_write && (ctrl_reg_addr[2:0] == 3'h5))
                swi_phase_lsb_r           <= ctrl_reg_wdata[7:0];

            // ── AUTONOMOUS SYNC-DETECT CONFIG DRIVE (the LAST autonomy layer) ──
            // (2026-06-30) Replicate the host rcp() SYNC-detect config on-chip on
            // the autonomous (nego_en) path, so the on-chip winscan + cross-lane
            // deskew reanchor have the SAME config the manual recipe writes before
            // its winscan() — without which reanchored never latches on silicon
            // (FCSM wedges at 1, cr=0).
            //
            // Mapping to the golden rcp() (fpga/hw_regression/td_v2_hwlib.sh):
            //   rcp: R_SYNCTOL 0x44032128 = 0x5e4  -> swi_sync_lane_mask_r=
            //        wlink_rx_lane_mask (M2 2026-07-02: the Wlink RX lane mask
            //        mirror — 0xE4 on the TD_AUTO_LANE_MASK_E4 silicon build =
            //        the rcp value; 0xFF in the 8-lane sim — single source of
            //        truth, no bridge1 literal) and swi_sync_tol_r=5 ([12:8]).
            //        The deskew `all_sync_seen = &(sync_seen_vec | ~lane_mask)`
            //        and the live-SYNC obs both consume these. matching the
            //        ACTIVE lane set is THE fix (0xFF waits for 8 lanes when
            //        only 4 are active on silicon).
            //   rcp: R_R8 0x44032100 = 0x1D        -> SYNC_EN bits: insert_en (b2)
            //                                          + force_always (b3) + robust
            //                                          (b4). (b0 train / b1 recal
            //                                          are owned by the FSM and the
            //                                          calibrator — NOT touched.)
            //   rcp: word-pin 0x44032104 = 0       -> already the POR default
            //        (swi_word_pin_ovr_r=0, swi_word_pin_auto_dis_r=0 = AUTO), so
            //        no drive needed; kept AUTO explicitly here for parity.
            //
            // SEQUENCING (the critical part):
            //   * SYNC-ON  fires the FIRST cycle the FULL conjunction
            //     `nego_en & role_locked & swi_training_mode_r` is true (one-shot
            //     latch sync_cfg_on_fired_q, cleared on the training FALL so a
            //     re-training re-fires). R3 arm-order fix (2026-07-02): the old
            //     RISING-edge trigger raced the gate — when the MASTER armed
            //     first, its I²C wrote the slave's SWI_TRAINING_MODE=1 before
            //     the slave's nego_en/role_locked latched, the edge was consumed
            //     while the gate was false, and SYNC-ON never fired (slave
            //     R8=0x00/tol=0 → both calibrators park at cstate=6). Training
            //     is held HIGH for the whole run, so the level+one-shot catches
            //     the late-arming die the instant its gate closes. This is still
            //     BEFORE the winscan FSM and the FC handoff (both kicked on the
            //     training-mode FALLING edge), so the SYNC-detect config is in
            //     place before the scan needs it (ws_kick_evt needs the same
            //     gate at the fall).
            //   * SYNC-OFF: THERE IS NONE any more (D2 "never blind-OFF",
            //     2026-07-03). The R4b/F2 fch_done+settle timer raced the
            //     PEER's WS_FINALIZE re-anchor (the refill needs PEER beacons;
            //     one missed SYNC_PERIOD grid slot resets the deskew confirm
            //     run) and no timer bounds the cross-die scan/arm skew.
            //     insert_en=1 (idle-gated) + robust=1 are the PERMANENT
            //     autonomous data-mode state — data-safe by this design's own
            //     history (the bootstrap + 0.5 s of data mode already ran
            //     under idle-gated beacons on eye-intact silicon; FORCE was
            //     the R4 word-deleter, not idle-gated insert; cost ≈ 1 idle
            //     slot per 32 words). Only force-SYNC drops (winscan FINALIZE
            //     exit). lane_mask=0xe4 / tol=5 likewise stay set across data
            //     mode (correct for the deskew, benign for the datapath).
            //
            // ADDITIVITY: gated on nego_en & role_locked. On the proven SW-role_
            // lock + host-winscan path nego_en=0 ⇒ this never fires and every
            // swi_sync_* reg holds its POR default / host-written value — the SW
            // data regression and the manual silicon recipe are bit-identical.
            // R3: re-arm the one-shot on the training FALL (level, not edge —
            // robust even if the drop is missed for a cycle). Mutually
            // exclusive with the set below (which requires training HIGH).
            if (!swi_training_mode_r)
                sync_cfg_on_fired_q <= 1'b0;
            // LOOP-9: the whole autonomous SYNC-config drive (SYNC-ON one-shot
            // + the F1b/D2 permanent heal) is scoped to autonomy_armed —
            // nego_en & role_locked alone kept it LIVE on silicon manual runs
            // (NEGO_CFG PORs 0x61; the recipe only writes 0x210C=0). With
            // train_auto_en=0 no autonomous write ever lands on the swi_sync_*
            // regs: the manual R8 writes are authoritative, bit-identical.
            if (autonomy_armed) begin
                // SYNC-ON: one-shot on the full conjunction first true (R3).
                if (swi_training_mode_r && !sync_cfg_on_fired_q) begin
                    sync_cfg_on_fired_q      <= 1'b1;
                    // M2 (2026-07-02): the active-lane SYNC mask is the local
                    // Wlink RX lane mask (single source of truth, POR-correct
                    // per build: 0xFF in sim/8-lane, 0xE4 on TD_AUTO_LANE_MASK_E4
                    // silicon builds) — NOT a hardcoded bridge1 constant. This
                    // keeps the 8-lane sim and the 4-lane silicon SYNC masks
                    // consistent with the datapath lane mask by construction.
                    swi_sync_lane_mask_r     <= wlink_rx_lane_mask; // rcp 0x2128[7:0]
                    swi_sync_tol_r           <= 5'd5;   // rcp 0x2128[12:8] — Hamming tol=5
                    swi_sync_insert_en_r     <= 1'b1;   // rcp R8 b2 — SYNC beacon on
                    // R4a (2026-07-02): do NOT set swi_sync_force_always_r
                    // here. Setting it made force-always persist through the
                    // whole ~6.4 s scan AND past WS_FINALIZE (the OR at the
                    // Wlink ports kept the idle gate dead), so the FCSMs —
                    // running from POR (Wlink swi_enable PORs 1) — conversed
                    // over a link that DELETED every 32nd payload word
                    // (WlinkRxLinkLayer substitutes the SYNC beat with 0):
                    // pktnum/credit desync → long=1 / credit-overcount /
                    // fe_full re-wedge = the silicon (h)-data garble.
                    // winscan_force_sync (WS_ARM..WS_PICK) already provides
                    // force-always for the scan window, and training disarms
                    // the TX inserter pre-scan (WavD2DGpio sync_insert is
                    // gated on ~effective_training_mode), so there is no
                    // coverage gap. Outside the scan the beacon is idle-gated
                    // (insert_en only) — safe for live FC traffic.
                    swi_sync_robust_detect_r <= 1'b1;   // rcp R8 b4 — robust re-hunt
                    swi_word_pin_ovr_r       <= 4'h0;   // rcp 0x2104=0 — per-lane AUTO
                    swi_word_pin_auto_dis_r  <= 1'b0;   //   (POR default; explicit)
                    sync_cfg_hold_q          <= 1'b1;   // F1b: hold phase engaged
                end
                // F1b I2C-CLOBBER HEAL (2026-07-02, sim-discovered): on the
                // SLAVE die the master's autoneg drives training over the
                // AXIL->APB bridge as FULL-WORD R8 slot-0 writes (e.g.
                // SWI_TRAINING_MODE=0 at ST_TRAIN_EXIT, wdata=32'h0) — the
                // slot-0 case above then rewrites EVERY slot-0 bit, zeroing
                // the autonomous SYNC-ON's insert_en/robust mid-flight (the
                // MASTER is immune: its training clear is the local strobe,
                // not a slot-0 write). Sim signature: slave ended data mode
                // robust=0 while the master ended robust=1. While the drive
                // owns the SYNC config (sync_cfg_hold_q — set at SYNC-ON,
                // now PERMANENT: D2), RE-DRIVE insert_en/robust every cycle
                // so any slot-0 write is healed the next cycle.
                // Nego-gated (enclosing if) => manual path bit-identical.
                //
                // D2 "NEVER BLIND-OFF" (2026-07-03): the R4b/F2 timed
                // SYNC-OFF that used to follow this heal is DELETED — see the
                // rationale at the sync_cfg_hold_q declaration. insert_en=1
                // (idle-gated) + robust=1 ARE the permanent autonomous
                // data-mode state; only force-SYNC ever drops (already at the
                // winscan FINALIZE exit; swi_sync_force_always_r is never set
                // autonomously per R4a, so it stays POR-0 here). lane_mask
                // (=wlink_rx_lane_mask) / tol=5 likewise stay set for the
                // deskew. The manual nego_en=0 path never executes this block.
                if (sync_cfg_hold_q) begin
                    swi_sync_insert_en_r     <= 1'b1;
                    swi_sync_robust_detect_r <= 1'b1;
                end
            end
`endif
        end
    end

    // Phase 1 G1b — drive the sticky IRQ output. Held HIGH until SW
    // acknowledges via W1C to slot 3'h3 bit[16]. No CDC needed: same
    // apb_clk as the consumer (top-level IRQ pin).
    assign train_fail_irq_o = train_fail_irq_r;

    // =====================================================================
    // Region 9 — SYNC-insert TX OBSERVABILITY (SoC Labs 2026-06-15, PART 1)
    //   SoC MMIO 0x4403_2120 (apb_region 4'b1001 -> ctrl_reg_addr[4:3]==2'b00,
    //   slot 3'h0). Read-only. Decodes the new, previously-unused region-select
    //   2'b00 (see tidelink_apb_regs.sv Region 9 routing). The intended slot for
    //   this register per the integration spec was 0x4403_2118, but that address
    //   is ALREADY ASSIGNED to SWI_PHASE_OFFSET (Region 8 slot 6); Region 8 and
    //   Region C are both fully populated (all 8 slots each), so a fresh region
    //   was allocated instead of clobbering a live RW register. 0x2120 was the
    //   reserved/reads-0 Region 9 window in tidelink_apb_regs.sv.
    //
    //   SYNC-OBS layout (slot 3'h0):
    //     [15: 0] tx_sync_ins_cnt    — 16-bit saturating count of TX word-clk
    //                                  cycles the PHY drove a SYNC word (>0 proves
    //                                  the inserter is physically firing)
    //     [16]    tx_link_idle_level — live io_link_tx_tx_idle (the production gate)
    //     [17]    tx_training_level  — live effective_training_mode_tx
    //     [23:18] reserved (0)
    //     [31:24] 0x5C               — presence marker (old images read 0 here)
    //   All fields are apb_clk 2-flop-synced from the TX-link-clk domain.
    // =====================================================================
    // =====================================================================
    // Region 9 — RX mask-aware SYNC-DETECT (SoC Labs 2026-06-15, PART 1)
    //   SoC MMIO 0x4403_2124 (slot 3'h1). Read-only. THE KEY DIAGNOSTIC for the
    //   silicon "TX inserts but RX never detects" defect: the mask-aware per-lane
    //   detector on the post-deskew word.
    //     [15: 0] sync_seen_cnt        — 16-bit saturating count of mask-aware
    //                                    SYNC matches (>0 proves RX sees coherent
    //                                    SYNC — the full-128 compare at 0x2114
    //                                    [31:16] can read 0 while THIS climbs)
    //     [23:16] sync_seen_lane_sticky — 8-bit per-lane "ever-matched" vector
    //                                    (which lanes delivered their SYNC slice;
    //                                    THE load-bearing per-lane diagnostic)
    //     [31:24] 0x5D                 — presence marker (old images read 0)
    //   All fields apb_clk 2-flop-synced from the rx-link-clk domain.
    //
    // Region 9 — RX SYNC-detect SW LANE_MASK (PART 3)
    //   SoC MMIO 0x4403_2128 (slot 3'h2). RW, default 0xFF. Feeds the detector's
    //   lane_mask_i so the operator can mask marginal lanes on silicon.
    //     [ 7: 0] swi_sync_lane_mask   — per-lane detector enable (1=in)
    //     [12: 8] swi_sync_tol         — SYNC-slice Hamming tolerance (2026-06-17,
    //                                    0 = exact; sweep 0..5 on marginal silicon)
    // =====================================================================
`ifdef TIDELINK_PHY_V2
    assign region9_sync_obs_rdata =
        (ctrl_reg_addr[2:0] == 3'h0) ? {8'h5C,                    // [31:24] marker
                                        6'h0,                     // [23:18] reserved
                                        sync_obs_tx_train_1,      // [17]    training level
                                        sync_obs_tx_idle_1,       // [16]    tx_idle level
                                        sync_obs_tx_sync_ins_1} : // [15:0]  SYNC-insert sat. count
        (ctrl_reg_addr[2:0] == 3'h1) ? {8'h5D,                    // [31:24] marker (PART1 SYNC-DETECT)
                                        sync_obs_sync_seen_lane_1,// [23:16] per-lane sticky "ever-matched"
                                        sync_obs_sync_seen_cnt_1} : // [15:0] mask-aware SYNC-detect sat. count
        (ctrl_reg_addr[2:0] == 3'h2) ? {19'h0, swi_sync_tol_r,         // [12:8] Hamming tol (RW, 2026-06-17)
                                        swi_sync_lane_mask_r} :        // [ 7:0] PART3 SW LANE_MASK (RW)
        // SoC Labs RX RAW-WORD + PERMUTATION obs (2026-06-15, rawobs). Slots 3..7
        // fill the rest of Region 9 (the bank's last free word is slot 7). All RO.
        (ctrl_reg_addr[2:0] == 3'h3) ? dbg_obs_raw_word_1[ 31:  0] : // 0x212C raw word [31:0]
        (ctrl_reg_addr[2:0] == 3'h4) ? dbg_obs_raw_word_1[ 63: 32] : // 0x2130 raw word [63:32]
        (ctrl_reg_addr[2:0] == 3'h5) ? dbg_obs_raw_word_1[ 95: 64] : // 0x2134 raw word [95:64]
        (ctrl_reg_addr[2:0] == 3'h6) ? dbg_obs_raw_word_1[127: 96] : // 0x2138 raw word [127:96]
        // Slot 7 (0x213C): the DECISIVE per-RX-lane carried-slice-index map +
        // companion popcount + presence marker, packed. The 8x4-bit slice map
        // needs all 32 bits, so the explicit match-vector/popcount get a SECOND
        // packed word would need a 9th slot the bank does not have — instead the
        // match vector is FULLY recoverable from the slice map in SW
        // (lane_any_match[i] = (slice_idx[i]==i); best_popcount = popcount of
        // those), and slot 7 carries the raw slice map verbatim.
        (ctrl_reg_addr[2:0] == 3'h7) ? dbg_obs_slice_idx_1          // 0x213C [31:0] 8x4-bit slice map
                                     : 32'h0;
    // =====================================================================
    // Region 10 — PER-LANE SYNC-match SWEEP ORACLE + word-pin override
    //   (SoC Labs 2026-06-16, perlane-wp). Shares the 2'b00 controller select
    //   with Region 9; apb_ctrl_reg_r10 disambiguates. Slot 0 (0x2140) is the
    //   gpio_phy EPOCH_STATUS word (served elsewhere) and is NOT decoded here.
    //
    //     slot 1 (0x4403_2144) — SYNC_LANE_LIVE (RO). THE sweep oracle.
    //        [ 7: 0] live per-lane "matched since last clear" vector (1=lane L
    //                currently carries its SYNC slice). Cleared by the W1-pulse
    //                SWI_SYNC_OBS_CLR (0x44032100[5]); re-accumulates after.
    //        [31:24] 0x5E presence marker (old/V1 images read 0 here).
    //     slot 2 (0x4403_2148) — WORD_PIN_PERLANE (RW). 8 x 4-bit per-lane window
    //                pin value (lane L at [4L+3:4L]). Applied to a lane only when
    //                its enable bit (slot 3) is set. Reset 0.
    //     slot 3 (0x4403_214C) — WORD_PIN_PERLANE_EN (RW). [7:0] per-lane override
    //                enable (lane L at bit L). 1 = lane L uses WORD_PIN_PERLANE[L]
    //                for its word window (overrides auto/global pin); 0 = legacy.
    //                Reset 0 -> bit-identical datapath.
    // =====================================================================
    assign region10_rdata =
        (ctrl_reg_addr[2:0] == 3'h1) ? {8'h5E, 16'h0, sync_obs_lane_live_1} :  // 0x2144 live match (RO)
        (ctrl_reg_addr[2:0] == 3'h2) ? swi_word_pin_perlane_r              :  // 0x2148 per-lane pin (RW)
        (ctrl_reg_addr[2:0] == 3'h3) ? {24'h0, swi_word_pin_perlane_en_r}  :  // 0x214C per-lane enable (RW)
        // EYE-WIDTH VISIBILITY (2026-06-17) — slot 4 (0x4403_2150) EYE_WIDTH_SEL
        // (RO). The DECISIVE per-lane eye-quality diagnostic: read the matched-
        // window WIDTH (IDELAY/phase taps) of the lane selected by
        // SWI_EYE_LANE_SEL after a sweep. A wide eye = healthy lane; a narrow/
        // zero eye = the marginal-RX die's off-centre lane. Packed:
        //   [ 5: 0] best_run  (eye width, 0..16)
        //   [ 9: 6] best_run_start_phase
        //   [12:10] best_run_slip
        //   [13]    lane_passed (best_run >= LOCK_THRESH)
        //   [31:24] 0xE7 presence marker (old/V1 images read 0 here)
        (ctrl_reg_addr[2:0] == 3'h4) ? {8'hE7, 10'h0, sync_eye_width_1}    :  // 0x2150 eye width (RO)
        // Task 3 (2026-06-17) — slot 5 (0x4403_2154) EYE_WIDTH_SEL lane select
        // (RW, readback). [2:0] selected lane; [31:24] 0xE8 presence marker.
        (ctrl_reg_addr[2:0] == 3'h5) ? {8'hE8, 21'h0, swi_eye_lane_sel_r}  :  // 0x2154 eye lane sel (RW)
        // SoC Labs V2 data-send observation 2026-06-21 — slot 6 (0x4403_2158)
        // A2L_REPLAY_OBS (RO). THE diagnostic for the V2 data-send blocker
        // (a2l_fc_replay_link_valid stuck 0 while a2l_replay_app_valid=1): the
        // a2l replay buffer's true app_ready and link_empty, 2-flop synced to
        // apb_clk. Both are pure read-only fan-outs — no datapath change.
        //   [ 0] a2l_replay_app_ready  — replay buffer app_ready (FIFO accepts
        //                                the app write; if 0 the word never
        //                                crosses into the a2l async FIFO).
        //   [ 1] a2l_replay_link_empty — replay buffer link side empty (1 = no
        //                                word available on the link/TX side).
        //   [31:24] 0xA2 presence marker (old/V1 images read 0 here).
        //
        // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 — the raw
        // a2l replay internals packed into the previously-spare bits so silicon
        // can compute the false-FULL mechanism directly (app_ready alone did not
        // localize it; two sim-proven fixes failed on silicon). All app-clk
        // domain, 2-flop synced to apb_clk. EXACT 0x4403_2158 BIT MAP:
        //   [ 0]    app_ready              (= ~a2l_full & enable_app_clk_demet)
        //   [ 1]    link_empty
        //   [ 6: 2] a2l_wptr[4:0]          (app-clk WRITE binary pointer)
        //   [11: 7] a2l_synced_ack[4:0]    (ACK pointer synced into app-clk)
        //   [12]    a2l_full               (the false-FULL flag)
        //   [13]    enable_app_clk_demet   (other term of app_ready)
        //   [18:14] a2l_rptr[4:0]          (LINK read binary pointer)
        //   [19]    a2l_rreset             (read-side FIFO reset, == fifo_io_rreset)
        //   [23:20] spare (reads 0)
        //   [31:24] 0xA2 presence marker
        // Decode: if a2l_full=1 it is the pointer issue — compare wptr vs
        // synced_ack for the lap (e.g. ack=0b10001 vs wptr=0). If a2l_full=0 but
        // app_ready=0 then enable_app_clk_demet=0 (a different bug). If
        // a2l_rreset=1 the read side is HELD in reset (link_empty stuck 1). If
        // a2l_rreset=0 and a2l_rptr is stuck while a2l_wptr advances, the write-
        // ptr Gray sync into the read domain is broken.
        (ctrl_reg_addr[2:0] == 3'h6) ? {8'hA2, 4'h0,                        // [31:24] marker, [23:20] spare
                                        sync_obs_a2l_rreset_1,               // [19]    a2l_rreset
                                        sync_obs_a2l_rptr_1,                 // [18:14] a2l_rptr[4:0]
                                        sync_obs_a2l_endem_1,                // [13]    enable_app_clk_demet
                                        sync_obs_a2l_full_1,                 // [12]    a2l_full
                                        sync_obs_a2l_sack_1,                 // [11:7]  a2l_synced_ack[4:0]
                                        sync_obs_a2l_wptr_1,                 // [6:2]   a2l_wptr[4:0]
                                        sync_obs_a2l_lnk_empty_1,            // [1]     link_empty
                                        sync_obs_a2l_app_rdy_1}           :  // [0]     app_ready (0x2158, RO)
        // SoC Labs STICKY-POISON per-lane deskew sync_seen vector 2026-06-23 —
        // slot 7 (0x4403_215C) SYNC_SEEN_VEC (RO). The instrument the prior agent
        // left as a TODO: per-lane deskew SYNC re-anchor "committed a periodic-
        // confirmed SYNC index" vector. Lets a silicon read distinguish:
        //   0x00            -> NO lane armed (self-gating has rejected everything
        //                      so far / no clean periodic SYNC yet);
        //   set, EPOCH_STATUS(0x2140 bit0 reanchored)=0 -> lanes armed but indices
        //                      INCONSISTENT (the re-anchor latch has not engaged);
        //   set AND reanchored=1 -> armed + coherent (the healthy state).
        //   [ 7: 0] per-lane sync_seen (lane L at bit L)
        //   [31:24] 0x5F presence marker (old/V1 images read 0 here)
        (ctrl_reg_addr[2:0] == 3'h7) ? {8'h5F, 16'h0, sync_obs_seen_vec_1} :  // 0x215C sync_seen vec (RO)
                                       32'h0;
    // =====================================================================
    // Region D — RX-FRAMER long-DATA STICKY CAPTURE (SoC Labs 2026-06-21,
    //   rxcap). paddr[8:5]=4'b1101, SoC MMIO 0x4403_21A0-0x4403_21A8. All RO.
    //   THE decisive die_b (RECEIVER) capture: localises exactly WHERE a
    //   sustained A->B multi-beat long-DATA packet dies. Sticky in the rx-link-
    //   clk / io_rx_clk domain (survives the slow APB poll), 2-flop-synced here.
    //
    //   slot 0 (0x4403_21A0) RXCAP0 — RX framer (WlinkRxLinkLayer):
    //     [31:24] 0xC0 presence marker (old/V1 images read 0)
    //     [23]    is_long_ever        — framer EVER saw a long packet
    //     [22]    eop_ever            — endOfPacket EVER fired
    //     [21]    err_ever            — framer error-state (==2) EVER
    //     [20]    valid_ever          — LL_RX valid EVER
    //     [19:18] state               — live framer FSM state
    //     [15:0]  ph_at_first_long    — corrected_ph[15:0] captured at the FIRST
    //                                   is_long ([7:0]=header length byte,
    //                                   [15:8]=low candidate word_count)
    //   slot 1 (0x4403_21A4) RXCAP1 — RX framer depth:
    //     [31:15] max_byte_count[16:0]— deepest byte_count the framer reached
    //     [14:0]  long_start_cnt      — saturating count of long-packet starts
    //   slot 2 (0x4403_21A8) FCSMCAP — FCSM delivery (WlinkGenericFCSM_6):
    //     [31:24] 0xC1 presence marker
    //     [23]    data_ever           — DATA pkt (data_id 0xa1) EVER decoded
    //     [22]    l9_resync_ever       — L9 one-shot resync EVER fired
    //     [21]    pktnum_mismatch_ever — data-pkt pktnum mismatch (post-resync) EVER
    //     [20]    l2a_valid_ever       — L2A replay app_valid EVER (word enqueued)
    //     [15:8]  first_pktnum         — first observed ll_rx_pktnum
    //     [ 7:0]  last_exp_pktnum      — last exp_pkt_num at a data pkt
    //
    //   DECODE (one capture distinguishes the three hypotheses):
    //     (a) EYE corruption     : RXCAP0 is_long_ever=0 (or ph_at_first_long
    //                              garbage / max_byte_count stalls far below
    //                              (len+1)*16) AND FCSMCAP data_ever=0.
    //     (b) FCSM one-shot resync: RXCAP0 is_long_ever=1 + eop_ever=1 (frames
    //                              fine) BUT FCSMCAP data_ever=1, l9_resync_ever=1,
    //                              pktnum_mismatch_ever=1, l2a_valid_ever=0 (only
    //                              the 1st pkt enqueued) -> RTL resync fix.
    //     (c) commit-gate mis-target: FCSMCAP l2a_valid_ever=1 (delivery fine);
    //                              then read fifo_ctrl fc_wr_addr vs
    //                              write_target_addr (0x44032010 STATUS[4]).
    // =====================================================================
    // SoC Labs winscan obs (2026-06-25): slot 3 SYNC_DIST_OBS (RO) returns the
    // SYNC Hamming distance (5b) of the lane selected by swi_dist_lane_sel_r,
    // with a 0x5B presence marker (old/V1 images read 0). The 8x5b distance pack
    // is 2-flop-synced to apb_clk (sync_obs_dist_vec_1) then lane-muxed here.
    // slot 4 SYNC_DIST_SEL (RW, readback) carries the lane select + 0x5A marker.
    // slot 5 SWI_PHASE_LSB (RW, readback) carries the per-lane IDELAY tap LSB +
    // 0x1B marker.
    // slot 6 WINSCAN_OBS (RO, R2c 2026-07-02): on-chip winscan health.
    //     [0] winscan_done    — scan+finalize complete for this nego episode
    //     [1] ws_degenerate_q — STICKY: the sweep saw a FLAT metric on every
    //                           scanned lane (nothing measured); the SEEDED
    //                           host/APB taps were restored, not argmin-0.
    //     [2] ws_anchor_timeout_q — STICKY (F4 2026-07-02, FIX-3 2026-07-03):
    //                           the WS_FINALIZE anchor gate (winscan_done held
    //                           until the CDC'd deskew `reanchored` =1) timed
    //                           out AND all WS_ANCHOR_RETRIES(=5, R-A) bounded
    //                           clear-retries (re-pulse the F3 clear, re-wait)
    //                           ALSO timed out — only then did it fail open.
    //                           The handoff ran WITHOUT a settled anchor (dead
    //                           sync_obs_clr routing / un-anchorable eye /
    //                           beacon-less zombie peer).
    //                           Cleared on a fresh scan episode (WS_ARM).
    //     [3] ws_anchor_late_q — STICKY (FIX-3 2026-07-03): `reanchored` ROSE
    //                           while fch_done_r was already set — the anchor
    //                           healed LATE, after a fail-open handoff.
    //                           Cleared on a fresh scan episode (WS_ARM).
    //     [7:4] ws_abort_cnt_q — saturating count (FIX-1 2026-07-03) of
    //                           episode-binding ABORT-RESTARTS: a gated
    //                           training fall consumed MID-SCAN restarted the
    //                           scan at WS_ARM (the pre-fix lost-kick path).
    //                           POR-cleared only (lifetime counter).
    //     [8] fch_quiesced_r  — Q1 (2026-07-04) LIVE level: the fch sequencer
    //                           is holding the Wlink LL in swi_swreset (the
    //                           quiesce-before-finalize write landed and the
    //                           bootstrap has not yet released it). Reads 1
    //                           exactly across WS_FINALIZE(+retries)..the
    //                           bootstrap's SWRESET_OFF — on-silicon proof the
    //                           re-anchor ran over a QUIET link.
    //     [9] ws_vfy_retry_q  — STICKY (R-A 2026-07-04): a FIX-3 clear-retry
    //                           fired with `reanchored` ALREADY 1 — the
    //                           anchor latched but the zero-tolerance
    //                           ANCHOR-VERIFY did not (one lane's sticky
    //                           sync_idx on a wrong/adjacent SYNC slot — the
    //                           die_b byte-lane[23:16] mis-anchor signature).
    //                           The retry re-cleared and re-anchored.
    //                           Cleared on a fresh scan episode (WS_ARM).
    //     [10] ws_rdv_timeout_q — R-B rendezvous-timeout sticky. DORMANT
    //                           since Loop-13 (2026-07-04): the winscan no
    //                           longer waits on the peer rendezvous, so this
    //                           always reads 0. Slot kept stable for the
    //                           R-B rework.
    //     [13:11] ws_retry_cnt_q — FIX-4 (2026-07-04) per-episode ANCHOR-
    //                           RETRY ATTEMPT COUNTER (saturates at 7):
    //                           +1 per FIX-3 clear-retry arc. 0 = anchored
    //                           +verified in the first window; N = N retries
    //                           fired (the episode took N+1 windows); 5 with
    //                           [2]=1 = budget exhausted, failed open. On
    //                           silicon this is the statistic that validates
    //                           the retry-compounding model (per-roll ~50%
    //                           first-window odds -> >90% within the budget
    //                           IFF the attempts are independent — see the
    //                           FIX-4 jitter block at the winscan FSM).
    //                           Cleared on a fresh scan episode (WS_ARM).
    //     [31:24] 0x57 ('W')  — presence marker (old images read 0 here).
    //                           UNCONDITIONAL BY DESIGN (LOOP-9 2026-07-03):
    //                           the marker is a constant in the read mux, NOT
    //                           gated on the FSM/bring-up/arming — it reads
    //                           0x57 from POR onward, manual or autonomous.
    //                           A 0x00000000 read on silicon therefore means
    //                           the bitstream's controller PREDATES this slot
    //                           (2026-07-02) = STALE package_ip — stop and
    //                           rebuild (the known farm packaging hazard).
    //   All apb_clk-domain (the winscan FSM's own domain) — no CDC.
    // Slot 7 (0x21BC) FCH_OBS (RO, SoC Labs 2026-07-09, ported from f1b3aac):
    //   the FCH APB watchdog status — see the slot-7 case in the read mux below.
    //   fch_stall_err_q / fch_stall_widx_q are apb_clk-domain (the fch sequencer's
    //   own domain) — no CDC. (Upstream f1b3aac used 0x21B8[14]/[16:15]; that
    //   field is full on this branch, hence the dedicated slot.)
    wire [4:0] dist_sel_lane = sync_obs_dist_vec_1[5*swi_dist_lane_sel_r +: 5];
    assign regionD_rxcap_rdata =
        (ctrl_reg_addr[2:0] == 3'h0) ? sync_obs_rxcap0_1  : // 0x21A0 RXCAP0
        (ctrl_reg_addr[2:0] == 3'h1) ? sync_obs_rxcap1_1  : // 0x21A4 RXCAP1
        (ctrl_reg_addr[2:0] == 3'h2) ? sync_obs_fcsmcap_1 : // 0x21A8 FCSMCAP
        (ctrl_reg_addr[2:0] == 3'h3) ? {8'h5B, 19'h0, dist_sel_lane}        : // 0x21AC SYNC_DIST_OBS (RO)
        (ctrl_reg_addr[2:0] == 3'h4) ? {8'h5A, 21'h0, swi_dist_lane_sel_r}  : // 0x21B0 SYNC_DIST_SEL (RW)
        (ctrl_reg_addr[2:0] == 3'h5) ? {8'h1B, 16'h0, swi_phase_lsb_r}      : // 0x21B4 SWI_PHASE_LSB (RW)
        (ctrl_reg_addr[2:0] == 3'h6) ? {8'h57,
                                        // FIX-D obs (2026-07-07) — the FREE
                                        // [23:14] field (was 10'h0):
                                        ws_state_r,               // [23:20]
                                        ws_waitpeer_reentry_cnt,  // [19:18]
                                        ws_serve_cnt_q,           // [17:16]
                                        ws_waitpeer_entered_q,    // [15]
                                        ws_verify_stuck_q,        // [14]
                                        ws_retry_cnt_q,
                                        ws_rdv_timeout_q, ws_vfy_retry_q,
                                        fch_quiesced_r,
                                        ws_abort_cnt_q,
                                        ws_anchor_late_q, ws_anchor_timeout_q,
                                        ws_degenerate_q, winscan_done}      : // 0x21B8 WINSCAN_OBS (RO)
        // SoC Labs 2026-07-09 (ported from f1b3aac): FCH APB WATCHDOG status.
        // 0x21B8 (WINSCAN_OBS) is FULL on this branch, so the fch_stall status
        // lives here in the previously-reserved slot 7 instead of 0x21B8[14].
        //   [ 0]    fch_stall_err_q  (sticky) — fch seq timed out on wl_apb_pready
        //                            and RELEASED the bus (else the PS's apb_pready
        //                            was pinned low for ever = "training kills the
        //                            die_a PS<->PL bus"). 0 = the LL acked.
        //   [ 2:1]  fch_stall_widx_q — which write stalled: 0=SWRESET_ON,
        //                            1=SWRESET_OFF, 2=ENABLE.
        //   [31:24] 0xFC presence marker (old/STALE-IP images read 0 here).
        //   (Both fields are apb_clk-domain — the fch sequencer's own domain, no
        //   CDC. fch_active_r is NOT read here: it is declared with the fch FSM
        //   regs, downstream of this mux, so `default_nettype none forbids the
        //   forward reference — the sticky pair is what software needs anyway.)
        (ctrl_reg_addr[2:0] == 3'h7) ? {8'hFC, 21'h0,
                                        fch_stall_widx_q, fch_stall_err_q}  : // 0x21BC FCH_OBS (RO)
                                       32'h0;
`else
    // V1: no V2 SYNC inserter/detector; region-select 2'b00 reads 0 (bit-identical).
    assign region9_sync_obs_rdata = 32'h0;
    assign region10_rdata          = 32'h0;
    assign regionD_rxcap_rdata     = 32'h0;
`endif

    // Region 8 read mux
    assign region8_rdata =
`ifdef TIDELINK_PHY_V2
        // P1 (2026-07-19): bit[6] SWI_FORCE_RECAL is WRITE-ONLY and reads back
        // as 0, exactly like the slot-0 bit[5] SWI_SYNC_OBS_CLR W1-pulse beside
        // it. This is a CORRECTNESS requirement, not a style choice.
        //
        // An earlier revision read back the pulse-stretcher state here as a
        // "request handed off" status. That was unsafe: slot 0 is a PACKED
        // register that firmware must READ-MODIFY-WRITE to touch
        // training_mode / SWI_RECAL / the SYNC bits. Any RMW landing inside the
        // 1024-cycle stretch window would read bit[6]=1, write it straight back,
        // and re-fire force_recal_w1p_w — silently re-arming a PHY retrain on a
        // converged link, and doing so indefinitely under a polling loop.
        // Reading 0 makes that hazard structurally impossible: an RMW can never
        // carry bit[6] forward, so every re-arm is a deliberate write.
        //
        // (Gating the write strobe with !swi_force_recal_r was the alternative.
        // It is INCOMPLETE: it only covers an RMW whose WRITE lands inside the
        // window, not one that SAMPLED bit[6]=1 inside the window and wrote back
        // after the timer expired. Reading 0 covers both.)
        //
        // No handshake status is exposed in its place: the stretcher is an
        // open-loop timer with NO feedback from the calibrator, so a "busy" bit
        // could only ever prove the timer had expired — not that the calibrator
        // saw the request. The authoritative evidence that a retrain really
        // happened is the calibrator FSM state itself (Region C OBS_CAL /
        // cal_state), which is where SW should look.
        (ctrl_reg_addr[2:0] == 3'h0) ? {27'h0, swi_sync_robust_detect_r, swi_sync_force_always_r, swi_sync_insert_en_r, swi_recal_r, swi_training_mode_r} :
`else
        (ctrl_reg_addr[2:0] == 3'h0) ? {30'h0, swi_recal_r, swi_training_mode_r} :
`endif
`ifdef TIDELINK_PHY_V2
        (ctrl_reg_addr[2:0] == 3'h1) ? {3'h0, swi_word_pin_auto_dis_r,
                                        swi_word_pin_ovr_r, swi_bit_slip_lo_r} :
`else
        (ctrl_reg_addr[2:0] == 3'h1) ? {8'h0, swi_bit_slip_lo_r}    :
`endif
        (ctrl_reg_addr[2:0] == 3'h2) ? {sync_obs_fe_rx_full_1,          // [31]    fe_rx_is_full   — FCSM 4->5 SEND credit gate (SoC Labs 2026-06-09)
                                        sync_obs_a2l_replay_v_1,        // [30]    a2l_fc_replay_link_valid — FCSM 4->5 SEND app-valid gate (link side)
                                        sync_obs_llrx_valid_1,          // [29]    LL_RX valid pkt
                                        sync_obs_pkt_crack_1,           // [28]    pkt_is_crack_pkt
`ifdef TIDELINK_PHY_V2
                                        ws_fin_wait_lvl | (autonomy_armed & winscan_done & ~role_is_master),  // [27]    R-B ASYMMETRIC PEER-SERVE (2026-07-07): the peer-visible finalize-rendezvous bit. The MASTER advertises ws_fin_wait_lvl (it is parked quiesced in WS_FIN_WAITPEER). The SLAVE — the die the master POLLS — advertises READY-TO-SERVE (autonomy_armed & winscan_done: its own winscan is complete and its anchor is good, so it can quiesce+serve idle beacons on the master's GO). The master's autoneg byte-3 capture reads THIS from the slave and, once set, sends the FINALIZE_GO. Repurposed from the instantaneous pkt_is_cr_pkt (no script/regression consumes it — tlchar/tl39 read the [23]/[24] STICKY seen bits). V1 arm below keeps pkt_is_cr_pkt bit-identical.
`else
                                        sync_obs_pkt_cr_1,              // [27]    pkt_is_cr_pkt (pre-R-B V1 packing)
`endif
`ifdef TIDELINK_PHY_V2
                                        sync_cal_in_hold_1,             // [26]    L4 (2026-07-01): cal_in_hold (S_HOLD) — REPURPOSED from is_long_pkt so the PEER autoneg can rendezvous on both-in-S_HOLD over I2C. is_long_pkt obs is derivable (~is_short & valid) and hierarchically probeable; NOT consumed by any regression-gate test. M1 (2026-07-02): V2-ONLY — the V1 arm below keeps the original is_long_pkt so a V1 build's [26] is bit-identical to pre-L4 (and never aliases into a V2 peer's byte-3 capture, which is USE_CAL_IN_HOLD-gated off on V1).
`else
                                        sync_obs_long_1,                // [26]    is_long_pkt (pre-L4 V1 packing)
`endif
                                        sync_obs_short_1,               // [25]    is_short_pkt
                                        sync_obs_crack_seen_1,          // [24]    crack_pkt_seen_rx
                                        sync_obs_cr_seen_1,             // [23]    cr_pkt_seen_rx
                                        sync_obs_llrx_state_1,          // [22:21] LL_RX byte-align FSM state
                                        sync_obs_a2l_app_v_1,           // [20]    a2l_replay_app_valid — app side (distinguishes skid-empty vs CDC-stuck)
                                        sync_obs_fcsm_state_1,          // [19:17] FCSM state (3b)
                                        sync_cal_done_1,                // [16]    calibration_done
                                        sync_lane_fault_1,              // [15:8]  lane_fault
                                        sync_lane_locked_1}         :  // [7:0] lane_locked — SWI_LANE_STATUS + SEND-GATE OBS
        (ctrl_reg_addr[2:0] == 3'h3) ? {8'h0,                        // [31:24] reserved
                                        min_lock_dwells_r,           // [23:20] M11b MIN_LOCK_DWELLS override (0=param)
                                        3'h0,                        // [19:17] reserved
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
        (ctrl_reg_addr[2:0] == 3'h7) ? 32'h5041_0100                  : // PHY_ALIGN_ID = "PA" v1.0 (RO). V2 WRITES to this slot are the R-B FINALIZE_GO W1P (0x211C bit[0] -> ws_fin_go_reg_q). DORMANT since Loop-13 (2026-07-04): the write still latches the sticky, but nothing consumes it — kept for the R-B rework.
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
    //     3'h6  OBS_CAL             — M7 calibrator state/resweep obs (see
    //                                 obs_cal_w below)
    //     3'h7  OBS_FC_CREDIT       — FE credit obs (see obs_fc_credit_w
    //                                 below; SoC Labs 2026-06-12)
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
    wire [31:0] obs_mask_hs_w = {8'h0,                                // [31:24] reserved
                                 mask_hs_verified_reg,                // [23] genuine-match witness
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

    // OBS_FC_CREDIT (slot 3'h7 @ 0x4403219C) — SoC Labs 2026-06-12: the CR
    // packet's FE credit value intermittently garbles on RX (deskew ~97%
    // coherence residual). SWI_LANE_STATUS[31] fe_rx_is_full only flags the
    // garbled-to-ZERO case; a credit garbled to a SMALL NONZERO value lets
    // 1-4 packets through then wedges, invisible to fe_rx_is_full. Expose
    // the captured credit max (loaded from CR/CRACK
    // auto_rx_in_word_count[15:8], WlinkGenericFCSM_6.v) + the far-end RX
    // credit pointer so SW can compare against the peer's programmed value.
    //   [ 7: 0] fe_rx_credit_max  — apb-synced FCSM rx-clk reg (expect peer's
    //                               programmed credit count, e.g. 0x1f)
    //   [15: 8] fe_rx_ptr         — apb-synced FCSM tx-clk reg (credit-return
    //                               pointer from ACK/NACK packets)
    //   [16]    fe_rx_is_full     — apb-synced full gate (mirror of
    //                               SWI_LANE_STATUS[31])
    //   [23:17] reserved (0)
    //   [31:24] 8'hFC             — presence marker: old images return
    //                               0x00000000 here (slot was reserved/0), so
    //                               SW can detect whether the obs is live.
    // CDC: same 2-flop apb_clk treatment as the other sync_obs_* signals;
    // no raw cross-domain sampling.
    wire [31:0] obs_fc_credit_w = {8'hFC,                  // [31:24] marker
                                   7'h0,                   // [23:17] reserved
                                   sync_obs_fe_rx_full_1,  // [16]
                                   sync_obs_fe_rx_ptr_1,   // [15:8]
                                   sync_obs_fe_rx_cred_1}; // [7:0]

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
        (ctrl_reg_addr[2:0] == 3'h7) ? obs_fc_credit_w                     : // OBS_FC_CREDIT
                                       32'h0;

    // =====================================================================
    // Region F — AXI DATA-NODE observability (SoC Labs 2026-07-29, item I4)
    //   OBS_FC_CREDIT (Region C slot 7) only surfaces the FCSM_6 SIDEBAND flow-
    //   control node; the AXI2WL AW/W/B/AR/R data nodes that actually wedge had
    //   NO APB-visible health field. This block taps the ten AXI channel
    //   handshakes (pure fan-out — no datapath change) and packs a live-stall /
    //   sticky-wedge / response-error / aggregate-healthy word. RO; slot 0
    //   (0x4403_21E0) carries the word, other slots read 0. LIVE in V1 and V2.
    //   See src/rtl/tidelink_axinode_obs.sv for the packed bit layout.
    // =====================================================================
    wire [31:0] axinode_obs_word;
    tidelink_axinode_obs u_axinode_obs (
        .app_clk      (app_clk),
        .apb_clk      (apb_clk),
        .resetn       (hresetn),
        // Target face (axi_tgt_0_* — the local AXI master's view)
        .tgt_aw_valid (axi_tgt_0_aw_valid), .tgt_aw_ready (axi_tgt_0_aw_ready),
        .tgt_w_valid  (axi_tgt_0_w_valid),  .tgt_w_ready  (axi_tgt_0_w_ready),
        .tgt_b_valid  (axi_tgt_0_b_valid),  .tgt_b_ready  (axi_tgt_0_b_ready),
        .tgt_b_err    (axi_tgt_0_b_bits_resp[1]),
        .tgt_ar_valid (axi_tgt_0_ar_valid), .tgt_ar_ready (axi_tgt_0_ar_ready),
        .tgt_r_valid  (axi_tgt_0_r_valid),  .tgt_r_ready  (axi_tgt_0_r_ready),
        .tgt_r_err    (axi_tgt_0_r_bits_resp[1]),
        // Initiator face (axi_ini_0_* — the remote AXI slave's view)
        .ini_aw_valid (axi_ini_0_aw_valid), .ini_aw_ready (axi_ini_0_aw_ready),
        .ini_w_valid  (axi_ini_0_w_valid),  .ini_w_ready  (axi_ini_0_w_ready),
        .ini_b_valid  (axi_ini_0_b_valid),  .ini_b_ready  (axi_ini_0_b_ready),
        .ini_b_err    (axi_ini_0_b_bits_resp[1]),
        .ini_ar_valid (axi_ini_0_ar_valid), .ini_ar_ready (axi_ini_0_ar_ready),
        .ini_r_valid  (axi_ini_0_r_valid),  .ini_r_ready  (axi_ini_0_r_ready),
        .ini_r_err    (axi_ini_0_r_bits_resp[1]),
        .obs_axinodes (axinode_obs_word)
    );

    // =====================================================================
    // Region F slots 1-2 — I1 WINSCAN / CALIBRATOR observability (2026-07-30)
    //   Reads the forwarded-clock alignment calibrator's winscan result over
    //   the PS backdoor to confirm/refute the "override footprint shifts the
    //   capture phase so the winscan never locks -> cal_done=0" hypothesis.
    //   Pure RO fan-out of calibrator FSM registers; ZERO added flops in the
    //   rx_link_clk capture region (all detect/CDC in apb_clk). See
    //   src/rtl/tidelink_winscan_obs.sv for the packed bit layout + A/B read.
    //     slot 1 (0x2E03_21E4) WINSCAN_STAT  — FSM state, cal_done, val_timeout,
    //                                           ever-reached, lane_fault[7:0]
    //     slot 2 (0x2E03_21E8) WINSCAN_EYE   — selected-lane eye width/slip/phase,
    //                                           lane_locked[7:0]
    // =====================================================================
    wire [31:0] winscan_stat_word;
    wire [31:0] winscan_eye_word;
    tidelink_winscan_obs u_winscan_obs (
        .apb_clk           (apb_clk),
        .resetn            (hresetn),
        .cal_state         (cal_state_w),
        .cal_done          (cal_calibration_done_w),
        .cal_val_timeout   (cal_valto_w),
        .cal_in_hold       (cal_in_hold_w),
        .cal_training_mode (cal_training_mode_w),
        .lane_fault        (cal_lane_fault_w),
        .lane_locked       (lane_locked_w),
        .eye_lane_sel      (eye_lane_sel_eff),
        .eye_lane_passed   (cal_eye_lane_passed_w),
        .eye_best_slip     (cal_eye_best_slip_w),
        .eye_best_phase    (cal_eye_best_phase_w),
        .eye_best_run      (cal_eye_best_w),
        .obs_winscan_stat  (winscan_stat_word),
        .obs_winscan_eye   (winscan_eye_word)
    );

    // Region F slots 3-4 — FC-emit / router-grant obs (H1-H4). Packed in the
    // Wlink override's tx_link_clk domain (tidelink_fcemit_obs) and delivered
    // here already synced to apb_clk via the two obs_fcemit_*_o Wlink ports.
    // UNCONDITIONAL (like the sibling winscan obs) so it survives Vivado IP
    // packaging where a define never reaches the packaged-IP OOC synth.
    wire [31:0] obs_fcemit_stat_w;
    wire [31:0] obs_fcemit_idcnt_w;

    // AUTO_ANCHOR diagnostic obs (2026-08-04) — Region F slot 5, SoC 0x4403_21F4.
    // One read explains why reanchored did/didn't latch on the SELF_ARM path:
    //   [15:0] dwell_max  = longest tx-idle streak reached; if it stays << 256 the
    //                       beacon never got its ANCHOR_DWELL consecutive idle
    //                       cycles (keepalive/sideband keeps resetting it).
    //   [16] pulsed_ever  = a SYNC beacon DID emit (dwell+len both completed).
    //   [17] done, [18] pulse(live), [19] link_up(live), [20] tx_idle(live),
    //   [21] reanchored(ws_anchor_q), [22] training_mode_r, [23] AUTO_ANCHOR_EN.
    // AUTO_ANCHOR_EN=0 constant-folds every field to 0 (reads 0, harmless).
    // (net declared here so the Region-F read-mux below can reference it; the
    //  continuous assign lives after the AUTO_ANCHOR FSM — `default_nettype none`
    //  forbids referencing the FSM regs before their declaration.)
    wire [31:0] auto_anchor_obs_word;

    assign regionF_axinodes_rdata =
        (ctrl_reg_addr[2:0] == 3'h0) ? axinode_obs_word  : // 0x21E0 OBS_AXI_NODES
        (ctrl_reg_addr[2:0] == 3'h1) ? winscan_stat_word : // 0x21E4 WINSCAN_STAT
        (ctrl_reg_addr[2:0] == 3'h2) ? winscan_eye_word  : // 0x21E8 WINSCAN_EYE
        (ctrl_reg_addr[2:0] == 3'h3) ? obs_fcemit_stat_w  : // 0x21EC FCEMIT_STAT
        (ctrl_reg_addr[2:0] == 3'h4) ? obs_fcemit_idcnt_w : // 0x21F0 FCEMIT_IDCNT
        (ctrl_reg_addr[2:0] == 3'h5) ? auto_anchor_obs_word : // 0x21F4 AUTO_ANCHOR_OBS
`ifdef TIDELINK_PHY_V2
        (ctrl_reg_addr[2:0] == 3'h6) ? xhb_sub_obs_word_i   : // 0x21F8 XHB_SUB_OBS (TL-009 leak witness)
`endif
        32'h0;

    // =====================================================================
    // Wlink POR Gating
    //   Hold Wlink in reset until role is locked.
    //   swi_enable defaults HIGH, so link training starts automatically
    //   once por_reset deasserts.
    // =====================================================================
    wire wlink_por_reset = ~poresetn | ~role_locked;
    // SoC Labs 2026-06-21: coherent a2l replay-FIFO reset (see app_clk_reset decl ~:417).
    // Hold the app/write side until role_locked, matching the link/read side (por_reset),
    // so both replay-FIFO reset domains deassert on the same bring-up event and the gray
    // ACK-pointer synchronizer (WlinkGenericFCReplayV2_13.v:54) initializes consistently.
    assign app_clk_reset = ~hresetn | ~role_locked;

    // Lane-mask handshake plumbing.
    //   wlink_*_lane_mask  — local mask, exposed by Wlink as a read-only mirror
    //                        of the swi_*_lane_mask registers. Drives the
    //                        tidelink_autoneg comparator and the master-side
    //                        I2C "send local mask" transaction.
    //   peer_*_lane_mask_w — peer mask captured by the autoneg FSM during the
    //                        handshake; latched into Wlink's LaneMaskPeer
    //                        register at offset 0x218 for SW diagnosis.
    // (wlink_tx/rx_lane_mask declarations moved up beside the SWI_LANE_STATUS
    //  sync regs — the M2 autonomous SYNC-mask drive consumes wlink_rx_lane_mask
    //  in the Region-8/9 write block above; declaration-before-use.)
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
    wire        mst_axil_bvalid;
    wire        mst_axil_bready;
    wire [7:0]  mst_axil_araddr;
    wire        mst_axil_arvalid;
    wire        mst_axil_arready;
    wire [31:0] mst_axil_rdata;
    wire [1:0]  mst_axil_rresp;
    wire        mst_axil_rvalid;
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
                          train_in_progress_w ||
                          // R-B (2026-07-04): the finalize-rendezvous states
                          // drive I2C poll/GO transactions post-lock — same
                          // post-lock bus-ownership requirement as the
                          // training sub-flow (train_in_progress_w) above.
                          // Dedicated level because nego_state_w truncates
                          // 18/19 (ST_FIN_RDV/ST_FIN_GO) to 2/3.
                          fin_rdv_in_progress_w;

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

    tidelink_autoneg #(
        // M1 (2026-07-02): the L4 training-exit predicate retarget
        // (cal_in_hold rendezvous + mask-aware lane checks + byte-3 capture)
        // is V2-ONLY. On V1 cal_in_hold_w is tied 0 below, which would make
        // the autonomous training-exit UNSATISFIABLE, and SWI_LANE_STATUS[26]
        // carries is_long_pkt on a V1 peer — so V1 selects the exact pre-L4
        // predicate (cal_done + ==8'hFF compares, byte 3 ignored).
        // PENDING-DECISION #5: terminal role from strap (default 0 = historical)
        .ROLE_FROM_STRAP    (ROLE_FROM_STRAP),
        .TRAIN_ENTRY_FALLBACK (TRAIN_ENTRY_FALLBACK),
`ifdef TIDELINK_PHY_V2
        .USE_CAL_IN_HOLD    (1'b1)
`else
        .USE_CAL_IN_HOLD    (1'b0)
`endif
    ) u_autoneg (
        .clk                (apb_clk),
        .poresetn           (poresetn),
        .nego_en            (nego_cfg_reg[0]),
        .nego_start         (nego_cfg_reg[1]),
        .nego_pri_sel       (nego_cfg_reg[3:2]),
        .nego_fallback      (nego_cfg_reg[4]),
        .nego_force_lock    (nego_cfg_reg[5]),
        // PENDING-DECISION #5: strap consulted only when ROLE_FROM_STRAP=1
        .role_strap_i       (role_strap_i),
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
        // L4 training-exit-deadlock fix (2026-07-01): "locally parked in
        // S_HOLD" — the reachable rendezvous the ST_TRAIN_POLL_PEER success
        // predicate now waits on (instead of the downstream cal_done, which
        // needs training=0 which needs this exit → the old deadlock).
        .local_cal_in_hold_i       (sync_cal_in_hold_1),
        // R-B finalize peer-gated rendezvous — DORMANT since Loop-13
        // (2026-07-04): ws_fin_wait_lvl is tied 0 on BOTH V1 and V2, so the
        // autoneg's ST_FIN_RDV/ST_FIN_GO entry arc never fires and the whole
        // rendezvous machinery (incl. the fin_retrain_pend_r W1P-latch fix)
        // is compiled but unreachable. Kept wired for the R-B rework.
        .local_fin_wait_i          (ws_fin_wait_lvl),
        // FIX-B (2026-07-07): broadened POLL entry + the captured peer ready bit.
        .local_finalizing_i        (ws_finalizing_lvl),
        .peer_ready_to_serve_o     (peer_ready_to_serve_w),
        .fin_go_o                  (nego_fin_go_w),
        .fin_rdv_in_progress_o     (fin_rdv_in_progress_w),
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

    // =====================================================================
    // FC data-mode handoff sequencer (Phase 7b — autonomous bring-up).
    //
    // PROBLEM (bridge1 silicon 2026-06-29): the autonomous I²C bring-up does
    // role-lock + cal autonomously, but then STALLS at FCSM=SEND_CR (cr=0,
    // crack=0) and never reaches data mode. Root cause: the FCSM's data-mode
    // gate is `swi_enable` (Wlink reg 0x208 bit[0], driven through the
    // WavDemetReset 2-FF sync into io_tx_clk). swi_enable defaults HIGH, so
    // the FCSM leaves reset and enters SEND_CR the instant wlink_por_reset
    // deasserts (= role_locked rises) — which is DURING training, while
    // training_mode=1 and the lanes have not yet locked. It emits CR against
    // training traffic, the peer never returns CR/CRACK, and it wedges in
    // SEND_CR. Nothing re-kicks the LL framer once training completes.
    //
    // The MANUAL recipe fixes this with the LL swreset bootstrap on 0x208:
    //   0x00027f08 (swi_swreset=1) → 0x00027f00 (swi_swreset=0) →
    //   0x00027f07 (swi_enable=1, lltx_enable=1, llrx_enable=1, swreset=0).
    // The swreset pulse re-resets the LL framer AFTER the lanes have locked
    // and training has dropped, so the FCSM restarts the CR exchange against
    // a clean data path and walks to data mode (cr=1 crack=1). The "SYNC-off
    // R8" step in the manual recipe is, on this RTL, the training_mode=0 drop
    // — already performed by the autoneg FSM's ST_TRAIN_EXIT
    // (local_training_mode_clr → swi_training_mode_r=0). (On the V2 base the
    // SYNC re-hunt is autonomous and gated only by training_mode; the
    // swi_sync_* Region-8 bits stay at their defaults on the autonomous path.)
    //
    // FIX: replicate the manual 0x208 bootstrap autonomously. On the FALLING
    // edge of swi_training_mode_r (training just finished — fires symmetrically
    // on master via local_training_mode_clr AND on slave via the I²C-driven
    // APB clear), gated by `nego_en & role_locked` (autonomous path only),
    // inject the three 0x208 writes onto the wl_apb_* mux as synthetic APB
    // transfers. This is the established CDC pattern: the writes land in the
    // Wlink apb_clk-domain swi_* registers exactly as the SW path's writes
    // would, and the swreset crosses to the link domain via Wlink's own
    // WavResetSync (tx/rx_link_clk_reset_wrs) — no new synchroniser needed.
    //
    // SAFETY / additivity:
    //   * Gated on nego_en (= nego_cfg_reg[0]). On the proven SW-role_lock
    //     path (V2 pair_data tests do_role_lock W1S, manual silicon recipe)
    //     nego_cfg_reg=0 ⇒ nego_en=0 ⇒ this sequencer is permanently dormant.
    //     The SW path issues its own 0x208 writes unaffected.
    //   * One-shot per training episode (armed by the falling edge, disarmed
    //     when the burst completes); a later manual/SW recal+train cycle
    //     re-arms it via the next falling edge.
    //   * The injected writes carry swi_swreset=1 in the first step. The
    //     Tier-2 hardening shim in tidelink_top.sv (AND-masks 0x208 bit[3] to
    //     0 on the EXTERNAL apb_pwdata path) is UPSTREAM of this module's
    //     wl_apb_pwdata mux, so it does NOT touch these internally-generated
    //     writes — the swreset pulse reaches Wlink intact, which is exactly
    //     what the handoff needs (the shim's intent was to block buggy SW from
    //     wedging axi2wl; the LL framer swreset here is benign and required).
    // =====================================================================
    // R1 fix (2026-07-02): match the PROVEN manual recipe EXACTLY —
    // 0x27f09 -> 0x27f01 -> 0x27f07 (bit0 HELD 1 through the swreset), not the
    // previous 0x27f08 -> 0x27f00 -> 0x27f07 (bit0 held 0). FCCTRL 0x208 bit0
    // is swi_enable (Wlink.v: swi_enable <= pwdata[0]) = io_app_enable = the
    // FCSM's RUN enable: while 0 the FCSM is forced to state 0
    // (WlinkGenericFCSM_6.v state block: `else if (_fe_rx_ptr_in_T) state<=0`,
    // _fe_rx_ptr_in_T = ~en_ff2_tx_demet) and the FE credit bookkeeping is
    // held cleared (fe_rx_ptr / fe_tx_credit_max / exp_pkt_num), and the
    // replay app_ready/link_valid gates drop. Holding bit0=0 across the
    // bootstrap defers each die's FCSM restart from the (overlap-engineered)
    // swreset-deassert point to its own third write and inserts an extra
    // enable-low credit-clear window; on silicon (skewed triggers, one-shot
    // L6/L7 CR/CRACK min-emission, sticky cr/crack_seen) the peer's fresh
    // credit grant then flies while this die's FCSM is still enable-parked ->
    // credit ring desyncs -> sender wedges fe_rx_is_full=1 with fe_rx_ptr=0
    // (OBS_FC_CREDIT=0xfc01001f). Manually re-running the bootstrap with
    // bit0=1 (0x27f09/0x27f01/0x27f07) CLEARED the wedge on bridge1 — the
    // Bug-C precedent (WlinkGenericFCSM_6.v fe_rx_credit_max comment) already
    // documents that enable dips around the LL-swreset bootstrap wedge credit.
    //
    // Q1 QUIESCE-BEFORE-FINALIZE (2026-07-04, Loop-10 silicon-root-caused;
    // the Loop-8 design review's option B, deferred then). Silicon signature
    // (build c9dd132, deterministic + arm-order-independent): die_a (master)
    // fails its WS_FINALIZE re-anchor — F3 clear fires, lanes 2/5/6 re-latch,
    // lane 7 NEVER (sync_seen=0x64 vs 0xe4) → F4 clear-retries exhaust
    // (0x21B8=0x57000005) → unanchored bootstrap → dead data; die_b converges
    // in both orders. MECHANISM: the re-anchor's periodic-confirm consumes
    // IDLE-GATED beacons from the PEER's TX (WavD2DGpio V2 fork sync gate:
    // insert_en & (force_always | link_tx_tx_idle)); die_b's TX carries a
    // CONTINUOUS slave→master 0x12 keepalive/credit stream (beatcap-proven)
    // that occupies the idle slots once die_b's own force window has closed,
    // and ONE missed SYNC_PERIOD grid slot resets the confirm run
    // (tidelink_lane_deskew_v2 gap_ceil → sync_conf<=0) — die_a STARVES.
    // die_a's own TX is quieter (CR spam only), so die_b re-latches fine.
    // FIX: each die QUIESCES its FC link layer for its own finalize — the
    // winscan FSM raises fch_quiesce_req across WS_FINALIZE/WS_FIN_CLRLOW
    // (Loop-13 2026-07-04: back to the b55cb59 LOCALLY-TIMED rise at
    // WS_FINALIZE entry — the Loop-12 R-B WS_FIN_WAITPEER rendezvous hold
    // regressed b-first on silicon and is dormant) and this sequencer issues
    // the FCH_LL_SWRESET_ON write (0x27f09) ONCE at that entry
    // (fch_quiesced_r latches). swi_swreset resets ONLY the link
    // layer (Wlink.v :2383/:2386/:2392 — tx/rx_link_clk + app reset syncs;
    // lltx/txrouter reset = tx_link_clk_reset_wrs, Wlink.v :2025/:2086); the
    // PHY inserter + deskew are POR-reset-only, so a quiesced die transmits
    // PURE IDLE (WlinkTxLinkLayer io_link_idle = (state==0) & ~auto_in_sop —
    // both reset-true) and its idle-gated beacons fire EVERY grid slot.
    // Both dies' finalizes are sub-ms aligned (FIX-1 episode binding), so the
    // quiet windows overlap by construction; the CONTINUOUS keepalive stream
    // cannot even restart mid-finalize because the peer's credit ring needs
    // this die's (reset) framer. Credits then initialize strictly AFTER the
    // re-anchor — the manual recipe's own ordering. On winscan_done the
    // bootstrap proceeds FROM the swreset-ON state: its own SWRESET_ON step +
    // 0.25 s overlap dwell are SUBSUMED (walk starts at SWRESET_OFF, widx 1);
    // the swreset-HIGH overlap the R4c dwell engineered is now provided by
    // the aligned FINALIZE windows themselves. Armed-path-only (the req is
    // autonomy_armed-gated and V1-tied-0): the manual recipe stays
    // bit-identical. A mid-finalize DISARM parks the winscan (existing arc),
    // drops the req, and the IDLE release arm below writes SWRESET_OFF so a
    // manual takeover never inherits a stuck swreset (R5-zombie interplay).
    localparam [31:0] FCH_LL_SWRESET_ON  = 32'h0002_7f09; // swreset=1, ENABLE HELD 1
    localparam [31:0] FCH_LL_SWRESET_OFF = 32'h0002_7f01; // swreset=0, ENABLE HELD 1
    localparam [31:0] FCH_LL_ENABLE      = 32'h0002_7f07; // swi/lltx/llrx enable
    localparam [12:0] FCH_LL_CTRL_ADDR   = 13'h0208;      // Wlink LL ctrl reg

    // Inter-write settle gap (apb_clk cycles). Two distinct dwells:
    //   * FCH_SWRESET_DWELL — how long swi_swreset is held HIGH (the gap that
    //     follows the SWRESET_ON write). The two dies trigger their handoffs a
    //     few µs apart (the slave on the master's I²C training-clear, the
    //     master on its own ST_TRAIN_EXIT), so a SHORT swreset pulse would let
    //     one die's framer reset, release, and walk past the CR/CRACK exchange
    //     before the peer's framer has even reset — leaving the link half-up
    //     (slave reaches data, master stuck at CR-seen with no inbound CRACK,
    //     mirroring the documented S→M Bug-A signature). Holding swreset HIGH
    //     for a wide window (≈82 µs at 50 MHz apb_clk) makes the two dies'
    //     reset-asserted windows OVERLAP despite the trigger skew, so both
    //     framers leave reset within the same CR/CRACK epoch — exactly the
    //     overlap the SW recipe gets for free by writing both 0x208s in
    //     lockstep. Purely a bring-up dwell; no steady-state impact.
    //   * FCH_GAP_CYCLES — the short settle between SWRESET_OFF and ENABLE
    //     (mirrors the SW recipe's ~20-cycle gap).
    // R4c (2026-07-02): widened 12'd4095 (≈82 µs) → 24'd12_500_000 (≈0.25 s
    // @ 50 MHz). The two dies' fch bootstraps are gated on their LOCAL
    // winscan_done, whose skew is ms-scale (the scans start on each die's own
    // training fall and the per-tap silicon dwell is huge) — an 82 µs swreset
    // window can NEVER overlap across the dies, so the framers left reset in
    // different CR/CRACK epochs (the half-up wedge). The manual recipe holds
    // ~0.2 s; 0.25 s gives huge margin over the ms-scale skew. Sims force
    // tb_fch_dwell_short_q=1 (same idiom as tb_winscan_dwell_short_q) to get
    // the previous, proven-in-sim 4095-cycle dwell.
    localparam [23:0] FCH_SWRESET_DWELL     = 24'd12_500_000; // ≈0.25 s @ 50 MHz
    localparam [23:0] FCH_SWRESET_DWELL_SIM = 24'd4095;       // TB-forced (the old value)
    localparam [23:0] FCH_GAP_CYCLES        = 24'd20;
    reg tb_fch_dwell_short_q = 1'b0;   // RTL-constant 0; cocotb deposits 1
    wire [23:0] fch_swreset_dwell_w =
        tb_fch_dwell_short_q ? FCH_SWRESET_DWELL_SIM : FCH_SWRESET_DWELL;

    // Sequencer phases (per write): SETUP (psel, !penable) → ACCESS
    // (psel, penable, wait pready) → GAP (settle). A 2-bit write-index
    // (fch_widx_r) walks the three 0x208 payloads.
    localparam [1:0] FCH_IDLE   = 2'd0;
    localparam [1:0] FCH_SETUP  = 2'd1;
    localparam [1:0] FCH_ACCESS = 2'd2;
    localparam [1:0] FCH_GAP    = 2'd3;

    localparam [1:0] FCH_N_WRITES = 2'd3;  // three 0x208 writes

    reg [1:0]  fch_state_r;
    reg [1:0]  fch_widx_r;      // which of the three writes (0,1,2)
    reg [23:0] fch_gap_r;       // R4c: widened 12→24 bits for the 0.25 s dwell
    reg [31:0] fch_wdata_r;     // current write payload
    reg        fch_active_r;    // sequencer owns the wl_apb bus this cycle
    reg        fch_penable_r;   // APB access-phase flag
    reg        fch_qmode_r;     // Q1: the in-flight burst is a QUIESCE/RELEASE
                                //     single write (SWRESET_ON at FINALIZE
                                //     entry, or SWRESET_OFF on disarm), NOT
                                //     the three-write bootstrap walk
    reg [19:0] fch_wdog_r;      // FCH_ACCESS watchdog (see FCH_WDOG_LIMIT above)
    // fch_done_r (sticky episode-complete flag) is DECLARED early, next to the
    // autoneg forward decls (~line 1128) — the WINSCAN_OBS readback reads it
    // upstream and `default_nettype none` forbids forward references. It is
    // driven ONLY by this block's FSM below.

    // Slave mode: I2C path active when psel asserted
    wire slv_apb_active = slv_apb_psel && !role_is_master;

    // Bug N2 fix: slv_apb_* drives Wlink only when the address is NOT in
    // the chiplet-controller's register space (Region 4/8). When
    // slv_apb_ctrl_hit is asserted, the AXIL→APB bridge response comes
    // from ctrl_reg_rdata (see slv_apb_bridge_* mux above) and Wlink is
    // not poked, so PSEL must be held low for that case.
    wire slv_apb_to_wlink = slv_apb_active && !slv_apb_ctrl_hit;

    always_comb begin
        if (fch_active_r) begin
            // FC data-mode handoff sequencer owns the Wlink APB bus. Highest
            // priority — it only asserts during the brief autonomous 0x208
            // bootstrap burst (nego_en path), and the external/I²C APB is
            // idle at that point (post-training, pre-data). Drives a normal
            // APB write: psel always, penable in the ACCESS phase.
            wl_apb_psel    = 1'b1;
            wl_apb_paddr   = FCH_LL_CTRL_ADDR;
            wl_apb_penable = fch_penable_r;
            wl_apb_pprot   = 3'b0;
            wl_apb_pstrb   = 4'b1111;
            wl_apb_pwrite  = 1'b1;
            wl_apb_pwdata  = fch_wdata_r;
        end else if (role_is_master) begin
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
`ifdef TIDELINK_PHY_V2
    // S3 PHY swap: the V2 calibrator (always-on FSM) has different state
    // encodings — use its dedicated sweep_active_o output, not a decode.
    wire sweep_active_w;
`else
    wire sweep_active_w = (cal_state_w == 4'd2);
`endif
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

    // AUTONOMOUS lock-threshold (rcp 0x2160 = 0x55555555 -> per-lane thresh 5).
    // The host raises the lane-lock threshold from its POR default 3 to 5 (the
    // marginal-eye robustness knob feeding the lane_checker's lock decision) in
    // rcp() line 93. On the autonomous path NOBODY writes the gpio_phy APB slave
    // reg 0x2160 (a separate tl_apb bus this module cannot reach), so it stays 3.
    // The lock threshold arrives here as `lane_lock_thresh_i` (8 x 3-bit, from
    // tidelink_top's tidelink_gpio_phy_apb_regs). Override it to {8{3'd5}} when
    // nego_en is set — same effect as the host 0x2160=0x55555555 write, without a
    // tl_apb injector. nego_en=0 (manual/SW path) => straight passthrough of the
    // APB-written value, bit-identical.
    // FIX 2 (2026-08-07, TL-001 framing): relax the autonomous per-lane per-cycle
    // Hamming lock threshold 5->6. Root: winscan best_run=0 (no framing passed the
    // Hamming<=5 / LOCK_THRESH gate) -> calibrator falls back to the (0,0) framing
    // lottery. One-step relaxation lets a marginally-over-threshold lane (Hamming 6)
    // accumulate lock-score -> best_run>0 -> with min_lock_dwells=1 (centering ON)
    // the calibrator picks a REAL eye-centre framing, not the lottery fallback. A
    // genuinely-noisy (too-loose) framing is backstopped by link_up/PRBS validation
    // (re-sweeps). nego_en=0 (manual/SW path) unchanged. Measured step, not 3'd7.
    wire [23:0] lane_lock_thresh_eff = nego_en ? {8{3'd6}} : lane_lock_thresh_i;

    tidelink_lane_checker u_lane_checker (
        .clk                 (phy_link_rx_rx_link_clk_w),
        .rst_n               (lane_checker_rst_n_sync_r), // M2: sync'd from role_locked
        .lane_data_i         (phy_link_rx_rx_link_data_w),
        .lock_thresh_i       (lane_lock_thresh_eff),      // autonomous(0x2160=5) | APB regs
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

    // Falling edge of swi_training_mode — the trigger for the FC data-mode
    // handoff sequencer (see the "FC data-mode handoff sequencer" block near
    // the Wlink APB mux). Fires once per training episode on BOTH dies:
    //   * master — when the autoneg FSM's ST_TRAIN_EXIT pulses
    //     local_training_mode_clr (swi_training_mode_r 1→0);
    //   * slave  — when the master's I²C-write of the slave's
    //     SWI_TRAINING_MODE=0 lands via the AXIL→APB bridge (Bug N2 path).
    wire swi_training_mode_fall = ~swi_training_mode_r & swi_training_mode_q;

    // FC handoff arm condition: autonomous path only (nego_en) and the role
    // must already be locked (link is up, lanes locked). On the SW-role_lock
    // path nego_en=0 ⇒ never arms.
    //
    // AUTONOMOUS WINSCAN ORDERING (2026-06-29): the on-chip winscan FSM must
    // run BEFORE the FC handoff (SYNC-detect → winscan → reanchored=1 → handoff
    // → FCSM=4), exactly as the host recipe sequences winscan() then the 0x208
    // bootstrap. The training-mode falling edge is a 1-cycle pulse, and the
    // winscan takes many cycles (per-lane tap sweep), so a bare AND of the fall
    // with winscan_done would miss the arm. Instead LATCH the fall into a sticky
    // "handoff pending" flag, then release the arm the cycle winscan_done is
    // observed high. The winscan FSM itself is kicked off the SAME falling edge
    // (see the winscan FSM block below), so by construction the arm waits out
    // the scan. When WINSCAN_FSM_EN=0 / V1 the gate degenerates to the original
    // (winscan_done tied 1), so the handoff fires on the fall as before.
`ifdef TIDELINK_PHY_V2
    reg  fch_pending_r;
    wire winscan_gate = WINSCAN_FSM_EN ? winscan_done : 1'b1;
    // FIX-1 (2026-07-08): a 1-cycle-delayed registered copy of the winscan
    // block's ws_reanchor_catchup pulse (that combinational net is declared with
    // the winscan FSM, far BELOW this block, and this file is `default_nettype
    // none` = declaration-before-use enforced, so it cannot be referenced here
    // directly). Registered next to the winscan FSM (below) and consumed here as
    // an extra fch_pending_r SET term: the reanchor-catchup completes the FC
    // handoff for a die parked in WS_IDLE with a committed+verified anchor whose
    // armed training fall was dropped (the iter-1 NODONE). The 1-cycle skew is
    // harmless — the WS_IDLE arm raises winscan_done the same cycle catchup
    // fires, so winscan_gate is already open when this set lands.
    reg  ws_reanchor_catchup_q;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            fch_pending_r <= 1'b0;
        else if (autonomy_armed & swi_training_mode_fall)   // LOOP-9: armed-only
            fch_pending_r <= 1'b1;          // latch the (1-cycle) training fall
        else if (autonomy_armed & ws_reanchor_catchup_q)    // FIX-1 (2026-07-08)
            fch_pending_r <= 1'b1;          // reanchor-catchup: no armed training
                                            // fall ever landed, but the committed
                                            // + verified anchor must still hand
                                            // off. winscan_done is already 1 (the
                                            // WS_IDLE catchup arm) so winscan_gate
                                            // is open and this is consumed next
                                            // cycle by fch_arm.
        else if (!autonomy_armed)
            fch_pending_r <= 1'b0;          // LOOP-9: disarm clears a stale
                                            // pending (manual takeover must not
                                            // strand a queued handoff)
        else if (fch_pending_r & winscan_gate)
            fch_pending_r <= 1'b0;          // consumed once the arm fires
    end
    wire fch_arm = fch_pending_r & winscan_gate & autonomy_armed; // LOOP-9
`else
    wire fch_arm = nego_en & role_locked & swi_training_mode_fall;
`endif

    // ── FC data-mode handoff sequencer state machine (apb_clk domain) ──────
    // Replicates the SW recipe's three 0x208 writes
    // (SWRESET_ON → SWRESET_OFF → ENABLE) the first time training drops on
    // the autonomous path. One-shot per training episode (fch_done_r). A
    // subsequent recal+train cycle re-arms via the next falling edge (the
    // arm path clears fch_done_r). Crosses to the link domain through
    // Wlink's own WavResetSync on swi_swreset — no extra synchroniser here.
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            fch_state_r    <= FCH_IDLE;
            fch_widx_r     <= 2'd0;
            fch_gap_r      <= 24'd0;
            fch_wdata_r    <= FCH_LL_SWRESET_ON;
            fch_active_r   <= 1'b0;
            fch_penable_r  <= 1'b0;
            fch_done_r     <= 1'b0;
            fch_qmode_r    <= 1'b0;
            fch_quiesced_r <= 1'b0;
            fch_wdog_r       <= 20'd0;   // SoC Labs FCH APB watchdog
            fch_stall_err_q  <= 1'b0;
            fch_stall_widx_q <= 2'd0;
        end else begin
            case (fch_state_r)
                FCH_IDLE: begin
                    fch_active_r  <= 1'b0;
                    fch_penable_r <= 1'b0;
                    // Arm on the training-mode falling edge (autonomous path),
                    // once per episode. fch_arm re-arms after a fresh
                    // recal+train cycle by clearing the sticky done flag.
                    // Q1 (2026-07-04): when the quiesce already holds the LL
                    // in swreset (fch_quiesced_r — the SWRESET_ON step was
                    // issued at WS_FINALIZE entry, ≥ the whole anchor-gate
                    // window ago), that step AND its R4c 0.25 s overlap dwell
                    // are SUBSUMED: the walk starts at SWRESET_OFF (widx 1).
                    // The cross-die swreset-HIGH overlap the dwell engineered
                    // is provided by the FIX-1-aligned FINALIZE windows.
                    // fch_arm and the two arms below are mutually exclusive
                    // by construction: fch_arm needs winscan_done (WS_DONE),
                    // the quiesce arm needs WS_FINALIZE/WS_FIN_CLRLOW, the
                    // release arm needs !autonomy_armed (fch_arm is
                    // armed-gated on the V2 path).
                    if (fch_arm) begin
                        fch_done_r   <= 1'b0;   // re-run on a fresh episode
                        fch_qmode_r  <= 1'b0;
                        fch_widx_r   <= fch_quiesced_r ? 2'd1 : 2'd0;
                        fch_wdata_r  <= fch_quiesced_r ? FCH_LL_SWRESET_OFF
                                                       : FCH_LL_SWRESET_ON;
                        fch_active_r <= 1'b1;
                        fch_state_r  <= FCH_SETUP;
                    end else if (fch_quiesce_req && !fch_quiesced_r) begin
                        // Q1 QUIESCE: the winscan FSM entered WS_FINALIZE —
                        // park the LL in swreset (single 0x27f09 write) so the
                        // PEER's re-anchor consumes a PURE-IDLE link (beacons
                        // every grid slot). One-shot per quiesce window: the
                        // written swreset LEVEL is the payload; it is held by
                        // the Wlink register itself until the bootstrap (or a
                        // disarm release) writes it back OFF.
                        fch_qmode_r  <= 1'b1;
                        fch_wdata_r  <= FCH_LL_SWRESET_ON;
                        fch_active_r <= 1'b1;
                        fch_state_r  <= FCH_SETUP;
                    end else if (!autonomy_armed && fch_quiesced_r) begin
                        // Q1 DISARM-RELEASE: autonomy dropped (manual
                        // takeover / R5-zombie disarm) while the quiesce held
                        // swreset ON and no bootstrap ran to release it.
                        // Write SWRESET_OFF (0x27f01) so the manual operator
                        // never inherits a stuck LL reset; the manual recipe's
                        // own 0x27f09/01/07 bootstrap remains authoritative
                        // from here (this sequencer goes dormant: fch_arm and
                        // fch_quiesce_req are both armed-gated).
                        fch_qmode_r  <= 1'b1;
                        fch_wdata_r  <= FCH_LL_SWRESET_OFF;
                        fch_active_r <= 1'b1;
                        fch_state_r  <= FCH_SETUP;
                    end
                end

                FCH_SETUP: begin
                    // APB setup phase: psel=1, penable=0 (driven in the mux
                    // from fch_active_r / fch_penable_r). Advance to access.
                    fch_active_r  <= 1'b1;
                    fch_penable_r <= 1'b1;
                    fch_wdog_r    <= 20'd0;   // arm the access watchdog
                    fch_state_r   <= FCH_ACCESS;
                end

                FCH_ACCESS: begin
                    // APB access phase: psel=1, penable=1; complete on pready.
                    fch_active_r  <= 1'b1;
                    fch_penable_r <= 1'b1;
                    // SoC Labs watchdog (f1b3aac): a hung Wlink APB (e.g. the LL
                    // still held in swi_swreset) must NOT pin fch_active_r high,
                    // or the PS's apb_pready is pinned low with it and the whole
                    // 0x2xxx region becomes unreadable for ever. Abort, release
                    // the bus, and latch a sticky, software-visible error.
                    if (!wl_apb_pready && fch_wdog_r != FCH_WDOG_LIMIT)
                        fch_wdog_r <= fch_wdog_r + 20'd1;
                    if (!wl_apb_pready && fch_wdog_r == FCH_WDOG_LIMIT) begin
                        fch_active_r     <= 1'b0;   // RELEASE the APB bus
                        fch_penable_r    <= 1'b0;
                        fch_stall_err_q  <= 1'b1;   // sticky: 0x21BC[0]
                        fch_stall_widx_q <= fch_widx_r;
                        fch_qmode_r      <= 1'b0;
                        fch_state_r      <= FCH_IDLE;
                    end else if (wl_apb_pready) begin
                        fch_penable_r <= 1'b0;
                        if (fch_qmode_r) begin
                            // Q1: single quiesce/release write complete —
                            // park back to IDLE, no dwell (the swreset LEVEL
                            // just written is the payload; for the quiesce
                            // the hold window is WS_FINALIZE itself, closed
                            // by the bootstrap's SWRESET_OFF). wdata bit[3]
                            // (swi_swreset) tracks which level landed:
                            // SWRESET_ON sets fch_quiesced_r, the disarm
                            // release (SWRESET_OFF) clears it.
                            fch_quiesced_r <= fch_wdata_r[3];
                            fch_qmode_r    <= 1'b0;
                            fch_active_r   <= 1'b0;
                            fch_state_r    <= FCH_IDLE;
                        end else begin
                            // Wide dwell after the SWRESET_ON write (widx 0) so
                            // the swi_swreset HIGH window overlaps the peer
                            // die's; short settle after SWRESET_OFF (widx 1).
                            // (Quiesced walks start at widx 1 — no wide dwell.)
                            fch_gap_r   <= (fch_widx_r == 2'd0) ? fch_swreset_dwell_w
                                                                : FCH_GAP_CYCLES;
                            fch_state_r <= FCH_GAP;
                        end
                    end
                end

                FCH_GAP: begin
                    // Inter-write settle gap. Hold the bus (active) but idle
                    // (psel=1, penable=0) so no spurious transfer starts.
                    fch_active_r  <= 1'b1;
                    fch_penable_r <= 1'b0;
                    if (fch_gap_r != 24'd0) begin
                        fch_gap_r <= fch_gap_r - 24'd1;
                    end else if (fch_widx_r == FCH_N_WRITES - 2'd1) begin
                        // Final (ENABLE) write done — burst complete. The
                        // bootstrap walked swreset back OFF (widx 1) before
                        // ENABLE, so any quiesce hold is released (Q1).
                        fch_active_r   <= 1'b0;
                        fch_done_r     <= 1'b1;
                        fch_quiesced_r <= 1'b0;
                        fch_state_r    <= FCH_IDLE;
                    end else begin
                        // Advance to the next 0x208 payload.
                        fch_widx_r  <= fch_widx_r + 2'd1;
                        fch_wdata_r <= (fch_widx_r == 2'd0) ? FCH_LL_SWRESET_OFF
                                                            : FCH_LL_ENABLE;
                        fch_state_r <= FCH_SETUP;
                    end
                end

                default: fch_state_r <= FCH_IDLE;
            endcase
        end
    end

`ifdef TIDELINK_PHY_V2
    // =====================================================================
    // AUTONOMOUS ON-CHIP IDELAY WINSCAN FSM (2026-06-29)
    //
    // The last autonomy layer. On silicon the cross-lane deskew `reanchored`
    // latch (deps/tidelink-phy/rtl/tidelink_lane_deskew.sv, SYNC_REANCHOR_EN=1
    // build) needs all ACTIVE lanes to capture a clean SYNC slice
    // (all_sync_seen). On a marginal eye each active lane has a per-lane
    // optimum RX IDELAY tap; off that tap the lane's SYNC slice carries enough
    // bit errors that sync_hit (Hamming <= SYNC_REANCHOR_TOL=5) never fires,
    // sync_seen_vec stays sparse, reanchored=0, FCSM wedges at 1.
    //
    // The host fixes this with a SOFTWARE winscan loop (fpga/hw_regression/
    // td_v2_hwlib.sh winscan(), ~lines 113-139): per active lane it sweeps the
    // 32 IDELAY taps, samples the per-lane SYNC Hamming distance (SoC 0x21AC,
    // min over 5 reads), and writes the ARGMIN-distance tap. The autoneg path
    // had NO equivalent — so reanchored never latched autonomously.
    //
    // This FSM REPLICATES that host loop on-chip, byte-for-byte in intent:
    //   * force SYNC across the scan  (host R8=0x1C: insert_en+force_always+
    //     robust — driven via winscan_force_sync OR'd into the PHY ports above);
    //   * for each active lane L (swi_sync_lane_mask_r bit set): tap=0..31,
    //     drive ws_phase_offset_r[4L+:4]=tap>>1, ws_phase_lsb_r[L]=tap&1,
    //     DWELL (WINSCAN_DWELL apb_clk cycles — generous; the IDELAYE2 reload +
    //     SYNC re-flood settle, see the param), sample the lane's CDC'd 5-bit
    //     SYNC distance sync_obs_dist_vec_1[5L+:5] min-over-N, track the min;
    //   * write the argmin tap for the lane;
    //   * FINALIZE (F3/F4 2026-07-02): pulse the deskew sticky-anchor CLEAR
    //     (discard scan-era mid-scan commits), keep force-SYNC so the
    //     re-confirm sees on-grid beacons at the FINAL taps, hold winscan_done
    //     until the CDC'd `reanchored` reads 1 (fail-loud timeout), THEN drop
    //     force (host R8=0x14) and raise winscan_done → the FC handoff (gated
    //     above) runs idle-gated and walks to FCSM=4.
    //
    // GATING / additivity: the FSM only RUNS / owns the taps when ARMED via the
    // autonomous nego path (WINSCAN_FSM_EN & nego_en & role_locked). On the
    // proven SW-role_lock + host-winscan path nego_en=0 ⇒ winscan_owns_taps and
    // winscan_force_sync stay 0, the tap regs hold their APB-written values, and
    // the SYNC controls keep their strap values — the SW data regression and the
    // host winscan() are UNAFFECTED (bit-identical datapath).
    // =====================================================================
    localparam [3:0] WS_IDLE            = 4'd0;  // dormant; wait for the arm kick
    localparam [3:0] WS_ARM             = 4'd1;  // force SYNC, seed taps
    localparam [3:0] WS_NEXT_LANE_ENTER = 4'd2;  // per-lane entry / mask skip
    localparam [3:0] WS_SETTLE          = 4'd3;  // dwell at the current tap
    localparam [3:0] WS_SAMPLE          = 4'd4;  // N min-over samples of SYNC_DIST
    localparam [3:0] WS_NEXT_TAP        = 4'd5;  // argmin, advance tap
    localparam [3:0] WS_PICK            = 4'd6;  // write best tap for the lane
    localparam [3:0] WS_FINALIZE        = 4'd7;  // drop force-SYNC, settle reanchor
    localparam [3:0] WS_DONE            = 4'd8;  // winscan_done held; per-episode
    localparam [3:0] WS_FIN_CLRLOW      = 4'd9;  // FIX-3: anchor-retry — hold the
                                                 // F3 clear LOW so the destination
                                                 // edge-detect re-arms, then re-pulse
    localparam [3:0] WS_FIN_WAITPEER    = 4'd10; // R-B peer-rendezvous hold —
                                                 // DORMANT (Loop-13 2026-07-04):
                                                 // encoding RESERVED, state never
                                                 // entered (the Loop-12 aligned
                                                 // rendezvous regressed b-first
                                                 // on silicon; finalize is
                                                 // locally timed again, exact
                                                 // b55cb59 semantics)

    localparam int WINSCAN_NSAMP   = 5;          // host min-over-5
    // F3b/F4 RENDEZVOUS (2026-07-02): WINSCAN_FIN_WAIT widened 4096 (82 µs) →
    // ≈0.5 s. Each die's post-clear re-anchor needs the PEER to be beaconing
    // ON-GRID (forced) during its own WS_FINALIZE — and the peer forces only
    // through its OWN scan+FINALIZE, whose start is skewed by the cross-die
    // training-clear latency (the master's I2C write of the slave's
    // SWI_TRAINING_MODE=0: ~650 µs even in sim, ms-scale on silicon). With an
    // 82 µs dwell the FASTER die's force window closed before the SLOWER
    // die's FINALIZE opened → the slower die's re-confirm starved → F4
    // timeout (sim-proven: test_31 slave anchored=0/timeout=1). 0.5 s makes
    // the two dies' force-held FINALIZE windows overlap despite the skew —
    // the same overlap rationale as the R4c 0.25 s fch swreset dwell (the F2
    // SYNC-OFF settle that shared it is retired — D2). Sim: the existing tb_winscan_dwell_short_q
    // hook selects WINSCAN_FIN_WAIT_SIM = 100k (2 ms — 3x the observed sim
    // I2C skew).
    localparam int WINSCAN_FIN_WAIT     = 25_000_000; // ≈0.5 s @ 50 MHz
    localparam int WINSCAN_FIN_WAIT_SIM = 100_000;    // TB-forced (covers sim skew)
    // R2 sample-integrity (2026-07-02):
    //   * WINSCAN_SAMP_SPACE — inter-sample spacing (apb_clk cycles) between
    //     the 5 ACCEPTED min-over samples, so they are independent
    //     observations (the old 5 back-to-back reads, ~100 ns apart, were ~one
    //     observation — min-over-5 was vestigial vs the host's round-trip-
    //     spaced reads). A few hundred cycles rides the existing ws_dwell_r
    //     counter; sim uses a short spacing via the same dwell-short hook.
    //   * WINSCAN_QUAL_TIMEOUT — per-sample bound on the two-equal-reads
    //     tear-rejection qualifier: if the CDC'd metric genuinely never reads
    //     equal twice (pathologically toggling lane), accept the raw read
    //     rather than wedge WS_SAMPLE forever (winscan_done gates the FC
    //     handoff — a scan hang would deadlock the autonomous bring-up).
    localparam int WINSCAN_SAMP_SPACE     = 512;
    localparam int WINSCAN_SAMP_SPACE_SIM = 8;
    localparam [7:0] WINSCAN_QUAL_TIMEOUT = 8'd255;
    // F4 (2026-07-02) — WS_FINALIZE ANCHOR GATE. winscan_done (and hence the
    // fch_pending_r handoff release) is HELD until the CDC'd deskew
    // `reanchored` status (obs_epoch_anchored_o — the same net that feeds
    // R_REANCHORED / EPOCH_STATUS 0x4403_2140 bit0 and epoch_anchored_o) reads
    // 1: the on-chip equivalent of the manual host's reanchored poll before it
    // runs the 0x208 bootstrap — the handoff is strictly ordered after a
    // SETTLED anchor. FAIL-LOUD timeout: if the anchor never latches (dead
    // sync_obs_clr routing / genuinely un-anchorable eye) then, after the
    // FIX-3 bounded clear-retries below, release anyway — a never-done winscan
    // would DEADLOCK the handoff with no retry path — and latch the sticky
    // ws_anchor_timeout_q into WINSCAN_OBS 0x21B8[2].
    localparam [23:0] WS_ANCHOR_TIMEOUT     = 24'd15_000_000; // ≈0.3 s @ 50 MHz
    localparam [23:0] WS_ANCHOR_TIMEOUT_SIM = 24'd50_000;     // TB-forced bound
    // FIX-3 (2026-07-03) — BOUNDED CLEAR-RETRY on anchor timeout. Instead of
    // fail-OPEN on the first timeout, re-pulse the F3 clear and re-wait, up to
    // 3 attempts, THEN fail open with the sticky 0x21B8[2] as before. With
    // FIX-2 (beacons never dark: the peer's idle-gated SYNC-insert is now
    // PERMANENT data-mode state) a retry is meaningful — the anchor can latch
    // as soon as the peer's beacons reach the grid, whenever that is. The
    // clear must be RE-PULSED because the destination is a 2-FF level sync +
    // edge-detect in the link clock: WS_FIN_CLRLOW holds the level LOW for
    // WS_CLR_HOLD apb cycles (>> the slowest link-clock 2-FF window: 4096 apb
    // @50 MHz = 512 link cycles at the ASIC 6.25 MHz word clock) so the next
    // rise is a fresh clear pulse.
    localparam [23:0] WS_CLR_HOLD     = 24'd4096;
    localparam [23:0] WS_CLR_HOLD_SIM = 24'd512;
    // R-A (2026-07-04): retry budget 3 -> 5. The anchor gate now ALSO
    // requires the zero-tolerance ANCHOR-VERIFY (ws_verify_q), and a
    // wrong-slot mis-anchor burns one full WS_ANCHOR_TIMEOUT window per
    // mis-latch before its retry — 5 keeps the fail-open bound ~1.8 s worst
    // case while giving a marginal lane multiple independent re-latch rolls.
    localparam [2:0]  WS_ANCHOR_RETRIES = 3'd5;
    // AUTONOMY-LEVER (2026-07-10) — SOFT-EXTEND the FIRST anchor-gate window.
    //
    // ROOT CAUSE (verified this session, RTL identity): the deskew sets a
    // per-lane STICKY sync_seen_l only after SYNC_CONFIRM(=2) CONSECUTIVE
    // periodic SYNC-beacon matches (tidelink_lane_deskew_v2.sv:606/707/748/767),
    // and the read-side `reanchored` latches ONLY when EVERY active lane's
    // sticky bit is set within ONE clear-to-clear window (all_sync_seen,
    // :1350/1489). The window = time between clr_pulses; the winscan drives the
    // clear via ws_obs_clr_r (F3) held HIGH across WS_FINALIZE — ONE clr_pulse
    // per WS_FINALIZE entry — and each FIX-3 retry (WS_FIN_CLRLOW) RE-PULSES it,
    // so the retry budget RESTARTS accumulation instead of accumulating. On a
    // MARGINAL (not dead) lane that Hamming-matches only a FRACTION of beacon
    // slots, catching 2 CONSECUTIVE beacons before the clear is a lottery
    // (P ~ p^2 per attempt); the FIX-4 jittered retries decorrelate the PHASE
    // but each still restarts from scratch (soak: die_a 15% / die_b 45% clean-OK).
    //
    // LEVER: give the FIRST accumulation window (the longest, uninterrupted one)
    // WS_ANCHOR_EXTEND extra WS_ANCHOR_TIMEOUT reloads WITHOUT re-pulsing the F3
    // clear (ws_obs_clr_r stays HIGH -> NO new clr_pulse -> the sticky vector is
    // NOT cleared -> accumulation is CONTINUOUS). Window-1 becomes
    // (WS_ANCHOR_EXTEND+1) x WS_ANCHOR_TIMEOUT ~= 8 x 0.3 s = 2.4 s of
    // uninterrupted beacon opportunities — many more independent
    // 2-consecutive-beacon rolls for a marginal lane — BEFORE the jittered
    // clear-retries (unchanged) begin. A die that anchors early STILL releases
    // immediately (the ws_anchor_q && ws_verify_q poll precedes this branch), so
    // no clean-die latency penalty; only a struggling die spends the extra time.
    // The zero-tolerance ANCHOR-VERIFY (VERIFY_TOL=3, WavD2DGpio_v2.v:1139)
    // remains the backstop: a wrong-slot / temporally-misaligned accumulation
    // can never satisfy the cross-lane simultaneous match, so a longer window
    // cannot ship a bad anchor — worst case it fails open LATER (bound +~2.4 s).
    // A/B: WS_ANCHOR_EXTEND=0 restores the exact pre-lever behaviour. Sim gates
    // the extend to 0 via tb_ws_anchor_short_q (the same hook that shortens the
    // anchor timeout), so all sim suites are BIT-IDENTICAL to baseline.
    localparam [2:0]  WS_ANCHOR_EXTEND = 3'd0;   // consolidation 2026-07-15: lever OFF (baseline); the soft-extend is unproven/build-dependent (David). 3'd7 = lever ON.
    // FIX-D (2026-07-07): VERIFY-STUCK detector threshold (apb cycles the anchor
    // may sit latched with the verify low before ws_verify_stuck_q latches).
    // Sized WELL above any healthy anchor→verify settle skew (the F3 clear drops
    // both together, and the metric CDC re-latches them within a few cycles) yet
    // WELL below both anchor windows (WS_ANCHOR_TIMEOUT_SIM 50k / silicon 15M),
    // so it only latches on a genuine mis-anchor that verify can never confirm.
    localparam [15:0] WS_VFY_STUCK_N = 16'd4096;
    // FIX-4 (2026-07-04) — DECORRELATED RETRIES (retry-jitter LFSR).
    //
    // Silicon evidence: 8 zero-poke rolls across 4 builds show the FINALIZE
    // anchor re-latch is a PER-BRING-UP LOTTERY — ~coin-flip per die per
    // roll, loser varying randomly (die_a / die_b / both / nobody, no
    // order/die correlation), and EVERY failure reads 0x21B8[2]=1 with all 5
    // FIX-3 retries burned invisibly. If the 5 windows were INDEPENDENT
    // ~50% rolls the budget would compound to >90% per die (1-0.5^6) — the
    // observed ~50% per-roll rate means the retries are CORRELATED: they
    // re-fail identically.
    //
    // Root of the correlation: every FIX-3 retry is DETERMINISTICALLY timed.
    // The inter-attempt dwell is the compile-time constant WS_CLR_HOLD =
    // 4096 apb cycles — at the ASIC 8:1 apb:word ratio that is EXACTLY 512
    // word clocks = EXACTLY 16 SYNC_PERIODs (SYNC_PERIOD=32): the hold
    // contributes ZERO phase shift vs the SYNC grid, and the full attempt
    // pitch (WS_ANCHOR_TIMEOUT + WS_CLR_HOLD + 2 transition cycles) is the
    // same constant for every attempt, every roll, both dies. Against a
    // STATIC repeating within-tol alias in the peer's traffic (the c07f948
    // mutual-starvation analysis: a repeating pattern that permanently
    // blocks a marginal lane's confirm run), all 5 windows sample a
    // lock-stepped phase sequence — retry N fails exactly like retry N-1.
    //
    // Fix: JITTER the inter-attempt dwell. A free-running 16-bit LFSR
    // (apb_clk, POR seed 16'hACE1, never gated) is whitened by XOR-folding
    // the CDC'd per-lane SYNC-distance vector into its feedback — a live
    // rx-link-clk-domain observable sampled across a plesiochronous
    // boundary, so the value read at a retry instant is NOT a pure function
    // of POR time (per the decorrelation requirement: entropy from the lane
    // dist bits, no Date-like constructs). Each retry arc extends the
    // WS_FIN_CLRLOW hold by ws_jitter_w:
    //   silicon: 2048 + 8*lfsr[11:0] apb cycles = 256..4351 word clocks
    //            @8:1 — a few hundred to a few thousand word-clocks, in
    //            1-word steps: fine-grained vs the 32-word SYNC grid and
    //            spanning many grid periods, so consecutive attempts land
    //            at genuinely different phases vs SYNC_PERIOD and vs the
    //            peer's traffic pattern;
    //   sim:     64 + lfsr[8:0] cycles (floor > 0 so the t33 gate can
    //            assert the jitter term is live in the dwell path).
    // Cost: <= 5 x 0.74 ms added to the ~1.8 s worst-case fail-open bound.
    // Fail-open semantics on final-attempt exhaustion are UNCHANGED (sticky
    // 0x21B8[2], release anyway). Attempt count observable at 0x21B8[13:11]
    // (ws_retry_cnt_q) — the statistic that validates the compounding model
    // on silicon.
    // R-B ASYMMETRIC PEER-SERVE (2026-07-07): WS_FIN_WAITPEER peer-rendezvous
    // timeout — RE-ARMED (was dormant since Loop-13). Only die_a (MASTER) parks
    // in WS_FIN_WAITPEER and runs the rendezvous; die_b (SLAVE) holds its
    // already-good anchor and SERVES idle-gated beacons for this bounded window
    // (ws_serve_to_r loads the same value). FAIL-LOUD: on master expiry the
    // finalize proceeds LOCALLY (exact b55cb59 semantics) with ws_rdv_timeout_q
    // (0x21B8[10]) latched — never deadlocks on a dead/V1/zombie peer. The
    // slave's serve is time-bounded by the same countdown so a lost master GO
    // cannot park die_b in swreset forever. Sim value rides
    // tb_winscan_dwell_short_q and must exceed the sim I2C rendezvous latency.
    localparam [28:0] WS_RDV_TIMEOUT     = 29'd500_000_000; // ~=10 s @ 50 MHz
    localparam [28:0] WS_RDV_TIMEOUT_SIM = 29'd400_000;     // TB-forced bound
    // Sim dwell shrink (TB-forced, same idiom as the calibrator's
    // tb_early_exit_force_q). Default 0 = use the generous silicon WINSCAN_DWELL.
    reg tb_winscan_dwell_short_q = 1'b0;
    localparam int WINSCAN_DWELL_SIM = 32;       // sim: IDELAY passthrough, SYNC
                                                 //      floods every beat
    // Dwell counter must hold the larger of the two dwell choices.
    // F3b: the dwell counter must also hold the widened FINALIZE waits.
    localparam int WS_DW_MAX0 = (WINSCAN_DWELL > WINSCAN_DWELL_SIM)
                                 ? WINSCAN_DWELL : WINSCAN_DWELL_SIM;
    localparam int WS_DW_MAX  = (WS_DW_MAX0 > WINSCAN_FIN_WAIT)
                                 ? WS_DW_MAX0 : WINSCAN_FIN_WAIT;
    localparam int WS_DW_W   = $clog2(WS_DW_MAX + 1);

    // ws_state_r is declared EARLY (with the FIX-D obs regs, ~line 1310) so the
    // Region-D read mux (0x21B8[23:20], which precedes this FSM block in the
    // file) can reference it — VCS requires declaration-before-use.
    reg [3:0]          ws_lane_r;        // current lane index 0..7 (then 8 = end)
    reg [5:0]          ws_tap_r;         // current tap 0..31 (6b for the ==32 test)
    reg [2:0]          ws_nsamp_r;       // sample countdown
    reg [4:0]          ws_dist_min_r;    // min-over-N distance at this tap
    reg [4:0]          ws_best_dist_r;   // best (lowest) distance for this lane
    reg [5:0]          ws_best_tap_r;    // argmin tap for this lane
    reg [WS_DW_W-1:0]  ws_dwell_r;       // dwell countdown
    reg                ws_kicked_q;      // sticky: armed for this nego episode
    // R2 sample-integrity state (2026-07-02):
    reg [4:0]          ws_dist_prev_r;      // previous read of the CDC'd dist
    reg                ws_dist_pair_valid_q;// prev read is live (pair armed)
    reg [7:0]          ws_qual_to_r;        // per-sample qualification timeout
    // R2c degenerate-scan trackers:
    reg [4:0]          ws_lane_first_r;     // this lane's tap-0 min distance
    reg                ws_lane_flat_q;      // this lane's metric flat so far
    reg                ws_all_flat_q;       // every scanned lane flat so far
    reg                ws_any_scanned_q;    // >=1 active lane actually scanned
    // F3/F4 (2026-07-02) state:
    reg                ws_obs_clr_r;        // F3: level driven HIGH across
                                            //     WS_FINALIZE, OR'd into the
                                            //     swi_sync_obs_clr_in Wlink port
    reg [23:0]         ws_anchor_to_r;      // F4: anchor-gate timeout countdown
    reg [2:0]          ws_anchor_retry_r;   // FIX-3: clear-retries remaining (R-A: widened 2->3b, budget 5)
    reg [2:0]          ws_anchor_ext_r;     // AUTONOMY-LEVER: window-1 soft-extends remaining (no re-clear)
    reg [28:0]         ws_rdv_to_r;         // R-B: master peer-rendezvous timeout countdown (WS_FIN_WAITPEER)
    reg tb_ws_anchor_short_q = 1'b0;        // F4 sim hook (cocotb deposits 1)
    wire [23:0] ws_anchor_to_load =
        tb_ws_anchor_short_q ? WS_ANCHOR_TIMEOUT_SIM : WS_ANCHOR_TIMEOUT;
    // AUTONOMY-LEVER: the window-1 soft-extend count. Gated to 0 in sim by the
    // SAME hook that shortens the anchor timeout, so every sim suite that
    // reaches WS_FINALIZE is bit-identical to the pre-lever baseline; silicon
    // gets the full WS_ANCHOR_EXTEND uninterrupted-window widen.
    wire [2:0]  ws_anchor_ext_load =
        tb_ws_anchor_short_q ? 3'd0 : WS_ANCHOR_EXTEND;
    // FIX-3: the clear-low hold reuses the winscan sim hook (short in sim).
    wire [23:0] ws_clr_hold_load =
        tb_winscan_dwell_short_q ? WS_CLR_HOLD_SIM : WS_CLR_HOLD;
    // R-B: the master rendezvous timeout AND the slave serve window both reuse
    // the same sim hook (short in sim), keeping the two dies' bounded windows
    // co-scaled.
    wire [28:0] ws_rdv_to_load =
        tb_winscan_dwell_short_q ? WS_RDV_TIMEOUT_SIM : WS_RDV_TIMEOUT;
    // FIX-4 (2026-07-04): free-running retry-jitter LFSR — see the FIX-4
    // block above the WS_ANCHOR_RETRIES localparam for the full rationale.
    // 16-bit maximal Fibonacci LFSR (taps x^16+x^14+x^13+x^11), whitened by
    // XOR-folding the CDC'd 40-bit per-lane SYNC-distance vector into the
    // feedback (rx-link-clk sampling noise across the plesiochronous 2-FF
    // boundary — real per-bring-up entropy; with the fold-in a transient
    // all-zeros word cannot lock the register up, and the nonzero POR seed
    // covers the fold-in reading constant 0, e.g. under the t33 forced-0
    // dist model). Runs from POR, never gated — the value sampled at a
    // retry instant has advanced ~15M steps since the previous attempt.
    reg  [15:0] ws_jitter_lfsr_r;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            ws_jitter_lfsr_r <= 16'hACE1;
        else
            ws_jitter_lfsr_r <= {ws_jitter_lfsr_r[14:0],
                                 ws_jitter_lfsr_r[15] ^ ws_jitter_lfsr_r[13]
                               ^ ws_jitter_lfsr_r[12] ^ ws_jitter_lfsr_r[10]
                               ^ (^sync_obs_dist_vec_1)};
    end
    // Per-retry inter-attempt dwell extension (added to ws_clr_hold_load at
    // the FIX-3 retry arc). Silicon: 2048..34808 apb cycles in steps of 8
    // (= 256..4351 word clocks @ the ASIC 8:1 ratio, 1-word granularity vs
    // the 32-word SYNC grid). Sim (dwell-short hook): 64..575 cycles — the
    // nonzero floor lets t33e assert the jitter is live in the dwell path.
    wire [23:0] ws_jitter_w =
        tb_winscan_dwell_short_q
            ? (24'd64   + {15'd0, ws_jitter_lfsr_r[8:0]})
            : (24'd2048 + {9'd0,  ws_jitter_lfsr_r[11:0], 3'b000});
    // F4: 2-flop apb_clk sync of the deskew read-side `reanchored` latch.
    // obs_epoch_anchored_o is the rx-link-clk-domain pass-through from Wlink
    // (u_deskew reanchored → WavD2DGpio epoch_anchored → WlinkGPIOPHY →
    // Wlink.obs_epoch_anchored_o) — the same net EPOCH_STATUS 0x2140 bit0 /
    // epoch_anchored_o expose. Single bit ⇒ a plain 2-FF sync is sufficient.
    reg ws_anchor_meta_q, ws_anchor_q;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_anchor_meta_q <= 1'b0;
            ws_anchor_q      <= 1'b0;
        end else begin
            ws_anchor_meta_q <= obs_epoch_anchored_o;
            ws_anchor_q      <= ws_anchor_meta_q;
        end
    end

    // R-A (2026-07-04): 2-FF apb_clk sync of the WavD2DGpio_v2 anchor-verify
    // sticky (obs_anchor_verified_w — rx-link-clk domain, POR/F3-clear reset;
    // single bit, same CDC treatment as ws_anchor_q above). The WS_FINALIZE
    // release gate requires ws_anchor_q AND ws_verify_q: `reanchored` proves
    // all active lanes COMMITTED an anchor; the verify proves the committed
    // anchor reproduces the KNOWN beacon content EXACTLY on one beat — a
    // lane whose sticky sync_idx latched one slot off (tol-5 Hamming on a
    // marginal eye can match an adjacent slot) passes the first and can
    // never pass the second.
    reg ws_verify_meta_q, ws_verify_q;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_verify_meta_q <= 1'b0;
            ws_verify_q      <= 1'b0;
        end else begin
            ws_verify_meta_q <= obs_anchor_verified_w;
            ws_verify_q      <= ws_verify_meta_q;
        end
    end

    // R-B FINALIZE_GO capture — the peer master's I2C write of Region 8
    // slot 7 (0x211C bit[0], W1P) lands here via the slave AXIL bridge
    // (region8_write covers both the external APB and the I2C-slave paths).
    // R-B ASYMMETRIC PEER-SERVE (2026-07-07): RE-ARMED. On the SLAVE this GO
    // arms the serve engine (ws_serve_active_r) below — die_b quiesces and
    // serves idle beacons for the master's re-confirm. STICKY so the go
    // survives the CDC/poll skew between the master's write completing and this
    // die sampling it. Cleared on: a training rise (a new episode invalidates a
    // stale go), OR the serve window closing (ws_serve_active_r falling — so
    // the consumed go cannot immediately re-arm the serve).
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            ws_fin_go_reg_q <= 1'b0;
        else if (swi_training_mode_rise)
            ws_fin_go_reg_q <= 1'b0;
        else if (ws_serve_active_d & ~ws_serve_active_r)
            ws_fin_go_reg_q <= 1'b0;   // serve window closed — clear consumed go
        else if (region8_write && (ctrl_reg_addr[2:0] == 3'h7)
                 && ctrl_reg_wdata[0])
            ws_fin_go_reg_q <= 1'b1;
    end

    // R-B ASYMMETRIC PEER-SERVE (2026-07-07) — SLAVE serve engine (apb_clk).
    // Only the SLAVE (die_b) runs this. Once its OWN winscan is done (its
    // deskew anchor is already good and HELD), the master's FINALIZE_GO
    // (ws_fin_go_reg_q) arms a bounded serve window in which die_b FORCES SYNC
    // every grid slot toward the master (ws_serve_active_r is OR'd into the PHY
    // SYNC-insert force ports) — beating the keepalive that was occupying its
    // idle slots (the beacon-starvation fix: die_a re-confirms over these
    // forced beacons in its WS_FIN_WAITPEER Phase-2). CRUCIALLY the FC is NOT
    // quiesced: die_b's FC stays UP (RX live) so it still receives the master's
    // credit and reaches fcsm=4 — a serve quiesce would SWRESET the FC and
    // deadlock it at fcsm=2 (never receives the master's credit). The window is
    // time-bounded (ws_serve_to_r = ws_anchor_to_load, the master re-anchors
    // well within it); on expiry the force drops and its FC TX resumes. The
    // consumed go is cleared on the fall (above); the ~ws_serve_active_d
    // arm-guard blocks an immediate re-arm on the fall cycle.
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_serve_active_r <= 1'b0;
            ws_serve_active_d <= 1'b0;
            ws_serve_to_r     <= 29'd0;
            ws_serve_cnt_q    <= 2'd0;
        end else begin
            ws_serve_active_d <= ws_serve_active_r;
            // FIX-D obs (2026-07-07): count SLAVE serve engagements per episode
            // (2-bit saturating). Rising edge of ws_serve_active_r = one serve.
            // A count >1 flags the die_b RE-SERVE THRASH the livelock drove (each
            // WS_FINALIZE re-entry re-issued the serve GO). Cleared per episode.
            if (swi_training_mode_rise)
                ws_serve_cnt_q <= 2'd0;
            else if (ws_serve_active_r & ~ws_serve_active_d)
                ws_serve_cnt_q <= (ws_serve_cnt_q == 2'd3) ? 2'd3
                                                           : ws_serve_cnt_q + 2'd1;
            if (swi_training_mode_rise) begin
                ws_serve_active_r <= 1'b0;      // fresh episode drops any serve
            end else if (!ws_serve_active_r) begin
                if (autonomy_armed & ~role_is_master & winscan_done
                    & ws_fin_go_reg_q & ~ws_serve_active_d) begin
                    ws_serve_active_r <= 1'b1;
                    // Serve only as long as the master needs to re-confirm
                    // AFTER the GO — bounded by the anchor-gate window
                    // (ws_anchor_to_load, 0.3 s silicon / 50k sim), NOT the
                    // master's much longer wait-for-GO patience (ws_rdv_to_r).
                    // The master's Phase-2 re-anchor either latches well within
                    // this window or times out at its end; either way die_b can
                    // stop serving and re-bootstrap its FC then, minimising the
                    // slave's data-path downtime.
                    ws_serve_to_r     <= {5'd0, ws_anchor_to_load};
                end
            end else begin
                if (ws_serve_to_r == 29'd0)
                    ws_serve_active_r <= 1'b0;  // window closed — release + rebootstrap
                else
                    ws_serve_to_r <= ws_serve_to_r - 29'd1;
            end
        end
    end

    // FIX-3 obs (2026-07-03) — "anchored-late" sticky (WINSCAN_OBS 0x21B8[3]):
    // a ws_anchor_q RISE observed while fch_done_r is already set means the
    // deskew re-anchor completed only AFTER the FC handoff had bootstrapped —
    // i.e. the episode failed open (0x21B8[2]) and the permanent idle-gated
    // beacons (FIX-2) healed the anchor late. On silicon this discriminates
    // "anchor eventually fine, handoff mis-ordered" from "anchor never".
    // Cleared on a fresh scan episode (WS_ARM), like the other stickies.
    reg ws_anchor_q_d;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_anchor_q_d    <= 1'b0;
            ws_anchor_late_q <= 1'b0;
        end else begin
            ws_anchor_q_d <= ws_anchor_q;
            if (ws_state_r == WS_ARM)
                ws_anchor_late_q <= 1'b0;
            else if (ws_anchor_q & ~ws_anchor_q_d & fch_done_r)
                ws_anchor_late_q <= 1'b1;
        end
    end

    // ========================================================================
    // EVENT-GATED AUTONOMY RETIRE (2026-07-15) — THE B->A autonomy channel fix.
    //
    // MECHANISM. On silicon the B->A corruptor is the AUTONOMOUS FORCED-SYNC
    // chain (winscan_force_sync / ws_serve_active_r), which ORs into the Wlink
    // insert_en+force_always+robust ports (:~5924) and keeps SYNC beating over
    // the B->A payload on the receiver (die_a), so its RX framer never commits.
    // The proven on-silicon escape hatch is `0x210C=0` (clear train_auto_en =>
    // autonomy_armed=0 => the FSM's LOOP-9 DISARM-PARK arc :~4640 drops
    // winscan_force_sync within a cycle => the forced beacons stop => B->A
    // commits). td_b2a_diag2.log: B->A recovered byte-exact the instant die_a's
    // autonomy_armed dropped — with R8 STILL 0x14 (insert_en=1) and rea=0 — so
    // insert_en/R8[2] is NOT the blocker (it is a pure TX control and, with the
    // 0044bef drain guard + postcount pinned, fires no steady-state beacon);
    // autonomy_armed is. This block makes the die perform that escape hatch
    // ITSELF, once, when the link is provably up.
    //
    // TRIGGER — the B->A-dead armed state is a WINSCAN LIVELOCK, silicon-
    // confirmed on a clean fresh-POR exclusively-leased bench (reproduced twice,
    // td_b2a_diag2/3): die_a churns ws_state 3(SETTLE)<->7(FINALIZE);
    // winscan_done NEVER holds 1 (only BLIPS at a fail-open WS_DONE while
    // fcsm has already collapsed to 0), and advancing to FINALIZE TEARS DOWN the
    // FC (fcsm 4->0). So a winscan_done-gated retire is INERT on silicon. But
    // `reanchored && fcsm==4` HELD STABLY for ~2.8 s in the initial window
    // BEFORE the churn. Retiring in that window PARKS the FSM (DISARM-PARK) and
    // locks in the good anchor before the churn destroys the FC.
    //
    // WHY TWO BRANCHES (mutual-readiness is the crux). Retiring the MASTER stops
    // its forced beacons; if the SLAVE is not yet up, its FC bootstrap (which
    // needs those beacons to keep its RX aligned) STALLS — a peer-starvation.
    // On SILICON this is a non-issue: the dead-B->A state is a STEADY state,
    // die_b is long up before die_a churns, so a short reanchored dwell is safe.
    // In the SHORT sim it is NOT: die_a (master) races to fcsm=4 while die_b is
    // still at fcsm=2, and its `rea && fcsm==4` is STABLE there (verified: a
    // local-only reanchored timer, sticky OR reset-on-drop, fired mid-handoff
    // and starved the slave, t31 FAIL x2). The only MUTUAL "both dies up" signal
    // the sim TB models is winscan_done (the FSM rendezvous completes only when
    // both anchor). So:
    //   * BRANCH 1 (SIM correctness): winscan_done && rea && fcsm==4, held a
    //     SHORT dwell. Fires only after the rendezvous => both up => no
    //     starvation. This is the exact trigger that passed the whole sim gate.
    //     It is INERT on silicon (winscan_done never coincides with fcsm==4).
    //   * BRANCH 2 (SILICON path, the coordinator's reanchored trigger):
    //     rea && fcsm==4 held for a LONG dwell (RETIRE_DWELL_SI, << the ~2.8 s
    //     churn). Fires on silicon where winscan_done is dead; die_b is already
    //     up so it is starvation-safe. Its dwell is deliberately LARGER than the
    //     whole sim runtime, so it CANNOT fire before branch 1 in sim (=> no sim
    //     starvation) — the silicon reanchored path is thus not directly
    //     exercised by the short sim (same limitation the coordinator noted:
    //     sim cannot prove the B->A recovery, only that retire fires + no-
    //     regression). On silicon the ~2.8 s stable window >> RETIRE_DWELL_SI so
    //     it accumulates well before the churn.
    //
    // PER-EPISODE ONE-SHOT (re-armed on a training rise). A permanent
    // autonomy_armed=0 would spring the FSM's ws_kicked_q RE-SCAN TRAP (the
    // winscan cannot re-kick until POR) AND starve a peer that later RETRAINS.
    // So we CLEAR the latches on swi_training_mode_rise (a fresh training episode
    // = a legitimate re-scan): the forced-SYNC chain is re-enabled for the new
    // scan, and retire re-fires once the fresh episode restabilises.
    // swi_training_mode_rise also clears ws_kicked_q (:~4614), so the master
    // genuinely re-kicks. In STEADY data mode there is no training rise, so
    // retire holds and the beacons stay off (the B->A fix).
    //
    // NO-REGRESSION: DISARM-PARK sets ws_obs_clr_r=0 => it issues NO obs-clear,
    // so the deskew reanchored is NOT dropped; and retire touches neither the
    // FCSM nor role_locked nor nego_en, so fcsm stays 4 and data keeps flowing
    // (asserted in t31/t33: rea=1, fcsm=4 post-retire).
    //
    // MANUAL PATH BIT-IDENTICAL: the SET is gated on the RAW armed conjunction
    // (nego_en & role_locked & train_auto_en) AND the RETIRE_EN tapeout knob; on
    // the recipe (train_auto_en=0 or nego_en=0) or with RETIRE_EN=0 it can never
    // assert, so autonomy_armed is unchanged.
    localparam [15:0] RETIRE_DWELL    = 16'd4096;      // branch 1 (sim mutual gate)
    localparam [23:0] RETIRE_DWELL_SI = 24'd8_000_000; // branch 2 (silicon, ~160 ms @50MHz << 2.8 s)
    reg [15:0] fc_stable_cnt_q;   // branch 1: (winscan_done & rea & fcsm=4) consecutive
    reg [23:0] rea_up_cnt_q;      // branch 2: (rea & fcsm=4) consecutive
    reg        link_up_seen_q;    // obs: (rea & fcsm=4) seen at least once this episode
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            link_up_seen_q    <= 1'b0;
            fc_stable_cnt_q   <= 16'd0;
            rea_up_cnt_q      <= 24'd0;
            autonomy_retire_q <= 1'b0;
        end else if (swi_training_mode_rise) begin
            // Fresh training episode => re-arm: restore the forced-SYNC chain
            // for the new scan (the peer's re-anchor needs it).
            link_up_seen_q    <= 1'b0;
            fc_stable_cnt_q   <= 16'd0;
            rea_up_cnt_q      <= 24'd0;
            autonomy_retire_q <= 1'b0;
        end else begin
            if (ws_anchor_q && (sync_obs_fcsm_state_1 == 3'd4))
                link_up_seen_q <= 1'b1;
            // Branch 1 — SIM mutual gate: winscan_done proves the rendezvous
            // completed (both dies anchored) so the master's beacons are no
            // longer needed. Reset on any drop.
            if (winscan_done && ws_anchor_q && (sync_obs_fcsm_state_1 == 3'd4))
                fc_stable_cnt_q <= (fc_stable_cnt_q == RETIRE_DWELL)
                                       ? RETIRE_DWELL : fc_stable_cnt_q + 16'd1;
            else
                fc_stable_cnt_q <= 16'd0;
            // Branch 2 — SILICON reanchored timer: rea & bilateral FC held for a
            // LONG dwell (< the churn onset). Reset on any drop.
            if (ws_anchor_q && (sync_obs_fcsm_state_1 == 3'd4))
                rea_up_cnt_q <= (rea_up_cnt_q == RETIRE_DWELL_SI)
                                    ? RETIRE_DWELL_SI : rea_up_cnt_q + 24'd1;
            else
                rea_up_cnt_q <= 24'd0;
            // Fire on EITHER branch, when armed and enabled. Holds until the
            // next training rise (or POR).
            // 2026-07-24 — `& mask_hs_verified_reg` added. Entering autonomous
            // RETIRED operation now requires a GENUINE peer-mask verdict on this
            // die; a strap (mask_hs_bypass_i) or the nego_lost_w free pass can no
            // longer get you here. This is the integrity boundary that the
            // reverted F3 was reaching for, relocated off the mutual clock enable
            // (role_locked) so it fails closed RECOVERABLY and OBSERVABLY instead
            // of by gating this die's forwarded clock — which would also kill the
            // peer's RX clock domain. Bring-up timing is untouched: role_lock,
            // wlink_por_reset and autonomy_armed all latch exactly as before.
            if (RETIRE_EN && (nego_en & role_locked & nego_train_cfg_r[0])
                && mask_hs_verified_reg
                && ((fc_stable_cnt_q == RETIRE_DWELL)
                    || (rea_up_cnt_q == RETIRE_DWELL_SI)))
                autonomy_retire_q <= 1'b1;
        end
    end

    // --- AUTO-ANCHOR one-shot (2026-08-04) ------------------------------------
    // Pulse the SYNC beacon ONCE at link-up so the shipping SYNC-reanchor deskew
    // corrector latches its re-anchor on the nego_en=0 / SELF_ARM path (where no
    // beacon otherwise flows -> reanchored=0 -> RX mis-frames = the R1/deskew
    // wedge). Mirrors the ws_serve one-shot. CORRECTED per the 2026-08-04 review:
    //  (A) the burst is GATED on TX-idle (~sync_obs_a2l_app_v_1, the apb_clk sync
    //      of the app->link valid) so it can NEVER delete a live D2D word —
    //      force_always is a word-deleter over live app data (Defect A);
    //  (B) link-up = sync_obs_fcsm_state_1[2] (states 4..7, glitch-free) not ==4;
    //  (C) the abort branch clears pulse+dwell (no frozen-asserted burst).
    // Re-armed per training episode. AUTO_ANCHOR_EN=0 constant-folds all of it.
    localparam [15:0] ANCHOR_DWELL = 16'd256;   // link-stable + TX-idle cycles before pulsing
    // HW 08-05: on the marginal eye the reanchor needs MANY SYNC beats to commit all
    // masked lanes (SYNC_CONFIRM per lane vs a high per-SYNC bit-error rate); a 164us
    // burst (old 4096) was far too short — a sustained ~3s beacon latches reanchored
    // on BOTH dies incl. the master, then R1 crosses byte-exact (200/200). So the
    // beacon runs to this CAP. There is deliberately NO ws_anchor_q early-out (removed
    // below): stopping on THIS die's own reanchor would drop its force_always beacon
    // before the peer has latched (mutual-anchor starvation), so both dies hold the
    // beacon for the full window. (2026-08-05 convergence: corrected the stale comment
    // that claimed an early-out still gated the cap.)
    // SIM keeps a short window under `ifdef TB_TOP_AUTO_ANCHOR_EN (defined ONLY by the
    // cocotb auto-anchor build) so test_v2_auto_anchor's beacon completes inside the tb
    // window; the eth-chiplet silicon build sets AUTO_ANCHOR_EN via the parent param and
    // never defines it, so it gets the multi-second cap. Pairs with the SIM_BUILD
    // `_autoanchor` key fix in the pair Makefile (else the AUTO_ANCHOR=1/0 builds share
    // one sim_build dir and the negctl silently re-runs the beacon-ON binary = false FAIL).
`ifdef TB_TOP_AUTO_ANCHOR_EN
    localparam [27:0] ANCHOR_LEN   = 28'd4096;         // sim: complete within the tb window
`else
    localparam [27:0] ANCHOR_LEN   = 28'd200_000_000;  // silicon: ~8s @25MHz apb backstop cap
`endif
    reg        auto_anchor_pulse_q;
    reg        auto_anchor_done_q;
    reg [15:0] auto_anchor_dwell_q;
    reg [27:0] auto_anchor_len_q;            // widened for the multi-second beacon cap
    reg        auto_anchor_pulsed_ever_q;   // sticky diag: >=1 beacon cycle emitted this episode
    reg [15:0] auto_anchor_dwell_max_q;      // sticky diag: max tx-idle dwell streak reached
    wire       auto_anchor_link_up = sync_obs_fcsm_state_1[2];   // FCSM in 4..7 (link up)
    wire       auto_anchor_tx_idle = ~sync_obs_a2l_app_v_1;      // no app->link word in flight
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            auto_anchor_pulse_q <= 1'b0; auto_anchor_done_q <= 1'b0;
            auto_anchor_dwell_q <= 16'd0; auto_anchor_len_q <= 28'd0;
            auto_anchor_pulsed_ever_q <= 1'b0; auto_anchor_dwell_max_q <= 16'd0;
        end else if (swi_training_mode_rise) begin              // re-arm on a fresh episode
            auto_anchor_pulse_q <= 1'b0; auto_anchor_done_q <= 1'b0;
            auto_anchor_dwell_q <= 16'd0; auto_anchor_len_q <= 28'd0;
            auto_anchor_pulsed_ever_q <= 1'b0; auto_anchor_dwell_max_q <= 16'd0;
        end else if (AUTO_ANCHOR_EN && !auto_anchor_done_q && !swi_training_mode_r) begin
            if (auto_anchor_dwell_q > auto_anchor_dwell_max_q)
                auto_anchor_dwell_max_q <= auto_anchor_dwell_q;   // sticky max tx-idle streak
            // NO early-out on THIS die's ws_anchor_q (reanchored): stopping the
            // beacon the instant THIS die latches STARVES the PEER's RX of our
            // ongoing beacon -> mutual-anchor starvation. HW 08-05: die_a
            // reanchored autonomously, its early-out stopped its beacon, and die_b
            // was left reanchored=0; a sustained die_a beacon then latched die_b.
            // So keep beaconing through the whole idle window (both dies at once)
            // so BOTH reanchor; stop only on app-active (data) or the cap.
            if (auto_anchor_link_up && auto_anchor_tx_idle) begin
                if (auto_anchor_dwell_q < ANCHOR_DWELL) begin
                    auto_anchor_dwell_q <= auto_anchor_dwell_q + 16'd1;
                end else if (auto_anchor_len_q < ANCHOR_LEN) begin
                    auto_anchor_pulse_q <= 1'b1;                 // emit the SYNC burst
                    auto_anchor_pulsed_ever_q <= 1'b1;           // sticky diag latch
                    auto_anchor_len_q   <= auto_anchor_len_q + 28'd1;
                end else begin
                    auto_anchor_pulse_q <= 1'b0;                 // release -> the anchor latches
                    auto_anchor_done_q  <= 1'b1;
                end
            end else if (auto_anchor_link_up) begin
                // link UP but app TX active (~tx_idle): the DATA PHASE has begun.
                // STOP the beacon PERMANENTLY (done). force_always is a word-
                // deleter (the idle-gated path is starved on this silicon, HW
                // 08-05, so the beacon MUST use force_always), therefore it must
                // NEVER run once app data flows. The a2l path is provably idle
                // through the whole bring-up window (HW 08-05: tx_idle=1 stable
                // for seconds; FC keepalive is a separate path, not a2l), so
                // app-active here == the first REAL peer-write, not a blip. On a
                // normal bring-up both dies reanchor during the shared idle
                // beacon window long before any data, so the stop is moot; in the
                // pathological "data immediately, no idle window" case it stops
                // the beacon before it can straddle a word (Defect-A guard).
                auto_anchor_pulse_q <= 1'b0;
                auto_anchor_done_q  <= 1'b1;
            end else begin
                // link genuinely dropped out of UP -> re-settle the dwell from 0
                // (real instability, not mere traffic). len holds.
                auto_anchor_pulse_q <= 1'b0;
                auto_anchor_dwell_q <= 16'd0;
            end
        end
    end

    // AUTO_ANCHOR diagnostic obs word (2026-08-04) — served at Region F slot 5,
    // SoC 0x4403_21F4. One read explains why reanchored did/didn't latch on the
    // SELF_ARM path: [15:0] dwell_max = longest tx-idle streak reached (if it
    // stays << ANCHOR_DWELL the beacon never got enough consecutive idle cycles);
    // [16] pulsed_ever = a SYNC beacon DID emit; [17] done; [18] pulse(live);
    // [19] link_up(live); [20] tx_idle(live); [21] reanchored(ws_anchor_q);
    // [22] training_mode_r; [23] AUTO_ANCHOR_EN. Param=0 folds every field to 0.
    assign auto_anchor_obs_word = {
        8'h0,                        // [31:24]
        AUTO_ANCHOR_EN,              // [23]  build flag
        swi_training_mode_r,         // [22]
        ws_anchor_q,                 // [21]  reanchored (CDC'd)
        auto_anchor_tx_idle,         // [20]
        auto_anchor_link_up,         // [19]
        auto_anchor_pulse_q,         // [18]
        auto_anchor_done_q,          // [17]
        auto_anchor_pulsed_ever_q,   // [16]
        auto_anchor_dwell_max_q      // [15:0]
    };

    // FIX-D obs (2026-07-07) — WS_FIN_WAITPEER entry / re-entry tracker.
    //   ws_waitpeer_entered_q   (0x21B8[15], sticky): the master parked in
    //                           WS_FIN_WAITPEER at least once this episode.
    //   ws_waitpeer_reentry_cnt (0x21B8[19:18], 2-bit sat): the number of
    //                           WS_FINALIZE→WS_FIN_WAITPEER entries this episode —
    //                           the NODONE/livelock detector. On the pre-FIX-A RTL
    //                           the Phase-2 anchor-timeout return to WS_FINALIZE
    //                           re-entered WS_FIN_WAITPEER unboundedly (this
    //                           counter saturates at 3). With FIX-A the sticky
    //                           ws_rdv_timeout_q caps it at 1. Both cleared at
    //                           WS_ARM / POR.
    reg [3:0] ws_state_d;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_state_d              <= WS_IDLE;
            ws_waitpeer_entered_q   <= 1'b0;
            ws_waitpeer_reentry_cnt <= 2'd0;
        end else begin
            ws_state_d <= ws_state_r;
            if (ws_state_r == WS_ARM) begin
                ws_waitpeer_entered_q   <= 1'b0;
                ws_waitpeer_reentry_cnt <= 2'd0;
            end else if (ws_state_r == WS_FIN_WAITPEER
                         && ws_state_d != WS_FIN_WAITPEER) begin
                // A fresh WS_FINALIZE→WS_FIN_WAITPEER entry (the only transition
                // into this state is the WS_FINALIZE fallback arm).
                ws_waitpeer_entered_q   <= 1'b1;
                ws_waitpeer_reentry_cnt <= (ws_waitpeer_reentry_cnt == 2'd3)
                                           ? 2'd3 : ws_waitpeer_reentry_cnt + 2'd1;
            end
        end
    end

    // FIX-D obs (2026-07-07) — VERIFY-STUCK detector (0x21B8[14], sticky).
    // The wrong-slot / verify-never-passes signature (the Lever-1 premise): the
    // deskew anchor LATCHED (ws_anchor_q=1, `reanchored`) but the zero-tolerance
    // anchor-verify (ws_verify_q) stayed LOW for more than WS_VFY_STUCK_N apb
    // cycles — a lane whose sticky sync_idx latched an ADJACENT SYNC slot commits
    // an anchor it can never verify. Healthy operation clears both together on the
    // F3 clear, so a sustained anchor-high/verify-low window only occurs on a real
    // mis-anchor. The counter resets whenever the condition breaks; the sticky
    // clears at WS_ARM / POR.
    reg [15:0] ws_vfy_stuck_ctr;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_vfy_stuck_ctr  <= 16'd0;
            ws_verify_stuck_q <= 1'b0;
        end else if (ws_state_r == WS_ARM) begin
            ws_vfy_stuck_ctr  <= 16'd0;
            ws_verify_stuck_q <= 1'b0;
        end else if (ws_anchor_q & ~ws_verify_q) begin
            if (ws_vfy_stuck_ctr == WS_VFY_STUCK_N)
                ws_verify_stuck_q <= 1'b1;
            else
                ws_vfy_stuck_ctr <= ws_vfy_stuck_ctr + 16'd1;
        end else begin
            ws_vfy_stuck_ctr <= 16'd0;
        end
    end

    wire [WS_DW_W-1:0] ws_dwell_load =
        tb_winscan_dwell_short_q ? WINSCAN_DWELL_SIM[WS_DW_W-1:0]
                                 : WINSCAN_DWELL[WS_DW_W-1:0];
    wire [WS_DW_W-1:0] ws_samp_space =
        tb_winscan_dwell_short_q ? WINSCAN_SAMP_SPACE_SIM[WS_DW_W-1:0]
                                 : WINSCAN_SAMP_SPACE[WS_DW_W-1:0];
    // F3b: FINALIZE force-held rendezvous dwell (same sim hook as the tap dwell).
    wire [WS_DW_W-1:0] ws_fin_wait_load =
        tb_winscan_dwell_short_q ? WINSCAN_FIN_WAIT_SIM[WS_DW_W-1:0]
                                 : WINSCAN_FIN_WAIT[WS_DW_W-1:0];
    // FIX-4b (2026-07-05): retry re-entry RE-CLEAR SETTLE dwell — the 24-bit
    // clear-low hold constant zero-extended onto the (wider, >=25-bit from
    // the 25M WINSCAN_FIN_WAIT) dwell counter. See the WS_FIN_CLRLOW exit arm.
    wire [WS_DW_W-1:0] ws_clr_settle_load =
        {{(WS_DW_W-24){1'b0}}, ws_clr_hold_load};

    // Arm kick: the autoneg training-mode falling edge on the autonomous path
    // (= post role-lock + cal-done + lane-lock = SYNC-detect-capable), the SAME
    // event that latches fch_pending_r — so the handoff waits out the scan.
    //
    // EPISODE BINDING (2026-07-03, silicon-root-caused): the fall is a 1-cycle
    // PULSE, and pre-fix it was consumed only in WS_IDLE/WS_DONE. When the
    // first-armed die runs a PRIVATE training episode against an un-armed
    // zombie peer (R5 retry loop), a LATER bilateral training fall landing
    // MID-SCAN was silently LOST — while fch_pending_r (its own sticky, no
    // state gate) re-latched and re-ran the handoff on the STALE winscan_done
    // of the zombie-era scan. The two dies' scans then bound to DIFFERENT
    // training episodes displaced by the arm gap (seconds), starving the
    // late die's re-anchor of peer beacons. Fix = the fch_pending idiom:
    //   * ws_kick_pending_q — sticky, set on the gated fall; the FSM arms off
    //     the STICKY only (1-cycle arm latency — nothing against scans that
    //     run for thousands of cycles), and EVERY state acts on it the cycle
    //     it reads 1 (IDLE/DONE start a scan, all mid-scan states
    //     ABORT-RESTART to WS_ARM), so it is consumed exactly one cycle
    //     after set — no state can strand it (set has priority: a fall
    //     landing on the consume cycle re-latches);
    //   * the abort-restart arm (case-priority, below) re-seeds the taps,
    //     clears winscan_done (fch_pending_r re-blocks) and drops the F3
    //     clear level (re-arms the destination edge-detect); WS_ARM then
    //     clears the per-episode stickies (ws_degenerate_q /
    //     ws_anchor_timeout_q / ws_anchor_late_q) as on any fresh episode.
    // Result: both dies' FINAL scans start within sub-ms of the same
    // bilateral ST_TRAIN_EXIT clear — the fixed-window rendezvous holds.
    wire ws_kick_evt = WINSCAN_FSM_EN & autonomy_armed &    // LOOP-9: armed-only
                       swi_training_mode_fall & ~ws_kicked_q;
    reg  ws_kick_pending_q;
    // The FSM arms off the STICKY only — NOT the raw event — so the latch
    // set (evt cycle) and the FSM consume (the following cycle) are disjoint:
    // a same-cycle evt+consume would otherwise leave a stale pending that
    // fires a spurious abort out of the just-entered WS_ARM.
    wire ws_arm_req  = ws_kick_pending_q;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            ws_kick_pending_q <= 1'b0;
        else if (ws_kick_evt)
            ws_kick_pending_q <= 1'b1;   // latch the (1-cycle) training fall
        else if (ws_kick_pending_q)
            ws_kick_pending_q <= 1'b0;   // consumed: the FSM acts on the sticky
                                         // in EVERY state (start or abort-restart)
    end

    // FIX-1 (2026-07-08, REANCHOR-WITHOUT-WINSCAN CATCH-UP): the SECOND-armed
    // die (the slave) can be left with a COMMITTED + VERIFIED deskew anchor but
    // winscan_done NEVER asserting -> the fch handoff deadlocks (the NODONE
    // observed on iter-1 silicon, build 564ddde). Root cause: its I2C ACK from
    // POR lands BEFORE autonomy_armed=1, so the training FALL that would kick
    // the winscan is dropped by the LOOP-9 armed-only gate on ws_kick_evt
    // (ws_kick_evt requires autonomy_armed AT the fall). autonomy_armed then
    // rises with NO fresh fall -> the winscan stays parked in WS_IDLE ->
    // winscan_done stays 0 forever. But the die DID re-anchor passively (the
    // peer's beacons drove reanchored=1 => ws_anchor_q=1) AND that anchor is
    // ZERO-TOLERANCE VERIFIED (ws_verify_q=1 = the EXACT WS_FINALIZE release
    // gate's own criterion, verify_stuck=0). So it is a fully-committed,
    // verified anchor missing ONLY winscan_done + fch_pending_r. This term
    // detects exactly that state; the WS_IDLE arm (below) completes the arc
    // WITHOUT running a scan (raise winscan_done, one-shot ws_kicked_q, STAY in
    // WS_IDLE so winscan_owns_taps stays 0 = host/APB anchor taps untouched, NO
    // sweep) and the fch_pending_r set term (below) queues the handoff.
    // SAFETY (each verified): never ships an unverified anchor (gated on
    // ws_verify_q, the exact WS_FINALIZE release gate); NO tap sweep/disturbance
    // (winscan_owns_taps stays 0 in WS_IDLE); one-shot (ws_kicked_q<=1, cleared
    // only by a genuine training rise); declines the stuck-training-high variant
    // (~swi_training_mode_r); disarm-safe (LOOP-9 park still clears winscan_done
    // on !autonomy_armed). Does NOT affect the master: it kicks via its OWN real
    // training fall and LEAVES WS_IDLE, and its ws_anchor_q is 0 before its
    // anchor exists (so this term cannot fire for it).
    wire ws_reanchor_catchup = WINSCAN_FSM_EN & autonomy_armed & ~ws_kicked_q
                             & (ws_state_r == WS_IDLE)
                             & ws_anchor_q & ws_verify_q & ~swi_training_mode_r;
    // Register the (1-cycle) catchup pulse for the fch_pending_r SET term above
    // (declaration-before-use / `default_nettype none` forbids referencing the
    // combinational net directly in that earlier block). The WS_IDLE arm below
    // consumes ws_reanchor_catchup combinationally (in scope); this flopped copy
    // only feeds the fch handoff, one cycle later, by which point winscan_done
    // (raised by the same-cycle WS_IDLE arm) has already opened winscan_gate.
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            ws_reanchor_catchup_q <= 1'b0;
        else
            ws_reanchor_catchup_q <= ws_reanchor_catchup;
    end

    // The lane currently selected for the SYNC_DIST observation. Mirror it onto
    // swi_dist_lane_sel_r's read path is unnecessary — the FSM reads the full
    // CDC'd vector directly (sync_obs_dist_vec_1), exactly the same 5-bit slice
    // the host gets via the 0x21B0/0x21AC select+read.
    wire [4:0] ws_lane_dist = sync_obs_dist_vec_1[5*ws_lane_r[2:0] +: 5];
    // Active-lane test: scan a lane only if its mask bit is set (the 0xe4 set on
    // silicon; default 0xFF in sim → all 8 scanned). Matches the host's
    // for-L-in-active-set loop.
    wire ws_lane_active = swi_sync_lane_mask_r[ws_lane_r[2:0]];

    // Q1 QUIESCE-BEFORE-FINALIZE request (2026-07-04) — see the fch
    // sequencer's Q1 comment for the full silicon mechanism. Level-asserted
    // for the WHOLE finalize window (WS_FINALIZE + the FIX-3 WS_FIN_CLRLOW
    // retry arcs) so a late fch (e.g. still walking a previous episode's
    // bootstrap when FINALIZE opens) still picks the request up on its next
    // IDLE. autonomy_armed-gated twice over (the FSM can only REACH these
    // states while armed, and the disarm-park arc leaves them within a
    // cycle) so a manual takeover drops the request immediately; the fch
    // IDLE release arm then writes the swreset back OFF. Declared (hoisted)
    // next to fch_done_r; V1 arm ties it 0 below.
    // R-B ASYMMETRIC PEER-SERVE (2026-07-07): the quiesce request covers ONLY
    // WS_FINALIZE/WS_FIN_CLRLOW — the SLAVE's own b55cb59 finalize window (the
    // master enters those only as the 1-cycle pass-through or the rendezvous-
    // timeout fallback). NEITHER role quiesces for the peer-serve rendezvous:
    //   * The MASTER does NOT quiesce in WS_FIN_WAITPEER — it holds force-SYNC
    //     so its TX is already clean, and keeping its FC out of swreset lets its
    //     WS_DONE bootstrap run the NORMAL widx-0 full walk (with the R4c cross-
    //     die overlap dwell) that aligns the credit handshake; a WAITPEER
    //     quiesce (widx-1 bootstrap, no R4c) deadlocked the master FC at fcsm=2
    //     in multi-episode retry (t32).
    //   * The SLAVE serves by FORCING SYNC (see the serve-force below) with its
    //     FC LEFT UP so its RX stays live to receive the master's credit; a
    //     serve quiesce would SWRESET its FC and deadlock it at fcsm=2.
    assign fch_quiesce_req = autonomy_armed &
                             ((ws_state_r == WS_FINALIZE) |
                              (ws_state_r == WS_FIN_CLRLOW));

    // R-B ASYMMETRIC PEER-SERVE (2026-07-07): the exported "MASTER parked in
    // WS_FIN_WAITPEER" level. role_is_master-GATED — only die_a (master) parks
    // in WS_FIN_WAITPEER, runs the rendezvous and re-confirms its anchor; die_b
    // (slave) never sets this (it serves instead, see ws_serve_active_r).
    // The master does NOT quiesce its FC here (no fch_quiesced_r qualifier): it
    // holds winscan_force_sync through WS_FIN_WAITPEER so its OWN TX is clean
    // SYNC toward the slave anyway, and keeping its FC OUT of swreset means its
    // WS_DONE bootstrap runs the NORMAL full walk (SWRESET_ON->OFF->ENABLE with
    // the R4c cross-die overlap dwell) that aligns the credit handshake — a
    // WAITPEER quiesce made it start at widx 1 (skipping R4c) and deadlocked the
    // FC at fcsm=2 in multi-episode retry (t32). Fed to
    // u_autoneg.local_fin_wait_i (master-only ST_FIN_RDV/GO entry arc). The
    // peer-visible SWI_LANE_STATUS[27] export is separate (slave advertises
    // ready-to-serve there). V1 arm below ties it 0.
    assign ws_fin_wait_lvl = role_is_master
                             & (ws_state_r == WS_FIN_WAITPEER);

    // FIX-B (2026-07-07): the BROADENED finalize level — the master is in ANY
    // finalize state. Fed to u_autoneg.local_finalizing_i (the ST_FIN_RDV POLL
    // entry). role_is_master-gated (the slave serves, it never polls). The GO
    // write inside ST_FIN_RDV stays gated on the NARROW ws_fin_wait_lvl above
    // (routed as local_fin_wait_i), so the poll reads the peer's ready-to-serve
    // bit while finalizing but no GO is written until the master is actually
    // parked in WS_FIN_WAITPEER. V1 arm below ties it 0.
    assign ws_finalizing_lvl =
        role_is_master & ((ws_state_r == WS_FINALIZE)
                          | (ws_state_r == WS_FIN_CLRLOW)
                          | (ws_state_r == WS_FIN_WAITPEER));

    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            ws_state_r        <= WS_IDLE;
            ws_lane_r         <= 4'd0;
            ws_tap_r          <= 6'd0;
            ws_nsamp_r        <= 3'd0;
            ws_dist_min_r     <= 5'd31;
            ws_best_dist_r    <= 5'd31;
            ws_best_tap_r     <= 6'd0;
            ws_dwell_r        <= '0;
            ws_kicked_q       <= 1'b0;
            ws_dist_prev_r       <= 5'd31;
            ws_dist_pair_valid_q <= 1'b0;
            ws_qual_to_r         <= 8'd0;
            ws_lane_first_r      <= 5'd31;
            ws_lane_flat_q       <= 1'b0;
            ws_all_flat_q        <= 1'b0;
            ws_any_scanned_q     <= 1'b0;
            ws_degenerate_q      <= 1'b0;
            ws_obs_clr_r         <= 1'b0;
            ws_anchor_to_r       <= 24'd0;
            ws_anchor_timeout_q  <= 1'b0;
            ws_anchor_retry_r    <= 3'd0;
            ws_anchor_ext_r      <= 3'd0;   // AUTONOMY-LEVER: window-1 soft-extends

            ws_abort_cnt_q       <= 4'd0;
            ws_vfy_retry_q       <= 1'b0;
            ws_retry_cnt_q       <= 3'd0;
            ws_rdv_timeout_q     <= 1'b0;
            ws_rdv_to_r          <= 29'd0;
            ws_phase_offset_r <= 32'h0;
            ws_phase_lsb_r    <= 8'h0;
            winscan_owns_taps <= 1'b0;
            winscan_force_sync<= 1'b0;
            winscan_done      <= 1'b0;
        end else begin
            // Re-arm bookkeeping: a fresh training episode (a new rising edge)
            // re-allows one run. ws_kicked_q gates one scan per episode.
            if (swi_training_mode_rise)
                ws_kicked_q <= 1'b0;

            // EPISODE-BINDING ABORT-RESTART (2026-07-03, case-priority): a
            // gated training fall (ws_arm_req) observed while the FSM is
            // MID-SCAN / FINALIZE belongs to a NEW training episode — the
            // in-flight scan's taps/anchor are stale (they were measured
            // against the PREVIOUS episode's link state, possibly a zombie
            // peer). Jump to WS_ARM: re-seed the taps, clear winscan_done so
            // fch_pending_r re-blocks on the fresh episode, and drop the F3
            // clear level so the destination edge-detect re-arms (the scan
            // ahead is thousands of cycles — ample low time for the 2-FF
            // level sync). WS_ARM itself clears the per-episode stickies
            // (ws_degenerate_q / ws_anchor_timeout_q / retry counter).
            // ws_abort_cnt_q (WINSCAN_OBS 0x21B8[7:4], saturating) counts the
            // aborts for sim assertions + on-silicon episode-binding triage.
            // LOOP-9 DISARM-PARK (highest priority): autonomy disarmed
            // (nego_en=0, or the manual recipe's 0x210C=0 clearing
            // train_auto_en) while the FSM is anywhere past WS_IDLE — PARK
            // immediately: drop force-SYNC (the Wlink-port OR goes dark the
            // next cycle — insert_en/force_always/robust revert to the APB
            // regs = R8 authority), release tap ownership (APB taps rule),
            // clear winscan_done (a later re-arm starts a fresh episode; the
            // fch pending latch is armed-gated so it cannot deadlock).
            // This is also the on-silicon escape hatch from a live force
            // window: write 0x210C=0 and the beacons stop within a cycle.
            if (!autonomy_armed && ws_state_r != WS_IDLE) begin
                winscan_owns_taps  <= 1'b0;
                winscan_force_sync <= 1'b0;
                winscan_done       <= 1'b0;
                ws_obs_clr_r       <= 1'b0;
                ws_state_r         <= WS_IDLE;
            end else
            if (ws_arm_req && ws_state_r != WS_IDLE && ws_state_r != WS_DONE)
            begin
                ws_kicked_q    <= 1'b1;
                winscan_done   <= 1'b0;
                ws_obs_clr_r   <= 1'b0;
                ws_abort_cnt_q <= (ws_abort_cnt_q == 4'hF) ? 4'hF
                                                           : ws_abort_cnt_q + 4'd1;
                ws_state_r     <= WS_ARM;
            end else
            case (ws_state_r)
                // -------------------------------------------------------------
                WS_IDLE: begin
                    // Dormant: APB/host owns the taps, SYNC at its strap value.
                    winscan_owns_taps  <= 1'b0;
                    winscan_force_sync <= 1'b0;
                    ws_obs_clr_r       <= 1'b0;  // F3: dormant ⇒ the manual
                                                 // R8 bit[5] path is untouched
                    if (ws_arm_req) begin
                        ws_kicked_q  <= 1'b1;
                        winscan_done <= 1'b0;     // fresh episode
                        ws_state_r   <= WS_ARM;
                    end else if (ws_reanchor_catchup) begin
                        // FIX-1 (2026-07-08): reanchored+verified but the armed
                        // training fall never landed (dropped by the LOOP-9 gate)
                        // -> complete the handoff arc IN PLACE. Raise winscan_done
                        // (opens winscan_gate) + one-shot (ws_kicked_q). STAY in
                        // WS_IDLE — do NOT go to WS_DONE, which sets
                        // winscan_owns_taps and would PIN stale taps; WS_IDLE
                        // holds winscan_owns_taps=0 so the host/APB anchor taps
                        // are untouched (no sweep, no disturbance) and never
                        // re-clears winscan_done, so done HOLDS. The end-of-block
                        // ws_kick_evt mask cannot fire here (no training fall).
                        winscan_done <= 1'b1;
                        ws_kicked_q  <= 1'b1;
                    end
                end
                // -------------------------------------------------------------
                WS_ARM: begin
                    // Force SYNC (host R8=0x1C) + take ownership of the taps.
                    // Seed the override from the current host/APB regs so any
                    // lane not (yet) scanned keeps a sane tap. Start at lane 0.
                    winscan_force_sync <= 1'b1;
                    winscan_owns_taps  <= 1'b1;
                    ws_phase_offset_r  <= swi_phase_offset_r;
                    ws_phase_lsb_r     <= swi_phase_lsb_r;
                    ws_lane_r          <= 4'd0;
                    // R2c: fresh degenerate-scan trackers for this episode.
                    ws_all_flat_q      <= 1'b1;
                    ws_any_scanned_q   <= 1'b0;
                    ws_degenerate_q    <= 1'b0;
                    // F4: fresh anchor-gate verdict for this episode (sticky
                    // within/after an episode, like ws_degenerate_q).
                    ws_anchor_timeout_q <= 1'b0;
                    // R-A/R-B: fresh per-episode stickies.
                    ws_vfy_retry_q      <= 1'b0;
                    ws_rdv_timeout_q    <= 1'b0;
                    // FIX-4: fresh per-episode attempt counter (0x21B8[13:11]).
                    ws_retry_cnt_q      <= 3'd0;
                    ws_state_r         <= WS_NEXT_LANE_ENTER;
                end
                // -------------------------------------------------------------
                WS_NEXT_LANE_ENTER: begin
                    // Per-lane entry: if the lane is active (mask bit set) start
                    // its tap-0 scan; otherwise skip it (leave its tap as seeded).
                    // ws_lane_active reads the mask bit for the current lane.
                    if (ws_lane_r > 4'd7) begin
                        // R2c DEGENERATE-SCAN GUARD: the whole sweep produced a
                        // FLAT metric on every scanned lane — no tap changed the
                        // measured distance, i.e. nothing was actually measured
                        // (torn/dead obs vector — the silicon taps-(0,0,0,0)
                        // run). Do NOT ship the arbitrary argmin (tap 0 on a
                        // flat metric, strict-<): RESTORE THE SEEDED taps (the
                        // host/APB swi_phase_offset_r / swi_phase_lsb_r values
                        // WS_ARM captured — the best available knowledge when
                        // the scan measured nothing) and latch the sticky
                        // ws_degenerate_q observability flag (Region-D
                        // WINSCAN_OBS 0x21B8[1]).
                        //
                        // Why the seed and NOT the "middle tap": the tap nibble
                        // is OR-MERGED with cal_phase_offset_w into the Wlink
                        // deserialiser io_phase_offset (a word-phase ROTATION,
                        // WavD2DGpioRx adj_count = count + io_phase_offset —
                        // fully functional in sim and on silicon), so a nonzero
                        // "centre" nibble is NOT a neutral mid-eye point: OR-ing
                        // 8 into the calibrated phase CORRUPTS the operating
                        // point (proven: middle-tap fallback broke the FCSM
                        // relock in the de-forced test_31 run). The seed is the
                        // identity on that OR-merge. winscan_done is still
                        // raised in WS_FINALIZE — leaving it unset would
                        // DEADLOCK the fch_pending_r handoff gate (no retry
                        // path re-arms it within an episode), so
                        // fail-loud-but-alive with the seeded taps is the
                        // safest option here.
                        if (ws_all_flat_q && ws_any_scanned_q) begin
                            ws_degenerate_q   <= 1'b1;
                            ws_phase_offset_r <= swi_phase_offset_r;
                            ws_phase_lsb_r    <= swi_phase_lsb_r;
                        end
                        // F3 (2026-07-02) — WS_FINALIZE RE-ANCHOR. Raise the
                        // deskew sticky-anchor clear on FINALIZE entry: the
                        // level is OR'd into Wlink's swi_sync_obs_clr_in (the
                        // manual R8 bit[5] SWI_SYNC_OBS_CLR node), 2-FF-synced
                        // + edge-detected in the PHY to WavD2DGpio's
                        // sync_obs_clr_pulse → deskew sync_obs_clr_i, which
                        // clears every lane's sticky sync_seen_l/sync_idx_l AND
                        // drops the read-side `reanchored` latch (rearm_wait
                        // settles the re-fire). This DISCARDS any scan-era
                        // mid-scan anchor commit (sticky sync_idx captured at a
                        // swept — not final — tap; benign today only because
                        // the first tap swept == seed == winner) so all lanes
                        // re-confirm at the FINAL taps during the FINALIZE
                        // dwell, under STILL-FORCED beacons (force-SYNC is
                        // held through FINALIZE — see the state's comment: the
                        // periodic-confirm needs the on-grid beacon every
                        // SYNC_PERIOD). HELD HIGH for the whole
                        // WS_FINALIZE (dropped in WS_DONE) because the
                        // destination is a 2-FF LEVEL sync in the ~link clock:
                        // a 1-apb-cycle pulse would be lost in the CDC; the
                        // destination edge-detect still yields EXACTLY ONE
                        // clear pulse per episode. Graceful degradation: if
                        // the routing is dead on silicon this is a no-op and
                        // behavior = today's (pre-verify on HW with a manual
                        // R8 bit[5] pulse watching 0x215C drop/re-fill).
                        // Loop-13 (2026-07-04): this transition is the exact
                        // b55cb59/Loop-11 LOCALLY-TIMED flow — the Loop-12
                        // R-B WS_FIN_WAITPEER rendezvous park that used to
                        // sit here regressed the b-first zero-poke order on
                        // silicon (mutual anchor starvation) and is dormant.
                        // R-B ASYMMETRIC PEER-SERVE (2026-07-07, rev2): the scan
                        // is complete. BOTH roles take the base b55cb59 LOCALLY-
                        // TIMED finalize here (F3 clear + WS_FINALIZE + F3b
                        // dwell) — the role split is GONE. The peer-serve
                        // rendezvous (WS_FIN_WAITPEER) is NO LONGER the master's
                        // PRIMARY path at scan-complete: entering it FIRST dropped
                        // a good anchor + re-confirmed over the served link and,
                        // in the normal/multi-episode FC-handoff flows, broke the
                        // handoff (t33 wedged the master FC at fcsm=2). The
                        // master now enters WS_FIN_WAITPEER ONLY as a FALLBACK,
                        // from the WS_FINALIZE fail-open arm below, and ONLY when
                        // its LOCAL finalize STARVED (ws_anchor_q==0 — the die_a
                        // beacon-starvation case). A master that anchors locally
                        // NEVER enters WS_FIN_WAITPEER, so t31/t32/t33 run the
                        // EXACT base scan->WS_FINALIZE->WS_DONE path undisturbed
                        // and the FC handoff is identical to 788eb7e. die_b's RX
                        // re-anchors fine on the master's held force-SYNC beacons
                        // (the measured die_b 83% vs die_a 8% asymmetry — die_b
                        // was never the problem); on the master's GO it SERVES
                        // idle beacons (ws_serve_active_r) for the master's
                        // fallback re-confirm.
                        ws_obs_clr_r   <= 1'b1;
                        // F4: arm the anchor-gate timeout for FINALIZE.
                        ws_anchor_to_r <= ws_anchor_to_load;
                        // AUTONOMY-LEVER: arm the window-1 soft-extend budget.
                        // These reloads extend the FIRST (uninterrupted, no
                        // re-clear) accumulation window before the clear-retries.
                        ws_anchor_ext_r <= ws_anchor_ext_load;
                        // FIX-3: arm the bounded clear-retry budget (R-A
                        // budget of 5 — the verify gate is downstream of
                        // ws_anchor_q and unchanged by the Loop-13 revert).
                        ws_anchor_retry_r <= WS_ANCHOR_RETRIES;
                        ws_state_r <= WS_FINALIZE;
                        ws_dwell_r <= ws_fin_wait_load; // F3b rendezvous dwell
                    end else if (!ws_lane_active) begin
                        ws_lane_r  <= ws_lane_r + 4'd1;     // skip masked lane
                    end else begin
                        ws_tap_r       <= 6'd0;
                        ws_best_dist_r <= 5'd31;
                        ws_best_tap_r  <= 6'd0;
                        ws_lane_flat_q <= 1'b1;             // R2c: fresh lane tracker
                        // Drive lane L, tap 0 (nibble 0, lsb 0).
                        ws_phase_offset_r[4*ws_lane_r[2:0] +: 4] <= 4'd0;
                        ws_phase_lsb_r[ws_lane_r[2:0]]           <= 1'b0;
                        ws_dwell_r     <= ws_dwell_load;
                        ws_state_r     <= WS_SETTLE;
                    end
                end
                // -------------------------------------------------------------
                WS_SETTLE: begin
                    // Dwell at the current tap (IDELAYE2 reload + SYNC re-flood).
                    if (ws_dwell_r != '0) begin
                        ws_dwell_r <= ws_dwell_r - {{(WS_DW_W-1){1'b0}}, 1'b1};
                    end else begin
                        ws_dist_min_r        <= 5'd31;   // seed min-over-N
                        ws_nsamp_r           <= WINSCAN_NSAMP[2:0] - 3'd1;
                        ws_dist_pair_valid_q <= 1'b0;    // R2: fresh read pair
                        ws_qual_to_r         <= WINSCAN_QUAL_TIMEOUT;
                        ws_state_r           <= WS_SAMPLE;
                    end
                end
                // -------------------------------------------------------------
                WS_SAMPLE: begin
                    // R2 SAMPLE INTEGRITY (2026-07-02). sync_obs_dist_vec_1 is a
                    // plain 2-FF-synced MULTI-BIT vector: a single apb_clk read
                    // can be TORN mid-flight (a false-LOW distance for one tap =
                    // a false argmin — the silicon taps-(0,0,0,0) scan), and the
                    // old 5 back-to-back reads (~100 ns) were ~ONE observation
                    // (min-over-5 vestigial vs the host's round-trip-spaced
                    // reads). Qualify: accept a sample only when TWO CONSECUTIVE
                    // reads are EQUAL (tear rejection — a torn word cannot read
                    // identically across the boundary of a real change), and
                    // SPACE the accepted samples by ws_samp_space cycles (reuse
                    // of ws_dwell_r) so the 5 are independent observations. A
                    // per-sample timeout accepts the raw read if the metric
                    // never repeats (defence against a toggling lane wedging
                    // WS_SAMPLE — winscan_done gates the FC handoff).
                    if (ws_dwell_r != '0) begin
                        // Inter-sample spacing gap.
                        ws_dwell_r           <= ws_dwell_r
                                                - {{(WS_DW_W-1){1'b0}}, 1'b1};
                        ws_dist_pair_valid_q <= 1'b0;    // restart pair after gap
                    end else if (!ws_dist_pair_valid_q) begin
                        ws_dist_prev_r       <= ws_lane_dist;   // first of a pair
                        ws_dist_pair_valid_q <= 1'b1;
                    end else if ((ws_lane_dist == ws_dist_prev_r)
                                 || (ws_qual_to_r == 8'd0)) begin
                        // QUALIFIED (two equal consecutive reads) — or timed
                        // out: accept the current read.
                        if (ws_lane_dist < ws_dist_min_r)
                            ws_dist_min_r <= ws_lane_dist;
                        ws_dist_pair_valid_q <= 1'b0;
                        ws_qual_to_r         <= WINSCAN_QUAL_TIMEOUT;
                        if (ws_nsamp_r != 3'd0) begin
                            ws_nsamp_r <= ws_nsamp_r - 3'd1;
                            ws_dwell_r <= ws_samp_space; // space the next sample
                        end else begin
                            ws_state_r <= WS_NEXT_TAP;
                        end
                    end else begin
                        // Torn/changing read — retry the pair.
                        ws_dist_prev_r <= ws_lane_dist;
                        ws_qual_to_r   <= ws_qual_to_r - 8'd1;
                    end
                end
                // -------------------------------------------------------------
                WS_NEXT_TAP: begin
                    // Argmin (strict < keeps the earlier tap on a tie, as the
                    // host does), then advance the tap or finish the lane.
                    if (ws_dist_min_r < ws_best_dist_r) begin
                        ws_best_dist_r <= ws_dist_min_r;
                        ws_best_tap_r  <= ws_tap_r;
                    end
                    // R2c: per-lane flat-metric tracking. Capture the tap-0
                    // distance; any later tap measuring DIFFERENT clears the
                    // lane's flat flag (something was actually measured).
                    if (ws_tap_r == 6'd0)
                        ws_lane_first_r <= ws_dist_min_r;
                    else if (ws_dist_min_r != ws_lane_first_r)
                        ws_lane_flat_q  <= 1'b0;
                    if (ws_tap_r == 6'd31) begin
                        ws_state_r <= WS_PICK;
                    end else begin
                        ws_tap_r <= ws_tap_r + 6'd1;
                        // Drive the NEXT tap into the selected lane's slice.
                        ws_phase_offset_r[4*ws_lane_r[2:0] +: 4] <= (ws_tap_r + 6'd1) >> 1;
                        ws_phase_lsb_r[ws_lane_r[2:0]]           <= ws_tap_r[0] ^ 1'b1;
                        ws_dwell_r <= ws_dwell_load;
                        ws_state_r <= WS_SETTLE;
                    end
                end
                // -------------------------------------------------------------
                WS_PICK: begin
                    // Commit the argmin tap for this lane (host settap(L,best)).
                    ws_phase_offset_r[4*ws_lane_r[2:0] +: 4] <= ws_best_tap_r[4:1];
                    ws_phase_lsb_r[ws_lane_r[2:0]]           <= ws_best_tap_r[0];
                    // R2c: fold this lane into the scan-wide degeneracy verdict.
                    if (!ws_lane_flat_q)
                        ws_all_flat_q <= 1'b0;      // real variation seen
                    ws_any_scanned_q <= 1'b1;       // at least one lane scanned
                    ws_lane_r  <= ws_lane_r + 4'd1;
                    ws_state_r <= WS_NEXT_LANE_ENTER;
                end
                // -------------------------------------------------------------
                WS_FINALIZE: begin
                    // F3/F4 (2026-07-02): force-SYNC is HELD THROUGH FINALIZE
                    // and dropped only at the exit arms below — NOT on entry.
                    // The deskew's periodic-confirm REQUIRES on-grid beacons:
                    // a missed SYNC_PERIOD slot BREAKS the confirm run
                    // (tidelink_lane_deskew gap_ceil → sync_conf<=0), and
                    // idle-gated insertion on the pre-bootstrap CR-spamming
                    // link skips most grid slots — the post-clear re-confirm
                    // then never completes (sim-proven: test_31 anchor gate
                    // timed out under an entry-dropped force). Under held
                    // force the beacon fires EVERY grid slot, so seed + the
                    // SYNC_CONFIRM run completes in ~3 SYNC periods at the
                    // FINAL taps — deterministic. DATA-SAFE: Q1 (2026-07-04)
                    // the LL is QUIESCED for this whole state (fch_quiesce_req
                    // → SWRESET_ON at FINALIZE entry), so the link carries
                    // PURE IDLE + beacons — there is no CR/CRACK spam left to
                    // stomp, and the PEER's idle-gated re-anchor cannot be
                    // starved by this die's keepalives (the Loop-10 lane-7
                    // silicon signature); force is OFF strictly before
                    // winscan_done → the fch bootstrap's CR/CRACK re-walk
                    // (from the quiesced swreset-ON state, widx 1) and all
                    // real data run idle-gated (R4a intact).
                    // KEEP owning the taps (the picked per-lane centres stay
                    // applied). ws_obs_clr_r is HELD HIGH throughout this
                    // state (F3 — see the FINALIZE-entry comment): the
                    // scan-era sticky anchor is discarded and all lanes
                    // re-confirm at the FINAL taps during this dwell.
                    if (ws_dwell_r != '0) begin
                        ws_dwell_r <= ws_dwell_r - {{(WS_DW_W-1){1'b0}}, 1'b1};
                    end else if (ws_anchor_q && ws_verify_q) begin
                        // F4 ANCHOR GATE + R-A ANCHOR-VERIFY (2026-07-04):
                        // release only once the CDC'd deskew `reanchored`
                        // reads 1 (the on-chip equivalent of the manual host
                        // polling 0x2140 bit0 before the 0x208 bootstrap)
                        // AND the zero-tolerance anchor-verify sticky
                        // (ws_verify_q) reads 1 — the ENGAGED anchor has
                        // reproduced the KNOWN beacon content EXACTLY on
                        // every active lane on one post-deskew beat. A lane
                        // whose sticky sync_idx latched an ADJACENT SYNC
                        // slot (tol-5 Hamming on a marginal eye — the die_b
                        // byte-lane[23:16] 0x24->0x5c mis-anchor) satisfies
                        // `reanchored` but presents its slice one beat off
                        // the others, so it can NEVER satisfy the verify —
                        // the anchor-timeout path below then re-clears and
                        // re-anchors instead of shipping the wrong offset
                        // forever. winscan_done gates fch_pending_r, so this
                        // strictly orders the handoff after a SETTLED,
                        // VERIFIED post-clear anchor. Drop force-SYNC here
                        // (host R8=0x14): the anchor is sticky, beacons
                        // revert to idle-gated — and STAY up permanently
                        // (D2).
                        winscan_force_sync <= 1'b0;
                        winscan_done       <= 1'b1;
                        ws_state_r         <= WS_DONE;
                    end else if (ws_anchor_to_r == 24'd0) begin
                        if (ws_anchor_ext_r != 3'd0) begin
                            // AUTONOMY-LEVER (2026-07-10): SOFT-EXTEND window 1.
                            // Reload the anchor-gate countdown WITHOUT dropping
                            // ws_obs_clr_r — so NO fresh clr_pulse reaches the
                            // deskew and the per-lane sticky sync_seen
                            // accumulation continues UNINTERRUPTED. ws_obs_clr_r
                            // is already held HIGH here and force-SYNC is still
                            // held, so beacons keep flooding every SYNC grid slot
                            // and a marginal lane gets another full
                            // WS_ANCHOR_TIMEOUT of 2-consecutive-beacon rolls.
                            // Only once the extend budget is spent do the FIX-3
                            // jittered clear-retries below (which DO restart
                            // accumulation) begin. A clean/early anchor NEVER
                            // reaches this branch — the ws_anchor_q &&
                            // ws_verify_q release poll above wins first — so
                            // there is no clean-die latency penalty. Anti-poison
                            // is unaffected (the deskew's periodic+gap+K=2
                            // self-gating rejects poison independently of window
                            // length) and the VERIFY_TOL=3 backstop still gates
                            // the release, so a longer window cannot commit a
                            // wrong anchor.
                            ws_anchor_ext_r <= ws_anchor_ext_r - 3'd1;
                            ws_anchor_to_r  <= ws_anchor_to_load;
                        end else if (ws_anchor_retry_r != 3'd0) begin
                            // FIX-3 BOUNDED CLEAR-RETRY (2026-07-03): the
                            // anchor did not latch in this wait — re-pulse
                            // the F3 clear and re-wait (up to
                            // WS_ANCHOR_RETRIES=5 attempts, R-A) before
                            // failing open. Drop the clear level and
                            // hold it LOW in WS_FIN_CLRLOW so the destination
                            // 2-FF level sync + edge-detect re-arms; the next
                            // rise is a FRESH clear pulse. Beacons are never
                            // dark (FIX-2: the peer's idle-gated SYNC-insert
                            // is permanent + force-SYNC is still held HERE),
                            // so a late-arriving peer's beacons make the
                            // retry meaningful — this is exactly the
                            // arm-stagger starvation window the old fail-open
                            // turned into a dead, unanchored bootstrap.
                            // R-A (2026-07-04): a retry fired while the
                            // anchor was ALREADY latched = the verify (not
                            // the anchor) held the release — the wrong-slot
                            // mis-anchor signature. Latch the sticky obs
                            // (0x21B8[9]); the re-clear drops BOTH the
                            // deskew's sync_idx/reanchored AND the
                            // anchor-verify sticky (same sync_obs_clr edge),
                            // so the re-anchor re-rolls the per-lane slot
                            // confirm from scratch.
                            // FIX-4 (2026-07-04): DECORRELATE the attempts —
                            // extend the clear-low hold by the LFSR jitter
                            // (ws_jitter_w, sampled HERE) so the next
                            // window's clear pulse lands at a different
                            // phase vs SYNC_PERIOD and vs the peer's
                            // repeating traffic pattern (the old constant
                            // WS_CLR_HOLD = exactly 16 SYNC periods @8:1 =
                            // zero grid phase shift -> all 5 attempts
                            // lock-stepped onto the same alias — see the
                            // FIX-4 block above). Count the attempt into
                            // the per-episode 0x21B8[13:11] observability
                            // counter (saturating).
                            if (ws_anchor_q)
                                ws_vfy_retry_q <= 1'b1;
                            ws_anchor_retry_r <= ws_anchor_retry_r - 3'd1;
                            ws_retry_cnt_q    <= (ws_retry_cnt_q == 3'd7)
                                                 ? 3'd7 : ws_retry_cnt_q + 3'd1;
                            ws_obs_clr_r      <= 1'b0;
                            ws_anchor_to_r    <= ws_clr_hold_load + ws_jitter_w;
                            ws_state_r        <= WS_FIN_CLRLOW;
                        end else if (role_is_master && !ws_anchor_q
                                     && !ws_rdv_timeout_q
                                     && peer_ready_to_serve_w) begin
                            // FIX-B (2026-07-07 PEER-READY ENTRY GATE): only fall
                            // into the serve rendezvous when the PEER has actually
                            // advertised READY-TO-SERVE (peer_ready_to_serve_w =
                            // its SWI_LANE_STATUS[27], captured by our ST_FIN_RDV
                            // poll = its winscan is DONE and it is in data mode,
                            // able to quiesce+serve). Without this term a
                            // FIRST-armed die whose peer is STILL ARMING (peer[27]
                            // =0, cannot serve) fell into WS_FIN_WAITPEER, stalled
                            // for the whole rendezvous window, and its Phase-2
                            // re-clear destroyed the sticky anchor that would else
                            // late-heal — the die_b first-armed 83%→58% regression.
                            // With peer_ready=0 this arm is FALSE and control falls
                            // through to the BASE fail-open (~4659, Loop-14 83%
                            // path: sticky anchor PRESERVED). Only the 2nd-armed
                            // die (peer already in data mode) takes the serve.
                            //
                            // R-B ASYMMETRIC PEER-SERVE FALLBACK (2026-07-07
                            // rev2): the MASTER exhausted ALL its local
                            // clear-retries WITHOUT ever anchoring
                            // (ws_anchor_q==0) — the die_a beacon-starvation
                            // signature: the peer's keepalive occupied every
                            // idle slot so no commit-able periodic beacon ever
                            // reached the master's post-clear re-confirm
                            // (sync_seen stayed 0x00). Do NOT fail open into an
                            // UNANCHORED fch bootstrap (dead data). Fall to the
                            // peer-serve rendezvous: park in WS_FIN_WAITPEER,
                            // which advertises ws_fin_wait_lvl so the autoneg
                            // (ST_FIN_RDV/GO) polls die_b's ready-to-serve bit
                            // and writes the slave's FINALIZE_GO. die_b then
                            // FORCES SYNC (ws_serve_active_r, its FC left UP)
                            // every grid slot toward the master — beating its
                            // keepalive — and the master re-confirms over those
                            // served beacons IN WS_FIN_WAITPEER (Phase-2) before
                            // releasing to WS_DONE. Drop the F3 clear level to 0
                            // on entry so WS_FIN_WAITPEER lands in Phase-1
                            // (wait-for-GO) and re-raises a FRESH clear edge when
                            // the serve arrives (the local finalize left
                            // ws_obs_clr_r HIGH). KEEP winscan_force_sync HELD
                            // (do NOT drop it) so the master's own TX stays clean
                            // SYNC toward the slave through the rendezvous.
                            // ws_rdv_to_r bounds the wait; on its expiry the
                            // WS_FIN_WAITPEER Phase-1 fail-loud latches
                            // ws_rdv_timeout_q and returns LOCALLY to WS_FINALIZE
                            // (never a fcsm=2 wedge / deadlock). The
                            // !ws_rdv_timeout_q guard means a peer that never
                            // serves is tried EXACTLY ONCE per episode — a
                            // subsequent local exhaustion then takes the base
                            // fail-loud release below (no livelock). A master
                            // that DID anchor locally (ws_anchor_q==1 — the
                            // verify held the release, not the anchor) is HEALTHY
                            // and takes the base fail-open below.
                            ws_obs_clr_r <= 1'b0;
                            ws_rdv_to_r  <= ws_rdv_to_load;
                            ws_state_r   <= WS_FIN_WAITPEER;
                        end else begin
                            // F4 FAIL-LOUD timeout (retries exhausted): the
                            // anchor never (re-)latched (dead sync_obs_clr
                            // routing / un-anchorable eye / beacon-less
                            // zombie peer). Release anyway — never-done would
                            // DEADLOCK the fch_pending_r handoff gate — and
                            // latch the sticky observability bit (WINSCAN_OBS
                            // 0x21B8[2]). The anchor can still latch LATE on
                            // the permanent idle-gated beacons (FIX-2; the
                            // reanchored latch has no time veto) — a late
                            // rise with fch_done_r already set latches
                            // ws_anchor_late_q (0x21B8[3]). This is the base
                            // 788eb7e behavior for the SLAVE, and for a master
                            // that anchored locally or already tried the
                            // rendezvous once (ws_rdv_timeout_q).
                            winscan_force_sync  <= 1'b0;
                            ws_anchor_timeout_q <= 1'b1;
                            winscan_done        <= 1'b1;
                            ws_state_r          <= WS_DONE;
                        end
                    end else begin
                        ws_anchor_to_r <= ws_anchor_to_r - 24'd1;
                    end
                end
                // -------------------------------------------------------------
                WS_FIN_CLRLOW: begin
                    // FIX-3: hold the F3 clear LOW (ws_anchor_to_r reused as
                    // the hold counter — FIX-4: loaded with base hold +
                    // per-attempt LFSR jitter at the retry arc, so this
                    // dwell is what decorrelates consecutive attempts), then
                    // re-raise it and re-enter the
                    // FINALIZE anchor poll with a fresh timeout. force-SYNC
                    // and tap ownership stay held throughout (still FINALIZE
                    // in spirit); winscan_done stays 0 (fch stays blocked).
                    if (ws_anchor_to_r != 24'd0) begin
                        ws_anchor_to_r <= ws_anchor_to_r - 24'd1;
                    end else begin
                        ws_obs_clr_r   <= 1'b1;   // fresh clear pulse at dest
                        ws_anchor_to_r <= ws_anchor_to_load;
                        // FIX-4b (2026-07-05) — RE-CLEAR SETTLE. Do NOT poll
                        // the release gate right after re-entry: the fresh
                        // clear pulse is IN FLIGHT for ~2-3 LINK-clock cycles
                        // (apb->link 2-FF level sync + edge detect) and only
                        // then drops the deskew `reanchored` AND the anchor-
                        // verify sticky (same sync_obs_clr edge) — so
                        // ws_anchor_q / ws_verify_q read STALE pre-clear
                        // values for tens of apb cycles after re-entry. The
                        // old '0 dwell ("skip the F3b dwell") let the FSM
                        // release winscan_done on that stale pair whenever
                        // the verify latched during the clear-low hold (a
                        // marginal lane finally confirming — or t33e's
                        // released force); the in-flight clear then landed
                        // POST-RELEASE and wiped the anchor under the
                        // bootstrapping link (t33e wedge signature: slave
                        // anc_late=1 late-heal, master rea=0 starved under
                        // data-mode traffic). LATENT race predating FIX-4 —
                        // the retry jitter merely moved the window phases
                        // onto it. Settle for ws_clr_hold_load (the SAME
                        // constant already sized ">> the slowest link-clock
                        // 2-FF window" for exactly this CDC path) so the
                        // first release poll strictly follows the LANDED
                        // clear and reads genuinely post-clear anchor+verify
                        // state. The first window's 0.5 s F3b entry dwell
                        // already provides this settle at FINALIZE entry —
                        // retries now do too. Cost: +82 us/retry (silicon).
                        ws_dwell_r     <= ws_clr_settle_load;
                        ws_state_r     <= WS_FINALIZE;
                    end
                end
                // -------------------------------------------------------------
                WS_FIN_WAITPEER: begin
                    // R-B ASYMMETRIC PEER-SERVE (2026-07-07 rev2) — MASTER-ONLY
                    // FALLBACK. The slave never enters this state; the master
                    // enters ONLY from the WS_FINALIZE fail-open arm above and
                    // ONLY when its LOCAL finalize STARVED (role_is_master &&
                    // ws_anchor_q==0 — the die_a beacon-starvation case), with
                    // ws_obs_clr_r dropped to 0 on entry so it lands in Phase-1
                    // below. Two sub-phases keyed on ws_obs_clr_r:
                    //
                    // PHASE-1 (!ws_obs_clr_r) — WAIT FOR THE PEER TO SERVE.
                    //   fch_quiesce_req does NOT cover this state (it covers only
                    //   WS_FINALIZE/WS_FIN_CLRLOW), so on entry the master's LL
                    //   comes OUT of the finalize-window swreset — its WS_DONE
                    //   bootstrap then runs the NORMAL widx-0 full walk (with the
                    //   R4c cross-die overlap dwell) that aligns the credit
                    //   handshake, NOT the widx-1 quiesced bootstrap that
                    //   deadlocked the master FC at fcsm=2 in multi-episode
                    //   retry. The master holds winscan_force_sync through this
                    //   state so its own TX stays clean SYNC anyway. It
                    //   advertises ws_fin_wait_lvl. Its autoneg (ST_FIN_RDV/GO)
                    //   polls the slave's ready-to-serve bit (SWI_LANE_STATUS
                    //   [27]) and writes the slave's FINALIZE_GO, which sets the
                    //   slave's ws_serve_active_r (die_b quiesces + serves
                    //   idle-gated beacons every grid slot toward us) and raises
                    //   the master's own nego_fin_go_w. On GO: raise the F3
                    //   clear (drops our sticky anchor + verify — see the F3
                    //   comment in WS_NEXT_LANE_ENTER), settle for the FIX-4b
                    //   re-clear window (ws_clr_settle_load — the landed-clear
                    //   CDC guard), arm the F4 anchor timeout + FIX-3/FIX-4
                    //   retry budget as a safety net, and stay in-state to
                    //   re-confirm (Phase-2) OVER THE SERVED BEACONS. This
                    //   re-confirm happens HERE, never in WS_FINALIZE, so the
                    //   peer's keepalive never occupies the link while the
                    //   master re-anchors. FAIL-LOUD: ws_rdv_to_r expiry (dead/
                    //   V1/zombie/manual peer that never serves) latches
                    //   ws_rdv_timeout_q (0x21B8[10]) and proceeds LOCALLY into
                    //   WS_FINALIZE with the F3b dwell — exact b55cb59 fallback,
                    //   never deadlocks.
                    //
                    // PHASE-2 (ws_obs_clr_r) — RE-CONFIRM OVER THE SERVED
                    //   BEACONS. Settle the clear (ws_dwell_r), then release the
                    //   moment ws_anchor_q && ws_verify_q read 1 by raising
                    //   winscan_done DIRECTLY and going to WS_DONE (dropping
                    //   force here) — deliberately NOT via WS_FINALIZE, whose
                    //   fch_quiesce_req would spuriously quiesce the master's LL
                    //   and force its bootstrap to widx 1 (the fcsm=2 credit
                    //   deadlock). The F3 clear was a single rising edge in
                    //   Phase-1 and is not re-pulsed, so the anchor is not
                    //   re-dropped. If the re-confirm times out (ws_anchor_to_r
                    //   ==0 — should not happen once the peer serves) fall to
                    //   WS_FINALIZE and let the legacy FIX-3/FIX-4 retry
                    //   machinery run (retry budget was armed in Phase-1).
                    if (!ws_obs_clr_r) begin
                        if (nego_fin_go_w) begin
                            // GO landed (peer serving). Raise the F3 clear and
                            // re-confirm HERE (no FC quiesce — see the
                            // ws_fin_wait_lvl / fch_quiesce_req comments).
                            ws_obs_clr_r      <= 1'b1;              // F3 clear (one rising edge)
                            ws_dwell_r        <= ws_clr_settle_load; // FIX-4b landed-clear settle
                            ws_anchor_to_r    <= ws_anchor_to_load;  // Phase-2 anchor-gate window
                            ws_anchor_retry_r <= WS_ANCHOR_RETRIES;  // legacy-retry safety net
                        end else if (ws_rdv_to_r == 29'd0) begin
                            // FIX-C (2026-07-07 BOUNDED FALLBACK EXIT): the peer
                            // never served within the rendezvous window. Do NOT
                            // return to WS_FINALIZE for a SECOND anchor-clearing
                            // retry storm (which re-pulsed ws_obs_clr_r, wiping the
                            // sticky anchor that could still late-heal, and re-armed
                            // the whole FIX-3/FIX-4 budget for a second time). Go
                            // DIRECTLY to fail-open: keep the latched anchor (do NOT
                            // re-pulse ws_obs_clr_r), drop force, latch the sticky
                            // obs, raise winscan_done → WS_DONE. This caps the
                            // fallback's worst case at "Loop-14 base fail-open +
                            // ONE bounded wait". ws_rdv_timeout_q records that the
                            // rendezvous was attempted-and-timed-out (0x21B8[10]).
                            winscan_force_sync  <= 1'b0;
                            ws_rdv_timeout_q    <= 1'b1;
                            ws_anchor_timeout_q <= 1'b1;
                            winscan_done        <= 1'b1;
                            ws_state_r          <= WS_DONE;
                        end else begin
                            ws_rdv_to_r <= ws_rdv_to_r - 29'd1;
                        end
                    end else begin
                        if (ws_dwell_r != '0) begin
                            ws_dwell_r <= ws_dwell_r - {{(WS_DW_W-1){1'b0}}, 1'b1};
                        end else if (ws_anchor_q && ws_verify_q) begin
                            // Re-confirm succeeded over the served beacons.
                            // Raise winscan_done DIRECTLY and go to WS_DONE —
                            // do NOT pass through WS_FINALIZE (that state's
                            // fch_quiesce_req would trigger a spurious LL
                            // quiesce, forcing the bootstrap to widx 1 and the
                            // fcsm=2 credit deadlock). Drop force here (host
                            // R8=0x14): the anchor is sticky and STAYS up.
                            winscan_force_sync <= 1'b0;
                            winscan_done       <= 1'b1;
                            ws_state_r         <= WS_DONE;
                        end else if (ws_anchor_to_r == 24'd0) begin
                            // FIX-A (2026-07-07 LIVELOCK BREAK): the Phase-2
                            // re-confirm over the served beacons timed out. LATCH
                            // ws_rdv_timeout_q so the ~4619 fallback guard
                            // (!ws_rdv_timeout_q) trips — the rendezvous is tried
                            // EXACTLY ONCE per episode. Without this the return to
                            // WS_FINALIZE with the fallback still open re-issued
                            // the serve GO every cycle (WS_FIN_WAITPEER<->
                            // WS_FINALIZE ping-pong → winscan_done never asserts
                            // = NODONE livelock, and each re-entry re-thrashed
                            // die_b's credit). With the sticky set, the next
                            // WS_FINALIZE retry-exhaustion takes the BASE fail-loud
                            // arm (~4659: winscan_done<=1, ws_anchor_timeout_q<=1,
                            // keep the latched anchor, →WS_DONE) — no deadlock.
                            ws_rdv_timeout_q <= 1'b1;
                            ws_state_r       <= WS_FINALIZE;
                        end else begin
                            ws_anchor_to_r <= ws_anchor_to_r - 24'd1;
                        end
                    end
                end
                // -------------------------------------------------------------
                WS_DONE: begin
                    // Hold the picked taps + winscan_done for the episode. A new
                    // training episode (rise→fall) re-kicks via ws_kicked_q.
                    winscan_owns_taps  <= 1'b1;
                    winscan_force_sync <= 1'b0;
                    winscan_done       <= 1'b1;
                    ws_obs_clr_r       <= 1'b0;  // F3: drop the level (re-arms the
                                                 // destination edge-detect for the
                                                 // next episode's single pulse)
                    if (ws_arm_req) begin
                        ws_kicked_q  <= 1'b1;
                        winscan_done <= 1'b0;
                        ws_state_r   <= WS_ARM;
                    end
                end
                default: ws_state_r <= WS_IDLE;
            endcase

            // SAME-CYCLE STALE-DONE MASK (2026-07-03, placed AFTER the case so
            // it wins any same-cycle case assignment): a fresh gated kick
            // (ws_kick_evt) must suppress winscan_done THE CYCLE IT FIRES.
            // The FSM arms off the 1-cycle-delayed sticky, but fch_pending_r
            // latches off the SAME training fall with no delay — without this
            // override fch_arm would see pending=1 & the STALE episode's
            // winscan_done=1 for one cycle and re-run the bootstrap against
            // the old episode (the BUG-A re-run, reintroduced as a 1-cycle
            // race). Also closes the kick-lands-on-the-FINALIZE-release-cycle
            // corner (the case's winscan_done<=1 is overridden; the WS_DONE
            // arm then consumes the pending next cycle and re-arms cleanly).
            if (ws_kick_evt)
                winscan_done <= 1'b0;
        end
    end
`else
    // V1: no winscan FSM ⇒ no finalize window ⇒ the Q1 quiesce request never
    // fires — the fch sequencer's IDLE quiesce/release arms are dead logic
    // and the V1 bootstrap walk is bit-identical (fch_quiesced_r can never
    // set, so the walk always starts at widx 0 with the full R4c dwell).
    assign fch_quiesce_req = 1'b0;
    // R-B: no WS_FIN_WAITPEER on V1 — the exported quiesced-in-wait level is
    // tied 0 (SWI_LANE_STATUS[27] keeps pkt_is_cr on V1, and the autoneg's
    // rendezvous entry arc is USE_CAL_IN_HOLD(=0)-gated, so local_fin_wait_i
    // is never consumed); the autoneg fin_go_o output is sunk.
    assign ws_fin_wait_lvl = 1'b0;
    // FIX-B: no finalize FSM on V1 ⇒ the broadened poll level is tied 0 (the
    // autoneg's ST_FIN_RDV entry arc is USE_CAL_IN_HOLD(=0)-gated anyway, and
    // peer_ready_to_serve_o = peer_fin_wait_r stays 0 on V1).
    assign ws_finalizing_lvl = 1'b0;
    wire _unused_nego_fin_go = nego_fin_go_w;
`endif

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

    // Phase 7b (2026-06-29): sticky "calibrator converged" latch, used to
    // suppress the destructive ST_TRAIN_EXIT re-sweep (see u_calibrator
    // .swreset below). Set once the calibrator reaches S_DONE (cal_state==4),
    // 2-FF-synced from the rx_link_clk domain into apb_clk (slow-moving FSM
    // state — same CDC treatment as the existing sync_lane_locked / sync_cal
    // chains). We use S_DONE rather than all-lanes-locked because the
    // calibrator can legitimately reach S_DONE via its validation path even
    // when the lane_checker's live lane_locked has dropped (training pattern
    // gone) — S_DONE is the authoritative "calibration complete" signal.
    // It is a LATCH so the converged status survives the lane_checker /
    // training-pattern teardown that precedes local_swreset_pulse_w.
    // Cleared on a manual SW recal (swi_recal_r) or POR — so a deliberate
    // re-cal always re-opens the re-sweep path.
    //
    // COMPATIBILITY with the V2 calibrator credit-fix (calibrated_once_q in
    // deps/tidelink-phy and src/rtl tidelink_phy_align_calibrator.sv): that
    // fix masks the calibrator's role_locked_rise / swreset_fall re-arm edges
    // DOWNSTREAM (inside the calibrator) once it has converged. This gate
    // masks the local_swreset_pulse_w re-sweep UPSTREAM (it never reaches the
    // .swreset port once converged). They are belt-and-suspenders — both
    // prevent the same spurious post-training re-sweep, and neither conflicts
    // with the other (both are pure "do not re-arm a converged eye"). Kept
    // both per the integration note; the upstream gate also protects the
    // trunk-build path and is robust if the submodule credit-fix is ever
    // reverted.
    localparam [3:0] CAL_S_DONE = 4'd4;
    reg cal_done_state_meta_r, cal_done_state_sync_r;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn) begin
            cal_done_state_meta_r <= 1'b0;
            cal_done_state_sync_r <= 1'b0;
        end else begin
            cal_done_state_meta_r <= (cal_state_w == CAL_S_DONE);
            cal_done_state_sync_r <= cal_done_state_meta_r;
        end
    end

    reg cal_eye_converged_r;
    always_ff @(posedge apb_clk or negedge poresetn) begin
        if (!poresetn)
            cal_eye_converged_r <= 1'b0;
        else if (swi_recal_r)
            cal_eye_converged_r <= 1'b0;   // manual re-cal re-arms the sweep
        else if (cal_done_state_sync_r)
            cal_eye_converged_r <= 1'b1;   // sticky: reached S_DONE at least once
    end

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
`ifdef TIDELINK_PHY_V2
    // =====================================================================
    // S3 PHY swap (2026-06-11): deps/tidelink-phy calibrator (FIX-series,
    // always-on FSM, silicon-validated with the FIX-N..R serdes). Instance
    // name u_calibrator preserved — cocotb hierarchical force paths depend
    // on it. Port-map deltas vs V1 (see docs of feat/s3-phy-swap):
    //   cr_pkt_seen_i  <= cr | crack   (preserves the V1 A2 oracle)
    //   swi_training_hold_i <= swi_training_mode_r (Region 8 bit = hold,
    //                          mirroring the BIST CTRL[6] semantics; the
    //                          OR-merge into the PHY drive remains below)
    //   lane_mask      <= wlink_rx_lane_mask (resets 8'hFF pre-handshake)
    //   sync/lane_synced/pin_converge: opt-in BIST features, tied off
    //   RETIRED: dwell_min_dist_i, min_lock_dwells_i (M11b knob — register
    //   retained, consumer V1-only), crack_pkt_seen_i, resweep_ctr_o,
    //   eye-vis surface (AUDIT #17) — Region C OBS_CAL + eye outputs RAZ.
    // =====================================================================
    // SoC Labs 2026-06-18 — VAL_TIMEOUT_TO_DONE(1'b1): break the cal_done/lltx
    // deadlock seen on silicon. wlink_lltx_enable is gated by calibration_done,
    // but the S_VALIDATE oracle is the FCSM CR handshake which needs lltx — a
    // pure circular deadlock (both peers sit in S_VALIDATE forever, cal_done
    // never asserts, no CR). With VAL_TIMEOUT_TO_DONE=1 (MAX_RESWEEPS=0 default),
    // a val_ctr timeout WITHOUT validate_confirm latches terminal S_DONE,
    // asserting calibration_done so lltx enables and CR can run. HW equivalent
    // of the sim tb_early_exit_force_q bypass. M8 give-up policy; sim-clean.
    tidelink_phy_align_calibrator #(
        .VAL_TIMEOUT_TO_DONE (1'b1),
        // FIX D (2026-08-07, TL-009): peer-aware S_HOLD release — hold training
        // past HOLD_MAX until all active lanes are LOCKED (peer present+clean),
        // backstop-bounded. Widens the bilateral overlap so W+B cross on a ms-skew
        // bring-up (fixes the framing lottery -> data-drop + write-stall wedge).
        .HOLD_PEER_AWARE_EN  (1'b1)
    ) u_calibrator (
        .clk                    (phy_link_rx_rx_link_clk_w),
        .rst                    (~poresetn),
        .role_locked            (calibrator_role_locked),
        // Phase 7b (2026-06-29): gate the ST_TRAIN_EXIT re-sweep on the sticky
        // cal_eye_converged_r latch (reached S_DONE). local_swreset_pulse_w is
        // pulsed by the autoneg FSM at ST_TRAIN_EXIT to RE-ARM a calibrator
        // that had NOT yet converged (G1 intent). On the autonomous path the
        // calibrator reliably reaches S_DONE DURING training; firing the
        // re-sweep AFTER training_mode drops then sweeps against non-training
        // traffic, finds no eye, and the RX never re-locks (master cal=SWEEP,
        // locked=0x00, crack=0 → no S→M data). Suppressing the re-sweep once
        // converged preserves the eye through the FC data-mode handoff.
        // Additive: swi_recal_r (manual recal) untouched and also clears the
        // latch; the not-yet-converged re-arm still fires as before. Works
        // alongside the calibrator's own calibrated_once_q credit-fix (which
        // masks the same re-arm downstream).
        //
        // L4 fix (2026-07-01): the cal_eye_converged_r latch arms TOO LATE — it
        // only sets on S_DONE, but on the AUTONOMOUS path the autoneg fires the
        // ST_TRAIN_EXIT re-sweep the instant the both-in-S_HOLD rendezvous
        // succeeds, i.e. while the calibrator is still in S_HOLD/S_VALIDATE
        // (BEFORE S_DONE). So the guard is 0 and the destructive pulse passes,
        // kicking the master back to S_ARM to sweep against a peer that already
        // dropped training → death spiral (de-forced test_31). Also mask on
        // sync_cal_in_hold_1 = "locally PARKED" (S_HOLD|S_VALIDATE|S_DONE): by
        // the time ST_TRAIN_EXIT fires, the rendezvous predicate has ALREADY
        // proven the local die is parked with all active lanes locked, so a
        // re-sweep is never wanted. A genuinely-unconverged die is NOT parked
        // (cal_in_hold=0) so the legitimate "never-locked" re-arm still fires.
        .swreset                (swi_recal_r |
                                 (local_swreset_pulse_w &
                                  ~(cal_eye_converged_r | sync_cal_in_hold_1))),
        .lane_locked            (lane_locked_w),
        .lane_mask              (wlink_rx_lane_mask),
        .apb_bit_slip_override  (24'h0),
        .apb_override_enable    (1'b0),
        // EYE-CENTRE (2026-06-17): runtime MIN_LOCK_DWELLS override from
        // Region 8 slot 3 bits [23:20] (min_lock_dwells_r). 0 = use the
        // synth-time param default (MIN_LOCK_DWELLS=2); 1..15 = runtime
        // override. Lets SW tune the eye-centre contiguity requirement (and,
        // at a large value, DISABLE the eye-centre arm for a bit-identical
        // build) without re-synth.
        .min_lock_dwells_i      (min_lock_dwells_r),
        .swi_training_hold_i    (swi_training_mode_r),
        .cr_pkt_seen_i          (obs_cr_pkt_seen_rx_w | obs_crack_pkt_seen_rx_w),
        .sync_seen_i            (1'b0),
        .lane_synced_i          (8'h00),
        .lane_pin_converge_en_i (1'b0),
        // P1 (2026-07-19): the explicit forced-recal door. Deliberately NOT
        // OR-merged with local_swreset_pulse_w or anything else — only a
        // deliberate SW write reaches it, which is what lets the calibrator
        // honour it without weakening the Bug-A calibrated_once_q guard.
        .force_recal_i          (swi_force_recal_r),
        .bit_slip               (cal_bit_slip_w),
        .phase_offset           (cal_phase_offset_w),
        .training_mode          (cal_training_mode_w),
        .calibration_done       (cal_calibration_done_w),
        // I1 winscan obs (2026-07-30): capture the sticky validation give-up flag
        // (was unconnected). Pure RO fan-out into tidelink_winscan_obs.
        .validation_timed_out   (cal_valto_w),
        .lane_fault             (cal_lane_fault_w),
        .state                  (cal_state_w),
        .sweep_active_o         (sweep_active_w),
        // EYE-WIDTH VISIBILITY (2026-06-17): real per-lane eye-width read
        // surface replacing the V1 RAZ tie-offs. eye_lane_sel picks the lane —
        // Task 3: in V2 from the APB-writable swi_eye_lane_sel_r (0x2154) so all
        // 8 lanes scan remotely; in V1 from the swi_eye_lane_sel_i input. The
        // outputs report that lane's matched-window WIDTH + start (slip,phase).
        // Combinational reads of FSM regs in the rx_link_clk domain → CDC-synced
        // to apb_clk below before the APB read mux.
        .eye_lane_sel           (eye_lane_sel_eff),
        .eye_score_best         (cal_eye_best_w),
        .eye_score_best_phase   (cal_eye_best_phase_w),
        .eye_score_best_slip    (cal_eye_best_slip_w),
        .eye_score_lane_passed  (cal_eye_lane_passed_w),
        // L4 training-exit-deadlock fix (2026-07-01): expose "locally parked
        // in S_HOLD" so the autonomous autoneg FSM can rendezvous on both
        // dies being parked (see cal_in_hold_w declaration).
        .cal_in_hold_o          (cal_in_hold_w)
    );
    // Retired V1 surfaces still RAZ (resweep/eye_status/eye_score_data not
    // produced by the deps calibrator).
    assign cal_resweep_ctr_w        = 16'h0;
    assign eye_status_o             = 32'h0;
    assign eye_score_data_o         = 6'h0;
    // EYE-WIDTH VISIBILITY: drive the top-level eye_score_* observability
    // ports from the real calibrator wires (was RAZ). These feed the existing
    // eye_regs shim AND the new 0x2150 obs slot below.
    assign eye_score_lane_passed_o  = cal_eye_lane_passed_w;
    assign eye_score_best_o         = cal_eye_best_w;
    assign eye_score_best_slip_o    = cal_eye_best_slip_w;
    assign eye_score_best_phase_o   = cal_eye_best_phase_w;
`else
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
        // Phase 7b (2026-06-29): gate the ST_TRAIN_EXIT re-sweep on the sticky
        // cal_eye_converged_r latch — see the V2 calibrator above for the full
        // rationale. Same gate applied to the trunk (`else) calibrator so the
        // converged eye is preserved through the FC data-mode handoff
        // regardless of the TIDELINK_PHY_V2 build define.
        .swreset               (swi_recal_r |
                                (local_swreset_pulse_w & ~cal_eye_converged_r)),
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
        // §9.11c / M11b (2026-06-10): runtime MIN_LOCK_DWELLS override from
        // Region 8 slot 3 bits [23:20] (min_lock_dwells_r). NOT
        // nego_train_cfg_r[7:4] — that nibble is the autoneg FSM's
        // train_poll_timeout.
        // 0 = use parameter default (now MIN_LOCK_DWELLS=2); 1..15 = runtime override.
        // Allows SW to lower the eye-centre contiguity requirement on marginal-eye
        // hardware (die_a 2-3 consecutive passing phases < old default of 4).
        .min_lock_dwells_i     (min_lock_dwells_r),
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
        // P1 (2026-07-19): explicit forced-recal door — see the V2 instance
        // above. The V1 src/rtl calibrator carries the IDENTICAL
        // calibrated_once_q sticky, so the V1/trunk build needs the same fix.
        .force_recal_i         (swi_force_recal_r),
        .bit_slip              (cal_bit_slip_w),
        .phase_offset          (cal_phase_offset_w),
        .training_mode         (cal_training_mode_w),
        .calibration_done      (cal_calibration_done_w),
        // I1 winscan obs (2026-07-30): sticky validation give-up flag (RO tap).
        .validation_timed_out  (cal_valto_w),
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
    // L4 training-exit-deadlock fix (2026-07-01): the V1 (else) calibrator does
    // not expose cal_in_hold_o (the autonomous training-exit rendezvous is a
    // V2-only path). Tie the unconditionally-declared wire off so it is never
    // floating in a V1 build.
    assign cal_in_hold_w = 1'b0;
`endif

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
    // SoC Labs TideChart sequencing contract 2026-07-17 — data-mode strobe.
    // `>= 3'd4` over a 3-bit state reduces to bit [2]; written that way so the
    // synthesised result is a direct flop output (glitch-free, apb_clk domain)
    // rather than a multi-bit comparator over a partially-updated CDC word.
    // Pure ADD: no existing net is re-driven or re-timed by this assignment.
    assign data_mode_o                 = sync_obs_fcsm_state_1[2];

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
`ifdef TIDELINK_PHY_V2
    // AUTONOMOUS WINSCAN tap override (2026-06-29): when the on-chip winscan FSM
    // owns the taps (autonomous nego path only — winscan_owns_taps is 0 on the
    // SW/host path so this is bit-identical there), mux the FSM's per-lane
    // nibble in place of the APB-written swi_phase_offset_r. The cal_phase_
    // offset_w OR-merge is PRESERVED so the effective tap matches the host
    // winscan exactly (host RMWs swi_phase_offset_r, which is likewise OR'd
    // with the settled calibrator phase). winscan_owns_taps=0 => identical to
    // the historical cal | swi_phase_offset_r.
    wire [31:0] phase_offset_sel = winscan_owns_taps ? ws_phase_offset_r
                                                     : swi_phase_offset_r;
    assign      swi_phase_offset_w  = cal_phase_offset_w  | phase_offset_sel;
`else
    assign      swi_phase_offset_w  = cal_phase_offset_w  | swi_phase_offset_r;
`endif
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
    // AUTONOMOUS WINSCAN tap-LSB override (2026-06-29): mux the FSM's per-lane
    // LSB while the winscan owns the taps; bit-identical (= swi_phase_lsb_r)
    // when dormant and in V1 (where the FSM is absent and ws_* don't exist).
`ifdef TIDELINK_PHY_V2
    wire [7:0] phase_lsb_eff = winscan_owns_taps ? ws_phase_lsb_r : swi_phase_lsb_r;
`else
    wire [7:0] phase_lsb_eff = swi_phase_lsb_r;
`endif
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
        // FULL-RANGE TAP LSB (2026-06-25): per-lane tap bit[0] so the IDELAY tap
        // reaches odd values + the upper half (0..31). swi_phase_lsb_r is
        // declared in BOTH builds; reset 0 => even-only tap (bit-identical) and
        // in V1 it has no write path so it stays 0 forever.
        .lsb_i          (phase_lsb_eff),
        .pad_rx_i       (pad_rx),
        .pad_rx_o       (pad_rx_dly)
    );

    // Interim phy_align shim removed: Wlink owns the entire APB region
    // again (no paddr[12] split, no response mux). External APB response
    // passes Wlink straight back, stalled when the I²C slave bridge is
    // active.
    // SoC Labs 2026-07-09 (ported from f1b3aac): STALL the external (PS) APB
    // while the fch sequencer owns the Wlink APB. Previously apb_pready passed
    // wl_apb_pready straight through with no arbitration term, so a PS access
    // landing during the fch burst would complete against the SEQUENCER's
    // transaction (returning its prdata / consuming its pready) -- an APB
    // protocol violation. Holding pready low stalls the PS access until the bus
    // is handed back, which is the normal APB way to backpressure. Bounded by
    // the FCH_ACCESS watchdog above, so this can never become the permanent
    // lockout it replaces. In V1 / manual (autonomy off) the fch sequencer never
    // arms, so fch_active_r stays 0 and apb_pready is bit-identical to before.
    assign apb_prdata  = wl_apb_prdata;
    assign apb_pready  = (fch_active_r || slv_apb_active) ? 1'b0 : wl_apb_pready;
    assign apb_pslverr = (fch_active_r || slv_apb_active) ? 1'b0 : wl_apb_pslverr;

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
    Wlink #(.USE_CLKBUF(USE_CLKBUF), .USE_T3A(USE_T3A), .EPOCH_ANCHOR_EN(EPOCH_ANCHOR_EN)) u_wlink (
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
`ifdef TIDELINK_PHY_V2
        // S3 PHY swap: global word-window pin. Default = autonomous
        // WORD_PIN_AUTO (FIX-R-proper). SW override (mirrors the proven BIST
        // BIT_SLIP_OVR[28:24] layout) for the marginal-direction word-phase
        // that auto's exact-match can't commit on silicon (v36 finding):
        //   SWI_BIT_SLIP_LO[27:24] = manual word pin, [28] = auto-disable.
        .swi_word_pin_in            (swi_word_pin_ovr_r),
        .swi_word_pin_auto_en       (~swi_word_pin_auto_dis_r),
        // SoC Labs SYNC-insert (V2 LL re-hunt beacon, 2026-06-15) — DEFAULT-OFF.
        // Region 8 slot 0 bit[2] SWI_SYNC_INSERT_EN (MMIO 0x4403_2100). When 0
        // the PHY SYNC inserter is a pure passthrough so the TX datapath is
        // bit-identical to today. No calibrator OR-merge — pure SW strap.
        // AUTONOMOUS WINSCAN (2026-06-29): OR winscan_force_sync into the three
        // SYNC controls so the on-chip scan replicates the host's R8=0x1C
        // (insert_en + force_always + robust_detect all ON while scanning); the
        // FSM drops winscan_force_sync at the FINALIZE EXIT (F3/F4 2026-07-02:
        // held through FINALIZE so the post-clear `reanchored` re-confirm sees
        // on-grid beacons; = the host's R8=0x14 once anchored, force_always
        // back to idle-gated strictly before winscan_done/the bootstrap).
        // winscan_force_sync=0 when the FSM is dormant => bit-identical.
        // R-B ASYMMETRIC PEER-SERVE (2026-07-07): the SLAVE also ORs
        // ws_serve_active_r here so that, on the master's FINALIZE_GO, it
        // FORCES SYNC every grid slot (insert_en + force_always + robust)
        // toward the master REGARDLESS of its keepalive/idle — beating the
        // keepalive that was occupying its idle slots (the die_a starvation) —
        // WITHOUT quiescing its FC. Its FC stays UP (RX live) so it still
        // receives the master's credit and reaches fcsm=4; the forced-SYNC
        // window only briefly pre-empts its own FC TX (resumed on serve exit).
        .swi_sync_insert_en_in      (swi_sync_insert_en_r | winscan_force_sync | ws_serve_active_r | auto_anchor_pulse_q),
        // SoC Labs SYNC-insert GATE FIX (2026-06-15, PART 2) — DEFAULT-OFF.
        // Region 8 slot 0 bit[3] SWI_SYNC_FORCE_ALWAYS (MMIO 0x4403_2100). When
        // 0 the SYNC beacon keeps its idle-gated production behaviour
        // (bit-identical); when 1 the PHY drops the idle gate so the beacon
        // fires on enable alone (still self-gates ~training). Pure SW strap.
        .swi_sync_force_always_in   (swi_sync_force_always_r | winscan_force_sync | ws_serve_active_r | auto_anchor_pulse_q),
        // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PARTs 2/3) —
        // SW LANE_MASK strap (Region 9 slot 2, 0x44032128, default 0xFF) +
        // SWI_SYNC_ROBUST_DETECT (Region 8 slot 0 bit[4], default 0). Default
        // (mask=0xFF, robust=0) -> bit-identical datapath.
        .swi_sync_lane_mask_in      (swi_sync_lane_mask_r),
        // SoC Labs RX SYNC-detect Hamming TOLERANCE (2026-06-17). SoC 0x44032128
        // [12:8]. Reset 0 (exact) -> bit-identical. Sweep 0..5 on marginal silicon.
        .swi_sync_tol_in            (swi_sync_tol_r),
        .swi_sync_robust_detect_in  (swi_sync_robust_detect_r | winscan_force_sync | ws_serve_active_r | auto_anchor_pulse_q),
`endif
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
        .obs_a2l_replay_app_valid_o  (obs_a2l_replay_app_valid_w),
        // SoC Labs V2 data-send observation 2026-06-21 — a2l replay app_ready /
        // link_empty taps (read-only; consumed by the Region 10 APB read mux).
        .obs_a2l_replay_app_ready_o  (obs_a2l_replay_app_ready_w),
        .obs_a2l_replay_link_empty_o (obs_a2l_replay_link_empty_w),
        // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 — a2l replay
        // raw write ptr / synced ACK ptr / full / enable demet (read-only;
        // packed into the spare bits of the 0x2158 word by the Region 10 mux).
        .obs_a2l_wptr_o              (obs_a2l_wptr_w),
        .obs_a2l_synced_ack_o        (obs_a2l_synced_ack_w),
        .obs_a2l_full_o              (obs_a2l_full_w),
        .obs_a2l_enable_app_demet_o  (obs_a2l_enable_app_demet_w),
        // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation
        // 2026-06-21 — a2l replay read-side reset / LINK read ptr (read-only;
        // packed into the spare bits of the 0x2158 word by the Region 10 mux).
        .obs_a2l_rreset_o            (obs_a2l_rreset_w),
        .obs_a2l_rptr_o              (obs_a2l_rptr_w),
        // SoC Labs FC credit observation 2026-06-12
        .obs_fe_rx_ptr_o             (obs_fe_rx_ptr_w),
        // SoC Labs RX-FRAMER long-DATA STICKY CAPTURE 2026-06-21 (rxcap)
        .obs_rxcap0_o                (obs_rxcap0_w),
        .obs_rxcap1_o                (obs_rxcap1_w),
        .obs_fcsmcap_o               (obs_fcsmcap_w)
`ifdef TIDELINK_PHY_V2
        // SoC Labs V2 epoch-anchor obs 2026-06-14: pass straight through to the
        // controller's output ports -> tidelink_gpio_phy_apb_regs.epoch_*_i.
        ,
        .obs_epoch_anchored_o        (obs_epoch_anchored_o),
        .obs_epoch_span_o            (obs_epoch_span_o),
        // SoC Labs SYNC-insert TX obs 2026-06-15 (PART 1): raw TX-link-clk-domain
        // probe; double-synced to apb_clk below (sync_obs_tx_sync_* regs) and read
        // at the new SYNC-OBS register (SoC MMIO 0x4403_2120).
        .obs_tx_sync_ins_cnt_o       (obs_tx_sync_ins_cnt_w),
        .obs_tx_link_idle_level_o    (obs_tx_link_idle_level_w),
        .obs_tx_training_level_o     (obs_tx_training_level_w),
        // SoC Labs RX mask-aware SYNC-beacon DETECT (2026-06-15, PART 1): raw
        // rx-link-clk-domain probe; double-synced to apb_clk below and read at
        // the new SYNC-DETECT register (SoC MMIO 0x4403_2124).
        .obs_sync_seen_cnt_o         (obs_sync_seen_cnt_w),
        .obs_sync_seen_lane_o        (obs_sync_seen_lane_w),
        // SoC Labs RX RAW-WORD + PERMUTATION obs (2026-06-15, rawobs): raw
        // rx-link-clk-domain probes; double-synced to apb_clk below and read at
        // Region 9 slots 3..7 (SoC MMIO 0x4403_212C..0x4403_213C).
        .obs_dbg_raw_word_o          (obs_dbg_raw_word_w),
        .obs_dbg_lane_any_match_o    (obs_dbg_lane_any_match_w),
        .obs_dbg_best_popcount_o     (obs_dbg_best_popcount_w),
        .obs_dbg_slice_idx_o         (obs_dbg_slice_idx_w),
        // SoC Labs PER-LANE SYNC-match sweep oracle + word-pin override
        // (2026-06-16, perlane-wp). Clear pulse (Region 8 slot 0 bit[5],
        // SoC 0x44032100[5]) + live per-lane match vector (SoC 0x44032144) +
        // per-lane word-pin override (8x4b value + 8b enable, SoC 0x44032148).
        // Default (clr=0, ovr=0, en=0) -> bit-identical datapath.
        // F3 (2026-07-02): the winscan FSM's WS_FINALIZE re-anchor drives the
        // SAME node as the manual R8 bit[5] W1-pulse — ws_obs_clr_r is a level
        // held across WS_FINALIZE (the PHY 2-FF level sync would lose a
        // 1-apb-cycle pulse; its edge-detect still makes exactly one clear
        // pulse). ws_obs_clr_r=0 whenever the FSM is dormant ⇒ bit-identical
        // manual path.
        .swi_sync_obs_clr_in         (swi_sync_obs_clr_r | ws_obs_clr_r),
        .obs_sync_lane_live_o        (obs_sync_lane_live_w),
        .swi_word_pin_ovr_in         (swi_word_pin_perlane_r),
        .swi_word_pin_ovr_en_in      (swi_word_pin_perlane_en_r),
        // SoC Labs STICKY-POISON per-lane deskew sync_seen vector (2026-06-23):
        // raw rx-link-clk-domain probe; double-synced to apb_clk below and read
        // at Region 10 slot 7 (SoC MMIO 0x4403_215C, RO).
        .obs_sync_seen_vec_o         (obs_sync_seen_vec_w),
        // DATA-MODE per-lane SYNC Hamming-distance obs (2026-06-25, winscan
        // metric): raw rx-link-clk-domain per-lane 5b distance pack; double-
        // synced to apb_clk below and read at Region D slot 3 (SoC 0x4403_21AC,
        // lane-selected by swi_dist_lane_sel_r at 0x4403_21B0).
        .obs_sync_dist_vec_o         (obs_sync_dist_vec_w),
        // R-A FINALIZE ANCHOR-VERIFY (2026-07-04): engaged-anchor exact-beacon
        // sticky from the WavD2DGpio_v2 override; 2-FF synced to apb_clk
        // (ws_verify_q) and AND'd into the winscan WS_FINALIZE release gate.
        .obs_anchor_verified_o       (obs_anchor_verified_w)
`endif
        // I1 FC-emit / router-grant observability (2026-07-30): two packed obs
        // words from the Wlink tx_link_clk-domain fcemit tap (apb_clk synced).
        // UNCONDITIONAL (like the sibling winscan obs) so it survives Vivado IP
        // packaging where a define never reaches the packaged-IP OOC synth.
        ,
        .obs_fcemit_stat_o           (obs_fcemit_stat_w),
        .obs_fcemit_idcnt_o          (obs_fcemit_idcnt_w)
    );

endmodule
