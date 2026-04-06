// Cocotb wrapper for tidelink_addr_translator standalone testing.
//
// Exposes the APB config slave interface and two address translation
// channels as flat ports for cocotb signal-level driving.
// Parameterised for NUM_CHANNELS and NUM_RULES to test the CAM-based
// address translator.
module tb_top #(
    parameter NUM_CHANNELS = 2,
    parameter NUM_RULES    = 8
)(
    input  logic        hclk,
    input  logic        hresetn,

    // APB Slave -- Config registers (prefix "apbc")
    input  logic        apbc_psel,
    input  logic        apbc_penable,
    input  logic        apbc_pwrite,
    input  logic [15:0] apbc_paddr,
    input  logic [31:0] apbc_pwdata,
    input  logic [3:0]  apbc_pstrb,
    input  logic [2:0]  apbc_pprot,
    output logic [31:0] apbc_prdata,
    output logic        apbc_pready,
    output logic        apbc_pslverr,

    // Address translation channel 0
    input  logic [31:0] chp0_ahb_haddr_i,
    output logic [31:0] chp0_ahb_haddr_o,

    // Address translation channel 1
    input  logic [31:0] chp1_ahb_haddr_i,
    output logic [31:0] chp1_ahb_haddr_o
);

    tidelink_addr_translator #(
        .NUM_CHANNELS (NUM_CHANNELS),
        .NUM_RULES    (NUM_RULES)
    ) u_dut (
        .CLK               (hclk),
        .RESETn            (hresetn),

        // APB config slave
        .chp_adr_paddr     (apbc_paddr),
        .chp_adr_psel      (apbc_psel),
        .chp_adr_penable   (apbc_penable),
        .chp_adr_pwrite    (apbc_pwrite),
        .chp_adr_pwdata    (apbc_pwdata),
        .chp_adr_pstrb     (apbc_pstrb),
        .chp_adr_pprot     (apbc_pprot),
        .chp_adr_prdata    (apbc_prdata),
        .chp_adr_pready    (apbc_pready),
        .chp_adr_pslverr   (apbc_pslverr),

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
