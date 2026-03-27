// Cocotb wrapper for tidelink_ahb_returner (3-channel version)
// Exposes AHB bus signals as ports so cocotbext-ahb AHBLiteSlaveRAM
// can drive slave responses from Python.
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32
)(
    input  logic                  hclk,
    input  logic                  hresetn,

    // Interrupt channel 0 (release tokens — highest priority)
    input  logic                  interrupt_0,
    input  logic [SYS_ADDR_W-1:0] write_addr_0,
    input  logic [SYS_DATA_W-1:0] write_data_0,

    // Interrupt channel 1 (doorbell — medium priority)
    input  logic                  interrupt_1,
    input  logic [SYS_ADDR_W-1:0] write_addr_1,
    input  logic [SYS_DATA_W-1:0] write_data_1,

    // Interrupt channel 2 (reset doorbell — lowest priority)
    input  logic                  interrupt_2,
    input  logic [SYS_ADDR_W-1:0] write_addr_2,
    input  logic [SYS_DATA_W-1:0] write_data_2,

    // AHB Lite bus signals (exposed for cocotbext-ahb)
    output logic [SYS_ADDR_W-1:0] haddr,
    output logic [SYS_DATA_W-1:0] hwdata,
    output logic            [1:0] htrans,
    output logic            [2:0] hsize,
    output logic                  hwrite,
    input  logic                  hready,
    input  logic                  hresp,
    input  logic [SYS_DATA_W-1:0] hrdata,

    // Status
    output logic                  busy,
    output logic                  master_error,
    input  logic                  flush
);

    // DUT instantiation
    tidelink_returner #(
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W)
    ) u_dut (
        .hclk        (hclk),
        .hresetn     (hresetn),
        .interrupt_0 (interrupt_0),
        .write_addr_0(write_addr_0),
        .write_data_0(write_data_0),
        .interrupt_1 (interrupt_1),
        .write_addr_1(write_addr_1),
        .write_data_1(write_data_1),
        .interrupt_2 (interrupt_2),
        .write_addr_2(write_addr_2),
        .write_data_2(write_data_2),
        .haddr       (haddr),
        .hwdata      (hwdata),
        .htrans      (htrans),
        .hsize       (hsize),
        .hwrite      (hwrite),
        .hready      (hready),
        .hresp       (hresp),
        .hrdata      (hrdata),
        .busy        (busy),
        .master_error(master_error),
        .flush       (flush)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
