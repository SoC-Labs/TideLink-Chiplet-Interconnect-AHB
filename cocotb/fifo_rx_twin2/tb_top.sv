// Cocotb wrapper for tidelink_fifo_mem — RX-FIFO TWIN 2 disposition bench.
//
// Unlike the primary cocotb/tidelink_fifo bench (which ties the FC direct-write
// port OFF and injects packets via the AHB slave), THIS bench EXPOSES the FC
// direct-write port — the real silicon committer — so a genuine received packet
// can be delivered independently of the AHB write path. That is exactly what the
// TWIN 2 defect needs: the corruption is an illegitimate AHB write walking the
// FC-shared write_ptr, so the reproduction must drive BOTH ports.
//
// ENABLE_AHB_WRITE(0) models the SoC RX-FIFO instantiation (the TWIN 2 fix,
// applied to the tree 2026-07-19 and tied 0 at the RX instance in
// src/rtl/fifo/tidelink_fifo.sv).
//   * FIFO_SRC=tree — the REAL shared src/rtl RTL, which now carries the guard:
//     the param is honoured -> AHB writes are a NO-OP -> the FC-committed packet
//     is never corrupted (test PASSes). This is the config the gate runs.
//   * FIFO_SRC=unfixed — frozen *.UNFIXED.sv copies of the PRE-FIX RTL, where the
//     param does not exist -> VCS warns and IGNORES it -> AHB writes stay enabled
//     -> the bug reproduces (test FAILs). The negative control; its FAILURE is
//     what proves this test has teeth.
module tb_top #(
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32
)(
    input  logic                  hclk,
    input  logic                  hresetn,
    input  logic                  hsel,
    input  logic            [1:0] htrans,
    input  logic            [2:0] hsize,
    input  logic                  hwrite,
    input  logic [RAM_ADDR_W-1:0] haddr,
    input  logic [SYS_DATA_W-1:0] hwdata,
    output logic                  hready,
    output logic                  hresp,
    output logic [SYS_DATA_W-1:0] hrdata,
    output logic                  read_complete,
    output logic [RAM_ADDR_W-1:0] packet_word_length_out,
    output logic                  packet_committed_irq,
    output logic                  overrun,
    output logic                  underrun,
    input  logic                  flush,
    // FC direct-write port (the real silicon committer) — driven by the test
    input  logic                  fc_wr_valid,
    input  logic                  fc_wr_write,
    input  logic [RAM_ADDR_W-1:0] fc_wr_addr,
    input  logic [SYS_DATA_W-1:0] fc_wr_wdata,
    output logic                  fc_wr_ready
);

    // In a single-slave system, HREADY = HREADYOUT
    wire hreadyout;
    assign hready = hreadyout;

    tidelink_fifo_mem #(
        .SYS_DATA_W       (SYS_DATA_W),
        .RAM_ADDR_W       (RAM_ADDR_W),
        .RAM_DATA_W       (RAM_DATA_W),
        // Model the SoC RX-FIFO tie-off (the TWIN 2 fix). Ignored (warning) on
        // the unfixed RTL, which is what makes this an A/B reproduction.
        .ENABLE_AHB_WRITE (0)
    ) u_dut (
        .hclk      (hclk),
        .hresetn   (hresetn),
        .hsel      (hsel),
        .hready    (hready),
        .htrans    (htrans),
        .hsize     (hsize),
        .hwrite    (hwrite),
        .haddr     (haddr),
        .hwdata    (hwdata),
        .hreadyout     (hreadyout),
        .hresp         (hresp),
        .hrdata        (hrdata),
        .read_complete        (read_complete),
        .current_credit_count (),
        .packet_word_length_out(packet_word_length_out),
        .packet_committed_irq (packet_committed_irq),
        .overrun              (overrun),
        .underrun             (underrun),
        .flush                (flush),
        // FC direct-write port — EXPOSED (the genuine-packet committer)
        .fc_wr_valid          (fc_wr_valid),
        .fc_wr_write          (fc_wr_write),
        .fc_wr_addr           (fc_wr_addr),
        .fc_wr_wdata          (fc_wr_wdata),
        .fc_wr_ready          (fc_wr_ready),
        // PUF SRAM read port — tied off
        .puf_addr             ({(RAM_ADDR_W-2){1'b0}}),
        .puf_req              (1'b0),
        .puf_rdata            (),
        .puf_ack              ()
    );

    // Waveform dump
    initial begin
`ifndef TB_TOP_NO_DUMP
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
`endif
    end

endmodule
