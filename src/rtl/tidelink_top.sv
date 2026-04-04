//-----------------------------------------------------------------------------
// SoCLabs TideLink Top-Level Chiplet Subsystem
//
// Wraps all chiplet communication components into a single module:
//   - TideLink RX FIFO (tidelink_fifo_ahb): receive-side packet buffer
//   - TideLink FC Adapter: bridges AHB TX aperture and returner to
//     a dedicated Wlink FC node (data_id=0xa1, 48-bit)
//   - XHB500 AHB-to-AXI bridge: regular AHB subordinate path
//   - XHB500 AXI-to-AHB bridge: regular AHB manager path
//   - Address Translator: APB-configurable address remapping for AXI path
//   - Chiplet Controller (modified Wlink): link layer, FC, CRC/ECC, PHY
//
// External interfaces:
//   ahb_sub_*  — AHB subordinate: regular AHB access to remote side
//                (via XHB500 → AXI → Wlink, address translated)
//   ahb_tx_*   — AHB subordinate: TideLink TX aperture (direct to FC node,
//                same aperture size as remote RX FIFO, no address translation)
//   ahb_fifo_* — AHB subordinate: local RX FIFO data window (read packets)
//   ahb_cfg_*  — AHB subordinate: TideLink config registers (via APB bridge)
//   ahb_mng_*  — AHB manager: incoming from remote side (via XHB500)
//   ahb_adr_*  — AHB subordinate: address translator configuration
//   ahb_ctrl_* — APB subordinate: Wlink chiplet controller configuration
//
// Reference: nanosoc_ss_chiplet_mng.v in nanosoc-chiplet-tech
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_top #(
    // System parameters
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,

    // TideLink FIFO parameters
    parameter RAM_ADDR_W = 14,       // FIFO SRAM address width (16KB default)
    parameter RAM_DATA_W = 32,       // FIFO SRAM data width
    parameter APB_ADDR_W = 12,       // APB register address width

    // TideLink FC node parameters
    parameter FC_DATA_W  = 48,       // FC node data width (matches AXI W channel)

    // PHY parameters
    parameter NUM_PHY_LANES = 8,     // Number of GPIO PHY lanes (default 8 for production)

    // Default pair base address (for returner — routed through FC sideband)
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  wire                     hclk,           // AHB / application clock
    input  wire                     hresetn,        // Active-low reset
    input  wire                     poresetn,       // Power-on reset (active-low)

    // --------------------------------------------------------------------------
    // AHB Subordinate — Regular AHB access to remote side
    // (via XHB500 AHB→AXI → Wlink → remote XHB500 AXI→AHB)
    // --------------------------------------------------------------------------
    input  wire                     ahb_sub_hsel,
    input  wire  [SYS_ADDR_W-1:0]  ahb_sub_haddr,
    input  wire               [2:0] ahb_sub_hburst,
    input  wire               [3:0] ahb_sub_hprot,
    input  wire               [2:0] ahb_sub_hsize,
    input  wire               [1:0] ahb_sub_htrans,
    input  wire  [SYS_DATA_W-1:0]  ahb_sub_hwdata,
    input  wire                     ahb_sub_hwrite,
    input  wire                     ahb_sub_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_sub_hrdata,
    output wire                     ahb_sub_hresp,
    output wire                     ahb_sub_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Subordinate — TideLink TX Aperture
    // (direct to TideLink FC node, same size as remote RX FIFO)
    // --------------------------------------------------------------------------
    input  wire                     ahb_tx_hsel,
    input  wire  [RAM_ADDR_W-1:0]  ahb_tx_haddr,
    input  wire               [1:0] ahb_tx_htrans,
    input  wire               [2:0] ahb_tx_hsize,
    input  wire                     ahb_tx_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_tx_hwdata,
    input  wire                     ahb_tx_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_tx_hrdata,
    output wire                     ahb_tx_hresp,
    output wire                     ahb_tx_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Subordinate — Local RX FIFO data window (read received packets)
    // --------------------------------------------------------------------------
    input  wire                     ahb_fifo_hsel,
    input  wire  [RAM_ADDR_W-1:0]  ahb_fifo_haddr,
    input  wire               [1:0] ahb_fifo_htrans,
    input  wire               [2:0] ahb_fifo_hsize,
    input  wire                     ahb_fifo_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_fifo_hwdata,
    input  wire                     ahb_fifo_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_fifo_hrdata,
    output wire                     ahb_fifo_hresp,
    output wire                     ahb_fifo_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Subordinate — TideLink FIFO config registers (via APB bridge)
    // --------------------------------------------------------------------------
    input  wire                     ahb_cfg_hsel,
    input  wire   [APB_ADDR_W-1:0] ahb_cfg_haddr,
    input  wire               [1:0] ahb_cfg_htrans,
    input  wire               [2:0] ahb_cfg_hsize,
    input  wire                     ahb_cfg_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_cfg_hwdata,
    input  wire                     ahb_cfg_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_cfg_hrdata,
    output wire                     ahb_cfg_hresp,
    output wire                     ahb_cfg_hreadyout,

    // --------------------------------------------------------------------------
    // AHB Manager — Incoming from remote side (via XHB500 AXI→AHB)
    // --------------------------------------------------------------------------
    output wire  [SYS_ADDR_W-1:0]  ahb_mng_haddr,
    output wire               [2:0] ahb_mng_hburst,
    output wire               [3:0] ahb_mng_hprot,
    output wire               [2:0] ahb_mng_hsize,
    output wire               [1:0] ahb_mng_htrans,
    output wire  [SYS_DATA_W-1:0]  ahb_mng_hwdata,
    output wire                     ahb_mng_hwrite,
    output wire                     ahb_mng_hready,
    input  wire  [SYS_DATA_W-1:0]  ahb_mng_hrdata,
    input  wire                     ahb_mng_hresp,

    // --------------------------------------------------------------------------
    // AHB Subordinate — Address translator configuration
    // --------------------------------------------------------------------------
    input  wire                     ahb_adr_hsel,
    input  wire  [SYS_ADDR_W-1:0]  ahb_adr_haddr,
    input  wire               [2:0] ahb_adr_hburst,
    input  wire               [3:0] ahb_adr_hprot,
    input  wire               [2:0] ahb_adr_hsize,
    input  wire               [1:0] ahb_adr_htrans,
    input  wire  [SYS_DATA_W-1:0]  ahb_adr_hwdata,
    input  wire                     ahb_adr_hwrite,
    input  wire                     ahb_adr_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_adr_hrdata,
    output wire                     ahb_adr_hresp,
    output wire                     ahb_adr_hreadyout,

    // --------------------------------------------------------------------------
    // APB Subordinate — Chiplet controller (Wlink) configuration
    // --------------------------------------------------------------------------
    input  wire              [12:0] apb_ctrl_paddr,
    input  wire                     apb_ctrl_penable,
    input  wire                     apb_ctrl_pwrite,
    input  wire               [3:0] apb_ctrl_pstrb,
    input  wire               [2:0] apb_ctrl_pprot,
    input  wire  [SYS_DATA_W-1:0]  apb_ctrl_pwdata,
    input  wire                     apb_ctrl_psel,
    output wire  [SYS_DATA_W-1:0]  apb_ctrl_prdata,
    output wire                     apb_ctrl_pready,
    output wire                     apb_ctrl_pslverr,

    // --------------------------------------------------------------------------
    // Scan / DFT
    // --------------------------------------------------------------------------
    input  wire                     scan_mode,
    input  wire                     scan_asyncrst_ctrl,
    input  wire                     scan_clk,
    input  wire                     scan_shift,
    input  wire                     scan_in,
    output wire                     scan_out,

    // --------------------------------------------------------------------------
    // Reference clock for Wlink PLL
    // --------------------------------------------------------------------------
    input  wire                     user_ref_clk,

    // --------------------------------------------------------------------------
    // General Bus (interrupt forwarding across link)
    // --------------------------------------------------------------------------
    input  wire              [31:0] gb_in,
    output wire              [31:0] gb_out,

    // --------------------------------------------------------------------------
    // PHY Pads (width depends on NUM_PHY_LANES: 1 for GPIO, 8 for SerDes)
    // --------------------------------------------------------------------------
    output wire                              pad_clk_tx,
    output wire        [NUM_PHY_LANES-1:0]   pad_tx,
    input  wire                              pad_clk_rx,
    input  wire        [NUM_PHY_LANES-1:0]   pad_rx,

    // --------------------------------------------------------------------------
    // AHB Subordinate — PTP TX Write Port
    // (CPU writes here to trigger PTP FC messages)
    // --------------------------------------------------------------------------
    input  wire                     ahb_ptp_hsel,
    input  wire               [3:0] ahb_ptp_haddr,
    input  wire               [1:0] ahb_ptp_htrans,
    input  wire               [2:0] ahb_ptp_hsize,
    input  wire                     ahb_ptp_hwrite,
    input  wire  [SYS_DATA_W-1:0]  ahb_ptp_hwdata,
    input  wire                     ahb_ptp_hready,
    output wire  [SYS_DATA_W-1:0]  ahb_ptp_hrdata,
    output wire                     ahb_ptp_hresp,
    output wire                     ahb_ptp_hreadyout,

    // --------------------------------------------------------------------------
    // PHC Hardware Capture Output (directly to external PHC hw_capture input)
    // --------------------------------------------------------------------------
    output wire                     phc_hw_capture,

    // --------------------------------------------------------------------------
    // Interrupt Outputs
    // --------------------------------------------------------------------------
    output wire                     released_credits_irq,
    output wire                     doorbell_irq,
    output wire                     packet_committed_irq,
    output wire                     ptp_irq,
    output wire                     wlink_irq,

    // --------------------------------------------------------------------------
    // Reset output
    // --------------------------------------------------------------------------
    output wire                     d2d_reset_o
);

    // =========================================================================
    // Internal AXI wiring (XHB500 ↔ Chiplet Controller)
    // =========================================================================

    // AXI subordinate path (ahb_sub → XHB500 AHB→AXI → chiplet controller s_axi)
    wire [11:0]  s_axi_awid;
    wire [35:0]  s_axi_awaddr;
    wire  [7:0]  s_axi_awlen;
    wire  [2:0]  s_axi_awsize;
    wire  [1:0]  s_axi_awburst;
    wire         s_axi_awlock;
    wire  [3:0]  s_axi_awcache;
    wire  [2:0]  s_axi_awprot;
    wire  [3:0]  s_axi_awqos;
    wire         s_axi_awvalid;
    wire         s_axi_awready;

    wire [31:0]  s_axi_wdata;
    wire  [3:0]  s_axi_wstrb;
    wire         s_axi_wlast;
    wire         s_axi_wvalid;
    wire         s_axi_wready;

    wire [11:0]  s_axi_bid;
    wire  [1:0]  s_axi_bresp;
    wire         s_axi_bvalid;
    wire         s_axi_bready;

    wire [11:0]  s_axi_arid;
    wire [35:0]  s_axi_araddr;
    wire  [7:0]  s_axi_arlen;
    wire  [2:0]  s_axi_arsize;
    wire  [1:0]  s_axi_arburst;
    wire         s_axi_arlock;
    wire  [3:0]  s_axi_arcache;
    wire  [2:0]  s_axi_arprot;
    wire  [3:0]  s_axi_arqos;
    wire         s_axi_arvalid;
    wire         s_axi_arready;

    wire [11:0]  s_axi_rid;
    wire [31:0]  s_axi_rdata;
    wire  [1:0]  s_axi_rresp;
    wire         s_axi_rlast;
    wire         s_axi_rvalid;
    wire         s_axi_rready;

    // AXI manager path (chiplet controller m_axi → XHB500 AXI→AHB → ahb_mng)
    wire [11:0]  m_axi_awid;
    wire [35:0]  m_axi_awaddr;
    wire  [7:0]  m_axi_awlen;
    wire  [2:0]  m_axi_awsize;
    wire  [1:0]  m_axi_awburst;
    wire         m_axi_awlock;
    wire  [3:0]  m_axi_awcache;
    wire  [2:0]  m_axi_awprot;
    wire  [3:0]  m_axi_awqos;
    wire         m_axi_awvalid;
    wire         m_axi_awready;

    wire [31:0]  m_axi_wdata;
    wire  [3:0]  m_axi_wstrb;
    wire         m_axi_wlast;
    wire         m_axi_wvalid;
    wire         m_axi_wready;

    wire [11:0]  m_axi_bid;
    wire  [1:0]  m_axi_bresp;
    wire         m_axi_bvalid;
    wire         m_axi_bready;

    wire [11:0]  m_axi_arid;
    wire [35:0]  m_axi_araddr;
    wire  [7:0]  m_axi_arlen;
    wire  [2:0]  m_axi_arsize;
    wire  [1:0]  m_axi_arburst;
    wire         m_axi_arlock;
    wire  [3:0]  m_axi_arcache;
    wire  [2:0]  m_axi_arprot;
    wire  [3:0]  m_axi_arqos;
    wire         m_axi_arvalid;
    wire         m_axi_arready;

    wire [11:0]  m_axi_rid;
    wire [31:0]  m_axi_rdata;
    wire  [1:0]  m_axi_rresp;
    wire         m_axi_rlast;
    wire         m_axi_rvalid;
    wire         m_axi_rready;

    // =========================================================================
    // TideLink FC Node wiring (FC adapter ↔ Chiplet Controller)
    // =========================================================================
    // Separate valid/ready/data signals (used by FC adapter)
    wire                   tl_fc_a2l_valid;
    wire [FC_DATA_W-1:0]   tl_fc_a2l_data;
    wire                   tl_fc_a2l_ready;
    wire                   tl_fc_l2a_valid;
    wire [FC_DATA_W-1:0]   tl_fc_l2a_data;
    wire                   tl_fc_l2a_accept;

    // =========================================================================
    // PTP FC Node wiring (PTP module ↔ Chiplet Controller)
    // =========================================================================
    wire                   ptp_fc_a2l_valid;
    wire [FC_DATA_W-1:0]  ptp_fc_a2l_data;
    wire                   ptp_fc_a2l_ready;
    wire                   ptp_fc_l2a_valid;
    wire [FC_DATA_W-1:0]  ptp_fc_l2a_data;
    wire                   ptp_fc_l2a_accept;

    // TX link idle signal from chiplet controller (Wlink tx_link_idle output)
    // Directly driven by .tx_link_idle port on the Wlink instance
    wire                   tx_router_idle;

    // PTP register interface (PTP module ↔ APB regs, via pass-through)
    wire                   ptp_reg_write;
    wire            [2:0]  ptp_reg_addr;
    wire [SYS_DATA_W-1:0] ptp_reg_wdata;
    wire [SYS_DATA_W-1:0] ptp_reg_rdata;

    // =========================================================================
    // Returner AHB master wiring (tidelink_fifo_ahb → FC adapter interception)
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
    // FC adapter RX — split AHB master wiring (internal, not exposed)
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
    // FIFO port mux: 2:1 AHB mux for FIFO slave port
    //   Source 0: FC adapter RX FIFO master (writes incoming packets)
    //   Source 1: External ahb_fifo_* port (CPU reads received packets)
    //
    // FC adapter has priority (incoming data must not be dropped).
    // CPU access is stalled via HREADY when FC adapter is active.
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

    // FC adapter owns the mux during ADDR phase (htrans active) AND the
    // following DATA phase.  Combinational for ADDR, registered for DATA.
    reg fc_rx_fifo_data_phase;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            fc_rx_fifo_data_phase <= 1'b0;
        else if (fc_rx_fifo_htrans[1] && fifo_mux_hreadyout)
            fc_rx_fifo_data_phase <= 1'b1;
        else if (fc_rx_fifo_data_phase && fifo_mux_hreadyout)
            fc_rx_fifo_data_phase <= 1'b0;
    end
    wire fc_rx_fifo_active = fc_rx_fifo_htrans[1] || fc_rx_fifo_data_phase;

    assign fifo_mux_hsel   = fc_rx_fifo_active ? 1'b1              : ahb_fifo_hsel;
    assign fifo_mux_haddr  = fc_rx_fifo_active ? fc_rx_fifo_haddr  : ahb_fifo_haddr;
    assign fifo_mux_htrans = fc_rx_fifo_active ? fc_rx_fifo_htrans : ahb_fifo_htrans;
    assign fifo_mux_hsize  = fc_rx_fifo_active ? fc_rx_fifo_hsize  : ahb_fifo_hsize;
    assign fifo_mux_hwrite = fc_rx_fifo_active ? fc_rx_fifo_hwrite : ahb_fifo_hwrite;
    assign fifo_mux_hwdata = fc_rx_fifo_active ? fc_rx_fifo_hwdata : ahb_fifo_hwdata;
    // hready to slave: when FC active, use hreadyout (self-loop for internal master);
    // when CPU active, use external hready (driven by cocotbext-ahb or bus matrix)
    assign fifo_mux_hready = fc_rx_fifo_active ? fifo_mux_hreadyout : ahb_fifo_hready;

    assign fc_rx_fifo_hready    = fc_rx_fifo_active ? fifo_mux_hreadyout : 1'b1;
    assign fc_rx_fifo_hresp     = fifo_mux_hresp;
    assign fc_rx_fifo_hrdata    = fifo_mux_hrdata;
    assign ahb_fifo_hreadyout   = fc_rx_fifo_active ? 1'b0 : fifo_mux_hreadyout;
    assign ahb_fifo_hresp       = fifo_mux_hresp;
    assign ahb_fifo_hrdata      = fifo_mux_hrdata;

    // =========================================================================
    // Config port mux: 2:1 AHB mux for config/APB slave port
    //   Source 0: FC adapter RX Config master (writes credit/doorbell sideband)
    //   Source 1: External ahb_cfg_* port (CPU reads/writes config registers)
    //
    // FC adapter has priority (credit/doorbell delivery is time-sensitive).
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

    reg fc_rx_cfg_data_phase;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            fc_rx_cfg_data_phase <= 1'b0;
        else if (fc_rx_cfg_htrans[1] && cfg_mux_hreadyout)
            fc_rx_cfg_data_phase <= 1'b1;
        else if (fc_rx_cfg_data_phase && cfg_mux_hreadyout)
            fc_rx_cfg_data_phase <= 1'b0;
    end
    wire fc_rx_cfg_active = fc_rx_cfg_htrans[1] || fc_rx_cfg_data_phase;

    assign cfg_mux_hsel   = fc_rx_cfg_active ? 1'b1             : ahb_cfg_hsel;
    assign cfg_mux_haddr  = fc_rx_cfg_active ? fc_rx_cfg_haddr  : ahb_cfg_haddr;
    assign cfg_mux_htrans = fc_rx_cfg_active ? fc_rx_cfg_htrans : ahb_cfg_htrans;
    assign cfg_mux_hsize  = fc_rx_cfg_active ? fc_rx_cfg_hsize  : ahb_cfg_hsize;
    assign cfg_mux_hwrite = fc_rx_cfg_active ? fc_rx_cfg_hwrite : ahb_cfg_hwrite;
    assign cfg_mux_hwdata = fc_rx_cfg_active ? fc_rx_cfg_hwdata : ahb_cfg_hwdata;
    assign cfg_mux_hready = fc_rx_cfg_active ? cfg_mux_hreadyout : ahb_cfg_hready;

    assign fc_rx_cfg_hready    = fc_rx_cfg_active ? cfg_mux_hreadyout : 1'b1;
    assign fc_rx_cfg_hresp     = cfg_mux_hresp;
    assign fc_rx_cfg_hrdata    = cfg_mux_hrdata;
    assign ahb_cfg_hreadyout   = fc_rx_cfg_active ? 1'b0 : cfg_mux_hreadyout;
    assign ahb_cfg_hresp       = cfg_mux_hresp;
    assign ahb_cfg_hrdata      = cfg_mux_hrdata;

    // =========================================================================
    // Address translation wiring
    // =========================================================================
    wire [SYS_ADDR_W-1:0]  translated_sub_haddr;

    // =========================================================================
    // 1. TideLink RX FIFO (tidelink_fifo_ahb)
    //    - AHB slave: FIFO data window (via mux from CPU + FC adapter RX)
    //    - AHB slave: config registers (ahb_cfg_*)
    //    - AHB master: returner → routed to FC adapter for sideband transport
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

        // AHB Slave — FIFO data window (muxed: FC adapter RX writes + CPU reads)
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

        // AHB Slave — Config registers (muxed: FC adapter RX sideband + CPU access)
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

        // AHB Master — Returner (routed to FC adapter, NOT external bus)
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

        // PTP register pass-through (to/from tidelink_ptp)
        .ptp_reg_write       (ptp_reg_write),
        .ptp_reg_addr        (ptp_reg_addr),
        .ptp_reg_wdata       (ptp_reg_wdata),
        .ptp_reg_rdata       (ptp_reg_rdata)
    );

    // =========================================================================
    // 2. TideLink FC Adapter
    //    - TX path: AHB slave (TX aperture) → FC node TX
    //    - RX path: FC node RX → AHB master → local RX FIFO
    //    - Sideband: Intercepts returner AHB master → FC sideband packets
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

        // AHB Slave — TX aperture (CPU/DMA writes FIFO packets here)
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

        // AHB Slave — Returner interception (returner thinks this is remote)
        .rtn_haddr         (rtn_haddr),
        .rtn_hwdata        (rtn_hwdata),
        .rtn_htrans        (rtn_htrans),
        .rtn_hsize         (rtn_hsize),
        .rtn_hwrite        (rtn_hwrite),
        .rtn_hready        (rtn_hready),
        .rtn_hresp         (rtn_hresp),
        .rtn_hrdata        (rtn_hrdata),

        // AHB Master — RX FIFO path (internal, via FIFO mux)
        .fc_rx_fifo_haddr  (fc_rx_fifo_haddr),
        .fc_rx_fifo_hwdata (fc_rx_fifo_hwdata),
        .fc_rx_fifo_htrans (fc_rx_fifo_htrans),
        .fc_rx_fifo_hsize  (fc_rx_fifo_hsize),
        .fc_rx_fifo_hwrite (fc_rx_fifo_hwrite),
        .fc_rx_fifo_hready (fc_rx_fifo_hready),
        .fc_rx_fifo_hresp  (fc_rx_fifo_hresp),
        .fc_rx_fifo_hrdata (fc_rx_fifo_hrdata),

        // AHB Master — RX Config path (internal, via config mux)
        .fc_rx_cfg_haddr   (fc_rx_cfg_haddr),
        .fc_rx_cfg_hwdata  (fc_rx_cfg_hwdata),
        .fc_rx_cfg_htrans  (fc_rx_cfg_htrans),
        .fc_rx_cfg_hsize   (fc_rx_cfg_hsize),
        .fc_rx_cfg_hwrite  (fc_rx_cfg_hwrite),
        .fc_rx_cfg_hready  (fc_rx_cfg_hready),
        .fc_rx_cfg_hresp   (fc_rx_cfg_hresp),
        .fc_rx_cfg_hrdata  (fc_rx_cfg_hrdata),

        // FC Node interface (to Wlink TideLink FC node)
        .tl_fc_a2l_valid   (tl_fc_a2l_valid),
        .tl_fc_a2l_data    (tl_fc_a2l_data),
        .tl_fc_a2l_ready   (tl_fc_a2l_ready),
        .tl_fc_l2a_valid   (tl_fc_l2a_valid),
        .tl_fc_l2a_data    (tl_fc_l2a_data),
        .tl_fc_l2a_accept  (tl_fc_l2a_accept)
    );

    // =========================================================================
    // 2b. TideLink PTP Module
    //     - TX path: AHB slave → wait for tx_router_idle → PTP FC node TX
    //     - RX path: PTP FC node RX → payload latch + PHC hw_capture
    //     - Registers: PTP_CTRL/PTP_RX_PAYLOAD/PTP_STATUS via APB pass-through
    // =========================================================================
    tidelink_ptp #(
        .SYS_DATA_W (SYS_DATA_W),
        .FC_DATA_W  (FC_DATA_W)
    ) u_ptp (
        .hclk              (hclk),
        .hresetn           (hresetn),

        // TX router idle (from chiplet controller)
        .tx_router_idle    (tx_router_idle),

        // PTP FC TX interface
        .ptp_fc_a2l_valid  (ptp_fc_a2l_valid),
        .ptp_fc_a2l_data   (ptp_fc_a2l_data),
        .ptp_fc_a2l_ready  (ptp_fc_a2l_ready),

        // PTP FC RX interface
        .ptp_fc_l2a_valid  (ptp_fc_l2a_valid),
        .ptp_fc_l2a_data   (ptp_fc_l2a_data),
        .ptp_fc_l2a_accept (ptp_fc_l2a_accept),

        // PHC hardware capture
        .phc_hw_capture    (phc_hw_capture),

        // AHB slave — PTP TX write port
        .ahb_ptp_hsel      (ahb_ptp_hsel),
        .ahb_ptp_haddr     (ahb_ptp_haddr),
        .ahb_ptp_htrans    (ahb_ptp_htrans),
        .ahb_ptp_hsize     (ahb_ptp_hsize),
        .ahb_ptp_hwrite    (ahb_ptp_hwrite),
        .ahb_ptp_hwdata    (ahb_ptp_hwdata),
        .ahb_ptp_hready    (ahb_ptp_hready),
        .ahb_ptp_hrdata    (ahb_ptp_hrdata),
        .ahb_ptp_hresp     (ahb_ptp_hresp),
        .ahb_ptp_hreadyout (ahb_ptp_hreadyout),

        // Register interface (from APB regs pass-through)
        .ptp_reg_write     (ptp_reg_write),
        .ptp_reg_addr      (ptp_reg_addr),
        .ptp_reg_wdata     (ptp_reg_wdata),
        .ptp_reg_rdata     (ptp_reg_rdata),

        // Interrupt
        .ptp_irq           (ptp_irq)
    );

    // =========================================================================
    // 3. XHB500 AHB-to-AXI Bridge (subordinate path: AHB → AXI → Wlink)
    //    Address translation applied to haddr before the bridge
    // =========================================================================
    xhb500_ahb_to_axi_bridge_chiplet_slv u_xhb_sub (
        .clk               (hclk),
        .resetn             (hresetn),
        .buf_write_error_irq(),
        .irq_en            (1'b0),

        .hsel              (ahb_sub_hsel),
        .hnonsec           (1'b0),
        .haddr             (translated_sub_haddr),
        .htrans            (ahb_sub_htrans),
        .hsize             (ahb_sub_hsize),
        .hwrite            (ahb_sub_hwrite),
        .hready            (ahb_sub_hready),
        .hprot             ({3'h0, ahb_sub_hprot}),
        .hburst            (ahb_sub_hburst),
        .hmastlock         (1'b0),
        .hwdata            (ahb_sub_hwdata),
        .hexcl             (1'b0),
        .hmaster           (12'd0),
        .hrdata            (ahb_sub_hrdata),
        .hreadyout         (ahb_sub_hreadyout),
        .hresp             (ahb_sub_hresp),
        .hexokay           (),
        .hqos              (4'h0),
        .hregion           (4'h0),
        .hnsaid            (4'h0),

        .awvalid           (s_axi_awvalid),
        .awaddr            (s_axi_awaddr[31:0]),
        .awburst           (s_axi_awburst),
        .awid              (s_axi_awid),
        .awlen             (s_axi_awlen),
        .awsize            (s_axi_awsize),
        .awlock            (s_axi_awlock),
        .awprot            (s_axi_awprot),
        .awready           (s_axi_awready),
        .awcache           (s_axi_awcache),
        .awqos             (s_axi_awqos),

        .arvalid           (s_axi_arvalid),
        .araddr            (s_axi_araddr[31:0]),
        .arburst           (s_axi_arburst),
        .arid              (s_axi_arid),
        .arlen             (s_axi_arlen),
        .arsize            (s_axi_arsize),
        .arlock            (s_axi_arlock),
        .arprot            (s_axi_arprot),
        .arready           (s_axi_arready),
        .arcache           (s_axi_arcache),
        .arqos             (s_axi_arqos),

        .wvalid            (s_axi_wvalid),
        .wlast             (s_axi_wlast),
        .wstrb             (s_axi_wstrb),
        .wdata             (s_axi_wdata),
        .wready            (s_axi_wready),

        .rvalid            (s_axi_rvalid),
        .rid               (s_axi_rid),
        .rlast             (s_axi_rlast),
        .rdata             (s_axi_rdata),
        .rresp             (s_axi_rresp),
        .rready            (s_axi_rready),

        .bvalid            (s_axi_bvalid),
        .bid               (s_axi_bid),
        .bresp             (s_axi_bresp),
        .bready            (s_axi_bready),

        .awakeup           (),
        .clk_qactive       (),
        .clk_qreqn         (1'b1),
        .clk_qacceptn      (),
        .clk_qdeny         (),
        .pwr_qactive       (),
        .pwr_qreqn         (1'b1),
        .pwr_qacceptn      (),
        .pwr_qdeny         ()
    );

    // Upper 4 bits of 36-bit AXI address not used
    assign s_axi_awaddr[35:32] = 4'h0;
    assign s_axi_araddr[35:32] = 4'h0;

    // =========================================================================
    // 4. XHB500 AXI-to-AHB Bridge (manager path: Wlink → AXI → AHB)
    // =========================================================================
    xhb500_axi_to_ahb_bridge_chiplet_mst u_xhb_mng (
        .clk               (hclk),
        .resetn             (hresetn),

        .clk_qactive       (),
        .clk_qreqn         (1'b1),
        .clk_qacceptn      (),
        .clk_qdeny         (),
        .pwr_qactive       (),
        .pwr_qreqn         (1'b1),
        .pwr_qacceptn      (),
        .pwr_qdeny         (),

        .awvalid           (m_axi_awvalid),
        .awready           (m_axi_awready),
        .awaddr            (m_axi_awaddr[31:0]),
        .awburst           (m_axi_awburst),
        .awid              (m_axi_awid),
        .awlen             (m_axi_awlen),
        .awsize            (m_axi_awsize),
        .awlock            (m_axi_awlock),
        .awprot            (m_axi_awprot),
        .awcache           (m_axi_awcache),

        .arvalid           (m_axi_arvalid),
        .arready           (m_axi_arready),
        .araddr            (m_axi_araddr[31:0]),
        .arburst           (m_axi_arburst),
        .arid              (m_axi_arid),
        .arlen             (m_axi_arlen),
        .arsize            (m_axi_arsize),
        .arlock            (m_axi_arlock),
        .arprot            (m_axi_arprot),
        .arcache           (m_axi_arcache),

        .wvalid            (m_axi_wvalid),
        .wready            (m_axi_wready),
        .wlast             (m_axi_wlast),
        .wstrb             (m_axi_wstrb),
        .wdata             (m_axi_wdata),

        .rvalid            (m_axi_rvalid),
        .rready            (m_axi_rready),
        .rid               (m_axi_rid),
        .rlast             (m_axi_rlast),
        .rdata             (m_axi_rdata),
        .rresp             (m_axi_rresp),

        .bvalid            (m_axi_bvalid),
        .bready            (m_axi_bready),
        .bid               (m_axi_bid),
        .bresp             (m_axi_bresp),

        .ardomain          (2'b00),
        .awdomain          (2'b00),
        .awakeup           (1'b1),
        .awnsaid           (4'h0),
        .arnsaid           (4'h0),
        .awqos             (m_axi_awqos),
        .arqos             (m_axi_arqos),
        .awregion          (4'h0),
        .arregion          (4'h0),

        .hnonsec           (),
        .haddr             (ahb_mng_haddr),
        .htrans            (ahb_mng_htrans),
        .hsize             (ahb_mng_hsize),
        .hwrite            (ahb_mng_hwrite),
        .hprot             (ahb_mng_hprot),
        .hburst            (ahb_mng_hburst),
        .hmastlock         (),
        .hwdata            (ahb_mng_hwdata),
        .hexcl             (),
        .hmaster           (),
        .hrdata            (ahb_mng_hrdata),
        .hready            (ahb_mng_hready),
        .hresp             (ahb_mng_hresp),

        .hexokay           (1'b0),
        .hwstrb            (),
        .hqos              (),
        .hregion           (),
        .hnsaid            ()
    );

    // =========================================================================
    // 5. Address Translator
    //    APB-configurable address remapping for the regular AHB bridge path
    // =========================================================================
    tidelink_addr_translator #(
        .BE (0)
    ) u_addr_translator (
        .CLK               (hclk),
        .RESETn            (hresetn),

        // AHB slave for address translator configuration
        .chp_adr_hsel      (ahb_adr_hsel),
        .chp_adr_haddr     (ahb_adr_haddr),
        .chp_adr_hburst    (ahb_adr_hburst),
        .chp_adr_hmastlock (1'b0),
        .chp_adr_hprot     (ahb_adr_hprot),
        .chp_adr_hsize     (ahb_adr_hsize),
        .chp_adr_htrans    (ahb_adr_htrans),
        .chp_adr_hwdata    (ahb_adr_hwdata),
        .chp_adr_hwrite    (ahb_adr_hwrite),
        .chp_adr_hready    (ahb_adr_hready),
        .chp_adr_hrdata    (ahb_adr_hrdata),
        .chp_adr_hresp     (ahb_adr_hresp),
        .chp_adr_hreadyout (ahb_adr_hreadyout),

        // Address translation: input from ahb_sub, output to XHB500
        .chp0_ahb_haddr_i  (ahb_sub_haddr),
        .chp0_ahb_haddr_o  (translated_sub_haddr),

        // Second translation port unused (tie off)
        .chp1_ahb_haddr_i  (32'h0),
        .chp1_ahb_haddr_o  ()
    );

    // =========================================================================
    // 6. Chiplet Controller (Wlink with TideLink FC node)
    //    Handles link layer, flow control, CRC/ECC, and SERDES PHY
    //    Generated module: Wlink (Chisel output)
    //    Note: Wlink uses active-high resets
    // =========================================================================
    Wlink u_chiplet_controller (
        .apb_clk                    (hclk),
        .app_clk                    (hclk),
        .user_hsclk                 (user_ref_clk),

        .apb_reset                  (~hresetn),
        .por_reset                  (~poresetn),
        .app_clk_reset              (~hresetn),

        .sb_reset_in                (1'b0),
        .sb_reset_out               (d2d_reset_o),
        .sb_wake                    (),

        // APB control interface (apbport_0)
        .apbport_0_psel             (apb_ctrl_psel),
        .apbport_0_paddr            (apb_ctrl_paddr),
        .apbport_0_penable          (apb_ctrl_penable),
        .apbport_0_pprot            (apb_ctrl_pprot),
        .apbport_0_pstrb            (apb_ctrl_pstrb),
        .apbport_0_pwrite           (apb_ctrl_pwrite),
        .apbport_0_pwdata           (apb_ctrl_pwdata),
        .apbport_0_prdata           (apb_ctrl_prdata),
        .apbport_0_pready           (apb_ctrl_pready),
        .apbport_0_pslverr          (apb_ctrl_pslverr),

        // AXI target (from XHB500 AHB→AXI bridge)
        .axi_tgt_0_aw_valid         (s_axi_awvalid),
        .axi_tgt_0_aw_ready         (s_axi_awready),
        .axi_tgt_0_aw_bits_id       (s_axi_awid),
        .axi_tgt_0_aw_bits_addr     (s_axi_awaddr),
        .axi_tgt_0_aw_bits_len      (s_axi_awlen),
        .axi_tgt_0_aw_bits_size     (s_axi_awsize),
        .axi_tgt_0_aw_bits_burst    (s_axi_awburst),
        .axi_tgt_0_aw_bits_lock     (s_axi_awlock),
        .axi_tgt_0_aw_bits_cache    (s_axi_awcache),
        .axi_tgt_0_aw_bits_prot     (s_axi_awprot),
        .axi_tgt_0_aw_bits_qos      (s_axi_awqos),

        .axi_tgt_0_w_valid          (s_axi_wvalid),
        .axi_tgt_0_w_ready          (s_axi_wready),
        .axi_tgt_0_w_bits_data      (s_axi_wdata),
        .axi_tgt_0_w_bits_strb      (s_axi_wstrb),
        .axi_tgt_0_w_bits_last      (s_axi_wlast),

        .axi_tgt_0_b_valid          (s_axi_bvalid),
        .axi_tgt_0_b_ready          (s_axi_bready),
        .axi_tgt_0_b_bits_id        (s_axi_bid),
        .axi_tgt_0_b_bits_resp      (s_axi_bresp),

        .axi_tgt_0_ar_valid         (s_axi_arvalid),
        .axi_tgt_0_ar_ready         (s_axi_arready),
        .axi_tgt_0_ar_bits_id       (s_axi_arid),
        .axi_tgt_0_ar_bits_addr     (s_axi_araddr),
        .axi_tgt_0_ar_bits_len      (s_axi_arlen),
        .axi_tgt_0_ar_bits_size     (s_axi_arsize),
        .axi_tgt_0_ar_bits_burst    (s_axi_arburst),
        .axi_tgt_0_ar_bits_lock     (s_axi_arlock),
        .axi_tgt_0_ar_bits_cache    (s_axi_arcache),
        .axi_tgt_0_ar_bits_prot     (s_axi_arprot),
        .axi_tgt_0_ar_bits_qos      (s_axi_arqos),

        .axi_tgt_0_r_valid          (s_axi_rvalid),
        .axi_tgt_0_r_ready          (s_axi_rready),
        .axi_tgt_0_r_bits_id        (s_axi_rid),
        .axi_tgt_0_r_bits_data      (s_axi_rdata),
        .axi_tgt_0_r_bits_resp      (s_axi_rresp),
        .axi_tgt_0_r_bits_last      (s_axi_rlast),

        // AXI initiator (to XHB500 AXI→AHB bridge)
        .axi_ini_0_aw_valid         (m_axi_awvalid),
        .axi_ini_0_aw_ready         (m_axi_awready),
        .axi_ini_0_aw_bits_id       (m_axi_awid),
        .axi_ini_0_aw_bits_addr     (m_axi_awaddr),
        .axi_ini_0_aw_bits_len      (m_axi_awlen),
        .axi_ini_0_aw_bits_size     (m_axi_awsize),
        .axi_ini_0_aw_bits_burst    (m_axi_awburst),
        .axi_ini_0_aw_bits_lock     (m_axi_awlock),
        .axi_ini_0_aw_bits_cache    (m_axi_awcache),
        .axi_ini_0_aw_bits_prot     (m_axi_awprot),
        .axi_ini_0_aw_bits_qos      (m_axi_awqos),

        .axi_ini_0_w_valid          (m_axi_wvalid),
        .axi_ini_0_w_ready          (m_axi_wready),
        .axi_ini_0_w_bits_data      (m_axi_wdata),
        .axi_ini_0_w_bits_strb      (m_axi_wstrb),
        .axi_ini_0_w_bits_last      (m_axi_wlast),

        .axi_ini_0_b_valid          (m_axi_bvalid),
        .axi_ini_0_b_ready          (m_axi_bready),
        .axi_ini_0_b_bits_id        (m_axi_bid),
        .axi_ini_0_b_bits_resp      (m_axi_bresp),

        .axi_ini_0_ar_valid         (m_axi_arvalid),
        .axi_ini_0_ar_ready         (m_axi_arready),
        .axi_ini_0_ar_bits_id       (m_axi_arid),
        .axi_ini_0_ar_bits_addr     (m_axi_araddr),
        .axi_ini_0_ar_bits_len      (m_axi_arlen),
        .axi_ini_0_ar_bits_size     (m_axi_arsize),
        .axi_ini_0_ar_bits_burst    (m_axi_arburst),
        .axi_ini_0_ar_bits_lock     (m_axi_arlock),
        .axi_ini_0_ar_bits_cache    (m_axi_arcache),
        .axi_ini_0_ar_bits_prot     (m_axi_arprot),
        .axi_ini_0_ar_bits_qos      (m_axi_arqos),

        .axi_ini_0_r_valid          (m_axi_rvalid),
        .axi_ini_0_r_ready          (m_axi_rready),
        .axi_ini_0_r_bits_id        (m_axi_rid),
        .axi_ini_0_r_bits_data      (m_axi_rdata),
        .axi_ini_0_r_bits_resp      (m_axi_rresp),
        .axi_ini_0_r_bits_last      (m_axi_rlast),

        // General bus (interrupt forwarding)
        .generalbus_in              (gb_in),
        .generalbus_out             (gb_out),

        // TideLink FC node (packed bus, 50-bit = 48-bit data + 2 control)
        // tidelink_in  = {a2l_valid, a2l_data[47:0], l2a_accept}
        // tidelink_out = {a2l_ready, l2a_valid, l2a_data[47:0]}
        .tidelink_in                ({tl_fc_a2l_valid, tl_fc_a2l_data, tl_fc_l2a_accept}),
        .tidelink_out               ({tl_fc_a2l_ready, tl_fc_l2a_valid, tl_fc_l2a_data}),

        // PTP FC node (packed bus, same 50-bit convention)
        .ptp_in                     ({ptp_fc_a2l_valid, ptp_fc_a2l_data, ptp_fc_l2a_accept}),
        .ptp_out                    ({ptp_fc_a2l_ready, ptp_fc_l2a_valid, ptp_fc_l2a_data}),

        // TX link idle (for PTP jitter-free timestamp capture)
        .tx_link_idle               (tx_router_idle),

        // Scan / DFT
        .scan_mode                  (scan_mode),
        .scan_asyncrst_ctrl         (scan_asyncrst_ctrl),
        .scan_clk                   (scan_clk),
        .scan_shift                 (scan_shift),
        .scan_in                    (scan_in),
        .scan_out                   (scan_out),

        // Interrupts
        .interrupt                  (wlink_irq),

        // PHY pads (8-lane GPIO)
        .pad_clk_tx                 (pad_clk_tx),
        .pad_tx_0                   (pad_tx[0]),
        .pad_tx_1                   (pad_tx[1]),
        .pad_tx_2                   (pad_tx[2]),
        .pad_tx_3                   (pad_tx[3]),
        .pad_tx_4                   (pad_tx[4]),
        .pad_tx_5                   (pad_tx[5]),
        .pad_tx_6                   (pad_tx[6]),
        .pad_tx_7                   (pad_tx[7]),
        .pad_clk_rx                 (pad_clk_rx),
        .pad_rx_0                   (pad_rx[0]),
        .pad_rx_1                   (pad_rx[1]),
        .pad_rx_2                   (pad_rx[2]),
        .pad_rx_3                   (pad_rx[3]),
        .pad_rx_4                   (pad_rx[4]),
        .pad_rx_5                   (pad_rx[5]),
        .pad_rx_6                   (pad_rx[6]),
        .pad_rx_7                   (pad_rx[7])
    );

endmodule
