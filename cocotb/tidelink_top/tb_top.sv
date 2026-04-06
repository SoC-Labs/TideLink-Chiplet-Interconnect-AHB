// Cocotb wrapper for tidelink_top integration test
//
// Since XHB500 and Wlink chiplet controller are external IP that cannot be
// compiled in a unit-test environment, this testbench instantiates only the
// testable internal data path:
//
//   tidelink_fc_adapter  +  tidelink_fifo  +  AHB-to-APB bridge  +  APB mux
//
// The FC adapter's a2l (TX) output is looped back directly to its l2a (RX)
// input, simulating a zero-latency chiplet link.  This exercises:
//   - TX aperture writes -> FC packet encoding -> loopback -> RX decode
//   - FIFO mux arbitration (FC adapter RX vs CPU read port)
//   - APB config mux arbitration (FC adapter RX sideband vs CPU APB port)
//   - Returner interception -> FC sideband -> loopback -> config register write
//
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter FC_DATA_W  = 48,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // AHB Slave -- TX aperture (prefix "ahb_tx")
    // cocotbext-ahb convention: hready = slave output, hready_in = bus input
    input  logic                    ahb_tx_hsel,
    input  logic  [RAM_ADDR_W-1:0] ahb_tx_haddr,
    input  logic              [1:0] ahb_tx_htrans,
    input  logic              [2:0] ahb_tx_hsize,
    input  logic                    ahb_tx_hwrite,
    input  logic  [SYS_DATA_W-1:0] ahb_tx_hwdata,
    input  logic                    ahb_tx_hready_in,
    output logic  [SYS_DATA_W-1:0] ahb_tx_hrdata,
    output logic                    ahb_tx_hresp,
    output logic                    ahb_tx_hready,

    // AHB Slave -- FIFO data read port (prefix "ahb_fifo")
    input  logic                    ahb_fifo_hsel,
    input  logic  [RAM_ADDR_W-1:0] ahb_fifo_haddr,
    input  logic              [1:0] ahb_fifo_htrans,
    input  logic              [2:0] ahb_fifo_hsize,
    input  logic                    ahb_fifo_hwrite,
    input  logic  [SYS_DATA_W-1:0] ahb_fifo_hwdata,
    input  logic                    ahb_fifo_hready_in,
    output logic  [SYS_DATA_W-1:0] ahb_fifo_hrdata,
    output logic                    ahb_fifo_hresp,
    output logic                    ahb_fifo_hready,

    // APB Slave -- Unified config port (prefix "apb")
    // 15-bit address space:
    //   paddr[14:13]=0x -> Wlink (not instantiated here, unused)
    //   paddr[14:13]=10 -> TideLink config regs (0x2000-0x203F)
    input  logic             [14:0] apb_paddr,
    input  logic                    apb_penable,
    input  logic                    apb_pwrite,
    input  logic  [SYS_DATA_W-1:0] apb_pwdata,
    input  logic                    apb_psel,
    output logic  [SYS_DATA_W-1:0] apb_prdata,
    output logic                    apb_pready,

    // Interrupt outputs
    output logic                    released_credits_irq,
    output logic                    doorbell_irq,
    output logic                    packet_committed_irq
);

    // =========================================================================
    // FC loopback wiring: adapter TX (a2l) -> adapter RX (l2a)
    // =========================================================================
    wire                   tl_fc_a2l_valid;
    wire [FC_DATA_W-1:0]  tl_fc_a2l_data;
    wire                   tl_fc_a2l_ready;
    reg                    tl_fc_l2a_valid;
    reg  [FC_DATA_W-1:0]  tl_fc_l2a_data;
    wire                   tl_fc_l2a_accept;

    // 1-cycle registered loopback to break the combinational loop between
    // a2l_valid/ready and l2a_valid/accept.
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            tl_fc_l2a_valid <= 1'b0;
            tl_fc_l2a_data  <= '0;
        end else if (tl_fc_a2l_valid && tl_fc_a2l_ready) begin
            tl_fc_l2a_valid <= 1'b1;
            tl_fc_l2a_data  <= tl_fc_a2l_data;
        end else if (tl_fc_l2a_accept) begin
            tl_fc_l2a_valid <= 1'b0;
        end
    end
    assign tl_fc_a2l_ready = !tl_fc_l2a_valid || tl_fc_l2a_accept;

    // =========================================================================
    // AHB-Lite hready loopback: in single-slave systems, hready_in = hready
    // cocotbext-ahb doesn't drive hready_in, so we tie it to the slave output.
    // =========================================================================
    wire ahb_tx_hready_loop   = ahb_tx_hready;
    wire ahb_fifo_hready_loop = ahb_fifo_hready;

    // =========================================================================
    // Returner AHB master wiring (tidelink_fifo -> FC adapter)
    // =========================================================================
    wire [SYS_ADDR_W-1:0]  rtn_haddr;
    wire [SYS_DATA_W-1:0]  rtn_hwdata;
    wire              [1:0] rtn_htrans;
    wire              [2:0] rtn_hsize;
    wire                    rtn_hwrite;
    wire                    rtn_hready;
    wire                    rtn_hresp;
    wire [SYS_DATA_W-1:0]  rtn_hrdata;

    // =========================================================================
    // FC adapter RX direct write wiring (replaces AHB mux)
    // =========================================================================
    wire                    fc_rx_fifo_valid;
    wire                    fc_rx_fifo_write;
    wire [RAM_ADDR_W-1:0]  fc_rx_fifo_addr;
    wire [SYS_DATA_W-1:0]  fc_rx_fifo_wdata;
    wire                    fc_rx_fifo_ready;

    // FC adapter RX config path — APB-native
    wire [APB_ADDR_W-1:0]  fc_cfg_apb_paddr;
    wire [SYS_DATA_W-1:0]  fc_cfg_apb_pwdata;
    wire                    fc_cfg_apb_psel;
    wire                    fc_cfg_apb_penable;
    wire                    fc_cfg_apb_pwrite;
    wire [SYS_DATA_W-1:0]  fc_cfg_apb_prdata;
    wire                    fc_cfg_apb_pready;
    wire                    fc_cfg_apb_pslverr;

    // =========================================================================
    // Unified APB address decode (same as tidelink_top.sv)
    //   paddr[14:13] == 2'b0x -> Wlink (not present here, default response)
    //   paddr[14:13] == 2'b10 -> TideLink config registers (paddr[11:0])
    // =========================================================================
    wire apb_sel_tidelink = apb_psel && apb_paddr[13];

    // TideLink regs APB response signals (from APB mux below)
    wire [SYS_DATA_W-1:0] tl_regs_prdata;
    wire                   tl_regs_pready;

    // Unified APB response mux (Wlink region returns default values)
    assign apb_prdata  = apb_sel_tidelink ? tl_regs_prdata : '0;
    assign apb_pready  = apb_sel_tidelink ? tl_regs_pready : 1'b1;

    // =========================================================================
    // TideLink config APB mux: 2:1 APB mux (same as tidelink_top.sv)
    //   Source 0 (priority): FC adapter RX config (APB-native from FC adapter)
    //   Source 1: External unified APB port (CPU reads/writes)
    //
    // FC adapter has priority (credit/doorbell delivery is time-sensitive).
    // External APB is stalled (pready=0) when FC adapter is active.
    // =========================================================================
    wire fc_cfg_apb_active = fc_cfg_apb_psel;

    // APB signals to tidelink_fifo APB slave
    wire [APB_ADDR_W-1:0]  tl_apb_paddr;
    wire                    tl_apb_psel;
    wire                    tl_apb_penable;
    wire                    tl_apb_pwrite;
    wire [SYS_DATA_W-1:0]  tl_apb_pwdata;
    wire [SYS_DATA_W-1:0]  tl_apb_prdata;
    wire                    tl_apb_pready;
    wire                    tl_apb_pslverr;

    assign tl_apb_paddr   = fc_cfg_apb_active ? fc_cfg_apb_paddr   : apb_paddr[APB_ADDR_W-1:0];
    assign tl_apb_psel    = fc_cfg_apb_active ? fc_cfg_apb_psel    : apb_sel_tidelink;
    assign tl_apb_penable = fc_cfg_apb_active ? fc_cfg_apb_penable : apb_penable;
    assign tl_apb_pwrite  = fc_cfg_apb_active ? fc_cfg_apb_pwrite  : apb_pwrite;
    assign tl_apb_pwdata  = fc_cfg_apb_active ? fc_cfg_apb_pwdata  : apb_pwdata;

    // Route APB responses back to both sources
    assign fc_cfg_apb_prdata  = tl_apb_prdata;
    assign fc_cfg_apb_pready  = tl_apb_pready;
    assign fc_cfg_apb_pslverr = tl_apb_pslverr;

    assign tl_regs_prdata  = fc_cfg_apb_active ? '0   : tl_apb_prdata;
    assign tl_regs_pready  = fc_cfg_apb_active ? 1'b0 : tl_apb_pready;

    // =========================================================================
    // 1. TideLink RX FIFO (tidelink_fifo)
    //    - AHB slave: FIFO data window (via mux from CPU + FC adapter RX)
    //    - APB slave: config registers (via APB mux above)
    //    - AHB master: returner -> routed to FC adapter for sideband transport
    // =========================================================================
    tidelink_fifo #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_tidelink_fifo (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave -- FIFO data window (CPU reads, direct connection)
        .ahbs_hsel         (ahb_fifo_hsel),
        .ahbs_hready       (ahb_fifo_hready_loop),
        .ahbs_htrans       (ahb_fifo_htrans),
        .ahbs_hsize        (ahb_fifo_hsize),
        .ahbs_hwrite       (ahb_fifo_hwrite),
        .ahbs_haddr        (ahb_fifo_haddr),
        .ahbs_hwdata       (ahb_fifo_hwdata),
        .ahbs_hreadyout    (ahb_fifo_hready),
        .ahbs_hresp        (ahb_fifo_hresp),
        .ahbs_hrdata       (ahb_fifo_hrdata),

        // APB Slave -- Config registers (via APB mux: FC adapter + external APB)
        .apbs_psel         (tl_apb_psel),
        .apbs_penable      (tl_apb_penable),
        .apbs_pwrite       (tl_apb_pwrite),
        .apbs_paddr        (tl_apb_paddr),
        .apbs_pwdata       (tl_apb_pwdata),
        .apbs_prdata       (tl_apb_prdata),
        .apbs_pready       (tl_apb_pready),
        .apbs_pslverr      (tl_apb_pslverr),

        // AHB Master -- Returner (routed to FC adapter)
        .ahbm_haddr        (rtn_haddr),
        .ahbm_hwdata       (rtn_hwdata),
        .ahbm_htrans       (rtn_htrans),
        .ahbm_hsize        (rtn_hsize),
        .ahbm_hwrite       (rtn_hwrite),
        .ahbm_hready       (rtn_hready),
        .ahbm_hresp        (rtn_hresp),
        .ahbm_hrdata       (rtn_hrdata),

        // Interrupts
        .released_credits_irq (released_credits_irq),
        .doorbell_irq         (doorbell_irq),
        .packet_committed_irq (packet_committed_irq),

        // PTP register pass-through (unused in this testbench, tie off)
        .ptp_reg_write     (),
        .ptp_reg_addr      (),
        .ptp_reg_wdata     (),
        .ptp_reg_rdata     (32'h0),
        .ptp_reg_region    (),

        // FC direct write (from FC adapter)
        .fc_wr_valid       (fc_rx_fifo_valid),
        .fc_wr_write       (fc_rx_fifo_write),
        .fc_wr_addr        (fc_rx_fifo_addr),
        .fc_wr_wdata       (fc_rx_fifo_wdata),
        .fc_wr_ready       (fc_rx_fifo_ready)
    );

    // =========================================================================
    // 2. TideLink FC Adapter
    // =========================================================================
    tidelink_fc_adapter #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .APB_ADDR_W (APB_ADDR_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_fc_adapter (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave -- TX aperture
        .ahb_tx_hsel       (ahb_tx_hsel),
        .ahb_tx_haddr      (ahb_tx_haddr),
        .ahb_tx_htrans     (ahb_tx_htrans),
        .ahb_tx_hsize      (ahb_tx_hsize),
        .ahb_tx_hwrite     (ahb_tx_hwrite),
        .ahb_tx_hwdata     (ahb_tx_hwdata),
        .ahb_tx_hready     (ahb_tx_hready_loop),
        .ahb_tx_hrdata     (ahb_tx_hrdata),
        .ahb_tx_hresp      (ahb_tx_hresp),
        .ahb_tx_hreadyout  (ahb_tx_hready),

        // AHB Slave -- Returner interception
        .rtn_haddr         (rtn_haddr),
        .rtn_hwdata        (rtn_hwdata),
        .rtn_htrans        (rtn_htrans),
        .rtn_hsize         (rtn_hsize),
        .rtn_hwrite        (rtn_hwrite),
        .rtn_hready        (rtn_hready),
        .rtn_hresp         (rtn_hresp),
        .rtn_hrdata        (rtn_hrdata),

        // Direct Write -- RX FIFO path
        .fc_rx_fifo_valid  (fc_rx_fifo_valid),
        .fc_rx_fifo_write  (fc_rx_fifo_write),
        .fc_rx_fifo_addr   (fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (fc_rx_fifo_ready),

        //
        // APB Master — RX Config path (direct APB, no AHB-to-APB bridge)
        .fc_rx_cfg_paddr   (fc_cfg_apb_paddr),
        .fc_rx_cfg_pwdata  (fc_cfg_apb_pwdata),
        .fc_rx_cfg_psel    (fc_cfg_apb_psel),
        .fc_rx_cfg_penable (fc_cfg_apb_penable),
        .fc_rx_cfg_pwrite  (fc_cfg_apb_pwrite),
        .fc_rx_cfg_prdata  (fc_cfg_apb_prdata),
        .fc_rx_cfg_pready  (fc_cfg_apb_pready),

        // Servo (not tested at unit level, tied off)
        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        // Extension FC port (tied off)
        .tc_axis_tx_tvalid   (1'b0),
        .tc_axis_tx_tdata    ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready   (),
        .tc_axis_rx_tvalid   (),
        .tc_axis_rx_tdata    (),
        .tc_axis_rx_tready  (1'b1),

        // FC Node interface (looped back at top of this file)
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
