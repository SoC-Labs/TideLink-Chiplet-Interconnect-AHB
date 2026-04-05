// Cocotb wrapper for tidelink_ptp_servo
// Exposes all servo interfaces for cocotb access.
// Simulates the servo in isolation — PHC timestamps and PTP events
// are driven directly by cocotb testbench code.
module tb_top #(
    parameter SYS_DATA_W = 32,
    parameter FC_DATA_W  = 48
)(
    input  logic                    clk,
    input  logic                    resetn,

    // Register interface
    input  logic                    servo_reg_write,
    input  logic              [2:0] servo_reg_addr,
    input  logic [SYS_DATA_W-1:0]  servo_reg_wdata,
    output logic [SYS_DATA_W-1:0]  servo_reg_rdata,

    // PTP events
    input  logic                    sync_tx_done,
    input  logic                    dreq_tx_done,
    input  logic                    sync_rx_done,
    input  logic                    dreq_rx_done,

    // PHC hardware capture
    input  logic             [47:0] hw_cap_seconds,
    input  logic             [29:0] hw_cap_nanoseconds,
    input  logic [SYS_DATA_W-1:0]  hw_cap_sub_nanoseconds,

    // FC SIDEBAND TX
    output logic                    servo_fc_valid,
    output logic  [FC_DATA_W-1:0]  servo_fc_data,
    input  logic                    servo_fc_ready,

    // Mailbox
    input  logic                    mbox_reg_write,
    input  logic              [2:0] mbox_reg_addr,
    input  logic [SYS_DATA_W-1:0]  mbox_reg_wdata,

    // DELAY_REQ trigger
    output logic                    servo_dreq_trigger,

    // PHC adjustment
    output logic                    phc_hw_set_time,
    output logic             [47:0] phc_hw_set_seconds,
    output logic             [29:0] phc_hw_set_nanoseconds,
    output logic                    phc_hw_adj_valid,
    output logic [SYS_DATA_W-1:0]  phc_hw_adj_ns_incr_frac,

    // Status
    output logic                    servo_locked
);

    tidelink_ptp_servo #(
        .SYS_DATA_W (SYS_DATA_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_dut (
        .clk                    (clk),
        .resetn                 (resetn),
        .servo_reg_write        (servo_reg_write),
        .servo_reg_addr         (servo_reg_addr),
        .servo_reg_wdata        (servo_reg_wdata),
        .servo_reg_rdata        (servo_reg_rdata),
        .sync_tx_done           (sync_tx_done),
        .dreq_tx_done           (dreq_tx_done),
        .sync_rx_done           (sync_rx_done),
        .dreq_rx_done           (dreq_rx_done),
        .hw_cap_seconds         (hw_cap_seconds),
        .hw_cap_nanoseconds     (hw_cap_nanoseconds),
        .hw_cap_sub_nanoseconds (hw_cap_sub_nanoseconds),
        .servo_fc_valid         (servo_fc_valid),
        .servo_fc_data          (servo_fc_data),
        .servo_fc_ready         (servo_fc_ready),
        .mbox_reg_write         (mbox_reg_write),
        .mbox_reg_addr          (mbox_reg_addr),
        .mbox_reg_wdata         (mbox_reg_wdata),
        .servo_dreq_trigger     (servo_dreq_trigger),
        .phc_hw_set_time        (phc_hw_set_time),
        .phc_hw_set_seconds     (phc_hw_set_seconds),
        .phc_hw_set_nanoseconds (phc_hw_set_nanoseconds),
        .phc_hw_adj_valid       (phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac(phc_hw_adj_ns_incr_frac),
        .servo_locked           (servo_locked)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
