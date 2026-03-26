// Cocotb wrapper: stitches tidelink_control_counter + tidelink_sram_manager + sram_model
// Exposes AXI-Stream in/out interfaces for cocotb to drive
module tb_top #(
    parameter RAM_ADDR_W = 14,
    parameter WORD_LEN_W = 8
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Input (command + write data, driven by cocotb)
    input  logic [31:0] in_tdata,
    input  logic        in_tvalid,
    output logic        in_tready,
    input  logic        in_tlast,

    // AXI-Stream Output (read data, monitored by cocotb)
    output logic [31:0] out_tdata,
    output logic        out_tvalid,
    input  logic        out_tready,
    output logic        out_tlast
);

    localparam SRAM_AW = RAM_ADDR_W - 2;

    // AXI-Stream Control (control_counter -> sram_manager)
    logic [22:0] ctrl_tdata;
    logic        ctrl_tvalid;
    logic        ctrl_tready;

    // AXI-Stream Data Out (control_counter -> sram_manager din)
    logic [31:0] cc_dout_tdata;
    logic        cc_dout_tvalid;
    logic        cc_dout_tlast;
    logic        cc_dout_tready;

    // AXI-Stream Data In (sram_manager dout -> control_counter din)
    logic [31:0] sm_dout_tdata;
    logic        sm_dout_tvalid;
    logic        sm_dout_tlast;
    logic        sm_dout_tready;

    // SRAM Interface (internal)
    logic [RAM_ADDR_W-1:0] sramaddr;
    logic           [31:0] sramwdata;
    logic            [3:0] sramwen;
    logic                  sramcs;
    logic           [31:0] sramrdata;

    // ── Control Counter ──────────────────────────────────────────────────
    tidelink_control_counter #(
        .RAM_ADDR_W(RAM_ADDR_W),
        .WORD_LEN_W(WORD_LEN_W)
    ) u_ctrl_counter (
        .clk        (clk),
        .rst_n      (rst_n),

        // AXI-Stream Input
        .in_tdata   (in_tdata),
        .in_tvalid  (in_tvalid),
        .in_tready  (in_tready),
        .in_tlast   (in_tlast),

        // AXI-Stream Output
        .out_tdata  (out_tdata),
        .out_tvalid (out_tvalid),
        .out_tready (out_tready),
        .out_tlast  (out_tlast),

        // AXI-Stream Control Out -> sram_manager ctrl in
        .ctrl_tdata (ctrl_tdata),
        .ctrl_tvalid(ctrl_tvalid),
        .ctrl_tready(ctrl_tready),

        // AXI-Stream Data Out -> sram_manager din
        .dout_tdata (cc_dout_tdata),
        .dout_tvalid(cc_dout_tvalid),
        .dout_tlast (cc_dout_tlast),
        .dout_tready(cc_dout_tready),

        // AXI-Stream Data In <- sram_manager dout
        .din_tdata  (sm_dout_tdata),
        .din_tvalid (sm_dout_tvalid),
        .din_tlast  (sm_dout_tlast),
        .din_tready (sm_dout_tready)
    );

    // ── SRAM Manager ─────────────────────────────────────────────────────
    tidelink_sram_manager #(
        .RAM_ADDR_W(RAM_ADDR_W),
        .WORD_LEN_W(WORD_LEN_W)
    ) u_sram_mgr (
        .clk        (clk),
        .rst_n      (rst_n),

        // AXI-Stream Control In <- control_counter
        .ctrl_tdata (ctrl_tdata),
        .ctrl_tvalid(ctrl_tvalid),
        .ctrl_tready(ctrl_tready),

        // AXI-Stream Data In <- control_counter dout
        .din_tdata  (cc_dout_tdata),
        .din_tvalid (cc_dout_tvalid),
        .din_tlast  (cc_dout_tlast),
        .din_tready (cc_dout_tready),

        // AXI-Stream Data Out -> control_counter din
        .dout_tdata (sm_dout_tdata),
        .dout_tvalid(sm_dout_tvalid),
        .dout_tlast (sm_dout_tlast),
        .dout_tready(sm_dout_tready),

        // SRAM Interface
        .sramaddr   (sramaddr),
        .sramwdata  (sramwdata),
        .sramwen    (sramwen),
        .sramcs     (sramcs),
        .sramrdata  (sramrdata)
    );

    // ── SRAM Model ───────────────────────────────────────────────────────
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
