// PENDING-DECISION #1 — RX-FIFO TWIN 2 red/green testbench.
//
// Exposes the AHB slave AND the FC direct-write port of tidelink_fifo_mem so
// the test can (a) drive a stray AHB write pair to offset 0/4 (the TWIN-2
// corruptor) and (b) drive a genuine FC-direct packet, then observe the
// FC-shared write_ptr / credit_count hierarchically (u_dut.u_fifo_ctrl.*).
//
// ENABLE_AHB_WRITE is selected at compile time:
//   +define+TWIN2_ENABLE_AHB_WRITE=1  → RED  (today's behaviour, corruptible)
//   +define+TWIN2_ENABLE_AHB_WRITE=0  → GREEN (ASIC posture, FC-write-only)
`ifndef TWIN2_ENABLE_AHB_WRITE
  `define TWIN2_ENABLE_AHB_WRITE 1
`endif

module tb_top #(
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32
)(
    input  logic                  hclk,
    input  logic                  hresetn,
    // AHB slave
    input  logic                  hsel,
    input  logic            [1:0] htrans,
    input  logic            [2:0] hsize,
    input  logic                  hwrite,
    input  logic [RAM_ADDR_W-1:0] haddr,
    input  logic [SYS_DATA_W-1:0] hwdata,
    output logic                  hready,
    output logic                  hresp,
    output logic [SYS_DATA_W-1:0] hrdata,
    // FC direct write
    input  logic                  fc_wr_valid,
    input  logic                  fc_wr_write,
    input  logic [RAM_ADDR_W-1:0] fc_wr_addr,
    input  logic [SYS_DATA_W-1:0] fc_wr_wdata,
    // sidebands
    output logic                  read_complete,
    output logic [RAM_ADDR_W-1:0] packet_word_length_out,
    output logic                  packet_committed_irq,
    output logic                  overrun,
    output logic                  underrun,
    input  logic                  flush,
    // RX-FIFO TWIN 2 runtime arm (CTRL[3] equivalent). POR-disarmed in the real
    // register; here the TEST drives it: 0 = disarmed (stray writes are no-ops),
    // 1 = armed (the supported AHB-inject path is live).
    input  logic                  swi_ahb_inject_arm
);

    wire hreadyout;
    assign hready = hreadyout;

    tidelink_fifo_mem #(
        .SYS_DATA_W(SYS_DATA_W),
        .RAM_ADDR_W(RAM_ADDR_W),
        .RAM_DATA_W(RAM_DATA_W),
        .ENABLE_AHB_WRITE(`TWIN2_ENABLE_AHB_WRITE)
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
        .hreadyout (hreadyout),
        .hresp     (hresp),
        .hrdata    (hrdata),
        .read_complete        (read_complete),
        .current_credit_count (),
        .packet_word_length_out(packet_word_length_out),
        .packet_committed_irq (packet_committed_irq),
        .overrun              (overrun),
        .underrun             (underrun),
        .flush                (flush),
        .swi_ahb_inject_arm   (swi_ahb_inject_arm),
        // FC direct write port (driven by the test)
        .fc_wr_valid          (fc_wr_valid),
        .fc_wr_write          (fc_wr_write),
        .fc_wr_addr           (fc_wr_addr),
        .fc_wr_wdata          (fc_wr_wdata),
        .fc_wr_ready          (),
        // PUF unused
        .puf_addr             ({(RAM_ADDR_W-2){1'b0}}),
        .puf_req              (1'b0),
        .puf_rdata            (),
        .puf_ack              ()
    );

    initial begin
`ifndef TB_TOP_NO_DUMP
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
`endif
    end

endmodule
