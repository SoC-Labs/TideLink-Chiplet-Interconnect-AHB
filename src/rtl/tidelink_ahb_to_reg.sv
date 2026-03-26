//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB-to-Register Interface
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module implements an AHB slave interface that converts AHB transactions
// into a simple register read/write interface. Based on the ARM CMSDK
// cmsdk_ahb_eg_slave_interface pattern, rewritten in SystemVerilog.
//
// Features:
// - Zero wait-state AHB slave (HREADYOUT always high)
// - Supports byte, halfword, and word transfers via byte-lane strobes
// - Address-phase to data-phase pipeline for AHB protocol compliance
// - Parameterized address width for flexible register bank sizing
//-----------------------------------------------------------------------------
module tidelink_ahb_to_reg #(
    parameter ADDR_W = 12  // Register address width (byte-addressed)
)(
    input  logic                hclk,
    input  logic                hresetn,

    // AHB Slave Interface
    input  logic                hsel,
    input  logic                hready,
    input  logic  [1:0]         htrans,
    input  logic  [2:0]         hsize,
    input  logic                hwrite,
    input  logic  [ADDR_W-1:0]  haddr,
    input  logic  [31:0]        hwdata,
    output logic                hreadyout,
    output logic                hresp,
    output logic  [31:0]        hrdata,

    // Register Interface
    output logic  [ADDR_W-1:0]  reg_addr,
    output logic                reg_read_en,
    output logic                reg_write_en,
    output logic  [3:0]         reg_byte_strobe,
    output logic  [31:0]        reg_wdata,
    input  logic  [31:0]        reg_rdata
);

    // ----------------------------------------
    // Internal wires declarations
    logic                   trans_req;
    // transfer request issued only in SEQ and NONSEQ status and slave is
    // selected and last transfer finish
    
    logic                   ahb_read_req;
    logic                   ahb_write_req;
    logic                   update_read_req;    // To update the read enable register
    logic                   update_write_req;   // To update the write enable register
    
    logic     [ADDR_W-1:0]   addr_reg;     // address signal, registered
    logic                    read_en_reg;  // read enable signal, registered
    logic                    write_en_reg; // write enable signal, registered
    
    logic  [3:0]             byte_strobe_reg; // registered output for byte strobe
    logic  [3:0]             byte_strobe_nxt; // next state for byte_strobe_reg
    
    assign trans_req     = hready & hsel & htrans[1]; // AHB transfer request, valid when there is an active transfer (HREADY=1), slave is selected (HSEL=1) and the transfer is NONSEQ or SEQ (HTRANS[1]=1)
    assign ahb_read_req  = trans_req & (~hwrite);// AHB read request
    assign ahb_write_req = trans_req &  hwrite;  // AHB write request
    
    //-----------------------------------------------------------
    // Module logic start
    //----------------------------------------------------------

    // Address signal registering, to make the address and data active at the same cycle
    always_ff @(posedge hclk or negedge hresetn) begin
        if (~hresetn) begin
            addr_reg <= {(ADDR_W){1'b0}}; //default address 0 is selected
        end
        else if (trans_req) begin
            addr_reg <= haddr[ADDR_W-1:0];
        end
    end


    // register read signal generation
    assign update_read_req = ahb_read_req | (read_en_reg & hready); // Update read enable control if
                                    //  1. When there is a valid read request
                                    //  2. When there is an active read, update it at the end of transfer (HREADY=1)

    always_ff @(posedge hclk or negedge hresetn) begin
        if (~hresetn) begin
            read_en_reg <= 1'b0;
        end
        else if (update_read_req) begin
            read_en_reg  <= ahb_read_req;
        end
    end

    // register write signal generation
    assign update_write_req = ahb_write_req |( write_en_reg & hready);  // Update write enable control if
                                    //  1. When there is a valid write request
                                    //  2. When there is an active write, update it at the end of transfer (HREADY=1)

    always_ff @(posedge hclk or negedge hresetn) begin
        if (~hresetn) begin
            write_en_reg <= 1'b0;
        end
        else if (update_write_req) begin
            write_en_reg  <= ahb_write_req;
        end
    end

    // byte strobe signal
    always_comb begin
        if (hsize == 3'b000) begin
            case(haddr[1:0])
                2'b00: byte_strobe_nxt = 4'b0001;
                2'b01: byte_strobe_nxt = 4'b0010;
                2'b10: byte_strobe_nxt = 4'b0100;
                2'b11: byte_strobe_nxt = 4'b1000;
                default: byte_strobe_nxt = 4'bxxxx;
            endcase
        end
        else if (hsize == 3'b001) begin
            if(haddr[1]==1'b1)
            byte_strobe_nxt = 4'b1100;
            else
            byte_strobe_nxt = 4'b0011;
        end
        else begin
            byte_strobe_nxt = 4'b1111;
        end
    end

    always_ff @(posedge hclk or negedge hresetn) begin
        if (~hresetn) begin
            byte_strobe_reg <= {4{1'b0}};
        end
        else if (update_read_req|update_write_req) begin
            // Update byte strobe registers if
            // 1. if there is a valid read/write transfer request
            // 2. if there is an on going transfer
            byte_strobe_reg  <= byte_strobe_nxt;
        end
    end

    //-----------------------------------------------------------
    // Outputs
    //-----------------------------------------------------------
    // For simplify the timing, the master and slave signals are connected directly, execpt data bus.
    assign reg_addr        = addr_reg[ADDR_W-1:0];
    assign reg_read_en     = read_en_reg;
    assign reg_write_en    = write_en_reg;
    assign reg_wdata       = hwdata;
    assign reg_byte_strobe = byte_strobe_reg;

    assign hreadyout       = 1'b1;  // slave always ready
    assign hresp           = 1'b0;  // OKAY response from slave
    assign hrdata          = reg_rdata;

endmodule
