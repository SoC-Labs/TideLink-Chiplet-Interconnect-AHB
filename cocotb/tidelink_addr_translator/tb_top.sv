// Cocotb wrapper for tidelink_addr_translator standalone testing.
//
// Exposes the AHB config slave interface and two address translation
// channels as flat ports for cocotb signal-level driving.
// Parameterised for NUM_CHANNELS and NUM_RULES to test the CAM-based
// address translator.
module tb_top #(
    parameter BE           = 0,
    parameter NUM_CHANNELS = 2,
    parameter NUM_RULES    = 8
)(
    input  logic        hclk,
    input  logic        hresetn,

    // AHB Slave -- Config registers via AHB-to-APB bridge (prefix "ahbc")
    input  logic        ahbc_hsel,
    input  logic [1:0]  ahbc_htrans,
    input  logic [2:0]  ahbc_hburst,
    input  logic        ahbc_hmastlock,
    input  logic [3:0]  ahbc_hprot,
    input  logic [2:0]  ahbc_hsize,
    input  logic [31:0] ahbc_haddr,
    input  logic [31:0] ahbc_hwdata,
    input  logic        ahbc_hwrite,
    output logic        ahbc_hready,
    output logic        ahbc_hresp,
    output logic [31:0] ahbc_hrdata,

    // Address translation channel 0
    input  logic [31:0] chp0_ahb_haddr_i,
    output logic [31:0] chp0_ahb_haddr_o,

    // Address translation channel 1
    input  logic [31:0] chp1_ahb_haddr_i,
    output logic [31:0] chp1_ahb_haddr_o
);

    // Single-slave loopback for config AHB slave
    wire ahbc_hreadyout;
    assign ahbc_hready = ahbc_hreadyout;

    tidelink_addr_translator #(
        .BE           (BE),
        .NUM_CHANNELS (NUM_CHANNELS),
        .NUM_RULES    (NUM_RULES)
    ) u_dut (
        .CLK               (hclk),
        .RESETn             (hresetn),

        // AHB config slave
        .chp_adr_hsel      (ahbc_hsel),
        .chp_adr_haddr     (ahbc_haddr),
        .chp_adr_hburst    (ahbc_hburst),
        .chp_adr_hmastlock (ahbc_hmastlock),
        .chp_adr_hprot     (ahbc_hprot),
        .chp_adr_hsize     (ahbc_hsize),
        .chp_adr_htrans    (ahbc_htrans),
        .chp_adr_hwdata    (ahbc_hwdata),
        .chp_adr_hwrite    (ahbc_hwrite),
        .chp_adr_hready    (ahbc_hready),
        .chp_adr_hrdata    (ahbc_hrdata),
        .chp_adr_hresp     (ahbc_hresp),
        .chp_adr_hreadyout (ahbc_hreadyout),

        // Address translation I/O
        .chp0_ahb_haddr_i  (chp0_ahb_haddr_i),
        .chp0_ahb_haddr_o  (chp0_ahb_haddr_o),
        .chp1_ahb_haddr_i  (chp1_ahb_haddr_i),
        .chp1_ahb_haddr_o  (chp1_ahb_haddr_o)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
