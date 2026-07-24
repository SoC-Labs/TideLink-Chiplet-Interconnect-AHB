// =============================================================================
// tb_top.sv — unit bench for tidelink_tx_gen driving the REAL tidelink_fc_adapter
//
// The generator is wired to the adapter exactly as tidelink_top wires it (same
// 2:1 mux, same hready source, same external-collide rule), so these tests
// exercise the genuine TX path: the held-NONSEQ transfer lock, the 1-entry
// skid, the honest-back-pressure completion rule and the TX_STALL_TIMEOUT
// backstop. A bench that stubbed the adapter would prove nothing about the
// numbers this generator exists to produce.
//
// The peer credit counter is a TB-driven input here (pair_credit_count); the
// real 3-way combine lives in tidelink_apb_regs and is covered by the pair-level
// suites. What this bench owns is: inert-when-disarmed, saturation, and the
// hardware credit gate.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.  David Mapstone (d.a.mapstone@soton.ac.uk)
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================
`timescale 1ns/1ps

module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter APB_ADDR_W = 12,
    parameter FC_DATA_W  = 48
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // ── Region-E register port (cocotb drives) ───────────────────────────
    input  logic                    reg_sel,
    input  logic              [2:0] reg_addr,
    input  logic                    reg_write,
    input  logic [SYS_DATA_W-1:0]  reg_wdata,
    output logic [SYS_DATA_W-1:0]  reg_rdata,

    // ── Peer credit (cocotb drives) ──────────────────────────────────────
    input  logic [SYS_DATA_W-1:0]  pair_credit_count,
    input  logic                    pair_credit_en,
    output logic                    credit_consume_vld,
    output logic [SYS_DATA_W-1:0]  credit_consume_val,

    // ── External AHB master on the TX aperture (cocotb drives) ───────────
    input  logic                    ext_hsel,
    input  logic [RAM_ADDR_W-1:0]  ext_haddr,
    input  logic              [1:0] ext_htrans,
    input  logic              [2:0] ext_hsize,
    input  logic                    ext_hwrite,
    input  logic [SYS_DATA_W-1:0]  ext_hwdata,
    input  logic                    ext_hready,
    output logic                    ext_hreadyout,
    output logic                    ext_hresp,

    // ── FC node side (cocotb models the link) ────────────────────────────
    output logic                    tl_fc_a2l_valid,
    output logic  [FC_DATA_W-1:0]  tl_fc_a2l_data,
    input  logic                    tl_fc_a2l_ready,

    // ── Observability ────────────────────────────────────────────────────
    output logic                    gen_owns,
    output logic                    fc_tx_hreadyout
);

    // ---- generator -> adapter TX wires -------------------------------------
    logic [RAM_ADDR_W-1:0]  gen_haddr;
    logic             [1:0] gen_htrans;
    logic             [2:0] gen_hsize;
    logic                   gen_hwrite;
    logic [SYS_DATA_W-1:0] gen_hwdata;
    logic                   fc_tx_hresp;

    // CREDIT_GATE_DIS is normally 0 (gate ON). The mandatory negative control
    // (c3) builds with +define+TXGEN_FORCE_CREDIT_GATE_DIS to force it 1 and
    // prove the gate is load-bearing: without it the generator sends into ZERO
    // credit (the complement of test_c1_zero_credit_never_starts). SIM-ONLY.
    tidelink_tx_gen #(
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
`ifdef TXGEN_FORCE_CREDIT_GATE_DIS
        .CREDIT_GATE_DIS (1'b1)
`else
        .CREDIT_GATE_DIS (1'b0)
`endif
    ) u_gen (
        .hclk               (hclk),
        .hresetn            (hresetn),
        .reg_sel            (reg_sel),
        .reg_addr           (reg_addr),
        .reg_write          (reg_write),
        .reg_wdata          (reg_wdata),
        .reg_rdata          (reg_rdata),
        .pair_credit_count  (pair_credit_count),
        .pair_credit_en     (pair_credit_en),
        .credit_consume_vld (credit_consume_vld),
        .credit_consume_val (credit_consume_val),
        .gen_owns           (gen_owns),
        .gen_haddr          (gen_haddr),
        .gen_htrans         (gen_htrans),
        .gen_hsize          (gen_hsize),
        .gen_hwrite         (gen_hwrite),
        .gen_hwdata         (gen_hwdata),
        .fc_hreadyout       (fc_tx_hreadyout),
        .fc_hresp           (fc_tx_hresp),
        .ext_htrans         (ext_htrans),
        .txgen_active       ()
    );

    // Same mux + hready rule as tidelink_top.
    assign ext_hreadyout = gen_owns ? 1'b0 : fc_tx_hreadyout;
    assign ext_hresp     = fc_tx_hresp;

    tidelink_fc_adapter #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .APB_ADDR_W (APB_ADDR_W),
        .FC_DATA_W  (FC_DATA_W),
        // 2^8 cycles so the ERROR backstop is reachable in sim (HW = 2^16).
        .TX_STALL_TIMEOUT_LOG2 (8)
    ) u_adapter (
        .hclk              (hclk),
        .hresetn           (hresetn),

        .ahb_tx_hsel       (gen_owns ? 1'b1            : ext_hsel),
        .ahb_tx_haddr      (gen_owns ? gen_haddr       : ext_haddr),
        .ahb_tx_htrans     (gen_owns ? gen_htrans      : ext_htrans),
        .ahb_tx_hsize      (gen_owns ? gen_hsize       : ext_hsize),
        .ahb_tx_hwrite     (gen_owns ? gen_hwrite      : ext_hwrite),
        .ahb_tx_hwdata     (gen_owns ? gen_hwdata      : ext_hwdata),
        .ahb_tx_hready     (gen_owns ? fc_tx_hreadyout : ext_hready),
        .ahb_tx_hrdata     (),
        .ahb_tx_hresp      (fc_tx_hresp),
        .ahb_tx_hreadyout  (fc_tx_hreadyout),

        // Returner interception — idle for this bench.
        .rtn_haddr         ('0),
        .rtn_hwdata        ('0),
        .rtn_htrans        (2'b00),
        .rtn_hsize         (3'b010),
        .rtn_hwrite        (1'b0),
        .rtn_hready        (),
        .rtn_hresp         (),
        .rtn_hrdata        (),

        .fc_rx_fifo_valid  (),
        .fc_rx_fifo_write  (),
        .fc_rx_fifo_addr   (),
        .fc_rx_fifo_wdata  (),
        .fc_rx_fifo_ready  (1'b1),

        .fc_rx_cfg_paddr   (),
        .fc_rx_cfg_pwdata  (),
        .fc_rx_cfg_psel    (),
        .fc_rx_cfg_penable (),
        .fc_rx_cfg_pwrite  (),
        .fc_rx_cfg_prdata  ('0),
        .fc_rx_cfg_pready  (1'b1),

        .servo_fc_valid    (1'b0),
        .servo_fc_data     ({FC_DATA_W{1'b0}}),
        .servo_fc_ready    (),

        .tc_axis_tx_tvalid (1'b0),
        .tc_axis_tx_tdata  ({FC_DATA_W{1'b0}}),
        .tc_axis_tx_tready (),
        .tc_axis_rx_tvalid (),
        .tc_axis_rx_tdata  (),
        .tc_axis_rx_tready (1'b1),

        .tc_qos_priority   (2'b00),

        .puf_addr          (),
        .puf_req           (),
        .puf_rdata         ('0),
        .puf_ack           (1'b0),

        .tl_fc_a2l_valid   (tl_fc_a2l_valid),
        .tl_fc_a2l_data    (tl_fc_a2l_data),
        .tl_fc_a2l_ready   (tl_fc_a2l_ready),

        .tl_fc_l2a_valid   (1'b0),
        .tl_fc_l2a_data    ({FC_DATA_W{1'b0}}),
        .tl_fc_l2a_accept  ()
    );

endmodule
