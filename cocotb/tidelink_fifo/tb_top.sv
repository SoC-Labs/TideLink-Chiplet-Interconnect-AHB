// Cocotb wrapper for tidelink_fifo_mem
// Exposes AHB interface signals for cocotb to drive
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
    input  logic                  flush
);

    // In a single-slave system, HREADY = HREADYOUT
    wire hreadyout;
    assign hready = hreadyout;

    tidelink_fifo_mem #(
        .SYS_DATA_W(SYS_DATA_W),
        .RAM_ADDR_W(RAM_ADDR_W),
        .RAM_DATA_W(RAM_DATA_W)
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
        // RX-FIFO TWIN 2: this bench injects packets via the AHB write path, so
        // it models software having ARMED the inject path (CTRL[3]=1). The real
        // register is POR-disarmed; here it is hardwired on for the whole suite.
        .swi_ahb_inject_arm   (1'b1),
        // FC direct write port (tied off — tests use AHB)
        .fc_wr_valid          (1'b0),
        .fc_wr_write          (1'b0),
        .fc_wr_addr           ({RAM_ADDR_W{1'b0}}),
        .fc_wr_wdata          ({SYS_DATA_W{1'b0}}),
        .fc_wr_ready          ()
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
