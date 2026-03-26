// Cocotb wrapper for tidelink top-level module
// Exposes AHB slave (FIFO), AHB master (returner), and APB (config) interfaces
// for cocotb drivers to interact with.
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // AHB Slave interface (cocotbext AHBLiteMaster drives these, prefix "ahbs")
    input  logic                    ahbs_hsel,
    input  logic              [1:0] ahbs_htrans,
    input  logic              [2:0] ahbs_hsize,
    input  logic                    ahbs_hwrite,
    input  logic   [RAM_ADDR_W-1:0] ahbs_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbs_hwdata,
    output logic                    ahbs_hready,
    output logic                    ahbs_hresp,
    output logic   [SYS_DATA_W-1:0] ahbs_hrdata,

    // AHB Master interface (cocotbext AHBLiteSlaveRAM responds, prefix "ahbm")
    output logic   [SYS_ADDR_W-1:0] ahbm_haddr,
    output logic   [SYS_DATA_W-1:0] ahbm_hwdata,
    output logic              [1:0] ahbm_htrans,
    output logic              [2:0] ahbm_hsize,
    output logic                    ahbm_hwrite,
    input  logic                    ahbm_hready,
    input  logic                    ahbm_hresp,
    input  logic   [SYS_DATA_W-1:0] ahbm_hrdata,

    // APB Slave interface (driven manually from Python)
    input  logic                    apbs_psel,
    input  logic                    apbs_penable,
    input  logic                    apbs_pwrite,
    input  logic   [APB_ADDR_W-1:0] apbs_paddr,
    input  logic   [SYS_DATA_W-1:0] apbs_pwdata,
    output logic   [SYS_DATA_W-1:0] apbs_prdata,
    output logic                    apbs_pready,
    output logic                    apbs_pslverr,

    // Interrupt output
    output logic                    released_tokens_irq
);

    // Single-slave loopback: hready = hreadyout
    wire ahbs_hreadyout;
    assign ahbs_hready = ahbs_hreadyout;

    tidelink #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .RAM_DATA_W (RAM_DATA_W),
        .APB_ADDR_W (APB_ADDR_W)
    ) u_dut (
        .hclk            (hclk),
        .hresetn         (hresetn),

        // AHB Slave
        .ahbs_hsel       (ahbs_hsel),
        .ahbs_hready     (ahbs_hready),
        .ahbs_htrans     (ahbs_htrans),
        .ahbs_hsize      (ahbs_hsize),
        .ahbs_hwrite     (ahbs_hwrite),
        .ahbs_haddr      (ahbs_haddr),
        .ahbs_hwdata     (ahbs_hwdata),
        .ahbs_hreadyout  (ahbs_hreadyout),
        .ahbs_hresp      (ahbs_hresp),
        .ahbs_hrdata     (ahbs_hrdata),

        // AHB Master
        .ahbm_haddr      (ahbm_haddr),
        .ahbm_hwdata     (ahbm_hwdata),
        .ahbm_htrans     (ahbm_htrans),
        .ahbm_hsize      (ahbm_hsize),
        .ahbm_hwrite     (ahbm_hwrite),
        .ahbm_hready     (ahbm_hready),
        .ahbm_hresp      (ahbm_hresp),
        .ahbm_hrdata     (ahbm_hrdata),

        // APB Slave
        .apbs_psel       (apbs_psel),
        .apbs_penable    (apbs_penable),
        .apbs_pwrite     (apbs_pwrite),
        .apbs_paddr      (apbs_paddr),
        .apbs_pwdata     (apbs_pwdata),
        .apbs_prdata     (apbs_prdata),
        .apbs_pready     (apbs_pready),
        .apbs_pslverr    (apbs_pslverr),

        // Interrupt
        .released_tokens_irq (released_tokens_irq)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
