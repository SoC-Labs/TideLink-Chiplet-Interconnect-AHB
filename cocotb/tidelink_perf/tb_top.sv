// Cocotb wrapper for tidelink_perf standalone testing
module tb_top #(
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter FC_DATA_W  = 48
)(
    // Clock and Reset
    input  logic                     hclk,
    input  logic                     hresetn,

    // Register Interface (from tidelink_apb_regs pass-through, Regions 5-7)
    input  logic                     perf_reg_write,
    input  logic              [2:0]  perf_reg_addr,
    input  logic  [SYS_DATA_W-1:0]  perf_reg_wdata,
    output logic  [SYS_DATA_W-1:0]  perf_reg_rdata,
    input  logic              [1:0]  perf_reg_region,

    // Free-running PHC time (hclk domain, from CDC module Path 2)
    input  logic             [29:0]  phc_nanoseconds,
    input  logic             [31:0]  phc_seconds,

    // FC TX observation
    input  logic                     fc_tx_handshake,
    input  logic                     fc_tx_is_data,

    // FC RX observation
    input  logic                     fc_rx_handshake,
    input  logic                     fc_rx_is_data,
    input  logic                     fc_rx_is_first,

    // TX aperture observation
    input  logic                     tx_pkt_start,

    // RX FIFO observation
    input  logic                     rx_pkt_committed,

    // Link status
    input  logic                     tx_router_idle,
    input  logic                     fc_tx_valid,
    input  logic                     fc_tx_ready,
    input  logic                     fc_rx_valid,
    input  logic                     fc_rx_accept,

    // Credit observation
    input  logic [RAM_ADDR_W-2:0]    credit_count,

    // Interrupt output
    output logic                     perf_irq
);

    tidelink_perf #(
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_dut (
        .hclk              (hclk),
        .hresetn           (hresetn),

        .perf_reg_write    (perf_reg_write),
        .perf_reg_addr     (perf_reg_addr),
        .perf_reg_wdata    (perf_reg_wdata),
        .perf_reg_rdata    (perf_reg_rdata),
        .perf_reg_region   (perf_reg_region),

        .phc_nanoseconds   (phc_nanoseconds),
        .phc_seconds       (phc_seconds),

        .fc_tx_handshake   (fc_tx_handshake),
        .fc_tx_is_data     (fc_tx_is_data),

        .fc_rx_handshake   (fc_rx_handshake),
        .fc_rx_is_data     (fc_rx_is_data),
        .fc_rx_is_first    (fc_rx_is_first),

        .tx_pkt_start      (tx_pkt_start),

        .rx_pkt_committed  (rx_pkt_committed),

        .tx_router_idle    (tx_router_idle),
        .fc_tx_valid       (fc_tx_valid),
        .fc_tx_ready       (fc_tx_ready),
        .fc_rx_valid       (fc_rx_valid),
        .fc_rx_accept      (fc_rx_accept),

        .credit_count      (credit_count),

        .perf_irq          (perf_irq)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
