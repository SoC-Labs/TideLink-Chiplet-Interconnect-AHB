// Cocotb testbench for paired TideLink subsystem stress testing
//
// Instantiates two complete TideLink subsystems (A and B), each consisting of:
//   - tidelink_fc_adapter  (FC packet encode/decode)
//   - tidelink_fifo        (FIFO + APB regs + returner)
//   - cmsdk_ahb_to_apb     (CPU AHB config path -> APB bridge)
//   - APB 2:1 mux          (FC adapter APB config vs CPU APB config)
//
// FC adapter RX paths (new interface):
//   - FIFO writes: direct-write interface (fc_rx_fifo_valid/addr/wdata)
//                  -> tidelink_fifo fc_wr_* ports (no AHB mux needed)
//   - Config writes: APB master (fc_rx_cfg_p*)
//                    -> APB mux with CPU bridge output -> tidelink_fifo apbs_*
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

    // Returner AHB master (tidelink_fifo -> fc_adapter)
    wire [SYS_ADDR_W-1:0]  a_rtn_haddr;
    wire [SYS_DATA_W-1:0]  a_rtn_hwdata;
    wire              [1:0] a_rtn_htrans;
    wire              [2:0] a_rtn_hsize;
    wire                    a_rtn_hwrite;
    wire                    a_rtn_hready;
    wire                    a_rtn_hresp;
    wire [SYS_DATA_W-1:0]  a_rtn_hrdata;

    // FC adapter RX direct write (fc_adapter -> tidelink_fifo fc_wr_*)
    wire                    a_fc_rx_fifo_valid;
    wire                    a_fc_rx_fifo_write;
    wire [RAM_ADDR_W-1:0]  a_fc_rx_fifo_addr;
    wire [SYS_DATA_W-1:0]  a_fc_rx_fifo_wdata;
    wire                    a_fc_rx_fifo_ready;

    // FC adapter RX config APB (fc_adapter -> APB mux)
    wire [APB_ADDR_W-1:0]  a_fc_cfg_paddr;
    wire [SYS_DATA_W-1:0]  a_fc_cfg_pwdata;
    wire                    a_fc_cfg_psel;
    wire                    a_fc_cfg_penable;
    wire                    a_fc_cfg_pwrite;
    wire [SYS_DATA_W-1:0]  a_fc_cfg_prdata;
    wire                    a_fc_cfg_pready;

    // CPU AHB-to-APB bridge output (bridge -> APB mux)
    wire [APB_ADDR_W-1:0]  a_cpu_apb_paddr;
    wire                    a_cpu_apb_psel;
    wire                    a_cpu_apb_penable;
    wire                    a_cpu_apb_pwrite;
    wire [SYS_DATA_W-1:0]  a_cpu_apb_pwdata;
    wire [SYS_DATA_W-1:0]  a_cpu_apb_prdata;
    wire                    a_cpu_apb_pready;
    wire                    a_cpu_apb_pslverr;

    // APB mux output (-> tidelink_fifo apbs_*)
    wire [APB_ADDR_W-1:0]  a_apb_mux_paddr;
    wire                    a_apb_mux_psel;
    wire                    a_apb_mux_penable;
    wire                    a_apb_mux_pwrite;
    wire [SYS_DATA_W-1:0]  a_apb_mux_pwdata;
    wire [SYS_DATA_W-1:0]  a_apb_mux_prdata;
    wire                    a_apb_mux_pready;
    wire                    a_apb_mux_pslverr;

    // -----------------------------------------------------------------
    // Side A: APB 2:1 mux (FC adapter has priority over CPU bridge)
    // -----------------------------------------------------------------
    wire a_fc_cfg_active = a_fc_cfg_psel;

    assign a_apb_mux_paddr   = a_fc_cfg_active ? a_fc_cfg_paddr   : a_cpu_apb_paddr;
    assign a_apb_mux_psel    = a_fc_cfg_active ? a_fc_cfg_psel    : a_cpu_apb_psel;
    assign a_apb_mux_penable = a_fc_cfg_active ? a_fc_cfg_penable : a_cpu_apb_penable;
    assign a_apb_mux_pwrite  = a_fc_cfg_active ? a_fc_cfg_pwrite  : a_cpu_apb_pwrite;
    assign a_apb_mux_pwdata  = a_fc_cfg_active ? a_fc_cfg_pwdata  : a_cpu_apb_pwdata;

    // Route APB responses back to both sources
    assign a_fc_cfg_prdata  = a_apb_mux_prdata;
    assign a_fc_cfg_pready  = a_apb_mux_pready;

    assign a_cpu_apb_prdata  = a_fc_cfg_active ? '0   : a_apb_mux_prdata;
    assign a_cpu_apb_pready  = a_fc_cfg_active ? 1'b0 : a_apb_mux_pready;
    assign a_cpu_apb_pslverr = a_fc_cfg_active ? 1'b0 : a_apb_mux_pslverr;

    // -----------------------------------------------------------------
    // Side A: FIFO read port -- direct connection (no mux needed)
    // CPU reads go via AHB slave; FC writes go via fc_wr_* direct-write.
    // -----------------------------------------------------------------
    wire a_fifo_hreadyout;
    assign a_ahb_fifo_hready = a_fifo_hreadyout;

    // =====================================================================
    // Side B -- Internal wiring
    // =====================================================================

    // Returner AHB master (tidelink_fifo -> fc_adapter)
    wire [SYS_ADDR_W-1:0]  b_rtn_haddr;
    wire [SYS_DATA_W-1:0]  b_rtn_hwdata;
    wire              [1:0] b_rtn_htrans;
    wire              [2:0] b_rtn_hsize;
    wire                    b_rtn_hwrite;
    wire                    b_rtn_hready;
    wire                    b_rtn_hresp;
    wire [SYS_DATA_W-1:0]  b_rtn_hrdata;

    // FC adapter RX direct write (fc_adapter -> tidelink_fifo fc_wr_*)
    wire                    b_fc_rx_fifo_valid;
    wire                    b_fc_rx_fifo_write;
    wire [RAM_ADDR_W-1:0]  b_fc_rx_fifo_addr;
    wire [SYS_DATA_W-1:0]  b_fc_rx_fifo_wdata;
    wire                    b_fc_rx_fifo_ready;

    // FC adapter RX config APB (fc_adapter -> APB mux)
    wire [APB_ADDR_W-1:0]  b_fc_cfg_paddr;
    wire [SYS_DATA_W-1:0]  b_fc_cfg_pwdata;
    wire                    b_fc_cfg_psel;
    wire                    b_fc_cfg_penable;
    wire                    b_fc_cfg_pwrite;
    wire [SYS_DATA_W-1:0]  b_fc_cfg_prdata;
    wire                    b_fc_cfg_pready;

    // CPU AHB-to-APB bridge output (bridge -> APB mux)
    wire [APB_ADDR_W-1:0]  b_cpu_apb_paddr;
    wire                    b_cpu_apb_psel;
    wire                    b_cpu_apb_penable;
    wire                    b_cpu_apb_pwrite;
    wire [SYS_DATA_W-1:0]  b_cpu_apb_pwdata;
    wire [SYS_DATA_W-1:0]  b_cpu_apb_prdata;
    wire                    b_cpu_apb_pready;
    wire                    b_cpu_apb_pslverr;

    // APB mux output (-> tidelink_fifo apbs_*)
    wire [APB_ADDR_W-1:0]  b_apb_mux_paddr;
    wire                    b_apb_mux_psel;
    wire                    b_apb_mux_penable;
    wire                    b_apb_mux_pwrite;
    wire [SYS_DATA_W-1:0]  b_apb_mux_pwdata;
    wire [SYS_DATA_W-1:0]  b_apb_mux_prdata;
    wire                    b_apb_mux_pready;
    wire                    b_apb_mux_pslverr;

    // -----------------------------------------------------------------
    // Side B: APB 2:1 mux (FC adapter has priority over CPU bridge)
    // -----------------------------------------------------------------
    wire b_fc_cfg_active = b_fc_cfg_psel;

    assign b_apb_mux_paddr   = b_fc_cfg_active ? b_fc_cfg_paddr   : b_cpu_apb_paddr;
    assign b_apb_mux_psel    = b_fc_cfg_active ? b_fc_cfg_psel    : b_cpu_apb_psel;
    assign b_apb_mux_penable = b_fc_cfg_active ? b_fc_cfg_penable : b_cpu_apb_penable;
    assign b_apb_mux_pwrite  = b_fc_cfg_active ? b_fc_cfg_pwrite  : b_cpu_apb_pwrite;
    assign b_apb_mux_pwdata  = b_fc_cfg_active ? b_fc_cfg_pwdata  : b_cpu_apb_pwdata;

    // Route APB responses back to both sources
    assign b_fc_cfg_prdata  = b_apb_mux_prdata;
    assign b_fc_cfg_pready  = b_apb_mux_pready;

    assign b_cpu_apb_prdata  = b_fc_cfg_active ? '0   : b_apb_mux_prdata;
    assign b_cpu_apb_pready  = b_fc_cfg_active ? 1'b0 : b_apb_mux_pready;
    assign b_cpu_apb_pslverr = b_fc_cfg_active ? 1'b0 : b_apb_mux_pslverr;

    // -----------------------------------------------------------------
    // Side B: FIFO read port -- direct connection (no mux needed)
    // -----------------------------------------------------------------
    wire b_fifo_hreadyout;
    assign b_ahb_fifo_hready = b_fifo_hreadyout;

    // =====================================================================
    // Side A -- CPU AHB-to-APB Bridge (config path)
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
        .PADDR     (a_cpu_apb_paddr),
        .PSEL      (a_cpu_apb_psel),
        .PENABLE   (a_cpu_apb_penable),
        .PWRITE    (a_cpu_apb_pwrite),
        .PSTRB     (),
        .PPROT     (),
        .PWDATA    (a_cpu_apb_pwdata),
        .APBACTIVE (),
        .PRDATA    (a_cpu_apb_prdata),
        .PREADY    (a_cpu_apb_pready),
        .PSLVERR   (a_cpu_apb_pslverr)
    );

    // Note: a_ahb_cfg_hready is an output port driven by the bridge's HREADYOUT,
    // and fed back to the bridge's HREADY input (single-master, no other AHB agents).

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

        // AHB Slave -- FIFO data window (CPU reads, direct connection)
        .ahbs_hsel         (a_ahb_fifo_hsel),
        .ahbs_hready       (a_fifo_hreadyout),
        .ahbs_htrans       (a_ahb_fifo_htrans),
        .ahbs_hsize        (a_ahb_fifo_hsize),
        .ahbs_hwrite       (a_ahb_fifo_hwrite),
        .ahbs_haddr        (a_ahb_fifo_haddr),
        .ahbs_hwdata       (a_ahb_fifo_hwdata),
        .ahbs_hreadyout    (a_fifo_hreadyout),
        .ahbs_hresp        (a_ahb_fifo_hresp),
        .ahbs_hrdata       (a_ahb_fifo_hrdata),

        // APB Slave -- Config registers (via APB mux)
        .apbs_psel         (a_apb_mux_psel),
        .apbs_penable      (a_apb_mux_penable),
        .apbs_pwrite       (a_apb_mux_pwrite),
        .apbs_paddr        (a_apb_mux_paddr),
        .apbs_pwdata       (a_apb_mux_pwdata),
        .apbs_prdata       (a_apb_mux_prdata),
        .apbs_pready       (a_apb_mux_pready),
        .apbs_pslverr      (a_apb_mux_pslverr),

        // AHB Master -- Returner (routed to FC adapter)
        .ahbm_haddr        (a_rtn_haddr),
        .ahbm_hwdata       (a_rtn_hwdata),
        .ahbm_htrans       (a_rtn_htrans),
        .ahbm_hsize        (a_rtn_hsize),
        .ahbm_hwrite       (a_rtn_hwrite),
        .ahbm_hready       (a_rtn_hready),
        .ahbm_hresp        (a_rtn_hresp),
        .ahbm_hrdata       (a_rtn_hrdata),

        // Interrupts
        .released_credits_irq (a_released_credits_irq),
        .doorbell_irq         (a_doorbell_irq),
        .packet_committed_irq (a_packet_committed_irq),

        // PTP register pass-through (tied off -- no PTP in this testbench)
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

        // FC direct write (from FC adapter)
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

        // AHB Slave -- Returner interception
        .rtn_haddr         (a_rtn_haddr),
        .rtn_hwdata        (a_rtn_hwdata),
        .rtn_htrans        (a_rtn_htrans),
        .rtn_hsize         (a_rtn_hsize),
        .rtn_hwrite        (a_rtn_hwrite),
        .rtn_hready        (a_rtn_hready),
        .rtn_hresp         (a_rtn_hresp),
        .rtn_hrdata        (a_rtn_hrdata),

        // Direct Write -- RX FIFO path (to tidelink_fifo fc_wr_*)
        .fc_rx_fifo_valid  (a_fc_rx_fifo_valid),
        .fc_rx_fifo_write  (a_fc_rx_fifo_write),
        .fc_rx_fifo_addr   (a_fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (a_fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (a_fc_rx_fifo_ready),

        // APB Master -- RX Config path (to APB mux)
        .fc_rx_cfg_paddr   (a_fc_cfg_paddr),
        .fc_rx_cfg_pwdata  (a_fc_cfg_pwdata),
        .fc_rx_cfg_psel    (a_fc_cfg_psel),
        .fc_rx_cfg_penable (a_fc_cfg_penable),
        .fc_rx_cfg_pwrite  (a_fc_cfg_pwrite),
        .fc_rx_cfg_prdata  (a_fc_cfg_prdata),
        .fc_rx_cfg_pready  (a_fc_cfg_pready),

        // Servo FC injection (tied off -- no servo in this testbench)
        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        // FC Node interface
        .tl_fc_a2l_valid   (a_fc_a2l_valid),
        .tl_fc_a2l_data    (a_fc_a2l_data),
        .tl_fc_a2l_ready   (a_fc_a2l_ready),
        .tl_fc_l2a_valid   (a_fc_l2a_valid),
        .tl_fc_l2a_data    (a_fc_l2a_data),
        .tl_fc_l2a_accept  (a_fc_l2a_accept)
    );

    // =====================================================================
    // Side B -- CPU AHB-to-APB Bridge (config path)
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
        .PADDR     (b_cpu_apb_paddr),
        .PSEL      (b_cpu_apb_psel),
        .PENABLE   (b_cpu_apb_penable),
        .PWRITE    (b_cpu_apb_pwrite),
        .PSTRB     (),
        .PPROT     (),
        .PWDATA    (b_cpu_apb_pwdata),
        .APBACTIVE (),
        .PRDATA    (b_cpu_apb_prdata),
        .PREADY    (b_cpu_apb_pready),
        .PSLVERR   (b_cpu_apb_pslverr)
    );

    // Note: b_ahb_cfg_hready is an output port driven by the bridge's HREADYOUT,
    // and fed back to the bridge's HREADY input (single-master, no other AHB agents).

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

        // AHB Slave -- FIFO data window (CPU reads, direct connection)
        .ahbs_hsel         (b_ahb_fifo_hsel),
        .ahbs_hready       (b_fifo_hreadyout),
        .ahbs_htrans       (b_ahb_fifo_htrans),
        .ahbs_hsize        (b_ahb_fifo_hsize),
        .ahbs_hwrite       (b_ahb_fifo_hwrite),
        .ahbs_haddr        (b_ahb_fifo_haddr),
        .ahbs_hwdata       (b_ahb_fifo_hwdata),
        .ahbs_hreadyout    (b_fifo_hreadyout),
        .ahbs_hresp        (b_ahb_fifo_hresp),
        .ahbs_hrdata       (b_ahb_fifo_hrdata),

        // APB Slave -- Config registers (via APB mux)
        .apbs_psel         (b_apb_mux_psel),
        .apbs_penable      (b_apb_mux_penable),
        .apbs_pwrite       (b_apb_mux_pwrite),
        .apbs_paddr        (b_apb_mux_paddr),
        .apbs_pwdata       (b_apb_mux_pwdata),
        .apbs_prdata       (b_apb_mux_prdata),
        .apbs_pready       (b_apb_mux_pready),
        .apbs_pslverr      (b_apb_mux_pslverr),

        // AHB Master -- Returner (routed to FC adapter)
        .ahbm_haddr        (b_rtn_haddr),
        .ahbm_hwdata       (b_rtn_hwdata),
        .ahbm_htrans       (b_rtn_htrans),
        .ahbm_hsize        (b_rtn_hsize),
        .ahbm_hwrite       (b_rtn_hwrite),
        .ahbm_hready       (b_rtn_hready),
        .ahbm_hresp        (b_rtn_hresp),
        .ahbm_hrdata       (b_rtn_hrdata),

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

        // FC direct write (from FC adapter)
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

        // AHB Slave -- Returner interception
        .rtn_haddr         (b_rtn_haddr),
        .rtn_hwdata        (b_rtn_hwdata),
        .rtn_htrans        (b_rtn_htrans),
        .rtn_hsize         (b_rtn_hsize),
        .rtn_hwrite        (b_rtn_hwrite),
        .rtn_hready        (b_rtn_hready),
        .rtn_hresp         (b_rtn_hresp),
        .rtn_hrdata        (b_rtn_hrdata),

        // Direct Write -- RX FIFO path (to tidelink_fifo fc_wr_*)
        .fc_rx_fifo_valid  (b_fc_rx_fifo_valid),
        .fc_rx_fifo_write  (b_fc_rx_fifo_write),
        .fc_rx_fifo_addr   (b_fc_rx_fifo_addr),
        .fc_rx_fifo_wdata  (b_fc_rx_fifo_wdata),
        .fc_rx_fifo_ready  (b_fc_rx_fifo_ready),

        // APB Master -- RX Config path (to APB mux)
        .fc_rx_cfg_paddr   (b_fc_cfg_paddr),
        .fc_rx_cfg_pwdata  (b_fc_cfg_pwdata),
        .fc_rx_cfg_psel    (b_fc_cfg_psel),
        .fc_rx_cfg_penable (b_fc_cfg_penable),
        .fc_rx_cfg_pwrite  (b_fc_cfg_pwrite),
        .fc_rx_cfg_prdata  (b_fc_cfg_prdata),
        .fc_rx_cfg_pready  (b_fc_cfg_pready),

        // Servo FC injection (tied off -- no servo in this testbench)
        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        // FC Node interface
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
