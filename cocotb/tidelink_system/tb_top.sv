// Cocotb testbench for paired TideLink subsystem stress testing
//
// Instantiates two complete TideLink subsystems (A and B), each consisting of:
//   - tidelink_fc_adapter (FC packet encode/decode)
//   - tidelink_fifo_ahb   (FIFO + AHB-to-APB bridge + returner)
//   - FIFO port mux       (FC adapter RX vs CPU read port)
//   - Config port mux     (FC adapter RX sideband vs CPU config port)
//
// FC crossover wiring:
//   A's a2l (TX output) -> B's l2a (RX input)
//   B's a2l (TX output) -> A's l2a (RX input)
//
// This exercises full bidirectional data flow and credit exchange between
// two independent TideLink endpoints connected back-to-back.
//
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter FC_DATA_W  = 48,
    parameter [SYS_ADDR_W-1:0] TIDELINK_A_PAIR_BASE = '0,
    parameter [SYS_ADDR_W-1:0] TIDELINK_B_PAIR_BASE = '0
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // =====================================================================
    // Side A -- AHB Slave ports
    // =====================================================================

    // AHB Slave -- TX aperture A
    input  logic                    a_ahb_tx_hsel,
    input  logic  [RAM_ADDR_W-1:0] a_ahb_tx_haddr,
    input  logic              [1:0] a_ahb_tx_htrans,
    input  logic              [2:0] a_ahb_tx_hsize,
    input  logic                    a_ahb_tx_hwrite,
    input  logic  [SYS_DATA_W-1:0] a_ahb_tx_hwdata,
    output logic  [SYS_DATA_W-1:0] a_ahb_tx_hrdata,
    output logic                    a_ahb_tx_hresp,
    output logic                    a_ahb_tx_hready,

    // AHB Slave -- FIFO data read port A
    input  logic                    a_ahb_fifo_hsel,
    input  logic  [RAM_ADDR_W-1:0] a_ahb_fifo_haddr,
    input  logic              [1:0] a_ahb_fifo_htrans,
    input  logic              [2:0] a_ahb_fifo_hsize,
    input  logic                    a_ahb_fifo_hwrite,
    input  logic  [SYS_DATA_W-1:0] a_ahb_fifo_hwdata,
    output logic  [SYS_DATA_W-1:0] a_ahb_fifo_hrdata,
    output logic                    a_ahb_fifo_hresp,
    output logic                    a_ahb_fifo_hready,

    // AHB Slave -- Config registers A
    input  logic                    a_ahb_cfg_hsel,
    input  logic  [APB_ADDR_W-1:0] a_ahb_cfg_haddr,
    input  logic              [1:0] a_ahb_cfg_htrans,
    input  logic              [2:0] a_ahb_cfg_hsize,
    input  logic                    a_ahb_cfg_hwrite,
    input  logic  [SYS_DATA_W-1:0] a_ahb_cfg_hwdata,
    output logic  [SYS_DATA_W-1:0] a_ahb_cfg_hrdata,
    output logic                    a_ahb_cfg_hresp,
    output logic                    a_ahb_cfg_hready,

    // Interrupt outputs A
    output logic                    a_released_credits_irq,
    output logic                    a_doorbell_irq,
    output logic                    a_packet_committed_irq,

    // =====================================================================
    // Side B -- AHB Slave ports
    // =====================================================================

    // AHB Slave -- TX aperture B
    input  logic                    b_ahb_tx_hsel,
    input  logic  [RAM_ADDR_W-1:0] b_ahb_tx_haddr,
    input  logic              [1:0] b_ahb_tx_htrans,
    input  logic              [2:0] b_ahb_tx_hsize,
    input  logic                    b_ahb_tx_hwrite,
    input  logic  [SYS_DATA_W-1:0] b_ahb_tx_hwdata,
    output logic  [SYS_DATA_W-1:0] b_ahb_tx_hrdata,
    output logic                    b_ahb_tx_hresp,
    output logic                    b_ahb_tx_hready,

    // AHB Slave -- FIFO data read port B
    input  logic                    b_ahb_fifo_hsel,
    input  logic  [RAM_ADDR_W-1:0] b_ahb_fifo_haddr,
    input  logic              [1:0] b_ahb_fifo_htrans,
    input  logic              [2:0] b_ahb_fifo_hsize,
    input  logic                    b_ahb_fifo_hwrite,
    input  logic  [SYS_DATA_W-1:0] b_ahb_fifo_hwdata,
    output logic  [SYS_DATA_W-1:0] b_ahb_fifo_hrdata,
    output logic                    b_ahb_fifo_hresp,
    output logic                    b_ahb_fifo_hready,

    // AHB Slave -- Config registers B
    input  logic                    b_ahb_cfg_hsel,
    input  logic  [APB_ADDR_W-1:0] b_ahb_cfg_haddr,
    input  logic              [1:0] b_ahb_cfg_htrans,
    input  logic              [2:0] b_ahb_cfg_hsize,
    input  logic                    b_ahb_cfg_hwrite,
    input  logic  [SYS_DATA_W-1:0] b_ahb_cfg_hwdata,
    output logic  [SYS_DATA_W-1:0] b_ahb_cfg_hrdata,
    output logic                    b_ahb_cfg_hresp,
    output logic                    b_ahb_cfg_hready,

    // Interrupt outputs B
    output logic                    b_released_credits_irq,
    output logic                    b_doorbell_irq,
    output logic                    b_packet_committed_irq
);

    // =====================================================================
    // FC crossover wiring: A's TX -> B's RX, B's TX -> A's RX
    // =====================================================================
    wire                   a_fc_a2l_valid;
    wire [FC_DATA_W-1:0]  a_fc_a2l_data;
    wire                   a_fc_a2l_ready;
    wire                   a_fc_l2a_valid;
    wire [FC_DATA_W-1:0]  a_fc_l2a_data;
    wire                   a_fc_l2a_accept;

    wire                   b_fc_a2l_valid;
    wire [FC_DATA_W-1:0]  b_fc_a2l_data;
    wire                   b_fc_a2l_ready;
    wire                   b_fc_l2a_valid;
    wire [FC_DATA_W-1:0]  b_fc_l2a_data;
    wire                   b_fc_l2a_accept;

    // Crossover: A TX -> B RX, B TX -> A RX
    assign b_fc_l2a_valid = a_fc_a2l_valid;
    assign b_fc_l2a_data  = a_fc_a2l_data;
    assign a_fc_a2l_ready = b_fc_l2a_accept;

    assign a_fc_l2a_valid = b_fc_a2l_valid;
    assign a_fc_l2a_data  = b_fc_a2l_data;
    assign b_fc_a2l_ready = a_fc_l2a_accept;

    // =====================================================================
    // Side A -- Internal wiring
    // =====================================================================
    wire [SYS_ADDR_W-1:0]  a_rtn_haddr;
    wire [SYS_DATA_W-1:0]  a_rtn_hwdata;
    wire              [1:0] a_rtn_htrans;
    wire              [2:0] a_rtn_hsize;
    wire                    a_rtn_hwrite;
    wire                    a_rtn_hready;
    wire                    a_rtn_hresp;
    wire [SYS_DATA_W-1:0]  a_rtn_hrdata;

    wire [RAM_ADDR_W-1:0]  a_fc_rx_fifo_haddr;
    wire [SYS_DATA_W-1:0]  a_fc_rx_fifo_hwdata;
    wire              [1:0] a_fc_rx_fifo_htrans;
    wire              [2:0] a_fc_rx_fifo_hsize;
    wire                    a_fc_rx_fifo_hwrite;
    wire                    a_fc_rx_fifo_hready;
    wire                    a_fc_rx_fifo_hresp;
    wire [SYS_DATA_W-1:0]  a_fc_rx_fifo_hrdata;

    wire [APB_ADDR_W-1:0]  a_fc_rx_cfg_haddr;
    wire [SYS_DATA_W-1:0]  a_fc_rx_cfg_hwdata;
    wire              [1:0] a_fc_rx_cfg_htrans;
    wire              [2:0] a_fc_rx_cfg_hsize;
    wire                    a_fc_rx_cfg_hwrite;
    wire                    a_fc_rx_cfg_hready;
    wire                    a_fc_rx_cfg_hresp;
    wire [SYS_DATA_W-1:0]  a_fc_rx_cfg_hrdata;

    // Side A FIFO port mux
    wire                    a_fifo_mux_hsel;
    wire [RAM_ADDR_W-1:0]  a_fifo_mux_haddr;
    wire              [1:0] a_fifo_mux_htrans;
    wire              [2:0] a_fifo_mux_hsize;
    wire                    a_fifo_mux_hwrite;
    wire [SYS_DATA_W-1:0]  a_fifo_mux_hwdata;
    wire                    a_fifo_mux_hready;
    wire [SYS_DATA_W-1:0]  a_fifo_mux_hrdata;
    wire                    a_fifo_mux_hresp;
    wire                    a_fifo_mux_hreadyout;

    // FC RX FIFO active: high from addr phase through data phase completion.
    // Tracks the FC adapter's full AHB transaction to prevent mux switching
    // mid-transaction.
    wire a_fc_rx_fifo_addr_phase = a_fc_rx_fifo_htrans[1];
    reg  a_fc_rx_fifo_data_phase;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            a_fc_rx_fifo_data_phase <= 1'b0;
        else if (a_fc_rx_fifo_addr_phase && a_fifo_mux_hreadyout)
            a_fc_rx_fifo_data_phase <= 1'b1;
        else if (a_fc_rx_fifo_data_phase && a_fifo_mux_hreadyout)
            a_fc_rx_fifo_data_phase <= 1'b0;
    end
    wire a_fc_rx_fifo_active = a_fc_rx_fifo_addr_phase | a_fc_rx_fifo_data_phase;

    assign a_fifo_mux_hsel   = a_fc_rx_fifo_active ? 1'b1                 : a_ahb_fifo_hsel;
    assign a_fifo_mux_haddr  = a_fc_rx_fifo_active ? a_fc_rx_fifo_haddr   : a_ahb_fifo_haddr;
    assign a_fifo_mux_htrans = a_fc_rx_fifo_active ? a_fc_rx_fifo_htrans  : a_ahb_fifo_htrans;
    assign a_fifo_mux_hsize  = a_fc_rx_fifo_active ? a_fc_rx_fifo_hsize   : a_ahb_fifo_hsize;
    assign a_fifo_mux_hwrite = a_fc_rx_fifo_active ? a_fc_rx_fifo_hwrite  : a_ahb_fifo_hwrite;
    assign a_fifo_mux_hwdata = a_fc_rx_fifo_active ? a_fc_rx_fifo_hwdata  : a_ahb_fifo_hwdata;
    assign a_fifo_mux_hready = a_fifo_mux_hreadyout;

    assign a_fc_rx_fifo_hready    = a_fc_rx_fifo_active ? a_fifo_mux_hreadyout : 1'b1;
    assign a_fc_rx_fifo_hresp     = a_fifo_mux_hresp;
    assign a_fc_rx_fifo_hrdata    = a_fifo_mux_hrdata;
    assign a_ahb_fifo_hready      = a_fc_rx_fifo_active ? 1'b0 : a_fifo_mux_hreadyout;
    assign a_ahb_fifo_hresp       = a_fifo_mux_hresp;
    assign a_ahb_fifo_hrdata      = a_fifo_mux_hrdata;

    // Side A Config port mux
    wire                    a_cfg_mux_hsel;
    wire [APB_ADDR_W-1:0]  a_cfg_mux_haddr;
    wire              [1:0] a_cfg_mux_htrans;
    wire              [2:0] a_cfg_mux_hsize;
    wire                    a_cfg_mux_hwrite;
    wire [SYS_DATA_W-1:0]  a_cfg_mux_hwdata;
    wire                    a_cfg_mux_hready;
    wire [SYS_DATA_W-1:0]  a_cfg_mux_hrdata;
    wire                    a_cfg_mux_hresp;
    wire                    a_cfg_mux_hreadyout;

    // FC RX config active: high from addr phase through data phase completion
    wire a_fc_rx_cfg_addr_phase = a_fc_rx_cfg_htrans[1];
    reg  a_fc_rx_cfg_data_phase;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            a_fc_rx_cfg_data_phase <= 1'b0;
        else if (a_fc_rx_cfg_addr_phase && a_cfg_mux_hreadyout)
            a_fc_rx_cfg_data_phase <= 1'b1;
        else if (a_fc_rx_cfg_data_phase && a_cfg_mux_hreadyout)
            a_fc_rx_cfg_data_phase <= 1'b0;
    end
    wire a_fc_rx_cfg_active = a_fc_rx_cfg_addr_phase | a_fc_rx_cfg_data_phase;

    assign a_cfg_mux_hsel   = a_fc_rx_cfg_active ? 1'b1                : a_ahb_cfg_hsel;
    assign a_cfg_mux_haddr  = a_fc_rx_cfg_active ? a_fc_rx_cfg_haddr   : a_ahb_cfg_haddr;
    assign a_cfg_mux_htrans = a_fc_rx_cfg_active ? a_fc_rx_cfg_htrans  : a_ahb_cfg_htrans;
    assign a_cfg_mux_hsize  = a_fc_rx_cfg_active ? a_fc_rx_cfg_hsize   : a_ahb_cfg_hsize;
    assign a_cfg_mux_hwrite = a_fc_rx_cfg_active ? a_fc_rx_cfg_hwrite  : a_ahb_cfg_hwrite;
    assign a_cfg_mux_hwdata = a_fc_rx_cfg_active ? a_fc_rx_cfg_hwdata  : a_ahb_cfg_hwdata;
    assign a_cfg_mux_hready = a_cfg_mux_hreadyout;

    assign a_fc_rx_cfg_hready    = a_fc_rx_cfg_active ? a_cfg_mux_hreadyout : 1'b1;
    assign a_fc_rx_cfg_hresp     = a_cfg_mux_hresp;
    assign a_fc_rx_cfg_hrdata    = a_cfg_mux_hrdata;
    assign a_ahb_cfg_hready      = a_fc_rx_cfg_active ? 1'b0 : a_cfg_mux_hreadyout;
    assign a_ahb_cfg_hresp       = a_cfg_mux_hresp;
    assign a_ahb_cfg_hrdata      = a_cfg_mux_hrdata;

    // =====================================================================
    // Side B -- Internal wiring
    // =====================================================================
    wire [SYS_ADDR_W-1:0]  b_rtn_haddr;
    wire [SYS_DATA_W-1:0]  b_rtn_hwdata;
    wire              [1:0] b_rtn_htrans;
    wire              [2:0] b_rtn_hsize;
    wire                    b_rtn_hwrite;
    wire                    b_rtn_hready;
    wire                    b_rtn_hresp;
    wire [SYS_DATA_W-1:0]  b_rtn_hrdata;

    wire [RAM_ADDR_W-1:0]  b_fc_rx_fifo_haddr;
    wire [SYS_DATA_W-1:0]  b_fc_rx_fifo_hwdata;
    wire              [1:0] b_fc_rx_fifo_htrans;
    wire              [2:0] b_fc_rx_fifo_hsize;
    wire                    b_fc_rx_fifo_hwrite;
    wire                    b_fc_rx_fifo_hready;
    wire                    b_fc_rx_fifo_hresp;
    wire [SYS_DATA_W-1:0]  b_fc_rx_fifo_hrdata;

    wire [APB_ADDR_W-1:0]  b_fc_rx_cfg_haddr;
    wire [SYS_DATA_W-1:0]  b_fc_rx_cfg_hwdata;
    wire              [1:0] b_fc_rx_cfg_htrans;
    wire              [2:0] b_fc_rx_cfg_hsize;
    wire                    b_fc_rx_cfg_hwrite;
    wire                    b_fc_rx_cfg_hready;
    wire                    b_fc_rx_cfg_hresp;
    wire [SYS_DATA_W-1:0]  b_fc_rx_cfg_hrdata;

    // Side B FIFO port mux
    wire                    b_fifo_mux_hsel;
    wire [RAM_ADDR_W-1:0]  b_fifo_mux_haddr;
    wire              [1:0] b_fifo_mux_htrans;
    wire              [2:0] b_fifo_mux_hsize;
    wire                    b_fifo_mux_hwrite;
    wire [SYS_DATA_W-1:0]  b_fifo_mux_hwdata;
    wire                    b_fifo_mux_hready;
    wire [SYS_DATA_W-1:0]  b_fifo_mux_hrdata;
    wire                    b_fifo_mux_hresp;
    wire                    b_fifo_mux_hreadyout;

    // FC RX FIFO active: high from addr phase through data phase completion
    wire b_fc_rx_fifo_addr_phase = b_fc_rx_fifo_htrans[1];
    reg  b_fc_rx_fifo_data_phase;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            b_fc_rx_fifo_data_phase <= 1'b0;
        else if (b_fc_rx_fifo_addr_phase && b_fifo_mux_hreadyout)
            b_fc_rx_fifo_data_phase <= 1'b1;
        else if (b_fc_rx_fifo_data_phase && b_fifo_mux_hreadyout)
            b_fc_rx_fifo_data_phase <= 1'b0;
    end
    wire b_fc_rx_fifo_active = b_fc_rx_fifo_addr_phase | b_fc_rx_fifo_data_phase;

    assign b_fifo_mux_hsel   = b_fc_rx_fifo_active ? 1'b1                 : b_ahb_fifo_hsel;
    assign b_fifo_mux_haddr  = b_fc_rx_fifo_active ? b_fc_rx_fifo_haddr   : b_ahb_fifo_haddr;
    assign b_fifo_mux_htrans = b_fc_rx_fifo_active ? b_fc_rx_fifo_htrans  : b_ahb_fifo_htrans;
    assign b_fifo_mux_hsize  = b_fc_rx_fifo_active ? b_fc_rx_fifo_hsize   : b_ahb_fifo_hsize;
    assign b_fifo_mux_hwrite = b_fc_rx_fifo_active ? b_fc_rx_fifo_hwrite  : b_ahb_fifo_hwrite;
    assign b_fifo_mux_hwdata = b_fc_rx_fifo_active ? b_fc_rx_fifo_hwdata  : b_ahb_fifo_hwdata;
    assign b_fifo_mux_hready = b_fifo_mux_hreadyout;

    assign b_fc_rx_fifo_hready    = b_fc_rx_fifo_active ? b_fifo_mux_hreadyout : 1'b1;
    assign b_fc_rx_fifo_hresp     = b_fifo_mux_hresp;
    assign b_fc_rx_fifo_hrdata    = b_fifo_mux_hrdata;
    assign b_ahb_fifo_hready      = b_fc_rx_fifo_active ? 1'b0 : b_fifo_mux_hreadyout;
    assign b_ahb_fifo_hresp       = b_fifo_mux_hresp;
    assign b_ahb_fifo_hrdata      = b_fifo_mux_hrdata;

    // Side B Config port mux
    wire                    b_cfg_mux_hsel;
    wire [APB_ADDR_W-1:0]  b_cfg_mux_haddr;
    wire              [1:0] b_cfg_mux_htrans;
    wire              [2:0] b_cfg_mux_hsize;
    wire                    b_cfg_mux_hwrite;
    wire [SYS_DATA_W-1:0]  b_cfg_mux_hwdata;
    wire                    b_cfg_mux_hready;
    wire [SYS_DATA_W-1:0]  b_cfg_mux_hrdata;
    wire                    b_cfg_mux_hresp;
    wire                    b_cfg_mux_hreadyout;

    // FC RX config active: high from addr phase through data phase completion
    wire b_fc_rx_cfg_addr_phase = b_fc_rx_cfg_htrans[1];
    reg  b_fc_rx_cfg_data_phase;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            b_fc_rx_cfg_data_phase <= 1'b0;
        else if (b_fc_rx_cfg_addr_phase && b_cfg_mux_hreadyout)
            b_fc_rx_cfg_data_phase <= 1'b1;
        else if (b_fc_rx_cfg_data_phase && b_cfg_mux_hreadyout)
            b_fc_rx_cfg_data_phase <= 1'b0;
    end
    wire b_fc_rx_cfg_active = b_fc_rx_cfg_addr_phase | b_fc_rx_cfg_data_phase;

    assign b_cfg_mux_hsel   = b_fc_rx_cfg_active ? 1'b1                : b_ahb_cfg_hsel;
    assign b_cfg_mux_haddr  = b_fc_rx_cfg_active ? b_fc_rx_cfg_haddr   : b_ahb_cfg_haddr;
    assign b_cfg_mux_htrans = b_fc_rx_cfg_active ? b_fc_rx_cfg_htrans  : b_ahb_cfg_htrans;
    assign b_cfg_mux_hsize  = b_fc_rx_cfg_active ? b_fc_rx_cfg_hsize   : b_ahb_cfg_hsize;
    assign b_cfg_mux_hwrite = b_fc_rx_cfg_active ? b_fc_rx_cfg_hwrite  : b_ahb_cfg_hwrite;
    assign b_cfg_mux_hwdata = b_fc_rx_cfg_active ? b_fc_rx_cfg_hwdata  : b_ahb_cfg_hwdata;
    assign b_cfg_mux_hready = b_cfg_mux_hreadyout;

    assign b_fc_rx_cfg_hready    = b_fc_rx_cfg_active ? b_cfg_mux_hreadyout : 1'b1;
    assign b_fc_rx_cfg_hresp     = b_cfg_mux_hresp;
    assign b_fc_rx_cfg_hrdata    = b_cfg_mux_hrdata;
    assign b_ahb_cfg_hready      = b_fc_rx_cfg_active ? 1'b0 : b_cfg_mux_hreadyout;
    assign b_ahb_cfg_hresp       = b_cfg_mux_hresp;
    assign b_ahb_cfg_hrdata      = b_cfg_mux_hrdata;

    // =====================================================================
    // Side A -- FIFO instance
    // =====================================================================
    tidelink_fifo_ahb #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_A_PAIR_BASE)
    ) u_fifo_a (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .ahbs_hsel         (a_fifo_mux_hsel),
        .ahbs_hready       (a_fifo_mux_hready),
        .ahbs_htrans       (a_fifo_mux_htrans),
        .ahbs_hsize        (a_fifo_mux_hsize),
        .ahbs_hwrite       (a_fifo_mux_hwrite),
        .ahbs_haddr        (a_fifo_mux_haddr),
        .ahbs_hwdata       (a_fifo_mux_hwdata),
        .ahbs_hreadyout    (a_fifo_mux_hreadyout),
        .ahbs_hresp        (a_fifo_mux_hresp),
        .ahbs_hrdata       (a_fifo_mux_hrdata),
        .ahbc_hsel         (a_cfg_mux_hsel),
        .ahbc_hready       (a_cfg_mux_hready),
        .ahbc_htrans       (a_cfg_mux_htrans),
        .ahbc_hsize        (a_cfg_mux_hsize),
        .ahbc_hwrite       (a_cfg_mux_hwrite),
        .ahbc_haddr        (a_cfg_mux_haddr),
        .ahbc_hwdata       (a_cfg_mux_hwdata),
        .ahbc_hreadyout    (a_cfg_mux_hreadyout),
        .ahbc_hresp        (a_cfg_mux_hresp),
        .ahbc_hrdata       (a_cfg_mux_hrdata),
        .ahbm_haddr        (a_rtn_haddr),
        .ahbm_hwdata       (a_rtn_hwdata),
        .ahbm_htrans       (a_rtn_htrans),
        .ahbm_hsize        (a_rtn_hsize),
        .ahbm_hwrite       (a_rtn_hwrite),
        .ahbm_hready       (a_rtn_hready),
        .ahbm_hresp        (a_rtn_hresp),
        .ahbm_hrdata       (a_rtn_hrdata),
        .released_credits_irq (a_released_credits_irq),
        .doorbell_irq         (a_doorbell_irq),
        .packet_committed_irq (a_packet_committed_irq)
    );

    // =====================================================================
    // Side A -- FC adapter instance
    // =====================================================================
    wire a_ahb_tx_hreadyout;
    assign a_ahb_tx_hready = a_ahb_tx_hreadyout;

    tidelink_fc_adapter #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .APB_ADDR_W (APB_ADDR_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_fc_a (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .ahb_tx_hsel       (a_ahb_tx_hsel),
        .ahb_tx_haddr      (a_ahb_tx_haddr),
        .ahb_tx_htrans     (a_ahb_tx_htrans),
        .ahb_tx_hsize      (a_ahb_tx_hsize),
        .ahb_tx_hwrite     (a_ahb_tx_hwrite),
        .ahb_tx_hwdata     (a_ahb_tx_hwdata),
        .ahb_tx_hready     (a_ahb_tx_hreadyout),
        .ahb_tx_hrdata     (a_ahb_tx_hrdata),
        .ahb_tx_hresp      (a_ahb_tx_hresp),
        .ahb_tx_hreadyout  (a_ahb_tx_hreadyout),
        .rtn_haddr         (a_rtn_haddr),
        .rtn_hwdata        (a_rtn_hwdata),
        .rtn_htrans        (a_rtn_htrans),
        .rtn_hsize         (a_rtn_hsize),
        .rtn_hwrite        (a_rtn_hwrite),
        .rtn_hready        (a_rtn_hready),
        .rtn_hresp         (a_rtn_hresp),
        .rtn_hrdata        (a_rtn_hrdata),
        .fc_rx_fifo_haddr  (a_fc_rx_fifo_haddr),
        .fc_rx_fifo_hwdata (a_fc_rx_fifo_hwdata),
        .fc_rx_fifo_htrans (a_fc_rx_fifo_htrans),
        .fc_rx_fifo_hsize  (a_fc_rx_fifo_hsize),
        .fc_rx_fifo_hwrite (a_fc_rx_fifo_hwrite),
        .fc_rx_fifo_hready (a_fc_rx_fifo_hready),
        .fc_rx_fifo_hresp  (a_fc_rx_fifo_hresp),
        .fc_rx_fifo_hrdata (a_fc_rx_fifo_hrdata),
        .fc_rx_cfg_haddr   (a_fc_rx_cfg_haddr),
        .fc_rx_cfg_hwdata  (a_fc_rx_cfg_hwdata),
        .fc_rx_cfg_htrans  (a_fc_rx_cfg_htrans),
        .fc_rx_cfg_hsize   (a_fc_rx_cfg_hsize),
        .fc_rx_cfg_hwrite  (a_fc_rx_cfg_hwrite),
        .fc_rx_cfg_hready  (a_fc_rx_cfg_hready),
        .fc_rx_cfg_hresp   (a_fc_rx_cfg_hresp),
        .fc_rx_cfg_hrdata  (a_fc_rx_cfg_hrdata),
        .tl_fc_a2l_valid   (a_fc_a2l_valid),
        .tl_fc_a2l_data    (a_fc_a2l_data),
        .tl_fc_a2l_ready   (a_fc_a2l_ready),
        .tl_fc_l2a_valid   (a_fc_l2a_valid),
        .tl_fc_l2a_data    (a_fc_l2a_data),
        .tl_fc_l2a_accept  (a_fc_l2a_accept)
    );

    // =====================================================================
    // Side B -- FIFO instance
    // =====================================================================
    tidelink_fifo_ahb #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_B_PAIR_BASE)
    ) u_fifo_b (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .ahbs_hsel         (b_fifo_mux_hsel),
        .ahbs_hready       (b_fifo_mux_hready),
        .ahbs_htrans       (b_fifo_mux_htrans),
        .ahbs_hsize        (b_fifo_mux_hsize),
        .ahbs_hwrite       (b_fifo_mux_hwrite),
        .ahbs_haddr        (b_fifo_mux_haddr),
        .ahbs_hwdata       (b_fifo_mux_hwdata),
        .ahbs_hreadyout    (b_fifo_mux_hreadyout),
        .ahbs_hresp        (b_fifo_mux_hresp),
        .ahbs_hrdata       (b_fifo_mux_hrdata),
        .ahbc_hsel         (b_cfg_mux_hsel),
        .ahbc_hready       (b_cfg_mux_hready),
        .ahbc_htrans       (b_cfg_mux_htrans),
        .ahbc_hsize        (b_cfg_mux_hsize),
        .ahbc_hwrite       (b_cfg_mux_hwrite),
        .ahbc_haddr        (b_cfg_mux_haddr),
        .ahbc_hwdata       (b_cfg_mux_hwdata),
        .ahbc_hreadyout    (b_cfg_mux_hreadyout),
        .ahbc_hresp        (b_cfg_mux_hresp),
        .ahbc_hrdata       (b_cfg_mux_hrdata),
        .ahbm_haddr        (b_rtn_haddr),
        .ahbm_hwdata       (b_rtn_hwdata),
        .ahbm_htrans       (b_rtn_htrans),
        .ahbm_hsize        (b_rtn_hsize),
        .ahbm_hwrite       (b_rtn_hwrite),
        .ahbm_hready       (b_rtn_hready),
        .ahbm_hresp        (b_rtn_hresp),
        .ahbm_hrdata       (b_rtn_hrdata),
        .released_credits_irq (b_released_credits_irq),
        .doorbell_irq         (b_doorbell_irq),
        .packet_committed_irq (b_packet_committed_irq)
    );

    // =====================================================================
    // Side B -- FC adapter instance
    // =====================================================================
    wire b_ahb_tx_hreadyout;
    assign b_ahb_tx_hready = b_ahb_tx_hreadyout;

    tidelink_fc_adapter #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .APB_ADDR_W (APB_ADDR_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_fc_b (
        .hclk              (hclk),
        .hresetn           (hresetn),
        .ahb_tx_hsel       (b_ahb_tx_hsel),
        .ahb_tx_haddr      (b_ahb_tx_haddr),
        .ahb_tx_htrans     (b_ahb_tx_htrans),
        .ahb_tx_hsize      (b_ahb_tx_hsize),
        .ahb_tx_hwrite     (b_ahb_tx_hwrite),
        .ahb_tx_hwdata     (b_ahb_tx_hwdata),
        .ahb_tx_hready     (b_ahb_tx_hreadyout),
        .ahb_tx_hrdata     (b_ahb_tx_hrdata),
        .ahb_tx_hresp      (b_ahb_tx_hresp),
        .ahb_tx_hreadyout  (b_ahb_tx_hreadyout),
        .rtn_haddr         (b_rtn_haddr),
        .rtn_hwdata        (b_rtn_hwdata),
        .rtn_htrans        (b_rtn_htrans),
        .rtn_hsize         (b_rtn_hsize),
        .rtn_hwrite        (b_rtn_hwrite),
        .rtn_hready        (b_rtn_hready),
        .rtn_hresp         (b_rtn_hresp),
        .rtn_hrdata        (b_rtn_hrdata),
        .fc_rx_fifo_haddr  (b_fc_rx_fifo_haddr),
        .fc_rx_fifo_hwdata (b_fc_rx_fifo_hwdata),
        .fc_rx_fifo_htrans (b_fc_rx_fifo_htrans),
        .fc_rx_fifo_hsize  (b_fc_rx_fifo_hsize),
        .fc_rx_fifo_hwrite (b_fc_rx_fifo_hwrite),
        .fc_rx_fifo_hready (b_fc_rx_fifo_hready),
        .fc_rx_fifo_hresp  (b_fc_rx_fifo_hresp),
        .fc_rx_fifo_hrdata (b_fc_rx_fifo_hrdata),
        .fc_rx_cfg_haddr   (b_fc_rx_cfg_haddr),
        .fc_rx_cfg_hwdata  (b_fc_rx_cfg_hwdata),
        .fc_rx_cfg_htrans  (b_fc_rx_cfg_htrans),
        .fc_rx_cfg_hsize   (b_fc_rx_cfg_hsize),
        .fc_rx_cfg_hwrite  (b_fc_rx_cfg_hwrite),
        .fc_rx_cfg_hready  (b_fc_rx_cfg_hready),
        .fc_rx_cfg_hresp   (b_fc_rx_cfg_hresp),
        .fc_rx_cfg_hrdata  (b_fc_rx_cfg_hrdata),
        .tl_fc_a2l_valid   (b_fc_a2l_valid),
        .tl_fc_a2l_data    (b_fc_a2l_data),
        .tl_fc_a2l_ready   (b_fc_a2l_ready),
        .tl_fc_l2a_valid   (b_fc_l2a_valid),
        .tl_fc_l2a_data    (b_fc_l2a_data),
        .tl_fc_l2a_accept  (b_fc_l2a_accept)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
