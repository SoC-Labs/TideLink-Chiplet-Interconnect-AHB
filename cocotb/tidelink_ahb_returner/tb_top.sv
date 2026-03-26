// Cocotb wrapper for tidelink_ahb_returner
// Exposes AHB bus signals as ports so cocotbext-ahb AHBLiteSlaveRAM
// can drive slave responses from Python.
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32
)(
    input  logic                  hclk,
    input  logic                  hresetn,

    // Interrupt stimulus
    input  logic                  interrupt,

    // Write parameters
    input  logic [SYS_ADDR_W-1:0] write_addr,
    input  logic [SYS_DATA_W-1:0] write_data,

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
    output logic                  busy
);

    // DUT instantiation
    tidelink_ahb_returner #(
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W)
    ) u_dut (
        .hclk       (hclk),
        .hresetn    (hresetn),
        .interrupt  (interrupt),
        .write_addr (write_addr),
        .write_data (write_data),
        .haddr      (haddr),
        .hwdata     (hwdata),
        .htrans     (htrans),
        .hsize      (hsize),
        .hwrite     (hwrite),
        .hready     (hready),
        .hresp      (hresp),
        .hrdata     (hrdata),
        .busy       (busy)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
