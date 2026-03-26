module tidelink #(
    parameter DESCRIPTOR_FIFO_DEPTH = 16,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14  // 16KB of addressable space
)(
    input  logic                clk,
    input  logic                rst_n,
    
    // AHB Slave Port - Data (SRAM)
    input  logic         [31:0] haddr_data,
    input  logic         [2:0]  hburst_data,
    input  logic                hmastlock_data,
    input  logic         [3:0]  hprot_data,
    input  logic         [2:0]  hsize_data,
    input  logic         [1:0]  htrans_data,
    input  logic         [31:0] hwdata_data,
    input  logic                hwrite_data,
    output logic         [31:0] hrdata_data,
    output logic                hready_data,
    output logic         [1:0]  hresp_data,
    
    // AHB Slave Port - Control & Configuration
    input  logic         [31:0] haddr_ctrl,
    input  logic         [2:0]  hburst_ctrl,
    input  logic                hmastlock_ctrl,
    input  logic         [3:0]  hprot_ctrl,
    input  logic         [2:0]  hsize_ctrl,
    input  logic         [1:0]  htrans_ctrl,
    input  logic         [31:0] hwdata_ctrl,
    input  logic                hwrite_ctrl,
    output logic         [31:0] hrdata_ctrl,
    output logic                hready_ctrl,
    output logic         [1:0]  hresp_ctrl,
    
    // Interupt output
    output logic                irq_out
);

    // Default responses
    assign hrdata_ctrl  = 32'h0;
    assign hready_ctrl  = 1'b1;
    assign hresp_ctrl   = 2'b00;  // OKAY response
    
    assign hrdata_data  = 32'h0;
    assign hready_data  = 1'b1;
    assign hresp_data   = 2'b00;  // OKAY response
    
    // Internal Wiring
    wire  [RAM_ADDR_W-3:0] addr;
    wire            [31:0] wdata;
    wire            [31:0] rdata;
    wire             [3:0] wen;
    wire                   cs;
    
    // AHB to SRAM Conversion
    tidelink_fifo #(
        .RAM_ADDR_W (RAM_ADDR_W)
    ) u_tidelink_fifo (
        // AHB Inputs
        .hclk       (clk),
        .hresetn    (rst_n),
        .hsel       (hsel_data),  
        .haddr      (haddr_data[RAM_ADDR_W-1:0]),
        .htrans     (htrans_data),
        .hsize      (hsize_data),
        .hwrite     (hwrite_data),
        .hwdata     (hwdata_data),
        .hready     (hready_data),

        // AHB Outputs
        .hreadyout  (hready_data),
        .hrdata     (hrdata_data),
        .hresp      (hresp_data),

        // SRAM input
        .sramrdata  (rdata),
        
        // SRAM Outputs
        .sramaddr   (addr),
        .sramwdata  (wdata),
        .sramwen    (wen),
        .sramcs     (cs)
   );
    
    /* SRAM Managaer */
    tidelink_fifo #(
        
    ) u_sram_manager (
        // AHB Inputs
        .hclk       (clk),
        .hresetn    (rst_n),
        .hsel       (hsel_ctrl),  
        .haddr      (haddr_ctrl[RAM_ADDR_W-1:0]),
        .htrans     (htrans_ctrl),
        .hsize      (hsize_ctrl),
        .hwrite     (hwrite_ctrl),
        .hwdata     (hwdata_ctrl),
        .hready     (hready_ctrl),

        // AHB Outputs
        .hreadyout  (hready_ctrl),
        .hrdata     (hrdata_ctrl),
        .hresp      (hresp_ctrl),

        // SRAM input
        .sramrdata  (rdata),
        
        // SRAM Outputs
        .sramaddr   (addr),
        .sramwdata  (wdata),
        .sramwen    (wen),
        .sramcs     (cs)
    );

    // FPGA SRAM model
    cmsdk_fpga_sram #(
        .AW (RAM_ADDR_W)
    ) u_sram (
        // SRAM Inputs
        .CLK        (clk),
        .ADDR       (addr),
        .WDATA      (wdata),
        .WREN       (wen),
        .CS         (cs),
        
        // SRAM Output
        .RDATA      (rdata)
    );
    
    /* TideLink Register Bank */
    
    /* TideLink Interupt generator */
    
    /*  */

endmodule