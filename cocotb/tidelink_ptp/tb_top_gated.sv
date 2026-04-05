// Cocotb wrapper for tidelink_ptp with PHC_LOCK_GATE_EN=1
// Identical to tb_top.sv except the lock gate is active, so
// phc_locked_i actually controls the HW sync IDLE→ARMED transition.
module tb_top #(
    parameter SYS_DATA_W = 32
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

    // Short Packet TX Interface
    output logic                    ptp_sp_tx_valid,
    output logic              [7:0] ptp_sp_tx_data_id,
    output logic             [15:0] ptp_sp_tx_payload,
    input  logic                    ptp_sp_tx_ready,

    // Short Packet RX Interface
    input  logic                    ptp_sp_rx_valid,
    input  logic              [7:0] ptp_sp_rx_data_id,
    input  logic             [15:0] ptp_sp_rx_payload,
    output logic                    ptp_sp_rx_accept,

    // PHC Hardware Capture
    output logic                    phc_hw_capture,

    // PHC Time Inputs (for hardware sync initiator)
    input  logic             [29:0] phc_nanoseconds,
    input  logic             [47:0] phc_seconds,
    input  logic                    phc_pps,

    // Register Interface (normally from tidelink_apb_regs)
    input  logic                    ptp_reg_write,
    input  logic              [2:0] ptp_reg_addr,
    input  logic   [SYS_DATA_W-1:0] ptp_reg_wdata,
    output logic   [SYS_DATA_W-1:0] ptp_reg_rdata,
    input  logic                    ptp_reg_region,

    // External PHC lock gate (testable with PHC_LOCK_GATE_EN=1)
    input  logic                    phc_locked_i,

    // Interrupt
    output logic                    ptp_irq
);

    // Single-slave loopback: hready fed from hreadyout
    wire ahb_ptp_hready;
    assign ahb_ptp_hready = ahb_ptp_hreadyout;

    // Servo event outputs (unused in unit test, but must be connected)
    wire sync_tx_done;
    wire dreq_tx_done;
    wire sync_rx_done;
    wire dreq_rx_done;

    tidelink_ptp #(
        .SYS_DATA_W       (SYS_DATA_W),
        .PHC_LOCK_GATE_EN (1)             // <<< KEY DIFFERENCE: gate is active
    ) u_dut (
        .hclk               (hclk),
        .hresetn             (hresetn),

        .tx_router_idle      (tx_router_idle),

        .ptp_sp_tx_valid     (ptp_sp_tx_valid),
        .ptp_sp_tx_data_id   (ptp_sp_tx_data_id),
        .ptp_sp_tx_payload   (ptp_sp_tx_payload),
        .ptp_sp_tx_ready     (ptp_sp_tx_ready),

        .ptp_sp_rx_valid     (ptp_sp_rx_valid),
        .ptp_sp_rx_data_id   (ptp_sp_rx_data_id),
        .ptp_sp_rx_payload   (ptp_sp_rx_payload),
        .ptp_sp_rx_accept    (ptp_sp_rx_accept),

        .phc_hw_capture      (phc_hw_capture),

        .phc_nanoseconds     (phc_nanoseconds),
        .phc_seconds          (phc_seconds),
        .phc_pps              (phc_pps),

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
        .ptp_reg_region      (ptp_reg_region),

        // Servo event outputs (monitored in system tests, unused here)
        .sync_tx_done        (sync_tx_done),
        .dreq_tx_done        (dreq_tx_done),
        .sync_rx_done        (sync_rx_done),
        .dreq_rx_done        (dreq_rx_done),

        // Servo DELAY_REQ injection (tied off — no servo in unit test)
        .servo_dreq_trigger  (1'b0),

        // External PHC lock gate — actively used with PHC_LOCK_GATE_EN=1
        .phc_locked_i        (phc_locked_i),

        .ptp_irq             (ptp_irq)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
