// Cocotb wrapper for tidelink_top integration test
//
// Since XHB500 and Wlink chiplet controller are external IP that cannot be
// compiled in a unit-test environment, this testbench instantiates only the
// testable internal data path:
//
//   tidelink_fc_adapter  +  tidelink_fifo_ahb  +  mux logic
//
// The FC adapter's a2l (TX) output is looped back directly to its l2a (RX)
// input, simulating a zero-latency chiplet link.  This exercises:
//   - TX aperture writes -> FC packet encoding -> loopback -> RX decode
//   - FIFO mux arbitration (FC adapter RX vs CPU read port)
//   - Config mux arbitration (FC adapter RX sideband vs CPU config port)
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
    input  logic                    ahb_tx_hsel,
    input  logic  [RAM_ADDR_W-1:0] ahb_tx_haddr,
    input  logic              [1:0] ahb_tx_htrans,
    input  logic              [2:0] ahb_tx_hsize,
    input  logic                    ahb_tx_hwrite,
    input  logic  [SYS_DATA_W-1:0] ahb_tx_hwdata,
    input  logic                    ahb_tx_hready,
    output logic  [SYS_DATA_W-1:0] ahb_tx_hrdata,
    output logic                    ahb_tx_hresp,
    output logic                    ahb_tx_hreadyout,

    // AHB Slave -- FIFO data read port (prefix "ahb_fifo")
    input  logic                    ahb_fifo_hsel,
    input  logic  [RAM_ADDR_W-1:0] ahb_fifo_haddr,
    input  logic              [1:0] ahb_fifo_htrans,
    input  logic              [2:0] ahb_fifo_hsize,
    input  logic                    ahb_fifo_hwrite,
    input  logic  [SYS_DATA_W-1:0] ahb_fifo_hwdata,
    input  logic                    ahb_fifo_hready,
    output logic  [SYS_DATA_W-1:0] ahb_fifo_hrdata,
    output logic                    ahb_fifo_hresp,
    output logic                    ahb_fifo_hreadyout,

    // AHB Slave -- Config registers (prefix "ahb_cfg")
    input  logic                    ahb_cfg_hsel,
    input  logic  [APB_ADDR_W-1:0] ahb_cfg_haddr,
    input  logic              [1:0] ahb_cfg_htrans,
    input  logic              [2:0] ahb_cfg_hsize,
    input  logic                    ahb_cfg_hwrite,
    input  logic  [SYS_DATA_W-1:0] ahb_cfg_hwdata,
    input  logic                    ahb_cfg_hready,
    output logic  [SYS_DATA_W-1:0] ahb_cfg_hrdata,
    output logic                    ahb_cfg_hresp,
    output logic                    ahb_cfg_hreadyout,

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
    wire                   tl_fc_l2a_valid;
    wire [FC_DATA_W-1:0]  tl_fc_l2a_data;
    wire                   tl_fc_l2a_accept;

    // Loopback: connect TX output directly to RX input
    assign tl_fc_l2a_valid = tl_fc_a2l_valid;
    assign tl_fc_l2a_data  = tl_fc_a2l_data;
    assign tl_fc_a2l_ready = tl_fc_l2a_accept;

    // =========================================================================
    // Returner AHB master wiring (tidelink_fifo_ahb -> FC adapter)
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
    // FC adapter RX split AHB master wiring
    // =========================================================================
    wire [RAM_ADDR_W-1:0]  fc_rx_fifo_haddr;
    wire [SYS_DATA_W-1:0]  fc_rx_fifo_hwdata;
    wire              [1:0] fc_rx_fifo_htrans;
    wire              [2:0] fc_rx_fifo_hsize;
    wire                    fc_rx_fifo_hwrite;
    wire                    fc_rx_fifo_hready;
    wire                    fc_rx_fifo_hresp;
    wire [SYS_DATA_W-1:0]  fc_rx_fifo_hrdata;

    wire [APB_ADDR_W-1:0]  fc_rx_cfg_haddr;
    wire [SYS_DATA_W-1:0]  fc_rx_cfg_hwdata;
    wire              [1:0] fc_rx_cfg_htrans;
    wire              [2:0] fc_rx_cfg_hsize;
    wire                    fc_rx_cfg_hwrite;
    wire                    fc_rx_cfg_hready;
    wire                    fc_rx_cfg_hresp;
    wire [SYS_DATA_W-1:0]  fc_rx_cfg_hrdata;

    // =========================================================================
    // FIFO port mux (same logic as tidelink_top.sv)
    //   Source 0: FC adapter RX FIFO master (writes incoming packets)
    //   Source 1: External ahb_fifo_* port (CPU reads received packets)
    //   FC adapter has priority.
    // =========================================================================
    wire                    fifo_mux_hsel;
    wire [RAM_ADDR_W-1:0]  fifo_mux_haddr;
    wire              [1:0] fifo_mux_htrans;
    wire              [2:0] fifo_mux_hsize;
    wire                    fifo_mux_hwrite;
    wire [SYS_DATA_W-1:0]  fifo_mux_hwdata;
    wire                    fifo_mux_hready;
    wire [SYS_DATA_W-1:0]  fifo_mux_hrdata;
    wire                    fifo_mux_hresp;
    wire                    fifo_mux_hreadyout;

    wire fc_rx_fifo_active = fc_rx_fifo_htrans[1];

    assign fifo_mux_hsel   = fc_rx_fifo_active ? 1'b1              : ahb_fifo_hsel;
    assign fifo_mux_haddr  = fc_rx_fifo_active ? fc_rx_fifo_haddr  : ahb_fifo_haddr;
    assign fifo_mux_htrans = fc_rx_fifo_active ? fc_rx_fifo_htrans : ahb_fifo_htrans;
    assign fifo_mux_hsize  = fc_rx_fifo_active ? fc_rx_fifo_hsize  : ahb_fifo_hsize;
    assign fifo_mux_hwrite = fc_rx_fifo_active ? fc_rx_fifo_hwrite : ahb_fifo_hwrite;
    assign fifo_mux_hwdata = fc_rx_fifo_active ? fc_rx_fifo_hwdata : ahb_fifo_hwdata;
    assign fifo_mux_hready = fifo_mux_hreadyout;

    assign fc_rx_fifo_hready    = fc_rx_fifo_active ? fifo_mux_hreadyout : 1'b1;
    assign fc_rx_fifo_hresp     = fifo_mux_hresp;
    assign fc_rx_fifo_hrdata    = fifo_mux_hrdata;
    assign ahb_fifo_hreadyout   = fc_rx_fifo_active ? 1'b0 : fifo_mux_hreadyout;
    assign ahb_fifo_hresp       = fifo_mux_hresp;
    assign ahb_fifo_hrdata      = fifo_mux_hrdata;

    // =========================================================================
    // Config port mux (same logic as tidelink_top.sv)
    //   Source 0: FC adapter RX Config master (credit/doorbell sideband)
    //   Source 1: External ahb_cfg_* port (CPU config register access)
    //   FC adapter has priority.
    // =========================================================================
    wire                    cfg_mux_hsel;
    wire [APB_ADDR_W-1:0]  cfg_mux_haddr;
    wire              [1:0] cfg_mux_htrans;
    wire              [2:0] cfg_mux_hsize;
    wire                    cfg_mux_hwrite;
    wire [SYS_DATA_W-1:0]  cfg_mux_hwdata;
    wire                    cfg_mux_hready;
    wire [SYS_DATA_W-1:0]  cfg_mux_hrdata;
    wire                    cfg_mux_hresp;
    wire                    cfg_mux_hreadyout;

    wire fc_rx_cfg_active = fc_rx_cfg_htrans[1];

    assign cfg_mux_hsel   = fc_rx_cfg_active ? 1'b1             : ahb_cfg_hsel;
    assign cfg_mux_haddr  = fc_rx_cfg_active ? fc_rx_cfg_haddr  : ahb_cfg_haddr;
    assign cfg_mux_htrans = fc_rx_cfg_active ? fc_rx_cfg_htrans : ahb_cfg_htrans;
    assign cfg_mux_hsize  = fc_rx_cfg_active ? fc_rx_cfg_hsize  : ahb_cfg_hsize;
    assign cfg_mux_hwrite = fc_rx_cfg_active ? fc_rx_cfg_hwrite : ahb_cfg_hwrite;
    assign cfg_mux_hwdata = fc_rx_cfg_active ? fc_rx_cfg_hwdata : ahb_cfg_hwdata;
    assign cfg_mux_hready = cfg_mux_hreadyout;

    assign fc_rx_cfg_hready    = fc_rx_cfg_active ? cfg_mux_hreadyout : 1'b1;
    assign fc_rx_cfg_hresp     = cfg_mux_hresp;
    assign fc_rx_cfg_hrdata    = cfg_mux_hrdata;
    assign ahb_cfg_hreadyout   = fc_rx_cfg_active ? 1'b0 : cfg_mux_hreadyout;
    assign ahb_cfg_hresp       = cfg_mux_hresp;
    assign ahb_cfg_hrdata      = cfg_mux_hrdata;

    // =========================================================================
    // 1. TideLink RX FIFO (tidelink_fifo_ahb)
    // =========================================================================
    tidelink_fifo_ahb #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_tidelink_fifo (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave -- FIFO data window (muxed: FC adapter RX + CPU reads)
        .ahbs_hsel         (fifo_mux_hsel),
        .ahbs_hready       (fifo_mux_hready),
        .ahbs_htrans       (fifo_mux_htrans),
        .ahbs_hsize        (fifo_mux_hsize),
        .ahbs_hwrite       (fifo_mux_hwrite),
        .ahbs_haddr        (fifo_mux_haddr),
        .ahbs_hwdata       (fifo_mux_hwdata),
        .ahbs_hreadyout    (fifo_mux_hreadyout),
        .ahbs_hresp        (fifo_mux_hresp),
        .ahbs_hrdata       (fifo_mux_hrdata),

        // AHB Slave -- Config registers (muxed: FC adapter RX sideband + CPU)
        .ahbc_hsel         (cfg_mux_hsel),
        .ahbc_hready       (cfg_mux_hready),
        .ahbc_htrans       (cfg_mux_htrans),
        .ahbc_hsize        (cfg_mux_hsize),
        .ahbc_hwrite       (cfg_mux_hwrite),
        .ahbc_haddr        (cfg_mux_haddr),
        .ahbc_hwdata       (cfg_mux_hwdata),
        .ahbc_hreadyout    (cfg_mux_hreadyout),
        .ahbc_hresp        (cfg_mux_hresp),
        .ahbc_hrdata       (cfg_mux_hrdata),

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
        .packet_committed_irq (packet_committed_irq)
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
        .ahb_tx_hready     (ahb_tx_hready),
        .ahb_tx_hrdata     (ahb_tx_hrdata),
        .ahb_tx_hresp      (ahb_tx_hresp),
        .ahb_tx_hreadyout  (ahb_tx_hreadyout),

        // AHB Slave -- Returner interception
        .rtn_haddr         (rtn_haddr),
        .rtn_hwdata        (rtn_hwdata),
        .rtn_htrans        (rtn_htrans),
        .rtn_hsize         (rtn_hsize),
        .rtn_hwrite        (rtn_hwrite),
        .rtn_hready        (rtn_hready),
        .rtn_hresp         (rtn_hresp),
        .rtn_hrdata        (rtn_hrdata),

        // AHB Master -- RX FIFO path
        .fc_rx_fifo_haddr  (fc_rx_fifo_haddr),
        .fc_rx_fifo_hwdata (fc_rx_fifo_hwdata),
        .fc_rx_fifo_htrans (fc_rx_fifo_htrans),
        .fc_rx_fifo_hsize  (fc_rx_fifo_hsize),
        .fc_rx_fifo_hwrite (fc_rx_fifo_hwrite),
        .fc_rx_fifo_hready (fc_rx_fifo_hready),
        .fc_rx_fifo_hresp  (fc_rx_fifo_hresp),
        .fc_rx_fifo_hrdata (fc_rx_fifo_hrdata),

        // AHB Master -- RX Config path
        .fc_rx_cfg_haddr   (fc_rx_cfg_haddr),
        .fc_rx_cfg_hwdata  (fc_rx_cfg_hwdata),
        .fc_rx_cfg_htrans  (fc_rx_cfg_htrans),
        .fc_rx_cfg_hsize   (fc_rx_cfg_hsize),
        .fc_rx_cfg_hwrite  (fc_rx_cfg_hwrite),
        .fc_rx_cfg_hready  (fc_rx_cfg_hready),
        .fc_rx_cfg_hresp   (fc_rx_cfg_hresp),
        .fc_rx_cfg_hrdata  (fc_rx_cfg_hrdata),

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
