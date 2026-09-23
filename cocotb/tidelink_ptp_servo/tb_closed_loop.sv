//-----------------------------------------------------------------------------
// Closed-loop wrapper: tidelink_ptp_servo (Subordinate) driving a REAL
// phc_clock_core, so that a phase step / frequency adjust issued by the servo
// changes the clock the servo is measuring.  The Grandmaster is a Python
// model in test_closed_loop.py (ideal clock = sim time + epoch).
//
// The servo's hw_cap_* inputs come straight from the PHC's hw_cap_* outputs;
// the test pulses hw_capture one cycle BEFORE the servo event pulse so the
// servo latches the timestamp of THIS event (this deliberately sidesteps the
// review's separate 8.3 stale-capture race, which is not under test here).
//
// Used only by Makefile.closed / test_closed_loop.py (rev-2 review LP-13
// re-derivation).  PHC RTL comes from PHC_HOME (ptp-hardware-clock-ahb).
//-----------------------------------------------------------------------------
module tb_closed_loop #(
    parameter SYS_DATA_W = 32,
    parameter FC_DATA_W  = 48
)(
    input  logic                    clk,
    input  logic                    resetn,
    // servo register interface
    input  logic                    servo_reg_write,
    input  logic              [2:0] servo_reg_addr,
    input  logic [SYS_DATA_W-1:0]  servo_reg_wdata,
    output logic [SYS_DATA_W-1:0]  servo_reg_rdata,
    // servo events (subordinate side only)
    input  logic                    sync_rx_done,
    input  logic                    dreq_tx_done,
    input  logic                    hw_capture,      // to the PHC
    // mailbox (t1 / t4 from the Python grandmaster)
    input  logic                    mbox_reg_write,
    input  logic              [2:0] mbox_reg_addr,
    input  logic [SYS_DATA_W-1:0]  mbox_reg_wdata,
    output logic                    servo_dreq_trigger,
    output logic                    servo_locked,
    output logic                    phc_hw_set_time,
    output logic             [47:0] phc_hw_set_seconds,
    output logic             [29:0] phc_hw_set_nanoseconds,
    output logic                    phc_hw_adj_valid,
    output logic [SYS_DATA_W-1:0]  phc_hw_adj_ns_incr_frac,
    // PHC control / observation
    input  logic                    phc_enable,
    input  logic                    phc_set_time,
    input  logic             [47:0] phc_set_seconds,
    input  logic             [29:0] phc_set_nanoseconds,
    input  logic              [7:0] phc_ns_incr,
    input  logic [SYS_DATA_W-1:0]  phc_ns_incr_frac,
    output logic             [47:0] phc_seconds,
    output logic             [29:0] phc_nanoseconds,
    output logic [SYS_DATA_W-1:0]  phc_sub_nanoseconds,
    output logic             [47:0] hw_cap_seconds,
    output logic             [29:0] hw_cap_nanoseconds
);

    logic [FC_DATA_W-1:0] servo_fc_data_unused;
    logic                 servo_fc_valid_unused;
    logic [SYS_DATA_W-1:0] unused_sub;
    logic [47:0] unused_s0, unused_s1, unused_s2;
    logic [29:0] unused_n0, unused_n1, unused_n2;
    logic [SYS_DATA_W-1:0] unused_f0, unused_f1, unused_f2, unused_f3;
    logic        unused_pps;

    tidelink_ptp_servo #(
        .SYS_DATA_W (SYS_DATA_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_servo (
        .clk                    (clk),
        .resetn                 (resetn),
        .servo_reg_write        (servo_reg_write),
        .servo_reg_addr         (servo_reg_addr),
        .servo_reg_wdata        (servo_reg_wdata),
        .servo_reg_rdata        (servo_reg_rdata),
        .sync_tx_done           (1'b0),
        .dreq_tx_done           (dreq_tx_done),
        .sync_rx_done           (sync_rx_done),
        .dreq_rx_done           (1'b0),
        .hw_cap_seconds         (hw_cap_seconds),
        .hw_cap_nanoseconds     (hw_cap_nanoseconds),
        .servo_fc_valid         (servo_fc_valid_unused),
        .servo_fc_data          (servo_fc_data_unused),
        .servo_fc_ready         (1'b1),
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

    phc_clock_core #(.SYS_DATA_W(SYS_DATA_W)) u_phc (
        .clk                    (clk),
        .resetn                 (resetn),
        .enable                 (phc_enable),
        .set_time               (phc_set_time),
        .capture                (1'b0),
        .hw_capture             (hw_capture),
        .ns_incr                (phc_ns_incr),
        .ns_incr_frac           (phc_ns_incr_frac),
        .set_seconds            (phc_set_seconds),
        .set_nanoseconds        (phc_set_nanoseconds),
        .hw_set_time            (phc_hw_set_time),
        .hw_set_seconds         (phc_hw_set_seconds),
        .hw_set_nanoseconds     (phc_hw_set_nanoseconds),
        .hw_adj_valid           (phc_hw_adj_valid),
        .hw_adj_ns_incr_frac    (phc_hw_adj_ns_incr_frac),
        .seconds                (phc_seconds),
        .nanoseconds            (phc_nanoseconds),
        .sub_nanoseconds        (phc_sub_nanoseconds),
        .cap_seconds            (unused_s0),
        .cap_nanoseconds        (unused_n0),
        .cap_sub_nanoseconds    (unused_f0),
        .hw_cap_seconds         (hw_cap_seconds),
        .hw_cap_nanoseconds     (hw_cap_nanoseconds),
        .hw_cap_sub_nanoseconds (unused_f1),
        .eth_rx_capture         (1'b0),
        .eth_tx_capture         (1'b0),
        .eth_rx_cap_seconds     (unused_s1),
        .eth_rx_cap_nanoseconds (unused_n1),
        .eth_rx_cap_sub_nanoseconds (unused_f2),
        .eth_tx_cap_seconds     (unused_s2),
        .eth_tx_cap_nanoseconds (unused_n2),
        .eth_tx_cap_sub_nanoseconds (unused_f3),
        .pps                    (unused_pps)
    );

    initial begin
        $dumpfile("waves_closed.vcd");
        $dumpvars(0, tb_closed_loop);
    end
endmodule
