// Cocotb wrapper for tidelink_phc_cdc with BYPASS_CDC=0 (full CDC active)
// Two independent clock inputs: hclk and phc_clk, driven by cocotb at
// different frequencies to exercise all 6 CDC paths.
module tb_top #(
    parameter SYS_DATA_W  = 32,
    parameter SYNC_STAGES = 2
)(
    // Two independent clocks (driven by cocotb at different periods)
    input  logic                    hclk,
    input  logic                    phc_clk,

    // Independent resets
    input  logic                    hresetn,
    input  logic                    phc_resetn,

    // DFT
    input  logic                    scan_mode,

    // ── hclk-side ports ──────────────────────────────────────────────
    input  logic                    h_hw_capture,
    output logic             [47:0] h_hw_cap_seconds,
    output logic             [29:0] h_hw_cap_nanoseconds,
    output logic [SYS_DATA_W-1:0]  h_hw_cap_sub_nanoseconds,
    output logic             [29:0] h_phc_nanoseconds,
    output logic             [47:0] h_phc_seconds,
    output logic                    h_phc_pps,
    input  logic                    h_hw_set_time,
    input  logic             [47:0] h_hw_set_seconds,
    input  logic             [29:0] h_hw_set_nanoseconds,
    input  logic                    h_hw_adj_valid,
    input  logic [SYS_DATA_W-1:0]  h_hw_adj_ns_incr_frac,

    // ── phc_clk-side ports ───────────────────────────────────────────
    output logic                    p_hw_capture,
    input  logic             [47:0] p_hw_cap_seconds,
    input  logic             [29:0] p_hw_cap_nanoseconds,
    input  logic [SYS_DATA_W-1:0]  p_hw_cap_sub_nanoseconds,
    input  logic             [29:0] p_phc_nanoseconds,
    input  logic             [47:0] p_phc_seconds,
    input  logic                    p_phc_pps,
    output logic                    p_hw_set_time,
    output logic             [47:0] p_hw_set_seconds,
    output logic             [29:0] p_hw_set_nanoseconds,
    output logic                    p_hw_adj_valid,
    output logic [SYS_DATA_W-1:0]  p_hw_adj_ns_incr_frac
);

    tidelink_phc_cdc #(
        .SYS_DATA_W  (SYS_DATA_W),
        .SYNC_STAGES (SYNC_STAGES),
        .BYPASS_CDC  (0)                // Full CDC — always active
    ) u_dut (
        .hclk                    (hclk),
        .hresetn                 (hresetn),
        .phc_clk                 (phc_clk),
        .phc_resetn              (phc_resetn),
        .scan_mode               (scan_mode),

        .h_hw_capture            (h_hw_capture),
        .h_hw_cap_seconds        (h_hw_cap_seconds),
        .h_hw_cap_nanoseconds    (h_hw_cap_nanoseconds),
        .h_hw_cap_sub_nanoseconds(h_hw_cap_sub_nanoseconds),
        .h_phc_nanoseconds       (h_phc_nanoseconds),
        .h_phc_seconds           (h_phc_seconds),
        .h_phc_pps               (h_phc_pps),
        .h_hw_set_time           (h_hw_set_time),
        .h_hw_set_seconds        (h_hw_set_seconds),
        .h_hw_set_nanoseconds    (h_hw_set_nanoseconds),
        .h_hw_adj_valid          (h_hw_adj_valid),
        .h_hw_adj_ns_incr_frac   (h_hw_adj_ns_incr_frac),

        .p_hw_capture            (p_hw_capture),
        .p_hw_cap_seconds        (p_hw_cap_seconds),
        .p_hw_cap_nanoseconds    (p_hw_cap_nanoseconds),
        .p_hw_cap_sub_nanoseconds(p_hw_cap_sub_nanoseconds),
        .p_phc_nanoseconds       (p_phc_nanoseconds),
        .p_phc_seconds           (p_phc_seconds),
        .p_phc_pps               (p_phc_pps),
        .p_hw_set_time           (p_hw_set_time),
        .p_hw_set_seconds        (p_hw_set_seconds),
        .p_hw_set_nanoseconds    (p_hw_set_nanoseconds),
        .p_hw_adj_valid          (p_hw_adj_valid),
        .p_hw_adj_ns_incr_frac   (p_hw_adj_ns_incr_frac)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
