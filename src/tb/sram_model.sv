// Simple behavioral SRAM model for testbench use
module sram_model #(
    parameter ADDR_W = 12,
    parameter DATA_W = 32
)(
    input  logic                clk,
    input  logic [ADDR_W-1:0]   addr,
    input  logic [DATA_W-1:0]   wdata,
    input  logic [DATA_W/8-1:0] wen,
    input  logic                cs,
    output logic [DATA_W-1:0]   rdata
);

    localparam AWT = ((1<<ADDR_W)-1);

    // Memory Array
    reg     [7:0]   BRAM0 [AWT:0];
    reg     [7:0]   BRAM1 [AWT:0];
    reg     [7:0]   BRAM2 [AWT:0];
    reg     [7:0]   BRAM3 [AWT:0];

    // Internal signals
    reg     [ADDR_W-1:0]  addr_q1;
    wire           [3:0]  write_enable;
    reg                   cs_reg;
    wire          [31:0]  read_data;

    assign write_enable[3:0] = wen[3:0] & {4{cs}};

    always @ (posedge clk) begin
        cs_reg <= cs;
    end

    // Infer Block RAM - syntax is very specific.
    always @ (posedge clk) begin
        if (write_enable[0])
            BRAM0[addr] <= wdata[7:0];
        if (write_enable[1])
            BRAM1[addr] <= wdata[15:8];
        if (write_enable[2])
            BRAM2[addr] <= wdata[23:16];
        if (write_enable[3])
            BRAM3[addr] <= wdata[31:24];
        // do not use enable on read interface.
        addr_q1 <= addr[ADDR_W-1:0];
    end

    assign read_data  = {BRAM3[addr_q1],BRAM2[addr_q1],BRAM1[addr_q1],BRAM0[addr_q1]};

    assign rdata      = (cs_reg) ? read_data : {32{1'b0}};

endmodule
