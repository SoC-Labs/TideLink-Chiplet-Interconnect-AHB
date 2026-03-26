// Cocotb wrapper: instantiates tidelink_ahb_to_reg DUT + register bank model
// Exposes AHB ports with signal names matching cocotbext-ahb conventions
module tb_ahb_to_reg #(
    parameter ADDR_W = 12  // 4KB register space
)(
    input  logic               clk,
    input  logic               rst_n,

    // AHB signals (cocotbext-ahb auto-discovery names)
    input  logic        [31:0] haddr,
    input  logic         [2:0] hsize,
    input  logic         [1:0] htrans,
    input  logic        [31:0] hwdata,
    input  logic               hwrite,
    output logic               hready,
    output logic        [31:0] hrdata,
    output logic               hresp,

    // Directly exposed register interface for test observability
    output logic  [ADDR_W-1:0] reg_addr,
    output logic               reg_read_en,
    output logic               reg_write_en,
    output logic         [3:0] reg_byte_strobe,
    output logic        [31:0] reg_wdata,
    output logic        [31:0] reg_rdata
);

    // ----------------------------------------------------------
    // Internal signals
    // ----------------------------------------------------------
    logic hreadyout;

    // Single-slave loopback: HREADY = HREADYOUT
    assign hready = hreadyout;

    // ----------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------
    tidelink_ahb_to_reg #(
        .ADDR_W(ADDR_W)
    ) u_dut (
        .hclk       (clk),
        .hresetn    (rst_n),
        .hsel       (1'b1),          // Always selected (single slave)
        .hready     (hready),        // Loopback from hreadyout
        .htrans     (htrans),
        .hsize      (hsize),
        .hwrite     (hwrite),
        .haddr      (haddr[ADDR_W-1:0]),
        .hwdata     (hwdata),
        .hreadyout  (hreadyout),
        .hresp      (hresp),
        .hrdata     (hrdata),
        // Register interface
        .reg_addr       (reg_addr),
        .reg_read_en    (reg_read_en),
        .reg_write_en   (reg_write_en),
        .reg_byte_strobe(reg_byte_strobe),
        .reg_wdata      (reg_wdata),
        .reg_rdata      (reg_rdata)
    );

    // ----------------------------------------------------------
    // Simple register bank model (4KB / 1024 x 32-bit registers)
    // ----------------------------------------------------------
    localparam NUM_REGS = 2**(ADDR_W-2);  // Word-addressed

    logic [31:0] reg_bank [0:NUM_REGS-1];

    // Word-aligned address index
    wire [$clog2(NUM_REGS)-1:0] reg_idx = reg_addr[ADDR_W-1:2];

    // Register write with byte strobes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_REGS; i++)
                reg_bank[i] <= 32'h0;
        end else if (reg_write_en) begin
            if (reg_byte_strobe[0]) reg_bank[reg_idx][ 7: 0] <= reg_wdata[ 7: 0];
            if (reg_byte_strobe[1]) reg_bank[reg_idx][15: 8] <= reg_wdata[15: 8];
            if (reg_byte_strobe[2]) reg_bank[reg_idx][23:16] <= reg_wdata[23:16];
            if (reg_byte_strobe[3]) reg_bank[reg_idx][31:24] <= reg_wdata[31:24];
        end
    end

    // Combinational read (zero wait-state)
    assign reg_rdata = reg_bank[reg_idx];

    // ----------------------------------------------------------
    // Waveform dump
    // ----------------------------------------------------------
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_ahb_to_reg);
    end

endmodule
