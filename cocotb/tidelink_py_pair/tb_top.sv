// Cocotb wrapper for tidelink pair test
// Instantiates a single tidelink module with all interfaces exposed.
// The paired tidelink's register bank is modelled in Python.
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = 32'h4000_1000
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // AHB Slave Interface (FIFO data path)
    input  logic                    ahbs_hsel,
    input  logic              [1:0] ahbs_htrans,
    input  logic              [2:0] ahbs_hsize,
    input  logic                    ahbs_hwrite,
    input  logic   [RAM_ADDR_W-1:0] ahbs_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbs_hwdata,
    output logic                    ahbs_hreadyout,
    output logic                    ahbs_hresp,
    output logic   [SYS_DATA_W-1:0] ahbs_hrdata,

    // AHB Master Interface (returner outputs — monitored by Python pair model)
    output logic   [SYS_ADDR_W-1:0] ahbm_haddr,
    output logic   [SYS_DATA_W-1:0] ahbm_hwdata,
    output logic              [1:0] ahbm_htrans,
    output logic              [2:0] ahbm_hsize,
    output logic                    ahbm_hwrite,
    input  logic                    ahbm_hready,
    input  logic                    ahbm_hresp,
    input  logic   [SYS_DATA_W-1:0] ahbm_hrdata,

    // APB Slave Interface (configuration + released credits receiver)
    input  logic                    apbs_psel,
    input  logic                    apbs_penable,
    input  logic                    apbs_pwrite,
    input  logic   [APB_ADDR_W-1:0] apbs_paddr,
    input  logic   [SYS_DATA_W-1:0] apbs_pwdata,
    output logic   [SYS_DATA_W-1:0] apbs_prdata,
    output logic                    apbs_pready,
    output logic                    apbs_pslverr,

    // Interrupt outputs
    output logic                    released_credits_irq,
    output logic                    doorbell_irq,
    output logic                    packet_committed_irq
);

    // Single-slave loopback: hready = hreadyout
    wire ahbs_hready;
    assign ahbs_hready = ahbs_hreadyout;

    // Tie off unused pass-through inputs (no PTP, servo, or FC in this testbench)
    wire ptp_reg_write, ptp_reg_region;
    wire [2:0] ptp_reg_addr;
    wire [SYS_DATA_W-1:0] ptp_reg_wdata;
    wire servo_reg_write;
    wire [2:0] servo_reg_addr;
    wire [SYS_DATA_W-1:0] servo_reg_wdata;
    wire mbox_reg_write;
    wire [2:0] mbox_reg_addr;
    wire [SYS_DATA_W-1:0] mbox_reg_wdata;
    wire fc_wr_ready;

    tidelink_fifo #(
        .SYS_ADDR_W       (SYS_ADDR_W),
        .SYS_DATA_W       (SYS_DATA_W),
        .RAM_ADDR_W       (RAM_ADDR_W),
        .RAM_DATA_W       (RAM_DATA_W),
        .APB_ADDR_W       (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_dut (
        .hclk               (hclk),
        .hresetn             (hresetn),
        .ahbs_hsel           (ahbs_hsel),
        .ahbs_hready         (ahbs_hready),
        .ahbs_htrans         (ahbs_htrans),
        .ahbs_hsize          (ahbs_hsize),
        .ahbs_hwrite         (ahbs_hwrite),
        .ahbs_haddr          (ahbs_haddr),
        .ahbs_hwdata         (ahbs_hwdata),
        .ahbs_hreadyout      (ahbs_hreadyout),
        .ahbs_hresp          (ahbs_hresp),
        .ahbs_hrdata         (ahbs_hrdata),
        .ahbm_haddr          (ahbm_haddr),
        .ahbm_hwdata         (ahbm_hwdata),
        .ahbm_htrans         (ahbm_htrans),
        .ahbm_hsize          (ahbm_hsize),
        .ahbm_hwrite         (ahbm_hwrite),
        .ahbm_hready         (ahbm_hready),
        .ahbm_hresp          (ahbm_hresp),
        .ahbm_hrdata         (ahbm_hrdata),
        .apbs_psel           (apbs_psel),
        .apbs_penable        (apbs_penable),
        .apbs_pwrite         (apbs_pwrite),
        .apbs_paddr          (apbs_paddr),
        .apbs_pwdata         (apbs_pwdata),
        .apbs_prdata         (apbs_prdata),
        .apbs_pready         (apbs_pready),
        .apbs_pslverr        (apbs_pslverr),
        .released_credits_irq (released_credits_irq),
        .doorbell_irq        (doorbell_irq),
        .packet_committed_irq(packet_committed_irq),

        // PTP/Servo/Mbox pass-through (tied off)
        .ptp_reg_write   (ptp_reg_write),
        .ptp_reg_addr    (ptp_reg_addr),
        .ptp_reg_wdata   (ptp_reg_wdata),
        .ptp_reg_rdata   ({SYS_DATA_W{1'b0}}),
        .ptp_reg_region  (ptp_reg_region),
        .servo_reg_write (servo_reg_write),
        .servo_reg_addr  (servo_reg_addr),
        .servo_reg_wdata (servo_reg_wdata),
        .servo_reg_rdata ({SYS_DATA_W{1'b0}}),
        .mbox_reg_write  (mbox_reg_write),
        .mbox_reg_addr   (mbox_reg_addr),
        .mbox_reg_wdata  (mbox_reg_wdata),

        // FC direct write path (tied off)
        .fc_wr_valid     (1'b0),
        .fc_wr_write     (1'b0),
        .fc_wr_addr      ({RAM_ADDR_W{1'b0}}),
        .fc_wr_wdata     ({SYS_DATA_W{1'b0}}),
        .fc_wr_ready     (fc_wr_ready)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
