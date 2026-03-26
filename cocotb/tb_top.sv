// Cocotb wrapper: instantiates DUT + SRAM model, exposes AXI-Stream ports
module tb_top #(
    parameter RAM_ADDR_W = 14,
    parameter WORD_LEN_W = 8
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // AXI Stream Control In (padded to 24 bits for byte-aligned cocotbext-axi)
    input  logic           [23:0] ctrl_tdata,
    input  logic                  ctrl_tvalid,
    output logic                  ctrl_tready,

    // AXI Stream Data In
    input  logic           [31:0] din_tdata,
    input  logic                  din_tvalid,
    input  logic                  din_tlast,
    output logic                  din_tready,

    // AXI Stream Data Out
    output logic           [31:0] dout_tdata,
    output logic                  dout_tvalid,
    output logic                  dout_tlast,
    input  logic                  dout_tready
);

    localparam SRAM_AW = RAM_ADDR_W - 2;

    // SRAM Interface (internal)
    logic [RAM_ADDR_W-1:0] sramaddr;
    logic           [31:0] sramwdata;
    logic            [3:0] sramwen;
    logic                  sramcs;
    logic           [31:0] sramrdata;

    tidelink_sram_manager #(
        .RAM_ADDR_W(RAM_ADDR_W),
        .WORD_LEN_W(WORD_LEN_W)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .ctrl_tdata (ctrl_tdata[22:0]),
        .ctrl_tvalid(ctrl_tvalid),
        .ctrl_tready(ctrl_tready),
        .din_tdata  (din_tdata),
        .din_tvalid (din_tvalid),
        .din_tlast  (din_tlast),
        .din_tready (din_tready),
        .dout_tdata (dout_tdata),
        .dout_tvalid(dout_tvalid),
        .dout_tlast (dout_tlast),
        .dout_tready(dout_tready),
        .sramaddr   (sramaddr),
        .sramwdata  (sramwdata),
        .sramwen    (sramwen),
        .sramcs     (sramcs),
        .sramrdata  (sramrdata)
    );

    sram_model #(
        .ADDR_W(SRAM_AW),
        .DATA_W(32)
    ) u_sram (
        .clk   (clk),
        .addr  (sramaddr[RAM_ADDR_W-1:2]),
        .wdata (sramwdata),
        .wen   (sramwen),
        .cs    (sramcs),
        .rdata (sramrdata)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
