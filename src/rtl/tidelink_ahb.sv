//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB Token-based FIFO Interface
// - A FIFO interface over AHB for transferring variable-length packets of data
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_ahb #(
    // System Parameters
    parameter SYS_DATA_W = 32,  // System Data Width
    parameter RAM_ADDR_W = 14,  // Size of SRAM
    parameter RAM_DATA_W = 32   // Data Width of RAM
)(
    // --------------------------------------------------------------------------
    // Port Definitions
    // --------------------------------------------------------------------------
    input  wire                  hclk,      // system bus clock
    input  wire                  hresetn,   // system bus reset
    input  wire                  hsel,      // AHB peripheral select
    input  wire                  hready,    // AHB ready input
    input  wire            [1:0] htrans,    // AHB transfer type
    input  wire            [2:0] hsize,     // AHB hsize
    input  wire                  hwrite,    // AHB hwrite
    input  wire [RAM_ADDR_W-1:0] haddr,     // AHB address bus
    input  wire [SYS_DATA_W-1:0] hwdata,    // AHB write data bus
    output wire                  hreadyout, // AHB ready output to S->M mux
    output wire                  hresp,     // AHB response
    output wire [SYS_DATA_W-1:0] hrdata,    // AHB read data bus
    
    output wire                  write_addr_hit,
    output wire                  read_addr_hit,
    
    output wire [RAM_ADDR_W-2:0] current_token_count
);
    
    localparam MAX_TOKENS = (1 << (RAM_ADDR_W - 2)); // Maximum number of tokens in the FIFO, based on the address width and the fact that each token corresponds to a 32-bit word (4 bytes)
    
    // Internal Wiring
    logic  [RAM_ADDR_W-3:0] addr;
    logic  [RAM_DATA_W-1:0] wdata;
    logic  [RAM_DATA_W-1:0] rdata;
    logic             [3:0] wen;
    logic                   cs;
    
    // Address translation when reading/writing from FIFO
    // Pointer offset is registered in sync with cmsdk_ahb_to_sram's internal
    // address latch, then added to the SRAMADDR output to form the SRAM address
    logic [RAM_ADDR_W-3:0] ptr_offset, ptr_offset_nxt;
    logic [RAM_ADDR_W-3:0] translated_addr;
    
    // These pointers only get incremented when a address gets hit
    logic [RAM_ADDR_W-1:0] read_ptr, read_ptr_nxt;
    logic [RAM_ADDR_W-1:0] write_ptr, write_ptr_nxt;
    
    // Target Addresses to hit
    logic [RAM_ADDR_W-1:0] read_target_addr, read_target_addr_nxt;
    logic [RAM_ADDR_W-1:0] write_target_addr, write_target_addr_nxt;

    // Packet metadata — declared early so both always_comb blocks can use them
    logic [RAM_ADDR_W-1:0] packet_word_length, packet_word_length_nxt;
    logic [RAM_ADDR_W-1:0] packet_word_count, packet_word_count_nxt;
    logic check_addr, check_addr_nxt;
    
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            read_ptr  <= '0;
            write_ptr <= '0;
        end else begin
            read_ptr  <= read_ptr_nxt;
            write_ptr <= write_ptr_nxt;
        end
    end
    
    always_comb begin
        // Translate the address as a FIFO
        write_ptr_nxt = write_ptr;
        read_ptr_nxt  = read_ptr;
        // Compute the pointer offset in word-address space for this cycle
        ptr_offset_nxt = (hwrite ? write_ptr : read_ptr) >> 2;
        
        // If the address hits the target address for either a read or a write, then increment the relevant pointer to move to the next address in the FIFO
        // Only update pointers on valid AHB transfers (HSEL=1 and HTRANS=NONSEQ or SEQ)
        if (hsel && htrans[1] && (packet_word_length != '0)) begin
            if (haddr == write_target_addr && hwrite) begin
                write_ptr_nxt = write_ptr + (packet_word_length + 1) * 4; // Advance write pointer past length word + data words
            end else if (haddr == read_target_addr && ~hwrite) begin
                read_ptr_nxt = read_ptr + (packet_word_length + 1) * 4; // Advance read pointer past length word + data words
            end
        end
    end

    // Register the pointer offset so it aligns with the data phase
    // (matches the 1-cycle pipeline inside cmsdk_ahb_to_sram)
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ptr_offset <= '0;
        end else begin
            ptr_offset <= ptr_offset_nxt;
        end
    end

    // translated_addr = SRAMADDR from cmsdk_ahb_to_sram + registered pointer offset
    // Both are word addresses, both pipelined by 1 cycle, so they're aligned
    assign translated_addr = addr + ptr_offset;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            packet_word_length <= '0;
            packet_word_count  <= '0;
            check_addr         <= 1'b0;
        end else begin
            packet_word_length <= packet_word_length_nxt;
            packet_word_count  <= packet_word_count_nxt;
            check_addr         <= check_addr_nxt;
        end
    end
    
    always_comb begin
        // If reading or writing to address 0, this will be the length of the packet in words (4 bytes)
        check_addr_nxt = check_addr; // Default to hold the check address flag
        packet_word_length_nxt = packet_word_length; // Default to hold the current packet word length
        if (haddr == 0 && hwrite) begin
            packet_word_length_nxt = hwdata[RAM_ADDR_W-1:0];
        end else if (haddr == 0 && ~hwrite) begin
            // Address not ready until the next cycle, so set a flag to check the address in the next cycle and capture the packet length if it is still address 0
            check_addr_nxt = 1'b1;
        end else if (check_addr) begin
            // Capture the output from the SRAM when reading from address 0, which will be the packet length, and then reset the check address flag
            packet_word_length_nxt = rdata[RAM_ADDR_W-1:0];
            check_addr_nxt = 1'b0;
        end
        
        // Work out the target address required to consume or release tokens from the FIFO, which is the base address plus the packet length in bytes (packet length in words * 4)
        write_target_addr_nxt = packet_word_length * 4; // Target haddr for last data beat of a write packet
        read_target_addr_nxt  = packet_word_length * 4; // Target haddr for last data beat of a read packet
    end
    
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            write_target_addr <= '0;
            read_target_addr  <= '0;
        end else begin
            write_target_addr <= write_target_addr_nxt;
            read_target_addr  <= read_target_addr_nxt;
        end
    end
    
    assign write_addr_hit = (haddr == write_target_addr) && (packet_word_length != '0);
    assign read_addr_hit  = (haddr == read_target_addr)  && (packet_word_length != '0);
    
    //-----------------------------------
    // Token Counter for FIFO Management
    //-----------------------------------
    // One token per 32-bit word in the packet, so we can track how many tokens are currently in the FIFO to prevent overflow and underflow
    logic [RAM_ADDR_W-2:0] token_count, token_count_nxt;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            token_count <= MAX_TOKENS; // Start with an empty FIFO (max tokens available)
        end else begin
            token_count <= token_count_nxt;
        end
    end
    
    // Modify the token count based on completed read and write packets
    always_comb begin
        token_count_nxt = token_count; // Default: hold
        if (hsel && htrans[1] && (packet_word_length != '0)) begin
            if (haddr == write_target_addr && hwrite) begin
                // Check for completed write packet (write address hit) and decrement token count by the packet length
                token_count_nxt = token_count - (packet_word_length + 1); // Decrement token count by the packet length
            end else if (haddr == read_target_addr && ~hwrite) begin
                // Check for completed read packet (read address hit) and increment token count by the packet length
                token_count_nxt = token_count + (packet_word_length + 1); // Increment token count by the packet length
            end
        end
    end
    
    // TODO: Implement a master interface on the AHB which can communicate to an address set in memory in an APB register to report the current token count
    // and to report a token release when a packet is read out of the FIFO, so the software can track the token count and know when it's safe to write new packets 
    // to the FIFO without overflowing it.
    
    assign current_token_count = token_count;
    
    //------------------------------------------------
    // Instantiate AHB to SRAM adapter and SRAM model
    //------------------------------------------------

    // AHB to SRAM Conversion
    cmsdk_ahb_to_sram #(
        .AW (RAM_ADDR_W)
    ) u_ahb_to_sram (
        // AHB Inputs
        .HCLK       (hclk),
        .HRESETn    (hresetn),
        .HSEL       (hsel),
        .HADDR      (haddr),
        .HTRANS     (htrans),
        .HSIZE      (hsize),
        .HWRITE     (hwrite),
        .HWDATA     (hwdata),
        .HREADY     (hready),

        // AHB Outputs
        .HREADYOUT  (hreadyout),
        .HRDATA     (hrdata),
        .HRESP      (hresp),

        // SRAM input
        .SRAMRDATA  (rdata),

        // SRAM Outputs
        .SRAMADDR   (addr),
        .SRAMWDATA  (wdata),
        .SRAMWEN    (wen),
        .SRAMCS     (cs)
   );

    // FPGA SRAM model
    cmsdk_fpga_sram #(
        .AW (RAM_ADDR_W)
    ) u_sram (
        // SRAM Inputs
        .CLK        (hclk),
        .ADDR       (translated_addr),
        .WDATA      (wdata),
        .WREN       (wen),
        .CS         (cs),

        // SRAM Output
        .RDATA      (rdata)
    );
endmodule
