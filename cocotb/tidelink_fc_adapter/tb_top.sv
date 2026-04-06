// Cocotb wrapper for tidelink_fc_adapter
// Exposes all AHB slave/master and FC node signals for cocotb to drive/monitor.
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter APB_ADDR_W = 12,
    parameter FC_DATA_W  = 48
)(
    input  logic                     hclk,
    input  logic                     hresetn,

    // ── AHB Slave — TX Aperture ──────────────────────────────────────────
    input  logic                     ahb_tx_hsel,
    input  logic  [RAM_ADDR_W-1:0]  ahb_tx_haddr,
    input  logic              [1:0]  ahb_tx_htrans,
    input  logic              [2:0]  ahb_tx_hsize,
    input  logic                     ahb_tx_hwrite,
    input  logic  [SYS_DATA_W-1:0]  ahb_tx_hwdata,
    input  logic                     ahb_tx_hready,
    output logic  [SYS_DATA_W-1:0]  ahb_tx_hrdata,
    output logic                     ahb_tx_hresp,
    output logic                     ahb_tx_hreadyout,

    // ── AHB Slave — Returner Interception ────────────────────────────────
    input  logic  [SYS_ADDR_W-1:0]  rtn_haddr,
    input  logic  [SYS_DATA_W-1:0]  rtn_hwdata,
    input  logic              [1:0]  rtn_htrans,
    input  logic              [2:0]  rtn_hsize,
    input  logic                     rtn_hwrite,
    output logic                     rtn_hready,
    output logic                     rtn_hresp,
    output logic  [SYS_DATA_W-1:0]  rtn_hrdata,

    // ── Direct Write — RX FIFO Path ─────────────────────────────────────
    output logic                     fc_rx_fifo_valid,
    output logic                     fc_rx_fifo_write,
    output logic  [RAM_ADDR_W-1:0]  fc_rx_fifo_addr,
    output logic  [SYS_DATA_W-1:0]  fc_rx_fifo_wdata,
    input  logic                     fc_rx_fifo_ready,

    // ── APB Master — RX Config Path ─────────────────────────────────────
    output logic  [APB_ADDR_W-1:0]  fc_rx_cfg_paddr,
    output logic  [SYS_DATA_W-1:0]  fc_rx_cfg_pwdata,
    output logic                     fc_rx_cfg_psel,
    output logic                     fc_rx_cfg_penable,
    output logic                     fc_rx_cfg_pwrite,
    input  logic  [SYS_DATA_W-1:0]  fc_rx_cfg_prdata,
    input  logic                     fc_rx_cfg_pready,

    // ── FC Node Interface ────────────────────────────────────────────────
    output logic                     tl_fc_a2l_valid,
    output logic   [FC_DATA_W-1:0]  tl_fc_a2l_data,
    input  logic                     tl_fc_a2l_ready,

    input  logic                     tl_fc_l2a_valid,
    input  logic   [FC_DATA_W-1:0]  tl_fc_l2a_data,
    output logic                     tl_fc_l2a_accept
);

    // DUT instantiation
    tidelink_fc_adapter #(
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W),
        .RAM_ADDR_W(RAM_ADDR_W),
        .APB_ADDR_W(APB_ADDR_W),
        .FC_DATA_W (FC_DATA_W)
    ) u_dut (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // TX Aperture AHB Slave
        .ahb_tx_hsel       (ahb_tx_hsel),
        .ahb_tx_haddr      (ahb_tx_haddr),
        .ahb_tx_htrans     (ahb_tx_htrans),
        .ahb_tx_hsize      (ahb_tx_hsize),
        .ahb_tx_hwrite     (ahb_tx_hwrite),
        .ahb_tx_hwdata     (ahb_tx_hwdata),
        .ahb_tx_hready     (ahb_tx_hready),
        .ahb_tx_hrdata     (ahb_tx_hrdata),
        .ahb_tx_hresp      (ahb_tx_hresp),
        .ahb_tx_hreadyout  (ahb_tx_hreadyout),

        // Returner Interception AHB Slave
        .rtn_haddr         (rtn_haddr),
        .rtn_hwdata        (rtn_hwdata),
        .rtn_htrans        (rtn_htrans),
        .rtn_hsize         (rtn_hsize),
        .rtn_hwrite        (rtn_hwrite),
        .rtn_hready        (rtn_hready),
        .rtn_hresp         (rtn_hresp),
        .rtn_hrdata        (rtn_hrdata),

        // RX FIFO AHB Master
        // RX FIFO Direct Write
        .fc_rx_fifo_valid  (fc_rx_fifo_valid),
        .fc_rx_fifo_write  (fc_rx_fifo_write),
        .fc_rx_fifo_addr   (fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (fc_rx_fifo_ready),

        // RX Config APB Master
        .fc_rx_cfg_paddr   (fc_rx_cfg_paddr),
        .fc_rx_cfg_pwdata  (fc_rx_cfg_pwdata),
        .fc_rx_cfg_psel    (fc_rx_cfg_psel),
        .fc_rx_cfg_penable (fc_rx_cfg_penable),
        .fc_rx_cfg_pwrite  (fc_rx_cfg_pwrite),
        .fc_rx_cfg_prdata  (fc_rx_cfg_prdata),
        .fc_rx_cfg_pready  (fc_rx_cfg_pready),

        // Servo (not tested at unit level, tied off)
        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        // Extension FC port (not tested at unit level, tied off)
        .ext_fc_tx_valid   (1'b0),
        .ext_fc_tx_data    ({FC_DATA_W{1'b0}}),
        .ext_fc_tx_ready   (),
        .ext_fc_rx_valid   (),
        .ext_fc_rx_data    (),
        .ext_fc_rx_accept  (1'b1),

        // FC Node
        .tl_fc_a2l_valid   (tl_fc_a2l_valid),
        .tl_fc_a2l_data    (tl_fc_a2l_data),
        .tl_fc_a2l_ready   (tl_fc_a2l_ready),

        .tl_fc_l2a_valid   (tl_fc_l2a_valid),
        .tl_fc_l2a_data    (tl_fc_l2a_data),
        .tl_fc_l2a_accept  (tl_fc_l2a_accept)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
