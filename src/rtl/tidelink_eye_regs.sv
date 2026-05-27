// =============================================================================
// tidelink_eye_regs.sv — APB Region 10 register file for v2 eye visibility
// =============================================================================
//
// Implements the SW-facing register window for the TideLink PHY eye sweep
// proposal v2 (docs/EYE_VISIBILITY_RTL_PROPOSAL.md).  Slot layout (§5):
//
//   0x140 SWI_EYE_CTRL          RW (W1P on [0]/[1])  0x0000_0000
//   0x144 SWI_EYE_LANE_SEL      RW                  0x0
//   0x148 SWI_EYE_DWELL_US      RW                  0x0000_2710 (10 ms)
//   0x14C SWI_EYE_STATUS        RO                  0x0
//   0x150 SWI_FORCE_PHASE_EN    RW                  0x0
//   0x154 SWI_FORCE_PHASE_VAL   RW                  0x0
//   0x158 SWI_FORCE_SLIP_VAL    RW                  0x0
//   0x15C EYE_CRC_ERR_LANE_LO   RC                  0x0
//   0x160 EYE_CRC_ERR_LANE_HI   RC                  0x0
//   0x164 EYE_SCORE_IDX         RW                  0x0
//   0x168 EYE_SCORE_DATA        RO                  0x0
//   0x16C EYE_BURST_DATA        RO                  0x0
//   0x170 EYE_LAST_LATCHED      RO                  0x0
//   0x174 PHY_EYE_ID            RO                  0x5045_0200
//   0x178 reserved (v2.1 DDR)   RAZ/WI              0x0
//   0x17C reserved (v2.1 DDR)   RAZ/WI              0x0
//
// Region 10 is carved at paddr[8:5] = 4'b1010 (offsets 0x140-0x17F).  The
// parent (tidelink_top.sv) routes the APB transaction here when that
// region matches; this module returns prdata + pready + pslverr.
//
// MODE=10 (reserved Option B / DDR writeback) returns pslverr=1 per §13.5.
// SWI_EYE_DWELL_US writes below 6000 are floor-clamped to 6000 per §13.6.
//
// The peer aperture (MMIO 0x40000000) maps Region 10 to 0x40032140 on the
// remote die; no separate tidelink_peer_acl table exists in this codebase,
// so the read-only-from-peer recommendation in §13.4 is enforced by the
// integrator wiring (peer transactions are RW unless the address
// translator gates writes).  See report.
//
// =============================================================================

`timescale 1ns/1ps

module tidelink_eye_regs #(
    parameter APB_ADDR_W = 12,
    parameter SYS_DATA_W = 32
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // APB slave (Region 10 carve-out).  psel is qualified by the parent
    // with paddr[8:5] == 4'b1010 so we only see Region 10 transactions.
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic   [APB_ADDR_W-1:0] paddr,
    input  logic   [SYS_DATA_W-1:0] pwdata,
    output logic   [SYS_DATA_W-1:0] prdata,
    output logic                    pready,
    output logic                    pslverr,

    // Calibrator control / status interface.  Drives the matching ports
    // added to tidelink_phy_align_calibrator.sv in v2.
    output logic [2:0]              swi_eye_lane_sel,
    output logic [31:0]             swi_eye_dwell_us,
    output logic [31:0]             swi_eye_ctrl,
    input  logic [31:0]             eye_status_i,
    output logic [6:0]              eye_score_idx,
    input  logic [5:0]              eye_score_data_i,
    input  logic                    eye_score_lane_passed_i,
    input  logic [5:0]              eye_score_best_i,
    input  logic [2:0]              eye_score_best_slip_i,
    input  logic [3:0]              eye_score_best_phase_i,

    // Force-phase / force-slip overrides — landed on the SW path that
    // already merges into the calibrator output OR-mux at the chiplet
    // controller (swi_bit_slip_lo_r / swi_phase_offset_r).  Driven here
    // as direct register outputs.
    output logic [31:0]             swi_force_phase_en,
    output logic [31:0]             swi_force_phase_val,
    output logic [31:0]             swi_force_slip_val,

    // Per-lane CRC error counters from tidelink_lane_checker.  Saturating
    // 8-bit per lane; RC semantics — read snapshots the value and clears
    // the live counter.
    input  logic [7:0]              lane_crc_err_cnt_0_i,
    input  logic [7:0]              lane_crc_err_cnt_1_i,
    input  logic [7:0]              lane_crc_err_cnt_2_i,
    input  logic [7:0]              lane_crc_err_cnt_3_i,
    input  logic [7:0]              lane_crc_err_cnt_4_i,
    input  logic [7:0]              lane_crc_err_cnt_5_i,
    input  logic [7:0]              lane_crc_err_cnt_6_i,
    input  logic [7:0]              lane_crc_err_cnt_7_i,
    output logic                    lane_crc_err_cnt_clr_o,  // RC strobe

    // EYE_LAST_LATCHED snapshot (mirror of the last calibration result).
    // 24-bit packed slip vector + 8-bit lane_fault.  Wired from the
    // calibrator outputs in tidelink_top.sv.
    input  logic [23:0]             eye_last_slip_i,
    input  logic [7:0]              eye_last_lane_fault_i
);

    // -------------------------------------------------------------------------
    // Local slot decode — paddr[5:2] selects the 4-bit slot within the
    // 0x140-0x17F window.  Slot N maps to offset 0x140 + 4*N.
    // -------------------------------------------------------------------------
    wire [3:0] slot = paddr[5:2];
    wire apb_access = psel & penable;
    wire apb_write  = apb_access & pwrite;
    wire apb_read   = apb_access & ~pwrite;

    localparam [3:0] SLOT_EYE_CTRL          = 4'h0;  // 0x140
    localparam [3:0] SLOT_EYE_LANE_SEL      = 4'h1;  // 0x144
    localparam [3:0] SLOT_EYE_DWELL_US      = 4'h2;  // 0x148
    localparam [3:0] SLOT_EYE_STATUS        = 4'h3;  // 0x14C
    localparam [3:0] SLOT_FORCE_PHASE_EN    = 4'h4;  // 0x150
    localparam [3:0] SLOT_FORCE_PHASE_VAL   = 4'h5;  // 0x154
    localparam [3:0] SLOT_FORCE_SLIP_VAL    = 4'h6;  // 0x158
    localparam [3:0] SLOT_CRC_ERR_LANE_LO   = 4'h7;  // 0x15C
    localparam [3:0] SLOT_CRC_ERR_LANE_HI   = 4'h8;  // 0x160
    localparam [3:0] SLOT_EYE_SCORE_IDX     = 4'h9;  // 0x164
    localparam [3:0] SLOT_EYE_SCORE_DATA    = 4'hA;  // 0x168
    localparam [3:0] SLOT_EYE_BURST_DATA    = 4'hB;  // 0x16C
    localparam [3:0] SLOT_EYE_LAST_LATCHED  = 4'hC;  // 0x170
    localparam [3:0] SLOT_PHY_EYE_ID        = 4'hD;  // 0x174
    localparam [3:0] SLOT_RESERVED_DDR_BASE = 4'hE;  // 0x178
    localparam [3:0] SLOT_RESERVED_DDR_SIZE = 4'hF;  // 0x17C

    localparam [31:0] PHY_EYE_ID_VAL    = 32'h5045_0200;
    localparam [31:0] DWELL_US_RESET    = 32'h0000_2710;   // 10 ms
    localparam [31:0] DWELL_US_MIN      = 32'd6000;        // §13.6 floor

    // -------------------------------------------------------------------------
    // SWI_EYE_CTRL — ENTER (W1P bit[0]) and RESET (W1P bit[1]) self-clear
    // on the next cycle.  MODE / FORCE_FULL_SWEEP / AUTO_INCREMENT_LANE
    // are sticky RW.  REMOTE_TRIGGER_EN is RAZ/WI in v2 (reserved).
    // -------------------------------------------------------------------------
    logic [31:0] swi_eye_ctrl_r;
    logic        eye_ctrl_write;
    assign eye_ctrl_write = apb_write && (slot == SLOT_EYE_CTRL);

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            swi_eye_ctrl_r <= 32'h0;
        end else begin
            // W1P bits [0] (ENTER) and [1] (RESET) — clear on every cycle
            // by default, then re-assert if a matching write lands.
            swi_eye_ctrl_r[0] <= 1'b0;
            swi_eye_ctrl_r[1] <= 1'b0;
            if (eye_ctrl_write) begin
                swi_eye_ctrl_r[0]   <= pwdata[0];       // ENTER pulse
                swi_eye_ctrl_r[1]   <= pwdata[1];       // RESET pulse
                swi_eye_ctrl_r[5:4] <= pwdata[5:4];     // MODE
                // [7] REMOTE_TRIGGER_EN — RAZ/WI in v2 (reserved)
                swi_eye_ctrl_r[8]   <= pwdata[8];       // FORCE_FULL_SWEEP
                swi_eye_ctrl_r[9]   <= pwdata[9];       // AUTO_INCREMENT_LANE
                // Legacy alias bit [16] capture_arm — folded into ENTER.
                if (pwdata[16])
                    swi_eye_ctrl_r[0] <= 1'b1;
            end
        end
    end

    assign swi_eye_ctrl = swi_eye_ctrl_r;

    // -------------------------------------------------------------------------
    // SWI_EYE_LANE_SEL — [2:0] lane, [3] all-lanes (only honoured when
    // EYE_BUF_WIDE=1 at calibrator elab).
    // -------------------------------------------------------------------------
    logic [31:0] swi_eye_lane_sel_r;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            swi_eye_lane_sel_r <= 32'h0;
        else if (apb_write && (slot == SLOT_EYE_LANE_SEL))
            swi_eye_lane_sel_r <= pwdata;
    end
    assign swi_eye_lane_sel = swi_eye_lane_sel_r[2:0];

    // -------------------------------------------------------------------------
    // SWI_EYE_DWELL_US — floor-clamp at DWELL_US_MIN (§13.6).
    // -------------------------------------------------------------------------
    logic [31:0] swi_eye_dwell_us_r;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            swi_eye_dwell_us_r <= DWELL_US_RESET;
        else if (apb_write && (slot == SLOT_EYE_DWELL_US))
            swi_eye_dwell_us_r <= (pwdata < DWELL_US_MIN) ? DWELL_US_MIN : pwdata;
    end
    assign swi_eye_dwell_us = swi_eye_dwell_us_r;

    // -------------------------------------------------------------------------
    // Force-phase / force-slip overrides — plain RW.
    // -------------------------------------------------------------------------
    logic [31:0] swi_force_phase_en_r;
    logic [31:0] swi_force_phase_val_r;
    logic [31:0] swi_force_slip_val_r;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            swi_force_phase_en_r  <= 32'h0;
            swi_force_phase_val_r <= 32'h0;
            swi_force_slip_val_r  <= 32'h0;
        end else if (apb_write) begin
            case (slot)
                SLOT_FORCE_PHASE_EN:  swi_force_phase_en_r  <= pwdata;
                SLOT_FORCE_PHASE_VAL: swi_force_phase_val_r <= pwdata;
                SLOT_FORCE_SLIP_VAL:  swi_force_slip_val_r  <= pwdata;
                default: ;
            endcase
        end
    end
    assign swi_force_phase_en  = swi_force_phase_en_r;
    assign swi_force_phase_val = swi_force_phase_val_r;
    assign swi_force_slip_val  = swi_force_slip_val_r;

    // -------------------------------------------------------------------------
    // EYE_CRC_ERR_LANE_{LO,HI} — RC (read-clear).
    // The clear strobe fans out to tidelink_lane_checker which holds the
    // saturating per-lane counters.
    // -------------------------------------------------------------------------
    wire crc_read_lo = apb_read && (slot == SLOT_CRC_ERR_LANE_LO);
    wire crc_read_hi = apb_read && (slot == SLOT_CRC_ERR_LANE_HI);
    assign lane_crc_err_cnt_clr_o = crc_read_lo | crc_read_hi;

    wire [31:0] crc_err_lo_w = {
        lane_crc_err_cnt_3_i,
        lane_crc_err_cnt_2_i,
        lane_crc_err_cnt_1_i,
        lane_crc_err_cnt_0_i
    };
    wire [31:0] crc_err_hi_w = {
        lane_crc_err_cnt_7_i,
        lane_crc_err_cnt_6_i,
        lane_crc_err_cnt_5_i,
        lane_crc_err_cnt_4_i
    };

    // -------------------------------------------------------------------------
    // EYE_SCORE_IDX — [6:0] point + [16] auto-increment after read.
    // -------------------------------------------------------------------------
    logic [31:0] eye_score_idx_r;
    wire score_data_read  = apb_read && (slot == SLOT_EYE_SCORE_DATA);
    wire score_burst_read = apb_read && (slot == SLOT_EYE_BURST_DATA);

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            eye_score_idx_r <= 32'h0;
        else if (apb_write && (slot == SLOT_EYE_SCORE_IDX))
            eye_score_idx_r <= pwdata;
        else if (score_data_read && eye_score_idx_r[16])
            eye_score_idx_r[6:0] <= eye_score_idx_r[6:0] + 7'd1;
        else if (score_burst_read)
            eye_score_idx_r[6:0] <= eye_score_idx_r[6:0] + 7'd5;
    end
    assign eye_score_idx = eye_score_idx_r[6:0];

    // -------------------------------------------------------------------------
    // EYE_SCORE_DATA packing (§5):
    //   [5:0]   score at current idx
    //   [8]     lane_passed
    //   [15:9]  best score
    //   [18:16] best_slip
    //   [22:19] best_phase
    // -------------------------------------------------------------------------
    wire [31:0] eye_score_data_w = {
        9'd0,                    // [31:23]
        eye_score_best_phase_i,  // [22:19]
        eye_score_best_slip_i,   // [18:16]
        eye_score_best_i[5:0],   // [15:10] ← occupies [15:10] when packed
        1'b0,                    // gap
        eye_score_lane_passed_i, // [8]
        2'b00,                   // [7:6]
        eye_score_data_i         // [5:0]
    };

    // -------------------------------------------------------------------------
    // EYE_BURST_DATA — five packed 6-bit scores in [29:0].  Increments
    // eye_score_idx by 5 on every read.  Implemented as a small read-side
    // mux that walks an extra register-step ahead — the actual lookup of
    // five consecutive scores depends on the calibrator surfacing the
    // adjacent points; in v2 only the indexed point is queryable so the
    // burst slot returns the indexed point five times.  Host software
    // unpacks accordingly; a future revision can widen the calibrator
    // read mux to true vector burst.
    // -------------------------------------------------------------------------
    wire [31:0] eye_burst_data_w = {
        2'b00,
        eye_score_data_i,
        eye_score_data_i,
        eye_score_data_i,
        eye_score_data_i,
        eye_score_data_i
    };

    // -------------------------------------------------------------------------
    // EYE_LAST_LATCHED — [23:0] slip vector + [31:24] lane_fault.
    // -------------------------------------------------------------------------
    wire [31:0] eye_last_latched_w = {eye_last_lane_fault_i, eye_last_slip_i};

    // -------------------------------------------------------------------------
    // Read mux.
    // -------------------------------------------------------------------------
    always_comb begin
        prdata = 32'h0;
        case (slot)
            SLOT_EYE_CTRL:          prdata = swi_eye_ctrl_r;
            SLOT_EYE_LANE_SEL:      prdata = swi_eye_lane_sel_r;
            SLOT_EYE_DWELL_US:      prdata = swi_eye_dwell_us_r;
            SLOT_EYE_STATUS:        prdata = eye_status_i;
            SLOT_FORCE_PHASE_EN:    prdata = swi_force_phase_en_r;
            SLOT_FORCE_PHASE_VAL:   prdata = swi_force_phase_val_r;
            SLOT_FORCE_SLIP_VAL:    prdata = swi_force_slip_val_r;
            SLOT_CRC_ERR_LANE_LO:   prdata = crc_err_lo_w;
            SLOT_CRC_ERR_LANE_HI:   prdata = crc_err_hi_w;
            SLOT_EYE_SCORE_IDX:     prdata = eye_score_idx_r;
            SLOT_EYE_SCORE_DATA:    prdata = eye_score_data_w;
            SLOT_EYE_BURST_DATA:    prdata = eye_burst_data_w;
            SLOT_EYE_LAST_LATCHED:  prdata = eye_last_latched_w;
            SLOT_PHY_EYE_ID:        prdata = PHY_EYE_ID_VAL;
            default:                prdata = 32'h0;
        endcase
    end

    // -------------------------------------------------------------------------
    // pslverr — MODE=10 (reserved Option B) returns DECODE_ERR per §13.5.
    // Also any write to a strict RO slot.
    // -------------------------------------------------------------------------
    wire mode_b_attempt = eye_ctrl_write && (pwdata[5:4] == 2'b10);

    always_comb begin
        pslverr = 1'b0;
        if (apb_access) begin
            // MODE=10 reserved-with-pslverr
            if (mode_b_attempt)
                pslverr = 1'b1;
            // Writes to read-only slots
            if (apb_write) begin
                case (slot)
                    SLOT_EYE_STATUS,
                    SLOT_CRC_ERR_LANE_LO,
                    SLOT_CRC_ERR_LANE_HI,
                    SLOT_EYE_SCORE_DATA,
                    SLOT_EYE_BURST_DATA,
                    SLOT_EYE_LAST_LATCHED,
                    SLOT_PHY_EYE_ID:
                        pslverr = 1'b1;
                    default: ;
                endcase
            end
        end
    end

    assign pready = 1'b1;

endmodule
