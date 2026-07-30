// -----------------------------------------------------------------------------
// TideLink FC-emit / router-grant observability (silicon item I1, H1-H4)
//
// Companion to tidelink_winscan_obs.sv. cal_done is UPSTREAM of the FCSM: this
// block only reads meaningfully once the winscan has locked (cal_done=1). It
// discriminates the four FC-emit hypotheses at the WlinkTxRouter boundary (see
// docs/I1_OBSERVABILITY_PLAN.md):
//   H1 an AXI FC node never PRESENTS a CR packet (sop dead in FSM states 0-3)
//   H2 it presents but the round-robin arbiter never GRANTS it (starvation)
//   H3 it is granted but emits a wrong data_id (CR=0x8/CRACK=0x9 defaults)
//   H4 the shared TX serializer / link-clk is gated off
//
// It taps the txrouter_auto_in_N_{sop,advance,data_id} nets plus the global
// txrouter_auto_out_advance / txrouter_io_enable — ALL are declared nets in the
// EDITABLE local-override Wlink.v (tx_link_clk domain); no deps edit, pure RO
// fan-out. Channel map (Wlink.v ~2108-2145):
//   0 AW  1 W  2 B  3 AR  4 R  |  5 general-bus  6 SIDEBAND(ch6)  7 SW-port
//
// The sop/advance handshakes are single-cycle pulses in tx_link_clk, so the
// sticky "ever presented / ever granted" detection MUST run in tx_link_clk
// (apb cannot reliably sample a 1-cycle tx-clk pulse) before the 2-flop CDC to
// apb_clk. This DOES add flops in the TX-router region (quantified in the
// integration notes); it is instantiated UNCONDITIONALLY (like the sibling
// winscan obs) because a `define never reaches the packaged-IP OOC synth, so an
// `ifdef gate would silently drop it. All outputs RO — no datapath change.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
// -----------------------------------------------------------------------------
`default_nettype none

module tidelink_fcemit_obs (
    input  wire        tx_link_clk,  // txrouter clock (detection domain)
    input  wire        apb_clk,      // register-read clock (obs output domain)
    input  wire        tx_resetn,    // active-low reset in the tx_link_clk domain
    input  wire        apb_resetn,   // active-low reset in the apb_clk domain

    // Per-channel emit-presented (SOP) — ch0..ch6
    input  wire        in0_sop, in1_sop, in2_sop, in3_sop, in4_sop, in5_sop, in6_sop,
    // Per-channel grant/advance — ch0..ch6
    input  wire        in0_adv, in1_adv, in2_adv, in3_adv, in4_adv, in5_adv, in6_adv,
    // Emitted data_id of the two decisive channels: AXI AW (ch0) + sideband (ch6)
    input  wire [7:0]  in0_id, in6_id,
    // Global serializer accept + shared TX enable
    input  wire        out_advance,  // txrouter_auto_out_advance
    input  wire        io_enable,    // txrouter_io_enable

    // FCEMIT_STAT (0x2E03_21EC) — the one-read FC verdict word:
    //   [ 4:0] axi_sop_seen   {R,AR,B,W,AW} sticky — node ever presented SOP
    //   [ 5]   sb_sop_seen                  sticky — sideband(ch6) ever SOP
    //   [ 6]   gb_sop_seen                  sticky — general-bus(ch5) ever SOP
    //   [12:8] axi_grant_seen {R,AR,B,W,AW} sticky — node ever granted+advanced
    //   [13]   sb_grant_seen                sticky — sideband ever granted
    //   [14]   gb_grant_seen                sticky — general-bus ever granted
    //   [16]   router_io_enable_lvl         live   — TX link-clk out of reset
    //   [17]   out_advance_ever             sticky — serializer accepted >=1 word
    //   [18]   any_sop_live                 live   — some channel presenting SOP now
    //   [31:24] 0xE1 presence marker
    output wire [31:0] obs_fcemit_stat,
    // FCEMIT_IDCNT (0x2E03_21F0):
    //   [ 7:0] last_id_aw[7:0]   AXI AW last emitted data_id (cf CR=0x8/CRACK=0x9)
    //   [15:8] last_id_sb[7:0]   sideband last emitted data_id
    //   [23:16] ch6_grant_cnt[7:0] sideband grant/advance count (saturating)
    //   [31:24] 0xE2 presence marker
    output wire [31:0] obs_fcemit_idcnt
);

    wire [6:0] sop_c = {in6_sop,in5_sop,in4_sop,in3_sop,in2_sop,in1_sop,in0_sop};
    wire [6:0] adv_c = {in6_adv,in5_adv,in4_adv,in3_adv,in2_adv,in1_adv,in0_adv};

    // -- tx_link_clk-domain sticky/latched detection -------------------------
    reg  [6:0] sop_seen_q;
    reg  [6:0] grant_seen_q;
    reg        out_adv_ever_q;
    reg        any_sop_live_q;
    reg  [7:0] ch6_grant_cnt_q;
    reg  [7:0] last_id_aw_q;
    reg  [7:0] last_id_sb_q;

    wire cnt_sat = (ch6_grant_cnt_q == 8'hFF);

    always_ff @(posedge tx_link_clk or negedge tx_resetn) begin
        if (!tx_resetn) begin
            sop_seen_q      <= 7'h0;
            grant_seen_q    <= 7'h0;
            out_adv_ever_q  <= 1'b0;
            any_sop_live_q  <= 1'b0;
            ch6_grant_cnt_q <= 8'h0;
            last_id_aw_q    <= 8'h0;
            last_id_sb_q    <= 8'h0;
        end else begin
            sop_seen_q     <= sop_seen_q   | sop_c;
            grant_seen_q   <= grant_seen_q | adv_c;
            out_adv_ever_q <= out_adv_ever_q | out_advance;
            any_sop_live_q <= |sop_c;
            if (in6_adv && !cnt_sat) ch6_grant_cnt_q <= ch6_grant_cnt_q + 8'h1;
            if (in0_adv) last_id_aw_q <= in0_id;   // latch AW id when it is granted
            if (in6_adv) last_id_sb_q <= in6_id;   // latch sideband id when granted
        end
    end

    // -- 2-flop CDC into apb_clk ---------------------------------------------
    reg  [6:0] sop_s0, sop_s1;
    reg  [6:0] grant_s0, grant_s1;
    reg        oae_s0, oae_s1;
    reg        asl_s0, asl_s1;
    reg        ioen_s0, ioen_s1;
    reg  [7:0] cnt_s0, cnt_s1;
    reg  [7:0] idaw_s0, idaw_s1;
    reg  [7:0] idsb_s0, idsb_s1;

    always_ff @(posedge apb_clk or negedge apb_resetn) begin
        if (!apb_resetn) begin
            sop_s0   <= 7'h0; sop_s1   <= 7'h0;
            grant_s0 <= 7'h0; grant_s1 <= 7'h0;
            oae_s0   <= 1'b0; oae_s1   <= 1'b0;
            asl_s0   <= 1'b0; asl_s1   <= 1'b0;
            ioen_s0  <= 1'b0; ioen_s1  <= 1'b0;
            cnt_s0   <= 8'h0; cnt_s1   <= 8'h0;
            idaw_s0  <= 8'h0; idaw_s1  <= 8'h0;
            idsb_s0  <= 8'h0; idsb_s1  <= 8'h0;
        end else begin
            sop_s0   <= sop_seen_q;      sop_s1   <= sop_s0;
            grant_s0 <= grant_seen_q;    grant_s1 <= grant_s0;
            oae_s0   <= out_adv_ever_q;  oae_s1   <= oae_s0;
            asl_s0   <= any_sop_live_q;  asl_s1   <= asl_s0;
            ioen_s0  <= io_enable;       ioen_s1  <= ioen_s0;
            cnt_s0   <= ch6_grant_cnt_q; cnt_s1   <= cnt_s0;
            idaw_s0  <= last_id_aw_q;    idaw_s1  <= idaw_s0;
            idsb_s0  <= last_id_sb_q;    idsb_s1  <= idsb_s0;
        end
    end

    wire [31:0] fcemit_stat_w;
    assign fcemit_stat_w[ 4: 0] = sop_s1[4:0];      // axi_sop_seen {R,AR,B,W,AW}
    assign fcemit_stat_w[ 5]    = sop_s1[6];        // sb_sop_seen
    assign fcemit_stat_w[ 6]    = sop_s1[5];        // gb_sop_seen
    assign fcemit_stat_w[ 7]    = 1'b0;
    assign fcemit_stat_w[12: 8] = grant_s1[4:0];    // axi_grant_seen {R,AR,B,W,AW}
    assign fcemit_stat_w[13]    = grant_s1[6];      // sb_grant_seen
    assign fcemit_stat_w[14]    = grant_s1[5];      // gb_grant_seen
    assign fcemit_stat_w[15]    = 1'b0;
    assign fcemit_stat_w[16]    = ioen_s1;          // router_io_enable_lvl
    assign fcemit_stat_w[17]    = oae_s1;           // out_advance_ever
    assign fcemit_stat_w[18]    = asl_s1;           // any_sop_live
    assign fcemit_stat_w[23:19] = 5'h0;
    assign fcemit_stat_w[31:24] = 8'hE1;

    wire [31:0] fcemit_idcnt_w;
    assign fcemit_idcnt_w[ 7: 0] = idaw_s1;
    assign fcemit_idcnt_w[15: 8] = idsb_s1;
    assign fcemit_idcnt_w[23:16] = cnt_s1;
    assign fcemit_idcnt_w[31:24] = 8'hE2;

    assign obs_fcemit_stat  = fcemit_stat_w;
    assign obs_fcemit_idcnt = fcemit_idcnt_w;

endmodule

`default_nettype wire
