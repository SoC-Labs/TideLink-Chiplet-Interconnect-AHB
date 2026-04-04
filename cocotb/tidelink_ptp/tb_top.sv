// Cocotb wrapper for tidelink_ptp (single-phase PTP module)
// Exposes all DUT interfaces for cocotb access:
//   AHB slave (ahb_ptp_*), FC TX/RX, register interface, PHC capture, IRQ
module tb_top #(
    parameter SYS_DATA_W = 32,
    parameter FC_DATA_W  = 48
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // TX Router Idle
    input  logic                    tx_router_idle,

    // AHB Slave — PTP TX Write Port
    input  logic                    ahb_ptp_hsel,
    input  logic              [3:0] ahb_ptp_haddr,
    input  logic              [1:0] ahb_ptp_htrans,
    input  logic              [2:0] ahb_ptp_hsize,
    input  logic                    ahb_ptp_hwrite,
    input  logic   [SYS_DATA_W-1:0] ahb_ptp_hwdata,
    output logic   [SYS_DATA_W-1:0] ahb_ptp_hrdata,
    output logic                    ahb_ptp_hresp,
    output logic                    ahb_ptp_hreadyout,

    // FC TX Interface (a2l = application-to-link)
    output logic                    ptp_fc_a2l_valid,
    output logic   [FC_DATA_W-1:0] ptp_fc_a2l_data,
    input  logic                    ptp_fc_a2l_ready,

    // FC RX Interface (l2a = link-to-application)
    input  logic                    ptp_fc_l2a_valid,
    input  logic   [FC_DATA_W-1:0] ptp_fc_l2a_data,
    output logic                    ptp_fc_l2a_accept,

    // PHC Hardware Capture
    output logic                    phc_hw_capture,

    // Register Interface (normally from tidelink_apb_regs)
    input  logic                    ptp_reg_write,
    input  logic              [2:0] ptp_reg_addr,
    input  logic   [SYS_DATA_W-1:0] ptp_reg_wdata,
    output logic   [SYS_DATA_W-1:0] ptp_reg_rdata,

    // Interrupt
    output logic                    ptp_irq
);

    // Single-slave loopback: hready fed from hreadyout
    wire ahb_ptp_hready;
    assign ahb_ptp_hready = ahb_ptp_hreadyout;

    tidelink_ptp #(
        .SYS_DATA_W (SYS_DATA_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_dut (
        .hclk               (hclk),
        .hresetn             (hresetn),

        .tx_router_idle      (tx_router_idle),

        .ptp_fc_a2l_valid    (ptp_fc_a2l_valid),
        .ptp_fc_a2l_data     (ptp_fc_a2l_data),
        .ptp_fc_a2l_ready    (ptp_fc_a2l_ready),

        .ptp_fc_l2a_valid    (ptp_fc_l2a_valid),
        .ptp_fc_l2a_data     (ptp_fc_l2a_data),
        .ptp_fc_l2a_accept   (ptp_fc_l2a_accept),

        .phc_hw_capture      (phc_hw_capture),

        .ahb_ptp_hsel        (ahb_ptp_hsel),
        .ahb_ptp_haddr       (ahb_ptp_haddr),
        .ahb_ptp_htrans      (ahb_ptp_htrans),
        .ahb_ptp_hsize       (ahb_ptp_hsize),
        .ahb_ptp_hwrite      (ahb_ptp_hwrite),
        .ahb_ptp_hwdata      (ahb_ptp_hwdata),
        .ahb_ptp_hready      (ahb_ptp_hready),
        .ahb_ptp_hrdata      (ahb_ptp_hrdata),
        .ahb_ptp_hresp       (ahb_ptp_hresp),
        .ahb_ptp_hreadyout   (ahb_ptp_hreadyout),

        .ptp_reg_write       (ptp_reg_write),
        .ptp_reg_addr        (ptp_reg_addr),
        .ptp_reg_wdata       (ptp_reg_wdata),
        .ptp_reg_rdata       (ptp_reg_rdata),

        .ptp_irq             (ptp_irq)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
