// Cocotb testbench for paired TideLink subsystem stress testing
//
// Instantiates two complete TideLink subsystems (A and B), each consisting of:
//   - tidelink_fc_adapter (FC packet encode/decode)
//   - tidelink_fifo       (FIFO + returner)
//   - cmsdk_ahb_to_apb    (AHB-to-APB bridge for CPU config access)
//   - APB mux             (FC adapter RX APB vs CPU APB bridge)
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

    // Returner AHB bus (tidelink_fifo master -> fc_adapter)
    wire [SYS_ADDR_W-1:0]  a_rtn_haddr;
    wire [SYS_DATA_W-1:0]  a_rtn_hwdata;
    wire              [1:0] a_rtn_htrans;
    wire              [2:0] a_rtn_hsize;
    wire                    a_rtn_hwrite;
    wire                    a_rtn_hready;
    wire                    a_rtn_hresp;
    wire [SYS_DATA_W-1:0]  a_rtn_hrdata;

    // FC adapter direct-write FIFO RX outputs
    wire                    a_fc_rx_fifo_valid;
    wire                    a_fc_rx_fifo_write;
    wire [RAM_ADDR_W-1:0]  a_fc_rx_fifo_addr;
    wire [SYS_DATA_W-1:0]  a_fc_rx_fifo_wdata;
    wire                    a_fc_rx_fifo_ready;

    // FC adapter APB config RX outputs
    wire [APB_ADDR_W-1:0]  a_fc_rx_cfg_paddr;
    wire [SYS_DATA_W-1:0]  a_fc_rx_cfg_pwdata;
    wire                    a_fc_rx_cfg_psel;
    wire                    a_fc_rx_cfg_penable;
    wire                    a_fc_rx_cfg_pwrite;
    wire [SYS_DATA_W-1:0]  a_fc_rx_cfg_prdata;
    wire                    a_fc_rx_cfg_pready;

    // AHB-to-APB bridge APB outputs (CPU path)
    wire [APB_ADDR_W-1:0]  a_bridge_paddr;
    wire                    a_bridge_psel;
    wire                    a_bridge_penable;
    wire                    a_bridge_pwrite;
    wire [SYS_DATA_W-1:0]  a_bridge_pwdata;
    wire [SYS_DATA_W-1:0]  a_bridge_prdata;
    wire                    a_bridge_pready;

    // Muxed APB to tidelink_fifo
    wire [APB_ADDR_W-1:0]  a_apbs_paddr;
    wire                    a_apbs_psel;
    wire                    a_apbs_penable;
    wire                    a_apbs_pwrite;
    wire [SYS_DATA_W-1:0]  a_apbs_pwdata;
    wire [SYS_DATA_W-1:0]  a_apbs_prdata;
    wire                    a_apbs_pready;
    wire                    a_apbs_pslverr;

    // Side A APB mux: FC config vs CPU bridge
    wire a_fc_cfg_active = a_fc_rx_cfg_psel;

    assign a_apbs_psel    = a_fc_cfg_active ? a_fc_rx_cfg_psel    : a_bridge_psel;
    assign a_apbs_penable = a_fc_cfg_active ? a_fc_rx_cfg_penable : a_bridge_penable;
    assign a_apbs_pwrite  = a_fc_cfg_active ? a_fc_rx_cfg_pwrite  : a_bridge_pwrite;
    assign a_apbs_paddr   = a_fc_cfg_active ? a_fc_rx_cfg_paddr   : a_bridge_paddr;
    assign a_apbs_pwdata  = a_fc_cfg_active ? a_fc_rx_cfg_pwdata  : a_bridge_pwdata;

    assign a_fc_rx_cfg_prdata = a_apbs_prdata;
    assign a_fc_rx_cfg_pready = a_apbs_pready;
    assign a_bridge_prdata    = a_apbs_prdata;
    assign a_bridge_pready    = a_fc_cfg_active ? 1'b0 : a_apbs_pready;

    // Side A: CPU FIFO read port directly to tidelink_fifo AHB slave
    // (no mux needed -- FC adapter uses fc_wr_* direct-write path instead)
    wire a_fifo_hreadyout;
    wire a_fifo_hresp;
    wire [SYS_DATA_W-1:0] a_fifo_hrdata;

    assign a_ahb_fifo_hready = a_fifo_hreadyout;
    assign a_ahb_fifo_hresp  = a_fifo_hresp;
    assign a_ahb_fifo_hrdata = a_fifo_hrdata;

    // =====================================================================
    // Side B -- Internal wiring
    // =====================================================================

    // Returner AHB bus (tidelink_fifo master -> fc_adapter)
    wire [SYS_ADDR_W-1:0]  b_rtn_haddr;
    wire [SYS_DATA_W-1:0]  b_rtn_hwdata;
    wire              [1:0] b_rtn_htrans;
    wire              [2:0] b_rtn_hsize;
    wire                    b_rtn_hwrite;
    wire                    b_rtn_hready;
    wire                    b_rtn_hresp;
    wire [SYS_DATA_W-1:0]  b_rtn_hrdata;

    // FC adapter direct-write FIFO RX outputs
    wire                    b_fc_rx_fifo_valid;
    wire                    b_fc_rx_fifo_write;
    wire [RAM_ADDR_W-1:0]  b_fc_rx_fifo_addr;
    wire [SYS_DATA_W-1:0]  b_fc_rx_fifo_wdata;
    wire                    b_fc_rx_fifo_ready;

    // FC adapter APB config RX outputs
    wire [APB_ADDR_W-1:0]  b_fc_rx_cfg_paddr;
    wire [SYS_DATA_W-1:0]  b_fc_rx_cfg_pwdata;
    wire                    b_fc_rx_cfg_psel;
    wire                    b_fc_rx_cfg_penable;
    wire                    b_fc_rx_cfg_pwrite;
    wire [SYS_DATA_W-1:0]  b_fc_rx_cfg_prdata;
    wire                    b_fc_rx_cfg_pready;

    // AHB-to-APB bridge APB outputs (CPU path)
    wire [APB_ADDR_W-1:0]  b_bridge_paddr;
    wire                    b_bridge_psel;
    wire                    b_bridge_penable;
    wire                    b_bridge_pwrite;
    wire [SYS_DATA_W-1:0]  b_bridge_pwdata;
    wire [SYS_DATA_W-1:0]  b_bridge_prdata;
    wire                    b_bridge_pready;

    // Muxed APB to tidelink_fifo
    wire [APB_ADDR_W-1:0]  b_apbs_paddr;
    wire                    b_apbs_psel;
    wire                    b_apbs_penable;
    wire                    b_apbs_pwrite;
    wire [SYS_DATA_W-1:0]  b_apbs_pwdata;
    wire [SYS_DATA_W-1:0]  b_apbs_prdata;
    wire                    b_apbs_pready;
    wire                    b_apbs_pslverr;

    // Side B APB mux: FC config vs CPU bridge
    wire b_fc_cfg_active = b_fc_rx_cfg_psel;

    assign b_apbs_psel    = b_fc_cfg_active ? b_fc_rx_cfg_psel    : b_bridge_psel;
    assign b_apbs_penable = b_fc_cfg_active ? b_fc_rx_cfg_penable : b_bridge_penable;
    assign b_apbs_pwrite  = b_fc_cfg_active ? b_fc_rx_cfg_pwrite  : b_bridge_pwrite;
    assign b_apbs_paddr   = b_fc_cfg_active ? b_fc_rx_cfg_paddr   : b_bridge_paddr;
    assign b_apbs_pwdata  = b_fc_cfg_active ? b_fc_rx_cfg_pwdata  : b_bridge_pwdata;

    assign b_fc_rx_cfg_prdata = b_apbs_prdata;
    assign b_fc_rx_cfg_pready = b_apbs_pready;
    assign b_bridge_prdata    = b_apbs_prdata;
    assign b_bridge_pready    = b_fc_cfg_active ? 1'b0 : b_apbs_pready;

    // Side B: CPU FIFO read port directly to tidelink_fifo AHB slave
    wire b_fifo_hreadyout;
    wire b_fifo_hresp;
    wire [SYS_DATA_W-1:0] b_fifo_hrdata;

    assign b_ahb_fifo_hready = b_fifo_hreadyout;
    assign b_ahb_fifo_hresp  = b_fifo_hresp;
    assign b_ahb_fifo_hrdata = b_fifo_hrdata;

    // =====================================================================
    // Side A -- AHB-to-APB Bridge (CPU config path)
    // =====================================================================
    cmsdk_ahb_to_apb #(
        .ADDRWIDTH      (APB_ADDR_W),
        .REGISTER_RDATA (1),
        .REGISTER_WDATA (0)
    ) u_ahb_to_apb_a (
        .HCLK      (hclk),
        .HRESETn   (hresetn),
        .PCLKEN    (1'b1),
        .HSEL      (a_ahb_cfg_hsel),
        .HADDR     (a_ahb_cfg_haddr),
        .HTRANS    (a_ahb_cfg_htrans),
        .HSIZE     (a_ahb_cfg_hsize),
        .HPROT     (4'b0011),
        .HWRITE    (a_ahb_cfg_hwrite),
        .HREADY    (a_ahb_cfg_hready),
        .HWDATA    (a_ahb_cfg_hwdata),
        .HREADYOUT (a_ahb_cfg_hready),
        .HRDATA    (a_ahb_cfg_hrdata),
        .HRESP     (a_ahb_cfg_hresp),
        .PADDR     (a_bridge_paddr),
        .PSEL      (a_bridge_psel),
        .PENABLE   (a_bridge_penable),
        .PWRITE    (a_bridge_pwrite),
        .PSTRB     (),
        .PPROT     (),
        .PWDATA    (a_bridge_pwdata),
        .APBACTIVE (),
        .PRDATA    (a_bridge_prdata),
        .PREADY    (a_bridge_pready),
        .PSLVERR   (1'b0)
    );

    // =====================================================================
    // Side A -- FIFO instance (tidelink_fifo, not tidelink_fifo_ahb)
    // =====================================================================
    tidelink_fifo #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_A_PAIR_BASE)
    ) u_fifo_a (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave -- FIFO data (CPU read/write)
        .ahbs_hsel         (a_ahb_fifo_hsel),
        .ahbs_hready       (a_ahb_fifo_hready),
        .ahbs_htrans       (a_ahb_fifo_htrans),
        .ahbs_hsize        (a_ahb_fifo_hsize),
        .ahbs_hwrite       (a_ahb_fifo_hwrite),
        .ahbs_haddr        (a_ahb_fifo_haddr),
        .ahbs_hwdata       (a_ahb_fifo_hwdata),
        .ahbs_hreadyout    (a_fifo_hreadyout),
        .ahbs_hresp        (a_fifo_hresp),
        .ahbs_hrdata       (a_fifo_hrdata),

        // AHB Master -- Returner
        .ahbm_haddr        (a_rtn_haddr),
        .ahbm_hwdata       (a_rtn_hwdata),
        .ahbm_htrans       (a_rtn_htrans),
        .ahbm_hsize        (a_rtn_hsize),
        .ahbm_hwrite       (a_rtn_hwrite),
        .ahbm_hready       (a_rtn_hready),
        .ahbm_hresp        (a_rtn_hresp),
        .ahbm_hrdata       (a_rtn_hrdata),

        // APB Slave -- muxed config
        .apbs_psel         (a_apbs_psel),
        .apbs_penable      (a_apbs_penable),
        .apbs_pwrite       (a_apbs_pwrite),
        .apbs_paddr        (a_apbs_paddr),
        .apbs_pwdata       (a_apbs_pwdata),
        .apbs_prdata       (a_apbs_prdata),
        .apbs_pready       (a_apbs_pready),
        .apbs_pslverr      (a_apbs_pslverr),

        // Interrupts
        .released_credits_irq (a_released_credits_irq),
        .doorbell_irq         (a_doorbell_irq),
        .packet_committed_irq (a_packet_committed_irq),

        // PTP register pass-through (tied off)
        .ptp_reg_write       (),
        .ptp_reg_addr        (),
        .ptp_reg_wdata       (),
        .ptp_reg_rdata       ({SYS_DATA_W{1'b0}}),
        .ptp_reg_region      (),

        // Servo register pass-through (tied off)
        .servo_reg_write     (),
        .servo_reg_addr      (),
        .servo_reg_wdata     (),
        .servo_reg_rdata     ({SYS_DATA_W{1'b0}}),

        // Timestamp mailbox pass-through (tied off)
        .mbox_reg_write      (),
        .mbox_reg_addr       (),
        .mbox_reg_wdata      (),

        // FC direct-write interface (from FC adapter)
        .fc_wr_valid         (a_fc_rx_fifo_valid),
        .fc_wr_write         (a_fc_rx_fifo_write),
        .fc_wr_addr          (a_fc_rx_fifo_addr),
        .fc_wr_wdata         (a_fc_rx_fifo_wdata),
        .fc_wr_ready         (a_fc_rx_fifo_ready)
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

        // AHB Slave -- TX aperture
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

        // Returner interception
        .rtn_haddr         (a_rtn_haddr),
        .rtn_hwdata        (a_rtn_hwdata),
        .rtn_htrans        (a_rtn_htrans),
        .rtn_hsize         (a_rtn_hsize),
        .rtn_hwrite        (a_rtn_hwrite),
        .rtn_hready        (a_rtn_hready),
        .rtn_hresp         (a_rtn_hresp),
        .rtn_hrdata        (a_rtn_hrdata),

        // Direct-write FIFO RX path
        .fc_rx_fifo_valid  (a_fc_rx_fifo_valid),
        .fc_rx_fifo_write  (a_fc_rx_fifo_write),
        .fc_rx_fifo_addr   (a_fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (a_fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (a_fc_rx_fifo_ready),

        // APB master config RX path
        .fc_rx_cfg_paddr   (a_fc_rx_cfg_paddr),
        .fc_rx_cfg_pwdata  (a_fc_rx_cfg_pwdata),
        .fc_rx_cfg_psel    (a_fc_rx_cfg_psel),
        .fc_rx_cfg_penable (a_fc_rx_cfg_penable),
        .fc_rx_cfg_pwrite  (a_fc_rx_cfg_pwrite),
        .fc_rx_cfg_prdata  (a_fc_rx_cfg_prdata),
        .fc_rx_cfg_pready  (a_fc_rx_cfg_pready),

        // Servo timestamp injection (tied off)
        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        .tc_axis_tx_tvalid   (1'b0),
        .tc_axis_tx_tdata    ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready   (),
        .tc_axis_rx_tvalid   (),
        .tc_axis_rx_tdata    (),
        .tc_axis_rx_tready  (1'b1),

        // FC node interface
        .tl_fc_a2l_valid   (a_fc_a2l_valid),
        .tl_fc_a2l_data    (a_fc_a2l_data),
        .tl_fc_a2l_ready   (a_fc_a2l_ready),
        .tl_fc_l2a_valid   (a_fc_l2a_valid),
        .tl_fc_l2a_data    (a_fc_l2a_data),
        .tl_fc_l2a_accept  (a_fc_l2a_accept)
    );

    // =====================================================================
    // Side B -- AHB-to-APB Bridge (CPU config path)
    // =====================================================================
    cmsdk_ahb_to_apb #(
        .ADDRWIDTH      (APB_ADDR_W),
        .REGISTER_RDATA (1),
        .REGISTER_WDATA (0)
    ) u_ahb_to_apb_b (
        .HCLK      (hclk),
        .HRESETn   (hresetn),
        .PCLKEN    (1'b1),
        .HSEL      (b_ahb_cfg_hsel),
        .HADDR     (b_ahb_cfg_haddr),
        .HTRANS    (b_ahb_cfg_htrans),
        .HSIZE     (b_ahb_cfg_hsize),
        .HPROT     (4'b0011),
        .HWRITE    (b_ahb_cfg_hwrite),
        .HREADY    (b_ahb_cfg_hready),
        .HWDATA    (b_ahb_cfg_hwdata),
        .HREADYOUT (b_ahb_cfg_hready),
        .HRDATA    (b_ahb_cfg_hrdata),
        .HRESP     (b_ahb_cfg_hresp),
        .PADDR     (b_bridge_paddr),
        .PSEL      (b_bridge_psel),
        .PENABLE   (b_bridge_penable),
        .PWRITE    (b_bridge_pwrite),
        .PSTRB     (),
        .PPROT     (),
        .PWDATA    (b_bridge_pwdata),
        .APBACTIVE (),
        .PRDATA    (b_bridge_prdata),
        .PREADY    (b_bridge_pready),
        .PSLVERR   (1'b0)
    );

    // =====================================================================
    // Side B -- FIFO instance (tidelink_fifo, not tidelink_fifo_ahb)
    // =====================================================================
    tidelink_fifo #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .RAM_ADDR_W        (RAM_ADDR_W),
        .RAM_DATA_W        (RAM_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_B_PAIR_BASE)
    ) u_fifo_b (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // AHB Slave -- FIFO data (CPU read/write)
        .ahbs_hsel         (b_ahb_fifo_hsel),
        .ahbs_hready       (b_ahb_fifo_hready),
        .ahbs_htrans       (b_ahb_fifo_htrans),
        .ahbs_hsize        (b_ahb_fifo_hsize),
        .ahbs_hwrite       (b_ahb_fifo_hwrite),
        .ahbs_haddr        (b_ahb_fifo_haddr),
        .ahbs_hwdata       (b_ahb_fifo_hwdata),
        .ahbs_hreadyout    (b_fifo_hreadyout),
        .ahbs_hresp        (b_fifo_hresp),
        .ahbs_hrdata       (b_fifo_hrdata),

        // AHB Master -- Returner
        .ahbm_haddr        (b_rtn_haddr),
        .ahbm_hwdata       (b_rtn_hwdata),
        .ahbm_htrans       (b_rtn_htrans),
        .ahbm_hsize        (b_rtn_hsize),
        .ahbm_hwrite       (b_rtn_hwrite),
        .ahbm_hready       (b_rtn_hready),
        .ahbm_hresp        (b_rtn_hresp),
        .ahbm_hrdata       (b_rtn_hrdata),

        // APB Slave -- muxed config
        .apbs_psel         (b_apbs_psel),
        .apbs_penable      (b_apbs_penable),
        .apbs_pwrite       (b_apbs_pwrite),
        .apbs_paddr        (b_apbs_paddr),
        .apbs_pwdata       (b_apbs_pwdata),
        .apbs_prdata       (b_apbs_prdata),
        .apbs_pready       (b_apbs_pready),
        .apbs_pslverr      (b_apbs_pslverr),

        // Interrupts
        .released_credits_irq (b_released_credits_irq),
        .doorbell_irq         (b_doorbell_irq),
        .packet_committed_irq (b_packet_committed_irq),

        // PTP register pass-through (tied off)
        .ptp_reg_write       (),
        .ptp_reg_addr        (),
        .ptp_reg_wdata       (),
        .ptp_reg_rdata       ({SYS_DATA_W{1'b0}}),
        .ptp_reg_region      (),

        // Servo register pass-through (tied off)
        .servo_reg_write     (),
        .servo_reg_addr      (),
        .servo_reg_wdata     (),
        .servo_reg_rdata     ({SYS_DATA_W{1'b0}}),

        // Timestamp mailbox pass-through (tied off)
        .mbox_reg_write      (),
        .mbox_reg_addr       (),
        .mbox_reg_wdata      (),

        // FC direct-write interface (from FC adapter)
        .fc_wr_valid         (b_fc_rx_fifo_valid),
        .fc_wr_write         (b_fc_rx_fifo_write),
        .fc_wr_addr          (b_fc_rx_fifo_addr),
        .fc_wr_wdata         (b_fc_rx_fifo_wdata),
        .fc_wr_ready         (b_fc_rx_fifo_ready)
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

        // AHB Slave -- TX aperture
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

        // Returner interception
        .rtn_haddr         (b_rtn_haddr),
        .rtn_hwdata        (b_rtn_hwdata),
        .rtn_htrans        (b_rtn_htrans),
        .rtn_hsize         (b_rtn_hsize),
        .rtn_hwrite        (b_rtn_hwrite),
        .rtn_hready        (b_rtn_hready),
        .rtn_hresp         (b_rtn_hresp),
        .rtn_hrdata        (b_rtn_hrdata),

        // Direct-write FIFO RX path
        .fc_rx_fifo_valid  (b_fc_rx_fifo_valid),
        .fc_rx_fifo_write  (b_fc_rx_fifo_write),
        .fc_rx_fifo_addr   (b_fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (b_fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (b_fc_rx_fifo_ready),

        // APB master config RX path
        .fc_rx_cfg_paddr   (b_fc_rx_cfg_paddr),
        .fc_rx_cfg_pwdata  (b_fc_rx_cfg_pwdata),
        .fc_rx_cfg_psel    (b_fc_rx_cfg_psel),
        .fc_rx_cfg_penable (b_fc_rx_cfg_penable),
        .fc_rx_cfg_pwrite  (b_fc_rx_cfg_pwrite),
        .fc_rx_cfg_prdata  (b_fc_rx_cfg_prdata),
        .fc_rx_cfg_pready  (b_fc_rx_cfg_pready),

        // Servo timestamp injection (tied off)
        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        .tc_axis_tx_tvalid   (1'b0),
        .tc_axis_tx_tdata    ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready   (),
        .tc_axis_rx_tvalid   (),
        .tc_axis_rx_tdata    (),
        .tc_axis_rx_tready  (1'b1),

        // FC node interface
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
