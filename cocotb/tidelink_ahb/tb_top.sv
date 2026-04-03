// Cocotb wrapper for tidelink_fifo_ahb (AHB wrapper with AHB-to-APB bridge)
// Exposes three AHB interfaces:
//   ahbs_* — FIFO data path (driven by cocotbext AHBLiteMaster)
//   ahbc_* — Config registers via AHB-to-APB bridge (driven by second AHBLiteMaster)
//   ahbm_* — Returner master output (responded to by AHBLiteSlaveRAM)
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // AHB Slave — FIFO data path (prefix "ahbs")
    input  logic                    ahbs_hsel,
    input  logic              [1:0] ahbs_htrans,
    input  logic              [2:0] ahbs_hsize,
    input  logic                    ahbs_hwrite,
    input  logic   [RAM_ADDR_W-1:0] ahbs_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbs_hwdata,
    output logic                    ahbs_hready,
    output logic                    ahbs_hresp,
    output logic   [SYS_DATA_W-1:0] ahbs_hrdata,

    // AHB Slave — Config registers via bridge (prefix "ahbc")
    input  logic                    ahbc_hsel,
    input  logic              [1:0] ahbc_htrans,
    input  logic              [2:0] ahbc_hsize,
    input  logic                    ahbc_hwrite,
    input  logic   [APB_ADDR_W-1:0] ahbc_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbc_hwdata,
    output logic                    ahbc_hready,
    output logic                    ahbc_hresp,
    output logic   [SYS_DATA_W-1:0] ahbc_hrdata,

    // AHB Master — Returner (prefix "ahbm")
    output logic   [SYS_ADDR_W-1:0] ahbm_haddr,
    output logic   [SYS_DATA_W-1:0] ahbm_hwdata,
    output logic              [1:0] ahbm_htrans,
    output logic              [2:0] ahbm_hsize,
    output logic                    ahbm_hwrite,
    input  logic                    ahbm_hready,
    input  logic                    ahbm_hresp,
    input  logic   [SYS_DATA_W-1:0] ahbm_hrdata,

    // Interrupt outputs
    output logic                    released_credits_irq,
    output logic                    doorbell_irq,
    output logic                    packet_committed_irq
);

    // Single-slave loopback for FIFO AHB slave
    wire ahbs_hreadyout;
    assign ahbs_hready = ahbs_hreadyout;

    // Single-slave loopback for config AHB slave
    wire ahbc_hreadyout;
    assign ahbc_hready = ahbc_hreadyout;

    tidelink_fifo_ahb #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .RAM_DATA_W (RAM_DATA_W),
        .APB_ADDR_W (APB_ADDR_W)
    ) u_dut (
        .hclk               (hclk),
        .hresetn             (hresetn),

        // AHB Slave — FIFO
        .ahbs_hsel           (ahbs_hsel),
        .ahbs_hready         (ahbs_hready),
        .ahbs_htrans         (ahbs_htrans),
        .ahbs_hsize          (ahbs_hsize),
        .ahbs_hwrite         (ahbs_hwrite),
        .ahbs_haddr          (ahbs_haddr),
        .ahbs_hwdata         (ahbs_hwdata),
        .ahbs_hreadyout      (ahbs_hreadyout),
        .ahbs_hresp          (ahbs_hresp),
        .ahbs_hrdata         (ahbs_hrdata),

        // AHB Slave — Config
        .ahbc_hsel           (ahbc_hsel),
        .ahbc_hready         (ahbc_hready),
        .ahbc_htrans         (ahbc_htrans),
        .ahbc_hsize          (ahbc_hsize),
        .ahbc_hwrite         (ahbc_hwrite),
        .ahbc_haddr          (ahbc_haddr),
        .ahbc_hwdata         (ahbc_hwdata),
        .ahbc_hreadyout      (ahbc_hreadyout),
        .ahbc_hresp          (ahbc_hresp),
        .ahbc_hrdata         (ahbc_hrdata),

        // AHB Master — Returner
        .ahbm_haddr          (ahbm_haddr),
        .ahbm_hwdata         (ahbm_hwdata),
        .ahbm_htrans         (ahbm_htrans),
        .ahbm_hsize          (ahbm_hsize),
        .ahbm_hwrite         (ahbm_hwrite),
        .ahbm_hready         (ahbm_hready),
        .ahbm_hresp          (ahbm_hresp),
        .ahbm_hrdata         (ahbm_hrdata),

        // Interrupts
        .released_credits_irq (released_credits_irq),
        .doorbell_irq        (doorbell_irq),
        .packet_committed_irq(packet_committed_irq)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
