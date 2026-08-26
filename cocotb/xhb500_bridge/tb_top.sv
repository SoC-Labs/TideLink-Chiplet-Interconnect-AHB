//-----------------------------------------------------------------------------
// tb_top.sv -- standalone unit bench for the XHB500 bridge PAIR.
//
// WHY THIS BENCH EXISTS (2026-08-26, coverage-driven)
//   The first merged coverage database over the whole simulation corpus put
//   `xhb500_axi_to_ahb_bridge_chiplet_mst_core_xin` at FSM 0.00% -- and a
//   per-database re-check (112 databases, one urg run each, because the merged
//   report silently drops mismatched designs) confirmed 0.00% in ALL 42
//   databases that contain the module.  The INBOUND half of the cross-die path
//   -- the direction a far die uses to reach our memory -- has never
//   transacted in any simulation in this repository.  Same for
//   `..._core_h_xout` (the AXI response mux) at 0.00%.
//
//   The pair-level testbench cannot reach it: it does not model a peer-side
//   XHB500 target memory.  The only way to exercise the inbound bridge is to
//   instantiate it directly, which is what this file does.
//
// TWO DUTs, NOT CHAINED, DELIBERATELY
//   u_mst is the AXI->AHB bridge (inbound: AXI in, AHB out).
//   u_slv is the AHB->AXI bridge (outbound: AHB in, AXI out).
//   They are NOT wired to each other.  Chaining them would be prettier but
//   would make it impossible to inject an AHB ERROR at u_mst's AHB port and an
//   AXI SLVERR at u_slv's AXI port independently, which is the entire point of
//   the error-path half of this bench.  Every port of both DUTs is brought out
//   flat so cocotb owns both sides of both bridges.
//
// SOURCE SET
//   flists/xhb500_bridge_unit.flist -- the same files, in the same order, as
//   lines 87-121 of the shipping tapeout flist.  This bench compiles what
//   tapes out.
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_top (
    input  logic         clk,
    input  logic         resetn,

    // =====================================================================
    // u_mst : xhb500_axi_to_ahb_bridge_chiplet_mst  (INBOUND, AXI -> AHB)
    //   AXI subordinate port  <- driven by cocotb AxiMaster
    //   AHB manager port      -> answered by cocotb AhbSlave
    // =====================================================================
    input  logic         m_awvalid,
    output logic         m_awready,
    input  logic [31:0]  m_awaddr,
    input  logic [1:0]   m_awburst,
    input  logic [11:0]  m_awid,
    input  logic [7:0]   m_awlen,
    input  logic [2:0]   m_awsize,
    input  logic         m_awlock,
    input  logic [2:0]   m_awprot,
    input  logic [3:0]   m_awcache,

    input  logic         m_arvalid,
    output logic         m_arready,
    input  logic [31:0]  m_araddr,
    input  logic [1:0]   m_arburst,
    input  logic [11:0]  m_arid,
    input  logic [7:0]   m_arlen,
    input  logic [2:0]   m_arsize,
    input  logic         m_arlock,
    input  logic [2:0]   m_arprot,
    input  logic [3:0]   m_arcache,

    input  logic         m_wvalid,
    output logic         m_wready,
    input  logic         m_wlast,
    input  logic [3:0]   m_wstrb,
    input  logic [31:0]  m_wdata,

    output logic         m_rvalid,
    input  logic         m_rready,
    output logic [11:0]  m_rid,
    output logic         m_rlast,
    output logic [31:0]  m_rdata,
    output logic [1:0]   m_rresp,

    output logic         m_bvalid,
    input  logic         m_bready,
    output logic [11:0]  m_bid,
    output logic [1:0]   m_bresp,

    // u_mst AHB manager port
    output logic         m_hnonsec,
    output logic [31:0]  m_haddr,
    output logic [1:0]   m_htrans,
    output logic [2:0]   m_hsize,
    output logic         m_hwrite,
    output logic [6:0]   m_hprot,
    output logic [2:0]   m_hburst,
    output logic         m_hmastlock,
    output logic [31:0]  m_hwdata,
    output logic         m_hexcl,
    output logic [11:0]  m_hmaster,
    output logic [3:0]   m_hwstrb,
    input  logic [31:0]  m_hrdata,
    input  logic         m_hready,
    input  logic         m_hresp,
    input  logic         m_hexokay,

    // =====================================================================
    // u_slv : xhb500_ahb_to_axi_bridge_chiplet_slv  (OUTBOUND, AHB -> AXI)
    //   AHB subordinate port <- driven by cocotb AhbMaster
    //   AXI manager port     -> answered by cocotb AxiSlave
    // =====================================================================
    input  logic         s_hsel,
    input  logic         s_hnonsec,
    input  logic [31:0]  s_haddr,
    input  logic [1:0]   s_htrans,
    input  logic [2:0]   s_hsize,
    input  logic         s_hwrite,
    input  logic [6:0]   s_hprot,
    input  logic [2:0]   s_hburst,
    input  logic         s_hmastlock,
    input  logic [31:0]  s_hwdata,
    input  logic         s_hexcl,
    input  logic [11:0]  s_hmaster,
    output logic [31:0]  s_hrdata,
    output logic         s_hreadyout,
    output logic         s_hresp,
    output logic         s_hexokay,

    output logic         s_awvalid,
    output logic [31:0]  s_awaddr,
    output logic [1:0]   s_awburst,
    output logic [11:0]  s_awid,
    output logic [7:0]   s_awlen,
    output logic [2:0]   s_awsize,
    output logic         s_awlock,
    input  logic         s_awready,

    output logic         s_arvalid,
    output logic [31:0]  s_araddr,
    output logic [1:0]   s_arburst,
    output logic [11:0]  s_arid,
    output logic [7:0]   s_arlen,
    output logic [2:0]   s_arsize,
    output logic         s_arlock,
    input  logic         s_arready,

    output logic         s_wvalid,
    output logic         s_wlast,
    output logic [3:0]   s_wstrb,
    output logic [31:0]  s_wdata,
    input  logic         s_wready,

    input  logic         s_rvalid,
    input  logic [11:0]  s_rid,
    input  logic         s_rlast,
    input  logic [31:0]  s_rdata,
    input  logic [1:0]   s_rresp,
    output logic         s_rready,

    input  logic         s_bvalid,
    input  logic [11:0]  s_bid,
    input  logic [1:0]   s_bresp,
    output logic         s_bready,

    output logic         s_buf_write_error_irq
);

    // -------------------------------------------------------------------
    // INBOUND bridge: AXI subordinate -> AHB manager.
    //
    // The Q-channel tie-offs (clk_qreqn/pwr_qreqn = 1, awakeup = 1) are copied
    // from the SHIPPING instantiation at src/rtl/tidelink_top.sv:3241 so the
    // LPI enable behaves as it does in silicon.  Everything else is a port.
    // -------------------------------------------------------------------
    xhb500_axi_to_ahb_bridge_chiplet_mst u_mst (
        .clk          (clk),
        .resetn       (resetn),

        .clk_qactive  (),
        .clk_qreqn    (1'b1),
        .clk_qacceptn (),
        .clk_qdeny    (),
        .pwr_qactive  (),
        .pwr_qreqn    (1'b1),
        .pwr_qacceptn (),
        .pwr_qdeny    (),

        .awvalid      (m_awvalid),
        .awready      (m_awready),
        .awaddr       (m_awaddr),
        .awburst      (m_awburst),
        .awid         (m_awid),
        .awlen        (m_awlen),
        .awsize       (m_awsize),
        .awlock       (m_awlock),
        .awprot       (m_awprot),
        .awcache      (m_awcache),

        .arvalid      (m_arvalid),
        .arready      (m_arready),
        .araddr       (m_araddr),
        .arburst      (m_arburst),
        .arid         (m_arid),
        .arlen        (m_arlen),
        .arsize       (m_arsize),
        .arlock       (m_arlock),
        .arprot       (m_arprot),
        .arcache      (m_arcache),

        .wvalid       (m_wvalid),
        .wready       (m_wready),
        .wlast        (m_wlast),
        .wstrb        (m_wstrb),
        .wdata        (m_wdata),

        .rvalid       (m_rvalid),
        .rready       (m_rready),
        .rid          (m_rid),
        .rlast        (m_rlast),
        .rdata        (m_rdata),
        .rresp        (m_rresp),

        .bvalid       (m_bvalid),
        .bready       (m_bready),
        .bid          (m_bid),
        .bresp        (m_bresp),

        .ardomain     (2'b00),
        .awdomain     (2'b00),
        .awakeup      (1'b1),
        .awnsaid      (4'h0),
        .arnsaid      (4'h0),
        .awqos        (4'h0),
        .arqos        (4'h0),
        .awregion     (4'h0),
        .arregion     (4'h0),

        .hnonsec      (m_hnonsec),
        .haddr        (m_haddr),
        .htrans       (m_htrans),
        .hsize        (m_hsize),
        .hwrite       (m_hwrite),
        .hprot        (m_hprot),
        .hburst       (m_hburst),
        .hmastlock    (m_hmastlock),
        .hwdata       (m_hwdata),
        .hexcl        (m_hexcl),
        .hmaster      (m_hmaster),

        .hrdata       (m_hrdata),
        .hready       (m_hready),
        .hresp        (m_hresp),
        .hexokay      (m_hexokay),

        .hwstrb       (m_hwstrb),
        .hqos         (),
        .hregion      (),
        .hnsaid       ()
    );

    // Single-subordinate AHB: the bus HREADY the subordinate sees is its own
    // HREADYOUT.  Driving this from cocotb instead would insert a spurious
    // one-cycle delay through the Python layer and desynchronise the address
    // and data phases.  Loop-free: hreadyout in every arm of the RESP FSM is a
    // function of state / address_readyout / beat_done / axi_err, never of
    // hready.  src/rtl/tidelink_top.sv:2204 closes the same loop in silicon.
    wire s_hready_i = s_hreadyout;

    // -------------------------------------------------------------------
    // OUTBOUND bridge: AHB subordinate -> AXI manager.
    //
    // NOTE the deliberate difference from the shipping instantiation at
    // src/rtl/tidelink_top.sv:3154, which ties .hmastlock(1'b0) and
    // .hexcl(1'b0).  Here both are PORTS.  test_slv_lock_error_* exercise the
    // RESP_FSM_LOCK_ERROR arm that those tie-offs make unreachable in silicon,
    // and test_shipping_ties_* assert the tie-offs themselves.
    // -------------------------------------------------------------------
    xhb500_ahb_to_axi_bridge_chiplet_slv u_slv (
        .clk                  (clk),
        .resetn               (resetn),

        .buf_write_error_irq  (s_buf_write_error_irq),
        .irq_en               (1'b1),

        .hsel                 (s_hsel),
        .hnonsec              (s_hnonsec),
        .haddr                (s_haddr),
        .htrans               (s_htrans),
        .hsize                (s_hsize),
        .hwrite               (s_hwrite),
        .hready               (s_hready_i),
        .hprot                (s_hprot),
        .hburst               (s_hburst),
        .hmastlock            (s_hmastlock),
        .hwdata               (s_hwdata),
        .hexcl                (s_hexcl),
        .hmaster              (s_hmaster),
        .hrdata               (s_hrdata),
        .hreadyout            (s_hreadyout),
        .hresp                (s_hresp),
        .hexokay              (s_hexokay),

        .hqos                 (4'h0),
        .hregion              (4'h0),
        .hnsaid               (4'h0),

        .awvalid              (s_awvalid),
        .awaddr               (s_awaddr),
        .awdomain             (),
        .awburst              (s_awburst),
        .awid                 (s_awid),
        .awlen                (s_awlen),
        .awsize               (s_awsize),
        .awlock               (s_awlock),
        .awprot               (),
        .awready              (s_awready),
        .awcache              (),
        .awregion             (),
        .awnsaid              (),
        .awqos                (),

        .arvalid              (s_arvalid),
        .araddr               (s_araddr),
        .ardomain             (),
        .arburst              (s_arburst),
        .arid                 (s_arid),
        .arlen                (s_arlen),
        .arsize               (s_arsize),
        .arlock               (s_arlock),
        .arprot               (),
        .arready              (s_arready),
        .arcache              (),
        .arregion             (),
        .arnsaid              (),
        .arqos                (),

        .wvalid               (s_wvalid),
        .wlast                (s_wlast),
        .wstrb                (s_wstrb),
        .wdata                (s_wdata),
        .wready               (s_wready),

        .rvalid               (s_rvalid),
        .rid                  (s_rid),
        .rlast                (s_rlast),
        .rdata                (s_rdata),
        .rresp                (s_rresp),
        .rready               (s_rready),

        .bvalid               (s_bvalid),
        .bid                  (s_bid),
        .bresp                (s_bresp),
        .bready               (s_bready),

        .awakeup              (),

        .clk_qactive          (),
        .clk_qreqn            (1'b1),
        .clk_qacceptn         (),
        .clk_qdeny            (),

        .pwr_qactive          (),
        .pwr_qreqn            (1'b1),
        .pwr_qacceptn         (),
        .pwr_qdeny            ()
    );

`ifndef TB_TOP_NO_DUMP
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end
`endif

endmodule
