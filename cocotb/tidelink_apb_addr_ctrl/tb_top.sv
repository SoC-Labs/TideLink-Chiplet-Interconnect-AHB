// Cocotb wrapper for tidelink_apb_addr_ctrl standalone testing.
//
// The DUT consumes an apb4_if SystemVerilog interface (subordinate modport)
// for its APB slave port. cocotb can only drive flat scalar/vector ports,
// so this wrapper instantiates an apb4_if and bridges every signal to a
// flat top-level port. The DUT's unpacked segment-address output array is
// flattened to a single packed vector so the test can index into it via
// dut.seg_addr_flat.value.
module tb_top #(
    parameter ADDR_W    = 12,
    parameter DATA_W    = 32,
    parameter SEG_IDX_W = 8,
    parameter NUM_SEGS  = 256
)(
    input  logic                 PCLK,
    input  logic                 PRESETn,

    // APB master-driven signals (flat)
    input  logic   [ADDR_W-1:0]  paddr,
    input  logic   [DATA_W-1:0]  pwdata,
    input  logic                 penable,
    input  logic                 pwrite,
    input  logic                 psel,
    input  logic   [2:0]         pprot,
    input  logic   [3:0]         pstrb,

    // APB subordinate-driven signals (flat)
    output logic   [DATA_W-1:0]  prdata,
    output logic                 pready,
    output logic                 pslverr,

    // DUT outputs
    output logic   [DATA_W-1:0]              base_offset,
    output logic   [NUM_SEGS*SEG_IDX_W-1:0]  seg_addr_flat
);

    // APB interface instance
    apb4_if ctrl_apb();

    // Drive interface from flat inputs (master side of the link)
    assign ctrl_apb.paddr   = {{(32-ADDR_W){1'b0}}, paddr};
    assign ctrl_apb.pwdata  = pwdata;
    assign ctrl_apb.penable = penable;
    assign ctrl_apb.pwrite  = pwrite;
    assign ctrl_apb.psel    = psel;
    assign ctrl_apb.pprot   = pprot;
    assign ctrl_apb.pstrb   = pstrb;

    // Drive flat outputs from interface (subordinate side of the link)
    assign prdata  = ctrl_apb.prdata;
    assign pready  = ctrl_apb.pready;
    assign pslverr = ctrl_apb.pslverr;

    // DUT unpacked output array — flatten into packed vector for cocotb
    wire [SEG_IDX_W-1:0] seg_addr_arr [NUM_SEGS];

    genvar i;
    generate
        for (i = 0; i < NUM_SEGS; i = i + 1) begin : g_flat
            assign seg_addr_flat[i*SEG_IDX_W +: SEG_IDX_W] = seg_addr_arr[i];
        end
    endgenerate

    tidelink_apb_addr_ctrl #(
        .ADDR_W    (ADDR_W),
        .DATA_W    (DATA_W),
        .SEG_IDX_W (SEG_IDX_W),
        .NUM_SEGS  (NUM_SEGS)
    ) u_dut (
        .PCLK        (PCLK),
        .PRESETn     (PRESETn),
        .CTRL_APB    (ctrl_apb.subordinate),
        .seg_addr    (seg_addr_arr),
        .base_offset (base_offset)
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
