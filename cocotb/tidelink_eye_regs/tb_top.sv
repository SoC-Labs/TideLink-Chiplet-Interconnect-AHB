// Cocotb wrapper for tidelink_eye_regs standalone testing.
//
// tidelink_eye_regs.sv implements the APB Region-10 register window for the
// v2 PHY eye-visibility proposal (docs/EYE_VISIBILITY_RTL_PROPOSAL.md §5).
// Slot offsets are 0x140..0x17C (paddr[8:5] == 4'b1010). The parent SoC
// gates psel by that decode bits; this testbench drives the APB slave
// directly so any low offset reaches the read mux. The tests use byte
// offsets in the 0x140-0x17F window to mirror real-system addressing.
//
// Stimulus inputs (eye_status_i, eye_score_*_i, lane_crc_err_cnt_*_i,
// eye_last_*_i) are exposed flat for the test to drive.

module tb_top #(
    parameter APB_ADDR_W = 12,
    parameter SYS_DATA_W = 32
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // APB slave
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic   [APB_ADDR_W-1:0] paddr,
    input  logic   [SYS_DATA_W-1:0] pwdata,
    output logic   [SYS_DATA_W-1:0] prdata,
    output logic                    pready,
    output logic                    pslverr,

    // Calibrator control / status interface
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

    // Force-phase / force-slip overrides
    output logic [31:0]             swi_force_phase_en,
    output logic [31:0]             swi_force_phase_val,
    output logic [31:0]             swi_force_slip_val,

    // Per-lane CRC error counters
    input  logic [7:0]              lane_crc_err_cnt_0_i,
    input  logic [7:0]              lane_crc_err_cnt_1_i,
    input  logic [7:0]              lane_crc_err_cnt_2_i,
    input  logic [7:0]              lane_crc_err_cnt_3_i,
    input  logic [7:0]              lane_crc_err_cnt_4_i,
    input  logic [7:0]              lane_crc_err_cnt_5_i,
    input  logic [7:0]              lane_crc_err_cnt_6_i,
    input  logic [7:0]              lane_crc_err_cnt_7_i,
    output logic                    lane_crc_err_cnt_clr_o,

    // EYE_LAST_LATCHED snapshot
    input  logic [23:0]             eye_last_slip_i,
    input  logic [7:0]              eye_last_lane_fault_i
);

    tidelink_eye_regs #(
        .APB_ADDR_W (APB_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
    ) u_dut (
        .hclk                       (hclk),
        .hresetn                    (hresetn),
        .psel                       (psel),
        .penable                    (penable),
        .pwrite                     (pwrite),
        .paddr                      (paddr),
        .pwdata                     (pwdata),
        .prdata                     (prdata),
        .pready                     (pready),
        .pslverr                    (pslverr),
        .swi_eye_lane_sel           (swi_eye_lane_sel),
        .swi_eye_dwell_us           (swi_eye_dwell_us),
        .swi_eye_ctrl               (swi_eye_ctrl),
        .eye_status_i               (eye_status_i),
        .eye_score_idx              (eye_score_idx),
        .eye_score_data_i           (eye_score_data_i),
        .eye_score_lane_passed_i    (eye_score_lane_passed_i),
        .eye_score_best_i           (eye_score_best_i),
        .eye_score_best_slip_i      (eye_score_best_slip_i),
        .eye_score_best_phase_i     (eye_score_best_phase_i),
        .swi_force_phase_en         (swi_force_phase_en),
        .swi_force_phase_val        (swi_force_phase_val),
        .swi_force_slip_val         (swi_force_slip_val),
        .lane_crc_err_cnt_0_i       (lane_crc_err_cnt_0_i),
        .lane_crc_err_cnt_1_i       (lane_crc_err_cnt_1_i),
        .lane_crc_err_cnt_2_i       (lane_crc_err_cnt_2_i),
        .lane_crc_err_cnt_3_i       (lane_crc_err_cnt_3_i),
        .lane_crc_err_cnt_4_i       (lane_crc_err_cnt_4_i),
        .lane_crc_err_cnt_5_i       (lane_crc_err_cnt_5_i),
        .lane_crc_err_cnt_6_i       (lane_crc_err_cnt_6_i),
        .lane_crc_err_cnt_7_i       (lane_crc_err_cnt_7_i),
        .lane_crc_err_cnt_clr_o     (lane_crc_err_cnt_clr_o),
        .eye_last_slip_i            (eye_last_slip_i),
        .eye_last_lane_fault_i      (eye_last_lane_fault_i)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
